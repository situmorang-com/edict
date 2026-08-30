import Foundation
import Observation

// MARK: - Shared value types

/// Where a transcript's audio came from. Dictated ones are injected at the cursor; imported ones are
/// transcribed from a file the user dropped on the window and only ever land in history.
///
/// Hand-rolled `Codable` rather than the synthesised associated-value form (`{"imported":{"filename":…}}`)
/// for two reasons: the tagged object reads sanely to a human inspecting `history.json`, and an unknown
/// future `kind` degrades to `.dictated` instead of failing the whole file's decode.
public enum TranscriptSource: Codable, Hashable, Sendable {
    /// Spoken live and injected at the cursor.
    case dictated
    /// Transcribed from a file. `filename` is the last path component only — never a full path, because
    /// history is shown in the UI and a home directory is nobody's business.
    case imported(filename: String)

    public var isImported: Bool {
        if case .imported = self { return true }
        return false
    }

    /// The source file's name, or `nil` for a live dictation.
    public var importedFilename: String? {
        if case .imported(let filename) = self { return filename }
        return nil
    }

    public var displayName: String {
        switch self {
        case .dictated: "Dictated"
        case .imported(let filename): filename.isEmpty ? "Imported" : filename
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, filename }
    private enum Kind: String, Codable { case dictated, imported }

    public init(from decoder: any Decoder) throws {
        // A bare string is accepted too, so a hand-edited `"source": "dictated"` still loads.
        if let single = try? decoder.singleValueContainer(), let raw = try? single.decode(String.self) {
            self = (raw == Kind.imported.rawValue) ? .imported(filename: "") : .dictated
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch (try? c.decode(Kind.self, forKey: .kind)) ?? .dictated {
        case .dictated:
            self = .dictated
        case .imported:
            self = .imported(filename: (try? c.decode(String.self, forKey: .filename)) ?? "")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .dictated:
            try c.encode(Kind.dictated, forKey: .kind)
        case .imported(let filename):
            try c.encode(Kind.imported, forKey: .kind)
            try c.encode(filename, forKey: .filename)
        }
    }
}

/// One timed piece of a transcript, as the engine reported it. File transcription produces these;
/// live dictation does not, because there is nothing to seek back to.
///
/// The engine hands back per-word ranges, so these are usually single words — `TranscriptExport`
/// merges them into readable subtitle cues rather than emitting one cue per word.
public struct TranscriptSegment: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Seconds from the beginning of the audio.
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// `transcriptionConfidence` where the engine supplied one. RECON: below ~0.5 is strongly
    /// indicative of a mishearing.
    public var confidence: Double?

    /// Which locale actually produced this text, when that differs from segment to segment.
    ///
    /// `nil` for every transcript made in one pass, which is the overwhelming majority: there the
    /// transcript's own `localeIdentifier` is the whole truth and repeating it on a thousand
    /// segments would be a thousand copies of one fact. Non-nil only where a dual-pass import chose
    /// per section, and *that* is the case where the transcript-level field cannot be the whole
    /// truth — see `Transcript.localeIdentifiers`.
    public var locale: String?

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        confidence: Double? = nil,
        locale: String? = nil
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
        self.locale = locale
    }

    public var duration: TimeInterval { max(0, end - start) }

    /// `id` is deliberately **not** written.
    ///
    /// It exists for `Identifiable` inside one render pass and is referenced by nothing that
    /// outlives the process — unlike `CorrectionHit.entryID`, which points at a dictionary entry and
    /// must persist. Writing it cost 45 of the ~100 bytes a segment occupies, and segments are the
    /// bulk of an imported transcript: a 377 s file produces 1007 of them, which measured at 130 KB
    /// per entry with ids and 72 KB without. `init(from:)` mints a fresh one on load.
    // Spelled out because supplying `encode(to:)` suppresses the synthesised `CodingKeys`.
    // `id` stays in the enum so `init(from:)` can still read a file written by an older build.
    enum CodingKeys: String, CodingKey { case id, start, end, text, confidence, locale }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(confidence, forKey: .confidence)
        // Omitted when nil, which is the single-pass case, so the 130 KB-per-entry measurement that
        // justified dropping `id` is not quietly undone for every existing import.
        try c.encodeIfPresent(locale, forKey: .locale)
    }

    // Lenient for the same reason as `Transcript`: a segment missing its id or confidence is worth
    // keeping, not worth losing the surrounding history file over.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try c.decodeIfPresent(TimeInterval.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(TimeInterval.self, forKey: .end) ?? start
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
        locale = try? c.decodeIfPresent(String.self, forKey: .locale)
    }
}

// MARK: - RefinementRecord

