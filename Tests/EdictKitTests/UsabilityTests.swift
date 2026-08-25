import Foundation
import ServiceManagement
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
