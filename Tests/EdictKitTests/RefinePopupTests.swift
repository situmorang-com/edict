import AppKit
import Carbon.HIToolbox
import CoreGraphics
import SwiftUI
import Testing
@testable import EdictKit

/// What is and is not proved here, stated up front.
///
/// The popup is an `NSPanel` driven by a `CGEventTap`, and a `swift test` process has neither a live
/// tap nor another application to steal a selection from. So this suite pins the parts that would
/// break the feature *silently* if they were wrong, and nothing else claims to be covered:
///
/// * **Placement arithmetic** against synthetic screens — overflow on all four edges, a panel bigger
///   than the display, a second display with a negative origin (this user has two), and the
///   Quartz-to-Cocoa flip that the Accessibility API forces.
/// * **Resolve exactly once** under every pair of competing paths. A second delivery would refine
///   twice and replace twice, and the second replacement would land in text that had already been
///   rewritten — corruption, not waste.
/// * **Key mapping**, including the flags that must and must not disqualify a keystroke, with
///   Karabiner's `nonCoalesced` bit present (RECON amendment 31).
/// * **Timeouts**, on real (millisecond) durations rather than by inspecting the constants.
///
/// Not proved here, and verified by eye from the rendered proof sheets instead: that the panel is
/// placed where the caret actually is in a real app, that it never takes focus, and that it looks
/// like Edict. RECON amendment 40 — Screen Recording is denied to any process an agent starts — so
/// the proof sheets are `ImageRenderer` output, not photographs.
@Suite("RefinePopup")
struct RefinePopupTests {

    // MARK: - Screens used by the placement tests

