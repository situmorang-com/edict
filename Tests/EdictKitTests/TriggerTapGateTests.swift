import CoreGraphics
import Foundation
import Testing
@testable import EdictKit

/// The gate on the one tap Edict holds that *suppresses* the user's keystrokes.
///
/// RECON amendment 13 is "`.listenOnly`, never suppress"; amendment 42 as widened by 50 grants the
/// refine trigger exactly one exception, for one shape (`fn + /`), on the argument that swallowing a
/// redundant way to type `/` costs the user nothing. That argument buys a tap for the shipped default.
/// It buys nothing at all when the feature is off, and it was still paying: the install read
/// `if owned != nil`, with no reference to the setting, so a `.defaultTap` sat in the synchronous
/// delivery path of every keyDown on the machine for the process lifetime whatever the user had
/// chosen — and `update()`, which is where every settings change lands, could not change it.
///
/// Narrower holes in that gate are pinned further down, because closing the first one left them. All
/// of them come out of the same released lock: the install holds none for the whole of
/// `CGEvent.tapCreate`, and `s.trigger` is one shared field where the tap threads are two. So a setting
/// that moved inside that window reconciled against a world where the tap did not exist yet; a
/// `stop()`-then-`start()` with no join had a departing thread tearing down the live generation's port;
/// and two installs racing to publish into that field stored over each other, leaving a `.defaultTap`
/// nobody is allowed to invalidate. They end where the finding started: a consuming tap nobody asked
/// for, none where one was needed, or one that outlives every thread that could remove it.
///
/// What is provable here and what is not. A test process may not create the real port twice over: it
/// needs Accessibility, and a consuming `keyDown` tap would be suppressing the *user's* own typing to
/// prove a point about a setting. So the window-server side is asserted by
/// `HotkeyChordLive.refineOffHoldsOnlyTheListenOnlyTap` and its neighbours, gated behind
/// `EDICT_TAP_TESTS=1`. What this file pins is the decision those tests would be checking the effect
/// of — read through `HotkeyMonitor.triggerHarness`, which drives the production `update` and the
/// production gate rather than copies of them.
@Suite("TriggerTapGate")
struct TriggerTapGateTests {

    // MARK: Which settings want the tap

    @Test("the feature switched off wants no consuming tap, for every dictation key",
          arguments: HotkeyChoice.allCases)
    func featureOffWantsNoTap(key: HotkeyChoice) {
        let monitor = HotkeyMonitor()
        let harness = monitor.triggerHarness
        harness.bind(nil, dictationKey: key)
        #expect(!harness.wantsConsumingTap)
    }

