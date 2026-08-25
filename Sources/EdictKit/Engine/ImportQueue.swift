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
    }

    /// One row of the queue.
    public struct Item: Identifiable, Sendable, Hashable {
        public let id: UUID
        public let url: URL
        /// Last path component. The full path is deliberately never shown — same rule as
        /// `TranscriptSource.imported(filename:)`.
        public let filename: String
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

        init(url: URL) {
            self.id = UUID()
            self.url = url
            self.filename = url.lastPathComponent
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
        public var outcome: TranscriptionOutcome
        /// Per-word timings, ready for SRT/VTT export. Derived from
        /// `TranscriptionOutcome.words`, which carry `audioTimeRange` because
        /// `SpeechEngine.build(module:locale:)` asks for that attribute explicitly.
        public var segments: [TranscriptSegment]
        public var stats: ImportStats
        /// Non-nil when the read stopped early. The text before that point is genuine.
        public var incompleteReason: String?
        /// Wall clock for the whole file: open, decode, transcribe, finalize.
        public var wallSeconds: Double

        /// End-to-end speed, e.g. 18.4 means an hour of audio in 3 minutes 15. This is the number
        /// worth quoting, not `ImportStats.realtimeFactor`, which only covers decoding.
        public var realtimeFactor: Double {
            wallSeconds > 0 ? info.duration / wallSeconds : 0
        }
    }

    // MARK: - Environment

    /// Everything the queue needs from the rest of the app. Injected rather than reached for, so
    /// the queue is testable with three closures and no frameworks running.
    public struct Environment: Sendable {
        /// `SpeechEngine.bestAudioFormat()`. Asked once per file, because the engine only knows the
        /// answer after `prepare(localeIdentifier:)` and the locale can change between files.
        public var analyzerFormat: @Sendable () async -> AVAudioFormat?

        /// `SpeechEngine.transcribe(input:onUpdate:)`, curried. The queue hands over a stream and
        /// an update callback and gets back the finished outcome.
        public var transcribe: @Sendable (
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

        public init(
            analyzerFormat: @Sendable @escaping () async -> AVAudioFormat?,
            transcribe: @Sendable @escaping (
                AsyncStream<AnalyzerInput>,
                @escaping @Sendable (TranscriptionUpdate) -> Void
            ) async throws -> TranscriptionOutcome,
            cancelActive: (@Sendable () async -> Void)? = nil
        ) {
            self.analyzerFormat = analyzerFormat
            self.transcribe = transcribe
            self.cancelActive = cancelActive
        }
    }

    // MARK: - Observable state

    public private(set) var items: [Item] = []

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
    /// URLs already present and not yet finished are ignored, so dropping the same file twice while
    /// it is still queued does not transcribe it twice. Re-dropping a *finished* file does re-run
    /// it, which is what someone retrying a failure expects.
    @discardableResult
    public func enqueue(_ urls: [URL]) -> [Item.ID] {
        // Seeded from the rows already in flight and then *grown as we go*, so a batch that carries
        // the same file twice enqueues it once. Checking only the pre-existing rows would let
        // `enqueue([url, url])` through, which is reachable from a drag whose provider registered a
        // file under two type identifiers.
        var seen = Set(items.filter { !$0.state.isTerminal }.map(\.url))
        var added: [Item.ID] = []
        for url in urls where seen.insert(url).inserted {
            let item = Item(url: url)
            items.append(item)
            added.append(item.id)
        }
        if !added.isEmpty {
            Log.data.info("import queue: enqueued \(added.count, privacy: .public) file(s)")
            startWorkerIfNeeded()
        }
        return added
    }

    @discardableResult
    public func enqueue(_ url: URL) -> Item.ID? { enqueue([url]).first }

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
        let url = items[index].url
        items.remove(at: index)
        // Dropped so the fresh run is not cancelled the instant it starts by the old id's flag.
        cancelledIDs.remove(id)
        enqueue([url])
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

        runningItemID = id
        runningText = ""
        runningPhase = .reading(0)
        runningStartedAt = ContinuousClock.now
        runningDuration = items[index].info?.duration ?? 0
        items[index].state = .running(progress: 0)
        startTicker(for: id)

        let began = ContinuousClock.now
        let importer = AudioFileImporter(url: url, analyzerFormat: await environment.analyzerFormat())
        runningImporter = importer

        defer {
            ticker?.cancel()
            ticker = nil
            runningImporter = nil
            runningItemID = nil
            runningPhase = nil
            runningStartedAt = nil
            runningDuration = 0
            runningText = ""
        }

        do {
            let info = try await importer.open()
            update(id) { $0.info = info }
            runningDuration = info.duration

            let stream = try await importer.start(onProgress: { [weak self] fraction in
                // Fires off the main actor from the importer's read loop, ~10 times a second.
                Task { @MainActor [weak self] in self?.setProgress(id, fraction) }
            })

            let outcome = try await transcribeWithRetry(stream: stream, id: id)

            let readFailure = await importer.readFailure
            let stats = await importer.statistics

            if cancelledIDs.contains(id) {
                finish(id, state: .cancelled, stats: stats)
                Log.data.info("import cancelled: \(filename, privacy: .public)")
                return
            }
            if case .cancelled = readFailure {
                finish(id, state: .cancelled, stats: stats)
                return
            }

            // A read that stopped early still produced real text. Saving it with a warning beats
            // throwing away nine minutes of a ten-minute transcript.
            let warning = readFailure?.errorDescription
            let elapsed = ContinuousClock.now - began
            let result = Result(
                itemID: id,
                url: url,
                info: info,
                outcome: outcome,
                segments: Self.segments(from: outcome.words),
                stats: stats,
                incompleteReason: warning,
                wallSeconds: Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
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
                import done: \(filename, privacy: .public) \
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
            Log.data.error("import failed: \(filename, privacy: .public): \(reason, privacy: .public)")
        }
    }

    /// Run the stream through the engine, tolerating the engine being momentarily busy.
    ///
    /// `SpeechEngine` permits one utterance at a time (RECON §3: a module and analyzer are built
    /// per utterance and never reused), so a file landing while the user is holding the hotkey gets
    /// `.sessionAlreadyRunning`. Failing the file for that would be a bad experience for something
    /// that resolves itself in a second.
    private func transcribeWithRetry(
        stream: AsyncStream<AnalyzerInput>,
        id: Item.ID
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
                return try await environment.transcribe(stream, { update in
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
