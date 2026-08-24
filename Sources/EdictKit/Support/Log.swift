import os

/// The app's only logging surface. `print` is banned project-wide: the release build runs as a
/// signed .app with no attached terminal, so anything written to stdout is simply lost.
/// `os.Logger` shows up in Console.app and `log stream --predicate 'subsystem == "com.edict.app"'`.
public enum Log {
    /// Matches the bundle identifier's namespace but is deliberately independent of it — RECON §"bundle"
    /// showed `Bundle.main.bundleIdentifier` can be nil in dev-loop launches, and a nil subsystem would
    /// silently discard every message.
    public static let subsystem = "com.edict.app"

    /// Lifecycle, bootstrap, and the dictation state machine.
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    /// AVAudioEngine, taps, format conversion, level metering.
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    /// CGEventTap, push-to-talk hold detection, permission gating.
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    /// Accessibility / pasteboard / synthetic-keystroke injection.
    public static let inject = Logger(subsystem: subsystem, category: "inject")
    /// SpeechAnalyzer, DictationTranscriber, asset reservation.
    public static let stt = Logger(subsystem: subsystem, category: "stt")
    /// Settings, dictionary, history, on-disk persistence.
    public static let data = Logger(subsystem: subsystem, category: "data")
}
