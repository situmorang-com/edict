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
    /// The `SpeechTranscriber` half of the same two facts. Resolved lazily, the first time a file
    /// import asks for the general module — live dictation never touches it.
    private var generalLocale: Locale?
    private var generalFormat: AVAudioFormat?
    /// Memoised answer to "which module serves this locale for an import". Keyed by the *requested*
    /// identifier, because that is what the caller has; the resolved canonical form is stored in
    /// `generalLocale`.
    private var importModuleByLocale: [String: TranscriptionModule] = [:]
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

        try await reserve(canonical)
        return canonical
    }

    /// Hold a reservation for an already-canonical locale. Split out of `reserveLocale` so the
    /// import path can reserve a `SpeechTranscriber` locale, which resolves through a *different*
    /// module and therefore cannot go through the dictation resolver above.
    private func reserve(_ canonical: Locale) async throws {
        let existing = await AssetInventory.reservedLocales
        // Logged at every prepare because the probe leaked slots during exploration and a leak is invisible
        // until reservation starts failing outright.
        Log.stt.debug("reserved locales: \(existing.map(\.identifier).joined(separator: ","), privacy: .public)")

        if existing.contains(where: { $0.identifier == canonical.identifier }) { return }

        do {
            // `false` means "already reserved" and is not an error.
            _ = try await AssetInventory.reserve(locale: canonical)
        } catch {
            // SFSpeechErrorDomain Code=11 "Too many allocated locales, 5 maximum". Evict everything else and
            // retry — Edict only ever needs one locale at a time. `generalLocale` is spared as well as the
            // one being reserved, because evicting the import model's slot here would silently demote every
            // later import back to the dictation module.
            Log.stt.warning("reserve(\(canonical.identifier, privacy: .public)) failed, evicting: \(Self.describe(error), privacy: .public)")
            let keep = Set([canonical.identifier, canonicalLocale?.identifier, generalLocale?.identifier].compactMap { $0 })
            for stale in await AssetInventory.reservedLocales where !keep.contains(stale.identifier) {
                _ = await AssetInventory.release(reservedLocale: stale)
            }
            do {
                _ = try await AssetInventory.reserve(locale: canonical)
            } catch {
                throw SpeechEngineError.reservationFailed(Self.describe(error))
            }
        }
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
        await bestAudioFormat(for: .dictation)
    }

    /// The same question for a named module. The two modules are asked separately rather than
    /// assumed identical: `availableCompatibleAudioFormats` is a property of the module, and the
    /// import path must convert to whatever the module it is actually going to use accepts.
    public func bestAudioFormat(for module: TranscriptionModule) async -> AVAudioFormat? {
        switch module {
        case .dictation:
            if let cachedFormat { return cachedFormat }
            guard let locale = canonicalLocale else { return nil }
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [Self.build(module: .dictation, locale: locale).module]
            )
            cachedFormat = format
            return format
        case .general:
            if let generalFormat { return generalFormat }
            guard let locale = generalLocale else { return nil }
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                compatibleWith: [Self.build(module: .general, locale: locale).module]
            )
            generalFormat = format
            return format
        }
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
        try await beginSession(module: .dictation, biasing: nil, onUpdate: onUpdate)
    }

    /// - Parameters:
    ///   - module: which of Apple's two modules to build. `.dictation` for live push-to-talk;
    ///     `.general` for a file import whose locale `SpeechTranscriber` covers.
    ///   - biasing: contextual strings for *this* session only, bypassing the staged list. The
    ///     import path passes its own so a file cannot inherit — or clobber — the list a
    ///     concurrent dictation staged at key-down. `nil` uses the staged list.
    private func beginSession(
        module: TranscriptionModule,
        biasing: [String]?,
        onUpdate: @Sendable @escaping (TranscriptionUpdate) -> Void
    ) async throws -> SpeechSession {
        if activeSession != nil { throw SpeechEngineError.sessionAlreadyRunning }
        guard let locale = module == .general ? generalLocale : canonicalLocale else {
            throw SpeechEngineError.notPrepared
        }
        guard let format = await bestAudioFormat(for: module) else { throw SpeechEngineError.noAudioFormat }

        let built = Self.build(module: module, locale: locale)

        // Context MUST be supplied at init; `SpeechAnalyzer.setContext(_:)` later is a silent no-op (RECON §2).
        // Biasing is dropped entirely for `.general`: RECON §1 measured it as a byte-for-byte no-op
        // there, so paying the ~65 ms + ~1.5 ms/term setup cost would buy literally nothing.
        let strings = module.supportsBiasing ? (biasing ?? biasingStrings) : []
        let context = AnalysisContext()
        if !strings.isEmpty {
            context.contextualStrings = [.general: strings]
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(
            inputSequence: stream,
            modules: [built.module],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime),
            analysisContext: context
        )
        try await analyzer.prepareToAnalyze(in: format)
        if module == .dictation { warmed = true }

        let sink = TranscriptSink(onUpdate: onUpdate)
        // The results consumer is built by `build` rather than here, because the two modules have
        // *different* `Result` types and no common protocol member carrying `text` —
        // `SpeechModuleResult` only promises `range` and `resultsFinalizationTime`. Hoisting
        // `module.results` out of the `Task` still happens, inside `build`: capturing mutable local
        // state in the task closure is what Swift 6 rejects (RECON §7).
        sink.attach(built.attach(sink))

        let session = SpeechSession(
            continuation: continuation,
            analyzer: analyzer,
            sink: sink,
            sampleRate: format.sampleRate,
            biasingCount: strings.count
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
        module: TranscriptionModule = .dictation,
        biasing: [String]? = nil,
        onUpdate: @Sendable @escaping (TranscriptionUpdate) -> Void
    ) async throws -> TranscriptionOutcome {
        let session = try await beginSession(module: module, biasing: biasing, onUpdate: onUpdate)
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
            let session = try await beginSession(module: .dictation, biasing: nil, onUpdate: { _ in })
            activeSession = nil
            await session.abort()
            Log.stt.info("warm-up complete")
        } catch {
            // Warm-up is pure optimisation; a failure here must not block launch.
            Log.stt.warning("warm-up failed: \(Self.describe(error), privacy: .public)")
        }
    }

    // MARK: - Module construction

    /// A module plus the results consumer that belongs to it.
    ///
    /// `attach` is a closure and not a generic function because the two modules' `Result` types are
    /// unrelated: `SpeechModuleResult` promises only `range` and `resultsFinalizationTime`, so the
    /// `text` accessor can only be reached from inside a branch that knows the concrete type.
    private struct BuiltModule {
        let module: any SpeechModule
        let attach: (TranscriptSink) -> Task<Void, Error>
    }

    /// The one place either transcription module is built.
    ///
    /// **The explicit initializer is mandatory rather than stylistic.** RECON §7 measured every
    /// *named* preset carrying `attributeOptions == []`, which yields one attribute-free run with no
    /// confidence and **no time range at all** — code looking for `ConfidenceAttribute` or
    /// `TimeRangeAttribute` silently finds nothing and appears to work. Without
    /// `[.transcriptionConfidence, .audioTimeRange]` here there are no per-word timings, so
    /// `TranscriptSegment` comes back empty and SRT/VTT export is worthless. Both branches ask for
    /// both attributes; both were verified to deliver them (see the note below).
    ///
    /// ## Why two modules, measured on this machine
    ///
    /// The 377 s English script in `long.aiff`, same audio, same explicit attribute options:
    ///
    /// | module                 | word error | wall  | realtime | final results |
    /// |------------------------|-----------:|------:|---------:|--------------:|
    /// | `DictationTranscriber` |     10.1 % | 25.0s |    15.1x |             7 |
    /// | `SpeechTranscriber`    |      4.2 % |  5.7s |    66.4x |            64 |
    ///
    /// `SpeechTranscriber` more than halves the error rate, runs 4.4x faster, and emits ~9x as many
    /// final results — which matters for subtitles, because a cue can only be cut at a result
    /// boundary. Concretely, `DictationTranscriber` produced "It is a push to talk. Dictation tool
    /// for macOS" and "the text appears that the cursor" where `SpeechTranscriber` produced "Edict is
    /// a push to talk dictation tool for macOS" and "the text appears at the cursor".
    ///
    /// So imports use `SpeechTranscriber` — **but only where it can.** It covers 45 locales against
    /// `DictationTranscriber`'s 54, and Indonesian is in the gap:
    /// `SpeechTranscriber.supportedLocale(equivalentTo: id-ID)` returns nil, while the dictation
    /// module transcribed an 18.8 s Indonesian clip word-perfect at 34.5x realtime. `resolveImportModule`
    /// therefore falls back rather than refusing the file. One measured wrinkle worth knowing: on
    /// `id_ID` the dictation module returned time ranges on all 38 runs but confidence on **none** of
    /// them, so the low-confidence dictionary suggestions are silently empty for Indonesian while the
    /// subtitle export still works.
    ///
    /// Live dictation stays on `DictationTranscriber` regardless, for the reason RECON §1 exists:
    /// contextual-string biasing works there and nowhere else, and that is the whole dictionary
    /// feature. A file import has the correction pass instead, and no speech onset to hide the
    /// biasing setup cost behind.
    private static func build(module: TranscriptionModule, locale: Locale) -> BuiltModule {
        switch module {
        case .dictation:
            let transcriber = DictationTranscriber(
                locale: locale,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [.volatileResults],
                attributeOptions: [.transcriptionConfidence, .audioTimeRange]
            )
            let results = transcriber.results
            return BuiltModule(module: transcriber) { sink in
                Task {
                    for try await result in results {
                        sink.ingest(isFinal: result.isFinal, range: result.range, text: result.text)
                    }
                }
            }

        case .general:
            let transcriber = SpeechTranscriber(
                locale: locale,
                // `SpeechTranscriber.TranscriptionOption` has exactly one case,
                // `etiquetteReplacements` (profanity masking), which is not ours to impose. It has
                // no `.punctuation` option because it punctuates by default — measured: "Hold the
                // right option key, speak, and release, and the text appears at the cursor."
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: [.transcriptionConfidence, .audioTimeRange]
            )
            let results = transcriber.results
            return BuiltModule(module: transcriber) { sink in
                Task {
                    for try await result in results {
                        sink.ingest(isFinal: result.isFinal, range: result.range, text: result.text)
                    }
                }
            }
        }
    }

    /// Kept as the dictation-only shorthand the asset paths use.
    private static func makeModule(locale: Locale) -> any SpeechModule {
        build(module: .dictation, locale: locale).module
    }

    // MARK: - Import module selection

    /// Decide which module a file import should use, and prepare it.
    ///
    /// Never throws and never refuses: the worst case is falling back to `.dictation`, which
    /// `prepare(localeIdentifier:)` has already reserved and warmed. Three things send it back to
    /// `.dictation`:
    ///
    /// 1. The user turned the preference off.
    /// 2. `SpeechTranscriber` does not support the locale (`id-ID`).
    /// 3. `SpeechTranscriber` supports it but its assets are **not installed**. Downloading them
    ///    inside an import would stall a queue the user is watching for an unbounded time, so the
    ///    file is transcribed now with the model that is already on disk and the choice is logged.
    public func resolveImportModule(
        preferGeneral: Bool,
        localeIdentifier: String
    ) async -> TranscriptionModule {
        guard preferGeneral else { return .dictation }
        if let cached = importModuleByLocale[localeIdentifier] { return cached }

        func remember(_ module: TranscriptionModule, _ why: String) -> TranscriptionModule {
            importModuleByLocale[localeIdentifier] = module
            Log.stt.info(
                """
                import module for \(localeIdentifier, privacy: .public):                 \(module.rawValue, privacy: .public) — \(why, privacy: .public)
                """
            )
            return module
        }

        guard let canonical = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeIdentifier)
        ) else {
            return remember(.dictation, "the transcription model does not support this locale")
        }

        do {
            let probe = Self.build(module: .general, locale: canonical).module
            // Reserved *before* the status check, exactly as RECON §6 requires: unreserved-but-installed
            // locales report `.supported`, so gating on status would trigger a pointless download.
            _ = try await reserve(canonical)
            if try await AssetInventory.assetInstallationRequest(supporting: [probe]) != nil {
                return remember(.dictation, "the transcription model's assets are not installed")
            }
            generalLocale = canonical
            generalFormat = nil
            return remember(.general, "measured 4.2 % word error against 10.1 % on this machine")
        } catch {
            return remember(.dictation, "the transcription model could not be prepared: \(Self.describe(error))")
        }
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
