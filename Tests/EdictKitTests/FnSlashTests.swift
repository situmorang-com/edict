import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import EdictKit

/// The `fn + /` decision table, proved as pure logic — including the half that is a *suppression*.
///
/// This chord is the first trigger Edict swallows, and that raises the stakes on the table twice
/// over. The two failures are opposites and both are silent:
///
/// * **It never fires.** A raw flags word compared for equality misses every real event, because this
///   machine's Karabiner virtual keyboard stamps `nonCoalesced` (`0x100`) on everything it
///   synthesizes and a freshly constructed `CGEvent` carries `0x2000_0000` (RECON amendment 31).
///   Every assertion below therefore carries those junk bits, and the ones that must *not* fire are
///   written with them too — a forbidden mask that only works on clean flags is not a guard.
/// * **It fires when it must not, and eats the keystroke on the way.** A false positive on the
///   consuming half does not merely open a popup: it deletes a character the user typed. So the
///   negative half of this suite is the more important half, and it walks the entire slash family
///   measured on this machine's ABC layout plus the user's four-modifier Safari mapping.
///
/// The tap plumbing is exercised by `HotkeyChordLive` in `RefineGestureTests.swift`; this suite needs
/// no tap, no permission and no keyboard, which is the whole reason the table lives in `RefineChord`
/// rather than in the event callback.
@Suite("RefineChord fn+/")
struct FnSlashTests {

    static let junk: UInt64 = 0x100 | 0x2000_0000

    static let fn = UInt64(CGEventFlags.maskSecondaryFn.rawValue)
    static let cmd = UInt64(CGEventFlags.maskCommand.rawValue)
    static let alt = UInt64(CGEventFlags.maskAlternate.rawValue)
    static let ctrl = UInt64(CGEventFlags.maskControl.rawValue)
    static let shift = UInt64(CGEventFlags.maskShift.rawValue)

    /// Device-dependent side bits, verbatim from `IOLLEvent.h`.
    static let lcmd: UInt64 = 0x0000_0008
    static let rcmd: UInt64 = 0x0000_0010
    static let lalt: UInt64 = 0x0000_0020
    static let ralt: UInt64 = 0x0000_0040
    static let lctrl: UInt64 = 0x0000_0001
    static let rctrl: UInt64 = 0x0000_2000

    static let slash: Int64 = 44   // kVK_ANSI_Slash

    private func fires(_ keyCode: Int64, _ flags: UInt64) -> Bool {
        RefineChord.fnSlash.matches(keyCode: keyCode, rawFlags: flags)
    }

    // MARK: The table

    /// Two shapes, one setting. The order is the order the picker explains them in, and
    /// `discrete` — the singular accessor the other chords use — answers with the first.
    @Test("the chord is two shapes on keycode 44: fn alone, and Control+Command")
    func table() throws {
        let shapes = RefineChord.fnSlash.discretes
        #expect(shapes.count == 2)

        let apple = try #require(shapes.first)
        #expect(apple.keyCode == Self.slash)
        #expect(apple.keyCode == Int64(kVK_ANSI_Slash))
        #expect(apple.requiredFlags == Self.fn)
        // Every other modifier is forbidden. ⇧fn/ types "?" and ⌃fn/ is a chord the user rejected;
        // neither may be read as this gesture.
        #expect(apple.forbiddenFlags == Self.cmd | Self.alt | Self.ctrl | Self.shift)
        #expect(apple.consumesTrigger)

        let anyKeyboard = shapes[1]
        #expect(anyKeyboard.keyCode == Self.slash)
        #expect(anyKeyboard.requiredFlags == Self.ctrl | Self.cmd)
        #expect(anyKeyboard.forbiddenFlags == Self.alt | Self.shift)
        // It carries ⌘, so macOS routes it as a key equivalent and it inserts nothing. Nothing to
        // swallow means nothing is swallowed.
        #expect(!anyKeyboard.consumesTrigger)

        #expect(RefineChord.fnSlash.discrete == apple)
    }

    @Test("fn + / fires, junk bits and all")
    func fnSlashFires() {
        #expect(fires(Self.slash, Self.fn | Self.junk))
        // Clean flags too, which is what a hand-built `CGEvent` in a rig looks like.
        #expect(fires(Self.slash, Self.fn))
        // And with only Karabiner's bit, which is the shape a remapped keyboard actually delivers.
        #expect(fires(Self.slash, Self.fn | 0x100))
    }

