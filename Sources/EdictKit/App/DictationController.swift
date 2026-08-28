import AVFoundation
import AppKit
import Foundation
import Observation
import Speech
import Synchronization

// MARK: - DictationController

/// The seam that turns five independent subsystems into an application.
///
/// It owns exactly one sequence and nothing else:
///
///     hotkey down → read the dictionary → microphone → buffer audio
///                 → language window closes → engine session → stream the buffered audio
///                 → hotkey up → finalize → Corrector.apply → TextInjector.inject
///                 → HistoryStore.append → DictionaryStore.recordHits
///
/// Four invariants govern everything below, and each one is a bug that has already been paid for
/// somewhere in `RECON.md` or in the user's own transcript history:
///
/// 1. **The dictionary is read at key-down and never again.** `AnalysisContext` can only be handed
///    to `SpeechAnalyzer.init`; `setContext(_:)` mid-stream is a measured silent no-op (RECON §2).
///    Key-down is therefore the *only* moment biasing can be chosen, and it is also the moment the
///    ~65 ms + ~1.5 ms/term setup cost is free, because it hides behind the user's speech onset.
/// 4. **The language is chosen when the modifier window closes, not when the hold arms.** The
///    microphone opens first and the audio buffers; only then is an analyzer built. Deciding at arm
///    time meant a `⇧` that landed 130 ms after the dictation key was invisible, and the cost of
///    missing it is not a missing feature — the English model handed Indonesian speech returns
///    fluent English proper nouns, which is what "the model invents names" actually was. Six
///    consecutive dictations in the user's history show it, and every garbage one is `en-US`.
/// 2. **The microphone is never left running.** Every exit from `run(_:)` — success, throw, cancel,
///    or a hotkey monitor that lost its tap mid-hold — passes through the same unconditional
///    `capture.stop()`. There is no `defer` because `defer` cannot `await`.
/// 3. **Only committed text is injected.** Volatile results are materially worse and frequently
///    wrong mid-word (RECON §4), so they reach the HUD and nothing else.
///
/// Isolation: `@MainActor`. This object does no audio work — it starts actors, awaits them, and
/// publishes to `AppModel`. The real-time paths (the tap block, the C event-tap callback) live
/// inside `AudioCapture` and `HotkeyMonitor` and never touch this class.
@MainActor
public final class DictationController {

    /// What started the utterance. It decides whether injection is even meaningful: text dictated
    /// from Edict's own window has no foreign cursor to land in.
    public enum Origin: Sendable, Hashable {
        case hotkey
        case app
    }

    // MARK: Engine actors

    private let engine = SpeechEngine()
    private let capture = AudioCapture()
    private let injector = TextInjector()
    private let hotkey: HotkeyMonitor

    /// The on-device text refiner, shared with `AppModel.refinement` so both use the same pre-warmed
    /// sessions. Only touched when `Settings.refineBeforeInsert` is on.
    private let refiner: TextRefiner

    /// Reads and replaces a selection in *another* app, for the refine popup.
    ///
    /// Built on this controller's own `injector`, not a second one. `SelectionBridge` reads and writes
    /// `TextInjector`'s learned per-bundle policy map, so a separate injector would mean an app
    /// demoted to paste-only by a refinement stayed AX-first for dictation and vice versa — two
    /// halves of one machine learning different things about the same app.
    private let selectionBridge: SelectionBridge

    /// The refine-popup gesture, end to end. Lives here because it needs three things this class
    /// already owns: the hotkey monitor (for the chord *and* for the tap that swallows the popup's
    /// digits), the shared refiner, and the injector behind `selectionBridge`.
    private let refineGesture: RefineGestureController

    /// Handed to the views so `LevelMeter` can poll `levelSnapshot` synchronously at 60 Hz without
    /// an actor hop. That property is `nonisolated` and `Mutex`-backed precisely for this.
    public var levelSource: any LevelSource { capture }

    // MARK: Stores

    private let settings: Settings
    private let dictionary: DictionaryStore
    private let history: HistoryStore
    private let permissions: Permissions

    private weak var model: AppModel?

    // MARK: Runtime state

    private var utterance: Utterance?
    private var hotkeyEventsTask: Task<Void, Never>?
    private var hotkeyDiagnosticsTask: Task<Void, Never>?
    private var hotkeyGesturesTask: Task<Void, Never>?
    private var hotkeyCapturedKeysTask: Task<Void, Never>?
    private var permissionsTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?

    /// Cached so key-down does not pay an actor round-trip for a value that changes only when the
    /// locale changes.
    private var analyzerFormat: AVAudioFormat?
    /// The same answer for the secondary language. Held separately rather than reused: the format is a
    /// property of the module, which is built per locale, and `AudioCapture`'s converter is configured
    /// from it. They agree in practice; assuming so is not the same as checking.
    private var secondaryAnalyzerFormat: AVAudioFormat?

    /// Whether the language may be chosen *after* the microphone has already opened.
    ///
    /// The deferred decision — the whole point of the modifier window — needs the two prepared
    /// languages to accept the same audio format, because `AudioCapture`'s converter is configured
    /// at `start()` and the buffered head of the utterance is already in that format by the time the
    /// language is known. Both come back 1 ch / 16 kHz / Int16 / interleaved on this machine, but
    /// `availableCompatibleAudioFormats` is a property of the *module*, which is built per locale, so
    /// this is checked rather than assumed (see `SpeechEngine.bestAudioFormat(secondary:)`, which
    /// makes the same argument for asking twice).
    ///
    /// `false` restores the old arm-time contract exactly: the provisional reading becomes the
    /// decision at key-down and nothing waits. A wrong language is a bad transcript; a mismatched
    /// converter is silence.
    private var localeDecisionDeferrable = true

    private var appliedHotkey: HotkeyChoice?
    private var appliedAlternateModifier: HotkeyModifier?
    /// The refine chord currently bound into the tap, or `nil` when the feature is off. Tracked
    /// separately from the setting for the same reason as `appliedAlternateModifier`: a change to it
    /// is a rebind even when the dictation key has not moved.
    private var appliedRefineChord: RefineChord?
    private var appliedLocale: String?
    /// The secondary identifier the engine currently holds a reservation for, or `nil` when the
    /// shortcut is off or its locale could not be prepared.
    private var appliedSecondaryLocale: String?

    /// Press-to-start / press-to-stop bookkeeping for `Settings.pushToTalk == false`.
    private var toggleLatched = false

    private var didBootstrap = false

    /// Which module ran for each import language, keyed by `Settings.localeKey`.
    ///
    /// Keyed by language rather than kept as one "last module" because a queue can now hold files in
    /// different languages, and the two languages can resolve to *different* modules — `en-US` to
    /// `SpeechTranscriber`, `id-ID` to `DictationTranscriber`, since Indonesian is one of the nine
    /// locales the general module does not cover. One shared slot would attribute a finished
    /// Indonesian transcript to whichever model the file after it happened to use.
    private var importModuleByLocale: [String: TranscriptionModule] = [:]
    /// The module of the most recent import, for the one case where the per-locale answer is missing
    /// (a dual pass whose winning section cannot be matched back to a candidate).
    private var lastImportModule: TranscriptionModule = .dictation

    // MARK: Tuning

    /// Hard ceiling on one utterance.
    ///
    /// `HotkeyMonitor` guarantees a `.released` for every `.pressed`, but that guarantee lives in
    /// another process's event stream and RECON §12 is explicit that the window server can kill a
    /// tap without saying so. If the release genuinely never arrives, the failure mode without this
    /// is "Edict recorded for six hours". Three minutes is far past any real dictation and still
    /// commits rather than discards, because by then the user has certainly spoken.
    private static let maxUtteranceDuration: Duration = .seconds(180)

    /// Edict's own bundle id. Injecting into ourselves would type the transcript into the history
    /// search field.
    private static let ownBundleID = Bundle.main.bundleIdentifier ?? "com.edict.app"

    // MARK: Init

    public init(
        settings: Settings = .shared,
        dictionary: DictionaryStore = .shared,
        history: HistoryStore = .shared,
        permissions: Permissions = .shared,
        refiner: TextRefiner = TextRefiner()
    ) {
        self.settings = settings
        self.dictionary = dictionary
        self.history = history
        self.permissions = permissions
        self.refiner = refiner
        let hotkey = HotkeyMonitor()
        self.hotkey = hotkey
        let bridge = SelectionBridge(injector: injector)
        self.selectionBridge = bridge
        self.refineGesture = RefineGestureController(
            popup: RefinePopupController(),
            selection: bridge,
            refiner: refiner,
            capture: hotkey,
            settings: settings
        )
    }

    func attach(model: AppModel) {
        self.model = model
    }

    // MARK: - Bootstrap

