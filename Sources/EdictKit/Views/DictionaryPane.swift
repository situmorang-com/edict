import AppKit
import SwiftUI

// MARK: - Column metrics

/// Column geometry for the dictionary table. Same rule as `Components.swift`'s private `M`:
/// anything with a token uses the token, and what is left is this table's own proportions,
/// written as multiples of the tokens they relate to so a token change carries through.
private enum C {
    static let colKind = D.size.iconButton * 1.6          // 35.2 — fits "COR"
    static let colHits = D.size.iconButton * 2.4          // 52.8 — fits "128 HIT"
    static let colState = D.size.iconButton               // 22
    static let colArrow: CGFloat = D.space.md             // 12
    static let colTextMin = D.size.railWidth * 0.7        // 120.4
    /// Below this the replacement column folds into the term column's line.
    static let wideTable = D.size.windowMin.width * 0.62  // 558
}

// MARK: - EntryDraft

/// What the add/edit sheet is editing. A value, so presenting the sheet is a single state write and
/// the sheet itself owns no reference to the pane.
struct EntryDraft: Identifiable, Hashable {
    var id = UUID()
    /// nil for a new entry.
    var existing: DictionaryEntry?
    var isCorrection: Bool
    var term: String = ""
    var heard: String = ""
    var write: String = ""
    var note: String = ""
    var enabled: Bool = true

    init(isCorrection: Bool, heard: String = "", write: String = "", term: String = "") {
        self.existing = nil
        self.isCorrection = isCorrection
        self.heard = heard
        self.write = write
        self.term = term
    }

    init(editing entry: DictionaryEntry) {
        self.existing = entry
        self.note = entry.note ?? ""
        self.enabled = entry.enabled
        switch entry.kind {
        case .term(let t):
            self.isCorrection = false
            self.term = t
        case .correction(let heard, let write):
            self.isCorrection = true
            self.heard = heard
            self.write = write
        }
    }

