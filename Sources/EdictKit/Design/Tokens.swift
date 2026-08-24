//
//  Tokens.swift
//  EdictKit — Design
//
//  The whole design system, expressed as tokens, so that no view ever needs a literal.
//  Visual reference: early-1980s portable field recorders (Sony TC-D5, Marantz PMD-430,
//  Nakamichi decks) and Braun-era industrial design. Brushed aluminium, matte plastic,
//  silkscreened labels, one red record lamp, an analogue VU needle.
//
//  Call-site shape:
//
//      D.color.recordLamp      D.space.md        D.type.silkscreen
//      D.radius.panel          D.motion.needle   D.surface.brushedAluminium
//      .raisedPanel()          .recessedWell()   .engravedLabel()
//
//  The nested namespaces are deliberately lower-cased types. They are namespaces, not
//  values, so they cost nothing at runtime, and `D.color.deck` reads like a property path
//  instead of `D.Color.deck` shouting a type name in the middle of every view body.
//
//  Concurrency: this file is entirely immutable value data on nonisolated types, so it is
//  usable from any actor. Gradients are computed properties rather than stored statics
//  because SwiftUI's gradient types are cheap to build and this sidesteps any question of
//  global-state isolation under strict concurrency.
//

import AppKit
import SwiftUI

// MARK: - Dynamic colour plumbing

/// Builds an appearance-reactive colour from a light and a dark sRGB hex value.
///
/// Every colour in the system goes through here: there is no such thing as a token that
/// exists in only one appearance. The resolver also folds the increased-contrast
/// appearances onto their base appearance so a high-contrast user gets the deck, not a
/// fallback grey.
private func dyn(
    _ light: UInt32,
    _ dark: UInt32,
    lightAlpha: CGFloat = 1,
    darkAlpha: CGFloat = 1
) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [
            .aqua, .darkAqua,
            .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ])
        let isDark = (match == .darkAqua || match == .accessibilityHighContrastDarkAqua)
        return NSColor(srgbHex: isDark ? dark : light,
                       alpha: isDark ? darkAlpha : lightAlpha)
    })
}

private extension NSColor {
    /// 0xRRGGBB in the sRGB colour space. Not device-dependent: the palette is specified,
    /// not sampled, and must look the same on every display.
    convenience init(srgbHex hex: UInt32, alpha: CGFloat) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - D

/// The design system. Everything visual in Edict is reachable from here.
public enum D {}

// MARK: - Colour

public extension D {
    /// The palette. Nothing outside this enum is allowed to name a colour.
    enum color {

        // ---- Chassis and panels ------------------------------------------------------

        /// The window's ground: the painted chassis everything else is bolted to.
        public static let deck = dyn(0xBEB9AE, 0x232220)
        /// A panel sitting proud of the deck. Default background for grouped controls.
        public static let panelRaised = dyn(0xD2CDC2, 0x322F2B)
        /// A panel sunk into the deck. Backing for lists, tables, and text areas.
        public static let panelRecessed = dyn(0xA6A198, 0x1A1918)
        /// Matte black plastic insert — button caps, the transport block, the HUD body.
        public static let panelPlastic = dyn(0x33312D, 0x191817)

        /// Mid tone of a brushed-aluminium face. Used by `D.surface.brushedAluminium`.
        public static let metalBase = dyn(0xC8C3B8, 0x3A3835)
        /// Top-lit edge of brushed aluminium.
        public static let metalHighlight = dyn(0xEDE9DF, 0x55524C)
        /// Bottom shade of brushed aluminium.
        public static let metalShadow = dyn(0x8F8B81, 0x171615)

        /// The darkness inside a well: meter face surround, display cut-outs, level trough.
        public static let wellFill = dyn(0x1C1B19, 0x121110)

        // ---- Seams and bezels --------------------------------------------------------

        /// The dark line where two panels meet. One hairline, never a fat rule.
        public static let seam = dyn(0x858177, 0x100F0E)
        /// The light catch immediately below a seam. Together they read as a real joint.
        public static let seamHighlight = dyn(0xE4E0D6, 0x454239)

        /// Body of a bezel ring around a meter, lamp, or display.
        public static let bezel = dyn(0x9B968C, 0x302E2B)
        /// Top-left of the bezel, catching the light.
        public static let bezelHighlight = dyn(0xEFEBE2, 0x504C45)
        /// Bottom-right of the bezel, in shade.
        public static let bezelShadow = dyn(0x6E6A62, 0x0C0B0A)

        // ---- Type ---------------------------------------------------------------------

        /// Transcript text, list content, anything the user reads for meaning.
        public static let textPrimary = dyn(0x201F1C, 0xE9E5DA)
        /// Timestamps, counts, secondary metadata.
        public static let textSecondary = dyn(0x4A4741, 0x9C988D)
        /// Silkscreened equipment labels printed onto the panel. Never for prose.
        public static let textSilkscreen = dyn(0x4A463E, 0xB0AB9E)
        /// Ink used *inside* a dark well — counter digits, HUD text. Light in both appearances.
        public static let displayInk = dyn(0xE6E2D6, 0xE9E5DA)

