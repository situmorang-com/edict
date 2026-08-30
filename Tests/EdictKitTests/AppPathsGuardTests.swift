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
    //
    // A guard, not evidence for finding #26: it passed against the creating property too. What it
    // catches is the path *moving* — `folderName` renamed, which would strand the user's hand-edited
    // `dictionary.json` in a file the app no longer reads, or the process acquiring a sandbox
    // container, which RECON measured redirects `NSHomeDirectory()` into
    // `~/Library/Containers/<bundle id>/Data` and would take the whole store with it. The header doc on
    // `AppPaths` states the no-container half as a promise; this is where it is checked.
    @Test("The store's default path is the documented literal one")
    func defaultPathIsUnchanged() {
        let path = AppPaths.defaultSupportDirectoryURL.path
        #expect(AppPaths.defaultSupportDirectoryURL.lastPathComponent == "Edict")
        #expect(path.contains("/Library/Application Support/"))
        #expect(!path.contains("/Containers/"),
                "the documented path is the literal one, not a sandbox container redirect")
    }

    /// Two claims live here, and which is which matters.
    ///
    /// **Pinned as a filesystem outcome:** `defaultSupportDirectory(under:)` creates nothing. It is
    /// pointed at a base under `NSTemporaryDirectory()` that has never existed, so an `ensureDirectory`
    /// added inside that seam shows up as a directory that is suddenly there.
    ///
    /// **Pinned as a code path only:** that the public `defaultSupportDirectoryURL` is that same
    /// composition applied to the real search-path answer. This is *not* proof that reading the public
    /// property creates nothing, and no test on this machine can be: the real
    /// `~/Library/Application Support/Edict` exists and holds the user's transcripts, so
    /// `ensureDirectory` would early-return there, and moving that folder aside to find out is not an
    /// option. What keeps a statement out of the public property is structural rather than tested — it
    /// is a stored `static let` initialised by a single expression, so it has no statement position to
    /// grow one in. Nobody should read the assertions below as covering that.
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

        // The code-path half: the public property callers actually read must be this same seam over the
        // real search path, so that the assertion above is about the composition callers get.
        let searchPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        #expect(AppPaths.defaultSupportDirectoryURL.path
                == AppPaths.defaultSupportDirectory(under: searchPath).path)
    }

    /// The `nil` branch of the search path, which no other test can reach: `urls(for:in:)` returning
    /// empty does not happen on a healthy machine. Worth an assertion anyway, because the wrong
    /// fallback here is the destructive one — a relative path would put `dictionary.json` wherever the
    /// process was launched from, which for `swift test` is the package directory.
    ///
    /// The first assertion mirrors the implementation's own expression, so it is a guard and nothing
    /// more: co-editing the two keeps it green. The second is not a mirror — it holds the hardcoded
    /// fallback against what the OS actually answers, so it fails if the two drift apart, which is the
    /// one failure the mirrored assertion cannot see. It assumes an unsandboxed process: RECON measured
    /// that a sandboxed build's `NSHomeDirectory()` is redirected into
    /// `~/Library/Containers/<bundle id>/Data`, and the two sides would then be two different homes.
    ///
    /// A third assertion used to sit here, `composed.path.hasPrefix("/")`, and is gone because it could
    /// not fail: `NSHomeDirectory()` is absolute, so the composed path always begins with `/`.
    @Test("With no Application Support search path, the fallback stays an absolute path inside the home")
    func fallbackStaysInsideTheHome() {
        let composed = AppPaths.defaultSupportDirectory(under: nil)
        let expected = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Edict")

        #expect(composed.path == expected.path)
        #expect(composed.path == AppPaths.defaultSupportDirectoryURL.path,
                "the fallback must land where the search path already points, or a machine that ever takes it moves the store")
    }

    /// Ungated now, and that is the change. This assertion used to read `AppPaths.historyFile`, which
    /// creates the support directory, so it could only be enabled in a process that had already been
    /// redirected: `.enabled(if: AppPaths.overrideDirectory != nil)`. Amendment 39 mandates
    /// `EDICT_SUPPORT_DIR` for anything that exercises the real app — but a plain `swift test` is not
    /// that, and nothing in scripts/, Package.swift or .github exports the variable, so the gate left
    /// the names checked only in the runs where a caller had exported it by hand. `historyFile(in:)`
    /// and `dictionaryFile(in:)` take the directory, so the same claim costs nothing and holds in
    /// every run.
    ///
    /// A guard, and the rename it guards against is not cosmetic: `dictionary.json` is documented as a
    /// file the user opens in a text editor and hand-edits, so renaming it strands their edits in a
    /// file the app has stopped reading.
    @Test("The two store files keep their documented names")
    func storeFilesKeepTheirNames() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edict-names-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(AppPaths.historyFile(in: dir).lastPathComponent == "history.json")
        #expect(AppPaths.dictionaryFile(in: dir).lastPathComponent == "dictionary.json")
        #expect(AppPaths.historyFile(in: dir).deletingLastPathComponent().path == dir.path,
                "the file sits directly in the directory it was given, not in a subfolder of it")
        #expect(!FileManager.default.fileExists(atPath: dir.path),
                "composing a file name must not create the directory around it either")
    }
}
