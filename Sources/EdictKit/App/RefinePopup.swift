import AppKit
import ApplicationServices
import Carbon.HIToolbox   // kVK_Escape, kVK_ANSI_1 … — physical key positions, see `RefinePopupKey`
import CoreGraphics
import Foundation
import SwiftUI

// MARK: - What the popup is showing

/// The three things the popup can be showing. There is no fourth, and in particular there is no
/// empty state: a panel that is on screen showing nothing is the failure this enum exists to
/// prevent. Every path out of ``choosing`` leads either off screen or to one of the other two.
public enum RefinePopupState: Sendable, Hashable {
    /// The three keys. The only state that accepts a choice.
    case choosing
    /// The model is running on the chosen action. Measured at 0.84–1.24 s (RECON, "On-device text
    /// refinement"), so this is seen on *every* use — it is a first-class state, not an edge case.
    case working(RefinementAction)
    /// One finished sentence saying what went wrong. Closes itself after
    /// ``RefinePopupTimeouts/failureDwell``.
    case failed(String)
}

// MARK: - How a session ends

/// The single value a presented popup hands back. Exactly one of these is delivered per
/// presentation — see ``RefinePopupSession`` for the invariant and the tests that pin it.
public enum RefinePopupOutcome: Sendable, Hashable {
    /// The user picked an action. The panel has already moved to ``RefinePopupState/working(_:)``
    /// by the time this is delivered, so the caller does not have to remember to do it.
    case chose(RefinementAction)
    /// No action was picked, for the stated reason.
    case dismissed(RefinePopupDismissal)
}

/// Why a popup went away without a choice. Distinct cases because they mean different things to the
/// caller: `escape` and `clickedOutside` are the user saying no, `timedOut` and
/// `frontmostAppChanged` are the user having moved on, and `cancelled` is Edict's own doing.
public enum RefinePopupDismissal: String, Sendable, Hashable {
    case escape
    case clickedOutside
    case frontmostAppChanged
    case timedOut
    /// Edict closed the popup itself — a second presentation took the panel over, or the caller
    /// called ``RefinePopupController/close()`` before a choice was made.
    case cancelled
}

// MARK: - Keys

/// The keys the popup answers to, resolved from a `CGEventTap`'s raw keycode.
///
/// **Why a keycode and not a character.** The panel cannot become key (see ``RefinePanel``), so it
/// never receives an `NSEvent`; the only source of keystrokes is Edict's existing global event tap,
/// which reports `CGKeyCode` plus raw flags. Mapping the *position* — rather than resolving the
/// character through `UCKeyTranslate` as the synthetic Cmd-V must (RECON §15) — is the correct
/// choice here and not a shortcut: the panel prints the numeral that is screen-printed on the key
/// cap in front of the user, and on every layout Edict can be used with, the key labelled `1` is
/// keycode 18 even where unshifted it types `&`. The destructive risk that made §15 a rule cannot
/// arise either, because nothing is posted — three keycodes are read, and only while the panel is up.
public enum RefinePopupKey: Sendable, Hashable {
    /// A number key, 1-based, from either the top row or the numeric keypad.
    case digit(Int)
    /// Escape.
    case escape

    /// Map a tap's `(keyCode, rawFlags)` to a popup key, or `nil` for everything else.
    ///
    /// **Flags are bit-tested, never compared** (RECON amendment 31: this machine's Karabiner
    /// stamps `0x100` on every synthesized event, so an equality test against an expected raw word
    /// silently never fires).
    ///
    /// `command` and `control` disqualify the key: `⌘1` is "first tab" in every browser and
    /// `⌃1` is a Space switch, and swallowing those while the panel happens to be up would be a
    /// bug in the user's *other* app. `shift`, `option`, `fn` and caps lock deliberately do **not**
    /// disqualify it — the popup's own chord is `fn`+`⌥`, and a user who has not yet let go of it
    /// must still be able to choose.
    public static func key(keyCode: Int64, rawFlags: UInt64) -> RefinePopupKey? {
        let blocked = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
        guard rawFlags & blocked == 0 else { return nil }
        switch Int(keyCode) {
        case kVK_Escape: return .escape
        case kVK_ANSI_1, kVK_ANSI_Keypad1: return .digit(1)
        case kVK_ANSI_2, kVK_ANSI_Keypad2: return .digit(2)
        case kVK_ANSI_3, kVK_ANSI_Keypad3: return .digit(3)
        default: return nil
        }
    }
}

