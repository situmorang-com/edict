import AppKit
import ApplicationServices
import Carbon.HIToolbox   // UCKeyTranslate, TISCopyCurrent*, LMGetKbdType, IsSecureEventInputEnabled
import CoreGraphics
import Foundation

// MARK: - Public surface

public struct InjectionTarget: Sendable, Hashable {
    public var bundleID: String?
    public var appName: String?

    public init(bundleID: String? = nil, appName: String? = nil) {
        self.bundleID = bundleID
        self.appName = appName
    }
}

/// Which rung of the ladder to start on for a given app.
///
/// This is a *policy*, distinct from `InjectionOutcome` (which records what actually happened). It is
/// learned at runtime: RECON's core recommendation is that a hardcoded blocklist rots, whereas an app
/// that once returned `kAXErrorSuccess` and did nothing can be demoted permanently the first time it
/// lies, which is self-healing.
public enum InjectStrategy: String, Codable, Sendable, CaseIterable {
    /// Try the verified Accessibility insert first, then fall through to paste.
    case axFirst
    /// Skip Accessibility entirely; go straight to pasteboard + synthetic Cmd-V.
    case pasteOnly
    /// Type the text character by character. Slow, mangled by input methods — an explicit escape hatch.
    case unicodeOnly
    /// Never inject; just leave the text on the clipboard and say so.
    case clipboardOnly

    /// What the recovery UI prints for this policy. Natural case; the silkscreen type uppercases it.
    public var displayName: String {
        switch self {
        case .axFirst: "Accessibility first"
        case .pasteOnly: "Paste only"
        case .unicodeOnly: "Type it out"
        case .clipboardOnly: "Clipboard only"
        }
    }
}

public extension InjectionOutcome {
    /// True when the text never reached the cursor and re-running the ladder could still land it.
    ///
    /// `.notAttempted` is deliberately excluded: it means nothing was *meant* to be injected — an
    /// imported file, or an utterance started from Edict's own window — so offering to retry it would
    /// invent a failure the user never had.
    var needsRecovery: Bool {
        switch self {
        case .clipboardOnly, .failed: true
        case .accessibility, .paste, .keystrokes, .notAttempted: false
        }
    }
}

// MARK: - TextInjector

