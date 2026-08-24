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
///     hotkey down → read the dictionary → engine session → microphone → stream audio
///                 → hotkey up → finalize → Corrector.apply → TextInjector.inject
///                 → HistoryStore.append → DictionaryStore.recordHits
///
/// Three invariants govern everything below, and each one is a bug that has already been paid for
/// somewhere in `RECON.md`:
///
/// 1. **The dictionary is read at key-down and never again.** `AnalysisContext` can only be handed
///    to `SpeechAnalyzer.init`; `setContext(_:)` mid-stream is a measured silent no-op (RECON §2).
///    Key-down is therefore the *only* moment biasing can be chosen, and it is also the moment the
///    ~65 ms + ~1.5 ms/term setup cost is free, because it hides behind the user's speech onset.
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
    private var permissionsTask: Task<Void, Never>?
    private var prewarmTask: Task<Void, Never>?

    /// Cached so key-down does not pay an actor round-trip for a value that changes only when the
    /// locale changes.
    private var analyzerFormat: AVAudioFormat?

    private var appliedHotkey: HotkeyChoice?
    private var appliedLocale: String?

    /// Press-to-start / press-to-stop bookkeeping for `Settings.pushToTalk == false`.
    private var toggleLatched = false

    private var didBootstrap = false

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
        permissions: Permissions = .shared
    ) {
        self.settings = settings
        self.dictionary = dictionary
        self.history = history
        self.permissions = permissions
        self.hotkey = HotkeyMonitor()
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

        // RECON §26: retain a CGEventSource, build and discard one CGEvent, touch AXIsProcessTrusted
        // and do one throwaway system-wide AX read. Without this the *first* dictation of a session
        // pays the whole window-server + TCC bootstrap while the user watches.
        await injector.prewarm()
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
        permissionsTask?.cancel()
        hotkey.stop()
        dictionary.stopWatchingFile()
        // Fire-and-forget: the process is going away, and a synchronous wait on an actor from
        // `applicationWillTerminate` is how an app hangs on quit.
        let capture = self.capture
        Task.detached { await capture.teardown() }
    }

    // MARK: - Hotkey

    private func startHotkey() {
        hotkeyEventsTask?.cancel()
        hotkeyDiagnosticsTask?.cancel()

        let key = settings.hotkey
        do {
            try hotkey.start(key: key)
            appliedHotkey = key
            model?.apply(hotkeyLive: true)
            Log.hotkey.info("monitor live on \(key.rawValue, privacy: .public)")
        } catch {
            appliedHotkey = nil
            model?.apply(hotkeyLive: false)
            Log.hotkey.error("monitor failed to start: \(Self.describe(error), privacy: .public)")
        }

        // Consume both streams unconditionally, even when start() failed: a later permission grant
        // re-creates the tap and these consumers must already be in place.
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

    /// RECON §11 is categorical: a tap created while access was denied is *permanently* dead and
    /// re-enabling it does nothing. The only repair is destroy-and-recreate.
    public func restartHotkey() {
        hotkey.stop()
        startHotkey()
    }

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .pressed:
            if settings.pushToTalk {
                begin(origin: .hotkey)
            } else if toggleLatched {
                toggleLatched = false
                end()
            } else {
                begin(origin: .hotkey)
                // Latched only if the utterance actually started. Otherwise a refused `begin`
                // would leave the toggle armed and the *next* press would stop nothing.
                toggleLatched = utterance != nil
            }

        case .released:
            // In toggle mode the release of the *starting* press must not stop anything.
            guard settings.pushToTalk else { return }
            end()
        }
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
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.settingsChanged()
                self.observeSettings()
            }
        }
    }

    private func settingsChanged() {
        if settings.hotkey != appliedHotkey {
            let key = settings.hotkey
            appliedHotkey = key
            if hotkey.isRunning {
                hotkey.update(key: key)
                Log.hotkey.info("rebound to \(key.rawValue, privacy: .public)")
            } else {
                startHotkey()
            }
        }

        if settings.localeIdentifier != appliedLocale {
            let locale = settings.localeIdentifier
            Task { [weak self] in await self?.prepareEngine(localeIdentifier: locale) }
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
    public func begin(origin: Origin) {
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
        let biasing = dictionary.biasingStrings(limit: settings.effectiveBiasingLimit)
        // Layer 2 of the two-layer dictionary: the guaranteed find-and-replace pass. Compiled now
        // so a dictionary edit mid-utterance cannot change the rules under the transcript.
        let corrector = settings.correctionsEnabled
            ? dictionary.corrector(includeTermCaseNormalisation: settings.termCaseNormalisation)
            : Corrector(rules: [])

        let target = origin == .app
            ? InjectionTarget(bundleID: Self.ownBundleID, appName: "Edict")
            : TextInjector.currentTarget()

        let unit = Utterance(
            origin: origin,
            target: target,
            biasing: biasing,
            corrector: corrector,
            localeIdentifier: settings.localeIdentifier,
            droppedBaseline: capture.statsSnapshot.dropped
        )
        utterance = unit

        model?.clearLiveText()
        model?.apply(phase: .arming)
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
        Log.engine.notice("utterance cancelled")
        let capture = self.capture
        Task { await capture.stop() }
    }

    // MARK: - The sequence

    private func run(_ unit: Utterance) async {
        // Tracked so the guaranteed teardown below can tell "never started" from "started".
        var audioStarted = false
        var session: (any TranscriptionSession)?
        var watchdog: Task<Void, Never>?

        do {
            await engine.setBiasing(unit.biasing)

            // Sendable box: the update callback fires off the main actor from the analyzer's
            // results task, so it hops rather than touching `AppModel` directly.
            let sink = LiveTextRelay { [weak self] committed, volatile in
                self?.model?.apply(committed: committed, volatile: volatile)
            }
            let started = try await engine.begin(onUpdate: { update in
                sink.publish(committed: update.finalText, volatile: update.volatileText)
            })
            session = started
            unit.session = started

            // A cancel or a very fast tap can land while `begin` was awaiting. Bail before the
            // microphone is ever opened.
            try unit.checkCancelled()

            let stream = try await capture.start(targetFormat: analyzerFormat)
            audioStarted = true
            model?.apply(phase: .listening)

            watchdog = Task { [weak self] in
                try? await Task.sleep(for: Self.maxUtteranceDuration)
                guard !Task.isCancelled else { return }
                Log.engine.error("utterance exceeded the maximum duration; forcing a stop")
                self?.end()
            }

            // The user may have released the key while `start` was awaiting; `stop()` is safe to
            // call before the first buffer and simply finishes the stream immediately.
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
            await session?.abort()
            await engine.cancel()

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
        model?.apply(phase: .injecting)

        let dropped = max(0, capture.statsSnapshot.dropped - unit.droppedBaseline)
        let raw = outcome.text

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

        let injection = await inject(corrected.text, unit: unit)

        let transcript = Transcript(
            rawText: raw,
            text: corrected.text,
            corrections: corrected.hits,
            audioDuration: outcome.audioDuration,
            transcribeDuration: outcome.latency,
            localeIdentifier: unit.localeIdentifier,
            targetBundleID: unit.target.bundleID,
            targetAppName: unit.target.appName,
            injection: injection,
            droppedBuffers: dropped,
            lowConfidenceWords: outcome.lowConfidenceWords
        )

        if !raw.isEmpty {
            history.append(transcript)
        }
        if !corrected.hits.isEmpty {
            dictionary.recordHits(corrected.hits)
        }

        utterance = nil
        model?.apply(committed: corrected.text, volatile: "")
        model?.finished(transcript: transcript)
        model?.apply(phase: .idle)
        playFeedback(injection.isSuccess || injection == .notAttempted ? .stop : .fault)

        Log.engine.info("""
            utterance done: \(transcript.wordCount, privacy: .public) words in \
            \(outcome.audioDuration, format: .fixed(precision: 2), privacy: .public) s, \
            latency \(outcome.latency, format: .fixed(precision: 3), privacy: .public) s, \
            \(corrected.hits.count, privacy: .public) corrections, \
            injection \(injection.rawValue, privacy: .public)\
            \(dropped > 0 ? ", DROPPED \(dropped) buffers" : "")
            """)
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
    let localeIdentifier: String
    /// `CaptureStats` is cumulative for the process, so per-utterance drops are a delta.
    let droppedBaseline: Int

    var task: Task<Void, Never>?
    var session: (any TranscriptionSession)?
    var stopRequested = false
    var cancelRequested = false

    init(
        origin: DictationController.Origin,
        target: InjectionTarget,
        biasing: [String],
        corrector: Corrector,
        localeIdentifier: String,
        droppedBaseline: Int
    ) {
        self.origin = origin
        self.target = target
        self.biasing = biasing
        self.corrector = corrector
        self.localeIdentifier = localeIdentifier
        self.droppedBaseline = droppedBaseline
    }

    func checkCancelled() throws {
        if cancelRequested { throw CancellationError() }
    }
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
