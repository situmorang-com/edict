import Foundation
import Observation

// MARK: - Shared value types

public struct DictionaryEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        /// A word or phrase the engine should know about. Biasing only, plus optional canonical-case fixups.
        case term(String)
        /// "When you hear `heard`, write `write`." The guaranteed path (layer 2 of the dictionary).
        case correction(heard: String, write: String)
    }

    public var id: UUID
    public var kind: Kind
    public var enabled: Bool
    public var note: String?
    public var createdAt: Date
    /// Bumped by the corrector each time this entry changes text. Persisted, and used to rank the
    /// biasing list — a rule that keeps firing is exactly the term worth spending an analyzer slot on.
    public var hitCount: Int
    public var lastHitAt: Date?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        enabled: Bool = true,
        note: String? = nil,
        createdAt: Date = Date(),
        hitCount: Int = 0,
        lastHitAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.note = note
        self.createdAt = createdAt
        self.hitCount = hitCount
        self.lastHitAt = lastHitAt
    }

    /// The text shown in the left column of the dictionary table.
    public var displayTerm: String {
        switch kind {
        case .term(let t): t
        case .correction(let heard, _): heard
        }
    }

    /// The text shown in the right column; nil for `.term`.
    public var displayReplacement: String? {
        switch kind {
        case .term: nil
        case .correction(_, let write): write
        }
    }

    public var isCorrection: Bool {
        if case .correction = kind { return true }
        return false
    }

    /// What we want the engine to *produce*. Never the misheard form — biasing toward "cloud code"
    /// would actively teach the analyzer the mistake.
    public var biasingCandidate: String {
        switch kind {
        case .term(let t): t
        case .correction(_, let write): write
        }
    }

    // MARK: Codable
    //
    // Hand-written, and flattened, because `dictionary.json` is a documented plain-file interface that
    // users are expected to open in a text editor. Swift's synthesised enum-with-payload encoding would
    // emit `{"kind":{"term":{"_0":"Vercel"}}}`; this emits `{"type":"term","term":"Vercel"}`.

    private enum CodingKeys: String, CodingKey {
        case id, type, term, heard, write, enabled, note, createdAt, hitCount, lastHitAt
    }

    /// Every field optional so a hand-edited file with a missing `id` or `createdAt` still loads.
    struct Raw: Decodable {
        var id: UUID?
        var type: String?
        var term: String?
        var heard: String?
        var write: String?
        var enabled: Bool?
        var note: String?
        var createdAt: Date?
        var hitCount: Int?
        var lastHitAt: Date?
    }

    /// nil when the object carries no usable term at all; the loader counts and reports those rather
    /// than failing the whole file.
    init?(raw: Raw) {
        let kind: Kind
        let declaredCorrection = raw.type?.lowercased() == "correction"
        if declaredCorrection || raw.heard != nil {
            guard let heard = (raw.heard ?? raw.term)?.trimmed, !heard.isEmpty else { return nil }
            // A `heard` with no `write` is meaningless as a correction; treat it as a plain term so the
            // user's typo degrades to something harmless instead of an empty-string replacement.
            if let write = raw.write?.trimmed, !write.isEmpty {
                kind = .correction(heard: heard, write: write)
            } else {
                kind = .term(heard)
            }
        } else {
            guard let term = (raw.term ?? raw.write)?.trimmed, !term.isEmpty else { return nil }
            kind = .term(term)
        }
        self.init(
            id: raw.id ?? UUID(),
            kind: kind,
            enabled: raw.enabled ?? true,
            note: raw.note,
            createdAt: raw.createdAt ?? Date(),
            hitCount: raw.hitCount ?? 0,
            lastHitAt: raw.lastHitAt
        )
    }

    public init(from decoder: any Decoder) throws {
        let raw = try Raw(from: decoder)
        guard let entry = DictionaryEntry(raw: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Dictionary entry has neither a \"term\" nor a \"heard\" value."
            ))
        }
        self = entry
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        switch kind {
        case .term(let t):
            try c.encode("term", forKey: .type)
            try c.encode(t, forKey: .term)
        case .correction(let heard, let write):
            try c.encode("correction", forKey: .type)
            try c.encode(heard, forKey: .heard)
            try c.encode(write, forKey: .write)
        }
        try c.encode(enabled, forKey: .enabled)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(hitCount, forKey: .hitCount)
        try c.encodeIfPresent(lastHitAt, forKey: .lastHitAt)
    }
}

/// One correction that actually fired, recorded so history can show what the dictionary did.
public struct CorrectionHit: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var entryID: UUID
    /// The literal text that was matched, exactly as the engine produced it.
    public var from: String
    public var to: String
    /// UTF-16 offset in the *raw* transcript, so the history view can highlight the original span.
    public var offset: Int

    public init(id: UUID = UUID(), entryID: UUID, from: String, to: String, offset: Int) {
        self.id = id
        self.entryID = entryID
        self.from = from
        self.to = to
        self.offset = offset
    }
}