/// What the on-device model did to a dictation *before it was inserted*, when the user has asked for
/// that (`Settings.refineBeforeInsert`).
///
/// **Why this is stored beside `Transcript.text` rather than in it.** `text` is the record of what
/// the person said; a refinement is a derived reading of it. Overwriting `text` with cleaned prose
/// would destroy the only copy of the actual speech, in an app whose entire premise is a faithful
/// record — and it would do it silently, hours before the user noticed. So the refined string that
/// reached the cursor lives here, and the history pane shows both.
///
/// On-demand refinements made from the history pane are deliberately **not** stored: they are a
/// reading of a transcript the user can ask for again in about a second, and persisting every one
/// would grow the history file with text nobody has decided to keep. Only the refinement that was
/// actually inserted into a document is a fact about what happened.
public struct RefinementRecord: Codable, Hashable, Sendable {

    public var action: RefinementAction
    /// The refined text that was inserted, or `nil` when refinement did not produce one.
    public var text: String?
    /// Wall-clock seconds the model took. Kept because it is the cost the user opted into, and the
    /// only place they can see what it actually is on their machine (measured 1.0 s warm, 2.9 s cold).
    public var duration: TimeInterval
    public var localeIdentifier: String
    /// True when Apple does not list `localeIdentifier` as supported by the on-device model. The
    /// output is still in the dictated language — this flags "no guarantees". See `TextRefiner`.
    public var localeUnsupported: Bool
    /// Why nothing was refined, when `text` is `nil`. One sentence, shown verbatim.
    ///
    /// A failure here is never allowed to cost the dictation: what the user said is inserted
    /// unchanged and this says so, rather than the text vanishing into a model error.
    public var failure: String?

    public init(
        action: RefinementAction,
        text: String? = nil,
        duration: TimeInterval = 0,
        localeIdentifier: String = Settings.Default.localeIdentifier,
        localeUnsupported: Bool = false,
        failure: String? = nil
    ) {
        self.action = action
        self.text = text
        self.duration = duration
        self.localeIdentifier = localeIdentifier
        self.localeUnsupported = localeUnsupported
        self.failure = failure
    }

    /// True when the text that reached the cursor was the refined one rather than the transcript.
    public var didInsertRefinedText: Bool {
        guard let text else { return false }
        return !text.isEmpty
    }
}

