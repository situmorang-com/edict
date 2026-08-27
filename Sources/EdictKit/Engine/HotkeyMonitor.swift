import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

// MARK: - Public surface

public enum HotkeyEvent: Sendable, Hashable {
    /// The key has been held long enough to be a deliberate dictation gesture. Start recording.
    ///
    /// - Parameter alternate: the configured language modifier was held at the moment the hold armed.
    ///   The monitor deliberately knows nothing about locales — it reports the modifier state and
    ///   `DictationController` maps it to a language. Sampled once, at arm time, and never revised for
    ///   the rest of the hold; see `armTimerFired`.
    case pressed(alternate: Bool)
    /// The hold ended. Always follows a `.pressed`, exactly once — including when the hold was aborted,
    /// so a consumer can never be left recording forever.
    case released
}

/// A gesture that is *not* dictation, reported on its own stream.
///
/// Deliberately separate from ``HotkeyEvent``. That type is a two-case press/release contract with a
/// hard invariant (exactly one `.released` per `.pressed`), and a third case would have made every
/// consumer's exhaustive switch answer a question about a gesture that has no release at all.
public enum HotkeyGesture: Sendable, Hashable {
    /// The refine-selection chord fired. Dictation deliberately did **not** arm; there is no
    /// matching release event and none is owed.
    case refinePopup
}

/// One keystroke the monitor captured on behalf of a non-activating panel.
///
/// The panel that shows the refine popup can never become key (it would steal focus and lose the
/// selection it is about to replace), so its keystrokes have to come from a tap. See
/// ``HotkeyMonitor/beginKeyCapture(shouldCapture:)``.
public struct HotkeyCapturedKey: Sendable, Hashable {
    public var keyCode: Int64
    public var rawFlags: UInt64

    public init(keyCode: Int64, rawFlags: UInt64) {
        self.keyCode = keyCode
        self.rawFlags = rawFlags
    }
}

public enum HotkeyError: Error, Sendable {
    case tapCreationFailed
    case permissionDenied
}

/// Why a hold never became a `.pressed`, or why a `.pressed` was terminated early.
public enum HotkeyCancelReason: Sendable, Hashable {
    /// Held for less than `armDelay`. A bare tap of Right Option is AltGr on many layouts, not dictation.
    case tooShort(TimeInterval)
    case chordedWithKey(Int64)
    case chordedWithModifier(Int64)
    /// The window server disabled the tap mid-hold, so the key release may never arrive.
    case tapDisabled
    /// The user rebound the hotkey while it was held.
    case keyChanged
}

/// Out-of-band signal for the UI and the log. Deliberately a *separate* stream from `events`:
/// `HotkeyEvent` is a fixed two-case contract that other agents compile against, and a monitor that
/// silently swallows "your tap just died" is exactly the bug RECON §12 warns about.
public enum HotkeyDiagnostic: Sendable, Hashable {
    /// The key went down; the arm window has started. Not yet a recording.
    case holdBegan
    case cancelled(HotkeyCancelReason)
    /// `.tapDisabledByTimeout` / `.tapDisabledByUserInput` arrived and the tap was re-enabled.
    case tapReEnabled(String)
    /// The tap is dead and re-enabling did not help. The UI must say so; the tap needs re-creating.
    case permissionLost
    /// The window server granted a narrower `eventsOfInterest` than we asked for (RECON §11).
    case maskIncomplete(requested: UInt64, granted: UInt64)
}

// MARK: - HotkeyBinding

/// A `HotkeyChoice` resolved into the exact bit tests the event tap needs.
///
/// The device-dependent masks are verbatim from
/// `IOKit.framework/Headers/hidsystem/IOLLEvent.h` and were verified 10/10 by the RECON probe's
/// synthetic-event decoder. RECON §9: **never** intersect with
/// `NSEvent.ModifierFlags.deviceIndependentFlagsMask` (measured `0xffff0000`) — the low 16 bits are
/// exactly where left/right lives, and after masking Left and Right Option are indistinguishable.
struct HotkeyBinding: Sendable, Hashable {

    /// Device-dependent bits, low 16 of `CGEvent.flags.rawValue`.
    enum DevBits {
        static let rcmd: UInt64 = 0x0000_0010   // NX_DEVICERCMDKEYMASK
        static let ralt: UInt64 = 0x0000_0040   // NX_DEVICERALTKEYMASK
        static let rctrl: UInt64 = 0x0000_2000  // NX_DEVICERCTLKEYMASK
        // There is deliberately no fn entry: NX_DEVICEFN does not exist.
    }

    /// Virtual keycodes as reported in `.keyboardEventKeycode`.
    enum KeyCode {
        static let rightCommand: Int64 = 54
        static let rightOption: Int64 = 61
        static let rightControl: Int64 = 62
        static let fn: Int64 = 63
        static let f13: Int64 = 105
    }

    /// Which physical key toggled.
    let keyCode: Int64
    /// The device-dependent bit that is SET while the key is physically held. Zero for fn/Globe and for
    /// non-modifier keys.
    let deviceBit: UInt64
    /// Used only when `deviceBit == 0`: fn/Globe is legible solely through `maskSecondaryFn`.
    let fallbackMask: UInt64
    /// Modifiers arrive as `.flagsChanged`; ordinary keys as `.keyDown`/`.keyUp`.
    let isModifier: Bool
    let displayName: String

    /// Flag bits that mean "the language modifier is held". Zero when no modifier is configured, or
    /// when every bit the modifier owns is also owned by the hotkey itself — see `init` below.
    let alternateMask: UInt64
    /// Keycodes belonging to the language modifier, which are therefore *exempt* from chord
    /// cancellation. Only the sides whose device bit survives into `alternateMask` are listed, so the
    /// exemption can never be wider than the thing it is exempting for.
    let alternateKeyCodes: Set<Int64>

    init(_ choice: HotkeyChoice, alternate: HotkeyModifier? = nil) {
        displayName = choice.displayName

        // The modifier is masked against the hotkey's *own* bits before anything else. Without this,
        // choosing Option as the language modifier while the hotkey is Right Option would make every
        // single hold look "alternate", because Right Option sets `maskAlternate` itself. What is left
        // after the subtraction is the honest gesture — for that pair, Right Option + *Left* Option.
        // If nothing survives, the combination is unusable and the shortcut is simply off.
        let own = HotkeyBinding.ownedFlags(for: choice)
        let sides = (alternate?.sides ?? []).filter { $0.deviceBit & own == 0 }
        let mask = sides.reduce(UInt64(0)) { $0 | $1.deviceBit }
            | ((alternate?.deviceIndependentBit ?? 0) & ~own)
        // A device-independent bit on its own is not enough to identify a side, but it is enough to
        // answer "is it held", which is all `isAlternateHeld` is asked. Require at least one surviving
        // side *or* a surviving shared bit.
        alternateMask = sides.isEmpty && (alternate?.deviceIndependentBit ?? 0) & ~own == 0 ? 0 : mask
        alternateKeyCodes = Set(sides.map(\.keyCode))

        switch choice {
        case .rightOption:
            keyCode = KeyCode.rightOption; deviceBit = DevBits.ralt; fallbackMask = 0; isModifier = true
        case .rightCommand:
            keyCode = KeyCode.rightCommand; deviceBit = DevBits.rcmd; fallbackMask = 0; isModifier = true
        case .rightControl:
            keyCode = KeyCode.rightControl; deviceBit = DevBits.rctrl; fallbackMask = 0; isModifier = true
        case .fn:
            // RECON §9: fn has no device bit, and `maskSecondaryFn` (0x00800000) is *also* set on the
            // keyDown of every arrow key and every fn-row key. That is why `isHeld` is only ever
            // consulted after the keyCode has already been matched to 63 on a `.flagsChanged`.
            keyCode = KeyCode.fn
            deviceBit = 0
            fallbackMask = UInt64(CGEventFlags.maskSecondaryFn.rawValue)
            isModifier = true
        case .f13:
            keyCode = KeyCode.f13; deviceBit = 0; fallbackMask = 0; isModifier = false
        }
    }

