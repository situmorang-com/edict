import Foundation
import Testing
@testable import EdictKit

/// As with the dictionary tests: temporary directories only, and an injected history limit so the
/// user's real `Settings` (and `UserDefaults.standard`) are never touched.
@Suite("HistoryStore")
@MainActor
struct HistoryStoreTests {

    // MARK: Fixture

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore(limit: Int = 5000) throws -> (store: HistoryStore, dir: URL) {
        let dir = try makeTempDirectory()
        let store = HistoryStore(fileURL: dir.appendingPathComponent("history.json"), limit: { limit })
        return (store, dir)
    }

    private func transcript(
        _ text: String,
        raw: String? = nil,
        at seconds: TimeInterval,
        corrections: [CorrectionHit] = []
    ) -> Transcript {
        Transcript(
            createdAt: Date(timeIntervalSince1970: seconds),
            rawText: raw ?? text,
            text: text,
            corrections: corrections,
            audioDuration: 2.5,
            transcribeDuration: 0.2,
            injection: .accessibility
        )
    }

    // MARK: Value type

    @Test("A new transcript records the engine RECON established as the only one that supports biasing")
    func engineIdentifier() {
        #expect(Transcript.currentEngine == "apple.dictationtranscriber")
        #expect(transcript("hello", at: 0).engine == "apple.dictationtranscriber")
    }

    @Test("wordCount counts words, not characters, and tolerates messy whitespace")
    func wordCount() {
        #expect(transcript("", at: 0).wordCount == 0)
        #expect(transcript("   ", at: 0).wordCount == 0)
        #expect(transcript("one", at: 0).wordCount == 1)
        #expect(transcript("one two  three\nfour\t five", at: 0).wordCount == 5)
    }

    @Test("droppedBuffers surfaces as an incompleteness flag")
    func droppedBuffersFlag() {
        var t = transcript("partial", at: 0)
        #expect(!t.mayBeIncomplete)
        // RECON §20: `.bufferingNewest(n)` drops the OLDEST buffer, so this silently eats the start of
        // the utterance and must be visible to the user rather than read as a model failure.
        t.droppedBuffers = 3
        #expect(t.mayBeIncomplete)
    }

    @Test("didCorrect drives the history row's dictionary marker")
    func didCorrect() {
        #expect(!transcript("clean", at: 0).didCorrect)
        let hit = CorrectionHit(entryID: UUID(), from: "cloud code", to: "Claude Code", offset: 0)
        #expect(transcript("Claude Code", raw: "cloud code", at: 0, corrections: [hit]).didCorrect)
    }

    @Test("Injection outcomes report success honestly")
    func injectionOutcomeSuccess() {
        #expect(InjectionOutcome.accessibility.isSuccess)
        #expect(InjectionOutcome.paste.isSuccess)
        #expect(InjectionOutcome.keystrokes.isSuccess)
        // The user still has to paste manually, so this is not a success.
        #expect(!InjectionOutcome.clipboardOnly.isSuccess)
        #expect(!InjectionOutcome.notAttempted.isSuccess)
        #expect(!InjectionOutcome.failed.isSuccess)
    }

    // MARK: Round-tripping through the JSON file

    @Test("Transcripts survive a save/load round trip, including the correction hits")
    func roundTripsThroughDisk() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let hit = CorrectionHit(entryID: UUID(), from: "cloud code", to: "Claude Code", offset: 9)
        var rich = transcript("I ran Claude Code", raw: "I ran cloud code", at: 1_700_000_000, corrections: [hit])
        rich.targetBundleID = "com.apple.Safari"
        rich.targetAppName = "Safari"
        rich.localeIdentifier = "en-US"
        rich.droppedBuffers = 2
        rich.lowConfidenceWords = ["visa", "claw"]

        store.append(rich)
        store.append(transcript("second", at: 1_700_000_100))
        try store.save()

        let reloaded = HistoryStore(fileURL: store.fileURL, limit: { 5000 })
        try reloaded.load()

