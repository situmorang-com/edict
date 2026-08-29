import Foundation
import Testing
@testable import EdictKit

/// The recovery half of amendment 39.
///
/// The write half shipped — `AppPaths.writeAtomically` keeps one generation as `<name>.bak` — and
/// then nothing ever read it: a grep across `Sources/` found one write site and zero reads, so the
/// only backup Edict had was reachable solely by a user who knew the path and knew to quit first.
/// Meanwhile a `history.json` that failed to decode was left in place with `transcripts` unassigned,
/// and the next dictation's debounced save replaced it — the same total loss as the original
/// incident, reached through a decode error instead of a stray verification run.
///
/// Temporary directories only, and an injected history limit, so the real
/// `~/Library/Application Support/Edict` cannot be touched.
@Suite("Store recovery")
@MainActor
struct StoreRecoveryTests {

    // MARK: Fixtures

    private func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func transcript(_ text: String, at seconds: TimeInterval) -> Transcript {
        Transcript(
            createdAt: Date(timeIntervalSince1970: seconds),
            rawText: text,
            text: text,
            audioDuration: 1,
            transcribeDuration: 0.1,
            injection: .accessibility
        )
    }

    /// Everything in `dir` whose name marks it as quarantined bytes.
    private func quarantineFiles(in dir: URL, stem: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("\(stem).unreadable-") }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    // MARK: History

    @Test("An unreadable history.json is recovered from the .bak the app already writes")
    func historyRecoversFromBackup() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")

        // Two generations, so `.bak` holds the three-entry version.
        let seed = HistoryStore(fileURL: file, limit: { 5000 })
        for i in 1...3 { seed.append(transcript("entry \(i)", at: TimeInterval(i))) }
        try seed.save()
        seed.append(transcript("entry 4", at: 4))
        try seed.save()
        #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("bak").path))

        // Real corruption: the shape a truncating external writer leaves behind. Schema drift cannot
        // get here — every field decodes with `decodeIfPresent` plus a default.
        let corrupt = Data(#"[{"text":"entry 4","createdAt":"#.utf8)
        try corrupt.write(to: file)

        let store = HistoryStore(fileURL: file, limit: { 5000 })
        // Deliberately not `#expect(throws:)`: a recovered load is a successful load, and the caller
        // in `DictationController.bootstrap` only logs a throw.
        try store.load()

        #expect(store.transcripts.map(\.text) == ["entry 3", "entry 2", "entry 1"])
        let reported = store.lastLoadError ?? ""
        #expect(reported.contains("Recovered 3 entries from the backup"))

        // The bytes nobody could read are kept, byte for byte, under a name that is not reused.
        let quarantined = try quarantineFiles(in: dir, stem: "history")
        #expect(quarantined.count == 1)
        #expect(try quarantined.first.map { try Data(contentsOf: $0) } == corrupt)
        #expect(reported.contains(quarantined.first?.lastPathComponent ?? "<none>"))

        // Recovery has to outlive the process. `load()` returns early on an absent file, so without
        // the write-back the next launch would find nothing and leave the `.bak` unread again.
        let relaunched = HistoryStore(fileURL: file, limit: { 5000 })
        try relaunched.load()
        #expect(relaunched.transcripts.map(\.text) == ["entry 3", "entry 2", "entry 1"])
        #expect(relaunched.lastLoadError == nil)
    }

    @Test("With no usable backup the unreadable bytes are still moved out of the next save's way")
    func historyQuarantinesWithNoBackup() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")

        let corrupt = Data("{ not an array".utf8)
        try corrupt.write(to: file)

        let store = HistoryStore(fileURL: file, limit: { 5000 })
        store.append(transcript("dictated after launch", at: 100))
        #expect(throws: (any Error).self) { try store.load() }
        // In-memory state is the only copy of that entry, so a failed recovery must not clear it.
        #expect(store.transcripts.map(\.text) == ["dictated after launch"])
        #expect((store.lastLoadError ?? "").contains("No usable backup"))

        // This is the loss being fixed: before, the file stayed put and this save replaced it.
        store.append(transcript("and another", at: 101))
        store.flushPendingSave()

        let quarantined = try quarantineFiles(in: dir, stem: "history")
        #expect(quarantined.count == 1)
        #expect(try quarantined.first.map { try Data(contentsOf: $0) } == corrupt)

