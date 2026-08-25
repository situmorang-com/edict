import CoreGraphics
import Foundation
import Testing
@testable import EdictKit

/// The dual-language *surface*: the things the Settings panel and the live indicator promise the
/// user, tested where they can actually fail.
///
/// The hotkey chord itself cannot be tested — the tap needs Input Monitoring and a human finger —
/// and neither can a rendered view. What *can* be tested is every pure decision the surface makes
/// before it draws anything, and those are the ones with teeth:
///
/// * **The refusal.** A modifier that collides with the dictation key must be refused *in the UI*,
///   because the layer below will not refuse it: `HotkeyBinding` quietly keeps the surviving side, so
///   Right Option + Option becomes "Right Option + *Left* Option", a chord the user will never make
///   on purpose. The feature would look configured and dictate every Indonesian sentence with the
///   English model. Nothing about that failure is visible, which is why the refusal is a test and not
///   a comment.
/// * **The mapping.** "Modifier held" → which locale identifier, including every way the shortcut
///   can be inert.
/// * **The tag.** Two letters are only an indicator while the two configured languages differ in
///   their language subtag. `en-US` against `en-GB` would print `EN` for both — an indicator that
///   indicates nothing while looking like it works, which is worse than not having one.
///
/// `SecondaryLocaleTests` covers the plumbing these sit on (persistence, the flag bits, the engine
/// end to end). This file covers what the surface does with it.
@Suite("Dual locale — the surface")
struct DualLocaleTests {

    // MARK: - Modifier collision

    /// Every dictation key that is itself a modifier refuses that modifier, and only that one.
    @Test("Each modifier hotkey refuses its own modifier and accepts the other three")
    func refusalPerHotkey() {
        let expected: [HotkeyChoice: HotkeyModifier] = [
            .rightOption: .option,
            .rightCommand: .command,
            .rightControl: .control,
        ]
        for (hotkey, conflicting) in expected {
            #expect(SecondLanguageRule.conflicting(hotkey: hotkey) == conflicting)
            for modifier in HotkeyModifier.allCases {
                let refusal = SecondLanguageRule.refusal(hotkey: hotkey, modifier: modifier)
                if modifier == conflicting {
                    #expect(refusal != nil, "\(hotkey) must refuse \(modifier)")
                    // The reason has to name the key, or it is not a reason the user can act on.
                    #expect(refusal?.contains(modifier.glyph) == true)
                } else {
                    #expect(refusal == nil, "\(hotkey) must accept \(modifier)")
                }
            }
        }
    }

    /// `fn` has no device-dependent bit at all (RECON §9: there is no `NX_DEVICEFN`) and F13 is an
    /// ordinary key, so neither of them is holding any of the four modifiers down. Every combination
    /// is a real two-handed chord.
    @Test("Fn and F13 conflict with nothing")
    func nonModifierHotkeysRefuseNothing() {
        for hotkey in [HotkeyChoice.fn, .f13] {
            #expect(SecondLanguageRule.conflicting(hotkey: hotkey) == nil)
            for modifier in HotkeyModifier.allCases {
                #expect(SecondLanguageRule.refusal(hotkey: hotkey, modifier: modifier) == nil)
            }
        }
    }

    /// The refusal exists because the layer below does *not* refuse. This pins that: with Option
    /// chosen against Right Option, `HotkeyBinding` keeps a usable mask (left Option only) and
    /// reports "not alternate" for the very gesture the user would make — the hotkey held by itself.
    /// Nothing throws, nothing logs, and every utterance runs in the primary language.
    @Test("The binding does not refuse a collision, which is why the UI must")
    func bindingSilentlyAcceptsTheCollision() {
        let binding = HotkeyBinding(.rightOption, alternate: .option)
        #expect(binding.alternateMask != 0)                              // looks configured
        #expect(binding.isAlternateHeld(rawFlags: 0x0008_0140) == false)  // right Option held alone
        #expect(SecondLanguageRule.refusal(hotkey: .rightOption, modifier: .option) != nil)
    }

    // MARK: - "Modifier held" → locale identifier

    /// The rule `DictationController.begin(origin:alternate:)` applies, isolated.
    ///
    /// Duplicated here rather than called, because the controller's copy is entangled with the
    /// engine's readiness and its `Utterance` bookkeeping. What is under test is the *decision*, and
    /// the decision is exactly this expression — `effectiveSecondaryLocaleIdentifier` when the
    /// modifier was held, the primary otherwise, and never a throw.
    @MainActor
    private func locale(alternateHeld: Bool, _ settings: Settings) -> String {
        (alternateHeld ? settings.effectiveSecondaryLocaleIdentifier : nil)
            ?? settings.localeIdentifier
    }