    @Test("⌃⌘/ fires on either hand — the alias for a keyboard that hides fn")
    func aliasFires() {
        #expect(fires(Self.slash, Self.ctrl | Self.cmd | Self.junk))
        #expect(fires(Self.slash, Self.ctrl | Self.cmd | Self.lctrl | Self.lcmd | Self.junk))
        #expect(fires(Self.slash, Self.ctrl | Self.cmd | Self.rctrl | Self.rcmd | Self.junk))
        // Mixed hands, and with the fn bit incidentally along for the ride: still the gesture.
        #expect(fires(Self.slash, Self.ctrl | Self.cmd | Self.lctrl | Self.rcmd | Self.junk))
        #expect(fires(Self.slash, Self.ctrl | Self.cmd | Self.fn | Self.junk))
    }

    // MARK: What must not fire
    //
    // The whole slash family, measured with `UCKeyTranslate` on this machine's ABC layout:
    //
    //     /    -> "/"      ⌥/  -> "÷"      ⌃/   -> "/"
    //     ⌃⌥/  -> "/"      ⇧⌥/ -> "¿"      fn/  -> "/"
    //
    // A false positive here costs the user a character, because the matching half of this chord is
    // consumed. Every one of these carries the junk bits.

    @Test("a bare slash does not fire — this is the one the user types all day")
    func bareSlash() {
        #expect(!fires(Self.slash, Self.junk))
        #expect(!fires(Self.slash, 0))
        #expect(!fires(Self.slash, 0x100))
    }

    @Test("⇧/ does not fire — that is a question mark")
    func shiftSlash() {
        #expect(!fires(Self.slash, Self.shift | Self.junk))
        #expect(!fires(Self.slash, Self.shift | Self.fn | Self.junk))
    }

    @Test("⌥/ does not fire — it is this user's only way to type ÷")
    func optionSlash() {
        #expect(!fires(Self.slash, Self.alt | Self.junk))
        #expect(!fires(Self.slash, Self.alt | Self.lalt | Self.junk))
        #expect(!fires(Self.slash, Self.alt | Self.fn | Self.junk))
    }

    @Test("⌃/ does not fire — Command is required of the alias")
    func controlSlash() {
        #expect(!fires(Self.slash, Self.ctrl | Self.junk))
        #expect(!fires(Self.slash, Self.ctrl | Self.lctrl | Self.junk))
    }

    @Test("⌘/ does not fire — Control is required of the alias")
    func commandSlash() {
        #expect(!fires(Self.slash, Self.cmd | Self.junk))
        #expect(!fires(Self.slash, Self.cmd | Self.lcmd | Self.junk))
    }

    /// The previous default. It is still a chord the user can *choose*, so it must not also be a way
    /// to fire the new one — a picker where two rows answer to the same keystroke is a picker that
    /// cannot be trusted.
    @Test("⌘⌥/ does not fire the new chord")
    func commandOptionSlash() {
        #expect(!fires(Self.slash, Self.cmd | Self.alt | Self.junk))
        #expect(!fires(Self.slash, Self.cmd | Self.alt | Self.lcmd | Self.lalt | Self.junk))
    }

    @Test("⌃⌥/ and ⇧⌥/ do not fire")
    func otherSlashChords() {
        #expect(!fires(Self.slash, Self.ctrl | Self.alt | Self.junk))
        #expect(!fires(Self.slash, Self.shift | Self.alt | Self.junk))
        // ⌃fn/ — the three-finger reach the user rejected. It must not fire either, or rejecting it
        // would have made no difference.
        #expect(!fires(Self.slash, Self.ctrl | Self.fn | Self.junk))
        // And the alias plus Option or Shift is somebody else's shortcut, not this one.
        #expect(!fires(Self.slash, Self.ctrl | Self.cmd | Self.alt | Self.junk))
        #expect(!fires(Self.slash, Self.ctrl | Self.cmd | Self.shift | Self.junk))
    }