        let reloaded = HistoryStore(fileURL: file, limit: { 5000 })
        try reloaded.load()
        #expect(reloaded.transcripts.count == 2)
    }

    @Test("An empty backup is not reported as a recovery")
    func historyDoesNotClaimAnEmptyRecovery() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")

        try Data("{{{".utf8).write(to: file)
        try Data("[]".utf8).write(to: file.appendingPathExtension("bak"))

        let store = HistoryStore(fileURL: file, limit: { 5000 })
        #expect(throws: (any Error).self) { try store.load() }
        #expect(store.transcripts.isEmpty)
        // "Recovered 0 entries" would be a claim the code cannot stand behind.
        #expect(!(store.lastLoadError ?? "").contains("Recovered"))
        #expect((store.lastLoadError ?? "").contains("No usable backup"))
    }

    @Test("A recovered store is trimmed to the history limit, like any other load")
    func recoveredStoreRespectsTheLimit() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")

        let seed = HistoryStore(fileURL: file, limit: { 5000 })
        for i in 1...6 { seed.append(transcript("entry \(i)", at: TimeInterval(i))) }
        try seed.save()
        seed.append(transcript("entry 7", at: 7))
        try seed.save()
        try Data("nope".utf8).write(to: file)

        let store = HistoryStore(fileURL: file, limit: { 2 })
        try store.load()
        #expect(store.transcripts.map(\.text) == ["entry 6", "entry 5"])
    }

    // MARK: Dictionary

    @Test("An unreadable dictionary.json is recovered from the .bak, and not reseeded")
    func dictionaryRecoversFromBackup() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dictionary.json")

        let seed = DictionaryStore(fileURL: file)
        try seed.load()                                   // first run: seeds and writes
        seed.add(DictionaryEntry(kind: .term("Supabase")))
        try seed.save()                                   // second write: `.bak` now holds the seed
        let backedUpCount = seed.entries.count - 1
        #expect(backedUpCount > 0)

        let corrupt = Data("[ this is not json".utf8)
        try corrupt.write(to: file)

        let store = DictionaryStore(fileURL: file)
        try store.load()
        #expect(store.entries.count == backedUpCount)
        #expect((store.lastLoadError ?? "").contains("Recovered \(backedUpCount) entr"))

        let quarantined = try quarantineFiles(in: dir, stem: "dictionary")
        #expect(quarantined.count == 1)
        #expect(try quarantined.first.map { try Data(contentsOf: $0) } == corrupt)

        // The reinstated file matters more here than in history: an absent `dictionary.json` is
        // first run, so without the write-back the next launch would reseed over the recovery.
        let relaunched = DictionaryStore(fileURL: file)
        try relaunched.load()
        #expect(relaunched.entries.count == backedUpCount)
        #expect(relaunched.lastLoadError == nil)
    }

    @Test("The file-watcher reload path never moves the user's hand-edited file aside")
    func externalEditPathDoesNotQuarantine() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dictionary.json")

        let store = DictionaryStore(fileURL: file)
        try store.load()
        let seeded = store.entries.count
        #expect(seeded > 0)

        // What a text editor leaves on disk halfway through a hand-edit.
        let midEdit = Data(#"[{"type":"term","term":"Vercel"},"#.utf8)
        try midEdit.write(to: file)

        #expect(throws: (any Error).self) { try store.load(recoverFromBackup: false) }
        #expect(store.entries.count == seeded, "in-memory entries survive a bad external edit")
        #expect(try quarantineFiles(in: dir, stem: "dictionary").isEmpty)
        #expect(try Data(contentsOf: file) == midEdit, "the user's file is left exactly where it was")
    }

    // MARK: The backup swap itself

    @Test("A .bak.new left by an interrupted write is cleaned up and never becomes the backup")
    func staleStagingFileIsNotMistakenForABackup() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")

        try AppPaths.writeAtomically(Data("[1]".utf8), to: file)
        try AppPaths.writeAtomically(Data("[2]".utf8), to: file)

        // The residue of a write that died between staging and swapping.
        let staged = file.appendingPathExtension("bak.new")
        try Data("[stale]".utf8).write(to: staged)

        try AppPaths.writeAtomically(Data("[3]".utf8), to: file)

        #expect(try Data(contentsOf: file.appendingPathExtension("bak")) == Data("[2]".utf8))
        #expect(!FileManager.default.fileExists(atPath: staged.path),
                "the staging file is consumed by the swap, not left beside the backup")
    }

    @Test("The staged backup swap leaves the support directory with exactly two files")
    func backupSwapLeavesNoResidue() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")

        for i in 0..<5 { try AppPaths.writeAtomically(Data("[\(i)]".utf8), to: file) }

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(contents == ["history.json", "history.json.bak"])
    }
}