        // ---- The one accent -----------------------------------------------------------

        /// The record light. This red appears nowhere else in the app.
        public static let recordLamp = dyn(0xB0241A, 0xE33C2B)
        /// The same lens, unlit: a dead red-brown, not a grey hole.
        public static let recordLampOff = dyn(0x7A5A54, 0x4A2E2A)
        /// Bloom around a lit lamp. Used at low opacity, never as a glow effect on text.
        public static let recordLampHalo = dyn(0xE8564A, 0xFF6A55)

        // ---- Meter --------------------------------------------------------------------

        /// Cream VU faceplate. Stays warm and pale in dark mode — a lit meter is lit.
        public static let meterFace = dyn(0xD9D2BF, 0xC4BDA9)
        /// Printed scale, tick marks, and the "VU" legend on the faceplate.
        public static let meterScale = dyn(0x3A3833, 0x2A2925)
        /// The needle itself.
        public static let meterNeedle = dyn(0x23221F, 0x1A1917)
        /// The needle's cast shadow on the faceplate; sells the air gap under the glass.
        public static let meterNeedleShadow = dyn(0x8F887A, 0x7C776B)
        /// Safe zone: normal speech level.
        public static let meterGreen = dyn(0x4C8A3A, 0x6FBE51)
        /// Hot zone: loud but usable.
        public static let meterAmber = dyn(0xC08618, 0xE4A733)
        /// Over: clipping, in the bargraph/trough. Tuned against `wellFill`, not the faceplate.
        /// Deliberately close to, but not the same as, `recordLamp`.
        public static let meterRed = dyn(0xCE3826, 0xDC4230)
        /// The red band screen-printed above 0 VU on the cream faceplate. Ink on cream in both
        /// appearances, which is why it cannot reuse `meterRed`.
        public static let meterOverBand = dyn(0xA82418, 0x8E1C12)

        // ---- Selection and state ------------------------------------------------------

        /// Selected row fill. A dim amber wash, like a backlit tape counter.
        public static let selectionFill = dyn(0xCDC3A6, 0x4A4230)
        /// Selected row edge.
        public static let selectionStroke = dyn(0x8A7C55, 0x8E7C4C)
        /// Text on top of `selectionFill`.
        public static let selectionText = dyn(0x1B1A17, 0xF0ECE0)
        /// Keyboard focus ring. Same family as selection so focus never introduces a new hue.
        public static let focusRing = dyn(0x7E7150, 0xC9B57A)

        /// The single alert colour: permissions missing, injection failed, clipping sustained.
        /// Amber, not red — red belongs to the record lamp alone.
        public static let alert = dyn(0x76400C, 0xDE9A34)

        // ---- Shading primitives (consumed by `D.shadow` and the surface recipes) ------

        /// Tight contact shadow directly under a raised part.
        public static let shadowHard = dyn(0x000000, 0x000000, lightAlpha: 0.30, darkAlpha: 0.62)
        /// Ambient shadow further out.
        public static let shadowSoft = dyn(0x000000, 0x000000, lightAlpha: 0.16, darkAlpha: 0.40)
        /// The dark rim cast *inside* a recessed well from its top edge.
        public static let shadowInner = dyn(0x000000, 0x000000, lightAlpha: 0.42, darkAlpha: 0.72)
        /// The light rim on the *bottom* inside edge of a well, and the top edge of a raised panel.
        public static let highlightInner = dyn(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.55, darkAlpha: 0.14)
        /// Fine longitudinal grain drawn over brushed metal.
        public static let metalGrain = dyn(0xFFFFFF, 0xFFFFFF, lightAlpha: 0.032, darkAlpha: 0.022)
        /// Counter-grain, the dark half of the striation pair.
        public static let metalGrainDark = dyn(0x000000, 0x000000, lightAlpha: 0.028, darkAlpha: 0.085)
    }
}

// MARK: - Spacing

public extension D {
    /// A 4pt-based scale. Equipment layout is gridded; nothing lands off the scale.
    enum space {
        /// 2 — hairline gaps, lamp-to-label.
        public static let xxs: CGFloat = 2
        /// 4 — inside a control.
        public static let xs: CGFloat = 4
        /// 8 — between related controls.
        public static let sm: CGFloat = 8
        /// 12 — default padding inside a panel.
        public static let md: CGFloat = 12
        /// 16 — between panels in the same block.
        public static let lg: CGFloat = 16
        /// 24 — between functional blocks (transport deck vs. content).
        public static let xl: CGFloat = 24
        /// 32 — window margin on the long axis.
        public static let xxl: CGFloat = 32
        /// 48 — reserved for the top deck's breathing room.
        public static let xxxl: CGFloat = 48