        #expect(reloaded.transcripts.count == 2)
        #expect(reloaded.transcripts == store.transcripts)

        let restored = try #require(reloaded.transcripts.first { $0.id == rich.id })
        #expect(restored.rawText == "I ran cloud code")
        #expect(restored.text == "I ran Claude Code")
        #expect(restored.corrections.count == 1)
        #expect(restored.corrections[0].from == "cloud code")
        #expect(restored.corrections[0].offset == 9)
        #expect(restored.targetBundleID == "com.apple.Safari")
        #expect(restored.droppedBuffers == 2)
        #expect(restored.lowConfidenceWords == ["visa", "claw"])
        #expect(restored.injection == .accessibility)
    }

    @Test("Loading a missing or empty file is not an error")
    func loadingNothing() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.load()
        #expect(store.transcripts.isEmpty)
        #expect(store.lastLoadError == nil)

        try Data().write(to: store.fileURL)
        try store.load()
        #expect(store.transcripts.isEmpty)
        #expect(store.lastLoadError == nil)
    }

    @Test("A history file written before droppedBuffers existed still loads")
    func lenientDecodingOfOlderSchema() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")

        let older = """
        [{
          "id": "6E7F0E4A-1111-4222-8333-444455556666",
          "createdAt": "2026-08-24T10:00:00Z",
          "rawText": "cloud code",
          "text": "Claude Code",
          "corrections": [],
          "audioDuration": 1.5,
          "transcribeDuration": 0.1,
          "localeIdentifier": "en-US",
          "engine": "apple.dictationtranscriber",
          "injection": "paste"
        }]
        """
        try older.write(to: url, atomically: true, encoding: .utf8)

        let store = HistoryStore(fileURL: url, limit: { 5000 })
        try store.load()

        #expect(store.transcripts.count == 1)
        #expect(store.transcripts[0].droppedBuffers == 0)
        #expect(store.transcripts[0].lowConfidenceWords.isEmpty)
        #expect(store.transcripts[0].injection == .paste)
        #expect(store.lastLoadError == nil)
    }

    @Test("Malformed JSON is reported rather than silently discarding the user's history")
    func malformedJSONIsReported() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.append(transcript("keep me", at: 100))
        try store.save()
        try "{ not an array".write(to: store.fileURL, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) { try store.load() }
        #expect(store.transcripts.count == 1)
        #expect(store.lastLoadError != nil)
        // There is no `.bak` here — `save()` was this path's first write — so recovery has nothing to
        // adopt and the load still fails. What it must no longer do is leave the unreadable bytes
        // where the next debounced save will replace them. See `StoreRecoveryTests`.
        let asideBytes = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("history.unreadable-") }
        #expect(asideBytes.count == 1)
    }

    // MARK: Ordering, trimming, removal

    @Test("append puts the newest transcript first")
    func newestFirst() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.append(transcript("oldest", at: 100))
        store.append(transcript("middle", at: 200))
        store.append(transcript("newest", at: 300))

        #expect(store.transcripts.map(\.text) == ["newest", "middle", "oldest"])
    }

    @Test("Load re-sorts newest-first rather than trusting the file's order")
    func loadResorts() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Written deliberately oldest-first, as an external editor or a migration might leave it.
        let data = try JSONEncoder.iso8601.encode([
            transcript("oldest", at: 100),
            transcript("newest", at: 300),
        ])
        try data.write(to: store.fileURL)

        try store.load()
        #expect(store.transcripts.map(\.text) == ["newest", "oldest"])
    }

    @Test("append trims to the configured limit, dropping the oldest")
    func trimsToLimit() throws {
        let (store, dir) = try makeStore(limit: 3)
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 1...10 { store.append(transcript("t\(i)", at: TimeInterval(i))) }

        #expect(store.transcripts.count == 3)
        #expect(store.transcripts.map(\.text) == ["t10", "t9", "t8"])
    }

    @Test("remove and removeAll")
    func removal() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = transcript("a", at: 100)
        let b = transcript("b", at: 200)
        store.append(a)
        store.append(b)

        store.remove(ids: [])
        #expect(store.transcripts.count == 2)
        store.remove(ids: [UUID()])                 // unknown id: no-op
        #expect(store.transcripts.count == 2)
        store.remove(ids: [a.id])
        #expect(store.transcripts.map(\.text) == ["b"])

        store.removeAll()
        #expect(store.transcripts.isEmpty)
        store.removeAll()                            // idempotent
        #expect(store.transcripts.isEmpty)
    }

    // MARK: Search and aggregates

    @Test("Search covers both the corrected and the raw text, ignoring case and diacritics")
    func search() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.append(transcript("I ran Claude Code", raw: "I ran cloud code", at: 100))
        store.append(transcript("Deployed to Vercel", raw: "Deployed to visa", at: 200))
        store.append(transcript("Meet me at the café", at: 300))

        #expect(store.search("").count == 3)
        #expect(store.search("   ").count == 3)
        #expect(store.search("claude").count == 1)          // case-insensitive
        #expect(store.search("cloud code").count == 1)      // matches the raw text only
        #expect(store.search("visa").count == 1)
        #expect(store.search("cafe").count == 1)            // diacritic-insensitive
        #expect(store.search("nonsense").isEmpty)
    }

    @Test("Aggregates sum over the retained transcripts")
    func aggregates() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(store.totalWords == 0)
        store.append(transcript("one two three", at: 100))
        store.append(transcript("four five", at: 200))
        #expect(store.totalWords == 5)
        #expect(abs(store.totalAudioDuration - 5.0) < 0.0001)
    }

    // MARK: Persistence behaviour

    @Test("The debounced write eventually lands without an explicit save", .timeLimit(.minutes(1)))
    func debouncedSaveLands() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.append(transcript("debounced", at: 100))
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))

        var landed = false
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            if FileManager.default.fileExists(atPath: store.fileURL.path) { landed = true; break }
        }
        #expect(landed)

        let reloaded = HistoryStore(fileURL: store.fileURL, limit: { 5000 })
        try reloaded.load()
        #expect(reloaded.transcripts.map(\.text) == ["debounced"])
    }

    @Test("flushPendingSave writes immediately, for app termination")
    func flushPendingSave() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.append(transcript("flushed", at: 100))
        store.flushPendingSave()

        let reloaded = HistoryStore(fileURL: store.fileURL, limit: { 5000 })
        try reloaded.load()
        #expect(reloaded.transcripts.map(\.text) == ["flushed"])

        // Nothing pending: must not throw and must not clobber the file.
        store.flushPendingSave()
        try reloaded.load()
        #expect(reloaded.transcripts.count == 1)
    }

    @Test("Writes are atomic: a reader never sees a partial file")
    func writesAreAtomic() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 1...50 { store.append(transcript("t\(i)", at: TimeInterval(i))) }
        try store.save()
        // Rewriting must leave no orphaned temp file behind. The one companion that IS expected is
        // `history.json.bak`: `AppPaths.writeAtomically` keeps the outgoing version, because atomic
        // writes protect against a torn file and do nothing about a wrong one — which is the failure
        // that actually cost a user their transcript history.
        //
        // `history.json.bak.new` is deliberately NOT in this list. The backup is now staged there and
        // swapped in with `replaceItemAt`, so that there is never a moment with no backup on disk
        // while the main write proceeds — and a successful swap consumes the staging file. Its
        // presence here would mean the swap did not complete, which is why this stays an exact
        // comparison rather than a "contains the two we care about" check.
        try store.save()

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(contents == ["history.json", "history.json.bak"])
        #expect(!contents.contains { $0.hasSuffix(".tmp") }, "no orphaned temp file")
        #expect(!contents.contains("history.json.bak.new"), "the staged backup was swapped in, not abandoned")

        let reloaded = HistoryStore(fileURL: store.fileURL, limit: { 5000 })
        try reloaded.load()
        #expect(reloaded.transcripts.count == 50)
    }
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
