import AppKit
import SwiftUI

// MARK: - EdictApp

/// The application scene graph.
///
/// Declared without `@main` so it can live in a library target (and therefore be unit-testable);
/// `Sources/Edict/main.swift` calls `EdictApp.main()` to boot it.
///
/// This is a **real app**, not a menu-bar utility: a standard resizable `WindowGroup`, a full app
/// menu, a `Settings` scene on `Cmd+,`, and a Dock icon. `LSUIElement` is deliberately absent from
/// the Info.plist — RECON §25 confirmed a Dock icon, an app menu, a main window and an
/// `NSStatusItem` all coexist without it, and an `NSStatusItem` needs no plist key. The menu-bar
/// extra below is a *secondary* surface for when the user is in another app.
public struct EdictApp: App {

    /// Referenced by the menu-bar extra's "Window" button and by the `Window` menu command.
    public static let mainWindowID = "edict.main"

    /// The size a fresh window opens at. Comfortably above `D.size.windowMin` so the top deck and
    /// the history table both have room without the user reaching for the resize handle.
    static let windowIdeal = CGSize(width: 1180, height: 760)

    @NSApplicationDelegateAdaptor(EdictAppDelegate.self) private var delegate

    /// A `let`, not `@State`: `AppModel` is a main-actor singleton whose lifetime is the process,
    /// and re-creating it on a scene rebuild would orphan the running dictation controller.
    private let model = AppModel.shared

    public init() {}

    public var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            MainWindow(model: model)
                .frame(
                    minWidth: D.size.windowMin.width, idealWidth: Self.windowIdeal.width,
                    maxWidth: .infinity,
                    minHeight: D.size.windowMin.height, idealHeight: Self.windowIdeal.height,
                    maxHeight: .infinity
                )
                .task { await model.bootstrap() }
        }
        // A remembered size beats a nominal one, and SwiftUI restores the frame per scene id;
        // `defaultSize` only applies to the very first launch. Measured on a clean launch (with
        // `defaults delete com.srkk.edict "NSWindow Frame edict.main-AppWindow-1"`) by logging
        // `window.frame` from `viewDidMoveToWindow`: the window really is created at 1180x760.
        .defaultSize(width: Self.windowIdeal.width, height: Self.windowIdeal.height)
        // Spelled out rather than left `.automatic`, which resolves to exactly this for a
        // `WindowGroup` — naming it records the contract: **the window's minimum is the content's
        // minimum**, i.e. the root `.frame(minWidth:minHeight:)` above, i.e. `D.size.windowMin`.
        // The corollary is the rule every pane obeys: a pane whose intrinsic minimum exceeds
        // `windowMin` *becomes* the window's minimum, so each pane body sits in a `ScrollView` and
        // long content scrolls instead of growing the window. `.contentSize` would be wrong — it
        // pins the *maximum* to the content's too, and this window is meant to be dragged as large
        // as the user likes.
        .windowResizability(.contentMinSize)
        .commands { EdictCommands(model: model) }

        SwiftUI.Settings {
            SettingsWindow(model: model)
        }

        MenuBarExtra {
            EdictMenuBarContent(model: model)
        } label: {
            EdictMenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - App delegate

/// Activation policy, the HUD panel, and the two lifecycle hooks SwiftUI does not expose.
///
/// The HUD is an `NSPanel` rather than a SwiftUI `Window` scene because it must be a
/// `.nonactivatingPanel` that can never become key — see `HUDWindow.swift`. SwiftUI gives no way to
/// express that, so the panel is owned here, outside the scene graph.
@MainActor
public final class EdictAppDelegate: NSObject, NSApplicationDelegate {

    private var hud: HUDWindowController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Explicit, so a `swift run` of the executable (no Info.plist, RECON §25) still shows a
        // Dock icon and a menu bar instead of silently coming up as an accessory.
        NSApp.setActivationPolicy(.regular)

        let model = AppModel.shared
        hud = HUDWindowController(model: model)
        hud?.start()
    }

    /// The app is a background dictation tool with a status item; closing the window must not quit.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon with no windows open should bring the window back.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        // Both stores debounce their writes, so a dictation from the last half-second is only on
        // disk because of this call.
        hud?.stop()
        AppModel.shared.shutdown()
    }
}

// MARK: - Menus

/// The app menu.
///
/// Edict's whole interaction model is a key held down in another application, so every transport
/// action also has a menu item: it is the only discoverable list of what the app can do, and the
/// only path that works when the global hotkey is not permitted.
struct EdictCommands: Commands {

    let model: AppModel

    var body: some Commands {
        CommandMenu("Dictation") {
            Button(model.isRecording ? "Stop Dictation" : "Start Dictation") {
                model.toggleRecording()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!model.isRecording && !model.canStartRecording)

            Button("Cancel Dictation") {
                model.cancelRecording()
            }
            // `Cmd+.` is the platform's cancel gesture. Escape is not usable as a menu shortcut.
            .keyboardShortcut(".", modifiers: .command)
            .disabled(!model.phase.isActive)

            Divider()

            Button("Copy Last Transcript") {
                guard let last = model.lastTranscript ?? model.history.transcripts.first else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(last.text, forType: .string)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.history.transcripts.isEmpty)

            Divider()

            Toggle("Show Recording HUD", isOn: Binding(
                get: { model.settings.showHUD },
                set: { model.settings.showHUD = $0 }
            ))

            Toggle("Insert Text Automatically", isOn: Binding(
                get: { model.settings.autoInject },
                set: { model.settings.autoInject = $0 }
            ))

            Divider()

            Button("Restart Hotkey Monitor") {
                model.retryHotkey()
            }
            .help("Re-creates the event tap. Needed after granting Input Monitoring.")

            Button("Open Dictionary File") {
                NSWorkspace.shared.activateFileViewerSelecting([model.dictionary.fileURL])
            }
        }

        CommandGroup(after: .windowList) {
            Divider()
            Button("Edict Window") {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
            .keyboardShortcut("0", modifiers: .command)
        }

        CommandGroup(replacing: .help) {
            Button("Edict Help") {
                // No hosted docs yet; the dictionary file is the one thing a user is told to edit
                // by hand, so point at it rather than at a dead URL.
                NSWorkspace.shared.activateFileViewerSelecting([model.dictionary.fileURL])
            }
        }
    }
}
