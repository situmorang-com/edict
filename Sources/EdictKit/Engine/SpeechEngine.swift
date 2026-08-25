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

    /// Which of the two prepared languages an utterance runs in.
    ///
    /// The locale is fixed for the whole utterance by the framework — `DictationTranscriber` takes one
    /// `Locale` and there is no multilingual model that covers Indonesian — so this is chosen once, at
    /// key-down, and cannot change mid-stream. Because a fresh module and analyzer are built per
    /// utterance anyway (RECON §3), running one in a different locale costs nothing extra beyond the
    /// second model's own cold load.
    public enum UtteranceLocale: String, Sendable, Hashable, CaseIterable {
        case primary, secondary
    }

    /// RECON §5: cost is ~65 ms fixed plus ~1.5 ms/term at analyzer init, and hit rate measurably *degrades*
    /// with list length — a 9-term list fixed "Wispr Flow" and "Obsidian" where a 200-term list fixed neither.
    /// `Settings.biasingLimit` already clamps to this; the engine enforces it again so no caller can defeat it.
    public static let maxBiasingStrings = 50

    public private(set) var modelState: ModelState = .unavailable("not prepared")

    /// The second language's own asset state, reported separately so the UI can say "English ready,
    /// Indonesian downloading" rather than one aggregate lie.
    public private(set) var secondaryModelState: ModelState = .unavailable("not prepared")

    /// Set by `prepare`. Never derived from `Locale.current`: RECON §6 found this machine's `en_ID` resolves to
    /// `en-IN`, silently the wrong acoustic model for a US-English speaker.
    private var canonicalLocale: Locale?
    /// Cached because `bestAvailableAudioFormat` needs a throwaway module and the answer never changes for a
    /// given locale. Observed: 1 ch / 16000 Hz / Int16 / interleaved.
    private var cachedFormat: AVAudioFormat?
    /// The second dictation language, reserved at launch alongside the primary. macOS allows 5
    /// concurrent reservations and Edict holds 2, so this costs a slot and nothing else.
    private var secondaryLocale: Locale?
    private var secondaryFormat: AVAudioFormat?
    /// Whether the second language's assets are on disk. **Never used to fall back to the primary
    /// model** — see `beginSession`.
    private var secondaryAssetsReady = false
    /// The one in-flight download of the secondary assets, so a user leaning on the shortcut cannot
    /// start five of them.
    private var secondaryDownload: Task<Void, Never>?
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

    // MARK: The analyzer slot

    /// The session currently holding the slot, once it exists.
    ///
    /// Never the gate itself — see `slotHolder`. This is here so `cancel()` has something to abort
    /// and so a stale holder can be identified in a log line.
    private var activeSession: SpeechSession?
    /// Serial of whoever holds the slot, or `nil` when it is free.
    ///
    /// **The gate is this, not `activeSession`.** The claim has to be taken before the analyzer
    /// exists: `beginSession` awaits an asset check, a format query and `prepareToAnalyze` between
    /// deciding to start and having a session, and two presses that both got past a
    /// `activeSession == nil` check would both build one — the second overwriting the first, which
    /// orphans a live analyzer and wedges the engine permanently.
    private var slotHolder: UInt64?
    private var nextSlotSerial: UInt64 = 1
    /// Tasks suspended waiting for the slot, keyed so a timeout can resume exactly one of them.
    private var slotWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextWaiterID: UInt64 = 1

    /// Ceiling on waiting for the previous utterance to hand the slot back.
    ///
    /// **Deliberately unchanged at 1.5 s, and deliberately not the fix.** The leak that used to
    /// make this fire on every other press is fixed in `releaseSlot`; this is only the safety valve
    /// for a genuinely wedged analyzer, which has to surface as an error rather than hang the
    /// hotkey for ever. RECON §8 measured finalize at 0.15 s for a 4.7 s clip and 0.53 s for a 24 s
    /// one, so a healthy hand-back has ~3x headroom and a raised ceiling would buy nothing.
    private static let slotWaitCeiling = Duration.milliseconds(1500)

    /// Whether an utterance currently holds the analyzer slot. Diagnostics and tests only.
    ///
    /// Exists because the invariant it reports — "when `finishAndCommit` or `abort` has returned,
    /// the slot is free" — is not observable from anywhere else, and it is the invariant that broke.
    public var isSlotClaimed: Bool { slotHolder != nil }

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

    /// Resolve and reserve the *second* dictation language, and report whether its assets are present.
    ///
    /// Called at launch, right after `prepare`. Reserving both up front is deliberate: reservations are
    /// keyed to the bundle identifier and persist across launches, there are only 5 slots, and taking
    /// the second one lazily at key-down would mean a reservation — and possibly an eviction round —
    /// inside the utterance the user is already speaking into.
    ///
    /// The assets are **not** downloaded here. A cold download was measured at ~31 s for Indonesian,
    /// and paying that at every launch for a language the user may not touch today is worse than
    /// paying it once, on the first press, where the UI can say what is happening.
    public func prepareSecondary(localeIdentifier: String) async throws {
        do {
            let canonical = try await reserveLocale(localeIdentifier)
            secondaryLocale = canonical
            secondaryFormat = nil

            let probe = Self.makeModule(locale: canonical)
            let request = try await AssetInventory.assetInstallationRequest(supporting: [probe])
            secondaryAssetsReady = request == nil
            secondaryModelState = secondaryAssetsReady ? .ready : .needsDownload

            Log.stt.info("""
                prepared secondary locale=\(canonical.identifier, privacy: .public) \
                assets=\(self.secondaryAssetsReady ? "installed" : "needsDownload", privacy: .public)
                """)
        } catch {
            secondaryLocale = nil
            secondaryAssetsReady = false
            secondaryModelState = .unavailable(Self.describe(error))
            Log.stt.error("""
                prepareSecondary(\(localeIdentifier, privacy: .public)) failed: \
                \(Self.describe(error), privacy: .public)
                """)
            throw error
        }
    }

    /// Forget the second language. Its reservation is released — and only ever by handing back a
    /// `Locale` taken from `AssetInventory.reservedLocales`, because RECON §6 measured `release`
    /// matching on the raw identifier *string*: releasing a freshly-built `Locale(identifier: "id-ID")`
    /// against a stored `"id_ID"` returns false, does nothing, and leaks the slot permanently across
    /// every future launch of the app.
    public func clearSecondary() async {
        guard let locale = secondaryLocale else { return }
        secondaryDownload?.cancel()
        secondaryDownload = nil
        secondaryLocale = nil
        secondaryFormat = nil
        secondaryAssetsReady = false
        secondaryModelState = .unavailable("not prepared")

        for reserved in await AssetInventory.reservedLocales
        where reserved.identifier == locale.identifier {
            let released = await AssetInventory.release(reservedLocale: reserved)
            Log.stt.info("released \(reserved.identifier, privacy: .public): \(released, privacy: .public)")
        }
    }

    /// The reservation state as the framework sees it, for the launch log and for diagnostics.
    public func reservedLocaleIdentifiers() async -> [String] {
        await AssetInventory.reservedLocales.map(\.identifier).sorted()
    }

    /// Release every reservation Edict does not currently want.
    ///
    /// Called once at launch, after both languages are prepared. This exists because reservations
    /// **persist across process launches**, keyed to the bundle identifier, and there are only 5 —
    /// so anything Edict reserved and then stopped wanting is a slot lost until something explicitly
    /// hands it back. The observed case: the user turns the language shortcut off, and `id_ID` stays
    /// reserved for every future launch with nothing left in the app that remembers to release it.
    /// Enumerating what we *do* want and releasing the rest is the only version of this that cannot
    /// drift, since it needs no memory of what a previous launch did.
    ///
    /// Only ever releases `Locale` objects taken straight from `reservedLocales` — RECON §6 measured
    /// `release(reservedLocale:)` matching on the raw identifier *string*, so passing a rebuilt
    /// `Locale(identifier: "id-ID")` against a stored `"id_ID"` returns false, does nothing, and
    /// leaks the slot permanently.
    ///
    /// - Returns: the identifiers that were released.
    @discardableResult
    public func pruneReservations() async -> [String] {
        let keep = Set([
            canonicalLocale?.identifier,
            secondaryLocale?.identifier,
            generalLocale?.identifier,
        ].compactMap { $0 })
        // Never run this before anything is prepared: an empty keep set would release the primary.
        guard !keep.isEmpty else { return [] }

        var released: [String] = []
        for reserved in await AssetInventory.reservedLocales where !keep.contains(reserved.identifier) {
            if await AssetInventory.release(reservedLocale: reserved) {
                released.append(reserved.identifier)
            } else {
                Log.stt.error("release(\(reserved.identifier, privacy: .public)) refused")
            }
        }
        if !released.isEmpty {
            Log.stt.notice("released stale reservations: \(released.joined(separator: ","), privacy: .public)")
        }
        return released
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
            // Note for anyone reading the older comment that used to live here: `id-ID` does NOT land
            // here. RECON's correction is explicit — Indonesian is unsupported by `SpeechTranscriber`
            // but resolves to `id_ID` on `DictationTranscriber`, which is the module live dictation
            // uses, and an 18.8 s Indonesian clip transcribed word-perfect at 34.5x realtime.
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
            // retry. `generalLocale` is spared as well as the one being reserved, because evicting the
            // import model's slot here would silently demote every later import back to the dictation
            // module — and `secondaryLocale` too, because evicting *that* is how the language shortcut
            // would start throwing halfway through a session for no reason the user could see.
            Log.stt.warning("reserve(\(canonical.identifier, privacy: .public)) failed, evicting: \(Self.describe(error), privacy: .public)")
            let keep = Set([
                canonical.identifier,
                canonicalLocale?.identifier,
                secondaryLocale?.identifier,
                generalLocale?.identifier,
            ].compactMap { $0 })
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

    /// The same question for the second dictation language.
    ///
    /// Asked separately rather than assumed identical to the primary's. In practice both come back
    /// 1 ch / 16 kHz / Int16 / interleaved, but `availableCompatibleAudioFormats` is a property of the
    /// module — which is built per locale — and `AudioCapture`'s converter is configured from whatever
    /// this returns. Guessing here would be a silent format mismatch on the one path that has no
    /// English speech to sanity-check it against.
    public func bestAudioFormat(secondary: Bool) async -> AVAudioFormat? {
        guard secondary else { return await bestAudioFormat(for: .dictation) }
        if let secondaryFormat { return secondaryFormat }
        guard let locale = secondaryLocale else { return nil }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [Self.makeModule(locale: locale)]
        )
        secondaryFormat = format
        return format
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
        try await beginSession(module: .dictation, locale: .primary, biasing: nil, onUpdate: onUpdate)
    }

    /// Start one utterance in a named language.
    ///
    /// `.secondary` requires `prepareSecondary` to have succeeded and the assets to be installed; it
    /// throws rather than quietly using the primary model. See `beginSession`.
    public func begin(
        locale: UtteranceLocale,
        onUpdate: @Sendable @escaping (TranscriptionUpdate) -> Void
    ) async throws -> any TranscriptionSession {
        try await beginSession(module: .dictation, locale: locale, biasing: nil, onUpdate: onUpdate)
    }

    /// - Parameters:
    ///   - module: which of Apple's two modules to build. `.dictation` for live push-to-talk;
    ///     `.general` for a file import whose locale `SpeechTranscriber` covers.
    ///   - locale: which prepared dictation language to run in. Ignored for `.general`, which has
    ///     exactly one prepared locale of its own.
    ///   - biasing: contextual strings for *this* session only, bypassing the staged list. The
    ///     import path passes its own so a file cannot inherit — or clobber — the list a
    ///     concurrent dictation staged at key-down. `nil` uses the staged list.
    private func beginSession(
        module: TranscriptionModule,
        locale which: UtteranceLocale,
        biasing: [String]?,
        onUpdate: @Sendable @escaping (TranscriptionUpdate) -> Void
    ) async throws -> SpeechSession {
        // Serialised, not raced. A second utterance can arrive while the previous session is still
        // finalizing — RECON §8 puts that window at 0.15–0.53 s, comfortably inside a normal
        // press-pause-press rhythm — and throwing would discard speech the user has ALREADY SPOKEN.
        // So wait, and only give up if the holder is genuinely wedged. `claimSlot` also takes the
        // claim *before* any of the awaits below, which is what stops two presses from both
        // building a session.
        let serial = try await claimSlot(module: module, locale: which)

        do {
            let secondary = module == .dictation && which == .secondary
            if secondary { try await requireSecondaryAssets() }

            let resolved: Locale? = switch (module, which) {
            case (.general, _): generalLocale
            case (.dictation, .primary): canonicalLocale
            case (.dictation, .secondary): secondaryLocale
            }
            guard let locale = resolved else { throw SpeechEngineError.notPrepared }
            let format = secondary
                ? await bestAudioFormat(secondary: true)
                : await bestAudioFormat(for: module)
            guard let format else { throw SpeechEngineError.noAudioFormat }

            let built = Self.build(module: module, locale: locale)

            // Context MUST be supplied at init; `SpeechAnalyzer.setContext(_:)` later is a silent no-op
            // (RECON §2). Biasing is dropped entirely for `.general`: RECON §1 measured it as a
            // byte-for-byte no-op there, so paying the ~65 ms + ~1.5 ms/term setup cost would buy
            // literally nothing.
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
            // Only the primary counts as warm: `warmUp()` loads the primary model, and letting a
            // secondary utterance set this flag would mean the *English* model stays cold until the
            // first English press, which is the common case.
            if module == .dictation, which == .primary { warmed = true }

            let sink = TranscriptSink(onUpdate: onUpdate)
            // The results consumer is built by `build` rather than here, because the two modules have
            // *different* `Result` types and no common protocol member carrying `text` —
            // `SpeechModuleResult` only promises `range` and `resultsFinalizationTime`. Hoisting
            // `module.results` out of the `Task` still happens, inside `build`: capturing mutable local
            // state in the task closure is what Swift 6 rejects (RECON §7).
            sink.attach(built.attach(sink))

            let session = SpeechSession(
                serial: serial,
                continuation: continuation,
                analyzer: analyzer,
                sink: sink,
                sampleRate: format.sampleRate,
                biasingCount: strings.count,
                // THE FIX. The slot is handed back by the session itself, on whichever of its two
                // terminal paths actually runs, rather than by the caller remembering to. The leak
                // this closes: live dictation never calls `transcribe(input:)` — it calls `begin`
                // and drives the returned session directly, because it needs the object to feed
                // microphone buffers into — so the `defer` in `transcribe` was the only release and
                // it was on a path the hotkey never took.
                onTerminate: { [weak self] reason in
                    await self?.releaseSlot(serial: serial, reason: reason)
                }
            )
            activeSession = session
            Log.stt.debug("""
                slot #\(serial, privacy: .public) session built \
                module=\(module.rawValue, privacy: .public) \
                locale=\(locale.identifier, privacy: .public) \
                biasing=\(strings.count, privacy: .public)
                """)
            return session
        } catch {
            // Anything above can throw — a missing secondary asset, a locale that is not prepared,
            // `prepareToAnalyze`. The claim was taken before all of it, so it has to be handed back
            // here or the next press inherits a slot nobody is using.
            releaseSlot(serial: serial, reason: "begin failed: \(Self.describe(error))")
            throw error
        }
    }

    // MARK: - The analyzer slot

    /// Take the analyzer slot, waiting for the current holder if there is one.
    ///
    /// Returns the serial the caller must release with. Throws `.sessionAlreadyRunning` only when
    /// the holder is still there after `slotWaitCeiling` — which, with `releaseSlot` wired to the
    /// session's terminal transition, means a genuinely stuck analyzer rather than the ordinary
    /// press-pause-press rhythm.
    private func claimSlot(module: TranscriptionModule, locale which: UtteranceLocale) async throws -> UInt64 {
        // A holder whose session has already terminated is a bug in whatever tore it down, not a
        // race, and making the user press twice for it is the exact symptom this whole change is
        // about. Reclaim, and log it as the distinct third case: *failed to clear*.
        if let holder = slotHolder, let session = activeSession, session.isTerminated {
            Log.stt.error("""
                slot #\(holder, privacy: .public) FAILED TO CLEAR: \
                its session is already terminated; reclaiming
                """)
            forceReleaseSlot(reason: "stale terminated holder")
        }

        if let holder = slotHolder {
            Log.stt.debug("slot busy (#\(holder, privacy: .public)); waiting for it to be handed back")
            let deadline = ContinuousClock.now + Self.slotWaitCeiling
            while slotHolder != nil {
                guard await waitForSlotRelease(until: deadline) else {
                    Log.stt.error("""
                        slot #\(self.slotHolder ?? 0, privacy: .public) still held after \
                        1.5 s; refusing to start a second utterance
                        """)
                    throw SpeechEngineError.sessionAlreadyRunning
                }
            }
            Log.stt.debug("slot handed back; starting the next utterance")
        }

        // No `await` between the check above and this assignment, which is what makes the claim
        // atomic on the actor.
        let serial = nextSlotSerial
        nextSlotSerial += 1
        slotHolder = serial
        Log.stt.debug("""
            slot #\(serial, privacy: .public) claimed \
            module=\(module.rawValue, privacy: .public) \
            locale=\(which.rawValue, privacy: .public)
            """)
        return serial
    }

    /// Suspend until the holder releases the slot, or the deadline passes.
    ///
    /// A real suspension rather than a poll: the releasing session resumes us directly, so a
    /// back-to-back press waits exactly as long as the previous finalize takes and not a 20 ms tick
    /// longer. The timer exists only so a wedged holder cannot pin the caller past the ceiling.
    ///
    /// - Returns: `false` if the deadline passed.
    private func waitForSlotRelease(until deadline: ContinuousClock.Instant) async -> Bool {
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { return false }

        let id = nextWaiterID
        nextWaiterID += 1
        let timer = Task { [weak self] in
            try? await Task.sleep(for: remaining)
            await self?.wakeSlotWaiter(id)
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Re-checked in the same actor step that registers the waiter. Registering first and
            // trusting the earlier check would be a lost wakeup: if the holder released while this
            // call was getting here, the wake has already been delivered to nobody and this task
            // would sleep until the ceiling for no reason.
            if slotHolder == nil {
                continuation.resume()
            } else {
                slotWaiters[id] = continuation
            }
        }
        timer.cancel()
        return ContinuousClock.now < deadline
    }

    private func wakeSlotWaiter(_ id: UInt64) {
        slotWaiters.removeValue(forKey: id)?.resume()
    }

    /// Hand the slot back. Idempotent, and identity-checked so a late release from a session that
    /// has already been superseded cannot free somebody else's claim.
    private func releaseSlot(serial: UInt64, reason: String) {
        guard slotHolder == serial else {
            Log.stt.debug("""
                slot release #\(serial, privacy: .public) ignored \
                (holder=#\(self.slotHolder ?? 0, privacy: .public)) — \(reason, privacy: .public)
                """)
            return
        }
        forceReleaseSlot(reason: "#\(serial) \(reason)")
    }

    private func forceReleaseSlot(reason: String) {
        slotHolder = nil
        activeSession = nil
        Log.stt.debug("slot cleared — \(reason, privacy: .public)")
        // Wake everyone; the losers see `slotHolder != nil` again and re-suspend.
        let waiting = slotWaiters
        slotWaiters.removeAll()
        for (_, continuation) in waiting { continuation.resume() }
    }

    /// Gate a secondary-locale utterance on its assets actually being installed.
    ///
    /// **This is the one place where falling back would be indefensible.** Transcribing Indonesian
    /// speech with the English model does not fail — it succeeds, confidently, and returns fluent
    /// English nonsense that the injection ladder then types into the user's document. There is no
    /// signal anywhere for the user to notice; RECON §7 records that confidence is discriminative for
    /// *misheard words*, not for a wholesale language mismatch, and measured Indonesian returning no
    /// confidence attribute at all. So: install if we can, and otherwise throw a sentence the UI can
    /// show. Never substitute a model.
    private func requireSecondaryAssets() async throws {
        guard let locale = secondaryLocale else {
            throw SpeechEngineError.notPrepared
        }
        if secondaryAssetsReady { return }

        // A download is already running from an earlier press. Do not await it — the user is holding a
        // key right now and a 31 s stall inside an utterance is its own failure.
        if let secondaryDownload, !secondaryDownload.isCancelled {
            throw SpeechEngineError.assetInstallFailed(
                "The \(Self.languageName(locale)) speech model is still downloading. Try again in a moment."
            )
        }

        let probe = Self.makeModule(locale: locale)
        // Gate on the request being nil, not on `AssetInventory.status` (RECON §6: status reports
        // `.supported` rather than `.installed` for assets that are on disk but unreserved).
        //
        // `try?` is deliberately NOT used here: it flattens `AssetInstallationRequest??` into one
        // optional, which would make "assets already installed" indistinguishable from "the check
        // itself failed" — and those two must not take the same branch.
        let pending: AssetInstallationRequest?
        do {
            pending = try await AssetInventory.assetInstallationRequest(supporting: [probe])
        } catch {
            throw SpeechEngineError.assetInstallFailed(
                "The \(Self.languageName(locale)) speech model could not be checked: \(Self.describe(error))"
            )
        }
        guard let request = pending else {
            secondaryAssetsReady = true
            secondaryModelState = .ready
            return
        }

        secondaryModelState = .downloading(0)
        secondaryDownload = Task { [weak self] in
            do {
                try await request.downloadAndInstall()
                await self?.secondaryDownloadFinished(error: nil)
            } catch {
                await self?.secondaryDownloadFinished(error: error)
            }
        }
        throw SpeechEngineError.assetInstallFailed(
            "Downloading the \(Self.languageName(locale)) speech model. Try again in a moment."
        )
    }

    private func secondaryDownloadFinished(error: Error?) {
        secondaryDownload = nil
        if let error {
            secondaryAssetsReady = false
            secondaryModelState = .unavailable(Self.describe(error))
            Log.stt.error("secondary asset install failed: \(Self.describe(error), privacy: .public)")
        } else {
            secondaryAssetsReady = true
            secondaryModelState = .ready
            Log.stt.info("secondary assets installed")
        }
    }

    /// A language name the user will recognise, for the one error string they might actually read.
    private static func languageName(_ locale: Locale) -> String {
        Locale(identifier: "en-US").localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }

    /// Run one utterance end to end: forward `input` into the analyzer, then finalize.
    ///
    /// The forwarding loop exists so the teardown order from RECON §5 is guaranteed: stop feeding →
    /// `continuation.finish()` → `finalizeAndFinishThroughEndOfInput()` → await the results task. Handing the
    /// caller's stream straight to `SpeechAnalyzer` would give away control of step 1.
    public func transcribe(
        input: AsyncStream<AnalyzerInput>,
        module: TranscriptionModule = .dictation,
        locale: UtteranceLocale = .primary,
        biasing: [String]? = nil,
        onUpdate: @Sendable @escaping (TranscriptionUpdate) -> Void
    ) async throws -> TranscriptionOutcome {
        let session = try await beginSession(
            module: module,
            locale: locale,
            biasing: biasing,
            onUpdate: onUpdate
        )
        // No cleanup `defer` here any more, and that is the point: the slot is released by the
        // session's own terminal transition (`finishAndCommit` / `abort`), so it does not matter
        // whether a caller goes through this method or drives the session itself. A `defer` could
        // never have covered both, because the live dictation path does not come through here.

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
    ///
    /// Does not clear the slot itself: `abort()` does that, through the session's terminal hook. A
    /// claim with no session yet — `begin` is still inside `prepareToAnalyze` — is deliberately left
    /// alone, because that call's own error path owns it and clearing it here would let a second
    /// utterance start on top of an analyzer that is still being built.
    public func cancel() async {
        guard let session = activeSession else { return }
        await session.abort()
    }

    // MARK: - Warm-up

    /// Pay the cold model-load cost at launch. Measured ~26–50 ms cold versus ~2.5 ms for every subsequent
    /// utterance, which is the difference between the user's first dictation feeling broken and feeling instant.
    ///
    /// **The primary language only.** Warming both would double the launch cost for a second model that
    /// may not be used today, and the secondary path's first press pays ~50 ms — invisible next to the
    /// ~0.2–0.5 s the utterance itself takes to finalize.
    public func warmUp() async {
        guard !warmed, slotHolder == nil else { return }
        do {
            let session = try await beginSession(
                module: .dictation,
                locale: .primary,
                biasing: nil,
                onUpdate: { _ in }
            )
            // `abort()` hands the slot back on its own. Clearing `activeSession` by hand first — which
            // is what this used to do — would have made the release a no-op on the identity check and
            // left the warm-up's claim held for the user's very first press.
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
    /// Identifies this session's claim on the engine's analyzer slot, for the release and for logs.
    let serial: UInt64

    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let analyzer: SpeechAnalyzer
    private let sink: TranscriptSink
    private let sampleRate: Double
    private let biasingCount: Int
    /// Hands the engine's analyzer slot back. Called exactly once, on whichever terminal path runs,
    /// and awaited before that path returns — so "`finishAndCommit`/`abort` has returned" and "the
    /// engine is free" are the same moment, with no window for a following press to be refused.
    ///
    /// A closure rather than a reference to the engine so this stays a leaf object with no cycle
    /// back into the actor that owns it.
    private let onTerminate: @Sendable (String) async -> Void

    private let stateLock = NSLock()
    private var terminated = false
    /// Wall clock at the moment the last audio was handed over — the start of the latency the blog post
    /// benchmarks. Measured 0.15 s for a 4.7 s clip and 0.53 s for a 24 s clip.
    private var endOfAudio: Date?

    init(
        serial: UInt64,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        analyzer: SpeechAnalyzer,
        sink: TranscriptSink,
        sampleRate: Double,
        biasingCount: Int,
        onTerminate: @escaping @Sendable (String) async -> Void
    ) {
        self.serial = serial
        self.continuation = continuation
        self.analyzer = analyzer
        self.sink = sink
        self.sampleRate = sampleRate
        self.biasingCount = biasingCount
        self.onTerminate = onTerminate
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
        // Not a release: whoever set `terminated` already released, and releasing again here could
        // free a *later* utterance's claim if the identity check ever loosened.
        if alreadyDone { throw CancellationError() }

        do {
            // Exactly the order RECON §5 verified. Any other ordering either deadlocks or drops the
            // final result.
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
            // Before the return, so the caller cannot observe a committed utterance and a held slot
            // at the same time. That combination is precisely the reported bug: the controller logged
            // "utterance done" while the engine still refused the next press.
            await onTerminate("committed")
            Log.stt.info(
                """
                utterance committed slot=#\(self.serial, privacy: .public) \
                chars=\(outcome.text.count, privacy: .public) \
                audio=\(String(format: "%.2f", audioDuration), privacy: .public)s \
                latency=\(String(format: "%.3f", latency), privacy: .public)s \
                biasing=\(self.biasingCount, privacy: .public) \
                lowConf=\(outcome.lowConfidenceWords.count, privacy: .public)
                """
            )
            return outcome
        } catch {
            // `finalizeAndFinishThroughEndOfInput` throwing, or a results-consumer failure. The
            // analyzer is finished either way and the slot must not outlive it. `defer` cannot do
            // this — it cannot await — which is why this is spelled out twice.
            await onTerminate("commit failed: \(error)")
            throw error
        }
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
        // Same contract as the commit path. Esc, a lost permission, a chord cancellation and
        // `warmUp()` all land here, and every one of them used to leave the slot held.
        await onTerminate("aborted")
    }
}
