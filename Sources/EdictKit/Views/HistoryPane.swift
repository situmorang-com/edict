import AppKit
import CoreText
import ServiceManagement
import SwiftUI

// MARK: - Clipboard

/// The one place any view touches `NSPasteboard`. `TranscriptRow` deliberately does not (its
/// contract is "the row does not touch NSPasteboard"), so the callback has to land somewhere.
enum ViewClipboard {
    static func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - HistoryPane

/// The printed log. Searchable, newest first, one row per dictation, and — the part that matters —
/// a detail block that shows *what the dictionary did*.
///
/// The raw-vs-corrected comparison is not a nicety. Layer 1 (contextual-string biasing) is
/// invisible by construction and layer 2 (the correction pass) is silent, so without this block the
/// user has no evidence the dictionary exists at all. It is therefore given the same weight as the
/// table itself, not tucked into an inspector.
struct HistoryPane: View {

    let model: AppModel

    /// Render-harness escape hatch, exactly as `SettingsWindow.unbounded` and
    /// `PermissionsPane.unbounded` are: `ImageRenderer` does not rasterise a `ScrollView`'s contents,
    /// so the offline proof sheet comes out with an empty log tray and an empty transcript panel —
    /// measured, twice. When true the two scroll containers are dropped and the content lays out at its
    /// natural size. Never true in the app.
    var unbounded: Bool = false

    init(model: AppModel, initialSelection: UUID? = nil, unbounded: Bool = false) {
        self.model = model
        self.unbounded = unbounded
        self._selection = State(initialValue: initialSelection)
    }

    @State private var query = ""
    @State private var selection: UUID?
    @State private var armedClear = false
    @State private var draft: EntryDraft?
    /// The dictionary's size when the add sheet was opened, so its dismissal can be reported as
    /// "added" or "nothing added". The sheet itself hands back no result and is another agent's file.
    @State private var entryCountAtOpen = 0
    /// Which word's TEACH key is waiting for the sheet, and what the sheet turned out to have done.
    /// Carried as a pair so the report lands on the key that was pressed and not on all three.
    @State private var teachingWord: String?
    @State private var teachOutcome: TeachOutcome?

    struct TeachOutcome: Equatable {
        var word: String
        var report: ActionReport
    }
    /// The pane's own height, so the detail block can be capped as a fraction of it rather than at
    /// an invented number.
    @State private var paneHeight: CGFloat = D.size.windowMin.height

    /// How long the CLEAR LOG key stays armed. Behaviour, not motion: long enough to be a
    /// deliberate second press, short enough that a forgotten armed key disarms itself.
    private static let clearArmWindow: Duration = .seconds(4)

