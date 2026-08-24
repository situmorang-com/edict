import AppKit
import SwiftUI

// MARK: - Pane

/// What the left rail is pointing at.
///
/// `permissions` is a third rail stop rather than a Settings-only pane on purpose: the contracts
/// require the main window to surface a banner "linking to the permissions pane", and a link that
/// opens a *different window* is exactly the indirection a user in trouble cannot follow. The pane
/// is the same view the Settings window embeds.
enum Pane: String, CaseIterable, Identifiable, Hashable {
    case history, dictionary, permissions

    var id: String { rawValue }

    /// Natural case; the cap's type style uppercases it (spec §0.2).
    var legend: String {
        switch self {
        case .history: "History"
        case .dictionary: "Dictionary"
        case .permissions: "Permissions"
        }
    }
}

// MARK: - MainWindow

/// The main window: a transport deck across the top, a labelled equipment rail down the left, and
/// the selected pane filling the rest.
///
/// Assembled entirely from `Design/Components.swift` and `D.*`. The three structural joints are
/// `SeamDivider(depth: .channel)` — deck-to-body and rail-to-pane — because those are joints
/// between *blocks of material*, not between rows of content.
public struct MainWindow: View {

    private let model: AppModel

    /// Defaulted so `EdictApp`'s scene body can spell this `MainWindow()`, which is what the
    /// shell's views seam comment says it will do.
    public init(model: AppModel = .shared) {
        self.model = model
        self._pane = State(initialValue: .history)
        self.forcesBanner = false
        self.unbounded = false
    }

    /// Used only by `PreviewFixtures` to render a specific pane, and to force the attention banner
    /// on a machine where the permissions happen to be granted.
    init(model: AppModel, pane: Pane, forcesBanner: Bool = false, unbounded: Bool = false) {
        self.model = model
        self._pane = State(initialValue: pane)
        self.forcesBanner = forcesBanner
        self.unbounded = unbounded
    }

    private let forcesBanner: Bool

    /// Render-harness escape hatch, passed straight through to `PermissionsPane.unbounded`.
    private let unbounded: Bool

    @State private var pane: Pane

    public var body: some View {
        VStack(spacing: 0) {
            TransportDeck(model: model)

            // Deck to body: a machined channel, stopped short of the window's rounded corners the
            // way a real panel joint is.
            SeamDivider(.horizontal, depth: .channel, inset: D.radius.chassis)

            if showsBanner {
                AttentionBanner(model: model) { pane = .permissions }
                SeamDivider(.horizontal, depth: .channel, inset: D.radius.chassis)
            }

            HStack(spacing: 0) {
                EquipmentRail(model: model, selection: $pane)
                    .frame(width: D.size.railWidth)

                SeamDivider(.vertical, depth: .channel)

                body(for: pane)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: D.size.windowMin.width, minHeight: D.size.windowMin.height)
        .background(D.surface.deckPaint)
        // The whole window animates pane changes, so the rail's latch and the content move together.
        .animation(D.motion.pane, value: pane)
        .animation(D.motion.panel, value: showsBanner)
    }

    @ViewBuilder
    private func body(for pane: Pane) -> some View {
        switch pane {
        case .history: HistoryPane(model: model)
        case .dictionary: DictionaryPane(model: model)
        case .permissions: PermissionsPane(model: model, unbounded: unbounded)
        }
    }

    /// Non-nagging: the banner exists only while something is actually broken, it never appears on
    /// the pane that fixes it, and it has no dismiss control because a dismissed warning about a
    /// dead hotkey is worse than no warning at all.
    private var showsBanner: Bool {
        pane != .permissions
            && (forcesBanner || !model.permissions.allCriticalGranted || !model.hotkeyLive)
    }
}

// MARK: - Transport deck

/// One piece of milled aluminium across the top of the window, carrying the three blocks the
/// composition rules fix: the movement, the counters, the transport.
///
/// Height: `minHeight: D.size.deckHeight`, not a hard frame. The spec's 104 predates the
/// components, and `VUMeter` alone is 84 tall inside a panel whose inset is 12 a side — 108 is the
/// smallest honest height. A hard 104 clips the meter's bezel, so the deck grows the 4pt instead.
private struct TransportDeck: View {

