//
//  Components.swift
//  EdictKit — Design
//
//  The reusable physical parts every view in Edict assembles from: caps in seats, wells cut
//  into panels, silkscreened labels, seams, lamps, counters, rows and readouts.
//
//  Spec: docs/DESIGN-COMPONENTS.md. Every colour, type style, spacing, radius, border, shadow
//  and duration comes from `Tokens.swift`; nothing here invents one. The remaining numbers —
//  a column width, a plate size, a lift distance — live in `M` below and nowhere else.
//
//  Concurrency: no type here is `@MainActor` and none is `Sendable`. SwiftUI's `body` is
//  already main-actor isolated, so plain `() -> Void` action closures are correct and impose
//  nothing on callers (spec §0.6).
//

import SwiftUI

// MARK: - Metrics

/// Component metrics. Geometry that belongs to one component and is not a design token.
/// Anything with a token *must* use the token; this holds only the shapes' own proportions.
/// Where a metric is a multiple of a token it is written as the multiplication, so the
/// relationship survives a token change.
private enum M {

    // ---- Caps and seats -------------------------------------------------------------

    /// The gap that makes a cap read as *inserted* rather than *drawn on*. One point on every
    /// side of the cap, so a cap's view footprint is 2pt larger than the cap in each axis.
    static let capSeatOutset: CGFloat = 1
    /// How far a cap rises under the pointer. Deliberately sub-pixel-ish: a key does not jump.
    static let hoverLift: CGFloat = 0.5
    /// RECORD and STOP come out the same width without the call site coordinating, which is the
    /// invariant that matters on the transport deck.
    static let transportMinWidth = D.size.buttonHeight * 2.6          // 78

    // ---- Silkscreen -----------------------------------------------------------------

    /// The rule in a `ruled` label strikes through the middle of the capitals, not the baseline.
    static let ruleCapOffset: CGFloat = -1

    // ---- Seams ----------------------------------------------------------------------

    /// Depth of a machined channel between two *structural* blocks. A 1pt seam disappears at
    /// the scale of a whole-window boundary.
    static let channelDepth: CGFloat = 1.5

    // ---- Panels ---------------------------------------------------------------------

    /// Below this a panel drops its label rather than give up its inset.
    static let tightWidth: CGFloat = 240

    // ---- Wells -----------------------------------------------------------------------

    /// Cap on an inner shadow's radius as a fraction of the well's height. See `fittedRim`.
    static let innerRimHeightRatio: CGFloat = 0.075

    // ---- Rocker switch --------------------------------------------------------------

    static let rockerWidth = D.size.buttonHeight + D.space.xs          // 34
    static let rockerHeight = D.size.buttonHeight * 0.6                // 18
    static let rockerRowMin: CGFloat = 200

    // ---- Transcript row -------------------------------------------------------------

    /// The spec fixes this at 38, which is half a point short of `HH:mm` at `D.type.counterSmall`
    /// plus its 0.4pt tracking — measured, the clock truncated to `09:…`. A truncated clock is
    /// worse than a 42pt column, and the column stays *fixed*, so every row still lands on the
    /// same width.
    static let colTime: CGFloat = 42
    static let colDuration: CGFloat = 44
    static let colWords: CGFloat = 40
    static let colFlag: CGFloat = 12
    static let colTextMin: CGFloat = 120
    /// The glyph inside a `.icon` cap. Small and semibold so it survives the engraving shadow.
    static let iconGlyphSize: CGFloat = 9
    static let flagSize: CGFloat = 6
    /// Column degradation thresholds, widest first.
    static let rowWide: CGFloat = 620
    static let rowMedium: CGFloat = 480
    static let rowNarrow: CGFloat = 360

    // ---- Search field ---------------------------------------------------------------

    /// The field and the list it filters share one rhythm.
    static let fieldHeight = D.size.rowHeight                          // 26
    static let fieldMin: CGFloat = 140

    // ---- Status readout -------------------------------------------------------------

    static let statusHeight = D.size.troughHeight * 3                  // 18
    static let statusCompactHeight = D.size.troughHeight * 2           // 12
    /// A square, not a circle — the round lit thing in this app is the record lamp.
    static let tellTaleSize: CGFloat = 5
    static let progressHeight: CGFloat = 1.5
    static let statusMin: CGFloat = 110
    /// The longest fixed condition string; it sets the reserved width so the channel never
    /// resizes as the condition changes.
    static let statusTemplate = "Transcribing"

    // ---- Record lamp ----------------------------------------------------------------

    static let haloScale: CGFloat = 1.55
    static let breatheLow: Double = 0.42
    static let breatheHigh: Double = 0.78
    /// Steady-lit substitute for `lampAlarm`'s six half-cycles, under Reduce Motion.
    static let faultHold: TimeInterval = 1.7
    /// `D.surface.lampLens` bakes in `endRadius: D.size.lampDiameter * 0.75`, so a compact lens
    /// is the standard lens scaled, never a lens drawn at another diameter.
    static let compactLampScale: CGFloat = 0.62
}

// MARK: - Environment

public extension EnvironmentValues {
    /// True when the user has asked for increased contrast, in either appearance.
    ///
    /// The palette already folds the two high-contrast appearances onto their base appearances,
    /// so no component changes *colour* here. What changes is weight: structural hairlines
    /// thicken, dimmed text goes to full opacity, silkscreen loses its engraving offset, and
    /// needles and bars gain half a point (spec §0.4).
    var edictIncreasedContrast: Bool { colorSchemeContrast == .increased }
}

/// True when the surrounding surface is dark in *both* appearances, so content must use
/// `D.color.displayInk` rather than `D.color.textPrimary`.
///
/// The palette's one real trap: `textPrimary` is near-black in the light appearance while
/// `D.surface.wellFill` is near-black in *both*. `RecessedWell(fill: .display)` and
/// `.faceplate` set this true, `.list` and `PanelSurface` set it false, and every component
/// that draws text into either container reads it instead of relying on a convention.
private struct EdictInkOnDarkKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var edictInkOnDark: Bool {
        get { self[EdictInkOnDarkKey.self] }
        set { self[EdictInkOnDarkKey.self] = newValue }
    }
}

/// The ink a component should use for readable text, given where it has been placed.
private extension EnvironmentValues {
    var edictPrimaryInk: Color { edictInkOnDark ? D.color.displayInk : D.color.textPrimary }
    var edictSecondaryInk: Color { edictInkOnDark ? D.color.displayInk : D.color.textSecondary }
}

// MARK: - Rim shadows

/// Scales an inner-shadow token down for a short shape.
///
/// `D.InnerShadow` strokes the shape at twice the shadow's radius and blurs by it, which is right
/// for a tall well and floods a short one: `wellInner`'s 3pt radius paints 6pt in from every edge,
/// and the status channel is only 18pt tall. In the light appearance, where `highlightInner` is
/// 55% white, that turns a lit channel into a pale bar — measured on the rendered sheet, not
/// guessed. Capping the radius at `M.innerRimHeightRatio` of the height keeps the rim a rim; the
/// tall wells (the meter card at 76pt, the deck counter at 40pt) come back unchanged.
private func fittedRim(_ shadow: D.Shadow, height: CGFloat) -> D.Shadow {
    guard height.isFinite, height > 0 else { return shadow }
    let radius = min(shadow.radius, max(height * M.innerRimHeightRatio, 0.5))
    guard radius < shadow.radius, shadow.radius > 0 else { return shadow }
    let scale = radius / shadow.radius
    return D.Shadow(color: shadow.color, radius: radius, x: shadow.x * scale, y: shadow.y * scale)
}

// MARK: - SeamDivider

/// A joint between two panels. A single grey line is a divider; two hairlines, one dark and one
/// light, are a seam — the dark one is the gap, the light one is the lower panel catching the
/// light below it.
public struct SeamDivider: View {

    public enum Depth: Sendable, Hashable {
        /// `D.Seam` exactly: `seam` + `seamHighlight`, 1pt total.
        case hairline
        /// A machined channel: `seam` hairline, a `D.color.wellFill` groove, then `seamHighlight`.
        /// 2.5pt total. For the joint between two *structural* blocks — the deck and the content
        /// area, the rail and the panes.
        case channel
    }

    private let axis: Axis
    private let depth: Depth
    private let inset: CGFloat

    @Environment(\.edictIncreasedContrast) private var increasedContrast

    /// - Parameter inset: shortens the seam at both ends along its own axis, which is how a real
    ///   panel joint stops short of a rounded corner. The deck's seam passes `D.radius.chassis`.
    public init(_ axis: Axis = .horizontal, depth: Depth = .hairline, inset: CGFloat = 0) {
        self.axis = axis
        self.depth = depth
        self.inset = inset
    }

    public var body: some View {
        content
            .padding(axis == .horizontal ? .horizontal : .vertical, inset)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch depth {
        case .hairline:
            // Under Increase Contrast the dark half thickens and the light half does not, so the
            // joint gains definition without becoming a black rule (spec §7).
            if increasedContrast {
                stack(darkThickness: D.border.thin, groove: 0)
            } else {
                D.Seam(axis == .horizontal ? .horizontal : .vertical)
            }
        case .channel:
            stack(darkThickness: D.border.hairline, groove: M.channelDepth)
        }
    }

    /// The seam drawn by hand: dark line, optional groove, light catch.
    @ViewBuilder
    private func stack(darkThickness: CGFloat, groove: CGFloat) -> some View {
        switch axis {
        case .horizontal:
            VStack(spacing: 0) {
                D.color.seam.frame(height: darkThickness)
                if groove > 0 { D.color.wellFill.frame(height: groove) }
                D.color.seamHighlight.frame(height: D.border.hairline)
            }
            .frame(height: darkThickness + groove + D.border.hairline)
        case .vertical:
            HStack(spacing: 0) {
                D.color.seam.frame(width: darkThickness)
                if groove > 0 { D.color.wellFill.frame(width: groove) }
                D.color.seamHighlight.frame(width: D.border.hairline)
            }
            .frame(width: darkThickness + groove + D.border.hairline)
        }
    }
}

