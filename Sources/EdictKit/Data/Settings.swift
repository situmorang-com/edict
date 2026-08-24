import Foundation
import Observation

/// The push-to-talk key. Right Option is the default for a measured reason, not taste:
/// RECON §8 found this machine's Karabiner profile already claims `right_command`, `caps_lock` and
/// `fn`, that Siri holds a `.defaultTap` on `flagsChanged` ahead of us for `fn`, and that
/// `right_option` / `right_control` appear zero times in the active profile — but the only attached
/// keyboard (the internal one) has no Right Control key.
public enum HotkeyChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    case rightOption, rightCommand, rightControl, fn, f13

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rightOption: "Right Option (⌥)"
        case .rightCommand: "Right Command (⌘)"
        case .rightControl: "Right Control (⌃)"
        case .fn: "Fn / Globe (🌐)"
        case .f13: "F13"
        }
    }

    public var glyph: String {
        switch self {
        case .rightOption: "⌥"
        case .rightCommand: "⌘"
        case .rightControl: "⌃"
        case .fn: "🌐"
        case .f13: "F13"
        }
    }
}

/// User preferences, persisted to `UserDefaults.standard` under the `edict.` prefix.
///
/// Every property writes through on `didSet`. That is deliberately eager: settings changes are rare,
/// human-paced events, and a lost preference after a crash is far more annoying than the write cost.
@MainActor @Observable
public final class Settings {
    public static let shared = Settings()

    // MARK: Defaults

    public enum Default {
        public static let hotkey = HotkeyChoice.rightOption
        /// RECON §7: never derive this from `Locale.current`. This machine's locale is `en_ID`, which
        /// resolves to the `en-IN` acoustic model — silently the wrong one. Always start from `en-US`.
        public static let localeIdentifier = "en-US"
        public static let pushToTalk = true
        public static let autoInject = true
        public static let showHUD = true
        public static let playSounds = false
        public static let biasingEnabled = true
        /// RECON §5: cost is ~65 ms + ~1.5 ms/term at analyzer init and hit rate measurably *degrades*
        /// with list length (a 9-term list fixed terms a 200-term list did not). Hard cap, not advice.
        public static let biasingLimit = 50
        public static let correctionsEnabled = true
        public static let termCaseNormalisation = true
        /// RECON §22: pre-warming costs only 14–27 ms of captured speech but keeps the orange mic
        /// indicator lit for the whole session, which for a dictation tool reads as "always listening".
        public static let prewarmMicrophone = false
        public static let historyLimit = 5000
        public static let launchAtLogin = false
    }

    /// The hard ceiling on contextual strings handed to the analyzer. See `Default.biasingLimit`.
    public static let biasingLimitRange = 0...50
    public static let historyLimitRange = 10...100_000

    // MARK: Stored preferences

    public var hotkey: HotkeyChoice {
        didSet { write(hotkey.rawValue, .hotkey) }
    }

    public var localeIdentifier: String {
        didSet { write(localeIdentifier, .localeIdentifier) }
    }

    /// Hold-to-talk (release ends the utterance) vs press-once-to-start / press-again-to-stop.
    public var pushToTalk: Bool {
        didSet { write(pushToTalk, .pushToTalk) }
    }

    public var autoInject: Bool {
        didSet { write(autoInject, .autoInject) }
    }

    public var showHUD: Bool {
        didSet { write(showHUD, .showHUD) }
    }

    public var playSounds: Bool {
        didSet { write(playSounds, .playSounds) }
    }

    /// Feed dictionary terms to the engine as contextual strings (RECON §1: works on
    /// `DictationTranscriber`, a measured no-op on `SpeechTranscriber`).
    public var biasingEnabled: Bool {
        didSet { write(biasingEnabled, .biasingEnabled) }
    }