/// Puts text where the user's cursor is, and reports which strategy actually worked.
///
/// The whole design exists because **every** injection path on macOS can fail silently:
/// `AXUIElementSetAttributeValue` returns `kAXErrorSuccess` from Electron apps that ignore it, and
/// `CGEvent.post` returns `Void` and is discarded without a word when the process lacks PostEvent
/// (RECON §14, measured). So nothing here trusts a return code — every rung is verified by reading the
/// focused element back, and only a proven insert stops the ladder.
///
/// Isolation: this actor runs on **its own serial dispatch queue**, not the shared cooperative pool.
/// AX reads, `usleep` settle floors and the verify poll all block for tens to hundreds of milliseconds;
/// on a cooperative thread that would starve unrelated work. A custom executor also lets the actor hold
/// the long-lived, non-`Sendable` `CGEventSource` that RECON §26 requires.
public actor TextInjector {

    private let queue = DispatchSerialQueue(label: "com.edict.inject", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// One source for the app's lifetime. RECON §26 measured 44–50 ms for the *first*
    /// `CGEvent(keyboardEventSource:)` in a process (0.00 ms for the second) and 55–90 ms for the whole
    /// first create-and-post, once 1422 ms on a truly cold process. Paying that on the user's first
    /// dictation would also let a naive fixed-delay clipboard restore fire before the paste is delivered.
    private var eventSource: CGEventSource?

    /// Where learned per-bundle policy lives. Shared by every injector in the process by default —
    /// see `InjectPolicyStore`.
    private let policies: InjectPolicyStore

    /// Set once `prewarm()` has run, so `inject` never pays the cold cost twice.
    private var warmed = false

    /// - Parameter policies: the learned-policy store. Defaults to the process-wide one, which is what
    ///   keeps two injectors — the dictation controller's and the history pane's retry path — from
    ///   holding divergent snapshots of the same on-disk map. Tests pass their own so they never touch
    ///   `UserDefaults.standard`.
    public init(policies: InjectPolicyStore = .standard) {
        self.policies = policies
    }

    // MARK: Target

    /// The app that had focus when the user finished speaking. `NSWorkspace` is main-thread-affine in
    /// spirit but `frontmostApplication` is safe to read from anywhere, and this must be callable at
    /// key-down time from the dictation controller before the injector is ever touched.
    public static func currentTarget() -> InjectionTarget {
        let front = NSWorkspace.shared.frontmostApplication
        return InjectionTarget(bundleID: front?.bundleIdentifier, appName: front?.localizedName)
    }

    // MARK: Warm-up

    /// RECON §26. Retain one `CGEventSource`, create and discard one `CGEvent`, touch
    /// `AXIsProcessTrusted()` and do one throwaway system-wide AX read.
    public func prewarm() async {
        guard !warmed else { return }
        warmed = true

        let source = CGEventSource(stateID: .privateState)
        // `CGEventSourceSetLocalEventsSuppressionInterval` does not import as a static func — it is a
        // property setter (RECON, verified against CoreGraphics.apinotes). The measured default is
        // 0.25 s, which would suppress the user's real keyboard for a quarter second after every paste.
        source?.localEventsSuppressionInterval = 0.0
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        eventSource = source

        if let source { _ = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) }
        _ = AXIsProcessTrusted()
        _ = InjectAX.focused()
        // Warming the layout scan is the whole reason this hop exists: doing it here keeps TIS off
        // the first real paste, where the main actor may be busy rendering the HUD.
        _ = await MainActor.run { InjectKeycodes.vKeyCode() }
        Log.inject.debug("injection path pre-warmed")
    }

    // MARK: Policy

    /// Contract-shaped accessor: the outcome this app is *expected* to produce, or nil when Edict has
    /// no opinion and the full ladder should run.
    public func preferredStrategy(for bundleID: String?) -> InjectionOutcome? {
        guard let bundleID else { return .paste }   // unbundled helper: never trust AX
        guard let strategy = explicitStrategy(for: bundleID) else { return nil }
        switch strategy {
        case .axFirst: return .accessibility
        case .pasteOnly: return .paste
        case .unicodeOnly: return .keystrokes
        case .clipboardOnly: return .clipboardOnly
        }
    }

    /// The strategy actually used, seed list and learned demotions included.
    public func strategy(for bundleID: String?) -> InjectStrategy {
        // RECON: fall back to paste when the bundle id is nil. An unbundled or helper process cannot be
        // keyed in the policy map, so it can never be learned about, so it must never be trusted.
        guard let bundleID else { return .pasteOnly }
        return explicitStrategy(for: bundleID) ?? .axFirst
    }

    /// Lets the UI offer "always paste into this app" / "type character by character here".
    public func setStrategy(_ strategy: InjectStrategy, for bundleID: String) {
        policies.set(strategy, for: bundleID)
        Log.inject.notice("policy for \(bundleID, privacy: .public) set to \(strategy.rawValue, privacy: .public)")
    }

    /// Every app Edict has learned something about, for a settings pane.
    public func learnedStrategies() -> [String: InjectStrategy] {
        policies.all()
    }

    /// True when this app's policy was *learned* rather than seeded or defaulted. The recovery UI needs
    /// the distinction: "Edict decided this" and "Edict shipped with this" are different sentences.
    public func hasLearnedStrategy(for bundleID: String) -> Bool {
        policies.learned(for: bundleID) != nil
    }

    public func forgetStrategy(for bundleID: String) {
        policies.remove(bundleID)
        Log.inject.notice("policy for \(bundleID, privacy: .public) forgotten")
    }

    private func explicitStrategy(for bundleID: String) -> InjectStrategy? {
        if let remembered = policies.learned(for: bundleID) { return remembered }
        if InjectSeed.pasteOnlyBundles.contains(bundleID) { return .pasteOnly }
        if InjectSeed.terminalBundles.contains(bundleID) { return .pasteOnly }
        return nil
    }

    /// Demote an app permanently. This is the self-healing half: any app that yields
    /// `confirmedNotInserted` or `cannotVerify` can never be trusted with an AX insert again, because a
    /// `.success` return from it is unfalsifiable.
    private func demoteToPasteOnly(_ bundleID: String?, why: String) {
        guard let bundleID else { return }
        guard policies.learned(for: bundleID) != .pasteOnly else { return }
        policies.set(.pasteOnly, for: bundleID)
        Log.inject.notice("demoted \(bundleID, privacy: .public) to paste-only: \(why, privacy: .public)")
    }

    // MARK: Injection

    /// Runs the ladder: verified AX insert → pasteboard + layout-resolved Cmd-V → Unicode keystrokes →
    /// clipboard only. Returns the rung that actually worked.
    public func inject(_ text: String, into target: InjectionTarget) async -> InjectionOutcome {
        guard !text.isEmpty else { return .notAttempted }
        await prewarm()

        var strategy = strategy(for: target.bundleID)
        let payload = Self.normalise(text, for: target.bundleID)
        let expectedDelta = payload.utf16.count

        // Rung 0. RECON is explicit that all three gates are checked up front and never inferred from an
        // AXError: an untrusted system-wide element returns `.cannotComplete`, not `.apiDisabled`, which
        // is indistinguishable from a hung app.
        let trusted = AXIsProcessTrusted()
        let canPost = CGPreflightPostEventAccess()
        let secureInput = IsSecureEventInputEnabled()
        if !trusted || !canPost || secureInput {
            Log.inject.error("""
                injection gate closed: axTrusted=\(trusted, privacy: .public) \
                postEvent=\(canPost, privacy: .public) secureInput=\(secureInput, privacy: .public)
                """)
            return leaveOnClipboard(payload)
        }

        if strategy == .clipboardOnly {
            return leaveOnClipboard(payload)
        }

        // Rung 3, hoisted: Unicode typing is opt-in per app (RECON is explicit that it must never be a
        // silent default — it is the slowest rung and input methods and auto-complete mangle it), so the
        // only way to reach it is an explicit policy, and in that case it replaces the ladder rather
        // than trailing it.
        if strategy == .unicodeOnly {
            if InjectUnicode.type(payload, source: eventSource) {
                Log.inject.info("typed \(payload.utf16.count) UTF-16 units as keystrokes")
                return .keystrokes
            }
            Log.inject.error("unicode keystroke injection could not construct its events")
            return leaveOnClipboard(payload)
        }

        // One focus lookup for the whole ladder. The first system-wide AX read in a process costs
        // 31–42 ms (RECON §26); the focused element cannot change between rungs because the user is not
        // touching anything, so doing it twice would just pay that twice.
        let focus = InjectAX.focused()

        // Rung 1: verified Accessibility insert.
        if strategy == .axFirst {
            if let focus {
                if InjectAX.looksInsertable(focus) {
                    let verdict = InjectAX.insert(payload, into: focus)
                    switch verdict {
                    case .confirmedInserted:
                        Log.inject.info("AX insert verified in \(target.appName ?? "?", privacy: .public)")
                        return .accessibility
                    case .confirmedNotInserted:
                        demoteToPasteOnly(target.bundleID, why: "AX write returned success but nothing changed")
                    case .cannotVerify:
                        demoteToPasteOnly(target.bundleID, why: "AX insert is unverifiable on this element")
                    }
                } else {
                    // Not a demotion: the *element* was wrong (a button, a web area), not necessarily
                    // the app. Another field in the same app may still be insertable.
                    Log.inject.debug("AX insert skipped: focused element is not settable/readable")
                }
            } else {
                Log.inject.debug("no focused AX element; skipping rung 1")
            }
            strategy = .pasteOnly
        }

        // Rung 2: pasteboard + layout-resolved synthetic Cmd-V. The workhorse.
        if strategy == .pasteOnly {
            // Fingerprint BEFORE writing the clipboard, so the poll afterwards is measuring the paste —
            // and after rung 1, so a partial AX write cannot be mistaken for the paste landing.
            let fingerprint = focus.map { InjectAX.fingerprint($0.element) }

            let landed = await paste(payload) {
                guard let focus, let fingerprint else { return nil }
                return InjectAX.waitForChange(focus.element, from: fingerprint, expectedUTF16Delta: expectedDelta)
            }

            switch landed {
            case .some(true):
                Log.inject.info("paste verified in \(target.appName ?? "?", privacy: .public)")
                return .paste
            case nil:
                // The element exposes nothing readable, so success is unprovable either way. Reporting
                // `.paste` is the honest best guess — the alternative is telling the user it failed when
                // it almost certainly worked (terminals are the canonical case).
                Log.inject.info("paste unverifiable in \(target.appName ?? "?", privacy: .public); assuming success")
                return .paste
            case .some(false):
                // Provably dropped. Do not silently escalate to keystroke typing: the UI should offer
                // "type character by character in this app" and let the user opt in.
                Log.inject.error("paste provably did not land in \(target.appName ?? "?", privacy: .public)")
            }
        }

        // Rung 4: give up loudly. The text is on the clipboard and the UI must say which app refused.
        return leaveOnClipboard(payload)
    }

    private func leaveOnClipboard(_ text: String) -> InjectionOutcome {
        guard InjectPasteboard.writeTransient(text) != nil else {
            Log.inject.error("could not even write the clipboard")
            return .failed
        }
        Log.inject.notice("text left on the clipboard for a manual paste")
        return .clipboardOnly
    }

    /// Terminals execute a pasted newline. Collapse them rather than running the user's prose as shell
    /// commands — RECON flags this as the one content transformation the injector must make.
    private static func normalise(_ text: String, for bundleID: String?) -> String {
        guard let bundleID, InjectSeed.terminalBundles.contains(bundleID) else { return text }
        return text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    // MARK: Paste

    /// Snapshot → write → wait for clean modifiers → Cmd-V → verify-poll → restore.
    ///
    /// The verify poll deliberately sits *between* the post and the restore, so the time it spends
    /// polling **is** the settle delay: a native app finishes in ~40 ms while Electron gets the full
    /// budget. RECON §16 is emphatic that a fixed sleep here is the classic "Cmd-V pasted my OLD
    /// clipboard" bug, because the target reads the pasteboard lazily on its own run loop.
    private func paste(_ text: String, verify: () -> Bool?) async -> Bool? {
        let snapshot = InjectPasteboard.snapshot()

        // Edict's hotkey is a HELD modifier. Posting Cmd-V while Right Option is still physically down
        // delivers Cmd-Option-V to the target. RECON §27: query `.combinedSessionState` —
        // `CGEventSource.flagsState(.privateState)` blocks forever (measured at both 12 s and 120 s).
        let waited = Self.waitForCleanModifiers()
        if waited.stillHeld {
            Log.inject.error("hardware modifiers still held after \(waited.waitedMs) ms; Cmd-V may be contaminated")
        }

        guard let ourChangeCount = InjectPasteboard.writeTransient(text) else { return false }

        guard await postCommandV() else {
            _ = InjectPasteboard.restore(snapshot)
            return false
        }

        // A floor before the poll starts: RECON measured no app reading the pasteboard faster than this,
        // and polling immediately just burns a cycle.
        usleep(35_000)
        let proved = verify()

        let now = NSPasteboard.general.changeCount
        if now != ourChangeCount {
            // A clipboard manager, the target app, or the user wrote after us. Restoring now would
            // destroy their content. RECON §16: changeCount does not move on a *paste*, so a move here
            // is always somebody else writing.
            Log.inject.notice("clipboard changed under us (\(ourChangeCount) -> \(now)); not restoring")
        } else {
            _ = InjectPasteboard.restore(snapshot)
        }
        return proved
    }

    private func postCommandV() async -> Bool {
        // RECON §15: never hardcode keycode 9. On some layouts Cmd-<keycode 9> is Cmd-W, which closes
        // the user's browser tab — destructive, not merely broken. Resolved fresh every time rather than
        // cached, because the user can switch layout between dictations and the scan costs microseconds.
        // The hop is mandatory: TIS traps if touched off the main thread (see `InjectKeycodes`).
        let vKey = await MainActor.run { InjectKeycodes.vKeyCode() }
        guard let source = eventSource ?? CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else {
            Log.inject.error("could not construct the Cmd-V events")
            return false
        }
        // ASSIGN, never OR. A fresh CGEvent carries an undocumented default flag 0x20000000; assignment
        // replaces it wholesale and leaves exactly maskCommand (RECON, measured). OR-ing would also let
        // a held push-to-talk modifier leak in.
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    private static let dangerousFlags: CGEventFlags = [
        .maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn, .maskAlphaShift
    ]

    private static func waitForCleanModifiers(timeoutMs: Int = 400) -> (stillHeld: Bool, waitedMs: Int) {
        var waited = 0
        while waited < timeoutMs {
            let held = CGEventSource.flagsState(.combinedSessionState)
            if held.intersection(dangerousFlags).isEmpty { return (false, waited) }
            usleep(10_000)
            waited += 10
        }
        let held = CGEventSource.flagsState(.combinedSessionState)
        return (!held.intersection(dangerousFlags).isEmpty, waited)
    }
}

// MARK: - Seed policy

/// Apps that RECON identified as accepting an `AXSelectedText` write with `kAXErrorSuccess` and doing
/// nothing. This is only a *seed*: `TextInjector` learns and persists demotions at runtime, so the list
/// does not have to be exhaustive or maintained forever.
private enum InjectSeed {

    static let pasteOnlyBundles: Set<String> = [
        // Electron / Chromium shells
        "com.todesktop.230313mzl4w4u92",        // Cursor
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.visualstudio.code.oss",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "notion.id",
        "com.spotify.client",
        "com.figma.Desktop",
        "com.microsoft.teams2",
        "com.openai.chat",
        "md.obsidian",
        "com.linear",
        "com.postmanlabs.mac",
        // Browsers — a web text area usually exposes no writable AXSelectedText
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.brave.Browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
        // Java / Qt / bespoke text engines
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.WebStorm",
        "com.sublimetext.4",
        "com.microsoft.Word",
        "com.microsoft.Excel",
    ]

    /// Terminals: Cmd-V works, AX insert does not, and a pasted newline *executes the line*.
    /// Tracked separately from `pasteOnlyBundles` because they also need newline collapsing.
    static let terminalBundles: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "com.mitchellh.ghostty",
    ]
}

// MARK: - Learned-policy persistence

/// The learned per-bundle policy map, cached in memory and written through to `UserDefaults`.
///
/// A shared **object** rather than the static functions this used to be, because there is now more than
/// one `TextInjector` in the process: `DictationController` owns the one on the dictation path, and
/// `AppModel` owns the one behind the history pane's retry key. With a per-actor snapshot, a demotion
/// learned on one path was invisible to the other until the app relaunched — so the pane could offer
/// "always paste only here" and the *next dictation* would still try Accessibility first. One store
/// behind both makes the learning mean what it says.
///
/// `@unchecked Sendable` with an `NSLock`: it is reached from two actors on two different executors, so
/// main-actor confinement is not available and the dictionary has to be genuinely guarded.
public final class InjectPolicyStore: @unchecked Sendable {

    public static let standard = InjectPolicyStore(defaults: .standard)

    static let key = "edict.injectPolicies"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cache: [String: InjectStrategy]?

    /// - Parameter defaults: injected so tests can use an `EphemeralDefaults` and never write a key
    ///   into the user's real preferences.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func all() -> [String: InjectStrategy] {
        lock.withLock { loaded() }
    }

    func learned(for bundleID: String) -> InjectStrategy? {
        lock.withLock { loaded()[bundleID] }
    }

    func set(_ strategy: InjectStrategy, for bundleID: String) {
        lock.withLock {
            var map = loaded()
            map[bundleID] = strategy
            store(map)
        }
    }

    func remove(_ bundleID: String) {
        lock.withLock {
            var map = loaded()
            guard map.removeValue(forKey: bundleID) != nil else { return }
            store(map)
        }
    }

    /// Callers hold `lock`.
    private func loaded() -> [String: InjectStrategy] {
        if let cache { return cache }
        let raw = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        let map = raw.compactMapValues(InjectStrategy.init(rawValue:))
        cache = map
        return map
    }

    /// Callers hold `lock`.
    private func store(_ map: [String: InjectStrategy]) {
        cache = map
        defaults.set(map.mapValues(\.rawValue), forKey: Self.key)
    }
}