// MARK: - Timeouts

/// Every self-closing deadline in one place, so none of them is a number buried in a `Task`.
public struct RefinePopupTimeouts: Sendable, Hashable {

    /// How long the three keys wait for a choice.
    ///
    /// **Why there is a deadline at all.** While the popup is up it eats `1`, `2`, `3` and `Esc`
    /// out of the global tap. A popup left open by a missed keystroke, a user who walked away, or a
    /// click Edict never saw would therefore break plain typing in the app underneath — the worst
    /// failure this feature can have. Eight seconds is far longer than the ~2 s it takes to read
    /// three legends and press a number, and short enough that a stuck panel is a blip.
    public var choice: Duration
    /// A watchdog on the model, not a cancellation. Refinement measures 0.84–1.24 s warm; twenty
    /// seconds means the model is wedged, and the panel says so rather than sitting there.
    public var work: Duration
    /// How long a failure sentence stays. One sentence is read in about two; six seconds allows for
    /// looking away and back, and needs no dismissal gesture.
    public var failureDwell: Duration

    public static let standard = RefinePopupTimeouts(
        choice: .seconds(8),
        work: .seconds(20),
        failureDwell: .seconds(6)
    )

    public init(choice: Duration, work: Duration, failureDwell: Duration) {
        self.choice = choice
        self.work = work
        self.failureDwell = failureDwell
    }
}

// MARK: - Anchor

/// Where the popup should appear, in **Cocoa** screen coordinates (origin bottom-left, y up).
///
/// Two cases because the two are placed differently: a selection has a box to sit under, a mouse
/// location has only a point. Both are already converted; see ``fromQuartz(_:primaryMaxY:)`` for
/// the one conversion the Accessibility API forces on us.
public enum RefinePopupAnchor: Sendable, Hashable {
    /// The union of the selection's (or the caret's) bounds.
    case selection(CGRect)
    /// The pointer. The fallback for every app that will not tell us where its text is.
    case point(CGPoint)

    /// The point the panel is hung from: the bottom-left of a selection, or the pointer itself.
    var focus: CGPoint {
        switch self {
        case .selection(let rect): CGPoint(x: rect.minX, y: rect.minY)
        case .point(let point): point
        }
    }

    /// The y the panel flips *above* to when there is no room below.
    var topEdge: CGFloat {
        switch self {
        case .selection(let rect): rect.maxY
        case .point(let point): point.y
        }
    }

    /// Convert an Accessibility rect to an anchor.
    ///
    /// `kAXBoundsForRangeParameterizedAttribute` answers in Quartz global coordinates — origin at
    /// the **top-left of the primary display**, y increasing downward — while `NSWindow.setFrame`
    /// wants Cocoa coordinates with y increasing upward. Getting this wrong does not look like a
    /// coordinate bug: on a single 1080-tall display the panel appears mirrored about the middle of
    /// the screen, which reads as "it opens in the wrong place sometimes".
    public static func fromQuartz(_ rect: CGRect, primaryMaxY: CGFloat) -> RefinePopupAnchor {
        .selection(
            CGRect(
                x: rect.minX,
                y: primaryMaxY - rect.maxY,
                width: rect.width,
                height: rect.height
            )
        )
    }
}

// MARK: - Placement

/// One display, as much of it as placement needs. A value type so the arithmetic can be tested
/// against synthetic screens — including the negative-origin second display this machine has.
struct RefineScreen: Sendable, Hashable {
    /// Full bounds, used to decide *which* screen the anchor is on.
    var frame: CGRect
    /// Bounds minus the menu bar and the Dock, used to decide where the panel fits.
    var visibleFrame: CGRect

