import Foundation
import Testing
@testable import EdictKit

/// Every test here works inside its own temporary directory. Nothing may ever touch
/// `~/Library/Application Support/Edict` — that is the user's real, hand-editable dictionary.
@Suite("DictionaryStore")
@MainActor
struct DictionaryStoreTests {

    // MARK: Fixture

    private func makeTempDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeStore() throws -> (store: DictionaryStore, dir: URL) {
        let dir = try makeTempDirectory()
        return (DictionaryStore(fileURL: dir.appendingPathComponent("dictionary.json")), dir)
    }

    // MARK: First run

    @Test("First run seeds a visible starter dictionary and writes it to disk")
    func firstRunSeedsStarterEntries() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.load()

        #expect(store.lastLoadError == nil)
        #expect(!store.entries.isEmpty)
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))

        let terms = store.entries.map(\.displayTerm)
        for expected in ["Claude Code", "Anthropic", "Vercel", "Supabase", "Wispr Flow",
                         "SwiftUI", "Xcode", "macOS", "Obsidian"] {
            #expect(terms.contains(expected), "starter dictionary should ship \(expected)")
        }
        // The one correction that demonstrates layer 2 actually doing something.
        #expect(store.entries.contains {
            $0.kind == .correction(heard: "cloud code", write: "Claude Code")
        })
    }

    @Test("Starter entries have distinct creation timestamps so rule tie-breaks are stable")
    func starterEntriesHaveOrderedTimestamps() {
        let entries = DictionaryStore.starterEntries()
        let dates = entries.map(\.createdAt)
        #expect(zip(dates, dates.dropFirst()).allSatisfy { $0 < $1 })
    }

    // MARK: Round-tripping through the JSON file

    @Test("Entries survive a save/load round trip")
    func roundTripsThroughDisk() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.load()
        let added = store.add(DictionaryEntry(
            kind: .correction(heard: "whisper flow", write: "Wispr Flow"),
            note: "kept mishearing this"
        ))
        var term = DictionaryEntry(kind: .term("Ollama"))
        term.hitCount = 7
        term.lastHitAt = Date(timeIntervalSince1970: 1_700_000_000)
        term.enabled = false
        store.add(term)
        try store.save()

        let reloaded = DictionaryStore(fileURL: store.fileURL)
        try reloaded.load()

        #expect(reloaded.entries.count == store.entries.count)
        #expect(reloaded.entries.map(\.id) == store.entries.map(\.id))
        #expect(reloaded.entries.map(\.kind) == store.entries.map(\.kind))

        let roundTrippedCorrection = try #require(reloaded.entries.first { $0.id == added.id })
        #expect(roundTrippedCorrection.kind == .correction(heard: "whisper flow", write: "Wispr Flow"))
        #expect(roundTrippedCorrection.note == "kept mishearing this")

        let roundTrippedTerm = try #require(reloaded.entries.first { $0.id == term.id })
        #expect(roundTrippedTerm.hitCount == 7)
        #expect(roundTrippedTerm.enabled == false)
        #expect(roundTrippedTerm.lastHitAt == Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("The on-disk shape is flat and hand-editable")
    func onDiskShapeIsHumanReadable() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.load()
        try store.save()
        let json = try String(contentsOf: store.fileURL, encoding: .utf8)

        // Swift's synthesised enum-with-payload encoding would produce `"_0"`; the whole point of the
        // hand-written Codable is that a human can edit this file.
        #expect(!json.contains("_0"))
        #expect(json.contains("\"type\""))
        #expect(json.contains("\"heard\""))
        #expect(json.contains("\"write\""))
        #expect(json.contains("\"term\""))
        // ISO-8601 date strings, not float seconds-since-2001.
        #expect(json.contains("\"createdAt\" : \"20"))
    }

    @Test("A hand-written minimal file loads, and unusable entries are reported not dropped silently")
    func lenientDecoding() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dictionary.json")

        let handWritten = """
        [
          { "term": "Vercel" },
          { "type": "correction", "heard": "cloud code", "write": "Claude Code" },
          { "heard": "soup base", "write": "Supabase", "enabled": false },
          { "heard": "orphan" },
          { "note": "no term at all" }
        ]
        """
        try handWritten.write(to: url, atomically: true, encoding: .utf8)

        let store = DictionaryStore(fileURL: url)
        try store.load()

        #expect(store.entries.count == 4)
        #expect(store.entries[0].kind == .term("Vercel"))
        #expect(store.entries[1].kind == .correction(heard: "cloud code", write: "Claude Code"))
        #expect(store.entries[2].enabled == false)
        // A `heard` with no `write` degrades to a plain term instead of replacing text with "".
        #expect(store.entries[3].kind == .term("orphan"))
        // The unusable object is reported so the pane can say so.
        #expect(store.lastLoadError != nil)
    }

    @Test("Malformed JSON never overwrites the user's file with an empty dictionary")
    func malformedJSONPreservesInMemoryState() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.load()
        let seeded = store.entries.count
        #expect(seeded > 0)

        try "[ this is not json".write(to: store.fileURL, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(store.entries.count == seeded)
        #expect(store.lastLoadError != nil)
        // The launch load now moves the unreadable bytes aside instead of leaving them for the next
        // debounced save to replace. There is no `.bak` on this path — the seed was the first write —
        // so there is nothing to recover from and the load still fails. See `StoreRecoveryTests` for
        // the recovery case and for why the file *watcher's* reload deliberately does not do this.
        let asideBytes = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("dictionary.unreadable-") }
        #expect(asideBytes.count == 1)
    }

    // MARK: Mutation

    @Test("add, update, remove and search")
    func mutationAndSearch() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let entry = store.add(DictionaryEntry(kind: .term("Obsidian"), note: "note taking"))
        store.add(DictionaryEntry(kind: .correction(heard: "cloud code", write: "Claude Code")))
        #expect(store.entries.count == 2)

        var edited = entry
        edited.kind = .term("Obsidian.md")
        store.update(edited)
        #expect(store.entries.first?.displayTerm == "Obsidian.md")

        // Updating an entry that is not present must be a no-op, not an insert.
        store.update(DictionaryEntry(kind: .term("Ghost")))
        #expect(store.entries.count == 2)

        #expect(store.search("").count == 2)
        #expect(store.search("obsidian").count == 1)          // case-insensitive
        #expect(store.search("Claude Code").count == 1)       // searches the write side
        #expect(store.search("note taking").count == 1)       // searches the note
        #expect(store.search("nothing here").isEmpty)

        store.remove(ids: [entry.id])
        #expect(store.entries.count == 1)
        store.remove(ids: [])
        #expect(store.entries.count == 1)
    }

    @Test("Search is diacritic-insensitive")
    func searchIgnoresDiacritics() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.add(DictionaryEntry(kind: .term("Café Data")))
        #expect(store.search("cafe").count == 1)
    }

    @Test("recordHits bumps the counters the biasing ranking depends on")
    func recordHits() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = store.add(DictionaryEntry(kind: .correction(heard: "cloud code", write: "Claude Code")))
        let b = store.add(DictionaryEntry(kind: .term("Vercel")))

        store.recordHits([
            CorrectionHit(entryID: a.id, from: "cloud code", to: "Claude Code", offset: 0),
            CorrectionHit(entryID: a.id, from: "Cloud Code", to: "Claude Code", offset: 20),
            CorrectionHit(entryID: UUID(), from: "ghost", to: "Ghost", offset: 40),
        ])

        #expect(store.entries.first { $0.id == a.id }?.hitCount == 2)
        #expect(store.entries.first { $0.id == a.id }?.lastHitAt != nil)
        #expect(store.entries.first { $0.id == b.id }?.hitCount == 0)
        #expect(store.entries.first { $0.id == b.id }?.lastHitAt == nil)
    }

    // MARK: Compiled rules

    @Test("Compiled rules cover corrections always and terms only when normalisation is on")
    func compiledRules() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.add(DictionaryEntry(kind: .correction(heard: "cloud code", write: "Claude Code")))
        store.add(DictionaryEntry(kind: .term("Vercel")))
        store.add(DictionaryEntry(kind: .term("Ignored"), enabled: false))
        store.add(DictionaryEntry(kind: .correction(heard: "soup base", write: "Supabase"), enabled: false))

        #expect(store.compiledRules(includeTermCaseNormalisation: false).count == 1)
        #expect(store.compiledRules(includeTermCaseNormalisation: true).count == 2)

        // Longest first.
        let rules = store.compiledRules(includeTermCaseNormalisation: true)
        #expect(zip(rules, rules.dropFirst()).allSatisfy { $0.sortWeight >= $1.sortWeight })
    }

    @Test("The compiled-rule cache is invalidated by edits but not by hit counters")
    func rulesCacheInvalidation() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let entry = store.add(DictionaryEntry(kind: .correction(heard: "cloud code", write: "Claude Code")))
        let first = store.compiledRules(includeTermCaseNormalisation: true)
        #expect(first.count == 1)

        store.recordHits([CorrectionHit(entryID: entry.id, from: "cloud code", to: "Claude Code", offset: 0)])
        #expect(store.compiledRules(includeTermCaseNormalisation: true) == first)

        store.add(DictionaryEntry(kind: .term("Vercel")))
        #expect(store.compiledRules(includeTermCaseNormalisation: true).count == 2)
    }

    @Test("The store's corrector applies the user's dictionary end to end")
    func correctorFromStore() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.load()   // starter dictionary: `cloud code` -> `Claude Code`, plus the terms
        let result = store.corrector(includeTermCaseNormalisation: true)
            .apply(to: "I ran cloud code inside xcode on macos.")

        #expect(result.text == "I ran Claude Code inside Xcode on macOS.")
        #expect(result.hits.count == 3)
        // Every hit must be attributable to a real entry, or the history pane cannot link back to it.
        let ids = Set(store.entries.map(\.id))
        #expect(result.hits.allSatisfy { ids.contains($0.entryID) })
    }

    // MARK: Biasing (layer 1)

    @Test("biasingStrings biases toward the write side, never the misheard form")
    func biasingUsesWriteSide() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        store.add(DictionaryEntry(kind: .correction(heard: "cloud code", write: "Claude Code")))
        store.add(DictionaryEntry(kind: .correction(heard: "soup base", write: "Supabase")))

        let strings = store.biasingStrings(limit: 50)
        #expect(strings.contains("Claude Code"))
        #expect(strings.contains("Supabase"))
        #expect(!strings.contains("cloud code"))
        #expect(!strings.contains("soup base"))
    }

    @Test("biasingStrings respects the cap, dedupes, and skips disabled and one-character entries")
    func biasingCapAndHygiene() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 0..<120 { store.add(DictionaryEntry(kind: .term("Term\(i)"))) }
        store.add(DictionaryEntry(kind: .term("Vercel")))
        store.add(DictionaryEntry(kind: .term("vercel")))          // duplicate, differing only in case
        store.add(DictionaryEntry(kind: .term("x")))               // too short to be useful
        store.add(DictionaryEntry(kind: .term("Hidden"), enabled: false))

        // RECON §5: 50 is a measured ceiling — hit rate degrades with list length.
        let capped = store.biasingStrings(limit: Settings.Default.biasingLimit)
        #expect(capped.count == 50)
        #expect(Set(capped.map { $0.lowercased() }).count == capped.count)
        #expect(!capped.contains("x"))
        #expect(!capped.contains("Hidden"))

        #expect(store.biasingStrings(limit: 0).isEmpty)
        #expect(store.biasingStrings(limit: -5).isEmpty)
        #expect(store.biasingStrings(limit: 3).count == 3)
    }

    @Test("Entries the corrector keeps rescuing are ranked to the front of the biasing list")
    func biasingRanksProvenTermsFirst() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 0..<60 { store.add(DictionaryEntry(kind: .term("Filler\(i)"))) }
        let hot = store.add(DictionaryEntry(kind: .correction(heard: "whisper flow", write: "Wispr Flow")))
        store.recordHits((0..<12).map { _ in
            CorrectionHit(entryID: hot.id, from: "whisper flow", to: "Wispr Flow", offset: 0)
        })

        let strings = store.biasingStrings(limit: 50)
        #expect(strings.first == "Wispr Flow")
    }

    // MARK: Risk assessment

    @Test("A common single English word is flagged as a warning")
    func riskFlagsCommonWords() {
        let risk = DictionaryStore.assessRisk(for: .correction(heard: "cloud", write: "Claude"))
        #expect(risk.level == .warning)
        #expect(risk.message?.contains("common English word") == true)
    }

    @Test("Very short entries are flagged regardless of the word list")
    func riskFlagsShortEntries() {
        #expect(DictionaryStore.assessRisk(for: .correction(heard: "ab", write: "Alpha Beta")).level == .warning)
        #expect(DictionaryStore.assessRisk(for: .correction(heard: "x", write: "Xcode")).level == .warning)
        #expect(DictionaryStore.assessRisk(for: .term("ab")).level == .warning)
    }

    @Test("Blank and punctuation-only entries are flagged")
    func riskFlagsUnusableEntries() {
        #expect(DictionaryStore.assessRisk(for: .term("")).level == .warning)
        #expect(DictionaryStore.assessRisk(for: .term("   ")).level == .warning)
        #expect(DictionaryStore.assessRisk(for: .correction(heard: "-_-", write: "shrug")).level == .warning)
    }

    @Test("A distinctive proper noun carries no risk")
    func riskAllowsProperNouns() {
        #expect(DictionaryStore.assessRisk(for: .term("Vercel")) == .ok)
        #expect(DictionaryStore.assessRisk(for: .term("Wispr Flow")) == .ok)
        #expect(DictionaryStore.assessRisk(for: .correction(heard: "soup base", write: "Supabase")) == .ok)
    }

    @Test("A phrase made entirely of common words is a notice, not a warning")
    func riskNoticesCommonPhrases() {
        let risk = DictionaryStore.assessRisk(for: .correction(heard: "cloud code", write: "Claude Code"))
        #expect(risk.level == .notice)
        #expect(risk.message != nil)
    }

    @Test("An undistinguished lowercase term is a notice: biasing it is unlikely to help")
    func riskNoticesUndistinctiveTerms() {
        #expect(DictionaryStore.assessRisk(for: .term("kubernetes")).level == .notice)
    }

    @Test("Risk levels are ordered so the UI can pick the worst")
    func riskLevelsAreComparable() {
        #expect(EntryRisk.Level.none < .notice)
        #expect(EntryRisk.Level.notice < .warning)
    }

    // MARK: File watching

    @Test("An external edit to dictionary.json is picked up", .timeLimit(.minutes(1)))
    func externalEditTriggersReload() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.load()
        store.startWatchingFile()
        defer { store.stopWatchingFile() }

        // Let the debounced startup write settle so the reload we observe is unambiguously the
        // external edit and not our own seeding save.
        try await Task.sleep(for: .milliseconds(300))

        let handWritten = """
        [{ "type": "correction", "heard": "hand edited", "write": "Hand Edited" }]
        """
        try handWritten.write(to: store.fileURL, atomically: true, encoding: .utf8)

        var reloaded = false
        for _ in 0..<80 {
            try await Task.sleep(for: .milliseconds(50))
            if store.entries.count == 1, store.entries[0].displayTerm == "hand edited" {
                reloaded = true
                break
            }
        }
        #expect(reloaded, "the file watcher should have reloaded the external edit")
    }

    @Test("Our own writes do not trigger a reload loop", .timeLimit(.minutes(1)))
    func ownWritesAreIgnored() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        try store.load()
        store.startWatchingFile()
        defer { store.stopWatchingFile() }
        try await Task.sleep(for: .milliseconds(300))

        let marker = store.add(DictionaryEntry(kind: .term("LocallyAdded")))
        try store.save()

        // If our own write were treated as an external edit, the reload would replace the in-memory
        // array (new object identities, and any not-yet-saved edit lost).
        try await Task.sleep(for: .milliseconds(700))
        #expect(store.entries.contains { $0.id == marker.id })
        #expect(store.entries.count == DictionaryStore.starterEntries().count + 1)
    }

    @Test("stopWatchingFile is idempotent and safe before any watch started")
    func stopWatchingIsSafe() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        store.stopWatchingFile()
        store.stopWatchingFile()
        try store.load()
        store.startWatchingFile()
        store.stopWatchingFile()
        store.stopWatchingFile()
    }
}

