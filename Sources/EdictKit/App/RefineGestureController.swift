import AppKit
import ApplicationServices
import Foundation

// MARK: - Seams

/// The four collaborators this controller drives, each behind the narrowest protocol that expresses
/// what is asked of it.
///
/// Not architecture for its own sake: every one of them needs a live event tap, a granted
/// Accessibility permission, a focused application in another process, or Apple's on-device model.
/// A test suite has none of those, and the *sequencing* — which is where this feature's bugs live —
/// is worth testing without them. The real conformances are one line each, at the bottom of this
/// file.
@MainActor
public protocol RefinePopupPresenting: AnyObject {
    var isPresented: Bool { get }
    func present(anchor: RefinePopupAnchor) async -> RefinePopupOutcome
    func showFailure(_ sentence: String)
    func close()
    @discardableResult func handle(keyCode: Int64, rawFlags: UInt64) -> Bool
}

public protocol RefineSelectionReading: Sendable {
    func readSelection() async throws -> SelectionSnapshot
    func replace(_ snapshot: SelectionSnapshot, with text: String) async -> InjectionOutcome
}

public protocol RefineTextRefining: Sendable {
    func refine(
        _ text: String,
        as action: RefinementAction,
        localeIdentifier: String
    ) async throws -> RefinementResult
}

/// The keystroke source for a panel that cannot become key. See
/// ``HotkeyMonitor/beginKeyCapture(shouldCapture:)`` for why this has to *swallow* and not merely
/// observe.
public protocol RefineKeyCapturing: Sendable {
    func beginKeyCapture(shouldCapture: @escaping @Sendable (Int64, UInt64) -> Bool) async -> Bool
    func setKeyCaptureSuppressing(_ suppressing: Bool)
    func endKeyCapture()
}

// MARK: - Controller

/// The gesture, end to end: chord → read the selection → popup → choose → refine → replace.
///
/// ## The order of operations, and why the selection is read *while* the popup is up
///
/// Reading a selection out of another application costs a 35 ms floor plus up to a 500 ms poll on the
/// pasteboard route, and up to 1.2 s more waiting for the chord's own modifiers to come off the
/// keyboard (`SelectionBridge.copySelection`). Doing that *before* showing the panel would mean up to
/// 1.7 s of nothing happening after the user's gesture, which reads as a chord that did not register.
/// So the panel goes up first and the read runs alongside it, hidden behind the two seconds it takes
/// a person to read three legends and press a number. If the read fails before a choice is made, the
/// panel replaces its keys with the reason — that is what `RefinePopupController.showFailure` is for,
/// and it resolves the pending presentation as `dismissed(.cancelled)` on the way.
///
/// ## Nothing is recorded
///
/// No `HistoryStore` call appears anywhere in this file, deliberately. This is text the user already
/// had, in somebody else's document; filing it in Edict's transcript log would turn a refinement into
/// a copy of a document the user never asked Edict to keep.
///
/// ## Nothing leaves the machine
///
/// `TextRefiner` is Apple's on-device model (RECON amendment 41). There is no network path here and
/// there must never be one.
@MainActor
public final class RefineGestureController {

    /// What one gesture came to. Returned for tests and logged; the user learns it from the panel.
    public enum Result: Sendable, Hashable {
        /// The refined text landed in the user's app, by the named route.
        case replaced(RefinementAction, InjectionOutcome)
        /// Refinement worked and the replace did not, so the text is on the clipboard.
        case leftOnClipboard(RefinementAction)
        case dismissed(RefinePopupDismissal)
        /// A sentence was shown in the panel.
        case failed(String)
        /// Refused before anything appeared on screen, with the reason logged.
        case refused(String)
        /// A gesture arrived while one was already running.
        case busy
    }

    // MARK: Collaborators

    private let popup: any RefinePopupPresenting
    private let selection: any RefineSelectionReading
    private let refiner: any RefineTextRefining
    private let capture: any RefineKeyCapturing
    private let settings: Settings
    /// Injected so the sequencing can be tested without a focused application. Production passes
    /// `RefineAnchorResolver.anchor`, which never fails — the pointer is always somewhere.
    private let anchor: @MainActor () -> RefinePopupAnchor

    // MARK: State

    /// One gesture at a time. The chord is easy to press twice, and two popups racing over one
    /// selection would have the second one replacing text the first had already replaced.
    private var inFlight = false

    /// The most recent outcome, for tests and for a status line.
    public private(set) var lastResult: Result?

