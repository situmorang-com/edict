import AVFoundation
import AppKit
import Carbon.HIToolbox     // IsSecureEventInputEnabled
import ApplicationServices   // AXIsProcessTrusted / AXIsProcessTrustedWithOptions live in HIServices, NOT CoreGraphics
import CoreGraphics          // CGPreflight/CGRequest{Listen,Post}EventAccess
import Foundation
import IOKit                 // RECON §hotkey: no bridging header, no module map, no linker flag needed
import IOKit.hid             // IOHIDCheckAccess / IOHIDRequestAccess
import Observation

// MARK: - PermissionKind

/// The four TCC grants Edict actually needs.
///
/// RECON explicitly dropped `speechRecognition`: the speech probe transcribed successfully without ever
/// calling `SFSpeechRecognizer.requestAuthorization`, because `DictationTranscriber` runs entirely
/// on-device through `SpeechAnalyzer` and is not gated by `kTCCServiceSpeechRecognition`. Asking for it
/// would be an unearned scary prompt.
public enum PermissionKind: String, CaseIterable, Sendable, Identifiable {
    /// `kTCCServiceMicrophone`. Without it there is no audio at all.
    case microphone
    /// `kTCCServiceAccessibility`. Needed to *read* the focused text field (the only way to prove an
    /// injection landed — RECON §14) and to write into it directly.
    case accessibility
    /// `kTCCServiceListenEvent`. Needed by the push-to-talk `CGEventTap`.
    case inputMonitoring
    /// `kTCCServicePostEvent`. Needed to synthesise the Cmd-V / Unicode keystrokes that put text at the
    /// cursor. macOS has no separate pane for it — it rides along with Accessibility (see `settingsURL`).
    case postEvent

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .accessibility: "Accessibility"
        case .inputMonitoring: "Input Monitoring"
        case .postEvent: "Send Keystrokes"
        }
    }

    /// One plain sentence, phrased as what the user gets — not as what the API is called.
    public var why: String {
        switch self {
        case .microphone:
            "Edict needs the microphone to hear what you dictate."
        case .accessibility:
            "Lets Edict see the text field you are typing into, so it can confirm your words actually landed."
        case .inputMonitoring:
            "Lets Edict notice when you hold the dictation key, even while another app is in front."
        case .postEvent:
            "Lets Edict paste your words at the cursor. Granted together with Accessibility."
        }
    }

    /// Deep link into the exact System Settings pane. All of these were verified by RECON to resolve to
    /// System Settings.app via `NSWorkspace.urlForApplication(toOpen:)`.
    public var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(paneFragment)")
    }

    /// `postEvent` intentionally points at the Accessibility pane: there is no `Privacy_PostEvent` pane,
    /// and in practice granting Accessibility is what makes `CGPreflightPostEventAccess()` flip true.
    private var paneFragment: String {
        switch self {
        case .microphone: "Privacy_Microphone"
        case .accessibility, .postEvent: "Privacy_Accessibility"
        case .inputMonitoring: "Privacy_ListenEvent"
        }
    }

    /// True for the grants that make Edict usable at all. `postEvent` is excluded because the AX
    /// insert path and the "left on your clipboard" fallback both work without it.
    public var isCritical: Bool {
        switch self {
        case .microphone, .accessibility, .inputMonitoring: true
        case .postEvent: false
        }
    }
}

public enum PermissionState: Sendable, Hashable {
    case granted
    /// TCC has recorded a *deny*. Prompting again is a silent no-op; only System Settings can fix it.
    case denied
    /// Never asked. A prompt will actually appear.
    case notDetermined
    case unknown
}

// MARK: - PermissionProbe

/// The raw, non-prompting checks, callable from any isolation domain.
///
/// Split out from `Permissions` (which is `@MainActor`) because `HotkeyMonitor` gates tap creation on
/// `inputMonitoringGranted` from its own tap thread and `TextInjector` gates the whole ladder on
/// `accessibilityTrusted` from its own executor. Neither can hop to the main actor first: the hotkey
/// path must not block on UI work, and the injector runs while the main thread may be busy.
public enum PermissionProbe {