// MARK: - SilkscreenLabel

/// A label screen-printed onto the chassis. Everything gets one; nothing invents its own.
///
/// Pass **natural case** — the type style uppercases it. That is not cosmetic: an all-caps
/// string handed to VoiceOver is frequently spelled out letter by letter, so passing natural
/// case means the accessible string is correct with no extra work (spec §0.2). Genuine acronyms
/// (`"VU"`, `"dBFS"`, `"CLR"`) are correct in caps for both eye and screen reader.
///
/// Silkscreen sizes are fixed by the panel and do **not** scale with Dynamic Type: a label that
/// grows tears the deck apart. The content the user actually reads (`D.type.body`, `caption`,
/// `explain`) does scale. This is a deliberate, stated exception.
///
/// Accessibility is the caller's decision, because the label cannot know what it names. If it
/// names a control beside it, apply `.silkscreenDecorative()` here and put the name on the
/// control. If it names a *region*, leave it visible and let the container carry `.isHeader`.
public struct SilkscreenLabel: View {

    public enum Weight: Sendable, Hashable {
        /// `D.type.silkscreen`. The workhorse: above a control, beside a lamp.
        case standard
        /// `D.type.silkscreenTiny`. Scale legends, unit suffixes, tick labels.
        case tiny
        /// `D.type.silkscreenHeading`. Above a whole block of controls.
        case heading
    }

    private let text: String
    private let weight: Weight
    private let ruled: Bool
    private let alignment: HorizontalAlignment

    @Environment(\.edictIncreasedContrast) private var increasedContrast
    @Environment(\.edictInkOnDark) private var inkOnDark

    public init(
        _ text: String,
        weight: Weight = .standard,
        ruled: Bool = false,
        alignment: HorizontalAlignment = .leading
    ) {
        // `INPUT ─────────` only reads as equipment left-aligned; a centred label with a rule
        // hanging off one side is a web section header.
        assert(!ruled || alignment == .leading, "A ruled silkscreen label must be leading-aligned.")
        self.text = text
        self.weight = weight
        self.ruled = ruled
        self.alignment = ruled ? .leading : alignment
    }

    public var body: some View {
        if ruled {
            HStack(spacing: D.space.labelGap) {
                printedInk
                SeamDivider(.horizontal)
                    .offset(y: M.ruleCapOffset)
            }
        } else {
            // A silkscreen label never wraps: two-line panel labels do not exist on equipment.
            // The flexible frame is added only when the caller asked for a non-default alignment,
            // so the default label stays tight and can sit beside a lamp in an `HStack`.
            printedInk
                .fixedSize(horizontal: true, vertical: false)
                .modifier(SilkscreenAlignment(alignment: alignment))
        }
    }

    /// The printed ink itself. `.engravedLabel()` / `.engravedHeading()` are the one definition
    /// of printed ink, so the normal path calls them rather than restating type + colour +
    /// shadow. Under Increase Contrast the `D.shadow.engraved` offset is dropped — the light
    /// offset costs edge contrast on the letterform, and legibility beats material (spec §0.4).
    @ViewBuilder
    private var printedInk: some View {
        let label = Text(text)
            .lineLimit(1)
            .truncationMode(.tail)

        Group {
            switch (weight, usesTokenModifier) {
            case (.standard, true):
                label.engravedLabel()
            case (.heading, true):
                label.engravedHeading()
            default:
                label
                    .typeStyle(typeStyle)
                    .foregroundStyle(inkColour)
                    .shadow(increasedContrast ? D.Shadow(color: .clear, radius: 0) : D.shadow.engraved)
            }
        }
        .dynamicTypeSize(.large)
    }

    private var typeStyle: D.TypeStyle {
        switch weight {
        case .standard: D.type.silkscreen
        case .tiny: D.type.silkscreenTiny
        case .heading: D.type.silkscreenHeading
        }
    }

    /// Silkscreen ink is a *panel* colour, so a label printed on matte black plastic or inside a
    /// display well has to switch to `displayInk` — `textSilkscreen` is near-black in the light
    /// appearance and vanishes on a dark insert (spec §6.3).
    private var inkColour: Color { inkOnDark ? D.color.displayInk : D.color.textSilkscreen }

    /// `.engravedLabel()` / `.engravedHeading()` are the one definition of printed ink, so the
    /// default path calls them. They hardcode `textSilkscreen` and carry `D.shadow.engraved`, so
    /// the dark-insert and Increase Contrast cases have to be assembled by hand.
    private var usesTokenModifier: Bool { !increasedContrast && !inkOnDark }
}

/// Expands to the offered width and aligns, but only for a non-default alignment.
private struct SilkscreenAlignment: ViewModifier {
    let alignment: HorizontalAlignment

    func body(content: Content) -> some View {
        switch alignment {
        case .trailing: content.frame(maxWidth: .infinity, alignment: .trailing)
        case .center: content.frame(maxWidth: .infinity, alignment: .center)
        default: content
        }
    }
}

public extension View {
    /// Marks a silkscreen label as decoration: the control it names carries the accessible name,
    /// so the label must not be read a second time.
    func silkscreenDecorative() -> some View {
        accessibilityHidden(true)
    }
}

// MARK: - PanelSurface

/// The three materials a panel can be milled or moulded from. See `PanelSurface.Material`.
public enum PanelSurfaceMaterial: Sendable, Hashable {
    /// `.raisedPanel()` — matte painted plastic. The default for a group of controls.
    case painted
    /// `.brushedFace()` — milled aluminium. The transport deck and the meter housing only.
    case brushed
    /// Matte black plastic insert. The transport block and the HUD body.
    case plastic
}

/// A panel bolted to the deck. Standing proud of the chassis, with a lit top edge and a contact
/// shadow, so it reads as a separate piece of material.
///
/// One of exactly two structural containers. There is no third option: no bare `VStack` on the
/// deck paint, no floating card, no free-standing rectangle.
public struct PanelSurface<Content: View>: View {

    /// Spelled `PanelSurface.Material` at every call site. It is declared outside the generic
    /// struct because a type nested in a generic is parameterised by that generic, which would
    /// make `PanelSurface<VStack<…>>.Material` a *different* type from `PanelSurface<Text>.Material`.
    public typealias Material = PanelSurfaceMaterial

    private let label: String?
    private let material: Material
    private let radius: CGFloat
    private let inset: CGFloat
    private let content: Content

    /// Measured, not requested: `onGeometryChange` reports the width without a `GeometryReader`
    /// swallowing the panel's intrinsic size.
    @State private var measuredWidth: CGFloat = .greatestFiniteMagnitude

    /// - Parameters:
    ///   - label: a silkscreened panel label, natural case, drawn ruled above the content.
    ///   - inset: content padding. Defaults to `D.space.panelInset`; pass `0` for a panel whose
    ///     content already insets itself (a table, a well).
    public init(
        _ label: String? = nil,
        material: Material = .painted,
        radius: CGFloat = D.radius.panel,
        inset: CGFloat = D.space.panelInset,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.material = material
        self.radius = radius
        self.inset = inset
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: D.space.labelGap) {
            if let label, showsLabel {
                // Printed on the panel it belongs to, *inside* the inset — not floating above it
                // in the deck's gap, which is the mistake that makes panels look like web cards.
                SilkscreenLabel(label, weight: .heading, ruled: true)
                    .silkscreenDecorative()
                    .environment(\.edictInkOnDark, material == .plastic)
            }
            content
        }
        .padding(inset)
        .modifier(PanelMaterial(material: material, radius: radius))
        // The spec says a panel always sets this false, but `.plastic` is `D.surface.mattePlastic`
        // — matte black in *both* appearances — so false would print `textSilkscreen` (near-black
        // in the light appearance) onto black plastic. This is precisely the trap the key exists
        // to prevent, so the value follows the material.
        .environment(\.edictInkOnDark, material == .plastic)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
        // One name, not two: the panel carries the label and the printed label is hidden above.
        .accessibilityElement(children: .contain)
        .modifier(OptionalAccessibilityLabel(label: label))
    }

    /// Cramping order (spec §6): the label goes before the inset does, and the inset is never
    /// reduced at all — a panel whose padding has collapsed reads as broken, a panel that lost
    /// its label reads as unlabelled.
    private var showsLabel: Bool { measuredWidth >= M.tightWidth }
}

/// Applies an accessibility label only when there is one to apply.
private struct OptionalAccessibilityLabel: ViewModifier {
    let label: String?

    func body(content: Content) -> some View {
        if let label {
            content.accessibilityLabel(label)
        } else {
            content
        }
    }
}

/// The three materials, as one modifier so `PanelSurface.body` stays a single expression.
private struct PanelMaterial: ViewModifier {
    let material: PanelSurfaceMaterial
    let radius: CGFloat

    func body(content: Content) -> some View {
        switch material {
        case .painted:
            content.raisedPanel(radius: radius)
        case .brushed:
            content.brushedFace(radius: radius)
        case .plastic:
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            content
                .background(shape.fill(D.surface.mattePlastic))
                .overlay(shape.strokeBorder(D.surface.raisedEdge, lineWidth: D.border.thin))
                .clipShape(shape)
                .shadow(D.shadow.raised)
        }
    }
}

// MARK: - RecessedWell

