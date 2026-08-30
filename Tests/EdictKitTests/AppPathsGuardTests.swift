import Foundation
import Testing

@testable import EdictKit

/// Every test here guards against a real incident: an automated verification run wrote to the live
/// `~/Library/Application Support/Edict` and replaced a user's transcript history, and no backup of
/// any kind existed to restore from. The write half is the `.bak` generation; the path half is that a
/// run which never went near the live store leaves no trace of it — which this suite itself used to
/// break, by reading a path accessor that creates the directory it returns.
@Suite("App paths guard")
struct AppPathsGuardTests {

    private func scratch() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edict-guard-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Every write leaves the previous version recoverable as .bak")
    func writeKeepsPreviousVersion() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")

        // Stand in for the thirty transcripts that were lost.
        let original = Data(#"[{"id":"one"},{"id":"two"}]"#.utf8)
        try AppPaths.writeAtomically(original, to: file)

        // The destructive write: the same file, replaced with almost nothing.
        try AppPaths.writeAtomically(Data("[]".utf8), to: file)

        #expect(try Data(contentsOf: file) == Data("[]".utf8))
        let backup = file.appendingPathExtension("bak")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try Data(contentsOf: backup) == original, "the overwritten version must still be recoverable")
    }

    @Test("The first write has nothing to back up, and must not fail because of it")
    func firstWriteNeedsNoBackup() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("dictionary.json")
        try AppPaths.writeAtomically(Data("[]".utf8), to: file)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: file.appendingPathExtension("bak").path))
    }

    @Test("The backup only ever holds one generation, so it cannot grow without bound")
    func backupKeepsOneGeneration() throws {
        let dir = scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")
        for i in 0..<4 { try AppPaths.writeAtomically(Data("[\(i)]".utf8), to: file) }
        let backup = try Data(contentsOf: file.appendingPathExtension("bak"))
        #expect(backup == Data("[2]".utf8), "the .bak is the immediately previous version, not the oldest")
        let stray = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("history.json") }
        #expect(stray.count == 2, "exactly history.json and history.json.bak")
    }

    @Test("The override key is the documented one, so automation can rely on it")
    func overrideKeyIsStable() {
        #expect(AppPaths.supportDirectoryOverrideKey == "EDICT_SUPPORT_DIR")
    }

    // Ungated now, and that is the fix. This test used to be `.enabled(if: overrideDirectory == nil)`
    // — enabled precisely when nothing redirected the store — and it read `AppPaths.supportDirectory`,
    // which creates the directory it returns. So the test guarding the real support directory was a
    // test that created `~/Library/Application Support/Edict` in the developer's real home, and the
    // gate is what aimed it there. (It is not the last reader of a creating property in this package:
    // `TranscriptExportTests.realHistoryRoundTripLosesNothing` reaches the same directory through
    // `AppPaths.historyFile`. That one is a deliberate read of the live file and belongs to its own
    // suite.)
    //
    // `defaultSupportDirectoryURL` composes the same path and creates nothing, which is also why the
    // gate can go rather than merely being inverted: the pure property ignores the override, so this is
    // the documented literal path in a redirected run too, and the assertion is no longer
    // self-contradictory there.
    @Test("The store's default path is the documented literal one")
    func defaultPathIsUnchanged() {
        #expect(AppPaths.defaultSupportDirectoryURL.lastPathComponent == "Edict")
        #expect(AppPaths.defaultSupportDirectoryURL.path.contains("Application Support"))
    }

    /// The property above must stay a *path* accessor. A scratch base that has never existed is the
    /// only way to say that in an assertion: the real `~/Library/Application Support/Edict` exists on
    /// any machine that has run Edict once, so `ensureDirectory` early-returns there and re-adding the
    /// creation would be invisible on exactly the machines a developer runs the suite on.
    @Test("Composing the default path creates neither the folder nor its parent")
    func defaultPathCreatesNothing() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edict-absent-\(UUID().uuidString)", isDirectory: true)
        // Nothing to clean up while this passes. The `defer` is for the run where it does not: a
        // regression here leaves a folder behind, and this suite is the one place that should not.
        defer { try? FileManager.default.removeItem(at: base) }
        let composed = AppPaths.defaultSupportDirectory(under: base)

        #expect(composed.path == base.appendingPathComponent("Edict").path)
        #expect(!FileManager.default.fileExists(atPath: composed.path),
                "reading the path must not create the folder — an absent folder is the only signal that a run never went near the live store")
        #expect(!FileManager.default.fileExists(atPath: base.path), "nor its parent")
    }

    /// The `nil` branch of the search path, which no other test can reach: `urls(for:in:)` returning
    /// empty does not happen on a healthy machine. Worth an assertion anyway, because the wrong
    /// fallback here is the destructive one — a relative path would put `dictionary.json` wherever the
    /// process was launched from, which for `swift test` is the package directory.
    @Test("With no Application Support search path, the fallback stays an absolute path inside the home")
    func fallbackStaysInsideTheHome() {
        let composed = AppPaths.defaultSupportDirectory(under: nil)
        let expected = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Edict")

        #expect(composed.path == expected.path)
        #expect(composed.path.hasPrefix("/"))
    }

    // Inverted gate, deliberately: reading `AppPaths.historyFile` creates the support directory, so
    // this assertion may only run in a process that has already been redirected — where the creation
    // lands in the scratch directory the override names. Amendment 39 requires every automated run to
    // set `EDICT_SUPPORT_DIR`, so this is covered in exactly the runs the repo mandates, and skipped in
    // the plain `swift test` where it would be the leak.
    @Test("The two store files keep their documented names",
          .enabled(if: AppPaths.overrideDirectory != nil))
    func storeFilesKeepTheirNames() {
        #expect(AppPaths.historyFile.lastPathComponent == "history.json")
        #expect(AppPaths.dictionaryFile.lastPathComponent == "dictionary.json")
    }
}