    /// Never prompts. `CGPreflightListenEventAccess()` is the CoreGraphics wrapper over
    /// `IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`; RECON measured the two agreeing.
    public static var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }

    /// Distinguishes "never asked" from "explicitly denied", which the boolean above cannot.
    /// RECON: once TCC records a deny, `CGRequestListenEventAccess()` does nothing at all, so this is
    /// the difference between showing a prompt and sending the user to System Settings.
    public static var inputMonitoringStatus: IOHIDAccessType {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Never prompts.
    public static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Never prompts. `CGEvent.post` returns `Void` and is *silently dropped* without this
    /// (RECON §14), so it must be pre-flighted rather than discovered after the fact.
    public static var postEventGranted: Bool { CGPreflightPostEventAccess() }

    public static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Secure input (a focused password field, or an app that left it on) makes the window server drop
    /// every posted event regardless of TCC. Not a permission, but it fails identically, so callers that
    /// gate on `postEventGranted` must gate on this too.
    public static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    // MARK: State mapping

    static func state(for kind: PermissionKind) -> PermissionState {
        switch kind {
        case .microphone:
            switch microphoneStatus {
            case .authorized: .granted
            case .denied, .restricted: .denied
            case .notDetermined: .notDetermined
            @unknown default: .unknown
            }

        case .inputMonitoring:
            // The IOKit status is authoritative here; the CG preflight only reports granted-or-not.
            switch inputMonitoringStatus {
            case kIOHIDAccessTypeGranted: .granted
            case kIOHIDAccessTypeDenied: .denied
            case kIOHIDAccessTypeUnknown: .notDetermined
            default: inputMonitoringGranted ? .granted : .unknown
            }

        case .accessibility:
            // AX exposes one bit and no "not yet asked" signal. `Permissions` refines this to `.denied`
            // once it has actually shown the prompt and the bit is still false.
            accessibilityTrusted ? .granted : .notDetermined

        case .postEvent:
            postEventGranted ? .granted : .notDetermined
        }
    }
}

// MARK: - Permissions

/// The UI's view of the four grants, plus the prompting and deep-linking flow.
///
/// `@Observable`, so a SwiftUI permissions pane re-renders the moment `refresh()` notices a change.
/// Callers that need to *react* to a grant arriving — `HotkeyMonitor` must be destroyed and re-created,
/// never re-enabled (RECON §11) — should consume `changes`.
@MainActor @Observable
public final class Permissions {

    public static let shared = Permissions()

    public private(set) var states: [PermissionKind: PermissionState]

    /// Kinds we have shown the system prompt for during this app run. Used to turn an unhelpful
    /// `.notDetermined` into an honest `.denied` for Accessibility and PostEvent, which have no
    /// "not yet asked" API of their own.
    private var prompted: Set<PermissionKind> = []

    private var pollTask: Task<Void, Never>?
    private var activationObserver: (any NSObjectProtocol)?

    private let changesContinuation: AsyncStream<PermissionKind>.Continuation
    private let changesStream: AsyncStream<PermissionKind>

