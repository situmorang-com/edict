import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import EdictKit

/// What can and cannot be tested here, stated up front so nobody mistakes a green run for proof that
/// reading a selection works.
///
/// The two ladders themselves need a *live* focused element in another application, Accessibility
/// permission, PostEvent permission and a real selection — none of which a `swift test` process has. So
/// the rungs (`SelectionAX.selectedText`, `SelectionAX.replaceSelection`, the Cmd-C poll) were measured
/// by hand against real apps and the table is in the task receipt, not in here.
///
/// What *is* pinned here is everything that decided wrongly would break the feature silently: the
/// miss-versus-nothing-selected rule, the UTF-16 length gate, the front-app drift check, the readable-
/// channel pre-flight, the byte-lossless pasteboard round trip, the layout-resolved keycode, and the
/// modifier mask that has to include `fn` because `fn` is half the popup's own chord.
///
/// **Every pasteboard test uses a private named pasteboard.** `NSPasteboard.general` is the user's real
/// clipboard, and a test suite that clobbers it is exactly the class of accident RECON amendment 39 was
/// written about.
@Suite("SelectionBridge")
struct SelectionBridgeTests {

    private static func scratchPasteboard(_ label: String) -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.edict.tests.selection.\(label)"))
    }

    // MARK: - Miss versus nothing selected

    @Test("An absent, empty or whitespace-only AX answer is a miss, not a selection")
    func usableRejectsBlanks() {
        #expect(SelectionBridge.usable(nil) == nil)
        #expect(SelectionBridge.usable("") == nil)
        #expect(SelectionBridge.usable("   ") == nil)
        // A web area with nothing selected returns exactly this, which is why whitespace-only counts as
        // a miss rather than as a one-character selection.
        #expect(SelectionBridge.usable("\n") == nil)
        #expect(SelectionBridge.usable(" \t\n ") == nil)
    }

    @Test("Real text survives unchanged, including its own leading and trailing space")
    func usableKeepsTextVerbatim() {
        // Trimmed only for the *decision*, never for the value: the user selected that space, and the
        // refiner is entitled to see the selection exactly as it was.
        #expect(SelectionBridge.usable(" hello ") == " hello ")
        #expect(SelectionBridge.usable("hello\nworld") == "hello\nworld")
        #expect(SelectionBridge.usable("👩‍👩‍👧‍👦") == "👩‍👩‍👧‍👦")
    }

    // MARK: - Length gate

    @Test("A selection inside the limit passes")
    func lengthGateAllowsOrdinaryProse() throws {
        try SelectionBridge.checkLength(String(repeating: "a", count: 1_000))
        try SelectionBridge.checkLength(String(repeating: "a", count: SelectionBridge.lengthLimit))
    }

    @Test("A select-all of a whole document is refused with a sentence quoting both numbers")
    func lengthGateRefusesDocuments() {
        let text = String(repeating: "a", count: SelectionBridge.lengthLimit + 1)
        let error = #expect(throws: SelectionError.self) {
            try SelectionBridge.checkLength(text)
        }
        guard case .selectionTooLong(let units, let limit) = error else {
            Issue.record("expected selectionTooLong, got \(String(describing: error))")
            return
        }
        #expect(units == SelectionBridge.lengthLimit + 1)
        #expect(limit == SelectionBridge.lengthLimit)
        let sentence = try? #require(error?.errorDescription)
        #expect(sentence?.contains("\(units)") == true)
        #expect(sentence?.contains("\(limit)") == true)
    }

    @Test("The gate counts UTF-16 code units, the unit the Accessibility API works in")
    func lengthGateCountsUTF16() {
        // Each of these is one Character and two UTF-16 units, so half the limit's worth of them is
        // exactly at the limit and one more is over it. Counting Characters instead would let a
        // selection twice the model's capacity straight through.
        let atLimit = String(repeating: "😀", count: SelectionBridge.lengthLimit / 2)
        #expect(atLimit.count == SelectionBridge.lengthLimit / 2)
        #expect(atLimit.utf16.count == SelectionBridge.lengthLimit)
        #expect(throws: Never.self) { try SelectionBridge.checkLength(atLimit) }
        #expect(throws: SelectionError.self) { try SelectionBridge.checkLength(atLimit + "😀") }
    }

    // MARK: - Front-app drift

    @Test("Replacing into a different app than the selection came from is refused")
    func driftIsDetected() {
        let textEdit = InjectionTarget(bundleID: "com.apple.TextEdit", appName: "TextEdit")
        let safari = InjectionTarget(bundleID: "com.apple.Safari", appName: "Safari")
        #expect(SelectionBridge.isSameTarget(textEdit, textEdit))
        #expect(!SelectionBridge.isSameTarget(textEdit, safari))
    }

    @Test("An uncomparable bundle id is not treated as drift")
    func driftIgnoresUnbundledProcesses() {
        // An unbundled helper cannot be keyed at all, and the injector already defaults such a target to
        // paste-only. Calling it drift would refuse to replace in a process that is in fact still front.
        let unbundled = InjectionTarget(bundleID: nil, appName: "some helper")
        let textEdit = InjectionTarget(bundleID: "com.apple.TextEdit", appName: "TextEdit")
        #expect(SelectionBridge.isSameTarget(unbundled, textEdit))
        #expect(SelectionBridge.isSameTarget(textEdit, unbundled))
    }

    // MARK: - The AX replace pre-flight

    @Test("A settable element with no readable channel is refused an AX replace")
    func preflightNeedsAReadableChannel() {
        // RECON's decision rule: without a readable channel a `.success` return is unfalsifiable, and for
        // a *replace* an unfalsifiable success means a selection that may already be gone.
        #expect(!SelectionAX.hasReadableChannel([]))
        #expect(!SelectionAX.hasReadableChannel([kAXRoleAttribute as String, kAXSelectedTextAttribute as String]))
    }

    @Test("Any one of the three readable channels is enough")
    func preflightAcceptsAnyChannel() {
        #expect(SelectionAX.hasReadableChannel([kAXValueAttribute as String]))
        #expect(SelectionAX.hasReadableChannel([kAXNumberOfCharactersAttribute as String]))
        #expect(SelectionAX.hasReadableChannel([kAXSelectedTextRangeAttribute as String]))
    }

    // MARK: - Pasteboard: borrow it and give it back

    @Test("A multi-item, multi-flavor clipboard round-trips byte for byte")
    func pasteboardRoundTripIsLossless() throws {
        let board = Self.scratchPasteboard("lossless")
        board.clearContents()

        let rtf = Data("{\\rtf1\\ansi hello}".utf8)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF])

        let first = NSPasteboardItem()
        first.setString("selected sentence", forType: .string)
        first.setData(rtf, forType: .rtf)
        let second = NSPasteboardItem()
        second.setData(png, forType: .png)
        #expect(board.writeObjects([first, second]))

        let snapshot = SelectionPasteboard.snapshot(board)
        #expect(snapshot.items.count == 2)

        // Stand on it the way a synthetic Cmd-C does.
        board.clearContents()
        let intruder = NSPasteboardItem()
        intruder.setString("what the copy put there", forType: .string)
        #expect(board.writeObjects([intruder]))

        #expect(SelectionPasteboard.restore(snapshot, to: board))
        let after = SelectionPasteboard.snapshot(board)
        #expect(after == snapshot)

        let items = try #require(board.pasteboardItems)
        #expect(items.count == 2)
        #expect(items[0].string(forType: .string) == "selected sentence")
        #expect(items[0].data(forType: .rtf) == rtf)
        #expect(items[1].data(forType: .png) == png)
    }

    @Test("Lazily synthesized flavors are excluded, so a lossless restore does not look lossy")
    func snapshotSkipsDerivedFlavors() throws {
        // RECON §16: `public.utf16-external-plain-text` is *listed* in `item.types` but synthesized on
        // demand — `data(forType:)` returns nil and force-unwrapping it crashes. It also regenerates
        // after a restore, so capturing it would make every round trip compare unequal.
        let board = Self.scratchPasteboard("derived")
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString("plain", forType: .string)
        #expect(board.writeObjects([item]))

        let snapshot = SelectionPasteboard.snapshot(board)
        let captured = try #require(snapshot.items.first)
        #expect(!captured.isEmpty)
        for derived in SelectionPasteboard.derivedTypes {
            #expect(captured[derived] == nil, "captured a synthesized flavor: \(derived)")
        }
        for promised in SelectionPasteboard.promiseTypes {
            #expect(captured[promised] == nil, "captured a promised flavor: \(promised)")
        }
        #expect(SelectionPasteboard.restore(snapshot, to: board))
        #expect(board.string(forType: .string) == "plain")
    }

    @Test("An empty clipboard round-trips to an empty clipboard")
    func emptyClipboardRoundTrips() {
        let board = Self.scratchPasteboard("empty")
        board.clearContents()
        let snapshot = SelectionPasteboard.snapshot(board)
        #expect(snapshot.items.isEmpty)
        // No items to write is a success, not a failure — restoring nothing over nothing is correct.
        #expect(SelectionPasteboard.restore(snapshot, to: board))
    }

    @Test("The refined text left behind is marked transient so clipboard managers skip it")
    func transientWriteIsMarked() throws {
        let board = Self.scratchPasteboard("transient")
        board.clearContents()
        let before = board.changeCount

        let changeCount = try #require(SelectionPasteboard.writeTransient("refined text", to: board))
        #expect(changeCount != before)
        #expect(board.string(forType: .string) == "refined text")

        let types = try #require(board.pasteboardItems?.first?.types.map(\.rawValue))
        #expect(types.contains("org.nspasteboard.TransientType"))
        #expect(types.contains("org.nspasteboard.AutoGeneratedType"))
    }

    // MARK: - Layout-resolved Cmd-C

    @Test("The C keycode comes from the live layout, not from a constant")
    @MainActor
    func cKeyCodeResolvesFromTheLayout() {
        // RECON §15 and amendment 36 together: resolve from the layout, and only ever on the main
        // thread. A wrong keycode here does not fail quietly — it posts Cmd-<something else> into
        // whatever app the user is in.
        let resolved = SelectionKeycodes.keyCode(for: "c")
        #expect(resolved != nil, "no keyboard layout data — the Cmd-C would fall back to a constant")
        if let resolved { #expect(resolved < 128) }
        #expect(SelectionKeycodes.cKeyCode() < 128)
        // The scan must not invent a keycode for a character no key produces.
        #expect(SelectionKeycodes.keyCode(for: "😀") == nil)
    }

    // MARK: - Modifier mask

    @Test("fn is in the mask the copy waits on, because fn is half the popup's chord")
    func modifierMaskCoversTheChord() {
        // The popup opens on fn + the dictation key *held*. Posting Cmd-C while they are down delivers
        // Cmd-fn-Option-C, which is not a copy. Dropping `.maskSecondaryFn` from this set would make the
        // read fail intermittently and look like an Accessibility problem.
        #expect(SelectionBridge.dangerousFlags.contains(.maskSecondaryFn))
        #expect(SelectionBridge.dangerousFlags.contains(.maskAlternate))
        #expect(SelectionBridge.dangerousFlags.contains(.maskCommand))
    }

    @Test("A held modifier is a warning on the way in and a sentence only on the way out")
    func heldModifiersNeverPreemptivelyRefuse() {
        // Measured: `flagsState(.combinedSessionState)` reported `maskCommand` set for over three
        // seconds at a stretch on this machine with no key physically down, then read clean a moment
        // later. Gating the copy on that reading made the feature fail for seconds at a time, so the
        // wait is advisory and `modifiersHeld` is raised only *after* a copy has been tried and come
        // back empty — at which point "let go and try again" is honest advice rather than a guess.
        //
        // What is pinned here is the sentence being the actionable one, because the code path that
        // chooses it needs a live target app and cannot be reached from a test.
        let held = SelectionError.modifiersHeld.errorDescription ?? ""
        let empty = SelectionError.nothingSelected.errorDescription ?? ""
        #expect(held != empty)
        #expect(held.lowercased().contains("let go"))
        #expect(empty.lowercased().contains("select"))
    }

    @Test("The modifier wait honours a zero budget instead of blocking")
    func modifierWaitRespectsItsBudget() {
        // RECON §27 in passing: this reads `.combinedSessionState`. `.privateState` was measured blocking
        // for ever, so a regression to it would hang the popup rather than time out — a zero budget makes
        // that hang show up as a failed test instead of a wedged suite.
        let result = SelectionBridge.waitForCleanModifiers(timeoutMs: 0)
        #expect(result.waitedMs == 0)
    }

    @Test("The copy budget is wider than the injector's, and the floor sits inside it")
    func timingConstantsAreOrdered() {
        #expect(SelectionBridge.settleFloorMs < SelectionBridge.copyTimeoutMs)
        #expect(SelectionBridge.pollStepMs > 0)
        // A copy waits on the target app's own run loop servicing a shortcut, not merely on it reading a
        // pasteboard Edict already wrote, so 400 ms is not enough.
        #expect(SelectionBridge.copyTimeoutMs > 400)
        // And the chord being held is the *expected* state on entry, not an anomaly.
        #expect(SelectionBridge.modifierTimeoutMs > SelectionBridge.copyTimeoutMs)
    }

    // MARK: - Sentences

    @Test("Every failure is one finished sentence fit to put on a panel")
    func errorsAreScreenReady() throws {
        let all: [SelectionError] = [
            .noFocusedElement,
            .nothingSelected,
            .notPermitted("Edict needs Accessibility permission."),
            .modifiersHeld,
            .copyFailed,
            .selectionTooLong(units: 40_000, limit: SelectionBridge.lengthLimit),
            .replaceFailed("That app would not take the refined text."),
        ]
        for error in all {
            let sentence = try #require(error.errorDescription, "\(error) has no sentence")
            #expect(!sentence.isEmpty)
            #expect(sentence.first?.isUppercase == true, "not capitalised: \(sentence)")
            #expect(".!?".contains(sentence.last ?? " "), "unfinished: \(sentence)")
            #expect(!sentence.contains("\n"), "not one line: \(sentence)")
            // No API spelling leaks onto the screen.
            #expect(!sentence.contains("kAX"), "leaks an API name: \(sentence)")
            #expect(!sentence.lowercased().contains("nil"), "leaks an implementation detail: \(sentence)")
        }
    }

    @Test("A closed gate always explains itself, and an open one says nothing")
    func gateEitherPassesOrExplains() throws {
        // Whether the gate is open depends on what the test host has been granted, so both answers are
        // valid — what is asserted is that a refusal is never wordless.
        if let closed = SelectionBridge.closedGate() {
            #expect(!closed.isEmpty)
            #expect(".!?".contains(try #require(closed.last)))
        }
    }

    // MARK: - Snapshot value semantics

    @Test("A snapshot carries the route that won, and compares by value")
    func snapshotIsAValue() {
        let target = InjectionTarget(bundleID: "com.apple.TextEdit", appName: "TextEdit")
        let ax = SelectionSnapshot(text: "hello", target: target, route: .accessibility)
        let pasted = SelectionSnapshot(text: "hello", target: target, route: .pasteboard)
        #expect(ax != pasted)
        #expect(ax == SelectionSnapshot(text: "hello", target: target, route: .accessibility))
        // The raw values are persisted and logged, so they are part of the contract.
        #expect(SelectionSnapshot.Route.accessibility.rawValue == "accessibility")
        #expect(SelectionSnapshot.Route.pasteboard.rawValue == "pasteboard")
    }
}
