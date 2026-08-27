import CoreGraphics
import Foundation

/// The gesture that opens the refine popup over whatever text is selected in another app.
///
/// ## Why the default is `fn + /`, after three defaults that did not survive the keyboard
///
/// This is the fourth answer to one question — "what can Edict listen for, from inside somebody
/// else's window, without touching the selection it is about to replace?" — and each earlier answer
/// failed for a reason worth keeping written down, because all of them look correct on paper. The
/// search is over because the user ran out of candidates, not because this one is obvious: `⌘⌥/` is
/// Alfred's on this machine, `⌥/` types `÷` and `⌥'` types `æ`, and `⌃fn/` was rejected as a
/// three-finger reach.
///
/// ### 1. `fn` alone was a bad default, and the measurement that cleared it was too narrow
///
/// `fn` held first, then the dictation key, was measured working: it shows up as `maskSecondaryFn` on
/// the dictation key's own `.flagsChanged`, which makes the ordering rule exact. But it was measured
/// **on the built-in Apple keyboard only**, and that is the one keyboard where the bit exists.
/// Third-party keyboards — the user's Logitech among them — resolve `fn` in their own firmware and
/// send the *resulting* keycode; macOS never sees an `fn` transition at all, so `maskSecondaryFn` is
/// never set and **no** application can observe the key (RECON amendment 48). Not a permission
/// problem and not a tap-ordering problem: there is no event.
///
/// ### 2. The whole slash family types characters — and that was the objection
///
/// Measured with `UCKeyTranslate` against this machine's ABC layout:
///
///     /     -> "/"
///     ⌥/    -> "÷"
///     ⌃/    -> "/"
///     ⌃⌥/   -> "/"
///     ⇧⌥/   -> "¿"
///     fn/   -> "/"
///
/// Only a `⌘`-bearing chord inserts nothing, because macOS routes those as key equivalents rather
/// than as typed text. A trigger that inserts a character would **replace the user's selection before
/// Edict could read it** — precisely the failure this whole feature exists to avoid.
///
/// ### 3. Why `fn + /` is the one place a consuming trigger is the right trade
///
/// `fn + /` inserts a `/`, so it can only work if Edict *swallows* it. Everywhere else that price was
/// refused, and rightly: eating `⌥/` would cost the user the only way they have to type `÷`, and
/// eating `⌥'` the only way to type `æ`. `fn + /` costs them **nothing**, because it is a redundant
/// way to type a character they already have on an unmodified key. That asymmetry, and not
/// convenience, is what buys the second event tap (see ``RefineChord/Discrete/consumesTrigger`` and
/// RECON amendment 50).
///
/// ### 4. Why one setting needs two chords
///
/// `fn` is invisible on the user's Logitech (§1) and they work on both keyboards, so `fnSlash` fires
/// on either of two shapes and says so in the picker:
///
/// * **`fn + /`** — keycode 44 with `maskSecondaryFn` set. Apple keyboards. Consumed, per §3.
/// * **`⌃⌘/`** — keycode 44 with Control and Command. Any keyboard, because both modifiers reach
///   macOS from firmware that resolves nothing. It carries `⌘`, so it inserts nothing and is
///   **passed through** rather than swallowed: suppression is only ever bought where it is needed.
///
/// One setting, not two, so there is nothing to keep in sync — and nothing for a user who moves
/// between keyboards to remember.
///
/// ### 5. The remapper and the launcher were checked, not assumed
///
/// RECON's standing rule is that the active Karabiner profile owns keys before Edict does. Its only
/// rule on `slash` *with* modifiers requires all four of `left_command, left_option, left_control,
/// left_shift` (a Safari navigation mapping), so neither shape matches it — which is also why
/// ``matches(keyCode:rawFlags:)`` must *forbid* modifiers rather than merely ignore them. The other
/// `slash` rule is bare `slash` behind a caps-lock layer variable, which no chord reaches. Alfred
/// holds no keycode-44 hotkey in either its synced preferences or its local storage, which is what
/// disqualified `⌘⌥/`.
///
/// ## Everything here is a bit test
///
/// RECON amendment 31: a keyboard remapper stamps `nonCoalesced` (`0x100`) on every event it
/// synthesizes, and a freshly constructed `CGEvent` carries `0x2000_0000`. Comparing a raw flags word
/// for equality is how a chord silently never fires. ``Discrete`` therefore expresses itself as
/// *required* and *forbidden* masks, and ``matches(keyCode:rawFlags:)`` only ever ands.
public enum RefineChord: String, Codable, CaseIterable, Sendable, Identifiable {

    /// `fn + /` on an Apple keyboard, **or** `⌃⌘/` on any keyboard — one setting, two shapes, the
    /// same popup. The default, and the only chord Edict swallows; see §3 and §4 of the type's note
    /// for why that is the right trade here and nowhere else.
    case fnSlash

