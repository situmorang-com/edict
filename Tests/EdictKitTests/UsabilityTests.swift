import Foundation
import ServiceManagement
import Synchronization
import Testing
@testable import EdictKit

// MARK: - Login item

/// The switch that used to be inert. The interesting half is not `register()` — it is that the state
/// shown to the user is only ever derived from `SMAppService.mainApp.status`, so a `register()` that
/// throws, or one that parks the job in `.requiresApproval`, cannot leave the plate claiming a login
/// item macOS will not run.
///
/// Driven through the `LoginItemService` seam so nothing here touches the real login-item database.
@Suite("Login item")
@MainActor
struct LoginItemTests {

    /// A stub whose status is whatever the *system* would say — deliberately decoupled from what
    /// `register()` was asked to do, which is the whole failure mode being guarded.
    final class Stub: LoginItemService, @unchecked Sendable {
        private let lock = NSLock()
        private var _status: SMAppService.Status
        private let registerResult: (any Error)?
        private let statusAfterRegister: SMAppService.Status?
        private(set) var registerCalls = 0
        private(set) var unregisterCalls = 0

        init(
            status: SMAppService.Status,
            registerThrows: (any Error)? = nil,
            statusAfterRegister: SMAppService.Status? = nil
        ) {
            self._status = status
            self.registerResult = registerThrows
            self.statusAfterRegister = statusAfterRegister
        }

        var status: SMAppService.Status { lock.withLock { _status } }

        func register() throws {
            lock.withLock { registerCalls += 1 }
            if let registerResult { throw registerResult }
            if let statusAfterRegister { lock.withLock { _status = statusAfterRegister } }
        }

        func unregister() throws {
            lock.withLock {
                unregisterCalls += 1
                _status = .notRegistered
            }
        }
    }

    // MARK: Status mapping

    @Test("Every SMAppService status maps to exactly one shown state")
    func statusMapping() {
        #expect(LoginItem.state(for: .enabled) == .enabled)
        #expect(LoginItem.state(for: .notRegistered) == .disabled)
        #expect(LoginItem.state(for: .requiresApproval) == .requiresApproval)
        if case .unavailable = LoginItem.state(for: .notFound) {} else {
            Issue.record("notFound must be unavailable, not merely off")
        }
    }

    @Test("requiresApproval reads as on and as a fault, because macOS will not launch Edict yet")
    func approvalIsOnAndFaulted() {
        // The trap this pins down: `register()` does not throw for `.requiresApproval`, so anything
        // that treats a non-throwing call as success shows a plain "on" for a login item that will
        // not run. On, so the plate matches the registration; faulted, so the row says so.
        #expect(LoginItem.State.requiresApproval.isOn)
        #expect(LoginItem.State.requiresApproval.isFault)
        #expect(LoginItem.State.enabled.isOn)
        #expect(!LoginItem.State.enabled.isFault)
        #expect(!LoginItem.State.disabled.isOn)
        #expect(!LoginItem.State.disabled.isFault)
        #expect(!LoginItem.State.unavailable("no bundle").isOn)
        #expect(LoginItem.State.unavailable("no bundle").isFault)
    }

    // MARK: Reality, not intent

    @Test("A register that throws leaves the switch off and says why")
    func registerFailureRevertsTheSwitch() {
        let stub = Stub(
            status: .notRegistered,
            registerThrows: NSError(domain: "SMAppServiceErrorDomain", code: 1)
        )
        let item = LoginItem(service: stub)
        #expect(item.state == .disabled)

        item.set(true)

        #expect(stub.registerCalls == 1)
        // The whole point: the press happened, the call failed, and nothing claims otherwise.
        #expect(item.state == .disabled)
        #expect(item.failure != nil)
    }