    /// Launch sequence, ordered so that nothing expensive happens before first paint.
    ///
    /// Synchronous here: the disk stores (small JSON files), the permission probe (non-prompting),
    /// and the event tap. Deferred to `prewarmTask`: locale reservation, asset check, the speech
    /// model cold load (~50 ms, RECON §3) and the CoreGraphics/AX cold start (55–90 ms, once
    /// measured at 1422 ms — RECON §26). Those four are exactly the things that would otherwise be
    /// paid on the user's first hotkey press.
    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        do {
            try AppPaths.ensureSupportDirectory()
        } catch {
            Log.engine.error("support directory unavailable: \(error.localizedDescription, privacy: .public)")
        }

        do { try dictionary.load() } catch {
            Log.data.error("dictionary load failed: \(error.localizedDescription, privacy: .public)")
        }
        do { try history.load() } catch {
            Log.data.error("history load failed: \(error.localizedDescription, privacy: .public)")
        }
        // The dictionary file is a documented plain-file interface, so an external edit must show up.
        dictionary.startWatchingFile()

        permissions.refresh()
        observePermissions()
        observeSettings()

        startHotkey()

        // Everything below is optimisation. It runs after this method returns, at background
        // priority, so the first window paints on the frame it was going to paint on anyway.
        prewarmTask = Task { [weak self] in
            await self?.prewarm()
        }
    }

    private func prewarm() async {
        await prepareEngine(localeIdentifier: settings.localeIdentifier)
        // Reserve the second language now, not at key-down. Reservations persist across launches, are
        // keyed to the bundle id, and cap at 5; doing this inside an utterance would put a reservation
        // — and possibly an eviction round — in front of audio the user is already speaking.
        await prepareSecondary()

        // RECON §26: retain a CGEventSource, build and discard one CGEvent, touch AXIsProcessTrusted
        // and do one throwaway system-wide AX read. Without this the *first* dictation of a session
        // pays the whole window-server + TCC bootstrap while the user watches.
        await injector.prewarm()
        // Same reasoning as the injector's: the bridge's first `CGEventSource` costs 44–50 ms and the
        // main-actor keyboard-layout scan has to happen off the popup's hot path (RECON §26, §36).
        // Cheap and idempotent — and skipped entirely at no cost if the popup is never used.
        await selectionBridge.prewarm()
        permissions.prewarm()

        // RECON §3: pays the cold model load once, so every later utterance costs ~2.5 ms of setup.
        await engine.warmUp()

        if settings.prewarmMicrophone {
            await startMicrophonePrewarm()
        }
        Log.engine.info("pre-warm complete")
    }

    private func prepareEngine(localeIdentifier: String) async {
        appliedLocale = localeIdentifier
        do {
            try await engine.prepare(localeIdentifier: localeIdentifier)
            analyzerFormat = await engine.bestAudioFormat()
            let state = await engine.modelState
            model?.apply(modelState: state)
            if analyzerFormat == nil {
                Log.engine.error("no analyzer-compatible audio format for \(localeIdentifier, privacy: .public)")
            }
        } catch {
            let message = Self.describe(error)
            model?.apply(modelState: .unavailable(message))
            Log.engine.error("engine prepare failed: \(message, privacy: .public)")
        }
    }

    /// Resolve, validate and reserve the secondary dictation language.
    ///
    /// Validation happens here rather than in `Settings` because this is where the framework's own
    /// answer is available: a stale identifier — one an OS update dropped, or a hand-written
    /// `defaults write` — would otherwise make the modifier throw on every press with nothing in the
    /// UI to fix. `reconcileSecondaryLocale` resets it, or turns the shortcut off, and the primary
    /// language keeps working either way.
    private func prepareSecondary() async {
        let supported = await engine.supportedLocales.map(\.identifier)
        settings.reconcileSecondaryLocale(supportedIdentifiers: supported)

        if let identifier = settings.effectiveSecondaryLocaleIdentifier {
            if identifier != appliedSecondaryLocale {
                do {
                    try await engine.prepareSecondary(localeIdentifier: identifier)
                    appliedSecondaryLocale = identifier
                    secondaryAnalyzerFormat = await engine.bestAudioFormat(secondary: true)
                    model?.apply(secondaryLocaleReady: true)
                } catch {
                    appliedSecondaryLocale = nil
                    secondaryAnalyzerFormat = nil
                    model?.apply(secondaryLocaleReady: false)
                    Log.engine.error("""
                        secondary locale \(identifier, privacy: .public) unavailable: \
                        \(Self.describe(error), privacy: .public)
                        """)
                }
            }
        } else if appliedSecondaryLocale != nil {
            await engine.clearSecondary()
            appliedSecondaryLocale = nil
            secondaryAnalyzerFormat = nil
            model?.apply(secondaryLocaleReady: false)
        } else {
            model?.apply(secondaryLocaleReady: false)
        }

        refreshLocaleDecisionDeferrable()

        // Hand back anything Edict is no longer using. Unconditional, and specifically NOT guarded on
        // having just prepared something: the leak this closes is the one where a *previous* launch
        // reserved a locale the current settings no longer want, which no amount of in-process
        // bookkeeping can see. Reservations persist across launches and cap at 5.
        await engine.pruneReservations()

        // Logged at `notice` so it survives in the system log: a reservation leak is invisible until
        // reservation starts failing outright, and RECON's probe leaked slots during exploration.
        let reserved = await engine.reservedLocaleIdentifiers()
        Log.engine.notice("reserved locales: \(reserved.joined(separator: ","), privacy: .public)")
    }

    /// Re-answer "can the language wait until after the microphone opens?" against the two formats
    /// the engine has just resolved.
    ///
    /// Called from `prepareSecondary` and nowhere else, because that is the only place either format
    /// can change. Compares the four properties the converter is built from; `AVAudioFormat`'s own
    /// `==` also compares `isStandard` and the channel layout object, which would report a spurious
    /// difference between two formats the converter would treat identically.
    private func refreshLocaleDecisionDeferrable() {
        guard let secondary = secondaryAnalyzerFormat, appliedSecondaryLocale != nil else {
            // With no second language there is nothing to decide, so deferral costs nothing and the
            // window simply never changes an answer. Left on so the timing path is the same one the
            // dual-language user exercises, rather than a branch that only runs for some users.
            localeDecisionDeferrable = true
            return
        }
        guard let primary = analyzerFormat else {
            localeDecisionDeferrable = true
            return
        }
        let matches = primary.sampleRate == secondary.sampleRate
            && primary.channelCount == secondary.channelCount
            && primary.commonFormat == secondary.commonFormat
            && primary.isInterleaved == secondary.isInterleaved
        if matches != localeDecisionDeferrable {
            localeDecisionDeferrable = matches
        }
        if !matches {
            // Loud, and at `error`: the user silently loses the late-modifier window, which is the
            // difference between an Indonesian transcript and a page of invented English names.
            Log.engine.error("""
                the two dictation languages disagree on their analyzer format \
                (\(primary.sampleRate, format: .fixed(precision: 0), privacy: .public) Hz \
                \(primary.channelCount, privacy: .public) ch vs \
                \(secondary.sampleRate, format: .fixed(precision: 0), privacy: .public) Hz \
                \(secondary.channelCount, privacy: .public) ch); \
                the language modifier is back to being sampled at arm time
                """)
        } else {
            Log.engine.debug("""
                both languages accept \(primary.sampleRate, format: .fixed(precision: 0), privacy: .public) Hz \
                \(primary.channelCount, privacy: .public) ch; the language may be decided after capture opens
                """)
        }
    }

    /// Opt-in low-latency mode. Costs a permanently lit orange microphone indicator, which RECON §22
    /// calls out as the single likeliest reason a dictation app gets uninstalled — hence opt-in.
    private func startMicrophonePrewarm() async {
        do {
            try await capture.prewarm(targetFormat: analyzerFormat)
        } catch {
            Log.audio.warning("microphone pre-warm failed: \(Self.describe(error), privacy: .public)")
        }
    }

    /// Called from `applicationWillTerminate`.
    public func shutdown() {
        cancel()
        prewarmTask?.cancel()
        hotkeyEventsTask?.cancel()
        hotkeyDiagnosticsTask?.cancel()
        hotkeyGesturesTask?.cancel()
        hotkeyCapturedKeysTask?.cancel()
        permissionsTask?.cancel()
        hotkey.stop()
        dictionary.stopWatchingFile()
        // Fire-and-forget: the process is going away, and a synchronous wait on an actor from
        // `applicationWillTerminate` is how an app hangs on quit.
        let capture = self.capture
        Task.detached { await capture.teardown() }
    }

    // MARK: - Hotkey

    /// The modifier the monitor should treat as the language switch, or `nil` when the shortcut is off
    /// — in which case every modifier goes back to cancelling the hold.
    private var alternateModifier: HotkeyModifier? {
        settings.secondaryLocaleEnabled ? settings.secondaryLocaleModifier : nil
    }

    private func startHotkey() {
        let key = settings.hotkey
        let alternate = alternateModifier
        let refine = settings.effectiveRefineChord
        do {
            try hotkey.start(key: key, alternate: alternate, refine: refine)
            appliedHotkey = key
            appliedAlternateModifier = alternate
            appliedRefineChord = refine
            model?.apply(hotkeyLive: true)
            Log.hotkey.info("monitor live on \(key.rawValue, privacy: .public)")
        } catch {
            appliedHotkey = nil
            appliedRefineChord = nil
            model?.apply(hotkeyLive: false)
            Log.hotkey.error("monitor failed to start: \(Self.describe(error), privacy: .public)")
        }

        startHotkeyConsumersIfNeeded()
    }

    /// Created exactly ONCE, and deliberately never cancelled by a restart.
    ///
    /// `HotkeyMonitor.events` hands back a single *stored* `AsyncStream`, and an `AsyncStream`
    /// supports only one iterator. Cancelling the consumer and starting a second one over that same
    /// stream leaves the replacement receiving nothing, for ever — which is exactly what pressing
    /// RESTART used to do. The symptom was thoroughly misleading: the monitor went on arming and
    /// releasing correctly (its own log lines proved the tap, the keycode and the device bit were all
    /// fine) while the controller sat permanently deaf behind a dead iterator, so the key simply did
    /// nothing and there was no error anywhere to find.
    ///
    /// A single long-lived consumer is safe across any number of tap stop/start cycles, because the
    /// continuations are finished only in the monitor's `deinit`. Consume unconditionally, even when
    /// `start()` threw: a later permission grant re-creates the tap, and the consumer must already be
    /// in place when it does.
    private func startHotkeyConsumersIfNeeded() {
        guard hotkeyEventsTask == nil, hotkeyDiagnosticsTask == nil else { return }

        // Both of these are stored `AsyncStream`s with the same one-consumer rule as `events`
        // (RECON amendment 32), so they are iterated exactly once here and never re-iterated on a
        // restart. The captured-key loop in particular must outlive any number of tap generations:
        // it is the only path a keystroke has to a panel that cannot become key.
        let gestures = hotkey.gestures
        hotkeyGesturesTask = Task { [weak self] in
            for await gesture in gestures {
                guard let self else { return }
                switch gesture {
                case .refinePopup: self.refineGesture.gestureFired()
                }
            }
        }

        let capturedKeys = hotkey.capturedKeys
        hotkeyCapturedKeysTask = Task { [weak self] in
            for await key in capturedKeys {
                guard let self else { return }
                self.refineGesture.handleCapturedKey(keyCode: key.keyCode, rawFlags: key.rawFlags)
            }
        }

        let events = hotkey.events
        hotkeyEventsTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        }

        let diagnostics = hotkey.diagnostics
        hotkeyDiagnosticsTask = Task { [weak self] in
            for await diagnostic in diagnostics {
                guard let self else { return }
                self.handle(diagnostic)
            }
        }
    }

    /// Open the refine popup over the current selection without the chord.
    ///
    /// The menu-bar path, and the only path an automated verification run has: the chord itself has
    /// to be pressed, and posting it as a synthetic event exercises the tap rather than this.
    public func refineSelection() {
        refineGesture.gestureFired()
    }

    /// RECON §11 is categorical: a tap created while access was denied is *permanently* dead and
    /// re-enabling it does nothing. The only repair is destroy-and-recreate.
    public func restartHotkey() {
        hotkey.stop()
        startHotkey()
    }

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .pressed(let alternate):
            if settings.pushToTalk {
                begin(origin: .hotkey, alternate: alternate)
            } else if toggleLatched {
                toggleLatched = false
                end()
            } else {
                begin(origin: .hotkey, alternate: alternate)
                // Latched only if the utterance actually started. Otherwise a refused `begin`
                // would leave the toggle armed and the *next* press would stop nothing.
                toggleLatched = utterance != nil
            }

        case .alternateSettled(let alternate):
            // The only place a language is chosen for a hotkey-driven utterance. Arrives once per
            // `.pressed`, always before `.released`, and may disagree with the provisional reading
            // that came with `.pressed` — which is the entire reason it exists.
            settleLocale(alternate: alternate)

        case .released:
            // In toggle mode the release of the *starting* press must not stop anything.
            guard settings.pushToTalk else { return }
            end()
        }
    }

    /// Resolve the language modifier into a locale and hand it to the utterance in flight.
    ///
    /// Everything about *which* locale lives here and nowhere else — `HotkeyMonitor` knows only
    /// about modifier bits. Also the place the HUD's tag is corrected: `apply(activeLocale:)` is
    /// idempotent, so a settle that agrees with the provisional reading redraws nothing.
    private func settleLocale(alternate: Bool) {
        guard let unit = utterance, unit.decision == nil else { return }
        let decision = resolveLocale(alternate: alternate, announce: true)
        unit.settle(decision)
        model?.apply(activeLocale: decision.localeIdentifier, isSecondary: decision.isSecondary)
    }

    /// "Was the modifier held?" → which of the engine's two prepared languages.
    ///
    /// Requests the secondary only if the shortcut is on AND the engine actually holds a reservation
    /// for the language. A missing reservation makes the modifier inert for this press, which is
    /// right: the alternative is throwing on a gesture the user cannot un-learn.
    /// - Parameter announce: log the "modifier held but the language is not prepared" case. Only the
    ///   call that produces the *decision* announces it; the provisional reading at key-down does not,
    ///   because it is resolved again a few hundred milliseconds later and may well change.
    private func resolveLocale(alternate: Bool, announce: Bool) -> LocaleDecision {
        let wantsSecondary = alternate && settings.effectiveSecondaryLocaleIdentifier != nil
        let useSecondary = wantsSecondary && appliedSecondaryLocale != nil
        if announce, wantsSecondary, !useSecondary {
            Log.engine.error("""
                the language modifier was held but \
                \(self.settings.secondaryLocaleIdentifier, privacy: .public) is not prepared; \
                dictating in \(self.settings.localeIdentifier, privacy: .public)
                """)
        }
        return LocaleDecision(
            localeIdentifier: useSecondary
                ? (appliedSecondaryLocale ?? settings.localeIdentifier)
                : settings.localeIdentifier,
            engineLocale: useSecondary ? .secondary : .primary,
            isSecondary: useSecondary
        )
    }

    private func handle(_ diagnostic: HotkeyDiagnostic) {
        switch diagnostic {
        case .holdBegan:
            break

        case .cancelled(let reason):
            Log.hotkey.debug("hold cancelled: \(String(describing: reason), privacy: .public)")
            // The monitor promises a `.released` for every `.pressed`, so most cancels need nothing
            // here. `.tapDisabled` is the exception worth acting on immediately: the tap died
            // mid-hold, so the release may be arriving from a stream that is no longer being fed.
            // Committing (rather than discarding) is right — the user has already spoken. `end()`
            // is idempotent, so the guaranteed `.released` that follows is harmless.
            if reason == .tapDisabled { end() }
            if reason == .keyChanged { end() }

        case .tapReEnabled(let why):
            Log.hotkey.notice("tap re-enabled after \(why, privacy: .public)")
            model?.apply(hotkeyLive: hotkey.isRunning)

        case .permissionLost:
            // Nothing can be recorded from here on, and a half-captured utterance is worse than none.
            model?.apply(hotkeyLive: false)
            cancel()
            Log.hotkey.error("input monitoring lost; tap needs re-creating")

        case .maskIncomplete(let requested, let granted):
            model?.apply(hotkeyLive: false)
            Log.hotkey.error("""
                event mask stripped by the window server: requested \
                0x\(String(requested, radix: 16), privacy: .public) granted \
                0x\(String(granted, radix: 16), privacy: .public)
                """)
        }
    }

    // MARK: - Settings and permission observation

    /// Live-updating hotkey and locale pickers, without the settings view having to call us.
    ///
    /// `withObservationTracking` fires its `onChange` synchronously inside the mutation, so the
    /// work hops to a fresh main-actor task and re-arms the tracking there — an observation is
    /// one-shot by design.
    private func observeSettings() {
        withObservationTracking {
            _ = settings.hotkey
            _ = settings.localeIdentifier
            _ = settings.prewarmMicrophone
            _ = settings.secondaryLocaleEnabled
            _ = settings.secondaryLocaleIdentifier
            _ = settings.secondaryLocaleModifier
            _ = settings.refineSelectionEnabled
            _ = settings.refineSelectionChord
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.settingsChanged()
                self.observeSettings()
            }
        }
    }

    private func settingsChanged() {
        // The modifier is part of the binding, so a change to it is a rebind even when the key is the
        // same — without this, turning the shortcut on would leave Shift still cancelling the hold.
        // The refine chord is part of the binding too, and `effectiveRefineChord` can change without
        // either setting moving — switching the dictation key to Globe refuses a `fn`-qualified
        // chord — so it is compared as a resolved value rather than as a raw preference.
        let refine = settings.effectiveRefineChord
        if settings.hotkey != appliedHotkey
            || alternateModifier != appliedAlternateModifier
            || refine != appliedRefineChord {
            let key = settings.hotkey
            let alternate = alternateModifier
            appliedHotkey = key
            appliedAlternateModifier = alternate
            appliedRefineChord = refine
            if hotkey.isRunning {
                hotkey.update(key: key, alternate: alternate, refine: refine)
                Log.hotkey.info("""
                    rebound to \(key.rawValue, privacy: .public) \
                    + \(alternate?.rawValue ?? "none", privacy: .public) \
                    refine=\(refine?.rawValue ?? "off", privacy: .public)
                    """)
            } else {
                startHotkey()
            }
        }

        if settings.localeIdentifier != appliedLocale {
            let locale = settings.localeIdentifier
            Task { [weak self] in
                await self?.prepareEngine(localeIdentifier: locale)
                // The primary moving can make the secondary redundant (both `en-US`) or newly
                // meaningful, so re-resolve it against the new primary rather than leaving a stale
                // reservation behind.
                await self?.prepareSecondary()
            }
        } else if settings.effectiveSecondaryLocaleIdentifier != appliedSecondaryLocale {
            Task { [weak self] in await self?.prepareSecondary() }
        }

        if settings.prewarmMicrophone {
            Task { [weak self] in await self?.startMicrophonePrewarm() }
        } else {
            // Turning the mode off must actually put the microphone indicator out.
            let capture = self.capture
            Task { if !(await capture.isCapturing) { await capture.teardown() } }
        }
    }

    /// The tap has to be re-created the moment Input Monitoring arrives (RECON §11).
    private func observePermissions() {
        let changes = permissions.changes
        permissionsTask = Task { [weak self] in
            for await kind in changes {
                guard let self else { return }
                guard kind == .inputMonitoring else { continue }
                if self.permissions.state(of: .inputMonitoring) == .granted, !self.hotkey.isRunning {
                    self.restartHotkey()
                }
            }
        }
    }

    // MARK: - Transport

    /// Key-down. Reads the dictionary *here* and nowhere else (RECON §2).
    ///
    /// - Parameter alternate: the language modifier was held when the hotkey armed. **Provisional.**
    ///   It sets what the HUD draws for the first few hundred milliseconds and nothing else; the
    ///   locale the analyzer is built from comes from `.alternateSettled` by way of `settleLocale`.
    ///   For a non-hotkey origin there is no window and no settle owed, so it *is* the decision.
    public func begin(origin: Origin, alternate: Bool = false) {
        guard utterance == nil else {
            Log.engine.debug("begin ignored: an utterance is already in flight")
            return
        }
        if let phase = model?.phase, phase.isActive {
            Log.engine.debug("begin ignored: phase \(String(describing: phase), privacy: .public)")
            return
        }

        // ── The one moment biasing can be chosen ────────────────────────────────────────────────
        // RECON §2/§5: contextual strings reach the engine only through `SpeechAnalyzer.init`, and
        // a long list both costs more and biases *worse* (a 9-term list fixed "Wispr Flow" where a
        // 200-term list fixed neither). `biasingStrings(limit:)` ranks and caps; `effectiveBiasingLimit`
        // is 0 when the user turned biasing off.
        //
        // Biasing is the SAME list for both languages, deliberately.
        //
        // The dictionary holds proper nouns — Vercel, Supabase, Claude Code, Obsidian — not English
        // words, and this user code-switches inside single sentences: the jargon is identical whether
        // the surrounding grammar is English or Indonesian. Splitting it would need a per-entry locale
        // field on `DictionaryEntry` (a data-layer schema change) to buy a benefit nobody has measured,
        // and would silently stop fixing "Supabase" the moment the user pressed Shift. Layer 2, the
        // correction pass, is likewise language-independent and runs unchanged.
        let biasing = dictionary.biasingStrings(limit: settings.effectiveBiasingLimit)
        // Layer 2 of the two-layer dictionary: the guaranteed find-and-replace pass. Compiled now
        // so a dictionary edit mid-utterance cannot change the rules under the transcript.
        let corrector = settings.correctionsEnabled
            ? dictionary.corrector(includeTermCaseNormalisation: settings.termCaseNormalisation)
            : Corrector(rules: [])

        let target = origin == .app
            ? InjectionTarget(bundleID: Self.ownBundleID, appName: "Edict")
            : TextInjector.currentTarget()

        // ── Which language this utterance runs in, and WHEN that is decided ─────────────────────
        // The provisional reading, which exists only so the HUD has something to draw immediately.
        // The real decision arrives on `.alternateSettled` up to `HotkeyMonitor.alternateWindow`
        // later, and `run(_:)` will not build an analyzer until it has.
        let provisional = resolveLocale(alternate: alternate, announce: false)

        let unit = Utterance(
            origin: origin,
            target: target,
            biasing: biasing,
            corrector: corrector,
            captureFormat: analyzerFormat,
            provisional: provisional,
            droppedBaseline: capture.statsSnapshot.dropped
        )
        utterance = unit

        // Two reasons the decision is closed here and now rather than waited for:
        //
        // * Nothing is coming. `.app` is the Start button, the menu bar and the tests — there is no
        //   hold, no modifier and no `.alternateSettled` owed, so waiting would hang the utterance.
        // * Deferral is unsafe. The two prepared languages disagree on their analyzer format, so the
        //   converter cannot be configured before the language is known and the old arm-time
        //   contract is the only correct one. See `localeDecisionDeferrable`.
        model?.clearLiveText()
        model?.apply(activeLocale: provisional.localeIdentifier, isSecondary: provisional.isSecondary)
        model?.apply(phase: .arming)
        if origin != .hotkey || !localeDecisionDeferrable {
            settleLocale(alternate: alternate)
        }
        playFeedback(.start)

        unit.task = Task { [weak self] in
            await self?.run(unit)
        }
    }

    /// Key-up, Stop button, or a hotkey monitor that lost its tap mid-hold. Idempotent.
    public func end() {
        guard let unit = utterance, !unit.stopRequested, !unit.cancelRequested else { return }
        unit.stopRequested = true
        toggleLatched = false
        // Normally a no-op: `HotkeyMonitor` emits `.alternateSettled` before `.released` on the same
        // stream, handled by the same task, so the decision is already made by the time a key release
        // reaches here. This is for the paths that never go through a release — the duration
        // watchdog, the Stop button, a tap that died mid-hold — where the language would otherwise
        // never arrive and `run(_:)` would stay suspended for ever.
        fallBackToProvisionalIfUndecided(unit, why: "stop")
        Log.engine.debug("stop requested")
        // Finishing the audio stream is what lets `finalizeAndFinishThroughEndOfInput()` return
        // (RECON §5). The feed loop in `run` ends as a consequence; nothing else is signalled.
        let capture = self.capture
        Task { await capture.stop() }
    }

    /// Explicit abort (Esc, a lost permission, quitting). Discards the utterance.
    ///
    /// RECON §5 measured `cancelAndFinishNow()` throwing away the pending final result — 0 events,
    /// empty string — which is exactly right for an abort and exactly wrong for a key release.
    /// That is why `end()` and `cancel()` are different methods and not a flag.
    public func cancel() {
        guard let unit = utterance else { return }
        unit.cancelRequested = true
        toggleLatched = false
        // Same reason as in `end()`, and it matters more here: Esc must be able to tear an utterance
        // down even when it is parked waiting for a decision.
        fallBackToProvisionalIfUndecided(unit, why: "cancel")
        Log.engine.notice("utterance cancelled")
        let capture = self.capture
        Task { await capture.stop() }
    }

    private func fallBackToProvisionalIfUndecided(_ unit: Utterance, why: String) {
        guard unit.decision == nil else { return }
        Log.engine.notice("""
            no language decision arrived before \(why, privacy: .public); \
            falling back to the arm-time reading (\(unit.provisional.localeIdentifier, privacy: .public))
            """)
        unit.settle(unit.provisional)
        model?.apply(activeLocale: unit.provisional.localeIdentifier,
                     isSecondary: unit.provisional.isSecondary)
    }

    // MARK: - The sequence

    private func run(_ unit: Utterance) async {
        // Tracked so the guaranteed teardown below can tell "never started" from "started".
        var audioStarted = false
        var session: (any TranscriptionSession)?
        var watchdog: Task<Void, Never>?

        let openedAt = Date()

        do {
            await engine.setBiasing(unit.biasing)

            // ── Capture first, analyzer second. This ordering IS the fix. ───────────────────────
            //
            // The microphone opens here, before the language is known, and the buffers pile up in
            // the stream's own queue — which is sized in *seconds*, 100 of them, precisely because
            // `.bufferingNewest` discards the OLDEST element and would otherwise delete the
            // beginning of the utterance and look like a model failure (RECON §20). Nothing consumes
            // the stream until the feed loop below, so every buffer captured while the decision was
            // open is still in it, in order, when the analyzer finally exists.
            //
            // Two things improve for free by moving `capture.start` above `engine.begin`:
            //
            // * The language modifier gets a real window to arrive in. That is the point.
            // * `engine.begin` can *wait* — `claimSlot` gives the previous utterance up to 1.5 s to
            //   finish finalizing (RECON §8 puts the real window at 0.15–0.53 s) — and that wait
            //   used to happen with the microphone shut, so a press-pause-press rhythm silently
            //   dropped the first half-second of the second sentence. Now it is captured.
            let stream = try await capture.start(targetFormat: unit.captureFormat ?? analyzerFormat)
            audioStarted = true
            // `.listening` the moment the microphone is live, which is now *earlier* than before
            // rather than later: the HUD must not claim to be arming while audio is being recorded.
            model?.apply(phase: .listening)

            // Started from the moment audio starts flowing, not from the moment the analyzer exists,
            // so the ceiling covers the whole recording however long the decision took.
            watchdog = Task { [weak self] in
                try? await Task.sleep(for: Self.maxUtteranceDuration)
                guard !Task.isCancelled else { return }
                Log.engine.error("utterance exceeded the maximum duration; forcing a stop")
                self?.end()
            }

            // ── The language, at last ──────────────────────────────────────────────────────────
            // Resolved already for an `.app`-origin utterance and for the non-deferrable case, so
            // this returns without suspending there. For a hotkey hold it waits for the modifier
            // window to close — or for the release, if the user let go first.
            let decision = await unit.awaitDecision()
            let waited = -openedAt.timeIntervalSinceNow
            Log.engine.info("""
                locale settled after \(waited * 1000, format: .fixed(precision: 1), privacy: .public) ms: \
                \(decision.localeIdentifier, privacy: .public)\
                \(decision.isSecondary ? " (modifier)" : "")
                """)

            // A cancel or a very fast tap can land while the decision was open. Bail before an
            // analyzer is built for an utterance nobody wants.
            try unit.checkCancelled()

            // Sendable box: the update callback fires off the main actor from the analyzer's
            // results task, so it hops rather than touching `AppModel` directly.
            let sink = LiveTextRelay { [weak self] committed, volatile in
                self?.model?.apply(committed: committed, volatile: volatile)
            }
            // Throws rather than falling back if the secondary language's assets are missing. That is
            // the whole point: an English model handed Indonesian speech does not fail, it returns
            // confident English nonsense and the injection ladder types it into the user's document.
            let started = try await engine.begin(locale: decision.engineLocale, onUpdate: { update in
                sink.publish(committed: update.finalText, volatile: update.volatileText)
            })
            session = started
            unit.session = started

            // The user may have released the key while any of the above was awaiting; `stop()` is
            // safe to call before the first buffer and simply finishes the stream — which does NOT
            // discard what is already queued in it, so a hold shorter than the whole set-up still
            // delivers every buffer it captured.
            if unit.stopRequested || unit.cancelRequested {
                await capture.stop()
            }

            for await input in stream {
                if unit.cancelRequested { break }
                started.feed(input)
            }
            watchdog?.cancel()
            watchdog = nil

            if unit.cancelRequested {
                await started.abort()
                await capture.stop()
                finishCancelled(unit)
                return
            }

            model?.apply(phase: .transcribing)
            let outcome = try await started.finishAndCommit()

            // The microphone goes out *before* the correction and injection work, not after: an
            // extra second of lit indicator while text is being pasted is exactly the "always
            // listening" impression RECON §22 warns about.
            await capture.stop()
            audioStarted = false

            await complete(unit, outcome: outcome)

        } catch is CancellationError {
            watchdog?.cancel()
            if audioStarted { await capture.stop() }
            await session?.abort()
            finishCancelled(unit)

        } catch {
            watchdog?.cancel()
            // Invariant 2. Unconditional, and before anything that could itself fail.
            if audioStarted { await capture.stop() }
            // `abort()` is what hands the engine's analyzer slot back, and it does it for *this*
            // session only. There used to be an `await engine.cancel()` after this line as a
            // belt-and-braces; it is gone deliberately. `cancel()` aborts whatever the engine
            // currently holds, which after this session released is either nothing or a *different*
            // utterance — a file import, or the next press that was already waiting for the slot —
            // so on the one path where it did anything at all, what it did was wrong.
            await session?.abort()

            let message = Self.friendlyMessage(for: error)
            Log.engine.error("utterance failed: \(Self.describe(error), privacy: .public)")
            utterance = nil
            model?.apply(phase: .error(message))
            playFeedback(.fault)
        }
    }

    private func finishCancelled(_ unit: Utterance) {
        guard utterance === unit else { return }
        utterance = nil
        model?.clearLiveText()
        model?.apply(phase: .idle)
    }

    /// Correction → injection → history → dictionary hit counts.
    private func complete(_ unit: Utterance, outcome: TranscriptionOutcome) async {
        // The phase stays `.transcribing` through the correction pass and is moved on by the two
        // steps below, which is what lets the HUD distinguish a 1–3 s refinement from an insertion
        // that takes a few milliseconds. Announcing `.injecting` here would have the HUD say
        // "Inserting" for the whole of a wait that is not an insertion.
        let dropped = max(0, capture.statsSnapshot.dropped - unit.droppedBaseline)
        let raw = outcome.text
        // Non-nil by construction: `run(_:)` awaits the decision before it builds the analyzer that
        // produced this outcome. The fallback is the primary language rather than a crash, because a
        // transcript labelled with the wrong language is a smaller loss than a lost transcript.
        let localeIdentifier = unit.decision?.localeIdentifier ?? settings.localeIdentifier

        // Layer 2 runs off the main actor. `Corrector` is `Sendable` and the rule set was frozen at
        // key-down, so this is a pure function of two immutable values — the one piece of per-
        // utterance CPU work that is worth moving off the actor that is also drawing the HUD.
        let corrector = unit.corrector
        let corrected: CorrectionResult
        if corrector.isEmpty || raw.isEmpty {
            corrected = CorrectionResult(text: raw, hits: [])
        } else {
            corrected = await Task.detached(priority: .userInitiated) {
                corrector.apply(to: raw)
            }.value
        }

        // Opt-in, off by default: measured 1.0 s warm and 2.9 s cold, added between the user
        // releasing the key and the text appearing. See `Settings.refineBeforeInsert`.
        let refinement = await refineBeforeInserting(
            corrected.text,
            localeIdentifier: localeIdentifier
        )

        model?.apply(phase: .injecting)
        let injection = await inject(refinement?.text ?? corrected.text, unit: unit)

        let transcript = Transcript(
            rawText: raw,
            text: corrected.text,
            corrections: corrected.hits,
            audioDuration: outcome.audioDuration,
            transcribeDuration: outcome.latency,
            localeIdentifier: localeIdentifier,
            targetBundleID: unit.target.bundleID,
            targetAppName: unit.target.appName,
            injection: injection,
            droppedBuffers: dropped,
            lowConfidenceWords: outcome.lowConfidenceWords,
            refinement: refinement
        )

        if !raw.isEmpty {
            history.append(transcript)
        }
        if !corrected.hits.isEmpty {
            dictionary.recordHits(corrected.hits)
        }

        utterance = nil
        // What actually landed, which is the refined string when refinement ran. The HUD's last frame
        // should show the text that went into the document, not the version of it that did not.
        model?.apply(committed: refinement?.text ?? corrected.text, volatile: "")
        model?.finished(transcript: transcript)
        model?.apply(phase: .idle)
        playFeedback(injection.isSuccess || injection == .notAttempted ? .stop : .fault)

        Log.engine.info("""
            utterance done: \(transcript.wordCount, privacy: .public) words in \
            \(outcome.audioDuration, format: .fixed(precision: 2), privacy: .public) s, \
            latency \(outcome.latency, format: .fixed(precision: 3), privacy: .public) s, \
            \(corrected.hits.count, privacy: .public) corrections, \
            injection \(injection.rawValue, privacy: .public)\
            \(dropped > 0 ? ", DROPPED \(dropped) buffers" : "")\
            \(Self.refinementLog(refinement))
            """)
    }

    // MARK: - Refine before inserting

    /// Clean the text up with the on-device model before it reaches the cursor, when the user has
    /// asked for that. Returns `nil` when the switch is off, so the caller's `??` is the whole
    /// difference between the two paths.
    ///
    /// **A failure here never costs the dictation.** Everything `TextRefiner.refine` can throw —
    /// Apple Intelligence switched off, a guardrail refusal, a transcript longer than the context
    /// window — is caught, recorded on the transcript as a sentence the history pane prints, and the
    /// unrefined text is inserted exactly as if the switch were off. The alternative, letting the
    /// error propagate, would mean a user with this switch on and Apple Intelligence off loses their
    /// speech to a feature they turned on for convenience.
    /// `internal`, not `private`, and taking a locale rather than the `Utterance` it is called with:
    /// this is the one branch in the file that decides whether a user's speech survives a model
    /// error, and it is otherwise reachable only by speaking into a microphone.
    /// `RefinementSurfaceModelTests` calls it directly.
    func refineBeforeInserting(_ text: String, localeIdentifier: String) async -> RefinementRecord? {
        guard settings.refineBeforeInsert else { return nil }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        model?.apply(phase: .refining)
        let started = Date()
        // The one action offered here. Bullets and a summary are things the user asks for *about* a
        // finished transcript in the history pane; nobody wants their dictation silently turned into
        // a bullet list on the way to a text field they were typing a sentence into.
        let action = RefinementAction.cleanUp
        do {
            let result = try await refiner.refine(
                text,
                as: action,
                localeIdentifier: localeIdentifier
            )
            return RefinementRecord(
                action: action,
                text: result.text,
                duration: result.duration,
                localeIdentifier: result.localeIdentifier,
                localeUnsupported: result.wasLocaleUnsupported
            )
        } catch is CancellationError {
            // The user cancelled the utterance; there is nothing to say about a refinement that was
            // never going to be inserted either.
            return nil
        } catch {
            let sentence = (error as? any LocalizedError)?.errorDescription
                ?? "The on-device model could not clean this up."
            Log.engine.notice("refine-before-insert failed: \(sentence, privacy: .public)")
            return RefinementRecord(
                action: action,
                duration: Date().timeIntervalSince(started),
                localeIdentifier: localeIdentifier,
                failure: sentence
            )
        }
    }

    private static func refinementLog(_ record: RefinementRecord?) -> String {
        guard let record else { return "" }
        return record.didInsertRefinedText
            ? String(format: ", refined in %.2f s", record.duration)
            : ", refinement declined or failed"
    }

    private func inject(_ text: String, unit: Utterance) async -> InjectionOutcome {
        guard !text.isEmpty else { return .notAttempted }
        guard settings.autoInject else { return .notAttempted }
        // Dictated from Edict's own window: there is no foreign cursor, and injecting would type
        // the transcript into whichever of our own fields happens to have focus.
        guard unit.origin != .app, unit.target.bundleID != Self.ownBundleID else { return .notAttempted }

        // Only committed text ever gets here (RECON §4) — `finishAndCommit` returns finals only.
        let current = TextInjector.currentTarget()
        if current.bundleID != unit.target.bundleID {
            // Worth a log rather than a refusal: the injector works on the *currently* focused AX
            // element either way, and the recorded target is what the per-app policy was chosen from.
            Log.inject.notice("""
                focus moved during the utterance: \
                \(unit.target.bundleID ?? "nil", privacy: .public) -> \
                \(current.bundleID ?? "nil", privacy: .public)
                """)
        }
        return await injector.inject(text, into: unit.target)
    }

    // MARK: - File import

    /// Everything `ImportQueue` needs from the engine layer.
    ///
    /// Handed over as closures rather than letting the queue hold `SpeechEngine`, for the reason
    /// `ImportQueue.Environment` exists: the queue is then testable with three closures and no model,
    /// no microphone and no disk. All three hop back through this controller so there is exactly one
    /// owner of the engine's single-session rule.
    public func importEnvironment() -> ImportQueue.Environment {
        ImportQueue.Environment(
            analyzerFormat: { [weak self] locale in
                await self?.importAnalyzerFormat(localeIdentifier: locale)
            },
            transcribe: { [weak self] locale, stream, onUpdate in
                guard let self else { throw CancellationError() }
                return try await self.transcribeImport(
                    localeIdentifier: locale,
                    stream: stream,
                    onUpdate: onUpdate
                )
            },
            // Without this, cancelling a long file only closes the *reader*; the analyzer already
            // holds every remaining chunk in its unbounded input queue and would spend its full run
            // finalizing audio nobody wants. Measured at ~25 s for a 377 s file.
            cancelActive: { [weak self] in await self?.engine.cancel() },
            // Always supplied, never conditional on the setting: the `Environment` is built once at
            // launch and the switch can be flipped at any time, so the *closure* has to be the thing
            // that reads it. It returns nil when dual pass is off or unavailable, which the queue
            // treats as "run the ordinary single pass".
            dualPass: { [weak self] url, locale, reporting in
                guard let self else { throw CancellationError() }
                return try await self.runDualPass(
                    url: url,
                    primaryLocaleIdentifier: locale,
                    reporting: reporting
                )
            },
            // Read at each `enqueue` that did not name a language, which is what makes the default
            // "follow my dictation language" mean *now* rather than "whatever it says when the file
            // finally reaches the front of the queue".
            dictationLocaleIdentifier: { [weak self] in
                self?.settings.localeIdentifier ?? Settings.Default.localeIdentifier
            },
            // `DictationTranscriber`'s 54 locales, the superset — the picker's job is to offer every
            // language a file *can* be transcribed in, and the module is then resolved from the
            // choice (RECON: `SpeechTranscriber` covers 45 and `id-ID` is in the gap).
            supportedLocaleIdentifiers: { [weak self] in
                guard let self else { return [] }
                return await self.engine.supportedLocales.map(\.identifier)
            },
            dualPassPartnerLocaleIdentifier: { [weak self] in
                guard let self, self.settings.dualPassIsActive else { return nil }
                return self.settings.effectiveSecondaryLocaleIdentifier
            }
        )
    }

    /// The engine behind the import path, for the one test that needs a live dictation and an import
    /// contending for the *same* analyzer slot.
    ///
    /// Internal rather than public, and narrow on purpose: `SpeechEngine`'s slot is per instance, so
    /// two engines would never contend and "a live dictation wins the slot and the import retries"
    /// would pass without proving anything. See `ImportLocaleTests.liveDictationWinsTheSlot`.
    var engineForTesting: SpeechEngine { engine }

    /// One file, decoded once and transcribed twice per section.
    ///
    /// Returns `nil` — "not this file" — rather than throwing whenever the feature simply does not
    /// apply: the switch is off, there is no second language configured, or one of the two languages
    /// has no model on disk yet. Each of those must degrade to a single-pass transcript, because the
    /// user dropped a file to get a transcript and an error about a language contest is not one.
    /// - Parameter primaryLocaleIdentifier: the queue item's own language, which becomes the **first**
    ///   pass. See `ImportQueue.dualPassRule` for the rule and why this is the composition chosen:
    ///   the per-item choice decides which languages are tried, dual pass decides that more than one
    ///   is. When the item's language *is* the second dictation language there is no pair left to
    ///   compare, so this returns nil and the file gets one honest pass in the language it was
    ///   dropped as.
    private func runDualPass(
        url: URL,
        primaryLocaleIdentifier: String,
        reporting: DualPassImporter.Reporting
    ) async throws -> ImportQueue.DualPassJob? {
        guard settings.dualPassIsActive,
              let secondaryIdentifier = settings.effectiveSecondaryLocaleIdentifier,
              Settings.localeKey(secondaryIdentifier) != Settings.localeKey(primaryLocaleIdentifier)
        else { return nil }

        let began = ContinuousClock.now
        let primary = await engine.resolveImportPass(
            preferGeneral: settings.importUsesGeneralModel,
            localeIdentifier: primaryLocaleIdentifier
        )
        let secondary = await engine.resolveImportPass(
            // The second language is offered the general model on exactly the same terms as the
            // first. It will usually not get it — Indonesian is one of the 9 locales
            // `SpeechTranscriber` does not cover (RECON amendment 7) — but hardcoding the dictation
            // module for "the other language" would make the comparison asymmetric for a pair like
            // en-US/es-ES, where both are covered and one pass would be handicapped for no reason.
            preferGeneral: settings.importUsesGeneralModel,
            localeIdentifier: secondaryIdentifier
        )
        guard let primaryPass = primary.pass, let secondaryPass = secondary.pass else {
            let reason = primary.reason ?? secondary.reason ?? "a language could not be prepared"
            // Falling back to one pass, **never to another language**: the single pass that follows
            // runs in this item's own locale and fails outright if that locale's model is missing.
            Log.stt.notice("dual pass unavailable, using one model: \(reason, privacy: .public)")
            return nil
        }
        guard let format = await engine.bestAudioFormat(for: primaryPass) else { return nil }
        // Both passes are fed the same decoded samples, so a module that wanted a different format
        // would be handed audio at the wrong rate — which does not fail, it transcribes noise. RECON
        // §17 records only 16 kHz and 8 kHz mono Int16 as available at all, so this is a guard
        // against a future OS rather than an expected branch.
        guard let secondaryFormat = await engine.bestAudioFormat(for: secondaryPass),
              secondaryFormat.sampleRate == format.sampleRate,
              secondaryFormat.channelCount == format.channelCount else {
            Log.stt.notice("dual pass unavailable: the two models want different audio formats")
            return nil
        }

        let importer = AudioFileImporter(
            url: url,
            analyzerFormat: format,
            // The dual pass holds the whole decode itself, so the streaming probe would be a second
            // copy of the same samples for no reason.
            speechProbeBudgetBytes: 0
        )
        let info = try await importer.open()
        // Decode gets the same fixed 2 % of the bar `DualPassImporter` reserves for it, so the bar
        // moves during the decode instead of sitting at zero and then jumping.
        let decoded = try await importer.decodeAll(
            onProgress: { reporting.onProgress($0 * DualPassImporter.decodeShare) }
        )

        // Biasing follows the same rule as a single-pass import: layer 1 exists only on the dictation
        // module (RECON §1 measured contextual strings as a byte-for-byte no-op on the other), and
        // it is passed explicitly so a file can neither inherit nor clobber the list a live dictation
        // froze at key-down.
        let biasing = dictionary.biasingStrings(limit: settings.effectiveBiasingLimit)
        let engine = self.engine
        func makePass(_ pass: SpeechEngine.ImportPass) -> DualPassImporter.Pass {
            DualPassImporter.Pass(
                localeIdentifier: pass.requestedIdentifier,
                module: pass.module,
                transcribe: { stream in
                    try await engine.transcribe(
                        input: stream,
                        pass: pass,
                        biasing: pass.module.supportsBiasing ? biasing : [],
                        onUpdate: { _ in }
                    )
                }
            )
        }

        // `longForm` past ten minutes: on the real 70-minute meeting `standard` produces 1043
        // sections and `longForm` 374, and 1043 sections is 2086 analyzer builds for a file whose
        // language barely changes between neighbouring 3-second slices. Under ten minutes `standard`
        // is right — it is the preset measured to recover all four turns of the 17-second bilingual
        // fixture, where `longForm` finds one.
        let options: SpeechSegmenter.Options = info.duration > 600 ? .longForm : .standard
        let runner = DualPassImporter(segmenter: SpeechSegmenter(options: options))
        let outcome = try await runner.run(
            decoded: decoded,
            format: format,
            passes: [makePass(primaryPass), makePass(secondaryPass)],
            reporting: reporting
        )
        let elapsed = ContinuousClock.now - began
        return ImportQueue.DualPassJob(
            info: info,
            outcome: outcome,
            wallSeconds: Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
        )
    }

    /// The format the importer must convert to, for one file's language.
    ///
    /// Asked per file, and per *that file's* locale rather than the dictation language: the module is
    /// resolved from the locale, `availableCompatibleAudioFormats` is a property of the module, and a
    /// batch of three files in three languages can therefore want three answers. Returns nil when the
    /// language cannot be served at all — the importer then uses its 16 kHz mono fallback and the real
    /// error arrives from `transcribeImport`, with a sentence the user can act on.
    private func importAnalyzerFormat(localeIdentifier: String) async -> AVAudioFormat? {
        guard let pass = try? await resolvedImportPass(localeIdentifier) else { return nil }
        return await engine.bestAudioFormat(for: pass)
    }

    /// Resolve, reserve and asset-check the module for one import language.
    ///
    /// `resolveImportPass` rather than `resolveImportModule`, and that is the substantive change:
    /// `resolveImportModule` can only ever answer "general or dictation" for a language it assumes is
    /// available, so a locale whose assets are missing quietly ran on whatever was on disk. This one
    /// is allowed to answer `.unavailable`, which is the only honest answer for a language this Mac
    /// cannot transcribe yet — it starts the download and says so. Transcribing Indonesian with the
    /// English model does not fail, it invents proper nouns (RECON amendment 45), so **no silent
    /// fallback to a different language is permissible here**. A fallback between the two *modules* of
    /// the same language still is, and `resolveImportPass` makes exactly that one.
    ///
    /// Memoised inside `SpeechEngine` by requested identifier, so asking twice per file — once for the
    /// format, once for the transcribe — costs one dictionary lookup the second time. That also means
    /// the locale reservation is taken once per language per app run, which matters: RECON §6 allows
    /// only 5 concurrent reservations, and `SpeechEngine.reserve` evicts the ones Edict does not need.
    private func resolvedImportPass(_ localeIdentifier: String) async throws -> SpeechEngine.ImportPass {
        let resolution = await engine.resolveImportPass(
            preferGeneral: settings.importUsesGeneralModel,
            localeIdentifier: localeIdentifier
        )
        switch resolution {
        case .ready(let pass):
            importModuleByLocale[Settings.localeKey(localeIdentifier)] = pass.module
            lastImportModule = pass.module
            return pass
        case .unavailable(let reason):
            throw ImportLocaleUnavailable(localeIdentifier: localeIdentifier, reason: reason)
        }
    }

    private func transcribeImport(
        localeIdentifier: String,
        stream: AsyncStream<AnalyzerInput>,
        onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void
    ) async throws -> TranscriptionOutcome {
        // The locale comes from the queue item, never from `Settings`. That single change is what the
        // per-item locale *is*: a file's language is decided when it is enqueued and travels with it.
        let pass = try await resolvedImportPass(localeIdentifier)
        // Biasing is passed explicitly rather than staged with `setBiasing`, so a file cannot
        // inherit — or clobber — the list a live dictation froze at key-down. It is also empty for
        // the general module, where RECON §1 measured contextual strings as a complete no-op.
        let biasing = pass.module.supportsBiasing
            ? dictionary.biasingStrings(limit: settings.effectiveBiasingLimit)
            : []
        // `SpeechEngineError.sessionAlreadyRunning` must escape unwrapped: `ImportQueue` retries on
        // exactly that error while a live dictation holds the engine's one session.
        return try await engine.transcribe(
            input: stream,
            pass: pass,
            biasing: biasing,
            onUpdate: onUpdate
        )
    }

    /// One finished file becomes one history entry.
    ///
    /// **Nothing here injects.** That is the whole behavioural difference between an import and a
    /// dictation: the user dropped a file on a window, there is no cursor they were aiming at, and
    /// typing a six-minute transcript into whatever happens to be frontmost would be indefensible.
    /// So this method runs the correction pass, writes history, records dictionary hits — and stops.
    /// `TextInjector` is not reachable from it.
    ///
    /// - Returns: the id of the history entry, or `nil` when the file yielded no text (in which case
    ///   nothing is written, so there is nothing to link a queue row to).
    func completeImport(_ result: ImportQueue.Result) -> UUID? {
        let raw = result.outcome.text
        guard !raw.trimmed.isEmpty else {
            Log.data.notice("import produced no text: \(result.info.filename, privacy: .public)")
            return nil
        }

        let corrector = settings.correctionsEnabled
            ? dictionary.corrector(includeTermCaseNormalisation: settings.termCaseNormalisation)
            : Corrector(rules: [])
        let corrected = corrector.isEmpty
            ? CorrectionResult(text: raw, hits: [])
            : corrector.apply(to: raw)

        // A dual-pass transcript is attributed to the language that won the most recognised audio,
        // with the full list beside it — see `Transcript.localeIdentifiers` for why the single field
        // alone would be a false claim. A single-pass one keeps the locale the user chose, which is
        // the only one that could have produced anything.
        let locales = result.localeIdentifiers
        // `result.localeIdentifier`, not `settings.localeIdentifier`: the row's own language is what
        // ran, and reading the setting here would re-open the exact hole this feature closes — a
        // finished Indonesian import filed under `en-US` because the picker moved while it ran.
        let dominant = locales.first ?? result.localeIdentifier
        // The module recorded is the one that produced the dominant language's text. For a
        // single-locale import that is the only module that ran; for a mixed one it is the majority,
        // and `segments` carry the per-section truth.
        let module = result.sections
            .first(where: { $0.chosenLocale == dominant })?
            .candidates.first(where: { $0.localeIdentifier == dominant })?
            .module
            ?? importModuleByLocale[Settings.localeKey(dominant)]
            ?? lastImportModule

        let transcript = Transcript(
            rawText: raw,
            text: corrected.text,
            corrections: corrected.hits,
            // The file's own duration, not the frame count the engine was fed: they agree to within
            // a chunk, and the file's length is the number the user can check.
            audioDuration: result.info.duration > 0 ? result.info.duration : result.outcome.audioDuration,
            // For an import this is the whole job — open, decode, transcribe, finalize — not the
            // end-of-speech latency a dictation reports. It is the number that makes the realtime
            // factor legible in the history pane, which for a file is the interesting one.
            transcribeDuration: result.wallSeconds,
            localeIdentifier: dominant,
            localeIdentifiers: locales,
            engine: module.engineIdentifier,
            // No target and no attempt: see the note above.
            injection: .notAttempted,
            droppedBuffers: result.stats.dropped,
            lowConfidenceWords: Array(result.outcome.lowConfidenceWords.prefix(Self.maxImportSuggestions)),
            source: .imported(filename: result.info.filename),
            segments: Self.correct(result.segments, with: corrector),
            quality: result.quality
        )

        history.append(transcript)
        if !corrected.hits.isEmpty {
            dictionary.recordHits(corrected.hits)
        }

        Log.data.info("""
            import saved: \(result.info.filename, privacy: .public)             \(transcript.wordCount, privacy: .public) words,             \(transcript.segments.count, privacy: .public) segments,             \(corrected.hits.count, privacy: .public) corrections,             module \(module.rawValue, privacy: .public),             locale \(transcript.contributingLocales.joined(separator: "+"), privacy: .public),             quality \(result.quality.verdict.rawValue, privacy: .public),             \(String(format: "%.1f", result.realtimeFactor), privacy: .public)x realtime\
            \(result.incompleteReason == nil ? "" : " INCOMPLETE", privacy: .public)
            """)
        return transcript.id
    }

    /// A whole 377 s file can produce hundreds of sub-0.5 words, and the history pane offers three.
    /// Storing the rest would bloat `history.json` for a list nobody reads.
    private static let maxImportSuggestions = 12

    /// Run the correction pass over the timed segments as well as over the body text.
    ///
    /// Segments are per-word, so this catches every single-token rule — a `.term` casing fix, or
    /// "visa" → "Vercel". It cannot catch a multi-token rule such as "cloud code" → "Claude Code",
    /// because the two halves live in two segments with two different timestamps and there is no
    /// honest way to re-time a merged replacement. Those show corrected in the transcript body and
    /// uncorrected in an exported subtitle cue. The alternative — leaving the segments entirely raw —
    /// is strictly worse, since it loses the single-token fixes too.
    private static func correct(
        _ segments: [TranscriptSegment],
        with corrector: Corrector
    ) -> [TranscriptSegment] {
        guard !corrector.isEmpty else { return segments }
        return segments.map { segment in
            var copy = segment
            copy.text = corrector.apply(to: segment.text).text
            return copy
        }
    }

    // MARK: - Feedback

    private enum Feedback { case start, stop, fault }

    private func playFeedback(_ kind: Feedback) {
        guard settings.playSounds else { return }
        // System sounds only — no bundled audio resources, because RECON §24 rules out declaring
        // `resources:` on the app target at all.
        let name: NSSound.Name = switch kind {
        case .start: "Tink"
        case .stop: "Pop"
        case .fault: "Basso"
        }
        NSSound(named: name)?.play()
    }

    // MARK: - Error text

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// One plain sentence, because this string goes on the status line where the user reads it.
    private static func friendlyMessage(for error: Error) -> String {
        switch error {
        case AudioError.microphoneDenied:
            return "Microphone access is off for Edict."
        case AudioError.noInputDevice:
            return "No microphone is available."
        case AudioError.converterUnavailable:
            return "The microphone format could not be converted."
        case AudioError.engineStartFailed(let why):
            return "The microphone could not start: \(why)"
        case SpeechEngineError.localeUnsupported(let id):
            return "Dictation is not available for \(id)."
        case SpeechEngineError.notPrepared:
            return "The speech model is not ready yet."
        case SpeechEngineError.noAudioFormat:
            return "No compatible audio format for this language."
        case SpeechEngineError.sessionAlreadyRunning:
            return "A dictation is already in progress."
        case SpeechEngineError.reservationFailed(let why), SpeechEngineError.assetInstallFailed(let why):
            return why
        default:
            return "Dictation failed: \(describe(error))"
        }
    }
}

