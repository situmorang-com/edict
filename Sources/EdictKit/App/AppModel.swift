import AppKit
import Foundation
import Observation
import ServiceManagement
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
    /// The on-device language model is cleaning the text up before it is inserted. Only reachable
    /// when `Settings.refineBeforeInsert` is on.
    ///
    /// A phase of its own rather than a longer `injecting`, for one reason: it is the only phase in
    /// this machine measured in *seconds* rather than milliseconds — 1.0 s warm, 2.9 s cold — and a
    /// HUD that says "Inserting" for three seconds while nothing moves is indistinguishable from a
    /// hang. The user is waiting on this with their cursor parked in another app, so it has to be
    /// able to say what it is doing.
    case refining
    /// Running the correction pass and the injection ladder.
    case injecting
    case error(String)

    /// True whenever a new utterance must not be started.
    public var isActive: Bool {
        switch self {
        case .idle, .error: return false
        case .arming, .listening, .transcribing, .refining, .injecting: return true
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

// MARK: - LoginItem

/// "Open at login", wired to `SMAppService` and reporting **what macOS actually did**.
///
/// This exists because the switch that used to be here was inert: `Settings.launchAtLogin` persisted a
/// boolean and no `SMAppService` call existed in the whole app. The lesson taken from that is not "call
/// register()" — it is that the control must never show the user's *intent*. So `state` is only ever
/// assigned from a fresh read of `SMAppService.mainApp.status`, including immediately after a
/// `register()` that returned without throwing. If macOS disagrees with the press, the switch snaps
/// back and `failure` says why.
///
/// Three things that are easy to get wrong here, all handled below:
///
/// * **`.requiresApproval` is a success, not an error.** macOS registered the job but is waiting for
///   the user to switch it on in System Settings ▸ General ▸ Login Items. `register()` does not throw
///   in that case, so treating a non-throwing call as "on" and stopping there produces a switch that
///   claims a login item the system will not run.
/// * **`SMAppService` needs a real bundle launched by LaunchServices.** Under `swift run` there is no
///   `.app` around the executable, `status` reports `.notFound`, and `register()` throws — so the
///   control reports itself unavailable with a reason instead of failing on every press.
/// * **The state can change behind Edict's back.** The user can remove the login item in System
///   Settings while Edict runs. `refresh()` is therefore called every time the pane appears and every
///   time the app is activated, rather than once at launch.
@MainActor @Observable
public final class LoginItem {

    /// What macOS will actually do at the next login.
    public enum State: Sendable, Hashable {
        /// Registered and enabled: Edict launches at login.
        case enabled
        /// Not registered.
        case disabled
        /// Registered, but switched off (or not yet switched on) by the user in Login Items. macOS
        /// will **not** launch Edict until they do.
        case requiresApproval
        /// `SMAppService` cannot work in this launch — the string says why.
        case unavailable(String)

        /// What the rocker plate shows. `.requiresApproval` reads as on because Edict *is* registered
        /// and the remaining step is the user's, in another app.
        public var isOn: Bool {
            switch self {
            case .enabled, .requiresApproval: true
            case .disabled, .unavailable: false
            }
        }

        /// The word in the lit window beside the switch.
        public var displayName: String {
            switch self {
            case .enabled: "On"
            case .disabled: "Off"
            case .requiresApproval: "Needs approval"
            case .unavailable: "Unavailable"
            }
        }

        /// True when the row should carry the alert tell-tale.
        public var isFault: Bool {
            switch self {
            case .enabled, .disabled: false
            case .requiresApproval, .unavailable: true
            }
        }
    }

    /// The last read of `SMAppService.mainApp.status`, never an assumption about it.
    public private(set) var state: State = .disabled

    /// Why the last press did not do what it looked like it would. Cleared by a successful change.
    public private(set) var failure: String?

    /// True while `set(_:)` is in flight, so the plate cannot be flipped into a second call.
    public private(set) var isBusy = false

    /// The service, or nil when this process cannot use one. Injected so tests and previews can drive
    /// the state machine without touching the real login-item database.
    private let service: (any LoginItemService)?

    public init(service: (any LoginItemService)? = SystemLoginItemService.resolve()) {
        self.service = service
        refresh()
    }

    /// Read reality. Cheap — a `launchd` query, no disk I/O.
    public func refresh() {
        guard let service else {
            state = .unavailable("Edict is not running from an app bundle")
            return
        }
        state = Self.state(for: service.status)
    }

    /// Ask macOS to change it, then **read back what happened**.
    ///
    /// Deliberately not `async`: `SMAppService.register()` and `unregister()` are synchronous and
    /// return in well under a frame, and an `await` here would open a window in which the plate showed
    /// a state nothing had confirmed yet.
    public func set(_ on: Bool) {
        guard let service else {
            failure = "Edict has to be in your Applications folder and launched normally for this to work."
            refresh()
            return
        }
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            if on { try service.register() } else { try service.unregister() }
            failure = nil
        } catch {
            // The `register()` return is not the answer either way, so the message is recorded and the
            // state still comes from the status read below.
            failure = Self.explain(error, registering: on)
            let verb = on ? "register" : "unregister"
            let why = error.localizedDescription
            Log.data.error("login item \(verb, privacy: .public) failed: \(why, privacy: .public)")
        }
        refresh()
        Log.data.notice("login item is now \(String(describing: self.state), privacy: .public)")
    }

    /// Opens System Settings ▸ General ▸ Login Items, which is the only place `.requiresApproval` can
    /// be resolved. Uses the framework's own opener rather than an `x-apple.systempreferences:` URL, so
    /// it keeps working if Apple moves the pane.
    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: Pure mapping
    //
    // Split out so the whole state machine is testable without a login-item database.

    static func state(for status: SMAppService.Status) -> State {
        switch status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable("macOS has no record of this copy of Edict")
        @unknown default: return .unavailable("macOS reported a state Edict does not know")
        }
    }

    static func explain(_ error: any Error, registering: Bool) -> String {
        let ns = error as NSError
        // Code 1 is the one a self-signed or oddly-placed bundle actually produces; the rest are
        // reported verbatim rather than guessed at.
        if ns.domain == "SMAppServiceErrorDomain" && ns.code == 1 {
            return registering
                ? "macOS refused the login item. Move Edict to your Applications folder and try again."
                : "macOS refused to remove the login item."
        }
        return ns.localizedDescription
    }
}