/// **The most important choice in this file.** A "well" is two materially different things in
/// this design, and confusing them produces dark ink on a dark ground. See `RecessedWell.Fill`.
public enum RecessedWellFill: Sendable, Hashable {
    /// `D.surface.wellFill` — near-black in *both* appearances. A lit display: the counter
    /// window, the waveform strip, the HUD body, the status channel.
    /// Content ink is `D.color.displayInk`.
    case display
    /// `D.color.panelRecessed` — appearance-tracking (pale grey in light, near-black in dark).
    /// A sunken tray holding *readable content*: the history table, the dictionary table, a
    /// multi-line text area. Content ink is `textPrimary` / `textSecondary`.
    case list
    /// `D.surface.meterFace` — the cream VU card, warm and pale in both appearances because a
    /// lit meter is lit. Content ink is `D.color.meterScale`.
    case faceplate
}

/// An opening cut into the panel. Lists, text fields, counters, the waveform, the meter card.
public struct RecessedWell<Content: View>: View {

    /// Spelled `RecessedWell.Fill` at every call site; declared outside the generic for the same
    /// reason as `PanelSurface.Material`.
    public typealias Fill = RecessedWellFill

    private let fill: Fill
    private let radius: CGFloat
    private let inset: CGFloat
    private let clipsContent: Bool
    private let content: Content

    @State private var measuredHeight: CGFloat = .greatestFiniteMagnitude

    /// - Parameter clipsContent: `false` exists for the one case where content must overhang the
    ///   opening — the VU needle, whose tail runs under the bezel. It changes nothing else.
    public init(
        fill: Fill = .list,
        radius: CGFloat = D.radius.well,
        inset: CGFloat = D.space.wellInset,
        clipsContent: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.fill = fill
        self.radius = radius
        self.inset = inset
        self.clipsContent = clipsContent
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .padding(inset)
            .environment(\.edictInkOnDark, inkOnDark)
            .background(shape.fill(shading))
            // All four layers are required. An opening drawn with only some of them looks like a
            // border: (2) is the overhang shading the top, and (3) — the half people leave out —
            // is the light catch that makes it a hole rather than a dark rectangle.
            .innerShadow(shape, fittedRim(D.shadow.wellInner, height: measuredHeight))
            .innerShadow(shape, fittedRim(D.shadow.wellInnerLight, height: measuredHeight))
            .overlay(shape.strokeBorder(D.surface.recessedEdge, lineWidth: D.border.thin))
            .clipShapeIfNeeded(shape, enabled: clipsContent)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredHeight = $0 }
            .accessibilityElement(children: .contain)
    }

    private var shading: AnyShapeStyle {
        switch fill {
        case .display: AnyShapeStyle(D.surface.wellFill)
        case .list: AnyShapeStyle(D.color.panelRecessed)
        case .faceplate: AnyShapeStyle(D.surface.meterFace)
        }
    }

    private var inkOnDark: Bool {
        switch fill {
        case .display, .faceplate: true
        case .list: false
        }
    }
}

private extension View {
    /// `clipShape` with a switch, so `RecessedWell.body` stays one expression.
    @ViewBuilder
    func clipShapeIfNeeded<S: Shape>(_ shape: S, enabled: Bool) -> some View {
        if enabled { clipShape(shape) } else { self }
    }
}

// MARK: - TapeButton

/// A physical push key. The press is geometry, never a tint: the cap travels down into its seat,
/// its shading inverts, and its contact shadow disappears because it is no longer standing off
/// the panel.
///
/// A thin wrapper around a real `Button`, which buys — for free and correctly — the traits
/// VoiceOver expects, Space/Return activation, Full Keyboard Access focus, and press-drag-out
/// cancellation. `configuration.isPressed` already goes false when the pointer leaves the cap
/// while held, which a hand-rolled `DragGesture` gets wrong on the first try.
///
/// With the `@ViewBuilder` initialiser the caller **must** supply `.accessibilityLabel` — a
/// glyph has no accessible name of its own and the component cannot invent one.
public struct TapeButton<Label: View>: View {

    /// `Role` and `Size` live on `TapeButtonStyle`, not here, so a control that cannot be a
    /// `Button` can name them without spelling a generic parameter it does not have.
    public typealias Role = TapeButtonStyle.Role
    public typealias Size = TapeButtonStyle.Size

    private let role: Role
    private let size: Size
    private let isLatched: Bool
    private let minWidth: CGFloat?
    private let action: () -> Void
    private let label: Label

    public init(
        role: Role = .neutral,
        size: Size = .standard,
        isLatched: Bool = false,
        minWidth: CGFloat? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.role = role
        self.size = size
        self.isLatched = isLatched
        self.minWidth = minWidth
        self.action = action
        self.label = label()
    }

    public var body: some View {
        Button(action: action) { label }
            .buttonStyle(TapeButtonStyle(role: role, size: size, isLatched: isLatched, minWidth: minWidth))
            // The seat carries the focus ring; the system's own ring would draw a blue rounded
            // rect straight across the machined edge.
            .focusEffectDisabled()
    }
}

public extension TapeButton where Label == Text {
    /// Convenience for the overwhelmingly common case: a moulded legend.
    /// Pass the legend in natural case — `D.type.buttonCap` uppercases it (spec §0.2), which is
    /// also what keeps the accessible name from being spelled out letter by letter.
    init(
        _ title: String,
        role: Role = .neutral,
        size: Size = .standard,
        isLatched: Bool = false,
        minWidth: CGFloat? = nil,
        action: @escaping () -> Void
    ) {
        self.init(
            role: role,
            size: size,
            isLatched: isLatched,
            minWidth: minWidth,
            action: action,
            label: { Text(title) }
        )
    }
}

/// The cap treatment on its own, exposed so a control that cannot be a `Button` — a segmented
/// selector in the left rail, say — can still be the same physical object.
public struct TapeButtonStyle: ButtonStyle {

    /// What the key is for. Role decides the latching contract, the default width, and the
    /// accessibility traits — never the colour.
    public enum Role: Sendable, Hashable {
        /// Starts an utterance. Latches: stays down for as long as `isLatched` is true.
        case record
        /// Ends an utterance. Momentary.
        case stop
        /// Everything else. Momentary.
        case neutral
    }

    public enum Size: Sendable, Hashable {
        /// `D.size.buttonHeight` tall, `M.transportMinWidth` wide by default.
        case standard
        /// A `D.size.iconButton` square, for a glyph.
        case icon
    }

    private let role: Role
    private let size: Size
    private let isLatched: Bool
    private let minWidth: CGFloat?

    public init(role: Role = .neutral, size: Size = .standard, isLatched: Bool = false) {
        self.init(role: role, size: size, isLatched: isLatched, minWidth: nil)
    }

    /// `minWidth` is a `TapeButton` parameter rather than part of the style's public surface,
    /// so it travels through this internal initialiser.
    init(role: Role, size: Size, isLatched: Bool, minWidth: CGFloat?) {
        self.role = role
        self.size = size
        self.isLatched = isLatched
        self.minWidth = minWidth
    }

    public func makeBody(configuration: Configuration) -> some View {
        TapeCap(
            configuration: configuration,
            role: role,
            size: size,
            isLatched: isLatched,
            minWidth: minWidth
        )
    }
}

/// The cap itself. A separate `View` because a `ButtonStyle.makeBody` cannot read the
/// environment, and the cap needs `isEnabled`, focus and Reduce Motion.
private struct TapeCap: View {
    let configuration: ButtonStyleConfiguration
    let role: TapeButtonStyle.Role
    let size: TapeButtonStyle.Size
    let isLatched: Bool
    let minWidth: CGFloat?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.edictIncreasedContrast) private var increasedContrast
    @State private var isHovering = false

    /// The union of two independent facts: a finger is on the key, or state holds it down.
    /// A latched key and a held key are the *same* physical position, and a latched key that is
    /// then pressed does not travel further — the press is absorbed.
    private var isDown: Bool { configuration.isPressed || isLatched }

    var body: some View {
        let seatShape = RoundedRectangle(
            cornerRadius: D.radius.control + M.capSeatOutset,
            style: .continuous
        )

        cap
            // Outside `pressedCap`, so the whole cap — fill, edge and contact shadow — rises out
            // of its seat rather than only the legend moving. Dropped under Reduce Motion: the
            // press travel stays (1pt in 55 ms is the entire affordance and is not vestibular
            // motion), but nothing moves that the user did not cause.
            .offset(y: liftsOnHover ? -M.hoverLift : 0)
            .animation(D.motion.release, value: isHovering)
            // The seat: the hole the key travels in, one point wider than the cap on every side.
            .padding(M.capSeatOutset)
            .background(seatShape.fill(D.color.wellFill))
            .innerShadow(seatShape, fittedRim(D.shadow.wellInner, height: capHeight + M.capSeatOutset * 2))
            .focusRing(isFocused, radius: D.radius.control + M.capSeatOutset)
            // A disabled key still looks like a key, just unlit — geometry is unchanged.
            .opacity(isEnabled ? 1 : D.opacity.disabled)
            .onHover { isHovering = $0 }
            .accessibilityAddTraits(isSelectedKey ? .isSelected : [])
    }

    private var cap: some View {
        configuration.label
            .typeStyle(D.type.buttonCap)
            // The cap is matte black plastic in *both* appearances (`D.surface.buttonCap` is
            // built from `panelPlastic`/`wellFill`), so the legend is `displayInk`:
            // `textPrimary` is near-black in the light appearance and would vanish.
            .foregroundStyle(D.color.displayInk)
            .shadow(increasedContrast ? D.Shadow(color: .clear, radius: 0) : D.shadow.engraved)
            // The legend never wraps and never scales. If the container cannot afford the key,
            // the container is wrong: a squeezed transport key is worse than a clipped panel.
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .dynamicTypeSize(.large)
            .padding(.horizontal, size == .standard ? D.space.md : D.space.xxs)
            .padding(.vertical, size == .standard ? 0 : D.space.xxs)
            .frame(minWidth: capMinWidth, minHeight: capHeight)
            .frame(height: capHeight)
            .pressedCap(isDown, radius: D.radius.control)
    }

    private var capHeight: CGFloat {
        size == .standard ? D.size.buttonHeight : D.size.iconButton
    }

    private var capMinWidth: CGFloat {
        switch size {
        case .standard: minWidth ?? M.transportMinWidth
        case .icon: D.size.iconButton
        }
    }

    private var liftsOnHover: Bool {
        isHovering && !isDown && isEnabled && !reduceMotion
    }

    /// A latched RECORD key reads as "Record, selected", which is how a latched key should read.
    /// STOP adds nothing: it is momentary, and a momentary key is never selected.
    private var isSelectedKey: Bool { role == .record && isLatched }
}