    /// True when this event's flags say the key is physically DOWN. Only meaningful for modifiers, and
    /// only after `keyCode` has matched.
    func isHeld(rawFlags: UInt64) -> Bool {
        deviceBit != 0 ? (rawFlags & deviceBit) != 0 : (rawFlags & fallbackMask) != 0
    }

    /// True when the configured language modifier is held.
    ///
    /// **Bit test, never an equality test.** RECON §9 and the Karabiner finding together: this machine
    /// re-synthesises every keystroke through a DriverKit virtual keyboard that stamps
    /// `nonCoalesced` (`0x100`) on every event, so any comparison against a literal raw value — even a
    /// correct one like `0x00020002` — fails for reasons that look like the key is not being pressed.
    func isAlternateHeld(rawFlags: UInt64) -> Bool {
        alternateMask != 0 && (rawFlags & alternateMask) != 0
    }

    /// Every flag bit the hotkey key itself sets while held. Subtracted from the language modifier's
    /// mask so a modifier can never be satisfied by the hotkey it is qualifying.
    private static func ownedFlags(for choice: HotkeyChoice) -> UInt64 {
        switch choice {
        case .rightOption: UInt64(CGEventFlags.maskAlternate.rawValue) | DevBits.ralt
        case .rightCommand: UInt64(CGEventFlags.maskCommand.rawValue) | DevBits.rcmd
        case .rightControl: UInt64(CGEventFlags.maskControl.rawValue) | DevBits.rctrl
        case .fn: UInt64(CGEventFlags.maskSecondaryFn.rawValue)
        case .f13: 0
        }
    }
}

// MARK: - RefineChordBinding

/// A ``RefineChord`` resolved into the exact bit tests the event tap needs.
///
/// Two families, because they are recognised in two different places:
///
/// * **Qualified** (`fn` then the dictation key). Recognised in the `.flagsChanged` branch at the
///   moment the dictation key goes *down*, from the qualifier bit carried on that very event. This
///   is the whole ordering rule: the bit is either already set when the key goes down, or it is not.
/// * **Discrete** (`⌥⌘R`, `⌃⌥R`). Recognised in the `.keyDown` branch, from a keycode plus a
///   required-and-forbidden pair of flag masks.
///
/// Everything is a bit test. RECON amendment 31 measured Right Option arriving as `0x00080140`
/// rather than the expected `0x00080040` because a keyboard remapper stamps `nonCoalesced` (`0x100`)
/// on every event it synthesizes, and this file's own probe measured `0x20000000` on every
/// posted one — so any comparison against a literal raw word silently never fires.
struct RefineChordBinding: Sendable, Hashable {

    /// Virtual keycodes this file needs beyond ``HotkeyBinding/KeyCode``.
    private enum KeyCode {
        static let r: Int64 = 15   // kVK_ANSI_R
    }

    /// Flag bits meaning "the qualifier is held", or `nil` for the discrete family.
    let qualifierMask: UInt64?
    /// Keycodes belonging to the qualifier. Exempt from chord cancellation, which is the second half
    /// of the ordering rule: a qualifier pressed *during* a hold must not cancel the recording.
    let qualifierKeyCodes: Set<Int64>

    /// The plain key of a discrete chord, or `nil` for the qualified family.
    let discreteKeyCode: Int64?
    /// Every bit in here must be SET for a discrete chord to match.
    let requiredFlags: UInt64
    /// Any bit in here being set disqualifies the match.
    let forbiddenFlags: UInt64

    let displayName: String

    /// `nil` when the chord cannot be expressed with this dictation key — `fn` cannot qualify `fn`.
    /// `Settings.effectiveRefineChord` refuses the same combination in the UI, so this is the second
    /// of two independent guards rather than the only one.
    init?(_ chord: RefineChord, dictationKey: HotkeyChoice) {
        displayName = chord.displayName(dictationKey: dictationKey)

        switch chord {
        case .fnThenDictationKey:
            guard dictationKey != .fn else { return nil }
            qualifierMask = UInt64(CGEventFlags.maskSecondaryFn.rawValue)
            qualifierKeyCodes = [HotkeyBinding.KeyCode.fn]
            discreteKeyCode = nil
            requiredFlags = 0
            forbiddenFlags = 0

        case .optionCommandR, .controlOptionR:
            qualifierMask = nil
            qualifierKeyCodes = []
            discreteKeyCode = KeyCode.r
            let required: UInt64 = chord == .optionCommandR
                ? UInt64(CGEventFlags.maskAlternate.rawValue) | UInt64(CGEventFlags.maskCommand.rawValue)
                : UInt64(CGEventFlags.maskControl.rawValue) | UInt64(CGEventFlags.maskAlternate.rawValue)
            let excluded: UInt64 = chord == .optionCommandR
                ? UInt64(CGEventFlags.maskControl.rawValue) | UInt64(CGEventFlags.maskShift.rawValue)
                : UInt64(CGEventFlags.maskCommand.rawValue) | UInt64(CGEventFlags.maskShift.rawValue)
            requiredFlags = required
            // Plus the dictation key's own *device* bit. Without this, a user whose dictation key is
            // Right Option and who reaches for ⌥⌘R with that key would fire the chord out of a hold
            // that has already armed — a popup and a half-second recording from one gesture. Only the
            // device bit is excluded, never the side-agnostic `maskAlternate`, because ⌥⌘R needs
            // `maskAlternate` set to be ⌥⌘R at all.
            forbiddenFlags = excluded | Self.deviceBit(of: dictationKey)
        }
    }

    /// The side-specific bit the dictation key sets while held, or the `fn` bit for Globe. Zero for a
    /// non-modifier key, which cannot contaminate a chord.
    private static func deviceBit(of key: HotkeyChoice) -> UInt64 {
        switch key {
        case .rightOption: HotkeyBinding.DevBits.ralt
        case .rightCommand: HotkeyBinding.DevBits.rcmd
        case .rightControl: HotkeyBinding.DevBits.rctrl
        case .fn: UInt64(CGEventFlags.maskSecondaryFn.rawValue)
        case .f13: 0
        }
    }

    func matchesDiscrete(keyCode: Int64, rawFlags: UInt64) -> Bool {
        guard let discreteKeyCode, keyCode == discreteKeyCode else { return false }
        return rawFlags & requiredFlags == requiredFlags && rawFlags & forbiddenFlags == 0
    }
}

// MARK: - HotkeyModifier bits

extension HotkeyModifier {

    /// One physical key of a paired modifier: its virtual keycode and its device-dependent flag bit.
    struct Side: Sendable, Hashable {
        let keyCode: Int64
        let deviceBit: UInt64
    }

    /// Left and right, in that order. Device bits are verbatim from
    /// `IOKit.framework/Headers/hidsystem/IOLLEvent.h`; keycodes are the standard virtual keycodes.
    /// **Either side counts** — a user reaching for Shift with the left hand while the right hand
    /// holds Right Option is doing exactly the intended gesture.
    var sides: [Side] {
        switch self {
        case .shift:   [Side(keyCode: 56, deviceBit: 0x0000_0002), Side(keyCode: 60, deviceBit: 0x0000_0004)]
        case .control: [Side(keyCode: 59, deviceBit: 0x0000_0001), Side(keyCode: 62, deviceBit: 0x0000_2000)]
        case .command: [Side(keyCode: 55, deviceBit: 0x0000_0008), Side(keyCode: 54, deviceBit: 0x0000_0010)]
        case .option:  [Side(keyCode: 58, deviceBit: 0x0000_0020), Side(keyCode: 61, deviceBit: 0x0000_0040)]
        }
    }

