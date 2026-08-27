import AppKit
import ApplicationServices
import Carbon.HIToolbox   // UCKeyTranslate, TISCopyCurrent*, LMGetKbdType, IsSecureEventInputEnabled
import CoreGraphics
import Foundation

// MARK: - Public surface

/// What was selected in another application, and how Edict managed to find out.
///
/// `route` is not diagnostics decoration. The answer differs per app — a native `NSTextView` hands the
/// selection over through Accessibility, Chromium and terminals do not — and the popup wants to be able
/// to say which happened, because the two routes have different failure modes: the Accessibility route
/// cannot be contaminated by held modifiers, and the pasteboard route momentarily borrows the user's
/// clipboard.
public struct SelectionSnapshot: Sendable, Hashable {
    public var text: String
    public var target: InjectionTarget
    public var route: Route

    public enum Route: String, Sendable, Hashable {
        /// `kAXSelectedTextAttribute` on the focused element answered.
        case accessibility
        /// A synthetic Cmd-C into a saved-and-restored pasteboard answered.
        case pasteboard
    }

    public init(text: String, target: InjectionTarget, route: Route) {
        self.text = text
        self.target = target
        self.route = route
    }
}

/// Every way reading a selection out of another app can fail, each carrying one finished sentence.
///
/// The two cases beyond the original sketch — ``modifiersHeld`` and ``selectionTooLong`` — are here
/// because both are real, reachable, and need their own actionable sentence:
///
/// * `modifiersHeld` is intrinsic to this feature's gesture. The popup is opened by *holding* a chord,
///   so at the moment Edict wants to post a synthetic Cmd-C the user's fingers may still be on `fn` and
///   `⌥`, and Cmd-fn-Option-C is not a copy. It is raised only *after* a copy has actually been tried
///   and produced nothing, never as a pre-emptive refusal — see the measurement note in
///   ``SelectionBridge`` on why `flagsState` cannot be trusted to gate the attempt.
/// * `selectionTooLong` stops a whole document from being copied around and handed to a ~3B on-device
///   model that would quietly truncate it. It is a *coarse* gate in front of `TextRefiner`'s exact,
///   token-measured `RefinementFailure.tooLong` — not a second opinion about the context window.
public enum SelectionError: Error, Sendable, Hashable, LocalizedError {
    /// Nothing at all has keyboard focus — no frontmost application.
    case noFocusedElement
    /// Focus exists, but neither route found any selected text.
    case nothingSelected
    /// Accessibility, PostEvent, or secure input keeps Edict out. The string names which.
    case notPermitted(String)
    /// The chord that opened the popup is still physically held, so a synthetic Cmd-C cannot be sent.
    case modifiersHeld
    /// The Cmd-C could not be constructed or posted, or the copy produced no text flavor.
    case copyFailed
    /// More text than refinement can hold. Counts are UTF-16 code units.
    case selectionTooLong(units: Int, limit: Int)
    /// Reserved for the replace half when it is surfaced as a thrown error rather than an outcome.
    case replaceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noFocusedElement:
            "No app has the keyboard right now, so there is no selection to refine."
        case .nothingSelected:
            "Select some text first — Edict could not find anything selected in the app in front."
        case .notPermitted(let why):
            why
        case .modifiersHeld:
            "Let go of the shortcut keys and try again — Edict cannot copy the selection while they are held."
        case .copyFailed:
            "Edict could not copy the selection out of that app. Copy it yourself and try again."
        case .selectionTooLong(let units, let limit):
            "That selection is about \(units) characters and refinement handles about \(limit) at a time. "
                + "Select a shorter passage."
        case .replaceFailed(let why):
            why
        }
    }
}

// MARK: - SelectionBridge