// MARK: - Accessibility

/// The focused element plus the identity needed to key the policy map.
private struct InjectFocus {
    var element: AXUIElement
    var role: String?
    var subrole: String?
}

/// A cheap, comparable summary of a text element's contents. The only success signal Strategies B and C
/// have (RECON §14): `CGEvent.post` returns `Void` and drops events silently, so the paste is proven by
/// watching the target's own accessibility values move.
private struct InjectFingerprint: Equatable {
    var valueUTF16: Int?
    var numberOfCharacters: Int?
    var caret: Int?
    var valueHash: Int?

    var isUsable: Bool { valueUTF16 != nil || numberOfCharacters != nil || caret != nil }
}

private enum InjectAX {

    /// Bounds every AX round trip. The framework default is 6 s, so a single unresponsive app would
    /// otherwise stall the whole injector — and `.cannotComplete` from a timeout is exactly what the
    /// learned policy is designed to absorb.
    private static let messagingTimeout: Float = 1.0

    // MARK: Low-level bridging
    //
    // These are the precise spellings that compile under the Swift 6 language mode:
    // `AXValueGetValue` needs `withUnsafeMutablePointer`, `AXValueCreate` needs `withUnsafePointer`, and
    // `unsafeDowncast` (not `unsafeBitCast` — release-mode Swift 6.3 warns on `unsafeBitCast` from
    // `AnyObject` to a CF type).

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

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        let (error, raw) = copyRaw(element, attribute)
        guard error == .success, let raw, CFGetTypeID(raw) == CFStringGetTypeID() else { return nil }
        return (raw as! CFString) as String
    }

    private static func copyInt(_ element: AXUIElement, _ attribute: String) -> Int? {
        let (error, raw) = copyRaw(element, attribute)
        guard error == .success, let raw, CFGetTypeID(raw) == CFNumberGetTypeID() else { return nil }
        return (raw as! NSNumber).intValue
    }

    /// Locations and lengths are **UTF-16 code units**, not Characters and not grapheme clusters
    /// (RECON, verified round-trip). Using `String.count` here puts the caret in the wrong place on any
    /// text containing emoji or combining marks, and then makes the verifier report a false failure.
    private static func copyRange(_ element: AXUIElement, _ attribute: String) -> CFRange? {
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

    private static func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success, let names else { return [] }
        return (names as NSArray).compactMap { $0 as? String }
    }

    // MARK: Focus

    /// Three routes, in order of documentation and reliability. The system-wide route is the documented
    /// one but returns `.cannotComplete` on hardened or unresponsive apps, which is why the per-app
    /// element is the last resort rather than the first choice.
    static func focused() -> InjectFocus? {
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
        return InjectFocus(
            element: element,
            role: copyString(element, kAXRoleAttribute as String),
            subrole: copyString(element, kAXSubroleAttribute as String)
        )
    }

    // MARK: Strategy A

    /// The pre-flight decision rule. Without a *readable* channel, a `.success` return from the write is
    /// unfalsifiable, so attempting the insert at all would be a coin flip presented as a success.
    static func looksInsertable(_ focus: InjectFocus) -> Bool {
        guard isSettable(focus.element, kAXSelectedTextAttribute as String) else { return false }
        let names = attributeNames(focus.element)
        return names.contains(kAXValueAttribute as String)
            || names.contains(kAXSelectedTextRangeAttribute as String)
    }

    enum InsertVerdict {
        case confirmedInserted
        /// The write returned success and provably changed nothing. Classic Electron silent failure.
        case confirmedNotInserted
        /// The element exposes nothing that can settle the question. Treated as failure for policy
        /// purposes, because an unverifiable insert must never be reported to the user as a success.
        case cannotVerify
    }

    static func insert(_ text: String, into focus: InjectFocus) -> InsertVerdict {
        let element = focus.element
        let valueBefore = copyString(element, kAXValueAttribute as String)
        let rangeBefore = copyRange(element, kAXSelectedTextRangeAttribute as String)
        let charsBefore = copyInt(element, kAXNumberOfCharactersAttribute as String)

        let error = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString
        )
        guard error == .success else { return .confirmedNotInserted }

        let inserted = text.utf16.count
        let replaced = rangeBefore?.length ?? 0
        let expectedDelta = inserted - replaced

        // Verification strength, strongest first: AXValue compare > AXNumberOfCharacters delta >
        // caret advance. Anything weaker cannot distinguish "inserted" from "ignored".
        if let before = valueBefore, let after = copyString(element, kAXValueAttribute as String) {
            if after == before { return .confirmedNotInserted }
            let actualDelta = after.utf16.count - before.utf16.count
            if actualDelta == expectedDelta { advanceCaret(element, rangeBefore, by: inserted) }
            return .confirmedInserted
        }

        if let before = charsBefore, let after = copyInt(element, kAXNumberOfCharactersAttribute as String) {
            if after == before { return .confirmedNotInserted }
            advanceCaret(element, rangeBefore, by: inserted)
            return .confirmedInserted
        }

        if let before = rangeBefore, let after = copyRange(element, kAXSelectedTextRangeAttribute as String) {
            if after.location == before.location + inserted { return .confirmedInserted }
            if after.location == before.location && after.length == before.length {
                return .confirmedNotInserted
            }
            return .cannotVerify
        }

        return .cannotVerify
    }

    private static func advanceCaret(_ element: AXUIElement, _ before: CFRange?, by utf16Units: Int) {
        guard let before, let caret = makeRange(location: before.location + utf16Units, length: 0) else { return }
        _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, caret)
    }

    // MARK: Post-injection verification

    static func fingerprint(_ element: AXUIElement) -> InjectFingerprint {
        var print = InjectFingerprint()
        if let value = copyString(element, kAXValueAttribute as String) {
            print.valueUTF16 = value.utf16.count
            print.valueHash = value.hashValue
        }
        print.numberOfCharacters = copyInt(element, kAXNumberOfCharactersAttribute as String)
        print.caret = copyRange(element, kAXSelectedTextRangeAttribute as String)?.location
        return print
    }

    /// `nil` means verification is impossible on this element — which is not the same as failure, and
    /// callers must not report it as one. Works even in apps where *writing* `AXSelectedText` is a silent
    /// no-op, because those same apps still read correctly (Chromium exposes AXValue on input/textarea,
    /// Monaco exposes AXNumberOfCharacters on its hidden textarea).
    static func waitForChange(
        _ element: AXUIElement,
        from before: InjectFingerprint,
        expectedUTF16Delta: Int,
        timeoutMs: Int = 400,
        stepMs: Int = 20
    ) -> Bool? {
        guard before.isUsable else { return nil }
        var waited = 0
        while waited < timeoutMs {
            usleep(UInt32(stepMs) * 1000)
            waited += stepMs
            let now = fingerprint(element)
            if let b = before.valueUTF16, let a = now.valueUTF16 {
                if a - b == expectedUTF16Delta { return true }
                if now.valueHash != before.valueHash { return true }
            }
            if let b = before.numberOfCharacters, let a = now.numberOfCharacters, a != b { return true }
            if let b = before.caret, let a = now.caret, a != b { return true }
        }
        return false
    }
}