    /// The side-agnostic bit in the high half of the flags word. Kept as a *fallback* alongside the
    /// device bits, not instead of them: if Karabiner's virtual keyboard ever normalises the low bits
    /// away, this one still answers "is it held".
    var deviceIndependentBit: UInt64 {
        switch self {
        case .shift: UInt64(CGEventFlags.maskShift.rawValue)
        case .control: UInt64(CGEventFlags.maskControl.rawValue)
        case .command: UInt64(CGEventFlags.maskCommand.rawValue)
        case .option: UInt64(CGEventFlags.maskAlternate.rawValue)
        }
    }
}

// MARK: - HotkeyMonitor

/// Watches for the push-to-talk key globally.
///
/// Mechanism and every timing constant come from RECON's hotkey probe:
///
/// - A **listen-only** session tap (`.cgSessionEventTap`, `.headInsertEventTap`, `.listenOnly`).
///   `NSEvent.addGlobalMonitorForEvents` is disqualified twice over by the macOS 26.5 SDK header:
///   key events need the *Accessibility* grant, and the handler is never called for events destined for
///   our own app — so push-to-talk would die whenever Edict's own window had focus.
/// - Never suppress (RECON §13). Right Option is AltGr on many layouts; eating it would break dead keys
///   and accented characters system-wide. Ambiguity is resolved in software instead: the key must be held
///   alone, and held for at least `armDelay`.
/// - A dedicated `.userInteractive` thread with its own CFRunLoop (RECON §12). Measured: with the main
///   thread blocked 3 s, a dedicated run loop serviced 151/150 expected ticks and the main run loop
///   serviced 0/150. On the main run loop any SwiftUI hitch delays press/release by the hitch duration
///   *and* risks `.tapDisabledByTimeout`, which silently kills the hotkey.
public final class HotkeyMonitor: Sendable {

    // MARK: State

    /// Everything mutable, behind one lock. The C tap callback, the arm timer and the public API all
    /// touch this from three different threads; one uncontended `NSLock` acquisition is tens of
    /// nanoseconds, nothing against the sub-millisecond callback budget RECON §12 demands.
    ///
    /// `@unchecked Sendable` is deliberate and narrow. It holds `CFMachPort`, `CFRunLoopSource`,
    /// `CFRunLoopTimer`, `CFRunLoop` and `Thread`, none of which are `Sendable`, so
    /// `Synchronization.Mutex` cannot store them at all — its `withLock` takes `inout sending Value` and
    /// rejects a task-isolated CF reference. This is the same shape as RECON's compiled
    /// `PushToTalkMonitor`, with the extra invariant that *every* field below is read and written only
    /// inside `withLock`.
    /// One generation of tap plumbing, owned end to end by the thread that created it.
    ///
    /// Bundling these rather than storing four loose fields is what makes a fast `stop()`-then-`start()`
    /// safe: the departing thread tears down *its own* `TapResources`, so it can never invalidate the
    /// Mach port that a newly started thread has just published.
    private final class TapResources: @unchecked Sendable {
        let runLoop: CFRunLoop
        let port: CFMachPort
        let source: CFRunLoopSource?
        let timer: CFRunLoopTimer?

        init(runLoop: CFRunLoop, port: CFMachPort, source: CFRunLoopSource?, timer: CFRunLoopTimer?) {
            self.runLoop = runLoop
            self.port = port
            self.source = source
            self.timer = timer
        }
    }

    /// The suppressing tap, alive only while a non-activating panel is waiting for a keystroke.
    ///
    /// A second port rather than a second thread: it lives on the *same* run loop as the hotkey tap,
    /// so teardown happens on the thread that created it (CFMachPort teardown is not thread-agnostic
    /// in practice) and the two cannot race each other.
    private final class CaptureResources: @unchecked Sendable {
        let runLoop: CFRunLoop
        let port: CFMachPort
        let source: CFRunLoopSource?

        init(runLoop: CFRunLoop, port: CFMachPort, source: CFRunLoopSource?) {
            self.runLoop = runLoop
            self.port = port
            self.source = source
        }
    }

    private enum CaptureRequest: Sendable {
        case none, install, remove
    }

    private final class TapState: @unchecked Sendable {
        private let lock = NSLock()

        var binding: HotkeyBinding?
        /// The refine chord in force, or `nil` when the feature is off.
        var refine: RefineChordBinding?
        /// Whether the refine qualifier was held as of the most recent `.flagsChanged`.
        ///
        /// A second, independent source for the ordering rule, alongside the bit carried on the
        /// dictation key's own down event. Both come from the tap; neither comes from
        /// `CGEventSource.flagsState`, which `SelectionBridge` measured reporting `maskCommand` set
        /// for seconds at a stretch with no key physically down — a latched reading here would open
        /// the popup instead of starting a recording.
        ///
        /// Self-correcting, and that is what makes a second source safe rather than a second way to
        /// be wrong: every `.flagsChanged` carries the *complete* modifier state, so this is rewritten
        /// from scratch on every modifier event of any kind rather than accumulated.
        var qualifierHeld = false
        var thread: Thread?
        /// The run loop of the *current* thread, kept separately so `stop()` can wake it even before the
        /// tap is installed or after installation failed.
        var runLoop: CFRunLoop?
        var resources: TapResources?

        /// Non-nil while the key is physically down.
        var holdStart: CFAbsoluteTime?
        /// The raw flags word from the most recent `.flagsChanged` the tap delivered.
        ///
        /// A second, independent source for the language-modifier test. Every `.flagsChanged` carries
        /// the *complete* modifier state at that moment, so this is current rather than accumulated —
        /// and it needs no API beyond the tap we already have. It exists because RECON could not
        /// confirm whether `CGEventSource.flagsState` works at all without Input Monitoring (it polled
        /// 310 samples while nobody was pressing anything, so all-zero was inconclusive). If that call
        /// turns out to be inert, the feature would silently always choose the primary language; this
        /// makes that impossible.
        var lastObservedFlags: UInt64 = 0
        /// True once `.pressed` has been emitted for the current hold.
        var armed = false
        /// True once this hold has been disqualified; suppresses repeat cancellations.
        var chorded = false
        /// Set after a failed re-enable so the watchdog reports `.permissionLost` exactly once.
        var reportedPermissionLost = false
        var reEnableCount = 0

        // MARK: Key capture

        var capture: CaptureResources?
        /// Whether captured keys are swallowed as well as reported. False while the popup is showing
        /// something that cannot act on them, so a stray digit reaches the app underneath instead of
        /// vanishing — which is `RefinePopupSession.handle`'s rule, enforced here at the tap.
        var suppressing = false
        /// Keycodes whose `.keyDown` was swallowed, so the matching `.keyUp` is swallowed too even if
        /// suppression was switched off in between. An unmatched key-up is the kind of thing that
        /// leaves a text field thinking a key is still down.
        var suppressedKeys: Set<Int64> = []
        /// Set by the caller; asked of every keystroke while the capture tap is installed. Pure and
        /// allocation-free by contract — it runs inside a `.defaultTap` callback, which is on the
        /// critical path of every keystroke on the system.
        var shouldCapture: (@Sendable (Int64, UInt64) -> Bool)?
        /// What the tap thread should do with the capture tap next. Requests rather than direct calls
        /// because the port has to be created and invalidated on the thread that owns the run loop.
        var captureRequest: CaptureRequest = .none
        /// Set by the tap thread once an install request has been serviced; `nil` while pending.
        var captureOutcome: Bool?

