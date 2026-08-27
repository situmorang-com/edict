import CoreGraphics
import Foundation

/// The gesture that opens the refine popup over whatever text is selected in another app.
///
/// ## Why the default is `⌘⌥/`, after two defaults that did not survive contact with the keyboard
///
/// This is the third answer to one question — "what can Edict listen for, from inside somebody
/// else's window, without touching the selection it is about to replace?" — and each of the first
/// two failed for a reason worth keeping written down, because both look correct on paper.
///
/// ### 1. `fn` was a bad default, and the measurement that cleared it was too narrow
///
/// `fn` was measured working: held first, it shows up as `maskSecondaryFn` on the dictation key's own
/// `.flagsChanged`, which makes the ordering rule exact. But it was measured **on the built-in Apple
/// keyboard only**, and that is the one keyboard where the bit exists. Third-party keyboards — the
/// user's Logitech among them — resolve `fn` in their own firmware and send the *resulting* keycode;
/// macOS never sees an `fn` transition at all, so `maskSecondaryFn` is never set and **no**
/// application can observe the key. Not a permission problem and not a tap-ordering problem: there is
/// no event. So `fn` is demoted to an option, labelled Apple-keyboard-only in the picker, and the
/// reason is said in one sentence there rather than left for the user to discover as a chord that
/// does nothing.
///
/// ### 2. The whole slash family types characters — except with Command
///
/// The obvious replacement was a slash chord, and every shorter one **inserts text**. Measured with
/// `UCKeyTranslate` against this machine's ABC layout:
///
///     /    -> "/"
///     ⌥/   -> "÷"
///     ⌃⌥/  -> "/"
///     ⇧⌥/  -> "¿"
///
/// A trigger that inserts a character would **replace the user's selection before Edict could read
/// it** — precisely the failure this whole feature exists to avoid, and it would happen on the very
/// first press. `⌘⌥/` inserts nothing, because macOS routes a Command chord as a key equivalent
/// rather than as typed text. That, and not brevity, is why the chord carries Command.
///
/// ### 3. Nothing is inserted, so nothing has to be suppressed — and that is the point
///
/// Because `⌘⌥/` produces no character, Edict does not have to *consume* the trigger to keep the
/// selection intact. So it keeps holding exactly **one listen-only tap at idle** (RECON
/// amendment 42); the key-suppressing tap still exists only while the popup is on screen, for the
/// digit keys. **Do not add a consuming tap for the trigger.** A consuming `.defaultTap` at idle
/// would put Edict in the path of every keystroke the user types all day, which is a different and
/// much larger promise than this feature is worth.
///
/// ### 4. The remapper was checked, not assumed
///
/// RECON's standing rule is that the active Karabiner profile owns keys before Edict does. Its only
/// rule on `slash` *with* modifiers requires all four of `left_command, left_option, left_control,
/// left_shift` as mandatory (a Safari navigation mapping), so plain `⌘⌥/` does not match it — which
/// is also why ``matches(keyCode:rawFlags:)`` must *forbid* Control and Shift rather than merely
/// ignore them: without that, Edict would fire in the middle of the user's Safari shortcut. The only
/// other `slash` rule is bare `slash` behind a caps-lock layer variable, which no modifier chord
/// reaches.
///
/// ## Everything here is a bit test
///
/// RECON amendment 31: a keyboard remapper stamps `nonCoalesced` (`0x100`) on every event it
/// synthesizes, and a freshly constructed `CGEvent` carries `0x2000_0000`. Comparing a raw flags word
/// for equality is how a chord silently never fires. ``Discrete`` therefore expresses itself as
/// *required* and *forbidden* masks, and ``matches(keyCode:rawFlags:)`` only ever ands.
public enum RefineChord: String, Codable, CaseIterable, Sendable, Identifiable {

    /// `⌘⌥/`. The default: it inserts no character, so it needs no suppression, and it collides with
    /// nothing on this machine. See the type's own note for the measurements behind all three claims.
    case commandOptionSlash

    /// `⌥⌘R`. Shares no key with hold-to-dictate either; kept because some Macs already own `⌘⌥/`
    /// in an app the user cares about more than this.
    case optionCommandR