// MARK: - LoginItemService

/// The two calls `LoginItem` makes, behind a seam so its state machine can be tested.
public protocol LoginItemService: Sendable {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

/// `SMAppService.mainApp`, plus the one precondition that cannot be recovered from.
public struct SystemLoginItemService: LoginItemService {

    public init() {}

    public var status: SMAppService.Status { SMAppService.mainApp.status }
    public func register() throws { try SMAppService.mainApp.register() }
    public func unregister() throws { try SMAppService.mainApp.unregister() }

    /// nil when this process is not an app bundle at all.
    ///
    /// RECON is explicit that a bare SwiftPM executable has no bundle identity, and `SMAppService`
    /// needs one: under `swift run` every call here would throw and the switch would look broken rather
    /// than inapplicable. Checked once, at the only place that can act on the answer.
    public static func resolve() -> SystemLoginItemService? {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier != nil
        else {
            Log.data.notice("no app bundle; the login-item switch is unavailable in this launch")
            return nil
        }
        return SystemLoginItemService()
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

    /// The language of the utterance in flight, or `nil` when nothing is being dictated.
    ///
    /// Published live because the locale is fixed for the whole utterance and chosen by a modifier the
    /// user pressed a tenth of a second ago: if the chord did not register, the only moment they can
    /// notice is *while speaking*, and the fix is free (release, press again). Learning it afterwards
    /// from a history row is learning it too late.
    public private(set) var activeLocaleIdentifier: String?

    /// True while the in-flight utterance is running in the secondary language. Separate from a string
    /// comparison so a view can style the badge without knowing what the two locales are.
    public private(set) var activeLocaleIsSecondary: Bool = false

    /// False when the language shortcut is configured but the engine could not prepare it — an
    /// unsupported identifier, a failed reservation, or assets that are not on disk yet. The modifier
    /// silently does nothing in that state, so the UI has to be able to say so.
    public private(set) var secondaryLocaleReady: Bool = false

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

    /// Wall-clock seconds the on-device model has been refining the utterance in flight; zero in
    /// every other phase.
    ///
    /// This exists because `.refining` is the one wait in this app long enough to need evidence that
    /// it is a wait and not a stall. Measured 1.0 s warm and 2.9 s cold — long enough that a frozen
    /// HUD reads as a hang, and Apple's framework reports no progress at all, so a bar would be
    /// fiction. A counter climbing through tenths is the honest version of the same reassurance, and
    /// it is also the number that tells the user what the switch they turned on actually costs them.
    ///
    /// Separate from `elapsed`, which counts *speech*: adding refinement seconds to it would make
    /// the HUD claim the user talked for longer than they did.
    public private(set) var refineElapsed: TimeInterval = 0

    // MARK: Stores

    public let settings: Settings
    public let dictionary: DictionaryStore
    public let history: HistoryStore
    public let permissions: Permissions

    /// "Open at login", reading its state from `SMAppService` rather than from a preference.
    public let loginItem: LoginItem

    /// The 60 Hz meter. A `let`, so `@Observable` never sees it; hand it straight to `VUMeter` /
    /// `Waveform` and drive it from a `TimelineView`.
    @ObservationIgnored public let levelMeter = LevelMeter()

    @ObservationIgnored public let controller: DictationController

    /// The batch queue behind file transcription. `@ObservationIgnored` because it is a `let` that
    /// never changes and is itself `@Observable` — views bind to *its* properties directly, so
    /// routing them through this object would only add a second invalidation source.
    @ObservationIgnored public let importQueue: ImportQueue

    /// The on-device refinement surface's state, and the one `TextRefiner` the app owns.
    ///
    /// One instance, shared with `DictationController`, because `TextRefiner` keeps pre-warmed
    /// `LanguageModelSession`s: a second refiner would mean a second cold start, and the measured
    /// difference between cold and warm is 2.9 s against 1.0 s. `@ObservationIgnored` for the same
    /// reason as `importQueue` — it is a `let` that is itself `@Observable`.
    @ObservationIgnored public let refinement: RefinementStore

    // MARK: Window state

    /// Which rail stop the main window is showing.
    ///
    /// Lives here rather than in `MainWindow`'s `@State` because two things outside the view move
    /// it: the ⌘O menu command, which must land the user on the queue it just filled, and a dropped
    /// file, which can arrive while any pane is showing.
    var pane: Pane = .history

    // MARK: Tuning

    /// The coarse `level` publish rate. Deliberately two orders of magnitude below the needle so
    /// an `@Observable` write does not happen per frame.
    private static let coarseLevelHz: Double = 12
    /// `SegmentCounter(.elapsed:)` renders tenths, so ten publishes a second is exactly enough.
    private static let elapsedHz: Double = 10

    private var tickers: Task<Void, Never>?
    /// See `startRefineTicker()`.
    private var refineTicker: Task<Void, Never>?
    private var didBootstrap = false

    // MARK: Init

    /// - Parameter loginItem: injected so previews and the offscreen render harness can show all four
    ///   states of the switch — including `.requiresApproval`, which cannot be reached on demand on a
    ///   machine where `SMAppService.register()` goes straight to `.enabled`.
    public init(
        settings: Settings = .shared,
        dictionary: DictionaryStore = .shared,
        history: HistoryStore = .shared,
        permissions: Permissions = .shared,
        loginItem: LoginItem = LoginItem()
    ) {
        self.settings = settings
        self.dictionary = dictionary
        self.history = history
        self.permissions = permissions
        self.loginItem = loginItem
        // Built before the controller so both hold the same refiner. See `refinement`.
        let refinement = RefinementStore()
        self.refinement = refinement
        let controller = DictationController(
            settings: settings,
            dictionary: dictionary,
            history: history,
            permissions: permissions,
            refiner: refinement.refiner
        )
        self.controller = controller
        self.importQueue = ImportQueue(environment: controller.importEnvironment())
        // Two-phase on purpose: `self` is only usable once every stored property has a value, and
        // the controller must not hold a strong reference back (it would be a permanent cycle
        // through a singleton, which leak checkers rightly complain about).
        controller.attach(model: self)
        levelMeter.attach(to: controller.levelSource)
        // `controller`, not `self`: the queue must not keep the model alive, and the controller is
        // the only thing it needs. `AppModel → importQueue → controller` and `AppModel → controller`
        // are both one-way, so there is no cycle to break.
        importQueue.onFinish = { [controller] result in controller.completeImport(result) }
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
        case .idle:
            // The secondary language is discoverable only from here. A modifier nobody is told about
            // is a feature nobody uses, and there is no other surface — the app has no menu of modes.
            let base = "Hold \(settings.hotkey.displayName) to dictate"
            guard secondaryLocaleReady, let secondary = settings.effectiveSecondaryLocaleIdentifier else {
                return base
            }
            return "\(base) — add \(settings.secondaryLocaleModifier.glyph) for \(Self.badge(secondary))"
        case .arming: return "Arming"
        case .listening:
            // The badge prints for BOTH languages once a second one is configured, not just for the
            // unusual one. A readout that appears only when something unexpected happened is read as
            // decoration until the day it matters; a channel that always says which model is running
            // is the thing a user can learn to glance at — and glancing at it mid-sentence is the
            // only moment the wrong language is still free to fix. With one language configured it
            // stays plain "Listening": a badge that can never change indicates nothing, which is the
            // same argument `AppModel.tagCode` makes about `EN` against `EN`.
            guard secondaryLocaleReady, settings.effectiveSecondaryLocaleIdentifier != nil else {
                return "Listening"
            }
            return "Listening (\(localeBadge))"
        case .transcribing: return "Transcribing"
        case .refining: return "Cleaning the text up"
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
        case .refining: return .refining
        case .injecting: return .injecting
        case .error(let message): return .fault(message)
        }
    }