    init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    @MainActor
    static var current: [RefineScreen] {
        NSScreen.screens.map { RefineScreen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
    }
}

/// Pure placement arithmetic: given an anchor, a panel size and the displays, where does the panel
/// go. Separated from AppKit so all of it is testable, which matters because every one of these
/// cases is a real machine — this user has two displays and a window manager that moves windows
/// (RECON amendment 30).
enum RefinePopupPlacement {

    /// Gap between the text and the panel. Big enough that the panel does not touch the glyphs it
    /// refers to, small enough that it is clearly attached to them.
    static var gap: CGFloat { D.space.sm }
    /// Minimum distance from a screen edge, so the panel never sits flush against the bezel.
    static var margin: CGFloat { D.space.sm }

    /// The frame to give the panel, in Cocoa screen coordinates.
    static func frame(for anchor: RefinePopupAnchor, size: CGSize, screens: [RefineScreen]) -> CGRect {
        guard let screen = screen(containing: anchor.focus, in: screens) else {
            // No displays at all is not a real configuration, but returning something placed at
            // the anchor is better than returning `.zero`, which would park the panel in a corner.
            return CGRect(origin: anchor.focus, size: size)
        }
        let visible = screen.visibleFrame

        // Below the text by default, the way a completion list sits below the caret: it does not
        // cover the words the user is about to have rewritten.
        var origin = CGPoint(x: anchor.focus.x, y: anchor.focus.y - gap - size.height)

        // Not enough room below — flip above the selection rather than overlapping it.
        if origin.y < visible.minY + margin {
            let above = anchor.topEdge + gap
            origin.y = above + size.height + margin <= visible.maxY
                ? above
                // No room either side: sit as high as the screen allows and accept the overlap.
                // `max` with the bottom edge keeps a panel taller than the screen on screen at the
                // top, which is where its heading is.
                : max(visible.maxY - size.height - margin, visible.minY + margin)
        }

        origin.x = clamp(
            origin.x,
            low: visible.minX + margin,
            high: visible.maxX - size.width - margin
        )
        origin.y = clamp(
            origin.y,
            low: visible.minY + margin,
            high: visible.maxY - size.height - margin
        )
        return CGRect(origin: origin, size: size)
    }

    /// The display holding `point`; if none does — the pointer can sit in the dead space between two
    /// mismatched displays, and an AX rect from an app that lies can land anywhere — the nearest one.
    /// Never `NSScreen.main`: that follows the key window, and Edict deliberately has none.
    static func screen(containing point: CGPoint, in screens: [RefineScreen]) -> RefineScreen? {
        if let hit = screens.first(where: { $0.frame.contains(point) }) { return hit }
        return screens.min { a, b in
            squaredDistance(from: point, to: a.frame) < squaredDistance(from: point, to: b.frame)
        }
    }