    /// `⌃⌥R`. The third discrete chord, for a machine where something else owns `⌥⌘R`.
    case controlOptionR

    /// Hold `fn`, then press the dictation key. **Apple keyboards only** — see the type's note. It
    /// was the default until it was measured on a second keyboard; it is last in the picker now.
    case fnThenDictationKey

    public var id: String { rawValue }

    /// The shipped default, named here rather than at the `Settings.Default` call site so the reason
    /// and the value live in the same file.
    public static let `default`: RefineChord = .commandOptionSlash

    // MARK: - The decision table
    //
    // Pure logic over `(keyCode, rawFlags)`, deliberately in this file rather than in the event tap:
    // the tap needs a machine, and this is the part that is worth proving without one.

    /// A chord that is recognised from one `.keyDown`: a keycode plus a required-and-forbidden pair
    /// of flag masks.
    ///
    /// Forbidden masks are not decoration. `⌘⌥/` and the user's four-modifier Safari mapping share
    /// every bit `⌘⌥/` requires, and the *only* thing that tells them apart is that the Safari one
    /// also carries Control and Shift.
    public struct Discrete: Sendable, Hashable {

        /// Virtual keycodes, standard values (`Carbon.HIToolbox`, kept as literals so this file needs
        /// no framework import for three numbers).
        enum KeyCode {
            static let r: Int64 = 15       // kVK_ANSI_R
            static let slash: Int64 = 44   // kVK_ANSI_Slash
        }

        public let keyCode: Int64
        /// Every bit in here must be SET.
        public let requiredFlags: UInt64
        /// Any bit in here being set disqualifies the match.
        public let forbiddenFlags: UInt64

        /// Side-agnostic modifier bits. Either hand counts, and it has to: the user's Karabiner
        /// profile leans on the left-hand Command and Option, while a right-handed reach for the same
        /// chord is the same gesture. The *side* only ever enters as an exclusion, and only for the
        /// dictation key's own side — that lives in `RefineChordBinding`, next to the rest of the
        /// device-bit knowledge, because it depends on a setting this table does not know about.
        static let command = UInt64(CGEventFlags.maskCommand.rawValue)
        static let option = UInt64(CGEventFlags.maskAlternate.rawValue)
        static let control = UInt64(CGEventFlags.maskControl.rawValue)
        static let shift = UInt64(CGEventFlags.maskShift.rawValue)

        public func matches(keyCode: Int64, rawFlags: UInt64) -> Bool {
            guard keyCode == self.keyCode else { return false }
            // Ands only. Never `rawFlags == something` (RECON amendment 31).
            return rawFlags & requiredFlags == requiredFlags && rawFlags & forbiddenFlags == 0
        }
    }

    /// The chord's own keycode and masks, or `nil` for the qualified family, which is recognised from
    /// a `.flagsChanged` instead and has no keycode of its own.
    public var discrete: Discrete? {
        typealias D = Discrete
        switch self {
        case .commandOptionSlash:
            // Command and Option, either side, and neither Control nor Shift — the second half is
            // what keeps ⌘⌥⌃⇧/ (Safari) out.
            return Discrete(
                keyCode: D.KeyCode.slash,
                requiredFlags: D.command | D.option,
                forbiddenFlags: D.control | D.shift
            )
        case .optionCommandR:
            return Discrete(
                keyCode: D.KeyCode.r,
                requiredFlags: D.option | D.command,
                forbiddenFlags: D.control | D.shift
            )
        case .controlOptionR:
            return Discrete(
                keyCode: D.KeyCode.r,
                requiredFlags: D.control | D.option,
                forbiddenFlags: D.command | D.shift
            )
        case .fnThenDictationKey:
            return nil
        }
    }

    /// Does this event *fire* the chord? The whole decision, for the discrete family, in one call.
    ///
    /// Answers `false` for the qualified family rather than trapping: `fn`-then-dictation-key is
    /// decided in the `.flagsChanged` branch from the qualifier bit, and a `.keyDown` never fires it.
    public func matches(keyCode: Int64, rawFlags: UInt64) -> Bool {
        discrete?.matches(keyCode: keyCode, rawFlags: rawFlags) ?? false
    }