    @MainActor
    private func settings() -> Settings { Settings(defaults: EphemeralDefaults()) }

    @Test("Held selects the second language; not held selects the first")
    @MainActor
    func mappingWhenEnabled() {
        let s = settings()
        #expect(locale(alternateHeld: false, s) == "en-US")
        #expect(locale(alternateHeld: true, s) == "id-ID")
    }

    /// The switch being off must make the modifier *inert*, not merely undocumented. If the mapping
    /// consulted `secondaryLocaleIdentifier` directly it would keep working after the user turned the
    /// feature off — and the monitor stops exempting the modifier from chord cancellation at the same
    /// moment, so the two halves would disagree about what a Shift-press means.
    @Test("With the shortcut off the modifier is ignored and the first language is used")
    @MainActor
    func mappingWhenDisabled() {
        let s = settings()
        s.secondaryLocaleEnabled = false
        #expect(locale(alternateHeld: true, s) == "en-US")
        #expect(locale(alternateHeld: false, s) == "en-US")
    }

    @Test("A blank or same-as-primary second language leaves the modifier inert")
    @MainActor
    func mappingWhenInert() {
        let s = settings()
        s.secondaryLocaleIdentifier = "   "
        #expect(locale(alternateHeld: true, s) == "en-US")

        // Same language, other spelling. Underscores and case must not fool this, or holding the
        // modifier would build a second analyzer for the language already running.
        s.secondaryLocaleIdentifier = "en_us"
        #expect(locale(alternateHeld: true, s) == "en-US")

        s.secondaryLocaleIdentifier = "de-DE"
        #expect(locale(alternateHeld: true, s) == "de-DE")
    }

    /// The whole chain the feature actually runs on, from a raw flags word RECON measured on this
    /// machine through to the locale string handed to the engine. Every raw value carries Karabiner's
    /// `nonCoalesced` stamp (`0x100`), which is what makes an equality test wrong.
    @Test("Raw flag word to locale identifier, end to end")
    @MainActor
    func rawFlagsToLocale() {
        let s = settings()
        let binding = HotkeyBinding(.rightOption, alternate: .shift)

        let rightOptionAlone: UInt64 = 0x0008_0140
        let withLeftShift: UInt64 = 0x0008_0142 | 0x0002_0000

        #expect(locale(alternateHeld: binding.isAlternateHeld(rawFlags: rightOptionAlone), s) == "en-US")
        #expect(locale(alternateHeld: binding.isAlternateHeld(rawFlags: withLeftShift), s) == "id-ID")

        // And the same two presses once the user turns the shortcut off.
        s.secondaryLocaleEnabled = false
        #expect(locale(alternateHeld: binding.isAlternateHeld(rawFlags: withLeftShift), s) == "en-US")
    }

    // MARK: - Settings round trip, as the panel sees it

    @Test("Every second-language preference survives a round trip through the same store")
    @MainActor
    func roundTrip() {
        let store = EphemeralDefaults()
        let first = Settings(defaults: store)
        first.secondaryLocaleEnabled = true
        first.secondaryLocaleIdentifier = "de-DE"
        first.secondaryLocaleModifier = .control

        let second = Settings(defaults: store)
        #expect(second.secondaryLocaleEnabled)
        #expect(second.secondaryLocaleIdentifier == "de-DE")
        #expect(second.secondaryLocaleModifier == .control)
        #expect(second.effectiveSecondaryLocaleIdentifier == "de-DE")
    }

    /// A stale identifier — one an OS update dropped, or a hand-written `defaults write` — must not
    /// survive into the panel. The tray would latch nothing, the chord row would name a language the
    /// engine cannot serve, and the modifier would fail on every press with nothing the user could
    /// fix from the UI.
    @Test("An unsupported second language is rejected in favour of the default")
    @MainActor
    func staleIdentifierRejected() {
        let store = EphemeralDefaults()
        store.set("kl-GL", forKey: "edict.secondaryLocaleIdentifier")

        let s = Settings(defaults: store)
        #expect(s.secondaryLocaleIdentifier == "kl-GL")   // loaded as written, not silently ignored
        #expect(s.reconcileSecondaryLocale(supportedIdentifiers: ["en_US", "id_ID", "de_DE"]))
        #expect(s.secondaryLocaleIdentifier == "id-ID")
        #expect(s.secondaryLocaleEnabled)

        // And it stays rejected: reconciliation writes through, so the next launch does not start
        // from the stale value again.
        #expect(Settings(defaults: store).secondaryLocaleIdentifier == "id-ID")
    }