// MARK: - Pasteboard

private struct InjectPasteboardSnapshot {
    var items: [[String: Data]]
}

private enum InjectPasteboard {

    /// nspasteboard.org convention: cooperating clipboard managers skip items carrying these, so
    /// Edict's one-second-long transient item never pollutes the user's clipboard history.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")

    /// The promising app owns these bytes; reading can block or return nil and writing them back is
    /// meaningless. Never call `NSPasteboard.PasteboardType.fileContentsType(forPathExtension: "")` to
    /// build this list — RECON found it is an implicitly-unwrapped-optional bridge that *traps* on "".
    private static let promiseTypes: Set<String> = [
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-suggested-file-name",
        "com.apple.pasteboard.promised-file-name",
    ]

    /// Flavors the pasteboard *synthesizes* on demand. They appear in `item.types`, `data(forType:)`
    /// returns nil for them, and they regenerate after a restore — so capturing them makes a
    /// byte-perfect restore look lossy, and force-unwrapping them crashes (RECON §16).
    private static let derivedTypes: Set<String> = [
        "public.utf16-external-plain-text",
        "public.utf16-plain-text",
        "NSStringPboardType",
        "CorePasteboardFlavorType 0x75747874",
    ]

    /// All types of all items. Verified byte-lossless against a real two-item clipboard carrying
    /// public.tiff + public.rtf + public.utf8-plain-text + public.file-url.
    static func snapshot(_ pasteboard: NSPasteboard = .general) -> InjectPasteboardSnapshot {
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
        return InjectPasteboardSnapshot(items: items)
    }