// MARK: - Utterance

/// Everything one utterance needs, frozen at key-down.
///
/// A reference type so the cancel flags can be set from `end()` / `cancel()` while `run(_:)` is
/// suspended inside its feed loop. `@MainActor`-isolated, so the flags need no lock — every writer
/// and the reader are all on the main actor.
@MainActor
private final class Utterance {
    let origin: DictationController.Origin
    let target: InjectionTarget
    let biasing: [String]
    let corrector: Corrector
    /// The format every microphone buffer of this utterance is converted into.
    ///
    /// Frozen at key-down and **not** per-locale, unlike everything else about the language: capture
    /// now opens before the language is known, so the converter cannot be configured from a decision
    /// that has not been made yet. `DictationController.localeDecisionDeferrable` is the guard that
    /// makes this safe — it refuses to defer at all unless the two prepared languages agree on their
    /// analyzer format, which on this machine they do (1 ch / 16 kHz / Int16 / interleaved for both).
    let captureFormat: AVAudioFormat?
    /// What the modifier looked like at arm time. Not the decision — the fallback for the paths that
    /// end an utterance without the monitor ever getting to close the window (a dead tap, the
    /// duration watchdog, Esc, a lost permission). Without it those paths would leave `run(_:)`
    /// suspended on a decision that is never coming, and the app wedged with an utterance in flight.
    let provisional: LocaleDecision
    /// `CaptureStats` is cumulative for the process, so per-utterance drops are a delta.
    let droppedBaseline: Int

