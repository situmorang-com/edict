//
//  ImportQueue.swift
//  The serial batch queue behind file transcription.
//
//  One file at a time, deliberately. Concurrent transcription would put two `SpeechAnalyzer`
//  instances on the same on-device model: `SpeechEngine` holds exactly one `activeSession` and
//  rejects a second with `.sessionAlreadyRunning`, and even if it did not, RECON §5 measured
//  analyzer init at ~65 ms plus ~1.5 ms per biasing term, so two in flight would contend rather
//  than parallelise. A serial queue also keeps the ordering the user sees identical to the ordering
//  they dropped the files in.
//
//  Isolation: `@MainActor` throughout. Everything expensive — asset inspection, decoding, the
//  analyzer — happens inside `AudioFileImporter` (an actor) or behind the injected `transcribe`
//  closure, both of which are awaited. The main actor only ever mutates the observable item list,
//  so the UI never blocks on a decode.
//

import AVFoundation
import Foundation
import Observation
import Speech

/// A serial queue of files to transcribe.
///
/// The queue owns scheduling, progress and per-item state. It does **not** own the speech engine or
/// the history store — those arrive as closures in `Environment` and `onFinish`, which is what lets
/// it be driven in a test without a microphone, a model, or a disk.
@MainActor
@Observable
public final class ImportQueue {

    // MARK: - Item state

    /// Where one file is in its life. Exactly the five states the UI can render; anything finer
    /// (which chunk, which reader) belongs in `ImportStats`.
    public enum ItemState: Sendable, Hashable {
        case queued
        /// Estimated overall completion, 0…0.99, ticking at 10 Hz. See `ImportQueue.progressNote`
        /// for what this number is and is not.
        case running(progress: Double)
        case done
        /// Already-user-facing text, from `AudioImportError.errorDescription` where the failure came
        /// from the importer.
        case failed(reason: String)
        /// The user cancelled this item. Distinct from `failed` because nothing went wrong.
        case cancelled

        public var isTerminal: Bool {
            switch self {
            case .queued, .running: false
            case .done, .failed, .cancelled: true
            }
        }

        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    /// Which half of the work an item is in.
    ///
    /// The two are wildly asymmetric and the UI has to know which one it is looking at. Decoding a
    /// file runs at 570–4300x realtime (measured: a 377 s m4a is fully read in 90 ms), while
    /// transcription runs at ~15x. `SpeechEngine` feeds its analyzer through an unbounded stream, so
    /// it accepts everything we can read immediately and there is no way to observe the model's
    /// position from out here. So `reading` carries a real fraction and is over almost at once;
    /// `transcribing` is where all the time goes and must be rendered as indeterminate, with
    /// `runningText` as the thing that actually moves.
    public enum Phase: Sendable, Hashable {
        /// Fraction of the file handed to the transcriber, 0…1.
        case reading(Double)
        /// Everything is queued; the model is working through it.
        case transcribing
        /// A dual pass, which unlike the single pass can say where it actually is: `done` of `total`
        /// transcription passes finished, two per section. Reported separately from `transcribing`
        /// because the number is a measurement rather than an estimate — see
        /// `DualPassImporter.progressNote`.
        case transcribingSections(done: Int, total: Int)
    }

    /// One row of the queue.
    public struct Item: Identifiable, Sendable, Hashable {
        public let id: UUID
        public let url: URL
        /// Last path component. The full path is deliberately never shown — same rule as
        /// `TranscriptSource.imported(filename:)`.
        public let filename: String

        /// The language this file will be transcribed in.
        ///
        /// **Resolved once, at enqueue, and never re-read from `Settings` afterwards.** That is the
        /// whole point of the field. The old behaviour read `Settings.localeIdentifier` inside
        /// `transcribeImport`, so a file sitting in the queue changed language under the user if they
        /// touched the dictation picker, and — far worse — a file whose language was simply *not* the
        /// dictation language was transcribed by the wrong acoustic model with nothing on screen
        /// saying so. RECON amendment 45 measured what that costs: the same Indonesian audio came
        /// back as "Dan ada workshop karena sekarang…" under `id-ID` and as "Then other workshop
        /// Karna Saka Ito Sanga Dunia…" under `en-US`, because an English lexicon is at its most
        /// permissive around names. It does not fail; it invents.
        public var localeIdentifier: String

        /// True when the user picked this language for this file; false when it was inherited from
        /// the dictation language at enqueue time.
        ///
        /// The default is "follow my dictation language, **and show me**", so the surface needs to
        /// tell an inherited locale from a chosen one — an inherited one is the thing worth
        /// double-checking before reading 900 words.
        public var localeWasChosen: Bool

        /// Populated as soon as the file has been inspected, which is before any decoding.
        public var info: AudioFileInfo?
        public var state: ItemState
        /// The history entry this file produced, once it has one.
        public var transcriptID: UUID?
        /// Read counters, available once the item has finished.
        public var stats: ImportStats?
        /// Set when the transcript is real but incomplete — the reader stopped early, so the text
        /// is worth keeping and the UI must say so rather than let the user believe it is complete.
        public var warning: String?

        /// Non-nil on a row produced by `rerun`: the id of the row it was re-run from, so the
        /// surface can present the two transcripts as a pair rather than as two unrelated imports.
        public var rerunOf: Item.ID?

        /// Whether the language can still be changed. A running or finished item cannot: the
        /// analyzer is built from one `Locale` and never rebuilt (RECON §3), so the answer for a
        /// finished row is `rerun`, not a mutation.
        public var localeIsEditable: Bool { state == .queued }

        init(url: URL, localeIdentifier: String, localeWasChosen: Bool, rerunOf: Item.ID? = nil) {
            self.id = UUID()
            self.url = url
            self.filename = url.lastPathComponent
            self.localeIdentifier = localeIdentifier
            self.localeWasChosen = localeWasChosen
            self.rerunOf = rerunOf
            self.state = .queued
        }
    }

    // MARK: - Result

    /// One finished file, ready to become a `Transcript`.
    ///
    /// The queue stops here on purpose: correction (`Corrector`) and persistence (`HistoryStore`)
    /// belong to whoever owns those, so `onFinish` hands this over and gets an id back.
    public struct Result: Sendable {
        public var itemID: UUID
        public var url: URL
        public var info: AudioFileInfo
        /// The language this file was actually transcribed in — the item's locale, not
        /// `Settings.localeIdentifier`.
        ///
        /// Separate from `localeIdentifiers` on purpose. That field answers "which languages
        /// contributed text", which only a dual pass can answer and which stays empty for a single
        /// pass; this one answers "which model ran", which is always known and is the thing the
        /// history entry must be attributed to. Collapsing them would make an ordinary import claim
        /// a language *contest* it never held.
        public var localeIdentifier: String
        public var outcome: TranscriptionOutcome
        /// Per-word timings, ready for SRT/VTT export. Derived from
        /// `TranscriptionOutcome.words`, which carry `audioTimeRange` because
        /// `SpeechEngine.build(module:locale:)` asks for that attribute explicitly.
        public var segments: [TranscriptSegment]
        public var stats: ImportStats
        /// Non-nil when audio is known to be missing from the transcript — the read stopped early,
        /// buffers were refused by the converter, or the tail was dropped. The text that is here is
        /// genuine; see `ImportQueue.readVerdict` for how the sentence is built.
        public var incompleteReason: String?
        /// Wall clock for the whole file: open, decode, transcribe, finalize.
        public var wallSeconds: Double

        /// How much of the audio became words, and one sentence about it. Always present — a good
        /// transcript answers `isConcerning == false` and the UI shows nothing.
        public var quality: RecognitionQuality

