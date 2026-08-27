import SwiftUI

// MARK: - Metrics

/// The popup's own geometry. Every value is written as its relationship to a token, so a token
/// change moves the panel with it — and so the one number that is genuinely a choice (the panel's
/// width) is stated once and everything else is derived from it.
enum RefinePopupMetrics {

    /// The panel's width. A popup is not the HUD: it is read in one glance beside a caret while the
    /// user's attention is on their own text, so it is three quarters of the HUD's width. Expressed
    /// against the HUD token so the two stay in proportion.
    static var panelWidth: CGFloat { D.size.hudSize.width * 0.75 }              // 270

    /// The width available to content, inside the shadow padding and the panel's own inset.
    static var contentWidth: CGFloat {
        panelWidth - (D.space.xs + D.space.panelInset) * 2                      // 238
    }

    /// The digit column on a key cap. One space token wide, so `1`, `2` and `3` sit on a column.
    static var digitWidth: CGFloat { D.space.md }                               // 12

    /// The legend column: the cap's width, less the digit column, the seam between them, their two
    /// gaps, `TapeButtonStyle`'s own `D.space.md` cap padding either side, and the 2pt the cap's
    /// seat adds. Written out rather than eyeballed so a token change cannot silently make the row
    /// wider than the panel.
    static var legendWidth: CGFloat {
        contentWidth
            - digitWidth
            - D.space.sm * 2
            - D.border.hairline
            - D.space.md * 2
            - 2
    }

    /// The seam between the digit and the legend is a *short* rule, struck through the capitals
    /// rather than the full height of the cap — a full-height rule would read as two keys.
    static var legendSeamHeight: CGFloat { D.size.iconButton * 0.45 }           // ~10

    /// How often the working state's counter is asked for the time. The `.elapsed` format prints
    /// tenths, so this is one tenth of a second by definition: faster redraws a number that cannot
    /// have changed, slower drops digits the format is showing. Nowhere near the 60 Hz needle tick —
    /// this is a clock, not a movement.
    static let counterTickInterval: TimeInterval = 0.1

    /// A failure sentence is allowed this many lines before it truncates. Measured off the rendered
    /// sheet: three lines of `D.type.explain` at this width hold ~95 characters, and the longest
    /// sentence `SelectionError` and `RefinementFailure` can produce is `tooLong`'s at 122. Four
    /// lines covers every one of them, which is the point — a truncated explanation of a failure is
    /// a second failure.
    static let sentenceLines = 4
}

// MARK: - The popup

/// The popup's three states in one small panel.
///
/// Matte black plastic and a bezel radius, exactly like the recording HUD: both are Edict's own
/// hardware appearing on top of somebody else's window, and they should read as the same object.
/// This is deliberately not an `NSMenu` — a system menu here would be the one part of the app that
/// belongs to macOS rather than to the instrument, and it would also have to take key focus, which
/// this feature cannot afford (see ``RefinePanel``).
struct RefinePopupView: View {

    let state: RefinePopupState
    /// Called when a row is clicked. Keys arrive through the event tap instead, so this is the
    /// mouse's path to the same door.
    let choose: (RefinementAction) -> Void

    var body: some View {
        PanelSurface(
            "Refine selection",
            material: .plastic,
            radius: D.radius.bezel,
            inset: D.space.panelInset
        ) {
            VStack(alignment: .leading, spacing: D.space.sm) {
                switch state {
                case .choosing: chooser
                case .working(let action): WorkingRow(action: action)
                case .failed(let sentence): failure(sentence)
                }
            }
            .frame(width: RefinePopupMetrics.contentWidth, alignment: .leading)
        }
        .shadow(D.shadow.hud)
        // The shadow needs room inside the window, which is borderless and exactly the panel's size.
        .padding(D.space.xs)
        .frame(width: RefinePopupMetrics.panelWidth)
        .animation(D.motion.panel, value: state)
        // One accessible group: the panel's own name is on the `NSPanel`, and each key names itself.
        .accessibilityElement(children: .contain)
    }