    /// The language, once the modifier window has closed. `nil` while the decision is still open.
    ///
    /// This is the whole point of the change: it starts out `nil`, audio is already being captured
    /// against it being `nil`, and the analyzer is built only once it is not.
    private(set) var decision: LocaleDecision?
    /// Suspended `run(_:)` continuations waiting for `decision`. At most one in practice; an array
    /// because a second waiter must not silently overwrite the first.
    private var decisionWaiters: [CheckedContinuation<LocaleDecision, Never>] = []

    var task: Task<Void, Never>?
    var session: (any TranscriptionSession)?
    var stopRequested = false
    var cancelRequested = false

    init(
        origin: DictationController.Origin,
        target: InjectionTarget,
        biasing: [String],
        corrector: Corrector,
        captureFormat: AVAudioFormat?,
        provisional: LocaleDecision,
        droppedBaseline: Int
    ) {
        self.origin = origin
        self.target = target
        self.biasing = biasing
        self.corrector = corrector
        self.captureFormat = captureFormat
        self.provisional = provisional
        self.droppedBaseline = droppedBaseline
    }

    /// Publish the language. Idempotent: the first caller wins, so a window that closes at the same
    /// moment as a release cannot decide twice.
    func settle(_ decision: LocaleDecision) {
        guard self.decision == nil else { return }
        self.decision = decision
        let waiters = decisionWaiters
        decisionWaiters = []
        for waiter in waiters { waiter.resume(returning: decision) }
    }