        /// Locales that produced text, by share of recognised audio, descending.
        ///
        /// **Empty for a single-pass import**, where the queue has no business knowing the language:
        /// the caller picked one locale and it is the only one that could have produced anything, so
        /// repeating it here would be a second source of truth to disagree with the first.
        public var localeIdentifiers: [String]

        /// Per-section verdicts, empty unless a dual pass ran.
        public var sections: [DualPassSection]

        /// True when this file went through two passes per section.
        public var wasDualPass: Bool { !sections.isEmpty }

        /// End-to-end speed, e.g. 18.4 means an hour of audio in 3 minutes 15. This is the number
        /// worth quoting, not `ImportStats.realtimeFactor`, which only covers decoding.
        public var realtimeFactor: Double {
            wallSeconds > 0 ? info.duration / wallSeconds : 0
        }
    }

    /// One finished dual-pass job, as the injected closure hands it back.
    public struct DualPassJob: Sendable {
        public var info: AudioFileInfo
        public var outcome: DualPassOutcome
        /// Wall clock for decode + segment + every pass.
        public var wallSeconds: Double

        public init(info: AudioFileInfo, outcome: DualPassOutcome, wallSeconds: Double) {
            self.info = info
            self.outcome = outcome
            self.wallSeconds = wallSeconds
        }
    }

    // MARK: - Environment

    /// Everything the queue needs from the rest of the app. Injected rather than reached for, so
    /// the queue is testable with three closures and no frameworks running.
    public struct Environment: Sendable {
        /// `SpeechEngine.bestAudioFormat(for:)` for one locale. Asked once per file, because
        /// `availableCompatibleAudioFormats` is a property of the module and the module is resolved
        /// from the **item's** locale — a queue holding one `en-US` file and one `id-ID` file runs two
        /// different modules and must convert each file for the one that will read it.
        public var analyzerFormat: @Sendable (String) async -> AVAudioFormat?

        /// `SpeechEngine.transcribe(input:pass:…)`, curried, for one locale. The queue hands over the
        /// item's locale, a stream and an update callback and gets back the finished outcome.
        ///
        /// The locale is a parameter and not a captured setting because that is the bug this whole
        /// feature exists to close: whoever implements this closure must resolve the module from the
        /// identifier it is given, and must **fail** rather than substitute a different language when
        /// that language's assets are missing.
        public var transcribe: @Sendable (
            String,
            AsyncStream<AnalyzerInput>,
            @escaping @Sendable (TranscriptionUpdate) -> Void
        ) async throws -> TranscriptionOutcome

        /// `SpeechEngine.cancel()`. Without it, cancelling an item only closes the audio stream —
        /// and because the whole file is already sitting in the analyzer's unbounded input queue,
        /// `transcribe` then spends its full ~15x-realtime run finalizing audio nobody wants
        /// (measured: cancelling a 377 s file still took ~25 s to return). With it, the analyzer is
        /// torn down with `cancelAndFinishNow()` and cancel is immediate. Optional so the queue can
        /// be tested with two closures.
        public var cancelActive: (@Sendable () async -> Void)?

        /// The whole dual-pass job for one file, or `nil` when dual pass is switched off entirely.
        ///
        /// It owns the decode as well as the transcription because the two are inseparable there:
        /// `SpeechSegmenter` needs the whole buffer, and each section is replayed twice, so the
        /// streaming reader the single-pass route uses is not applicable. Returning `nil` *from the
        /// closure* means "not this file" — a second language whose model is still downloading, say —
        /// and the queue quietly runs the ordinary single pass instead rather than failing the file.
        /// The second argument is the **item's** locale, which becomes the first pass's language.
        /// See `ImportQueue.dualPassRule` for what a per-item locale means when dual pass is on.
        public var dualPass: (
            @Sendable (URL, String, DualPassImporter.Reporting) async throws -> DualPassJob?
        )?

        /// The dictation language, read at the moment of an `enqueue` that did not name one.
        ///
        /// A closure rather than a stored string because the queue is built once at launch and the
        /// user can change the dictation picker at any time: "inherit" has to mean "inherit *now*",
        /// which is exactly one read, at enqueue, of a value that is then frozen onto the item.
        public var dictationLocaleIdentifier: @MainActor @Sendable () -> String

        /// Every language a file may be imported in.
        ///
        /// `DictationTranscriber.supportedLocales` is the superset — 54 identifiers against
        /// `SpeechTranscriber`'s 45 — and the right list to offer, because the module is resolved
        /// *from* the locale rather than the other way round: a locale only the dictation module
        /// covers (`id-ID`) is fully supported, it simply runs the other model.
        public var supportedLocaleIdentifiers: @Sendable () async -> [String]

        /// The second language a dual pass would also try, or `nil` when dual pass is off.
        /// Rendered by the surface next to the item's own locale; see `ImportQueue.dualPassRule`.
        public var dualPassPartnerLocaleIdentifier: @MainActor @Sendable () -> String?

        public init(
            analyzerFormat: @Sendable @escaping (String) async -> AVAudioFormat?,
            transcribe: @Sendable @escaping (
                String,
                AsyncStream<AnalyzerInput>,
                @escaping @Sendable (TranscriptionUpdate) -> Void
            ) async throws -> TranscriptionOutcome,
            cancelActive: (@Sendable () async -> Void)? = nil,
            dualPass: (
                @Sendable (URL, String, DualPassImporter.Reporting) async throws -> DualPassJob?
            )? = nil,
            dictationLocaleIdentifier: @MainActor @Sendable @escaping () -> String,
            supportedLocaleIdentifiers: @Sendable @escaping () async -> [String] = {
                await DictationTranscriber.supportedLocales.map(\.identifier)
            },
            dualPassPartnerLocaleIdentifier: @MainActor @Sendable @escaping () -> String? = { nil }
        ) {
            self.analyzerFormat = analyzerFormat
            self.transcribe = transcribe
            self.cancelActive = cancelActive
            self.dualPass = dualPass
            self.dictationLocaleIdentifier = dictationLocaleIdentifier
            self.supportedLocaleIdentifiers = supportedLocaleIdentifiers
            self.dualPassPartnerLocaleIdentifier = dualPassPartnerLocaleIdentifier
        }

        /// The locale-blind shape, for a test that has no language to express.
        ///
        /// Kept as a real initialiser rather than deleted because a fake engine that returns one
        /// canned outcome genuinely does not care which language it was asked for, and making every
        /// such test thread an identifier through would be noise. Everything it builds inherits
        /// `Settings.Default.localeIdentifier`, which is `en-US`.
        public init(
            analyzerFormat: @Sendable @escaping () async -> AVAudioFormat?,
            transcribe: @Sendable @escaping (
                AsyncStream<AnalyzerInput>,
                @escaping @Sendable (TranscriptionUpdate) -> Void
            ) async throws -> TranscriptionOutcome,
            cancelActive: (@Sendable () async -> Void)? = nil,
            dualPass: (@Sendable (URL, DualPassImporter.Reporting) async throws -> DualPassJob?)? = nil
        ) {
            self.analyzerFormat = { _ in await analyzerFormat() }
            self.transcribe = { _, stream, onUpdate in try await transcribe(stream, onUpdate) }
            self.cancelActive = cancelActive
            // Written out rather than `map`-ed: wrapping an `async throws` closure inside a closure
            // inside `Optional.map` defeats the type-checker outright — it reports "failed to produce
            // diagnostic for expression" rather than an error anyone can read.
            if let job = dualPass {
                let wrapped: @Sendable (URL, String, DualPassImporter.Reporting) async throws -> DualPassJob? = {
                    url, _, reporting in try await job(url, reporting)
                }
                self.dualPass = wrapped
            } else {
                self.dualPass = nil
            }
            self.dictationLocaleIdentifier = { Settings.Default.localeIdentifier }
            self.supportedLocaleIdentifiers = { [Settings.Default.localeIdentifier] }
            self.dualPassPartnerLocaleIdentifier = { nil }
        }
    }