    @Test("A register macOS parks for approval does not report itself as enabled")
    func approvalIsNotEnabled() {
        let stub = Stub(status: .notRegistered, statusAfterRegister: .requiresApproval)
        let item = LoginItem(service: stub)

        item.set(true)

        #expect(stub.registerCalls == 1)
        #expect(item.state == .requiresApproval)
        // No throw, so no failure string — this is a legitimate outcome that needs a different sentence,
        // not an error.
        #expect(item.failure == nil)
    }

    @Test("A register macOS accepts reports enabled and clears the last failure")
    func registerSuccess() {
        let stub = Stub(status: .notRegistered, statusAfterRegister: .enabled)
        let item = LoginItem(service: stub)

        item.set(true)

        #expect(item.state == .enabled)
        #expect(item.failure == nil)
    }

    @Test("Unregistering turns it off")
    func unregister() {
        let stub = Stub(status: .enabled)
        let item = LoginItem(service: stub)
        #expect(item.state == .enabled)

        item.set(false)

        #expect(stub.unregisterCalls == 1)
        #expect(item.state == .disabled)
    }

    @Test("With no service at all the switch is unavailable rather than merely off")
    func noService() {
        // What `swift run` produces: no `.app` around the executable, so `SMAppService` has no bundle
        // to register. Reporting "off" there would invite the user to press a key that can never work.
        let item = LoginItem(service: nil)
        if case .unavailable = item.state {} else {
            Issue.record("a bundle-less launch must report unavailable")
        }
        #expect(!item.state.isOn)

        item.set(true)
        #expect(!item.state.isOn)
        #expect(item.failure != nil)
    }

    @Test("A state changed behind Edict's back is picked up by refresh")
    func refreshReadsReality() {
        let stub = Stub(status: .enabled)
        let item = LoginItem(service: stub)
        #expect(item.state == .enabled)

        // The user removes the login item in System Settings while Edict is running.
        try? stub.unregister()
        item.refresh()

        #expect(item.state == .disabled)
    }

    @Test("The dead preference is gone from Settings' storage")
    func noStaleLaunchAtLoginKey() {
        // The original defect: a `Bool` nothing read. Regression guard, because re-adding one is the
        // easy mistake — a preference here and an `SMAppService` call over there is a state machine
        // with two truths.
        let defaults = EphemeralDefaults()
        let settings = Settings(defaults: defaults)
        settings.resetToDefaults()
        #expect(defaults.object(forKey: "edict.launchAtLogin") == nil)
    }
}

// MARK: - Injection recovery

@Suite("Injection recovery")
struct InjectionRecoveryTests {

    @Test("Only outcomes that never reached the cursor offer recovery")
    func needsRecovery() {
        #expect(InjectionOutcome.clipboardOnly.needsRecovery)
        #expect(InjectionOutcome.failed.needsRecovery)
        #expect(!InjectionOutcome.accessibility.needsRecovery)
        #expect(!InjectionOutcome.paste.needsRecovery)
        #expect(!InjectionOutcome.keystrokes.needsRecovery)
        // `.notAttempted` is an imported file or an utterance started from Edict's own window. There was
        // never a cursor to miss, so offering to retry would invent a failure.
        #expect(!InjectionOutcome.notAttempted.needsRecovery)
    }

    @Test("Recovery is offered for exactly the unsuccessful outcomes that were attempted")
    func recoveryTracksSuccess() {
        for outcome in InjectionOutcome.allCases where outcome != .notAttempted {
            #expect(outcome.needsRecovery == !outcome.isSuccess,
                    "\(outcome.rawValue) disagrees with isSuccess")
        }
    }
}

// MARK: - Learned policy