/// The outcome of the post-transcription correction pass.
public struct CorrectionResult: Sendable, Hashable {
    public var text: String
    public var hits: [CorrectionHit]

    public init(text: String, hits: [CorrectionHit]) {
        self.text = text
        self.hits = hits
    }
}

/// Flagged at add/edit time so the UI can warn before a rule corrupts ordinary prose.
public struct EntryRisk: Sendable, Hashable {
    public enum Level: Int, Sendable, Hashable, Comparable {
        case none, notice, warning
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var level: Level
    public var message: String?

    public init(level: Level, message: String? = nil) {
        self.level = level
        self.message = message
    }

    public static let ok = EntryRisk(level: .none)
}

// MARK: - Store

/// Owns `dictionary.json`.
///
/// The file is a *documented interface*, not an implementation detail: the dictionary pane shows its
/// path and invites the user to edit it directly, which is why `startWatchingFile()` exists and why the
/// on-disk shape is flat, ISO-8601-dated, and tolerant of missing fields.
@MainActor @Observable
public final class DictionaryStore {
    public static let shared = DictionaryStore(fileURL: AppPaths.dictionaryFile)

    public private(set) var entries: [DictionaryEntry] = []
    /// Set when the file existed but could not be used as it was — and also set, deliberately, after
    /// a **successful** recovery, because a recovery is news. The pane surfaces it instead of
    /// silently showing an empty dictionary, which would look like data loss.
    ///
    /// Read it together with `recoveredEntryCount`: non-nil does not mean the load failed.
    public private(set) var lastLoadError: String?
    /// How many entries the last load rescued from `dictionary.json.bak`, or `nil` when nothing was
    /// rescued. Lets the UI tell a recovery from a failure without matching substrings of
    /// `lastLoadError`.
    public private(set) var recoveredEntryCount: Int?
    /// Where the bytes that could not be read were moved to, or `nil` when nothing was moved —
    /// which covers both an ordinary load and a quarantine that *failed*, the second of which
    /// `lastLoadError` states in words.
    public private(set) var quarantinedFileURL: URL?

    /// The quarantine file's name on its own, for a message that must not print a home directory.
    public var quarantinedFileName: String? { quarantinedFileURL?.lastPathComponent }

    /// Why the terminal flush could not write, or `nil` if it has not failed.
    ///
    /// Exists so the failure is assertable and, later, showable. `flushPendingSave()` runs from
    /// `applicationWillTerminate` with no UI left to report to, so the log is the only channel at the
    /// time — but the log is also not something a test can read, and an untestable error path is how
    /// this one stayed a bare `try?` for as long as it did.
    public private(set) var lastFlushError: String?

    public let fileURL: URL

    /// Injectable so the tests never touch `~/Library/Application Support/Edict`.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: Loading and saving

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// The exact bytes we last wrote. The file watcher compares against this so our own atomic
    /// `replaceItemAt` — which fires a rename *and* a write event — never triggers a reload.
    @ObservationIgnored private var lastWrittenData: Data?
    /// Bumped on every mutation; keys the compiled-rules cache.
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var rulesCache: (revision: Int, normalising: Bool, rules: [CorrectionRule])?

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// - Parameter recoverFromBackup: when the file is present and does not parse, move the
    ///   unreadable bytes aside and adopt `dictionary.json.bak` if it decodes.
    ///
    ///   True for the launch load, where an unreadable file is on its way to being overwritten by the
    ///   next debounced save and the backup is the only copy of the user's terms. **False** for the
    ///   file watcher's reload, and that asymmetry is the point: `dictionary.json` is a documented
    ///   plain-file interface a user is invited to hand-edit, so a save from their editor with a
    ///   stray comma in it must not have the file yanked out from under them mid-edit. There the old
    ///   behaviour is still right — keep what is in memory, report, change nothing on disk.
    public func load(recoverFromBackup: Bool = true) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            // A decodable backup means this is NOT first run, and seeding over it is the worse of the
            // two absent-file bugs: the user's own terms get replaced by starter entries, the log says
            // "Seeded starter dictionary" so it reads as a fresh install, and the backup that still
            // held their terms is destroyed by the next edit. `decodeBackup` used to be reachable only
            // from `recoverAfterFailedDecode`, which requires the file to be PRESENT — so the most
            // likely way a dictionary disappears was the one way the backup was never consulted.
            //
            // `recoverFromBackup` is honoured here for the same reason it exists on the decode path:
            // `reloadIfChangedOnDisk` must never reinterpret a user's editor writing a file, and a
            // watcher event that observes the file mid-replace can see it briefly absent.
            if recoverFromBackup, let recovered = decodeBackup() {
                entries = recovered
                recoveredEntryCount = recovered.count
                quarantinedFileURL = nil
                lastLoadError = "\(fileURL.lastPathComponent) is not there."
                    + " Recovered \(recovered.count) entr\(recovered.count == 1 ? "y" : "ies")"
                    + " from the backup, so the starter dictionary was not seeded over them."
                bumpRevision()
                Log.data.notice("recovered \(recovered.count, privacy: .public) dictionary entries from the backup; the store file was absent")
                // Reinstated for the same reason as history, plus one specific to this store: an
                // absent `dictionary.json` on the NEXT launch would seed the starter entries over the
                // recovered terms, so a recovery that is not written back is actively unsafe here.
                try save()
                return
            }