    /// True when the chord is the dictation key qualified by another modifier — the family that has
    /// to be disambiguated by order, and the family that can be refused by the dictation key itself.
    public var qualifiesDictationKey: Bool {
        switch self {
        case .fnThenDictationKey: true
        case .commandOptionSlash, .optionCommandR, .controlOptionR: false
        }
    }

    // MARK: - Copy

    /// The chord as key caps, for a settings row or a status line. Depends on the dictation key for
    /// the qualified family, which is exactly why it is a function and not a stored string.
    public func glyph(dictationKey: HotkeyChoice) -> String {
        switch self {
        case .commandOptionSlash: "⌘⌥/"
        case .optionCommandR: "⌥⌘R"
        case .controlOptionR: "⌃⌥R"
        case .fnThenDictationKey: "🌐 \(dictationKey.glyph)"
        }
    }

    public func displayName(dictationKey: HotkeyChoice) -> String {
        switch self {
        case .commandOptionSlash: "⌘⌥/"
        case .optionCommandR: "⌥⌘R"
        case .controlOptionR: "⌃⌥R"
        case .fnThenDictationKey: "Hold 🌐, then \(dictationKey.displayName)"
        }
    }

    /// A short tag for the picker row itself, next to the keys — or `nil` when the row needs no
    /// warning. Only one chord has one, and it is the one that cannot work on most keyboards.
    public var rowCaveat: String? {
        switch self {
        case .fnThenDictationKey: "Apple keyboards only"
        case .commandOptionSlash, .optionCommandR, .controlOptionR: nil
        }
    }

    /// One sentence saying what the gesture costs, so the choice between them is informed rather than
    /// a coin toss.
    public var explanation: String {
        switch self {
        case .commandOptionSlash:
            "Works on any keyboard, and shares no key with hold-to-dictate. Command is what makes "
                + "it safe: ⌥/ would type ÷ over the selection Edict is about to read, and ⌘⌥/ types "
                + "nothing at all, so Edict can just listen."
        case .optionCommandR:
            "Shares no key with dictation, so there is no order to get right. Some apps use ⌥⌘R "
                + "themselves; Edict only listens, so theirs still works."
        case .controlOptionR:
            "Shares no key with dictation, so there is no order to get right. Use this one if "
                + "something else on your Mac already owns ⌥⌘R."
        case .fnThenDictationKey:
            // "Fn" in the prose, the glyph only on the key caps: three coloured globes in one
            // paragraph of a monochrome panel read as clip art rather than as keys.
            "Only on Apple's own keyboards. Most others — Logitech, Keychron, Das — handle Fn inside "
                + "the keyboard and never tell macOS it was pressed, so no app can see it and this "
                + "gesture cannot fire at all. On an Apple keyboard the order matters: Fn has to be "
                + "down first, and an Fn that arrives late is ignored rather than stopping a "
                + "recording."
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

    // MARK: - Migration
    //
    // ## The stored value is NOT migrated, and this is the reasoning
    //
    // `fnThenDictationKey` used to be the default. Anyone stuck on a gesture their keyboard cannot
    // send is a real user with a real problem, so migrating them was considered and rejected, for
    // one structural reason: **`refineSelectionChord` is written to `UserDefaults` only by the
    // picker.** `Settings.init` reads the key and falls back when it is absent; nothing writes it at
    // launch. So the two populations are already distinguishable without a migration flag:
    //
    // * **Never chose** — the key is absent, and they get `RefineChord.default` (`⌘⌥/`) on the next
    //   launch for free. This is everybody who simply took the old default, which is nearly
    //   everybody, and it is the population the user was actually asking about.
    // * **Chose Fn deliberately** — the key holds `"fnThenDictationKey"`, and it is kept. Silently
    //   rewriting a setting somebody picked by hand is worse than the problem it solves, and a
    //   one-shot "migrated" flag to make the rewrite happen exactly once would add a second stored
    //   key to paper over a choice we can already read correctly.
    //
    // What they get instead is legibility, in the place where the choice was made: the picker row
    // says "Apple keyboards only" (``rowCaveat``) and ``explanation`` says why in plain words. A
    // caveat the user can read beats a setting that changes under them.
    //
    // If this ever does need migrating — a *third* default, say — the flag belongs next to the key in
    // `Settings`, not here, and this comment should say which way it went.
}
