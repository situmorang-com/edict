import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import EdictKit

/// The `⌘⌥/` decision table, proved as pure logic.
///
/// `RefineChord.matches(keyCode:rawFlags:)` is the whole recognition rule for the discrete family,
/// and it is a total function of two integers — no tap, no permission, no keyboard. That is
/// deliberate: the two ways this gesture can fail are both invisible from inside the app.
///
/// * **It never fires.** A raw flags word compared for equality misses every real event, because a
///   keyboard remapper stamps `nonCoalesced` (`0x100`) on everything it synthesizes and a fresh
///   `CGEvent` carries `0x2000_0000` (RECON amendment 31). Every assertion below therefore carries
///   those junk bits.
/// * **It fires when it must not.** The user's active Karabiner profile maps
///   `left_command+left_option+left_control+left_shift` plus `slash` to a Safari navigation command.
///   `⌘⌥/` is a *subset* of that chord, so a table that merely required Command and Option would
///   also fire in the middle of the user's own shortcut — and the popup would open over a selection
///   the user was not thinking about. The forbidden masks are what stop that, and they are tested
///   here in both directions.
///
/// The existing `RefineChord` suite in `RefineGestureTests.swift` proves the same table *through*
/// `RefineChordBinding`, which adds the dictation key's device bit on top. This suite stays below
/// that seam on purpose: the two files answer "is the chord right?" and "is the binding right?"
/// separately, so a failure names which one.
@Suite("RefineChord ⌘⌥/")
struct CommandOptionSlashTests {

    /// Bits a real event carries besides the ones the chord is about. Same values as the sibling
    /// suite's `RefineChordTests.junk`, restated rather than shared so this file reads on its own.
    static let junk: UInt64 = 0x100 | 0x2000_0000

    static let cmd = UInt64(CGEventFlags.maskCommand.rawValue)
    static let alt = UInt64(CGEventFlags.maskAlternate.rawValue)
    static let ctrl = UInt64(CGEventFlags.maskControl.rawValue)
    static let shift = UInt64(CGEventFlags.maskShift.rawValue)

    /// Device-dependent side bits, verbatim from `IOLLEvent.h`. The user's Karabiner rules lean on
    /// the left-hand modifiers, so the left ones are the interesting half.
    static let lcmd: UInt64 = 0x0000_0008
    static let rcmd: UInt64 = 0x0000_0010
    static let lalt: UInt64 = 0x0000_0020
    static let ralt: UInt64 = 0x0000_0040

    static let slash: Int64 = 44   // kVK_ANSI_Slash

    private func fires(_ keyCode: Int64, _ flags: UInt64) -> Bool {
        RefineChord.commandOptionSlash.matches(keyCode: keyCode, rawFlags: flags)
    }

    // MARK: The table

    @Test("the chord is keycode 44 with Command and Option required, Control and Shift forbidden")
    func table() throws {
        let table = try #require(RefineChord.commandOptionSlash.discrete)
        #expect(table.keyCode == Self.slash)
        #expect(table.keyCode == Int64(kVK_ANSI_Slash))
        #expect(table.requiredFlags == Self.cmd | Self.alt)
        #expect(table.forbiddenFlags == Self.ctrl | Self.shift)
    }

    @Test("⌘⌥/ fires, junk bits and all")
    func firesOnTheChord() {
        #expect(fires(Self.slash, Self.cmd | Self.alt | Self.junk))
        // And on clean flags, which is what a hand-built `CGEvent` in a test rig looks like.
        #expect(fires(Self.slash, Self.cmd | Self.alt))
    }

    /// Either hand. The user's Karabiner profile is written in left-hand modifiers, but a right-hand
    /// reach for the same chord is the same gesture, and a table that only accepted one side would
    /// be a coin toss for anybody who does not think about which thumb they used.
    @Test("either side's Command and Option counts, including a mixed pair")
    func eitherSide() {
        #expect(fires(Self.slash, Self.cmd | Self.alt | Self.lcmd | Self.lalt | Self.junk))
        #expect(fires(Self.slash, Self.cmd | Self.alt | Self.rcmd | Self.ralt | Self.junk))
        // Left Command, right Option — one hand on each side of the keyboard.
        #expect(fires(Self.slash, Self.cmd | Self.alt | Self.lcmd | Self.ralt | Self.junk))
    }

