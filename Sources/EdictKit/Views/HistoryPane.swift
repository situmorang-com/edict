import AppKit
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
        VStack(alignment: .leading, spacing: D.space.md) {
            controls
            table
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

    private var controls: some View {
        HStack(spacing: D.space.md) {
            EquipmentSearchField(legend: "Find", text: $query, resultCount: rows.count)
                // `TextField` has no maximum height, so the channel would otherwise absorb the
                // slack the log tray is supposed to get.
                .frame(height: D.size.rowHeight)

            Spacer(minLength: D.space.sm)

            if model.history.lastLoadError != nil {
                Text("history.json could not be read")
                    .typeStyle(D.type.caption)
                    .foregroundStyle(D.color.alert)
            }

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

    // MARK: Table

    private var table: some View {
        PanelSurface("Log", inset: D.space.wellInset) {
            RecessedWell(fill: .list, inset: 0) {
                MaybeScroll(scrolls: !unbounded) {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { transcript in
                            TranscriptRow(
                                transcript,
                                isSelected: selection == transcript.id,
                                onCopy: { ViewClipboard.put(transcript.text) },
                                outcome: model.displayOutcome(for: transcript),
                                isRetrying: model.retryingTranscriptID == transcript.id,
                                localeIsAmbiguous: ambiguousLocales.contains(
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
        }
        .frame(minHeight: D.size.rowHeight * 4, maxHeight: .infinity)
    }

    // MARK: Data

    private var rows: [Transcript] { model.history.search(query) }

    /// Two-letter badges that more than one language in this log would print.
    ///
    /// A row sees one transcript and so cannot know that `en-US` and `en-GB` are both here; only the
    /// pane can. Without this the language column would print `EN` for both — a column that indicates
    /// nothing while looking like it works, which is the same class of failure the column was added to
    /// prevent. Computed over the *filtered* rows, because that is what is on screen: a badge is only
    /// ambiguous against something the reader can also see.
    private var ambiguousLocales: Set<String> {
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

    var body: some View {
        PanelSurface("Transcript") {
            // A *definite* height: given only a maximum a `ScrollView` is greedy and eats the log
            // tray, and given an ideal proposal it measures as zero and disappears entirely.
            MaybeScroll(scrolls: !unbounded) {
                VStack(alignment: .leading, spacing: D.space.md) {
                    header
                    if transcript.mayBeIncomplete { incompleteNotice }
                    // Above the transcript, not below it: the point is to be read *before* the text
                    // is trusted. Renders to nothing when the recognition rate was plausible.
                    QualityNotice(transcript.quality)
                    if outcome.needsRecovery { recovery }
                    textBlock(label: transcriptLabel, body: transcript.text)
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
                        textBlock(label: "As heard", body: transcript.rawText)
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

    private var header: some View {
        HStack(alignment: .center, spacing: D.space.md) {
            readout("Length", .duration(transcript.audioDuration))
            readout("Words", .count(transcript.wordCount, unit: "w"))
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
            TranscriptExportKeys(transcript)
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

    private func textBlock(label: String, body text: String) -> some View {
        VStack(alignment: .leading, spacing: D.space.labelGap) {
            SilkscreenLabel(label, weight: .tiny)
                .silkscreenDecorative()
            RecessedWell(fill: .list) {
                Text(text.isEmpty ? "—" : text)
                    .typeStyle(D.type.body)
                    .foregroundStyle(D.color.textPrimary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityValue(text)
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