    let model: AppModel

    var body: some View {
        PanelSurface(material: .brushed, radius: D.radius.square, inset: D.space.md) {
            HStack(alignment: .center, spacing: D.space.xl) {
                movement
                counters
                transport
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: D.size.deckHeight)
    }

    // MARK: Block 1 — the movement

    /// The 60 Hz path. Driven from a render timeline rather than from `@Observable`: `AppModel`
    /// deliberately keeps the needle out of the observation graph, so the meter must pull.
    private var movement: some View {
        TimelineView(
            .animation(minimumInterval: D.motion.needleTickInterval, paused: !model.isRecording)
        ) { context in
            let frame = model.isRecording
                ? model.levelMeter.advance(to: context.date)
                : model.levelMeter.frame
            VUMeter(level: frame, isLive: model.isRecording, showsNumericReadout: true)
        }
        .frame(width: D.size.meterSize.width, height: D.size.meterSize.height)
    }

    // MARK: Block 2 — the counters

    private var counters: some View {
        VStack(alignment: .leading, spacing: D.space.labelGap) {
            SegmentCounter(.elapsed(model.elapsed), scale: .large)
            SilkscreenLabel("Elapsed")
                .silkscreenDecorative()
            HStack(spacing: D.space.labelGap) {
                SegmentCounter(.count(wordCount, unit: "w"), scale: .small)
                SilkscreenLabel("Words", weight: .tiny)
                    .silkscreenDecorative()
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Elapsed")
    }

    /// Live while an utterance is in flight, otherwise the last one — so the counter is never a
    /// stale number with no explanation, and never zero after a successful dictation.
    private var wordCount: Int {
        if model.phase.isActive {
            return model.committedText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        }
        return model.lastTranscript?.wordCount ?? 0
    }

    // MARK: Block 3 — the transport

    private var transport: some View {
        PanelSurface(material: .plastic) {
            VStack(alignment: .leading, spacing: D.space.sm) {
                HStack(spacing: D.space.xxs) {
                    RecordLamp(model.lampMode)
                    StatusReadout(model.statusCondition)
                }
                HStack(spacing: D.space.md) {
                    Waveform(
                        level: model.level,
                        isLive: model.isRecording,
                        isTranscribing: model.phase == .transcribing
                    )
                    // Framed to the key height beside it rather than to
                    // `D.size.waveformHeight`: the strip and the transport keys are one line of
                    // hardware, and 44 pushes the deck to 118 for no gain in a relative,
                    // unlabelled trace.
                    .frame(minWidth: D.size.meterSize.width / 2)
                    .frame(height: D.size.buttonHeight)

                    TapeButton(
                        "Record",
                        role: .record,
                        isLatched: model.isRecording,
                        action: model.startRecording
                    )
                    .disabled(!model.canStartRecording)

                    TapeButton("Stop", role: .stop, action: model.stopRecording)
                        .disabled(!model.phase.isActive)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Equipment rail

/// The left rail. One painted panel, a latching selector at the top, and the log's totals printed
/// at the bottom — a labelled equipment panel, not a system sidebar: no disclosure triangles, no
/// hover highlights on text, no `List`.
private struct EquipmentRail: View {

    let model: AppModel
    @Binding var selection: Pane

    /// The rail is narrower than `PanelSurface`'s own label threshold (it drops a label below 240pt
    /// rather than give up its inset), so the rail prints its two headings itself.
    private static let keyWidth = D.size.railWidth - D.space.panelInset * 2

    var body: some View {
        PanelSurface(radius: D.radius.square) {
            VStack(alignment: .leading, spacing: D.space.md) {
                VStack(alignment: .leading, spacing: D.space.sm) {
                    SilkscreenLabel("View", weight: .heading, ruled: true)
                        .silkscreenDecorative()
                    ForEach(Pane.allCases) { pane in
                        RailKey(
                            pane: pane,
                            width: Self.keyWidth,
                            isSelected: selection == pane,
                            needsAttention: pane == .permissions && !model.permissions.allCriticalGranted
                        ) {
                            selection = pane
                        }
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("View")

                Spacer(minLength: D.space.sm)

                SeamDivider(.horizontal)

                totals
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// The rail's second job: a printed count of what is in the log, so the window always says how
    /// much of the user's speech it is holding.
    private var totals: some View {
        VStack(alignment: .leading, spacing: D.space.labelGap) {
            SilkscreenLabel("Log", weight: .heading, ruled: true)
                .silkscreenDecorative()
            totalRow("Entries", .count(model.history.transcripts.count, unit: "rec"))
            totalRow("Words", .count(model.history.totalWords, unit: "w"))
            totalRow("Audio", .duration(model.history.totalAudioDuration))
            totalRow("Terms", .count(model.dictionary.entries.count, unit: "trm"))
        }
    }

    private func totalRow(_ label: String, _ format: SegmentCounter.Format) -> some View {
        HStack(spacing: D.space.xs) {
            SilkscreenLabel(label, weight: .tiny)
                .silkscreenDecorative()
            Spacer(minLength: D.space.xxs)
            SegmentCounter(format, scale: .tiny)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

/// One stop on the rail. A latching `TapeButton`, not a `Picker` and not a `List` row.
///
/// `minWidth` rather than `.frame(maxWidth: .infinity)`: the cap's legend is `fixedSize`d, so an
/// infinite proposal does not widen it — the seat sizes off `minWidth`, which is the parameter that
/// exists for exactly this.
private struct RailKey: View {

    let pane: Pane
    let width: CGFloat
    let isSelected: Bool
    let needsAttention: Bool
    let action: () -> Void

    var body: some View {
        TapeButton(role: .neutral, isLatched: isSelected, minWidth: width, action: action) {
            HStack(spacing: D.space.xs) {
                Text(pane.legend)
                // Shape *and* colour: a hollow square in the alert ink, matching the flag column's
                // vocabulary in `TranscriptRow` rather than inventing a badge.
                if needsAttention {
                    Rectangle()
                        .strokeBorder(D.color.alert, lineWidth: D.border.thin)
                        .frame(width: D.space.sm, height: D.space.sm)
                }
            }
        }
        .accessibilityLabel(pane.legend)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(needsAttention ? "A required permission is missing." : "")
    }
}

// MARK: - Attention banner

/// The one thing the window shouts about: a missing critical permission, or a hotkey that is not
/// actually live. Prominent because the app looks completely broken without them; non-nagging
/// because it is one line on the chassis, it names the fix, and it vanishes by itself.
private struct AttentionBanner: View {

    let model: AppModel
    let openPermissions: () -> Void

    var body: some View {
        HStack(spacing: D.space.md) {
            // Alert ink is the only colour permitted on the chassis, and only for a fault
            // (composition invariant 3). Shape carries it too: a hollow square, same vocabulary
            // as the "may be incomplete" flag.
            Rectangle()
                .strokeBorder(D.color.alert, lineWidth: D.border.medium)
                .frame(width: D.size.troughHeight * 2, height: D.size.troughHeight * 2)

            VStack(alignment: .leading, spacing: D.space.xxs) {
                Text(headline)
                    .typeStyle(D.type.bodyEmphasis)
                    .foregroundStyle(D.color.alert)
                Text(detail)
                    .typeStyle(D.type.explain)
                    .foregroundStyle(D.color.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: D.space.sm)

            if !model.hotkeyLive && model.permissions.state(of: .inputMonitoring) == .granted {
                // Input Monitoring is granted but the tap is dead — RECON §11: after a grant the
                // tap must be destroyed and re-created, so the fix is a restart, not a trip to
                // System Settings.
                TapeButton("Retry", action: model.retryHotkey)
            }
            TapeButton("Permissions", action: openPermissions)
        }
        .padding(.horizontal, D.space.md)
        .padding(.vertical, D.space.sm)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headline)
    }

    private var headline: String {
        if let missing = model.permissions.missingCritical.first {
            return "\(missing.title) is not granted"
        }
        return "The dictation key is not being watched"
    }

    private var detail: String {
        if let missing = model.permissions.missingCritical.first {
            return missing.why
        }
        return "Edict cannot see \(model.settings.hotkey.displayName) being held. "
            + "Recording from this window still works."
    }
}

// MARK: - Preview and render fixtures

/// Sample state for `#Preview` blocks and for the offline `ImageRenderer` harness that renders the
/// window to PNGs in both appearances.
///
/// `public` because the render harness is a separate package that links `EdictKit`; there is no
/// other way to hand it a populated `AppModel` without the views growing a second, fake data path.
/// Nothing in the shipping app calls this — `AppModel.shared` is what `EdictApp` uses.
@MainActor
public enum PreviewFixtures {

    /// An `AppModel` on throwaway stores, so a preview or a render never touches
    /// `~/Library/Application Support/Edict`.
    public static func model(populated: Bool = true) -> AppModel {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-preview-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // `EphemeralDefaults`, not `UserDefaults(suiteName:)`: a suite domain would leave a
        // `~/Library/Preferences/edict.preview.<UUID>.plist` behind the first time a preview wrote
        // a setting, and cfprefsd re-persists such a file even after `removePersistentDomain`.
        // See `EphemeralDefaults` for the measurements.
        let model = AppModel(
            settings: Settings(defaults: EphemeralDefaults()),
            dictionary: DictionaryStore(fileURL: root.appendingPathComponent("dictionary.json")),
            history: HistoryStore(fileURL: root.appendingPathComponent("history.json"))
        )
        guard populated else { return model }

        for entry in sampleDictionary { model.dictionary.add(entry) }
        // Oldest first: `append` inserts at index 0, exactly as real dictations arrive, so feeding
        // the list in reverse is what leaves the store newest-first.
        for transcript in sampleTranscripts.reversed() { model.history.append(transcript) }
        return model
    }

    /// Stored, not computed: `sampleTranscripts` references these ids, so a fresh `UUID()` per
    /// access would break the link between a `CorrectionHit` and the entry it came from.
    static let sampleDictionary: [DictionaryEntry] = {
        [
            DictionaryEntry(kind: .correction(heard: "cloud code", write: "Claude Code"),
                            note: "The canonical one.", hitCount: 14, lastHitAt: Date()),
            DictionaryEntry(kind: .term("Anthropic"), hitCount: 3, lastHitAt: Date()),
            DictionaryEntry(kind: .term("Supabase"), note: "Heard as \"soup base\".", hitCount: 0),
            DictionaryEntry(kind: .correction(heard: "visa", write: "Vercel"), hitCount: 2),
            DictionaryEntry(kind: .term("SwiftUI"), hitCount: 7),
            DictionaryEntry(kind: .term("Wispr Flow"), enabled: false, hitCount: 0),
        ]
    }()

    static let sampleTranscripts: [Transcript] = {
        let corrected = Transcript(
            createdAt: Date(timeIntervalSinceNow: -120),
            rawText: "Let's ship the cloud code integration before Friday and tell anthropic.",
            text: "Let's ship the Claude Code integration before Friday and tell Anthropic.",
            corrections: [
                CorrectionHit(entryID: sampleDictionary[0].id, from: "cloud code", to: "Claude Code", offset: 18),
                CorrectionHit(entryID: sampleDictionary[1].id, from: "anthropic", to: "Anthropic", offset: 61),
            ],
            audioDuration: 6.4,
            transcribeDuration: 0.31,
            targetBundleID: "com.apple.dt.Xcode",
            targetAppName: "Xcode",
            injection: .accessibility,
            lowConfidenceWords: ["soup", "base"]
        )
        return [
            corrected,
            Transcript(
                createdAt: Date(timeIntervalSinceNow: -600),
                rawText: "Add a rocker switch for the pre warm microphone setting.",
                text: "Add a rocker switch for the pre warm microphone setting.",
                audioDuration: 4.1,
                transcribeDuration: 0.22,
                targetAppName: "Notes",
                injection: .paste
            ),
            Transcript(
                createdAt: Date(timeIntervalSinceNow: -1_800),
                rawText: "in the deck so the needle",
                text: "in the deck so the needle",
                audioDuration: 12.8,
                transcribeDuration: 0.53,
                targetAppName: "Safari",
                injection: .clipboardOnly,
                droppedBuffers: 9,
                lowConfidenceWords: ["needle"]
            ),
            Transcript(
                createdAt: Date(timeIntervalSinceNow: -7_200),
                rawText: "The quick brown fox jumped over the lazy dog and kept going for quite a while longer than anyone expected.",
                text: "The quick brown fox jumped over the lazy dog and kept going for quite a while longer than anyone expected.",
                audioDuration: 9.2,
                transcribeDuration: 0.27,
                targetAppName: "Mail",
                injection: .keystrokes
            ),
        ]
    }()

    // MARK: Render sheets

    /// One page of the layout proof sheet.
    /// Not `Sendable`: `AnyView` is not, and this never leaves the main actor.
    public struct RenderSheet: Identifiable {
        public let id: String
        public let size: CGSize
        /// Erased because the harness renders a heterogeneous list; nothing in the app calls this.
        public let view: AnyView
    }

    /// Every pane at a size worth checking, for the offline `ImageRenderer` harness. The panes
    /// themselves are `internal`, so this is the only way an out-of-module tool can rasterise them —
    /// which is the point: the views' visibility does not have to widen for the layout to be proved.
    /// - Parameter locales: the transcriber's supported locales, which the harness has to `await`
    ///   before rendering — an offscreen rasteriser cannot wait on a view's own `.task`.
    public static func renderSheets(locales: [Locale] = []) -> [RenderSheet] {
        let window = D.size.windowMin
        let paneSize = CGSize(width: window.width - D.size.railWidth, height: window.height)

        func sheet(_ id: String, _ size: CGSize, _ view: some View) -> RenderSheet {
            RenderSheet(
                id: id,
                size: size,
                view: AnyView(
                    view
                        .frame(width: size.width, height: size.height)
                        .background(D.surface.deckPaint)
                )
            )
        }

        let main = model()
        let selectedHistory = model()
        let selectedDictionary = model()
        let wide = model()

        return [
            sheet("main-history", window, MainWindow(model: main, pane: .history)),
            sheet("main-history-banner", window,
                  MainWindow(model: model(), pane: .history, forcesBanner: true)),
            sheet("main-dictionary", window, MainWindow(model: model(), pane: .dictionary)),
            sheet("main-permissions", window,
                  MainWindow(model: model(), pane: .permissions, unbounded: true)),
            sheet("main-wide", CGSize(width: 1_280, height: 800),
                  MainWindow(model: wide, pane: .dictionary)),
            sheet("pane-history", paneSize,
                  HistoryPane(model: selectedHistory,
                              initialSelection: selectedHistory.history.transcripts.first?.id)),
            sheet("pane-history-incomplete", paneSize,
                  HistoryPane(model: model(),
                              initialSelection: sampleTranscripts[2].id)),
            sheet("pane-dictionary", paneSize,
                  DictionaryPane(model: selectedDictionary,
                                 initialSelection: selectedDictionary.dictionary.entries.first?.id)),
            sheet("pane-permissions", paneSize, PermissionsPane(model: model(), unbounded: true)),
            sheet("sheet-add-term", CGSize(width: window.width / 2, height: 460),
                  DictionaryEntrySheet(store: model().dictionary,
                                       draft: EntryDraft(isCorrection: false, term: "Supabase")) {}),
            sheet("sheet-add-correction", CGSize(width: window.width / 2, height: 520),
                  DictionaryEntrySheet(store: model().dictionary,
                                       draft: EntryDraft(isCorrection: true,
                                                         heard: "cloud",
                                                         write: "Claude")) {}),
            sheet("window-settings", CGSize(width: D.size.windowMin.width * 0.62, height: 660),
                  SettingsWindow(model: model(), unbounded: false, locales: locales)),
            sheet("window-settings-full", CGSize(width: D.size.windowMin.width * 0.62, height: 2_400),
                  SettingsWindow(model: model(), unbounded: true, locales: locales)),
        ]
    }
}

// MARK: - Previews

#Preview("Main window — light") {
    MainWindow(model: PreviewFixtures.model())
        .frame(width: D.size.windowMin.width, height: D.size.windowMin.height)
}

#Preview("Main window — dark") {
    MainWindow(model: PreviewFixtures.model())
        .frame(width: D.size.windowMin.width, height: D.size.windowMin.height)
        .preferredColorScheme(.dark)
}