    // MARK: - Observable state

    public private(set) var items: [Item] = []

    /// Every language a file may be imported in, hyphenated and sorted by display name.
    ///
    /// Empty until `loadSupportedLocales()` has run — the framework's answer is an `await` and the
    /// picker has to render before it arrives. A surface must therefore fall back to the item's own
    /// locale rather than assuming this list contains it.
    public private(set) var supportedLocaleIdentifiers: [String] = []

    /// The item currently being transcribed, if any.
    public private(set) var runningItemID: Item.ID?

    /// Which half of the work the running item is in. `nil` when nothing is running.
    public private(set) var runningPhase: Phase?

    /// Committed text of the running item, so the UI can show the transcript filling in. Volatile
    /// text is excluded: RECON §4 measured it as materially worse and frequently wrong mid-word.
    public private(set) var runningText: String = ""

    /// Overall progress across the whole batch, weighted by each file's duration.
    ///
    /// A running item counts as **half** done rather than as its read fraction. Read progress
    /// saturates within milliseconds (see `Phase`), so crediting it in full made a five-file queue
    /// report 100% with four files still to go — worse than no number at all. Half is honest: the
    /// file is somewhere in the middle of its transcription, and the number only moves when a file
    /// actually finishes.
    public var overallProgress: Double {
        let counted = items.filter { $0.state != .cancelled }
        guard !counted.isEmpty else { return 0 }
        let weights = counted.map { max(1, $0.info?.duration ?? 1) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        var accumulated = 0.0
        for (item, weight) in zip(counted, weights) {
            switch item.state {
            case .done, .failed: accumulated += weight
            case .running: accumulated += weight * 0.5
            case .queued, .cancelled: break
            }
        }
        return accumulated / total
    }

    public var isBusy: Bool { runningItemID != nil }

    /// Files still to do, including the one in flight.
    public var pendingCount: Int { items.count { !$0.state.isTerminal } }

    /// Called on the main actor for each finished file. Return the id of the history entry it
    /// became, so the row can link to it. Wire this to `Corrector` + `HistoryStore`.
    public var onFinish: ((Result) -> UUID?)?

    // MARK: - Private state

    private let environment: Environment
    /// The drain loop. One at a time, which is what makes the queue serial.
    private var worker: Task<Void, Never>?
    /// The importer for the running item, so `cancel` can reach its `AVAssetReader`.
    private var runningImporter: AudioFileImporter?
    /// Ids the user cancelled. Checked after `transcribe` returns, because cancelling the importer
    /// merely ends the audio stream — the engine then finalizes normally and hands back the partial
    /// text, which for an explicit cancel must be thrown away rather than saved.
    private var cancelledIDs: Set<Item.ID> = []
    /// The dual-pass job in flight, so `cancel` can stop it. A dual pass has no importer of its own
    /// to reach into — it owns one privately — so cancelling the *task* is the only lever, and
    /// `DualPassImporter.run` checks for cancellation between sections.
    private var runningDualTask: Task<DualPassJob?, Error>?

    /// Ticks the running item's estimated progress. Cancelled when the item finishes.
    private var ticker: Task<Void, Never>?
    /// When the running item started, for the elapsed-time estimate.
    private var runningStartedAt: ContinuousClock.Instant?
    /// Audio duration of the running item, once known.
    private var runningDuration: TimeInterval = 0

    /// Transcription speed as a multiple of realtime, learned as files complete.
    ///
    /// Seeded from measurement on this machine — `DictationTranscriber` transcribed a 377 s file in
    /// 25.5 s end to end, i.e. 14.8x, and six shorter files landed between 9x and 18x — and then
    /// updated by an exponential moving average so a slower machine, a thermally-throttled one, or
    /// a much longer file converges within one or two items.
    private var realtimeFactor: Double = 15
    /// Weight given to the newest measurement. Low enough that one anomalous short file (where
    /// fixed analyzer setup dominates) does not swing the estimate.
    private static let factorSmoothing = 0.3

    /// What `ItemState.running(progress:)` actually measures, for anyone wiring up a progress bar.
    ///
    /// It is an **estimate**: elapsed wall time against `duration / realtimeFactor`, capped at 0.99
    /// so it never claims completion it cannot verify. It is not a measurement, because there is no
    /// way to measure it from here — the importer's own read progress is real but useless as a bar
    /// (decoding runs at 570–4300x realtime and saturates within milliseconds, see `Phase`), and
    /// `SpeechEngine` exposes no signal for how far the analyzer has got. The estimate is monotonic
    /// within an item and self-corrects across items. `runningText` is the honest liveness signal;
    /// show both.
    public static let progressNote = """
        Estimated from elapsed time and a learned realtime factor, capped at 99%. \
        The transcript text is the real progress indicator.
        """

    /// `SpeechEngine` allows one utterance at a time. If the user is mid-dictation when a file
    /// lands, `transcribe` throws `.sessionAlreadyRunning`; rather than fail the file, wait and
    /// retry for up to this long.
    private static let engineBusyRetry = Duration.milliseconds(250)
    private static let engineBusyAttempts = 40  // 10 s

    public init(environment: Environment) {
        self.environment = environment
    }

    // MARK: - Enqueueing

    /// Add files to the back of the queue and start work if nothing is running.
    ///
    /// URLs already present in the same language and not yet finished are ignored, so dropping the
    /// same file twice while it is still queued does not transcribe it twice. Re-dropping a
    /// *finished* file does re-run it, which is what someone retrying a failure expects.
    ///
    /// - Parameters:
    ///   - localeIdentifier: the language every file in this batch is transcribed in, or `nil` to
    ///     inherit the dictation language **at this moment** and freeze it onto each row. One locale
    ///     for the batch and not one for the queue: dropping five files must not force one language
    ///     on all of them for ever, so each row carries its own copy and `setLocale` moves them
    ///     one at a time.
    @discardableResult
    public func enqueue(_ urls: [URL], localeIdentifier: String? = nil) -> [Item.ID] {
        let locale = normalised(localeIdentifier ?? environment.dictationLocaleIdentifier())
        let wasChosen = localeIdentifier != nil
        // Keyed on (url, language), not on url alone. Two rows for the same file in two languages is
        // a legitimate thing to ask for — it is the whole comparison this feature exists to make —
        // while two rows for the same file in the *same* language is the accident the dedup is for.
        // Seeded from the rows already in flight and then *grown as we go*, so a batch that carries
        // the same file twice enqueues it once; checking only the pre-existing rows would let
        // `enqueue([url, url])` through, which is reachable from a drag whose provider registered a
        // file under two type identifiers.
        var seen = Set(
            items.filter { !$0.state.isTerminal }
                .map { LocalisedFile(url: $0.url, localeKey: Settings.localeKey($0.localeIdentifier)) }
        )
        var added: [Item.ID] = []
        for url in urls
        where seen.insert(LocalisedFile(url: url, localeKey: Settings.localeKey(locale))).inserted {
            items.append(Item(url: url, localeIdentifier: locale, localeWasChosen: wasChosen))
            added.append(items[items.count - 1].id)
        }
        if !added.isEmpty {
            Log.data.info("""
                import queue: enqueued \(added.count, privacy: .public) file(s) as \
                \(locale, privacy: .public)\(wasChosen ? "" : " (inherited)", privacy: .public)
                """)
            startWorkerIfNeeded()
        }
        return added
    }

    @discardableResult
    public func enqueue(_ url: URL, localeIdentifier: String? = nil) -> Item.ID? {
        enqueue([url], localeIdentifier: localeIdentifier).first
    }

    /// One file in one language, for the dedup key.
    private struct LocalisedFile: Hashable {
        let url: URL
        let localeKey: String
    }

    // MARK: - Per-item language

    /// Change the language of a row that has not started yet.
    ///
    /// Refused once the item is running or terminal, and that is not a limitation to work around:
    /// the analyzer is built from exactly one `Locale` and is never reused (RECON §3), so there is
    /// no such thing as changing the language of a transcription in flight. For a finished row the
    /// answer is `rerun`.
    ///
    /// - Returns: true when the row changed.
    @discardableResult
    public func setLocale(_ identifier: String, for id: Item.ID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].localeIsEditable
        else { return false }
        let locale = normalised(identifier)
        guard Settings.localeKey(locale) != Settings.localeKey(items[index].localeIdentifier) else {
            // Still record the intent: a user who explicitly picks the language that was already
            // inherited has *checked* it, and the row should stop flagging itself as a default.
            items[index].localeWasChosen = true
            return false
        }
        Log.data.info("""
            import queue: \(self.items[index].filename, privacy: .private(mask: .hash)) \
            \(self.items[index].localeIdentifier, privacy: .public) -> \(locale, privacy: .public)
            """)
        items[index].localeIdentifier = locale
        items[index].localeWasChosen = true
        return true
    }

