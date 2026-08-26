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
    /// Three three-letter export keys side by side, which is the widest the trailing bank gets.
    static let colKeys = D.size.buttonHeight * 3 + D.space.sm            // 98
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
        warning: String? = nil
    ) {
        self.id = id
        self.filename = filename
        self.duration = duration
        self.isVideo = isVideo
        self.state = state
        self.note = note
        self.warning = warning
    }

    /// Natural case; genuine three-letter abbreviations are correct in caps for eye and screen
    /// reader alike.
    var kindTag: String { isVideo ? "VID" : "AUD" }
}

// MARK: - ImportPane

/// Files being turned into transcripts.
struct ImportPane: View {

    let rows: [ImportQueueRow]
    /// Files the user picked or dropped, in order.
    let onEnqueue: ([URL]) -> Void
    /// Stops a running job. Terminal rows are removed with `onClearFinished` instead, so one key
    /// per row is enough.
    let onCancel: (UUID) -> Void
    let onRetry: (UUID) -> Void
    /// Removes every terminal row — finished, failed and cancelled alike.
    let onClearFinished: () -> Void

    init(
        rows: [ImportQueueRow],
        onEnqueue: @escaping ([URL]) -> Void = { _ in },
        onCancel: @escaping (UUID) -> Void = { _ in },
        onRetry: @escaping (UUID) -> Void = { _ in },
        onClearFinished: @escaping () -> Void = {}
    ) {
        self.rows = rows
        self.onEnqueue = onEnqueue
        self.onCancel = onCancel
        self.onRetry = onRetry
        self.onClearFinished = onClearFinished
    }

    var body: some View {
        VStack(alignment: .leading, spacing: D.space.md) {
            controls
            speakerNotice
            queue
            if rows.isEmpty { Spacer(minLength: 0) }
        }
        .padding(D.space.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(D.motion.panel, value: rows)
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
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                ImportRow(
                                    row: row,
                                    onCancel: { onCancel(row.id) },
                                    onRetry: { onRetry(row.id) }
                                )
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
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
    let onCancel: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: D.space.xxs) {
            HStack(spacing: D.space.sm) {
                SilkscreenLabel(row.kindTag, weight: .tiny)
                    .frame(width: M.colKind, alignment: .leading)
                    .silkscreenDecorative()

                Text(row.filename)
                    .typeStyle(D.type.body)
                    .foregroundStyle(D.color.textPrimary)
                    .lineLimit(1)
                    // Middle, not tail: the extension is the half that says what the file is, and
                    // a queue of `interview-2026-…` names truncates to nothing useful at the tail.
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(row.filename)

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