        func withLock<R>(_ body: (TapState) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body(self)
        }
    }

    private let state = TapState()

    private let eventStream: AsyncStream<HotkeyEvent>
    private let eventContinuation: AsyncStream<HotkeyEvent>.Continuation
    private let diagnosticStream: AsyncStream<HotkeyDiagnostic>
    private let diagnosticContinuation: AsyncStream<HotkeyDiagnostic>.Continuation
    private let gestureStream: AsyncStream<HotkeyGesture>
    private let gestureContinuation: AsyncStream<HotkeyGesture>.Continuation
    private let capturedKeyStream: AsyncStream<HotkeyCapturedKey>
    private let capturedKeyContinuation: AsyncStream<HotkeyCapturedKey>.Continuation

    /// Minimum hold before a `.pressed` is emitted (RECON §13, ~120 ms). Below this, the gesture is
    /// treated as an ordinary modifier tap and produces no recording at all.
    ///
    /// This costs ~120 ms of leading audio. It is inside the human press-then-speak gap in practice, and
    /// `Settings.prewarmMicrophone` plus the capture layer's pre-roll ring buffer recovers it for users
    /// who want the last millisecond.
    public let armDelay: TimeInterval

    public init(armDelay: TimeInterval = 0.12) {
        self.armDelay = armDelay
        // Unbounded on purpose. `.bufferingNewest` discards the OLDEST element (RECON §20), which here
        // would mean dropping a `.released` and leaving the app recording forever.
        (eventStream, eventContinuation) = AsyncStream<HotkeyEvent>.makeStream(bufferingPolicy: .unbounded)
        // Diagnostics are advisory and may have no consumer at all, so they must not grow without bound.
        (diagnosticStream, diagnosticContinuation) =
            AsyncStream<HotkeyDiagnostic>.makeStream(bufferingPolicy: .bufferingNewest(16))
        // `.bufferingNewest` is right here where it is wrong for `events`: a gesture has no matching
        // release to lose, and a chord the consumer was too busy to service two seconds ago should
        // not open a popup over whatever the user has selected *now*.
        (gestureStream, gestureContinuation) =
            AsyncStream<HotkeyGesture>.makeStream(bufferingPolicy: .bufferingNewest(1))
        (capturedKeyStream, capturedKeyContinuation) =
            AsyncStream<HotkeyCapturedKey>.makeStream(bufferingPolicy: .bufferingNewest(8))
    }

    /// Best-effort only. The tap thread's block captures `self` **strongly** on purpose: the tap holds
    /// an `Unmanaged.passUnretained` pointer back to this object, so a weak capture would open a window
    /// where the callback dereferences freed memory. The consequence is that a running monitor keeps
    /// itself alive, so `stop()` is not optional — a caller that simply drops the last reference leaks
    /// the thread and one Mach port. `AppModel`/`DictationController` must call `stop()` on teardown.
    deinit {
        // `tearingDownCapture: false` on purpose. The capture path's `wake` closure captures `self`,
        // and forming any reference to an object already inside `deinit` is a crash waiting for a
        // release build. Nothing is leaked by skipping it: the tap thread's exit path calls
        // `removeCaptureTap()` unconditionally, and by the time `deinit` can run the thread is
        // already gone — a running monitor keeps itself alive through the tap's strong capture.
        stop(tearingDownCapture: false)
        eventContinuation.finish()
        diagnosticContinuation.finish()
        gestureContinuation.finish()
        capturedKeyContinuation.finish()
    }

    // MARK: Public API

    public var events: AsyncStream<HotkeyEvent> { eventStream }

    public var diagnostics: AsyncStream<HotkeyDiagnostic> { diagnosticStream }

    /// Gestures that are not dictation. Same one-consumer rule as ``events`` (RECON amendment 32):
    /// this is a stored stream, so iterate it exactly once and never cancel that consumer on a
    /// restart.
    public var gestures: AsyncStream<HotkeyGesture> { gestureStream }

    /// Keystrokes captured for a non-activating panel, while ``beginKeyCapture(shouldCapture:)`` is
    /// in force. Same one-consumer rule.
    public var capturedKeys: AsyncStream<HotkeyCapturedKey> { capturedKeyStream }

    /// True only when the tap exists *and* the window server still has it enabled. RECON §11: a
    /// `.listenOnly` tap created without Input Monitoring is non-nil but permanently dead, so the
    /// existence of the port proves nothing.
    public var isRunning: Bool {
        state.withLock { s in
            guard let port = s.resources?.port else { return false }
            return CGEvent.tapIsEnabled(tap: port)
        }
    }

    /// Installs the tap on a fresh dedicated thread.
    ///
    /// Throws `.permissionDenied` *before* creating anything, because a tap created while denied can
    /// never be enabled — only replaced (RECON §11). Call this again after the grant arrives; do not try
    /// to revive a dead monitor.
    /// - Parameter alternate: the modifier that may be held alongside the hotkey without cancelling
    ///   the hold, whose state is reported on `.pressed(alternate:)`. `nil` restores the strict
    ///   "held alone" rule for every modifier.
    /// - Parameter refine: the chord that opens the refine popup, or `nil` when that feature is off.
    public func start(
        key: HotkeyChoice,
        alternate: HotkeyModifier? = nil,
        refine: RefineChord? = nil
    ) throws {
        let binding = HotkeyBinding(key, alternate: alternate)
        let refineBinding = refine.flatMap { RefineChordBinding($0, dictationKey: key) }

        // Gate BEFORE creating. This is the whole point of RECON §11: `.listenOnly` `tapCreate` hands
        // back a non-nil CFMachPort even when access is denied, and five `tapEnable` retries over a
        // second never flipped `tapIsEnabled`.
        guard PermissionProbe.inputMonitoringGranted else {
            Log.hotkey.error("start refused: Input Monitoring not granted")
            throw HotkeyError.permissionDenied
        }

        let alreadyRunning: Bool = state.withLock { s in
            s.binding = binding
            s.refine = refineBinding
            s.qualifierHeld = false
            if s.thread == nil {
                // A fresh generation gets a fresh watchdog: without this reset, a monitor that died once
                // and was correctly re-created after the grant arrived would never report a second death.
                s.reportedPermissionLost = false
                s.holdStart = nil
                s.armed = false
                s.chorded = false
            }
            return s.thread != nil
        }
        if alreadyRunning {
            Log.hotkey.info("start: already running, rebound to \(binding.displayName, privacy: .public)")
            return
        }

        #if DEBUG
        let portsBefore = Self.machPortCount()
        #endif

        // A one-shot box rather than a captured `var`: the semaphore is the happens-before edge, which
        // is what makes this safe, but the compiler cannot see that through a `var` capture.
        final class Flag: @unchecked Sendable { var value = false }
        let ready = DispatchSemaphore(value: 0)
        let installed = Flag()

        let thread = Thread { [self] in
            var owned: TapResources?
            if let runLoop = CFRunLoopGetCurrent() {
                state.withLock { $0.runLoop = runLoop }
                owned = installTap(on: runLoop)
                installed.value = owned != nil
            }
            ready.signal()

            while !Thread.current.isCancelled {
                // 0.25 s slices give a cheap cancellation check plus a place for the watchdog. A bare
                // `CFRunLoopRun()` would return instantly on a source-less run loop and busy-spin.
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
                runWatchdog()
                // Belt and braces behind `CFRunLoopPerformBlock`: a request that somehow missed the
                // wake-up is serviced on the next slice rather than never.
                serviceCaptureRequest()
            }
            // Unconditional, and before the hotkey tap goes: a suppressing tap left installed after
            // its owning thread exited would swallow the user's digits for ever.
            removeCaptureTap()
            teardown(owned)
        }
        thread.name = "com.edict.hotkey"
        thread.qualityOfService = .userInteractive   // keeps the tap off the efficiency cores
        thread.stackSize = 512 * 1024
        state.withLock { $0.thread = thread }
        thread.start()
        ready.wait()

        guard installed.value else {
            stop()
            #if DEBUG
            let leaked = Self.machPortCount() - portsBefore
            if leaked > 0 { Log.hotkey.error("failed start leaked \(leaked) Mach ports") }
            #endif
            throw HotkeyError.tapCreationFailed
        }

        Log.hotkey.notice("""
            hotkey monitor live on \(binding.displayName, privacy: .public) \
            (keyCode \(binding.keyCode)) \
            alternate=\(alternate?.rawValue ?? "none", privacy: .public) \
            mask=0x\(String(binding.alternateMask, radix: 16), privacy: .public) \
            refine=\(refineBinding?.displayName ?? "off", privacy: .public)
            """)
    }