/// Reads whatever is selected in the frontmost app, and puts refined text back in its place.
///
/// This is the part of the popup most likely to fail *silently*, so nothing here trusts a return code.
/// RECON §14 measured `CGEvent.post` returning `Void` and dropping the event without a word, and the
/// Accessibility API reporting `kAXErrorSuccess` on writes it ignores; read support is just as uneven
/// (RECON line 298 left "does an ignoring element still return success?" as the project's central open
/// question). So both halves are two-route ladders whose every rung is proved by reading the target's
/// own values back, and both report which route actually won.
///
/// **Never lose the user's text** is the load-bearing rule. A replace that cannot be *proved* leaves the
/// refined text on the clipboard and says so in the returned ``InjectionOutcome``, and it never runs a
/// second write that might land on top of a first one that already did.
///
/// Isolation: its own serial dispatch queue, not the shared cooperative pool — same reasoning as
/// `TextInjector`. AX round trips, the settle floor and the change poll all block for tens to hundreds
/// of milliseconds, and a custom executor is also what lets the actor hold the long-lived, non-`Sendable`
/// `CGEventSource` that RECON §26 asks for.
public actor SelectionBridge {

    private let queue = DispatchSerialQueue(label: "com.edict.selection", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// The replace half is `TextInjector`'s, whole: its verified paste, its byte-lossless pasteboard
    /// snapshot/restore, its layout-resolved Cmd-V and its learned per-bundle policy. This bridge adds a
    /// selection-shaped Accessibility rung in front of it and otherwise gets out of the way.
    private let injector: TextInjector

    /// One source for the bridge's lifetime. RECON §26: the *first* `CGEvent(keyboardEventSource:)` in a
    /// process costs 44–50 ms and 0.00 ms thereafter. Paying that inside the popup's first Cmd-C would
    /// also widen the window in which the target app has not yet read the pasteboard.
    private var eventSource: CGEventSource?
    private var warmed = false

    public init(injector: TextInjector) {
        self.injector = injector
    }

    // MARK: Warm-up

    /// Pay the cold costs off the hot path: the event source, the trust check, one throwaway AX read and
    /// the main-actor keyboard-layout scan. Additive to the sketched API and safe to skip — every entry
    /// point calls it — but calling it at launch is what keeps the first popup from feeling slow.
    public func prewarm() async {
        guard !warmed else { return }
        warmed = true

        let source = CGEventSource(stateID: .privateState)
        // Property setter, not a static func (RECON, verified against CoreGraphics.apinotes). The
        // measured 0.25 s default would suppress the user's real keyboard after every synthetic Cmd-C.
        source?.localEventsSuppressionInterval = 0.0
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        eventSource = source

        if let source { _ = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) }
        _ = AXIsProcessTrusted()
        _ = SelectionAX.focused()
        // RECON amendment 36: Text Input Services reaches `dispatch_assert_queue(main)` and SIGTRAPs
        // rather than erroring, so every touch of it has to hop to the main actor first.
        _ = await MainActor.run { SelectionKeycodes.cKeyCode() }
        Log.inject.debug("selection bridge pre-warmed")
    }

    // MARK: Read

    /// Read whatever is selected in the frontmost app.
    ///
    /// Accessibility first, because it posts no events at all: it cannot be contaminated by the held
    /// chord, it does not touch the user's clipboard, and it costs one AX round trip. An empty or
    /// unsupported answer is a **miss**, not "nothing selected" — Chromium, Monaco and every terminal
    /// return exactly that with text plainly selected on screen — so it falls through rather than
    /// reporting a failure the user can see is wrong.
    public func readSelection() async throws -> SelectionSnapshot {
        await prewarm()

        guard NSWorkspace.shared.frontmostApplication != nil else {
            throw SelectionError.noFocusedElement
        }
        let target = TextInjector.currentTarget()
        if let closed = Self.closedGate() { throw SelectionError.notPermitted(closed) }

        // Rung 1: Accessibility.
        if let focus = SelectionAX.focused() {
            if let raw = SelectionAX.selectedText(focus.element), let text = Self.usable(raw) {
                try Self.checkLength(text)
                Log.inject.info("""
                    AX selection read from \(target.appName ?? "?", privacy: .public) \
                    (\(text.utf16.count) UTF-16 units)
                    """)
                return SelectionSnapshot(text: text, target: target, route: .accessibility)
            }
            Log.inject.debug("""
                AX selection read missed in \(target.appName ?? "?", privacy: .public); \
                role=\(focus.role ?? "?", privacy: .public)
                """)
        } else {
            Log.inject.debug("no focused AX element; going straight to the copy route")
        }

        // Rung 2: synthetic Cmd-C into a saved-and-restored pasteboard.
        let text = try await copySelection()
        try Self.checkLength(text)
        Log.inject.info("""
            selection copied from \(target.appName ?? "?", privacy: .public) \
            (\(text.utf16.count) UTF-16 units)
            """)
        return SelectionSnapshot(text: text, target: target, route: .pasteboard)
    }

    /// Snapshot → baseline `changeCount` → Cmd-C → floor → poll → read → restore.
    ///
    /// RECON §16 forbids a fixed sleep before restoring the clipboard, and the reasoning applies with the
    /// sign flipped here: on a *copy* the change is the thing being waited for, so `changeCount` is the
    /// success signal rather than the veto. It moves on every write, including a copy of text identical
    /// to what is already on the clipboard, which is what makes it usable as one.
    private func copySelection() async throws -> String {
        // The popup's gesture is a *held* chord, so this wait is not a formality. RECON §27:
        // `.combinedSessionState`, never `.privateState`, which blocks for ever.
        //
        // **Measured, and it is why this is a warning rather than a refusal.** On this machine
        // `flagsState(.combinedSessionState)` reports `maskCommand` set for many seconds at a stretch —
        // repeatedly past a 3 s poll — with no key physically down and `./flags` reading 0x00000000 a
        // moment later. (This machine runs Karabiner-Elements with a virtual keyboard and 729 event taps;
        // RECON amendment 31 already found it stamping flags onto every event it synthesizes.) A hard
        // refusal keyed on that reading would make the feature fail for seconds at a time for no reason.
        //
        // Proceeding is safe because the posted event's flags are *assigned*, not OR-ed, so the target
        // receives exactly Command-C, and because this route is self-verifying: a contaminated shortcut
        // moves no `changeCount` and comes back as a miss rather than as wrong text. None of the
        // plausible contaminations (Cmd-Shift-C, Cmd-Option-C) is destructive in a text field.
        let modifiers = Self.waitForCleanModifiers()
        if modifiers.stillHeld {
            Log.inject.notice("""
                modifiers still reported held after \(modifiers.waitedMs) ms; posting Cmd-C anyway \
                (flagsState is not trustworthy on this machine — measured latched with no key down)
                """)
        }

        let saved = SelectionPasteboard.snapshot()
        let baseline = NSPasteboard.general.changeCount

        guard await postCommandC() else { throw SelectionError.copyFailed }

        // A floor before the poll: RECON §16 measured no app servicing a paste faster than this, and a
        // copy is the same run-loop hop in the other direction.
        usleep(UInt32(Self.settleFloorMs) * 1000)
        var copied: String?
        var waited = Self.settleFloorMs
        while waited < Self.copyTimeoutMs {
            if NSPasteboard.general.changeCount != baseline {
                copied = NSPasteboard.general.string(forType: .string)
                break
            }
            usleep(UInt32(Self.pollStepMs) * 1000)
            waited += Self.pollStepMs
        }

        // Restore only if somebody wrote — if `changeCount` never moved, the user's clipboard was never
        // touched and restoring would bump it for nothing.
        if NSPasteboard.general.changeCount != baseline {
            _ = SelectionPasteboard.restore(saved)
        }

        guard let copied, let text = Self.usable(copied) else {
            // Indistinguishable from here: nothing was selected, or the app ignored Cmd-C. "Select some
            // text first" is the sentence that helps in the overwhelmingly more common case — *unless*
            // modifiers really were held, in which case letting go is the actionable advice and this is
            // the only place it can honestly be offered, because by now the copy has actually been tried.
            Log.inject.notice("Cmd-C produced no text after \(waited) ms")
            throw modifiers.stillHeld ? SelectionError.modifiersHeld : SelectionError.nothingSelected
        }
        return text
    }

    private func postCommandC() async -> Bool {
        // RECON §15: never hardcode the keycode. On some layouts Cmd-<keycode 8> is not Cmd-C, and a
        // wrong guess here posts an arbitrary command shortcut into the user's app. Resolved fresh every
        // time — the user can switch layout between refinements and the scan costs microseconds.
        let cKey = await MainActor.run { SelectionKeycodes.cKeyCode() }
        guard let source = eventSource ?? CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        else {
            Log.inject.error("could not construct the Cmd-C events")
            return false
        }
        // ASSIGN, never OR. A fresh CGEvent carries an undocumented default flag 0x20000000; assignment
        // leaves exactly maskCommand (RECON, measured). OR-ing would also let the held chord leak in.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    // MARK: Replace

    /// Replace the selection this snapshot came from with `text`, and report how it landed.
    ///
    /// Two rungs, and the fall-through rule is deliberately *stricter* than `TextInjector`'s. An insert
    /// is additive, so re-trying a rung that may have half-worked costs duplicated text at the caret. A
    /// replace is destructive: if an Accessibility write cannot be proved, running the paste after it
    /// risks either replacing text that was already replaced or appending to a collapsed caret. So the
    /// unprovable case stops the ladder and leaves the refined text on the clipboard.
    public func replace(_ snapshot: SelectionSnapshot, with text: String) async -> InjectionOutcome {
        guard !text.isEmpty else { return .notAttempted }
        await prewarm()

        if let closed = Self.closedGate() {
            Log.inject.error("replace gate closed: \(closed, privacy: .public)")
            return leaveOnClipboard(text)
        }

        // The popup is a non-activating panel, so the frontmost app should not have changed — but the
        // user can still click another window while it is open, and pasting into the wrong app is worse
        // than not pasting at all.
        let now = TextInjector.currentTarget()
        guard Self.isSameTarget(snapshot.target, now) else {
            Log.inject.notice("""
                front app moved from \(snapshot.target.bundleID ?? "?", privacy: .public) to \
                \(now.bundleID ?? "?", privacy: .public); not replacing
                """)
            return leaveOnClipboard(text)
        }

        // Rung 1: the learned per-bundle policy is `TextInjector`'s, read through its public accessor
        // rather than duplicated. An app already demoted to paste-only never gets an AX write here
        // either, and a demotion learned here is visible to the dictation path.
        let strategy = await injector.strategy(for: snapshot.target.bundleID)
        if strategy == .axFirst,
           let focus = SelectionAX.focused(),
           SelectionAX.looksReplaceable(focus) {
            switch SelectionAX.replaceSelection(with: text, replacing: snapshot.text, in: focus) {
            case .confirmedReplaced:
                Log.inject.info("AX replace verified in \(snapshot.target.appName ?? "?", privacy: .public)")
                return .accessibility
            case .confirmedNotReplaced:
                await demote(snapshot.target.bundleID, why: "AX replace returned success but nothing changed")
            case .cannotVerify:
                await demote(snapshot.target.bundleID, why: "AX replace is unverifiable on this element")
                // Do NOT fall through. The write may have landed; a paste on top of it would either
                // duplicate the refined text or drop it into a collapsed caret.
                Log.inject.error("""
                    AX replace unverifiable in \(snapshot.target.appName ?? "?", privacy: .public); \
                    leaving the refined text on the clipboard rather than risking a double write
                    """)
                return leaveOnClipboard(text)
            }
        }

        // Rung 2: `TextInjector`'s verified paste, which replaces a selection natively. Reused whole —
        // pasteboard snapshot/restore, the layout-resolved Cmd-V, the fingerprint poll between the post
        // and the restore, and the clipboard-only fallback that keeps the text recoverable.
        return await injector.inject(text, into: snapshot.target)
    }

    private func demote(_ bundleID: String?, why: String) async {
        guard let bundleID else { return }
        await injector.setStrategy(.pasteOnly, for: bundleID)
        Log.inject.notice("selection replace demoted \(bundleID, privacy: .public): \(why, privacy: .public)")
    }

    /// The last resort, and the reason a failed replace never costs the user their words.
    private func leaveOnClipboard(_ text: String) -> InjectionOutcome {
        guard SelectionPasteboard.writeTransient(text) != nil else {
            Log.inject.error("could not even write the refined text to the clipboard")
            return .failed
        }
        Log.inject.notice("refined text left on the clipboard for a manual paste")
        return .clipboardOnly
    }

    // MARK: Pure decisions
    //
    // Factored out so they can be tested without permissions, a focused app, or a running event tap.

    /// UTF-16 units. Coarse on purpose: `TextRefiner` owns the exact, token-measured limit, and this only
    /// has to stop a Cmd-A of a whole document from being copied around and handed to the model at all.
    /// A clean-up has to fit its input *twice* in a ~4k-token window, so anything past this is certainly
    /// beyond refinement and is almost always a mis-aimed select-all.
    static let lengthLimit = 20_000

    static let settleFloorMs = 35
    static let pollStepMs = 20
    /// Longer than `TextInjector`'s 400 ms: a copy has to wait for the target app's own run loop to
    /// service the shortcut, not just to read a pasteboard we already wrote.
    static let copyTimeoutMs = 500
    /// Also longer than the injector's 400 ms, because here the modifiers being held is the *expected*
    /// state at entry — this is the release of the chord that opened the popup.
    static let modifierTimeoutMs = 1_200

    /// An AX or pasteboard answer, reduced to "is there anything here". Whitespace-only is a miss:
    /// a web area with nothing selected happily returns `"\n"`.
    static func usable(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw
    }

    static func checkLength(_ text: String) throws {
        let units = text.utf16.count
        guard units > lengthLimit else { return }
        throw SelectionError.selectionTooLong(units: units, limit: lengthLimit)
    }

    /// Same app, still. A nil bundle id on either side cannot be compared, so it is not treated as a
    /// mismatch — an unbundled helper process is already handled by the injector's paste-only default.
    static func isSameTarget(_ expected: InjectionTarget, _ actual: InjectionTarget) -> Bool {
        guard let want = expected.bundleID, let have = actual.bundleID else { return true }
        return want == have
    }

    /// All three gates up front, never inferred from an `AXError` (RECON: an untrusted system-wide
    /// element returns `.cannotComplete`, which is indistinguishable from a hung app). Secure input is in
    /// here because a focused password field silently drops every posted event — and because a password
    /// field is the last place this feature should be reaching into.
    static func closedGate() -> String? {
        if !AXIsProcessTrusted() {
            return "Edict needs Accessibility permission to read the selection. "
                + "Turn it on in System Settings > Privacy & Security > Accessibility."
        }
        if !CGPreflightPostEventAccess() {
            return "Edict needs permission to send keystrokes before it can copy the selection. "
                + "Turn it on in System Settings > Privacy & Security > Accessibility."
        }
        if IsSecureEventInputEnabled() {
            return "A password field has the keyboard, so Edict cannot touch the selection. "
                + "Click somewhere else and try again."
        }
        return nil
    }

    static func waitForCleanModifiers(timeoutMs: Int? = nil) -> (stillHeld: Bool, waitedMs: Int) {
        let budget = timeoutMs ?? modifierTimeoutMs
        var waited = 0
        while waited < budget {
            let held = CGEventSource.flagsState(.combinedSessionState)
            if held.intersection(dangerousFlags).isEmpty { return (false, waited) }
            usleep(10_000)
            waited += 10
        }
        let held = CGEventSource.flagsState(.combinedSessionState)
        return (!held.intersection(dangerousFlags).isEmpty, waited)
    }

    /// `.maskSecondaryFn` is in here for this feature specifically: `fn` is half the popup's chord, and
    /// `fn`+Cmd-C is not Cmd-C.
    static let dangerousFlags: CGEventFlags = [
        .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn, .maskAlphaShift
    ]
}

// MARK: - Accessibility

/// The focused element plus the identity the policy map is keyed on.
struct SelectionFocus {
    var element: AXUIElement
    var role: String?
    var subrole: String?
}

/// Selection-shaped Accessibility, with the same verification discipline `TextInjector` applies to its
/// inserts and one extra channel it does not have: after replacing a selection, `kAXSelectedText` itself
/// can be read back and compared.
///
/// **Measured on this machine, with the permissions the RECON probes lacked.** RECON line 298 left the
/// project's central question open — *does `AXUIElementSetAttributeValue(kAXSelectedText)` return
/// `.success` on elements that ignore it?* It does. **Safari** reports `settable == true` for
/// `kAXSelectedText` on a `<textarea>`, accepts the write with `kAXErrorSuccess`, and provably changes
/// nothing; the read-back caught it and the app was demoted to paste-only, which then worked. Any code
/// here that trusted the return value would have silently eaten the user's selection.
///
/// The rest of the sweep, which contradicts the assumption that only native apps answer:
///
///     app                     AX read            AX replace                  fallback
///     TextEdit                yes, 43 units      verified                    Cmd-C also works, 35 ms
///     Notes                   yes, 59 units      verified                    (not reached)
///     Safari <textarea>       yes, 43 units      success, ignored, demoted   paste, landed
///     Google Chrome           yes, 43 units      seeded paste-only           paste, landed
///     Ghostty                 yes, whole view    settable == false           Cmd-C works, 35 ms
///     Cursor (Electron)       no focused element -                           Cmd-C found nothing
///
/// Two of those rows change how this file has to behave. **Terminals do answer the read** — Ghostty
/// returns the whole selected viewport, and `kAXErrorNoValue` (-25212) when nothing is selected, so it is
/// honest and the miss-versus-empty rule handles it. And **an Electron app can have no focused AX element
/// at all**, not merely an unreadable one, which is why the read ladder falls through on a nil focus
/// instead of throwing `noFocusedElement` there.
///
/// **On the duplicated low-level bridging.** `TextInjector.swift`'s `InjectAX`, `InjectPasteboard` and
/// `InjectKeycodes` are `private` at file scope, so nothing outside that file can reach them. These are
/// deliberately `internal` rather than `private` so the consolidation can go the other way when someone
/// owns both files: promote or delete one copy, and point the other at it. The spellings here are the
/// ones RECON established compile under the Swift 6 language mode — `withUnsafeMutablePointer` for
/// `AXValueGetValue`, `withUnsafePointer` for `AXValueCreate`, and `unsafeDowncast` rather than
/// `unsafeBitCast` from `AnyObject` to a CF type.
enum SelectionAX {

    /// Bounds every AX round trip. The framework default is 6 s, so one unresponsive app would otherwise
    /// hang the popup — and a `.cannotComplete` from a timeout is exactly what the fall-through absorbs.
    private static let messagingTimeout: Float = 1.0

    // MARK: Bridging

    private static func copyRaw(_ element: AXUIElement, _ attribute: String) -> (AXError, CFTypeRef?) {
        var out: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &out)
        return (error, out)
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        let (error, raw) = copyRaw(element, attribute)
        guard error == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(raw, to: AXUIElement.self)
    }

    static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        let (error, raw) = copyRaw(element, attribute)
        guard error == .success, let raw, CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        return (raw as! CFString) as String
    }

    static func copyInt(_ element: AXUIElement, _ attribute: String) -> Int? {
        let (error, raw) = copyRaw(element, attribute)
        guard error == .success, let raw, CFGetTypeID(raw) == CFNumberGetTypeID() else { return nil }
        return (raw as! NSNumber).intValue
    }

    /// Locations and lengths are **UTF-16 code units**, not Characters and not grapheme clusters (RECON,
    /// verified round-trip). Using `String.count` here mis-measures any selection containing emoji or
    /// combining marks and then makes the verifier report a false failure.
    static func copyRange(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        let (error, raw) = copyRaw(element, attribute)
        guard error == .success, let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        let ok = withUnsafeMutablePointer(to: &range) { AXValueGetValue(value, .cfRange, $0) }
        return ok ? range : nil
    }

    private static func makeRange(location: Int, length: Int) -> AXValue? {
        var range = CFRange(location: location, length: length)
        return withUnsafePointer(to: &range) { AXValueCreate(.cfRange, $0) }
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        let error = AXUIElementIsAttributeSettable(element, attribute as CFString, &settable)
        return error == .success && settable.boolValue
    }

    static func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success, let names else { return [] }
        return (names as NSArray).compactMap { $0 as? String }
    }

    // MARK: Focus

    /// Three routes, in order of documentation and reliability. The system-wide route is the documented
    /// one but returns `.cannotComplete` on hardened or unresponsive apps, which is why the per-app
    /// element is a last resort rather than the first choice.
    static func focused() -> SelectionFocus? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)

        var element = copyElement(systemWide, kAXFocusedUIElementAttribute as String)

        if element == nil, let app = copyElement(systemWide, kAXFocusedApplicationAttribute as String) {
            AXUIElementSetMessagingTimeout(app, messagingTimeout)
            element = copyElement(app, kAXFocusedUIElementAttribute as String)
        }

        if element == nil, let front = NSWorkspace.shared.frontmostApplication {
            let app = AXUIElementCreateApplication(front.processIdentifier)
            AXUIElementSetMessagingTimeout(app, messagingTimeout)
            element = copyElement(app, kAXFocusedUIElementAttribute as String)
        }

        guard let element else { return nil }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return SelectionFocus(
            element: element,
            role: copyString(element, kAXRoleAttribute as String),
            subrole: copyString(element, kAXSubroleAttribute as String)
        )
    }

    // MARK: Read

    /// `nil` for every kind of miss — attribute absent, read error, or an empty string. The caller must
    /// not distinguish them, because in Chromium and Monaco "unsupported" and "nothing selected" arrive
    /// as the same answer with text visibly selected on screen.
    static func selectedText(_ element: AXUIElement) -> String? {
        copyString(element, kAXSelectedTextAttribute as String)
    }

    // MARK: Replace

    /// The pre-flight rule, inherited from RECON's decision rule for inserts: without a *readable*
    /// channel, a `.success` return from the write is unfalsifiable, so attempting it at all would be a
    /// coin flip presented to the user as a success — and for a replace, a lost selection.
    static func looksReplaceable(_ focus: SelectionFocus) -> Bool {
        guard isSettable(focus.element, kAXSelectedTextAttribute as String) else { return false }
        return hasReadableChannel(attributeNames(focus.element))
    }

    /// Split out from ``looksReplaceable(_:)`` so the rule itself is testable without a live element.
    static func hasReadableChannel(_ names: [String]) -> Bool {
        names.contains(kAXValueAttribute as String)
            || names.contains(kAXNumberOfCharactersAttribute as String)
            || names.contains(kAXSelectedTextRangeAttribute as String)
    }

    enum ReplaceVerdict: Equatable {
        case confirmedReplaced
        /// The write returned success and provably changed nothing. Classic Electron silent failure.
        case confirmedNotReplaced
        /// Nothing readable can settle the question. For a replace this is *worse* than a failure,
        /// because the write may have landed — so the caller must not retry on top of it.
        case cannotVerify
    }

    static func replaceSelection(
        with text: String,
        replacing selected: String,
        in focus: SelectionFocus
    ) -> ReplaceVerdict {
        let element = focus.element
        let valueBefore = copyString(element, kAXValueAttribute as String)
        let rangeBefore = copyRange(element, kAXSelectedTextRangeAttribute as String)
        let charsBefore = copyInt(element, kAXNumberOfCharactersAttribute as String)

        let error = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString
        )
        guard error == .success else { return .confirmedNotReplaced }

        let inserted = text.utf16.count
        let expectedDelta = inserted - (rangeBefore?.length ?? 0)

        // Strongest signal first, and one `TextInjector` cannot use: read the selection back. Engines
        // that honour the write either leave the new text selected or collapse the caret, and the former
        // is unambiguous proof. An empty read-back proves nothing either way, so it falls through.
        if let after = copyString(element, kAXSelectedTextAttribute as String), after == text, !text.isEmpty {
            collapseCaret(element, rangeBefore, by: inserted)
            return .confirmedReplaced
        }

        if let before = valueBefore, let after = copyString(element, kAXValueAttribute as String) {
            if after == before {
                // One honest way an unchanged value means success: the refined text is identical to what
                // was selected. Calling that a failure would demote a perfectly good app.
                return text == selected ? .confirmedReplaced : .confirmedNotReplaced
            }
            if after.utf16.count - before.utf16.count == expectedDelta {
                collapseCaret(element, rangeBefore, by: inserted)
            }
            return .confirmedReplaced
        }

        if let before = charsBefore, let after = copyInt(element, kAXNumberOfCharactersAttribute as String) {
            if after == before {
                return text == selected || expectedDelta == 0 ? .cannotVerify : .confirmedNotReplaced
            }
            collapseCaret(element, rangeBefore, by: inserted)
            return .confirmedReplaced
        }

        if let before = rangeBefore, let after = copyRange(element, kAXSelectedTextRangeAttribute as String) {
            if after.location == before.location, after.length == before.length {
                // Ambiguous when the replacement is exactly as long as the selection was: the engine may
                // have replaced the text and re-selected it. Only an unchanged range of a *different*
                // length proves the write was ignored.
                return before.length == inserted ? .cannotVerify : .confirmedNotReplaced
            }
            if after.location == before.location + inserted, after.length == 0 { return .confirmedReplaced }
            if after.location == before.location, after.length == inserted { return .confirmedReplaced }
            return .cannotVerify
        }

        return .cannotVerify
    }

    /// Put the caret after the refined text rather than leaving it selected — the user asked for a
    /// replacement, and a still-selected result is one keystroke away from being deleted.
    private static func collapseCaret(_ element: AXUIElement, _ before: CFRange?, by utf16Units: Int) {
        guard let before,
              let caret = makeRange(location: before.location + utf16Units, length: 0)
        else { return }
        _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, caret)
    }
}