        /// Inset used by every raised panel's content.
        public static let panelInset: CGFloat = 12
        /// Inset used inside a recessed well (tighter — the well already reads as a frame).
        public static let wellInset: CGFloat = 8
        /// Horizontal padding of a table row.
        public static let rowInset: CGFloat = 10
        /// Gap between a silkscreen label and the thing it labels.
        public static let labelGap: CGFloat = 5
    }
}

// MARK: - Radii

public extension D {
    /// Small radii only. This is milled metal and injection-moulded plastic, not soft UI.
    enum radius {
        /// 0 — genuinely square: seams, scale ticks.
        public static let square: CGFloat = 0
        /// 2 — tick caps, tiny chips.
        public static let tight: CGFloat = 2
        /// 3 — button caps and toggles.
        public static let control: CGFloat = 3
        /// 4 — recessed wells and text fields.
        public static let well: CGFloat = 4
        /// 5 — raised panels.
        public static let panel: CGFloat = 5
        /// 7 — bezel rings and the meter housing.
        public static let bezel: CGFloat = 7
        /// 10 — the window chassis itself and the HUD.
        public static let chassis: CGFloat = 10
        /// A pill, for the level trough.
        public static let pill: CGFloat = 999
    }
}

// MARK: - Border widths

public extension D {
    /// Stroke weights. Hairlines are specified in points and assume ≥2x backing scale.
    enum border {
        /// 0.5 — seams, scale ticks, faint separations.
        public static let hairline: CGFloat = 0.5
        /// 1 — standard panel edge.
        public static let thin: CGFloat = 1
        /// 1.5 — a pressed control's inner edge.
        public static let medium: CGFloat = 1.5
        /// 2 — bezel ring.
        public static let bezel: CGFloat = 2
        /// 3 — focus ring, and the meter housing's outer wall.
        public static let heavy: CGFloat = 3
    }
}

// MARK: - Fixed metrics

public extension D {
    /// Sizes that are part of the instrument's identity rather than of a single view.
    enum size {
        /// Minimum main-window content size, per the contracts.
        public static let windowMin = CGSize(width: 900, height: 600)
        /// Left rail carrying HISTORY / DICTIONARY. Wide enough for a silkscreen label plus lamp.
        public static let railWidth: CGFloat = 172
        /// The transport deck across the top of the main window.
        public static let deckHeight: CGFloat = 104
        /// VU meter housing.
        public static let meterSize = CGSize(width: 232, height: 84)
        /// Record lamp lens diameter.
        public static let lampDiameter: CGFloat = 13
        /// Standard transport button (RECORD / STOP).
        public static let buttonHeight: CGFloat = 30
        /// A small square utility button (copy, delete).
        public static let iconButton: CGFloat = 22
        /// Table row height. Tight, like a printed log.
        public static let rowHeight: CGFloat = 26
        /// Height of the horizontal level trough used in compact places (HUD, menu bar popover).
        public static let troughHeight: CGFloat = 6
        /// Waveform strip height.
        public static let waveformHeight: CGFloat = 44
        /// HUD panel size.
        public static let hudSize = CGSize(width: 360, height: 96)
    }

    /// Named opacities, so "disabled" means one thing everywhere.
    enum opacity {
        public static let disabled: Double = 0.38
        public static let ghost: Double = 0.55
        public static let halo: Double = 0.28
        public static let grain: Double = 1.0
        public static let scrim: Double = 0.72
    }
}

// MARK: - Shadows

public extension D {
    /// A shadow specification. `Sendable` value type so it can live in a token namespace.
    struct Shadow: Sendable, Hashable {
        public let color: Color
        public let radius: CGFloat
        public let x: CGFloat
        public let y: CGFloat

        public init(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat = 0) {
            self.color = color
            self.radius = radius
            self.x = x
            self.y = y
        }
    }

    /// Drop shadows (outer) and rim shadows (inner). The inner ones are what make a
    /// pressed control read as pressed and a well read as a hole.
    enum shadow {
        /// Contact shadow under a raised panel.
        public static let raised = Shadow(color: D.color.shadowHard, radius: 2, y: 1)
        /// Ambient shadow under a raised panel — pair with `raised`.
        public static let raisedAmbient = Shadow(color: D.color.shadowSoft, radius: 7, y: 3)
        /// A button cap standing off its panel.
        public static let cap = Shadow(color: D.color.shadowHard, radius: 1.5, y: 1)
        /// The floating HUD over other applications.
        public static let hud = Shadow(color: D.color.shadowSoft, radius: 18, y: 6)
        /// Needle shadow on the meter faceplate.
        public static let needle = Shadow(color: D.color.meterNeedleShadow, radius: 1.5, x: 1, y: 1.5)