    @discardableResult
    static func restore(_ snapshot: InjectPasteboardSnapshot, to pasteboard: NSPasteboard = .general) -> Bool {
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
        // A `public.file-url` flavor logs a benign `sandbox_extension_consume failed` line to stderr on
        // restore. RECON confirmed it is a red herring: the bytes still compare identical.
        return pasteboard.writeObjects(items)
    }

    /// Returns the `changeCount` our write produced, so the restore can tell "nobody touched it" from
    /// "a clipboard manager wrote after us". nil means the write itself failed.
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

/// `@MainActor` is load-bearing, not decoration. Text Input Services is main-thread-only:
/// `TISGetInputSourceProperty` funnels into `TSMGetInputSourceProperty` ->
/// `isValidateInputSourceRef` -> `dispatch_assert_queue(main)`, which does not return an error —
/// it `SIGTRAP`s the process. Because `TextInjector` is an `actor`, its executor is a background
/// thread, so calling this from `prewarm()` crashed the app ~1.6 s after launch with
/// `EXC_BREAKPOINT` in `_dispatch_assert_queue_fail` on the `com.edict.inject` thread. Every
/// caller therefore has to `await` its way onto the main actor first.
@MainActor
private enum InjectKeycodes {

    /// Scans every virtual keycode against the user's live layout. RECON verified v=9, a=0, z=6, q=12 on
    /// this machine — but on Dvorak keycode 9 is '.', and on some layouts Cmd-<9> is Cmd-W.
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