/// An in-memory `UserDefaults` that counts write-throughs of the injection policy map.
///
/// Why not `EphemeralDefaults`: it is `final`, and it counts nothing. This repeats its trick for the
/// same measured reason — a suite domain, once written to, is re-persisted by cfprefsd on its own
/// schedule and cannot be cleaned up in-process (see `EphemeralDefaults` for the table), so a domain
/// that is never created is the only teardown that works. Every read and write below is answered out
/// of `store` without reaching `super`.
///
/// The count exists because a demotion that ignores its idempotence guard and one that respects it
/// leave *the same value* behind. Asserting on the strategy alone would pass against both, which is
/// the class of test this phase is meant to stop writing.
///
/// `@unchecked Sendable`: `UserDefaults` is already `Sendable`, so this cannot be actor-confined; the
/// dictionary and the counter are genuinely guarded by `lock` instead.
private final class CountingDefaults: UserDefaults, @unchecked Sendable {

    private let lock = NSLock()
    private var store: [String: Any] = [:]
    private var writes = 0

    /// `init(suiteName:)` is `UserDefaults`' only designated initializer, and `nil` means "the default
    /// search list" — the cheapest thing to hand the superclass, and never written to.
    init() { super.init(suiteName: nil)! }

    /// Writes of `InjectPolicyStore.key` only, so an unrelated key cannot inflate the count.
    var policyWriteCount: Int { lock.withLock { writes } }

    override func object(forKey key: String) -> Any? { lock.withLock { store[key] } }

    override func set(_ value: Any?, forKey key: String) {
        lock.withLock {
            if key == InjectPolicyStore.key { writes += 1 }
            if let value { store[key] = value } else { _ = store.removeValue(forKey: key) }
        }
    }

    override func removeObject(forKey key: String) {
        lock.withLock { _ = store.removeValue(forKey: key) }
    }
}

/// The learned per-bundle policy has to be one thing in the process, not one per `TextInjector`.
///
/// There are now two injectors: `DictationController`'s, on the dictation path, and `AppModel`'s,
/// behind the history pane's retry key. With the old per-actor snapshot, "always paste only here" set
/// from the pane was invisible to the next dictation until relaunch — a control that appears to do
/// something and does not, which is the same defect as the login switch in a different costume.
@Suite("Learned injection policy")
struct InjectPolicyTests {

    /// An ephemeral `UserDefaults`, so no test ever writes `edict.injectPolicies` into the user's real
    /// preferences, and no suite plist is created for cfprefsd to re-persist (see `EphemeralDefaults`).
    private func makeStore() -> InjectPolicyStore {
        InjectPolicyStore(defaults: EphemeralDefaults())
    }

    @Test("An unknown app has no learned policy but still gets a strategy")
    func defaults() async {
        let injector = TextInjector(policies: makeStore())
        #expect(await injector.strategy(for: "com.example.unknown") == .axFirst)
        #expect(await injector.hasLearnedStrategy(for: "com.example.unknown") == false)
    }

    @Test("A seeded app is paste-only without anything having been learned about it")
    func seeds() async {
        let injector = TextInjector(policies: makeStore())
        // Ghostty — the terminal from the real failure in the brief. The distinction matters to the UI:
        // "Edict shipped with this" and "Edict decided this" are different sentences.
        #expect(await injector.strategy(for: "com.mitchellh.ghostty") == .pasteOnly)
        #expect(await injector.hasLearnedStrategy(for: "com.mitchellh.ghostty") == false)
    }

    @Test("A nil bundle id is never trusted with an Accessibility insert")
    func nilBundle() async {
        let injector = TextInjector(policies: makeStore())
        #expect(await injector.strategy(for: nil) == .pasteOnly)
    }

    @Test("A policy set on one injector is visible to another sharing the store")
    func sharedStore() async {
        let store = makeStore()
        let pane = TextInjector(policies: store)
        let dictation = TextInjector(policies: store)

        await pane.setStrategy(.pasteOnly, for: "com.example.electron")

        #expect(await dictation.strategy(for: "com.example.electron") == .pasteOnly)
        #expect(await dictation.hasLearnedStrategy(for: "com.example.electron") == true)
    }