    /// Keeps a panel wider or taller than the space on screen anchored to the low edge rather than
    /// letting the clamp invert and push it off the other side.
    private static func clamp(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        high < low ? low : min(max(value, low), high)
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = point.x < rect.minX ? rect.minX - point.x : max(0, point.x - rect.maxX)
        let dy = point.y < rect.minY ? rect.minY - point.y : max(0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

// MARK: - Session

/// One presentation of the popup: its state, its deadlines, and the **resolve-exactly-once**
/// guarantee. Holds no AppKit, so every rule in here is testable.
///
/// **Why exactly-once is the central invariant.** The outcome starts a refinement and a replacement
/// of the user's selected text. A second delivery would refine twice and paste twice — and the
/// second paste would land in text that had already been replaced, so it is not merely wasteful, it
/// corrupts the document. The competing paths are real and can arrive in the same run loop turn: the
/// user can press `1` at the moment the choice deadline fires, and clicking outside can activate
/// another app, which raises the click and the frontmost-app change together.
@MainActor
final class RefinePopupSession {

    private(set) var state: RefinePopupState = .choosing
    /// Set to nil by the first resolution; that is the whole mechanism.
    private var deliver: ((RefinePopupOutcome) -> Void)?
    private let onState: (RefinePopupState) -> Void
    private let onClose: () -> Void
    private let timeouts: RefinePopupTimeouts
    private var deadline: Task<Void, Never>?
    private var isClosed = false

    var isResolved: Bool { deliver == nil }

    init(
        timeouts: RefinePopupTimeouts = .standard,
        onState: @escaping (RefinePopupState) -> Void = { _ in },
        onClose: @escaping () -> Void = {},
        deliver: @escaping (RefinePopupOutcome) -> Void
    ) {
        self.timeouts = timeouts
        self.onState = onState
        self.onClose = onClose
        self.deliver = deliver
    }

    /// Arms the choice deadline. Separate from `init` so a test can drive the state machine without
    /// a live clock.
    func start() {
        arm(timeouts.choice) { [weak self] in self?.dismiss(.timedOut) }
    }

    // MARK: Choosing

    /// Feed a key from the global event tap. Returns whether the popup consumed it.
    ///
    /// A key is consumed **only** in the state that can act on it, so a stray `2` during the ~1 s
    /// working state reaches the app underneath instead of vanishing.
    func handle(_ key: RefinePopupKey) -> Bool {
        // A resolved or closed session consumes nothing. Without this, a `1` that raced the click
        // which had already taken the panel away would be *reported as consumed* — the tap would
        // swallow it, and the digit the user meant for their own document would vanish. The
        // `isResolved` guard is the same rule stated for the case where the panel is still up.
        guard !isClosed else { return false }
        switch (state, key) {
        case (.choosing, .digit(let n)):
            guard !isResolved, let action = Self.action(forDigit: n) else { return false }
            choose(action)
            return true
        case (.choosing, .escape):
            guard !isResolved else { return false }
            dismiss(.escape)
            return true
        case (.failed, .escape):
            // Nothing left to resolve; this just takes the sentence away early.
            close()
            return true
        case (.working, _), (.failed, .digit):
            return false
        }
    }

    /// The digit-to-action map. Derived from `RefinementAction.allCases` rather than written out, so
    /// the keys the panel prints and the keys it obeys cannot drift apart — or from the engine.
    ///
    /// `nonisolated` because it is a pure lookup over a compile-time list: the view draws the digit
    /// from it and the session obeys it, and neither should have to hop an actor for a table.
    nonisolated static func action(forDigit digit: Int) -> RefinementAction? {
        let all = RefinementAction.allCases
        guard digit >= 1, digit <= all.count else { return nil }
        return all[digit - 1]
    }

    /// The digit printed on an action's key. The inverse of ``action(forDigit:)``.
    nonisolated static func digit(for action: RefinementAction) -> Int? {
        RefinementAction.allCases.firstIndex(of: action).map { $0 + 1 }
    }

    func choose(_ action: RefinementAction) {
        // The move to `working` happens here, not in the caller: leaving the three keys on screen
        // while the model runs would offer a second choice the session can no longer honour.
        guard resolve(.chose(action)) else { return }
        transition(to: .working(action))
        arm(timeouts.work) { [weak self] in
            self?.fail(
                "Refining is taking longer than expected. If it finishes, the text will still be "
                    + "replaced."
            )
        }
    }

    func dismiss(_ reason: RefinePopupDismissal) {
        guard resolve(.dismissed(reason)) else { return }
        close()
    }

    // MARK: Working and after

    /// Show one sentence and start the dwell. Safe to call after any outcome.
    func fail(_ sentence: String) {
        guard !isClosed else { return }
        // A failure that arrives before a choice still has an outcome owed to the caller.
        _ = resolve(.dismissed(.cancelled))
        transition(to: .failed(sentence))
        arm(timeouts.failureDwell) { [weak self] in self?.close() }
    }

    /// Take the panel away. Idempotent, and resolves as `cancelled` if nothing else has.
    func close() {
        _ = resolve(.dismissed(.cancelled))
        guard !isClosed else { return }
        isClosed = true
        deadline?.cancel()
        deadline = nil
        onClose()
    }

    // MARK: Machinery

    /// The one place `deliver` is read and cleared. Returns false when someone got there first,
    /// which every caller treats as "do nothing further".
    @discardableResult
    private func resolve(_ outcome: RefinePopupOutcome) -> Bool {
        guard let deliver else { return false }
        self.deliver = nil
        deliver(outcome)
        return true
    }

    private func transition(to next: RefinePopupState) {
        guard !isClosed else { return }
        state = next
        onState(next)
    }

    /// One deadline at a time: arming replaces the previous one, so leaving `choosing` cancels the
    /// choice timeout by construction rather than by remembering to.
    private func arm(_ duration: Duration, _ body: @escaping @MainActor () -> Void) {
        deadline?.cancel()
        deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, self != nil else { return }
            body()
        }
    }
}

// MARK: - The panel

/// The popup's window.
///
/// `canBecomeKey` is a hard `false`, and that is the point of this whole file. The feature replaces
/// the text that is selected **in another application**; if Edict becomes active, that app loses
/// first-responder status, its selection is deselected or forgotten, and the refined text is then
/// replaced into nothing. `.nonactivatingPanel`, `hidesOnDeactivate == false` and
/// `orderFrontRegardless` are the same requirement stated three more times.
///
/// The consequence is that this window can never receive a key event, which is why choices arrive
/// from Edict's global event tap instead — see ``RefinePopupKey``. That needs no new permission: the
/// tap already exists for push-to-talk.
final class RefinePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

/// Shows the popup, places it, and turns the world's attempts to interrupt it into exactly one
/// outcome.
@MainActor
public final class RefinePopupController {

    private let timeouts: RefinePopupTimeouts
    private var panel: RefinePanel?
    private var host: NSHostingView<RefinePopupView>?
    private var session: RefinePopupSession?
    private var mouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    /// The app that owned the selection. Used to tell "the user switched away" from "the user is
    /// still in the same app", because Edict itself never activates and so never fires this.
    private var anchoredAppPID: pid_t?
    /// The screen the panel was placed on, kept so a state change that resizes the panel re-clamps
    /// against the same display instead of re-deciding which one it is on.
    private var placedScreen: RefineScreen?
    /// Top-left of the placed frame. The panel grows and shrinks between states from this corner,
    /// so its heading does not move under the reader's eye.
    private var placedTopLeft: CGPoint?

    public init(timeouts: RefinePopupTimeouts = .standard) {
        self.timeouts = timeouts
    }

    /// Whether a popup is on screen. The integrator's event tap uses this to decide whether to
    /// offer keys to ``handle(keyCode:rawFlags:)`` at all.
    public var isPresented: Bool { session != nil }

    /// The state the panel is showing, for tests and for logging.
    var state: RefinePopupState? { session?.state }

    // MARK: Presenting

    /// Present the three keys near `anchor` and wait for the one outcome.
    ///
    /// The panel is already in ``RefinePopupState/working(_:)`` when this returns `.chose`, so the
    /// caller's next step is simply to run the refinement and then call ``close()`` or
    /// ``showFailure(_:)``.
    ///
    /// A caller that returns `.chose` and then never calls either does **not** leave a panel on
    /// somebody's screen: ``RefinePopupTimeouts/work`` fires, the panel says the model did not
    /// answer, and the dwell takes it away. The rule this file enforces everywhere is that no path
    /// leaves the popup on screen without an owner.
    public func present(anchor: RefinePopupAnchor) async -> RefinePopupOutcome {
        // A second presentation takes the panel over rather than queueing behind the first: the
        // first one's selection is stale by definition, since the user has pressed the chord again.
        session?.close()

        return await withCheckedContinuation { continuation in
            let session = RefinePopupSession(
                timeouts: timeouts,
                onState: { [weak self] state in self?.render(state) },
                onClose: { [weak self] in self?.tearDown() },
                deliver: { outcome in continuation.resume(returning: outcome) }
            )
            self.session = session
            show(anchor: anchor)
            session.start()
        }
    }

    /// Replace the working state with one finished sentence, which then closes itself.
    public func showFailure(_ sentence: String) {
        session?.fail(sentence)
    }

    /// Close now. Resolves an unresolved presentation as ``RefinePopupDismissal/cancelled``.
    public func close() {
        session?.close()
    }

    /// Feed a key from the global event tap; returns whether the popup consumed it.
    @discardableResult
    public func handle(keyCode: Int64, rawFlags: UInt64) -> Bool {
        guard let session, let key = RefinePopupKey.key(keyCode: keyCode, rawFlags: rawFlags) else {
            return false
        }
        return session.handle(key)
    }

    // MARK: Window

    private func show(anchor: RefinePopupAnchor) {
        let panel = panel ?? makePanel()
        self.panel = panel
        render(.choosing)
        place(anchor: anchor)
        anchoredAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        startWatchingForInterruptions()
        // Never `makeKeyAndOrderFront`: that activates Edict and loses the selection.
        panel.orderFrontRegardless()
    }

    private func tearDown() {
        stopWatchingForInterruptions()
        panel?.orderOut(nil)
        session = nil
        anchoredAppPID = nil
        placedScreen = nil
        placedTopLeft = nil
    }

    private func makePanel() -> RefinePanel {
        let panel = RefinePanel(
            contentRect: NSRect(x: 0, y: 0, width: RefinePopupMetrics.panelWidth, height: RefinePopupMetrics.panelWidth),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false            // drawn in SwiftUI from `D.shadow.hud`
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isReleasedWhenClosed = false
        // Unlike the recording HUD, this panel *is* interactive: a click on a row picks that action.
        panel.ignoresMouseEvents = false
        panel.setAccessibilityLabel("Refine selection")
        // Subrole, not role: it is still a window, and rewriting `AXWindow` to `AXPopover` would take
        // it out of VoiceOver's window navigation altogether. The floating subrole is what this
        // actually is. Note that the digit keys — not this panel — are the accessible path to a
        // choice, because a non-activating panel belonging to a background app is hard to reach with
        // the VoiceOver cursor, and that is a consequence of never taking focus, not an oversight.
        panel.setAccessibilitySubrole(.systemFloatingWindow)

        let host = NSHostingView(rootView: RefinePopupView(state: .choosing, choose: { [weak self] in
            self?.session?.choose($0)
        }))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.host = host
        return panel
    }

    /// Push a new state into the view and resize the panel around it.
    private func render(_ state: RefinePopupState) {
        guard let host, let panel else { return }
        host.rootView = RefinePopupView(state: state, choose: { [weak self] in
            self?.session?.choose($0)
        })
        resize(panel, to: CGSize(width: RefinePopupMetrics.panelWidth, height: measuredHeight()))
    }

    /// The panel's height for the state currently in the view.
    ///
    /// `fittingSize` is the right question to ask an `NSHostingView` — the root view fixes its own
    /// width, so the answer is the wrapped height — but it can come back degenerate before the view
    /// has laid out, and a zero-height panel is an invisible popup with no error anywhere. Hence the
    /// explicit layout pass, `intrinsicContentSize` as a backstop, and a square panel as the last
    /// resort: too tall is a cosmetic bug, absent is a broken feature.
    private func measuredHeight() -> CGFloat {
        guard let host else { return RefinePopupMetrics.panelWidth }
        host.layoutSubtreeIfNeeded()
        if host.fittingSize.height > 1 { return host.fittingSize.height }
        if host.intrinsicContentSize.height > 1 { return host.intrinsicContentSize.height }
        Log.engine.error("refine popup measured no height; falling back to a square panel")
        return RefinePopupMetrics.panelWidth
    }

    /// Grow or shrink from the top-left, then re-clamp to the display the panel was placed on. A
    /// panel that grew downward past the Dock, or that jumped upward when the failure sentence
    /// wrapped to a third line, would read as a bug in the app underneath.
    private func resize(_ panel: RefinePanel, to size: CGSize) {
        let height = max(size.height, 1)
        guard let topLeft = placedTopLeft else {
            panel.setContentSize(CGSize(width: RefinePopupMetrics.panelWidth, height: height))
            return
        }
        var frame = CGRect(
            x: topLeft.x,
            y: topLeft.y - height,
            width: RefinePopupMetrics.panelWidth,
            height: height
        )
        if let visible = placedScreen?.visibleFrame {
            frame.origin.y = max(frame.origin.y, visible.minY + RefinePopupPlacement.margin)
            frame.origin.y = min(frame.origin.y, visible.maxY - height - RefinePopupPlacement.margin)
        }
        panel.setFrame(frame, display: true)
    }

    private func place(anchor: RefinePopupAnchor) {
        guard let panel else { return }
        let size = CGSize(width: RefinePopupMetrics.panelWidth, height: measuredHeight())
        let screens = RefineScreen.current
        let frame = RefinePopupPlacement.frame(for: anchor, size: size, screens: screens)
        placedScreen = RefinePopupPlacement.screen(containing: anchor.focus, in: screens)
        placedTopLeft = CGPoint(x: frame.minX, y: frame.maxY)
        panel.setFrame(frame, display: false)
    }

    // MARK: Interruptions

    private func startWatchingForInterruptions() {
        // A click anywhere else means the user is doing something other than choosing. Global
        // monitors only see events destined for *other* applications, so a click on the panel's own
        // rows never arrives here — the frame test below is belt and braces.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let session = self.session else { return }
                let location = event.locationInWindow    // already screen coordinates: no window
                if let frame = self.panel?.frame, frame.contains(location) { return }
                session.dismiss(.clickedOutside)
            }
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let session = self.session else { return }
                // Edict never activates while the popup is up, so this fires only for a genuine
                // switch — but the anchored pid is checked anyway, because a `didActivate` for the
                // app we are already anchored to is not a switch.
                guard pid != self.anchoredAppPID else { return }
                session.dismiss(.frontmostAppChanged)
            }
        }
    }