    /// Re-run a finished row in another language, as a **new row**.
    ///
    /// The original row and its history entry are left exactly where they are. That is deliberate and
    /// it is the point of the feature: the reason to re-run is that the first transcript looked
    /// plausible and wrong — RECON amendment 45's "Kanaya Sushma Manga Cheil Danka" — and the user
    /// cannot tell the second one is better without the first one still on screen to compare it
    /// against. Overwriting would destroy the evidence that motivated the click. `onFinish` is called
    /// again, so a second `Transcript` is appended to history rather than the first being edited.
    ///
    /// The file is re-read from disk and re-decoded. Nothing is cached between runs, and that is the
    /// right trade rather than a shortcut: decoding measured 570–4300x realtime (a 377 s m4a fully
    /// read in 90 ms) against transcription's 15–66x, so the decode is ~2 % of the wall clock, while
    /// caching the decoded PCM for a 70-minute file would hold 134 MB of Int16 at 16 kHz for as long
    /// as the row stayed on screen. The URL itself is already retained by the row — the app is not
    /// sandboxed, so there is no security-scoped bookmark to keep alive and re-running costs nothing
    /// but the re-read. A file the user has since moved or deleted fails the new row with the
    /// reader's own message, which is the honest outcome.
    ///
    /// - Returns: the new row's id, or `nil` when `id` is not a finished row.
    @discardableResult
    public func rerun(_ id: Item.ID, localeIdentifier: String) -> Item.ID? {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state.isTerminal
        else { return nil }
        let source = items[index]
        let locale = normalised(localeIdentifier)
        let item = Item(
            url: source.url,
            localeIdentifier: locale,
            localeWasChosen: true,
            // The row this one exists to be compared against. Chained through, so re-running a
            // re-run still points back at the original rather than at the middle of a chain.
            rerunOf: source.rerunOf ?? source.id
        )
        // Straight after its source rather than at the back of the queue, so the pair the user is
        // comparing stays adjacent even in a tray of twenty rows.
        items.insert(item, at: index + 1)
        Log.data.info("""
            import queue: re-running \(source.filename, privacy: .private(mask: .hash)) as \
            \(locale, privacy: .public) (was \(source.localeIdentifier, privacy: .public))
            """)
        startWorkerIfNeeded()
        return item.id
    }

    /// The language pair the surface must explain for one row, when dual pass is on.
    ///
    /// See `dualPassRule`. `nil` means one pass in the row's own language, which is the common case.
    public func secondPassLocaleIdentifier(for id: Item.ID) -> String? {
        guard let item = items.first(where: { $0.id == id }),
              let partner = environment.dualPassPartnerLocaleIdentifier() else { return nil }
        guard Settings.localeKey(partner) != Settings.localeKey(item.localeIdentifier) else { return nil }
        return partner
    }

    /// What a per-item locale means when dual pass is switched on, in one sentence for the UI.
    ///
    /// **The rule: the item's locale replaces the first pass's language; the second pass stays the
    /// configured second dictation language; if the two would be the same, dual pass is skipped and
    /// the row runs a single pass in its own language.**
    ///
    /// The alternative — "the per-item locale pins the file to one language and turns dual pass off"
    /// — was rejected because it makes the two features fight over the same row: a user who has dual
    /// pass on for a bilingual meeting and then corrects one file's language would silently lose the
    /// comparison on exactly the file they were paying attention to. Substituting the *first* pass
    /// keeps both features doing what they say: the per-item choice decides which languages are
    /// tried, and dual pass decides that more than one is.
    public static let dualPassRule = """
        This file's language is the first of the two tried. The second stays your second dictation \
        language, and the transcript keeps whichever section-by-section result reads more like the \
        language that produced it.
        """