    // MARK: What must not fire
    //
    // The whole slash family, measured through `UCKeyTranslate` on this machine's ABC layout. The
    // three that type a character are the reason the chord carries Command at all: `/` types "/",
    // `⌥/` types "÷", `⇧⌥/` types "¿", and any of them would overwrite the selection Edict is about
    // to read. None of them may be mistaken for the gesture.

    @Test("a bare slash does not fire")
    func bareSlash() {
        #expect(!fires(Self.slash, Self.junk))
        #expect(!fires(Self.slash, 0))
    }

    @Test("⌘/ does not fire — Option is required")
    func commandSlash() {
        #expect(!fires(Self.slash, Self.cmd | Self.junk))
        #expect(!fires(Self.slash, Self.cmd | Self.lcmd | Self.junk))
    }

    @Test("⌥/ does not fire — Command is required, and ⌥/ types ÷")
    func optionSlash() {
        #expect(!fires(Self.slash, Self.alt | Self.junk))
        #expect(!fires(Self.slash, Self.alt | Self.lalt | Self.junk))
    }

    @Test("⌃⌥/ does not fire — it types a plain slash, and Control is forbidden anyway")
    func controlOptionSlash() {
        #expect(!fires(Self.slash, Self.ctrl | Self.alt | Self.junk))
    }

    @Test("⇧⌥/ does not fire")
    func shiftOptionSlash() {
        #expect(!fires(Self.slash, Self.shift | Self.alt | Self.junk))
    }

    /// The one that would actually hurt. `left_command+left_option+left_control+left_shift` plus
    /// `slash` is a Safari navigation mapping in the user's live Karabiner profile; it carries every
    /// bit `⌘⌥/` requires. If the forbidden masks were dropped, Edict would open a popup in the
    /// middle of that shortcut — over whatever happened to be selected.
    @Test("the four-modifier Safari mapping does not fire")
    func safariMapping() {
        let allFour = Self.cmd | Self.alt | Self.ctrl | Self.shift
        #expect(!fires(Self.slash, allFour | Self.junk))
        // Written the way the profile is: explicitly left-hand.
        #expect(!fires(Self.slash, allFour | Self.lcmd | Self.lalt | 0x0000_0001 | 0x0000_0002 | Self.junk))
        // Either extra modifier on its own is enough to disqualify it.
        #expect(!fires(Self.slash, Self.cmd | Self.alt | Self.ctrl | Self.junk))
        #expect(!fires(Self.slash, Self.cmd | Self.alt | Self.shift | Self.junk))
    }

    @Test("⌘⌥ with a different key does not fire", arguments: [
        Int64(kVK_ANSI_R), Int64(kVK_ANSI_Period), Int64(kVK_ANSI_Backslash),
        Int64(kVK_ANSI_KeypadDivide), Int64(kVK_ANSI_1), Int64(kVK_Escape),
    ])
    func otherKeys(keyCode: Int64) {
        #expect(!fires(keyCode, Self.cmd | Self.alt | Self.junk))
    }

    /// The keypad's own divide key is a *different keycode* even though it prints a slash, and it is
    /// not part of the gesture. Called out because "slash" is a character in the user's head and a
    /// keycode in the tap's.
    @Test("the keypad divide key is not the slash key")
    func keypadDivideIsNotSlash() {
        #expect(Int64(kVK_ANSI_KeypadDivide) != Self.slash)
    }

    // MARK: The other chords still answer the same table