    /// The one that would actually hurt. `left_command+left_option+left_control+left_shift` plus
    /// `slash` is a Safari navigation mapping in the user's live Karabiner profile, and it carries
    /// both of the alias's required bits. Without the forbidden masks, Edict would fire — and swallow
    /// nothing, but open a popup — in the middle of the user's own shortcut.
    @Test("the four-modifier Safari mapping does not fire")
    func safariMapping() {
        let allFour = Self.cmd | Self.alt | Self.ctrl | Self.shift
        #expect(!fires(Self.slash, allFour | Self.junk))
        // Written the way the profile is: explicitly left-hand.
        #expect(!fires(
            Self.slash,
            allFour | Self.lcmd | Self.lalt | Self.lctrl | 0x0000_0002 | Self.junk
        ))
        // And with fn incidentally held, which is the shape a MacBook user could produce.
        #expect(!fires(Self.slash, allFour | Self.fn | Self.junk))
    }

    /// RECON §9: `maskSecondaryFn` rides on the `.keyDown` of **every** arrow and fn-row key, so "fn
    /// is held" alone can never be the rule. The keycode is what tells them apart, and these are the
    /// keys that would break first if it were ever dropped.
    @Test("fn with any other key does not fire", arguments: [
        Int64(kVK_LeftArrow), Int64(kVK_RightArrow), Int64(kVK_F5), Int64(kVK_F13),
        Int64(kVK_ANSI_R), Int64(kVK_ANSI_Period), Int64(kVK_ANSI_Backslash),
        Int64(kVK_ANSI_KeypadDivide), Int64(kVK_ANSI_1), Int64(kVK_Escape), Int64(kVK_Delete),
    ])
    func fnWithAnotherKey(keyCode: Int64) {
        #expect(!fires(keyCode, Self.fn | Self.junk))
        #expect(!fires(keyCode, Self.ctrl | Self.cmd | Self.junk))
    }

    /// The keypad's own divide key prints a slash and is a *different keycode*. Called out because
    /// "slash" is a character in the user's head and a keycode in the tap's.
    @Test("the keypad divide key is not the slash key")
    func keypadDivideIsNotSlash() {
        #expect(Int64(kVK_ANSI_KeypadDivide) != Self.slash)
    }

    // MARK: Which tap owns which shape

    /// The invariant that makes two taps safe. Each shape is claimed by exactly one of them, so no
    /// keystroke can fire the gesture twice and the answer does not depend on which tap the window
    /// server serves first.
    @Test("the consuming and listen-only sets are disjoint and cover the chord")
    func tapOwnershipIsAPartition() throws {
        let binding = try #require(RefineChordBinding(.fnSlash, dictationKey: .rightOption))

        // fn + / — swallowed, and therefore never offered to the listen-only tap.
        #expect(binding.matchesConsuming(keyCode: Self.slash, rawFlags: Self.fn | Self.junk))
        #expect(!binding.matchesListenOnly(keyCode: Self.slash, rawFlags: Self.fn | Self.junk))

        // ⌃⌘/ — inserts nothing, so it is fired and passed through.
        let alias = Self.ctrl | Self.cmd | Self.junk
        #expect(binding.matchesListenOnly(keyCode: Self.slash, rawFlags: alias))
        #expect(!binding.matchesConsuming(keyCode: Self.slash, rawFlags: alias))

        // Both are the chord.
        #expect(binding.matchesDiscrete(keyCode: Self.slash, rawFlags: Self.fn | Self.junk))
        #expect(binding.matchesDiscrete(keyCode: Self.slash, rawFlags: alias))
        // And a plain slash is neither, which is the assertion the user's document depends on.
        #expect(!binding.matchesConsuming(keyCode: Self.slash, rawFlags: Self.junk))
        #expect(!binding.matchesListenOnly(keyCode: Self.slash, rawFlags: Self.junk))
        #expect(!binding.matchesDiscrete(keyCode: Self.slash, rawFlags: Self.junk))
    }

    /// Only this chord costs a tap. The others are listen-only exactly as they were, which is what
    /// keeps amendment 42's rule ("suppression nowhere else") true for anyone who picks one.
    @Test("fn+/ is the only chord that needs the consuming tap")
    func onlyThisChordConsumes() throws {
        #expect(RefineChord.fnSlash.consumesTrigger)
        for chord in RefineChord.allCases where chord != .fnSlash {
            #expect(!chord.consumesTrigger, "\(chord.rawValue) asked for a consuming tap")
        }

        let listenOnly = try #require(RefineChordBinding(.commandOptionSlash, dictationKey: .rightOption))
        #expect(!listenOnly.needsConsumingTap)
        #expect(!listenOnly.matchesConsuming(keyCode: Self.slash, rawFlags: Self.cmd | Self.alt | Self.junk))
        #expect(listenOnly.matchesListenOnly(keyCode: Self.slash, rawFlags: Self.cmd | Self.alt | Self.junk))

        let consuming = try #require(RefineChordBinding(.fnSlash, dictationKey: .rightOption))
        #expect(consuming.needsConsumingTap)
    }

    // MARK: Through the binding, with the dictation key on top

    /// The binding adds the dictation key's own device bit to every forbidden mask, so a chord cannot
    /// fire out of a hold that has already armed. Right Option is the shipped dictation key, so this
    /// is the combination nearly every user has.
    @Test("the dictation key's own side cannot fire either shape")
    func dictationKeysSideIsExcluded() throws {
        let binding = try #require(RefineChordBinding(.fnSlash, dictationKey: .rightOption))
        // Left Option held is not the dictation key — but Option is forbidden by the fn shape anyway,
        // so what this proves is the *right* one being excluded on top of it.
        #expect(!binding.matchesDiscrete(keyCode: Self.slash, rawFlags: Self.fn | Self.ralt | Self.junk))
        #expect(!binding.matchesDiscrete(
            keyCode: Self.slash,
            rawFlags: Self.ctrl | Self.cmd | Self.ralt | Self.junk
        ))
        // With F13 as the dictation key there is no side to exclude.
        let f13 = try #require(RefineChordBinding(.fnSlash, dictationKey: .f13))
        #expect(f13.variants.count == 2)
        #expect(f13.matchesConsuming(keyCode: Self.slash, rawFlags: Self.fn | Self.junk))
    }

    /// Globe as the dictation key is the one case where a shape has to be *dropped* rather than
    /// masked. `fn` is busy holding a recording open, so `fn + /` cannot mean anything else — but the
    /// alias still can, and dropping only the one shape is what keeps the setting usable instead of
    /// taking the whole gesture away.
    @Test("Globe as the dictation key keeps the alias and drops the fn shape")
    func globeDictationKeyKeepsTheAlias() throws {
        let binding = try #require(RefineChordBinding(.fnSlash, dictationKey: .fn))
        #expect(binding.variants.count == 1)
        #expect(!binding.needsConsumingTap)
        #expect(!binding.matchesDiscrete(keyCode: Self.slash, rawFlags: Self.fn | Self.junk))
        #expect(binding.matchesListenOnly(
            keyCode: Self.slash,
            rawFlags: Self.ctrl | Self.cmd | Self.junk
        ))
        // …and not while Globe is actually held, which would be mid-dictation.
        #expect(!binding.matchesListenOnly(
            keyCode: Self.slash,
            rawFlags: Self.ctrl | Self.cmd | Self.fn | Self.junk
        ))
    }

    /// The picker must never be able to leave the user with no working chord, so the default has to
    /// resolve against every dictation key.
    @Test("fn+/ resolves for every dictation key", arguments: HotkeyChoice.allCases)
    @MainActor
    func resolvesEverywhere(key: HotkeyChoice) throws {
        #expect(RefineChord.fnSlash.refusal(dictationKey: key) == nil)
        let binding = try #require(RefineChordBinding(.fnSlash, dictationKey: key))
        #expect(!binding.variants.isEmpty)

        let settings = Settings(defaults: EphemeralDefaults())
        settings.hotkey = key
        #expect(settings.effectiveRefineChord == .fnSlash)
    }

    // MARK: Copy

    /// The gesture is two chords behind one row, and a user who reads only the row has to come away
    /// able to press the right one. So the alias appears twice: as the row's own tag, and in the
    /// paragraph, with the reason it exists.
    @Test("the picker says both chords, and says why there are two")
    func pickerSaysBothChords() throws {
        let caveat = try #require(RefineChord.fnSlash.rowCaveat(dictationKey: .rightOption))
        #expect(caveat.contains("⌃⌘/"))
        #expect(caveat.localizedCaseInsensitiveContains("any keyboard"))

        // Globe as the dictation key is the one configuration where the row would otherwise print
        // two chords and mean one, because the binding drops the fn shape there.
        let globe = try #require(RefineChord.fnSlash.rowCaveat(dictationKey: .fn))
        #expect(globe.contains("⌃⌘/"))
        #expect(globe.localizedCaseInsensitiveContains("only"))
        #expect(globe != caveat)

        let why = RefineChord.fnSlash.explanation
        #expect(why.localizedCaseInsensitiveContains("Fn+/"))
        #expect(why.contains("⌃⌘/"))
        // Naming a real brand is the point: "some keyboards" is advice nobody can act on.
        #expect(why.localizedCaseInsensitiveContains("Logitech"))
        // And the one surprise — Edict keeps this keystroke — is said rather than left to be
        // discovered.
        #expect(why.localizedCaseInsensitiveContains("swallow"))

        #expect(RefineChord.fnSlash.glyph(dictationKey: .rightOption) == "🌐/")
        #expect(RefineChord.fnSlash.displayName(dictationKey: .f13) == "🌐/")
        // Not the qualified family: there is no order to get right and nothing to refuse.
        #expect(!RefineChord.fnSlash.qualifiesDictationKey)
    }
}