/// `Settings` lives in the data layer too. These run against `EphemeralDefaults`, an in-memory
/// `UserDefaults`, so the real `edict.*` keys in `UserDefaults.standard` are never touched *and*
/// no preferences file is created.
///
/// These tests used to build a `UserDefaults(suiteName: "com.edict.tests.<UUID>")` per test and
/// destroy it with `removePersistentDomain(forName:)` in a `defer`. That looked correct and was not:
/// a full `swift test` still left one `~/Library/Preferences/com.edict.tests.<UUID>.plist` per test
/// behind, and 85 of them had piled up on the development machine. `EphemeralDefaults` documents the
/// measurements — the short version is that cfprefsd re-persists a suite domain after any teardown,
/// so the only reliable fix is never to create one. **Do not reintroduce `UserDefaults(suiteName:)`
/// here.**
@Suite("Settings")
@MainActor
struct SettingsTests {

    private func makeSettings() -> Settings {
        Settings(defaults: EphemeralDefaults())
    }

    @Test("Defaults match the RECON amendments")
    func defaults() {
        let settings = makeSettings()

        // RECON §8: Right Option is the only key Karabiner and Siri leave alone on this machine.
        #expect(settings.hotkey == .rightOption)
        // RECON §7: never Locale.current — this machine's en_ID resolves to the wrong acoustic model.
        #expect(settings.localeIdentifier == "en-US")
        // RECON §5: 50, not 100.
        #expect(settings.biasingLimit == 50)
        #expect(settings.historyLimit == 5000)
        #expect(settings.biasingEnabled)
        #expect(settings.correctionsEnabled)
        // RECON §22: pre-warming keeps the orange mic indicator lit for the whole session.
        #expect(!settings.prewarmMicrophone)
    }