    /// The kind the draft would save as, so `assessRisk` can be asked *before* saving.
    var kind: DictionaryEntry.Kind {
        isCorrection
            ? .correction(heard: heard.trimmingCharacters(in: .whitespacesAndNewlines),
                          write: write.trimmingCharacters(in: .whitespacesAndNewlines))
            : .term(term.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var isSavable: Bool {
        if isCorrection {
            return !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !write.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - DictionaryPane

/// The user dictionary: layer 1 (terms fed to the analyzer as contextual strings) and layer 2
/// (guaranteed find-and-replace) in one table.
///
/// Two things here are load-bearing rather than decorative. The **hit count** makes a dead rule
/// visible — a rule that has never fired is either wrong or unnecessary, and without the counter the
/// list only ever grows. The **file path** is shown because `dictionary.json` is a documented plain
/// file the user is invited to edit, and a store that watches the file for external edits should say
/// so out loud.
struct DictionaryPane: View {

    let model: AppModel

    init(model: AppModel, initialSelection: UUID? = nil) {
        self.model = model
        self._selection = State(initialValue: initialSelection)
    }

    @State private var query = ""
    @State private var selection: UUID?
    @State private var draft: EntryDraft?
    @State private var measuredWidth: CGFloat = .greatestFiniteMagnitude

    var body: some View {
        VStack(alignment: .leading, spacing: D.space.md) {
            controls
            table
            fileFooter
        }
        .padding(D.space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $draft) { draft in
            DictionaryEntrySheet(store: model.dictionary, draft: draft) { self.draft = nil }
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: D.space.md) {
            EquipmentSearchField(legend: "Find", text: $query, resultCount: rows.count)
                // See `HistoryPane`: an unconstrained field steals the table's height.
                .frame(height: D.size.rowHeight)

            Spacer(minLength: D.space.sm)

            TapeButton("Add") { draft = EntryDraft(isCorrection: false) }

            TapeButton("Edit") {
                if let entry = selected { draft = EntryDraft(editing: entry) }
            }
            .disabled(selected == nil)

            // One click, no arming: a deleted rule is a rule, and it is one line of JSON to put
            // back. The two-stage key is reserved for erasing the user's own speech.
            TapeButton("Delete") {
                guard let id = selection else { return }
                model.dictionary.remove(ids: [id])
                selection = nil
            }
            .disabled(selected == nil)
        }
    }

    // MARK: Table

    private var table: some View {
        PanelSurface("Terms", inset: D.space.wellInset) {
            VStack(alignment: .leading, spacing: D.space.labelGap) {
                headerRow
                RecessedWell(fill: .list, inset: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { entry in
                                DictionaryRow(
                                    entry: entry,
                                    isSelected: selection == entry.id,
                                    showsReplacement: showsReplacement
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selection = (selection == entry.id) ? nil : entry.id
                                }
                                .simultaneousGesture(TapGesture(count: 2).onEnded {
                                    draft = EntryDraft(editing: entry)
                                })
                                .contextMenu {
                                    Button("Edit") { draft = EntryDraft(editing: entry) }
                                    Button(entry.enabled ? "Disable" : "Enable") { toggle(entry) }
                                    Button("Delete") { model.dictionary.remove(ids: [entry.id]) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
    }

    /// Silkscreened column legends, printed on the panel above the well rather than inside it — a
    /// header row *inside* the tray would read as a first row of data.
    private var headerRow: some View {
        HStack(spacing: D.space.sm) {
            SilkscreenLabel("Kind", weight: .tiny).frame(width: C.colKind, alignment: .leading)
            SilkscreenLabel("Heard", weight: .tiny)
                .frame(minWidth: C.colTextMin, maxWidth: .infinity, alignment: .leading)
            if showsReplacement {
                Spacer().frame(width: C.colArrow)
                SilkscreenLabel("Writes", weight: .tiny)
                    .frame(minWidth: C.colTextMin, maxWidth: .infinity, alignment: .leading)
            }
            SilkscreenLabel("Hits", weight: .tiny).frame(width: C.colHits, alignment: .trailing)
            SilkscreenLabel("On", weight: .tiny).frame(width: C.colState, alignment: .trailing)
        }
        .silkscreenDecorative()
        .padding(.horizontal, D.space.rowInset)
    }

    private var showsReplacement: Bool { measuredWidth >= C.wideTable }

    // MARK: File footer

    /// `dictionary.json` is a documented interface, not an implementation detail: the store watches
    /// it and reloads on external edits, so the path belongs on screen.
    private var fileFooter: some View {
        PanelSurface("File") {
            VStack(alignment: .leading, spacing: D.space.sm) {
                HStack(spacing: D.space.md) {
                    RecessedWell(fill: .list) {
                        Text(model.dictionary.fileURL.path)
                            .typeStyle(D.type.mono)
                            .foregroundStyle(D.color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    TapeButton("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.dictionary.fileURL])
                    }
                }
                loadNotice
            }
        }
    }

    /// What actually happened to `dictionary.json` at launch, in the store's own words.
    ///
    /// On its own row, wrapping, with no line limit. It was a third column in the `HStack` above at
    /// `.lineLimit(2)`, and caption size in a third of a footer's width truncates a recovery message
    /// well before its end — which is precisely where the load-bearing part is: "Recovered 11 entries
    /// from the backup. The unreadable file is kept as dictionary.unreadable-20260830T101500Z.json."
    /// A message whose only useful half is cut off is the same silence as no message.
    ///
    /// `recoveredEntryCount` rather than a substring match, so the store can reword freely.
    @ViewBuilder private var loadNotice: some View {
        if let message = model.dictionary.lastLoadError {
            let recovered = model.dictionary.recoveredEntryCount
            HStack(alignment: .top, spacing: D.space.md) {
                Text(message)
                    .typeStyle(D.type.caption)
                    // Red is for a load that produced nothing. A recovery is news, not a fault: the
                    // terms in the table above it are real.
                    .foregroundStyle(recovered == nil ? D.color.alert : D.color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Naming a timestamped quarantine file without a way to reach it would leave the user
                // retyping it into a Finder search. Absent when the move failed: there is nothing to
                // reveal, and the message says where the bytes actually are.
                if let quarantined = model.dictionary.quarantinedFileURL {
                    TapeButton("Kept file") {
                        NSWorkspace.shared.activateFileViewerSelecting([quarantined])
                    }
                    .help("Shows \(quarantined.lastPathComponent) in the Finder.")
                    .accessibilityLabel("Show the quarantined dictionary file in the Finder")
                }
            }
        }
    }

    // MARK: Data

    private var rows: [DictionaryEntry] { model.dictionary.search(query) }

    private var selected: DictionaryEntry? {
        guard let selection else { return nil }
        return model.dictionary.entries.first { $0.id == selection }
    }

    private func toggle(_ entry: DictionaryEntry) {
        var copy = entry
        copy.enabled.toggle()
        model.dictionary.update(copy)
    }
}

// MARK: - DictionaryRow

/// One rule. Deliberately the same physical read as `TranscriptRow`: fixed columns, `D.size.rowHeight`
/// tall in every state, no separators, no banding, and a full-width square-ended selection band.
private struct DictionaryRow: View {

    let entry: DictionaryEntry
    let isSelected: Bool
    let showsReplacement: Bool

    @Environment(\.edictIncreasedContrast) private var increasedContrast
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: D.space.sm) {
            Text(entry.isCorrection ? "Cor" : "Trm")
                .typeStyle(D.type.silkscreenTiny)
                .foregroundStyle(secondaryInk)
                .frame(width: C.colKind, alignment: .leading)

            Text(entry.displayTerm)
                .typeStyle(D.type.body)
                .foregroundStyle(primaryInk)
                .lineLimit(1)
                .truncationMode(.tail)
                // The two text columns share the slack, so the hit count and the on/off tell-tale
                // stay pinned to the tray's trailing edge instead of floating mid-row.
                .frame(minWidth: C.colTextMin, maxWidth: .infinity, alignment: .leading)

            if showsReplacement {
                Text(entry.displayReplacement == nil ? "" : "\u{2192}")
                    .typeStyle(D.type.body)
                    .foregroundStyle(D.color.selectionStroke)
                    .frame(width: C.colArrow)
                Text(entry.displayReplacement ?? "\u{2014}")
                    .typeStyle(D.type.body)
                    .foregroundStyle(entry.displayReplacement == nil ? secondaryInk : primaryInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(minWidth: C.colTextMin, maxWidth: .infinity, alignment: .leading)
            }

            // A rule that has never fired is the one thing this table exists to make visible, so a
            // zero is printed in the alert ink (spec §10) rather than left to look like data.
            SegmentCounter(
                .count(entry.hitCount, unit: "hit"),
                scale: .tiny,
                seated: false,
                ink: hitInk
            )
            .frame(width: C.colHits, alignment: .trailing)

            // Shape, not colour: a filled square is on, a hollow one is off, matching the flag
            // vocabulary in `TranscriptRow`.
            Group {
                if entry.enabled {
                    Rectangle().fill(secondaryInk)
                } else {
                    Rectangle().strokeBorder(secondaryInk, lineWidth: D.border.hairline)
                }
            }
            .frame(width: D.space.sm, height: D.space.sm)
            .frame(width: C.colState, alignment: .trailing)
        }
        .padding(.horizontal, D.space.rowInset)
        .frame(height: D.size.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(entry.enabled ? 1 : D.opacity.disabled)
        .background(selectionBand)
        .overlay(hoverLift)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .help(entry.note ?? spokenLabel)
    }

    @ViewBuilder
    private var selectionBand: some View {
        if isSelected {
            D.color.selectionFill
                .overlay(alignment: .top) { rule }
                .overlay(alignment: .bottom) { rule }
        }
    }

    private var rule: some View {
        D.color.selectionStroke
            .frame(height: increasedContrast ? D.border.thin : D.border.hairline)
    }

    @ViewBuilder
    private var hoverLift: some View {
        if isHovering && !isSelected {
            D.color.highlightInner
                .opacity(increasedContrast ? D.opacity.halo * 2 : D.opacity.halo)
                .allowsHitTesting(false)
        }
    }

    private var primaryInk: Color { isSelected ? D.color.selectionText : D.color.textPrimary }

    private var secondaryInk: Color {
        isSelected
            ? D.color.selectionText.opacity(increasedContrast ? 1 : D.opacity.ghost)
            : D.color.textSecondary
    }

    private var hitInk: Color {
        if isSelected { return D.color.selectionText }
        return entry.hitCount == 0 ? D.color.alert : D.color.textSecondary
    }

    private var spokenLabel: String {
        let state = entry.enabled ? "" : ", disabled"
        let hits = entry.hitCount == 1 ? "1 hit" : "\(entry.hitCount) hits"
        if let replacement = entry.displayReplacement {
            return "Correction, \(entry.displayTerm) becomes \(replacement), \(hits)\(state)"
        }
        return "Term, \(entry.displayTerm), \(hits)\(state)"
    }
}

// MARK: - DictionaryEntrySheet

/// Add or edit one rule. The risk assessment is shown **before** saving, because layer 2 is
/// unconditional: a `heard` of "cloud" rewrites the word "cloud" in every sentence the user ever
/// dictates, and finding that out afterwards means going back through the history to work out what
/// happened.
struct DictionaryEntrySheet: View {

    let store: DictionaryStore
    let onClose: () -> Void

    @State private var draft: EntryDraft

    init(store: DictionaryStore, draft: EntryDraft, onClose: @escaping () -> Void) {
        self.store = store
        self.onClose = onClose
        self._draft = State(initialValue: draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: D.space.md) {
            SilkscreenLabel(draft.existing == nil ? "Add entry" : "Edit entry",
                            weight: .heading, ruled: true)

            kindSelector
            fields
            RockerSwitch("Enabled", isOn: $draft.enabled,
                         caption: "A disabled entry is kept but neither biased nor replaced.")
            risk
            filePath

            HStack(spacing: D.space.sm) {
                Spacer(minLength: D.space.sm)
                TapeButton("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                TapeButton("Save", action: save)
                    .disabled(!draft.isSavable)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(D.space.md)
        .frame(width: D.size.windowMin.width / 2)
        .background(D.surface.deckPaint)
    }

    // MARK: Kind

    /// Two latching caps, not a `Picker`: the two kinds do genuinely different things, and a popup
    /// menu hides the one the user needs to understand.
    private var kindSelector: some View {
        VStack(alignment: .leading, spacing: D.space.labelGap) {
            SilkscreenLabel("Kind", weight: .tiny).silkscreenDecorative()
            HStack(spacing: D.space.sm) {
                kindKey("Term", isCorrection: false)
                kindKey("Correction", isCorrection: true)
                Spacer(minLength: 0)
            }
            Text(draft.isCorrection
                 ? "When Edict hears the first phrase, it writes the second. Always, exactly."
                 : "Fed to the speech model as a hint so it hears the word correctly in the first place.")
                .typeStyle(D.type.explain)
                .foregroundStyle(D.color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kind")
    }

    private func kindKey(_ legend: String, isCorrection: Bool) -> some View {
        TapeButton(legend, isLatched: draft.isCorrection == isCorrection) {
            draft.isCorrection = isCorrection
        }
        .accessibilityAddTraits(draft.isCorrection == isCorrection ? .isSelected : [])
    }

    // MARK: Fields

    @ViewBuilder
    private var fields: some View {
        if draft.isCorrection {
            FieldWell(legend: "Heard", text: $draft.heard)
            FieldWell(legend: "Writes", text: $draft.write)
        } else {
            FieldWell(legend: "Term", text: $draft.term)
        }
        FieldWell(legend: "Note", text: $draft.note)
    }

    // MARK: Risk

    @ViewBuilder
    private var risk: some View {
        let assessment = DictionaryStore.assessRisk(for: draft.kind)
        if let message = assessment.message {
            HStack(alignment: .top, spacing: D.space.sm) {
                Rectangle()
                    .strokeBorder(riskInk(assessment.level), lineWidth: D.border.thin)
                    .frame(width: D.size.troughHeight, height: D.size.troughHeight)
                    .padding(.top, D.space.xxs)
                Text(message)
                    .typeStyle(D.type.explain)
                    .foregroundStyle(riskInk(assessment.level))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(assessment.level == .warning ? "Warning. \(message)" : message)
        }
    }

    /// A notice is information, so it stays in the ink family; a warning is a fault, which is the
    /// one thing `D.color.alert` is for.
    private func riskInk(_ level: EntryRisk.Level) -> Color {
        level == .warning ? D.color.alert : D.color.textSecondary
    }

    /// Two lines, not one: a path spliced into a sentence truncates in the middle and eats the
    /// half of the sentence that says what the file *is*.
    private var filePath: some View {
        VStack(alignment: .leading, spacing: D.space.xxs) {
            Text("Saved to a plain JSON file you can edit by hand.")
                .typeStyle(D.type.explain)
            Text(store.fileURL.path)
                .typeStyle(D.type.mono)
                .lineLimit(1)
                // Head, so the filename — the part that identifies it — always survives.
                .truncationMode(.head)
        }
        .foregroundStyle(D.color.textSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Save

    private func save() {
        let note = draft.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if var entry = draft.existing {
            // id, createdAt and hitCount are preserved: editing a rule's text must not reset the
            // evidence that it has been working.
            entry.kind = draft.kind
            entry.note = note.isEmpty ? nil : note
            entry.enabled = draft.enabled
            store.update(entry)
        } else {
            store.add(DictionaryEntry(
                kind: draft.kind,
                enabled: draft.enabled,
                note: note.isEmpty ? nil : note
            ))
        }
        onClose()
    }
}

// MARK: - FieldWell

/// A labelled text slot: a silkscreened legend over a channel cut into the panel.
///
/// `EquipmentSearchField` is the design system's only field, and it is a *search* field — it prints
/// a hardcoded "SEARCH" placeholder and a match count, both wrong for an editor. Rather than inline
/// a bespoke bezel this uses the same two primitives the search field is built from
/// (`RecessedWell(fill: .list)` plus `SilkscreenLabel`) and nothing but tokens, so the two fields
/// are the same object. A general `EquipmentField` in `Components.swift` should replace it.
private struct FieldWell: View {

    let legend: String
    @Binding var text: String

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: D.space.labelGap) {
            SilkscreenLabel(legend, weight: .tiny)
                .silkscreenDecorative()
            RecessedWell(fill: .list, inset: 0) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    // Without this the system paints its blue ring inside the machined channel.
                    .focusEffectDisabled()
                    .focused($isFocused)
                    .typeStyle(D.type.body)
                    .foregroundStyle(D.color.textPrimary)
                    .padding(.horizontal, D.space.sm)
                    .frame(minHeight: D.size.rowHeight)
            }
            .focusRing(isFocused, radius: D.radius.well)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(legend)
    }
}

// Gated with the fixture enums these previews use. `PreviewFixtures` is `#if DEBUG` because it is
// `public` for an out-of-tree render harness and therefore cannot be dead-stripped; a `#Preview` that
// references it has to be gated too, or the file stops compiling in release. This file was one of the
// two the audit's list of affected files missed — the release build found them, which is why the
// release build is now part of finishing this change.
#if DEBUG
// MARK: - Previews

#Preview("Dictionary — light") {
    DictionaryPane(model: PreviewFixtures.model())
        .frame(width: 720, height: 620)
        .background(D.surface.deckPaint)
}

#Preview("Dictionary — dark") {
    DictionaryPane(model: PreviewFixtures.model())
        .frame(width: 720, height: 620)
        .background(D.surface.deckPaint)
        .preferredColorScheme(.dark)
}

#Preview("Add entry sheet") {
    DictionaryEntrySheet(
        store: PreviewFixtures.model().dictionary,
        draft: EntryDraft(isCorrection: true, heard: "cloud", write: "Claude")
    ) {}
}
#endif