// MARK: - Pasteboard

struct SelectionPasteboardSnapshot: Equatable {
    var items: [[String: Data]]
}

/// Byte-lossless snapshot and restore of every type of every item, so a synthetic Cmd-C can borrow the
/// user's clipboard and give it back unchanged.
///
/// Mirrors `TextInjector`'s `InjectPasteboard`, which is `private` at file scope and therefore
/// unreachable — see the note on ``SelectionAX``. The three exclusion lists are the load-bearing part
/// and are RECON findings, not caution: promised flavors belong to the promising app, derived flavors are
/// synthesized lazily and `data(forType:)` returns nil for them (force-unwrapping
/// `public.utf16-external-plain-text` crashes, RECON §16), and
/// `PasteboardType.fileContentsType(forPathExtension: "")` *traps* on an empty extension so the derived
/// list can never be built that way.
enum SelectionPasteboard {

    /// nspasteboard.org convention: cooperating clipboard managers skip items carrying these, so the
    /// second-long transient item never pollutes the user's clipboard history.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")

    static let promiseTypes: Set<String> = [
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-suggested-file-name",
        "com.apple.pasteboard.promised-file-name",
    ]

    static let derivedTypes: Set<String> = [
        "public.utf16-external-plain-text",
        "public.utf16-plain-text",
        "NSStringPboardType",
        "CorePasteboardFlavorType 0x75747874",
    ]