    /// The identifier as Edict writes it: hyphenated, trimmed.
    ///
    /// `DictationTranscriber.supportedLocales` reports **underscored** identifiers (`id_ID`) while
    /// Settings and history store hyphenated ones (`id-ID`), and `Transcript.localeIdentifier` is
    /// what the history pane shows. Normalising on the way in keeps one spelling in the queue, in
    /// history and in the picker; `Settings.localeKey` is still what any *comparison* goes through,
    /// because RECON §6 records `AssetInventory.release` matching on the raw string.
    private func normalised(_ identifier: String) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Settings.Default.localeIdentifier }
        return trimmed.replacingOccurrences(of: "_", with: "-")
    }

    /// Load the language list the picker offers. Cheap, and safe to call more than once.
    public func loadSupportedLocales() async {
        let identifiers = await environment.supportedLocaleIdentifiers()
        var seen = Set<String>()
        supportedLocaleIdentifiers = identifiers
            .map { $0.replacingOccurrences(of: "_", with: "-") }
            .filter { seen.insert(Settings.localeKey($0)).inserted }
            .sorted { Self.localeDisplayName($0) < Self.localeDisplayName($1) }
        Log.data.debug("import queue: \(self.supportedLocaleIdentifiers.count, privacy: .public) import locales")
    }

    /// A language name a user will recognise, for a picker row and for a queue row's badge.
    ///
    /// Named in English rather than in the user's own locale, matching `SpeechEngine`'s own
    /// `languageName` — the rest of Edict's interface is English, and a half-translated picker reads
    /// as a bug. Falls back to the identifier, which is still more use than an empty label.
    public nonisolated static func localeDisplayName(_ identifier: String) -> String {
        let hyphenated = identifier.replacingOccurrences(of: "_", with: "-")
        return Locale(identifier: "en-US").localizedString(forIdentifier: hyphenated) ?? hyphenated
    }

    // MARK: - Cancellation

    /// Cancel one item, whether it is queued or running.
    public func cancel(_ id: Item.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].state.isTerminal else { return }
        cancelledIDs.insert(id)
        if id == runningItemID {
            // Two steps, and both are needed. Closing the audio stream stops the *reader*; aborting
            // the engine stops the *analyzer*, which by this point already holds every remaining
            // chunk of the file in its unbounded input queue. Without the second step a cancelled
            // 377 s file still took ~25 s to come back, because `finishAndCommit` dutifully
            // finalized audio nobody wanted.
            let importer = runningImporter
            let abort = environment.cancelActive
            runningDualTask?.cancel()
            Task { [weak self] in
                await importer?.cancel()
                // Re-check ownership before touching the shared engine. The item's `transcribe`
                // call may have returned in the moments since, and a live dictation may already
                // have taken the engine's single session — aborting *that* would be a real bug.
                guard self?.runningItemID == id else { return }
                await abort?()
            }
        } else {
            items[index].state = .cancelled
        }
    }

    /// Cancel everything not already finished.
    public func cancelAll() {
        for item in items where !item.state.isTerminal {
            cancel(item.id)
        }
    }

    /// Drop finished rows. Nothing in flight is touched.
    public func clearFinished() {
        items.removeAll { $0.state.isTerminal }
    }

    /// Re-run a row that has stopped — failed, cancelled, or finished.
    ///
    /// Replaces the row rather than adding a second one for the same file, so RETRY on a failure
    /// does not leave the tray holding two rows the user has to tell apart.
    public func retry(_ id: Item.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state.isTerminal else { return }
        let previous = items[index]
        items.remove(at: index)
        // Dropped so the fresh run is not cancelled the instant it starts by the old id's flag.
        cancelledIDs.remove(id)
        // The row's own language, never the dictation language of the moment. RETRY means "try that
        // again", and silently changing the language on a retry because the picker moved in between
        // would be the original bug wearing a different hat.
        let added = enqueue([previous.url], localeIdentifier: previous.localeIdentifier)
        // `enqueue` marks anything it was handed a locale for as chosen; a retry has to keep the
        // *original* provenance, or a row that inherited its language would start claiming the user
        // picked it and stop being flagged as worth checking.
        if let newID = added.first, let index = items.firstIndex(where: { $0.id == newID }) {
            items[index].localeWasChosen = previous.localeWasChosen
            items[index].rerunOf = previous.rerunOf
        }
    }

    public func remove(_ id: Item.ID) {
        cancel(id)
        items.removeAll { $0.id == id && $0.state.isTerminal }
    }

    // MARK: - The drain loop

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
            self?.worker = nil
        }
    }

    private func drain() async {
        // `firstIndex` is re-evaluated every pass rather than iterating a snapshot: the user can
        // cancel, remove or enqueue between files, so any index held across an await is stale.
        while let index = items.firstIndex(where: { $0.state == .queued }) {
            let item = items[index]
            if cancelledIDs.contains(item.id) {
                items[index].state = .cancelled
                continue
            }
            await run(item.id)
        }
        ticker?.cancel()
        ticker = nil
        runningItemID = nil
        runningImporter = nil
        runningDualTask = nil
        runningPhase = nil
        runningStartedAt = nil
        runningText = ""
    }

    /// One file, start to finish. Never throws: a failure marks the row and the loop moves on,
    /// because a queue that stops on the first bad file is worse than useless for a batch drop.
    private func run(_ id: Item.ID) async {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let url = items[index].url
        let filename = items[index].filename
        // Read once, from the item, and carried through both routes. Never re-read from `Settings`
        // and never re-read from `items` after an await, so a picker change mid-transcription cannot
        // make the row's badge disagree with the model that actually ran.
        let locale = items[index].localeIdentifier

        runningItemID = id
        runningText = ""
        runningPhase = .reading(0)
        runningStartedAt = ContinuousClock.now
        runningDuration = items[index].info?.duration ?? 0
        items[index].state = .running(progress: 0)

        let began = ContinuousClock.now

        // Registered before either route runs, so an early `return` out of the dual-pass branch
        // still tears the running-item state down.
        defer {
            ticker?.cancel()
            ticker = nil
            runningImporter = nil
            runningDualTask = nil
            runningItemID = nil
            runningPhase = nil
            runningStartedAt = nil
            runningDuration = 0
            runningText = ""
        }

        // Dual pass owns its own decode, so it has to be offered the file before the streaming
        // reader is built. It declines — returns nil — for a file it cannot serve, and the ordinary
        // single pass then runs as though the switch had been off.
        if let dualPass = environment.dualPass,
           await runDualPass(
               id, url: url, filename: filename, locale: locale, began: began, job: dualPass
           ) {
            return
        }

        // Only the single pass needs the elapsed-time estimate: a dual pass reports measured
        // progress and a ticker fighting it would only make the bar less honest.
        startTicker(for: id)
        // The format is asked for *this item's* locale: the two modules are built per locale and
        // `availableCompatibleAudioFormats` is a property of the module, so a mixed batch converts
        // each file for the model that is going to read it. `nil` falls back to 16 kHz mono Int16
        // inside the importer, and the real error — a language whose model is not on disk — then
        // surfaces from `transcribe` with a sentence the user can act on.
        let importer = AudioFileImporter(url: url, analyzerFormat: await environment.analyzerFormat(locale))
        runningImporter = importer

        do {
            let info = try await importer.open()
            update(id) { $0.info = info }
            runningDuration = info.duration

            let stream = try await importer.start(onProgress: { [weak self] fraction in
                // Fires off the main actor from the importer's read loop, ~10 times a second.
                Task { @MainActor [weak self] in self?.setProgress(id, fraction) }
            })

            let outcome = try await transcribeWithRetry(stream: stream, id: id, locale: locale)

            let readFailure = await importer.readFailure
            let stats = await importer.statistics

            if cancelledIDs.contains(id) {
                finish(id, state: .cancelled, stats: stats)
                Log.data.info("import cancelled: \(filename, privacy: .private(mask: .hash))")
                return
            }
            if case .cancelled = readFailure {
                finish(id, state: .cancelled, stats: stats)
                return
            }

            // Checked before anything reads `outcome.text`, and checked here rather than left to the
            // empty-text branch below, because the failure this catches does not throw and does not
            // set `readFailure`: `AVAudioConverter` refuses every buffer, no chunk is ever handed
            // over, so the analyzer is fed nothing and returns nothing. That used to reach the
            // surface as "No speech was found in this file."
            let verdict = Self.readVerdict(for: stats)
            if case .undecodable(let reason) = verdict {
                finish(id, state: .failed(reason: reason), stats: stats)
                Log.data.error("import undecodable: \(filename, privacy: .private(mask: .hash)): \(reason, privacy: .public)")
                return
            }

            // A read that stopped early, or one that lost buffers on the way, still produced real
            // text. Saving it with a warning beats throwing away nine minutes of a ten-minute
            // transcript — and beats keeping it silently, which is the same as claiming it is whole.
            let warning = Self.warning(readFailure: readFailure, verdict: verdict)
            let elapsed = ContinuousClock.now - began
            let segments = Self.segments(from: outcome.words)
            // Taken before the importer is released, and released straight after: the probe is the
            // decoded audio, so it is the one thing in this method with a real memory cost.
            let probe = await importer.speechProbe
            await importer.releaseProbe()
            let result = Result(
                itemID: id,
                url: url,
                info: info,
                localeIdentifier: locale,
                outcome: outcome,
                segments: segments,
                stats: stats,
                incompleteReason: warning,
                wallSeconds: Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18,
                quality: await Self.assess(
                    text: outcome.text,
                    audioDuration: info.duration > 0 ? info.duration : outcome.audioDuration,
                    probe: probe,
                    segments: segments
                ),
                localeIdentifiers: [],
                sections: []
            )

            if outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let readFailure {
                // Nothing usable *and* a read failure: report the failure rather than saving an
                // empty transcript the user cannot act on.
                finish(id, state: .failed(reason: readFailure.errorDescription ?? "the file could not be read"), stats: stats)
                return
            }

            if result.realtimeFactor > 0, info.duration > 1 {
                realtimeFactor = realtimeFactor * (1 - Self.factorSmoothing)
                    + result.realtimeFactor * Self.factorSmoothing
            }
            let transcriptID = onFinish?(result)
            update(id) {
                $0.transcriptID = transcriptID
                $0.warning = warning
                $0.stats = stats
                $0.state = .done
            }
            Log.data.info(
                """
                import done: \(filename, privacy: .private(mask: .hash)) [\(locale, privacy: .public)] \
                \(String(format: "%.1f", info.duration), privacy: .public)s audio in \
                \(String(format: "%.1f", result.wallSeconds), privacy: .public)s \
                (\(String(format: "%.1f", result.realtimeFactor), privacy: .public)x) \
                words=\(outcome.words.count, privacy: .public) \
                segments=\(result.segments.count, privacy: .public)\
                \(warning == nil ? "" : " INCOMPLETE", privacy: .public)
                """
            )

        } catch is CancellationError {
            finish(id, state: .cancelled, stats: await importer.statistics)

        } catch {
            await importer.cancel()
            let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            finish(id, state: .failed(reason: reason), stats: await importer.statistics)
            Log.data.error("import failed: \(filename, privacy: .private(mask: .hash)): \(reason, privacy: .public)")
        }
    }

    // MARK: - The dual-pass route

    /// Offer one file to the dual-pass job.
    ///
    /// - Returns: true when the item reached a terminal state here — done, failed or cancelled — and
    ///   false when the file must go the ordinary single-pass route instead. The second answer is not
    ///   a failure: the injected closure returns `nil` for a file it cannot serve (no second language
    ///   configured, a model still downloading, a format mismatch between the two modules), and the
    ///   user gets a transcript from one model rather than an error about two.
    private func runDualPass(
        _ id: Item.ID,
        url: URL,
        filename: String,
        locale: String,
        began: ContinuousClock.Instant,
        job: @Sendable @escaping (URL, String, DualPassImporter.Reporting) async throws -> DualPassJob?
    ) async -> Bool {
        let reporting = DualPassImporter.Reporting(
            onProgress: { [weak self] fraction in
                Task { @MainActor [weak self] in self?.setDualProgress(id, fraction) }
            },
            onText: { [weak self] text in
                Task { @MainActor [weak self] in
                    guard self?.runningItemID == id else { return }
                    self?.runningText = text
                }
            },
            onSections: { [weak self] done, total in
                Task { @MainActor [weak self] in
                    guard self?.runningItemID == id else { return }
                    self?.runningPhase = .transcribingSections(done: done, total: total)
                }
            }
        )

        // Wrapped in a `Task` purely so `cancel(_:)` has something to cancel: the dual pass owns its
        // decode privately, so there is no importer for the queue to reach into, and
        // `DualPassImporter.run` checks for cancellation between sections.
        // The item's locale goes in as the *first* pass's language — see `dualPassRule`. The closure
        // returns nil when it cannot serve the pair (dual pass off, no second language, or the second
        // language is the same as this item's), and the single pass then runs in the item's language.
        let task = Task { try await job(url, locale, reporting) }
        runningDualTask = task

        let outcome: DualPassJob?
        do {
            outcome = try await task.value
        } catch is CancellationError {
            finish(id, state: .cancelled, stats: nil)
            return true
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            // A dual pass that failed outright is not a reason to refuse the file: fall through and
            // let one model have a go. The user asked for a transcript, not for a language contest.
            Log.data.error("""
                dual pass failed, falling back to a single pass: \
                \(filename, privacy: .private(mask: .hash)): \(reason, privacy: .public)
                """)
            runningDualTask = nil
            return false
        }
        runningDualTask = nil

        guard let outcome else { return false }
        if cancelledIDs.contains(id) {
            finish(id, state: .cancelled, stats: outcome.outcome.stats)
            Log.data.info("import cancelled: \(filename, privacy: .private(mask: .hash))")
            return true
        }

        update(id) { $0.info = outcome.info }
        let info = outcome.info
        let dual = outcome.outcome

        // The dual pass owns its own decode — `AudioFileImporter.decodeAll`, wired in at
        // DictationController.runDualPass — so it accumulates the same counters and can fail the same
        // silent way: every buffer refused, no samples, no sections, no passes, empty text, nothing
        // thrown. Same verdict and the same sentence, so the two routes cannot come to disagree
        // about what a file the converter refused looks like.
        let verdict = Self.readVerdict(for: dual.stats)
        if case .undecodable(let reason) = verdict {
            finish(id, state: .failed(reason: reason), stats: dual.stats)
            Log.data.error("dual-pass undecodable: \(filename, privacy: .private(mask: .hash)): \(reason, privacy: .public)")
            return true
        }

        // Gated on `failedPasses`, not on `passesRun == 0` alone, and the difference is the whole
        // point: a file of pure silence also runs no passes, because `DualPassImporter` finds no
        // sections to run them on — and for that file "no speech was found" is the true answer, not
        // a misdiagnosis. Passes that were attempted and *threw* are the failure worth reporting.
        if dual.failedPasses > 0, dual.passesRun == 0 {
            let reason = "None of the \(dual.failedPasses) transcription "
                + (dual.failedPasses == 1 ? "pass" : "passes")
                + " could run, so there is no transcript for this file. Try it again."
            finish(id, state: .failed(reason: reason), stats: dual.stats)
            Log.data.error("""
                dual pass produced nothing: \(filename, privacy: .private(mask: .hash)): \
                \(dual.failedPasses, privacy: .public) passes failed
                """)
            return true
        }

        // Every sentence that is true about this outcome, in the order the user needs them: what
        // stopped the decode, how much audio is missing from it, and how many passes never ran.
        // A failed pass is a *section* absent from the transcript, which no other signal reveals —
        // the text still reads fluently, it is simply short.
        var warning = Self.warning(readFailure: dual.failure, verdict: verdict)
        if dual.failedPasses > 0 {
            let sentence = "\(dual.failedPasses) of \(dual.passesAttempted) transcription passes "
                + "could not run; parts of this file are missing from the transcript."
            warning = [warning, sentence].compactMap { $0 }.joined(separator: " ")
        }

        if dual.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let failure = dual.failure {
            finish(
                id,
                state: .failed(reason: failure.errorDescription ?? "the file could not be read"),
                stats: dual.stats
            )
            return true
        }

        let elapsed = ContinuousClock.now - began
        let result = Result(
            itemID: id,
            url: url,
            info: info,
            // The row's language, which for a dual pass is the first of the two tried. Which one
            // actually *won* is `localeIdentifiers`, below, and that is the one history attributes
            // the transcript to.
            localeIdentifier: locale,
            // A dual pass has no single `TranscriptionOutcome` — it has one per section per language —
            // so this is the stitched equivalent, assembled so every existing reader of `Result`
            // keeps working unchanged.
            outcome: TranscriptionOutcome(
                text: dual.text,
                confidence: dual.meanConfidence,
                // The whole job, as for a single-pass import: for a file this is the number that
                // makes the realtime factor legible, not an end-of-speech latency.
                latency: outcome.wallSeconds,
                audioDuration: info.duration,
                words: dual.segments.map {
                    WordConfidence(
                        text: $0.text,
                        confidence: $0.confidence,
                        startSeconds: $0.start,
                        endSeconds: $0.end
                    )
                },
                lowConfidenceWords: dual.lowConfidenceWords
            ),
            segments: dual.segments,
            stats: dual.stats,
            incompleteReason: warning,
            wallSeconds: Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18,
            quality: Self.assess(
                text: dual.text,
                audioDuration: info.duration,
                speechDuration: dual.speechDuration,
                segments: dual.segments
            ),
            localeIdentifiers: dual.localeIdentifiers,
            sections: dual.sections
        )

        let transcriptID = onFinish?(result)
        update(id) {
            $0.transcriptID = transcriptID
            $0.warning = warning
            $0.stats = dual.stats
            $0.state = .done
        }
        Log.data.info(
            """
            dual-pass import done: \(filename, privacy: .private(mask: .hash)) \
            \(String(format: "%.1f", info.duration), privacy: .public)s audio in \
            \(String(format: "%.1f", result.wallSeconds), privacy: .public)s \
            (\(String(format: "%.1f", result.realtimeFactor), privacy: .public)x) \
            sections=\(dual.sections.count, privacy: .public) \
            passes=\(dual.passesRun, privacy: .public) \
            failedPasses=\(dual.failedPasses, privacy: .public) \
            locales=\(dual.localeIdentifiers.joined(separator: "+"), privacy: .public) \
            quality=\(result.quality.verdict.rawValue, privacy: .public)\
            \(warning == nil ? "" : " INCOMPLETE", privacy: .public)
            """
        )
        return true
    }

    /// Measured dual-pass progress, straight onto the bar. Monotonic for the same reason `tick` is.
    private func setDualProgress(_ id: Item.ID, _ fraction: Double) {
        guard id == runningItemID else { return }
        let clamped = min(0.99, max(0, fraction))
        update(id) { item in
            guard case .running(let current) = item.state else { return }
            if clamped > current { item.state = .running(progress: clamped) }
        }
    }

    // MARK: - What the read counters mean for the row

    /// What `ImportStats` says about a read that did **not** throw.
    ///
    /// This exists because the interesting import failures are the quiet ones. `AudioFileImporter`
    /// counts every buffer `AVAudioConverter` refused (`conversionFailures`) and every frame the
    /// consumer never took (`dropped`). Dropped frames at least also set a `readFailure`, so the row
    /// said *something*; `conversionFailures` was written, logged and read by nothing in production,
    /// and so a file whose every buffer was refused produced no chunks, no text, no thrown error and
    /// a `.done` row — which the surface rendered as "No speech was found in this file.", a confident
    /// diagnosis of silence over a recording full of speech.
    ///
    /// `ImportStats.isSuspect` asks the same question as a Bool and had no caller either, while the
    /// live-capture path uses its namesake in `AudioCapture`. This answers it with the sentence the
    /// row has to print, and separates "some audio is missing" from "no audio arrived at all",
    /// because those two need different terminal states.
    enum ReadVerdict: Equatable, Sendable {
        /// Audio arrived and nothing was refused or dropped. Say nothing.
        case clean
        /// A real transcript with a hole in it. Keep the text, print the sentence.
        case incomplete(String)
        /// Nothing was ever handed to the analyzer, so there is no transcript to keep.
        case undecodable(String)
    }

    /// Read the counters, and be specific about what is missing.
    ///
    /// Deliberately a pure function of the counters and nothing else: it is the one part of the
    /// terminal decision that can be tested without a file, a reader or a model, and both the
    /// single-pass and the dual-pass route go through it so the two cannot drift apart.
    static func readVerdict(for stats: ImportStats) -> ReadVerdict {
        guard stats.isSuspect else { return .clean }

        // Nothing decoded *and* buffers refused: the converter turned the whole file away. Distinct
        // from an empty transcript with clean counters, which really is a file with no speech in it.
        if stats.chunks == 0, stats.conversionFailures > 0 {
            return .undecodable(
                "Edict could not decode this file's audio: all "
                    + "\(stats.conversionFailures) audio "
                    + (stats.conversionFailures == 1 ? "buffer was" : "buffers were")
                    + " refused. It may use a channel layout or codec this Mac cannot convert."
            )
        }

        var parts: [String] = []
        if stats.conversionFailures > 0 {
            // Named as a share of what was read, so the number means something: "2 of 431" is a
            // glitch, "400 of 431" is a transcript not worth trusting, and only the user can tell
            // which of those matters for this recording.
            parts.append(
                "\(stats.conversionFailures) of \(stats.chunks + stats.conversionFailures) "
                    + "audio buffers could not be decoded; parts of this file are missing from the "
                    + "transcript."
            )
        }
        if stats.dropped > 0 {
            // The tail, specifically, and that is structural rather than a guess: the reader's
            // channel is FIFO with back-pressure, so what is lost when the consumer goes away is
            // always the end (see `ImportStats.dropped`) — the opposite of the live path's failure
            // mode, where `.bufferingNewest` discards the oldest element (RECON amendment 20).
            let amount = stats.sampleRate > 0
                ? String(format: "%.1f seconds", Double(stats.dropped) / stats.sampleRate)
                : "\(stats.dropped) frames"
            parts.append(
                "The last \(amount) of audio never reached the transcriber, so the end of this "
                    + "file is missing from the transcript."
            )
        }
        // Unreachable while `isSuspect` is exactly these two counters, but a future third counter
        // must not silently produce an empty warning: an empty sentence in the row would read as a
        // clean import.
        guard !parts.isEmpty else { return .clean }
        return .incomplete(parts.joined(separator: " "))
    }

    /// The row's warning: every sentence that is true about this read, or `nil` for a clean one.
    ///
    /// Both sentences can apply at once and they say different things — the read failure names the
    /// stage that stopped, the verdict names how much is gone — so neither is allowed to displace
    /// the other.
    static func warning(readFailure: AudioImportError?, verdict: ReadVerdict) -> String? {
        var parts: [String] = []
        if let sentence = readFailure?.errorDescription { parts.append(sentence) }
        if case .incomplete(let sentence) = verdict { parts.append(sentence) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: - Recognition quality

    /// Words in a transcript, counted the same way `Transcript.wordCount` does so the number the
    /// warning quotes and the number the history row shows cannot disagree.
    nonisolated static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Assess a finished import against both denominators, and pick between them on evidence.
    ///
    /// `RecognitionQuality` takes one denominator and both candidates are wrong in a different
    /// direction, which is why this is a decision and not a parameter:
    ///
    /// * **Wall clock** over-flags a recording that is mostly silence. A two-minute memo with ninety
    ///   seconds of thinking-pauses reads as 40 words a minute and gets warned about, which is the
    ///   false alarm that teaches users to ignore the real ones.
    /// * **Detected speech** over-*forgives* far-field audio, and does so systematically: the same
    ///   quiet distant voices that the recogniser cannot read also sit near `SpeechSegmenter`'s
    ///   energy gate, so the denominator shrinks by roughly the amount the numerator did.
    ///
    /// Measured, on the 300-second slice of the real 70-minute meeting, transcribed per section:
    ///
    ///     basis            wpm    verdict     mean word confidence   share of words under 0.30
    ///     detected speech  112    good                        0.288                       57 %
    ///     wall clock        49    sparse                      0.288                       57 %
    ///
    /// against the two recordings that are genuinely fine:
    ///
    ///     clean bilingual, 17 s    158 wpm  good   confidence 0.941   0 % under 0.30
    ///     English script,  377 s   188 wpm  good   confidence 0.929   0 % under 0.30
    ///
    /// So confidence is what separates the two failures the rate cannot. A recording is let off only
    /// when detected speech explains the shortfall **and** the words that did come back are words the
    /// engine was sure of; otherwise the wall-clock verdict stands. `Threshold.lowConfidence` is the
    /// gate, not a number invented here — RECON measured a misheard "Visa" at 0.05 against 0.998 for
    /// a correct word.
    ///
    /// A `nil` confidence — which is every Indonesian transcript, since `DictationTranscriber` on
    /// `id_ID` reports none — is treated as passing. That follows `RecognitionQuality`'s own stance
    /// that no verdict may *require* this number, and it fails in the quiet direction: a
    /// hard-to-read Indonesian recording is judged on detected speech alone.
    public nonisolated static func assess(
        text: String,
        audioDuration: TimeInterval,
        speechDuration: TimeInterval?,
        segments: [TranscriptSegment]
    ) -> RecognitionQuality {
        let words = wordCount(text)
        let byWallClock = RecognitionQuality.assess(
            wordCount: words,
            audioDuration: audioDuration,
            speechDuration: nil,
            segments: segments
        )
        guard let speechDuration else { return byWallClock }
        let bySpeech = RecognitionQuality.assess(
            wordCount: words,
            audioDuration: audioDuration,
            speechDuration: speechDuration,
            segments: segments
        )
        let confident = (bySpeech.meanConfidence ?? 1) > RecognitionQuality.Threshold.lowConfidence
        return (bySpeech.verdict == .good && confident) ? bySpeech : byWallClock
    }

    /// The same assessment for the streaming single-pass route, which has to run `SpeechSegmenter`
    /// over its probe first.
    ///
    /// Off the main actor: cheap — 39 ms for the whole 70-minute meeting, so ~15 ms at the probe's
    /// 25-minute ceiling — but a main-actor hitch of even that size while a queue is drawing has no
    /// business being synchronous. A `nil` probe means the file was longer than the budget, and the
    /// wall-clock verdict then stands on its own.
    nonisolated static func assess(
        text: String,
        audioDuration: TimeInterval,
        probe: SpeechProbe?,
        segments: [TranscriptSegment]
    ) async -> RecognitionQuality {
        let speech: TimeInterval? = await {
            guard let probe else { return nil }
            return await Task.detached(priority: .utility) {
                probe.samples.withUnsafeBufferPointer {
                    SpeechSegmenter().speechDuration(inPCM: $0, sampleRate: probe.sampleRate)
                }
            }.value
        }()
        return assess(
            text: text,
            audioDuration: audioDuration,
            speechDuration: speech,
            segments: segments
        )
    }

    /// Run the stream through the engine, tolerating the engine being momentarily busy.
    ///
    /// `SpeechEngine` permits one utterance at a time (RECON §3: a module and analyzer are built
    /// per utterance and never reused), so a file landing while the user is holding the hotkey gets
    /// `.sessionAlreadyRunning`. Failing the file for that would be a bad experience for something
    /// that resolves itself in a second.
    private func transcribeWithRetry(
        stream: AsyncStream<AnalyzerInput>,
        id: Item.ID,
        locale: String
    ) async throws -> TranscriptionOutcome {
        let relay = TranscriptRelay { [weak self] committed in
            Task { @MainActor [weak self] in
                guard self?.runningItemID == id else { return }
                self?.runningText = committed
            }
        }
        var attempt = 0
        while true {
            do {
                return try await environment.transcribe(locale, stream, { update in
                    relay.publish(update.finalText)
                })
            } catch SpeechEngineError.sessionAlreadyRunning {
                attempt += 1
                guard attempt < Self.engineBusyAttempts, !cancelledIDs.contains(id) else { throw
                    SpeechEngineError.sessionAlreadyRunning
                }
                if attempt == 1 {
                    Log.data.info("import waiting: the engine is busy with a live dictation")
                }
                try await Task.sleep(for: Self.engineBusyRetry)
            }
        }
    }

    // MARK: - Item mutation

    private func update(_ id: Item.ID, _ mutate: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(&items[index])
    }

    /// The importer's read fraction drives the *phase label* only, never the bar — reading is over
    /// in milliseconds, so a bar fed from it would jump to 100% and sit there for the whole job.
    private func setProgress(_ id: Item.ID, _ fraction: Double) {
        guard id == runningItemID else { return }
        let clamped = min(1, max(0, fraction))
        runningPhase = clamped >= 1 ? .transcribing : .reading(clamped)
    }

    private func startTicker(for id: Item.ID) {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                self?.tick(id)
            }
        }
    }

    /// Advance the estimate. Monotonic by construction — `max` against the current value — so a
    /// mid-item change to `realtimeFactor` can never make a bar go backwards.
    private func tick(_ id: Item.ID) {
        guard id == runningItemID, let startedAt = runningStartedAt else { return }
        let elapsed = ContinuousClock.now - startedAt
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let expected = runningDuration > 0 ? runningDuration / max(1, realtimeFactor) : 0
        let estimate = expected > 0 ? min(0.99, seconds / expected) : 0
        update(id) { item in
            guard case .running(let current) = item.state else { return }
            let next = max(current, estimate)
            if next > current { item.state = .running(progress: next) }
        }
    }

    private func finish(_ id: Item.ID, state: ItemState, stats: ImportStats?) {
        update(id) {
            $0.state = state
            $0.stats = stats
        }
    }

    // MARK: - Segments

    /// Turn the engine's per-word attribute runs into timed segments.
    ///
    /// Only runs that actually carried an `audioTimeRange` can become segments — a segment without
    /// timing is useless for SRT/VTT and would break the export's cue packing. Sorted by start
    /// because RECON §4 warns final ranges are monotonic but not contiguous, and a revised final can
    /// arrive out of order.
    static func segments(from words: [WordConfidence]) -> [TranscriptSegment] {
        words
            .compactMap { word -> TranscriptSegment? in
                guard let start = word.startSeconds else { return nil }
                let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return TranscriptSegment(
                    start: max(0, start),
                    end: max(start, word.endSeconds ?? start),
                    text: text,
                    confidence: word.confidence
                )
            }
            .sorted { $0.start < $1.start }
    }
}