// MARK: - RecordLamp

/// The record lamp — the one red thing in Edict. A domed lens in a machined ring, sunk into
/// the panel.
///
/// Exactly one of these exists in the main window; the HUD and the menu-bar popover each own one
/// more, and that is the whole census. If a fourth appears, the app has two things claiming to be
/// the recording indicator.
///
/// It avoids reading as a *glow* geometrically rather than by tuning opacity: the halo is clipped
/// to the socket so no light spills onto the aluminium, there is no `.shadow` and no `.blur`
/// anywhere on the lamp in any mode, the bezel is drawn last so the brightest pixels are always
/// bounded by a hard machined edge, and "brighter" means the dome catches more light rather than
/// the element getting bigger or blurrier.
public struct RecordLamp: View {

    /// Named `Mode` and not `State` so it does not read as `@State` at every call site.
    public enum Mode: Sendable, Hashable {
        /// Not recording. The lens is a dead red-brown, not a grey hole.
        case off
        /// Armed: hotkey held past the 120 ms threshold, or the model still downloading.
        /// A slow breath, never a blink.
        case armed
        /// Capturing. Steady, full brightness.
        case recording
        /// Something failed. Three deliberate pulses, then off.
        case fault
    }

    public enum Fitting: Sendable, Hashable {
        /// `D.size.lampDiameter` (13). The deck.
        case standard
        /// `D.size.lampDiameter * 0.62` (≈8). The HUD and the menu-bar popover.
        case compact
    }

    private let mode: Mode
    private let fitting: Fitting

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.edictIncreasedContrast) private var increasedContrast
    @Environment(\.controlActiveState) private var controlActiveState

    /// Drives the `armed` breath and the `fault` pulse. Plain `@State`, because the animation is
    /// SwiftUI's to run — there is no per-frame work here.
    @State private var breathPhase = false
    /// `fault` settles to off once its six half-cycles are done: attention that does not end is
    /// noise.
    @State private var faultSettled = false

    public init(_ mode: Mode, fitting: Fitting = .standard) {
        self.mode = mode
        self.fitting = fitting
    }

    public var body: some View {
        let socket = D.size.lampDiameter + D.border.bezel * 2

        ZStack {
            // 0 — the hole in the panel.
            Circle()
                .fill(D.color.wellFill)
                .innerShadow(Circle(), D.shadow.wellInner)

            // 1 — the halo, a *painted* radial gradient inside the hole. Clipped to the socket:
            // a real 3mm LED in a chromed bezel does not illuminate the panel around it, and a
            // soft red bloom on brushed metal is the clearest possible signal that a UI is a
            // theme rather than an object. Dropped under Increase Contrast, where it is the only
            // low-contrast element.
            if isLit && !increasedContrast {
                Circle()
                    .fill(
                        RadialGradient(
                            stops: [
                                .init(color: D.color.recordLampHalo.opacity(D.opacity.halo), location: 0),
                                .init(color: .clear, location: 1),
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: D.size.lampDiameter * M.haloScale / 2
                        )
                    )
                    .frame(width: D.size.lampDiameter * M.haloScale,
                           height: D.size.lampDiameter * M.haloScale)
                    .clipShape(Circle().inset(by: -D.border.bezel))
            }

            // 2 — the lens. Compact draws the standard fill and scales it, because
            // `D.surface.lampLens` bakes in `endRadius: D.size.lampDiameter * 0.75` and a lens
            // drawn at an arbitrary diameter gets the wrong gradient falloff.
            Circle()
                .fill(D.surface.lampLens(lit: isLit))
                .frame(width: D.size.lampDiameter, height: D.size.lampDiameter)
                // 3 — rim shade, so the lens has a dark edge even when lit.
                .overlay(
                    Circle().strokeBorder(
                        D.color.shadowInner,
                        lineWidth: increasedContrast ? D.border.thin : D.border.hairline
                    )
                )
                .scaleEffect(fitting == .compact ? M.compactLampScale : 1)
        }
        .frame(width: socket, height: socket)
        .opacity(lampOpacity)
        // 4 — the bezel, drawn last and stroked at its true size so the hairlines stay hairlines.
        .bezelRingCircular(width: D.border.bezel)
        .scaleEffect(fitting == .compact ? scaleForCompactSocket : 1)
        .frame(width: intrinsicSize, height: intrinsicSize)
        .animation(modeAnimation, value: animationKey)
        .onAppear { restart() }
        .onChange(of: mode) { _, _ in restart() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recorder")
        .accessibilityValue(spokenValue)
        // Only `armed` is a repeating animation with no value change behind it.
        .accessibilityAddTraits(mode == .armed ? .updatesFrequently : [])
    }

    // MARK: Geometry

    /// The socket is stroked at full size and then scaled as a whole for `.compact`, so the
    /// bezel's proportions are preserved. 17pt standard, 12pt compact.
    private var intrinsicSize: CGFloat {
        let socket = D.size.lampDiameter + D.border.bezel * 2
        return fitting == .compact ? (D.size.lampDiameter * M.compactLampScale + D.border.bezel * 2) : socket
    }

    private var scaleForCompactSocket: CGFloat {
        let socket = D.size.lampDiameter + D.border.bezel * 2
        return intrinsicSize / socket
    }

    // MARK: State

    private var isLit: Bool {
        switch mode {
        case .off: false
        case .armed, .recording: true
        case .fault: !faultSettled
        }
    }

    /// Brightness is carried by opacity on the whole lamp; the lens never changes size and the
    /// socket never moves.
    private var lampOpacity: Double {
        let base: Double = switch mode {
        case .off: 1
        case .recording: 1
        case .armed: reduceMotion ? M.breatheHigh : (breathPhase ? M.breatheHigh : M.breatheLow)
        case .fault:
            if faultSettled { 1 } else if reduceMotion { 1 } else { breathPhase ? M.breatheLow : 1 }
        }
        // When the window is not frontmost, lamps and readouts drop to `ghost`; geometry never
        // changes (spec §0.3).
        return controlActiveState == .inactive ? base * D.opacity.ghost : base
    }

    /// The 3.4× asymmetry between `lampOn` and `lampOff` is why this reads as a filament: it
    /// reaches brightness fast and cools slowly.
    private var modeAnimation: Animation? {
        if reduceMotion { return nil }
        switch mode {
        case .armed: return D.motion.lampBreathe
        case .fault: return faultSettled ? D.motion.lampOff : D.motion.lampAlarm
        case .recording: return D.motion.lampOn
        case .off: return D.motion.lampOff
        }
    }

    /// One value for `.animation(_:value:)` to watch, so a mode change and a phase change both
    /// drive the same transition.
    private var animationKey: some Equatable { AnimationKey(mode: mode, phase: breathPhase, settled: faultSettled) }

    private struct AnimationKey: Equatable {
        let mode: Mode
        let phase: Bool
        let settled: Bool
    }

    /// Arming *breathes* and never blinks — a hard blink in an always-visible window is an alarm,
    /// and arming is not an alarm. `fault` is the only thing allowed to blink, three times.
    private func restart() {
        breathPhase = false
        faultSettled = false
        guard !reduceMotion else {
            // Steady substitutes: `armed` sits at the top of its breath, `fault` holds lit for
            // the alarm's duration and then goes out. No repeating animation ever runs.
            if mode == .fault { settleFaultAfterHold() }
            return
        }
        switch mode {
        case .armed, .fault:
            breathPhase = true
            if mode == .fault { settleFaultAfterHold() }
        case .off, .recording:
            break
        }
    }

    private func settleFaultAfterHold() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(M.faultHold))
            guard mode == .fault else { return }
            faultSettled = true
        }
    }

    /// The lamp is never the *only* indication of a state — `StatusReadout` always carries the
    /// same information in words, which is what makes a colour-only signal safe.
    private var spokenValue: String {
        switch mode {
        case .off: "Off"
        case .armed: "Armed"
        case .recording: "Recording"
        case .fault: "Fault"
        }
    }
}

// MARK: - SegmentCounter

/// A counter in segmented numerals, seated in a lit display window. Elapsed time, durations,
/// word counts and the dB readout.
///
/// `SegmentCounter` **never owns a timer**. `elapsed` is pushed in from the app model. A
/// component that runs its own clock will drift out of step with the recorder it claims to be
/// measuring.
public struct SegmentCounter: View {

    public enum Format: Sendable, Hashable {
        /// `MM:SS.T` — the running elapsed counter on the transport deck.
        case elapsed(TimeInterval)
        /// `MM:SS` — a finished duration, e.g. a history row.
        case duration(TimeInterval)
        /// An integer with a silkscreened unit suffix, e.g. `128 W`.
        case count(Int, unit: String)
        /// `-00.0` — the dBFS readout beside the meter.
        case decibels(Double)
    }

    public enum Scale: Sendable, Hashable {
        /// `D.type.counter` (26pt mono). One per window: the transport deck.
        case large
        /// `D.type.counterSmall` (12pt mono). Table rows, latency readouts.
        case small
        /// `D.type.numeralTiny` (9pt mono). Beside the meter, inside the HUD.
        case tiny
    }