    private func stopWatchingForInterruptions() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
    }
}

// MARK: - Finding the text

/// Where the caret or the selection actually is, asked of the focused application through the
/// Accessibility API, with the pointer as the fallback.
///
/// **Why the pointer is a first-class fallback and not a failure.** `kAXSelectedTextRangeAttribute`
/// and `kAXBoundsForRangeParameterizedAttribute` answer in native text views and answer nothing
/// useful in Electron apps and terminals (RECON, "Text injection at the cursor": AX read support is
/// as uneven as AX write support). Those are exactly the apps this feature is most used in, so the
/// popup has to look right when the answer never comes.
public enum RefineAnchorResolver {

    /// AX round trips are bounded hard, because this runs on the main actor: the framework default
    /// is 6 s, and one unresponsive app would otherwise freeze Edict's UI while the user waits for a
    /// popup. A quarter second is ~8x the slowest measured system-wide AX read (31–42 ms cold).
    static let axTimeout: Float = 0.25

    /// The anchor to present at. Never fails: the pointer is always somewhere.
    @MainActor
    public static func anchor() -> RefinePopupAnchor {
        selectionAnchor() ?? .point(NSEvent.mouseLocation)
    }

    /// The selection's bounds, or nil if this app will not say.
    @MainActor
    static func selectionAnchor() -> RefinePopupAnchor? {
        // Gate on the permission explicitly. RECON: an untrusted process gets `cannotComplete` from
        // the system-wide element rather than `apiDisabled`, so an error code cannot tell us this.
        guard AXIsProcessTrusted() else { return nil }
        guard let primaryMaxY = NSScreen.screens.first?.frame.maxY else { return nil }

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, axTimeout)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focused
        ) == .success, let focused else { return nil }
        guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeDowncast(focused, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, axTimeout)

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeValue
        ) == .success, let rangeValue,
            CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }

        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &bounds
        ) == .success, let bounds, CFGetTypeID(bounds) == AXValueGetTypeID() else { return nil }

        var rect = CGRect.zero
        let value = unsafeDowncast(bounds, to: AXValue.self)
        guard AXValueGetType(value) == .cgRect,
              withUnsafeMutablePointer(to: &rect, { AXValueGetValue(value, .cgRect, $0) })
        else { return nil }

        // A collapsed caret legitimately has zero width; a zero-*height* rect means the app
        // answered with nothing useful, and hanging the panel off it would put it at the top-left
        // of the primary display. `isNull` catches the CGRectNull some apps return outright.
        guard !rect.isNull, rect.height > 0 else { return nil }
        return .fromQuartz(rect, primaryMaxY: primaryMaxY)
    }
}
