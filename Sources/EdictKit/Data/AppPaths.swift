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

    /// `~/Library/Application Support/Edict` — the path, and nothing else. It composes a URL and
    /// hands it back: no directory is created, and the override is deliberately not consulted, so this
    /// is the *documented literal* path even in a redirected process.
    ///
    /// It exists because `supportDirectory` cannot be read without a side effect, which made the suite
    /// that guards the real support directory a test that *created* it:
    /// `AppPathsGuardTests.defaultPathIsUnchanged` used to read `supportDirectory`, and was enabled
    /// precisely when no override was set, so a plain `swift test` on a fresh machine made
    /// `~/Library/Application Support/Edict` in the developer's real home. Nothing was written into it
    /// — but an absent directory is the only signal that says a test run never strayed towards the live
    /// store, and creating it removed that signal.
    ///
    /// Stored, and initialised by a single expression, so that there is no statement position inside it
    /// for a `try? ensureDirectory(...)` to be added to later. That is the whole reason it is a `let`:
    /// re-adding the creation *here* is the likely form of this regression — it is what a reader would
    /// "fix" after seeing a caller get a path that does not exist — and no test could catch it on any
    /// machine that has run Edict once, because `~/Library/Application Support/Edict` already exists
    /// there and `ensureDirectory` early-returns. Only the seam below can be driven at a path that has
    /// never existed, so only the seam can be *proved* to create nothing.
    ///
    /// Asked once, at first access. Nothing in Edict changes the process's home directory, so there is
    /// no run in which a later read would answer differently.
    ///
    /// Anything that wants to *know* the path, rather than write to it, wants this property.
    public static let defaultSupportDirectoryURL: URL =
        defaultSupportDirectory(under: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first)

    /// The composition on its own, with the search-path answer passed in.
    ///
    /// Split out twice over. For the `nil` branch: `urls(for:in:)` returning empty is unreachable on a
    /// healthy machine, so a test cannot provoke the fallback any other way, and the fallback is the
    /// half that would do real damage if it regressed. And for purity: this is the only form of the
    /// composition a test can point at a directory that has never existed, which is what makes
    /// "reading the path creates nothing" an assertion rather than an assurance
    /// (`AppPathsGuardTests.defaultPathCreatesNothing`).
    static func defaultSupportDirectory(under applicationSupport: URL?) -> URL {
        let base = applicationSupport
            // Fall back to an explicit path rather than the CWD: a nil here would otherwise scatter
            // dictionary.json wherever the process happened to be launched from.
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    /// `defaultSupportDirectoryURL`, or `overrideDirectory` when set. Created on first access; creation
    /// failures are logged rather than thrown so a read-only home directory degrades to "nothing
    /// persists" instead of a crash. Read this only to write something: for the path alone, read
    /// `defaultSupportDirectoryURL`, which creates nothing.
    public static var supportDirectory: URL {
        if let override = overrideDirectory {
            do { try ensureDirectory(override) } catch {
                Log.data.error("Could not create overridden support directory \(override.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
            return override
        }
        let dir = defaultSupportDirectoryURL
        do {
            try ensureDirectory(dir)
        } catch {
            Log.data.error("Could not create support directory \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return dir
    }

    // Both of these still hang off the *creating* property, so reading either one creates the
    // directory. That is what the two production callers want — `DictionaryStore.shared`
    // (DictionaryStore.swift:213) and `HistoryStore.shared` (HistoryStore.swift:424) are each a store
    // about to read or write its file — but it means anything that only wants the *name* must set
    // `EDICT_SUPPORT_DIR` first, or compose from `defaultSupportDirectoryURL` or the two `in:` seams
    // below, or it becomes the leak that property exists to fix.
    public static var dictionaryFile: URL { dictionaryFile(in: supportDirectory) }

    public static var historyFile: URL { historyFile(in: supportDirectory) }

    /// The two documented file names, composed against a directory the caller supplies.
    ///
    /// Split out for the same reason as `defaultSupportDirectory(under:)`. The properties above cannot
    /// be read from a test without creating a directory, so the assertion that these names are the
    /// documented ones had to be gated on `EDICT_SUPPORT_DIR` — and nothing in scripts/, Package.swift
    /// or .github exports that variable, so it ran only when a caller set it by hand. Taking the
    /// directory as an argument makes the names checkable in every run. The names matter because
    /// `dictionary.json` is a documented user interface: a rename would silently leave the user's
    /// hand-edited file behind.
    static func dictionaryFile(in directory: URL) -> URL {
        directory.appendingPathComponent("dictionary.json")
    }

    static func historyFile(in directory: URL) -> URL {
        directory.appendingPathComponent("history.json")
    }

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
    /// Staged through `<name>.bak.new` and swapped in with `replaceItemAt`, rather than the obvious
    /// `removeItem(bak)` then `copyItem(url, bak)`. The obvious order is wrong in the one way that
    /// matters: between those two calls there is no backup on disk at all, and the caller replaces
    /// the real file immediately afterwards regardless — so a crash, a full disk or a revoked
    /// permission in that window leaves amendment 39's incident with its only undo already deleted.
    /// Copying first buys that window away for nothing measurable: a 63 MB copy measured 0.00 s on
    /// APFS, which clones the blocks instead of duplicating them.
    ///
    /// One exception to "always keep the outgoing version": a **zero-length** outgoing file never
    /// replaces a non-empty backup. A 0-byte file is the characteristic output of the truncating
    /// external writer this backup exists to survive, and it carries nothing — so promoting it would
    /// have the undo mechanism delete the only undo, reaching amendment 39's total loss on the first
    /// save after the truncation. An absent or already-empty `.bak` still gets the copy: there is
    /// nothing to protect there, and refusing would leave no backup at all.
    ///
    /// Best-effort by design otherwise: a failure here must never block the real write, because
    /// refusing to save new work in order to protect old work is the wrong trade.
    private static func keepPreviousVersion(of url: URL) {
        let backup = url.appendingPathExtension("bak")
        let staged = url.appendingPathExtension("bak.new")

        if byteSize(of: url) == 0, let held = byteSize(of: backup), held > 0 {
            Log.data.error("refused to overwrite \(backup.lastPathComponent, privacy: .public) with a zero-length \(url.lastPathComponent, privacy: .public)")
            return
        }

        do {
            // A `.bak.new` left behind by an interrupted earlier write is stale by definition, and
            // `copyItem` refuses to overwrite. Removing it destroys nothing recoverable: the backup
            // of record is `.bak`, which nothing below touches until the swap succeeds.
            if FileManager.default.fileExists(atPath: staged.path) {
                try FileManager.default.removeItem(at: staged)
            }
            try FileManager.default.copyItem(at: url, to: staged)
            if FileManager.default.fileExists(atPath: backup.path) {
                _ = try FileManager.default.replaceItemAt(backup, withItemAt: staged)
            } else {
                // `replaceItemAt` requires an existing original, so the very first backup gets the
                // rename instead — equally atomic, and the only reason both branches exist.
                try FileManager.default.moveItem(at: staged, to: backup)
            }
        } catch {
            // Leaving a half-copied `.bak.new` behind would be read as a backup by a human looking
            // for one, so it goes even though the failure is only logged.
            try? FileManager.default.removeItem(at: staged)
            Log.data.debug("could not keep a backup of \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Size in bytes, or `nil` when the file is not there or cannot be stat'd. Deliberately not
    /// `Data(contentsOf:)`: the caller only needs to know whether the file is empty, and reading a
    /// multi-megabyte history in to find out would be the one place this file measures cost.
    private static func byteSize(of url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.intValue
    }

    // MARK: - Quarantine

    /// Move a file that could not be decoded to a sibling name that is never reused, and answer
    /// where it went — or `nil` when the move itself failed.
    ///
    /// This exists because a store that cannot *read* its file goes on to *write* it: `HistoryStore`
    /// schedules a save 500 ms after the next dictation and `save()` replaces the file outright, so
    /// bytes nobody could decode are silently replaced by bytes somebody can. That is amendment 39's
    /// incident reached through a decode error rather than through a stray automated run, and it is
    /// the reason the recovery side of the story cannot just be "log it and carry on".
    ///
    /// The obvious alternative — refuse to save until the user intervenes — is ruled out a few lines
    /// up this file: refusing to save new work in order to protect old work is the wrong trade.
    /// Moving the old bytes aside keeps both sides, and costs one rename.
    ///
    /// `<stem>.unreadable-<ISO8601>.<ext>`. The timestamp is what makes the name never-reused: a
    /// fixed `history.unreadable.json` would let the second failure overwrite what the first one
    /// rescued, which is the same loss displaced by one filename. Basic ISO 8601 rather than the
    /// extended form because a `:` in a filename is legal at the POSIX layer but displays as `/` in
    /// the Finder, and this file exists to be found by a human.
    static func quarantineUnreadableFile(at url: URL) -> URL? {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let stamp = unreadableStampFormatter.string(from: Date())

        // Two failures inside the same second are not a reason to overwrite the first one's bytes.
        for attempt in 0..<100 {
            var name = attempt == 0 ? "\(stem).unreadable-\(stamp)" : "\(stem).unreadable-\(stamp)-\(attempt + 1)"
            if !ext.isEmpty { name += ".\(ext)" }
            let destination = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: destination.path) { continue }
            do {
                try fm.moveItem(at: url, to: destination)
                // Loud, and `.public`, for the same reason as the override notice above: this is
                // Edict's own support directory, and a recovery path nobody can see is no better
                // than the unreachable `.bak` this replaces.
                Log.data.error("moved unreadable \(url.lastPathComponent, privacy: .public) aside to \(destination.lastPathComponent, privacy: .public)")
                return destination
            } catch {
                // A lost race is the one failure worth another attempt: the `fileExists` check above
                // is not atomic with the move, so a concurrent creator (a second Edict process, the
                // user's own editor) can claim this exact name in between. Retrying with
                // `attempt + 1` is what makes the 100-name loop mean anything.
                //
                // Everything else — no write permission on the directory, a read-only volume, a
                // source that has already vanished — will fail identically for all 100 names, so
                // carrying on would buy nothing but 100 lines of log. Bail and let the caller report
                // that the bytes are still where they were.
                let nsError = error as NSError
                let isCollision = (nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteFileExistsError)
                    || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EEXIST))
                if isCollision { continue }
                Log.data.error("could not move unreadable \(url.lastPathComponent, privacy: .public) aside: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        Log.data.error("could not find an unused quarantine name for \(url.lastPathComponent, privacy: .public)")
        return nil
    }

    /// Fixed format and fixed locale: this string goes into a filename, so a user whose region
    /// formats dates differently must not get a differently-shaped name.
    private static let unreadableStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()
}

// MARK: - Why a store file could not be loaded

/// Why one of the two plain-JSON stores could not turn its file into an in-memory store.
///
/// Three shapes, one recovery path, because all three have the same enemy: the next debounced save,
/// which replaces the file outright. Before this existed only `.undecodable` reached the recovery —
/// the read and the emptiness check sat *outside* the `do` block — so an unreadable file and a
/// 0-byte file both skipped the quarantine and the backup and were then overwritten. The 0-byte case
/// was the worse of the two, because it also read as a legitimately empty store, so nothing was
/// reported anywhere.
///
/// They do not *end* the same way, which is why the distinction survives into the recovery: only
/// `.empty` may fall back to an empty store without a word, because zero bytes is also what a file
/// the user genuinely emptied looks like.
enum UnusableStoreFile {
    /// `Data(contentsOf:)` threw — a permissions change, an I/O error, a path that is now a directory.
    case unreadable(any Error)
    /// The bytes are there and the decoder rejected them.
    case undecodable(any Error)
    /// Zero bytes, which is the characteristic output of a truncating external writer.
    case empty

    /// The error to rethrow when recovery does not succeed, or `nil` for `.empty`, which is not a
    /// failure the caller should be told about.
    var underlyingError: (any Error)? {
        switch self {
        case .unreadable(let error), .undecodable(let error): error
        case .empty: nil
        }
    }

    var isEmptyFile: Bool {
        if case .empty = self { return true }
        return false
    }

    /// The first sentence of the user-visible message. `filename` is the last path component only,
    /// for the same reason `TranscriptSource.imported` stores only that: a home directory is nobody's
    /// business, and this string is shown in the window.
    func sentence(about filename: String) -> String {
        switch self {
        case .unreadable(let error), .undecodable(let error):
            "\(filename) could not be read: \(error.localizedDescription)"
        case .empty:
            "\(filename) was empty — zero bytes, not an empty list."
        }
    }
}
