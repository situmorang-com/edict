import SwiftUI

// MARK: - PermissionsPane

/// One row per `PermissionKind`: what it is, what the user gets for granting it, where it stands,
/// and a key that opens the exact System Settings pane.
///
/// It polls while it is on screen (`Permissions.beginPolling()`), because the user grants these in
/// *another app* — a pane that still says "Not granted" after the switch has been flipped is the
/// single most confusing thing a permissions screen can do. `endPolling()` on disappear, so an idle
/// window is not waking up to call TCC.
struct PermissionsPane: View {

    let model: AppModel

    /// Embedded in the Settings window as well as the main window. In Settings the pane is one panel
    /// among several, so it drops its own heading.
    var showsHeading: Bool = true

    /// Render-harness escape hatch, exactly as `SettingsWindow.unbounded` is: `ImageRenderer` does
    /// not rasterise a `ScrollView`'s contents (measured — `HistoryPane`'s log tray comes out empty
    /// on the same sheet), so the offline proof sheet asks for the column unwrapped. Never true in
    /// the app.
    var unbounded: Bool = false

    var body: some View {
        Group {
            if showsHeading && !unbounded {
                // Standing on its own in the main window, the pane owns the whole height it is
                // given, so it scrolls. This is not cosmetic: the window's minimum *is* the
                // content's minimum (`.windowResizability(.contentMinSize)`), and every row here
                // is prose under `.fixedSize(horizontal: false, vertical: true)`, so without a
                // scroll container the pane's minimum height grows without bound as it narrows —
                // measured 7614pt at 366pt wide, against 405pt at 900pt wide. A pane that cannot
                // compress is a window that cannot be made small.
                ScrollView { column }
                    // Definite, not ideal: given an ideal proposal a `ScrollView` measures as zero
                    // and the pane disappears (the same trap `TranscriptDetail` documents).
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Embedded in Settings, which already scrolls its whole column. A second scroll
                // view inside the first would collapse to zero height.
                column
            }
        }
        .onAppear { model.permissions.beginPolling() }
        .onDisappear { model.permissions.endPolling() }
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: D.space.md) {
            if showsHeading { intro }

            PanelSurface(showsHeading ? "Permissions" : nil) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(PermissionKind.allCases.enumerated()), id: \.element.id) { index, kind in
                        if index > 0 { SeamDivider(.horizontal) }
                        PermissionRow(permissions: model.permissions, kind: kind)
                            .padding(.vertical, D.space.sm)
                    }
                }
            }

            if showsHeading { hotkeyDiagnostic }
        }
        .padding(showsHeading ? D.space.md : 0)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: D.space.xs) {
            SilkscreenLabel("Setup", weight: .heading, ruled: true)
                .silkscreenDecorative()
            Text("macOS grants these one at a time, in System Settings. This list updates itself while "
                 + "you are over there, so you can leave it open.")
                .typeStyle(D.type.explain)
                .foregroundStyle(D.color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// A granted permission is not the same as a working hotkey: RECON §11 measured a `tapCreate`
    /// that returns a non-nil, permanently dead port, and a window server that silently strips keys
    /// from the mask. After a grant the tap must be destroyed and re-created, so the pane offers that
    /// rather than leaving the user to relaunch the app.
    @ViewBuilder
    private var hotkeyDiagnostic: some View {
        PanelSurface("Dictation key") {
            HStack(spacing: D.space.md) {
                StateWindow(text: model.hotkeyLive ? "Live" : "Inactive",
                            isFault: !model.hotkeyLive)
                VStack(alignment: .leading, spacing: D.space.xxs) {
                    Text("Watching \(model.settings.hotkey.displayName)")
                        .typeStyle(D.type.caption)
                        .foregroundStyle(D.color.textPrimary)
                    Text(model.hotkeyLive
                         ? "Hold the key in any app to dictate."
                         : "Input Monitoring has to be granted and the watcher restarted afterwards.")
                        .typeStyle(D.type.explain)
                        .foregroundStyle(D.color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: D.space.sm)
                // This key is the reason the whole confirmation pass exists. It worked, it said
                // nothing, and an hour went into debugging a watcher that was already live. It now
                // waits for `hotkeyLive` to settle and prints the answer on its own cap.
                ReportingButton("Restart", template: "Still dead") {
                    let live = await model.restartHotkey()
                    return live ? .done("Live") : .failed("Still dead")
                }
                .accessibilityLabel("Restart the dictation key watcher")
                .help("Destroys and re-creates the key watcher. RECON §11: a tap created while Input "
                      + "Monitoring was denied is permanently dead and cannot be re-enabled.")
            }
        }
    }
}

// MARK: - PermissionRow

private struct PermissionRow: View {

    let permissions: Permissions
    let kind: PermissionKind

    /// Set while `request(_:)` is in flight so the key cannot be pressed twice into the same prompt.
    @State private var isRequesting = false

    var body: some View {
        HStack(alignment: .center, spacing: D.space.md) {
            StateWindow(text: stateText, isFault: isFault)

            VStack(alignment: .leading, spacing: D.space.xxs) {
                HStack(spacing: D.space.xs) {
                    SilkscreenLabel(kind.title)
                        .silkscreenDecorative()
                    if !kind.isCritical {
                        Text("optional")
                            .typeStyle(D.type.silkscreenTiny)
                            .foregroundStyle(D.color.textSecondary)
                    }
                }
                Text(kind.why)
                    .typeStyle(D.type.explain)
                    .foregroundStyle(D.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: D.space.sm)

            action
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(kind.title)
        .accessibilityValue(stateText)
    }

    @ViewBuilder
    private var action: some View {
        switch state {
        case .granted:
            // No key at all. A "Revoke" button would be a lie — only System Settings can take a
            // grant back — and a disabled key beside a granted row is just noise.
            EmptyView()
        case .notDetermined:
            // Only `notDetermined` can produce a prompt. Once TCC has recorded a deny, requesting
            // again is a silent no-op, which is why the other cases go straight to Settings.
            // The prompt is macOS's, so the outcome is only knowable afterwards — and "Denied" is
            // exactly the outcome a user needs told, since TCC will never prompt for this again.
            ReportingButton("Allow", template: "Denied") {
                isRequesting = true
                await permissions.request(kind)
                isRequesting = false
                switch permissions.state(of: kind) {
                case .granted: return .done("Granted")
                case .denied: return .failed("Denied")
                case .notDetermined, .unknown: return .failed("No answer")
                }
            }
            .disabled(isRequesting)
        case .denied, .unknown:
            // Nothing to report: the outcome of this key is System Settings appearing in front of the
            // user, which is its own confirmation. A "Opened" badge on a key whose whole effect is a
            // window arriving would be noise, and the row's own state readout is already polling.
            TapeButton("Open") { permissions.openSettings(for: kind) }
                .accessibilityLabel("Open System Settings for \(kind.title)")
        }
    }

    private var state: PermissionState { permissions.state(of: kind) }

    private var stateText: String {
        switch state {
        case .granted: "Granted"
        case .denied: "Denied"
        case .notDetermined: "Not asked"
        case .unknown: "Unknown"
        }
    }

    /// A fault only when the grant actually matters: a denied `postEvent` still leaves the AX insert
    /// path and the "left on your clipboard" fallback working.
    private var isFault: Bool {
        switch state {
        case .granted, .notDetermined: false
        case .denied, .unknown: kind.isCritical
        }
    }
}

// MARK: - StateWindow

/// A word the machine is displaying, so it goes in a lit display well — composition invariant 2.
/// Fixed width, so the column does not twitch as a state changes under polling.
///
/// The text is **always** `D.color.displayInk`. `D.color.alert` is a dark brown in the light
/// appearance and `D.surface.wellFill` is near-black in *both*, so an alert-coloured word inside the
/// window is unreadable — measured on the rendered sheet. The fault signal is therefore a tell-tale
/// on the chassis beside the window, where alert ink is the one colour that belongs.
private struct StateWindow: View {

    let text: String
    /// True when this state is a fault the user has to act on.
    let isFault: Bool

    var body: some View {
        HStack(spacing: D.space.xs) {
            Rectangle()
                .strokeBorder(D.color.alert, lineWidth: D.border.thin)
                .frame(width: D.size.troughHeight, height: D.size.troughHeight)
                .opacity(isFault ? 1 : 0)
            RecessedWell(fill: .display, radius: D.radius.tight, inset: D.space.xs) {
                Text(text)
                    .typeStyle(D.type.silkscreen)
                    .foregroundStyle(D.color.displayInk)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Sized off the longest state string ("Not asked") rather than measured, so every row's
            // window is the same window.
            .frame(width: D.size.railWidth * 0.5)
        }
        .accessibilityHidden(true)
    }
}

// Gated with the fixture enums these previews use. `PreviewFixtures` is `#if DEBUG` because it is
// `public` for an out-of-tree render harness and therefore cannot be dead-stripped; a `#Preview` that
// references it has to be gated too, or the file stops compiling in release. This file was one of the
// two the audit's list of affected files missed — the release build found them, which is why the
// release build is now part of finishing this change.
#if DEBUG
// MARK: - Previews

#Preview("Permissions — light") {
    PermissionsPane(model: PreviewFixtures.model())
        .frame(width: 720, height: 480)
        .background(D.surface.deckPaint)
}

#Preview("Permissions — dark") {
    PermissionsPane(model: PreviewFixtures.model())
        .frame(width: 720, height: 480)
        .background(D.surface.deckPaint)
        .preferredColorScheme(.dark)
}
#endif