    /// `⌘⌥/`. The previous default, kept: it inserts no character, so it needs no suppression. It
    /// stopped being the default because Alfred owns it on this machine.
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
    public static let `default`: RefineChord = .fnSlash

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
        /// Whether recognising this shape requires **swallowing** the `.keyDown`.
        ///
        /// True for exactly one shape in this file — `fn + /`, which types a `/` — and the reason it
        /// is a property rather than a rule is that consumption is bought per *shape*, not per chord:
        /// `fnSlash`'s `⌃⌘/` alias carries `⌘`, inserts nothing, and is passed through. The two sets
        /// are disjoint by construction, which is what lets one tap own the swallowed shapes and the
        /// other own the rest with no chance of a doubled gesture (see `RefineChordBinding`).
        public let consumesTrigger: Bool

        init(
            keyCode: Int64,
            requiredFlags: UInt64,
            forbiddenFlags: UInt64,
            consumesTrigger: Bool = false
        ) {
            self.keyCode = keyCode
            self.requiredFlags = requiredFlags
            self.forbiddenFlags = forbiddenFlags
            self.consumesTrigger = consumesTrigger
        }

        /// `fn`/Globe. There is no device-dependent bit for it (RECON §9): it is legible *only* as
        /// `maskSecondaryFn`, and that same bit rides on the `.keyDown` of every arrow and fn-row key
        /// — which is harmless here because a shape is a keycode *and* a mask, and those keys carry
        /// their own keycodes.
        static let fn = UInt64(CGEventFlags.maskSecondaryFn.rawValue)

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

    /// Every `.keyDown` shape that fires this chord, in the order they are documented. Empty for the
    /// qualified family, which is recognised from a `.flagsChanged` instead and has no keycode.
    ///
    /// A list rather than one shape because `fnSlash` is deliberately two: `fn` cannot be observed at
    /// all on a keyboard that resolves it in firmware (RECON amendment 48), and this user works on
    /// both an Apple keyboard and a Logitech. Two shapes behind one setting is the only way to cover
    /// both without asking them to remember which machine they are on.
    public var discretes: [Discrete] {
        typealias D = Discrete
        switch self {
        case .fnSlash:
            return [
                // fn + / — the user-facing gesture, Apple keyboards. Every other modifier is
                // forbidden: ⇧fn/ types "?" and ⌃fn/ was a candidate the user rejected, so neither
                // may be mistaken for this. CONSUMED, because fn+/ types a "/" and swallowing it
                // costs nothing (§3).
                Discrete(
                    keyCode: D.KeyCode.slash,
                    requiredFlags: D.fn,
                    forbiddenFlags: D.command | D.option | D.control | D.shift,
                    consumesTrigger: true
                ),
                // ⌃⌘/ — the keyboard-independent alias. Not consumed: it carries ⌘, so macOS treats
                // it as a key equivalent and it inserts nothing. Option and Shift are forbidden, which
                // is what keeps the user's four-modifier Safari mapping (⌃⌥⌘⇧/) out.
                Discrete(
                    keyCode: D.KeyCode.slash,
                    requiredFlags: D.control | D.command,
                    forbiddenFlags: D.option | D.shift
                ),
            ]
        case .commandOptionSlash:
            // Command and Option, either side, and neither Control nor Shift — the second half is
            // what keeps ⌘⌥⌃⇧/ (Safari) out.
            return [Discrete(
                keyCode: D.KeyCode.slash,
                requiredFlags: D.command | D.option,
                forbiddenFlags: D.control | D.shift
            )]
        case .optionCommandR:
            return [Discrete(
                keyCode: D.KeyCode.r,
                requiredFlags: D.option | D.command,
                forbiddenFlags: D.control | D.shift
            )]
        case .controlOptionR:
            return [Discrete(
                keyCode: D.KeyCode.r,
                requiredFlags: D.control | D.option,
                forbiddenFlags: D.command | D.shift
            )]
        case .fnThenDictationKey:
            return []
        }
    }

    /// The chord's first `.keyDown` shape, or `nil` for the qualified family. Kept because most of
    /// this file's readers — and every chord but ``fnSlash`` — only ever have one.
    public var discrete: Discrete? { discretes.first }

    /// Does this event *fire* the chord? The whole decision, for the discrete family, in one call.
    ///
    /// Answers `false` for the qualified family rather than trapping: `fn`-then-dictation-key is
    /// decided in the `.flagsChanged` branch from the qualifier bit, and a `.keyDown` never fires it.
    public func matches(keyCode: Int64, rawFlags: UInt64) -> Bool {
        discretes.contains { $0.matches(keyCode: keyCode, rawFlags: rawFlags) }
    }

    /// True when at least one of the chord's shapes has to be swallowed to be usable. Only
    /// ``fnSlash``, and only for its `fn + /` half.
    public var consumesTrigger: Bool {
        discretes.contains(where: \.consumesTrigger)
    }

    /// True when the chord is the dictation key qualified by another modifier — the family that has
    /// to be disambiguated by order, and the family that can be refused by the dictation key itself.
    public var qualifiesDictationKey: Bool {
        switch self {
        case .fnThenDictationKey: true
        case .fnSlash, .commandOptionSlash, .optionCommandR, .controlOptionR: false
        }
    }

