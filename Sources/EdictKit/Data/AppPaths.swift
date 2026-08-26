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

    /// Environment variable that redirects every on-disk path somewhere else.
    ///
    /// This exists because an automated verification run **destroyed a user's real transcript
    /// history**: it exercised the import path against the installed app, which naturally writes to
    /// the real `~/Library/Application Support/Edict`, and the file came back with two entries where
    /// there had been thirty. There was no backup.
    ///
    /// Anything automated — a test, a probe, an agent verifying a feature end to end — must be able
    /// to point the whole store at a scratch directory so that touching real data is *impossible*
    /// rather than merely discouraged. Set `EDICT_SUPPORT_DIR=/some/tmp/dir` and every path below
    /// moves with it.
    public static let supportDirectoryOverrideKey = "EDICT_SUPPORT_DIR"

    /// Non-nil when the override is in effect. Read once: an override that changed mid-run would
    /// split the stores across two directories, which is worse than either choice.
    public static let overrideDirectory: URL? = {
        guard let raw = ProcessInfo.processInfo.environment[supportDirectoryOverrideKey],
              !raw.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        // Loud on purpose. Silently writing somewhere unexpected is how the incident above went
        // unnoticed until the data was already gone.
        Log.data.notice("support directory overridden to \(url.path, privacy: .public)")
        return url
    }()

    /// `~/Library/Application Support/Edict`, or `overrideDirectory` when set. Created on first
    /// access; creation failures are logged rather than thrown so a read-only home directory degrades
    /// to "nothing persists" instead of a crash.
    public static var supportDirectory: URL {
        if let override = overrideDirectory {
            do { try ensureDirectory(override) } catch {
                Log.data.error("Could not create overridden support directory \(override.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return override
        }
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
        keepPreviousVersion(of: url)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Copy the outgoing file to `<name>.bak` before it is replaced.
    ///
    /// One generation, kept deliberately simple. A user's transcript history was lost to a single bad
    /// write and no backup existed anywhere — not in the support directory, not in a temp file, and
    /// Time Machine held only OS-update snapshots. Atomic writes protect against a *torn* file; they
    /// do nothing about a *wrong* one, which is the failure that actually happened.
    ///
    /// Best-effort by design: a failure here must never block the real write, because refusing to
    /// save new work in order to protect old work is the wrong trade.
    private static func keepPreviousVersion(of url: URL) {
        let backup = url.appendingPathExtension("bak")
        do {
            if FileManager.default.fileExists(atPath: backup.path) {
                try FileManager.default.removeItem(at: backup)
            }
            try FileManager.default.copyItem(at: url, to: backup)
        } catch {
            Log.data.debug("could not keep a backup of \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