// MARK: - The terminal flush

/// `flushPendingSave()` is the only reason a dictation made in the 500 ms before quit reaches disk —
/// `NSSupportsSuddenTermination` is false specifically so it runs. Its body was
/// `guard saveTask != nil else { return }; try? save()` in both stores, so a failed terminal write
/// left no trace anywhere: the app is exiting, so there is no UI, and unlike `scheduleSave`'s task
/// body this path had no catch that logged. Every other write path in both stores logs its failures,
/// which made the bare `try?` an inconsistency rather than a policy.
@Suite("The terminal flush")
@MainActor
struct TerminalFlushTests {

    /// A path that looks like a directory to a store and cannot be written into by **any** uid.
    ///
    /// This was a real directory at `posixPermissions: 0o500`, which root bypasses entirely — so
    /// under root both flush tests passed while proving nothing, which is worse than not having them.
    /// The geometry here is a mode-independent one: `notadir` is a *regular file*, so
    /// `AppPaths.writeAtomically`'s `ensureDirectory` cannot make a directory at that path (measured:
    /// `NSCocoaErrorDomain` 516) and the write fails before a single byte is attempted, for root and
    /// for everyone else.
    ///
    /// Returns the fake directory; `unseal` turns it into a real one so the same store can then
    /// succeed, which is what the clearing test needs.
    private func unwritableDirectory() throws -> (dir: URL, unseal: () throws -> Void, cleanup: () -> Void) {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-flush-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let notADirectory = root.appendingPathComponent("notadir")
        try Data("a regular file standing where a directory would have to be".utf8).write(to: notADirectory)
        return (
            notADirectory,
            {
                try fm.removeItem(at: notADirectory)
                try fm.createDirectory(at: notADirectory, withIntermediateDirectories: true)
            },
            { try? fm.removeItem(at: root) }
        )
    }

    @Test("A history flush that cannot write says so instead of swallowing it")
    func historyFlushReportsFailure() throws {
        let (dir, _, cleanup) = try unwritableDirectory()
        defer { cleanup() }

        let store = HistoryStore(fileURL: dir.appendingPathComponent("history.json"), limit: { 5000 })
        // `append` schedules the debounced save, which is what arms the flush: the guard returns
        // early when there is no pending work, so a store with nothing to write must stay silent.
        #expect(store.lastFlushError == nil)

        store.append(Transcript(
            createdAt: Date(timeIntervalSince1970: 1),
            rawText: "the last thing said before quitting",
            text: "the last thing said before quitting",
            audioDuration: 1,
            transcribeDuration: 0.1,
            injection: .accessibility
        ))
        store.flushPendingSave()

        #expect(store.lastFlushError != nil,
                "the terminal write failed into an unwritable directory and reported nothing")
    }

    @Test("A dictionary flush that cannot write says so instead of swallowing it")
    func dictionaryFlushReportsFailure() throws {
        let (dir, _, cleanup) = try unwritableDirectory()
        defer { cleanup() }

        let store = DictionaryStore(fileURL: dir.appendingPathComponent("dictionary.json"))
        store.add(DictionaryEntry(kind: .correction(heard: "kanaya", write: "Kanaya")))
        store.flushPendingSave()

        #expect(store.lastFlushError != nil)
    }

    @Test("A flush with nothing pending reports nothing, even where it could not have written")
    func idleFlushIsSilent() throws {
        let (dir, _, cleanup) = try unwritableDirectory()
        defer { cleanup() }

        let store = HistoryStore(fileURL: dir.appendingPathComponent("history.json"), limit: { 5000 })
        store.flushPendingSave()

        #expect(store.lastFlushError == nil,
                "an unwritable directory is not a failure until something actually needs writing")
    }

    @Test("A later successful write clears the recorded flush failure")
    func aSuccessfulSaveClearsTheFlushError() throws {
        let (dir, unseal, cleanup) = try unwritableDirectory()
        defer { cleanup() }

        let store = HistoryStore(fileURL: dir.appendingPathComponent("history.json"), limit: { 5000 })
        store.append(Transcript(
            createdAt: Date(timeIntervalSince1970: 1),
            rawText: "written while the disk was refusing",
            text: "written while the disk was refusing",
            audioDuration: 1,
            transcribeDuration: 0.1,
            injection: .accessibility
        ))
        store.flushPendingSave()
        #expect(store.lastFlushError != nil)

        // The obstruction goes away — a full disk emptied, a volume remounted, a permission granted.
        try unseal()
        try store.save()

        // `lastFlushError` is surfaced long after it is set, because there is no UI at termination.
        // Left uncleared, the first time the user ever saw it, it could be describing a failure a
        // later save had already fixed.
        #expect(store.lastFlushError == nil)
    }
}

