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

    /// One transcription module bound to one prepared locale: everything a single import pass needs.
    ///
    /// The dual-pass import needs this shape because the engine's two *dictation* slots — primary and
    /// secondary — cannot express it. A pass may want `SpeechTranscriber` for English (measured 4.2 %
    /// word error against 10.1 %, RECON amendment 1) and `DictationTranscriber` for Indonesian, which
    /// `SpeechTranscriber` does not support at all. Which module a language gets is therefore a
    /// property of the language, resolved once per identifier and memoised.
    public struct ImportPass: Sendable, Hashable {
        /// Which of Apple's two modules will run.
        public var module: TranscriptionModule
        /// The identifier the caller asked for — `"id-ID"`. This is what goes in the transcript, so
        /// history shows the user's own spelling rather than the framework's.
        public var requestedIdentifier: String
        /// The identifier the framework resolved it to — `"id_ID"`, underscored. Diagnostics only.
        public var canonicalIdentifier: String

        public init(module: TranscriptionModule, requestedIdentifier: String, canonicalIdentifier: String) {
            self.module = module
            self.requestedIdentifier = requestedIdentifier
            self.canonicalIdentifier = canonicalIdentifier
        }
    }

    /// Whether a language can be transcribed right now, or a sentence saying why not.
    ///
    /// Two cases rather than an optional because the failure has to reach the user: a missing
    /// on-device model is fixable (it downloads) and an unsupported locale is not, and neither may be
    /// papered over by substituting a different model. Transcribing Indonesian with the English model
    /// does not fail — it returns fluent English nonsense, with no signal anywhere that it did.
    public enum ImportPassResolution: Sendable {
        case ready(ImportPass)
        /// Already-user-facing text.
        case unavailable(String)

        public var pass: ImportPass? {
            if case .ready(let pass) = self { return pass }
            return nil
        }

        public var reason: String? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }
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
    /// Asset downloads in flight, keyed by the framework's canonical identifier.
    ///
    /// **Keyed rather than one slot, because the languages downloading here are not one language.**
    /// A single `secondaryDownload` slot was shared between the live secondary dictation language
    /// and every import language, and all three consequences were real: a secondary-language press
    /// during an import's download threw "the <secondary language> model is still downloading" —
    /// about the wrong language, and it started no download for the language actually asked for;
    /// `clearSecondary()` cancelled an import's download; and a third language's *successful*
    /// download flipped `secondaryAssetsReady` for a model that is not on disk, which is the one
    /// flag `requireSecondaryAssets()` may never be wrong about (it is what stops Indonesian speech
    /// being handed to the English model and typed out as invented English names).
    private var downloads: [String: Task<Void, Never>] = [:]
    /// The terminal asset state of an *import* language, keyed by canonical identifier.
    ///
    /// Deliberately not `secondaryModelState`, which belongs to the live secondary dictation
    /// language and is what the UI shows. This one exists so the second attempt at the same file
    /// reports the real reason the model never arrived, instead of repeating "Downloading… Try this
    /// file again in a moment." for ever with the error only in the log.
    private var importModelStates: [String: ModelState] = [:]
    /// Resolved dual-pass import passes, keyed by the *requested* identifier.
    ///
    /// A dual pass resolves **two** locales, and each carries its own module: `en-US` may resolve to
    /// `SpeechTranscriber` while `id-ID` can only ever be `DictationTranscriber`. Keying by the
    /// requested identifier is what stops one pass's resolution overwriting the other's and
    /// silently transcribing a section in the wrong language — a failure with no symptom except a
    /// nonsense transcript.
    private var importPasses: [String: ImportPass] = [:]
    private var importPassLocales: [String: Locale] = [:]
    private var importPassFormats: [String: AVAudioFormat] = [:]
    /// Requested identifiers in least-recently-used order, oldest first.
    ///
    /// The memos above used to be permanent, and so were the reservations behind them: every import
    /// language ever resolved held one of the five slots for the rest of the process (and, because
    /// reservations persist across launches, beyond it). This is the eviction order — see
    /// `pruneImportPasses(reserving:)`, which drops a memo and releases its reservation in the same
    /// step so a memo can never outlive the reservation it depends on.
    private var importPassOrder: [String] = []
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
        // This language's download only. Cancelling whatever happened to be in a single shared slot
        // is how turning the language shortcut off used to kill an import's model download for an
        // unrelated language.
        downloads.removeValue(forKey: locale.identifier)?.cancel()
        secondaryLocale = nil
        secondaryFormat = nil
        secondaryAssetsReady = false
        secondaryModelState = .unavailable("not prepared")

        // Not released if an import still needs this exact language — the user who dictates in
        // Indonesian is also the user who imports Indonesian files, and dropping the reservation
        // under a memoised `.ready` import pass would leave the memo pointing at an unreserved
        // module (RECON §6: "will be an error in a future release").
        guard !keepSet().contains(locale.identifier) else {
            Log.stt.info("""
                kept \(locale.identifier, privacy: .public) reserved: an import pass still needs it
                """)
            return
        }
        for reserved in await AssetInventory.reservedLocales
        where reserved.identifier == locale.identifier {
            let released = await AssetInventory.release(reservedLocale: reserved)
            Log.stt.info("released \(reserved.identifier, privacy: .public): \(released, privacy: .public)")
        }
    }

    /// Every reservation Edict currently depends on, by canonical identifier.
    ///
    /// One function rather than three copies, because the copies drifted and the drift was the bug:
    /// `pruneReservations` and `reserve`'s eviction ladder both listed `generalLocale` — which is
    /// always nil in production, so it spared nothing — and both omitted the import pass locales,
    /// which are the ones genuinely in use. An import of a French file followed by a touch of the
    /// language picker was therefore enough to release the reservation behind a memoised pass, and
    /// on a machine importing while dictating it could release the language the user was speaking.
    ///
    /// Split into this reader and the pure `static` below for the reason the last round paid for:
    /// every test that could see the keep set at all was in the gated reservation suite, which
    /// cannot run on this machine — so a one-line body returning only the two dictation locales
    /// shipped green underneath a ten-line comment promising the import passes. The static takes its
    /// four inputs as values and touches no framework, so `KeepSetTests` pins the contents on every
    /// machine, every run.
    ///
    /// `importPassLocales`, not `importPasses`: the memo is keyed by the identifier the CALLER asked
    /// for ("en-GB"), while the reservation is held under the canonical one the framework handed back
    /// ("en_GB"), and `AssetInventory.release` matches on the raw string (RECON §6). Keying the sweep
    /// off the request would spare nothing and release everything.
    private func keepSet() -> Set<String> {
        Self.keepSet(
            canonical: canonicalLocale?.identifier,
            secondary: secondaryLocale?.identifier,
            importPassLocales: importPassLocales.values.map(\.identifier),
            downloading: Array(downloads.keys)
        )
    }

    /// The keep set as a value: the two dictation languages, every resolved import pass's locale, and
    /// every language whose model is downloading.
    ///
    /// Every argument is a **canonical** identifier — the underscored form the framework stores and
    /// the only form `release(reservedLocale:)` will match (RECON §6).
    ///
    /// In-flight downloads are kept as well: releasing the slot under a running
    /// `downloadAndInstall()` is not a case anything has measured, and the cost of being wrong is a
    /// model that never arrives.
    ///
    /// An empty result is legitimate and load-bearing — it is how `pruneReservations` recognises "no
    /// language is prepared yet" and releases nothing rather than everything.
    static func keepSet(
        canonical: String?,
        secondary: String?,
        importPassLocales: [String],
        downloading: [String]
    ) -> Set<String> {
        var keep = Set([canonical, secondary].compactMap { $0 })
        keep.formUnion(importPassLocales)
        keep.formUnion(downloading)
        return keep
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
        let keep = keepSet()
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
            // SFSpeechErrorDomain Code=11 "Too many allocated locales, 5 maximum". Evict everything
            // outside `keepSet()` and retry. Everything Edict is actually using is spared: the two
            // dictation languages, because evicting `secondaryLocale` is how the language shortcut
            // would start throwing halfway through a session for no reason the user could see, and
            // the resolved import pass locales, because evicting one of those releases the slot
            // under a memo that still says `.ready`. If all five are in the keep set this now
            // throws rather than evicting something in use — which is the honest outcome, and the
            // reason `resolveImportPass` prunes *before* it asks for a sixth.
            Log.stt.warning("reserve(\(canonical.identifier, privacy: .public)) failed, evicting: \(Self.describe(error), privacy: .public)")
            var keep = keepSet()
            keep.insert(canonical.identifier)
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
    /// Only `.dictation` has an engine-wide prepared locale, so `.general` answers `nil` here.
    /// A general-module session always arrives through a resolved `ImportPass`, which carries its
    /// own locale and is asked through `bestAudioFormat(for pass:)`. There used to be a single
    /// app-wide `generalLocale` beside it; it was written by one method that nothing called, so in
    /// production it was permanently nil and this branch permanently returned nil anyway.
    public func bestAudioFormat(for module: TranscriptionModule) async -> AVAudioFormat? {
        guard module == .dictation else { return nil }
        if let cachedFormat { return cachedFormat }
        guard let locale = canonicalLocale else { return nil }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [Self.build(module: .dictation, locale: locale).module]
        )
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
    ///   - explicitLocale: a locale resolved by the caller, overriding `locale`. Used only by the
    ///     dual-pass import, which resolves and prepares its own two locales (see `ImportPass`)
    ///     because neither of the engine's two prepared *dictation* slots can express "this module,
    ///     that language".
    private func beginSession(
        module: TranscriptionModule,
        locale which: UtteranceLocale,
        biasing: [String]?,
        explicitLocale: Locale? = nil,
        explicitFormat: AVAudioFormat? = nil,
        onUpdate: @Sendable @escaping (TranscriptionUpdate) -> Void
    ) async throws -> SpeechSession {
        // Serialised, not raced. A second utterance can arrive while the previous session is still
        // finalizing — RECON §8 puts that window at 0.15–0.53 s, comfortably inside a normal
        // press-pause-press rhythm — and throwing would discard speech the user has ALREADY SPOKEN.
        // So wait, and only give up if the holder is genuinely wedged. `claimSlot` also takes the
        // claim *before* any of the awaits below, which is what stops two presses from both
        // building a session.
        let serial = try await claimSlot(module: module, locale: which)

        // Hoisted above the `do` for one reason: `SpeechAnalyzer(inputSequence:…)` **starts
        // analysing at init** — the app never calls `start()` anywhere, which is why the analyzer is
        // per-utterance — so between that initializer and the `SpeechSession` that owns its teardown
        // there is a window where a throw would drop a *running* analyzer, its results task and a
        // `modelRetention: .processLifetime` model on the floor with nobody left holding a reference
        // to finish them. `prepareToAnalyze(in:)` is the throw that reaches it.
        var halfBuilt: (AsyncStream<AnalyzerInput>.Continuation, SpeechAnalyzer)?

        do {
            // An explicitly-resolved locale has already been reserved and asset-checked by
            // `resolveImportPass`, so the secondary-asset gate below does not apply to it.
            let secondary = explicitLocale == nil && module == .dictation && which == .secondary
            if secondary { try await requireSecondaryAssets() }

            let prepared: Locale? = switch (module, which) {
            // The general module has no engine-wide prepared locale: it is reachable only through a
            // resolved `ImportPass`, which supplies `explicitLocale`. Without one this throws
            // `.notPrepared`, which is the right answer rather than a fallback — see
            // `resolveImportPass` for why substituting a language is never allowed here.
            case (.general, _): nil
            case (.dictation, .primary): canonicalLocale
            case (.dictation, .secondary): secondaryLocale
            }
            guard let locale = explicitLocale ?? prepared else { throw SpeechEngineError.notPrepared }
            var format = explicitFormat
            if format == nil {
                format = secondary
                    ? await bestAudioFormat(secondary: true)
                    : await bestAudioFormat(for: module)
            }
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
            halfBuilt = (continuation, analyzer)
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
            // From here the session owns the teardown, so the catch below must not do it as well:
            // `abort()` would be called on an analyzer the caller is about to drive.
            halfBuilt = nil
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
            let why = "begin failed: \(Self.describe(error))"
            guard let (continuation, analyzer) = halfBuilt else {
                // Nothing was built, so there is nothing to tear down and no await to get in the
                // way: hand the slot straight back.
                releaseSlot(serial: serial, reason: why)
                throw error
            }

            Log.stt.warning("""
                slot #\(serial, privacy: .public) tearing down a half-built analyzer: \
                \(Self.describe(error), privacy: .public)
                """)
            // Finishing the input stream comes first, in the order `SpeechSession.abort()` uses and
            // RECON §5 verified. The order is not cosmetic — finishing the stream is what keeps the
            // cancellation below off RECON §3's `finalize(through:)` deadlock, which blocks for ever
            // while the stream is still open — and it is synchronous, so it costs the slot nothing.
            continuation.finish()
            // The remaining half of the teardown is an `await`, and the slot goes back *before* it.
            // See `abandonHalfBuilt` for what that buys and what it costs.
            await abandonHalfBuilt(serial: serial, reason: why) {
                // `cancelAndFinishNow` discards the pending final, which is exactly right here:
                // this utterance has already failed and there is nothing to salvage from it.
                await analyzer.cancelAndFinishNow()
            }
            throw error
        }
    }

    /// Hand the analyzer slot back, and only *then* await the teardown of a half-built analyzer.
    ///
    /// The order is the entire content of this function, which is why it is a function rather than
    /// two lines at the call site. `SpeechAnalyzer(inputSequence:…)` starts analysing at init, so a
    /// throw from `prepareToAnalyze(in:)` leaves a *running* analyzer that has to be finished — and
    /// `cancelAndFinishNow()` on an analyzer whose `prepareToAnalyze` has just thrown is a state
    /// nothing on this machine has measured. If it never returned while the slot was still held,
    /// `slotHolder` would stay set with `activeSession` still nil, and `claimSlot`'s stale-holder
    /// reclaim requires a **non-nil** `activeSession` — so it could never fire, and every later
    /// press would fail with `.sessionAlreadyRunning` for the rest of the process.
    ///
    /// Releasing first costs two things, both smaller than that:
    ///
    /// * A following press can claim the slot and build its own analyzer while this doomed one is
    ///   still cancelling, so two analyzers can be alive for that moment. RECON §3 forbids
    ///   *reusing* an analyzer, not having two, and the doomed one is fed nothing — its stream is
    ///   already finished — and is reachable from nowhere.
    /// * `beginSession` itself can still hang inside the teardown, which loses the one press that
    ///   failed. That is a bounded loss where the alternative was the whole process.
    ///
    /// Amendment 33 is untouched: the claim is still taken before any `await` in `beginSession`.
    ///
    /// `teardown` is a parameter rather than the `cancelAndFinishNow()` call itself so that the
    /// ordering has a test. Nothing can reach this path from a test as the code stands —
    /// `beginSession` is private and every public entry point derives the format from the module
    /// itself, so nothing can hand `prepareToAnalyze(in:)` something it would reject — and a real
    /// analyzer cannot be made to hang on demand either. A stand-in teardown is the only observable
    /// surface this ordering has.
    func abandonHalfBuilt(
        serial: UInt64,
        reason: String,
        teardown: @Sendable () async -> Void
    ) async {
        releaseSlot(serial: serial, reason: reason)
        await teardown()
    }

    // MARK: - The analyzer slot

    /// Take the analyzer slot, waiting for the current holder if there is one.
    ///
    /// Returns the serial the caller must release with. Throws `.sessionAlreadyRunning` only when
    /// the holder is still there after `slotWaitCeiling` — which, with `releaseSlot` wired to the
    /// session's terminal transition, means a genuinely stuck analyzer rather than the ordinary
    /// press-pause-press rhythm.
    ///
    /// `internal` rather than `private` for one reason: `abandonHalfBuilt`'s ordering can only be
    /// observed by a test that holds a real claim, and this is the only way to take one without a
    /// real analyzer and a real model on disk.
    func claimSlot(module: TranscriptionModule, locale which: UtteranceLocale) async throws -> UInt64 {
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

        // A download of *this* language is already running from an earlier press. Do not await it —
        // the user is holding a key right now and a 31 s stall inside an utterance is its own
        // failure. Keyed by identifier, so an import downloading a third language no longer makes
        // this sentence appear about a language nobody asked for.
        if let running = downloads[locale.identifier], !running.isCancelled {
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
        startDownload(request, for: locale)
        throw SpeechEngineError.assetInstallFailed(
            "Downloading the \(Self.languageName(locale)) speech model. Try again in a moment."
        )
    }

    /// Park one `downloadAndInstall()` under its own language's key.
    private func startDownload(_ request: AssetInstallationRequest, for locale: Locale) {
        let identifier = locale.identifier
        downloads[identifier] = Task { [weak self] in
            do {
                try await request.downloadAndInstall()
                await self?.downloadFinished(identifier: identifier, error: nil)
            } catch {
                await self?.downloadFinished(identifier: identifier, error: error)
            }
        }
    }

    /// Record the outcome of one download **against the language it was for**.
    ///
    /// The identifier parameter is the whole point. This used to take only an error and write
    /// `secondaryAssetsReady = true` unconditionally, so on a machine where the secondary dictation
    /// language is not installed, an import's successful download of a *third* language reported the
    /// secondary language as ready — and `requireSecondaryAssets()`, whose own comment calls itself
    /// "the one place where falling back would be indefensible", then let an utterance run against a
    /// model that is not on disk.
    ///
    /// `internal`, not `private`, and for the reason the audit gave: there is no seam for faking a
    /// `downloadAndInstall()`, so the only way to test which language a completion is applied to is
    /// to call this directly. `EngineRecoveryTests` does.
    func downloadFinished(identifier: String, error: Error?) {
        downloads[identifier] = nil
        // Which language actually finished. This was hardcoded `true` while the surrounding branches
        // were being written, which made every `else` unreachable and — far worse — made ANY
        // completed import download mark the live secondary language as ready: a French import
        // finishing would let the next Shift-Right-Option build an Indonesian analyzer against a
        // model that is not on disk, past the one gate (`requireSecondaryAssets`) whose comment says
        // falling back there would be indefensible.
        let isSecondary = identifier == secondaryLocale?.identifier
        if let error {
            let why = Self.describe(error)
            if isSecondary {
                secondaryAssetsReady = false
                secondaryModelState = .unavailable(why)
            } else {
                importModelStates[identifier] = .unavailable(why)
            }
            Log.stt.error("""
                asset install failed for \(identifier, privacy: .public): \(why, privacy: .public)
                """)
        } else {
            if isSecondary {
                secondaryAssetsReady = true
                secondaryModelState = .ready
            } else {
                importModelStates[identifier] = .ready
            }
            Log.stt.info("assets installed for \(identifier, privacy: .public)")
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
    /// module transcribed an 18.8 s Indonesian clip word-perfect at 34.5x realtime.
    /// `resolveImportPass` therefore falls back to the dictation module for those 9 languages rather
    /// than refusing the file. One measured wrinkle worth knowing: on
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

    /// Whether the assets for the module Edict would *actually build* for this locale are on disk.
    ///
    /// `internal`, and for a reason the last round paid for: a test has to be able to decide "skip"
    /// **before** it asks `resolveImportPass` for a language, because `resolveImportPass` answers a
    /// missing model by calling `downloadAndInstall()` from a detached task — minutes of the user's
    /// bandwidth, begun before the `try #require` on the next line of the test can fire. Measured
    /// while writing this: the *dictation* models for `en-GB`, `en-AU` and `en-CA` are all missing on
    /// this machine, so for the three locales the gated reservation suite uses, the general-module
    /// asset check is the only thing standing between that suite and a real download.
    ///
    /// It goes through `build` rather than constructing a probe of its own because a hand-rolled
    /// probe lies. RECON's second `AssetInventory` trap: installed state depends on
    /// `attributeOptions`, and `fr-FR` on the general module reads **installed** with `[]` and
    /// **missing** with the `[.transcriptionConfidence, .audioTimeRange]` this app always requests.
    /// Only a module built with the real options can answer this question.
    ///
    /// **Asking is not free.** RECON §6 measured `assetInstallationRequest(supporting:)` reserving
    /// the locale it is asked about as a side effect — that is what silently consumed a `ja-JP` slot
    /// during probing — so a caller must prune afterwards. And "cannot tell" answers `false`: for a
    /// skip decision an unanswerable check and a missing model belong on the same branch, and the
    /// branch that does less is the safe one.
    static func assetsInstalled(module: TranscriptionModule, locale: Locale) async -> Bool {
        do {
            let probe = build(module: module, locale: locale).module
            return try await AssetInventory.assetInstallationRequest(supporting: [probe]) == nil
        } catch {
            Log.stt.warning("""
                assets for \(locale.identifier, privacy: .public) on \
                \(module.rawValue, privacy: .public) could not be checked: \
                \(Self.describe(error), privacy: .public)
                """)
            return false
        }
    }

    // MARK: - Import reservations

    /// macOS allows five concurrent locale reservations, they **persist across process launches**
    /// keyed by bundle identifier, and the sixth throws `SFSpeechErrorDomain` Code=11 (RECON §6).
    private static let reservationSlots = 5

    /// How many import languages may hold a reservation at once, the one being resolved included.
    ///
    /// One slot beyond the dictation languages is deliberately left unused, and it is not slack:
    ///
    /// * RECON §6 measured `assetInstallationRequest(supporting:)` **reserving the locale it is asked
    ///   about as a side effect** — that is what silently consumed a `ja-JP` slot during probing — so
    ///   the availability check for a new language needs a free slot before Edict asks for one.
    /// * A dictation language change re-reserves through `prepare` / `prepareSecondary`, and with all
    ///   five slots inside the keep set the Code=11 eviction ladder has nothing it is allowed to
    ///   evict and the language change fails outright.
    ///
    /// With both dictation languages prepared this comes out at 2, which is exactly what a dual-pass
    /// import needs: pass A is resolved and kept, then pass B's resolution prunes to one, keeps A —
    /// the most recent — and takes a slot for itself.
    private var importReservationBudget: Int {
        let live = (canonicalLocale == nil ? 0 : 1) + (secondaryLocale == nil ? 0 : 1)
        return max(1, Self.reservationSlots - live - 1)
    }

    /// Drop the least-recently-used import passes, and release the reservations behind them.
    ///
    /// Called at the top of `resolveImportPass` for every language it has to resolve, rather than
    /// only after a failure. Nothing used to prune these at all: every import language ever resolved
    /// held a slot for the life of the process and beyond, so a fourth language met a Code=11 whose
    /// eviction ladder had nothing evictable left.
    ///
    /// The memo and the reservation are dropped in the same step, in that order, because the
    /// dangerous state is a memoised `.ready` pass on an unreserved locale — the framework logs
    /// "Cannot use modules with unallocated locales … This will be an error in a future release!"
    /// and today still transcribes (RECON §6), which is precisely why nothing would notice.
    ///
    /// Called only from `resolveImportPass`, which the import path calls between items and never
    /// while a `DualPassImporter` is mid-file. That is what makes it safe for
    /// `transcribe(input:pass:)` to look its locale up by identifier: a pass in use cannot have its
    /// memo pulled out from under it, and both of a dual pass's languages fit inside the budget.
    private func pruneImportPasses(reserving requested: String) async {
        // Room for the one about to be taken: `requested` is never already in the order here, because
        // a memoised language returns from `resolveImportPass` before this is called.
        let dropped = Self.memosToEvict(
            order: importPassOrder,
            budget: max(0, importReservationBudget - 1)
        )
        for identifier in dropped {
            importPasses[identifier] = nil
            importPassLocales[identifier] = nil
            importPassFormats[identifier] = nil
        }
        importPassOrder.removeFirst(dropped.count)

        // Then release anything the framework still holds that Edict no longer depends on. This is a
        // release-what-is-not-kept pass rather than a release-what-was-evicted one on purpose: the
        // general-module availability check reserves a locale it may then decline to use, so slots
        // exist that were never memoised by anything and only a keep-set sweep can see them.
        let keep = keepSet()
        guard !keep.isEmpty else { return }
        var released: [String] = []
        for reserved in await AssetInventory.reservedLocales where !keep.contains(reserved.identifier) {
            // Only ever a `Locale` taken straight from `reservedLocales` — RECON §6: `release`
            // matches on the raw identifier string, so a rebuilt `Locale(identifier: "id-ID")`
            // returns false against a stored `"id_ID"` and leaks the slot for every future launch.
            if await AssetInventory.release(reservedLocale: reserved) {
                released.append(reserved.identifier)
            } else {
                Log.stt.error("release(\(reserved.identifier, privacy: .public)) refused")
            }
        }
        if !released.isEmpty {
            Log.stt.notice("""
                import pass \(requested, privacy: .public): released \
                \(released.joined(separator: ","), privacy: .public)
                """)
        }
    }

    /// Which memos must go for `order` to fit in `budget`, least recently used first.
    ///
    /// A value-returning function rather than an `if` wrapped around the eviction loop, because that
    /// `if` is what shipped as `if false, importPassOrder.count > budget {` — a literal `false`
    /// swiftc accepts in silence, dead-coding the whole eviction while the only tests that could see
    /// it sat in the gated suite that cannot run here. There is no branch left at the call site to
    /// disable, and what replaced it is pinned by `KeepSetTests`: that an order which fits loses
    /// nothing, and that the ones dropped are the **oldest**, since evicting the newest would release
    /// the language the caller is resolving right now.
    ///
    /// The `guard` is belt-and-braces rather than the boundary — `prefix(0)` is already empty when
    /// the order exactly fills the budget — but it keeps `order.count - budget` from ever being
    /// negative, which `prefix(_:)` traps on rather than clamping.
    static func memosToEvict(order: [String], budget: Int) -> [String] {
        guard order.count > budget else { return [] }
        return Array(order.prefix(order.count - budget))
    }

    /// Move a requested identifier to the most-recently-used end of the eviction order.
    private func touchImportPass(_ identifier: String) {
        guard importPassOrder.last != identifier else { return }
        importPassOrder.removeAll { $0 == identifier }
        importPassOrder.append(identifier)
    }

    // MARK: - Dual-pass import passes

    /// Resolve, reserve and asset-check one language for a file import.
    ///
    /// Memoised by requested identifier, so the dual pass asks twice per file and pays for it once
    /// per language — up to `importReservationBudget` languages at a time, after which the
    /// least-recently-used one is dropped and re-resolved if it comes back. The module choice is the
    /// measured one: `SpeechTranscriber` halves the word error and runs 4.4x faster on a whole file,
    /// asked *per language* rather than once for the app.
    ///
    /// This can come back `.unavailable`, and must be allowed to. A fallback between the two
    /// *modules* of one language is always safe; a fallback to a different **language** never is,
    /// because transcribing Indonesian with the English model does not fail — it returns fluent
    /// English nonsense. A missing model kicks off its own download and says so, exactly as the live
    /// secondary-language path does.
    public func resolveImportPass(
        preferGeneral: Bool,
        localeIdentifier: String
    ) async -> ImportPassResolution {
        if let cached = importPasses[localeIdentifier] {
            // Touched on the cheap path too, or the language a queue is actually running would age
            // out of the eviction order while it was still in use.
            touchImportPass(localeIdentifier)
            return .ready(cached)
        }
        await pruneImportPasses(reserving: localeIdentifier)

        func remember(_ pass: ImportPass, _ locale: Locale, _ why: String) -> ImportPassResolution {
            importPasses[localeIdentifier] = pass
            importPassLocales[localeIdentifier] = locale
            touchImportPass(localeIdentifier)
            Log.stt.info("""
                import pass \(localeIdentifier, privacy: .public): \
                \(pass.module.rawValue, privacy: .public) \(locale.identifier, privacy: .public) \
                — \(why, privacy: .public)
                """)
            return .ready(pass)
        }

        // The general module first where it is wanted and covers the language. Asset state is checked
        // rather than downloaded: an import the user is watching must not stall on a model download
        // when a supported model for the same language is already on disk.
        if preferGeneral,
           let canonical = await SpeechTranscriber.supportedLocale(
               equivalentTo: Locale(identifier: localeIdentifier)
           ) {
            do {
                try await reserve(canonical)
                let probe = Self.build(module: .general, locale: canonical).module
                // Falling through from here leaves this reservation held with no memo behind it —
                // usually harmless, because the dictation branch below reserves the same identifier
                // for the same language, and otherwise released by the next resolution's prune,
                // which sweeps everything outside the keep set rather than only what it evicted.
                if try await AssetInventory.assetInstallationRequest(supporting: [probe]) == nil {
                    return remember(
                        ImportPass(
                            module: .general,
                            requestedIdentifier: localeIdentifier,
                            canonicalIdentifier: canonical.identifier
                        ),
                        canonical,
                        "measured 4.2 % word error against 10.1 % on this machine"
                    )
                }
            } catch {
                Log.stt.warning("""
                    import pass \(localeIdentifier, privacy: .public): general module unavailable — \
                    \(Self.describe(error), privacy: .public)
                    """)
            }
        }

        // The dictation module is the fallback and the only route for the 9 locales the general
        // module does not cover, Indonesian among them (RECON amendment 7).
        guard let canonical = await DictationTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeIdentifier)
        ) else {
            return .unavailable(
                "\(Self.languageName(Locale(identifier: localeIdentifier))) is not one of the languages "
                    + "this Mac can transcribe."
            )
        }
        do {
            try await reserve(canonical)
        } catch {
            return .unavailable(
                "\(Self.languageName(canonical)) could not be prepared: \(Self.describe(error))"
            )
        }

        let probe = Self.makeModule(locale: canonical)
        let pending: AssetInstallationRequest?
        do {
            // Gated on the request being nil, never on `AssetInventory.status` — RECON amendment 6
            // measured that reporting `.supported` for an installed-but-unreserved locale, which
            // would trigger a pointless download.
            pending = try await AssetInventory.assetInstallationRequest(supporting: [probe])
        } catch {
            return .unavailable(
                "The \(Self.languageName(canonical)) speech model could not be checked: \(Self.describe(error))"
            )
        }
        guard let request = pending else {
            return remember(
                ImportPass(
                    module: .dictation,
                    requestedIdentifier: localeIdentifier,
                    canonicalIdentifier: canonical.identifier
                ),
                canonical,
                "the transcription model does not cover this locale, or its assets are missing"
            )
        }

        // A previous attempt's download has already finished, and failed. Report *that* rather than
        // the download sentence again: repeating "Try this file again in a moment" for ever, with the
        // real reason only in the log, is what this language's own state exists to prevent. Cleared
        // as it is read, so the attempt after this one starts a fresh download — the usual cause is
        // the network, and "try again" has to mean something.
        if case .unavailable(let why) = importModelStates[canonical.identifier] {
            importModelStates[canonical.identifier] = nil
            return .unavailable(
                "The \(Self.languageName(canonical)) speech model could not be installed: \(why)"
            )
        }

        // Not awaited: the caller has a queue on screen and a model download is minutes, not
        // milliseconds. Start it, say so, and let the next import find it installed. Keyed by this
        // language, so a second import language downloads alongside the first instead of being
        // silently skipped because one shared slot was occupied — and so finishing it can never
        // report the *secondary dictation* language as installed.
        if downloads[canonical.identifier] == nil {
            startDownload(request, for: canonical)
        }
        return .unavailable(
            "Downloading the \(Self.languageName(canonical)) speech model. Try this file again in a moment."
        )
    }

    /// The audio format a resolved pass wants. Asked per pass, never assumed shared: the two passes
    /// of a dual-pass import run different modules built for different locales, and
    /// `availableCompatibleAudioFormats` is a property of the module.
    public func bestAudioFormat(for pass: ImportPass) async -> AVAudioFormat? {
        if let cached = importPassFormats[pass.requestedIdentifier] { return cached }
        guard let locale = importPassLocales[pass.requestedIdentifier] else { return nil }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [Self.build(module: pass.module, locale: locale).module]
        )
        if let format { importPassFormats[pass.requestedIdentifier] = format }
        return format
    }

    /// Run one section of a dual-pass import through one resolved pass.
    ///
    /// Goes through the same slot as everything else, which is the whole point: `SpeechEngine` holds
    /// exactly one analyzer at a time, so the two passes over a section are serialised whether the
    /// caller asks for that or not. See `DualPassImporter` for the measurement behind not trying to
    /// beat it.
    public func transcribe(
        input: AsyncStream<AnalyzerInput>,
        pass: ImportPass,
        biasing: [String] = [],
        onUpdate: @Sendable @escaping (TranscriptionUpdate) -> Void
    ) async throws -> TranscriptionOutcome {
        guard let locale = importPassLocales[pass.requestedIdentifier] else {
            throw SpeechEngineError.notPrepared
        }
        let session = try await beginSession(
            module: pass.module,
            locale: .primary,
            biasing: biasing,
            explicitLocale: locale,
            explicitFormat: await bestAudioFormat(for: pass),
            onUpdate: onUpdate
        )
        for await item in input {
            if session.isTerminated { break }
            session.feed(item)
        }
        if session.isTerminated {
            Log.stt.info("import pass aborted")
            throw CancellationError()
        }
        return try await session.finishAndCommit()
    }

    // MARK: - Waiting out a live dictation

    /// How long to wait before asking for the analyzer slot again, and how many times.
    ///
    /// 10 s in total, which is the ladder `ImportQueue` arrived at for the same reason: a file
    /// landing while the user is mid-dictation is refused with `.sessionAlreadyRunning` and resolves
    /// itself in a second or two, so failing the file for it would be a bad answer to a temporary
    /// state. Public so both import routes share one policy instead of two that drift.
    public static let slotBusyRetry = Duration.milliseconds(250)
    public static let slotBusyAttempts = 40

    /// Run `body`, waiting out `.sessionAlreadyRunning` instead of failing on it.
    ///
    /// Lives here, on the engine, because the two import routes reach the engine differently and both
    /// need it: `ImportQueue` comes in through a closure `Environment` and cannot touch
    /// `SpeechEngine` at all, while `DictationController.runDualPass` holds it directly and used to
    /// call `transcribe(input:pass:)` bare — so a user holding the dictation key during a dual-pass
    /// import lost roughly one section per 3 s of hold, silently, because `DualPassImporter` catches
    /// a failed pass and logs it.
    ///
    /// **The retry is only safe because the throw lands before the stream is touched.** `claimSlot`
    /// runs first inside `beginSession`, ahead of the `for await item in input` loop, so a refused
    /// attempt has consumed no elements — and an `AsyncStream` has exactly one consumer, so a retry
    /// that had already drained part of it would silently transcribe the tail of the audio. Do not
    /// widen this to wrap anything that reads the stream first.
    ///
    /// - Parameter keepWaiting: asked before each sleep. Return false to give up early — the caller's
    ///   own cancellation, which the engine cannot see.
    /// - Parameter onWait: called once, on the first refusal, for the caller's log line.
    public static func waitingForSlot<T: Sendable>(
        attempts: Int = SpeechEngine.slotBusyAttempts,
        delay: Duration = SpeechEngine.slotBusyRetry,
        // The caller's isolation is inherited rather than crossed. Without this, `body` is a
        // non-`Sendable` closure being handed from an isolated context to a `nonisolated static`
        // one, which Swift 6 rejects outright — and the alternatives are worse: marking `body`
        // `@Sendable` would force every caller to launder the actor it is calling.
        isolation: isolated (any Actor)? = #isolation,
        keepWaiting: @Sendable () async -> Bool = { true },
        onWait: @Sendable () -> Void = {},
        body: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body()
            } catch SpeechEngineError.sessionAlreadyRunning {
                attempt += 1
                guard attempt < attempts, await keepWaiting() else {
                    throw SpeechEngineError.sessionAlreadyRunning
                }
                if attempt == 1 { onWait() }
                try await Task.sleep(for: delay)
            }
        }
    }

    /// `transcribe(input:pass:)`, waiting out a live dictation rather than losing the section.
    ///
    /// The retrying variant is the one every import pass should use; the bare one is kept for callers
    /// that own their own ladder. See `waitingForSlot` for why re-entering with the same stream is
    /// safe.
    public func transcribeWaitingForSlot(
        input: AsyncStream<AnalyzerInput>,
        pass: ImportPass,
        biasing: [String] = [],
        onUpdate: @Sendable @escaping (TranscriptionUpdate) -> Void
    ) async throws -> TranscriptionOutcome {
        try await Self.waitingForSlot(
            onWait: {
                Log.stt.info("import pass waiting: the engine is busy with a live dictation")
            }
        ) {
            try await transcribe(input: input, pass: pass, biasing: biasing, onUpdate: onUpdate)
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