    @Test("biasingLimit is clamped to 0...50 on the way in")
    func biasingLimitClamps() {
        let settings = makeSettings()

        settings.biasingLimit = 400
        #expect(settings.biasingLimit == 50)
        settings.biasingLimit = -1
        #expect(settings.biasingLimit == 0)
        settings.biasingLimit = 25
        #expect(settings.biasingLimit == 25)
        #expect(Settings.biasingLimitRange == 0...50)
    }

    @Test("effectiveBiasingLimit collapses to zero when biasing is off")
    func effectiveBiasingLimit() {
        let settings = makeSettings()

        settings.biasingLimit = 20
        #expect(settings.effectiveBiasingLimit == 20)
        settings.biasingEnabled = false
        #expect(settings.effectiveBiasingLimit == 0)
    }

    /// "Reload" here means a second `Settings` over the same store, which is what this always
    /// actually tested — that `write` and `init` agree on the `edict.` key names and the value
    /// types round-trip. Whether `UserDefaults` itself can write a plist is Apple's test, not ours.
    @Test("Changes persist through the edict. key prefix and survive a reload")
    func persistence() {
        let defaults = EphemeralDefaults()

        let first = Settings(defaults: defaults)
        first.hotkey = .f13
        first.localeIdentifier = "en-GB"
        first.biasingLimit = 12
        first.playSounds = true

        #expect(defaults.string(forKey: "edict.hotkey") == "f13")
        #expect(defaults.integer(forKey: "edict.biasingLimit") == 12)

        let second = Settings(defaults: defaults)
        #expect(second.hotkey == .f13)
        #expect(second.localeIdentifier == "en-GB")
        #expect(second.biasingLimit == 12)
        #expect(second.playSounds)
    }