    /// The naive gate is `refine != nil`, and it would hold a consuming tap for all four of these.
    /// Three of them are chords whose entire selling point is that they insert nothing (RECON
    /// amendment 47 for `⌘⌥/`), so suppression buys them nothing and costs the same as always.
    @Test("only a chord with a shape that must be swallowed wants the tap",
          arguments: RefineChord.allCases)
    func onlyTheSwallowedShapeWantsTheTap(chord: RefineChord) {
        let monitor = HotkeyMonitor()
        let harness = monitor.triggerHarness
        harness.bind(chord, dictationKey: .rightOption)
        #expect(harness.wantsConsumingTap == (chord == .fnSlash),
                "\(chord.rawValue) asked for the consuming tap")
    }

    /// The shipped default is the one case that pays for the tap, and it must go on paying — this is
    /// the regression that would turn the flagship gesture silent rather than merely quiet.
    @Test("the shipped default wants the tap")
    func shippedDefaultWantsTheTap() {
        let monitor = HotkeyMonitor()
        let harness = monitor.triggerHarness
        harness.bind(RefineChord.default, dictationKey: .rightOption)
        #expect(harness.wantsConsumingTap)
    }

    /// Amendment 50's known edge, from the other end. With Globe as the dictation key the `fn` shape
    /// is dropped rather than neutered (`fn` is holding a recording open), leaving `fnSlash` with only
    /// its `⌃⌘/` alias — which inserts nothing. The row still reads as live, and the tap must go.
    @Test("Globe as the dictation key leaves only the ⌃⌘/ alias, which needs no tap")
    func globeDropsTheFnShapeAndWithItTheTap() throws {
        let monitor = HotkeyMonitor()
        let harness = monitor.triggerHarness
        harness.bind(.fnSlash, dictationKey: .fn)
        // The chord itself survives — this is not the refusal case.
        #expect(RefineChordBinding(.fnSlash, dictationKey: .fn) != nil)
        #expect(!harness.wantsConsumingTap)
    }

    // MARK: The reconciliation table

    @Test("wanted but absent installs; unwanted but present removes; agreement does nothing",
          arguments: [
              (wanted: true, installed: false, request: HotkeyMonitor.TriggerRequest.install),
              (wanted: false, installed: true, request: HotkeyMonitor.TriggerRequest.remove),
              (wanted: true, installed: true, request: HotkeyMonitor.TriggerRequest.none),
              (wanted: false, installed: false, request: HotkeyMonitor.TriggerRequest.none),
          ])
    func reconciliationTable(row: (wanted: Bool, installed: Bool, request: HotkeyMonitor.TriggerRequest)) {
        #expect(HotkeyMonitor.triggerRequest(wanted: row.wanted, installed: row.installed) == row.request)
    }

    // MARK: The runtime toggle, through the production `update`

    /// The half of the finding that is more than hygiene. `DictationController.settingsChanged` routes
    /// a live monitor's settings change to `update(key:alternate:refine:)`, never to a restart, so a
    /// toggle this method does not act on cannot take effect until the next launch.
    @Test("switching the feature off asks the tap thread to remove the tap")
    func switchingOffRemovesTheTap() throws {
        let monitor = HotkeyMonitor()
        let harness = monitor.triggerHarness
        harness.pretendThreadIsLive()
        defer { harness.forgetPretendTap(); harness.forgetPretendThread() }
        try #require(harness.pretendTapIsInstalled())

        monitor.update(key: .rightOption, alternate: .shift, refine: nil)

        #expect(!harness.wantsConsumingTap)
        #expect(harness.pendingRequest == .remove)
    }

    @Test("switching the feature on asks the tap thread to install the tap")
    func switchingOnInstallsTheTap() {
        let monitor = HotkeyMonitor()
        let harness = monitor.triggerHarness
        harness.pretendThreadIsLive()
        defer { harness.forgetPretendThread() }

        monitor.update(key: .rightOption, alternate: .shift, refine: .fnSlash)

        #expect(harness.wantsConsumingTap)
        #expect(harness.pendingRequest == .install)
    }

    /// Moving between two chords that both insert nothing must not touch the tap at all — and neither
    /// must a plain rebind of the dictation key, which is what `update` is called for most often.
    @Test("a rebind that changes nothing about swallowing queues nothing")
    func rebindWithoutSwallowingQueuesNothing() {
        let monitor = HotkeyMonitor()
        let harness = monitor.triggerHarness
        harness.pretendThreadIsLive()
        defer { harness.forgetPretendThread() }

        monitor.update(key: .rightOption, alternate: .shift, refine: .commandOptionSlash)
        #expect(harness.pendingRequest == .none)
        monitor.update(key: .rightControl, alternate: .shift, refine: .optionCommandR)
        #expect(harness.pendingRequest == .none)
    }

    /// The request is derived from the world on every pass rather than accumulated, so a setting that
    /// moves twice inside one 0.25 s run-loop slice cancels its own pending work instead of leaving an
    /// install queued that the settings no longer ask for.
    @Test("switching off and straight back on inside one slice cancels the pending request")
    func aRequestThatIsNoLongerWantedIsCancelled() throws {
        let monitor = HotkeyMonitor()
        let harness = monitor.triggerHarness
        harness.pretendThreadIsLive()
        defer { harness.forgetPretendTap(); harness.forgetPretendThread() }
        try #require(harness.pretendTapIsInstalled())

        monitor.update(key: .rightOption, alternate: .shift, refine: nil)
        #expect(harness.pendingRequest == .remove)
        // Nothing serviced the remove, so the tap is still there and is wanted again.
        monitor.update(key: .rightOption, alternate: .shift, refine: .fnSlash)
        #expect(harness.pendingRequest == .none)
    }

    /// A stopped monitor has no thread to service anything, and a request left pending on one would be
    /// serviced by the *next* generation — whose install gate has already read the setting directly. A
    /// stale `.remove` there would take out the tap that gate had just put in.
    @Test("update on a stopped monitor queues nothing")
    func updateOnAStoppedMonitorQueuesNothing() {
        let monitor = HotkeyMonitor()
        let harness = monitor.triggerHarness
        monitor.update(key: .rightOption, alternate: .shift, refine: .fnSlash)
        #expect(harness.wantsConsumingTap)
        #expect(harness.pendingRequest == .none)
    }

    // MARK: The window between the gate and the port

    /// `update()`'s reconciliation cannot see an install that is still in flight, because it derives
    /// "installed" from `s.trigger != nil` and the whole of `CGEvent.tapCreate` —
    /// plus `CFRunLoopAddSource`, `tapEnable` and `tapIsEnabled` — runs with that field still nil and
    /// the lock released. So the sequence below leaves the request table saying `.none`: wanted=false,
    /// installed=false, nothing to do. The install then completes and stores a consuming `.defaultTap`
    /// the settings no longer ask for, and nothing removes it until the next settings change or quit,
    /// which is finding #29's condition in a smaller window.
    ///
    /// The close is a re-read of the gate under the **same lock** that stores the port. Only that lock
    /// can order the two: whoever holds it last decides.
    @Test("an install that lands after the setting moved queues its own removal")
    func aStaleInstallQueuesItsOwnRemoval() throws {
        let monitor = HotkeyMonitor()
        let harness = monitor.triggerHarness
        harness.pretendThreadIsLive()
        defer { harness.forgetPretendTap(); harness.forgetPretendThread() }

        // The user switched the feature off while the tap thread was inside `tapCreate`. This is what
        // `update()` did with that, and it is right: there was no port to remove yet.
        harness.bind(nil, dictationKey: .rightOption)
        #expect(harness.pendingRequest == .none)

        #expect(try #require(harness.publishPretendTap()) == .publishedButStale)

        // The port stays published: it exists, and the tap thread is the only thread that may
        // invalidate it (RECON §12). What must change is that something is now going to.
        #expect(harness.tapIsInstalled)
        #expect(harness.pendingRequest == .remove,
                "a consuming tap the settings no longer ask for was left with nothing to remove it")
    }

    /// The other side of the same re-read: an install that lands while the setting still wants it must
    /// queue nothing at all, or every start-up would ask the slice loop to undo its own work.
    @Test("an install that lands while the setting still wants it queues nothing")
    func aWantedInstallQueuesNothing() throws {
        let monitor = HotkeyMonitor()
        let harness = monitor.triggerHarness
        harness.pretendThreadIsLive()
        defer { harness.forgetPretendTap(); harness.forgetPretendThread() }
        harness.bind(.fnSlash, dictationKey: .rightOption)

        #expect(try #require(harness.publishPretendTap()) == .published)

        #expect(harness.tapIsInstalled)
        #expect(harness.pendingRequest == .none)
    }

    /// The third way the released lock bites, and the one that leaks rather than over-suppresses.
    ///
    /// `s.trigger` is one field where the tap threads are two, and both can be inside
    /// `CGEvent.tapCreate` with it empty. The route is a *runtime* install: the live thread is inside
    /// `installTriggerTap` for a settings change when `restartHotkey()` arrives, `stop()` cancels it
    /// without joining, `tapCreate` does not look at cancellation — so it publishes anyway, and it can
    /// land after the arriving generation's own start-up install has read the field as empty. (A
    /// start-up install cannot interleave this way: `start()` blocks on `ready` until the thread has
    /// installed both its taps.)
    ///
    /// Storing over whichever port got there first drops the only reference to it. RECON §12 measured
    /// teardown as thread-bound and one leaked Mach port per un-invalidated tap, 1:1, and the losing
    /// port's owner then skips it on the exit path's ownership check, because the field no longer names
    /// its run loop — so the window server goes on reporting a `.defaultTap` in `CGGetEventTapList`
    /// that nothing will ever service or remove.
    ///
    /// The fix is that the second publish loses instead, which it can afford to: its creating thread is
    /// still inside `installTriggerTap`, the one place allowed to invalidate that port. The install is
    /// re-queued for the slice that finds the field clear.
    ///
    /// The interleaving itself is not reproducible in-process — it needs two real `tapCreate` calls in
    /// flight, which is two consuming taps in front of the user's keyboard — so what is pinned here is
    /// the decision the two publishes race for, taken through the production path.
    @Test("an install that finds another generation's port already in the field is refused, not stored")
    func aForeignPortIsNotOverwritten() throws {
        let monitor = HotkeyMonitor()
        let harness = monitor.triggerHarness
        harness.pretendThreadIsLive()
        defer { harness.forgetPretendTap(); harness.forgetPretendThread() }
        harness.bind(.fnSlash, dictationKey: .rightOption)

        // The other generation's install published first, on its own run loop and not on this one.
        let departing = try #require(Self.foreignRunLoop())
        try #require(harness.pretendTapIsInstalled(onRunLoop: departing))

        // This one's `tapCreate` returns a moment later.
        #expect(try #require(harness.publishPretendTap()) == .blockedByAnotherGeneration)

        #expect(harness.installedTapRunLoop === departing,
                "the other generation's port was overwritten, and nothing can invalidate it now")
        #expect(harness.pendingRequest == .install,
                "the install this generation still needs was not re-queued")
    }

    // MARK: One shared field, two generations of tap thread

    /// `DictationController.restartHotkey()` is `stop()` immediately followed by `start()` with no
    /// join — `stop()` cancels the thread and wakes its run loop, but does not wait for it. So the
    /// departing thread can reach its exit path *after* the new one has published its own trigger
    /// port, and `s.trigger` is a single shared field where `TapResources` is per-generation. An
    /// unconditional `removeTriggerTap()` there invalidates the live generation's port: `fn + /` then
    /// types a slash into the user's document with no popup and no error, which is the exact failure
    /// amendment 50's consuming tap exists to prevent, and the watchdog cannot see it because there is
    /// nothing left in `s.trigger` to poll.
    ///
    /// So the exit path tears down only what it owns, matched by run loop — the same rule
    /// `teardown(_:)` applies to `TapResources` with `s.resources === resources`.
    @Test("a departing tap thread leaves the live generation's trigger port alone")
    func aDepartingThreadLeavesTheLiveTapAlone() throws {
        let monitor = HotkeyMonitor()
        let harness = monitor.triggerHarness
        harness.pretendThreadIsLive()
        defer { harness.forgetPretendTap(); harness.forgetPretendThread() }
        harness.bind(.fnSlash, dictationKey: .rightOption)
        // Published on this thread's run loop, standing in for the new generation.
        #expect(try #require(harness.publishPretendTap()) == .published)

        harness.removeTapAsThreadExit(ownedBy: try #require(Self.foreignRunLoop()))

        #expect(harness.tapIsInstalled,
                "a departing generation tore down the live one's consuming tap")
        #expect(harness.pendingRequest == .none, "and left a request behind")
    }

    /// A `CFRunLoop` that is not this thread's, for the two ownership comparisons in this file and
    /// nothing else — no source is added to it and it is never run. The thread hands its run loop back
    /// and exits; the object stays alive because this reference retains it, and a dead thread's run
    /// loop is a fine stand-in when the only question asked of it is whether it is the same object.
    private static func foreignRunLoop() -> CFRunLoop? {
        final class Box: @unchecked Sendable { var value: CFRunLoop? }
        let box = Box()
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = CFRunLoopGetCurrent()
            ready.signal()
        }
        thread.start()
        ready.wait()
        return box.value
    }

    // MARK: The log's `trigger=` vocabulary

    /// A regression guard, not a bug reproduction: this pins the three words the log's `trigger=` key
    /// may carry, because that key used to carry two vocabularies in one stream. `start` logged a
    /// verified outcome (live / MISSING / not needed) and `update` logged
    /// `String(describing: request)` (install / remove / none) — a *queued* request, logged before the
    /// tap thread had serviced it and therefore before any install could have failed, so a runtime
    /// install that hit a revoked grant printed `trigger=install` on one line and "could not create the
    /// refine trigger tap" on another. `update` now logs `triggerRequest=`, and every `trigger=` comes
    /// from the helper read here.
    @Test("trigger= is an outcome in one vocabulary, whoever logs it")
    func triggerStateVocabulary() throws {
        let monitor = HotkeyMonitor()
        let harness = monitor.triggerHarness
        defer { harness.forgetPretendTap() }

        harness.bind(nil, dictationKey: .rightOption)
        #expect(harness.loggedTriggerState == "not needed")

        harness.bind(.fnSlash, dictationKey: .rightOption)
        #expect(harness.loggedTriggerState == "MISSING")

        try #require(harness.pretendTapIsInstalled())
        #expect(harness.loggedTriggerState == "live")
    }
}