            // First run: seed something visible so the feature is obviously alive rather than an
            // empty table the user has to believe in.
            entries = Self.starterEntries()
            clearLoadDiagnostics()
            bumpRevision()
            try save()
            Log.data.info("Seeded starter dictionary with \(self.entries.count, privacy: .public) entries")
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            // This read used to sit outside the `do` below, so an *unreadable* file — as opposed to
            // an undecodable one — skipped the quarantine and the backup and was then replaced by
            // the next debounced save.
            Log.data.error("Dictionary read failed: \(error.localizedDescription, privacy: .public)")
            try handleUnusableFile(.unreadable(error), recoverFromBackup: recoverFromBackup)
            return
        }

        if data.isEmpty {
            // A 0-byte file is not an empty dictionary; it is what a truncating writer leaves behind.
            // Reading it as "the user has no terms" meant no quarantine, no backup, and a `nil`
            // `lastLoadError`, and then the first debounced save had `keepPreviousVersion` copy the
            // 0 bytes over the `.bak`.
            try handleUnusableFile(.empty, recoverFromBackup: recoverFromBackup)
            return
        }

        do {
            let raws = try Self.decoder.decode([DictionaryEntry.Raw].self, from: data)
            let decoded = raws.compactMap(DictionaryEntry.init(raw:))
            let skipped = raws.count - decoded.count
            entries = decoded
            lastLoadError = skipped == 0
                ? nil
                : "\(skipped) entr\(skipped == 1 ? "y was" : "ies were") skipped: no \"term\" or \"heard\" value."
            recoveredEntryCount = nil
            quarantinedFileURL = nil
            lastWrittenData = data
            bumpRevision()
            if skipped > 0 {
                Log.data.warning("Skipped \(skipped, privacy: .public) malformed dictionary entries")
            }
        } catch {
            Log.data.error("Dictionary decode failed: \(error.localizedDescription, privacy: .public)")
            try handleUnusableFile(.undecodable(error), recoverFromBackup: recoverFromBackup)
        }
    }

    private func clearLoadDiagnostics() {
        lastLoadError = nil
        recoveredEntryCount = nil
        quarantinedFileURL = nil
    }

    /// Route one of the three ways `dictionary.json` can fail to become the store, honouring the
    /// `recoverFromBackup` asymmetry.
    private func handleUnusableFile(_ kind: UnusableStoreFile, recoverFromBackup: Bool) throws {
        guard recoverFromBackup else {
            // Keep whatever is in memory. Overwriting the user's hand-edited file with an empty
            // array because of one stray comma would be unforgivable — and a 0-byte file is the
            // *most* likely thing to see here, because that is what the file looks like for the
            // instant between an editor truncating it and writing the new contents. This path
            // therefore changes nothing on disk and nothing in memory; it only reports.
            lastLoadError = kind.sentence(about: fileURL.lastPathComponent)
            // `.empty` carries no error to rethrow, so the caller gets a quiet return: the reload
            // simply did not happen, which is the correct outcome mid-edit.
            if let error = kind.underlyingError { throw error }
            return
        }
        try recoverAfterFailedDecode(kind)
    }

    /// The one generation `AppPaths.writeAtomically` keeps. Read here and nowhere else in the app.
    private var backupURL: URL { fileURL.appendingPathExtension("bak") }

    /// `dictionary.json` is present and could not be used, on the launch path. Move the bytes aside,
    /// then try the backup.
    ///
    /// The `.bak` is read before the quarantine — different files, so the order is free — because it
    /// is the only way to decide whether a 0-byte `dictionary.json` is worth keeping at all. It is
    /// not, unless a recovery is actually happening; a quarantine file holding nothing, with no
    /// message to explain it, is just litter in a directory the user is invited to open.
    ///
    /// The quarantine still happens before anything is written, and for the two non-empty shapes it
    /// happens even with no backup to adopt, for the same reason as in `HistoryStore`: the next
    /// debounced save writes the whole store, so an unreadable file left in place is an overwritten
    /// one. Here it is strictly kinder than what it replaces — the old code left the user's bytes on
    /// disk right up until the next in-app edit silently replaced them.
    private func recoverAfterFailedDecode(_ kind: UnusableStoreFile) throws {
        let recovered = decodeBackup()
        let quarantined = (recovered != nil || !kind.isEmptyFile)
            ? AppPaths.quarantineUnreadableFile(at: fileURL)
            : nil
        quarantinedFileURL = quarantined
        var message = kind.sentence(about: fileURL.lastPathComponent)

        if let recovered {
            entries = recovered
            recoveredEntryCount = recovered.count
            bumpRevision()
            message += " Recovered \(recovered.count) entr\(recovered.count == 1 ? "y" : "ies") from the backup."
            if let quarantined {
                message += " The unreadable file is kept as \(quarantined.lastPathComponent)."
                lastLoadError = message
                Log.data.notice("Recovered \(recovered.count, privacy: .public) dictionary entries from the backup")
                // Reinstate the file now: `load()` treats an absent `dictionary.json` as first run and
                // would reseed the starter entries over the user's recovered terms on the next launch.
                do { try save() } catch {
                    Log.data.error("could not reinstate dictionary.json after recovery: \(error.localizedDescription, privacy: .public)")
                }
            } else {
                // The quarantine failed, so the file still holds the only copy of the bytes nobody
                // could read. Writing now would have `keepPreviousVersion` copy those bytes over the
                // `.bak` this recovery just came from, and the next edit would copy the reinstated
                // file over that — the original bytes gone in two writes. So the save is skipped and
                // the message says so, instead of dropping the clause and reporting a clean recovery.
                //
                // The cost is real and is named here so nobody "fixes" it by writing anyway: with
                // `dictionary.json` still unreadable, the next launch recovers from the `.bak` again
                // rather than reseeding, which is the correct outcome for as long as the user has not
                // dealt with the file.
                message += " Edict could not move it aside, so those bytes are still in"
                    + " \(fileURL.lastPathComponent) and the recovered entries were not written back."
                    + " Copy that file somewhere safe before editing the dictionary again."
                lastLoadError = message
                Log.data.error("recovered the dictionary from the backup but could not quarantine \(self.fileURL.lastPathComponent, privacy: .public); skipped the reinstating save")
            }
            return
        }

        if kind.isEmptyFile {
            // Nothing to adopt and nothing to report: the empty store `load()` has always presented
            // for a 0-byte file, reached now with the backup genuinely consulted first. Not seeded
            // with the starter entries — the file exists, so this is not first run, and inventing
            // terms over a file the user may be halfway through emptying is not this method's call.
            entries = []
            clearLoadDiagnostics()
            bumpRevision()
            return
        }

        message += quarantined.map { " No usable backup; the unreadable file is kept as \($0.lastPathComponent)." }
            // Not silence. Before this, a failed move just omitted the clause, so the message named
            // no file at all and the only pointer to the user's bytes was the unified log.
            ?? " No usable backup, and Edict could not move the unreadable file aside — those bytes are still in \(fileURL.lastPathComponent)."
        lastLoadError = message
        if let error = kind.underlyingError { throw error }
    }

    /// Decode `dictionary.json.bak`, or `nil` when there is nothing usable in it. An empty result
    /// counts as nothing usable: "recovered 0 entries" is not a recovery.
    private func decodeBackup() -> [DictionaryEntry]? {
        guard let data = try? Data(contentsOf: backupURL), !data.isEmpty,
              let raws = try? Self.decoder.decode([DictionaryEntry.Raw].self, from: data)
        else { return nil }
        // Same lenient compactMap as the primary path: a backup entry with no usable term is worth
        // skipping, not worth abandoning the whole recovery over.
        let decoded = raws.compactMap(DictionaryEntry.init(raw:))
        return decoded.isEmpty ? nil : decoded
    }

    public func save() throws {
        saveTask?.cancel()
        saveTask = nil
        let data = try Self.encoder.encode(entries)
        try AppPaths.writeAtomically(data, to: fileURL)
        lastWrittenData = data
        // Cleared only on the far side of a successful write. `lastFlushError` is surfaced long after
        // it is set — there is no UI at termination — so leaving a stale one behind meant the first
        // time the user ever saw it, it could describe a failure a later save had already fixed.
        lastFlushError = nil

        // Re-arm the file watcher if the file went missing under it.
        //
        // `armWatcher()` bails when the file does not exist, and on a failed recovery the quarantine
        // renames `dictionary.json` away *before* `DictationController.bootstrap` calls
        // `startWatchingFile()` — so the watch was dead for the whole session, and a user who fixed
        // their JSON in an editor got no reload and no hint why. This write has just recreated the
        // file, so there is something to watch again.
        //
        // Honestly partial, and the comment must not pretend otherwise: this recovers the watch
        // through an *in-app* edit only. A file recreated purely from outside Edict, with no in-app
        // save in between, is still only picked up on the next launch.
        if watchRequested, watchSourceStorage == nil { armWatcher() }
    }

    /// Coalesces a burst of edits (typing in the dictionary table, a batch delete) into one disk write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            do { try self.save() } catch {
                Log.data.error("Dictionary save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Force any pending debounced write to disk now. Call before termination.
    public func flushPendingSave() {
        guard saveTask != nil else { return }
        // NOT `try?`. This runs from `applicationWillTerminate` — which is the only reason
        // `NSSupportsSuddenTermination` is false — so it is the last chance the work of the previous
        // 500 ms has to reach disk, and there is no UI left to report to. Swallowing the error here
        // made a lost dictionary invisible rather than merely lost; every other write path in
        // this file logs its failures, so the bare `try?` was an inconsistency, not a policy.
        do {
            try save()
        } catch {
            lastFlushError = error.localizedDescription
            Log.data.error(
                "terminal dictionary flush failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func bumpRevision() {
        revision += 1
        rulesCache = nil
    }

    // MARK: Mutation

    @discardableResult
    public func add(_ entry: DictionaryEntry) -> DictionaryEntry {
        entries.append(entry)
        bumpRevision()
        scheduleSave()
        return entry
    }

    public func update(_ entry: DictionaryEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx] = entry
        bumpRevision()
        scheduleSave()
    }

    public func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let before = entries.count
        entries.removeAll { ids.contains($0.id) }
        guard entries.count != before else { return }
        bumpRevision()
        scheduleSave()
    }

    public func search(_ query: String) -> [DictionaryEntry] {
        let q = query.trimmed
        guard !q.isEmpty else { return entries }
        return entries.filter { entry in
            entry.displayTerm.containsLoosely(q)
                || (entry.displayReplacement?.containsLoosely(q) ?? false)
                || (entry.note?.containsLoosely(q) ?? false)
        }
    }

    /// Bump usage counters after a correction pass so the table can show what is actually earning its keep.
    /// This also feeds `biasingStrings(limit:)` ranking, closing the loop: terms that keep needing the
    /// layer-2 fallback get promoted into the layer-1 biasing list.
    public func recordHits(_ hits: [CorrectionHit]) {
        guard !hits.isEmpty else { return }
        var counts: [UUID: Int] = [:]
        for hit in hits { counts[hit.entryID, default: 0] += 1 }
        let now = Date()
        var changed = false
        for (idx, entry) in entries.enumerated() {
            guard let n = counts[entry.id] else { continue }
            entries[idx].hitCount += n
            entries[idx].lastHitAt = now
            changed = true
        }
        guard changed else { return }
        // No `bumpRevision()`: counters do not affect the compiled rules, and invalidating the cache
        // after every dictation would recompile ~50 rules for nothing.
        scheduleSave()
    }

    // MARK: Biasing (layer 1)

    /// Contextual strings for `AnalysisContext.contextualStrings[.general]`, highest-value first,
    /// deduped case-insensitively, capped at `limit`.
    ///
    /// RECON §5: the cap is 50 and ranking genuinely matters — measured hit rate *degrades* with list
    /// length (a 9-term list fixed "Wispr Flow" and "Obsidian" where a 200-term list fixed neither),
    /// and setup costs ~65 ms + ~1.5 ms per term at analyzer init. So this is a ranked shortlist, not a
    /// dump of the dictionary; anything that does not make the cut is still handled by the corrector.
    public func biasingStrings(limit: Int) -> [String] {
        let cap = max(0, limit)
        guard cap > 0 else { return [] }
        let now = Date()

        let scored: [(text: String, score: Double)] = entries.compactMap { entry in
            guard entry.enabled else { return nil }
            let text = entry.biasingCandidate.trimmed
            // Single characters are useless as contextual strings and dilute the list.
            guard text.count > 1 else { return nil }

            var score = 0.0
            // Proven need dominates: an entry the corrector keeps rescuing is one the acoustic model
            // is getting wrong, which is precisely what biasing is for.
            score += 40.0 * log2(Double(entry.hitCount) + 1)
            if let last = entry.lastHitAt {
                // Half-life of roughly a week, so a term used today outranks one used last month.
                let days = max(0, now.timeIntervalSince(last)) / 86_400
                score += 25.0 * pow(0.5, days / 7.0)
            }
            // A correction is an explicit "the engine gets this wrong" signal from the user; a bare
            // term is only ever a hint.
            if entry.isCorrection { score += 12.0 }
            // Multi-word proper nouns are where biasing measurably paid off ("Wispr Flow", "Claude Code").
            let tokenCount = CorrectionRule.tokenise(text).count
            if tokenCount > 1 { score += 8.0 }
            // Mixed or upper case is a strong proper-noun tell ("SwiftUI", "macOS", "Vercel").
            if text != text.lowercased() { score += 4.0 }
            // Mild recency preference among never-hit entries: the term just added is the one the user
            // is trying to make work right now.
            score += 3.0 * pow(0.5, max(0, now.timeIntervalSince(entry.createdAt)) / 86_400 / 30.0)
            return (text, score)
        }

        var seen = Set<String>()
        var result: [String] = []
        for candidate in scored.sorted(by: { $0.score > $1.score }) {
            let key = candidate.text.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(candidate.text)
            if result.count == cap { break }
        }
        return result
    }

    // MARK: Rules (layer 2)

    /// Compiled rules for the correction pass, longest-first. Recompiled only when `entries` changes.
    public func compiledRules(includeTermCaseNormalisation: Bool) -> [CorrectionRule] {
        if let cache = rulesCache, cache.revision == revision, cache.normalising == includeTermCaseNormalisation {
            return cache.rules
        }

        var rules: [CorrectionRule] = []
        rules.reserveCapacity(entries.count)
        for entry in entries where entry.enabled {
            switch entry.kind {
            case .correction(let heard, let write):
                let rule = CorrectionRule(entryID: entry.id, heard: heard, write: write)
                if rule.isUsable { rules.append(rule) }
            case .term(let term):
                guard includeTermCaseNormalisation else { continue }
                // CONTRACTS corrector rule 8: an implicit `heard == write` rule that only ever changes
                // casing, and emits no hit when the casing already matches.
                let rule = CorrectionRule(entryID: entry.id, heard: term, write: term)
                if rule.isUsable { rules.append(rule) }
            }
        }

        // Stable longest-first ordering. `entries` is in creation order, so equal weights fall back to
        // "whichever the user added first" — the deterministic tie-break CONTRACTS asks for.
        let ordered = rules.enumerated()
            .sorted { $0.element.sortWeight != $1.element.sortWeight
                ? $0.element.sortWeight > $1.element.sortWeight
                : $0.offset < $1.offset }
            .map(\.element)

        rulesCache = (revision, includeTermCaseNormalisation, ordered)
        return ordered
    }

    /// Convenience: the corrector configured from the current entries and settings.
    public func corrector(includeTermCaseNormalisation: Bool) -> Corrector {
        Corrector(rules: compiledRules(includeTermCaseNormalisation: includeTermCaseNormalisation))
    }

    // MARK: File watching

    @ObservationIgnored private var watchDebounce: Task<Void, Never>?
    @ObservationIgnored private var watchSourceStorage: (any DispatchSourceFileSystemObject)?
    /// True between `startWatchingFile()` and `stopWatchingFile()`, whether or not a source is
    /// currently armed. Separate from `watchSourceStorage != nil` because those two differ in exactly
    /// the case that matters: watching was asked for, and the file was not there to arm on. Without
    /// it, `save()`'s re-arm would start watching in a process that never asked to — every test that
    /// saves, for one.
    @ObservationIgnored private var watchRequested = false

    /// Watch `dictionary.json` and reload on external edits.
    ///
    /// Two non-obvious requirements. (1) Debounce ~250 ms: a text editor's save is several syscalls and
    /// fires several vnode events. (2) Do not react to our own writes — `AppPaths.writeAtomically` uses
    /// `replaceItemAt`, which both fires events *and* swaps the inode out from under the watched file
    /// descriptor. So after every debounced fire the source is torn down and rebuilt, and the reload is
    /// gated on the file's bytes differing from what we last wrote.
    public func startWatchingFile() {
        stopWatchingFile()
        watchRequested = true
        armWatcher()
    }

    public func stopWatchingFile() {
        watchRequested = false
        watchDebounce?.cancel()
        watchDebounce = nil
        watchSourceStorage?.cancel()
        watchSourceStorage = nil
    }

    private func armWatcher() {
        // Nothing to watch until the file exists; `load()` creates it on first run, and a failed
        // recovery renames it away. `save()` retries this call for the second case.
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let fd = open(fileURL.path, O_EVTONLY)
        guard fd >= 0 else {
            Log.data.error("Could not open dictionary.json for watching (errno \(errno, privacy: .public))")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete, .revoke],
            queue: DispatchQueue.global(qos: .utility)
        )
        // Both handlers MUST be `@Sendable`. `setCancelHandler`/`setEventHandler` take non-Sendable
        // blocks, so a plain closure written inside this main-actor method inherits main-actor
        // isolation — and Swift 6 then emits an `_swift_task_checkIsolated` precondition that traps
        // (SIGTRAP in `_dispatch_assert_queue_fail`) the moment Dispatch runs it on its own queue.
        source.setCancelHandler { @Sendable in close(fd) }
        source.setEventHandler { @Sendable [weak self] in
            Task { @MainActor in self?.fileSystemEventFired() }
        }
        watchSourceStorage = source
        source.resume()
    }

    private func fileSystemEventFired() {
        watchDebounce?.cancel()
        watchDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            self.watchDebounce = nil
            // Rebuild first: after an atomic replace the old descriptor points at an unlinked inode and
            // would never fire again.
            self.watchSourceStorage?.cancel()
            self.watchSourceStorage = nil
            self.armWatcher()
            self.reloadIfChangedOnDisk()
        }
    }

    /// Reload only when the bytes differ from our last write. This is what keeps our own saves from
    /// looping, and it also makes a byte-identical external edit correctly a no-op.
    private func reloadIfChangedOnDisk() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let last = lastWrittenData, last == data { return }
        // An in-flight debounced save of ours is newer than anything on disk, so it wins: flush it and
        // abandon the reload rather than resurrect the stale copy over the user's in-app edit.
        if saveTask != nil {
            flushPendingSave()
            return
        }
        do {
            // `recoverFromBackup: false`: the bytes on disk are the user's, seconds old, and possibly
            // mid-edit. Moving their file aside because their editor saved a half-typed line would be
            // the app breaking a documented plain-file interface. See `load(recoverFromBackup:)`.
            try load(recoverFromBackup: false)
            Log.data.info("Reloaded dictionary.json after external edit (\(self.entries.count, privacy: .public) entries)")
        } catch {
            Log.data.error("External dictionary edit did not parse: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Risk assessment

    /// Warn at add/edit time when a rule looks like it will fire on ordinary prose.
    ///
    /// The whole hazard of layer 2 is that it is unconditional: a `heard` of "cloud" rewrites the word
    /// "cloud" in every sentence the user ever dictates. Nothing clever here on purpose — a short
    /// embedded common-word list catches the realistic mistakes, and pretending to do more would just
    /// produce confident nonsense.
    public static func assessRisk(for kind: DictionaryEntry.Kind) -> EntryRisk {
        let heard: String
        let isCorrection: Bool
        switch kind {
        case .term(let t): heard = t.trimmed; isCorrection = false
        case .correction(let h, _): heard = h.trimmed; isCorrection = true
        }

        guard !heard.isEmpty else {
            return EntryRisk(level: .warning, message: "This entry has no text, so it can never match anything.")
        }

        let tokens = CorrectionRule.tokenise(heard)
        guard !tokens.isEmpty else {
            return EntryRisk(level: .warning, message: "This entry is only punctuation, so it can never match a word.")
        }

        if tokens.count == 1 {
            let token = tokens[0]
            if token.count < 3 {
                return EntryRisk(
                    level: .warning,
                    message: "\"\(token)\" is only \(token.count) character\(token.count == 1 ? "" : "s") long; short entries fire constantly on ordinary speech."
                )
            }
            if Self.commonEnglishWords.contains(token.lowercased()) {
                return EntryRisk(
                    level: .warning,
                    message: isCorrection
                        ? "\"\(token)\" is a common English word; this will fire on ordinary prose."
                        : "\"\(token)\" is a common English word; case normalisation will change it everywhere it appears."
                )
            }
            if !isCorrection {
                // A lone lowercase word is a weak biasing signal — proper nouns are what pay off (RECON §5).
                if token == token.lowercased() {
                    return EntryRisk(
                        level: .notice,
                        message: "\"\(token)\" has no distinctive capitalisation, so biasing it is unlikely to help much."
                    )
                }
            }
            return .ok
        }

        // Multi-token entries are far safer, but "the thing" is still every other sentence.
        let allCommon = tokens.allSatisfy { Self.commonEnglishWords.contains($0.lowercased()) }
        if allCommon {
            return EntryRisk(
                level: .notice,
                message: "\"\(heard)\" is made entirely of common English words; it may fire on ordinary prose."
            )
        }
        return .ok
    }

    // MARK: Starter content

    /// Shipped on first run so the two-layer dictionary is visibly doing something before the user has
    /// typed anything. Every term here is one RECON actually observed the engine getting wrong.
    static func starterEntries(now: Date = Date()) -> [DictionaryEntry] {
        let terms = [
            "Edict", "Claude Code", "Anthropic", "Vercel", "Supabase", "Wispr Flow",
            "SwiftUI", "Xcode", "macOS", "Obsidian",
        ]
        var result = terms.enumerated().map { index, term in
            DictionaryEntry(
                kind: .term(term),
                note: "Shipped with Edict.",
                // Spread the timestamps so creation order (and therefore the rule tie-break) is stable.
                createdAt: now.addingTimeInterval(Double(index) * 0.001)
            )
        }
        // The canonical demonstration: RECON heard "cloud code" repeatedly, and biasing alone did not
        // reliably fix it. This is exactly the case layer 2 exists for.
        result.append(DictionaryEntry(
            kind: .correction(heard: "cloud code", write: "Claude Code"),
            note: "Shipped with Edict.",
            createdAt: now.addingTimeInterval(Double(terms.count) * 0.001)
        ))
        return result
    }

    /// Deliberately small and deliberately hand-picked: the words a dictation user is most likely to
    /// type into the `heard` field without realising it appears in every third sentence.
    static let commonEnglishWords: Set<String> = [
        "a", "able", "about", "above", "across", "act", "actually", "add", "after", "again", "against",
        "age", "ago", "agree", "all", "almost", "alone", "along", "already", "also", "although",
        "always", "am", "among", "an", "and", "another", "answer", "any", "anyone", "anything",
        "appear", "are", "area", "around", "as", "ask", "at", "away",
        "back", "bad", "base", "be", "because", "become", "been", "before", "begin", "behind", "being",
        "believe", "below", "best", "better", "between", "big", "bit", "book", "both", "boy", "break",
        "bring", "build", "business", "but", "buy", "by",
        "call", "can", "car", "care", "carry", "case", "cause", "certain", "change", "check", "child",
        "choose", "city", "class", "clean", "clear", "close", "cloud", "code", "cold", "come",
        "company", "consider", "continue", "could", "country", "course", "cover", "create", "cut",
        "data", "day", "deal", "decide", "deep", "develop", "did", "die", "differ", "different", "do",
        "does", "done", "down", "draw", "drive", "drop", "during",
        "each", "early", "easy", "eat", "either", "else", "end", "enough", "even", "ever", "every",
        "example", "expect", "explain", "eye",
        "face", "fact", "fall", "family", "far", "fast", "feel", "few", "field", "figure", "fill",
        "find", "fine", "first", "fix", "flow", "follow", "food", "for", "force", "form", "found",
        "free", "friend", "from", "front", "full", "further",
        "game", "general", "get", "girl", "give", "go", "good", "got", "government", "great", "group",
        "grow", "guess",
        "had", "half", "hand", "happen", "hard", "has", "have", "he", "head", "hear", "help", "her",
        "here", "high", "him", "his", "hold", "home", "hope", "hour", "house", "how", "however",
        "i", "idea", "if", "important", "in", "include", "increase", "indeed", "information", "inside",
        "instead", "interest", "into", "is", "issue", "it", "its",
        "job", "join", "just",
        "keep", "kind", "know",
        "land", "language", "large", "last", "late", "later", "lead", "learn", "leave", "left", "less",
        "let", "level", "life", "light", "like", "line", "list", "listen", "little", "live", "long",
        "look", "lose", "lot", "love", "low",
        "made", "main", "make", "man", "many", "matter", "may", "maybe", "me", "mean", "meet", "might",
        "mind", "minute", "miss", "moment", "money", "month", "more", "most", "move", "much", "must",
        "my",
        "name", "near", "need", "never", "new", "next", "nice", "night", "no", "none", "nor", "not",
        "note", "nothing", "now", "number",
        "of", "off", "offer", "office", "often", "oh", "okay", "old", "on", "once", "one", "only",
        "open", "or", "order", "other", "our", "out", "over", "own",
        "page", "paper", "part", "pass", "past", "pay", "people", "perhaps", "person", "pick", "place",
        "plan", "play", "please", "point", "possible", "power", "present", "press", "pretty",
        "probably", "problem", "process", "produce", "product", "provide", "put",
        "question", "quick", "quite",
        "rather", "reach", "read", "ready", "real", "really", "reason", "receive", "record", "remain",
        "remember", "report", "require", "rest", "result", "return", "right", "room", "run",
        "said", "same", "save", "saw", "say", "school", "second", "see", "seem", "send", "sense",
        "series", "serve", "service", "set", "several", "shall", "share", "she", "short", "should",
        "show", "side", "since", "single", "sit", "small", "so", "some", "someone", "something",
        "sometimes", "soon", "sort", "sound", "speak", "special", "stand", "start", "state", "stay",
        "step", "still", "stop", "story", "study", "such", "suggest", "sure", "system",
        "take", "talk", "team", "tell", "term", "test", "than", "thank", "that", "the", "their",
        "them", "then", "there", "these", "they", "thing", "think", "this", "those", "though",
        "thought", "three", "through", "time", "to", "today", "together", "too", "took", "top",
        "toward", "town", "try", "turn", "two", "type",
        "under", "understand", "until", "up", "upon", "us", "use", "used", "usually",
        "value", "very", "view", "voice",
        "wait", "walk", "want", "war", "was", "watch", "water", "way", "we", "week", "well", "went",
        "were", "what", "when", "where", "whether", "which", "while", "white", "who", "whole", "why",
        "will", "wish", "with", "within", "without", "woman", "word", "work", "world", "would",
        "write", "wrong",
        "year", "yes", "yet", "you", "young", "your",
    ]
}

// MARK: - Small shared helpers

extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Case- and diacritic-insensitive substring match. Used by both stores' search boxes so that
    /// "cafe" finds "café" and "MACOS" finds "macOS".
    func containsLoosely<T: StringProtocol>(_ other: T) -> Bool {
        range(of: other, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