// MARK: - Locale availability

/// A file's chosen language cannot be transcribed right now.
///
/// Thrown rather than papered over, and that is the whole reason it exists. The tempting failure mode
/// is to notice a missing model and quietly use one that *is* installed — which does not produce an
/// error, it produces fluent nonsense: RECON amendment 45 measured the same Indonesian audio coming
/// back as "Then other workshop Karna Saka Ito Sanga Dunia interested in workshop to my DR info"
/// under `en-US`, 19 of 23 words low-confidence, against a word-perfect `id-ID` transcript of the
/// same clip. So an import either runs in the language it was given, or it fails saying so, and the
/// row shows that instead of 900 plausible words.
///
/// `reason` is already user-facing — it comes from `SpeechEngine.ImportPassResolution.unavailable`,
/// which distinguishes "Downloading the Indonesian speech model. Try this file again in a moment."
/// from "Indonesian is not one of the languages this Mac can transcribe."
public struct ImportLocaleUnavailable: LocalizedError, Sendable, Hashable {
    public let localeIdentifier: String
    public let reason: String

    public init(localeIdentifier: String, reason: String) {
        self.localeIdentifier = localeIdentifier
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}

// MARK: - Live text relay

/// Carries committed text from the analyzer's results task to the main actor.
///
/// The engine's `onUpdate` is `@Sendable` and fires off the main actor, so it cannot touch
/// `@Observable` state directly. Coalescing here rather than in the closure keeps the hop count
/// down: the engine emits volatile results continuously, but only a *change in committed text* is
/// worth a main-actor round trip.
private final class TranscriptRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ""
    // Named `sink`, not `publish`: a stored property and a method of the same name compile fine and
    // then `publish(committed)` resolves to the *method*, i.e. unbounded recursion.
    private let sink: @Sendable (String) -> Void

    init(_ sink: @Sendable @escaping (String) -> Void) {
        self.sink = sink
    }

    func publish(_ committed: String) {
        let changed: Bool = lock.withLock {
            guard committed != last else { return false }
            last = committed
            return true
        }
        if changed { sink(committed) }
    }
}