    private let format: Format
    private let scale: Scale
    private let seated: Bool
    private let inkOverride: Color?

    @Environment(\.edictInkOnDark) private var inkOnDark
    @Environment(\.edictIncreasedContrast) private var increasedContrast

    /// - Parameters:
    ///   - seated: wraps the digits in a `RecessedWell(fill: .display)`, which is how the deck's
    ///     counter is drawn. `false` for a counter inside an existing well, e.g. a row.
    ///   - ink: overrides the resolved ink. The counter fixes its own colour so it can never end
    ///     up dark-on-dark, which also means an outer `.foregroundStyle` cannot reach it — so the
    ///     two places the spec colours a counter by *state* rather than by container need this:
    ///     a zero hit count in `D.color.alert` (§10) and a counter on a selected row in
    ///     `D.color.selectionText` (§9.2).
    public init(_ format: Format, scale: Scale = .small, seated: Bool = true, ink: Color? = nil) {
        self.format = format
        self.scale = scale
        self.seated = seated
        self.inkOverride = ink
    }

    public var body: some View {
        Group {
            if seated {
                RecessedWell(fill: .display, radius: D.radius.well, inset: D.space.xs) {
                    digits
                }
            } else {
                digits
            }
        }
        .fixedSize()
        // A number that eases into another number is a spreadsheet, not a counter. The tokens
        // file is explicit that `D.motion.readout` is a *surrounding* fade only.
        .animation(nil, value: format)
        .accessibilityElement(children: .ignore)
        .accessibilityValue(spokenValue)
        .accessibilityAddTraits(isElapsed ? .updatesFrequently : [])
    }

    // MARK: Digits

    @ViewBuilder
    private var digits: some View {
        switch format {
        // `.elapsed` and `.duration` are zero-padded fixed forms, so the *string* length is
        // constant for the whole useful range: no re-layout at 1:40 and none at 10:00.
        // `.monospacedDigit()` alone is not enough — the colon and the period are not digits and
        // are not guaranteed the same advance width.
        case .elapsed(let t):
            numerals(Self.elapsedString(t))
        case .duration(let t):
            numerals(Self.durationString(t))
        case .count(let n, let unit):
            // A reserved field plus right alignment: the last digit never moves, which is the
            // axis the eye actually tracks.
            HStack(alignment: .firstTextBaseline, spacing: D.space.xxs) {
                reserved("\(n)", template: "0000")
                unitSuffix(unit)
            }
        case .decibels(let d):
            reserved(Self.decibelString(d), template: "-00.0")
        }
    }

    private func numerals(_ string: String) -> some View {
        Text(string)
            .typeStyle(typeStyle)
            .foregroundStyle(ink)
            .contentTransition(.identity)
            .dynamicTypeSize(.large)
    }

    private func reserved(_ string: String, template: String) -> some View {
        ZStack(alignment: .trailing) {
            numerals(template)
                .hidden()
                .accessibilityHidden(true)
            numerals(string)
        }
    }

    /// Drawn inline rather than as a `SilkscreenLabel`, because a unit inside a display window is
    /// display ink, not silkscreen ink — a panel-coloured suffix on a dark counter disappears.
    private func unitSuffix(_ unit: String) -> some View {
        Text(unit)
            .typeStyle(D.type.silkscreenTiny)
            .foregroundStyle(ink)
            .opacity(increasedContrast ? 1 : D.opacity.ghost)
            .dynamicTypeSize(.large)
    }

    /// Seated digits are always `displayInk`: the window is near-black in both appearances.
    /// Unseated, the ink comes from the surrounding surface, which removes the single most common
    /// bug in a palette like this — dark ink on a dark well.
    private var ink: Color {
        if let inkOverride { return inkOverride }
        return seated ? D.color.displayInk : (inkOnDark ? D.color.displayInk : D.color.textPrimary)
    }

    private var typeStyle: D.TypeStyle {
        switch scale {
        case .large: D.type.counter
        case .small: D.type.counterSmall
        case .tiny: D.type.numeralTiny
        }
    }

    private var isElapsed: Bool {
        if case .elapsed = format { return true }
        return false
    }

    // MARK: Formatting
    //
    // `String(format:)` throughout, which is locale-independent. Never
    // `DateComponentsFormatter` or `Text(_:format:)`: this machine's locale is `en_ID`, and a
    // locale that substitutes its own digit shapes would silently destroy both the monospacing
    // and the look.

    static func elapsedString(_ t: TimeInterval) -> String {
        let clamped = max(0, t)
        let total = Int(clamped)
        // Tenths are truncated, not rounded, so the counter never shows a time that has not
        // happened yet.
        return String(format: "%02d:%02d.%d", total / 60, total % 60, Int((clamped - Double(total)) * 10))
    }

    static func durationString(_ t: TimeInterval) -> String {
        let total = Int(max(0, t))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    static func decibelString(_ d: Double) -> String {
        String(format: "%.1f", d)
    }

    /// Spoken, not printed: `"00:04.2"` read aloud is gibberish.
    private var spokenValue: String {
        switch format {
        case .elapsed(let t), .duration(let t):
            String(format: "%.1f seconds", max(0, t))
        case .count(let n, let unit):
            "\(n) \(Self.spokenUnit(unit, count: n))"
        case .decibels(let d):
            d < 0
                ? String(format: "minus %.0f decibels", -d)
                : String(format: "%.0f decibels", d)
        }
    }

    /// The printed suffix is a panel abbreviation; the spoken one has to be a word.
    private static func spokenUnit(_ unit: String, count: Int) -> String {
        switch unit.lowercased() {
        case "w": count == 1 ? "word" : "words"
        case "hit": count == 1 ? "match" : "matches"
        default: unit
        }
    }
}

// MARK: - RockerSwitch

/// A rocker toggle. Implemented as a `ToggleStyle` so it inherits the whole of `Toggle`'s
/// behaviour — the `.isToggle` trait, "on"/"off" as an accessibility value, Space to flip, label
/// association, Full Keyboard Access focus — rather than re-deriving any of it.
///
/// **Off** = leading half down. **On** = trailing half down, so the `I` is pressed in. There is
/// no colour change in either direction and no track fill: the state is which end is down,
/// exactly as on the hardware. Resisting the urge to tint the "on" state green is what keeps
/// this from being a system `Switch` in costume.
public struct RockerSwitchStyle: ToggleStyle {

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        // A real `Button` inside the style, for the same reason `TapeButton` is one: keyboard
        // activation, focus and press-drag-out cancellation all come free and correct.
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(RockerPlateStyle(isOn: configuration.isOn))
        .focusEffectDisabled()
    }
}

/// Lays out the plate and the label block, and does the rocking.
private struct RockerPlateStyle: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        RockerPlate(isOn: isOn, isPressed: configuration.isPressed, label: configuration.label)
    }
}

private struct RockerPlate: View {
    let isOn: Bool
    let isPressed: Bool
    let label: ButtonStyleConfiguration.Label

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.edictIncreasedContrast) private var increasedContrast
    @State private var isHovering = false

    /// While held, the plate flips immediately — before the value does — so the control tracks
    /// the finger. The user always presses the half that is standing up.
    private var showsOn: Bool { isPressed ? !isOn : isOn }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: D.space.sm) {
            plate
            // The whole row is the hit target, because `Toggle`'s label is part of the control.
            label
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: M.rockerRowMin, alignment: .leading)
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : D.opacity.disabled)
        .onHover { isHovering = $0 }
        // No rotation is drawn: a 3D tilt at 18pt tall is a blur, and two offsets read as a tilt.
        .animation(reduceMotion ? nil : (isPressed ? D.motion.press : D.motion.release), value: showsOn)
        .animation(reduceMotion ? nil : D.motion.release, value: isHovering)
    }

    private var plate: some View {
        let seatShape = RoundedRectangle(
            cornerRadius: D.radius.control + M.capSeatOutset,
            style: .continuous
        )

        return HStack(spacing: 0) {
            half(legend: "O", isDown: !showsOn, leading: true)
            half(legend: "I", isDown: showsOn, leading: false)
        }
        .frame(width: M.rockerWidth, height: M.rockerHeight)
        // The line the plate rocks about, and the reason the control reads as one plate rather
        // than two buttons.
        .overlay(SeamDivider(.vertical).frame(height: M.rockerHeight))
        .padding(M.capSeatOutset)
        .background(seatShape.fill(D.color.wellFill))
        .innerShadow(seatShape, fittedRim(D.shadow.wellInner, height: M.rockerHeight + M.capSeatOutset * 2))
        .focusRing(isFocused, radius: D.radius.control + M.capSeatOutset)
        // Baseline-align the plate to the label so a row of switches lines up on its text.
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - D.space.xxs }
    }

    private func half(legend: String, isDown: Bool, leading: Bool) -> some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: leading ? D.radius.control : 0,
            bottomLeadingRadius: leading ? D.radius.control : 0,
            bottomTrailingRadius: leading ? 0 : D.radius.control,
            topTrailingRadius: leading ? 0 : D.radius.control,
            style: .continuous
        )

        return Text(legend)
            .typeStyle(D.type.silkscreenTiny)
            .foregroundStyle(D.color.displayInk)
            .shadow(increasedContrast ? D.Shadow(color: .clear, radius: 0) : D.shadow.engraved)
            // The legend on the *down* half is in shadow.
            .opacity(isDown && !increasedContrast ? D.opacity.ghost : 1)
            .dynamicTypeSize(.large)
            .frame(width: M.rockerWidth / 2, height: M.rockerHeight)
            .background(shape.fill(D.surface.buttonCap(pressed: isDown)))
            // Not `fittedRim`: a half is a cap, not a well, and at 18pt the light-versus-dark
            // inner rim is the *only* thing that separates up from down — `D.surface.buttonCap`'s
            // two gradients are nearly indistinguishable against the dark seat.
            .innerShadow(shape, isDown ? D.shadow.pressedInner : D.shadow.capInnerLight)
            .clipShape(shape)
            .shadow(isDown ? D.Shadow(color: .clear, radius: 0) : D.shadow.cap)
            .offset(y: isDown ? 1 : (liftsOnHover ? -M.hoverLift : 0))
    }

    private var liftsOnHover: Bool { isHovering && isEnabled && !reduceMotion }
}

