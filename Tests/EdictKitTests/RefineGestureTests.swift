import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import EdictKit

/// What is and is not proved here.
///
/// The gesture's three hard parts are a live event tap, another application's selection, and Apple's
/// on-device model, and a `swift test` process has none of them. So this suite pins the two things
/// that would be wrong *silently*:
///
/// * **The ordering rule, as bit tests.** `fn` already held when the dictation key goes down is the
///   popup; the other order is dictation. Every assertion carries the junk bits a real machine
///   stamps on an event — Karabiner's `nonCoalesced` `0x100` (RECON amendment 31) and the
///   `0x20000000` this project's own probe measured on every posted event — because a chord that
///   works only on clean flags works nowhere.
/// * **The sequencing**, against fakes. Which collaborator is called, in what order, and what happens
///   to the user's text when one of them fails. The rule that matters most is negative: a gesture
///   that does not end in a proved replacement must leave the words recoverable.
///
/// The tap itself is exercised by a separate gated suite at the bottom, which posts a synthetic chord
/// through a real `HotkeyMonitor`.
@Suite("RefineChord")
struct RefineChordTests {

    /// Bits a real event carries besides the ones the chord is about. `0x100` is
    /// `kCGEventFlagMaskNonCoalesced`, stamped by this machine's Karabiner virtual keyboard on every
    /// event it synthesizes, release included; `0x20000000` is the undocumented default on a freshly
    /// constructed `CGEvent`, measured on all four events of a posted chord.
    static let junk: UInt64 = 0x100 | 0x2000_0000

    static let fn = UInt64(CGEventFlags.maskSecondaryFn.rawValue)
    static let alt = UInt64(CGEventFlags.maskAlternate.rawValue)
    static let cmd = UInt64(CGEventFlags.maskCommand.rawValue)
    static let ctrl = UInt64(CGEventFlags.maskControl.rawValue)
    static let shift = UInt64(CGEventFlags.maskShift.rawValue)
    /// `NX_DEVICERALTKEYMASK` — the bit that says it was the *right* Option key.
    static let ralt: UInt64 = 0x40

    // MARK: The qualified family

    @Test("fn qualifying Right Option resolves to the fn bit and keycode 63")
    func fnQualifier() throws {
        let binding = try #require(RefineChordBinding(.fnThenDictationKey, dictationKey: .rightOption))
        #expect(binding.qualifierMask == Self.fn)
        #expect(binding.qualifierKeyCodes == [63])
        // Nothing to match in the keyDown branch: this family is recognised from the dictation key's
        // own flagsChanged, which is the entire ordering rule.
        #expect(binding.discreteKeyCode == nil)
    }

    @Test("fn cannot qualify fn")
    func fnCannotQualifyItself() {
        #expect(RefineChordBinding(.fnThenDictationKey, dictationKey: .fn) == nil)
        #expect(RefineChord.fnThenDictationKey.refusal(dictationKey: .fn) != nil)
        #expect(RefineChord.fnThenDictationKey.refusal(dictationKey: .rightOption) == nil)
    }

    /// The measured shape of the real thing. These are the exact raw words a listen-only session tap
    /// reported on this machine while the chord was posted through it:
    ///
    ///     kc=63  0x20800000   fn down
    ///     kc=61  0x20880040   Right Option down, fn still held   <- the popup gesture
    ///     kc=61  0x20800000   Right Option up
    ///     kc=63  0x20000000   fn up
    @Test("the qualifier bit is legible on the dictation key's own down event")
    func qualifierBitOnTheDictationKeysEvent() throws {
        let binding = try #require(RefineChordBinding(.fnThenDictationKey, dictationKey: .rightOption))
        let mask = try #require(binding.qualifierMask)

        let rightOptionDownWithFn: UInt64 = 0x2088_0040
        let rightOptionDownAlone: UInt64 = 0x2008_0040 | 0x100
        #expect(rightOptionDownWithFn & mask != 0)
        #expect(rightOptionDownAlone & mask == 0)
    }

    // MARK: The discrete family