    /// Wait for the language. Returns immediately when it is already known — which is the common
    /// case for a hold long enough that the window closed while `capture.start()` was awaiting.
    func awaitDecision() async -> LocaleDecision {
        if let decision { return decision }
        return await withCheckedContinuation { continuation in
            decisionWaiters.append(continuation)
        }
    }

    func checkCancelled() throws {
        if cancelRequested { throw CancellationError() }
    }
}

// MARK: - LocaleDecision

/// Which language one utterance runs in, and therefore which analyzer gets built.
///
/// A value rather than three loose fields on `Utterance` so that "the decision" is one thing that is
/// either made or not made. It is what `Utterance.decision` being non-`nil` *means*.
struct LocaleDecision: Sendable, Equatable {
    /// The identifier recorded on the `Transcript`, in Edict's own spelling — `id-ID`, not `id_ID`.
    let localeIdentifier: String
    /// Which of the engine's two prepared locales to build the analyzer from.
    let engineLocale: SpeechEngine.UtteranceLocale
    /// True when the language modifier chose this, for the HUD's tag.
    let isSecondary: Bool
}

// MARK: - LiveTextRelay

/// Carries volatile/committed text from the analyzer's results task to the main actor.
///
/// The engine's `onUpdate` is `@Sendable` and fires from whatever task is draining
/// `DictationTranscriber.results`, at roughly 1 Hz plus every volatile revision. It cannot touch
/// `AppModel`, so it hops — and it coalesces, because a burst of volatile revisions arriving while
/// the main actor is busy laying out the history table should collapse to the newest one rather
/// than queue up a dozen redundant view invalidations.
private final class LiveTextRelay: Sendable {

    private struct Pending {
        var committed = ""
        var volatile = ""
        var dirty = false
        /// True while a hop to the main actor is already in flight, so a burst of revisions costs
        /// one `Task` rather than one per result.
        var scheduled = false
    }

    private let state = Mutex(Pending())
    private let deliver: @MainActor (String, String) -> Void

    init(deliver: @escaping @MainActor (String, String) -> Void) {
        self.deliver = deliver
    }

    func publish(committed: String, volatile: String) {
        let needsHop = state.withLock { pending -> Bool in
            pending.committed = committed
            pending.volatile = volatile
            pending.dirty = true
            guard !pending.scheduled else { return false }
            pending.scheduled = true
            return true
        }

        guard needsHop else { return }
        Task { @MainActor in
            let latest = self.state.withLock { pending -> (String, String)? in
                pending.scheduled = false
                guard pending.dirty else { return nil }
                pending.dirty = false
                return (pending.committed, pending.volatile)
            }
            if let latest { self.deliver(latest.0, latest.1) }
        }
    }
}