/// One completed dictation. `rawText` and `text` are both kept so the history pane can show the
/// raw-vs-corrected diff — without that, the user has no way to tell whether the dictionary did
/// anything at all.
public struct Transcript: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    /// Exactly what the speech engine produced, before the dictionary touched it.
    public var rawText: String
    /// What was actually injected.
    public var text: String
    public var corrections: [CorrectionHit]
    public var audioDuration: TimeInterval
    /// Wall clock from end-of-speech to final result. The number the blog post benchmarks.
    public var transcribeDuration: TimeInterval
    /// The single locale this transcript is attributed to.
    ///
    /// For a dual-pass import that landed on more than one language this is the locale that won the
    /// most *seconds of recognised audio*, and `localeIdentifiers` carries the rest. Dominant-by-audio
    /// rather than by section count or word count on purpose: sections vary in length, and word
    /// counts are exactly the quantity a weaker acoustic model deflates, so counting words would let
    /// the language that transcribed *worse* look like the smaller share of the recording.
    public var localeIdentifier: String

    /// Every locale that contributed text, ordered by that same share, descending — and **empty
    /// whenever there is only one**, which is every single-pass transcript.
    ///
    /// This field exists because `localeIdentifier` alone would be a false claim about a mixed
    /// transcript: a recording that is two-thirds Indonesian and one-third English is not an
    /// Indonesian recording, and writing `id-ID` there and stopping would say it was. So the
    /// dominant locale stays in the field every existing reader already understands, and the full
    /// truth sits beside it where the UI can show "id-ID + en-US".
    public var localeIdentifiers: [String]

    public var engine: String
    public var targetBundleID: String?
    public var targetAppName: String?
    public var injection: InjectionOutcome

    /// RECON §20: `.bufferingNewest(n)` discards the *oldest* element, so a consumer stall silently
    /// deletes the beginning of the utterance and looks like a model failure. Non-zero means the UI must
    /// say "transcript may be incomplete" rather than let the user believe this is what they said.
    public var droppedBuffers: Int
    /// Words whose `transcriptionConfidence` came back below 0.5. RECON measured this as strongly
    /// discriminative (misheard "Visa" 0.05, "claw" 0.31, versus 0.998 for a correct word), so these
    /// become one-click "add a correction" suggestions in the history pane.
    public var lowConfidenceWords: [String]

    /// Live dictation or a transcribed file. Absent from pre-import history files, where `.dictated`
    /// is the only thing it could have been.
    public var source: TranscriptSource
    /// Timed segments, ascending by `start`. Empty for dictated transcripts; populated for imported
    /// ones so they can be exported as subtitles.
    public var segments: [TranscriptSegment]

    /// How much of the audio actually became words, and one sentence about it — or `nil` when the
    /// transcript predates the measurement or there was nothing measurable to say.
    ///
    /// Stored rather than recomputed on read because the honest denominator is not recoverable
    /// later: `RecognitionQuality` prefers *detected speech* from `SpeechSegmenter`, which needs the
    /// decoded audio, and by the time a history row is drawn the file may not even exist. See
    /// `RecognitionQuality` for the 70-minute meeting that made this necessary.
    public var quality: RecognitionQuality?

    /// What the on-device language model did to this dictation before it was inserted, or `nil` —
    /// which is every transcript unless the user turned `Settings.refineBeforeInsert` on.
    ///
    /// See `RefinementRecord` for why the refined string is kept here instead of replacing `text`.
    public var refinement: RefinementRecord?

    /// The engine identifier written into new transcripts. RECON §1: `DictationTranscriber`, not
    /// `SpeechTranscriber` — contextual-string biasing is a measured no-op on the latter.
    public static let currentEngine = "apple.dictationtranscriber"

    /// The engine identifier written into imported transcripts that used `SpeechTranscriber`.
    /// Measured on this machine over a 377 s script: 4.2 % word error and 66x realtime, against
    /// 10.1 % and 15x for `DictationTranscriber` on the same audio. See `SpeechEngine.build(module:locale:)`.
    public static let generalEngine = "apple.speechtranscriber"

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        rawText: String,
        text: String,
        corrections: [CorrectionHit] = [],
        audioDuration: TimeInterval = 0,
        transcribeDuration: TimeInterval = 0,
        localeIdentifier: String = Settings.Default.localeIdentifier,
        localeIdentifiers: [String] = [],
        engine: String = Transcript.currentEngine,
        targetBundleID: String? = nil,
        targetAppName: String? = nil,
        injection: InjectionOutcome = .notAttempted,
        droppedBuffers: Int = 0,
        lowConfidenceWords: [String] = [],
        source: TranscriptSource = .dictated,
        segments: [TranscriptSegment] = [],
        quality: RecognitionQuality? = nil,
        refinement: RefinementRecord? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawText = rawText
        self.text = text
        self.corrections = corrections
        self.audioDuration = audioDuration
        self.transcribeDuration = transcribeDuration
        self.localeIdentifier = localeIdentifier
        // Normalised here rather than trusted: a single-element list is the same fact as
        // `localeIdentifier`, and `isMixedLanguage` reading `count > 1` must not depend on callers
        // remembering that.
        self.localeIdentifiers = localeIdentifiers.count > 1 ? localeIdentifiers : []
        self.engine = engine
        self.targetBundleID = targetBundleID
        self.targetAppName = targetAppName
        self.injection = injection
        self.droppedBuffers = droppedBuffers
        self.lowConfidenceWords = lowConfidenceWords
        self.source = source
        self.segments = segments
        self.quality = quality
        self.refinement = refinement
    }

    public var wordCount: Int { Self.wordCount(of: text) }

    /// Words in an arbitrary string, counted exactly as ``wordCount`` counts them.
    ///
    /// Spelled once so a second caller cannot count differently: the history pane needs the count of
    /// `rawText` as well as of `text`, and two counting rules in one panel would print two numbers
    /// for the same transcript.
    public static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// True when the dictionary changed something, so the row can show a marker.
    public var didCorrect: Bool { !corrections.isEmpty }

    /// See `droppedBuffers`.
    public var mayBeIncomplete: Bool { droppedBuffers > 0 }

    /// True when this came from a file rather than the microphone.
    public var isImported: Bool { source.isImported }

    /// True when there is timing information, i.e. when subtitle export is possible.
    public var hasSegments: Bool { !segments.isEmpty }

    /// True when more than one language produced text — i.e. when `localeIdentifier` is a summary
    /// rather than the whole story.
    public var isMixedLanguage: Bool { localeIdentifiers.count > 1 }

    /// Every locale that contributed, always non-empty: the mixed list where there is one, otherwise
    /// the single attributed locale.
    public var contributingLocales: [String] {
        localeIdentifiers.isEmpty ? [localeIdentifier] : localeIdentifiers
    }

    /// True when the recogniser plainly under-read this audio and the UI owes the user a sentence.
    /// A good transcript answers `false` and shows nothing — see `RecognitionQuality`.
    public var hasQualityConcern: Bool { quality?.isConcerning == true }

    // Lenient decoding: `droppedBuffers` and `lowConfidenceWords` were added after the first schema,
    // `source` and `segments` after the second, and a history file is far too valuable to fail to
    // load over missing keys.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        rawText = try c.decodeIfPresent(String.self, forKey: .rawText) ?? ""
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? rawText
        corrections = try c.decodeIfPresent([CorrectionHit].self, forKey: .corrections) ?? []
        audioDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .audioDuration) ?? 0
        transcribeDuration = try c.decodeIfPresent(TimeInterval.self, forKey: .transcribeDuration) ?? 0
        localeIdentifier = try c.decodeIfPresent(String.self, forKey: .localeIdentifier)
            ?? Settings.Default.localeIdentifier
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? Transcript.currentEngine
        targetBundleID = try c.decodeIfPresent(String.self, forKey: .targetBundleID)
        targetAppName = try c.decodeIfPresent(String.self, forKey: .targetAppName)
        injection = try c.decodeIfPresent(InjectionOutcome.self, forKey: .injection) ?? .notAttempted
        droppedBuffers = try c.decodeIfPresent(Int.self, forKey: .droppedBuffers) ?? 0
        lowConfidenceWords = try c.decodeIfPresent([String].self, forKey: .lowConfidenceWords) ?? []
        // `try?` rather than `decodeIfPresent` for these two: they are the newest keys, so a
        // malformed or future-shaped value should degrade to the old behaviour, not lose the entry.
        source = (try? c.decode(TranscriptSource.self, forKey: .source)) ?? .dictated
        segments = (try? c.decode([TranscriptSegment].self, forKey: .segments)) ?? []
        let locales = (try? c.decodeIfPresent([String].self, forKey: .localeIdentifiers)) ?? []
        localeIdentifiers = locales.count > 1 ? locales : []
        // `try?` for the same reason as the two above: a malformed quality block must cost the
        // warning, never the entry. `RecognitionQuality`'s own decoder is lenient in the same way.
        quality = try? c.decodeIfPresent(RecognitionQuality.self, forKey: .quality)
        // `try?` for the same reason as `quality`: a malformed refinement block must cost the note
        // about the refinement, never the transcript it is attached to.
        refinement = try? c.decodeIfPresent(RefinementRecord.self, forKey: .refinement)
    }
}