        /// Inner rim cast from the *top* edge into a recessed well.
        public static let wellInner = Shadow(color: D.color.shadowInner, radius: 3, y: 2)
        /// Light rim on the *bottom* inside edge of a well — the other half of the illusion.
        public static let wellInnerLight = Shadow(color: D.color.highlightInner, radius: 2, y: -1)
        /// Deeper inner rim used when a control is actively held down.
        public static let pressedInner = Shadow(color: D.color.shadowInner, radius: 4, y: 3)
        /// Light catch on the *top* inside edge of a control cap that is standing out.
        /// Distinct from `wellInnerLight`, which lights the bottom edge of a hole.
        public static let capInnerLight = Shadow(color: D.color.highlightInner, radius: 1.5, y: 1)
        /// Engraved-text shadow: one point down, light, so the letters look cut into the panel.
        public static let engraved = Shadow(color: D.color.highlightInner, radius: 0, y: 0.5)
    }
}

// MARK: - Typography

public extension D {
    /// A complete text treatment: face, tracking, casing, and leading together.
    ///
    /// Tracking cannot live on `Font` in SwiftUI, so a "font token" alone would leak the
    /// most important part of the silkscreen look back into every call site. `TypeStyle`
    /// bundles all of it and is applied with `.typeStyle(_:)`.
    struct TypeStyle: Sendable, Hashable {
        public let font: Font
        /// Letter spacing in points, applied via `.tracking(_:)`.
        public let tracking: CGFloat
        /// Forced casing, or `nil` to leave the string alone.
        public let textCase: Text.Case?
        /// Extra leading in points, applied via `.lineSpacing(_:)`.
        public let lineSpacing: CGFloat

        public init(
            font: Font,
            tracking: CGFloat = 0,
            textCase: Text.Case? = nil,
            lineSpacing: CGFloat = 0
        ) {
            self.font = font
            self.tracking = tracking
            self.textCase = textCase
            self.lineSpacing = lineSpacing
        }
    }

    /// Type styles.
    ///
    /// Two faces only, both shipped with every macOS install so there is no fallback risk:
    ///
    /// * **SF Pro** — reached through `Font.system(size:weight:)`. A neutral grotesque, which
    ///   is exactly the genre used for panel silkscreening in the period. Its *condensed*
    ///   width (`Font.Width.condensed`) narrows the letterforms the way a real screen-printed
    ///   panel label is narrowed to fit under a control, and it takes positive tracking
    ///   without the counters closing up.
    /// * **SF Mono** — reached through `design: .monospaced`. Fixed pitch for counters and
    ///   timings, so a running clock never reflows. `.monospacedDigit()` is applied on top
    ///   even for the proportional styles that show numbers, because a jittering digit reads
    ///   as a software bug rather than a mechanical counter.
    ///
    /// No custom font files, no `NSFont(name:)` lookups that can return `nil`.
    enum type {

        // ---- Silkscreen: panel labels printed onto the chassis -----------------------

        /// The workhorse panel label. 10pt condensed semibold, generously tracked, uppercase.
        public static let silkscreen = TypeStyle(
            font: .system(size: 10, weight: .semibold).width(.condensed),
            tracking: 1.15,
            textCase: .uppercase
        )
        /// Smallest legible silkscreen: scale legends, tick labels, unit suffixes.
        public static let silkscreenTiny = TypeStyle(
            font: .system(size: 8.5, weight: .semibold).width(.condensed),
            tracking: 0.95,
            textCase: .uppercase
        )
        /// A section heading on the deck — the label above a whole block of controls.
        public static let silkscreenHeading = TypeStyle(
            font: .system(size: 12, weight: .bold).width(.condensed),
            tracking: 1.6,
            textCase: .uppercase
        )
        /// The label moulded into a button cap. Slightly heavier so it survives the shadow.
        public static let buttonCap = TypeStyle(
            font: .system(size: 10.5, weight: .bold).width(.condensed),
            tracking: 1.3,
            textCase: .uppercase
        )

        // ---- Body: text the user reads for meaning ------------------------------------

        /// Transcript text and list content.
        public static let body = TypeStyle(
            font: .system(size: 13, weight: .regular),
            tracking: 0,
            lineSpacing: 2
        )
        /// Emphasised body, for the matched side of a correction pair.
        public static let bodyEmphasis = TypeStyle(
            font: .system(size: 13, weight: .semibold),
            tracking: 0
        )
        /// Small print: timestamps, word counts, hit counts, file paths.
        public static let caption = TypeStyle(
            font: .system(size: 11, weight: .regular),
            tracking: 0.1
        )
        /// One plain sentence explaining a permission or a risk. Slightly looser leading.
        public static let explain = TypeStyle(
            font: .system(size: 11.5, weight: .regular),
            tracking: 0,
            lineSpacing: 3
        )

        // ---- Numerals: counters, timings, levels ---------------------------------------

        /// The big elapsed counter on the transport deck. Reads as a mechanical tape counter.
        public static let counter = TypeStyle(
            font: .system(size: 26, weight: .medium, design: .monospaced).monospacedDigit(),
            tracking: 1.0
        )
        /// A secondary counter — per-row duration, latency readout.
        public static let counterSmall = TypeStyle(
            font: .system(size: 12, weight: .medium, design: .monospaced).monospacedDigit(),
            tracking: 0.4
        )
        /// dBFS readout beside the meter. Tiny, fixed pitch, tracked like a printed scale.
        public static let numeralTiny = TypeStyle(
            font: .system(size: 9, weight: .semibold, design: .monospaced).monospacedDigit(),
            tracking: 0.5
        )
        /// Monospaced body, for showing a rule's regex or a raw-vs-corrected diff.
        public static let mono = TypeStyle(
            font: .system(size: 11.5, weight: .regular, design: .monospaced),
            tracking: 0,
            lineSpacing: 2
        )
    }
}

public extension View {
    /// Applies a complete `D.TypeStyle`. Views must never set `.font` and `.tracking` separately.
    func typeStyle(_ style: D.TypeStyle) -> some View {
        self.font(style.font)
            .tracking(style.tracking)
            .textCase(style.textCase)
            .lineSpacing(style.lineSpacing)
    }
}

// MARK: - Motion

public extension D {
    /// Durations and curves. Nothing in the app animates for a length not named here.
    ///
    /// The house style is short and mechanical: a control reaches its new position in well
    /// under a fifth of a second, because a switch has no easing. The only slow thing in
    /// the app is a needle falling back, and that is slow for a physical reason.
    enum motion {