    @Test("Forgetting a policy on one injector is visible to the other, and restores the default")
    func forgetIsShared() async {
        let store = makeStore()
        let pane = TextInjector(policies: store)
        let dictation = TextInjector(policies: store)

        await pane.setStrategy(.pasteOnly, for: "com.example.editor")
        #expect(await dictation.strategy(for: "com.example.editor") == .pasteOnly)

        await dictation.forgetStrategy(for: "com.example.editor")

        #expect(await pane.strategy(for: "com.example.editor") == .axFirst)
        #expect(await pane.hasLearnedStrategy(for: "com.example.editor") == false)
    }

    @Test("Forgetting a seeded app's policy does not resurrect it as learned")
    func forgetLeavesTheSeed() async {
        let injector = TextInjector(policies: makeStore())
        await injector.forgetStrategy(for: "com.mitchellh.ghostty")
        // The seed is not a learned entry, so there is nothing to remove and the seed still applies.
        #expect(await injector.strategy(for: "com.mitchellh.ghostty") == .pasteOnly)
        #expect(await injector.hasLearnedStrategy(for: "com.mitchellh.ghostty") == false)
    }

    @Test("A learned policy overrides the seed in both directions")
    func learningBeatsTheSeed() async {
        let injector = TextInjector(policies: makeStore())
        await injector.setStrategy(.axFirst, for: "com.mitchellh.ghostty")
        #expect(await injector.strategy(for: "com.mitchellh.ghostty") == .axFirst)
        #expect(await injector.hasLearnedStrategy(for: "com.mitchellh.ghostty") == true)
    }

    @Test("Policies survive a store rebuilt on the same defaults")
    func persistence() async {
        let defaults = EphemeralDefaults()
        let first = TextInjector(policies: InjectPolicyStore(defaults: defaults))
        await first.setStrategy(.unicodeOnly, for: "com.example.qt")

        // A fresh store over the same storage is what the next launch sees.
        let second = TextInjector(policies: InjectPolicyStore(defaults: defaults))
        #expect(await second.strategy(for: "com.example.qt") == .unicodeOnly)
    }

    // MARK: Self-healing demotion

    // The half of the amendment nothing reached: every test above this point drives `setStrategy` or
    // `forgetStrategy` by hand, so deleting both `demoteToPasteOnly` call sites in `inject` left the
    // suite green. The three below call the demotion itself, which is why it is internal.
    //
    // Be clear about what that does and does not buy: `inject` reads the frontmost app's focused
    // element and posts a Cmd-V, so no test here may run the ladder, and the two call sites inside it
    // stay unguarded until the `InjectAX`/`InjectPasteboard` seam exists. What is guarded now is the
    // function those call sites call — before this, it was reachable by nothing at all.

    @Test("An unverifiable AX write demotes the app for good")
    func demotionLearns() async {
        let injector = TextInjector(policies: makeStore())
        #expect(await injector.strategy(for: "com.example.electron") == .axFirst)

        await injector.demoteToPasteOnly(
            "com.example.electron",
            why: "AX insert is unverifiable on this element"
        )

        #expect(await injector.strategy(for: "com.example.electron") == .pasteOnly)
        // Learned rather than seeded, so the recovery block can say Edict decided this.
        #expect(await injector.hasLearnedStrategy(for: "com.example.electron") == true)
    }

    @Test("A repeat demotion of an already-demoted app writes nothing")
    func demotionIsIdempotent() async {
        let defaults = CountingDefaults()
        let injector = TextInjector(policies: InjectPolicyStore(defaults: defaults))

        await injector.demoteToPasteOnly("com.example.electron", why: "first failure")
        #expect(defaults.policyWriteCount == 1)

        await injector.demoteToPasteOnly("com.example.electron", why: "second failure")

        // The `learned(...) != .pasteOnly` guard. Without it, an app that fails its AX verify on every
        // dictation rewrites the whole policy map and logs a fresh demotion each time, for a decision
        // already taken. The stored value is identical either way, which is why this asserts on the
        // write count rather than on the strategy.
        #expect(defaults.policyWriteCount == 1)
        #expect(await injector.strategy(for: "com.example.electron") == .pasteOnly)
    }

