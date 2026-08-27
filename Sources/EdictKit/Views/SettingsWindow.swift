import Speech
import SwiftUI

// MARK: - Column metrics

/// The settings column's own geometry, derived from the tokens it is measured against.
private enum S {
    /// A fixed column: every panel's seams line up, and the window never reflows.
    static let column = D.size.windowMin.width * 0.62                       // 558
    /// Full-bleed key width inside a panel inside the column. `TapeButton`'s legend is `fixedSize`d,
    /// so a key only fills its row if it is given a `minWidth`.
    static let keyWidth = column - (D.space.md + D.space.panelInset) * 2     // 510
    /// A key inside a sunken tray: the same width less the cap's 1pt seat on each side and room
    /// for an overlay scroller.
    static let trayKeyWidth = keyWidth - D.space.sm                         // 502
    /// Seven rows of the locale tray. 54 locales cannot be a column of 54 keys.
    static let localeTrayHeight = D.size.rowHeight * 7                      // 182
    /// The lit window holding a key chord. Wide enough for the longest chord Edict can produce
    /// (`⇧F13`) so the two chord rows line their language names up on one edge.
    static let chordWidth = D.size.buttonHeight * 1.6                       // 48
}

// MARK: - SettingsWindow

/// The settings surface, presented by the `SwiftUI.Settings` scene on `Cmd+,`.
///
/// One column of panels in a scroll view rather than a `TabView`: every group here is short, and a
/// tab bar would hide the permissions list behind a click at exactly the moment the user is looking
/// for it.
public struct SettingsWindow: View {

    private let model: AppModel

    /// Render-harness escape hatch: drops the scroll view and the height cap so the whole column
    /// can be rasterised in one image. Never true in the app.
    private let unbounded: Bool

    /// Defaulted so the shell's `Settings` scene can spell this `SettingsWindow()`.
    public init(model: AppModel = .shared) {
        self.model = model
        self.unbounded = false
    }

    init(model: AppModel, unbounded: Bool, locales: [Locale] = []) {
        self.model = model
        self.unbounded = unbounded
        self.preloadedLocales = locales
    }

    /// Render-harness seam: the locale list normally arrives from an `await` in a `.task`, which the
    /// offscreen rasteriser cannot wait for. Empty in the app.
    private var preloadedLocales: [Locale] = []

    /// Fetched once, here, and handed to both language sections.
    ///
    /// Two sections pick from the same 54 entries, and asking the framework twice would be two
    /// awaits, two sort orders to keep in step, and two ways for the trays to disagree about what is
    /// supported — which is exactly the class of bug that silently disables the language shortcut.
    @State private var locales: [Locale] = []

    public var body: some View {
        Group {
            if unbounded { column } else { scrolling }
        }
        .frame(width: S.column)
        .background(D.surface.deckPaint)
        .task {
            guard preloadedLocales.isEmpty else {
                locales = preloadedLocales
                return
            }
            // Asked directly of the framework because neither `AppModel` nor `DictationController`
            // exposes the engine's `supportedLocales` yet; see the handover note. Read-only and
            // cheap — it takes no locale reservation.
            let supported = await DictationTranscriber.supportedLocales
            locales = supported.sorted { $0.identifier(.bcp47) < $1.identifier(.bcp47) }
        }
    }

    private var scrolling: some View {
        ScrollView { column }
            // A settings window is not resizable content: a fixed column keeps every panel's seams
            // lined up, and the height is capped so it never grows taller than a laptop screen.
            .frame(minHeight: D.size.windowMin.height * 0.66,
                   maxHeight: D.size.windowMin.height * 1.1)
    }

    private var column: some View {
        VStack(alignment: .leading, spacing: D.space.md) {
                HotkeySection(settings: model.settings, hotkeyLive: model.hotkeyLive)
                SpeechModelSection(model: model, locales: locales)
                SecondLanguageSection(model: model, locales: locales)
                BehaviourSection(model: model)
                RefineSection(model: model)
                RefineSelectionSection(settings: model.settings)
                ImportSection(settings: model.settings)
                DictionarySection(settings: model.settings, dictionary: model.dictionary)
                LimitsSection(settings: model.settings, history: model.history)
                PermissionsPane(model: model, showsHeading: false)
            }
        .padding(D.space.md)
    }
}

// MARK: - Hotkey

/// Live-updating: `DictationController` watches `Settings.hotkey` and re-arms the event tap, so
/// writing the setting *is* the rebind. There is no Apply key and there must not be one.
private struct HotkeySection: View {

    let settings: Settings
    let hotkeyLive: Bool

