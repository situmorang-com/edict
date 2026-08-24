import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

// MARK: - Public surface

public enum HotkeyEvent: Sendable, Hashable {
    /// The key has been held long enough to be a deliberate dictation gesture. Start recording.
    case pressed
    /// The hold ended. Always follows a `.pressed`, exactly once — including when the hold was aborted,
    /// so a consumer can never be left recording forever.
    case released
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

    init(_ choice: HotkeyChoice) {
        displayName = choice.displayName
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

    private final class TapState: @unchecked Sendable {
        private let lock = NSLock()

        var binding: HotkeyBinding?
        var thread: Thread?
        /// The run loop of the *current* thread, kept separately so `stop()` can wake it even before the
        /// tap is installed or after installation failed.
        var runLoop: CFRunLoop?
        var resources: TapResources?

        /// Non-nil while the key is physically down.
        var holdStart: CFAbsoluteTime?
        /// True once `.pressed` has been emitted for the current hold.
        var armed = false
        /// True once this hold has been disqualified; suppresses repeat cancellations.
        var chorded = false
        /// Set after a failed re-enable so the watchdog reports `.permissionLost` exactly once.
        var reportedPermissionLost = false
        var reEnableCount = 0

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
    }

    /// Best-effort only. The tap thread's block captures `self` **strongly** on purpose: the tap holds
    /// an `Unmanaged.passUnretained` pointer back to this object, so a weak capture would open a window
    /// where the callback dereferences freed memory. The consequence is that a running monitor keeps
    /// itself alive, so `stop()` is not optional — a caller that simply drops the last reference leaks
    /// the thread and one Mach port. `AppModel`/`DictationController` must call `stop()` on teardown.
    deinit {
        stop()
        eventContinuation.finish()
        diagnosticContinuation.finish()
    }

    // MARK: Public API

    public var events: AsyncStream<HotkeyEvent> { eventStream }

    public var diagnostics: AsyncStream<HotkeyDiagnostic> { diagnosticStream }

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
    public func start(key: HotkeyChoice) throws {
        let binding = HotkeyBinding(key)

        // Gate BEFORE creating. This is the whole point of RECON §11: `.listenOnly` `tapCreate` hands
        // back a non-nil CFMachPort even when access is denied, and five `tapEnable` retries over a
        // second never flipped `tapIsEnabled`.
        guard PermissionProbe.inputMonitoringGranted else {
            Log.hotkey.error("start refused: Input Monitoring not granted")
            throw HotkeyError.permissionDenied
        }

        let alreadyRunning: Bool = state.withLock { s in
            s.binding = binding
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
            }
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

        Log.hotkey.notice("hotkey monitor live on \(binding.displayName, privacy: .public) (keyCode \(binding.keyCode))")
    }

    /// Rebinding while running needs no new tap: the mask is identical for every choice, and the
    /// callback reads the binding fresh on every event.
    public func update(key: HotkeyChoice) {
        let binding = HotkeyBinding(key)
        let wasHolding: Bool = state.withLock { s in
            let changed = s.binding?.keyCode != binding.keyCode
            s.binding = binding
            return changed && s.holdStart != nil
        }
        if wasHolding { abortHold(reason: .keyChanged) }
        Log.hotkey.info("hotkey rebound to \(binding.displayName, privacy: .public)")
    }

    public func stop() {
        // Aborting first guarantees a `.released` reaches the consumer before the tap goes away.
        if state.withLock({ $0.holdStart != nil }) { abortHold(reason: .tapDisabled) }

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
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            let binding = state.withLock { $0.binding }
            if let binding, !binding.isModifier, keyCode == binding.keyCode {
                if !isRepeat { beginHold() }
            } else {
                // A real key during the hold means the user is typing a shortcut, not dictating.
                cancelHoldIfAny(.chordedWithKey(keyCode))
            }

        case .keyUp:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let binding = state.withLock { $0.binding }
            if let binding, !binding.isModifier, keyCode == binding.keyCode { endHold() }

        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard let binding = state.withLock({ $0.binding }) else { break }
            guard binding.isModifier, keyCode == binding.keyCode else {
                // A *different* modifier toggled — Shift for a capital letter, Cmd for a shortcut.
                cancelHoldIfAny(.chordedWithModifier(keyCode))
                break
            }
            // RECON §9: raw `UInt64` flags, never `.deviceIndependentFlagsMask`.
            binding.isHeld(rawFlags: event.flags.rawValue) ? beginHold() : endHold()

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
    private func armTimerFired() {
        let shouldArm: Bool = state.withLock { s in
            guard s.holdStart != nil, !s.armed, !s.chorded else { return false }
            s.armed = true
            return true
        }
        guard shouldArm else { return }
        Log.hotkey.debug("hotkey armed")
        eventContinuation.yield(.pressed)
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