    @Test("every discrete chord has a table and the qualified one has none")
    func families() {
        #expect(RefineChord.commandOptionSlash.discrete != nil)
        #expect(RefineChord.optionCommandR.discrete != nil)
        #expect(RefineChord.controlOptionR.discrete != nil)
        #expect(RefineChord.fnThenDictationKey.discrete == nil)

        #expect(!RefineChord.commandOptionSlash.qualifiesDictationKey)
        #expect(RefineChord.fnThenDictationKey.qualifiesDictationKey)

        // A `.keyDown` can never fire the qualified family, and asking must be safe rather than fatal:
        // the tap calls `matches` on every key the user presses.
        #expect(!RefineChord.fnThenDictationKey.matches(keyCode: Self.slash,
                                                        rawFlags: Self.cmd | Self.alt | Self.junk))
    }

    /// `⌥⌘R` and `⌘⌥/` are the same modifiers on different keys, so neither may answer for the other.
    @Test("the R chords do not answer to the slash key, and vice versa")
    func noCrossTalk() {
        #expect(!RefineChord.optionCommandR.matches(keyCode: Self.slash,
                                                    rawFlags: Self.cmd | Self.alt | Self.junk))
        #expect(!RefineChord.commandOptionSlash.matches(keyCode: Int64(kVK_ANSI_R),
                                                        rawFlags: Self.cmd | Self.alt | Self.junk))
    }

    // MARK: Through the binding, and through the settings

    /// The binding adds one thing to the table: the dictation key's own device bit is forbidden, so a
    /// user whose dictation key is Right Command cannot fire the popup out of a hold that has already
    /// armed. Same rule `⌥⌘R` has had; asserted here because `⌘⌥/` is the first chord that requires
    /// Command, which is what makes Right Command the interesting dictation key.
    @Test("the binding excludes the dictation key's own side")
    func bindingExcludesTheDictationKeysSide() throws {
        let rightCommand = try #require(
            RefineChordBinding(.commandOptionSlash, dictationKey: .rightCommand)
        )
        #expect(rightCommand.discreteKeyCode == Self.slash)
        // Left Command: not the dictation key, so this is the gesture.
        #expect(rightCommand.matchesDiscrete(keyCode: Self.slash,
                                             rawFlags: Self.cmd | Self.alt | Self.lcmd | Self.junk))
        // Right Command: the dictation key, mid-hold.
        #expect(!rightCommand.matchesDiscrete(keyCode: Self.slash,
                                              rawFlags: Self.cmd | Self.alt | Self.rcmd | Self.junk))

        // Right Option as the dictation key excludes the *Option* side instead.
        let rightOption = try #require(
            RefineChordBinding(.commandOptionSlash, dictationKey: .rightOption)
        )
        #expect(rightOption.matchesDiscrete(keyCode: Self.slash,
                                            rawFlags: Self.cmd | Self.alt | Self.lalt | Self.junk))
        #expect(!rightOption.matchesDiscrete(keyCode: Self.slash,
                                             rawFlags: Self.cmd | Self.alt | Self.ralt | Self.junk))
    }

    /// The picker must never be able to leave the user with no working chord, so the new default has
    /// to resolve against every dictation key — including Globe, which refuses the `fn` gesture.
    @Test("⌘⌥/ resolves for every dictation key", arguments: HotkeyChoice.allCases)
    func resolvesEverywhere(key: HotkeyChoice) {
        #expect(RefineChordBinding(.commandOptionSlash, dictationKey: key) != nil)
        #expect(RefineChord.commandOptionSlash.refusal(dictationKey: key) == nil)
        #expect(RefineChord.commandOptionSlash.matches(keyCode: Self.slash,
                                                       rawFlags: Self.cmd | Self.alt | Self.junk))
    }

    @Test("⌘⌥/ is the default, and it is what a fresh install gets")
    @MainActor
    func isTheDefault() {
        #expect(RefineChord.default == .commandOptionSlash)
        #expect(Settings.Default.refineSelectionChord == .commandOptionSlash)

        let settings = Settings(defaults: EphemeralDefaults())
        #expect(settings.refineSelectionChord == .commandOptionSlash)
        #expect(settings.effectiveRefineChord == .commandOptionSlash)
        // And it stays live on the one dictation key that silences the `fn` gesture.
        settings.hotkey = .fn
        #expect(settings.effectiveRefineChord == .commandOptionSlash)
    }

    /// The documented migration decision, pinned so it cannot drift into an accident.
    ///
    /// `refineSelectionChord` is written to `UserDefaults` **only** by the picker, so an absent key
    /// means "never chose" and a present one means "chose". Everybody who merely inherited the old
    /// `fn` default therefore moves to `⌘⌥/` with no migration code, and a deliberate `fn` choice is
    /// kept rather than silently rewritten. See the note at the foot of `RefineChord`.
    @Test("a deliberate Fn choice survives a relaunch, and no stored value means the new default")
    @MainActor
    func migrationDecision() {
        let store = EphemeralDefaults()

        // Nothing stored: the new default, and nothing written by merely reading it.
        let fresh = Settings(defaults: store)
        #expect(fresh.refineSelectionChord == .commandOptionSlash)
        #expect(store.object(forKey: "edict.refineSelectionChord") == nil)

        // Chosen by hand: kept.
        fresh.refineSelectionChord = .fnThenDictationKey
        #expect(store.string(forKey: "edict.refineSelectionChord") == "fnThenDictationKey")
        #expect(Settings(defaults: store).refineSelectionChord == .fnThenDictationKey)
    }

    // MARK: Copy

    /// The picker's job is to stop somebody choosing the one chord their keyboard cannot send. Read
    /// as strings here; read as pixels in the proof sheets below.
    @Test("only the Fn gesture carries a keyboard caveat, and it says which keyboards")
    func caveats() throws {
        #expect(RefineChord.commandOptionSlash.rowCaveat == nil)
        #expect(RefineChord.optionCommandR.rowCaveat == nil)
        #expect(RefineChord.controlOptionR.rowCaveat == nil)

        let caveat = try #require(RefineChord.fnThenDictationKey.rowCaveat)
        #expect(caveat.localizedCaseInsensitiveContains("Apple"))
        #expect(caveat.localizedCaseInsensitiveContains("keyboard"))

        let why = RefineChord.fnThenDictationKey.explanation
        #expect(why.localizedCaseInsensitiveContains("Apple"))
        // Naming a real brand is the point: "some keyboards" is advice nobody can act on.
        #expect(why.localizedCaseInsensitiveContains("Logitech"))

        // The default's explanation has to say why Command is in the chord, because that is the part
        // that looks like an accident.
        let slash = RefineChord.commandOptionSlash.explanation
        #expect(slash.localizedCaseInsensitiveContains("Command"))
        #expect(slash.contains("÷"))
    }

    @Test("the keys print as they are pressed")
    func glyphs() {
        #expect(RefineChord.commandOptionSlash.glyph(dictationKey: .rightOption) == "⌘⌥/")
        #expect(RefineChord.commandOptionSlash.displayName(dictationKey: .f13) == "⌘⌥/")
        // The qualified one still names the dictation key it qualifies.
        #expect(RefineChord.fnThenDictationKey.displayName(dictationKey: .rightOption)
            .contains(HotkeyChoice.rightOption.displayName))
    }

    /// The default has to be reachable first: a picker whose recommended row is fourth reads as a
    /// list of alternatives to something else.
    @Test("the picker offers the default first and the Apple-only gesture last")
    func order() {
        #expect(RefineChord.allCases.first == .commandOptionSlash)
        #expect(RefineChord.allCases.last == .fnThenDictationKey)
        #expect(RefineChord.allCases.count == 4)
    }

    // MARK: - Proof sheets

    /// Rasterises the refine-selection panel in both appearances so a human — or an agent with the
    /// Read tool — can check that the Apple-keyboard-only caveat reads as a warning rather than as a
    /// feature. Off by default: it writes files and needs a window server.
    ///
    /// `EDICT_RENDER_CHORD=1 EDICT_RENDER_DIR=<dir> swift test --filter renderChordSheets`
    @Test("Chord picker proof sheets render",
          .enabled(if: ProcessInfo.processInfo.environment["EDICT_RENDER_CHORD"] == "1"))
    @MainActor
    func renderChordSheets() throws {
        let directory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["EDICT_RENDER_DIR"]
                ?? NSTemporaryDirectory(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sheets = DualLocaleFixtures.renderSheets().filter { $0.id.hasPrefix("refine-selection") }
        #expect(!sheets.isEmpty)

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let nsAppearance = NSAppearance(named: appearance) else { continue }
            for sheet in sheets {
                // The tokens resolve through `NSColor(name:dynamicProvider:)`, which reads the
                // *current drawing appearance* rather than SwiftUI's `colorScheme`, so both have to
                // be set or the dark sheet comes back in light colours.
                var image: NSImage?
                nsAppearance.performAsCurrentDrawingAppearance {
                    let renderer = ImageRenderer(
                        content: sheet.view.environment(\.colorScheme, name == "dark" ? .dark : .light)
                    )
                    renderer.scale = 2
                    image = renderer.nsImage
                }
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else {
                    Issue.record("could not rasterise \(sheet.id) \(name)")
                    continue
                }
                try png.write(to: directory.appendingPathComponent("\(sheet.id)-\(name).png"))
            }
        }
    }
}
