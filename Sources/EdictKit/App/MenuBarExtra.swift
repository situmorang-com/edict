import AppKit
import SwiftUI

// MARK: - Menu-bar extra
//
// This is deliberately the *secondary* interface. Edict is a real windowed app with a Dock icon
// and a full app menu (RECON §25 confirmed a Dock icon, app menu, main window and status item all
// coexist, and `LSUIElement` is left out entirely). The status item exists for the case the main
// window cannot serve: the user is in another app, has just dictated, and wants to know whether the
// hotkey is live and what came out — without leaving that app.
//
// The types are named `EdictMenuBar*` rather than `MenuBarExtra*` because SwiftUI already owns
// `MenuBarExtra`, and shadowing a scene type inside the module that declares the scene graph is a
// trap for whoever reads it next.

/// The status-item glyph.
///
/// Template-rendered so macOS tints it for the menu bar's appearance and for the highlighted state;
/// hardcoding a colour here would produce a status item that is invisible against a light wallpaper.
struct EdictMenuBarLabel: View {

    let model: AppModel

    var body: some View {
        Image(systemName: symbolName)
            .symbolRenderingMode(.monochrome)
            .accessibilityLabel(model.statusLine)
    }

    private var symbolName: String {
        switch model.phase {
        case .listening, .arming: return "waveform.circle.fill"
        case .transcribing, .refining, .injecting: return "waveform.circle"
        case .error: return "exclamationmark.triangle"
        case .idle: return model.hotkeyLive ? "waveform" : "waveform.badge.exclamationmark"
        }
    }
}

/// The status item's panel: condition, hotkey, transport, and the last few transcripts.
struct EdictMenuBarContent: View {

    let model: AppModel

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    /// Three is enough to answer "did that last one work?" without turning the popover into a
    /// second history browser — that is what the main window is for.
    private static let recentCount = 3

    var body: some View {
        // Bound once. `lastNotice` scans history for the one outcome whose sentence names it, and a
        // property read twice in a view body is a scan run twice.
        let notice = model.lastNotice
        return VStack(alignment: .leading, spacing: D.space.sm) {
            header
            SeamDivider()
            transport
            if let notice {
                SeamDivider()
                noticeBlock(notice)
            }
            if !recent.isEmpty {
                SeamDivider()
                recentList
            }
            SeamDivider()
            footer
        }
        .padding(D.space.md)
        .frame(width: D.size.hudSize.width)
    }

    // MARK: sections

    private var header: some View {
        HStack(spacing: D.space.sm) {
            RecordLamp(model.lampMode, fitting: .compact)
            StatusReadout(model.statusCondition, compact: true)
            Spacer(minLength: D.space.xs)
            SegmentCounter(.elapsed(model.elapsed), scale: .tiny, seated: false)
        }
    }

    private var transport: some View {
        VStack(alignment: .leading, spacing: D.space.xs) {
            HStack(spacing: D.space.sm) {
                TapeButton(model.isRecording ? "STOP" : "RECORD", role: model.isRecording ? .stop : .record, isLatched: model.isRecording) {
                    model.toggleRecording()
                }
                .disabled(!model.isRecording && !model.canStartRecording)

                if model.phase.errorMessage != nil {
                    TapeButton("CLEAR") { model.clearError() }
                }
            }
            SilkscreenLabel("Hold \(model.settings.hotkey.glyph) \(model.settings.hotkey.displayName)")
            // Text, not a button. Clicking anything in here activates Edict, and the refine gesture
            // exists precisely because activating Edict loses the selection it is about to replace —
            // so the only honest thing the menu bar can do for this feature is name the chord.
            if let chord = model.settings.effectiveRefineChord {
                SilkscreenLabel("\(chord.glyph(dictationKey: model.settings.hotkey)) refines a selection")
            }
        }
    }

    /// What became of the last dictation, when it did not end up at the cursor.
    ///
    /// Fed by `AppModel.lastNotice` and not `AppModel.notice`: the HUD's copy of this removes itself
    /// after `RefinePopupTimeouts.failureDwell`, and by the time a user has noticed nothing appeared
    /// in their document and reached the menu bar, it is gone. This one stays until the next
    /// dictation reports an outcome of its own, which makes the status item the surface that still
    /// answers "what happened?" — including for a user who has switched the HUD off entirely.
    ///
    /// Text, not keys. The recovery controls — insert again, teach Edict to paste only in this app —
    /// need the app the text was meant for to still be in front, and clicking anything in this
    /// popover activates Edict. They live on the transcript's own row in the history pane, and
    /// WINDOW below is what opens the window that holds it.
    private func noticeBlock(_ notice: DictationNotice) -> some View {
        VStack(alignment: .leading, spacing: D.space.xxs) {
            SilkscreenLabel(notice.label, weight: .tiny)
                .silkscreenDecorative()
            Text(notice.sentence)
                .typeStyle(D.type.explain)
                .foregroundStyle(D.color.alert)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(notice.sentence)
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: D.space.xxs) {
            SilkscreenLabel("Recent")
            ForEach(recent) { transcript in
                Button {
                    copy(transcript)
                } label: {
                    HStack(spacing: D.space.sm) {
                        Text(transcript.text)
                            .typeStyle(D.type.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: D.space.xs)
                        SegmentCounter(.count(transcript.wordCount, unit: "W"), scale: .tiny, seated: false)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Copy this transcript")
            }
        }
    }

    private var footer: some View {
        HStack(spacing: D.space.sm) {
            TapeButton("WINDOW") {
                openMainWindow()
            }
            SettingsLink {
                Text("SETTINGS")
            }
            .buttonStyle(TapeButtonStyle())
            Spacer(minLength: D.space.xs)
            TapeButton("QUIT") {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: actions

    private var recent: [Transcript] {
        Array(model.history.transcripts.prefix(Self.recentCount))
    }

    private func copy(_ transcript: Transcript) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(transcript.text, forType: .string)
    }

    /// Opening the main window is the one place the status item *should* activate Edict — the user
    /// asked to come to the app. Everything else in this popover leaves focus where it was.
    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: EdictApp.mainWindowID)
        dismiss()
    }
}