    @Test("⌥⌘R matches only with Option and Command, junk bits and all")
    func optionCommandR() throws {
        let binding = try #require(RefineChordBinding(.optionCommandR, dictationKey: .rightOption))
        #expect(binding.discreteKeyCode == 15)   // kVK_ANSI_R
        #expect(binding.qualifierMask == nil)

        #expect(binding.matchesDiscrete(keyCode: 15, rawFlags: Self.alt | Self.cmd | Self.junk))
        // The wrong key.
        #expect(!binding.matchesDiscrete(keyCode: 16, rawFlags: Self.alt | Self.cmd | Self.junk))
        // Missing a required modifier.
        #expect(!binding.matchesDiscrete(keyCode: 15, rawFlags: Self.cmd | Self.junk))
        #expect(!binding.matchesDiscrete(keyCode: 15, rawFlags: Self.junk))
        // A forbidden one present: ⌃⌥⌘R is somebody else's shortcut, not this one.
        #expect(!binding.matchesDiscrete(keyCode: 15, rawFlags: Self.alt | Self.cmd | Self.ctrl | Self.junk))
        #expect(!binding.matchesDiscrete(keyCode: 15, rawFlags: Self.alt | Self.cmd | Self.shift | Self.junk))
    }

    /// The subtle one. If the user's dictation key is Right Option and they reach for ⌥⌘R with *that*
    /// key, the chord must not fire out of a hold that has already armed — that would be one gesture
    /// producing both a popup and a half-second recording. Only the side-specific device bit is
    /// excluded, never `maskAlternate`, which ⌥⌘R needs set to be ⌥⌘R at all.
    @Test("a discrete chord ignores the dictation key's own side")
    func discreteExcludesTheDictationKeysSide() throws {
        let binding = try #require(RefineChordBinding(.optionCommandR, dictationKey: .rightOption))
        // Left Option: no device bit for the right side, so this is the gesture.
        #expect(binding.matchesDiscrete(keyCode: 15, rawFlags: Self.alt | Self.cmd | 0x20 | Self.junk))
        // Right Option: the dictation key.
        #expect(!binding.matchesDiscrete(keyCode: 15, rawFlags: Self.alt | Self.cmd | Self.ralt | Self.junk))
        // With F13 as the dictation key there is no side to exclude, so both work.
        let f13 = try #require(RefineChordBinding(.optionCommandR, dictationKey: .f13))
        #expect(f13.matchesDiscrete(keyCode: 15, rawFlags: Self.alt | Self.cmd | Self.ralt | Self.junk))
    }

    @Test("⌃⌥R requires Control and Option and refuses Command")
    func controlOptionR() throws {
        let binding = try #require(RefineChordBinding(.controlOptionR, dictationKey: .rightOption))
        #expect(binding.matchesDiscrete(keyCode: 15, rawFlags: Self.ctrl | Self.alt | Self.junk))
        #expect(!binding.matchesDiscrete(keyCode: 15, rawFlags: Self.ctrl | Self.alt | Self.cmd | Self.junk))
        #expect(!binding.matchesDiscrete(keyCode: 15, rawFlags: Self.ctrl | Self.junk))
    }

    /// The discrete chords must remain expressible whatever the dictation key is, or the picker could
    /// offer three rows and leave the user with none.
    @Test("a discrete chord resolves for every dictation key", arguments: HotkeyChoice.allCases)
    func discreteAlwaysResolves(key: HotkeyChoice) {
        #expect(RefineChordBinding(.optionCommandR, dictationKey: key) != nil)
        #expect(RefineChordBinding(.controlOptionR, dictationKey: key) != nil)
        #expect(RefineChord.optionCommandR.refusal(dictationKey: key) == nil)
        #expect(RefineChord.controlOptionR.refusal(dictationKey: key) == nil)
    }

    // MARK: Settings

    @Test("the feature is on by default, on the user's own chord")
    @MainActor
    func defaults() {
        let settings = Settings(defaults: EphemeralDefaults())
        #expect(settings.refineSelectionEnabled)
        #expect(settings.refineSelectionChord == .commandOptionSlash)
        #expect(settings.effectiveRefineChord == .commandOptionSlash)
    }

    @Test("effectiveRefineChord is the one answer the tap, the picker and the status line share")
    @MainActor
    func effectiveChord() {
        let settings = Settings(defaults: EphemeralDefaults())

        settings.refineSelectionEnabled = false
        #expect(settings.effectiveRefineChord == nil)

        settings.refineSelectionEnabled = true
        // Globe as the dictation key cannot also qualify it, so the chord goes quiet rather than
        // staying armed and never firing.
        settings.hotkey = .fn
        settings.refineSelectionChord = .fnThenDictationKey
        #expect(settings.effectiveRefineChord == nil)

        settings.refineSelectionChord = .optionCommandR
        #expect(settings.effectiveRefineChord == .optionCommandR)
    }