/// Convenience wrapper: a `Toggle` in `RockerSwitchStyle`, plus the explanatory caption that most
/// settings need.
public struct RockerSwitch: View {
    private let label: String
    private let caption: String?
    @Binding private var isOn: Bool

    /// - Parameters:
    ///   - label: natural case; `D.type.silkscreen` uppercases it.
    ///   - caption: one plain sentence in `D.type.explain`, or nil.
    public init(_ label: String, isOn: Binding<Bool>, caption: String? = nil) {
        self.label = label
        self._isOn = isOn
        self.caption = caption
    }

    public var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: D.space.xxs) {
                SilkscreenLabel(label)
                if let caption {
                    Text(caption)
                        .typeStyle(D.type.explain)
                        .foregroundStyle(D.color.textSecondary)
                        // Truncates to two lines and then drops; the plate never moves.
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        // Available on demand as a hint rather than read twice as content.
                        .accessibilityHidden(true)
                }
            }
        }
        .toggleStyle(RockerSwitchStyle())
        .modifier(OptionalAccessibilityHint(hint: caption))
    }
}

/// Applies an accessibility hint only when there is one to apply.
private struct OptionalAccessibilityHint: ViewModifier {
    let hint: String?

    func body(content: Content) -> some View {
        if let hint {
            content.accessibilityHint(hint)
        } else {
            content
        }
    }
}

// MARK: - TranscriptRow

/// One row of the history table — the densest component in the app and the one the user reads
/// most, so its rules are the strictest.
///
/// The row lives inside `RecessedWell(fill: .list)`, whose fill is `D.color.panelRecessed`
/// (appearance-tracking), which is what makes `textPrimary`/`textSecondary` the correct inks. If
/// the list were built on `D.surface.wellFill` (near-black in *both* appearances) the transcript
/// text would be near-black on near-black in the light appearance. That is the single most likely
/// bug in the history pane, so it is asserted rather than merely documented.
///
/// **No row separators and no banding.** A 26pt row with a fixed-pitch time column already reads
/// as a printed log; a hairline under every row at this density turns the table into graph paper,
/// and zebra striping is a web table idiom. The well's own edge frames the list, and selection is
/// the only fill. This is a deliberate decision, not an omission.
public struct TranscriptRow: View {

    private let transcript: Transcript
    private let isSelected: Bool
    private let onCopy: () -> Void

    @Environment(\.edictInkOnDark) private var inkOnDark
    @Environment(\.edictIncreasedContrast) private var increasedContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var measuredWidth: CGFloat = .greatestFiniteMagnitude

    /// - Parameters:
    ///   - transcript: the record. `corrections`, `injection` and `droppedBuffers` all drive the
    ///     flag column.
    ///   - isSelected: driven by the pane's selection, never by a tap the row handled itself.
    ///   - onCopy: copies `transcript.text`. The row does not touch `NSPasteboard`.
    public init(_ transcript: Transcript, isSelected: Bool, onCopy: @escaping () -> Void) {
        self.transcript = transcript
        self.isSelected = isSelected
        self.onCopy = onCopy
    }

