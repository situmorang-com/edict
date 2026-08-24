import Foundation

/// Where Edict keeps its two plain-JSON files.
///
/// Both files are a *documented user interface*: `dictionary.json` is meant to be opened in a text
/// editor and hand-edited (see `DictionaryStore.startWatchingFile()`), so the location has to be
/// stable, discoverable, and free of any container indirection. RECON §25 rules out the App Sandbox
/// for this app, so `~/Library/Application Support/Edict` really is the literal path — not a
/// container redirect.
public enum AppPaths {
    /// Folder name under Application Support. Not derived from the bundle identifier: RECON showed
    /// `Bundle.main.bundleIdentifier` is nil under `swift run`, and a nil-derived path would move the
    /// user's dictionary between dev and release builds.
    public static let folderName = "Edict"

    /// `~/Library/Application Support/Edict`. Created on first access; creation failures are logged
    /// rather than thrown so a read-only home directory degrades to "nothing persists" instead of a crash.
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            // Fall back to an explicit path rather than the CWD: a nil here would otherwise scatter
            // dictionary.json wherever the process happened to be launched from.
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent(folderName, isDirectory: true)
        do {
            try ensureDirectory(dir)
        } catch {
            Log.data.error("Could not create support directory \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return dir
    }

    public static var dictionaryFile: URL { supportDirectory.appendingPathComponent("dictionary.json") }

    public static var historyFile: URL { supportDirectory.appendingPathComponent("history.json") }

    public static func ensureSupportDirectory() throws {
        try ensureDirectory(supportDirectory)
    }

    private static func ensureDirectory(_ url: URL) throws {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - Atomic writes

    /// Write `data` to `url` so that a reader never observes a truncated or half-written file.
    ///
    /// The temp file must live in the *same* directory as the destination, otherwise
    /// `replaceItemAt` degrades to a cross-volume copy and loses atomicity. `replaceItemAt`
    /// requires an existing original, so the first write goes through `Data.write(options: .atomic)`.
    static func writeAtomically(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try ensureDirectory(dir)

        guard FileManager.default.fileExists(atPath: url.path) else {
            try data.write(to: url, options: .atomic)
            return
        }

        // Dot-prefixed so a directory-level file watcher can recognise and ignore it.
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}