    @Test("a chord survives a round trip through defaults, and a corrupt value falls back")
    @MainActor
    func persistence() {
        let store = EphemeralDefaults()
        let first = Settings(defaults: store)
        first.refineSelectionChord = .controlOptionR
        first.refineSelectionEnabled = false
        let second = Settings(defaults: store)
        #expect(second.refineSelectionChord == .controlOptionR)
        #expect(!second.refineSelectionEnabled)

        store.set("nonsense-written-by-hand", forKey: "edict.refineSelectionChord")
        let third = Settings(defaults: store)
        #expect(third.refineSelectionChord == Settings.Default.refineSelectionChord)
    }
}

// MARK: - Which keys the tap swallows

@Suite("RefinePopupKeyCapture")
struct RefinePopupKeyCaptureTests {

    /// The predicate the capture tap is driven by. It must claim exactly what the panel obeys: a
    /// tap that swallows a key the panel ignores deletes a keystroke out of the user's document.
    @Test("the capture predicate claims the panel's keys and nothing else")
    func predicate() {
        let claim = RefineGestureController.isPopupKey
        let junk = RefineChordTests.junk

        #expect(claim(Int64(kVK_ANSI_1), junk))
        #expect(claim(Int64(kVK_ANSI_2), junk))
        #expect(claim(Int64(kVK_ANSI_3), junk))
        #expect(claim(Int64(kVK_Escape), junk))
        #expect(claim(Int64(kVK_ANSI_Keypad1), junk))

        #expect(!claim(Int64(kVK_ANSI_4), junk))
        #expect(!claim(Int64(kVK_ANSI_A), junk))
        // The chord's own modifiers must not disqualify a choice — the user may still be holding it.
        #expect(claim(Int64(kVK_ANSI_1), junk | UInt64(CGEventFlags.maskSecondaryFn.rawValue)))
        #expect(claim(Int64(kVK_ANSI_1), junk | UInt64(CGEventFlags.maskAlternate.rawValue)))
        // ⌘1 is "first tab" in every browser and ⌃1 is a Space switch. Swallowing those would be a
        // bug in the user's other app.
        #expect(!claim(Int64(kVK_ANSI_1), junk | UInt64(CGEventFlags.maskCommand.rawValue)))
        #expect(!claim(Int64(kVK_ANSI_1), junk | UInt64(CGEventFlags.maskControl.rawValue)))
    }
}

// MARK: - Fakes

@MainActor
final class FakePopup: RefinePopupPresenting {
    /// What `present` should hand back.
    var outcome: RefinePopupOutcome = .chose(.cleanUp)
    /// When set, `present` parks until ``release()`` — a suspended task rather than a wall-clock
    /// sleep, so a test that needs the panel to still be "up" costs no elapsed time and adds no
    /// scheduling pressure to the rest of the suite, which runs in parallel with it.
    var holdsUntilReleased = false

    var presented: [RefinePopupAnchor] = []
    var failures: [String] = []
    var closes = 0
    var handled: [(Int64, UInt64)] = []
    var isPresented = false

    private var gate: CheckedContinuation<Void, Never>?
    private var released = false

    func present(anchor: RefinePopupAnchor) async -> RefinePopupOutcome {
        presented.append(anchor)
        isPresented = true
        if holdsUntilReleased, !released {
            await withCheckedContinuation { gate = $0 }
        }
        return outcome
    }

    /// Let a parked `present` return.
    func release() {
        released = true
        gate?.resume()
        gate = nil
    }

    func showFailure(_ sentence: String) {
        failures.append(sentence)
    }

    func close() {
        closes += 1
        isPresented = false
    }

    @discardableResult
    func handle(keyCode: Int64, rawFlags: UInt64) -> Bool {
        handled.append((keyCode, rawFlags))
        return true
    }
}

/// A selection source whose every answer is dictated by the test.
final class FakeSelection: RefineSelectionReading, @unchecked Sendable {
    private let lock = NSLock()