public enum InjectionOutcome: String, Codable, Hashable, Sendable, CaseIterable {
    /// AX `kAXSelectedTextAttribute` insert, verified by read-back (RECON: never trust the return code).
    case accessibility
    case paste
    case keystrokes
    /// Everything failed; the text was left on the clipboard so the user can paste it themselves.
    case clipboardOnly
    /// Recorded from the app window, no injection wanted.
    case notAttempted
    case failed

    public var isSuccess: Bool {
        switch self {
        case .accessibility, .paste, .keystrokes: true
        case .clipboardOnly, .notAttempted, .failed: false
        }
    }

    public var displayName: String {
        switch self {
        case .accessibility: "Accessibility"
        case .paste: "Paste"
        case .keystrokes: "Keystrokes"
        case .clipboardOnly: "Clipboard only"
        case .notAttempted: "Not injected"
        case .failed: "Failed"
        }
    }
}

// MARK: - Store

/// Owns `history.json`. Newest first, trimmed to `Settings.historyLimit`, written atomically and
/// debounced so a burst of short dictations does not thrash the disk.
@MainActor @Observable
public final class HistoryStore {
    public static let shared = HistoryStore(fileURL: AppPaths.historyFile)

    public private(set) var transcripts: [Transcript] = []

    /// The running sum behind ``totalWords``.
    ///
    /// Kept rather than recomputed because `Transcript.wordCount` splits the whole text on
    /// whitespace on every call — measured on this machine at 4.6–6.1 ms for one 10,200-word
    /// imported transcript — and `EquipmentRail.totals` reads `totalWords` on every render of the
    /// rail, which includes every keystroke typed into the history pane's search field. The reduce
    /// it replaced was O(all text in the store) at exactly that frequency.
    ///
    /// A plain stored property, deliberately **not** `@ObservationIgnored`: the rail has to
    /// invalidate when this number changes, and observing the sum rather than the array means it
    /// invalidates when the *number* changes instead of whenever any transcript is touched.
    ///
    /// Every mutation path below maintains it — `append` (including its trim), `remove`,
    /// `removeAll`, and `adopt` for the four places a load replaces the array wholesale.
    /// `HistoryStoreTests.wordTotalTracksEveryMutation` holds the cache to the reduce.
    private var wordTotal = 0

    /// One sentence-or-three about the last load, or `nil` when it went normally.
    ///
    /// Deliberately **non-nil after a successful recovery**, because a recovery is news: it is the
    /// only place the app says how many entries came back and where the bytes it could not read were
    /// put. Read it together with `recoveredEntryCount` — a reader that treats non-nil as "failed"
    /// tells the user their history could not be read while they are looking at it.
    public private(set) var lastLoadError: String?
    /// How many entries the last load rescued from `history.json.bak`, or `nil` when nothing was
    /// rescued — which is every ordinary launch.
    ///
    /// Exists so the UI can tell a recovery from a failure without matching substrings of
    /// `lastLoadError`, which would make the message's wording load-bearing.
    public private(set) var recoveredEntryCount: Int?
    /// Where the bytes that could not be read were moved to, or `nil` when nothing was moved.
    ///
    /// `nil` covers two different situations and the UI must not conflate them: an ordinary load
    /// (nothing to move) and a quarantine that *failed* (`lastLoadError` says so in words, and the
    /// bytes are still at `fileURL`).
    public private(set) var quarantinedFileURL: URL?