        // ---- Raw durations (seconds) --------------------------------------------------

        /// Key-down feedback. Deliberately near-instant.
        public static let pressDuration: TimeInterval = 0.055
        /// Key-up recovery — a hair slower than the press, like a spring returning.
        public static let releaseDuration: TimeInterval = 0.11
        /// A panel or pane changing state.
        public static let panelDuration: TimeInterval = 0.22
        /// Swapping the whole content pane (HISTORY ⇄ DICTIONARY).
        public static let paneDuration: TimeInterval = 0.26
        /// The HUD arriving or leaving over another application.
        public static let hudDuration: TimeInterval = 0.16

        // ---- Curves --------------------------------------------------------------------

        /// A control being pushed in. Fast out of the gate, no overshoot.
        public static let press = Animation.timingCurve(0.2, 0.9, 0.3, 1.0, duration: pressDuration)
        /// A control coming back out.
        public static let release = Animation.timingCurve(0.3, 0.0, 0.2, 1.0, duration: releaseDuration)
        /// General panel state change.
        public static let panel = Animation.easeInOut(duration: panelDuration)
        /// Content pane swap.
        public static let pane = Animation.easeInOut(duration: paneDuration)
        /// HUD in/out.
        public static let hud = Animation.easeOut(duration: hudDuration)
        /// A value appearing in a counter or readout. No animation of digits themselves —
        /// this is for the surrounding fade only.
        public static let readout = Animation.easeOut(duration: 0.12)

        // ---- Record lamp ----------------------------------------------------------------

        /// A filament reaching full brightness: quick, but not a step function.
        public static let lampOn = Animation.easeOut(duration: 0.07)
        /// A filament cooling. Noticeably slower than the switch-on — this asymmetry is the
        /// whole reason the lamp reads as a lamp rather than a coloured rectangle.
        public static let lampOff = Animation.easeIn(duration: 0.24)
        /// Arming / model-download state: a slow breath, never a blink. A hard blink in an
        /// always-visible window is an alarm, and arming is not an alarm.
        public static let lampBreathe = Animation
            .easeInOut(duration: 0.85)
            .repeatForever(autoreverses: true)
        /// Error state: three deliberate pulses, then stop. Attention, then silence.
        public static let lampAlarm = Animation
            .easeInOut(duration: 0.28)
            .repeatCount(6, autoreverses: true)

        // ---- VU needle ballistics --------------------------------------------------------
        //
        // Measured on this machine (see docs/RECON.md §19): the audio tap delivers levels at
        // only 2.5–10 Hz, so the needle is NOT animated from audio callbacks. It is
        // integrated on a 60 Hz main-actor tick using a one-pole filter, which is what a real
        // moving-coil movement does. These constants are the movement; `D.motion.needle` is
        // only for the rare case where SwiftUI must interpolate a discrete jump.

        /// The integration tick the needle is advanced on.
        public static let needleTickHz: Double = 60
        /// Convenience: seconds per tick.
        public static let needleTickInterval: TimeInterval = 1.0 / 60.0

        /// Rise time constant. 0.065 s corresponds to the ANSI C16.5 VU standard's 300 ms
        /// integration time — a real VU meter is *slow*, and faking a faster attack makes the
        /// needle twitch on plosives instead of tracking loudness.
        public static let needleAttackTau: TimeInterval = 0.065
        /// Fall time constant. Roughly 2.3× the attack, so the needle hangs and drifts back
        /// the way a weighted movement does.
        public static let needleReleaseTau: TimeInterval = 0.150

        /// The one-pole coefficient for a single tick, so no view hand-rolls `exp`.
        ///
        ///     needle += (target - needle) * D.motion.needleCoefficient(
        ///         dt: dt, rising: target > needle)
        ///
        /// - Parameters:
        ///   - dt: elapsed seconds since the previous tick (use the real delta, not the
        ///     nominal one — a dropped frame must not slow the movement down).
        ///   - rising: whether the target is above the current needle position.
        public static func needleCoefficient(dt: TimeInterval, rising: Bool) -> Double {
            let tau = rising ? needleAttackTau : needleReleaseTau
            guard tau > 0, dt > 0 else { return 1 }
            return 1 - exp(-dt / tau)
        }

