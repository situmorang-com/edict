//
//  ImportPane.swift
//  EdictKit — Views
//
//  The IMPORT rail stop: a batch queue of files being transcribed into history, an OPEN FILE key,
//  and one plainly-worded panel saying what Edict cannot do (tell speakers apart).
//
//  The pane is *pure*: it takes rows and closures, never a store. Two reasons. The queue lives in
//  the engine layer, and a view that reaches into it would make the three states that matter here
//  — empty, mid-transcription, failed — impossible to render offline, which is exactly how a
//  progress UI ends up shipping untested.
//

import AppKit
import SwiftUI

// MARK: - Metrics

/// Geometry belonging to this pane, written as multiples of tokens.
private enum M {
    /// `AUD` / `VID`, wide enough for either at `silkscreenTiny`.
    static let colKind: CGFloat = 26
    /// Matches `TranscriptRow`'s duration column so the two tables share one rhythm.
    static let colDuration: CGFloat = 44
    /// The state channel. Sized on "Transcribing", the longest legend, exactly as
    /// `StatusReadout` reserves its own width.
    static let colState: CGFloat = 92
    /// The percentage readout.
    static let colProgress: CGFloat = 34
    /// The language channel. Wide enough for a two-language pair of full tags at
    /// `D.type.silkscreenTiny` (`en-GB\u{2192}en-US`) so the column never shifts when a row turns out
    /// to need the disambiguated form — the row that needs it is the row being checked, and a grid
    /// that jumps at exactly that moment is a grid that hides the answer.
    static let colLocale: CGFloat = 84
    /// Three three-letter export keys side by side, which is the widest the trailing bank gets.
    static let colKeys = D.size.buttonHeight * 3 + D.space.sm            // 98
    /// The language tray inside a row's popover. Shorter than Settings' seven rows: a popover hanging
    /// off a table row must not cover the rows it is there to be compared against.
    static let popoverTrayRows: CGFloat = 6
    /// The tray key inside a popover, and so the popover's own working width.
    static let popoverTrayKeyWidth: CGFloat = 236
    /// A three-letter moulded legend (`TXT`) needs far less than a transport key's default width.
    static let keyWidth = D.size.buttonHeight                            // 30
    /// The creeping rule under a state channel. `StatusReadout` uses 1.5 for the same job, but
    /// its channel is wider and its use is rare; at this width the render showed 1.5 losing the
    /// fight with the well's own bottom light-catch rim, so the bar is a full border weight.
    static let progressHeight = D.border.heavy                           // 3
    /// Floor on the queue tray, so an empty queue is still visibly a tray.
    static let trayMinRows: CGFloat = 5
    /// Ceiling on the tray when there is nothing in it.
    static let emptyTrayRows: CGFloat = 8
}

// MARK: - ImportQueueRow

/// One job in the import queue, as the pane needs to draw it.
///
/// A value type rather than a reference to the engine's own job object: the pane must be
/// renderable from a literal, and a `Sendable` snapshot is also what lets the queue live off the
/// main actor and publish frames of state.
///
/// `finished` carries the whole `Transcript` because the finished row offers export, and export
/// needs the segments. The engine has just written it to history, so nothing is copied that it did
/// not already hold.
public struct ImportQueueRow: Identifiable, Hashable, Sendable {

    public enum State: Hashable, Sendable {
        /// In the queue, not started. Only one job runs at a time — a second `SpeechAnalyzer`
        /// racing the first buys nothing on an on-device model and doubles peak memory.
        case waiting
        /// `AVAssetReader` is pulling samples. 0…1 through the file's duration.
        case reading(Double)
        /// Samples are in the analyzer and results are coming back. 0…1.
        case transcribing(Double)
        /// Done, and in history.
        case finished(Transcript)
        /// Terminal failure. The string is shown verbatim, so it must be a sentence a user can act
        /// on, not an `NSError` description.
        case failed(String)
        /// The user cancelled it.
        case cancelled

        /// Natural case; the silkscreen type style does the shouting (spec §0.2), which is also
        /// what stops VoiceOver spelling it out letter by letter.
        public var legend: String {
            switch self {
            case .waiting: "Waiting"
            case .reading: "Reading"
            case .transcribing: "Transcribing"
            case .finished: "Done"
            case .failed: "Failed"
            case .cancelled: "Cancelled"
            }
        }

        /// 0…1 while work is in flight, `nil` otherwise. Reading and transcribing are reported as
        /// one continuous sweep rather than two bars: the user is waiting for a transcript, not
        /// for a file read.
        public var progress: Double? {
            switch self {
            case .reading(let p), .transcribing(let p): min(max(p, 0), 1)
            case .waiting, .cancelled: nil
            case .finished: 1
            case .failed: nil
            }
        }

        /// True while the job can still be cancelled.
        public var isRunning: Bool {
            switch self {
            case .waiting, .reading, .transcribing: true
            case .finished, .failed, .cancelled: false
            }
        }

        /// True once the job will never change again — what CLEAR FINISHED removes.
        public var isTerminal: Bool { !isRunning }

        public var isFault: Bool {
            if case .failed = self { return true }
            return false
        }

        /// The sentence to print under the row, or `nil`.
        ///
        /// A finished row speaks up only when the recogniser plainly under-read the audio. That is
        /// the whole point of routing it through `RecognitionQuality.isConcerning` rather than
        /// printing a rate on every row: a line most rows carry is a line nobody reads, and the one
        /// recording that needed it would go past unremarked.
        public var detail: String? {
            switch self {
            case .failed(let reason): return reason
            case .finished(let transcript):
                guard let quality = transcript.quality, quality.isConcerning else { return nil }
                return quality.explanation
            case .waiting, .reading, .transcribing, .cancelled: return nil
            }
        }

        /// True when `detail` is a problem rather than an aside, so the row can pick its ink. A
        /// failure and an under-read both are; a truncated-but-real transcript (`warning`) is not.
        public var detailIsAlert: Bool {
            switch self {
            case .failed: true
            case .finished(let transcript): transcript.hasQualityConcern
            case .waiting, .reading, .transcribing, .cancelled: false
            }
        }

        public var transcript: Transcript? {
            if case .finished(let transcript) = self { return transcript }
            return nil
        }
    }