    @Test("A stored value outside the allowed range is clamped when it is read back")
    func storedOutOfRangeValueIsClamped() {
        let defaults = EphemeralDefaults()
        // Simulates a settings file carried over from before the cap dropped from 100 to 50.
        defaults.set(400, forKey: "edict.biasingLimit")
        defaults.set(1, forKey: "edict.historyLimit")

        let settings = Settings(defaults: defaults)
        #expect(settings.biasingLimit == 50)
        #expect(settings.historyLimit == Settings.historyLimitRange.lowerBound)
    }

    @Test("resetToDefaults restores every field")
    func resetToDefaults() {
        let settings = makeSettings()

        settings.hotkey = .fn
        settings.autoInject = false
        settings.biasingLimit = 3
        settings.historyLimit = 100
        settings.resetToDefaults()

        #expect(settings.hotkey == .rightOption)
        #expect(settings.autoInject)
        #expect(settings.biasingLimit == 50)
        #expect(settings.historyLimit == 5000)
    }

    @Test("Every hotkey choice has a display name and a glyph")
    func hotkeyPresentation() {
        for choice in HotkeyChoice.allCases {
            #expect(!choice.displayName.isEmpty)
            #expect(!choice.glyph.isEmpty)
            #expect(choice.id == choice.rawValue)
        }
        #expect(HotkeyChoice.rightOption.displayName.contains("Right Option"))
    }
}