    var readResult: Result<SelectionSnapshot, any Error> = .success(
        SelectionSnapshot(
            text: "um so the thing is we need to ship this thursday",
            target: InjectionTarget(bundleID: "com.apple.TextEdit", appName: "TextEdit"),
            route: .accessibility
        )
    )
    var readDelay: Duration = .zero
    var replaceOutcome: InjectionOutcome = .paste

    private var _reads = 0
    private var _replacements: [String] = []
    var reads: Int { lock.withLock { _reads } }
    var replacements: [String] { lock.withLock { _replacements } }

    func readSelection() async throws -> SelectionSnapshot {
        lock.withLock { _reads += 1 }
        if readDelay != .zero { try await Task.sleep(for: readDelay) }
        return try readResult.get()
    }

    func replace(_ snapshot: SelectionSnapshot, with text: String) async -> InjectionOutcome {
        lock.withLock { _replacements.append(text) }
        return replaceOutcome
    }
}

final class FakeRefiner: RefineTextRefining, @unchecked Sendable {
    private let lock = NSLock()
    var result: Result<String, any Error> = .success("So the thing is, we need to ship this Thursday.")
    private var _calls: [RefinementAction] = []
    var calls: [RefinementAction] { lock.withLock { _calls } }

    func refine(
        _ text: String,
        as action: RefinementAction,
        localeIdentifier: String
    ) async throws -> RefinementResult {
        lock.withLock { _calls.append(action) }
        return RefinementResult(
            action: action,
            text: try result.get(),
            duration: 1.0,
            localeIdentifier: localeIdentifier,
            wasLocaleUnsupported: false
        )
    }
}

final class FakeCapture: RefineKeyCapturing, @unchecked Sendable {
    private let lock = NSLock()
    var installable = true
    /// Every state change, in order, so the test can pin *when* suppression stops.
    private var _log: [String] = []
    var log: [String] { lock.withLock { _log } }

    func beginKeyCapture(shouldCapture: @escaping @Sendable (Int64, UInt64) -> Bool) async -> Bool {
        lock.withLock { _log.append(installable ? "begin" : "begin-failed") }
        return installable
    }

    func setKeyCaptureSuppressing(_ suppressing: Bool) {
        lock.withLock { _log.append("suppress=\(suppressing)") }
    }

    func endKeyCapture() {
        lock.withLock { _log.append("end") }
    }
}

// MARK: - Sequencing

/// `.serialized` on purpose, and not for correctness of these tests — each `Rig` is independent.
/// Every test in here is `@MainActor`, and running fourteen of them at once fills the main actor's
/// queue deep enough to starve the 10 Hz main-actor tickers that two *other* suites in this package
/// measure with a wall clock. Serialising this suite costs about a tenth of a second and stops this
/// file from making somebody else's timing test flaky.
@Suite("RefineGesture", .serialized)
@MainActor
struct RefineGestureTests {

    struct Rig {
        let popup: FakePopup
        let selection: FakeSelection
        let refiner: FakeRefiner
        let capture: FakeCapture
        let settings: Settings
        let controller: RefineGestureController

        @MainActor
        init() {
            let popup = FakePopup()
            let selection = FakeSelection()
            let refiner = FakeRefiner()
            let capture = FakeCapture()
            let settings = Settings(defaults: EphemeralDefaults())
            self.popup = popup
            self.selection = selection
            self.refiner = refiner
            self.capture = capture
            self.settings = settings
            self.controller = RefineGestureController(
                popup: popup,
                selection: selection,
                refiner: refiner,
                capture: capture,
                settings: settings,
                anchor: { .point(CGPoint(x: 100, y: 200)) }
            )
        }
    }

    /// Poll rather than sleep for a fixed period. Two seconds is a ceiling for a hung expectation,
    /// not a wait: the condition is normally true on the first or second slice, and 5 ms steps keep
    /// this test from starving the suites running beside it.
    @MainActor
    static func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    @Test("the happy path reads, refines and replaces exactly once")
    func happyPath() async throws {
        let rig = Rig()
        rig.popup.outcome = .chose(.bullets)

        let result = await rig.controller.run()

        #expect(result == .replaced(.bullets, .paste))
        #expect(rig.selection.reads == 1)
        #expect(rig.refiner.calls == [.bullets])
        #expect(rig.selection.replacements == ["So the thing is, we need to ship this Thursday."])
        #expect(rig.popup.closes == 1)
        #expect(rig.popup.failures.isEmpty)
    }

