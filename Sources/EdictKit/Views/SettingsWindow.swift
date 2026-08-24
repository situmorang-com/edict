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

    public var body: some View {
        Group {
            if unbounded { column } else { scrolling }
        }
        .frame(width: S.column)
        .background(D.surface.deckPaint)
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
                SpeechModelSection(model: model, preloaded: preloadedLocales)
                BehaviourSection(settings: model.settings)
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
    let preloaded: [Locale]

    @State private var locales: [Locale] = []

    var body: some View {
        PanelSurface("Speech model") {
            VStack(alignment: .leading, spacing: D.space.sm) {
                stateRow

                if locales.isEmpty {
                    Text("Reading the list of supported languages\u{2026}")
                        .typeStyle(D.type.explain)
                        .foregroundStyle(D.color.textSecondary)
                } else {
                    RecessedWell(fill: .list, inset: 0) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: D.space.xs) {
                                ForEach(ordered, id: \.identifier) { locale in
                                    localeKey(locale)
                                }
                            }
                            .padding(D.space.xs)
                        }
                        // Definite, not maximum: a `ScrollView` handed an ideal proposal measures
                        // as zero and the tray vanishes.
                        .frame(height: S.localeTrayHeight)
                    }
                }

                Text("The model runs entirely on this Mac; nothing you dictate leaves it. "
                     + "Changing the language takes effect on your next dictation.")
                    .typeStyle(D.type.explain)
                    .foregroundStyle(D.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            guard preloaded.isEmpty else {
                locales = preloaded
                return
            }
            // Asked directly of the framework because neither `AppModel` nor `DictationController`
            // exposes the engine's `supportedLocales` yet; see the handover note. Read-only and
            // cheap — it takes no locale reservation.
            let supported = await DictationTranscriber.supportedLocales
            locales = supported.sorted { $0.identifier(.bcp47) < $1.identifier(.bcp47) }
        }
    }

    /// Current first: with 54 entries the one that matters must not be somewhere down a scroll.
    private var ordered: [Locale] {
        let current = model.settings.localeIdentifier
        let isCurrent = { (l: Locale) in
            l.identifier(.bcp47).caseInsensitiveCompare(current) == .orderedSame
        }
        return locales.filter(isCurrent) + locales.filter { !isCurrent($0) }
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

    private func localeKey(_ locale: Locale) -> some View {
        let identifier = locale.identifier(.bcp47)
        let isCurrent = identifier.caseInsensitiveCompare(model.settings.localeIdentifier) == .orderedSame
        return TapeButton(
            role: .neutral,
            isLatched: isCurrent,
            minWidth: S.trayKeyWidth,
            action: { model.settings.localeIdentifier = identifier }
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

// MARK: - Behaviour

private struct BehaviourSection: View {

    let settings: Settings

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
                RockerSwitch("Open at login", isOn: bind(\.launchAtLogin))
            }
        }
    }

    /// `Settings` is `@Observable`, not `ObservableObject`, so there is no projected `$` binding.
    private func bind(_ path: ReferenceWritableKeyPath<Settings, Bool>) -> Binding<Bool> {
        Binding(get: { settings[keyPath: path] }, set: { settings[keyPath: path] = $0 })
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

// MARK: - Previews

#Preview("Settings — light") {
    SettingsWindow(model: PreviewFixtures.model())
}

#Preview("Settings — dark") {
    SettingsWindow(model: PreviewFixtures.model())
        .preferredColorScheme(.dark)
}