        /// Fallback curve for a needle move that cannot be integrated (e.g. resetting to rest
        /// when recording stops). Matches the release feel.
        public static let needle = Animation.easeOut(duration: 0.18)
        /// Returning to the rest peg when capture ends.
        public static let needleRest = Animation.easeInOut(duration: 0.42)

        /// How long the peak marker sits at its high-water mark before it starts to fall.
        public static let peakHoldDuration: TimeInterval = 1.5
        /// Decay rate of the peak marker once the hold expires, in dB per second.
        public static let peakFallDBPerSecond: Double = 20
    }
}

// MARK: - Meter scale

public extension D {
    /// The dB → sweep mapping for the VU meter and the level trough.
    ///
    /// These are calibration numbers, not taste: measured on this machine, a quiet room sits
    /// at −61…−48 dBFS and ordinary speech at −18…−13 dBFS (docs/RECON.md §19). A meter
    /// scaled 0…1 on linear amplitude would leave the needle pinned at the bottom peg for
    /// all normal use, which is why the scale is in decibels and starts at −54.
    enum meter {
        /// Bottom of the sweep. Below this the needle rests on the low peg.
        public static let floorDBFS: Double = -54
        /// Top of the sweep.
        public static let ceilingDBFS: Double = 0
        /// The "0 VU" reference mark — where normal speech should sit.
        public static let referenceDBFS: Double = -18
        /// Above this the scale is printed in red and the over-lamp arms.
        public static let overDBFS: Double = -6
        /// Green up to here, amber between here and `overDBFS`.
        public static let hotDBFS: Double = -12

        /// Total needle sweep, in degrees, centred on vertical.
        public static let sweepDegrees: Double = 84
        /// Angle of the needle at `floorDBFS` (negative = anticlockwise from vertical).
        public static let restAngleDegrees: Double = -42

        /// Normalises a dBFS reading onto 0...1 across the printed scale.
        public static func fraction(dbfs: Double) -> Double {
            guard ceilingDBFS > floorDBFS else { return 0 }
            let t = (dbfs - floorDBFS) / (ceilingDBFS - floorDBFS)
            return min(max(t, 0), 1)
        }

        /// Needle angle in degrees for a normalised 0...1 position.
        public static func angle(fraction: Double) -> Double {
            restAngleDegrees + min(max(fraction, 0), 1) * sweepDegrees
        }

        /// The zone colour for a level, used by both the needle's over-lamp and the trough.
        public static func zoneColor(dbfs: Double) -> Color {
            if dbfs >= overDBFS { return D.color.meterRed }
            if dbfs >= hotDBFS { return D.color.meterAmber }
            return D.color.meterGreen
        }
    }
}

// MARK: - Surface recipes

public extension D {
    /// The material recipes. A view picks a surface; it never assembles one.
    ///
    /// These are computed rather than stored so the token namespace holds no global state,
    /// and because a `LinearGradient` of dynamic `Color`s costs almost nothing to build
    /// while resolving correctly in whichever appearance the view is drawn in.
    enum surface {

        /// Deterministic grain offsets for brushed metal.
        ///
        /// Real brushed aluminium is anisotropic: fine parallel scratches from the abrasive,
        /// running along the long axis of the panel. Faking that with a noise image would mean
        /// shipping an asset and would tile visibly; instead the striations are a fixed,
        /// irregular set of gradient stops along the *cross*-grain axis, so the streaks
        /// themselves run with the grain. Generated once from a fixed seed so the panel looks
        /// identical on every launch — a chassis does not get re-brushed between sessions.
        private static let grainOffsets: [Double] = {
            var state: UInt64 = 0x4D75_726D_7572_0001    // "Edict" + 1
            func next() -> Double {
                // Small deterministic LCG; we only need irregularity, not randomness.
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double((state >> 33) & 0xFFFF) / Double(0xFFFF)
            }
            let bands = 170
            return (0..<bands).map { i in
                let base = Double(i) / Double(bands)
                // Jitter each band inside its own slot so no two scratches are evenly spaced.
                return min(max(base + (next() - 0.5) / Double(bands), 0), 1)
            }
        }()

        // ---- Metal ---------------------------------------------------------------------