    public var id: UUID
    /// Last path component only. History never shows a full path and neither does the queue — a
    /// home directory is nobody's business, and the pane is screenshotted.
    public var filename: String
    /// The language this file will be transcribed in, or was.
    ///
    /// **On every row, in every state.** This is the half of the feature that actually prevents the
    /// failure RECON amendment 45 records: the same Indonesian audio came back as plausible English
    /// nonsense under `en-US`, and the user read 900 words of it before discovering the cause. A tag
    /// on the row would have caught it in a second, so the tag is never conditional — not hidden
    /// behind a hover, not shown only when it differs from the dictation language, not omitted while
    /// the row is still queued.
    public var localeIdentifier: String
    /// False when this language was inherited from the dictation language at enqueue time rather than
    /// picked for this file. Drives the cap's latch, never a colour: an inherited language is the one
    /// worth double-checking, not an error.
    public var localeWasChosen: Bool
    /// Whether the language can still be changed on this row. Mirrors `ImportQueue.Item`: a queued row
    /// can, a running or finished one cannot, because the analyzer is built from exactly one `Locale`
    /// and is never rebuilt (RECON §3). A finished row is offered a re-run instead.
    public var localeIsEditable: Bool
    /// The second language a dual pass will also try on this row, or `nil` for one pass in the row's
    /// own language — which is the common case. See `ImportQueue.dualPassRule`: the row's own language
    /// replaces the *first* pass, and this stays the configured second dictation language.
    public var secondPassLocaleIdentifier: String?
    /// True on a row produced by re-running an earlier one. Marked because the pair only means
    /// anything read together: the reason to re-run is that the first transcript looked plausible and
    /// wrong, and the comparison is the whole point.
    public var isRerun: Bool
    /// The asset's duration, or `nil` until it has been probed. A file that has not been opened
    /// yet genuinely has no known length, and printing `00:00` for it is a lie.
    public var duration: TimeInterval?
    /// Drives the `AUD` / `VID` tag. `AVAssetReader` opens both, which is the whole reason video
    /// came for free.
    public var isVideo: Bool
    public var state: State
    /// A neutral aside about the running job — "24 of 96 passes" for a dual pass. Never a warning,
    /// always in the secondary ink, and printed above `warning` so a real problem is never displaced
    /// by a progress note.
    public var note: String?
    /// Set when the transcript is real but the read stopped early. Printed under the row in the
    /// secondary ink, not the alert ink: nine minutes of a ten-minute transcript is a result worth
    /// keeping, and the user has to be told which it is.
    public var warning: String?

    public init(
        id: UUID = UUID(),
        filename: String,
        duration: TimeInterval? = nil,
        isVideo: Bool = false,
        state: State = .waiting,
        note: String? = nil,
        warning: String? = nil,
        localeIdentifier: String = Settings.Default.localeIdentifier,
        localeWasChosen: Bool = false,
        localeIsEditable: Bool = false,
        secondPassLocaleIdentifier: String? = nil,
        isRerun: Bool = false
    ) {
        self.id = id
        self.filename = filename
        self.duration = duration
        self.isVideo = isVideo
        self.state = state
        self.note = note
        self.warning = warning
        self.localeIdentifier = localeIdentifier
        self.localeWasChosen = localeWasChosen
        self.localeIsEditable = localeIsEditable
        self.secondPassLocaleIdentifier = secondPassLocaleIdentifier
        self.isRerun = isRerun
    }

    /// Natural case; genuine three-letter abbreviations are correct in caps for eye and screen
    /// reader alike.
    var kindTag: String { isVideo ? "VID" : "AUD" }

    /// The finished transcript's quality verdict, when it has one.
    var quality: RecognitionQuality? { state.transcript?.quality }

    /// True when a language re-run should be offered **prominently** rather than only from the
    /// language cell.
    ///
    /// Every finished row can be re-run from its language cell. This gates the extra, in-row key on
    /// `sparse` and `veryPoor` — which today is every concerning verdict, and is written as an
    /// explicit list rather than as `isConcerning` so a future verdict has to be considered rather
    /// than silently inheriting a button. Those are the verdicts where "the model barely recognised
    /// anything" and "the language was wrong" look identical on screen, which is when the second
    /// reading has to be offered rather than described. The key's own wording then refuses to promise
    /// that a language change rescues difficult audio, because measured on a real far-field
    /// multi-speaker meeting it does not: ~16 words per minute in *either* language.
    var offersLanguageRerun: Bool {
        guard case .finished = state, let quality else { return false }
        switch quality.verdict {
        case .sparse, .veryPoor: return true
        case .good: return false
        }
    }

    /// The one thing this offer must not do is imply that a different language rescues bad audio.
    ///
    /// Measured on a real far-field multi-speaker meeting, Apple's model recognised about 16 words a
    /// minute in **either** language, and conditioning the audio moved that only from 61 to 75 words.
    /// So the wording is specific about the case it does help with — the language was wrong — and says
    /// plainly that it is not a remedy for difficult audio. Over-promising here would cost the user
    /// another 70-minute wait for the same nonsense.
    public static let languageRerunExplanation = """
        Transcribes this file again in the language you pick, as a new row. The transcript you \
        already have is kept, so you can compare them. This helps when the language was wrong — an \
        English model transcribing Indonesian invents confident, plausible names rather than \
        failing. It will not rescue difficult audio: on a far-field recording of several people, \
        Edict recognised about the same handful of words per minute in either language.
        """
}

// MARK: - ImportPane

/// Files being turned into transcripts.
struct ImportPane: View {

    let rows: [ImportQueueRow]
    /// Every locale an import can run, in the queue's own display-name order. Empty until
    /// `ImportQueue.loadSupportedLocales()` has answered, which the tray renders as a sentence
    /// rather than as an empty box.
    let locales: [String]
    /// The dictation language, as Settings holds it. Named on the panel even when it is also the
    /// import language, because "follow my dictation language" is only a useful default if the user
    /// can see which language that currently is.
    let dictationLocaleIdentifier: String
    /// The language chosen for files added from now on, or `nil` to follow the dictation language.
    ///
    /// `nil` is the default and is a *different state* from "explicitly set to the same value as the
    /// dictation language": the first tracks Settings when the user changes it there, the second does
    /// not. The panel says which one is in force.
    let newFileLocaleIdentifier: String?
    /// The second language a dual pass will try, or `nil` when dual pass is off. Drives whether the
    /// panel explains `ImportQueue.dualPassRule` — a rule nobody needs to read while the feature is
    /// switched off.
    let dualPassLocaleIdentifier: String?
    /// Files the user picked or dropped, in order.
    let onEnqueue: ([URL]) -> Void
    /// Sets, or with `nil` clears, the language for files added from now on.
    let onSetNewFileLocale: (String?) -> Void
    /// Changes one not-yet-started row's language.
    let onSetRowLocale: (UUID, String) -> Void
    /// Transcribes a finished row's file again, in another language, as a new row.
    let onRerun: (UUID, String) -> Void
    /// Stops a running job. Terminal rows are removed with `onClearFinished` instead, so one key
    /// per row is enough.
    let onCancel: (UUID) -> Void
    let onRetry: (UUID) -> Void
    /// Removes every terminal row — finished, failed and cancelled alike.
    let onClearFinished: () -> Void
    /// Render-harness escape hatch, exactly as `HistoryPane.unbounded` and `SettingsWindow.unbounded`
    /// are: `ImageRenderer` does not rasterise a `ScrollView`'s contents, so a queue proved offline
    /// has to be drawn without one. RECON amendment 40 — Screen Recording is denied to any process an
    /// agent starts — makes rendered sheets the only way this pane gets looked at before it ships.
    /// Never true in the app.
    var unbounded: Bool = false

    init(
        rows: [ImportQueueRow],
        locales: [String] = [],
        dictationLocaleIdentifier: String = Settings.Default.localeIdentifier,
        newFileLocaleIdentifier: String? = nil,
        dualPassLocaleIdentifier: String? = nil,
        onEnqueue: @escaping ([URL]) -> Void = { _ in },
        onSetNewFileLocale: @escaping (String?) -> Void = { _ in },
        onSetRowLocale: @escaping (UUID, String) -> Void = { _, _ in },
        onRerun: @escaping (UUID, String) -> Void = { _, _ in },
        onCancel: @escaping (UUID) -> Void = { _ in },
        onRetry: @escaping (UUID) -> Void = { _ in },
        onClearFinished: @escaping () -> Void = {},
        unbounded: Bool = false
    ) {
        self.rows = rows
        self.locales = locales
        self.dictationLocaleIdentifier = dictationLocaleIdentifier
        self.newFileLocaleIdentifier = newFileLocaleIdentifier
        self.dualPassLocaleIdentifier = dualPassLocaleIdentifier
        self.onEnqueue = onEnqueue
        self.onSetNewFileLocale = onSetNewFileLocale
        self.onSetRowLocale = onSetRowLocale
        self.onRerun = onRerun
        self.onCancel = onCancel
        self.onRetry = onRetry
        self.onClearFinished = onClearFinished
        self.unbounded = unbounded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: D.space.md) {
            controls
            speakerNotice
            // Between the speaker notice and the queue on purpose. The notice claims to be "the
            // first thing" and still is; this sits directly above the rows whose language tags it
            // explains, which is the adjacency that makes the tags legible as a column.
            languagePanel
            queue
            if rows.isEmpty { Spacer(minLength: 0) }
        }
        .padding(D.space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(D.motion.panel, value: rows)
    }