    public var body: some View {
        HStack(spacing: D.space.sm) {
            if showsTime {
                Text(RowClock.hhmm(transcript.createdAt))
                    .typeStyle(D.type.counterSmall)
                    .foregroundStyle(secondaryInk)
                    .frame(width: M.colTime, alignment: .leading)
            }
            if showsDuration {
                SegmentCounter(.duration(transcript.audioDuration), scale: .small, seated: false, ink: secondaryInk)
                    .frame(width: M.colDuration, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            if showsWords {
                SegmentCounter(.count(transcript.wordCount, unit: "w"), scale: .tiny, seated: false, ink: secondaryInk)
                    .frame(width: M.colWords, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            flag
                .frame(width: M.colFlag)
            Text(transcript.text)
                .typeStyle(D.type.body)
                .foregroundStyle(primaryInk)
                // No fade mask (a gradient mask makes the last legible word ambiguous), no
                // `.minimumScaleFactor` (shrinking body text breaks the row's optical rhythm),
                // no wrapping (a variable-height row destroys the printed-log read). The full
                // text is reachable three ways: this tooltip, the copy key, and selecting the row.
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: M.colTextMin, maxWidth: .infinity, alignment: .leading)
                .help(transcript.text)
            copyKey
        }
        .padding(.horizontal, D.space.rowInset)
        // Exactly `D.size.rowHeight` in every state — collapsed *and* selected.
        .frame(height: D.size.rowHeight)
        .background(rowFill)
        .overlay(selectionRules)
        .onHover { isHovering = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(transcript.text)
        .accessibilityValue(spokenValue)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .onAppear {
            assert(
                !inkOnDark,
                "TranscriptRow must sit in RecessedWell(fill: .list); a .display well would put "
                    + "near-black text on a near-black ground in the light appearance."
            )
        }
    }

    // MARK: Fills

    /// A **full-width band with square ends**, never an inset rounded pill — a pill is a list-row
    /// idiom from the web; a band across the whole tray is a backlit line on a tape counter.
    @ViewBuilder
    private var rowFill: some View {
        ZStack {
            if isSelected {
                D.color.selectionFill
            }
            if isHovering {
                // A lift, not a tint: ≈15% white in the light appearance, ≈4% in dark.
                D.color.highlightInner
                    .opacity(increasedContrast ? D.opacity.halo * 2 : D.opacity.halo)
            }
        }
    }

    @ViewBuilder
    private var selectionRules: some View {
        if isSelected {
            let width = increasedContrast ? D.border.thin : D.border.hairline
            VStack(spacing: 0) {
                D.color.selectionStroke.frame(height: width)
                Spacer(minLength: 0)
                D.color.selectionStroke.frame(height: width)
            }
            .allowsHitTesting(false)
        }
    }

    private var primaryInk: Color {
        isSelected ? D.color.selectionText : (inkOnDark ? D.color.displayInk : D.color.textPrimary)
    }

    private var secondaryInk: Color {
        if isSelected {
            return D.color.selectionText.opacity(increasedContrast ? 1 : D.opacity.ghost)
        }
        return inkOnDark ? D.color.displayInk : D.color.textSecondary
    }

    // MARK: Copy key

    /// Present but invisible on non-hovered rows: it occupies its column always, so nothing in
    /// the row shifts when the pointer arrives.
    private var copyKey: some View {
        TapeButton(role: .neutral, size: .icon, action: onCopy) {
            Image(systemName: "square.on.square")
                .font(.system(size: M.iconGlyphSize, weight: .semibold))
        }
        .accessibilityLabel("Copy transcript")
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
        .animation(reduceMotion ? nil : D.motion.readout, value: isHovering)
    }

    // MARK: Flag column

    /// At most one glyph, chosen by priority, because a row with three markers communicates
    /// nothing. Shape — not just colour — distinguishes all three.
    @ViewBuilder
    private var flag: some View {
        switch flagKind {
        case .notInserted:
            Rectangle()
                .fill(D.color.alert)
                .frame(width: M.flagSize, height: M.flagSize)
                .help(Self.flagPhrase(.notInserted, corrections: 0))
        case .incomplete:
            Rectangle()
                .strokeBorder(D.color.alert, lineWidth: increasedContrast ? D.border.thin : D.border.hairline)
                .frame(width: M.flagSize, height: M.flagSize)
                .help(Self.flagPhrase(.incomplete, corrections: 0))
        case .corrected:
            // Amber-ink family, deliberately *not* `D.color.alert`: the dictionary firing is the
            // feature working, not a warning — and deliberately not red.
            Rectangle()
                .fill(D.color.selectionStroke)
                .frame(width: M.flagSize, height: M.flagSize)
                .rotationEffect(.degrees(45))
                .help(Self.flagPhrase(.corrected, corrections: transcript.corrections.count))
        case .none:
            Color.clear.frame(width: M.flagSize, height: M.flagSize)
        }
    }

    private enum FlagKind { case notInserted, incomplete, corrected, none }

    private var flagKind: FlagKind {
        if transcript.injection == .failed || transcript.injection == .clipboardOnly { return .notInserted }
        if transcript.droppedBuffers > 0 { return .incomplete }
        if !transcript.corrections.isEmpty { return .corrected }
        return .none
    }

    private static func flagPhrase(_ kind: FlagKind, corrections: Int) -> String {
        switch kind {
        case .notInserted: "not inserted"
        case .incomplete: "may be incomplete"
        case .corrected: corrections == 1 ? "1 dictionary correction" : "\(corrections) dictionary corrections"
        case .none: ""
        }
    }

    // MARK: Cramping

    // Widths are fixed, not proportional, so every row in the table is in the same place — the
    // columns are what makes it a log, and a percentage column ruins that at the first long
    // transcript. One step at a time as the pane narrows.
    private var showsWords: Bool { measuredWidth >= M.rowWide }
    private var showsDuration: Bool { measuredWidth >= M.rowMedium }
    private var showsTime: Bool { measuredWidth >= M.rowNarrow }

    // MARK: Accessibility

    /// Spoken forms, not the printed ones.
    private var spokenValue: String {
        var parts = [RowClock.hhmm(transcript.createdAt)]
        parts.append(String(format: "%.1f seconds", max(0, transcript.audioDuration)))
        parts.append(transcript.wordCount == 1 ? "1 word" : "\(transcript.wordCount) words")
        let phrase = Self.flagPhrase(flagKind, corrections: transcript.corrections.count)
        if !phrase.isEmpty { parts.append(phrase) }
        return parts.joined(separator: ", ")
    }
}

/// 24-hour, POSIX, and built from date components rather than a `DateFormatter`.
///
/// 24-hour because a log is a log, and because `HH:mm` is fixed-width where `h:mm a` is not.
/// POSIX because this machine's locale is `en_ID` and a locale that substitutes its own digit
/// shapes would destroy the column's monospacing.
private enum RowClock {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    static func hhmm(_ date: Date) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

// MARK: - EquipmentSearchField

/// A search channel: a slot cut into the panel with a legend plate at one end and a match count
/// at the other.
///
/// Not a `TextField` in a rounded rect — the system field's focus ring, its bezel and its
/// magnifying glass all read as macOS chrome, which is the one thing this app must never look
/// like. `.focusEffectDisabled()` is mandatory rather than tasteful: without it the system draws
/// its blue ring *inside* the machined channel.
public struct EquipmentSearchField: View {

    private let legend: String
    @Binding private var text: String
    private let resultCount: Int?
    private let onSubmit: (() -> Void)?

    @Environment(\.edictIncreasedContrast) private var increasedContrast
    @FocusState private var isFocused: Bool

    /// - Parameters:
    ///   - legend: the plate at the leading edge. Natural case; uppercased by the type style.
    ///   - text: the live query. The field is fully controlled; it never debounces (the store does).
    ///   - resultCount: matches, printed at the trailing edge. Nil hides the readout entirely.
    public init(
        legend: String = "Find",
        text: Binding<String>,
        resultCount: Int? = nil,
        onSubmit: (() -> Void)? = nil
    ) {
        self.legend = legend
        self._text = text
        self.resultCount = resultCount
        self.onSubmit = onSubmit
    }

    public var body: some View {
        // `.list`, not `.display`: the user's query is content to be read, so it must be
        // `textPrimary` on `panelRecessed`.
        RecessedWell(fill: .list, radius: D.radius.well, inset: 0) {
            HStack(spacing: 0) {
                legendPlate
                field
                if let count = shownCount {
                    countReadout(count)
                        .padding(.trailing, D.space.wellInset)
                }
                clearKey
            }
        }
        .frame(minHeight: M.fieldHeight)
        .frame(minWidth: M.fieldMin)
        .focusRing(isFocused, radius: D.radius.well)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isSearchField)
        .accessibilityLabel(legend)
        .accessibilityValue(spokenValue)
    }

    /// A raised plate inside a recess: the label is printed on metal, and the seam separates it
    /// from the channel.
    private var legendPlate: some View {
        HStack(spacing: 0) {
            SilkscreenLabel(legend, weight: .tiny)
                .silkscreenDecorative()
                .padding(D.space.xxs)
                .background(
                    RoundedRectangle(cornerRadius: D.radius.tight, style: .continuous)
                        .fill(D.surface.raisedPanelFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: D.radius.tight, style: .continuous)
                        .strokeBorder(D.surface.raisedEdge, lineWidth: D.border.hairline)
                )
                .padding(D.space.wellInset / 2)
            SeamDivider(.vertical)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var field: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .focused($isFocused)
            .typeStyle(D.type.body)
            .foregroundStyle(D.color.textPrimary)
            .padding(.horizontal, D.space.sm)
            .onSubmit { onSubmit?() }
            // macOS-standard and free.
            .onExitCommand { if !text.isEmpty { text = "" } }
            .overlay(alignment: .leading) {
                // Not `TextField`'s prompt, which renders in the system's secondary colour.
                // Hidden when focused even if empty: the caret is the invitation.
                if text.isEmpty && !isFocused {
                    SilkscreenLabel("Search")
                        .foregroundStyle(D.color.textSecondary)
                        .opacity(increasedContrast ? 1 : D.opacity.ghost)
                        .padding(.horizontal, D.space.sm)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    /// The whole no-results treatment: no empty-state illustration, no message in the channel.
    private func countReadout(_ count: Int) -> some View {
        SegmentCounter(
            .count(count, unit: "hit"),
            scale: .tiny,
            seated: false,
            ink: count == 0 ? D.color.alert : D.color.textSecondary
        )
        .accessibilityHidden(true)
    }

    /// A text legend rather than an `xmark` glyph, because "CLR" is what the panel would actually
    /// say. Reserved column, so nothing shifts when it appears.
    private var clearKey: some View {
        TapeButton(role: .neutral, size: .icon) {
            text = ""
        } label: {
            Text("Clr")
                .typeStyle(D.type.silkscreenTiny)
        }
        .accessibilityLabel("Clear search")
        .opacity(text.isEmpty ? 0 : 1)
        .allowsHitTesting(!text.isEmpty)
        .padding(.trailing, D.space.xxs)
    }

    /// A count of everything is not information.
    private var shownCount: Int? {
        guard let resultCount, !text.isEmpty else { return nil }
        return resultCount
    }

    /// The count is announced as the field's value suffix rather than as a sibling label, so a
    /// screen-reader user gets the result of typing without hunting for it.
    private var spokenValue: String {
        guard let count = shownCount else { return text }
        return "\(text), \(count == 1 ? "1 match" : "\(count) matches")"
    }
}

// MARK: - StatusReadout

/// The small lit channel that says, in words, what the machine is doing.
///
/// Everything the record lamp indicates is also written here, which is what makes the lamp safe
/// as a colour-only signal for a colour-blind user.
///
/// `Condition` is declared *here*, in the design layer, and the shell maps `DictationPhase` +
/// `ModelState` onto it: the design layer must not import App types, and a component that
/// switched on `DictationPhase` would drag the whole app model into the previews.
public struct StatusReadout: View {

    public enum Condition: Sendable, Hashable {
        case ready
        case armed
        case listening
        case transcribing
        case injecting
        /// 0…1. Model download.
        case downloading(Double)
        /// Terminal, user-visible failure. The string is shown verbatim.
        case fault(String)
        /// A permission is missing; the string names it.
        case needsPermission(String)
    }

    private let condition: Condition
    private let compact: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.edictIncreasedContrast) private var increasedContrast
    @Environment(\.controlActiveState) private var controlActiveState

    /// - Parameter compact: drops to `D.type.silkscreenTiny`. For the HUD and the menu-bar popover.
    public init(_ condition: Condition, compact: Bool = false) {
        self.condition = condition
        self.compact = compact
    }

    public var body: some View {
        RecessedWell(fill: .display, radius: D.radius.tight, inset: D.space.xs) {
            HStack(spacing: D.space.xs) {
                if !compact {
                    tellTale
                }
                reservedText
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .bottomLeading) { progressRule }
        // `minHeight`, not `height`: the channel must never resize as the *condition* changes,
        // which the reserved text field guarantees — but clipping a 10pt silkscreen line inside a
        // hard 18pt channel is worse than being two points taller than nominal.
        .frame(minHeight: compact ? M.statusCompactHeight : M.statusHeight)
        .frame(minWidth: compact ? nil : M.statusMin, alignment: .leading)
        .opacity(controlActiveState == .inactive ? D.opacity.ghost : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status")
        .accessibilityValue(spokenText)
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear { announceIfNeeded() }
        .onChange(of: condition) { _, _ in announceIfNeeded() }
    }

    // MARK: Tell-tale

    /// A square, not a circle — the round lit thing in this app is the record lamp, and there is
    /// one of those. Shares the record lamp's filament asymmetry, and never breathes or blinks:
    /// `armed` is expressed by opacity, because a blinking word is unreadable.
    private var tellTale: some View {
        Rectangle()
            .fill(tellTaleColor)
            .frame(width: M.tellTaleSize, height: M.tellTaleSize)
            .opacity(tellTaleOpacity)
            .overlay {
                if increasedContrast && !isLitTellTale {
                    Rectangle().strokeBorder(D.color.displayInk, lineWidth: D.border.hairline)
                }
            }
            .animation(reduceMotion ? nil : (isLitTellTale ? D.motion.lampOn : D.motion.lampOff),
                       value: tellTaleOpacity)
    }

    private var isAlert: Bool {
        switch condition {
        case .fault, .needsPermission: true
        default: false
        }
    }

    private var isLitTellTale: Bool {
        switch condition {
        case .ready, .listening, .transcribing, .injecting, .downloading: true
        case .armed, .fault, .needsPermission: false
        }
    }

    private var tellTaleColor: Color { isAlert ? D.color.alert : D.color.displayInk }

    private var tellTaleOpacity: Double {
        if isAlert { return 1 }
        switch condition {
        case .armed: return increasedContrast ? 1 : D.opacity.ghost
        default: return 1
        }
    }

    // MARK: Text

    /// The channel never resizes as the condition changes: the width of the longest fixed
    /// string — `"Transcribing"` — is reserved with a hidden template. `fault` and
    /// `needsPermission` carry arbitrary text and truncate into that same reserved width.
    private var reservedText: some View {
        ZStack(alignment: .leading) {
            styled(Text(M.statusTemplate))
                .hidden()
                .accessibilityHidden(true)
            styled(Text(displayText))
                .foregroundStyle(isAlert ? D.color.alert : D.color.displayInk)
                // `.id` + `.transition(.opacity)` crossfades two whole words. A
                // `.contentTransition(.numericText)` character-level morph at 10pt condensed is
                // illegible mush.
                .id(condition)
                .transition(.opacity)
                .help(displayText)
        }
        .animation(reduceMotion ? nil : D.motion.readout, value: condition)
    }

    private func styled(_ text: Text) -> some View {
        text
            .typeStyle(compact ? D.type.silkscreenTiny : D.type.silkscreen)
            .lineLimit(1)
            .truncationMode(.tail)
            .dynamicTypeSize(.large)
    }

    /// A hairline creeping along the bottom of the channel, not a progress bar with a track: the
    /// channel *is* the track.
    @ViewBuilder
    private var progressRule: some View {
        if case .downloading(let fraction) = condition {
            GeometryReader { proxy in
                D.color.displayInk
                    .frame(width: proxy.size.width * min(max(fraction, 0), 1),
                           height: M.progressHeight)
                    .animation(reduceMotion ? nil : D.motion.panel, value: fraction)
            }
            .frame(height: M.progressHeight)
            .allowsHitTesting(false)
        }
    }

    // MARK: Strings

    /// Natural case; `D.type.silkscreen` does the shouting (spec §0.2).
    private var displayText: String {
        switch condition {
        case .ready: "Ready"
        case .armed: "Armed"
        case .listening: "Listening"
        case .transcribing: "Transcribing"
        case .injecting: "Inserting"
        case .downloading(let p): String(format: "Model %.0f%%", min(max(p, 0), 1) * 100)
        case .fault(let message): message
        case .needsPermission(let what): "\(what) required"
        }
    }

    /// Never the uppercased display string: a screen reader spells caps out letter by letter.
    private var spokenText: String {
        if case .downloading(let p) = condition {
            return String(format: "Model %.0f percent", min(max(p, 0), 1) * 100)
        }
        return displayText
    }

    /// A failure the user cannot see must still reach them.
    private func announceIfNeeded() {
        guard isAlert else { return }
        var message = AttributedString(spokenText)
        message.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(message).post()
    }
}

// MARK: - Previews
//
// Previews are the only verification this layer gets before the views agent starts, so a state
// that is not in a preview is a state that has not been checked. Every one renders on
// `D.surface.deckPaint`, because a component checked on white has not been checked.

#if DEBUG

/// A preview backdrop: the painted chassis, at the deck's own inset.
private struct Bench<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: D.space.lg) {
            content
        }
        .padding(D.space.xl)
        .background(D.surface.deckPaint)
    }
}

private enum PreviewData {
    static let now = Date(timeIntervalSince1970: 1_770_000_000)

    static var transcripts: [Transcript] {
        [
            Transcript(rawText: "Ship the deck first.", text: "Ship the deck first.",
                       audioDuration: 1.8, injection: .accessibility),
            Transcript(rawText: "Push the vercel deploy.", text: "Push the Vercel deploy.",
                       corrections: [CorrectionHit(entryID: UUID(), from: "vercel", to: "Vercel", offset: 9)],
                       audioDuration: 4.2, injection: .paste),
            Transcript(rawText: "Never inserted.", text: "Never inserted.",
                       audioDuration: 3.1, injection: .failed),
            Transcript(rawText: "Half of this was dropped.", text: "Half of this was dropped.",
                       audioDuration: 2.4, injection: .accessibility, droppedBuffers: 3),
        ].enumerated().map { index, transcript in
            var copy = transcript
            copy.createdAt = now.addingTimeInterval(Double(index) * 613)
            return copy
        }
    }
}

#Preview("TapeButton") {
    Bench {
        HStack(spacing: D.space.lg) {
            TapeButton("Record", role: .record) {}
            TapeButton("Record", role: .record, isLatched: true) {}
            TapeButton("Stop", role: .stop) {}
            TapeButton("Stop", role: .stop) {}.disabled(true)
        }
        TapeButton(role: .neutral, size: .icon, action: {}) {
            Image(systemName: "square.on.square").font(.system(size: M.iconGlyphSize, weight: .semibold))
        }
        .accessibilityLabel("Copy")
    }
}

#Preview("RecordLamp") {
    Bench {
        HStack(spacing: D.space.xl) {
            ForEach([RecordLamp.Mode.off, .armed, .recording, .fault], id: \.self) { mode in
                VStack(spacing: D.space.xs) {
                    RecordLamp(mode)
                    RecordLamp(mode, fitting: .compact)
                }
            }
        }
    }
}

#Preview("SilkscreenLabel") {
    Bench {
        SilkscreenLabel("Input", weight: .heading, ruled: true)
        SilkscreenLabel("Elapsed")
        SilkscreenLabel("dBFS", weight: .tiny)
        RecessedWell(fill: .display) { SilkscreenLabel("On dark") }
    }
}

#Preview("SegmentCounter") {
    Bench {
        SegmentCounter(.elapsed(64.28), scale: .large)
        HStack(spacing: D.space.md) {
            SegmentCounter(.duration(213))
            SegmentCounter(.count(128, unit: "w"), scale: .small)
            SegmentCounter(.decibels(-18.4), scale: .tiny)
        }
        RecessedWell(fill: .list) {
            SegmentCounter(.duration(4.2), scale: .small, seated: false)
        }
    }
}

#Preview("Containers") {
    Bench {
        HStack(spacing: D.space.md) {
            PanelSurface("Painted") { Text("A").typeStyle(D.type.body).frame(width: 60, height: 24) }
            PanelSurface("Brushed", material: .brushed) { SilkscreenLabel("Metal", weight: .tiny).frame(width: 60, height: 24) }
            PanelSurface("Plastic", material: .plastic) { SilkscreenLabel("Insert", weight: .tiny).frame(width: 60, height: 24) }
        }
        HStack(spacing: D.space.md) {
            RecessedWell(fill: .display) { SegmentCounter(.elapsed(4.2), scale: .small, seated: false) }
            RecessedWell(fill: .list) { Text("List").typeStyle(D.type.body).foregroundStyle(D.color.textPrimary) }
            RecessedWell(fill: .faceplate) { Text("Card").typeStyle(D.type.body).foregroundStyle(D.color.meterScale) }
        }
        SeamDivider(.horizontal)
        SeamDivider(.horizontal, depth: .channel)
    }
    .frame(width: 520)
}

#Preview("RockerSwitch") {
    @Previewable @State var on = true
    @Previewable @State var off = false
    return Bench {
        PanelSurface("Input") {
            VStack(alignment: .leading, spacing: D.space.md) {
                RockerSwitch("Pre-warm microphone", isOn: $on,
                             caption: "Keeps the input open so the first syllable is never lost.")
                RockerSwitch("Play a click on release", isOn: $off)
                RockerSwitch("Insert at cursor", isOn: $on).disabled(true)
            }
        }
    }
    .frame(width: 480)
}