    public init(
        popup: any RefinePopupPresenting,
        selection: any RefineSelectionReading,
        refiner: any RefineTextRefining,
        capture: any RefineKeyCapturing,
        settings: Settings = .shared,
        anchor: @escaping @MainActor () -> RefinePopupAnchor = { RefineAnchorResolver.anchor() }
    ) {
        self.popup = popup
        self.selection = selection
        self.refiner = refiner
        self.capture = capture
        self.settings = settings
        self.anchor = anchor
    }

    // MARK: Entry points

    /// Called from the hotkey monitor's gesture stream. Fire and forget: the tap's consumer must not
    /// wait on a model, a pasteboard poll or a human.
    public func gestureFired() {
        Task { [weak self] in _ = await self?.run() }
    }

    /// A keystroke the capture tap swallowed on the panel's behalf.
    ///
    /// The panel is `.nonactivatingPanel` with `canBecomeKey == false`, so this is the *only* way a
    /// key reaches it. Handing a key to a popup that is not showing is a no-op inside
    /// `RefinePopupController.handle`, so no state has to be tracked here.
    public func handleCapturedKey(keyCode: Int64, rawFlags: UInt64) {
        popup.handle(keyCode: keyCode, rawFlags: rawFlags)
    }

    // MARK: The gesture

    @discardableResult
    public func run() async -> Result {
        guard !inFlight else {
            Log.engine.info("refine gesture ignored: one is already running")
            return finish(.busy)
        }
        inFlight = true
        defer { inFlight = false }

        let clock = ContinuousClock()
        let started = clock.now

        guard settings.refineSelectionEnabled else {
            return finish(.refused("the refine popup is switched off in Settings"))
        }
        // Gate before anything is shown. Both halves of this feature need Accessibility — the
        // selection read and, just as importantly, the tap that stops the digit keys from reaching
        // the user's document — so a popup shown without it could only mislead.
        if let closed = Self.closedGate() {
            return finish(.refused(closed))
        }

        // Suppression first, panel second. The window between the two is where a digit would land in
        // the user's document, so it is closed before there is anything to press a digit at.
        let capturing = await capture.beginKeyCapture(shouldCapture: Self.isPopupKey)
        guard capturing else {
            return finish(.refused(
                "Edict could not take over the number keys, so it will not offer a choice it cannot "
                    + "protect your selection from."
            ))
        }
        defer { capture.endKeyCapture() }

        let where_ = anchor()
        let selection = self.selection
        let read = Task { try await selection.readSelection() }

        // Present and watch the read at the same time. `showFailure` on a panel that is not up yet is
        // a no-op, and the same error is handled again below, so nothing is lost if the watcher wins
        // the race to the first main-actor slice.
        let presentation = Task { @MainActor [popup] in await popup.present(anchor: where_) }
        let watcher = Task { @MainActor [popup] in
            do {
                _ = try await read.value
            } catch {
                guard !Task.isCancelled else { return }
                popup.showFailure(Self.sentence(for: error))
            }
        }
        let outcome = await presentation.value
        watcher.cancel()
        let chosenAt = clock.now

        switch outcome {
        case .dismissed(let why):
            // The read may already have posted its Cmd-C; that is harmless, because
            // `SelectionBridge` snapshots and restores the pasteboard either way.
            read.cancel()
            Log.engine.info("""
                refine popup dismissed (\(why.rawValue, privacy: .public)) after \
                \(Self.ms(started, chosenAt)) ms
                """)
            return finish(.dismissed(why))

        case .chose(let action):
            // The panel is in `.working` now, which cannot act on a digit — so stop swallowing them.
            // `RefinePopupSession.handle` makes the same promise ("a stray `2` during the working
            // state reaches the app underneath instead of vanishing"); this is where it is kept.
            capture.setKeyCaptureSuppressing(false)
            return await complete(action, read: read, clock: clock, started: started, chosenAt: chosenAt)
        }
    }