// MARK: - Test hygiene

/// A guard on the tests themselves. `swift test` is supposed to leave no trace on this machine, and
/// the two ways it previously did were invisible until someone counted files by hand: a
/// `UserDefaults` suite domain per `Settings` test, and any store that fell back to the real
/// `~/Library/Application Support/Edict`.
@Suite("Test hygiene")
@MainActor
struct TestHygieneTests {

    /// The regression guard for the 85 leaked `com.edict.tests.<UUID>.plist` files. If someone
    /// swaps `EphemeralDefaults` back to a `UserDefaults(suiteName:)`, the written value becomes
    /// visible to a persistent domain and this fails.
    @Test("EphemeralDefaults round-trips values without them reaching a persistent domain")
    func ephemeralDefaultsReachNoPersistentDomain() {
        let key = "edict.testHygiene.\(UUID().uuidString)"
        let defaults = EphemeralDefaults()

        defaults.set("written", forKey: key)
        defaults.set(7, forKey: "\(key).int")
        defaults.set(true, forKey: "\(key).bool")

        // The typed getters have to funnel through the overridden `object(forKey:)`, or `Settings`
        // would read the real defaults back.
        #expect(defaults.string(forKey: key) == "written")
        #expect(defaults.integer(forKey: "\(key).int") == 7)
        #expect(defaults.bool(forKey: "\(key).bool"))
        #expect(defaults.object(forKey: key) as? String == "written")

        // Nothing may have escaped into the domain cfprefsd would persist.
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        #expect(UserDefaults.standard.object(forKey: "\(key).int") == nil)
        #expect(UserDefaults.standard.object(forKey: "\(key).bool") == nil)

        defaults.removeObject(forKey: key)
        #expect(defaults.string(forKey: key) == nil)
    }

    // The companion test for the support directory lives in `AppPathsGuardTests`, and it took an API
    // change to make it safe. It used to be true that a test asserting anything about the support
    // directory would itself be the leak it was meant to catch, because `AppPaths.supportDirectory`
    // *creates* the directory as a side effect of being read, and the guard test read it three times.
    // `AppPaths.defaultSupportDirectoryURL` now composes the same path and creates nothing, so the
    // path can be asserted without touching the real `~/Library/Application Support/Edict`. Reading
    // `historyFile` or `dictionaryFile` still creates it, which is why the assertion about their
    // names runs only under `EDICT_SUPPORT_DIR`.
    //
    // The store fixtures above all pass an explicit `fileURL:` under `NSTemporaryDirectory()`, which
    // is what keeps the real directory out of the test run in the first place.
}