    public var lampMode: RecordLamp.Mode {
        switch phase {
        case .idle: return .off
        case .arming: return .armed
        case .listening: return .recording
        case .transcribing, .refining, .injecting: return .armed
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
        observeForegroundApp()
        loginItem.refresh()
        await refreshLearnedPolicies()
        await controller.bootstrap()
    }


    /// Called from `applicationWillTerminate`. Flushing matters: both stores debounce their writes,
    /// so a dictation from the last half-second would otherwise be lost.
    public func shutdown() {
        if let foregroundObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }
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

    // MARK: File import

    /// Queue files for transcription and show the queue.
    ///
    /// The pane switch is not decoration: a file dropped while the dictionary pane is showing would
    /// otherwise vanish into a queue the user has no reason to look for, and the one thing they need
    /// to know — that the transcript goes to history and **not** to their cursor — is printed there.
    public func enqueueImports(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        // `nil` means "inherit the dictation language, now, and freeze it onto each row" — see
        // `ImportQueue.enqueue`. Passing the override through rather than mutating Settings keeps
        // the two facts separate: the dictation language is what the hotkey uses, and this is what
        // the next file uses.
        let added = importQueue.enqueue(urls, localeIdentifier: importLocaleOverride)
        guard !added.isEmpty else { return }
        pane = .imports
    }

    /// The language files added from now on are transcribed in, or `nil` to follow the dictation
    /// language.
    ///
    /// Deliberately **not** persisted to `Settings`. Two reasons, and the second is the real one.
    /// The advertised default is "follow my dictation language, and show me", so the resting state
    /// has to be the one that tracks Settings rather than a stale copy of it; and a language pinned
    /// months ago in a pane the user has since forgotten is exactly the silent, invisible override
    /// that transcribed a 70-minute Indonesian meeting with an English model. A per-launch override
    /// cannot rot. Each row still carries its own frozen copy, so nothing already queued moves.
    public var importLocaleOverride: String?

    /// Every locale an import can run. Empty until `ImportQueue.loadSupportedLocales()` answers.
    ///
    /// Read from the queue rather than from `DictationTranscriber` directly, because the queue is
    /// what normalises `id_ID` to `id-ID` and orders by display name — and the picker must offer
    /// exactly the set the queue will accept.
    var importLocales: [String] { importQueue.supportedLocaleIdentifiers }

    /// The second language a dual-pass import will try, or `nil` when dual pass is off. Mirrors
    /// `DictationController.importEnvironment`'s `dualPassPartnerLocaleIdentifier` so the pane
    /// explains the same rule the queue actually applies.
    var importDualPassLocaleIdentifier: String? {
        guard settings.dualPassIsActive else { return nil }
        return settings.effectiveSecondaryLocaleIdentifier
    }

    /// Open the file picker, then queue whatever was chosen.
    public func pickImports() {
        enqueueImports(MediaOpenPanel.pick())
    }

    /// The queue as the pane draws it.
    ///
    /// The mapping lives here rather than in `ImportQueue` because a finished row carries the whole
    /// `Transcript` — the export keys need its segments — and only the model can reach history.
    var importRows: [ImportQueueRow] {
        importQueue.items.map { item in
            ImportQueueRow(
                id: item.id,
                filename: item.filename,
                duration: item.info?.duration,
                isVideo: item.info?.hasVideo ?? false,
                state: rowState(for: item),
                note: note(for: item),
                warning: item.warning,
                // Straight off the item. The queue froze this at enqueue and never re-reads
                // `Settings.localeIdentifier`, which is the whole point of the field — so the row
                // must not "helpfully" fall back to the current dictation language either.
                localeIdentifier: item.localeIdentifier,
                localeWasChosen: item.localeWasChosen,
                localeIsEditable: item.localeIsEditable,
                secondPassLocaleIdentifier: importQueue.secondPassLocaleIdentifier(for: item.id),
                isRerun: item.rerunOf != nil
            )
        }
    }

    /// The neutral progress aside, when there is one to give.
    ///
    /// Only a dual pass has one, and only because only a dual pass can *measure* its position: it
    /// knows how many sections there are before it starts. The single-pass route deliberately says
    /// nothing here, because everything it could say would be the elapsed-time estimate the bar is
    /// already showing (`ImportQueue.progressNote`).
    ///
    /// "\(done) of \(total) passes" and not "passes done", because `done` counts passes **attempted**
    /// — see `DualPassImporter.Reporting.onSections`, where counting only the successful ones left
    /// this readout and the bar advancing at the *surviving* passes' rate on exactly the file that had
    /// lost a section. What failed is a sentence in the row's warning when the job ends, not a word
    /// squeezed into a running counter.
    private func note(for item: ImportQueue.Item) -> String? {
        guard item.id == importQueue.runningItemID,
              case .transcribingSections(let done, let total) = importQueue.runningPhase,
              total > 0 else { return nil }
        return "Two languages per section — \(done) of \(total) passes"
    }

    private func rowState(for item: ImportQueue.Item) -> ImportQueueRow.State {
        switch item.state {
        case .queued:
            return .waiting
        case .running(let progress):
            // The importer's read fraction is real but useless as a bar — decoding runs at
            // 570–4300x realtime and saturates within milliseconds — so `reading` is only ever a
            // label, and the bar belongs to the transcription estimate. See `ImportQueue.Phase`.
            if item.id == importQueue.runningItemID, case .reading(let fraction) = importQueue.runningPhase {
                return .reading(fraction)
            }
            return .transcribing(progress)
        case .done:
            if let id = item.transcriptID, let transcript = history.transcripts.first(where: { $0.id == id }) {
                return .finished(transcript)
            }
            // `.done` with nothing in history means no text was produced. Reporting that as a
            // failure is honest: there is no transcript, so there is nothing to export and nothing
            // to open, and a row saying "Done" with dead keys would be a lie.
            //
            // The *reason* is the row's own warning wherever there is one, and that ordering is the
            // point. "No speech was found in this file." is a diagnosis, and it is only true when
            // the pipeline came through clean — when buffers were refused by the converter or a
            // transcription pass could not run, `ImportQueue` has already put a sentence on the row
            // naming what is missing, and asserting silence over the top of it is the app confidently
            // misreading a recording it never managed to read (finding #1).
            return .failed(item.warning ?? "No speech was found in this file.")
        case .failed(let reason):
            return .failed(reason)
        case .cancelled:
            return .cancelled
        }
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
        if newPhase == .refining {
            startRefineTicker()
        } else {
            stopRefineTicker()
        }
        if newPhase == .idle {
            elapsed = 0
            refineElapsed = 0
            level = .silent
            levelMeter.reset()
        }
        // Cleared here rather than at every exit from `DictationController.run` — success, cancel and
        // error all pass through a non-active phase, so one rule covers all three and none can be
        // forgotten.
        if !newPhase.isActive {
            activeLocaleIdentifier = nil
            activeLocaleIsSecondary = false
        }
    }

    /// The language chosen for the utterance that is starting. Set at key-down, before any audio.
    func apply(activeLocale identifier: String?, isSecondary: Bool) {
        guard activeLocaleIdentifier != identifier || activeLocaleIsSecondary != isSecondary else { return }
        activeLocaleIdentifier = identifier
        activeLocaleIsSecondary = isSecondary
    }

    func apply(secondaryLocaleReady ready: Bool) {
        guard secondaryLocaleReady != ready else { return }
        secondaryLocaleReady = ready
    }

    /// A short label for the active or configured dictation language — "EN", "ID" — for the HUD and
    /// the menu bar, where there is room for two characters and not for "Indonesian (Indonesia)".
    public var localeBadge: String {
        Self.badge(activeLocaleIdentifier ?? settings.localeIdentifier)
    }

    /// One implementation, in `LanguageCode`, because the HUD, the import queue and the history log
    /// all print this and a row that says `EN` in one pane and `en-US` in another reads as two
    /// different facts about the same transcript.
    static func badge(_ identifier: String) -> String { LanguageCode.badge(identifier) }

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

    // MARK: Injection recovery

    /// Re-injection outcomes, keyed by transcript id, for rows the user retried in this session.
    ///
    /// An overlay rather than a rewrite of the stored `Transcript`: `HistoryStore` is another agent's
    /// file and exposes no update, and — more to the point — the stored record is the *history* of what
    /// happened when the user spoke. A retry an hour later into a different app is a new event, so
    /// overwriting the original row's outcome would destroy the only evidence of the original failure.
    /// The cost is that a retry is forgotten on quit, which is correct: the text has landed by then, and
    /// what a stale "retried successfully" badge would mean the next morning is nothing.
    public private(set) var retryOutcomes: [UUID: RetryRecord] = [:]

    /// The row whose retry is in flight, so its key can latch and the others stay pressable.
    public private(set) var retryingTranscriptID: UUID?

    /// One re-injection attempt.
    public struct RetryRecord: Sendable, Hashable {
        public var outcome: InjectionOutcome
        /// The app the text was actually aimed at — never the one in the stored transcript.
        public var appName: String
    }

    /// The app the user was in before they came to Edict. See `observeForegroundApp`.
    public private(set) var lastForegroundApp: ForegroundApp?

    public struct ForegroundApp: Sendable, Hashable {
        public var pid: pid_t
        public var bundleID: String?
        public var name: String
    }

    /// The injector behind the retry key.
    ///
    /// A second `TextInjector`, because `DictationController` keeps its own `private`. That is safe
    /// precisely because the learned policy now lives in one process-wide `InjectPolicyStore` (see
    /// `TextInjector.init(policies:)`) — otherwise "always paste only here", set from the history pane,
    /// would be invisible to the next dictation.
    @ObservationIgnored private let retryInjector = TextInjector()

    @ObservationIgnored private var foregroundObserver: (any NSObjectProtocol)?

    /// A cached copy of the learned map, so a view can read a policy without an `await`.
    public private(set) var learnedPolicies: [String: InjectStrategy] = [:]

    /// The outcome a history row should show: the retry if there was one, otherwise what was recorded.
    public func displayOutcome(for transcript: Transcript) -> InjectionOutcome {
        retryOutcomes[transcript.id]?.outcome ?? transcript.injection
    }

    /// The learned policy for an app, or nil when Edict has not learned one (a seeded or defaulted
    /// strategy is not a *learned* one, and the recovery block says so).
    public func learnedPolicy(for bundleID: String?) -> InjectStrategy? {
        guard let bundleID else { return nil }
        return learnedPolicies[bundleID]
    }

    /// Re-run the injection ladder for a transcript whose text never landed.
    ///
    /// Nothing is re-transcribed — this is the stored string going through `TextInjector` again.
    ///
    /// **It aims at the app the user was last working in, not the one in the transcript.** Two reasons,
    /// and the first is a bug waiting to happen: the frontmost application at the moment the user
    /// clicks a key in Edict's window *is Edict*, so the naive "inject into the frontmost app" would
    /// paste the transcript into the history pane's own search field. The second is the brief's: by the
    /// time someone comes back to a failed row they have moved on, and the original target may not even
    /// be running.
    ///
    /// - Returns: the rung that worked, or nil when there was nowhere to aim.
    @discardableResult
    public func retryInjection(_ transcript: Transcript) async -> InjectionOutcome? {
        guard !transcript.text.isEmpty else { return nil }
        guard retryingTranscriptID == nil else { return nil }

        guard let target = lastForegroundApp,
              let running = NSRunningApplication(processIdentifier: target.pid)
        else {
            Log.inject.notice("retry declined: no app to aim at")
            return nil
        }

        retryingTranscriptID = transcript.id
        defer { retryingTranscriptID = nil }

        // Bring the target forward and *wait for it*. Injection reads the focused AX element, so the
        // ladder would otherwise run against whatever still had focus — Edict.
        running.activate()
        let arrived = await Self.waitForFrontmost(pid: target.pid)
        if !arrived {
            Log.inject.error("\(target.name, privacy: .public) did not come to the front; retry aborted")
            let record = RetryRecord(outcome: .failed, appName: target.name)
            retryOutcomes[transcript.id] = record
            return .failed
        }

        let outcome = await retryInjector.inject(
            transcript.text,
            into: InjectionTarget(bundleID: target.bundleID, appName: target.name)
        )
        retryOutcomes[transcript.id] = RetryRecord(outcome: outcome, appName: target.name)
        await refreshLearnedPolicies()
        Log.inject.notice("""
            retry into \(target.name, privacy: .public) finished as \(outcome.rawValue, privacy: .public)
            """)
        return outcome
    }

    /// Teach Edict to skip the Accessibility rung in an app for good. The learning the injector already
    /// does silently, made available as a decision the user can make on purpose.
    public func setPasteOnly(for bundleID: String) async {
        await retryInjector.setStrategy(.pasteOnly, for: bundleID)
        await refreshLearnedPolicies()
    }

    /// Undo the above — and any demotion the injector learned by itself — so the app gets a clean try.
    public func forgetPolicy(for bundleID: String) async {
        await retryInjector.forgetStrategy(for: bundleID)
        await refreshLearnedPolicies()
    }

    func refreshLearnedPolicies() async {
        learnedPolicies = await retryInjector.learnedStrategies()
    }

    /// Poll rather than await an activation notification: `activate()` has no completion, and the
    /// window server takes a few frames. 1.2 s is generous for a running app and short enough that a
    /// refusal is still felt as a refusal.
    private static func waitForFrontmost(pid: pid_t, timeout: Duration = .milliseconds(1200)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { return true }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    // MARK: Render seams
    //
    // `internal`, and only for `#Preview` blocks and the offscreen render harness. Retry state is
    // otherwise produced solely by `retryInjection`, which needs a live app in front of it.

    func recordRetryForRender(_ id: UUID, outcome: InjectionOutcome, appName: String) {
        retryOutcomes[id] = RetryRecord(outcome: outcome, appName: appName)
    }

    func noteForegroundAppForRender(name: String, bundleID: String?) {
        lastForegroundApp = ForegroundApp(pid: 0, bundleID: bundleID, name: name)
    }

    // MARK: Foreground tracking

    /// Remember the last application that was frontmost *other than Edict*.
    ///
    /// macOS has no public "previous application" API, so it has to be watched for. This is the whole
    /// basis of the retry key: it is the only way to answer "where does this text belong" from inside
    /// a window that is, by definition, the thing in front.
    private func observeForegroundApp() {
        guard foregroundObserver == nil else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            lastForegroundApp = Self.describe(front)
        }

        foregroundObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // `queue: .main` guarantees this body is already on the main thread, so `assumeIsolated` is
            // how it reaches main-actor state. A `Task { @MainActor in … }` hop would be wrong as well
            // as slower: the user can switch apps again before it runs, and then the recorded app is
            // not the one that was activated.
            MainActor.assumeIsolated {
                guard let self, let app, app.processIdentifier != ownPID else { return }
                self.lastForegroundApp = Self.describe(app)
            }
        }
    }

