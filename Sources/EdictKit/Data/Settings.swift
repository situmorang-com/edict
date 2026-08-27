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

/// A bare modifier that can be held *alongside* the push-to-talk key to change something about the
/// utterance. Edict uses exactly one of these, for the secondary dictation locale.
///
/// Deliberately locale-agnostic: `HotkeyMonitor` reports "this modifier was held" and nothing more,
/// and the mapping from that boolean to a language lives in `DictationController`. The bit masks and
/// keycodes are in `HotkeyMonitor.swift` next to the rest of the device-bit knowledge.
///
/// Why a modifier at all, rather than a second hotkey: RECON §8 found that the only keys this
/// machine's active Karabiner profile leaves alone are `right_option` and `right_control`, and the
/// only attached keyboard has no Right Control key — so there is no second key to give out. Shift
/// appears in the profile only as a *combination condition*, never as a `from` key, so it is not
/// swallowed by the remapper and its state is readable.
public enum HotkeyModifier: String, Codable, CaseIterable, Sendable, Identifiable {
    case shift, control, command, option

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .shift: "Shift (⇧)"
        case .control: "Control (⌃)"
        case .command: "Command (⌘)"
        case .option: "Option (⌥)"
        }
    }

    public var glyph: String {
        switch self {
        case .shift: "⇧"
        case .control: "⌃"
        case .command: "⌘"
        case .option: "⌥"
        }
    }
}

