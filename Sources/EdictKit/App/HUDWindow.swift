import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - HUDPanel

/// The floating recording panel's window.
///
/// `canBecomeKey` and `canBecomeMain` are hard `false`, and that is the single most important line
/// in this file. The whole point of Edict is to put text into the app the user is *already* typing
/// in; a HUD that takes key focus moves the focused AX element to itself, and the injection ladder
/// then inserts the transcript into a panel that has no text field. Every other property here —
/// `.nonactivatingPanel`, `isFloatingPanel`, `ignoresMouseEvents` — is defence in depth around the
/// same requirement.
final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - HUDWindowController

/// Shows and hides the recording HUD in step with `AppModel.phase`, honouring `Settings.showHUD`.
@MainActor
public final class HUDWindowController {

    /// Width from the token; height is the token height plus one waveform strip, because the HUD
    /// carries a live-text line that `D.size.hudSize` does not account for. Composed from tokens
    /// rather than measured by eye.
    private static var panelSize: CGSize {
        CGSize(width: D.size.hudSize.width,
               height: D.size.hudSize.height + D.size.waveformHeight)
    }

    /// Distance from the bottom of the screen's visible frame. `xxl` puts it clear of the Dock in
    /// its default position without floating in the middle of the user's work.
    private static var bottomInset: CGFloat { D.space.xxl }

    private let model: AppModel
    private var panel: HUDPanel?
    private var isObserving = false

    public init(model: AppModel) {
        self.model = model
    }

    // MARK: Lifecycle

    /// Begin tracking `phase` and `showHUD`. Called once from the app delegate.
    public func start() {
        guard !isObserving else { return }
        isObserving = true
        observe()
        synchronise()
    }

    public func stop() {
        isObserving = false
        dismiss()
    }

    /// `withObservationTracking` is one-shot, so the handler re-arms itself. It fires synchronously
    /// inside the mutation, hence the hop.
    private func observe() {
        withObservationTracking {
            _ = model.phase
            _ = model.settings.showHUD
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isObserving else { return }
                self.synchronise()
                self.observe()
            }
        }
    }

    private func synchronise() {
        let wanted = model.settings.showHUD && Self.shouldShow(model.phase)
        if wanted {
            present()
        } else {
            dismiss()
        }
    }

    /// Visible for the whole utterance, including the finalize and inject tail — those are the
    /// seconds when the user most wants to know something is still happening.
    private static func shouldShow(_ phase: DictationPhase) -> Bool {
        switch phase {
        case .arming, .listening, .transcribing, .injecting: return true
        case .idle, .error: return false
        }
    }

    // MARK: Window

    private func present() {
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        // `orderFrontRegardless`, never `makeKeyAndOrderFront`: the latter would activate Edict and
        // pull focus away from the app the transcript is destined for.
        panel.orderFrontRegardless()
    }

    private func dismiss() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> HUDPanel {
        let panel = HUDPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false          // the shadow is drawn in SwiftUI from `D.shadow.hud`
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .utilityWindow
        // Follows the user across spaces and over full-screen apps, and stays out of Cmd-` cycling.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        // Nothing in the HUD is interactive. Passing clicks straight through means it can never
        // intercept a click meant for the editor underneath it.
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityLabel("Edict recording status")

        let host = NSHostingView(rootView: HUDContent(model: model, meter: model.levelMeter))
        host.frame = NSRect(origin: .zero, size: Self.panelSize)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// Bottom-centre of whichever screen holds the pointer — the screen the user is working on.
    /// `NSScreen.main` would be wrong: it follows the key window, and Edict deliberately has none.
    private func position(_ panel: HUDPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }

        let size = Self.panelSize
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + Self.bottomInset
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }
}

// MARK: - HUDContent

/// The HUD's contents: record lamp, status, elapsed counter, live level, and the live text with a
/// visually distinct volatile tail.
struct HUDContent: View {

    let model: AppModel
    /// Passed explicitly rather than read off `model`, so it is obvious that this 60 Hz path does
    /// not go through observation.
    let meter: LevelMeter

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PanelSurface(material: .plastic, radius: D.radius.bezel, inset: D.space.panelInset) {
            VStack(alignment: .leading, spacing: D.space.sm) {
                instrumentRow
                levelStrip
                liveTextWell
            }
        }
        .shadow(D.shadow.hud)
        .padding(D.space.xs)
        .transition(.opacity)
        .animation(D.motion.hud, value: model.phase)
    }

    // MARK: rows

    private var instrumentRow: some View {
        HStack(spacing: D.space.sm) {
            RecordLamp(model.lampMode, fitting: .compact)
            StatusReadout(model.statusCondition, compact: true)
            Spacer(minLength: D.space.xs)
            SegmentCounter(.elapsed(model.elapsed), scale: .tiny, seated: false)
        }
    }

    /// The level display.
    ///
    /// DESIGN-COMPONENTS §5 specifies a horizontal level *trough* here rather than the full
    /// `VUMeter` (which is 232×84 and would leave no room for the text). That component does not
    /// exist yet, so this uses `Waveform` — the other horizontal display-well level component —
    /// at the same height. Swap it for `LevelTrough` when it lands.
    private var levelStrip: some View {
        // The one place the 60 Hz path is driven: `advance(to:)` is main-actor, touches no SwiftUI
        // state, and returns the frame instead of publishing it, so not one view invalidation
        // happens per frame (DESIGN-COMPONENTS §2).
        TimelineView(
            .animation(minimumInterval: D.motion.needleTickInterval, paused: !isLive)
        ) { context in
            let frame = isLive ? meter.advance(to: context.date) : meter.frame
            Waveform(
                level: frame,
                isLive: isLive,
                isTranscribing: model.phase == .transcribing || model.phase == .injecting
            )
        }
        .frame(height: D.size.waveformHeight)
    }

    private var liveTextWell: some View {
        RecessedWell(fill: .display, radius: D.radius.tight, inset: D.space.xs) {
            Text(styledLiveText)
                .typeStyle(D.type.caption)
                .lineLimit(2)
                .truncationMode(.head)      // the tail is where the newest words are
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(reduceMotion ? nil : D.motion.readout, value: model.liveText)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: text

    private var isLive: Bool { model.phase.isCapturing }

    /// Committed text in display ink; the volatile tail dimmed and italic.
    ///
    /// Built as an `AttributedString` rather than two concatenated `Text`s so the run styling is
    /// data, not view modifiers — which is also what lets the whole thing animate as one string.
    /// RECON §4: the tail is frequently wrong mid-word and occasionally disagrees with the final,
    /// so it must never look like settled text.
    private var styledLiveText: AttributedString {
        var committed = AttributedString(model.committedText)
        committed.foregroundColor = D.color.displayInk

        var tail = AttributedString(model.volatileText)
        tail.foregroundColor = D.color.displayInk.opacity(D.opacity.ghost)
        tail.inlinePresentationIntent = .emphasized

        let combined = committed + tail
        if combined.characters.isEmpty {
            var placeholder = AttributedString(placeholderText)
            placeholder.foregroundColor = D.color.displayInk.opacity(D.opacity.ghost)
            return placeholder
        }
        return combined
    }

    private var placeholderText: String {
        switch model.phase {
        case .arming: return "Listening…"
        case .listening: return "Speak now"
        case .transcribing: return "Finishing…"
        case .injecting: return "Inserting…"
        case .idle, .error: return ""
        }
    }
}