    private static func describe(_ app: NSRunningApplication) -> ForegroundApp {
        ForegroundApp(
            pid: app.processIdentifier,
            bundleID: app.bundleIdentifier,
            name: app.localizedName ?? app.bundleIdentifier ?? "the other app"
        )
    }

    // MARK: Hotkey restart

    /// Restart the hotkey watcher and **wait long enough to say whether it worked**.
    ///
    /// The synchronous `retryHotkey()` is what cost an hour of debugging: it works, it returns
    /// immediately, and nothing on screen changes, so a user who has just been told the hotkey is dead
    /// concludes the key is dead too. `hotkeyLive` does move — a beat later, from the controller — so
    /// the fix is to give the control something to report.
    ///
    /// - Returns: true when the tap came back live.
    public func restartHotkey() async -> Bool {
        controller.restartHotkey()
        let deadline = ContinuousClock.now + .milliseconds(1500)
        while ContinuousClock.now < deadline {
            if hotkeyLive { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return hotkeyLive
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

    /// Publishes `refineElapsed` at the same rate `SegmentCounter(.elapsed:)` renders tenths at.
    ///
    /// A second task rather than a branch inside `startTickers`, because that one exists to sample
    /// the audio level as well and must stop the instant the microphone closes. This one runs on the
    /// other side of that boundary.
    private func startRefineTicker() {
        guard refineTicker == nil else { return }
        let started = ContinuousClock.now
        refineElapsed = 0
        refineTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.0 / Self.elapsedHz))
                guard let self, self.phase == .refining else { return }
                let span = started.duration(to: .now)
                self.refineElapsed = Double(span.components.seconds)
                    + Double(span.components.attoseconds) / 1e18
            }
        }
    }

    private func stopRefineTicker() {
        refineTicker?.cancel()
        refineTicker = nil
        // Deliberately not zeroed here. The HUD is still on screen for the injection that follows,
        // and snapping the counter to 0.0 s for those few milliseconds would erase the one number
        // that says what the wait cost. `apply(phase:)` clears it when the phase reaches `.idle`.
    }
}