    // MARK: Language

    /// The language files are transcribed in, and the fact that it is following the dictation setting.
    ///
    /// The default is "follow my dictation language, **and show me**" rather than "ask on every drop":
    /// a modal on every file gets annoying within a day and then gets dismissed without reading, which
    /// would reproduce the original failure with an extra click. So the choice is stated here, applied
    /// to what comes next, and printed on every row.
    private var languagePanel: some View {
        PanelSurface("Language") {
            VStack(alignment: .leading, spacing: D.space.sm) {
                HStack(spacing: D.space.sm) {
                    SilkscreenLabel("New files use", weight: .tiny)
                        .silkscreenDecorative()

                    LanguagePickerKey(
                        identifier: effectiveNewFileLocale,
                        ambiguous: localeIsAmbiguous(effectiveNewFileLocale),
                        isChosen: newFileLocaleIdentifier != nil,
                        locales: locales,
                        title: "Language for files you add next",
                        explanation: nil,
                        // The full name, not the two-letter badge. A badge is a fast read *in a
                        // column*, where the grid says what it is; on its own control it is a riddle,
                        // and this is the one place with room to spell it out.
                        legend: LanguageCode.name(effectiveNewFileLocale),
                        onPick: { onSetNewFileLocale($0) }
                    )
                    .accessibilityLabel("Language for files you add next")
                    .accessibilityValue(LanguageCode.name(effectiveNewFileLocale))

                    // Only offered when there is something to undo. A key that resets a setting to
                    // the value it already holds is a key that teaches the user it does nothing.
                    if newFileLocaleIdentifier != nil {
                        TapeButton("Follow dictation") { onSetNewFileLocale(nil) }
                            .accessibilityLabel("Follow the dictation language again")
                            .help("Go back to using whatever your dictation language is set to, "
                                  + "including when you change it later.")
                    }

                    Spacer(minLength: D.space.sm)
                }

                Text(languageProse)
                    .typeStyle(D.type.explain)
                    .foregroundStyle(D.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let dualPassLocaleIdentifier {
                    Text("Two languages per section is on. \(ImportQueue.dualPassRule) "
                         + "Your second language is \(LanguageCode.name(dualPassLocaleIdentifier)).")
                        .typeStyle(D.type.explain)
                        .foregroundStyle(D.color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The language for files added from now on: the explicit choice, or the dictation language.
    private var effectiveNewFileLocale: String {
        newFileLocaleIdentifier ?? dictationLocaleIdentifier
    }

    private var languageProse: String {
        // The clause that has to survive any future trim is the middle one. It is the whole reason a
        // language tag on a row is worth the space: the failure mode is not an error message, it is a
        // fluent transcript of words nobody said.
        let why = "Apple's model is told one language before it hears a word and never guesses, so a "
            + "file in another language comes back as confident nonsense rather than as an error. "
            + "Every row below shows its own language, and a row that has not started can still be "
            + "changed."
        guard let chosen = newFileLocaleIdentifier else {
            return "Files you add follow your dictation language, "
                + "\(LanguageCode.name(dictationLocaleIdentifier)). " + why
        }
        return "Files you add are transcribed in \(LanguageCode.name(chosen)), which you chose here — "
            + "your dictation language is \(LanguageCode.name(dictationLocaleIdentifier)) and is "
            + "unchanged. " + why
    }

    /// Every language on screen, so a two-letter badge is only used where two letters can only mean
    /// one thing.
    ///
    /// `en-US` beside `en-GB` would otherwise print `EN` twice — a column that indicates nothing while
    /// looking like it works, which is the failure this surface exists to prevent, one level down.
    private var localesOnScreen: [String] {
        var all = [effectiveNewFileLocale, dictationLocaleIdentifier]
        if let dualPassLocaleIdentifier { all.append(dualPassLocaleIdentifier) }
        for row in rows {
            all.append(row.localeIdentifier)
            if let second = row.secondPassLocaleIdentifier { all.append(second) }
        }
        return all
    }

    private func localeIsAmbiguous(_ identifier: String) -> Bool {
        LanguageCode.isAmbiguous(identifier, among: localesOnScreen)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: D.space.md) {
            // ⌘O is bound in the app menu instead of here. A `keyboardShortcut` on this key would
            // only work while the IMPORT pane happens to be showing, and would then be a second
            // claimant on the same chord — so the menu owns the gesture and this key and the menu
            // item call the same `MediaOpenPanel`.
            TapeButton("Open file…") { onEnqueue(MediaOpenPanel.pick()) }
                .accessibilityLabel("Open an audio or video file")
                .help("Choose audio or video files to transcribe. \(ImportableMedia.plainFormatList)")

            readout("Running", .count(runningCount, unit: "job"))
            readout("Queued", .duration(queuedDuration))

            Spacer(minLength: D.space.sm)

            TapeButton("Clear finished", action: onClearFinished)
                .disabled(terminalCount == 0)
                .accessibilityLabel("Clear finished, failed and cancelled rows")
                .help("Removes every row that has stopped. Transcripts stay in HISTORY.")
        }
    }

    private func readout(_ label: String, _ format: SegmentCounter.Format) -> some View {
        HStack(spacing: D.space.labelGap) {
            SegmentCounter(format, scale: .small)
            SilkscreenLabel(label, weight: .tiny)
                .silkscreenDecorative()
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    // MARK: The honest bit

    /// Printed on the panel, above the queue, in body type — not a footnote, not a tooltip, and
    /// not hedged.
    ///
    /// MacWhisper sells diarization on its paid tier and users arrive expecting it. Apple's Speech
    /// framework has no module that separates voices, so the only options were to say so plainly
    /// or to fake it with something that would silently mislabel every second turn. This is the
    /// first thing.
    private var speakerNotice: some View {
        PanelSurface("Speakers") {
            VStack(alignment: .leading, spacing: D.space.xs) {
                Text("Edict does not identify speakers.")
                    .typeStyle(D.type.bodyEmphasis)
                    .foregroundStyle(D.color.textPrimary)
                Text("Apple's on-device speech framework has no way to tell one voice from "
                     + "another, so a meeting or an interview arrives as a single block of text "
                     + "with no names and no turn breaks. If you need who said what, Edict "
                     + "cannot give you that.")
                    .typeStyle(D.type.explain)
                    .foregroundStyle(D.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Queue

    private var queue: some View {
        PanelSurface("Queue", inset: D.space.wellInset) {
            RecessedWell(fill: .list, inset: 0) {
                if rows.isEmpty {
                    emptyTray
                } else {
                    MaybeScrolling(scrolls: !unbounded) {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                ImportRow(
                                    row: row,
                                    localeIsAmbiguous: localeIsAmbiguous(row.localeIdentifier),
                                    secondLocaleIsAmbiguous: row.secondPassLocaleIdentifier
                                        .map(localeIsAmbiguous) ?? false,
                                    locales: locales,
                                    onCancel: { onCancel(row.id) },
                                    onRetry: { onRetry(row.id) },
                                    onSetLocale: { onSetRowLocale(row.id, $0) },
                                    onRerun: { onRerun(row.id, $0) }
                                )
                            }
                        }
                    }
                }
            }
        }
        // An empty tray is capped rather than stretched: 700 points of void with one centred
        // sentence in it reads as a broken layout, where a tray sized to a handful of rows reads
        // as an empty tray.
        .frame(
            minHeight: D.size.rowHeight * M.trayMinRows,
            maxHeight: rows.isEmpty ? D.size.rowHeight * M.emptyTrayRows : .infinity
        )
    }

    private var emptyTray: some View {
        VStack(spacing: D.space.sm) {
            SilkscreenLabel("Queue empty", weight: .heading, alignment: .center)
            Text("Drop \(ImportableMedia.plainDescription) anywhere on this window, or press "
                 + "OPEN FILE. The transcript is written to HISTORY — nothing is typed at the "
                 + "cursor.")
                .typeStyle(D.type.explain)
                .foregroundStyle(D.color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: D.size.meterSize.width * 1.5)
        }
        .padding(D.space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Data

    private var runningCount: Int { rows.count { $0.state.isRunning } }
    private var terminalCount: Int { rows.count { $0.state.isTerminal } }

    /// Total length of everything still to do, which is the number that predicts the wait —
    /// RECON measured the engine at roughly 12× realtime, so an hour of audio is about five
    /// minutes.
    private var queuedDuration: TimeInterval {
        rows.reduce(0) { total, row in
            guard row.state.isRunning, let duration = row.duration else { return total }
            return total + duration
        }
    }
}

// MARK: - ImportRow

/// One job. Same density discipline as `TranscriptRow`: fixed-pitch numeric columns, no
/// separators, no banding — the columns are the grid.
private struct ImportRow: View {

    let row: ImportQueueRow
    /// Print the whole BCP-47 tag instead of the two-letter badge, because another language on this
    /// pane badges the same. The row cannot know that; the pane can.
    let localeIsAmbiguous: Bool
    let secondLocaleIsAmbiguous: Bool
    let locales: [String]
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onSetLocale: (String) -> Void
    let onRerun: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: D.space.xxs) {
            HStack(spacing: D.space.sm) {
                SilkscreenLabel(row.kindTag, weight: .tiny)
                    .frame(width: M.colKind, alignment: .leading)
                    .silkscreenDecorative()

                HStack(spacing: D.space.sm) {
                    Text(row.filename)
                        .typeStyle(D.type.body)
                        .foregroundStyle(D.color.textPrimary)
                        .lineLimit(1)
                        // Middle, not tail: the extension is the half that says what the file is, and
                        // a queue of `interview-2026-…` names truncates to nothing useful at the tail.
                        .truncationMode(.middle)
                        .help(row.filename)
                    // *After* the name, not before it. Read back on the rendered sheet, a leading
                    // marker pushed one filename right and broke the single left edge that makes the
                    // tray scannable — and a re-run row is already adjacent to its source with a
                    // different language tag, so the word is a confirmation, not the signal.
                    if row.isRerun {
                        SilkscreenLabel("Rerun", weight: .tiny)
                            .silkscreenDecorative()
                            .help("This file transcribed again in another language. The earlier row "
                                  + "and its transcript are untouched \u{2014} compare them.")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Centred, not leading. The three renderings have different natural widths — a cap
                // fills the column, a lit readout does not — and leading-aligning them left the
                // readout orphaned against the column's edge instead of in the channel the caps
                // above and below it occupy.
                languageCell
                    .frame(width: M.colLocale)

                durationColumn

                ImportStateChannel(state: row.state)
                    .frame(width: M.colState)

                progressColumn

                keys
                    .frame(width: M.colKeys, alignment: .trailing)
            }

            if let note = row.note, row.state.isRunning {
                Text(note)
                    .typeStyle(D.type.caption)
                    .foregroundStyle(D.color.textSecondary)
                    .lineLimit(1)
                    .padding(.leading, M.colKind + D.space.sm)
                    .padding(.trailing, M.colKeys + D.space.sm)
            }

            if let detail = row.state.detail ?? row.warning {
                Text(detail)
                    .typeStyle(D.type.caption)
                    .foregroundStyle(row.state.detailIsAlert ? D.color.alert : D.color.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    // Indented to the filename column and stopped short of the key bank, so a long
                    // reason wraps instead of running underneath RETRY.
                    .padding(.leading, M.colKind + D.space.sm)
                    .padding(.trailing, M.colKeys + D.space.sm)
            }

            // Directly under the sentence that reports the problem, because that sentence is what
            // sends the user looking for a remedy. The language cell above offers the same action on
            // every finished row; this is the one case where it must not have to be found.
            if row.offersLanguageRerun {
                rerunKey
                    .padding(.leading, M.colKind + D.space.sm)
            }
        }
        .padding(.horizontal, D.space.rowInset)
        .padding(.vertical, D.space.xs)
        .frame(minHeight: D.size.rowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.filename)
        .accessibilityValue(spokenState)
    }

    @ViewBuilder
    private var durationColumn: some View {
        if let duration = row.duration {
            SegmentCounter(.duration(duration), scale: .small, seated: false)
                .frame(width: M.colDuration, alignment: .trailing)
        } else {
            // A length nobody has measured yet. Printed as blanks in the same pitch, so the column
            // does not shift when the probe lands.
            Text("--:--")
                .typeStyle(D.type.counterSmall)
                .foregroundStyle(D.color.textSecondary)
                .frame(width: M.colDuration, alignment: .trailing)
                .accessibilityLabel("Length not known yet")
        }
    }

    @ViewBuilder
    private var progressColumn: some View {
        if let progress = row.state.progress, row.state.isRunning {
            SegmentCounter(.count(Int(progress * 100), unit: "%"), scale: .small, seated: false)
                .frame(width: M.colProgress, alignment: .trailing)
        } else {
            Color.clear.frame(width: M.colProgress, height: 0)
        }
    }

    /// The trailing key bank. Exactly one bank per state, always the same width, so the keys line
    /// up down the tray instead of dancing as jobs finish.
    @ViewBuilder
    private var keys: some View {
        switch row.state {
        case .waiting, .reading, .transcribing:
            TapeButton("Cancel", role: .stop, minWidth: M.colKeys, action: onCancel)
                .accessibilityLabel("Cancel \(row.filename)")
        case .finished(let transcript):
            TranscriptExportKeys(transcript)
        case .failed:
            TapeButton("Retry", minWidth: M.colKeys, action: onRetry)
                .accessibilityLabel("Try \(row.filename) again")
        case .cancelled:
            TapeButton("Retry", minWidth: M.colKeys, action: onRetry)
                .accessibilityLabel("Transcribe \(row.filename) after all")
        }
    }

    // MARK: Language cell

    /// Which acoustic model this file gets, on every row, in every state.
    ///
    /// Three renderings of one fact, because the *available action* differs and a control that looks
    /// identical whether or not it does anything is worse than two controls:
    ///
    /// * **Queued** — a key. The language can still be changed, and the cap is latched when the user
    ///   picked it and unlatched when it was inherited from the dictation language. Latch, not colour:
    ///   an inherited language is worth double-checking, not an error, and the spec has no coloured
    ///   badge.
    /// * **Finished** — a key that offers a re-run instead. The analyzer is built from exactly one
    ///   `Locale` and never rebuilt (RECON §3), so there is no such thing as changing a finished row's
    ///   language; the honest offer is to run the file again.
    /// * **Running, failed, cancelled** — a `LanguageTag`, which is a readout and not a control.
    @ViewBuilder
    private var languageCell: some View {
        if row.localeIsEditable {
            LanguagePickerKey(
                identifier: row.localeIdentifier,
                ambiguous: localeIsAmbiguous,
                isChosen: row.localeWasChosen,
                locales: locales,
                title: "Language for this file",
                explanation: row.localeWasChosen
                    ? nil
                    : "Inherited from your dictation language. Change it if this file is not in that "
                        + "language — the model is told one language before it hears a word and never "
                        + "guesses.",
                pairSuffix: pairSuffix,
                onPick: { onSetLocale($0) }
            )
            .accessibilityLabel("Language for this file")
            .accessibilityValue(spokenLanguage)
        } else if case .finished = row.state {
            LanguagePickerKey(
                identifier: row.localeIdentifier,
                ambiguous: localeIsAmbiguous,
                isChosen: true,
                locales: locales,
                title: "Transcribe again in another language",
                explanation: ImportQueueRow.languageRerunExplanation,
                pairSuffix: pairSuffix,
                onPick: { onRerun($0) }
            )
            .accessibilityLabel("Transcribed in \(LanguageCode.name(row.localeIdentifier)). "
                                + "Transcribe again in another language")
            .accessibilityValue(spokenLanguage)
        } else {
            // Full size, not `compact`. The compact tag is a HUD instrument; read back on the
            // rendered sheet it sat visibly lighter than the keys above and below it, and a column
            // whose mass changes as jobs start is the dancing that `keys`' fixed width exists to
            // prevent. A readout still reads as a readout here — it is a lit well, not a cap.
            LanguageTag(codeText, spoken: spokenLanguage)
        }
    }

    /// `→ID` when a dual pass will also try a second language on this row, else empty.
    ///
    /// Printed rather than merely explained on the panel, because `ImportQueue.dualPassRule` makes the
    /// row's own language the *first* of two — so the row's tag alone would be a half-truth about what
    /// ran, and "which languages were tried" is exactly the question a wrong transcript raises.
    private var pairSuffix: String {
        guard let second = row.secondPassLocaleIdentifier else { return "" }
        return "\u{2192}" + LanguageCode.code(second, ambiguous: secondLocaleIsAmbiguous)
    }

    private var codeText: String {
        LanguageCode.code(row.localeIdentifier, ambiguous: localeIsAmbiguous) + pairSuffix
    }

    /// Names, never codes: VoiceOver spells `EN` out letter by letter.
    private var spokenLanguage: String {
        let first = LanguageCode.name(row.localeIdentifier)
        guard let second = row.secondPassLocaleIdentifier else {
            return row.localeWasChosen || !row.localeIsEditable
                ? first
                : "\(first), inherited from your dictation language"
        }
        return "\(first) first, then \(LanguageCode.name(second))"
    }

    // MARK: Re-run

    private var rerunKey: some View {
        LanguagePickerKey(
            identifier: row.localeIdentifier,
            ambiguous: localeIsAmbiguous,
            isChosen: true,
            locales: locales,
            title: "Transcribe again in another language",
            explanation: ImportQueueRow.languageRerunExplanation,
            latches: false,
            legend: "Try another language…",
            onPick: { onRerun($0) }
        )
        .accessibilityLabel("Transcribe this file again in another language")
        .help("Little of the audio became words. If the language was wrong this will fix it; if the "
              + "recording is simply hard to hear, it will not.")
    }

    /// Never the uppercased legend: a screen reader spells caps out letter by letter.
    private var spokenState: String {
        if let detail = row.state.detail ?? row.warning { return "\(row.state.legend). \(detail)" }
        if let note = row.note, row.state.isRunning { return "\(row.state.legend), \(note)" }
        if let progress = row.state.progress, row.state.isRunning {
            return "\(row.state.legend), \(Int(progress * 100)) percent"
        }
        return row.state.legend
    }
}

// MARK: - LanguagePickerKey

/// A key printing a language, which opens the shared `LanguageTray` to change it.
///
/// One control for all four jobs on this pane — the pane default, a queued row, a finished row's
/// re-run, and the prominent re-run under a poor-quality row — because they are the same gesture with
/// different consequences, and the consequence is stated in the popover rather than implied by a
/// different-looking control. The tray inside is `LanguageTray`, the same component Settings uses, so
/// the list, its order and its keys cannot drift from the choice the user already made there.
private struct LanguagePickerKey: View {

    let identifier: String
    let ambiguous: Bool
    /// Latches the cap: the user picked this language, rather than inheriting it — never a colour,
    /// because an inherited language is worth double-checking and not an error.
    let isChosen: Bool
    let locales: [String]
    /// Silkscreened heading inside the popover, which is where this control says what it will do.
    let title: String
    /// The honest paragraph. `nil` where there is nothing that needs saying.
    let explanation: String?
    /// Appended to the printed code, for a dual pass's second language.
    var pairSuffix: String = ""
    /// Suppresses the latch. A key whose legend is a *sentence* ("Try another language…") would read
    /// as a toggle that is switched on; a key whose legend is a language would not.
    var latches = true
    /// Overrides the printed code, for a key that is a sentence rather than a tag.
    var legend: String?
    let onPick: (String) -> Void

    @State private var isPicking = false

    var body: some View {
        TapeButton(
            role: .neutral,
            isLatched: isChosen && latches,
            action: { isPicking = true }
        ) {
            Text(legend ?? code)
        }
        .popover(isPresented: $isPicking) {
            LanguageChoiceTray(
                title: title,
                explanation: explanation,
                locales: locales,
                selected: identifier,
                onPick: { picked in
                    // Dismissed first: picking a language on a finished row starts a transcription,
                    // and a popover still hanging over the tray while a new row appears underneath it
                    // hides the thing the click just produced.
                    isPicking = false
                    onPick(picked)
                }
            )
        }
    }

    private var code: String {
        LanguageCode.code(identifier, ambiguous: ambiguous) + pairSuffix
    }
}

// MARK: - LanguageChoiceTray

/// The contents of a `LanguagePickerKey`'s popover: what this choice will do, then the tray.
///
/// A named view rather than a closure inside the key, so the render harness can rasterise the real
/// popover. `ImageRenderer` cannot open a popover, and RECON amendment 40 means an agent cannot
/// photograph one either — so a picker that is only reachable through a `.popover` modifier is a
/// picker nobody looks at before it ships. This is the one thing standing between the honest
/// re-run wording and never being read.
struct LanguageChoiceTray: View {

    let title: String
    let explanation: String?
    let locales: [String]
    let selected: String
    /// Render-harness hatch, forwarded to `LanguageTray`. Never `false` in the app.
    var scrolls = true
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: D.space.sm) {
            SilkscreenLabel(title, weight: .tiny)
                .silkscreenDecorative()

            if let explanation {
                Text(explanation)
                    .typeStyle(D.type.explain)
                    .foregroundStyle(D.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: M.popoverTrayKeyWidth)
            }

            LanguageTray(
                identifiers: locales,
                selected: selected,
                keyMinWidth: M.popoverTrayKeyWidth,
                visibleRows: M.popoverTrayRows,
                scrolls: scrolls,
                onPick: onPick
            )
            .frame(width: M.popoverTrayKeyWidth + D.space.md)
        }
        .padding(D.space.md)
        .background(D.surface.deckPaint)
    }
}

// MARK: - Render-harness helpers

/// A `ScrollView`, or its content bare. Only the render harness ever asks for bare — see
/// `ImportPane.unbounded`.
private struct MaybeScrolling<Content: View>: View {
    let scrolls: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if scrolls {
            ScrollView { content }
                .scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}


// MARK: - ImportStateChannel

/// The lit channel that says what this job is doing, with the progress hairline creeping along its
/// bottom edge.
///
/// Deliberately not `StatusReadout`: that component's `Condition` names the *dictation* state
/// machine, and its strings ("Listening", "Inserting") are wrong for a file. The construction is
/// copied exactly, though — a display well, a reserved width so the channel never resizes as the
/// legend changes, and the channel itself as the progress track.
private struct ImportStateChannel: View {

    let state: ImportQueueRow.State

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RecessedWell(fill: .display, radius: D.radius.tight, inset: D.space.xs) {
            ZStack(alignment: .leading) {
                // The longest legend, hidden, reserving the width. Without it the channel would
                // grow and shrink as a job moves from WAITING to TRANSCRIBING to DONE.
                legendText(ImportQueueRow.State.transcribing(0).legend)
                    .hidden()
                    .accessibilityHidden(true)
                legendText(state.legend)
                    .foregroundStyle(state.isFault ? D.color.alert : D.color.displayInk)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottomLeading) { progressRule }
        .accessibilityHidden(true)
    }

    private func legendText(_ text: String) -> some View {
        Text(text)
            .typeStyle(D.type.silkscreen)
            .lineLimit(1)
            .truncationMode(.tail)
            .dynamicTypeSize(.large)
    }

    /// A hairline creeping along the bottom of the channel, not a bar with its own track: the
    /// channel is the track. Same idiom as `StatusReadout`'s model-download rule, so progress
    /// looks like one thing everywhere in the app.
    @ViewBuilder
    private var progressRule: some View {
        if let fraction = state.progress, state.isRunning {
            GeometryReader { proxy in
                D.color.displayInk
                    .frame(width: proxy.size.width * fraction, height: M.progressHeight)
                    .animation(reduceMotion ? nil : D.motion.panel, value: fraction)
            }
            .frame(height: M.progressHeight)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - TranscriptExportKeys

/// Three moulded keys — TXT, SRT, VTT — that write a transcript to disk.
///
/// A bank of keys rather than a `Menu`: a pop-up button is macOS chrome, and there are only ever
/// three formats, so hiding them behind a disclosure costs a click and buys nothing.
///
/// SRT and VTT are **disabled without per-word timings**, which is a real distinction and not a
/// technicality: a live dictation has no timeline to cut cues against, so only an imported file
/// can be exported as subtitles. The keys stay visible, greyed, with a tooltip that says why —
/// hiding them would leave the user wondering whether Edict does subtitles at all.
public struct TranscriptExportKeys: View {

    private let transcript: Transcript

    public init(_ transcript: Transcript) {
        self.transcript = transcript
    }

    public var body: some View {
        HStack(spacing: D.space.xs) {
            ForEach(TranscriptExportFormat.allCases, id: \.self) { format in
                let isAvailable = available.contains(format)
                TapeButton(format.fileExtension, minWidth: M.keyWidth) {
                    TranscriptFileExport.save(transcript, as: format)
                }
                .disabled(!isAvailable)
                .accessibilityLabel("Export as \(format.displayName)")
                .help(isAvailable
                      ? "Write \(TranscriptExport.suggestedFilename(for: transcript, format: format))."
                      : "\(format.displayName) needs per-word timings, which only imported files have.")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Export")
    }

    private var available: [TranscriptExportFormat] {
        TranscriptExport.availableFormats(for: transcript)
    }
}

// MARK: - Choosing the files

/// The open panel behind both ⌘O and the OPEN FILE key.
///
/// `NSOpenPanel` rather than SwiftUI's `.fileImporter`, for the same reason `TranscriptFileExport`
/// uses `NSSavePanel`: `.fileImporter` needs a presentation `Binding` on a *visible* view, so ⌘O
/// would silently do nothing whenever the user was looking at any pane other than IMPORT. A panel
/// that can be opened from a menu command is the whole requirement.
enum MediaOpenPanel {

    /// Runs the panel and returns the files the engine can actually open, in the order chosen.
    /// Empty when the user cancelled.
    @MainActor
    static func pick() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ImportableMedia.contentTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Choose audio or video to transcribe. "
            + "The transcript goes to HISTORY, not to your cursor."
        panel.prompt = "Transcribe"
        guard panel.runModal() == .OK else { return [] }
        // Filtered again on the way out: `allowedContentTypes` constrains the panel, but a file the
        // panel let through can still fail `accepts` (a symlink to something else, an iCloud
        // placeholder), and it is cheaper to drop it here than to fail a queue row over it.
        return panel.urls.filter(ImportableMedia.accepts)
    }
}

// MARK: - Writing the file

/// The one place a view writes a transcript to disk, mirroring `ViewClipboard` in `HistoryPane`.
///
/// `NSSavePanel` rather than SwiftUI's `fileExporter`: `fileExporter` wants a `FileDocument` and a
/// presentation `Binding`, which would mean a piece of `@State` per row in the queue. The save
/// panel is also the one piece of system UI that *should* look like system UI — it is the user's
/// file system, not Edict's panel.
enum TranscriptFileExport {

    @MainActor
    static func save(_ transcript: Transcript, as format: TranscriptExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = TranscriptExport.suggestedFilename(for: transcript, format: format)
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.message = "Save the transcript of \(transcript.source.displayName)."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try TranscriptExport.data(for: transcript, format: format)
                .write(to: url, options: .atomic)
            Log.data.info("Exported a transcript as \(format.rawValue, privacy: .public).")
        } catch {
            Log.data.error("Could not write the export: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Render fixtures

/// Sample queues for `#Preview` and for the offline layout harness.
///
/// A parallel of `PreviewFixtures` rather than an addition to it, because `MainWindow.swift` is not
/// this file's to edit. The sheets belong in `PreviewFixtures.renderSheets()` eventually.
@MainActor
public enum ImportPreviewFixtures {

    /// A queue caught mid-run: one job transcribing, one reading, one waiting, one done, one
    /// failed, one cancelled. Every branch of the row on one page.
    public static var busyQueue: [ImportQueueRow] {
        [
            ImportQueueRow(
                filename: "board-meeting-2026-08-24.m4a",
                duration: 3_784,
                state: .transcribing(0.42)
            ),
            ImportQueueRow(
                filename: "site-visit.mov",
                duration: 612,
                isVideo: true,
                state: .reading(0.08)
            ),
            ImportQueueRow(filename: "voice-memo-114.mp3", duration: 96),
            ImportQueueRow(filename: "standup.wav", state: .waiting),
            ImportQueueRow(
                filename: "interview-hannah.mp4",
                duration: 1_455,
                isVideo: true,
                state: .finished(finishedTranscript)
            ),
            ImportQueueRow(
                filename: "corrupt-take-3.mp4",
                duration: nil,
                isVideo: true,
                state: .failed("No audio track. The file has video but nothing to transcribe.")
            ),
            ImportQueueRow(
                filename: "old-cassette-side-b.aiff",
                duration: 2_712,
                state: .cancelled
            ),
        ]
    }

    /// Just the failure, so the alert ink and the second line can be checked on their own.
    public static var failedQueue: [ImportQueueRow] {
        [
            ImportQueueRow(
                filename: "corrupt-take-3.mp4",
                duration: nil,
                isVideo: true,
                state: .failed("No audio track. The file has video but nothing to transcribe.")
            ),
            ImportQueueRow(
                filename: "locked.m4a",
                duration: 42,
                state: .failed("Edict is not allowed to read this file. Move it out of an "
                               + "iCloud-only folder and try again.")
            ),
        ]
    }

    /// An imported transcript with segments, so the SRT and VTT keys are live.
    public static var finishedTranscript: Transcript {
        Transcript(
            createdAt: Date(timeIntervalSinceNow: -300),
            rawText: "So the plan is to ship the import queue first.",
            text: "So the plan is to ship the import queue first.",
            audioDuration: 1_455,
            transcribeDuration: 118.4,
            injection: .notAttempted,
            source: .imported(filename: "interview-hannah.mp4"),
            segments: [
                TranscriptSegment(start: 0, end: 1.2, text: "So the plan", confidence: 0.98),
                TranscriptSegment(start: 1.2, end: 2.9, text: " is to ship", confidence: 0.94),
                TranscriptSegment(start: 2.9, end: 4.6, text: " the import queue first.", confidence: 0.91),
            ]
        )
    }

    // MARK: Language fixtures

    /// The locale list a fixture offers, short enough to render and long enough to scroll.
    ///
    /// `id-ID` is first because it is the case the whole feature exists for: RECON records it as
    /// present in `DictationTranscriber`'s 54 locales and absent from `SpeechTranscriber`'s 45, so it
    /// is both the language that broke and the one that proves the module is resolved per item.
    public static let sampleLocales = [
        "id-ID", "en-US", "en-GB", "de-DE", "es-ES", "fr-FR", "ja-JP", "zh-CN",
    ]

    /// The same file queued twice in two languages, which is the comparison the feature exists to
    /// make — and the sheet that proves a per-file locale is not a global one.
    ///
    /// Also holds the two cases the tag has to distinguish at a glance: a row still queued whose
    /// language was *inherited* (unlatched cap) and one the user *chose* (latched), plus a finished
    /// row whose language is a re-run offer rather than an editable setting.
    public static var bilingualQueue: [ImportQueueRow] {
        [
            ImportQueueRow(
                filename: "rapat-direksi-70min.m4a",
                duration: 4_212,
                state: .finished(englishNonsenseTranscript),
                localeIdentifier: "en-US",
                localeWasChosen: false
            ),
            ImportQueueRow(
                filename: "rapat-direksi-70min.m4a",
                duration: 4_212,
                state: .transcribing(0.31),
                localeIdentifier: "id-ID",
                localeWasChosen: true,
                isRerun: true
            ),
            ImportQueueRow(
                filename: "standup-notes.wav",
                duration: 240,
                state: .waiting,
                localeIdentifier: "en-US",
                localeWasChosen: false,
                localeIsEditable: true
            ),
            ImportQueueRow(
                filename: "wawancara-kandidat.mp3",
                duration: 1_980,
                state: .waiting,
                localeIdentifier: "id-ID",
                localeWasChosen: true,
                localeIsEditable: true
            ),
        ]
    }

    /// A queue with dual pass switched on, so the row tag prints the pair it will actually try.
    public static var dualPassQueue: [ImportQueueRow] {
        [
            ImportQueueRow(
                filename: "bilingual-standup.m4a",
                duration: 900,
                state: .waiting,
                localeIdentifier: "id-ID",
                localeWasChosen: true,
                localeIsEditable: true,
                secondPassLocaleIdentifier: "en-US"
            ),
            ImportQueueRow(
                filename: "client-call.m4a",
                duration: 2_400,
                state: .transcribing(0.5),
                note: "Two languages per section — 24 of 96 passes done",
                localeIdentifier: "en-US",
                localeWasChosen: false,
                secondPassLocaleIdentifier: "id-ID"
            ),
        ]
    }

    /// A finished row the recogniser barely read, which is where the re-run has to be offered rather
    /// than merely described — and where the wording has to refuse to promise a fix.
    public static var poorQualityQueue: [ImportQueueRow] {
        [
            ImportQueueRow(
                filename: "far-field-meeting.m4a",
                duration: 4_200,
                state: .finished(veryPoorTranscript),
                localeIdentifier: "en-US",
                localeWasChosen: false
            ),
            ImportQueueRow(
                filename: "phone-recording.m4a",
                duration: 1_320,
                state: .finished(sparseTranscript),
                localeIdentifier: "en-US",
                localeWasChosen: true
            ),
        ]
    }

    /// What RECON amendment 45 actually measured: an English model on Indonesian audio inventing
    /// confident, plausible proper nouns instead of failing. The quality verdict is `good`, because
    /// the *rate* was fine — which is precisely why the language tag, and not a warning, is what
    /// catches this.
    public static var englishNonsenseTranscript: Transcript {
        Transcript(
            createdAt: Date(timeIntervalSinceNow: -900),
            rawText: "Then other workshop Karna Saka Ito Sanga Dunia Kanaya Sushma Manga Cheil Danka.",
            text: "Then other workshop Karna Saka Ito Sanga Dunia Kanaya Sushma Manga Cheil Danka.",
            audioDuration: 4_212,
            transcribeDuration: 61.2,
            localeIdentifier: "en-US",
            injection: .notAttempted,
            source: .imported(filename: "rapat-direksi-70min.m4a"),
            quality: RecognitionQuality(verdict: .good, wordsPerMinute: 112, coverage: 0.93)
        )
    }

    public static var veryPoorTranscript: Transcript {
        Transcript(
            createdAt: Date(timeIntervalSinceNow: -600),
            rawText: "so if we could just and then the other thing",
            text: "So if we could just, and then the other thing.",
            audioDuration: 4_200,
            transcribeDuration: 58.0,
            localeIdentifier: "en-US",
            injection: .notAttempted,
            source: .imported(filename: "far-field-meeting.m4a"),
            quality: RecognitionQuality(
                verdict: .veryPoor,
                wordsPerMinute: 16,
                coverage: 0.21,
                explanation: "Only about 16 words a minute came back over 70 minutes of audio. "
                    + "Most of this recording did not become text."
            )
        )
    }

    public static var sparseTranscript: Transcript {
        Transcript(
            createdAt: Date(timeIntervalSinceNow: -420),
            rawText: "yes we can do that next week",
            text: "Yes, we can do that next week.",
            audioDuration: 1_320,
            transcribeDuration: 22.0,
            localeIdentifier: "en-US",
            injection: .notAttempted,
            source: .imported(filename: "phone-recording.m4a"),
            quality: RecognitionQuality(
                verdict: .sparse,
                wordsPerMinute: 41,
                coverage: 0.48,
                explanation: "About 41 words a minute came back, well under a speaking rate. "
                    + "Passages are missing."
            )
        )
    }

    /// A dictated transcript, which has no segments — the case that greys SRT and VTT.
    public static var dictatedTranscript: Transcript {
        Transcript(
            rawText: "No timings on a live dictation.",
            text: "No timings on a live dictation.",
            audioDuration: 3.1,
            transcribeDuration: 0.2,
            injection: .accessibility
        )
    }

    /// The main window with the curtain over it, which is exactly how the state ships.
    private static func drop(_ phase: DropPhase) -> some View {
        MainWindow(model: PreviewFixtures.model())
            .overlay { DropCurtain(phase) }
    }

    /// A model whose log holds one imported transcript, selected — so the render shows the export
    /// keys, the `From file` target and the `Took` / `Speed` readouts that only an import has.
    private static func historyWithImport() -> some View {
        let model = PreviewFixtures.model()
        let transcript = finishedTranscript
        model.history.append(transcript)
        return HistoryPane(model: model, initialSelection: transcript.id)
    }

    /// A log holding three languages, two of which badge the same.
    ///
    /// The sheet that proves the history column *and* its disambiguation in one image: `id-ID` stays
    /// at the two-letter read while `en-US` and `en-GB` both go long, because `EN` against `EN` would
    /// be a column that indicates nothing. `unbounded`, because `ImageRenderer` renders a `ScrollView`
    /// as empty and an empty log would "prove" the column while showing none of it.
    private static func historyWithLanguages() -> some View {
        let model = PreviewFixtures.model(populated: false)
        let entries: [(String, String)] = [
            ("id-ID", "Terima kasih, kita lanjutkan minggu depan."),
            ("en-GB", "We'll organise the schedule and revisit the colour scheme."),
            ("en-US", "Then other workshop Karna Saka Ito Sanga Dunia Kanaya Sushma."),
        ]
        for (locale, text) in entries {
            model.history.append(Transcript(
                rawText: text,
                text: text,
                audioDuration: 42,
                transcribeDuration: 1.8,
                localeIdentifier: locale,
                injection: .accessibility,
                source: .imported(filename: "meeting.m4a")
            ))
        }
        // A dual pass, so the `+` that stops a mixed transcript claiming to be monolingual is on the
        // sheet too.
        model.history.append(Transcript(
            rawText: "Oke, so the deliverable is due Friday.",
            text: "Oke, so the deliverable is due Friday.",
            audioDuration: 96,
            transcribeDuration: 6.2,
            localeIdentifier: "id-ID",
            localeIdentifiers: ["id-ID", "en-US"],
            injection: .accessibility,
            source: .imported(filename: "bilingual.m4a")
        ))
        return HistoryPane(model: model, unbounded: true)
    }

    public static func renderSheets() -> [PreviewFixtures.RenderSheet] {
        let paneSize = CGSize(
            width: D.size.windowMin.width - D.size.railWidth,
            height: D.size.windowMin.height
        )

        func sheet(_ id: String, _ size: CGSize, _ view: some View) -> PreviewFixtures.RenderSheet {
            PreviewFixtures.RenderSheet(
                id: id,
                size: size,
                view: AnyView(
                    view
                        .frame(width: size.width, height: size.height)
                        .background(D.surface.deckPaint)
                )
            )
        }

        return [
            sheet("pane-import-empty", paneSize, ImportPane(rows: [])),
            sheet("pane-import-busy", paneSize, ImportPane(rows: busyQueue)),
            sheet("pane-import-failed", paneSize, ImportPane(rows: failedQueue)),
            sheet("pane-import-narrow",
                  CGSize(width: paneSize.width * 0.8, height: paneSize.height),
                  ImportPane(rows: busyQueue)),
            // Over a real window, not over blank chassis: the drop state is a state *of* the
            // window, and the only question worth checking is whether the plate holds up against
            // a lit VU meter and a full log behind the scrim.
            sheet("drop-ready", D.size.windowMin, drop(.ready(fileCount: 1))),
            sheet("drop-ready-many", D.size.windowMin, drop(.ready(fileCount: 7))),
            sheet("drop-refused", D.size.windowMin, drop(.refused)),
            // The three sheets that prove the language surface. `unbounded` so the queue tray
            // actually rasterises — `ImageRenderer` renders a `ScrollView` as empty, and an empty
            // tray would "prove" nothing while looking fine.
            sheet("pane-import-languages", paneSize, ImportPane(
                rows: bilingualQueue,
                locales: sampleLocales,
                dictationLocaleIdentifier: "en-US",
                unbounded: true
            )),
            sheet("pane-import-language-chosen", paneSize, ImportPane(
                rows: bilingualQueue,
                locales: sampleLocales,
                dictationLocaleIdentifier: "en-US",
                newFileLocaleIdentifier: "id-ID",
                unbounded: true
            )),
            sheet("pane-import-language-poor", paneSize, ImportPane(
                rows: poorQualityQueue,
                locales: sampleLocales,
                dictationLocaleIdentifier: "en-US",
                unbounded: true
            )),
            sheet("pane-import-language-dualpass", paneSize, ImportPane(
                rows: dualPassQueue,
                locales: sampleLocales,
                dictationLocaleIdentifier: "en-US",
                dualPassLocaleIdentifier: "en-US",
                unbounded: true
            )),
            // The picker itself. It only ever appears inside a `.popover`, which `ImageRenderer`
            // cannot open, so the popover's body is a named view and this is the real one.
            sheet("import-language-tray",
                  CGSize(width: 300, height: 460),
                  LanguageChoiceTray(
                      title: "Language for this file",
                      explanation: "Inherited from your dictation language. Change it if this file "
                          + "is not in that language — the model is told one language before it "
                          + "hears a word and never guesses.",
                      locales: sampleLocales,
                      selected: "en-US",
                      scrolls: false,
                      onPick: { _ in }
                  )),
            sheet("import-language-rerun",
                  CGSize(width: 300, height: 620),
                  LanguageChoiceTray(
                      title: "Transcribe again in another language",
                      explanation: ImportQueueRow.languageRerunExplanation,
                      locales: sampleLocales,
                      selected: "en-US",
                      scrolls: false,
                      onPick: { _ in }
                  )),
            sheet("pane-history-languages", paneSize, historyWithLanguages()),
            sheet("pane-history-import", paneSize, historyWithImport()),
            // `paneSize` is already the narrowest the pane can ever be — `D.size.windowMin.width`
            // minus the rail — so this is the size at which the detail header's key bank has to fit,
            // and there is no narrower case to check. Anything smaller is a render-harness artefact,
            // not a state the window can be dragged into (`EdictApp` pins the window's minimum to
            // the content's).
            sheet("export-keys",
                  CGSize(width: M.colKeys + D.space.xl, height: D.size.buttonHeight + D.space.xl),
                  TranscriptExportKeys(finishedTranscript).padding(D.space.md)),
            sheet("export-keys-dictated",
                  CGSize(width: M.colKeys + D.space.xl, height: D.size.buttonHeight + D.space.xl),
                  TranscriptExportKeys(dictatedTranscript).padding(D.space.md)),
        ]
    }
}

// MARK: - Previews

#Preview("Import — busy") {
    ImportPane(rows: ImportPreviewFixtures.busyQueue)
        .frame(width: D.size.windowMin.width - D.size.railWidth, height: D.size.windowMin.height)
        .background(D.surface.deckPaint)
}

#Preview("Import — empty, dark") {
    ImportPane(rows: [])
        .frame(width: D.size.windowMin.width - D.size.railWidth, height: D.size.windowMin.height)
        .background(D.surface.deckPaint)
        .preferredColorScheme(.dark)
}