/// User preferences, persisted to `UserDefaults.standard` under the `edict.` prefix.
///
/// **"Open at login" is deliberately not here.** It used to be, as a `Bool` that nothing read: the
/// switch wrote a preference and no `SMAppService` call existed anywhere in the app, so the control
/// silently lied. The fix is not a better-behaved preference — it is having no preference at all.
/// `SMAppService.mainApp.status` is the only truth about whether macOS will launch Edict, it survives
/// reinstalls and it can be changed behind Edict's back in System Settings, so a mirror of it in
/// `UserDefaults` could only ever go stale. See `LoginItem` in `AppModel.swift`.
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
        /// On by default. The user of this build is Indonesian, works bilingually, and the locale is
        /// fixed per utterance by the framework — `DictationTranscriber` takes one `Locale` and there
        /// is no multilingual model that covers Indonesian (`mul_IN` exists on `SpeechTranscriber`
        /// only, which does not support `id-ID` at all). Automatic detection is therefore impossible,
        /// and switching languages in Settings before every sentence is not a workflow.
        public static let secondaryLocaleEnabled = true
        public static let secondaryLocaleIdentifier = "id-ID"
        /// RECON §8: `right_option` survives Karabiner's DriverKit virtual keyboard with its device
        /// bit intact, and Shift is referenced in the active profile only as a combination condition,
        /// so it is neither remapped nor swallowed.
        public static let secondaryLocaleModifier = HotkeyModifier.shift
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
        /// Use `SpeechTranscriber` for file imports where it covers the locale. On by default
        /// because it is measurably better at the job — 4.2 % word error against 10.1 % and 66x
        /// realtime against 15x on the same 377 s file. See `SpeechEngine.build`.
        public static let importUsesGeneralModel = true
        /// **Off**, and it stays off unless the user asks for it.
        ///
        /// Measured cost: **4.3–5.1x the wall clock** of a single pass (0.29 s → 1.25 s on a
        /// 17-second clip, 4.34 s → 22.31 s on a 377-second one — the per-utterance finalize latency
        /// is paid once per section per language, not once per file), plus the whole decoded file
        /// held in memory at 32 KB per second of audio, about 128 MB for a 70-minute meeting.
        ///
        /// Measured benefit: on clean bilingual audio it is large — 41.5 % word error down to 7.3 %
        /// on the 17-second four-turn fixture. On the real 70-minute far-field meeting this project
        /// was diagnosed against it is nil: the Indonesian model produced 18 words in 300 s where the
        /// English model produced 61, and choosing between two transcripts neither of which contains
        /// the speech is not a fix. On by default would present it as one.
        public static let importDualPass = false
        /// **Off**, because it changes what kind of tool Edict is.
        ///
        /// Measured on this machine: clean-up costs 1.0 s warm and 2.9 s cold, *added to every
        /// dictation* between the last word and the text appearing. Dictation's own end-to-end tail
        /// is 0.15–0.53 s, so this is not a percentage — it is several times the whole wait, on a
        /// key the user holds down expecting the text to be there when they let go. A user who
        /// wants that trade can have it; a user who never opens Settings must not be given it.
        public static let refineBeforeInsert = false
        public static let historyLimit = 5000
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

    /// Hold the push-to-talk key *plus* `secondaryLocaleModifier` to dictate one utterance in
    /// `secondaryLocaleIdentifier` instead of `localeIdentifier`.
    ///
    /// A per-utterance modifier rather than a mode or a menu-bar toggle, and that is the whole design:
    /// a mode means discovering you dictated an entire paragraph in the wrong language. The modifier
    /// decides one utterance at a time, so the user cannot drift.
    public var secondaryLocaleEnabled: Bool {
        didSet { write(secondaryLocaleEnabled, .secondaryLocaleEnabled) }
    }

    /// The language of an utterance dictated with the modifier held. Validated against the framework's
    /// own list at launch — see `reconcileSecondaryLocale(supportedIdentifiers:)`.
    public var secondaryLocaleIdentifier: String {
        didSet { write(secondaryLocaleIdentifier, .secondaryLocaleIdentifier) }
    }

    public var secondaryLocaleModifier: HotkeyModifier {
        didSet { write(secondaryLocaleModifier.rawValue, .secondaryLocaleModifier) }
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

    /// Transcribe imported files with `SpeechTranscriber` rather than `DictationTranscriber`.
    ///
    /// The trade is real in both directions, which is why it is a switch and not a constant: the
    /// general model is far more accurate and much faster on a whole file, but contextual-string
    /// biasing is a measured no-op on it (RECON §1), so layer 1 of the dictionary does nothing for
    /// an import that uses it. Off puts imports on the same model as live dictation, biasing and
    /// all. Either way the correction pass still runs, and either way a locale the general model
    /// does not cover — Indonesian — falls back automatically.
    public var importUsesGeneralModel: Bool {
        didSet { write(importUsesGeneralModel, .importUsesGeneralModel) }
    }

    /// Transcribe each section of an imported file in **both** configured languages and keep whichever
    /// transcript reads more like the language that produced it.
    ///
    /// This is a heuristic over two finished transcripts, not language detection. Apple's speech
    /// framework has no language identification at all: a `DictationTranscriber` is constructed for
    /// one `Locale` and will transcribe anything you feed it in that language, confidently and
    /// wrongly. So Edict transcribes twice and `LanguageScorer` reads the two results for function
    /// words and affixes. Where the margin is not decisive the primary language wins by default,
    /// which is the cheaper of the two mistakes.
    ///
    /// Only has any effect when `effectiveSecondaryLocaleIdentifier` is non-nil — there is nothing
    /// to compare against otherwise. See `Default.importDualPass` for the costs.
    public var importDualPass: Bool {
        didSet { write(importDualPass, .importDualPass) }
    }

    /// True when an import should actually run two passes: the switch is on *and* there is a second
    /// language configured to run the second pass in.
    public var dualPassIsActive: Bool {
        importDualPass && effectiveSecondaryLocaleIdentifier != nil
    }

    /// Clean up a dictation with the on-device language model before it reaches the cursor.
    ///
    /// The whole cost of this switch is latency, and it is a cost the user pays on *every* dictation
    /// rather than when they ask: measured 1.0 s warm and 2.9 s cold on top of a 0.15–0.53 s tail.
    /// That is why it is off by default and why the settings copy quotes the numbers instead of
    /// describing the feature. Refinement runs entirely on this Mac either way — the same
    /// `TextRefiner` the history pane uses, so nothing new leaves the machine.
    ///
    /// A refinement that fails or is declined never costs the dictation: what was said is inserted
    /// unchanged and `Transcript.refinement.failure` records why. See `DictationController.complete`.
    public var refineBeforeInsert: Bool {
        didSet { write(refineBeforeInsert, .refineBeforeInsert) }
    }

    public var historyLimit: Int {
        didSet {
            let clamped = Self.historyLimitRange.clamped(to: historyLimit)
            if clamped != historyLimit { historyLimit = clamped }
            write(historyLimit, .historyLimit)
        }
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
        secondaryLocaleEnabled = bool(.secondaryLocaleEnabled, Default.secondaryLocaleEnabled)
        secondaryLocaleIdentifier = string(.secondaryLocaleIdentifier, Default.secondaryLocaleIdentifier)
        secondaryLocaleModifier = HotkeyModifier(
            rawValue: string(.secondaryLocaleModifier, Default.secondaryLocaleModifier.rawValue)
        ) ?? Default.secondaryLocaleModifier
        pushToTalk = bool(.pushToTalk, Default.pushToTalk)
        autoInject = bool(.autoInject, Default.autoInject)
        showHUD = bool(.showHUD, Default.showHUD)
        playSounds = bool(.playSounds, Default.playSounds)
        biasingEnabled = bool(.biasingEnabled, Default.biasingEnabled)
        biasingLimit = Self.biasingLimitRange.clamped(to: int(.biasingLimit, Default.biasingLimit))
        correctionsEnabled = bool(.correctionsEnabled, Default.correctionsEnabled)
        termCaseNormalisation = bool(.termCaseNormalisation, Default.termCaseNormalisation)
        prewarmMicrophone = bool(.prewarmMicrophone, Default.prewarmMicrophone)
        importUsesGeneralModel = bool(.importUsesGeneralModel, Default.importUsesGeneralModel)
        importDualPass = bool(.importDualPass, Default.importDualPass)
        refineBeforeInsert = bool(.refineBeforeInsert, Default.refineBeforeInsert)
        historyLimit = Self.historyLimitRange.clamped(to: int(.historyLimit, Default.historyLimit))
    }

    public func resetToDefaults() {
        hotkey = Default.hotkey
        localeIdentifier = Default.localeIdentifier
        secondaryLocaleEnabled = Default.secondaryLocaleEnabled
        secondaryLocaleIdentifier = Default.secondaryLocaleIdentifier
        secondaryLocaleModifier = Default.secondaryLocaleModifier
        pushToTalk = Default.pushToTalk
        autoInject = Default.autoInject
        showHUD = Default.showHUD
        playSounds = Default.playSounds
        biasingEnabled = Default.biasingEnabled
        biasingLimit = Default.biasingLimit
        correctionsEnabled = Default.correctionsEnabled
        termCaseNormalisation = Default.termCaseNormalisation
        prewarmMicrophone = Default.prewarmMicrophone
        importUsesGeneralModel = Default.importUsesGeneralModel
        importDualPass = Default.importDualPass
        refineBeforeInsert = Default.refineBeforeInsert
        historyLimit = Default.historyLimit
        Log.data.info("Settings reset to defaults")
    }

    /// The effective biasing list length: zero when biasing is off, so callers do not have to check both.
    public var effectiveBiasingLimit: Int { biasingEnabled ? biasingLimit : 0 }

    // MARK: Secondary locale validation

    /// The identifier a secondary-locale utterance should actually use, or `nil` when the shortcut is
    /// off or points at the primary language anyway (in which case the modifier is a no-op and the
    /// utterance is just an ordinary one).
    public var effectiveSecondaryLocaleIdentifier: String? {
        guard secondaryLocaleEnabled else { return nil }
        let trimmed = secondaryLocaleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard Self.localeKey(trimmed) != Self.localeKey(localeIdentifier) else { return nil }
        return trimmed
    }

    /// Compare `en-US`, `en_US` and `EN-us` as the same thing.
    ///
    /// Load-bearing rather than tidy: `DictationTranscriber.supportedLocales` reports **underscored**
    /// identifiers (`id_ID`), Edict stores hyphenated ones (`id-ID`), and RECON §6 records that
    /// `AssetInventory.release` matches on the raw identifier string — so anything comparing these two
    /// forms naively concludes the locale is unsupported and silently disables the feature.
    public static func localeKey(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "-", with: "_").lowercased()
    }

    /// Drop a secondary locale the speech framework cannot actually serve.
    ///
    /// Called once at launch with `DictationTranscriber.supportedLocales`. A stale value — a locale
    /// that was removed by an OS update, or a hand-edited `defaults write` — must not be able to wedge
    /// dictation: the modifier would then throw on every press with nothing the user could do from the
    /// UI. Falling back to the default identifier, and turning the shortcut off if that is unsupported
    /// too, keeps the primary language working no matter what is in the preference.
    ///
    /// Takes the list as a parameter rather than importing `Speech` here so it stays a pure function
    /// the tests can drive. The caller (`DictationController.prewarm`) has the framework's answer.
    ///
    /// - Returns: true when something had to be changed.
    @discardableResult
    public func reconcileSecondaryLocale(supportedIdentifiers: [String]) -> Bool {
        guard secondaryLocaleEnabled else { return false }
        let supported = Set(supportedIdentifiers.map(Self.localeKey))
        guard !supported.isEmpty else { return false }   // nothing to validate against; leave it alone

        if supported.contains(Self.localeKey(secondaryLocaleIdentifier)) { return false }

        let previous = secondaryLocaleIdentifier
        if supported.contains(Self.localeKey(Default.secondaryLocaleIdentifier)) {
            secondaryLocaleIdentifier = Default.secondaryLocaleIdentifier
            Log.data.error("""
                secondary locale \(previous, privacy: .public) is not supported; \
                reset to \(Default.secondaryLocaleIdentifier, privacy: .public)
                """)
        } else {
            secondaryLocaleEnabled = false
            Log.data.error("""
                secondary locale \(previous, privacy: .public) is not supported and neither is the \
                default; the language shortcut is off
                """)
        }
        return true
    }

    // MARK: Storage

    private enum Key: String {
        case hotkey, localeIdentifier, pushToTalk, autoInject, showHUD, playSounds
        case secondaryLocaleEnabled, secondaryLocaleIdentifier, secondaryLocaleModifier
        case biasingEnabled, biasingLimit, correctionsEnabled, termCaseNormalisation
        case prewarmMicrophone, importUsesGeneralModel, importDualPass, historyLimit
        case refineBeforeInsert

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
