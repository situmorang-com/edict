import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Edict's speech backend: `SpeechAnalyzer` driving a `DictationTranscriber`.
///
/// **`DictationTranscriber`, not `SpeechTranscriber`.** RECON §1 measured `contextualStrings[.general]` as a
/// complete no-op on `SpeechTranscriber` (byte-identical output across 4 audio files × 4 configurations) and
/// demonstrably working on `DictationTranscriber` — "Visa and soup base and anthropic" became "Vercel and
/// Supabase and Anthropic", repeatably. The entire dictionary-biasing feature rests on that one difference, so
/// this must not be "simplified" back to `SpeechTranscriber`.
///
/// One instance per app run; a fresh module + analyzer per utterance (RECON §3 — reuse deadlocks or silently
/// swallows the utterance). Warm setup is ~2.5 ms, so per-utterance construction is not a cost worth optimising.
public actor SpeechEngine: TranscriptionEngine {

    /// RECON §5: cost is ~65 ms fixed plus ~1.5 ms/term at analyzer init, and hit rate measurably *degrades*
    /// with list length — a 9-term list fixed "Wispr Flow" and "Obsidian" where a 200-term list fixed neither.
    /// `Settings.biasingLimit` already clamps to this; the engine enforces it again so no caller can defeat it.
    public static let maxBiasingStrings = 50

    public private(set) var modelState: ModelState = .unavailable("not prepared")

    /// Set by `prepare`. Never derived from `Locale.current`: RECON §6 found this machine's `en_ID` resolves to
    /// `en-IN`, silently the wrong acoustic model for a US-English speaker.
    private var canonicalLocale: Locale?
    /// Cached because `bestAvailableAudioFormat` needs a throwaway module and the answer never changes for a
    /// given locale. Observed: 1 ch / 16000 Hz / Int16 / interleaved.
    private var cachedFormat: AVAudioFormat?
    /// Staged for the *next* utterance. RECON §2: `setContext` mid-stream is a silent no-op, so context can only
    /// be handed to `SpeechAnalyzer.init(analysisContext:)`. Read the dictionary at key-down.
    private var biasingStrings: [String] = []
    private var warmed = false
    private var activeSession: SpeechSession?

    public init() {}

    // MARK: - Locale and assets

    public var supportedLocales: [Locale] {
        get async { await DictationTranscriber.supportedLocales }
    }

    /// Resolve, reserve, and report whether the on-device assets are present.
    public func prepare(localeIdentifier: String) async throws {
        do {
            let canonical = try await reserveLocale(localeIdentifier)
            canonicalLocale = canonical

            let probe = Self.makeModule(locale: canonical)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe]) else {
                throw SpeechEngineError.noAudioFormat
            }
            cachedFormat = format

            // Gate on the installation request being nil, NOT on `AssetInventory.status(forModules:)`:
            // RECON §6 measured status returning `.supported` (not `.installed`) for locales whose assets are
            // on disk, which would trigger a pointless download every launch.
            let request = try await AssetInventory.assetInstallationRequest(supporting: [probe])
            modelState = request == nil ? .ready : .needsDownload

            Log.stt.info(
                """
                prepared locale=\(canonical.identifier, privacy: .public) \
                format=\(format.sampleRate, privacy: .public)Hz/\(format.channelCount, privacy: .public)ch \
                assets=\(request == nil ? "installed" : "needsDownload", privacy: .public)
                """
            )
        } catch {
            modelState = .unavailable(Self.describe(error))
            Log.stt.error("prepare(\(localeIdentifier, privacy: .public)) failed: \(Self.describe(error), privacy: .public)")
            throw error
        }
    }

    /// Resolve a locale identifier to the framework's canonical form and hold a reservation for it.
    ///
    /// RECON §6: reservation is effectively required (the framework logs "will be an error in a future
    /// release" without it), there are only 5 slots, and they **persist across process launches** keyed by
    /// bundle identifier. `release(reservedLocale:)` matches on the raw `Locale.identifier` *string*, so we
    /// only ever release objects taken straight out of `reservedLocales` — releasing a freshly-built
    /// `Locale(identifier: "en-US")` silently fails against a stored `"en_US"` and leaks the slot forever.
    @discardableResult
    public func reserveLocale(_ localeIdentifier: String) async throws -> Locale {
        guard let canonical = await DictationTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeIdentifier)
        ) else {
            // `id-ID` lands here — Indonesian is not supported, which matters on this user's machine.
            throw SpeechEngineError.localeUnsupported(localeIdentifier)
        }

        let existing = await AssetInventory.reservedLocales
        // Logged at every prepare because the probe leaked slots during exploration and a leak is invisible
        // until reservation starts failing outright.
        Log.stt.debug("reserved locales: \(existing.map(\.identifier).joined(separator: ","), privacy: .public)")

        if existing.contains(where: { $0.identifier == canonical.identifier }) { return canonical }

        do {
            // `false` means "already reserved" and is not an error.
            _ = try await AssetInventory.reserve(locale: canonical)
        } catch {
            // SFSpeechErrorDomain Code=11 "Too many allocated locales, 5 maximum". Evict everything else and
            // retry — Edict only ever needs one locale at a time.
            Log.stt.warning("reserve(\(canonical.identifier, privacy: .public)) failed, evicting: \(Self.describe(error), privacy: .public)")
            for stale in await AssetInventory.reservedLocales
            where stale.identifier != canonical.identifier {
                _ = await AssetInventory.release(reservedLocale: stale)
            }
            do {
                _ = try await AssetInventory.reserve(locale: canonical)
            } catch {
                throw SpeechEngineError.reservationFailed(Self.describe(error))
            }
        }
        return canonical
    }

    /// Download the locale's assets if they are missing. No-op when `prepare` already reported `.ready`.
    public func installModelIfNeeded(progress: @Sendable (Double) -> Void) async throws {
        guard let locale = canonicalLocale else { throw SpeechEngineError.notPrepared }
        let probe = Self.makeModule(locale: locale)

        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) else {
                modelState = .ready
                progress(1.0)
                return
            }
            modelState = .downloading(0)
            progress(0)
            // Coarse 0 → 1 reporting: `AssetInstallationRequest.progress` is a `Progress`, which is not
            // `Sendable`, so it cannot be polled from a child task under strict concurrency. RECON never
            // exercised this path at all (assets were already installed and the request came back nil in
            // 0.07 s), so a smarter progress bridge should wait until it can be measured.
            try await request.downloadAndInstall()
            modelState = .ready
            progress(1.0)
            Log.stt.info("installed assets for \(locale.identifier, privacy: .public)")
        } catch {
            modelState = .unavailable(Self.describe(error))
            throw SpeechEngineError.assetInstallFailed(Self.describe(error))
        }
    }

    /// The format `AudioCapture` must convert every mic buffer into. The analyzer accepts nothing else —
    /// RECON §6 found only 1 ch/16 kHz and 1 ch/8 kHz Int16 interleaved in `availableCompatibleAudioFormats`,
    /// while a live tap is typically 48 kHz Float32 non-interleaved.
    public func bestAudioFormat() async -> AVAudioFormat? {
        if let cachedFormat { return cachedFormat }
        guard let locale = canonicalLocale else { return nil }
        let probe = Self.makeModule(locale: locale)
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])
        cachedFormat = format
        return format
    }

    // MARK: - Biasing

    /// Stage the contextual strings for the next utterance.
    public func setBiasing(_ strings: [String]) async {
        var seen = Set<String>()
        var deduped: [String] = []
        for string in strings {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed.lowercased()).inserted else { continue }
            deduped.append(trimmed)
            if deduped.count == Self.maxBiasingStrings { break }
        }
        if strings.count > deduped.count {
            Log.stt.debug("biasing list trimmed \(strings.count, privacy: .public) -> \(deduped.count, privacy: .public)")
        }
        biasingStrings = deduped
    }

    // MARK: - One utterance

    /// Build a fresh module + analyzer for one utterance.
    ///
    /// Everything about this being per-utterance comes from RECON §3: `finalize(through:)` deadlocks forever
    /// while the input stream is open (the probe had to be SIGKILLed), and calling `start(inputSequence:)`
    /// again after `finalizeAndFinishThroughEndOfInput()` does not throw — it silently no-ops because
    /// `results` is a one-shot sequence that has already terminated, losing the whole second utterance.
    public func begin(
        onUpdate: @Sendable @escaping (TranscriptionUpdate) -> Void
    ) async throws -> any TranscriptionSession {
        try await beginSession(onUpdate: onUpdate)
    }

    private func beginSession(
        onUpdate: @Sendable @escaping (TranscriptionUpdate) -> Void
    ) async throws -> SpeechSession {
        if activeSession != nil { throw SpeechEngineError.sessionAlreadyRunning }
        guard let locale = canonicalLocale else { throw SpeechEngineError.notPrepared }
        guard let format = await bestAudioFormat() else { throw SpeechEngineError.noAudioFormat }

        let module = Self.makeModule(locale: locale)

        // Context MUST be supplied at init; `SpeechAnalyzer.setContext(_:)` later is a silent no-op (RECON §2).
        let context = AnalysisContext()
        if !biasingStrings.isEmpty {
            context.contextualStrings = [.general: biasingStrings]
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(
            inputSequence: stream,
            modules: [module],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime),
            analysisContext: context
        )
        try await analyzer.prepareToAnalyze(in: format)
        warmed = true

        let sink = TranscriptSink(onUpdate: onUpdate)
        // Hoisted out of the `Task` on purpose: capturing mutable local state inside the task closure is what
        // Swift 6 rejects with "sending value of non-Sendable type … risks causing data races" (RECON §7).
        // `module.results` is Sendable; the sink is lock-protected.
        let results = module.results
        sink.attach(
            Task {
                for try await result in results {
                    sink.ingest(isFinal: result.isFinal, range: result.range, text: result.text)
                }
            }
        )

        let session = SpeechSession(
            continuation: continuation,
            analyzer: analyzer,
            sink: sink,
            sampleRate: format.sampleRate,
            biasingCount: biasingStrings.count
        )
        activeSession = session
        return session
    }

    /// Run one utterance end to end: forward `input` into the analyzer, then finalize.
    ///
    /// The forwarding loop exists so the teardown order from RECON §5 is guaranteed: stop feeding →
    /// `continuation.finish()` → `finalizeAndFinishThroughEndOfInput()` → await the results task. Handing the
    /// caller's stream straight to `SpeechAnalyzer` would give away control of step 1.
    public func transcribe(
        input: AsyncStream<AnalyzerInput>,
        onUpdate: @Sendable @escaping (TranscriptionUpdate) -> Void
    ) async throws -> TranscriptionOutcome {
        let session = try await beginSession(onUpdate: onUpdate)
        // Identity-checked so a `cancel()` followed by a fresh `begin()` — which is legal, because cancel
        // clears `activeSession` while this method is still draining the caller's stream — is not torn down
        // by this call's cleanup.
        defer { if activeSession === session { activeSession = nil } }

        for await item in input {
            // `cancel()` terminates the session underneath us; keep draining the caller's stream so the
            // producer is not left blocked, but stop handing audio to a dead analyzer.
            if session.isTerminated { break }
            session.feed(item)
        }

        if session.isTerminated {
            Log.stt.info("utterance aborted")
            throw CancellationError()
        }
        return try await session.finishAndCommit()
    }

    /// Explicit user abort. RECON §5: `cancelAndFinishNow()` **discards** the pending final (measured 0 events
    /// / 0 finals / empty string), so this must never be on the normal key-release path.
    public func cancel() async {
        guard let session = activeSession else { return }
        activeSession = nil
        await session.abort()
    }

    // MARK: - Warm-up

    /// Pay the cold model-load cost at launch. Measured ~26–50 ms cold versus ~2.5 ms for every subsequent
    /// utterance, which is the difference between the user's first dictation feeling broken and feeling instant.
    public func warmUp() async {
        guard !warmed, activeSession == nil else { return }
        do {
            let session = try await beginSession(onUpdate: { _ in })
            activeSession = nil
            await session.abort()
            Log.stt.info("warm-up complete")
        } catch {
            // Warm-up is pure optimisation; a failure here must not block launch.
            Log.stt.warning("warm-up failed: \(Self.describe(error), privacy: .public)")
        }
    }

    // MARK: - Module construction

    /// The one place a `DictationTranscriber` is built.
    ///
    /// The explicit initializer is mandatory rather than stylistic: RECON §7 measured every *named* preset
    /// carrying `attributeOptions == []`, which yields one attribute-free run and no confidence at all — code
    /// looking for `ConfidenceAttribute` silently finds nothing and appears to work.
    private static func makeModule(locale: Locale) -> DictationTranscriber {
        DictationTranscriber(
            locale: locale,
            contentHints: [],
            transcriptionOptions: [.punctuation],
            reportingOptions: [.volatileResults],
            attributeOptions: [.transcriptionConfidence, .audioTimeRange]
        )
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

// MARK: - Session

/// One in-flight utterance. Single-use by construction.
///
/// A class rather than a struct so the terminal-state flag is shared between the transcribe loop and a
/// concurrent `cancel()`; `@unchecked Sendable` covers exactly one lock-guarded `Bool`.
final class SpeechSession: TranscriptionSession, @unchecked Sendable {
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let analyzer: SpeechAnalyzer
    private let sink: TranscriptSink
    private let sampleRate: Double
    private let biasingCount: Int

    private let stateLock = NSLock()
    private var terminated = false
    /// Wall clock at the moment the last audio was handed over — the start of the latency the blog post
    /// benchmarks. Measured 0.15 s for a 4.7 s clip and 0.53 s for a 24 s clip.
    private var endOfAudio: Date?

    init(
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        analyzer: SpeechAnalyzer,
        sink: TranscriptSink,
        sampleRate: Double,
        biasingCount: Int
    ) {
        self.continuation = continuation
        self.analyzer = analyzer
        self.sink = sink
        self.sampleRate = sampleRate
        self.biasingCount = biasingCount
    }

    var isTerminated: Bool { stateLock.withLock { terminated } }

    /// Yielding is cheap enough to do straight from the audio tap's thread (RECON's audio section measured
    /// ≤50 µs against a ≥100 ms buffer budget), so this does no work beyond bookkeeping.
    func feed(_ input: AnalyzerInput) {
        guard !isTerminated else { return }
        sink.countFrames(Int(input.buffer.frameLength))
        continuation.yield(input)
    }

    var snapshot: TranscriptionUpdate { sink.snapshot }

    func finishAndCommit() async throws -> TranscriptionOutcome {
        let alreadyDone: Bool = stateLock.withLock {
            if terminated { return true }
            terminated = true
            endOfAudio = Date()
            return false
        }
        if alreadyDone { throw CancellationError() }

        // Exactly the order RECON §5 verified. Any other ordering either deadlocks or drops the final result.
        continuation.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await sink.drain()

        if let failure = sink.consumerFailure { throw failure }

        let latency = stateLock.withLock { endOfAudio }.map { -$0.timeIntervalSinceNow } ?? 0
        let audioDuration = sink.audioDuration(sampleRate: sampleRate)
        let outcome = TranscriptionOutcome(
            text: sink.committed,
            confidence: sink.meanConfidence,
            latency: latency,
            audioDuration: audioDuration,
            words: sink.allWords,
            lowConfidenceWords: sink.lowConfidenceWords
        )
        Log.stt.info(
            """
            utterance committed chars=\(outcome.text.count, privacy: .public) \
            audio=\(String(format: "%.2f", audioDuration), privacy: .public)s \
            latency=\(String(format: "%.3f", latency), privacy: .public)s \
            biasing=\(self.biasingCount, privacy: .public) \
            lowConf=\(outcome.lowConfidenceWords.count, privacy: .public)
            """
        )
        return outcome
    }

    func abort() async {
        let alreadyDone: Bool = stateLock.withLock {
            if terminated { return true }
            terminated = true
            return false
        }
        guard !alreadyDone else { return }
        continuation.finish()
        // Discards the pending final on purpose — this is the Esc path.
        await analyzer.cancelAndFinishNow()
        await sink.drain()
    }
}
