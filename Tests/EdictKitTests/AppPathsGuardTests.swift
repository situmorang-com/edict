import Foundation
import Testing

@testable import EdictKit

/// Both of these guard against a real incident: an automated verification run wrote to the live
/// `~/Library/Application Support/Edict` and replaced a user's transcript history, and no backup of
/// any kind existed to restore from.
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

    // Skipped rather than failed when the override is set: the whole point is that a redirected run
    // does not touch the real path, so asserting the real path there would be self-contradictory.
    @Test("Without the override, the store stays at the documented literal path",
          .enabled(if: AppPaths.overrideDirectory == nil))
    func defaultPathIsUnchanged() throws {
        #expect(AppPaths.supportDirectory.lastPathComponent == "Edict")
        #expect(AppPaths.supportDirectory.path.contains("Application Support"))
        #expect(AppPaths.historyFile.lastPathComponent == "history.json")
    }
}