    /// A 1440x900 built-in display: menu bar at the top, Dock at the bottom.
    static let builtIn = RefineScreen(
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: 0, y: 60, width: 1440, height: 803)
    )

    /// A 4K display placed to the *left* and above, so its origin is negative in x — the exact
    /// arrangement that makes a naive `min`/`max` clamp put the panel on the wrong display.
    static let secondary = RefineScreen(
        frame: CGRect(x: -3840, y: 220, width: 3840, height: 2160),
        visibleFrame: CGRect(x: -3840, y: 220, width: 3840, height: 2123)
    )

    static let panel = CGSize(width: 270, height: 160)

    private func place(_ anchor: RefinePopupAnchor,
                       size: CGSize = panel,
                       screens: [RefineScreen] = [builtIn, secondary]) -> CGRect {
        RefinePopupPlacement.frame(for: anchor, size: size, screens: screens)
    }

    // MARK: - Placement

    @Test("The panel hangs under the leading edge of the selection")
    func placesBelowSelection() {
        let selection = CGRect(x: 400, y: 500, width: 180, height: 18)
        let frame = place(.selection(selection))
        #expect(frame.minX == 400)
        // Below, in Cocoa coordinates, means a *smaller* y: the panel's top edge sits one gap under
        // the selection's bottom edge.
        #expect(frame.maxY == 500 - RefinePopupPlacement.gap)
        #expect(frame.size == Self.panel)
    }

    @Test("A mouse anchor is treated as a zero-size selection")
    func placesBelowPoint() {
        let frame = place(.point(CGPoint(x: 700, y: 500)))
        #expect(frame.minX == 700)
        #expect(frame.maxY == 500 - RefinePopupPlacement.gap)
    }

    @Test("Too little room below flips the panel above the selection")
    func flipsAboveOnBottomOverflow() {
        // 100pt above the bottom of the visible frame: a 160pt panel cannot fit under it.
        let selection = CGRect(x: 300, y: Self.builtIn.visibleFrame.minY + 100, width: 90, height: 20)
        let frame = place(.selection(selection))
        #expect(frame.minY == selection.maxY + RefinePopupPlacement.gap)
        #expect(frame.minY >= Self.builtIn.visibleFrame.minY)
        #expect(frame.maxY <= Self.builtIn.visibleFrame.maxY)
    }

    @Test("With room neither below nor above, the panel stays fully on screen")
    func clampsWhenNeitherSideFits() {
        // A selection tall enough that there is no room below it and no room above it either.
        let visible = Self.builtIn.visibleFrame
        let selection = CGRect(x: 20, y: visible.minY + 20, width: 200, height: visible.height - 60)
        let frame = place(.selection(selection))
        #expect(frame.minY >= visible.minY)
        #expect(frame.maxY <= visible.maxY)
    }

    @Test("A selection at the right edge pulls the panel back onto the screen")
    func clampsRightOverflow() {
        let visible = Self.builtIn.visibleFrame
        let selection = CGRect(x: visible.maxX - 40, y: 500, width: 30, height: 18)
        let frame = place(.selection(selection))
        #expect(frame.maxX <= visible.maxX)
        #expect(frame.maxX == visible.maxX - RefinePopupPlacement.margin)
    }

    @Test("A selection at the top edge does not push the panel under the menu bar")
    func clampsTopOverflow() {
        let visible = Self.builtIn.visibleFrame
        // Right at the top, and tall, so the flip-above branch would overshoot the menu bar.
        let selection = CGRect(x: 100, y: visible.maxY - 10, width: 120, height: 400)
        let frame = place(.selection(selection))
        #expect(frame.maxY <= visible.maxY)
    }

    @Test("An anchor on the negative-origin second display is placed on that display")
    func staysOnSecondDisplay() {
        let selection = CGRect(x: -3800, y: 1200, width: 200, height: 20)
        let frame = place(.selection(selection))
        #expect(Self.secondary.frame.contains(CGPoint(x: frame.midX, y: frame.midY)))
        #expect(frame.minX == -3800)
    }

    @Test("A selection at the left edge of the second display is clamped to that display's edge")
    func clampsLeftOverflowOnSecondDisplay() {
        let visible = Self.secondary.visibleFrame
        let selection = CGRect(x: visible.minX - 30, y: 1200, width: 60, height: 20)
        let frame = place(.selection(selection))
        #expect(frame.minX == visible.minX + RefinePopupPlacement.margin)
    }

    @Test("A point in the dead space between two displays lands on the nearest one")
    func fallsBackToNearestScreen() {
        // Below both displays, closer to the built-in.
        let orphan = CGPoint(x: 700, y: -400)
        let screen = RefinePopupPlacement.screen(containing: orphan, in: [Self.builtIn, Self.secondary])
        #expect(screen == Self.builtIn)
        let frame = place(.point(orphan))
        #expect(frame.minY >= Self.builtIn.visibleFrame.minY)
    }

    @Test("A panel wider or taller than the display is anchored to the low edges, not pushed off")
    func clampInvertsSafely() {
        let huge = CGSize(width: 2000, height: 2000)
        let frame = place(.point(CGPoint(x: 700, y: 500)), size: huge, screens: [Self.builtIn])
        #expect(frame.minX == Self.builtIn.visibleFrame.minX + RefinePopupPlacement.margin)
        #expect(frame.minY == Self.builtIn.visibleFrame.minY + RefinePopupPlacement.margin)
    }

    @Test("With no displays at all the panel is still placed at the anchor")
    func survivesNoScreens() {
        let frame = place(.point(CGPoint(x: 12, y: 34)), screens: [])
        #expect(frame.origin == CGPoint(x: 12, y: 34))
    }

    @Test("Accessibility rects are flipped from Quartz's top-left origin to Cocoa's bottom-left")
    func flipsQuartzToCocoa() {
        // A line of text 40pt down from the top of a 900-tall primary display.
        let quartz = CGRect(x: 200, y: 40, width: 120, height: 18)
        guard case .selection(let cocoa) = RefinePopupAnchor.fromQuartz(quartz, primaryMaxY: 900) else {
            Issue.record("fromQuartz must produce a selection anchor")
            return
        }
        #expect(cocoa.minX == 200)
        #expect(cocoa.height == 18)
        // 900 - (40 + 18): the *bottom* of the Cocoa rect is measured from the top of the rect in
        // Quartz. Flipping only the origin — the mistake — would give 860 here and put the panel a
        // line-height off, or, on the secondary display, a screen away.
        #expect(cocoa.minY == 842)
        #expect(cocoa.maxY == 860)
    }

    // MARK: - Resolve exactly once

    /// A session plus a record of everything delivered to the caller.
    @MainActor
    private final class Harness {
        var outcomes: [RefinePopupOutcome] = []
        var states: [RefinePopupState] = []
        var closes = 0
        let session: RefinePopupSession

        init(timeouts: RefinePopupTimeouts = .standard) {
            var record: ((RefinePopupOutcome) -> Void)!
            var state: ((RefinePopupState) -> Void)!
            var close: (() -> Void)!
            session = RefinePopupSession(
                timeouts: timeouts,
                onState: { state($0) },
                onClose: { close() },
                deliver: { record($0) }
            )
            record = { [unowned self] in self.outcomes.append($0) }
            state = { [unowned self] in self.states.append($0) }
            close = { [unowned self] in self.closes += 1 }
        }
    }

    @Test("A choice followed by every dismiss path still delivers exactly one outcome") @MainActor
    func choiceWinsOverLaterDismissals() {
        let harness = Harness()
        #expect(harness.session.handle(.digit(2)))
        harness.session.dismiss(.escape)
        harness.session.dismiss(.clickedOutside)
        harness.session.dismiss(.frontmostAppChanged)
        harness.session.dismiss(.timedOut)
        harness.session.close()
        #expect(harness.outcomes == [.chose(.bullets)])
    }

    @Test("A dismissal followed by a choice still delivers exactly one outcome") @MainActor
    func dismissalWinsOverLaterChoice() {
        let harness = Harness()
        harness.session.dismiss(.clickedOutside)
        // The click already took the panel away; a keystroke that raced it must not be consumed,
        // or the tap would swallow a `1` the user meant for their own document.
        #expect(harness.session.handle(.digit(1)) == false)
        harness.session.choose(.summarise)
        // Escape after the fact is somebody else's Escape too.
        #expect(harness.session.handle(.escape) == false)
        #expect(harness.outcomes == [.dismissed(.clickedOutside)])
    }

    @Test("Two dismissals arriving together resolve as the first one") @MainActor
    func firstDismissalWins() {
        // Clicking on another app's window raises the click *and* an activation, in that order.
        let harness = Harness()
        harness.session.dismiss(.clickedOutside)
        harness.session.dismiss(.frontmostAppChanged)
        #expect(harness.outcomes == [.dismissed(.clickedOutside)])
        // The panel is taken away once, not twice.
        #expect(harness.closes == 1)
    }

    @Test("A failure before any choice still owes the caller one outcome") @MainActor
    func failureResolvesAnUnchosenSession() {
        let harness = Harness()
        harness.session.fail("Select some text first.")
        #expect(harness.outcomes == [.dismissed(.cancelled)])
        #expect(harness.session.state == .failed("Select some text first."))
        // Still on screen showing the sentence — a failure is not a close.
        #expect(harness.closes == 0)
    }

    @Test("Choosing moves the panel into its working state without being asked") @MainActor
    func choiceEntersWorkingState() {
        let harness = Harness()
        harness.session.choose(.cleanUp)
        #expect(harness.session.state == .working(.cleanUp))
        #expect(harness.states == [.working(.cleanUp)])
        // And a second key cannot be taken, which is what keeps one gesture to one refinement.
        #expect(harness.session.handle(.digit(3)) == false)
    }

    @Test("Closing is idempotent") @MainActor
    func closeIsIdempotent() {
        let harness = Harness()
        harness.session.close()
        harness.session.close()
        harness.session.close()
        #expect(harness.outcomes == [.dismissed(.cancelled)])
        #expect(harness.closes == 1)
    }

    @Test("A closed session accepts nothing further") @MainActor
    func closedSessionIsInert() {
        let harness = Harness()
        harness.session.close()
        harness.session.fail("too late")
        #expect(harness.session.state == .choosing)
        #expect(harness.states.isEmpty)
    }

    // MARK: - Keys

    @Test("The digits and Escape map to the popup's keys")
    func mapsKeys() {
        #expect(RefinePopupKey.key(keyCode: Int64(kVK_ANSI_1), rawFlags: 0) == .digit(1))
        #expect(RefinePopupKey.key(keyCode: Int64(kVK_ANSI_2), rawFlags: 0) == .digit(2))
        #expect(RefinePopupKey.key(keyCode: Int64(kVK_ANSI_3), rawFlags: 0) == .digit(3))
        #expect(RefinePopupKey.key(keyCode: Int64(kVK_Escape), rawFlags: 0) == .escape)
        // The keypad is a genuinely different physical key with the same numeral printed on it.
        #expect(RefinePopupKey.key(keyCode: Int64(kVK_ANSI_Keypad1), rawFlags: 0) == .digit(1))
        #expect(RefinePopupKey.key(keyCode: Int64(kVK_ANSI_Keypad3), rawFlags: 0) == .digit(3))
        // Everything else is somebody else's keystroke.
        #expect(RefinePopupKey.key(keyCode: Int64(kVK_ANSI_4), rawFlags: 0) == nil)
        #expect(RefinePopupKey.key(keyCode: Int64(kVK_Return), rawFlags: 0) == nil)
        #expect(RefinePopupKey.key(keyCode: Int64(kVK_ANSI_A), rawFlags: 0) == nil)
    }

    @Test("The popup's own chord, still held, does not disqualify a choice")
    func allowsTheChordsOwnModifiers() {
        // `fn` + right Option as this machine really reports it: RECON amendment 31 — Karabiner
        // stamps `nonCoalesced` (0x100) on every synthesized event, so 0x00080040 arrives as
        // 0x00080140, and the extra `secondaryFn` bit rides along while `fn` is held.
        let held = CGEventFlags.maskSecondaryFn.rawValue | CGEventFlags.maskAlternate.rawValue
            | 0x40 | 0x100
        #expect(RefinePopupKey.key(keyCode: Int64(kVK_ANSI_1), rawFlags: held) == .digit(1))
        #expect(RefinePopupKey.key(keyCode: Int64(kVK_Escape), rawFlags: held) == .escape)
        // Shift and caps lock are harmless too: on some layouts a digit needs shift.
        let shifted = CGEventFlags.maskShift.rawValue | CGEventFlags.maskAlphaShift.rawValue | 0x100
        #expect(RefinePopupKey.key(keyCode: Int64(kVK_ANSI_2), rawFlags: shifted) == .digit(2))
    }

    @Test("Command and Control belong to the app underneath")
    func rejectsCommandAndControl() {
        // ⌘1 is "first tab" in every browser; ⌃1 switches Space. Swallowing either because our
        // panel happened to be open would be a bug in the user's other app.
        for blocked in [CGEventFlags.maskCommand, .maskControl] {
            let flags = blocked.rawValue | 0x100
            #expect(RefinePopupKey.key(keyCode: Int64(kVK_ANSI_1), rawFlags: flags) == nil)
            #expect(RefinePopupKey.key(keyCode: Int64(kVK_Escape), rawFlags: flags) == nil)
        }
    }

    @Test("The digit map is the engine's own list, in order")
    func digitsFollowTheEngine() {
        #expect(RefinePopupSession.action(forDigit: 1) == RefinementAction.allCases[0])
        #expect(RefinePopupSession.action(forDigit: 2) == RefinementAction.allCases[1])
        #expect(RefinePopupSession.action(forDigit: 3) == RefinementAction.allCases[2])
        #expect(RefinePopupSession.action(forDigit: 0) == nil)
        #expect(RefinePopupSession.action(forDigit: RefinementAction.allCases.count + 1) == nil)
        // And the inverse, which is what the panel prints on each cap.
        for action in RefinementAction.allCases {
            let digit = RefinePopupSession.digit(for: action)
            #expect(digit != nil)
            #expect(RefinePopupSession.action(forDigit: digit ?? 0) == action)
        }
    }

    @Test("A digit with no action is not consumed") @MainActor
    func unmappedDigitPassesThrough() {
        let harness = Harness()
        #expect(harness.session.handle(.digit(9)) == false)
        #expect(harness.outcomes.isEmpty)
    }

    @Test("Escape takes a failure sentence away early, and digits are left alone there") @MainActor
    func failureStateConsumesOnlyEscape() {
        let harness = Harness()
        harness.session.choose(.cleanUp)
        harness.session.fail("Edict could not copy the selection out of that app.")
        #expect(harness.session.handle(.digit(1)) == false)
        #expect(harness.session.handle(.escape))
        #expect(harness.closes == 1)
        // The choice was already delivered; Escape here resolves nothing a second time.
        #expect(harness.outcomes == [.chose(.cleanUp)])
    }

    // MARK: - Timeouts

    /// Wait for a condition instead of sleeping past a deadline and asserting.
    ///
    /// These tests arm real millisecond deadlines, so a fixed sleep is a bet that the timer fires
    /// before the sleep ends. That bet loses under load: all six timeout tests here passed 3/3 in
    /// isolation (0.42 s) and failed in the full 546-test run, because parallel suites starve the
    /// run loop and the assertion arrives before the `Task` does. Polling for the outcome keeps the
    /// deadline real while making the test indifferent to scheduling.
    @MainActor
    private func eventually(
        _ label: String,
        within limit: Duration = .milliseconds(3000),
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(label)")
    }

    /// Real deadlines on millisecond durations. Slow tests are not worth it, and a test that only
    /// reads the constants back proves nothing about the `Task` that arms them.
    private static let brisk = RefinePopupTimeouts(
        choice: .milliseconds(40),
        work: .milliseconds(40),
        failureDwell: .milliseconds(40)
    )

    @Test("An unanswered popup dismisses itself") @MainActor
    func choiceTimesOut() async throws {
        let harness = Harness(timeouts: Self.brisk)
        harness.session.start()
        await eventually("the choice deadline to dismiss the panel") { harness.closes == 1 }
        #expect(harness.outcomes == [.dismissed(.timedOut)])
        #expect(harness.closes == 1)
        // And the tap must stop being fed by us afterwards.
        #expect(harness.session.handle(.digit(1)) == false)
    }

    @Test("A choice cancels the choice deadline") @MainActor
    func choiceDisarmsItsOwnDeadline() async throws {
        let harness = Harness(timeouts: Self.brisk)
        harness.session.start()
        harness.session.choose(.bullets)
        await eventually("the work watchdog to leave a sentence") {
            if case .failed = harness.session.state { return true }
            return false
        }
        // One outcome, and the *work* watchdog — not the choice timeout — is what fired.
        #expect(harness.outcomes == [.chose(.bullets)])
        guard case .failed = harness.session.state else {
            Issue.record("a wedged model must leave a sentence, not a dead panel")
            return
        }
    }

    @Test("A model that never answers leaves a sentence, then closes") @MainActor
    func workWatchdogClosesTheSentence() async throws {
        let harness = Harness(timeouts: Self.brisk)
        harness.session.start()
        harness.session.choose(.summarise)
        await eventually("the work watchdog to close the panel") { harness.closes == 1 }
        #expect(harness.closes == 1)
    }

    @Test("A failure sentence closes itself after the dwell") @MainActor
    func failureDwellCloses() async throws {
        let harness = Harness(timeouts: Self.brisk)
        harness.session.fail("Select some text first.")
        #expect(harness.closes == 0)
        await eventually("the failure dwell to close the panel") { harness.closes == 1 }
        #expect(harness.closes == 1)
    }

    @Test("The shipping deadlines are the ones the comments justify")
    func shippingTimeouts() {
        #expect(RefinePopupTimeouts.standard.choice == .seconds(8))
        #expect(RefinePopupTimeouts.standard.work == .seconds(20))
        #expect(RefinePopupTimeouts.standard.failureDwell == .seconds(6))
    }

    // MARK: - Geometry sanity

    @Test("Every key row fits inside the panel")
    func rowsFitThePanel() {
        // The legend column is derived by subtracting the cap's own padding from the panel's content
        // width, so this is the one arithmetic slip that would push a row past the panel edge.
        let row = RefinePopupMetrics.digitWidth
            + D.space.sm * 2
            + D.border.hairline
            + RefinePopupMetrics.legendWidth
            + D.space.md * 2
            + 2
        #expect(row <= RefinePopupMetrics.contentWidth)
        #expect(RefinePopupMetrics.legendWidth > 0)
        #expect(RefinePopupMetrics.contentWidth < RefinePopupMetrics.panelWidth)
    }

    // MARK: - Proof sheets

    /// Renders the three states in both appearances to PNGs for a human (or an agent with the Read
    /// tool) to look at. Off by default: it writes files and needs a window server.
    ///
    /// `EDICT_RENDER_POPUP=1 EDICT_RENDER_DIR=<dir> swift test --filter renderProofSheets`
    @Test("Proof sheets render", .enabled(if: ProcessInfo.processInfo.environment["EDICT_RENDER_POPUP"] == "1"))
    @MainActor
    func renderProofSheets() throws {
        let directory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["EDICT_RENDER_DIR"]
                ?? NSTemporaryDirectory(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let nsAppearance = NSAppearance(named: appearance) else { continue }
            for sheet in RefinePopupFixtures.sheets {
                // The tokens resolve through `NSColor(name:dynamicProvider:)`, which reads the
                // *current drawing appearance* — not SwiftUI's `colorScheme` — so both have to be
                // set or the dark sheet comes back in light colours.
                var image: NSImage?
                nsAppearance.performAsCurrentDrawingAppearance {
                    let renderer = ImageRenderer(
                        content: sheet.view.environment(\.colorScheme, name == "dark" ? .dark : .light)
                    )
                    renderer.scale = 2
                    image = renderer.nsImage
                }
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else {
                    Issue.record("could not rasterise \(sheet.id) \(name)")
                    continue
                }
                try png.write(to: directory.appendingPathComponent("popup-\(sheet.id)-\(name).png"))
            }
        }
    }
}
