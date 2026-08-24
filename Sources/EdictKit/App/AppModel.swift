import Foundation
import Observation
import SwiftUI

// MARK: - DictationPhase

/// Where the one-utterance-at-a-time state machine currently is.
///
/// `arming` is not cosmetic: `HotkeyMonitor` deliberately withholds `.pressed` until the key has
/// been held past its arm delay (RECON §13 — a bare tap of Right Option is AltGr on many layouts,
/// not dictation), and the engine + audio bring-up that follows takes a few milliseconds more. The
/// user gets a lamp during that window instead of a UI that appears to have ignored them.
public enum DictationPhase: Sendable, Hashable {
    case idle
    /// Hotkey held, session and microphone coming up. Nothing is being recorded yet.
    case arming
    /// Capturing and streaming into the analyzer.
    case listening
    /// Audio is closed; waiting for the final result. RECON measured 0.15–0.53 s here.
    case transcribing
    /// Running the correction pass and the injection ladder.
    case injecting
    case error(String)

    /// True whenever a new utterance must not be started.
    public var isActive: Bool {
        switch self {
        case .idle, .error: return false
        case .arming, .listening, .transcribing, .injecting: return true
        }
    }

    /// True while the microphone is open. Drives the record lamp and the live meter.
    public var isCapturing: Bool {
        switch self {
        case .arming, .listening: return true
        default: return false
        }
    }

    public var errorMessage: String? {
        if case .error(let message) = self { return message }
        return nil
    }
}

// MARK: - AppModel

/// The single main-actor façade the views bind to.
///
/// Everything below this line is view-facing state. The engine actors (`AudioCapture`,
/// `SpeechEngine`, `TextInjector`, `HotkeyMonitor`) live behind `DictationController` and are never
/// exposed, so a view can never accidentally `await` an audio actor during layout.
///
/// **The 60 Hz level path deliberately does not go through `@Observable`.** `levelMeter` is a plain
/// `let` — invisible to the observation machinery — and views drive it from their own
/// `TimelineView(.animation)`. Publishing a needle position sixty times a second would invalidate
/// every view observing this object sixty times a second. `level` exists for the contract and for
/// consumers that cannot run a render timeline (the menu-bar extra), and is refreshed at
/// `coarseLevelHz`, not at frame rate.
@MainActor @Observable
public final class AppModel {

    public static let shared = AppModel()

    // MARK: Transport state

    public private(set) var phase: DictationPhase = .idle

    /// Coarse level for readouts that have no render timeline. See the note above: this is **not**
    /// the meter path. Use `levelMeter` for anything that draws.
    public private(set) var level: AudioFrame = .silent

    /// Seconds of the utterance in flight, published at `elapsedHz`.
    public private(set) var elapsed: TimeInterval = 0

    /// Committed text — the only text that is ever injected (RECON §4).
    public private(set) var committedText: String = ""

    /// The unstable tail the engine may still revise. Draw it visually distinct; never inject it.
    public private(set) var volatileText: String = ""

    /// `committedText + volatileText`, the HUD's single string.
    public private(set) var liveText: String = ""

    public private(set) var modelState: ModelState = .unavailable("starting up")

    public private(set) var lastOutcome: InjectionOutcome?

    /// The transcript just produced, so a view can flash it without re-querying history.
    public private(set) var lastTranscript: Transcript?

    /// False when the global hotkey is not actually live — denied Input Monitoring, a stripped
    /// event mask, or a tap the window server killed. The one thing a user needs told about
    /// loudly, because the app otherwise looks like it simply does not work.
    public private(set) var hotkeyLive: Bool = false

    /// Set when the capture layer dropped buffers or the converter failed during the last
    /// utterance. RECON §20: a stalled consumer silently deletes the *beginning* of the utterance
    /// and it reads as a model failure, so it has to be surfaced.
    public private(set) var lastCaptureSuspect: Bool = false

    // MARK: Stores

    public let settings: Settings
    public let dictionary: DictionaryStore
    public let history: HistoryStore
    public let permissions: Permissions

    /// The 60 Hz meter. A `let`, so `@Observable` never sees it; hand it straight to `VUMeter` /
    /// `Waveform` and drive it from a `TimelineView`.
    @ObservationIgnored public let levelMeter = LevelMeter()

    @ObservationIgnored public let controller: DictationController

    // MARK: Tuning

    /// The coarse `level` publish rate. Deliberately two orders of magnitude below the needle so
    /// an `@Observable` write does not happen per frame.
    private static let coarseLevelHz: Double = 12
    /// `SegmentCounter(.elapsed:)` renders tenths, so ten publishes a second is exactly enough.
    private static let elapsedHz: Double = 10