    @Test("A nil bundle id cannot be demoted, because it cannot be keyed")
    func demotionNeedsABundleID() async {
        let defaults = CountingDefaults()
        let injector = TextInjector(policies: InjectPolicyStore(defaults: defaults))

        await injector.demoteToPasteOnly(nil, why: "AX write returned success but nothing changed")

        #expect(defaults.policyWriteCount == 0)
        #expect(await injector.learnedStrategies().isEmpty)
        // Nothing is lost by not recording it: an unbundled process is already paste-only under the
        // nil rule in `strategy(for:)`, and a nil key would collide with every other such process.
        #expect(await injector.strategy(for: nil) == .pasteOnly)
    }

    @Test("Every strategy has a sentence the recovery block can print")
    func displayNames() {
        for strategy in InjectStrategy.allCases {
            #expect(!strategy.displayName.isEmpty)
            // Natural case: the silkscreen type uppercases, and an all-caps string handed to VoiceOver
            // is spelled out letter by letter.
            #expect(strategy.displayName != strategy.displayName.uppercased())
        }
    }
}

// MARK: - Action reports

/// The confirmation values themselves. Small, but the shape is load-bearing: a report carries *what
/// happened*, and whether it was the outcome the user wanted, as two separate facts — so a key can say
/// "Denied" and be visibly a refusal rather than a cheerful "Done".
@Suite("Action reports")
struct ActionReportTests {

    @Test("done and failed differ only in the fault flag")
    func constructors() {
        #expect(ActionReport.done("Live") == ActionReport(text: "Live", isFault: false))
        #expect(ActionReport.failed("Still dead") == ActionReport(text: "Still dead", isFault: true))
        #expect(ActionReport.done("Live") != ActionReport.failed("Live"))
    }

    @Test("Reports are hashable so a repeated press can restart its own dwell")
    func hashable() {
        // The component keys its dwell on a counter rather than on the value precisely because two
        // presses can produce an equal report; this pins the equality that makes that necessary.
        #expect(ActionReport.done("Copied") == ActionReport.done("Copied"))
        #expect(Set([ActionReport.done("Copied"), ActionReport.done("Copied")]).count == 1)
    }
}

// MARK: - Terminal newline collapse

/// The seven ids `TextInjector.normalise` collapses newlines for, written out here rather than read
/// from `InjectSeed`.
///
/// Iterating the production set would not fail in the direction that matters: an id dropping *out* of
/// `terminalBundles` would simply stop being iterated, and the suite would stay green while dictated
/// prose began executing as shell commands in that terminal. `tableCoversTheSeedSet` closes the other
/// direction, so a newly supported terminal has to be added here and proved to collapse.
private let terminalBundleTable = [
    "com.apple.Terminal",
    "com.googlecode.iterm2",
    "dev.warp.Warp-Stable",
    "net.kovidgoyal.kitty",
    "io.alacritty",
    "com.github.wez.wezterm",
    "com.mitchellh.ghostty",
]

/// The one transformation Edict makes to the user's words, and the only one whose regression is
/// destructive rather than merely wrong: a terminal *executes* a pasted newline. Bullets made
/// multi-line dictation routine a few commits before this suite existed, and until it did, nothing in
/// `Tests/` mentioned `normalise` or `terminalBundles` at all.
///
/// Nothing here posts an event or writes a pasteboard: `normalise` is a pure function of the text and
/// the bundle id, which is exactly why it is the half of the ladder worth testing on every machine.
@Suite("Terminal newline collapse")
struct InjectNormalisationTests {

    @Test("The table covers exactly the shipped terminal list")
    func tableCoversTheSeedSet() {
        // An id added to the seed without a row here, or removed from the seed while a row remains,
        // both land as a failure — which is the point, since every terminal in the set has to be
        // proved to collapse and no id may silently leave the set.
        #expect(InjectSeed.terminalBundles == Set(terminalBundleTable))
    }