    /// The order of the capture calls is the whole safety property of the keyboard path. Suppression
    /// is on before the panel exists, and off the instant a choice is taken — because the panel then
    /// shows a state that cannot act on a digit, and `RefinePopupSession` promises such a digit
    /// reaches the app underneath.
    @Test("suppression starts before the panel and stops when a choice is taken")
    func suppressionWindow() async throws {
        let rig = Rig()
        _ = await rig.controller.run()
        #expect(rig.capture.log == ["begin", "suppress=false", "end"])
    }

    @Test("a dismissal refines nothing and replaces nothing")
    func dismissed() async throws {
        let rig = Rig()
        rig.popup.outcome = .dismissed(.escape)

        let result = await rig.controller.run()

        #expect(result == .dismissed(.escape))
        #expect(rig.refiner.calls.isEmpty)
        #expect(rig.selection.replacements.isEmpty)
        #expect(rig.capture.log.last == "end")
    }

    /// The panel must not be offered at all when its digits cannot be stopped: they would land in the
    /// user's document, on top of the very selection the popup is about to replace.
    @Test("no panel is shown when the keys cannot be swallowed")
    func captureUnavailable() async throws {
        let rig = Rig()
        rig.capture.installable = false

        let result = await rig.controller.run()

        guard case .refused = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(rig.popup.presented.isEmpty)
        #expect(rig.selection.reads == 0)
    }

    @Test("the switch in Settings is read on every gesture, not at launch")
    func disabled() async throws {
        let rig = Rig()
        rig.settings.refineSelectionEnabled = false

        let result = await rig.controller.run()

        guard case .refused = result else {
            Issue.record("expected a refusal, got \(result)")
            return
        }
        #expect(rig.capture.log.isEmpty)
        #expect(rig.popup.presented.isEmpty)
    }

    /// A read that fails while the user is still reading the legends replaces the keys with the
    /// reason, rather than waiting for them to press a number to be told there was nothing selected.
    @Test("a selection read that fails is shown in the panel")
    func readFailureSurfaces() async throws {
        let rig = Rig()
        rig.selection.readResult = .failure(SelectionError.nothingSelected)
        rig.popup.holdsUntilReleased = true
        rig.popup.outcome = .dismissed(.cancelled)

        async let running = rig.controller.run()
        // The panel is still parked in `present`, which is exactly the state this is about: the
        // failure has to reach it *before* the user chooses.
        let surfaced = await Self.waitUntil { !rig.popup.failures.isEmpty }
        #expect(surfaced)
        #expect(rig.popup.failures.first == SelectionError.nothingSelected.errorDescription)
        rig.popup.release()

        #expect(await running == .dismissed(.cancelled))
        #expect(rig.popup.failures.count == 1)
        #expect(rig.selection.replacements.isEmpty)
    }

    @Test("a read that fails after a choice still explains itself")
    func readFailureAfterChoice() async throws {
        let rig = Rig()
        rig.selection.readResult = .failure(SelectionError.modifiersHeld)
        rig.popup.outcome = .chose(.cleanUp)

        let result = await rig.controller.run()

        #expect(result == .failed(SelectionError.modifiersHeld.errorDescription ?? ""))
        #expect(rig.refiner.calls.isEmpty)
        #expect(rig.popup.failures.contains(SelectionError.modifiersHeld.errorDescription ?? ""))
    }

    @Test("a model failure leaves the user's text alone and says why")
    func refineFailure() async throws {
        let rig = Rig()
        rig.refiner.result = .failure(RefinementFailure.failed("The model returned nothing."))

        let result = await rig.controller.run()

        #expect(result == .failed("The model returned nothing."))
        #expect(rig.selection.replacements.isEmpty)
        #expect(rig.popup.closes == 0)
    }

    /// The load-bearing promise: a replace that cannot be proved never costs the user their words.
    @Test("an unprovable replace names the app and points at the clipboard")
    func clipboardFallback() async throws {
        let rig = Rig()
        rig.selection.replaceOutcome = .clipboardOnly

        let result = await rig.controller.run()

        #expect(result == .leftOnClipboard(.cleanUp))
        let sentence = try #require(rig.popup.failures.first)
        #expect(sentence.contains("TextEdit"))
        #expect(sentence.contains("⌘V"))
    }