    /// When even the default is unsupported the shortcut turns itself off rather than pointing at a
    /// language nothing can transcribe. The panel then shows only the rocker, which is honest.
    @Test("When nothing supported is left, the shortcut disables itself")
    @MainActor
    func nothingSupported() {
        let store = EphemeralDefaults()
        let s = Settings(defaults: store)
        s.secondaryLocaleIdentifier = "kl-GL"
        #expect(s.reconcileSecondaryLocale(supportedIdentifiers: ["en_US"]))
        #expect(s.secondaryLocaleEnabled == false)
        #expect(s.effectiveSecondaryLocaleIdentifier == nil)
        #expect(Settings(defaults: store).secondaryLocaleEnabled == false)
    }

    /// An empty list means the framework could not be asked, not that nothing is supported. Wiping
    /// the user's choice on a transient failure would be worse than leaving it alone.
    @Test("An empty supported list is not evidence of anything")
    @MainActor
    func emptySupportedListChangesNothing() {
        let s = settings()
        s.secondaryLocaleIdentifier = "kl-GL"
        #expect(s.reconcileSecondaryLocale(supportedIdentifiers: []) == false)
        #expect(s.secondaryLocaleIdentifier == "kl-GL")
    }

    // MARK: - The live tag

    @Test("The tag is the language subtag while the two languages differ in language")
    @MainActor
    func tagCodeIsTheSubtag() {
        #expect(AppModel.tagCode(for: "en-US", primary: "en-US", secondary: "id-ID") == "EN")
        #expect(AppModel.tagCode(for: "id-ID", primary: "en-US", secondary: "id-ID") == "ID")
        // The framework hands identifiers back underscored; the readout must not care.
        #expect(AppModel.tagCode(for: "id_ID", primary: "en-US", secondary: "id-ID") == "ID")
    }

    /// Two letters cannot distinguish two regions of one language. Falling back to the whole tag is
    /// the difference between an indicator and a decoration that looks like an indicator.
    @Test("The tag falls back to the whole identifier when the subtags would collide")
    @MainActor
    func tagCodeDisambiguates() {
        #expect(AppModel.tagCode(for: "en-US", primary: "en-US", secondary: "en-GB") == "en-US")
        #expect(AppModel.tagCode(for: "en-GB", primary: "en-US", secondary: "en-GB") == "en-GB")
        // Never an underscore: printing `id_ID` one day and `id-ID` the next reads as a bug.
        #expect(AppModel.tagCode(for: "en_GB", primary: "en-US", secondary: "en-GB") == "en-GB")
    }

    @Test("With no second language configured the tag is just the subtag")
    @MainActor
    func tagCodeWithoutSecondary() {
        #expect(AppModel.tagCode(for: "en-US", primary: "en-US", secondary: nil) == "EN")
    }

    /// Live only. A tag that is lit while nothing is being dictated is panel nomenclature; the whole
    /// value of this one is that it appears when recording starts.
    @Test("The tag is absent at idle and present for the utterance in flight")
    @MainActor
    func tagIsLiveOnly() {
        let model = PreviewFixtures.model()
        #expect(model.languageTag == nil)

        model.apply(activeLocale: "id-ID", isSecondary: true)
        model.apply(phase: .listening)
        let tag = model.languageTag
        #expect(tag?.code == "ID")
        #expect(tag?.isSecondary == true)
        // Never only two letters: the screen reader and the tooltip get the language's name.
        #expect(tag?.spoken.isEmpty == false)
        #expect(tag?.spoken != tag?.code)

        // Returning to idle clears it, via the one rule in `AppModel.apply(phase:)` that covers
        // success, cancel and error alike.
        model.apply(phase: .idle)
        #expect(model.languageTag == nil)
    }

    @Test("A primary-language utterance is tagged too, and not marked secondary")
    @MainActor
    func tagForPrimary() {
        let model = PreviewFixtures.model()
        model.apply(activeLocale: model.settings.localeIdentifier, isSecondary: false)
        model.apply(phase: .listening)
        #expect(model.languageTag?.code == "EN")
        #expect(model.languageTag?.isSecondary == false)
    }
}