    /// Number of contextual strings sent to the analyzer. Clamped to `Settings.biasingLimitRange`
    /// on the way in — see `Default.biasingLimit` for why 50 is a ceiling and not a suggestion.
    public var biasingLimit: Int {
        didSet {
            // Assigning inside the observer does NOT re-enter it (Swift does not recurse into
            // willSet/didSet), so this converges in one step and the write below sees the clamped value.
            let clamped = Self.biasingLimitRange.clamped(to: biasingLimit)
            if clamped != biasingLimit { biasingLimit = clamped }
            write(biasingLimit, .biasingLimit)
        }
    }

    /// Run the guaranteed find-and-replace pass after transcription. This is layer 2 of the two-layer
    /// dictionary; RECON §5 is explicit that layer 1 (biasing) alone is not reliable.
    public var correctionsEnabled: Bool {
        didSet { write(correctionsEnabled, .correctionsEnabled) }
    }

    /// A `.term` entry also normalises the casing of that word in the output.
    public var termCaseNormalisation: Bool {
        didSet { write(termCaseNormalisation, .termCaseNormalisation) }
    }

    public var prewarmMicrophone: Bool {
        didSet { write(prewarmMicrophone, .prewarmMicrophone) }
    }

    public var historyLimit: Int {
        didSet {
            let clamped = Self.historyLimitRange.clamped(to: historyLimit)
            if clamped != historyLimit { historyLimit = clamped }
            write(historyLimit, .historyLimit)
        }
    }

    public var launchAtLogin: Bool {
        didSet { write(launchAtLogin, .launchAtLogin) }
    }

    // MARK: Lifecycle

    /// `defaults` is injectable so tests can use a throwaway suite instead of the user's real prefs.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Read straight from `defaults` here — the property observers are not active during `init`,
        // so this cannot accidentally write the defaults back out on first launch.
        func string(_ key: Key, _ fallback: String) -> String {
            defaults.string(forKey: key.storageKey) ?? fallback
        }
        func bool(_ key: Key, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key.storageKey) as? Bool ?? fallback
        }
        func int(_ key: Key, _ fallback: Int) -> Int {
            defaults.object(forKey: key.storageKey) as? Int ?? fallback
        }

        hotkey = HotkeyChoice(rawValue: string(.hotkey, Default.hotkey.rawValue)) ?? Default.hotkey
        localeIdentifier = string(.localeIdentifier, Default.localeIdentifier)
        pushToTalk = bool(.pushToTalk, Default.pushToTalk)
        autoInject = bool(.autoInject, Default.autoInject)
        showHUD = bool(.showHUD, Default.showHUD)
        playSounds = bool(.playSounds, Default.playSounds)
        biasingEnabled = bool(.biasingEnabled, Default.biasingEnabled)
        biasingLimit = Self.biasingLimitRange.clamped(to: int(.biasingLimit, Default.biasingLimit))
        correctionsEnabled = bool(.correctionsEnabled, Default.correctionsEnabled)
        termCaseNormalisation = bool(.termCaseNormalisation, Default.termCaseNormalisation)
        prewarmMicrophone = bool(.prewarmMicrophone, Default.prewarmMicrophone)
        historyLimit = Self.historyLimitRange.clamped(to: int(.historyLimit, Default.historyLimit))
        launchAtLogin = bool(.launchAtLogin, Default.launchAtLogin)
    }

    public func resetToDefaults() {
        hotkey = Default.hotkey
        localeIdentifier = Default.localeIdentifier
        pushToTalk = Default.pushToTalk
        autoInject = Default.autoInject
        showHUD = Default.showHUD
        playSounds = Default.playSounds
        biasingEnabled = Default.biasingEnabled
        biasingLimit = Default.biasingLimit
        correctionsEnabled = Default.correctionsEnabled
        termCaseNormalisation = Default.termCaseNormalisation
        prewarmMicrophone = Default.prewarmMicrophone
        historyLimit = Default.historyLimit
        launchAtLogin = Default.launchAtLogin
        Log.data.info("Settings reset to defaults")
    }

    /// The effective biasing list length: zero when biasing is off, so callers do not have to check both.
    public var effectiveBiasingLimit: Int { biasingEnabled ? biasingLimit : 0 }

    // MARK: Storage

    private enum Key: String {
        case hotkey, localeIdentifier, pushToTalk, autoInject, showHUD, playSounds
        case biasingEnabled, biasingLimit, correctionsEnabled, termCaseNormalisation
        case prewarmMicrophone, historyLimit, launchAtLogin

        var storageKey: String { "edict.\(rawValue)" }
    }

    private func write(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.storageKey)
    }
}