    @Test("Every terminal collapses a dictated line break to one space", arguments: terminalBundleTable)
    func collapsesEveryLineEnding(bundleID: String) {
        #expect(TextInjector.normalise("line one\nline two", for: bundleID) == "line one line two")
        // `\r\n` has to be replaced first. Run the bare `\n` pass ahead of it and this comes back as
        // "a  b" — two spaces from one dictated break — and hoisting the `\r` pass gives the same. Only
        // the head of the chain is load-bearing: `\n` and `\r` are interchangeable with each other.
        #expect(TextInjector.normalise("a\r\nb", for: bundleID) == "a b")
        #expect(TextInjector.normalise("a\rb", for: bundleID) == "a b")
    }

    @Test("A dictated bullet list reaches a terminal as one line", arguments: terminalBundleTable)
    func collapsesBullets(bundleID: String) {
        // The shape the bullets feature produces. Uncollapsed, the first line runs and the rest queue
        // behind it as further commands.
        #expect(
            TextInjector.normalise("- check the logs\n- restart the box\n- tell Ana", for: bundleID)
                == "- check the logs - restart the box - tell Ana"
        )
    }

    @Test("Tabs survive the collapse", arguments: terminalBundleTable)
    func leavesTabsAlone(bundleID: String) {
        // No shell executes a line on a tab, so it is not the failure being prevented, and rewriting
        // it would mangle dictated code.
        #expect(TextInjector.normalise("a\tb", for: bundleID) == "a\tb")
        #expect(TextInjector.normalise("indent\tthis\nand that", for: bundleID) == "indent\tthis and that")
    }

    @Test("A non-terminal app gets the user's text byte for byte")
    func textEditIsUntouched() {
        // TextEdit takes a pasted newline as a newline, which is what the user dictated. Collapsing
        // here would be a silent content edit with nothing to justify it.
        let dictated = "cafe\u{301} au lait\nsecond line\r\nthird\rfourth\twith a tab"
        let out = TextInjector.normalise(dictated, for: "com.apple.TextEdit")
        #expect(out == dictated)
        // NOT redundant with the line above, and it took a decomposed "e\u{301}" in the fixture to
        // make that true. Swift's `==` compares canonical equivalence, so on an ASCII-only fixture
        // byte equality was the same predicate — and a pass-through that quietly folded the user's
        // words with `precomposedStringWithCanonicalMapping` was invisible to both.
        #expect(Array(out.utf8) == Array(dictated.utf8),
                "the pass-through path recomposed the user's text instead of leaving it alone")
    }

    @Test("A nil bundle id gets the user's text byte for byte")
    func nilBundleIsUntouched() {
        // An unbundled or helper process cannot be keyed in the policy map, so it cannot be known to
        // be a terminal. `strategy(for: nil)` already refuses to trust it with an AX insert; that is
        // a reason to be careful about *how* the text is delivered, not a licence to rewrite it.
        let dictated = "one nai\u{308}ve\ntwo\r\nthree\rfour\tfive"
        let out = TextInjector.normalise(dictated, for: nil)
        #expect(out == dictated)
        // Decomposed "i\u{308}" for the same reason as above.
        #expect(Array(out.utf8) == Array(dictated.utf8),
                "the pass-through path recomposed the user's text instead of leaving it alone")
    }

    // MARK: The verdict-to-demotion mapping

    /// The other half of the wiring that nothing pinned.
    ///
    /// Measured: replacing both `demoteToPasteOnly` call sites in `inject` with `break` left every
    /// injection suite green, so the self-healing half of the CONTRACTS amendment was unguarded. The
    /// ladder itself still needs an `InjectAX`/`InjectPasteboard` seam to drive, and that is scoped
    /// separately — but the mapping from a verdict to a reason is pure, and it is where the decision
    /// actually lives.
    @Test("Only a verdict that failed or could not be verified demotes an app")
    func demotionMapping() {
        #expect(TextInjector.demotionReason(for: .confirmedInserted) == nil,
                "a verified insert demoted the app, so one good app would be paste-only forever")

        // Both demote, and they are deliberately different sentences: the log is where a "why is this
        // app on the slow path" question gets answered.
        let notInserted = TextInjector.demotionReason(for: .confirmedNotInserted)
        let cannotVerify = TextInjector.demotionReason(for: .cannotVerify)
        #expect(notInserted != nil)
        #expect(cannotVerify != nil,
                """
                an insert nothing could verify was treated as a success, which is the one outcome this                 app must never report — the alternative is telling the user their words landed when the                 app silently dropped them
                """)
        #expect(notInserted != cannotVerify)
    }

    // MARK: The call site, not just the function

    /// The hole the tests above do not close.
    ///
    /// Measured: replacing `let payload = Self.normalise(text, for: target.bundleID)` in `inject` with
    /// `let payload = text` — Edict simply stops collapsing newlines for terminals — left every
    /// injection suite green. `normalise` was pinned; the fact that anything CALLS it was not. And the
    /// consequence of that regression is the one this whole area exists to prevent: a user's dictated
    /// bullet list arriving in Ghostty as a run of shell commands.
    ///
    /// Reached through the rung-0 gate rather than the ladder. `payload` is computed ABOVE the gate,
    /// so closing the gate sends the collapsed text to the clipboard without any AX write, any posted
    /// keystroke, or any contact with the frontmost app — and the injected clipboard closure means the
    /// user's real pasteboard is never touched either. Closing the gate has to be INJECTED rather than
    /// read: this machine has Accessibility granted, so an ambient gate would take the AX rung and the
    /// test would pass or fail depending on whose Mac it ran on.
    @Test("inject collapses newlines for a terminal, not just normalise on its own")
    func injectCollapsesForATerminal() async {
        let captured = Captured()
        let injector = TextInjector(
            policies: InjectPolicyStore(defaults: EphemeralDefaults()),
            gate: { .closed },
            writeClipboard: { text in
                captured.append(text)
                return 1
            }
        )

        let outcome = await injector.inject(
            "line one\nline two",
            into: InjectionTarget(bundleID: "com.mitchellh.ghostty", appName: "Ghostty")
        )

        #expect(outcome == .clipboardOnly)
        #expect(captured.all == ["line one line two"],
                "inject stopped collapsing newlines for a terminal, so dictated prose would arrive in Ghostty as shell commands")
    }

    @Test("inject leaves a non-terminal app's newlines alone")
    func injectLeavesNonTerminalsAlone() async {
        let captured = Captured()
        let injector = TextInjector(
            policies: InjectPolicyStore(defaults: EphemeralDefaults()),
            gate: { .closed },
            writeClipboard: { text in
                captured.append(text)
                return 1
            }
        )

        _ = await injector.inject(
            "line one\nline two",
            into: InjectionTarget(bundleID: "com.apple.TextEdit", appName: "TextEdit")
        )

        // The other direction, so a mutation that collapses unconditionally fails too. Without this,
        // "always collapse" would satisfy the test above.
        #expect(captured.all == ["line one\nline two"])
    }
}

/// A `@Sendable` collector for what the injected clipboard closure was handed.
///
/// The closure is `@Sendable` because `TextInjector` is, so a captured `var` is a compile error under
/// strict concurrency. `Mutex` rather than an unchecked box: the repo already uses it in
/// `HotkeyMonitor` for the same reason, and an `@unchecked Sendable` here would be a claim nobody
/// checked.
private final class Captured: Sendable {
    private let items = Mutex<[String]>([])
    func append(_ text: String) { items.withLock { $0.append(text) } }
    var all: [String] { items.withLock { $0 } }
}
