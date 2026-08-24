import Foundation
import Observation

// MARK: - Shared value types

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
    public var localeIdentifier: String
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

    /// The engine identifier written into new transcripts. RECON §1: `DictationTranscriber`, not
    /// `SpeechTranscriber` — contextual-string biasing is a measured no-op on the latter.
    public static let currentEngine = "apple.dictationtranscriber"

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        rawText: String,
        text: String,
        corrections: [CorrectionHit] = [],
        audioDuration: TimeInterval = 0,
        transcribeDuration: TimeInterval = 0,
        localeIdentifier: String = Settings.Default.localeIdentifier,
        engine: String = Transcript.currentEngine,
        targetBundleID: String? = nil,
        targetAppName: String? = nil,
        injection: InjectionOutcome = .notAttempted,
        droppedBuffers: Int = 0,
        lowConfidenceWords: [String] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.rawText = rawText
        self.text = text
        self.corrections = corrections
        self.audioDuration = audioDuration
        self.transcribeDuration = transcribeDuration
        self.localeIdentifier = localeIdentifier
        self.engine = engine
        self.targetBundleID = targetBundleID
        self.targetAppName = targetAppName
        self.injection = injection
        self.droppedBuffers = droppedBuffers
        self.lowConfidenceWords = lowConfidenceWords
    }

    public var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// True when the dictionary changed something, so the row can show a marker.
    public var didCorrect: Bool { !corrections.isEmpty }

    /// See `droppedBuffers`.
    public var mayBeIncomplete: Bool { droppedBuffers > 0 }

    // Lenient decoding: `droppedBuffers` and `lowConfidenceWords` were added after the first schema,
    // and a history file is far too valuable to fail to load over two missing keys.
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
