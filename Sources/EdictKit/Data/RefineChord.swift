import Foundation

/// The gesture that opens the refine popup over whatever text is selected in another app.
///
/// ## Why the default is the dictation key *qualified* by `fn`, and how the ambiguity is resolved
///
/// The user asked for "fn+option", and Right Option already **is** dictation — it arms after ~120 ms
/// of hold. A chord that shares a key with a push-to-talk hold is ambiguous unless something breaks
/// the tie, and the only tie-breaker that needs no timer and no guessing is **order**: if `fn` is
/// already held at the instant the dictation key goes down, this is the popup gesture and dictation
/// does not arm. If the dictation key went down first, it is dictation, and `fn` arriving late is
/// ignored rather than allowed to cancel a recording the user is already speaking into.
///
/// That rule is implementable exactly, with no heuristics, because of one measured fact: **every
/// `.flagsChanged` carries the complete modifier state at that moment**, so the dictation key's own
/// down event says whether `fn` was already held. Measured on this machine through a listen-only
/// session tap, posting the chord and reading it back:
///
///     flagsChanged kc=63  raw=0x20800000  fn=SET   ralt=-      <- fn down
///     flagsChanged kc=61  raw=0x20880040  fn=SET   ralt=SET    <- Right Option down, fn still held
///     flagsChanged kc=61  raw=0x20800000  fn=SET   ralt=-      <- Right Option up
///     flagsChanged kc=63  raw=0x20000000  fn=-     ralt=-      <- fn up
///
/// 4 of 4 events delivered, nothing ahead of Edict in the tap chain consumed them — including Siri
/// and SiriNCService, which both hold *consuming* `.defaultTap` taps on `flagsChanged` at the same
/// tap point. Note the `0x20000000` present on every one of them: RECON amendment 31's rule (bit-test
/// flags, never compare a raw word) is not optional here either.
///
/// ## What is still a risk, and why `fn` is nevertheless allowed here when RECON forbids it as a hotkey
///
/// RECON lists `fn`/Globe under "DANGEROUS KEYS — DO NOT GRAB", and every reason it gives is about
/// `fn` as the *push-to-talk hold key*: macOS owns hold-`fn` and double-`fn`, it has no device bit so
/// left/right is undecidable, and the active Karabiner profile uses it as a layer. None of those
/// applies to a qualifier. Edict never arms anything on `fn` alone, never suppresses it, and never
/// has to know which `fn` was pressed — it reads one bit that is already present on an event it was
/// going to receive anyway. Checked on this machine before defaulting to it:
///
/// * the active Karabiner profile claims `fn`+`esc` and `fn`+`N` only, and `right_option` zero times,
///   so `fn`+Right Option is not remapped;
/// * exactly **one** input source is enabled (ABC), so the Globe key's default "change input source"
///   action has nothing to switch to;
/// * `AppleFnUsageType` is unset, so `fn` is not bound to dictation or the emoji picker.
///
/// The residual risk that could not be measured without a human at the keyboard: whether a
/// *physical* `fn` hold followed by Right Option behaves exactly as the synthesized one did. That is
/// the whole reason the two discrete chords below exist and the whole reason this is a setting.
public enum RefineChord: String, Codable, CaseIterable, Sendable, Identifiable {

    /// Hold `fn`, then press the dictation key. The user's stated gesture, and the default.
    case fnThenDictationKey

    /// `⌥⌘R`. Shares no key with hold-to-dictate, so the ordering rule never has to run.
    case optionCommandR

    /// `⌃⌥R`. The second discrete chord, for a machine where something else owns `⌥⌘R`.
    case controlOptionR

    public var id: String { rawValue }

    /// True when the chord is the dictation key qualified by another modifier — the family that has
    /// to be disambiguated by order, and the family that can be refused by the dictation key itself.
    public var qualifiesDictationKey: Bool {
        switch self {
        case .fnThenDictationKey: true
        case .optionCommandR, .controlOptionR: false
        }
    }

    /// The chord as key caps, for a settings row or a status line. Depends on the dictation key for
    /// the qualified family, which is exactly why it is a function and not a stored string.
    public func glyph(dictationKey: HotkeyChoice) -> String {
        switch self {
        case .fnThenDictationKey: "🌐 \(dictationKey.glyph)"
        case .optionCommandR: "⌥⌘R"
        case .controlOptionR: "⌃⌥R"
        }
    }

    public func displayName(dictationKey: HotkeyChoice) -> String {
        switch self {
        case .fnThenDictationKey: "Hold 🌐, then \(dictationKey.displayName)"
        case .optionCommandR: "⌥⌘R"
        case .controlOptionR: "⌃⌥R"
        }
    }

    /// One sentence saying what the gesture costs, so the choice between the families is informed
    /// rather than a coin toss.
    public var explanation: String {
        switch self {
        case .fnThenDictationKey:
            // "Fn" in the prose, the glyph only on the key caps: three coloured globes in one
            // paragraph of a monochrome panel read as clip art rather than as a key.
            "The order matters: Fn has to be down first. Press the dictation key first and you get "
                + "dictation, as always — an Fn that arrives late is ignored, and it never stops a "
                + "recording."
        case .optionCommandR:
            "Shares no key with dictation, so there is no order to get right. Some apps use ⌥⌘R "
                + "themselves; Edict only listens, so theirs still works."
        case .controlOptionR:
            "Shares no key with dictation, so there is no order to get right. Use this one if "
                + "something else on your Mac already owns ⌥⌘R."
        }
    }

    /// Why this chord cannot be used with the dictation key currently configured, or `nil`.
    ///
    /// One case, and it is real rather than defensive: `fn` qualifying `fn` is not a gesture. The
    /// picker refuses it instead of storing a setting that could never fire, which is the same rule
    /// `SecondLanguageRule` applies to the language modifier.
    public func refusal(dictationKey: HotkeyChoice) -> String? {
        guard self == .fnThenDictationKey, dictationKey == .fn else { return nil }
        return "Fn is already the dictation key, so it cannot also qualify it. Choose a discrete "
            + "chord, or change the dictation key."
    }
}