// MARK: - The paths review found still open

/// Everything the first two repair rounds either left open or fixed without asserting.
///
/// The pattern worth naming: each of these is a *shape a file on disk can be in* that the recovery
/// code did not enumerate. The decode failure was fixed first because it is the one the finding
/// named; absence, zero length and a truncating writer all reach the same total loss and all three
/// shipped unasserted. A zero-length guard that is three lines of straight-line code with two
/// optional comparisons in it (`byteSize(of: url) == 0` on an `Int?`, and `let held = …, held > 0`)
/// leaves the whole suite green if either comparison is inverted.
@Suite("Store recovery — file shapes")
@MainActor
struct StoreFileShapeTests {

    private func scratch() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-shapes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func transcript(_ text: String, at seconds: TimeInterval) -> Transcript {
        Transcript(
            createdAt: Date(timeIntervalSince1970: seconds),
            rawText: text,
            text: text,
            audioDuration: 1,
            transcribeDuration: 0.1,
            injection: .accessibility
        )
    }

    /// Two generations, so `.bak` holds a real store of `count` entries.
    private func seededStore(at file: URL, count: Int) throws {
        let seed = HistoryStore(fileURL: file, limit: { 5000 })
        for i in 1...count { seed.append(transcript("entry \(i)", at: TimeInterval(i))) }
        try seed.save()
        seed.append(transcript("newest", at: TimeInterval(count + 1)))
        try seed.save()
    }