    // MARK: - Copy

    /// The chord as key caps, for a settings row or a status line. Depends on the dictation key for
    /// the qualified family, which is exactly why it is a function and not a stored string.
    public func glyph(dictationKey: HotkeyChoice) -> String {
        switch self {
        // The globe, not the word: this is the key-cap spelling, and 🌐 is what is printed on the
        // key on every Mac keyboard made since 2021. The word "Fn" is used in the prose below.
        case .fnSlash: "🌐/"
        case .commandOptionSlash: "⌘⌥/"
        case .optionCommandR: "⌥⌘R"
        case .controlOptionR: "⌃⌥R"
        case .fnThenDictationKey: "🌐 \(dictationKey.glyph)"
        }
    }

    public func displayName(dictationKey: HotkeyChoice) -> String {
        switch self {
        case .fnSlash: "🌐/"
        case .commandOptionSlash: "⌘⌥/"
        case .optionCommandR: "⌥⌘R"
        case .controlOptionR: "⌃⌥R"
        case .fnThenDictationKey: "Hold 🌐, then \(dictationKey.displayName)"
        }
    }

    /// A short tag for the picker row itself, next to the keys — or `nil` when the row needs no
    /// second line.
    ///
    /// Two chords have one, for opposite reasons. `fnThenDictationKey` carries a *warning*: it cannot
    /// work on most keyboards. `fnSlash` carries its *alias*, because a row that shows only 🌐/ looks
    /// like the one thing a Logitech cannot send — and the answer to that is on the same row rather
    /// than in the paragraph the user has already stopped reading.
    ///
    /// It takes the dictation key for one configuration, and that configuration is a promise the row
    /// would otherwise break: with Globe *as the dictation key*, `fn` is holding a recording open, so
    /// `RefineChordBinding` drops the `fn + /` shape and only the alias can fire. The row has to say
    /// which of its two chords is the live one rather than print both and mean one.
    public func rowCaveat(dictationKey: HotkeyChoice) -> String? {
        switch self {
        case .fnSlash:
            dictationKey == .fn ? "⌃⌘/ only — 🌐 dictates" : "or ⌃⌘/ on any keyboard"
        case .fnThenDictationKey: "Apple keyboards only"
        case .commandOptionSlash, .optionCommandR, .controlOptionR: nil
        }
    }

    /// One sentence saying what the gesture costs, so the choice between them is informed rather than
    /// a coin toss.
    public var explanation: String {
        switch self {
        case .fnSlash:
            // Two keys, one setting, said in the order a user needs it: what to press, what to press
            // on the other keyboard, and then the one surprise — that Edict eats this slash.
            "Two ways to press the same gesture, and you do not have to choose: Fn+/ on an Apple "
                + "keyboard, or ⌃⌘/ on any keyboard at all. Both open the same popup. The second one "
                + "exists because other keyboards — Logitech, Keychron, Das — handle Fn inside the "
                + "keyboard and never tell macOS it was pressed. Fn+/ is the one gesture Edict takes "
                + "for itself: it types a slash, so Edict has to swallow it to keep your selection, "
                + "and that costs nothing because / on its own still types a slash."
        case .commandOptionSlash:
            "Works on any keyboard, and shares no key with hold-to-dictate. Command is what makes "
                + "it safe: ⌥/ would type ÷ over the selection Edict is about to read, and ⌘⌥/ types "
                + "nothing at all, so Edict can just listen. Use this one if you would rather Edict "
                + "left every key on your keyboard alone — but check that Alfred or Spotlight does "
                + "not already own it."
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
    // * **Never chose** — the key is absent, and they get `RefineChord.default` on the next launch
    //   for free. This is everybody who simply took whatever the default was, which is nearly
    //   everybody, and it is the population the user was actually asking about.
    // * **Chose one deliberately** — the key holds that raw value, and it is kept. Silently
    //   rewriting a setting somebody picked by hand is worse than the problem it solves, and a
    //   one-shot "migrated" flag to make the rewrite happen exactly once would add a second stored
    //   key to paper over a choice we can already read correctly.
    //
    // What they get instead is legibility, in the place where the choice was made: the picker row
    // says "Apple keyboards only" (``rowCaveat(dictationKey:)``) and ``explanation`` says why in
    // plain words. A
    // caveat the user can read beats a setting that changes under them.
    //
    // **The fourth default, `fnSlash`, followed exactly the same rule** rather than reopening the
    // question: an absent key becomes `fn + /`, and a hand-picked `commandOptionSlash` stays `⌘⌥/`.
    // Note what that means for whoever chose `⌘⌥/` because it was recommended — they keep a chord
    // Alfred now owns, and the only honest fix for that is the picker saying so
    // (``explanation``), not a rewrite behind their back.
    //
    // If this ever does need migrating, the flag belongs next to the key in `Settings`, not here, and
    // this comment should say which way it went.
}