    var body: some View {
        // Both derived collections are bound ONCE, here, and threaded down into the row builder.
        //
        // `rows` used to be a computed property and the badge set another one that re-ran the same
        // `search`, and the badge set was read from *inside* the `ForEach` content closure — so
        // SwiftUI evaluated it per materialised row, and each evaluation re-filtered the whole store
        // and allocated a `contributingLocales` array per transcript. That is O(rows²) over the
        // store on every render of the pane, not "twice per body".
        //
        // Bound here rather than cached in `@State` with an `onChange`, which is what the shape
        // suggests: the only invalidation signal that shape has is `transcripts.count`, and
        // `HistoryStore.load()` replacing the array with a different one of equal length — a
        // recovery from the backup, at launch — would leave the previous rows on screen.
        let rows = model.history.search(query)
        let ambiguousBadges = Self.ambiguousBadges(in: rows)

        return VStack(alignment: .leading, spacing: D.space.md) {
            controls(resultCount: rows.count)
            loadNotice
            table(rows: rows, ambiguousBadges: ambiguousBadges)
            if let transcript = selected {
                detail(for: transcript)
            }
        }
        .padding(D.space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
        .sheet(item: $draft) { draft in
            DictionaryEntrySheet(store: model.dictionary, draft: draft) {
                // The sheet closing is not the same event as an entry being saved, and the user needs
                // to know which one happened: a cancelled sheet closes exactly like a saved one.
                if let word = teachingWord {
                    teachOutcome = TeachOutcome(
                        word: word,
                        report: model.dictionary.entries.count > entryCountAtOpen
                            ? .done("Added")
                            : .failed("Not added")
                    )
                    teachingWord = nil
                }
                self.draft = nil
            }
        }
        .animation(D.motion.panel, value: selection)
        .task(id: armedClear) {
            guard armedClear else { return }
            try? await Task.sleep(for: Self.clearArmWindow)
            if !Task.isCancelled { armedClear = false }
        }
        // Re-read the learned policy whenever a row is opened. The *dictation* path demotes apps by
        // itself while this window is open, so a policy read once at launch would let the recovery
        // block print a sentence that stopped being true — which is the same silence as an inert
        // control, just quieter.
        .task(id: selection) { await model.refreshLearnedPolicies() }
    }

    private func detail(for transcript: Transcript) -> some View {
        TranscriptDetail(
            transcript: transcript,
            dictionary: model.dictionary,
            // Half the pane: enough for the whole comparison in the common case, never enough to
            // squeeze the log tray below its four-row floor.
            contentCap: paneHeight * 0.5,
            unbounded: unbounded,
            onDelete: { delete(transcript.id) },
            onSuggest: { word in
                entryCountAtOpen = model.dictionary.entries.count
                teachingWord = word
                teachOutcome = nil
                draft = EntryDraft(isCorrection: true, heard: word)
            },
            teachOutcome: teachOutcome,
            model: model
        )
    }

    // MARK: Controls

    private func controls(resultCount: Int) -> some View {
        HStack(spacing: D.space.md) {
            EquipmentSearchField(legend: "Find", text: $query, resultCount: resultCount)
                // `TextField` has no maximum height, so the channel would otherwise absorb the
                // slack the log tray is supposed to get.
                .frame(height: D.size.rowHeight)

            Spacer(minLength: D.space.sm)

            // Two-stage rather than a system confirmation dialog: an `NSAlert` in the middle of a
            // machined panel is exactly the macOS chrome this app is built to avoid, and a key that
            // must be pressed twice is how a tape deck guards an erase.
            ReportingButton(
                armedClear ? "Confirm" : "Clear log",
                template: "9999 erased",
                minWidth: D.size.buttonHeight * 3
            ) {
                guard armedClear else {
                    armedClear = true
                    // Nothing has happened yet, so nothing is reported. The latched cap *is* the
                    // report of an arming press.
                    return nil
                }
                let erased = model.history.transcripts.count
                model.history.removeAll()
                selection = nil
                armedClear = false
                return .done("\(erased) erased")
            }
            .disabled(model.history.transcripts.isEmpty)
            .accessibilityLabel(armedClear ? "Confirm erasing the whole log" : "Erase the whole log")
            .help(armedClear
                  ? "Press again to erase every transcript."
                  : "Erases every transcript. Press twice.")
        }
    }

    // MARK: The load notice

    /// What actually happened to `history.json` at launch, in the store's own words.
    ///
    /// This replaces a hardcoded `Text("history.json could not be read")` shown whenever
    /// `lastLoadError != nil`, which was wrong in both directions. After a **successful** recovery
    /// `lastLoadError` is deliberately non-nil — it is the only channel carrying "Recovered N entries
    /// from the backup" and the quarantine filename — so the pane told the user their history could
    /// not be read while they were looking at the recovered log. And it discarded the message, so the
    /// one pointer to where the user's bytes went existed only in the unified log: the unreachable
    /// backup all over again, displaced by one step.
    ///
    /// `recoveredEntryCount` rather than a substring match on the message, so the wording is not
    /// load-bearing. No line limit: the recovery and quarantine sentences are at the *end* of the
    /// message, which is exactly what a truncating limit removes.
    @ViewBuilder private var loadNotice: some View {
        if let message = model.history.lastLoadError {
            let recovered = model.history.recoveredEntryCount
            PanelSurface(recovered == nil ? "Log file" : "Recovered") {
                HStack(alignment: .top, spacing: D.space.md) {
                    Text(message)
                        .typeStyle(D.type.caption)
                        // Red is for a load that produced nothing. A recovery is news, not a fault:
                        // the log below it is real.
                        .foregroundStyle(recovered == nil ? D.color.alert : D.color.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    // With a quarantine file now genuinely on disk, naming it without offering a way
                    // to reach it would leave the user retyping a timestamped filename into a Finder
                    // search. Absent when the move failed — there is nothing to reveal, and the
                    // message says where the bytes actually are.
                    if let quarantined = model.history.quarantinedFileURL {
                        TapeButton("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([quarantined])
                        }
                        .help("Shows \(quarantined.lastPathComponent) in the Finder.")
                        .accessibilityLabel("Show the quarantined history file in the Finder")
                    }
                }
            }
        }
    }

    // MARK: Table

    private func table(rows: [Transcript], ambiguousBadges: Set<String>) -> some View {
        let content = LogTrayContent(
            rowCount: rows.count,
            storeCount: model.history.transcripts.count,
            query: query
        )
        return PanelSurface("Log", inset: D.space.wellInset) {
            RecessedWell(fill: .list, inset: 0) {
                switch content {
                case .rows: rowList(rows, ambiguousBadges: ambiguousBadges)
                case .emptyLog: emptyLog
                case .noMatch(let query): noMatch(query)
                }
            }
        }
        // An empty tray is capped rather than stretched, exactly as `ImportPane.queue` caps its
        // own: 700 points of void with one sentence in it "reads as a broken layout", in that
        // pane's words, where a tray sized to a handful of rows reads as an empty tray.
        .frame(
            minHeight: D.size.rowHeight * 4,
            maxHeight: content == .rows ? .infinity : D.size.rowHeight * HistoryPaneMetrics.emptyTrayRows
        )
    }

    private func rowList(_ rows: [Transcript], ambiguousBadges: Set<String>) -> some View {
        MaybeScroll(scrolls: !unbounded) {
            LazyVStack(spacing: 0) {
                ForEach(rows) { transcript in
                    TranscriptRow(
                        transcript,
                        isSelected: selection == transcript.id,
                        onCopy: { ViewClipboard.put(transcript.text) },
                        outcome: model.displayOutcome(for: transcript),
                        isRetrying: model.retryingTranscriptID == transcript.id,
                        localeIsAmbiguous: ambiguousBadges.contains(
                            LanguageCode.badge(transcript.localeIdentifier)
                        ),
                        onRetry: { Task { await model.retryInjection(transcript) } }
                    )
                    // Not a `Button` wrapper: the row already contains one (the copy key),
                    // and nesting buttons swallows the inner key's hits.
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = (selection == transcript.id) ? nil : transcript.id
                    }
                    .contextMenu {
                        Button("Copy") { ViewClipboard.put(transcript.text) }
                        if model.displayOutcome(for: transcript).needsRecovery {
                            Button("Insert again") {
                                Task { await model.retryInjection(transcript) }
                            }
                        }
                        Button("Delete") { delete(transcript.id) }
                    }
                }
            }
        }
    }

    // MARK: The empty tray

    /// First run, and the pane the app opens on.
    ///
    /// The tray used to be a recessed well wrapping a `ForEach` over nothing: no text, no next step.
    /// It is also the only moment the gestures are learnable — `AppModel.statusLine` names the
    /// language modifier but the main window prints `StatusReadout(.ready)`, i.e. the single word
    /// "Ready", and the refine chord is named only in the menu-bar popover and in Settings.
    ///
    /// The sentences come from `GestureCopy.lines`, off the *live* settings, so a rebound key or a
    /// switched-off feature cannot leave this teaching a gesture the user does not have.
    private var emptyLog: some View {
        VStack(spacing: D.space.sm) {
            SilkscreenLabel("Nothing recorded yet", weight: .heading, alignment: .center)
            VStack(alignment: .leading, spacing: D.space.xs) {
                ForEach(
                    GestureCopy.lines(
                        settings: model.settings,
                        secondaryLocaleReady: model.secondaryLocaleReady
                    ),
                    id: \.self
                ) { line in
                    Text(line)
                        .typeStyle(D.type.explain)
                        .foregroundStyle(D.color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            // Left-aligned inside a centred block: four gestures are a list, and a centred list
            // has no edge for the eye to run down. The width is what the height cap above was
            // measured against — see `HistoryPaneMetrics.emptyCopyWidth`.
            .frame(maxWidth: HistoryPaneMetrics.emptyCopyWidth)
        }
        .padding(D.space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// A query that filtered everything out. Distinct from an empty log, because the remedy is
    /// different: there was no branch for this at all, so a search with no hits looked exactly like
    /// a log with nothing in it.
    private func noMatch(_ query: String) -> some View {
        VStack(spacing: D.space.sm) {
            SilkscreenLabel("No match", weight: .heading, alignment: .center)
            Text("No transcript matches \u{201C}\(query)\u{201D}.")
                .typeStyle(D.type.explain)
                .foregroundStyle(D.color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                // The query is already legible in the field above, so a pasted paragraph is
                // truncated here rather than allowed to grow the tray past its cap.
                .lineLimit(2)
                .frame(maxWidth: HistoryPaneMetrics.emptyCopyWidth)
        }
        .padding(D.space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Data

    /// Two-letter badges that more than one language in this log would print.
    ///
    /// A row sees one transcript and so cannot know that `en-US` and `en-GB` are both here; only the
    /// pane can. Without this the language column would print `EN` for both — a column that indicates
    /// nothing while looking like it works, which is the same class of failure the column was added to
    /// prevent. Computed over the *filtered* rows, because that is what is on screen: a badge is only
    /// ambiguous against something the reader can also see.
    ///
    /// A `static` function of the rows rather than a computed property over `model`, so that
    /// `body` can call it once instead of the `ForEach` calling it per row.
    static func ambiguousBadges(in rows: [Transcript]) -> Set<String> {
        var byBadge: [String: Set<String>] = [:]
        for transcript in rows {
            for identifier in transcript.contributingLocales {
                let tag = LanguageCode.hyphenated(identifier)
                byBadge[LanguageCode.badge(tag), default: []].insert(tag.lowercased())
            }
        }
        return Set(byBadge.filter { $0.value.count > 1 }.keys)
    }

    private var selected: Transcript? {
        guard let selection else { return nil }
        return model.history.transcripts.first { $0.id == selection }
    }

    private func delete(_ id: UUID) {
        model.history.remove(ids: [id])
        // A refinement is a reading of a transcript, so it cannot outlive one. Without this, a
        // deleted row's cleaned-up text would sit in memory keyed by an id nothing points at any
        // more — and a new transcript is never given a used id, so it would never be shown again,
        // but the app would still be holding the user's deleted speech.
        model.refinement.forget(id)
        if selection == id { selection = nil }
    }
}

// MARK: - HistoryPaneMetrics

/// The widths and heights this pane's own arithmetic is checked against.
///
/// A named enum rather than private constants for the same reason `ExportKeyMetrics` is one: the app
/// cannot be photographed from an automated run (RECON §40), so the only thing that can catch a
/// legend the container cannot afford is a test doing the arithmetic — and a test can only do it
/// against numbers it can read. `HistoryPaneLayoutTests` holds these to the font.
enum HistoryPaneMetrics {
    /// The ceiling on the log tray when it has no rows, in `D.size.rowHeight` units.
    ///
    /// Ten rather than `ImportPane`'s eight, and the two points of difference are the point: that
    /// tray holds one centred sentence, this one holds a heading and four gestures. Eight rows was
    /// tried first and `HistoryPaneLayoutTests.theEmptyTrayFitsItsCap` refused it — 208pt against a
    /// worst case of 219.6pt, which would have clipped the drop hint. Nothing else could have caught
    /// that: RECON §40 means the tray cannot be photographed from an automated run.
    static let emptyTrayRows: CGFloat = 10
    /// The measure the empty tray's sentences are set to. Prose, so it is set for line length rather
    /// than filled to the tray: at the tray's full width a gesture line would be one long line and
    /// the four of them would not read as a list.
    static let emptyCopyWidth: CGFloat = 460

    /// How many lines of a transcript the well shows before the user asks for the rest.
    static let collapsedLineLimit = 4
    /// Words per block in an expanded well. See `TranscriptWell` for the measurement that chose it;
    /// anything shorter than this is one block, i.e. one `Text`, i.e. unchanged.
    static let chunkTargetWords = 300

    /// The narrowest the transcript panel's content can be: the minimum window width, less the
    /// rail, the machined channel beside it, the pane's own padding and the panel's inset.
    ///
    /// `railSeam` mirrors `SeamDivider(.vertical, depth: .channel)`, whose width is assembled from
    /// constants private to `Components.swift`; its own documentation states the total.
    static let railSeam: CGFloat = 2.5
    static var narrowestPanelWidth: CGFloat {
        D.size.windowMin.width - D.size.railWidth - railSeam - 2 * D.space.md - 2 * D.space.panelInset
    }
    /// `TapeCap`'s seat, one point on each side outside the cap's own padding — mirroring
    /// `M.capSeatOutset`, which is private to `Components.swift`.
    static let capSeatOutset: CGFloat = 1
}

// MARK: - LogTrayContent

/// What the log tray draws: rows, an empty log, or a query that matched nothing.
///
/// A type rather than two `if`s in the view body, because the distinction is the finding: a tray
/// with no rows had one branch — the `ForEach` over nothing — so a filtered-out search and a log
/// with nothing in it produced the same blank well. View bodies cannot be tested; this can.
enum LogTrayContent: Equatable {
    case rows
    case emptyLog
    case noMatch(query: String)

    /// - Parameters:
    ///   - rowCount: rows after the search filter.
    ///   - storeCount: transcripts in the store, unfiltered.
    ///   - query: the search field's text, as typed.
    init(rowCount: Int, storeCount: Int, query: String) {
        let trimmed = query.trimmed
        if rowCount > 0 {
            self = .rows
        } else if storeCount > 0, !trimmed.isEmpty {
            self = .noMatch(query: trimmed)
        } else {
            // Also the unreachable case — a non-empty store with an empty query — since
            // `HistoryStore.search` returns everything for an empty query. Teaching the gestures is
            // the safer thing to do if that ever stops being true.
            self = .emptyLog
        }
    }
}

// MARK: - GestureCopy

/// The gestures the empty log teaches, in the words of the settings actually in force.
///
/// Read from live settings rather than written out, because every one of them is reconfigurable and
/// two of them can be switched off: a first-run panel that named a chord the user does not have
/// would be teaching a gesture that does nothing. Pure, and returned as strings, so the wording and
/// the conditions are testable without a view.
enum GestureCopy {

    /// - Parameter secondaryLocaleReady: whether the second language's speech assets are installed.
    ///   The line is withheld until they are, matching `AppModel.statusLine`, which gates the same
    ///   sentence the same way — naming the modifier before the model is on disk would teach a
    ///   gesture whose first use is an error message.
    @MainActor
    static func lines(settings: Settings, secondaryLocaleReady: Bool) -> [String] {
        var lines: [String] = []

        let hold = settings.pushToTalk
            ? "Hold \(settings.hotkey.displayName) and speak."
            : "Press \(settings.hotkey.displayName) to start, and press it again to stop."
        // Never "the words appear at your cursor": with `autoInject` off nothing is inserted at all,
        // and the ladder can still end on the clipboard even when it is on — which the transcript's
        // own row says, in its own words, when it happens.
        let destination = settings.autoInject
            ? " Edict puts the text at your cursor."
            : " Edict leaves the text on your clipboard."
        lines.append(hold + destination)

        if secondaryLocaleReady, let secondary = settings.effectiveSecondaryLocaleIdentifier {
            lines.append(
                "Add \(settings.secondaryLocaleModifier.glyph) while you hold it to dictate in "
                    + "\(LocaleNames.display(secondary))."
            )
        }

        if let chord = settings.effectiveRefineChord {
            lines.append(
                "\(chord.glyph(dictationKey: settings.hotkey)) cleans up, bullets or summarises "
                    + "text you have selected in any app."
            )
        }

        lines.append(
            "Drop \(ImportableMedia.plainDescription) anywhere on this window to transcribe it — "
                + "the transcript arrives here."
        )
        return lines
    }
}

// MARK: - Render-harness helpers

/// A `ScrollView`, or its content bare. Only the render harness ever asks for bare — see
/// `HistoryPane.unbounded`.
private struct MaybeScroll<Content: View>: View {
    let scrolls: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if scrolls {
            ScrollView { content() }
                .scrollContentBackground(.hidden)
        } else {
            content()
        }
    }
}

/// Applies a definite height, or none at all. `TranscriptDetail` needs a definite one in the app (an
/// ideal proposal makes its `ScrollView` measure as zero) and none in the harness, where there is no
/// scroll view to measure.
private struct DefiniteHeight: ViewModifier {
    let height: CGFloat?

    func body(content: Content) -> some View {
        if let height { content.frame(height: height) } else { content }
    }
}

// MARK: - TranscriptDetail

/// What the machine heard, what it wrote, and every rule that fired in between.
private struct TranscriptDetail: View {

    let transcript: Transcript
    let dictionary: DictionaryStore
    /// Ceiling on the *content*, not on the panel. The scroll view lives inside the panel so the
    /// panel's own edge and contact shadow are never cut — a clipped panel border reads as a
    /// rendering bug, where a scrolled interior reads as a scrolled interior.
    let contentCap: CGFloat
    /// See `HistoryPane.unbounded`.
    let unbounded: Bool
    let onDelete: () -> Void
    let onSuggest: (String) -> Void
    /// The outcome of the last TEACH press, printed on that key. Owned by the pane because the sheet
    /// that produces it outlives this view's identity (`.id(transcript.id)`).
    let teachOutcome: HistoryPane.TeachOutcome?
    /// Needed for the recovery block: the injector's learned policy and the retry path both live on
    /// the model. Nothing else in this view reads it.
    let model: AppModel

    /// The content's ideal height. A vertical `ScrollView` proposes nil in its scroll axis, so the
    /// content inside it lays out at its natural size and this measures that.
    @State private var contentHeight: CGFloat = 0

    /// What the last export press did. Held here rather than on the keys because the keys cannot
    /// print it — see `TranscriptExportKeys` for the measurement — and this view carries
    /// `.id(transcript.id)`, so selecting another transcript correctly clears an outcome that
    /// belonged to the previous one.
    @State private var exportOutcome: TranscriptExportOutcome?

    var body: some View {
        // Counted once, here, and handed to both the header readout and the transcript well's key.
        // `Transcript.wordCount` splits the whole text on whitespace — measured on this machine at
        // 4.6-6.1 ms for a 10,200-word import — and the two of them would otherwise pay for it
        // twice on every render of this block.
        let words = transcript.wordCount
        return PanelSurface("Transcript") {
            // A *definite* height: given only a maximum a `ScrollView` is greedy and eats the log
            // tray, and given an ideal proposal it measures as zero and disappears entirely.
            MaybeScroll(scrolls: !unbounded) {
                VStack(alignment: .leading, spacing: D.space.md) {
                    header(words: words)
                    // Directly under the keys that produced it, and full width, because the reason a
                    // write failed is a sentence with a remedy in it. `TranscriptExportKeys` records
                    // why this cannot go on the key cap.
                    if let exportOutcome {
                        Text(exportOutcome.sentence)
                            .typeStyle(D.type.caption)
                            .foregroundStyle(exportOutcome.isFault ? D.color.alert : D.color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if transcript.mayBeIncomplete { incompleteNotice }
                    // Above the transcript, not below it: the point is to be read *before* the text
                    // is trusted. Renders to nothing when the recognition rate was plausible.
                    QualityNotice(transcript.quality)
                    if outcome.needsRecovery { recovery }
                    TranscriptWell(
                        label: transcriptLabel,
                        text: transcript.text,
                        wordCount: words,
                        // An import opens expanded: for a file the transcript IS the deliverable,
                        // and the four-line cap was justified for a dictation the user had just
                        // spoken and already read.
                        startsExpanded: transcript.isImported
                    )
                    // What the on-device model did to this dictation *before* it was inserted, for a
                    // transcript recorded while `Settings.refineBeforeInsert` was on. Directly under
                    // the transcript, because the pair is the point: this is the record of speech,
                    // that is what went into the document.
                    if let record = transcript.refinement {
                        InsertedRefinement(record: record)
                    }
                    LanguageSpansView(transcript: transcript)
                    // The three keys, above the dictionary evidence rather than below it. This is a
                    // control the user came here to press; "as heard" and the hit list are evidence
                    // they read when something looks wrong. Burying the keys under a scroll would
                    // make the primary surface of the feature the part nobody finds.
                    RefinementBlock(
                        transcript: transcript,
                        store: model.refinement,
                        unbounded: unbounded
                    )
                    if transcript.didCorrect {
                        // Collapsed even for an import, deliberately: this well is the evidence
                        // that the dictionary fired, read when something looks wrong, and two
                        // expanded copies of a 70-minute transcript would bury everything under it.
                        TranscriptWell(
                            label: "As heard",
                            text: transcript.rawText,
                            wordCount: Transcript.wordCount(of: transcript.rawText),
                            startsExpanded: false
                        )
                        corrections
                    }
                    if !suggestions.isEmpty { lowConfidence }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .modifier(DefiniteHeight(height: unbounded
                ? nil
                : min(max(contentHeight, D.size.rowHeight * 2), contentCap)))
        }
        // A fresh measurement per transcript: a stale height would size the new block for a frame.
        .id(transcript.id)
    }

    /// What the transcript well is called.
    ///
    /// Normally "Inserted", because for a dictation the transcript *is* what went to the cursor. When
    /// refinement ran before inserting, it is not: the refined text went in, and calling this well
    /// "Inserted" would be a false claim about a document the user cannot see from here. The refined
    /// block below takes the name in that case.
    private var transcriptLabel: String {
        if transcript.isImported { return "Transcript" }
        return transcript.refinement?.didInsertRefinedText == true ? "As dictated" : "Inserted"
    }

    // MARK: Header

    private func header(words: Int) -> some View {
        HStack(alignment: .center, spacing: D.space.md) {
            readout("Length", .duration(transcript.audioDuration))
            readout("Words", .count(words, unit: "w"))
            if transcript.isImported {
                // For a file this is the whole job, not an end-of-speech latency, so it is reported
                // as a speed: "62x" reads as "an hour of audio in a minute", which is the number a
                // user deciding whether to import a long recording actually wants.
                readout("Took", .duration(transcript.transcribeDuration))
                readout("Speed", .count(Int(realtimeFactor.rounded()), unit: "x"))
            } else {
                readout("Latency", .count(Int((transcript.transcribeDuration * 1000).rounded()), unit: "ms"))
            }

            if transcript.isMixedLanguage {
                VStack(alignment: .leading, spacing: D.space.xxs) {
                    SilkscreenLabel("Languages", weight: .tiny)
                        .silkscreenDecorative()
                    // The identifiers, not the language names: this readout sits in a row of
                    // fixed-width counters with no room to grow, and "Indonesian + English"
                    // truncated to "Indone…" says less than "id-ID + en-US" says whole. The names
                    // are spelled out in the per-section table below.
                    Text(transcript.contributingLocales.map(LocaleNames.short).joined(separator: " + "))
                        .typeStyle(D.type.mono)
                        .foregroundStyle(D.color.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                        .help(
                            LocaleNames.summary(transcript.contributingLocales)
                                + " — each section was transcribed in both languages and the closer match kept."
                        )
                }
            }

            VStack(alignment: .leading, spacing: D.space.xxs) {
                SilkscreenLabel(transcript.isImported ? "From file" : "Inserted into", weight: .tiny)
                    .silkscreenDecorative()
                Text(target)
                    .typeStyle(D.type.caption)
                    // An imported transcript was never *meant* to be inserted, so the alert ink
                    // would be a false alarm — the only fault here is a failed injection.
                    .foregroundStyle(
                        transcript.isImported || outcome.isSuccess
                            ? D.color.textPrimary
                            : D.color.alert
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(target)
            }

            Spacer(minLength: D.space.sm)

            // Export lives in the detail block, not on the row: the row is a dense table line and
            // three more keys per row would swamp it, while the detail is already the place the user
            // has committed to one transcript. SRT and VTT grey themselves out for a dictated
            // transcript — there are no per-word timings to cut cues against — and say so on hover.
            // The outcome goes to a line under this header, not onto a cap: measured, a bank of three
            // keys templated for a write failure needs 410.9pt where this header has 137.8pt of
            // slack left. See `TranscriptExportKeys`.
            TranscriptExportKeys(transcript) { exportOutcome = $0 }
            SeamDivider(.vertical)
                .frame(height: D.size.buttonHeight)
            ReportingButton("Copy", template: "Copied") {
                ViewClipboard.put(transcript.text)
                return .done("Copied")
            }
            ReportingButton("Delete", template: "Deleted") {
                onDelete()
                // The block this key lives in is torn down by its own success, so the report is only
                // ever seen when something went wrong. Reporting it anyway costs nothing and means the
                // key is not a special case in the pass.
                return .done("Deleted")
            }
            .help("Deletes this recording of your speech. There is no undo.")
        }
    }

    /// Audio seconds per wall-clock second over the whole import.
    private var realtimeFactor: Double {
        guard transcript.transcribeDuration > 0 else { return 0 }
        return transcript.audioDuration / transcript.transcribeDuration
    }

    /// The outcome to *show*: a retry's result when there was one, else what was recorded.
    private var outcome: InjectionOutcome { model.displayOutcome(for: transcript) }

    /// Where a retry would aim, and how it is described. Nil when there is nowhere to aim yet.
    private var retryTarget: String? { model.lastForegroundApp?.name }

    // MARK: Recovery

    /// What to do about a transcript whose text never reached the cursor.
    ///
    /// The ladder used to end here — `.clipboardOnly`, the text sitting on the clipboard, and nothing
    /// further offered. This is the exact failure the app exists to handle well, so it gets a block of
    /// its own rather than a footnote: re-run the ladder, or teach Edict to stop trying the rung that
    /// failed. Nothing is re-transcribed; this is the stored string going through `TextInjector` again.
    @ViewBuilder
    private var recovery: some View {
        VStack(alignment: .leading, spacing: D.space.sm) {
            SilkscreenLabel("Did not land", weight: .tiny)
                .silkscreenDecorative()
            Text(explanation)
                .typeStyle(D.type.explain)
                .foregroundStyle(D.color.alert)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: D.space.sm) {
                ReportingButton(
                    "Insert again",
                    template: "Clipboard only",
                    minWidth: D.size.buttonHeight * 4
                ) {
                    guard let outcome = await model.retryInjection(transcript) else {
                        return .failed("Nowhere to aim")
                    }
                    return outcome.isSuccess
                        ? .done(outcome.displayName)
                        : .failed(outcome.displayName)
                }
                .disabled(model.retryingTranscriptID != nil || retryTarget == nil)
                .help(retryHelp)

                if let bundleID = transcript.targetBundleID {
                    policyKeys(bundleID)
                }
                Spacer(minLength: D.space.xs)
            }

            if let bundleID = transcript.targetBundleID {
                policyReadout(bundleID)
            }
        }
        .padding(D.space.sm)
        .background(RoundedRectangle(cornerRadius: D.radius.tight, style: .continuous)
            .strokeBorder(D.color.alert, lineWidth: D.border.hairline))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recovery")
    }

    private var explanation: String {
        let app = transcript.targetAppName ?? transcript.targetBundleID ?? "the app you were in"
        let landed = model.retryOutcomes[transcript.id]
        if let landed, landed.outcome.isSuccess {
            return "Edict could not put this into \(app), so it was left on your clipboard. "
                + "It has since been inserted into \(landed.appName)."
        }
        return "Edict could not put this into \(app), so it was left on your clipboard."
    }

    private var retryHelp: String {
        guard let retryTarget else {
            return "Click the app you want the text in, come back here, then press this — Edict aims at "
                + "the app you were last working in, because while you are reading this the app in "
                + "front is Edict."
        }
        return "Runs the whole insertion ladder again, into \(retryTarget)."
    }

    // MARK: Learned policy

    /// The per-bundle policy `TextInjector` already keeps, made visible and editable.
    ///
    /// It is surfaced rather than left implicit because the injector demotes apps *by itself* — an app
    /// that accepts an Accessibility write and ignores it is permanently switched to paste-only — and a
    /// system that silently changes its own behaviour is indistinguishable from a flaky one.
    private func policyReadout(_ bundleID: String) -> some View {
        let learned = model.learnedPolicy(for: bundleID)
        let app = transcript.targetAppName ?? bundleID
        return Text(learned.map { "Edict has learned to use \($0.displayName.lowercased()) in \(app)." }
                    ?? "Edict has learned nothing about \(app) yet; it tries the full ladder there.")
            .typeStyle(D.type.explain)
            .foregroundStyle(D.color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func policyKeys(_ bundleID: String) -> some View {
        if model.learnedPolicy(for: bundleID) == nil {
            ReportingButton("Paste only here", template: "Learned", minWidth: D.size.buttonHeight * 4.6) {
                await model.setPasteOnly(for: bundleID)
                return .done("Learned")
            }
            .help("Skip the Accessibility rung in this app from now on, and go straight to a paste.")
        } else {
            ReportingButton("Forget", template: "Forgotten", minWidth: D.size.buttonHeight * 3) {
                await model.forgetPolicy(for: bundleID)
                return .done("Forgotten")
            }
            .help("Clear what Edict has learned about this app so it tries the full ladder again.")
        }
    }

    private var target: String {
        // Imported transcripts have no target app by construction — nothing was injected, which is
        // the whole behavioural difference from a dictation.
        if let filename = transcript.source.importedFilename {
            return filename.isEmpty ? "Imported file" : filename
        }
        let app = transcript.targetAppName ?? transcript.targetBundleID
        switch (app, outcome) {
        case (let app?, .notAttempted): return "\(app) — not inserted"
        case (let app?, let outcome): return "\(app) — \(outcome.displayName)"
        case (nil, let outcome): return outcome.displayName
        }
    }

    private func readout(_ label: String, _ format: SegmentCounter.Format) -> some View {
        VStack(alignment: .leading, spacing: D.space.xxs) {
            SilkscreenLabel(label, weight: .tiny)
                .silkscreenDecorative()
            SegmentCounter(format, scale: .small)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    // MARK: Blocks

    /// RECON §20: dropped buffers delete the *beginning* of the utterance, which reads as the model
    /// failing rather than as audio being lost. Saying so is the whole point of the flag.
    private var incompleteNotice: some View {
        HStack(spacing: D.space.sm) {
            Rectangle()
                .strokeBorder(D.color.alert, lineWidth: D.border.thin)
                .frame(width: D.size.troughHeight, height: D.size.troughHeight)
            Text("This transcript may be incomplete — \(transcript.droppedBuffers) audio buffers were dropped, "
                 + "which loses the start of what you said.")
                .typeStyle(D.type.explain)
                .foregroundStyle(D.color.alert)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// The evidence. One line per hit, in the form the contracts fix:
    /// `"cloud code" → "Claude Code"`.
    private var corrections: some View {
        VStack(alignment: .leading, spacing: D.space.labelGap) {
            HStack(spacing: D.space.xs) {
                SilkscreenLabel("Dictionary", weight: .tiny)
                    .silkscreenDecorative()
                SegmentCounter(.count(transcript.corrections.count, unit: "hit"), scale: .tiny)
            }
            // A plain `VStack`, not a `ScrollView`: given an *ideal* height proposal — which is
            // what a fit-sized panel hands down — a `ScrollView` measures as zero and the whole
            // tray disappears. Measured on the rendered sheet: the hit list was invisible.
            // Bounded instead by showing the first `maxHits` and counting the rest.
            RecessedWell(fill: .list, inset: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shownHits) { hit in
                        CorrectionLine(hit: hit, entry: entry(for: hit))
                    }
                    if hiddenHitCount > 0 {
                        Text("+\(hiddenHitCount) more")
                            .typeStyle(D.type.explain)
                            .foregroundStyle(D.color.textSecondary)
                            .padding(.horizontal, D.space.rowInset)
                            .frame(height: D.size.rowHeight, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Four rows is one screenful of evidence; past that the count is the information.
    private static let maxHits = 4

    private var shownHits: [CorrectionHit] { Array(transcript.corrections.prefix(Self.maxHits)) }
    private var hiddenHitCount: Int { max(0, transcript.corrections.count - Self.maxHits) }

    private func entry(for hit: CorrectionHit) -> DictionaryEntry? {
        dictionary.entries.first { $0.id == hit.entryID }
    }

    // MARK: Low confidence

    /// RECON's one earned feature: per-word `transcriptionConfidence` is strongly discriminative
    /// (misheard "Visa" scored 0.05 against 0.998 for a correct word), so a sub-0.5 word is a very
    /// good guess at what the dictionary is missing. One press opens the add sheet with the misheard
    /// side already filled in — the user only has to type what it should have been.
    private var lowConfidence: some View {
        VStack(alignment: .leading, spacing: D.space.labelGap) {
            SilkscreenLabel("Unsure of", weight: .tiny)
                .silkscreenDecorative()
            Text("Edict was not confident about these words. Teach it the right ones.")
                .typeStyle(D.type.explain)
                .foregroundStyle(D.color.textSecondary)
            VStack(spacing: D.space.xs) {
                ForEach(suggestions, id: \.self) { word in
                    HStack(spacing: D.space.sm) {
                        RecessedWell(fill: .list) {
                            Text("\u{201C}\(word)\u{201D}")
                                .typeStyle(D.type.mono)
                                .foregroundStyle(D.color.textPrimary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ReportingButton(
                            "Teach",
                            template: "Not added",
                            report: teachOutcome?.word == word ? teachOutcome?.report : nil
                        ) {
                            onSuggest(word)
                            // Opening the sheet is not an outcome. The pane watches the dictionary
                            // across the sheet's lifetime and hands the real one back above.
                            return nil
                        }
                        .accessibilityLabel("Add a correction for \(word)")
                    }
                }
            }
        }
    }

    /// Deduped and capped: a long tail of unsure words is noise, and the first few are the ones the
    /// user will recognise.
    private var suggestions: [String] {
        var seen = Set<String>()
        return transcript.lowConfidenceWords.filter { word in
            let key = word.lowercased()
            guard !key.isEmpty, seen.insert(key).inserted else { return false }
            return true
        }
        .prefix(3)
        .map { $0 }
    }
}

// MARK: - TranscriptWell

/// A transcript in a recessed well: the first `collapsedLineLimit` lines by default, all of it on
/// request.
///
/// **Why the limit is state and not a constant.** The four-line cap was justified by
/// `RefinementPane`'s note that this well "is a reminder of text the user has already read". That is
/// true of a dictation and false of every import: an imported transcript is a result the user waited
/// minutes for and has never seen, the README sells nine-minute recordings and 70-minute meetings,
/// and refinement is no way round it either (`TextRefiner` throws `tooLong` rather than truncating).
/// The cap also sat *outside* the `textSelection`, so the hidden text could not even be selected.
/// So an import opens expanded, a dictation opens capped, and either can be toggled.
///
/// **Why the expanded text is drawn in blocks rather than as one `Text`.** Measured with CoreText at
/// this well's width on this machine, 664pt, `D.type.body` rebuilt through AppKit: framesetting a
/// 10,500-word transcript (64,359 characters — 70 minutes of speech at 150 wpm) as one string takes
/// 146 ms and produces 610 lines. The cost is superlinear, so cutting the *same* text into 35 blocks
/// lays all of them out in 12.4 ms, and inside a `LazyVStack` only the blocks in the viewport lay out
/// at all, at 0.36 ms each. One `Text` would therefore stall the pane for about nine frames every
/// time the block is laid out again, which includes every step of a window resize. Anything under
/// `HistoryPaneMetrics.chunkTargetWords` words is returned whole, so every dictation and every short
/// import is exactly one `Text` with the exact stored string in it.
///
/// The price is real and worth stating: a selection cannot be dragged across a block boundary the way
/// it can inside one `Text`, and the single space at each cut is drawn as a block break. COPY in the
/// header above puts the whole transcript on the clipboard and the export keys write the whole file,
/// so no block boundary is between the user and their text.
///
/// The expanded state is only ever *seen* offline through the `unbounded` hatch (RECON §40), which
/// also removes the enclosing `ScrollView` — so in the render harness the `LazyVStack` is not lazy
/// and every block lays out. That is the 12.4 ms case, not the 146 ms one.
private struct TranscriptWell: View {

    let label: String
    let text: String
    /// Words in `text`, passed in rather than recomputed here: see `TranscriptDetail.body`.
    let wordCount: Int

    @State private var isExpanded: Bool
    /// The width the text is actually laid out at, so the truncation test measures the real line
    /// breaks rather than an assumed column.
    @State private var measuredWidth: CGFloat = 0

    init(label: String, text: String, wordCount: Int, startsExpanded: Bool) {
        self.label = label
        self.text = text
        self.wordCount = wordCount
        self._isExpanded = State(initialValue: startsExpanded)
    }

    /// Measured 2pt narrower than the real column. The bias is deliberate: `CTTypesetter`'s line
    /// breaking is not guaranteed to agree with SwiftUI's to the point, and of the two ways to be
    /// wrong at the boundary — a key that reveals nothing, or a hidden fifth line with no key — only
    /// one of them hides the user's words.
    private static let wrapSafety: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: D.space.labelGap) {
            HStack(spacing: D.space.sm) {
                SilkscreenLabel(label, weight: .tiny)
                    .silkscreenDecorative()
                Spacer(minLength: D.space.xs)
                key
            }
            RecessedWell(fill: .list) {
                content
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
            }
            // Combined on the WELL and not on the whole block, unlike the plain text block this
            // replaced: `.combine` on the outer stack would fold the key into one element and take
            // its action with it, so the only control that can reveal the rest of the transcript
            // would be unreachable to VoiceOver. The value is the full text either way.
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityValue(text)
        }
    }

    @ViewBuilder private var key: some View {
        if isExpanded {
            TapeButton("Show less") { isExpanded = false }
                .accessibilityLabel("Show only the first \(HistoryPaneMetrics.collapsedLineLimit) lines")
                .help("Shows the first \(HistoryPaneMetrics.collapsedLineLimit) lines again.")
        } else if isTruncated {
            TapeButton("Show all (\(wordCount.formatted()) words)") { isExpanded = true }
                .accessibilityLabel("Show the whole transcript, \(wordCount) words")
                .help("Shows the whole transcript. It scrolls inside this panel.")
        }
    }

    @ViewBuilder private var content: some View {
        if text.isEmpty {
            styled("—")
        } else if isExpanded {
            LazyVStack(alignment: .leading, spacing: D.space.sm) {
                // Offset ids, not the block text: two blocks of a repetitive transcript can be
                // byte-identical, and identical ids would collapse them into one row.
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    styled(block)
                }
            }
        } else {
            styled(text)
                .lineLimit(HistoryPaneMetrics.collapsedLineLimit)
        }
    }

    private func styled(_ string: String) -> some View {
        Text(string)
            .typeStyle(D.type.body)
            .foregroundStyle(D.color.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var blocks: [String] {
        TranscriptWellText.blocks(text, targetWords: HistoryPaneMetrics.chunkTargetWords)
    }

    /// Whether the collapsed well is hiding anything — measured, not guessed from a character count.
    private var isTruncated: Bool {
        TranscriptWellText.exceeds(
            lineLimit: HistoryPaneMetrics.collapsedLineLimit,
            text: text,
            width: measuredWidth - Self.wrapSafety
        )
    }
}

// MARK: - TranscriptWellText

/// The two text measurements `TranscriptWell` needs, kept out of the view so both can be tested —
/// a view body cannot be, and these are the parts that can be wrong.
enum TranscriptWellText {

    /// `D.type.body` rebuilt through AppKit, because a SwiftUI `Font` cannot be measured. Exactly the
    /// trick `ExportKeyWidthTests` uses on the cap face, and it carries the same warning: if the
    /// token's size changes and this does not, the threshold drifts by a line at the boundary. The
    /// consequence of that drift is a key that appears slightly early or late, never text that
    /// cannot be reached.
    ///
    /// Computed rather than stored because `NSFont` is not `Sendable`, and a `static let` of one
    /// would have to be either `nonisolated(unsafe)` or main-actor-isolated — the second of which
    /// would drag `blocks`, which needs no font at all, onto the main actor with it. `systemFont`
    /// is itself cached by AppKit, so this is a dictionary lookup against a 0.27 ms measurement.
    private static var bodyFont: NSFont { NSFont.systemFont(ofSize: 13, weight: .regular) }

    /// True when `text` needs more than `lineLimit` lines at `width`.
    ///
    /// CoreText rather than SwiftUI, because SwiftUI cannot answer this without laying the text out:
    /// the usual trick — render it twice and compare heights — costs the full 146 ms layout on
    /// exactly the transcripts this exists for. A `CTTypesetter` is asked for at most
    /// `lineLimit + 1` line breaks, so the cost does not grow with the text: measured at 0.27 ms for
    /// a 64,359-character transcript and 0.10 ms for a four-word one, which is why the view calls it
    /// straight from its body rather than caching the answer.
    ///
    /// No paragraph loop, because `CTTypesetterSuggestLineBreak` was measured on this machine to
    /// break at hard newlines: five `\n`-separated words at 664pt report five lines, the same text
    /// with spaces reports one.
    static func exceeds(lineLimit: Int, text: String, width: CGFloat) -> Bool {
        // A width of zero is the first frame, before `onGeometryChange` has reported anything —
        // and at zero the typesetter breaks after roughly every character, so guessing would put a
        // key on every four-word dictation for one frame.
        guard lineLimit > 0, width > 1, !text.isEmpty else { return false }

        let attributed = NSAttributedString(string: text, attributes: [.font: bodyFont])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        var index = 0
        var lines = 0
        while index < attributed.length {
            let count = CTTypesetterSuggestLineBreak(typesetter, index, Double(width))
            // Defensive, not expected: a zero-length suggestion would spin here for ever, and a
            // measurement this cheap must not be able to hang the pane.
            guard count > 0 else { return false }
            index += count
            lines += 1
            if lines > lineLimit { return true }
        }
        return false
    }

    /// Break `text` into blocks of about `targetWords` words for the expanded well.
    ///
    /// Cuts only *after* a word, and preferentially after one that ends a sentence, so a block break
    /// falls where a paragraph break would. A run with no sentence end is cut at twice the target
    /// rather than allowed to grow without bound — an unpunctuated transcript is precisely the case
    /// that most needs breaking up.
    ///
    /// Every word survives, in order. What does not survive is the whitespace at each cut, which is
    /// consumed and drawn as the gap between two blocks. A text shorter than the target is returned
    /// as a single block, byte for byte, which is the path every dictation takes.
    ///
    /// Scanned over UTF-8 rather than over `Character`s: measured 0.32-0.50 ms against 3.6 ms for the
    /// grapheme-by-grapheme version on the same 64,359-character transcript, and this runs from a
    /// view body. The consequence is that only ASCII space, tab, CR and LF end a word here, so a
    /// transcript joined by non-breaking spaces would come back as one block — the slow layout, not
    /// a wrong one. No speech model in this app has been observed to emit one.
    static func blocks(_ text: String, targetWords: Int) -> [String] {
        guard targetWords > 0, !text.isEmpty else { return text.isEmpty ? [] : [text] }

        let bytes = text.utf8
        var blocks: [String] = []
        var blockStart = bytes.startIndex
        var index = bytes.startIndex
        var words = 0

        while index < bytes.endIndex {
            guard !isSpace(bytes[index]) else {
                index = bytes.index(after: index)
                continue
            }
            // One word, remembering its last two bytes: the terminator may sit behind a closing
            // quote or bracket ( `…said." ` ), which is common in refined text.
            var last: UInt8 = 0
            var previous: UInt8 = 0
            while index < bytes.endIndex, !isSpace(bytes[index]) {
                previous = last
                last = bytes[index]
                index = bytes.index(after: index)
            }
            let wordEnd = index
            words += 1

            let endsSentence = sentenceEnders.contains(last)
                || (closers.contains(last) && sentenceEnders.contains(previous))
            let cut = (words >= targetWords && endsSentence) || words >= targetWords * 2
            guard cut, wordEnd < bytes.endIndex else { continue }

            blocks.append(String(text[blockStart..<wordEnd]))
            var next = wordEnd
            while next < bytes.endIndex, isSpace(bytes[next]) { next = bytes.index(after: next) }
            blockStart = next
            index = next
            words = 0
        }

        if blockStart < bytes.endIndex { blocks.append(String(text[blockStart...])) }
        return blocks
    }

    /// `.` `!` `?` `:` `;` — the last two because a transcribed list ("three things: one, two")
    /// breaks as readably there as at a full stop.
    private static let sentenceEnders: Set<UInt8> = [0x2E, 0x21, 0x3F, 0x3A, 0x3B]
    /// `"` `'` `)` `]`, the closers a terminator can hide behind.
    private static let closers: Set<UInt8> = [0x22, 0x27, 0x29, 0x5D]

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    }
}

// MARK: - CorrectionLine

/// One fired rule. The arrow is `D.color.selectionStroke` — the amber *selection* family, not
/// `D.color.alert`: the dictionary working is the feature, not a warning (composition invariant 3).
private struct CorrectionLine: View {

    let hit: CorrectionHit
    let entry: DictionaryEntry?

    var body: some View {
        HStack(spacing: D.space.xs) {
            Text("\u{201C}\(hit.from)\u{201D}")
                .foregroundStyle(D.color.textSecondary)
            Text("\u{2192}")
                .foregroundStyle(D.color.selectionStroke)
            Text("\u{201C}\(hit.to)\u{201D}")
                .foregroundStyle(D.color.textPrimary)
            Spacer(minLength: D.space.xs)
            if let entry, entry.hitCount > 0 {
                SegmentCounter(.count(entry.hitCount, unit: "hit"), scale: .tiny, seated: false)
            }
        }
        .typeStyle(D.type.mono)
        .lineLimit(1)
        .padding(.horizontal, D.space.rowInset)
        .frame(height: D.size.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(hit.from) became \(hit.to)")
    }
}

// MARK: - Render fixtures

/// Sheets for the offscreen renderer, covering the three things this pass changed: the login-item
/// switch in every state it can reach, a history row whose text never landed together with its
/// recovery block, and a control caught mid-report.
///
/// A parallel of `PreviewFixtures` rather than an addition to it, for the same reason
/// `DualLocaleFixtures` and `ImportPreviewFixtures` are: `MainWindow.swift` — where `PreviewFixtures`
/// lives — is not this agent's file to edit.
@MainActor
public enum RecoveryFixtures {

    /// A login-item service pinned to one status, so a sheet can show a state that cannot be produced
    /// on demand. `.requiresApproval` in particular: on this machine `register()` goes straight to
    /// `.enabled` (verified with a signed probe bundle in `/Applications`), so the approval path can
    /// only be *seen* through a stub — and it is the state most worth seeing, since it is the one where
    /// a naive implementation would claim the login item was on.
    public struct FixedLoginItemService: LoginItemService {
        public let status: SMAppService.Status
        public init(status: SMAppService.Status) { self.status = status }
        public func register() throws {}
        public func unregister() throws {}
    }

    static func model(loginItemStatus: SMAppService.Status) -> AppModel {
        AppModel(
            settings: Settings(defaults: EphemeralDefaults()),
            dictionary: PreviewFixtures.model().dictionary,
            history: PreviewFixtures.model().history,
            loginItem: LoginItem(service: FixedLoginItemService(status: loginItemStatus))
        )
    }

    /// A model with a bundle-less launch, where the switch is inapplicable rather than off.
    static func unavailableModel() -> AppModel {
        AppModel(
            settings: Settings(defaults: EphemeralDefaults()),
            loginItem: LoginItem(service: nil)
        )
    }

    /// First run: an empty log, which is the pane the app opens on.
    ///
    /// Worth a sheet of its own because the empty tray cannot be seen any other way — RECON §40
    /// forbids photographing the running app from an automated run, and the state disappears the
    /// moment the developer dictates anything. `EphemeralDefaults` means the settings are the shipped
    /// defaults, so all four gesture lines print: Right Option, ⇧ for Indonesian, the refine chord
    /// and the drop hint.
    static func emptyLogModel() -> AppModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-render-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = AppModel(
            settings: Settings(defaults: EphemeralDefaults()),
            history: HistoryStore(fileURL: dir.appendingPathComponent("history.json"), limit: { 100 }),
            loginItem: LoginItem(service: nil)
        )
        // Nothing installs speech assets in a render run, and the second-language line is gated on
        // them the same way `AppModel.statusLine` gates its own — so without this the sheet would
        // prove a three-line panel that a real first run shows with four.
        model.apply(secondaryLocaleReady: true)
        return model
    }

    /// A history holding the real failure from the brief: four words that Ghostty provably did not
    /// take, left on the clipboard.
    static func failedInjectionModel(retried: Bool = false) -> AppModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-render-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let history = HistoryStore(fileURL: dir.appendingPathComponent("history.json"), limit: { 100 })

        let failed = Transcript(
            createdAt: Date(timeIntervalSinceNow: -60),
            rawText: "run the migration now",
            text: "run the migration now",
            audioDuration: 2.1,
            transcribeDuration: 0.18,
            targetBundleID: "com.mitchellh.ghostty",
            targetAppName: "Ghostty",
            injection: .clipboardOnly,
            lowConfidenceWords: ["migration"]
        )
        history.append(Transcript(
            createdAt: Date(timeIntervalSinceNow: -20),
            rawText: "that one landed fine",
            text: "that one landed fine",
            audioDuration: 1.6,
            transcribeDuration: 0.14,
            targetBundleID: "com.apple.TextEdit",
            targetAppName: "TextEdit",
            injection: .accessibility
        ))
        history.append(failed)

        let model = AppModel(
            settings: Settings(defaults: EphemeralDefaults()),
            history: history,
            loginItem: LoginItem(service: nil)
        )
        if retried { model.recordRetryForRender(failed.id, outcome: .paste, appName: "Ghostty") }
        model.noteForegroundAppForRender(name: "Ghostty", bundleID: "com.mitchellh.ghostty")
        return model
    }

    public static func renderSheets() -> [PreviewFixtures.RenderSheet] {
        let switchSize = CGSize(width: 560, height: 210)
        let pane = CGSize(width: D.size.windowMin.width - D.size.railWidth, height: 620)
        let keys = CGSize(width: 620, height: 110)

        func sheet(_ id: String, _ size: CGSize, _ view: some View) -> PreviewFixtures.RenderSheet {
            PreviewFixtures.RenderSheet(
                id: id,
                size: size,
                view: AnyView(
                    view
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .background(D.surface.deckPaint)
                )
            )
        }

        func switchPanel(_ model: AppModel) -> some View {
            PanelSurface("Behaviour") { LoginItemRow(loginItem: model.loginItem) }
                .padding(D.space.md)
        }

        func historyPane(_ model: AppModel, selecting id: UUID?) -> some View {
            HistoryPane(model: model, initialSelection: id, unbounded: true)
        }

        let failed = failedInjectionModel()
        let failedID = failed.history.transcripts.first { $0.injection.needsRecovery }?.id
        let retried = failedInjectionModel(retried: true)
        let retriedID = retried.history.transcripts.first { $0.injection.needsRecovery }?.id

        return [
            sheet("login-off", switchSize, switchPanel(model(loginItemStatus: .notRegistered))),
            sheet("login-on", switchSize, switchPanel(model(loginItemStatus: .enabled))),
            sheet("login-approval", switchSize, switchPanel(model(loginItemStatus: .requiresApproval))),
            sheet("login-unavailable", switchSize, switchPanel(unavailableModel())),
            sheet("history-failed", pane, historyPane(failed, selecting: failedID)),
            sheet("history-retried", pane, historyPane(retried, selecting: retriedID)),
            sheet("history-collapsed", pane, historyPane(failedInjectionModel(), selecting: nil)),
            sheet("history-empty", pane, historyPane(emptyLogModel(), selecting: nil)),
            sheet("reports", keys, reportBank()),
        ]
    }

    /// Keys frozen mid-report. `ReportingButton` shows a report handed to it at construction, so the
    /// dwell can be photographed rather than described.
    static func reportBank() -> some View {
        PanelSurface("Mid-report") {
            HStack(spacing: D.space.md) {
                ReportingButton("Restart", template: "Still dead", report: .done("Live")) { nil }
                ReportingButton("Restart", template: "Still dead", report: .failed("Still dead")) { nil }
                ReportingButton("Clear log", template: "9999 erased", report: .done("42 erased")) { nil }
                Spacer(minLength: 0)
            }
        }
        .padding(D.space.md)
    }
}

// MARK: - Previews

#Preview("History — light") {
    HistoryPane(model: PreviewFixtures.model())
        .frame(width: 720, height: 620)
        .background(D.surface.deckPaint)
}

#Preview("History — dark") {
    HistoryPane(model: PreviewFixtures.model())
        .frame(width: 720, height: 620)
        .background(D.surface.deckPaint)
        .preferredColorScheme(.dark)
}