    static func snapshot(_ pasteboard: NSPasteboard = .general) -> SelectionPasteboardSnapshot {
        var items: [[String: Data]] = []
        for item in pasteboard.pasteboardItems ?? [] {
            var flavors: [String: Data] = [:]
            for type in item.types {
                let raw = type.rawValue
                guard !promiseTypes.contains(raw), !derivedTypes.contains(raw) else { continue }
                // Skip, never force-unwrap: a lazily-provided flavor is listed but yields nil data.
                guard let data = item.data(forType: type) else { continue }
                flavors[raw] = data
            }
            items.append(flavors)
        }
        return SelectionPasteboardSnapshot(items: items)
    }

    @discardableResult
    static func restore(
        _ snapshot: SelectionPasteboardSnapshot,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.items.compactMap { flavors in
            guard !flavors.isEmpty else { return nil }
            let item = NSPasteboardItem()
            for (raw, data) in flavors {
                item.setData(data, forType: NSPasteboard.PasteboardType(raw))
            }
            return item
        }
        guard !items.isEmpty else { return true }
        // A `public.file-url` flavor logs a benign `sandbox_extension_consume failed` line on restore.
        // RECON confirmed it is a red herring: the bytes still compare identical.
        return pasteboard.writeObjects(items)
    }

    /// Returns the `changeCount` the write produced, or nil if the write itself failed.
    @discardableResult
    static func writeTransient(_ text: String, to pasteboard: NSPasteboard = .general) -> Int? {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        item.setData(Data(), forType: autoGeneratedType)
        guard pasteboard.writeObjects([item]) else { return nil }
        return pasteboard.changeCount
    }
}