    @Test("a total failure says the text is unchanged rather than claiming success")
    func totalFailure() async throws {
        let rig = Rig()
        rig.selection.replaceOutcome = .failed

        let result = await rig.controller.run()

        guard case .failed(let sentence) = result else {
            Issue.record("expected a failure, got \(result)")
            return
        }
        #expect(sentence.contains("unchanged"))
        #expect(rig.popup.closes == 0)
    }

    /// Two popups over one selection would have the second replacing text the first had already
    /// replaced. The chord is easy to press twice.
    @Test("a second gesture is refused while one is running")
    func reentrancy() async throws {
        let rig = Rig()
        rig.popup.holdsUntilReleased = true

        async let first = rig.controller.run()
        // Wait for the first gesture to reach the panel, which is past its `inFlight` claim.
        #expect(await Self.waitUntil { !rig.popup.presented.isEmpty })
        let second = await rig.controller.run()
        rig.popup.release()

        #expect(second == .busy)
        #expect(await first == .replaced(.cleanUp, .paste))
        #expect(rig.selection.replacements.count == 1)
        #expect(rig.popup.presented.count == 1)
    }

    @Test("captured keys reach the panel unchanged")
    func capturedKeysForwarded() {
        let rig = Rig()
        rig.controller.handleCapturedKey(keyCode: Int64(kVK_ANSI_2), rawFlags: RefineChordTests.junk)
        #expect(rig.popup.handled.count == 1)
        #expect(rig.popup.handled.first?.0 == Int64(kVK_ANSI_2))
    }

    @Test("every error becomes one finished sentence")
    func sentences() {
        #expect(
            RefineGestureController.sentence(for: SelectionError.nothingSelected)
                == SelectionError.nothingSelected.errorDescription
        )
        #expect(
            RefineGestureController.sentence(for: RefinementFailure.nothingToRefine)
                == RefinementFailure.nothingToRefine.errorDescription
        )
        let opaque = NSError(domain: "test", code: 7, userInfo: [NSLocalizedDescriptionKey: "bad"])
        #expect(RefineGestureController.sentence(for: opaque).contains("bad"))
    }
}

// MARK: - The chord against a real event tap

/// The ordering rule, measured through a real `CGEventTap` rather than reasoned about.
///
/// Gated behind `EDICT_TAP_TESTS=1` and skipped by default, for three reasons that all make it a
/// manual instrument rather than a suite member:
///
/// 1. It needs **Input Monitoring**, which a bare SwiftPM test binary can only borrow from the
///    terminal that launched it (RECON: TCC attributes responsibility to the launching process, so
///    this passes from Ghostty and reports "denied" from anywhere else).
/// 2. It **posts events into the user's session**. Only `.flagsChanged` for `fn` and Right Option, so
///    it types no characters and cannot damage a document — but it is still somebody's keyboard.
/// 3. Any running copy of Edict shares the same global tap and would act on these events: the plain
///    hold below would start a *real* recording, with a live microphone, in whatever app is in front.
///    **Quit Edict before running this.**
///
/// It also needs an **idle keyboard**. Observed while writing it: a run taken while the machine's
/// owner was typing failed the third test with no events at all, because their keystrokes
/// chord-cancelled the synthetic hold — which is the "held alone" rule working exactly as RECON §13
/// specifies, not a defect. Do not chase a failure here without checking `HIDIdleTime` first.
///
///     EDICT_TAP_TESTS=1 swift test --filter HotkeyChordLive
@Suite(
    "HotkeyChordLive",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["EDICT_TAP_TESTS"] == "1"),
    .disabled(if: !CGPreflightListenEventAccess(), "Input Monitoring is not available to this process")
)
struct HotkeyChordLiveTests {

    /// One `.flagsChanged`, exactly as the window server delivers it: a keycode plus the *complete*
    /// modifier state at that moment.
    static func postFlags(_ keyCode: CGKeyCode, _ raw: UInt64) {
        let source = CGEventSource(stateID: .privateState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        else { return }
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: raw)
        event.post(tap: .cghidEventTap)
    }

