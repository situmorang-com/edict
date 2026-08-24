import AppKit
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

    init(model: AppModel, initialSelection: UUID? = nil) {
        self.model = model
        self._selection = State(initialValue: initialSelection)
    }

    @State private var query = ""
    @State private var selection: UUID?
    @State private var armedClear = false
    @State private var draft: EntryDraft?
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
            DictionaryEntrySheet(store: model.dictionary, draft: draft) { self.draft = nil }
        }
        .animation(D.motion.panel, value: selection)
        .task(id: armedClear) {
            guard armedClear else { return }
            try? await Task.sleep(for: Self.clearArmWindow)
            if !Task.isCancelled { armedClear = false }
        }
    }

    private func detail(for transcript: Transcript) -> some View {
        TranscriptDetail(
            transcript: transcript,
            dictionary: model.dictionary,
            // Half the pane: enough for the whole comparison in the common case, never enough to
            // squeeze the log tray below its four-row floor.
            contentCap: paneHeight * 0.5,
            onDelete: { delete(transcript.id) },
            onSuggest: { word in
                draft = EntryDraft(isCorrection: true, heard: word)
            }
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
            TapeButton(
                armedClear ? "Confirm" : "Clear log",
                isLatched: armedClear,
                minWidth: D.size.buttonHeight * 3
            ) {
                if armedClear {
                    model.history.removeAll()
                    selection = nil
                    armedClear = false
                } else {
                    armedClear = true
                }
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
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { transcript in
                            TranscriptRow(
                                transcript,
                                isSelected: selection == transcript.id,
                                onCopy: { ViewClipboard.put(transcript.text) }
                            )
                            // Not a `Button` wrapper: the row already contains one (the copy key),
                            // and nesting buttons swallows the inner key's hits.
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selection = (selection == transcript.id) ? nil : transcript.id
                            }
                            .contextMenu {
                                Button("Copy") { ViewClipboard.put(transcript.text) }
                                Button("Delete") { delete(transcript.id) }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minHeight: D.size.rowHeight * 4, maxHeight: .infinity)
    }

    // MARK: Data

    private var rows: [Transcript] { model.history.search(query) }

    private var selected: Transcript? {
        guard let selection else { return nil }
        return model.history.transcripts.first { $0.id == selection }
    }

    private func delete(_ id: UUID) {
        model.history.remove(ids: [id])
        if selection == id { selection = nil }
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
    let onDelete: () -> Void
    let onSuggest: (String) -> Void

    /// The content's ideal height. A vertical `ScrollView` proposes nil in its scroll axis, so the
    /// content inside it lays out at its natural size and this measures that.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        PanelSurface("Transcript") {
            // A *definite* height: given only a maximum a `ScrollView` is greedy and eats the log
            // tray, and given an ideal proposal it measures as zero and disappears entirely.
            ScrollView {
                VStack(alignment: .leading, spacing: D.space.md) {
                    header
                    if transcript.mayBeIncomplete { incompleteNotice }
                    textBlock(label: "Inserted", body: transcript.text)
                    if transcript.didCorrect {
                        textBlock(label: "As heard", body: transcript.rawText)
                        corrections
                    }
                    if !suggestions.isEmpty { lowConfidence }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, D.size.rowHeight * 2), contentCap))
        }
        // A fresh measurement per transcript: a stale height would size the new block for a frame.
        .id(transcript.id)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: D.space.md) {
            readout("Length", .duration(transcript.audioDuration))
            readout("Words", .count(transcript.wordCount, unit: "w"))
            readout("Latency", .count(Int((transcript.transcribeDuration * 1000).rounded()), unit: "ms"))

            VStack(alignment: .leading, spacing: D.space.xxs) {
                SilkscreenLabel("Inserted into", weight: .tiny)
                    .silkscreenDecorative()
                Text(target)
                    .typeStyle(D.type.caption)
                    .foregroundStyle(transcript.injection.isSuccess ? D.color.textPrimary : D.color.alert)
                    .lineLimit(1)
            }

            Spacer(minLength: D.space.sm)

            TapeButton("Copy") { ViewClipboard.put(transcript.text) }
            TapeButton("Delete", action: onDelete)
                .help("Deletes this recording of your speech. There is no undo.")
        }
    }

    private var target: String {
        let app = transcript.targetAppName ?? transcript.targetBundleID
        switch (app, transcript.injection) {
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
                        TapeButton("Teach") { onSuggest(word) }
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