    private func quarantineFiles(in dir: URL, stem: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("\(stem).unreadable-") }
            .sorted()
    }

    // MARK: An absent file — finding #2's headline, still open after the first repair

    @Test("A history.json that has been deleted is recovered from the backup, not presented as empty")
    func absentHistoryRecoversFromBackup() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")
        try seededStore(at: file, count: 3)
        try FileManager.default.removeItem(at: file)

        let store = HistoryStore(fileURL: file, limit: { 5000 })
        try store.load()

        // `.bak` holds the generation before the last save — the 3 seeded entries, not "newest".
        // That is the contract of one generation of backup, and the point is that it came back at all.
        #expect(store.transcripts.count == 3,
                "a deleted history.json presented an empty store while the backup sat unread beside it")
        #expect(store.recoveredEntryCount == 3)
        #expect(store.lastLoadError?.contains("is not there") == true)
        // No file to move aside, so no mystery file explaining its own absence.
        #expect(try quarantineFiles(in: dir, stem: "history").isEmpty)
        // Reinstated, or the next launch reads a missing file again.
        #expect(FileManager.default.fileExists(atPath: file.path))
        // And that write must not have consumed the backup it came from.
        #expect(FileManager.default.fileExists(atPath: file.path + ".bak"))
    }

    @Test("A deleted dictionary.json is recovered, not reseeded with starter entries over the user's terms")
    func absentDictionaryDoesNotReseed() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dictionary.json")

        let seed = DictionaryStore(fileURL: file)
        try seed.load()                                    // seeds the starter set
        seed.add(DictionaryEntry(kind: .term("Pertamina")))
        seed.add(DictionaryEntry(kind: .correction(heard: "kanaya", write: "Kanaya")))
        try seed.save()
        seed.add(DictionaryEntry(kind: .term("Mayapada")))
        try seed.save()
        let starterCount = DictionaryStore(fileURL: dir.appendingPathComponent("probe.json")).entries.count

        try FileManager.default.removeItem(at: file)

        let store = DictionaryStore(fileURL: file)
        try store.load()

        // The backup holds the generation before the last save, so "Mayapada" is expected to be gone.
        // What must NOT happen is the starter set replacing the user's terms — assert that directly
        // rather than by a count that has to be kept in step with `starterEntries()`.
        let terms = store.entries.compactMap { entry -> String? in
            if case .term(let t) = entry.kind { return t }
            return nil
        }
        #expect(terms.contains("Pertamina"),
                "the user's dictionary was replaced by starter entries while the backup held their terms")
        #expect(store.entries.count > starterCount)
        #expect(store.recoveredEntryCount == store.entries.count)
        #expect(store.lastLoadError?.contains("is not there") == true)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test("The file watcher's reload does not recover an absent file")
    func watcherReloadDoesNotRecoverAbsence() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dictionary.json")

        let seed = DictionaryStore(fileURL: file)
        try seed.load()
        seed.add(DictionaryEntry(kind: .term("Pertamina")))
        try seed.save()
        seed.add(DictionaryEntry(kind: .term("Mayapada")))
        try seed.save()
        try FileManager.default.removeItem(at: file)

        // A watcher event can observe the file mid-replace, so this path must reinterpret nothing.
        let store = DictionaryStore(fileURL: file)
        try store.load(recoverFromBackup: false)

        #expect(store.recoveredEntryCount == nil,
                "the watcher path recovered from a backup, which is the behaviour recoverFromBackup: false exists to prevent")
    }

    // MARK: A zero-length file — the hole the first repair opened

    @Test("A zero-length store is never allowed to become the backup")
    func zeroLengthNeverBecomesTheBackup() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")
        try seededStore(at: file, count: 3)

        let backup = file.appendingPathExtension("bak")
        let goodBackup = try Data(contentsOf: backup)
        #expect(!goodBackup.isEmpty)

        // A truncating external writer's most characteristic output.
        try Data().write(to: file)
        // The next save is what used to destroy the backup.
        try AppPaths.writeAtomically(Data("[]".utf8), to: file)

        #expect(try Data(contentsOf: backup) == goodBackup,
                "a zero-length history.json was copied over the backup, so the user's entries are gone")
    }

    @Test("The same refusal holds on the path a user actually reaches it by")
    func zeroLengthRefusalHoldsThroughAppend() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")
        try seededStore(at: file, count: 3)
        let backup = file.appendingPathExtension("bak")
        let goodBackup = try Data(contentsOf: backup)

        try Data().write(to: file)

        let store = HistoryStore(fileURL: file, limit: { 5000 })
        store.append(transcript("said after the truncation", at: 99))
        store.flushPendingSave()

        #expect(try Data(contentsOf: backup) == goodBackup)
    }

    @Test("A zero-length history.json with a good backup is recovered from it")
    func zeroLengthRecoversFromBackup() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")
        try seededStore(at: file, count: 3)
        try Data().write(to: file)

        let store = HistoryStore(fileURL: file, limit: { 5000 })
        try store.load()

        #expect(store.transcripts.count == 3)
        #expect(store.recoveredEntryCount == 3)
        #expect(try quarantineFiles(in: dir, stem: "history").count == 1,
                "a 0-byte file worth recovering from should be kept as evidence")
    }

    @Test("A zero-length history.json with no backup leaves no litter behind")
    func zeroLengthWithNoBackupLeavesNoLitter() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")
        try Data().write(to: file)

        let store = HistoryStore(fileURL: file, limit: { 5000 })
        try store.load()

        #expect(store.transcripts.isEmpty)
        #expect(store.lastLoadError == nil, "an empty store is not a failure to report")
        // A bare 0-byte file is also what a legitimately emptied store looks like, so quarantining it
        // would put a mystery file in the support directory that no message explains.
        #expect(try quarantineFiles(in: dir, stem: "history").isEmpty)
    }

    @Test("A second load over a 0-byte file keeps entries this session appended")
    func emptyFileDoesNotDiscardInMemoryWork() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")
        try Data().write(to: file)

        let store = HistoryStore(fileURL: file, limit: { 5000 })
        try store.load()
        store.append(transcript("the only copy of itself", at: 1))
        try store.load()

        #expect(store.transcripts.count == 1,
                "a second load discarded an entry that existed nowhere else")
    }

    // MARK: An unreadable file

    @Test("An unreadable history.json is quarantined byte for byte")
    func unreadableIsQuarantinedIntact() throws {
        let dir = try scratch()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: dir.appendingPathComponent("history.json").path
            )
            try? FileManager.default.removeItem(at: dir)
        }
        let file = dir.appendingPathComponent("history.json")
        try seededStore(at: file, count: 2)

        let originalBytes = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)

        let store = HistoryStore(fileURL: file, limit: { 5000 })
        try store.load()

        // `moveItem` needs the directory, not the file, so an unreadable file still moves.
        let aside = try quarantineFiles(in: dir, stem: "history")
        #expect(aside.count == 1)
        if let name = aside.first {
            let moved = dir.appendingPathComponent(name)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: moved.path)
            #expect(try Data(contentsOf: moved) == originalBytes,
                    "the quarantined copy is not the bytes that could not be read")
        }
        #expect(store.recoveredEntryCount == 2)
    }
}