private extension ClosedRange where Bound == Int {
    func clamped(to value: Int) -> Int { Swift.min(Swift.max(value, lowerBound), upperBound) }
}

// MARK: - Ephemeral defaults

/// A `UserDefaults` that keeps every key in memory and never reaches `~/Library/Preferences`.
///
/// This is what tests, `#Preview` blocks and the offline render harness pass to
/// `Settings(defaults:)`. It exists instead of the obvious `UserDefaults(suiteName:)` plus a
/// `removePersistentDomain(forName:)` teardown because that pattern provably cannot clean up after
/// itself. Measured on this machine, for a suite that has had a single key written to it:
///
/// | teardown                                                        | `~/Library/Preferences/<suite>.plist` |
/// |-----------------------------------------------------------------|---------------------------------------|
/// | `removePersistentDomain(forName:)`                              | present, 42 bytes (`{ }`)             |
/// | + `synchronize()` + `removeSuite(named:)`                       | present, 42 bytes                     |
/// | + `FileManager.removeItem`                                      | gone for ~4 s, then **rewritten**     |
/// | never write to a suite at all                                   | never created                         |
///
/// Once anything has been written to a suite domain, cfprefsd owns it and re-persists an empty
/// dictionary on its own schedule, so no in-process cleanup wins the race. 85 stale
/// `com.edict.tests.<UUID>.plist` files had accumulated from a test suite that *did* call
/// `removePersistentDomain` from a `defer`. A domain that is never created cannot leak, so this
/// subclass is the fix rather than a more diligent teardown.
///
/// Only the four accessors `Settings` and its tests use had to be overridden: the typed getters
/// (`string(forKey:)`, `integer(forKey:)`, `bool(forKey:)`) are documented to funnel through
/// `object(forKey:)`, and a probe confirmed they do here.
///
/// `@unchecked Sendable`: `UserDefaults` is already `Sendable`, so the dictionary underneath has to
/// be guarded rather than merely main-actor-confined — a caller outside this module could hold this
/// as a plain `UserDefaults` and touch it from anywhere.
public final class EphemeralDefaults: UserDefaults, @unchecked Sendable {

    private let lock = NSLock()
    nonisolated(unsafe) private var store: [String: Any] = [:]

    /// `init(suiteName:)` is `UserDefaults`' only designated initializer and `nil` means "the default
    /// search list", which is the cheapest thing to hand the superclass. It never gets written to:
    /// every read and write below is answered out of `store` without reaching `super`.
    public init() {
        super.init(suiteName: nil)!
    }

    public override func object(forKey key: String) -> Any? {
        lock.withLock { store[key] }
    }

    public override func set(_ value: Any?, forKey key: String) {
        lock.withLock {
            if let value { store[key] = value } else { _ = store.removeValue(forKey: key) }
        }
    }

    public override func set(_ value: Int, forKey key: String) { set(value as Any, forKey: key) }
    public override func set(_ value: Bool, forKey key: String) { set(value as Any, forKey: key) }
    public override func set(_ value: Double, forKey key: String) { set(value as Any, forKey: key) }
    public override func set(_ value: Float, forKey key: String) { set(value as Any, forKey: key) }

    public override func removeObject(forKey key: String) {
        lock.withLock { _ = store.removeValue(forKey: key) }
    }
}