#Preview("TranscriptRow") {
    Bench {
        RecessedWell(fill: .list, inset: 0) {
            VStack(spacing: 0) {
                ForEach(Array(PreviewData.transcripts.enumerated()), id: \.element.id) { pair in
                    TranscriptRow(pair.element, isSelected: pair.offset == 1) {}
                }
            }
        }
    }
    .frame(width: 680)
}

#Preview("EquipmentSearchField") {
    @Previewable @State var hit = "cloud"
    @Previewable @State var empty = ""
    @Previewable @State var miss = "zzz"
    return Bench {
        EquipmentSearchField(text: $hit, resultCount: 3)
        EquipmentSearchField(text: $empty, resultCount: 12)
        EquipmentSearchField(text: $miss, resultCount: 0)
        EquipmentSearchField(text: $hit, resultCount: 3).disabled(true)
    }
    .frame(width: 420)
}

#Preview("StatusReadout") {
    Bench {
        StatusReadout(.ready)
        StatusReadout(.armed)
        StatusReadout(.listening)
        StatusReadout(.transcribing)
        StatusReadout(.injecting)
        StatusReadout(.downloading(0.42))
        StatusReadout(.fault("Microphone busy"))
        StatusReadout(.needsPermission("Accessibility"))
        StatusReadout(.listening, compact: true)
    }
}

/// One of everything, which is the closest this layer gets to seeing the window.
struct ComponentGallery: View {
    @State private var query = "cloud"
    @State private var prewarm = true

    var body: some View {
        Bench {
            HStack(alignment: .top, spacing: D.space.xl) {
                VStack(alignment: .leading, spacing: D.space.lg) {
                    VUMeter(level: AudioFrame(rms: 0.2, peak: 0.3, dbfs: -16), isLive: true,
                            showsNumericReadout: true)
                    Waveform(level: AudioFrame(rms: 0.2, peak: 0.3, dbfs: -16), isLive: true)
                        .frame(width: 260)
                    PanelSurface(material: .plastic) {
                        VStack(alignment: .leading, spacing: D.space.sm) {
                            HStack(spacing: D.space.xxs) {
                                RecordLamp(.recording)
                                StatusReadout(.listening)
                            }
                            HStack(spacing: D.space.sm) {
                                TapeButton("Record", role: .record, isLatched: true) {}
                                TapeButton("Stop", role: .stop) {}
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: D.space.lg) {
                    SegmentCounter(.elapsed(64.28), scale: .large)
                    EquipmentSearchField(text: $query, resultCount: 3)
                    RecessedWell(fill: .list, inset: 0) {
                        VStack(spacing: 0) {
                            ForEach(Array(PreviewData.transcripts.prefix(3).enumerated()), id: \.element.id) { pair in
                                TranscriptRow(pair.element, isSelected: pair.offset == 1) {}
                            }
                        }
                    }
                    SeamDivider(.horizontal, depth: .channel)
                    RockerSwitch("Pre-warm microphone", isOn: $prewarm,
                                 caption: "Keeps the input open so the first syllable is never lost.")
                }
                .frame(width: 420)
            }
        }
    }
}

#Preview("Gallery") {
    ComponentGallery()
}

#endif