    /// The quarantine file's name on its own, for a message that must not print a home directory.
    public var quarantinedFileName: String? { quarantinedFileURL?.lastPathComponent }

    /// Why the terminal flush could not write, or `nil` if it has not failed.
    ///
    /// Exists so the failure is assertable and, later, showable. `flushPendingSave()` runs from
    /// `applicationWillTerminate` with no UI left to report to, so the log is the only channel at the
    /// time — but the log is also not something a test can read, and an untestable error path is how
    /// this one stayed a bare `try?` for as long as it did.
    public private(set) var lastFlushError: String?

    public let fileURL: URL
    /// Injected so tests can supply a fixed limit without touching the real `Settings`.
    private let limitProvider: @MainActor () -> Int

    public init(fileURL: URL, limit: (@MainActor () -> Int)? = nil) {
        self.fileURL = fileURL
        self.limitProvider = limit ?? { Settings.shared.historyLimit }
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    /// Built per write rather than held in a `static let`.
    ///
    /// The debounced path encodes off the main actor, and a `@MainActor` class's statics are
    /// main-actor-isolated too — so a shared encoder would have to be `nonisolated(unsafe)` on a
    /// mutable Foundation class, which is exactly the kind of hole this project does not open for a
    /// few object allocations. Construction is four property assignments; the encode is the cost.
    nonisolated private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        // Not pretty-printed: history is machine-owned and can reach thousands of entries, where
        // indentation is pure disk cost. dictionary.json is the hand-editable one.
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // An absent file is the *most likely* way a store goes missing — an external delete, a
            // half-finished restore, a sync client, or the reinstating `save()` in `recover` failing
            // after a successful quarantine — and it was the one shape that never consulted the
            // backup. `decodeBackup` was reachable only from `recover`, which requires the file to be
            // PRESENT, so finding #2's own headline ("the `.bak` that would save it is never read")
            // stayed open for precisely the case that reaches it soonest.
            //
            // Nothing is quarantined here, and the message says "is not there" rather than "could not
            // be read": there is no file to move aside, and inventing a mystery file to explain its
            // own absence is the litter `recover` refuses to create for a 0-byte store.
            if let recovered = decodeBackup() {
                adopt(recovered)
                recoveredEntryCount = recovered.count
                quarantinedFileURL = nil
                lastLoadError = "\(fileURL.lastPathComponent) is not there."
                    + " Recovered \(recovered.count) entr\(recovered.count == 1 ? "y" : "ies")"
                    + " from the backup."
                Log.data.notice("recovered \(recovered.count, privacy: .public) history entries from the backup; the store file was absent")
                // Reinstate now. `writeAtomically` skips `keepPreviousVersion` when the destination
                // is absent, so THIS write does not consume the backup — but the second save would
                // copy the reinstated file straight over it, so a recovery that is not written back
                // is one dictation away from being lost anyway.
                do { try save() } catch {
                    Log.data.error("could not reinstate history.json after recovering from the backup: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
            presentEmptyStore()
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // This read used to sit outside the `do` below, so an *unreadable* file — as opposed to
            // an undecodable one — skipped the quarantine and the backup entirely and was then
            // replaced by the next save. Same enemy, same treatment.
            Log.data.error("History read failed: \(error.localizedDescription, privacy: .public)")
            try recover(from: .unreadable(error))
            return
        }

        if data.isEmpty {
            // A 0-byte file is not an empty store. It is the characteristic output of a truncating
            // external writer, which is the trigger the recovery was built for — and reading it as
            // "the user has no history" was the worst hole in that recovery: no quarantine, no
            // backup, `lastLoadError` nil so the UI said nothing, and then the first append's save
            // had `keepPreviousVersion` copy the 0 bytes over the `.bak`. The history was gone on
            // the first dictation instead of surviving one write of grace.
            try recover(from: .empty)
            return
        }

        do {
            let loaded = try Self.decoder.decode([Transcript].self, from: data)
            // Sort rather than trust: an externally-touched file, or a schema migration, should still
            // present newest-first.
            adopt(loaded.sorted { $0.createdAt > $1.createdAt })
            clearLoadDiagnostics()
        } catch {
            Log.data.error("History decode failed: \(error.localizedDescription, privacy: .public)")
            try recover(from: .undecodable(error))
        }
    }

    /// A load that found nothing to load: no file, or a 0-byte file with no backup worth adopting.
    private func presentEmptyStore() {
        adopt([])
        clearLoadDiagnostics()
    }

    /// Replace the whole array and re-derive ``wordTotal`` from it.
    ///
    /// The one entry point for a wholesale replacement — a successful load, a recovery from the
    /// backup, or an empty store — so the cached total cannot be left describing the previous
    /// contents. `append`/`remove`/`removeAll` adjust it incrementally instead, because they know
    /// exactly which entries moved.
    private func adopt(_ replacement: [Transcript]) {
        transcripts = replacement
        wordTotal = replacement.reduce(0) { $0 + $1.wordCount }
    }

    private func clearLoadDiagnostics() {
        lastLoadError = nil
        recoveredEntryCount = nil
        quarantinedFileURL = nil
    }

    /// The one generation `AppPaths.writeAtomically` keeps.
    ///
    /// Read here and nowhere else. Before this, a grep across `Sources/` found one write site for
    /// `.bak` and *zero* reads, so the only backup Edict has was reachable only by a user who knew
    /// the path, knew to quit first, and knew to rename it — which is to say, not reachable.
    private var backupURL: URL { fileURL.appendingPathExtension("bak") }

    /// `history.json` is present and could not become the store. Move the bytes out of the way of
    /// the next save, then try the backup.
    ///
    /// Two orderings matter and only one of them is the intuitive one.
    ///
    /// The `.bak` is read *before* the quarantine, which is safe because they touch different files
    /// and buys the one decision the quarantine cannot make for itself: whether a 0-byte
    /// `history.json` is worth keeping at all. It is not, unless a recovery is actually happening —
    /// otherwise the support directory collects mystery files that hold nothing and that no message
    /// explains, because a bare 0-byte file is also what a legitimately emptied store looks like.
    ///
    /// The quarantine still happens before anything is *written*, and for the two non-empty shapes it
    /// happens even with no backup to adopt. The file's real enemy is not the failure that got us
    /// here, it is the next `append` — `scheduleSave` fires 500 ms later and `save()` writes the whole
    /// store — so an unreadable file left in place is an overwritten file, which is amendment 39's
    /// incident with a decode error standing in for the stray verification run. See
    /// `AppPaths.quarantineUnreadableFile` for why refusing to save instead is the wrong trade.
    ///
    /// On a failed recovery `transcripts` is deliberately left untouched rather than emptied: at
    /// launch it is already empty, and on any later call it holds entries this process appended,
    /// which are the only copy of themselves.
    private func recover(from kind: UnusableStoreFile) throws {
        let recovered = decodeBackup()
        let quarantined = (recovered != nil || !kind.isEmptyFile)
            ? AppPaths.quarantineUnreadableFile(at: fileURL)
            : nil
        quarantinedFileURL = quarantined
        var message = kind.sentence(about: fileURL.lastPathComponent)

        if let recovered {
            adopt(recovered)
            recoveredEntryCount = recovered.count
            message += " Recovered \(recovered.count) entr\(recovered.count == 1 ? "y" : "ies") from the backup."
            if let quarantined {
                message += " The unreadable file is kept as \(quarantined.lastPathComponent)."
                lastLoadError = message
                Log.data.notice("Recovered \(recovered.count, privacy: .public) history entries from the backup")
                // Write the recovered entries back now. Without this the recovery lasts exactly as
                // long as the process: `load()` returns early when `history.json` is absent, so the
                // next launch would read a missing file, find nothing, and leave the `.bak` unread —
                // the very unreachable-backup bug this method exists to close.
                do { try save() } catch {
                    Log.data.error("could not reinstate history.json after recovery: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                // The quarantine failed, so `history.json` still holds the only copy of the bytes
                // nobody could read — and writing now would be worse than not writing.
                // `writeAtomically` would take the tmp-plus-replace branch, `keepPreviousVersion`
                // would copy those unreadable bytes straight over the `.bak` this recovery came
                // from, and the next dictation 500 ms later would copy the reinstated file over that.
                // The original bytes would be gone in two writes: "exactly one write of grace",
                // which is the phrase for the bug the quarantine exists to remove. So the reinstating
                // save is skipped, and the message says so rather than quietly dropping a clause.
                message += " Edict could not move it aside, so those bytes are still in"
                    + " \(fileURL.lastPathComponent) and the recovered entries were not written back."
                    + " Copy that file somewhere safe — the next dictation will replace it."
                lastLoadError = message
                Log.data.error("recovered history from the backup but could not quarantine \(self.fileURL.lastPathComponent, privacy: .public); skipped the reinstating save")
            }
            return
        }

        if kind.isEmptyFile {
            // Nothing to adopt and nothing to report: this is the empty store `load()` has always
            // presented for a 0-byte file, reached now with the backup genuinely consulted first.
            //
            // Guarded on `transcripts.isEmpty` so the doc above stays true. `load()` is called once,
            // from `bootstrap`, so today this only ever runs against an empty store — but it is
            // `public`, and a second call that found a 0-byte file with no usable backup would
            // otherwise discard entries this process appended, which at that moment are the only
            // copy of themselves. A rule that holds only because of a call-site count is not a rule.
            if transcripts.isEmpty {
                presentEmptyStore()
            } else {
                lastLoadError = "\(fileURL.lastPathComponent) is empty and there is no usable"
                    + " backup. The \(transcripts.count) entr\(transcripts.count == 1 ? "y" : "ies")"
                    + " already in this session are kept."
            }
            return
        }

        message += quarantined.map { " No usable backup; the unreadable file is kept as \($0.lastPathComponent)." }
            // Not silence. Before this, a failed move just omitted the clause, so the message named
            // no file at all and the only pointer to the user's bytes was the unified log.
            // The warning matters MOST here and was the one branch that omitted it: with no backup
            // to adopt, that file holds the user's only copy of those bytes.
            ?? (" No usable backup, and Edict could not move the unreadable file aside — those bytes"
                + " are still in \(fileURL.lastPathComponent). Copy that file somewhere safe: the"
                + " next dictation will replace it.")
        lastLoadError = message
        // Still thrown. The caller logs it, and the load genuinely did not produce the user's history.
        if let error = kind.underlyingError { throw error }
    }

    /// Decode `history.json.bak`, or `nil` when there is nothing usable in it.
    ///
    /// An empty array counts as nothing usable: adopting it would let the app report "recovered 0
    /// entries" as though something had been rescued, and this project's rule is never to claim an
    /// outcome the code did not verify.
    private func decodeBackup() -> [Transcript]? {
        guard let data = try? Data(contentsOf: backupURL), !data.isEmpty,
              let loaded = try? Self.decoder.decode([Transcript].self, from: data),
              !loaded.isEmpty
        else { return nil }
        // Sorted the way any load sorts, and trimmed to `historyLimit` — which `load()` itself does
        // *not* do. The asymmetry is deliberate rather than an oversight: this store is written
        // straight back to disk a few lines below, so an untrimmed recovery would persist entries
        // above the user's own limit that the very next `append` would then drop anyway.
        let sorted = loaded.sorted { $0.createdAt > $1.createdAt }
        let limit = max(1, limitProvider())
        return sorted.count > limit ? Array(sorted.prefix(limit)) : sorted
    }

    /// Encode and write on the calling actor.
    ///
    /// Synchronous on purpose: `flushPendingSave()` runs from `applicationWillTerminate`, which
    /// cannot await, and it is the only reason a dictation made in the last 500 ms reaches disk.
    public func save() throws {
        saveTask?.cancel()
        saveTask = nil
        let data = try Self.makeEncoder().encode(transcripts)
        try AppPaths.writeAtomically(data, to: fileURL)
        // Cleared only on the far side of a successful write. `lastFlushError` is surfaced long after
        // it is set — there is no UI at termination — so leaving a stale one behind meant the first
        // time the user ever saw it, it could describe a failure a later save had already fixed.
        lastFlushError = nil
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }

            // Snapshot on the main actor, encode off it. `save()` re-encodes the *entire* store on
            // every debounced write, and `Transcript.segments` are inlined — one imported file adds
            // ~129 KB — so a few hundred retained imports turn this into a visible hitch on the actor
            // that draws the window. Measured 6–8 ms at the user's real 450 KB store, which is why
            // this is a shape fix rather than an urgent one.
            //
            // Capping the store by bytes to keep the encode small is the wrong fix and is not done
            // here: it deletes entries the user's own `historyLimit` told the app to keep, which is
            // the class of loss amendment 39 exists to prevent.
            let snapshot = self.transcripts
            let data: Data
            do {
                data = try await Self.encodeOffActor(snapshot)
            } catch {
                Log.data.error("History encode failed: \(error.localizedDescription, privacy: .public)")
                // `saveTask` is deliberately left alone. Clearing it here — as this branch used to,
                // with none of the cancellation care the write branch below takes — could disarm
                // `flushPendingSave()` for a task this one no longer owns: a `save()` that arrived
                // during the encode has already cancelled this task and installed its own state, and
                // niling the field would tell the terminal flush there was nothing pending.
                // Leaving it non-nil is also the safer failure on its own terms: the flush at quit
                // then retries the encode synchronously instead of standing down.
                return
            }

            // The write deliberately stays on the main actor, and `saveTask` deliberately stays
            // non-nil across the await above. Both hold the same invariant: every write to
            // `history.json` is issued from one actor in one order. Moving the write off too would
            // let a `flushPendingSave()` arriving mid-encode run `writeAtomically` concurrently with
            // this one, and `replaceItemAt` promises atomicity, not ordering — so the older snapshot
            // could land last. That is amendment 39's failure (writing the wrong contents)
            // reintroduced by a fix for latency nobody can perceive. Cancellation is the handshake:
            // `save()` cancels this task before writing, and the guard below stands down for it.
            guard !Task.isCancelled else { return }
            self.saveTask = nil
            do {
                try AppPaths.writeAtomically(data, to: self.fileURL)
                // Same reason as in `save()`: a write that worked is the evidence that an earlier
                // terminal-flush failure is no longer the current state of the disk.
                self.lastFlushError = nil
            } catch {
                // Record it, and do NOT leave the flush disarmed. `saveTask` was cleared above, so
                // `flushPendingSave()`'s `guard saveTask != nil` would stand down at quit and this
                // transcript would never be retried — which is the policy the encode-failure branch
                // above argues for in writing, so breaking it here would leave the file stating one
                // rule in one branch and the opposite in the next. Re-arming costs one synchronous
                // retry at quit; not re-arming costs the dictation.
                self.lastFlushError = error.localizedDescription
                self.saveTask = Task { @MainActor [weak self] in _ = self }
                Log.data.error("History save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Encode away from the main actor.
    ///
    /// `nonisolated` plus `Task.detached`: a plain `async` method on this class would inherit
    /// `@MainActor` and run the encode exactly where it runs today. The array is passed by value and
    /// `Transcript` is `Sendable`, so the encode cannot observe a half-mutated store.
    nonisolated private static func encodeOffActor(_ transcripts: [Transcript]) async throws -> Data {
        try await Task.detached(priority: .utility) {
            try makeEncoder().encode(transcripts)
        }.value
    }

    /// Force any pending debounced write to disk now. Call before termination.
    public func flushPendingSave() {
        guard saveTask != nil else { return }
        // NOT `try?`. This runs from `applicationWillTerminate` — which is the only reason
        // `NSSupportsSuddenTermination` is false — so it is the last chance the work of the previous
        // 500 ms has to reach disk, and there is no UI left to report to. Swallowing the error here
        // made a lost transcript invisible rather than merely lost; every other write path in
        // this file logs its failures, so the bare `try?` was an inconsistency, not a policy.
        do {
            try save()
        } catch {
            lastFlushError = error.localizedDescription
            Log.data.error(
                "terminal transcript flush failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    public func append(_ transcript: Transcript) {
        transcripts.insert(transcript, at: 0)
        wordTotal += transcript.wordCount
        let limit = max(1, limitProvider())
        if transcripts.count > limit {
            // The trim is the half of this method a cached total is easiest to get wrong: the
            // entries it drops take their words with them, and a cache that only ever added the
            // new transcript would climb for ever on a store sitting at its limit.
            let dropped = transcripts.count - limit
            for old in transcripts.suffix(dropped) { wordTotal -= old.wordCount }
            transcripts.removeLast(dropped)
        }
        scheduleSave()
    }

    public func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let before = transcripts.count
        var removedWords = 0
        transcripts.removeAll { transcript in
            guard ids.contains(transcript.id) else { return false }
            removedWords += transcript.wordCount
            return true
        }
        guard transcripts.count != before else { return }
        wordTotal -= removedWords
        scheduleSave()
    }

    public func removeAll() {
        guard !transcripts.isEmpty else { return }
        transcripts.removeAll()
        wordTotal = 0
        scheduleSave()
    }

    /// Case- and diacritic-insensitive substring match over `text` and `rawText`.
    /// An empty query returns everything, so the pane can bind straight to the search field.
    public func search(_ query: String) -> [Transcript] {
        let q = query.trimmed
        guard !q.isEmpty else { return transcripts }
        return transcripts.filter {
            $0.text.containsLoosely(q)
                || $0.rawText.containsLoosely(q)
                // The filename and the app are the two things a user actually remembers about a row
                // they are trying to find again, and neither was searchable. Both are already stored
                // on every transcript and both are already PRINTED in the detail header — so the
                // obvious query for an imported transcript, the name of the file it came from,
                // returned nothing while the answer sat on screen.
                || ($0.source.importedFilename?.containsLoosely(q) ?? false)
                || ($0.targetAppName?.containsLoosely(q) ?? false)
        }
    }

    /// Words across every retained transcript; printed by `EquipmentRail.totals`.
    ///
    /// A cache read, not a reduce — see ``wordTotal`` for the measurement and for the four
    /// mutation paths that keep it true.
    public var totalWords: Int { wordTotal }

    /// Total audio captured across all retained dictations; shown in the history pane footer.
    public var totalAudioDuration: TimeInterval {
        transcripts.reduce(0) { $0 + $1.audioDuration }
    }
}