    private var tickers: Task<Void, Never>?
    private var didBootstrap = false

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
        self.controller = DictationController(
            settings: settings,
            dictionary: dictionary,
            history: history,
            permissions: permissions
        )
        // Two-phase on purpose: `self` is only usable once every stored property has a value, and
        // the controller must not hold a strong reference back (it would be a permanent cycle
        // through a singleton, which leak checkers rightly complain about).
        controller.attach(model: self)
        levelMeter.attach(to: controller.levelSource)
    }

    // MARK: Derived, for the views

    /// The window's and the menu bar's one-line status.
    public var statusLine: String {
        if let message = phase.errorMessage { return message }
        switch modelState {
        case .unavailable(let why): return why
        case .needsDownload: return "Speech model not installed"
        case .downloading(let fraction): return "Downloading model \(Int(fraction * 100))%"
        case .ready: break
        }
        if !permissions.allCriticalGranted, let missing = permissions.missingCritical.first {
            return "\(missing.title) required"
        }
        if !hotkeyLive { return "Hotkey inactive" }
        switch phase {
        case .idle: return "Hold \(settings.hotkey.displayName) to dictate"
        case .arming: return "Arming"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .injecting: return "Inserting text"
        case .error(let message): return message
        }
    }

    /// The same thing shaped for `StatusReadout`, so no view has to re-derive it.
    public var statusCondition: StatusReadout.Condition {
        if let message = phase.errorMessage { return .fault(message) }
        if case .downloading(let fraction) = modelState { return .downloading(fraction) }
        if case .unavailable(let why) = modelState, phase == .idle { return .fault(why) }
        if !permissions.allCriticalGranted, let missing = permissions.missingCritical.first {
            return .needsPermission(missing.title)
        }
        if !hotkeyLive { return .needsPermission(PermissionKind.inputMonitoring.title) }
        switch phase {
        case .idle: return .ready
        case .arming: return .armed
        case .listening: return .listening
        case .transcribing: return .transcribing
        case .injecting: return .injecting
        case .error(let message): return .fault(message)
        }
    }

    public var lampMode: RecordLamp.Mode {
        switch phase {
        case .idle: return .off
        case .arming: return .armed
        case .listening: return .recording
        case .transcribing, .injecting: return .armed
        case .error: return .fault
        }
    }

    public var isRecording: Bool { phase.isCapturing }
    public var canStartRecording: Bool { !phase.isActive }

    // MARK: Lifecycle

    /// Called exactly once from `EdictApp`. Everything expensive is deferred so first paint is
    /// not blocked (RECON §26 pre-warm work in particular).
    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await controller.bootstrap()
    }

    /// Called from `applicationWillTerminate`. Flushing matters: both stores debounce their writes,
    /// so a dictation from the last half-second would otherwise be lost.
    public func shutdown() {
        stopTickers()
        controller.shutdown()
        history.flushPendingSave()
        dictionary.flushPendingSave()
    }

    // MARK: Transport commands

    public func toggleRecording() {
        if phase.isCapturing {
            stopRecording()
        } else if canStartRecording {
            startRecording()
        }
    }

    /// The Record button. `origin: .app` tells the controller this utterance was started from
    /// Edict's own window, so the frontmost-app target is meaningless and injection is skipped.
    public func startRecording() {
        controller.begin(origin: .app)
    }

    public func stopRecording() {
        controller.end()
    }

    public func cancelRecording() {
        controller.cancel()
    }

    /// Clear a terminal error so the transport is usable again without relaunching.
    public func clearError() {
        if case .error = phase { apply(phase: .idle) }
    }

    public func retryHotkey() {
        controller.restartHotkey()
    }

    // MARK: Controller callbacks
    //
    // `internal`, not `public`: only `DictationController` may move this state, and the views must
    // see it as read-only or the single-writer invariant is gone.

    func apply(phase newPhase: DictationPhase) {
        guard phase != newPhase else { return }
        phase = newPhase
        if newPhase.isCapturing {
            startTickers()
        } else {
            stopTickers()
        }
        if newPhase == .idle {
            elapsed = 0
            level = .silent
            levelMeter.reset()
        }
    }

    func apply(committed: String, volatile: String) {
        guard committedText != committed || volatileText != volatile else { return }
        committedText = committed
        volatileText = volatile
        liveText = committed + volatile
    }

    func clearLiveText() {
        apply(committed: "", volatile: "")
    }

    func apply(modelState newState: ModelState) {
        guard modelState != newState else { return }
        modelState = newState
    }

    func apply(hotkeyLive live: Bool) {
        guard hotkeyLive != live else { return }
        hotkeyLive = live
    }

    func finished(transcript: Transcript) {
        lastTranscript = transcript
        lastOutcome = transcript.injection
        lastCaptureSuspect = transcript.mayBeIncomplete
    }

    // MARK: Tickers

    /// One task drives both the elapsed counter and the coarse level, because they are the same
    /// kind of work — read a value someone else owns, publish it at a human rate — and one task is
    /// one cancellation point instead of two.
    private func startTickers() {
        guard tickers == nil else { return }
        let started = ContinuousClock.now
        let levelPeriod = 1.0 / Self.coarseLevelHz
        let elapsedPeriod = 1.0 / Self.elapsedHz
        let period = min(levelPeriod, elapsedPeriod)

        tickers = Task { [weak self] in
            var lastLevelPublish = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(period))
                guard let self, self.phase.isCapturing else { return }

                self.elapsed = Double(started.duration(to: .now).components.seconds)
                    + Double(started.duration(to: .now).components.attoseconds) / 1e18

                let now = ContinuousClock.now
                if lastLevelPublish.duration(to: now) >= .seconds(levelPeriod) {
                    lastLevelPublish = now
                    let snapshot = self.controller.levelSource.levelSnapshot
                    let frame = AudioFrame(
                        rms: Float(D.meter.fraction(dbfs: Double(snapshot.rmsDBFS))),
                        peak: Float(D.meter.fraction(dbfs: Double(snapshot.peakDBFS))),
                        dbfs: snapshot.rmsDBFS
                    )
                    if frame != self.level { self.level = frame }
                }
            }
        }
    }

    private func stopTickers() {
        tickers?.cancel()
        tickers = nil
    }
}