    static func vKeyCode() -> CGKeyCode { keyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V) }

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

// MARK: - Unicode keystrokes

private enum InjectUnicode {

    /// Chunking **must** be on grapheme-cluster boundaries. Slicing by raw UTF-16 index cuts surrogate
    /// pairs, combining sequences, regional-indicator flags and ZWJ families in half and produces tofu.
    /// Verified lossless over a ZWJ family emoji, a flag, combining Latin, CJK and long ASCII.
    static func chunk(_ text: String, maxUTF16: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        var length = 0
        for character in text {
            let width = character.utf16.count
            if length + width > maxUTF16, !current.isEmpty {
                chunks.append(current)
                current = ""
                length = 0
            }
            current.append(character)
            length += width
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// 20 UTF-16 units per chunk is conservative folklore, not measurement: RECON proved the *event*
    /// holds at least 4096 units intact, but could not post a single event to test delivery.
    @discardableResult
    static func type(_ text: String, source: CGEventSource?, maxUTF16: Int = 20) -> Bool {
        guard let source = source ?? CGEventSource(stateID: .privateState) else { return false }
        source.localEventsSuppressionInterval = 0.0

        for piece in chunk(text, maxUTF16: maxUTF16) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { return false }
            // Cleared, not inherited: a held push-to-talk modifier would otherwise turn every character
            // into a menu shortcut.
            down.flags = []
            up.flags = []
            Array(piece.utf16).withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(2_000)
        }
        return true
    }
}