    static let fn = UInt64(CGEventFlags.maskSecondaryFn.rawValue)
    static let alt = UInt64(CGEventFlags.maskAlternate.rawValue)
    static let ralt: UInt64 = 0x40

    /// Collects both streams for a bounded window, so a test can assert on what did *and did not*
    /// arrive rather than only on what did.
    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [HotkeyEvent] = []
        private var _gestures: [HotkeyGesture] = []
        var events: [HotkeyEvent] { lock.withLock { _events } }
        var gestures: [HotkeyGesture] { lock.withLock { _gestures } }

        func consume(_ monitor: HotkeyMonitor) -> [Task<Void, Never>] {
            let events = monitor.events
            let gestures = monitor.gestures
            return [
                Task { for await e in events { self.lock.withLock { self._events.append(e) } } },
                Task { for await g in gestures { self.lock.withLock { self._gestures.append(g) } } },
            ]
        }
    }

    @Test("fn held first opens the popup and does not arm dictation")
    func chordDoesNotArmDictation() async throws {
        let monitor = HotkeyMonitor(armDelay: 0.12)
        let sink = Sink()
        let tasks = sink.consume(monitor)
        defer { tasks.forEach { $0.cancel() }; monitor.stop() }
        try monitor.start(key: .rightOption, alternate: .shift, refine: .fnThenDictationKey)

        Self.postFlags(63, Self.fn)                              // fn down
        try await Task.sleep(for: .milliseconds(90))
        Self.postFlags(61, Self.fn | Self.alt | Self.ralt)       // Right Option down, fn held
        // Well past `armDelay`: if this were going to arm, it would have.
        try await Task.sleep(for: .milliseconds(400))
        Self.postFlags(61, Self.fn)                              // Right Option up
        try await Task.sleep(for: .milliseconds(90))
        Self.postFlags(63, 0)                                    // fn up
        try await Task.sleep(for: .milliseconds(250))

        #expect(sink.gestures == [.refinePopup])
        #expect(sink.events.isEmpty, "the chord armed a recording: \(sink.events)")
    }

    @Test("a plain Right Option hold still dictates, and opens no popup")
    func plainHoldStillDictates() async throws {
        let monitor = HotkeyMonitor(armDelay: 0.12)
        let sink = Sink()
        let tasks = sink.consume(monitor)
        defer { tasks.forEach { $0.cancel() }; monitor.stop() }
        try monitor.start(key: .rightOption, alternate: .shift, refine: .fnThenDictationKey)

        Self.postFlags(61, Self.alt | Self.ralt)
        try await Task.sleep(for: .milliseconds(400))
        Self.postFlags(61, 0)
        try await Task.sleep(for: .milliseconds(250))

        #expect(sink.gestures.isEmpty, "a plain hold opened the popup")
        #expect(sink.events == [.pressed(alternate: false), .released])
    }

    /// The other half of the ordering rule: "if a hold has already armed, do not retroactively cancel
    /// the recording — finish it." Before the qualifier keycode was exempted from chord cancellation,
    /// reaching for 🌐 a moment too late aborted a dictation the user was already speaking into.
    @Test("fn arriving after the hold armed neither cancels it nor opens a popup")
    func lateQualifierIsIgnored() async throws {
        let monitor = HotkeyMonitor(armDelay: 0.12)
        let sink = Sink()
        let tasks = sink.consume(monitor)
        defer { tasks.forEach { $0.cancel() }; monitor.stop() }
        try monitor.start(key: .rightOption, alternate: .shift, refine: .fnThenDictationKey)

        Self.postFlags(61, Self.alt | Self.ralt)                 // Right Option down first
        try await Task.sleep(for: .milliseconds(250))            // armed by now
        #expect(sink.events == [.pressed(alternate: false)])

        Self.postFlags(63, Self.fn | Self.alt | Self.ralt)       // fn arrives late
        try await Task.sleep(for: .milliseconds(250))
        // Still recording: no `.released` yet, and no popup.
        #expect(sink.events == [.pressed(alternate: false)], "a late fn ended the recording")
        #expect(sink.gestures.isEmpty, "a late fn opened the popup")

        Self.postFlags(61, Self.fn)                              // Right Option up
        try await Task.sleep(for: .milliseconds(250))
        Self.postFlags(63, 0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(sink.events == [.pressed(alternate: false), .released])
        #expect(sink.gestures.isEmpty)
    }
}