// MARK: - Layout-aware keycodes

/// `@MainActor` is load-bearing, not decoration. RECON amendment 36: `TISGetInputSourceProperty` funnels
/// into `dispatch_assert_queue(main)`, which does not return an error — it `SIGTRAP`s the process. Because
/// `SelectionBridge` is an actor on its own dispatch queue, every caller has to `await` its way onto the
/// main actor first. Mirrors `TextInjector`'s `InjectKeycodes` (private, unreachable — see ``SelectionAX``).
@MainActor
enum SelectionKeycodes {

    /// Scans every virtual keycode against the user's live layout. RECON verified v=9, a=0, z=6, q=12 on
    /// this machine — but layouts move them, and posting Cmd-<wrong keycode> into another app runs
    /// whatever command that turns out to be.
    static func keyCode(for target: Character) -> CGKeyCode? {
        guard let data = currentLayoutData() else { return nil }
        let keyboardType = UInt32(LMGetKbdType())
        return data.withUnsafeBytes { raw -> CGKeyCode? in
            guard let base = raw.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            for candidate in UInt16(0)..<UInt16(128) {
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 8)
                var length = 0
                let error = UCKeyTranslate(
                    layout, candidate, UInt16(kUCKeyActionDown), 0, keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState, characters.count, &length, &characters
                )
                guard error == noErr, length > 0 else { continue }
                if String(utf16CodeUnits: characters, count: length) == String(target) {
                    return CGKeyCode(candidate)
                }
            }
            return nil
        }
    }

    static func cKeyCode() -> CGKeyCode { keyCode(for: "c") ?? CGKeyCode(kVK_ANSI_C) }

    private static func currentLayoutData() -> Data? {
        // For IME sources (Japanese, Pinyin) it is the *keyboard layout* source that carries
        // kTISPropertyUnicodeKeyLayoutData; the current input source returns nil.
        var source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        if source == nil { source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() }
        guard let source,
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return (unsafeBitCast(pointer, to: CFData.self)) as Data
    }
}