        /// Base shading of a brushed-aluminium face: lit from above, in shade below.
        public static var brushedAluminium: LinearGradient {
            LinearGradient(
                stops: [
                    .init(color: D.color.metalHighlight, location: 0.00),
                    .init(color: D.color.metalBase, location: 0.34),
                    .init(color: D.color.metalBase, location: 0.66),
                    .init(color: D.color.metalShadow, location: 1.00),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        /// The scratch pattern. Overlay this on `brushedAluminium`, never use it alone.
        public static var brushedGrain: LinearGradient {
            var stops: [Gradient.Stop] = []
            stops.reserveCapacity(grainOffsets.count)
            for (i, offset) in grainOffsets.enumerated() {
                stops.append(.init(
                    color: i.isMultiple(of: 2) ? D.color.metalGrain : D.color.metalGrainDark,
                    location: offset
                ))
            }
            return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
        }

        // ---- Plastic --------------------------------------------------------------------

        /// Matte injection-moulded plastic: almost flat, with just enough falloff to show it
        /// is a solid object and not a filled rectangle.
        public static var mattePlastic: LinearGradient {
            LinearGradient(
                colors: [
                    D.color.panelPlastic.opacity(0.92),
                    D.color.panelPlastic,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        /// The painted chassis the whole window sits on.
        public static var deckPaint: LinearGradient {
            LinearGradient(
                colors: [D.color.deck, D.color.deck.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        /// A panel standing proud of the deck.
        public static var raisedPanelFill: LinearGradient {
            LinearGradient(
                colors: [D.color.panelRaised, D.color.panelRaised.opacity(0.86)],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        // ---- Wells and displays -----------------------------------------------------------

        /// Inside a recessed well. Darkest at the top, where the overhang shades it.
        public static var wellFill: LinearGradient {
            LinearGradient(
                colors: [
                    D.color.wellFill,
                    D.color.wellFill.opacity(0.86),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        /// The cream VU faceplate, lit from the bottom bezel the way these meters always were.
        public static var meterFace: LinearGradient {
            LinearGradient(
                stops: [
                    .init(color: D.color.meterFace.opacity(0.82), location: 0.0),
                    .init(color: D.color.meterFace, location: 0.55),
                    .init(color: D.color.meterFace, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        // ---- Edges ---------------------------------------------------------------------------

        /// The one-point edge that makes a panel look like it has thickness: light on top,
        /// dark underneath.
        public static var raisedEdge: LinearGradient {
            LinearGradient(
                colors: [D.color.highlightInner, D.color.shadowSoft],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        /// The inverse, for a recessed opening: dark on top, light underneath.
        public static var recessedEdge: LinearGradient {
            LinearGradient(
                colors: [D.color.shadowInner, D.color.highlightInner],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        /// A bezel ring, lit from the top-left.
        public static var bezelRing: LinearGradient {
            LinearGradient(
                stops: [
                    .init(color: D.color.bezelHighlight, location: 0.0),
                    .init(color: D.color.bezel, location: 0.45),
                    .init(color: D.color.bezelShadow, location: 1.0),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }

        // ---- Lamp ------------------------------------------------------------------------------

        /// The record lamp's lens. A domed red lens over a point source, so the bright spot
        /// sits slightly above centre and the rim stays dark even when lit.
        /// - Parameter lit: whether the filament is on.
        public static func lampLens(lit: Bool) -> RadialGradient {
            let core = lit ? D.color.recordLampHalo : D.color.recordLampOff
            let body = lit ? D.color.recordLamp : D.color.recordLampOff.opacity(0.85)
            return RadialGradient(
                stops: [
                    .init(color: core, location: 0.0),
                    .init(color: body, location: 0.55),
                    .init(color: body.opacity(lit ? 0.9 : 0.7), location: 1.0),
                ],
                center: UnitPoint(x: 0.42, y: 0.36),
                startRadius: 0,
                endRadius: D.size.lampDiameter * 0.75
            )
        }

        /// A button cap. Flips its shading when held, which is most of why a press reads as
        /// mechanical rather than as a colour change.
        public static func buttonCap(pressed: Bool) -> LinearGradient {
            LinearGradient(
                colors: pressed
                    ? [D.color.wellFill, D.color.panelPlastic]
                    : [D.color.panelPlastic.opacity(0.74), D.color.panelPlastic],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        /// Dimming layer behind the HUD or a modal sheet.
        public static var scrim: Color { D.color.wellFill.opacity(D.opacity.scrim) }
    }
}

// MARK: - Physical treatments

public extension D {
    /// Draws a shadow *inside* a shape. SwiftUI has no inner shadow, and without one a
    /// pressed control and a recessed well are impossible: an outer shadow makes everything
    /// look like it is floating. Implemented as a heavily blurred stroke masked to the
    /// shape's interior, which is exactly what an inner shadow is.
    struct InnerShadow<S: Shape>: ViewModifier {
        public let shape: S
        public let shadow: D.Shadow

        public init(shape: S, shadow: D.Shadow) {
            self.shape = shape
            self.shadow = shadow
        }

        public func body(content: Content) -> some View {
            content.overlay {
                shape
                    .stroke(shadow.color, lineWidth: max(shadow.radius, 0.5) * 2)
                    .blur(radius: max(shadow.radius, 0.5))
                    .offset(x: shadow.x, y: shadow.y)
                    .mask(shape.fill(Color.black))
                    .allowsHitTesting(false)
            }
        }
    }

    /// A seam between two panels: one dark hairline and one light hairline. A single grey
    /// line is a divider; a pair is a joint between two pieces of metal.
    struct Seam: View {
        public enum Direction: Sendable, Hashable { case horizontal, vertical }

        private let direction: Direction

        public init(_ direction: Direction = .horizontal) {
            self.direction = direction
        }

        public var body: some View {
            Group {
                switch direction {
                case .horizontal:
                    VStack(spacing: 0) {
                        D.color.seam.frame(height: D.border.hairline)
                        D.color.seamHighlight.frame(height: D.border.hairline)
                    }
                    .frame(height: D.border.hairline * 2)
                case .vertical:
                    HStack(spacing: 0) {
                        D.color.seam.frame(width: D.border.hairline)
                        D.color.seamHighlight.frame(width: D.border.hairline)
                    }
                    .frame(width: D.border.hairline * 2)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

public extension View {

    /// Applies a `D.Shadow` as an ordinary drop shadow.
    func shadow(_ token: D.Shadow) -> some View {
        shadow(color: token.color, radius: token.radius, x: token.x, y: token.y)
    }

    /// Applies a `D.Shadow` inside the given shape.
    func innerShadow<S: Shape>(_ shape: S, _ token: D.Shadow) -> some View {
        modifier(D.InnerShadow(shape: shape, shadow: token))
    }

    /// A panel standing proud of the deck: matte fill, a lit top edge, and a contact shadow.
    /// The default background for any grouped block of controls.
    func raisedPanel(radius: CGFloat = D.radius.panel) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(shape.fill(D.surface.raisedPanelFill))
            .overlay(shape.strokeBorder(D.surface.raisedEdge, lineWidth: D.border.thin))
            .clipShape(shape)
            .shadow(D.shadow.raised)
            .shadow(D.shadow.raisedAmbient)
    }

    /// A brushed-aluminium face: the same geometry as `raisedPanel` but milled metal rather
    /// than painted plastic. Use for the transport deck and the meter housing.
    func brushedFace(radius: CGFloat = D.radius.panel) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background {
                shape
                    .fill(D.surface.brushedAluminium)
                    .overlay(shape.fill(D.surface.brushedGrain))
            }
            .overlay(shape.strokeBorder(D.surface.raisedEdge, lineWidth: D.border.thin))
            .clipShape(shape)
            .shadow(D.shadow.raised)
            .shadow(D.shadow.raisedAmbient)
    }

    /// A well cut into the panel: dark fill, a shadow cast in from the top edge, and a light
    /// catch on the bottom inside edge. Backing for lists, text fields, and the waveform.
    func recessedWell(radius: CGFloat = D.radius.well) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(shape.fill(D.surface.wellFill))
            .innerShadow(shape, D.shadow.wellInner)
            .innerShadow(shape, D.shadow.wellInnerLight)
            .overlay(shape.strokeBorder(D.surface.recessedEdge, lineWidth: D.border.thin))
            .clipShape(shape)
    }

    /// A control being held down. Swaps the shading and sinks the content by half a point,
    /// so the cap genuinely moves rather than merely darkening.
    func pressedCap(_ isPressed: Bool, radius: CGFloat = D.radius.control) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .offset(y: isPressed ? 1 : 0)
            .background(shape.fill(D.surface.buttonCap(pressed: isPressed)))
            .innerShadow(shape, isPressed ? D.shadow.pressedInner : D.shadow.capInnerLight)
            .overlay(
                shape.strokeBorder(
                    isPressed ? D.surface.recessedEdge : D.surface.raisedEdge,
                    lineWidth: isPressed ? D.border.medium : D.border.thin
                )
            )
            .clipShape(shape)
            .shadow(isPressed ? D.Shadow(color: .clear, radius: 0) : D.shadow.cap)
            .animation(isPressed ? D.motion.press : D.motion.release, value: isPressed)
    }

    /// A silkscreened panel label: condensed uppercase, tightly tracked, in silkscreen ink,
    /// with a one-point light offset underneath so it reads as printed into the surface.
    func engravedLabel() -> some View {
        typeStyle(D.type.silkscreen)
            .foregroundStyle(D.color.textSilkscreen)
            .shadow(D.shadow.engraved)
    }

    /// The same treatment at heading weight, for a block label on the deck.
    func engravedHeading() -> some View {
        typeStyle(D.type.silkscreenHeading)
            .foregroundStyle(D.color.textSilkscreen)
            .shadow(D.shadow.engraved)
    }

    /// A machined ring around a meter, lamp, or display cut-out.
    func bezelRing(
        radius: CGFloat = D.radius.bezel,
        width: CGFloat = D.border.bezel
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return overlay(shape.strokeBorder(D.surface.bezelRing, lineWidth: width))
            .overlay(
                shape
                    .inset(by: width)
                    .strokeBorder(D.color.shadowInner, lineWidth: D.border.hairline)
            )
    }

    /// A circular bezel, for the record lamp.
    func bezelRingCircular(width: CGFloat = D.border.bezel) -> some View {
        overlay(Circle().strokeBorder(D.surface.bezelRing, lineWidth: width))
            .overlay(
                Circle()
                    .inset(by: width)
                    .strokeBorder(D.color.shadowInner, lineWidth: D.border.hairline)
            )
    }

    /// The keyboard focus ring, in the selection family so focus introduces no new hue.
    func focusRing(_ isFocused: Bool, radius: CGFloat = D.radius.well) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    isFocused ? D.color.focusRing : .clear,
                    lineWidth: D.border.heavy
                )
                .animation(D.motion.panel, value: isFocused)
        )
    }
}