    // MARK: Choosing

    private var chooser: some View {
        VStack(alignment: .leading, spacing: D.space.xs) {
            // Driven off `allCases`, so the keys the panel prints, the digits it obeys, and the
            // engine's own list are one list. Adding a fourth action needs no change here.
            ForEach(RefinementAction.allCases) { action in
                KeyRow(action: action, isLatched: false) { choose(action) }
            }
            // Printed at full strength, not at `D.opacity.ghost`: this is the only place the user
            // is told how to get out, so it is nomenclature, not decoration. The tiny weight is
            // what makes it recede.
            SilkscreenLabel("Esc cancels", weight: .tiny)
                .padding(.top, D.space.xxs)
        }
    }

    // MARK: Failure

    /// One sentence, in the app's single alert colour. Never a dead panel: this state closes itself
    /// after `RefinePopupTimeouts.failureDwell`, and `Esc` takes it away sooner.
    ///
    /// The sentence sits in a `.list` well rather than directly on the plastic, and that is a
    /// legibility fix, not decoration: the panel is matte black in *both* appearances, so
    /// `D.color.alert` — a dark brown, `#76400C`, in the light appearance — was unreadable on it in
    /// the rendered sheet. A `.list` well is the one ground in the system that tracks the appearance,
    /// so the amber lands on pale grey in light and on near-black in dark, which is the pairing the
    /// token's measured 5.3:1 contrast was computed against.
    private func failure(_ sentence: String) -> some View {
        VStack(alignment: .leading, spacing: D.space.sm) {
            RecessedWell(fill: .list, radius: D.radius.well, inset: D.space.wellInset) {
                Text(sentence)
                    .typeStyle(D.type.explain)
                    .foregroundStyle(D.color.alert)
                    .lineLimit(RefinePopupMetrics.sentenceLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: RefinePopupMetrics.contentWidth)
            SilkscreenLabel("Esc closes", weight: .tiny)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(sentence)
    }
}

// MARK: - One key

/// A full-width key cap: the digit, a seam, and the action's legend.
///
/// The legend is `RefinementAction.title` verbatim, so what the panel offers cannot drift from what
/// the engine does.
private struct KeyRow: View {

    let action: RefinementAction
    /// A latched key is the working state's answer to "which one did I press": the cap stays down.
    let isLatched: Bool
    let press: () -> Void

    var body: some View {
        Button(action: press) {
            HStack(spacing: D.space.sm) {
                // The digit is silkscreen, not cap legend: it is the number printed *on* the key,
                // and at cap weight it would compete with the action's own name.
                Text("\(digit)")
                    .typeStyle(D.type.silkscreen)
                    .frame(width: RefinePopupMetrics.digitWidth, alignment: .center)
                SeamDivider(.vertical)
                    .frame(height: RefinePopupMetrics.legendSeamHeight)
                Text(action.title)
                    .frame(width: RefinePopupMetrics.legendWidth, alignment: .leading)
            }
        }
        .buttonStyle(
            TapeButtonStyle(role: .neutral, size: .standard, isLatched: isLatched, minWidth: nil)
        )
        .focusEffectDisabled()
        // A latched key is a readout, not an offer: clicking the working state must not re-refine.
        // `.disabled` would be the obvious way to say that and it is the wrong one — it drops the
        // cap to `D.opacity.disabled`, and the rendered sheet showed a key that read as *unavailable*
        // rather than as *held down*, which is the one thing this state has to communicate.
        .allowsHitTesting(!isLatched)
        // Natural case, so VoiceOver says "Clean Up" instead of spelling the silkscreened caps out
        // letter by letter (DESIGN-COMPONENTS §0.2). The digit is in the name rather than the hint
        // because the number *is* how this control is operated, and hints can be switched off.
        .accessibilityLabel("\(action.title.capitalized), key \(digit)")
        .accessibilityHint(action.explanation)
        .accessibilityInputLabels([action.title.capitalized, "\(digit)"])
        .accessibilityAddTraits(isLatched ? .isSelected : [])
    }

    /// Falls back to 0 only if an action is somehow outside `allCases`, which cannot happen; a
    /// crash here would take down the popup over somebody else's document.
    private var digit: Int { RefinePopupSession.digit(for: action) ?? 0 }
}

// MARK: - Working

/// The ~1 s the model takes, which means this is seen on every single use.
///
/// Two moving parts and no invented progress. The chosen key stays **down** — the physical answer to
/// "did it take my keystroke" — and the counter climbs. `FoundationModels` reports no progress
/// fraction, so a bar here would be a fiction; a climbing counter is the true version of the same
/// reassurance, and it is the same choice the HUD makes for refinement.
private struct WorkingRow: View {

    let action: RefinementAction

    /// Set when this state appears. The session does not carry a start date, because the elapsed
    /// clock belongs to the view that draws it — nothing else in the app needs to know.
    @State private var began = Date.now

    var body: some View {
        VStack(alignment: .leading, spacing: D.space.sm) {
            KeyRow(action: action, isLatched: true, press: {})
            HStack(spacing: D.space.sm) {
                SilkscreenLabel("Refining")
                Spacer(minLength: D.space.xs)
                TimelineView(
                    .animation(minimumInterval: RefinePopupMetrics.counterTickInterval)
                ) { context in
                    SegmentCounter(
                        .elapsed(context.date.timeIntervalSince(began)),
                        scale: .tiny,
                        seated: true
                    )
                }
            }
            .frame(width: RefinePopupMetrics.contentWidth, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Refining, \(action.title.capitalized)")
    }
}

// MARK: - Fixtures

/// The three states at their real size, for the offline `ImageRenderer` proof sheets. RECON
/// amendment 40: Screen Recording is denied to any process an agent starts, so a rendered view is
/// the only picture of this panel that can be taken automatically.
@MainActor
enum RefinePopupFixtures {

    struct Sheet: Identifiable {
        let id: String
        let view: AnyView
    }

    static var sheets: [Sheet] {
        [
            Sheet(id: "choosing", view: AnyView(sheet(.choosing))),
            Sheet(id: "working", view: AnyView(sheet(.working(.bullets)))),
            // The *longest* sentence either error type can produce (`RefinementFailure.tooLong`, 122
            // characters), so the sheet proves the line allowance rather than flattering it.
            Sheet(
                id: "failed",
                view: AnyView(
                    sheet(
                        .failed(
                            "This transcript is about 4200 words and refinement handles about 6000 "
                                + "at a time. Select a shorter passage, or refine it in parts."
                        )
                    )
                )
            ),
        ]
    }

    /// On the deck paint, because that is not what is behind it in life — a document is — but a
    /// neutral ground is the only honest way to judge the panel's own edges and shadow.
    private static func sheet(_ state: RefinePopupState) -> some View {
        RefinePopupView(state: state, choose: { _ in })
            .padding(D.space.lg)
            .background(D.surface.deckPaint)
    }
}

#if DEBUG
#Preview("Refine popup — choosing") {
    RefinePopupView(state: .choosing, choose: { _ in })
        .padding(D.space.lg)
        .background(D.surface.deckPaint)
}

#Preview("Refine popup — working") {
    RefinePopupView(state: .working(.cleanUp), choose: { _ in })
        .padding(D.space.lg)
        .background(D.surface.deckPaint)
}

#Preview("Refine popup — failed") {
    RefinePopupView(
        state: .failed("Edict could not copy the selection out of that app. Copy it yourself and try again."),
        choose: { _ in }
    )
    .padding(D.space.lg)
    .background(D.surface.deckPaint)
}
#endif