    var body: some View {
        PanelSurface("Dictation key") {
            VStack(alignment: .leading, spacing: D.space.sm) {
                ForEach(HotkeyChoice.allCases) { choice in
                    key(choice)
                }

                Text(rationale)
                    .typeStyle(D.type.explain)
                    .foregroundStyle(D.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func key(_ choice: HotkeyChoice) -> some View {
        TapeButton(
            role: .neutral,
            isLatched: choice == settings.hotkey,
            minWidth: S.keyWidth,
            action: { settings.hotkey = choice }
        ) {
            HStack(spacing: D.space.sm) {
                // `displayName` already carries the glyph ("Right Option (⌥)"), so printing
                // `choice.glyph` beside it would double it.
                Text(choice.displayName)
                if choice == settings.hotkey {
                    Text(hotkeyLive ? "Live" : "Inactive")
                        .typeStyle(D.type.silkscreenTiny)
                }
            }
        }
        .accessibilityLabel(choice.displayName)
        .accessibilityAddTraits(choice == settings.hotkey ? .isSelected : [])
    }

    /// Straight out of RECON §8, because it is the question every user will ask first.
    private var rationale: String {
        """
        Right Option is the default because it is the only modifier left. This machine runs \
        Karabiner-Elements, whose active profile already claims Right Command, Caps Lock and Fn, and \
        Siri holds a tap on Fn ahead of Edict. Right Control exists on external keyboards but not on \
        the built-in one. Edict only listens — it never swallows the key — so Right Option still \
        works as AltGr for typing accented characters.
        """
    }
}

// MARK: - Speech model

/// Locale and on-device asset state.
///
/// The list comes from the transcriber itself, never from `Locale.current`: RECON §7 measured
/// `Locale.current` on this machine resolving to `en-IN` — silently the wrong acoustic model — which
/// is why the default is an explicit `en-US` and why this is a fixed list rather than a text field.
/// `DictationTranscriber` reports 54 locales, so they live in a scrollable tray with the current one
/// pinned to the top.
private struct SpeechModelSection: View {

    let model: AppModel
    let locales: [Locale]

    var body: some View {
        PanelSurface("Speech model") {
            VStack(alignment: .leading, spacing: D.space.sm) {
                stateRow

                LocaleTray(
                    locales: locales,
                    selected: model.settings.localeIdentifier,
                    onPick: { model.settings.localeIdentifier = $0 }
                )

                Text("The model runs entirely on this Mac; nothing you dictate leaves it. "
                     + "Changing the language takes effect on your next dictation.")
                    .typeStyle(D.type.explain)
                    .foregroundStyle(D.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stateRow: some View {
        HStack(spacing: D.space.md) {
            // Fault ink goes on the chassis, never inside the window: `D.color.alert` is a dark
            // brown in the light appearance and `wellFill` is near-black in both, so the word
            // itself stays `displayInk` and the tell-tale carries the alarm.
            Rectangle()
                .strokeBorder(D.color.alert, lineWidth: D.border.thin)
                .frame(width: D.size.troughHeight, height: D.size.troughHeight)
                .opacity(isFault ? 1 : 0)
            RecessedWell(fill: .display, radius: D.radius.tight, inset: D.space.xs) {
                Text(stateText)
                    .typeStyle(D.type.silkscreen)
                    .foregroundStyle(D.color.displayInk)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: D.size.railWidth)

            if case .downloading(let fraction) = model.modelState {
                SegmentCounter(.count(Int((fraction * 100).rounded()), unit: "pct"), scale: .small)
            }

            Spacer(minLength: D.space.sm)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Model state")
        .accessibilityValue(stateText)
    }

    private var stateText: String {
        switch model.modelState {
        case .ready: "Installed"
        case .needsDownload: "Not installed"
        case .downloading(let fraction): "Downloading \(Int((fraction * 100).rounded()))%"
        case .unavailable(let why): why
        }
    }

    private var isFault: Bool {
        switch model.modelState {
        case .ready, .downloading: false
        case .needsDownload, .unavailable: true
        }
    }

}

// MARK: - LocaleTray

/// The 54-entry language tray, shared by the primary and the second-language sections.
///
/// One component rather than two, and not for brevity: the two trays must look and order the same,
/// because the whole point of the second one is that the user recognises it as the *same kind of
/// choice* they already made above. Two copies drift.
private struct LocaleTray: View {

    let locales: [Locale]
    let selected: String
    let onPick: (String) -> Void

    var body: some View {
        if locales.isEmpty {
            Text("Reading the list of supported languages\u{2026}")
                .typeStyle(D.type.explain)
                .foregroundStyle(D.color.textSecondary)
        } else {
            RecessedWell(fill: .list, inset: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: D.space.xs) {
                        ForEach(ordered, id: \.identifier) { locale in
                            key(locale)
                        }
                    }
                    .padding(D.space.xs)
                }
                // Definite, not maximum: a `ScrollView` handed an ideal proposal measures
                // as zero and the tray vanishes.
                .frame(height: S.localeTrayHeight)
            }
        }
    }

    /// Current first: with 54 entries the one that matters must not be somewhere down a scroll.
    private var ordered: [Locale] {
        let isCurrent = { (l: Locale) in
            l.identifier(.bcp47).caseInsensitiveCompare(selected) == .orderedSame
        }
        return locales.filter(isCurrent) + locales.filter { !isCurrent($0) }
    }

    private func key(_ locale: Locale) -> some View {
        let identifier = locale.identifier(.bcp47)
        let isCurrent = identifier.caseInsensitiveCompare(selected) == .orderedSame
        return TapeButton(
            role: .neutral,
            isLatched: isCurrent,
            minWidth: S.trayKeyWidth,
            action: { onPick(identifier) }
        ) {
            HStack(spacing: D.space.sm) {
                // Named in the *user's* language, not its own: `العربية (المملكة…)` is unreadable
                // to someone picking from an English UI, and the BCP-47 tag beside it is the
                // unambiguous part. Using `Locale.current` for a display string is unrelated to
                // RECON §7, which is about never deriving the *acoustic model* from it.
                Text(Locale.current.localizedString(forIdentifier: identifier) ?? identifier)
                Text(identifier)
                    .typeStyle(D.type.silkscreenTiny)
            }
        }
        .accessibilityLabel(Locale.current.localizedString(forIdentifier: identifier) ?? identifier)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

// MARK: - Second language

/// Whether a modifier can qualify a given dictation key, and why not when it cannot.
///
/// A free function rather than a `private` helper inside the view, so the refusal is testable
/// without a rendered view: the consequence of getting it wrong is not cosmetic. If Option were
/// accepted alongside Right Option, `HotkeyBinding` would keep only the *left* Option bit and every
/// two-handed press would look like an English one — the feature would appear to work and silently
/// dictate every Indonesian sentence with the English model.
enum SecondLanguageRule {

    /// The modifier the dictation key is *itself* holding down while it is held.
    ///
    /// `fn` and `f13` hold nothing: `fn` has no device-dependent bit at all (RECON §9 — there is no
    /// `NX_DEVICEFN`), and F13 is an ordinary key, so any of the four modifiers is a real chord
    /// alongside either of them.
    static func conflicting(hotkey: HotkeyChoice) -> HotkeyModifier? {
        switch hotkey {
        case .rightOption: .option
        case .rightCommand: .command
        case .rightControl: .control
        case .fn, .f13: nil
        }
    }

    /// A sentence to print, or `nil` when the pair is usable.
    static func refusal(hotkey: HotkeyChoice, modifier: HotkeyModifier) -> String? {
        guard conflicting(hotkey: hotkey) == modifier else { return nil }
        return """
            \(modifier.glyph) is the dictation key itself, so holding it cannot also mean \
            "the other language". Only the left \(modifier.glyph) would count, and remembering to \
            use the left one every time is not something you can feel. Choose a different key.
            """
    }
}

/// The second dictation language and the key that selects it.
///
/// Below the primary picker because it is read in that order: this panel means nothing until you
/// know what the first language is. The controls are deliberately the same two the panel above
/// uses — a tray of languages and a row of keys — so the gesture reads as a variation on something
/// already understood rather than a new mode.
private struct SecondLanguageSection: View {

    let model: AppModel
    let locales: [Locale]

    private var settings: Settings { model.settings }

    var body: some View {
        PanelSurface("Second language") {
            VStack(alignment: .leading, spacing: D.space.md) {
                RockerSwitch(
                    "Use a second language",
                    isOn: Binding(get: { settings.secondaryLocaleEnabled },
                                  set: { settings.secondaryLocaleEnabled = $0 }),
                    caption: "One phrase at a time. Hold an extra key while you speak and just that "
                           + "phrase is dictated in the other language."
                )

                if settings.secondaryLocaleEnabled {
                    gesture
                    modifierRow
                    languageTray
                    explanation
                    SeamDivider(.horizontal)
                    dualPass
                }
            }
        }
    }

    // MARK: The gesture, spelled out

    /// The two chords, printed with the keys the user has actually chosen.
    ///
    /// Hardcoding "⌥" and "⇧⌥" here would be a lie the moment anyone changed either picker, and it
    /// is the one thing on this panel that has to be literally true — it is an instruction for the
    /// hands, not a description.
    private var gesture: some View {
        VStack(alignment: .leading, spacing: D.space.xs) {
            SilkscreenLabel("Hold", weight: .tiny)
                .silkscreenDecorative()
            chord(settings.hotkey.glyph, identifier: settings.localeIdentifier)
            if let refusal {
                notice(refusal)
            } else if let secondary = settings.effectiveSecondaryLocaleIdentifier {
                chord(settings.secondaryLocaleModifier.glyph + settings.hotkey.glyph,
                      identifier: secondary)
            } else {
                notice(sameLanguageRefusal)
            }
        }
    }

    private func chord(_ keys: String, identifier: String) -> some View {
        HStack(spacing: D.space.sm) {
            // The chord sits in a lit window and the language is printed on the panel beside it:
            // the keys are the machine's state, the language is the label for it.
            RecessedWell(fill: .display, radius: D.radius.tight, inset: D.space.xs) {
                Text(keys)
                    .typeStyle(D.type.silkscreen)
                    .foregroundStyle(D.color.displayInk)
                    .lineLimit(1)
                    .fixedSize()
                    // Widened *inside* the opening, not outside it: a `minWidth` on the well itself
                    // sizes the frame without sizing the cut, so `⌥` and `⇧⌥` came out as two
                    // different-sized windows one above the other.
                    .frame(minWidth: S.chordWidth)
            }
            Text(Self.name(identifier))
                .typeStyle(D.type.body)
                .foregroundStyle(D.color.textPrimary)
                .lineLimit(1)
            Text(identifier)
                .typeStyle(D.type.silkscreenTiny)
                .foregroundStyle(D.color.textSilkscreen)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold \(keys)")
        .accessibilityValue(Self.name(identifier))
    }

    // MARK: Extra key

    private var modifierRow: some View {
        VStack(alignment: .leading, spacing: D.space.xs) {
            SilkscreenLabel("Extra key", weight: .tiny)
                .silkscreenDecorative()
            HStack(spacing: D.space.sm) {
                ForEach(HotkeyModifier.allCases) { modifier in
                    modifierKey(modifier)
                }
                Spacer(minLength: 0)
            }
            // A dead key with no explanation reads as a bug. Printed in ordinary secondary ink
            // rather than alert ink, because for the default configuration this is simply how the
            // panel looks — nothing has gone wrong, one key is just already in use. It escalates to
            // the alert notice above only when the refused key is the one currently selected.
            if let deadKey {
                Text(deadKey)
                    .typeStyle(D.type.explain)
                    .foregroundStyle(D.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Why one of the four keys is greyed out, when one is.
    private var deadKey: String? {
        guard let conflicting = SecondLanguageRule.conflicting(hotkey: settings.hotkey) else {
            return nil
        }
        return "\(conflicting.glyph) cannot be used: it is part of \(settings.hotkey.displayName), "
            + "the dictation key itself."
    }

    private func modifierKey(_ modifier: HotkeyModifier) -> some View {
        let refused = SecondLanguageRule.refusal(hotkey: settings.hotkey, modifier: modifier)
        return TapeButton(
            role: .neutral,
            isLatched: modifier == settings.secondaryLocaleModifier,
            action: { settings.secondaryLocaleModifier = modifier }
        ) {
            Text(modifier.glyph)
        }
        // Refused, not merely unselected: the key is still shown, because a choice that silently
        // vanished would send the user hunting for it.
        .disabled(refused != nil)
        .help(refused ?? modifier.displayName)
        .accessibilityLabel(modifier.displayName)
        .accessibilityAddTraits(modifier == settings.secondaryLocaleModifier ? .isSelected : [])
    }

    // MARK: Language

    private var languageTray: some View {
        VStack(alignment: .leading, spacing: D.space.xs) {
            // Not "Second language" again: the panel above it already says that, and two identical
            // legends on one panel make the reader check whether they are looking at the same
            // control twice. This one names what the tray *does* to the key row above it.
            SilkscreenLabel("Switches to", weight: .tiny)
                .silkscreenDecorative()
            LocaleTray(
                locales: locales,
                selected: settings.secondaryLocaleIdentifier,
                onPick: { settings.secondaryLocaleIdentifier = $0 }
            )
        }
    }

    // MARK: Prose

    private var explanation: some View {
        VStack(alignment: .leading, spacing: D.space.sm) {
            Text("""
                Edict cannot tell which language you are speaking — Apple's dictation model is given \
                one language before it hears a word, and it never guesses. So you choose, with your \
                hands, one phrase at a time: hold the dictation key on its own for \
                \(Self.name(settings.localeIdentifier)), or add the extra key for the second \
                language. Let go and the next phrase is back to normal.
                """)
                .typeStyle(D.type.explain)
                .foregroundStyle(D.color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("""
                The language is fixed the moment recording starts, so press both keys before you \
                speak. While you are speaking, the two letters beside the record lamp say which \
                language Edict is actually using — check it there if a phrase comes back wrong.
                """)
                .typeStyle(D.type.explain)
                .foregroundStyle(D.color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let unavailable {
                notice(unavailable)
            }
        }
    }

    // MARK: Dual pass, for files only

    /// The one place the two languages can be used without the user's hands.
    ///
    /// It sits on *this* panel and not on the import panel because it is only meaningful once a
    /// second language exists — it is the file counterpart of the extra key above, and the sentence
    /// immediately above it ("Edict cannot tell which language you are speaking") is exactly the fact
    /// this control has to be read against.
    ///
    /// **The wording is the feature.** There is no language identification anywhere in Apple's speech
    /// framework, and a switch called anything like "detect language automatically" would be a claim
    /// about the operating system that is not true. What actually happens is mechanical and worth
    /// saying: the file is cut at its silences, every section is transcribed twice, and the two
    /// transcripts are compared for the function words and affixes of the language each one claims.
    /// So the label names what it does and the caption names its nature — a comparison of two
    /// transcripts, with a stated fallback for when the comparison is not decisive.
    private var dualPass: some View {
        VStack(alignment: .leading, spacing: D.space.sm) {
            RockerSwitch(
                "Try both languages on imported files",
                isOn: Binding(get: { settings.importDualPass },
                              set: { settings.importDualPass = $0 }),
                caption: "Transcribes each section of a file twice and keeps the closer match. "
                       + "A comparison of two transcripts, not the model recognising a language."
            )

            Text("""
                Live dictation is untouched by this — there, your hands choose. A file has no hands, \
                so Edict cuts the recording at its pauses, transcribes every section in \
                \(Self.name(settings.localeIdentifier)) and in \
                \(Self.name(settings.effectiveSecondaryLocaleIdentifier ?? settings.secondaryLocaleIdentifier)), \
                then keeps whichever transcript reads more like the language that produced it. Where \
                the two are too close to call it keeps \(Self.name(settings.localeIdentifier)).
                """)
                .typeStyle(D.type.explain)
                .foregroundStyle(D.color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if settings.importDualPass {
                Text("""
                    It makes a file take about five times as long — measured 4.3x on a 17-second \
                    clip and 5.1x on a 6-minute one — and holds the whole recording in memory \
                    while it works — about 130 MB for an hour. It helps on clean bilingual audio: a \
                    call, a voice memo, one person switching languages. On a distant or crowded \
                    recording it does not help at all, because there neither model transcribes much \
                    to choose between — the transcript itself will say so when that happens.
                    """)
                    .typeStyle(D.type.explain)
                    .foregroundStyle(D.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The honest version of "it is configured": `secondaryLocaleReady` is false when the engine
    /// could not prepare the language — assets not downloaded, or all five of this Mac's locale
    /// reservations already spent (RECON §6). The modifier then does nothing at all, and saying so
    /// here is the only place the user could ever find out.
    private var unavailable: String? {
        guard let secondary = settings.effectiveSecondaryLocaleIdentifier,
              refusal == nil,
              !model.secondaryLocaleReady
        else { return nil }
        return """
            \(Self.name(secondary)) is not ready yet. Its speech model may still be downloading, or \
            this Mac already has as many languages reserved as it allows. Until it is ready, \
            holding \(settings.secondaryLocaleModifier.glyph) dictates in \
            \(Self.name(settings.localeIdentifier)) like an ordinary phrase.
            """
    }

    private var refusal: String? {
        SecondLanguageRule.refusal(hotkey: settings.hotkey,
                                   modifier: settings.secondaryLocaleModifier)
    }

    /// The other way the shortcut can be inert: both trays pointing at the same language, which is
    /// what `Settings.effectiveSecondaryLocaleIdentifier` returns `nil` for.
    private var sameLanguageRefusal: String {
        """
        Both languages are set to \(Self.name(settings.localeIdentifier)), so the extra key has \
        nothing to switch to. Pick a different second language below.
        """
    }

    /// Alert ink on the panel, with the same stroked square the speech-model fault uses, so a
    /// problem here looks like the other problems in this window rather than like a new kind.
    private func notice(_ text: String) -> some View {
        HStack(alignment: .top, spacing: D.space.sm) {
            Rectangle()
                .strokeBorder(D.color.alert, lineWidth: D.border.thin)
                .frame(width: D.size.troughHeight, height: D.size.troughHeight)
                // Optically aligned to the first line of `explain` type rather than its box.
                .padding(.top, D.space.xs)
            Text(text)
                .typeStyle(D.type.explain)
                .foregroundStyle(D.color.alert)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private static func name(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

// MARK: - Behaviour

private struct BehaviourSection: View {

    let model: AppModel

    private var settings: Settings { model.settings }

    var body: some View {
        PanelSurface("Behaviour") {
            VStack(alignment: .leading, spacing: D.space.md) {
                RockerSwitch("Hold to talk", isOn: bind(\.pushToTalk),
                             caption: "Hold the key while you speak. Off means press once to start "
                                    + "and again to stop.")
                RockerSwitch("Insert text automatically", isOn: bind(\.autoInject),
                             caption: "Puts the text at your cursor. Off leaves it on the clipboard.")
                RockerSwitch("Show recording HUD", isOn: bind(\.showHUD),
                             caption: "A small floating panel while you dictate.")
                RockerSwitch("Play sounds", isOn: bind(\.playSounds),
                             caption: "A short tone when recording starts and stops.")
                RockerSwitch("Keep the microphone warm", isOn: bind(\.prewarmMicrophone),
                             caption: "Loses nothing at the start of a phrase, but leaves the orange "
                                    + "microphone indicator lit the whole time Edict is running.")
                SeamDivider(.horizontal)
                LoginItemRow(loginItem: model.loginItem)
            }
        }
    }

    /// `Settings` is `@Observable`, not `ObservableObject`, so there is no projected `$` binding.
    private func bind(_ path: ReferenceWritableKeyPath<Settings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: path] }, set: { settings[keyPath: path] = $0 })
    }
}

// MARK: - Login item

/// "Open at login", showing what `SMAppService` reports rather than what the user asked for.
///
/// The switch used to be bound to a `Settings.launchAtLogin` boolean that nothing read — no
/// `SMAppService` call existed anywhere in the app — so it flipped, persisted, and did nothing. What
/// replaces it is not just the missing call: the plate is bound to a getter that reads
/// `SMAppService.mainApp.status`, so if `register()` throws or macOS parks the job in
/// `.requiresApproval`, the plate is already showing the truth on the next frame and the row says why.
///
/// The lit window beside the plate exists because "on" is three states, not two: enabled, registered
/// but awaiting the user's approval in Login Items, and unavailable. A rocker can only be down or up.
struct LoginItemRow: View {

    let loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: D.space.sm) {
            HStack(spacing: D.space.md) {
                Toggle(isOn: binding) {
                    VStack(alignment: .leading, spacing: D.space.xxs) {
                        SilkscreenLabel("Open at login")
                        Text(caption)
                            .typeStyle(D.type.explain)
                            .foregroundStyle(D.color.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityHidden(true)
                    }
                }
                .toggleStyle(RockerSwitchStyle())
                .disabled(loginItem.isBusy || isUnavailable)
                .accessibilityHint(caption)

                Spacer(minLength: D.space.sm)

                // Fault ink on the chassis, never inside the window: `D.color.alert` is a dark brown in
                // the light appearance and `wellFill` is near-black in both.
                Rectangle()
                    .strokeBorder(D.color.alert, lineWidth: D.border.thin)
                    .frame(width: D.size.troughHeight, height: D.size.troughHeight)
                    .opacity(loginItem.state.isFault ? 1 : 0)
                RecessedWell(fill: .display, radius: D.radius.tight, inset: D.space.xs) {
                    Text(loginItem.state.displayName)
                        .typeStyle(D.type.silkscreen)
                        .foregroundStyle(D.color.displayInk)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: D.size.railWidth * 0.62)
                .accessibilityHidden(true)
            }

            if let notice { self.notice(notice) }

            if case .requiresApproval = loginItem.state {
                // The one state Edict cannot resolve on its own: macOS has the job registered and is
                // waiting for the user to switch it on. Saying "on" here would be the old lie again.
                TapeButton("Open Login Items", minWidth: S.keyWidth) {
                    loginItem.openLoginItemsSettings()
                }
                .accessibilityLabel("Open Login Items in System Settings")
            }
        }
        // The user can change this in System Settings while the window is open, so it is re-read every
        // time the pane appears rather than trusted from launch.
        .onAppear { loginItem.refresh() }
    }

    private var binding: Binding<Bool> {
        // The getter reads the *service*, so the plate can only ever show what macOS reports. There is
        // no stored intent anywhere in this row for the two to drift apart.
        Binding(get: { loginItem.state.isOn }, set: { loginItem.set($0) })
    }

    private var isUnavailable: Bool {
        if case .unavailable = loginItem.state { return true }
        return false
    }

    private var caption: String {
        switch loginItem.state {
        case .enabled: "macOS starts Edict when you log in."
        case .disabled: "Start Edict automatically when you log in."
        case .requiresApproval: "Registered, but macOS is waiting for you to switch it on in Login Items."
        case .unavailable(let why): why + "."
        }
    }

    private var notice: String? {
        if let failure = loginItem.failure { return failure }
        if case .unavailable(let why) = loginItem.state {
            return "\(why), so macOS will not manage a login item for it."
        }
        return nil
    }

    private func notice(_ text: String) -> some View {
        HStack(alignment: .top, spacing: D.space.sm) {
            Rectangle()
                .strokeBorder(D.color.alert, lineWidth: D.border.thin)
                .frame(width: D.size.troughHeight, height: D.size.troughHeight)
            Text(text)
                .typeStyle(D.type.explain)
                .foregroundStyle(D.color.alert)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Refine

/// One switch, and the numbers that are the whole reason it is a switch.
///
/// **The copy quotes latency before it describes the feature.** Clean-up is genuinely good — measured
/// excellent on both English and Indonesian — so a section that led with what it does would read as an
/// unqualified improvement, and the user would turn it on and then find that Edict had stopped feeling
/// instant without knowing which setting did it. The cost is 1.0 s warm and 2.9 s cold on a tail that
/// is otherwise 0.15–0.53 s, paid on *every* dictation. That belongs in the first sentence.
///
/// The availability line below the switch is not decoration either: refinement runs on Apple's
/// on-device model, which can be switched off in System Settings or still downloading, and a switch
/// that flips happily while the model it needs is unavailable is the inert-control failure this
/// codebase has already paid for once (see `LoginItemRow`).
private struct RefineSection: View {

    let model: AppModel

    private var settings: Settings { model.settings }

    /// The answer for the *primary* dictation language. The secondary language gets its own answer
    /// when a transcript in it is refined; this line is about the switch, and the switch's common case
    /// is the language the user dictates in by default.
    @State private var availability: RefinerAvailability?

    var body: some View {
        PanelSurface("Refine") {
            VStack(alignment: .leading, spacing: D.space.md) {
                RockerSwitch(
                    "Clean up before inserting",
                    isOn: Binding(
                        get: { settings.refineBeforeInsert },
                        set: { settings.refineBeforeInsert = $0 }
                    ),
                    // `RockerSwitch` truncates its caption at two lines, so the number that decides
                    // this lives there and the rest of the trade is printed below.
                    caption: "Measured on this Mac: 1.0 s once warm, 2.9 s cold — added to every "
                           + "dictation, on top of a wait that is normally under half a second."
                )
                Text("On, a dictation is punctuated and stripped of filler before it reaches your "
                     + "cursor, and Edict stops feeling instant. Off, you can still clean up, "
                     + "bullet-point or summarise any transcript from the log whenever you want it, "
                     + "at no cost to dictation itself.")
                    .typeStyle(D.type.explain)
                    .foregroundStyle(D.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Refinement runs on Apple's on-device model. Nothing is sent anywhere, there is "
                     + "no account and no key, and it works with no network at all — the same as the "
                     + "rest of Edict. It only ever rewrites words you said: it will not add a fact, "
                     + "answer a question in your dictation, or translate.")
                    .typeStyle(D.type.explain)
                    .foregroundStyle(D.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let sentence = availabilitySentence {
                    Text(sentence)
                        .typeStyle(D.type.explain)
                        .foregroundStyle(availabilityIsFault ? D.color.alert : D.color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: settings.localeIdentifier) {
            availability = await model.refinement.refiner.availability(for: settings.localeIdentifier)
        }
    }

    /// Only says something when there is something to say: a supported language on a working model
    /// needs no line, and printing "available" would be a control reporting its own health at the
    /// user for no reason.
    private var availabilitySentence: String? {
        switch availability {
        case .ready, .none: return nil
        case .localeUnsupported(let why), .unavailable(let why): return why
        }
    }

    private var availabilityIsFault: Bool {
        if case .unavailable = availability { return true }
        return false
    }
}

// MARK: - Refine a selection

/// The chord that opens the refine popup over text selected in *another* app.
///
/// This section exists as much for discoverability as for configuration. The gesture has no other
/// surface — the popup is summoned from inside somebody else's window, and the menu-bar item cannot
/// offer it, because clicking the menu bar activates Edict and loses the selection the popup is about
/// to replace. So the chord is printed here, in the same keys it is pressed in.
///
/// Live-updating like the dictation key: `DictationController` watches both settings and re-binds the
/// tap, so writing them *is* the change. There is no Apply key.
private struct RefineSelectionSection: View {

    let settings: Settings

    var body: some View {
        PanelSurface("Refine a selection") {
            VStack(alignment: .leading, spacing: D.space.md) {
                RockerSwitch(
                    "Refine selected text",
                    isOn: Binding(
                        get: { settings.refineSelectionEnabled },
                        set: { settings.refineSelectionEnabled = $0 }
                    ),
                    caption: "Select text in any app, press the chord below, and pick CLEAN UP, "
                           + "BULLETS or SUMMARY. The selection is replaced in place."
                )

                VStack(alignment: .leading, spacing: D.space.sm) {
                    ForEach(RefineChord.allCases) { chord in
                        key(chord)
                    }
                }
                .disabled(!settings.refineSelectionEnabled)
                .opacity(settings.refineSelectionEnabled ? 1 : D.opacity.disabled)

                if let refusal = settings.refineSelectionChord.refusal(dictationKey: settings.hotkey) {
                    Text(refusal)
                        .typeStyle(D.type.explain)
                        .foregroundStyle(D.color.alert)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(settings.refineSelectionChord.explanation)
                    .typeStyle(D.type.explain)
                    .foregroundStyle(D.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(caveat)
                    .typeStyle(D.type.explain)
                    .foregroundStyle(D.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One row per chord: the keys, whether it is the live one, and — for the one chord that cannot
    /// work on most keyboards — the reason, on the row rather than only in the paragraph below.
    ///
    /// The caveat is on the key itself because that is where the mistake gets made. A user scanning
    /// four rows picks one and stops reading; `Hold 🌐` looks like the friendliest of the four and is
    /// the only one that is silently dead on a Logitech, a Keychron or a Das. It has to say so in the
    /// same glance as its own name.
    private func key(_ chord: RefineChord) -> some View {
        let refused = chord.refusal(dictationKey: settings.hotkey) != nil
        let isLive = chord == settings.refineSelectionChord
        return TapeButton(
            role: .neutral,
            isLatched: isLive,
            minWidth: S.keyWidth,
            action: { settings.refineSelectionChord = chord }
        ) {
            HStack(spacing: D.space.sm) {
                Text(chord.displayName(dictationKey: settings.hotkey))
                if isLive {
                    Text(refused ? "Unavailable" : "Live")
                        .typeStyle(D.type.silkscreenTiny)
                }
                if let caveat = chord.rowCaveat {
                    Spacer(minLength: D.space.sm)
                    Text(caveat)
                        .typeStyle(D.type.silkscreenTiny)
                        .foregroundStyle(D.color.textSecondary)
                }
            }
        }
        .disabled(refused)
        .opacity(refused ? D.opacity.disabled : 1)
        .accessibilityLabel(
            [chord.displayName(dictationKey: settings.hotkey), chord.rowCaveat]
                .compactMap(\.self)
                .joined(separator: ", ")
        )
        .accessibilityAddTraits(isLive ? .isSelected : [])
    }

    /// The two things a user has to know before trusting this with their own document, both measured
    /// rather than hedged.
    private var caveat: String {
        """
        Edict reads the selection through Accessibility where the app allows it and with a copy         where it does not, and it restores your clipboard afterwards. If it cannot prove the         replacement landed, it leaves the refined text on your clipboard and says so rather than         writing twice. While the three keys are showing, Edict does swallow 1, 2, 3 and Esc —         otherwise pressing 1 would type a 1 over the selection it is about to replace. Nothing is         recorded in the log: this is text you already had.
        """
    }
}

// MARK: - Import

/// The one real choice file transcription has: which of Apple's two models runs it.
///
/// Worth a switch rather than a constant because the trade cuts both ways, and worth *saying* rather
/// than hiding, because the losing side of the trade is the dictionary the user has been curating.
private struct ImportSection: View {

    let settings: Settings

    var body: some View {
        PanelSurface("Import") {
            VStack(alignment: .leading, spacing: D.space.md) {
                RockerSwitch(
                    "Use the transcription model for files",
                    isOn: Binding(
                        get: { settings.importUsesGeneralModel },
                        set: { settings.importUsesGeneralModel = $0 }
                    ),
                    // `RockerSwitch` truncates its caption at two lines, so the headline number
                    // lives there and the rest of the trade is printed below.
                    caption: "Measured on a six-minute recording: 4% of words wrong at 66x "
                           + "realtime, against 10% at 15x for the dictation model."
                )
                Text("Off puts imported files on the same model as live dictation, which is the "
                     + "only one your dictionary can hint. Either way the replacement rules still "
                     + "run, and a language the transcription model does not cover — Indonesian "
                     + "among them — falls back on its own.")
                    .typeStyle(D.type.explain)
                    .foregroundStyle(D.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Edict does not identify speakers, whichever model runs. Apple's framework has "
                     + "no way to tell one voice from another.")
                    .typeStyle(D.type.explain)
                    .foregroundStyle(D.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Dictionary

private struct DictionarySection: View {

    let settings: Settings
    let dictionary: DictionaryStore

    var body: some View {
        PanelSurface("Dictionary") {
            VStack(alignment: .leading, spacing: D.space.md) {
                RockerSwitch("Hint the speech model", isOn: bind(\.biasingEnabled),
                             caption: "Sends your terms to the model so it hears them correctly in "
                                    + "the first place. Layer one.")
                RockerSwitch("Replace what it mishears", isOn: bind(\.correctionsEnabled),
                             caption: "Runs your correction pairs over the finished text. Layer two, "
                                    + "and the one that always works.")
                RockerSwitch("Fix capitalisation of terms", isOn: bind(\.termCaseNormalisation),
                             caption: "A term also corrects its own casing wherever it appears.")

                Stepped(
                    legend: "Hints sent",
                    value: Binding(get: { settings.biasingLimit },
                                   set: { settings.biasingLimit = $0 }),
                    range: Settings.biasingLimitRange,
                    step: 5,
                    unit: "trm"
                )
                .disabled(!settings.biasingEnabled)

                // Deliberately *not* alert ink: 50 is the default, so painting its explanation
                // orange would mean every user sees a warning about a setting they never touched.
                // Alert ink is for faults, and the ceiling is not one.
                Text(biasingNote)
                    .typeStyle(D.type.explain)
                    .foregroundStyle(D.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if dictionary.entries.count > settings.biasingLimit {
                    Text("\(dictionary.entries.count) entries, \(settings.biasingLimit) sent. "
                         + "The rest are still corrected afterwards \u{2014} nothing is ignored.")
                        .typeStyle(D.type.explain)
                        .foregroundStyle(D.color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var atCeiling: Bool { settings.biasingLimit >= Settings.biasingLimitRange.upperBound }

    /// RECON §5, and the reason the control stops where it does: measured hit rate *degrades* with
    /// list length. A 9-term list fixed "Wispr Flow" and "Obsidian" where a 200-term list fixed
    /// neither, and each term costs ~1.5 ms at analyzer setup on top of a ~65 ms floor.
    private var biasingNote: String {
        atCeiling
            ? "50 is the ceiling, and it is a measured one: longer hint lists make the model worse, "
            + "not better. The entries sent are ranked by how often each has actually fired."
            : "Only the highest-ranked entries are sent. Long hint lists measurably reduce accuracy, "
            + "so the cap stops at 50."
    }

    private func bind(_ path: ReferenceWritableKeyPath<Settings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: path] }, set: { settings[keyPath: path] = $0 })
    }
}

// MARK: - Limits

private struct LimitsSection: View {

    let settings: Settings
    let history: HistoryStore

    var body: some View {
        PanelSurface("History") {
            VStack(alignment: .leading, spacing: D.space.md) {
                Stepped(
                    legend: "Keep",
                    value: Binding(get: { settings.historyLimit },
                                   set: { settings.historyLimit = $0 }),
                    range: Settings.historyLimitRange,
                    step: 500,
                    unit: "rec"
                )
                HStack(spacing: D.space.md) {
                    SegmentCounter(.count(history.transcripts.count, unit: "rec"), scale: .small)
                    Text("held now")
                        .typeStyle(D.type.explain)
                        .foregroundStyle(D.color.textSecondary)
                    Spacer(minLength: 0)
                }
                Text("Everything you dictate is kept on this Mac in a plain file until it falls off "
                     + "the end of this limit, or you delete it in the History pane.")
                    .typeStyle(D.type.explain)
                    .foregroundStyle(D.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Stepped

/// A number with a decrement and an increment key. There is no `Stepper` in this design system and
/// there should not be — the system stepper's tiny stacked arrows are macOS chrome — so this is two
/// icon caps around a seated counter, which is what the hardware would have.
private struct Stepped: View {

    let legend: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String

    var body: some View {
        HStack(spacing: D.space.sm) {
            SilkscreenLabel(legend)
                .silkscreenDecorative()
            Spacer(minLength: D.space.xs)
            TapeButton(role: .neutral, size: .icon) { nudge(-step) } label: {
                Text("\u{2212}")
            }
            .disabled(value <= range.lowerBound)
            .accessibilityLabel("Decrease \(legend)")

            SegmentCounter(.count(value, unit: unit), scale: .small)

            TapeButton(role: .neutral, size: .icon) { nudge(step) } label: {
                Text("+")
            }
            .disabled(value >= range.upperBound)
            .accessibilityLabel("Increase \(legend)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(legend)
        .accessibilityValue("\(value)")
    }

    /// Snaps to the step grid rather than adding blindly, so a value loaded from disk (or clamped by
    /// the setter) does not leave the control permanently off-grid.
    private func nudge(_ delta: Int) {
        let target = delta > 0
            ? ((value / step) + 1) * step
            : ((value + step - 1) / step - 1) * step
        value = min(max(target, range.lowerBound), range.upperBound)
    }
}

// MARK: - Render fixtures

/// Sheets for the offscreen renderer, covering the second-language panel and the live language
/// indicator in both languages.
///
/// A parallel of `PreviewFixtures` rather than an addition to it, for the same reason
/// `ImportPreviewFixtures` is: `MainWindow.swift` — where `PreviewFixtures` lives — is not this
/// agent's file to edit. These sheets belong in `PreviewFixtures.renderSheets()` eventually.
@MainActor
public enum DualLocaleFixtures {

    /// A model in the middle of an utterance, in one of the two languages.
    ///
    /// Reaches for the same `apply(_:)` entry points `DictationController` uses, so a rendered state
    /// is a state the app can actually be in — a fixture that set the fields directly could paint a
    /// combination the controller never produces.
    public static func recording(secondary: Bool,
                                 secondaryReady: Bool = true,
                                 text: String? = nil) -> AppModel {
        let model = PreviewFixtures.model()
        model.apply(secondaryLocaleReady: secondaryReady)
        let identifier = secondary
            ? (model.settings.effectiveSecondaryLocaleIdentifier ?? model.settings.localeIdentifier)
            : model.settings.localeIdentifier
        model.apply(activeLocale: identifier, isSecondary: secondary)
        model.apply(phase: .listening)
        let spoken = text ?? (secondary
            ? "Tolong kirimkan draf itu sebelum rapat"
            : "Send the draft over before the meeting")
        model.apply(committed: spoken, volatile: " sore")
        return model
    }

    /// A model whose second language is configured but which the engine could not prepare.
    public static func notReady() -> AppModel {
        let model = PreviewFixtures.model()
        model.apply(secondaryLocaleReady: false)
        return model
    }

    /// The refused pair: Option as the language key while Right Option *is* the dictation key.
    public static func collided() -> AppModel {
        let model = PreviewFixtures.model()
        model.settings.hotkey = .rightOption
        model.settings.secondaryLocaleModifier = .option
        model.apply(secondaryLocaleReady: true)
        return model
    }

    /// Both trays on the same language, so the extra key has nothing to switch to.
    public static func sameLanguage() -> AppModel {
        let model = PreviewFixtures.model()
        model.settings.secondaryLocaleIdentifier = model.settings.localeIdentifier
        model.apply(secondaryLocaleReady: true)
        return model
    }

    /// - Parameter locales: the transcriber's supported locales, which the harness has to `await`
    ///   before rendering — an offscreen rasteriser cannot wait on a view's own `.task`.
    public static func renderSheets(locales: [Locale] = []) -> [PreviewFixtures.RenderSheet] {
        // Panel width plus the deck gutter the settings column pads with, so the sheet frames the
        // panel the way the window does.
        let panel = CGSize(width: S.column, height: 640)
        // The refine panel is the tallest of these: four chord rows plus two paragraphs.
        let refinePanel = CGSize(width: S.column, height: 860)
        let hud = CGSize(width: D.size.hudSize.width + D.space.lg,
                         height: D.size.hudSize.height + D.size.waveformHeight + D.space.lg)

        func sheet(_ id: String, _ size: CGSize, _ view: some View) -> PreviewFixtures.RenderSheet {
            PreviewFixtures.RenderSheet(
                id: id,
                size: size,
                view: AnyView(
                    view
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .background(D.surface.deckPaint)
                )
            )
        }

        func section(_ model: AppModel) -> some View {
            SecondLanguageSection(model: model, locales: locales)
                .padding(D.space.md)
        }

        func panelHUD(_ model: AppModel) -> some View {
            HUDContent(model: model, meter: model.levelMeter)
                .padding(D.space.sm)
        }

        func refineSelection(_ model: AppModel) -> some View {
            RefineSelectionSection(settings: model.settings)
                .padding(D.space.md)
        }

        return [
            sheet("second-language", panel, section(ready())),
            sheet("second-language-collision", panel, section(collided())),
            sheet("second-language-same", panel, section(sameLanguage())),
            sheet("second-language-not-ready", panel, section(notReady())),
            sheet("second-language-off", panel, section(disabled())),
            // Taller than `panel`: the dual-pass block sits below the prose and the whole point of
            // rendering it is to read the copy.
            sheet("second-language-dual-off", CGSize(width: S.column, height: 1_020), section(ready())),
            sheet("second-language-dual-on", CGSize(width: S.column, height: 1_120), section(dualPassOn())),
            sheet("hud-primary", hud, panelHUD(recording(secondary: false))),
            sheet("hud-secondary", hud, panelHUD(recording(secondary: true))),
            // Taller than it was: the refine-selection panel was added below the refine panel, and a
            // sheet cropped above the thing being proved proves nothing.
            sheet("settings-column", CGSize(width: S.column, height: 2_560),
                  SettingsWindow(model: PreviewFixtures.model(), unbounded: true, locales: locales)),
            // Taller than `panel`: the picker grew a fourth row and the two prose blocks under it
            // are the whole reason these sheets exist. A sheet cropped above the copy proves nothing.
            sheet("refine-selection-default", refinePanel, refineSelection(PreviewFixtures.model())),
            sheet("refine-selection-discrete", refinePanel, refineSelection(discreteChord())),
            // The row that has to read as a caveat rather than as a feature.
            sheet("refine-selection-fn", refinePanel, refineSelection(globeQualifier())),
            sheet("refine-selection-refused", refinePanel, refineSelection(globeIsTheDictationKey())),
            sheet("refine-selection-off", refinePanel, refineSelection(refineOff())),
        ]
    }

    /// The ordinary, working configuration: shortcut on, Indonesian prepared.
    private static func ready() -> AppModel {
        let model = PreviewFixtures.model()
        model.apply(secondaryLocaleReady: true)
        return model
    }

    /// The same panel with the file-import dual pass switched on, which is the state that has to be
    /// read most carefully: it is the one where the copy has to say what the switch actually does
    /// without implying the model recognises a language.
    private static func dualPassOn() -> AppModel {
        let model = ready()
        model.settings.importDualPass = true
        return model
    }

    /// A discrete chord chosen, so the explanation line under the keys is the other one.
    private static func discreteChord() -> AppModel {
        let model = ready()
        model.settings.refineSelectionChord = .optionCommandR
        return model
    }

    /// The demoted `fn` gesture, deliberately chosen on a keyboard-agnostic dictation key so the row
    /// is *live* rather than refused. This is the sheet to read: it is the only chord that can be
    /// selected, look healthy and still never fire, so the picker has to say "Apple keyboards only"
    /// on the row and say why underneath.
    private static func globeQualifier() -> AppModel {
        let model = ready()
        model.settings.refineSelectionChord = .fnThenDictationKey
        return model
    }

    /// The one refusal this picker can produce: Globe cannot qualify Globe. The row goes dead and the
    /// panel says why, rather than storing a chord that could never fire.
    private static func globeIsTheDictationKey() -> AppModel {
        let model = ready()
        model.settings.hotkey = .fn
        model.settings.refineSelectionChord = .fnThenDictationKey
        return model
    }

    private static func refineOff() -> AppModel {
        let model = ready()
        model.settings.refineSelectionEnabled = false
        return model
    }

    private static func disabled() -> AppModel {
        let model = PreviewFixtures.model()
        model.settings.secondaryLocaleEnabled = false
        return model
    }
}

// MARK: - Previews

#Preview("Second language") {
    SecondLanguageSection(model: PreviewFixtures.model(), locales: [])
        .padding(D.space.md)
        .background(D.surface.deckPaint)
}

#Preview("Second language — refused") {
    VStack(spacing: D.space.md) {
        SecondLanguageSection(model: DualLocaleFixtures.collided(), locales: [])
        SecondLanguageSection(model: DualLocaleFixtures.sameLanguage(), locales: [])
    }
    .padding(D.space.md)
    .background(D.surface.deckPaint)
}

#Preview("Settings — light") {
    SettingsWindow(model: PreviewFixtures.model())
}

#Preview("Settings — dark") {
    SettingsWindow(model: PreviewFixtures.model())
        .preferredColorScheme(.dark)
}