    public init() {
        var initial: [PermissionKind: PermissionState] = [:]
        for kind in PermissionKind.allCases { initial[kind] = PermissionProbe.state(for: kind) }
        states = initial

        // Unbounded is safe: emissions are human-paced (a user flipping a switch in System Settings),
        // and dropping one would strand the hotkey tap in its dead state forever.
        let (stream, continuation) = AsyncStream<PermissionKind>.makeStream(bufferingPolicy: .unbounded)
        changesStream = stream
        changesContinuation = continuation

        // A TCC grant can only be given while Edict is in the background (the user is in System
        // Settings), so regaining focus is the single highest-value moment to re-check.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees this body runs on the main thread, so the isolation assertion
            // is sound and avoids an extra hop that would let a stale state linger for one frame.
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: Reading

    public func state(of kind: PermissionKind) -> PermissionState {
        states[kind] ?? .unknown
    }

    /// microphone + accessibility + inputMonitoring. `postEvent` is deliberately not critical — without
    /// it Edict still transcribes and still leaves the text on the clipboard.
    public var allCriticalGranted: Bool {
        PermissionKind.allCases
            .filter(\.isCritical)
            .allSatisfy { states[$0] == .granted }
    }

    public var missingCritical: [PermissionKind] {
        PermissionKind.allCases.filter { $0.isCritical && states[$0] != .granted }
    }

    /// Emits a kind every time its state changes. Consume this to re-create the event tap when Input
    /// Monitoring arrives; a tap created while denied is permanently dead (RECON §11).
    public var changes: AsyncStream<PermissionKind> { changesStream }

    // MARK: Refreshing

    /// Re-reads every grant. Never prompts, so it is safe to call on a timer or on every activation.
    public func refresh() {
        for kind in PermissionKind.allCases {
            var fresh = PermissionProbe.state(for: kind)

            // Accessibility and PostEvent have no "not yet asked" API. If we have already put the
            // system prompt on screen and the bit is still false, the honest answer is `.denied` —
            // that is what routes the UI to the deep link instead of a prompt button that does nothing.
            if fresh == .notDetermined, prompted.contains(kind),
               kind == .accessibility || kind == .postEvent {
                fresh = .denied
            }

            guard states[kind] != fresh else { continue }
            let old = states[kind] ?? .unknown
            states[kind] = fresh
            Log.hotkey.notice("permission \(kind.rawValue, privacy: .public): \(String(describing: old), privacy: .public) -> \(String(describing: fresh), privacy: .public)")
            changesContinuation.yield(kind)
        }
    }

    // MARK: Requesting

    /// Shows the system prompt when one is still possible, and otherwise opens the right Settings pane.
    ///
    /// The distinction matters: RECON found that after TCC records a deny, `CGRequestListenEventAccess()`
    /// and `AXIsProcessTrustedWithOptions` are no-ops. A "Grant" button that silently does nothing is
    /// worse than no button, so a denied grant deep-links instead.
    public func request(_ kind: PermissionKind) async {
        switch kind {
        case .microphone:
            switch PermissionProbe.microphoneStatus {
            case .notDetermined:
                prompted.insert(kind)
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            case .denied, .restricted:
                openSettings(for: kind)
            default:
                break
            }

        case .inputMonitoring:
            switch PermissionProbe.inputMonitoringStatus {
            case kIOHIDAccessTypeGranted:
                break
            case kIOHIDAccessTypeUnknown:
                prompted.insert(kind)
                // Returns the *pre-prompt* state, so `false` here is not a failure.
                _ = CGRequestListenEventAccess()
            default:
                openSettings(for: kind)
            }

        case .accessibility:
            if PermissionProbe.accessibilityTrusted { break }
            if prompted.contains(kind) {
                openSettings(for: kind)
            } else {
                prompted.insert(kind)
                // RECON §10: `kAXTrustedCheckOptionPrompt` is imported as a mutable global `var`, so
                // referencing it is a hard error under the Swift 6 language mode. The literal string is
                // the symbol's actual runtime value (confirmed by dlsym in the probe).
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            }

        case .postEvent:
            if PermissionProbe.postEventGranted { break }
            // Same shape as Accessibility: `CGRequestPostEventAccess()` returns the *pre-prompt* state,
            // so a `false` return on a first call means "the prompt is now on screen", not "refused".
            // Only after we have already prompted once is deep-linking the right move.
            if prompted.contains(kind) {
                // No dedicated pane exists; Accessibility is what actually grants this.
                openSettings(for: kind)
            } else {
                prompted.insert(kind)
                _ = CGRequestPostEventAccess()
            }
        }

        refresh()
    }

    public func openSettings(for kind: PermissionKind) {
        guard let url = kind.settingsURL else {
            Log.hotkey.error("no settings URL for \(kind.rawValue, privacy: .public)")
            return
        }
        Log.hotkey.info("opening settings pane for \(kind.rawValue, privacy: .public)")
        NSWorkspace.shared.open(url)
        // The user is about to leave for System Settings; start watching for the switch to flip.
        beginPolling()
    }

    // MARK: Polling

    /// Poll while a settings pane or onboarding sheet is on screen, so the UI updates the instant the
    /// user flips the switch. There is no TCC notification to observe — polling is the only mechanism.
    public func beginPolling() {
        guard pollTask == nil else { return }
        Log.hotkey.debug("permission polling started")
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // 1 s is fast enough to feel instant next to a physical trip to System Settings, and
                // cheap: every probe is an in-process TCC cache read.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    public func endPolling() {
        guard pollTask != nil else { return }
        pollTask?.cancel()
        pollTask = nil
        Log.hotkey.debug("permission polling stopped")
    }

    /// Pays the one-time TCC/window-server bootstrap cost off the hot path. RECON §26 measured
    /// `AXIsProcessTrusted()` at 17–18 ms and the first system-wide AX read at 31–42 ms on a cold
    /// process — latency the user would otherwise see on their very first dictation.
    public func prewarm() {
        refresh()
    }
}