    /// Rebinding while running needs no new tap: the mask is identical for every choice, and the
    /// callback reads the binding fresh on every event.
    public func update(
        key: HotkeyChoice,
        alternate: HotkeyModifier? = nil,
        refine: RefineChord? = nil
    ) {
        let binding = HotkeyBinding(key, alternate: alternate)
        let refineBinding = refine.flatMap { RefineChordBinding($0, dictationKey: key) }
        let wasHolding: Bool = state.withLock { s in
            let changed = s.binding?.keyCode != binding.keyCode
            s.binding = binding
            s.refine = refineBinding
            // The tracker is keyed to a mask that may just have changed, and a `true` carried across
            // a rebind would answer the ordering rule for the wrong modifier.
            s.qualifierHeld = false
            return changed && s.holdStart != nil
        }
        if wasHolding { abortHold(reason: .keyChanged) }
        Log.hotkey.info("""
            hotkey rebound to \(binding.displayName, privacy: .public) \
            alternate=\(alternate?.rawValue ?? "none", privacy: .public) \
            mask=0x\(String(binding.alternateMask, radix: 16), privacy: .public) \
            refine=\(refineBinding?.displayName ?? "off", privacy: .public)
            """)
    }

    public func stop() {
        stop(tearingDownCapture: true)
    }

    private func stop(tearingDownCapture: Bool) {
        // Aborting first guarantees a `.released` reaches the consumer before the tap goes away.
        if state.withLock({ $0.holdStart != nil }) { abortHold(reason: .tapDisabled) }
        // A suppressing tap that outlived its thread would keep swallowing the user's digits with
        // nothing left to deliver them to.
        if tearingDownCapture { endKeyCapture() }

        let (thread, runLoop) = state.withLock { s -> (Thread?, CFRunLoop?) in
            let t = s.thread
            let rl = s.runLoop
            s.thread = nil
            return (t, rl)
        }
        guard let thread else { return }
        thread.cancel()
        // Wake the run loop so the 0.25 s slice ends immediately and `teardownTap()` runs on the same
        // thread that created the port — CFMachPort teardown is not thread-agnostic in practice.
        if let runLoop { CFRunLoopWakeUp(runLoop) }
        Log.hotkey.info("hotkey monitor stopping")
    }

    // MARK: Tap plumbing — tap thread only

    /// The mask we ask for. Keyboard-only on purpose: RECON §11 measured that mixing in mouse events
    /// lets the window server strip keyDown/keyUp while keeping the mask non-empty, so the tap is
    /// created, looks healthy, and is keyboard-blind.
    private static let requestedMask: CGEventMask =
        (1 << CGEventType.flagsChanged.rawValue)
        | (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.keyUp.rawValue)

    private func installTap(on runLoop: CFRunLoop) -> TapResources? {
        // `passUnretained` is mandatory, not a micro-optimisation: `CGEventTapCreate` never releases
        // `userInfo`, and there is nowhere legal to call `takeRetainedValue` because the callback fires
        // many times. `passRetained` would be an unconditional leak of the monitor and its streams.
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.requestedMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<HotkeyMonitor>.fromOpaque(refcon)
                    .takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: context
        ) else {
            Log.hotkey.error("CGEvent.tapCreate returned nil")
            return nil
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)

        // A repeating timer with an absurd interval, parked in the far future. Rescheduling it with
        // `CFRunLoopTimerSetNextFireDate` on key-down costs no allocation, which keeps the hot path
        // inside RECON §12's sub-millisecond callback budget. A one-shot timer would invalidate itself
        // on first fire and force a fresh allocation per press.
        let timer = CFRunLoopTimerCreateWithHandler(
            kCFAllocatorDefault,
            Date.distantFuture.timeIntervalSinceReferenceDate,
            .greatestFiniteMagnitude,
            0, 0
        ) { [weak self] _ in
            self?.armTimerFired()
        }
        if let timer { CFRunLoopAddTimer(runLoop, timer, .commonModes) }

        let resources = TapResources(runLoop: runLoop, port: port, source: source, timer: timer)
        state.withLock { $0.resources = resources }