    private func complete(
        _ action: RefinementAction,
        read: Task<SelectionSnapshot, any Error>,
        clock: ContinuousClock,
        started: ContinuousClock.Instant,
        chosenAt: ContinuousClock.Instant
    ) async -> Result {
        let snapshot: SelectionSnapshot
        do {
            snapshot = try await read.value
        } catch {
            let sentence = Self.sentence(for: error)
            popup.showFailure(sentence)
            return finish(.failed(sentence))
        }
        let readAt = clock.now

        let refined: RefinementResult
        do {
            // The dictation language is the only locale answer available: this is arbitrary text out
            // of somebody else's window, and nothing in it says what language it is. It costs
            // nothing to be wrong — the instruction tells the model to answer in the language of the
            // input, and an unsupported locale is a caption rather than a refusal (RECON
            // amendment 41).
            refined = try await refiner.refine(
                snapshot.text,
                as: action,
                localeIdentifier: settings.localeIdentifier
            )
        } catch is CancellationError {
            popup.close()
            return finish(.dismissed(.cancelled))
        } catch {
            let sentence = Self.sentence(for: error)
            popup.showFailure(sentence)
            return finish(.failed(sentence))
        }
        let refinedAt = clock.now

        let landed = await selection.replace(snapshot, with: refined.text)
        let doneAt = clock.now

        Log.engine.notice("""
            refine \(action.rawValue, privacy: .public) in \
            \(snapshot.target.appName ?? "?", privacy: .public): \
            read=\(snapshot.route.rawValue, privacy: .public) \
            outcome=\(landed.rawValue, privacy: .public) — \
            chord→popup+choice \(Self.ms(started, chosenAt)) ms, \
            selection read \(Self.ms(started, readAt)) ms, \
            model \(Self.ms(chosenAt, refinedAt)) ms, \
            replace \(Self.ms(refinedAt, doneAt)) ms, \
            total \(Self.ms(started, doneAt)) ms
            """)

        switch landed {
        case .accessibility, .paste, .keystrokes:
            popup.close()
            return finish(.replaced(action, landed))
        case .clipboardOnly:
            // The load-bearing promise of the whole feature: a replace that cannot be proved never
            // costs the user their words. Say where they are.
            popup.showFailure(
                "Edict could not put the text back into \(snapshot.target.appName ?? "that app"). "
                    + "The refined version is on your clipboard — press ⌘V."
            )
            return finish(.leftOnClipboard(action))
        case .failed, .notAttempted:
            let sentence = "Edict could not replace the selection, and could not put the refined "
                + "text on the clipboard either. Your text is unchanged."
            popup.showFailure(sentence)
            return finish(.failed(sentence))
        }
    }

    @discardableResult
    private func finish(_ result: Result) -> Result {
        lastResult = result
        if case .refused(let why) = result {
            Log.engine.notice("refine gesture refused: \(why, privacy: .public)")
        }
        return result
    }

    // MARK: Pure decisions
    //
    // `nonisolated` and static: none of them touches state, one of them runs on the tap thread, and
    // all of them are worth testing without a tap, a permission or a model.

    /// Which keystrokes the panel wants. Delegated to `RefinePopupKey` rather than restated, so the
    /// keys the tap swallows are exactly the keys the panel obeys — a table copied into a second
    /// place is a table that will disagree with itself.
    nonisolated static let isPopupKey: @Sendable (Int64, UInt64) -> Bool = { keyCode, rawFlags in
        RefinePopupKey.key(keyCode: keyCode, rawFlags: rawFlags) != nil
    }

    /// Both permissions this feature needs, checked before a panel appears rather than inferred from
    /// an error code afterwards.
    ///
    /// `SelectionBridge.closedGate()` checks the same two plus secure input, and it stays the
    /// authority for the read itself. This one exists because it is asked *earlier*: the key-capture
    /// tap needs Accessibility too, and finding that out from a `tapCreate` returning nil would mean
    /// the panel was already on screen.
    nonisolated static func closedGate() -> String? {
        if !AXIsProcessTrusted() {
            return "Edict needs Accessibility permission to read and replace a selection. "
                + "Turn it on in System Settings > Privacy & Security > Accessibility."
        }
        if !CGPreflightPostEventAccess() {
            return "Edict needs permission to send keystrokes before it can copy a selection. "
                + "Turn it on in System Settings > Privacy & Security > Accessibility."
        }
        return nil
    }

    /// One finished sentence for anything that can go wrong.
    ///
    /// `SelectionError` and `RefinementFailure` are both `LocalizedError` carrying exactly that, so
    /// this is a pass-through with a backstop rather than a second set of copy — two places writing
    /// the same apology is how they drift.
    nonisolated static func sentence(for error: any Error) -> String {
        if let localized = (error as? any LocalizedError)?.errorDescription { return localized }
        if error is CancellationError { return "Edict stopped before it finished." }
        return "Edict could not refine that selection: \(error.localizedDescription)"
    }

    nonisolated private static func ms(_ from: ContinuousClock.Instant, _ to: ContinuousClock.Instant) -> Int {
        Int((to - from) / .milliseconds(1))
    }
}

// MARK: - Real conformances

extension RefinePopupController: RefinePopupPresenting {}
extension SelectionBridge: RefineSelectionReading {}
extension TextRefiner: RefineTextRefining {}
extension HotkeyMonitor: RefineKeyCapturing {}
