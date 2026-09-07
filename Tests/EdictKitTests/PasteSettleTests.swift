import Foundation
import Testing
@testable import EdictKit

/// The window that pasted the user's previous clipboard instead of their dictation.
///
/// Reported symptom: "sometimes I started recording and it pasted the last clipboard item instead of
/// the dictation." The mechanism is the restore, not the write.
///
/// `paste(_:verify:)` is snapshot → write → Cmd-V → floor → verify → restore, and its design is that
/// the verify poll's DURATION doubles as the settle delay before the restore. `InjectAX.waitForChange`
/// polls up to 400 ms in 20 ms steps, so on an app with readable AX text the clipboard is held for up
/// to ~435 ms — ample.
///
/// But the verify closure opens `guard let focus, let fingerprint else { return nil }`, and
/// `waitForChange` itself opens `guard before.isUsable else { return nil }`. In a terminal — named in
/// the source as "the canonical case" — or an Electron app, both return INSTANTLY. There is then no
/// poll, so no settle delay: the restore landed 35 ms after Cmd-V. The target reads the pasteboard
/// lazily on its own run loop (RECON §16), so any app slower than that read the snapshot Edict had
/// just put back.
///
/// Two things made it hard to notice. `changeCount` does not move on a paste, so the
/// "did somebody write after us" check cannot see the failure. And an unverifiable paste returns
/// `.paste`, so the app reported success while inserting the wrong text.
///
/// The 35 ms floor is documented as "no app reading the pasteboard faster than this" — a lower bound
/// on when a read can START. It was being relied on as an upper bound on when one FINISHES.
@Suite("Paste settle")
struct PasteSettleTests {

    @Test("An unverifiable paste holds the clipboard for the same budget the poll would have spent")
    func unverifiableWaitsOutTheBudget() {
        // The bug, in one line: verification returned nil after only the floor had elapsed.
        let wait = TextInjector.settleWaitMs(verdict: nil, elapsedMs: TextInjector.settleFloorMs)

        #expect(wait == TextInjector.settleBudgetMs - TextInjector.settleFloorMs)
        #expect(wait > 0, """
            an unverifiable paste restored the user's previous clipboard \
            \(TextInjector.settleFloorMs) ms after Cmd-V, so any app that reads the pasteboard more \
            slowly than that pasted the old contents — and reported success
            """)
    }

    @Test("A proved paste restores immediately")
    func provedRestoresAtOnce() {
        // The target has demonstrably read the pasteboard, so holding it longer only widens the
        // window where the user's own clipboard is missing.
        #expect(TextInjector.settleWaitMs(verdict: true, elapsedMs: TextInjector.settleFloorMs) == 0)
        #expect(TextInjector.settleWaitMs(verdict: true, elapsedMs: 0) == 0)
    }

    @Test("A paste that provably did not land restores immediately")
    func provablyDroppedRestoresAtOnce() {
        // Nothing landed, so there is nothing to protect and no reason to keep the user's clipboard
        // hostage. This arm matters because the naive fix — "always wait" — would hold it for 400 ms
        // on every failure in an app that is known-bad.
        #expect(TextInjector.settleWaitMs(verdict: false, elapsedMs: 0) == 0)
    }

    @Test("A slow poll that already spent the budget adds no further wait")
    func aSlowPollIsNotPunishedTwice() {
        // `waitForChange` can return nil after a full 400 ms in one shape: a usable fingerprint whose
        // element never changed would return false, but an element that becomes unreadable mid-poll
        // can still come back nil. Whatever the route, time already spent counts.
        #expect(TextInjector.settleWaitMs(verdict: nil, elapsedMs: 400) == 0)
        #expect(TextInjector.settleWaitMs(verdict: nil, elapsedMs: 900) == 0, "negative wait")
    }

    @Test("The two paths give the target the same time")
    func bothPathsAllowTheSameSettle() {
        // The invariant behind the fix rather than a number: whatever budget the polling path spends
        // before restoring, the non-polling path must match it. If `waitForChange`'s timeout is ever
        // raised without raising this, the bug returns for exactly the apps that cannot be verified.
        #expect(TextInjector.settleBudgetMs == 400, """
            settleBudgetMs no longer matches InjectAX.waitForChange's timeoutMs default of 400 ms. \
            Either they track each other or the unverifiable path silently gets less time than the \
            verifiable one, which is the original bug.
            """)
    }
}