        // Non-nil is NOT success for a `.listenOnly` tap. Both of these checks are load-bearing.
        guard CGEvent.tapIsEnabled(tap: port) else {
            Log.hotkey.error("tap created but permanently disabled — Input Monitoring is not really granted")
            teardown(resources)
            return nil
        }
        let granted = Self.grantedMask(forPID: getpid())
        guard granted & Self.requestedMask == Self.requestedMask else {
            Log.hotkey.error("granted event mask 0x\(String(granted, radix: 16), privacy: .public) is narrower than requested 0x\(String(Self.requestedMask, radix: 16), privacy: .public)")
            diagnosticContinuation.yield(.maskIncomplete(requested: Self.requestedMask, granted: granted))
            teardown(resources)
            return nil
        }
        return resources
    }

    /// Tears down one generation. Only ever called on the thread that created `resources`.
    ///
    /// RECON §12 measured the exact order, and it is not negotiable: 500 create-without-teardown cycles
    /// moved this task's Mach port count by exactly 500, 1:1, while the order below held the delta
    /// constant across 50, 500 and 3000 iterations. Dropping the Swift reference is not enough, because
    /// the run loop source holds the port. (Re-measured locally at 500 cycles: delta 4 with teardown,
    /// 500 without.)
    private func teardown(_ resources: TapResources?) {
        guard let resources else {
            state.withLock { $0.runLoop = nil }
            return
        }
        // Clear the shared pointer only if it still refers to *this* generation.
        state.withLock { s in
            if s.resources === resources {
                s.resources = nil
                s.runLoop = nil
            }
        }
        if let timer = resources.timer {
            CFRunLoopRemoveTimer(resources.runLoop, timer, .commonModes)
            CFRunLoopTimerInvalidate(timer)
        }
        if let source = resources.source {
            CFRunLoopRemoveSource(resources.runLoop, source, .commonModes)
        }
        CGEvent.tapEnable(tap: resources.port, enable: false)
        CFMachPortInvalidate(resources.port)
    }

    // MARK: Key capture — for a panel that cannot become key

    /// Start swallowing and reporting the keystrokes `shouldCapture` claims.
    ///
    /// ## Why this needs a second, *consuming* tap, when RECON §13 says never suppress
    ///
    /// §13's rule is about the hotkey: Right Option is AltGr on many layouts, and eating it would
    /// break dead keys and accented characters system-wide. The popup's digits are a different
    /// problem with a different answer. The panel is deliberately non-activating, so `1` goes to the
    /// app the user is looking at — **and that app has text selected**. Typing `1` there replaces the
    /// selection with `1`, and the refined text then lands beside a stray digit in a document whose
    /// original words are gone. Listening is not enough; the keystroke has to be stopped.
    ///
    /// Measured on this machine before building on it: a `.defaultTap` at `.cgSessionEventTap`
    /// returning `nil` for keycode 18 was created, enabled with the full requested mask, and a
    /// downstream listen-only tap at `.cgAnnotatedSessionEventTap` then saw `down kc=19, up kc=19`
    /// and **nothing** for keycode 18. Suppression works and is selective.
    ///
    /// The blast radius is bounded three ways: the tap exists only while a panel is up (at most the
    /// popup's 8 s choice deadline), it asks `shouldCapture` before touching anything, and everything
    /// else is returned unmodified.
    ///
    /// Note the nil-check *is* a complete permission gate here, unlike RECON §11's listen-only case:
    /// the requested mask is keyDown|keyUp only, so a window server that strips keyboard events is
    /// left with an empty mask, and `CGEvent.h` returns NULL for an empty mask.
    ///
    /// - Returns: whether keystrokes are now being swallowed. `false` means the caller must not offer
    ///   a keyboard choice — its digits would reach the user's document.
    @discardableResult
    public func beginKeyCapture(
        shouldCapture: @escaping @Sendable (Int64, UInt64) -> Bool
    ) async -> Bool {
        enum Decision { case already, request(CFRunLoop), unavailable }
        let decision: Decision = state.withLock { s in
            s.shouldCapture = shouldCapture
            s.suppressing = true
            s.suppressedKeys.removeAll()
            if s.capture != nil { return .already }
            guard s.thread != nil, let runLoop = s.runLoop else { return .unavailable }
            s.captureRequest = .install
            s.captureOutcome = nil
            return .request(runLoop)
        }

        switch decision {
        case .already:
            return true
        case .unavailable:
            Log.hotkey.error("key capture requested with no live tap thread")
            return false
        case .request(let runLoop):
            wake(runLoop)
            // Polled rather than awaiting a continuation the tap thread resumes: a continuation that
            // is never resumed — because the thread was cancelled in the same instant — is a hang,
            // and a hang here is a frozen menu bar. 2 ms steps, 100 ms ceiling; the install measures
            // well under a millisecond.
            for _ in 0..<50 {
                if let outcome = state.withLock({ $0.captureOutcome }) { return outcome }
                try? await Task.sleep(for: .milliseconds(2))
            }
            Log.hotkey.error("key capture install did not complete within 100 ms")
            return false
        }
    }

    /// Keep reporting captured keys but stop swallowing them.
    ///
    /// Called when the popup leaves the state that can act on a digit. `RefinePopupSession.handle`
    /// already refuses a digit in the working state so it "reaches the app underneath instead of
    /// vanishing" — this is that promise kept at the tap, where it is actually decided.
    public func setKeyCaptureSuppressing(_ suppressing: Bool) {
        state.withLock { $0.suppressing = suppressing }
    }

    /// Remove the capture tap. Idempotent, and safe to call when none was ever installed.
    public func endKeyCapture() {
        let runLoop: CFRunLoop? = state.withLock { s in
            s.shouldCapture = nil
            s.suppressing = false
            s.suppressedKeys.removeAll()
            guard s.capture != nil else {
                s.captureRequest = .none
                return nil
            }
            s.captureRequest = .remove
            return s.runLoop
        }
        guard let runLoop else { return }
        wake(runLoop)
    }

    /// Ask the tap thread to service a pending request now rather than on its next 0.25 s slice.
    private func wake(_ runLoop: CFRunLoop) {
        // A strong capture, and safe: the block is one-shot and the run loop drops it after running,
        // so there is no cycle — and `deinit` deliberately never reaches this (see `deinit`). A
        // `[weak self]` here would be the bug instead of the fix, because the object it would have to
        // reference weakly is the one being deallocated.
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            serviceCaptureRequest()
        }
        CFRunLoopWakeUp(runLoop)
    }

    /// Tap thread only. The one place the capture port is created or invalidated.
    private func serviceCaptureRequest() {
        let request: CaptureRequest = state.withLock { s in
            guard s.thread === Thread.current else { return .none }
            let request = s.captureRequest
            s.captureRequest = .none
            return request
        }
        switch request {
        case .none: break
        case .install: installCaptureTap()
        case .remove: removeCaptureTap()
        }
    }

    /// Keyboard only, and only the two types the panel needs. Mixing in anything else would let the
    /// window server keep the mask non-empty while stripping the keys (RECON §11).
    private static let captureMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

    private func installCaptureTap() {
        guard let runLoop = state.withLock({ s in s.capture == nil ? s.runLoop : nil }) else {
            state.withLock { $0.captureOutcome = true }
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.captureMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<HotkeyMonitor>.fromOpaque(refcon)
                    .takeUnretainedValue()
                    .handleCapture(type: type, event: event)
            },
            userInfo: context
        ) else {
            // A `.defaultTap` returns nil rather than a dead port, so this is the whole gate.
            Log.hotkey.error("could not create the key-capture tap; Accessibility is not granted")
            state.withLock { $0.captureOutcome = false }
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        guard CGEvent.tapIsEnabled(tap: port) else {
            Log.hotkey.error("key-capture tap created but disabled")
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFMachPortInvalidate(port)
            state.withLock { $0.captureOutcome = false }
            return
        }
        state.withLock { s in
            s.capture = CaptureResources(runLoop: runLoop, port: port, source: source)
            s.captureOutcome = true
        }
        Log.hotkey.info("key capture installed")
    }

    /// Same teardown order as the hotkey tap, for the same measured reason (RECON §12): dropping the
    /// Swift reference leaks one Mach port per tap because the run loop source holds the port.
    private func removeCaptureTap() {
        let capture: CaptureResources? = state.withLock { s in
            let capture = s.capture
            s.capture = nil
            s.suppressing = false
            s.suppressedKeys.removeAll()
            s.shouldCapture = nil
            return capture
        }
        guard let capture else { return }
        if let source = capture.source {
            CFRunLoopRemoveSource(capture.runLoop, source, .commonModes)
        }
        CGEvent.tapEnable(tap: capture.port, enable: false)
        CFMachPortInvalidate(capture.port)
        Log.hotkey.info("key capture removed")
    }

    /// The capture tap's callback. Returning `nil` swallows the event.
    private func handleCapture(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-enable, exactly as for the hotkey tap — but *also* tell the panel to go away by
            // reporting Escape. While this tap was down the user's digits were reaching their
            // document, and a popup that can no longer protect the selection has no business
            // offering to replace it.
            let port: CFMachPort? = state.withLock { $0.capture?.port }
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            Log.hotkey.error("key-capture tap disabled; re-enabled and dismissing the panel")
            capturedKeyContinuation.yield(HotkeyCapturedKey(keyCode: 53, rawFlags: 0))   // kVK_Escape
            return nil

        case .keyDown, .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let rawFlags = event.flags.rawValue

            if type == .keyUp {
                // A key whose down was swallowed must have its up swallowed too, even if suppression
                // was switched off in between: an unmatched key-up leaves a text field believing a
                // key is still held.
                let swallow: Bool = state.withLock { s in s.suppressedKeys.remove(keyCode) != nil }
                return swallow ? nil : Unmanaged.passUnretained(event)
            }

            let claim: (capture: Bool, suppress: Bool) = state.withLock { s in
                guard let shouldCapture = s.shouldCapture, shouldCapture(keyCode, rawFlags) else {
                    return (false, false)
                }
                if s.suppressing { s.suppressedKeys.insert(keyCode) }
                return (true, s.suppressing)
            }
            guard claim.capture else { return Unmanaged.passUnretained(event) }
            // Autorepeat is swallowed but not re-reported: the panel acted on the first press, and a
            // held key would otherwise deliver the same choice thirty times a second.
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                capturedKeyContinuation.yield(HotkeyCapturedKey(keyCode: keyCode, rawFlags: rawFlags))
            }
            return claim.suppress ? nil : Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Belt and braces: the OS can kill a tap without ever delivering `.tapDisabledBy*`, so poll.
    private func runWatchdog() {
        let port: CFMachPort? = state.withLock { s in
            guard s.thread === Thread.current, !s.reportedPermissionLost else { return nil }
            return s.resources?.port
        }
        guard let port, !CGEvent.tapIsEnabled(tap: port) else { return }

        CGEvent.tapEnable(tap: port, enable: true)
        if CGEvent.tapIsEnabled(tap: port) {
            Log.hotkey.notice("watchdog re-enabled a silently disabled tap")
            diagnosticContinuation.yield(.tapReEnabled("watchdog"))
        } else {
            state.withLock { $0.reportedPermissionLost = true }
            Log.hotkey.error("tap is dead and cannot be re-enabled; it must be destroyed and re-created")
            diagnosticContinuation.yield(.permissionLost)
        }
        // Either way we may have missed the key release.
        if state.withLock({ $0.holdStart != nil }) { abortHold(reason: .tapDisabled) }
    }

    // MARK: Event handling — tap thread only

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // These arrive as CGEventTypes 0xFFFFFFFE / 0xFFFFFFFF whether or not we asked for them, and
            // falling through to `return event` here is how a hotkey goes permanently deaf (RECON §12).
            let reason = type == .tapDisabledByTimeout ? "timeout" : "userInput"
            let port: CFMachPort? = state.withLock { s in
                s.reEnableCount += 1
                // While the tap was down we may have missed the qualifier's *release*, which is the
                // one way the tracker can latch. Clearing it costs a gesture the user would have to
                // repeat; leaving it costs a recording that silently became a popup.
                s.qualifierHeld = false
                return s.resources?.port
            }
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            Log.hotkey.error("tap disabled by \(reason, privacy: .public); re-enabled")
            diagnosticContinuation.yield(.tapReEnabled(reason))
            // Critical: while the tap was down we may have missed the release, and a naive
            // implementation would record forever.
            if state.withLock({ $0.holdStart != nil }) { abortHold(reason: .tapDisabled) }
            return nil

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let rawFlags = event.flags.rawValue
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // A `.keyDown` carries the full modifier state too, and for a non-modifier hotkey (F13)
            // this event *is* the start of the hold — so without recording it here the arm sampler
            // would be looking at whatever modifier last toggled instead.
            let down: (binding: HotkeyBinding?, refine: RefineChordBinding?) = state.withLock { s in
                s.lastObservedFlags = rawFlags
                // Clearing only, never setting. A `.keyDown` reporting the qualifier bit CLEAR is
                // proof it is not held, because RECON §9's incidental `maskSecondaryFn` can only
                // ever add the bit (every arrow and fn-row keyDown carries it) — it can never
                // remove one. So this direction is a free corrector and the other would be a lie.
                if let mask = s.refine?.qualifierMask, rawFlags & mask == 0 { s.qualifierHeld = false }
                return (s.binding, s.refine)
            }
            // The discrete chord is recognised before the cancellation rule below, which would
            // otherwise see nothing but "a real key arrived during a hold".
            if let refine = down.refine, !isRepeat,
               refine.matchesDiscrete(keyCode: keyCode, rawFlags: rawFlags) {
                Log.hotkey.info("refine chord \(refine.displayName, privacy: .public) fired")
                gestureContinuation.yield(.refinePopup)
            }
            if let binding = down.binding, !binding.isModifier, keyCode == binding.keyCode {
                if !isRepeat { beginHold() }
            } else {
                // A real key during the hold means the user is typing a shortcut, not dictating.
                cancelHoldIfAny(.chordedWithKey(keyCode))
            }

        case .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let rawFlags = event.flags.rawValue
            let binding = state.withLock { s -> HotkeyBinding? in
                if let mask = s.refine?.qualifierMask, rawFlags & mask == 0 { s.qualifierHeld = false }
                return s.binding
            }
            if let binding, !binding.isModifier, keyCode == binding.keyCode { endHold() }

        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let rawFlags = event.flags.rawValue
            // Recorded for every modifier, including the ones that go on to cancel the hold: the arm
            // sampler needs the state of a modifier that is not the hotkey.
            let toggle: (binding: HotkeyBinding?, refine: RefineChordBinding?, qualifierWasHeld: Bool) =
                state.withLock { s in
                    let wasHeld = s.qualifierHeld
                    s.lastObservedFlags = rawFlags
                    // Rewritten from this event rather than accumulated: every `.flagsChanged`
                    // carries the complete modifier state, so a release we somehow never saw is
                    // corrected by the next modifier event of any kind instead of latching "held".
                    // Only `.flagsChanged` may SET it — see the `.keyDown` branch for why.
                    if let mask = s.refine?.qualifierMask { s.qualifierHeld = rawFlags & mask != 0 }
                    return (s.binding, s.refine, wasHeld)
                }
            guard let binding = toggle.binding else { break }
            guard binding.isModifier, keyCode == binding.keyCode else {
                // The designated language modifier is the ONE exemption from chord cancellation, and
                // it is deliberately narrow. Every other modifier still cancels (that is what stops a
                // ⌘-shortcut from arming a recording), and any ordinary *key* down still cancels
                // regardless of which modifier is held — see the `.keyDown` branch, which is
                // untouched. Widening this to "ignore all modifiers" would make ⌘⇧4 start dictating.
                if binding.alternateKeyCodes.contains(keyCode) { break }
                // The refine qualifier is the second exemption, and it *is* the other half of the
                // ordering rule: "if a hold has already armed, do not retroactively cancel the
                // recording — finish it". Without this, reaching for 🌐 a moment too late would
                // abort a dictation the user is already speaking into.
                if let refine = toggle.refine, refine.qualifierKeyCodes.contains(keyCode) { break }
                // A *different* modifier toggled — Shift for a capital letter, Cmd for a shortcut.
                cancelHoldIfAny(.chordedWithModifier(keyCode))
                break
            }
            // RECON §9: raw `UInt64` flags, never `.deviceIndependentFlagsMask`.
            guard binding.isHeld(rawFlags: rawFlags) else {
                // A release. `endHold` is a no-op when no hold was ever begun, which is exactly what
                // makes the suppression below safe: the popup gesture leaves nothing to release.
                endHold()
                break
            }
            // THE ORDERING RULE. Two independent sources, OR-ed, both from the tap: the qualifier bit
            // carried on this very event (measured present — `kc=61 raw=0x20880040` with 🌐 held), and
            // the state left by the previous `.flagsChanged`. Either is enough. `flagsState` is
            // deliberately not a third source; see `TapState.qualifierHeld`.
            if let refine = toggle.refine, let mask = refine.qualifierMask,
               rawFlags & mask != 0 || toggle.qualifierWasHeld {
                Log.hotkey.info("""
                    refine chord \(refine.displayName, privacy: .public) fired \
                    (flags=0x\(String(rawFlags, radix: 16), privacy: .public), \
                    tracked=\(toggle.qualifierWasHeld, privacy: .public)); dictation not armed
                    """)
                gestureContinuation.yield(.refinePopup)
                break
            }
            beginHold()

        default:
            break
        }
        // `.listenOnly` means the return value is advisory, but passing the event through keeps the
        // intent unambiguous: Edict never consumes the user's keystrokes.
        return Unmanaged.passUnretained(event)
    }

    private func beginHold() {
        let timer: CFRunLoopTimer? = state.withLock { s in
            guard s.holdStart == nil else { return nil }   // ignore duplicate down reports
            s.holdStart = CFAbsoluteTimeGetCurrent()
            s.armed = false
            s.chorded = false
            return s.resources?.timer
        }
        guard let timer else { return }
        CFRunLoopTimerSetNextFireDate(timer, CFAbsoluteTimeGetCurrent() + armDelay)
        diagnosticContinuation.yield(.holdBegan)
    }

    /// Fires `armDelay` after key-down. Only here does a hold become a recording.
    ///
    /// ## The language modifier is sampled HERE, and this is the contract
    ///
    /// Not at key-down. The whole `armDelay` window (~120 ms) is a grace period in which the user may
    /// press the hotkey and the modifier **in either order** and still get the secondary language —
    /// which matters because there is no natural order for a two-handed chord, and requiring one would
    /// mean silently dictating Indonesian speech with an English model whenever the thumbs landed the
    /// wrong way round. Pressing the modifier *after* arming does not retroactively change the
    /// language: the locale is fixed for the whole utterance by the framework
    /// (`DictationTranscriber` takes one `Locale`), so there is nothing to change it to.
    private func armTimerFired() {
        let sample: (binding: HotkeyBinding, observed: UInt64)? = state.withLock { s in
            guard s.holdStart != nil, !s.armed, !s.chorded, let binding = s.binding else { return nil }
            s.armed = true
            return (binding, s.lastObservedFlags)
        }
        guard let sample else { return }

        // `.combinedSessionState`, NEVER `.privateState`: RECON's injection section measured
        // `CGEventSource.flagsState(.privateState)` blocking FOREVER — the probe process had to be
        // SIGTERMed at both 12 s and 120 s. Blocking here would wedge the tap thread's run loop and
        // kill the hotkey outright.
        let polled = CGEventSource.flagsState(.combinedSessionState).rawValue
        // Two independent sources, OR-ed. Either one saying the modifier is held is enough: the tap's
        // own last `.flagsChanged` cannot be inert, and the poll covers a modifier that was already
        // down before the tap started. They agree in the normal case.
        let alternate = sample.binding.isAlternateHeld(rawFlags: polled)
            || sample.binding.isAlternateHeld(rawFlags: sample.observed)

        Log.hotkey.debug("""
            hotkey armed polled=0x\(String(polled, radix: 16), privacy: .public) \
            observed=0x\(String(sample.observed, radix: 16), privacy: .public) \
            alternate=\(alternate, privacy: .public)
            """)
        eventContinuation.yield(.pressed(alternate: alternate))
    }

    private func endHold() {
        enum Ending { case none, released(TimeInterval), tooShort(TimeInterval) }
        let ending: Ending = state.withLock { s in
            guard let start = s.holdStart else { return .none }
            let held = CFAbsoluteTimeGetCurrent() - start
            let wasArmed = s.armed
            s.holdStart = nil
            s.armed = false
            s.chorded = false
            if let timer = s.resources?.timer {
                CFRunLoopTimerSetNextFireDate(timer, Date.distantFuture.timeIntervalSinceReferenceDate)
            }
            return wasArmed ? .released(held) : .tooShort(held)
        }
        switch ending {
        case .none:
            break
        case .released(let held):
            Log.hotkey.debug("hotkey released after \(Int(held * 1000)) ms")
            eventContinuation.yield(.released)
        case .tooShort(let held):
            // Never armed, so no `.pressed` was emitted and nothing needs stopping.
            diagnosticContinuation.yield(.cancelled(.tooShort(held)))
        }
    }

    private func cancelHoldIfAny(_ reason: HotkeyCancelReason) {
        let shouldAbort: Bool = state.withLock { s in
            guard s.holdStart != nil, !s.chorded else { return false }
            return true
        }
        guard shouldAbort else { return }
        abortHold(reason: reason)
    }

    /// Ends the current hold without waiting for a key release. Emits `.released` if and only if a
    /// `.pressed` was already emitted, so the pressed/released pairing invariant always holds.
    private func abortHold(reason: HotkeyCancelReason) {
        let wasArmed: Bool = state.withLock { s in
            let armed = s.armed
            s.holdStart = nil
            s.armed = false
            s.chorded = true
            if let timer = s.resources?.timer {
                CFRunLoopTimerSetNextFireDate(timer, Date.distantFuture.timeIntervalSinceReferenceDate)
            }
            return armed
        }
        diagnosticContinuation.yield(.cancelled(reason))
        if wasArmed {
            Log.hotkey.notice("hold aborted after arming (\(String(describing: reason), privacy: .public))")
            eventContinuation.yield(.released)
        }
    }

    // MARK: Diagnostics

    /// The mask the window server actually granted this process. Needs no permission of its own.
    static func grantedMask(forPID pid: pid_t) -> CGEventMask {
        var count: UInt32 = 0
        _ = CGGetEventTapList(0, nil, &count)
        guard count > 0 else { return 0 }
        var buffer = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        var written: UInt32 = 0
        guard CGGetEventTapList(count, &buffer, &written) == .success else { return 0 }
        var mask: CGEventMask = 0
        for index in 0..<Int(written) where buffer[index].tappingProcess == pid {
            mask |= buffer[index].eventsOfInterest
        }
        return mask
    }

    /// Human-readable dump of every event tap installed on this system, for a debug menu item.
    ///
    /// RECON used exactly this to discover, in under a second, that this machine has 751 installed taps —
    /// 729 of them Karabiner's — plus a BetterTouchTool `.defaultTap` and Siri's `flagsChanged` tap
    /// sitting ahead of ours. When a user reports "the hotkey does nothing", this is the first thing to read.
    public static func installedTapsDiagnostic() -> String {
        var count: UInt32 = 0
        _ = CGGetEventTapList(0, nil, &count)
        guard count > 0 else { return "no event taps installed" }
        var buffer = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        var written: UInt32 = 0
        guard CGGetEventTapList(count, &buffer, &written) == .success else {
            return "CGGetEventTapList failed"
        }
        let mine = getpid()
        var byProcess: [pid_t: (taps: Int, mask: CGEventMask)] = [:]
        for index in 0..<Int(written) {
            let info = buffer[index]
            var entry = byProcess[info.tappingProcess] ?? (0, 0)
            entry.taps += 1
            entry.mask |= info.eventsOfInterest
            byProcess[info.tappingProcess] = entry
        }
        var lines = ["\(written) event tap(s) across \(byProcess.count) process(es)"]
        for (pid, entry) in byProcess.sorted(by: { $0.value.taps > $1.value.taps }) {
            let name = ProcessInfo.processInfo.processName
            let label = pid == mine ? "\(name) (us)" : "pid \(pid)"
            lines.append("  \(label): \(entry.taps) tap(s), mask 0x\(String(entry.mask, radix: 16))")
        }
        return lines.joined(separator: "\n")
    }

    /// Mach port names owned by this task. A `CFMachPort` that was never invalidated shows up here 1:1,
    /// forever — RECON measured exactly that. Used only in DEBUG start/stop assertions.
    static func machPortCount() -> Int {
        var names: mach_port_name_array_t?
        var nameCount: mach_msg_type_number_t = 0
        var types: mach_port_type_array_t?
        var typeCount: mach_msg_type_number_t = 0
        guard mach_port_names(mach_task_self_, &names, &nameCount, &types, &typeCount) == KERN_SUCCESS
        else { return -1 }
        if let names {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: names)),
                          vm_size_t(Int(nameCount) * MemoryLayout<mach_port_name_t>.stride))
        }
        if let types {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: types)),
                          vm_size_t(Int(typeCount) * MemoryLayout<mach_port_type_t>.stride))
        }
        return Int(nameCount)
    }
}
