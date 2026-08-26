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
        quality: RecognitionQuality? = nil
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
    }

    public var wordCount: Int {
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
    public private(set) var lastLoadError: String?

    public let fileURL: URL
    /// Injected so tests can supply a fixed limit without touching the real `Settings`.
    private let limitProvider: @MainActor () -> Int

    public init(fileURL: URL, limit: (@MainActor () -> Int)? = nil) {
        self.fileURL = fileURL
        self.limitProvider = limit ?? { Settings.shared.historyLimit }
    }

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Not pretty-printed: history is machine-owned and can reach thousands of entries, where
        // indentation is pure disk cost. dictionary.json is the hand-editable one.
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            transcripts = []
            lastLoadError = nil
            return
        }
        let data = try Data(contentsOf: fileURL)
        guard !data.isEmpty else {
            transcripts = []
            lastLoadError = nil
            return
        }
        do {
            let loaded = try Self.decoder.decode([Transcript].self, from: data)
            // Sort rather than trust: an externally-touched file, or a schema migration, should still
            // present newest-first.
            transcripts = loaded.sorted { $0.createdAt > $1.createdAt }
            lastLoadError = nil
        } catch {
            lastLoadError = "history.json could not be read: \(error.localizedDescription)"
            Log.data.error("History decode failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public func save() throws {
        saveTask?.cancel()
        saveTask = nil
        let data = try Self.encoder.encode(transcripts)
        try AppPaths.writeAtomically(data, to: fileURL)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            do { try self.save() } catch {
                Log.data.error("History save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Force any pending debounced write to disk now. Call before termination.
    public func flushPendingSave() {
        guard saveTask != nil else { return }
        try? save()
    }

    public func append(_ transcript: Transcript) {
        transcripts.insert(transcript, at: 0)
        let limit = max(1, limitProvider())
        if transcripts.count > limit {
            transcripts.removeLast(transcripts.count - limit)
        }
        scheduleSave()
    }

    public func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let before = transcripts.count
        transcripts.removeAll { ids.contains($0.id) }
        guard transcripts.count != before else { return }
        scheduleSave()
    }

    public func removeAll() {
        guard !transcripts.isEmpty else { return }
        transcripts.removeAll()
        scheduleSave()
    }

    /// Case- and diacritic-insensitive substring match over `text` and `rawText`.
    /// An empty query returns everything, so the pane can bind straight to the search field.
    public func search(_ query: String) -> [Transcript] {
        let q = query.trimmed
        guard !q.isEmpty else { return transcripts }
        return transcripts.filter { $0.text.containsLoosely(q) || $0.rawText.containsLoosely(q) }
    }

    public var totalWords: Int {
        transcripts.reduce(0) { $0 + $1.wordCount }
    }

    /// Total audio captured across all retained dictations; shown in the history pane footer.
    public var totalAudioDuration: TimeInterval {
        transcripts.reduce(0) { $0 + $1.audioDuration }
    }
}
