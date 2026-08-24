//
//  VUMeter.swift
//  EdictKit — Design
//
//  A moving-coil VU movement behind glass: cream faceplate, printed arc, ten major ticks with
//  numerals, a green/amber/red zone strip, a reference mark at 0 VU, a peak witness marker, an
//  OVER lamp, and a needle with real ballistics.
//
//  The whole file exists because of RECON §19: `installTap`'s bufferSize is hard-clamped to
//  100–400 ms, so levels arrive at only 2.5–10 Hz. A needle animated from arrivals visibly steps.
//  The meter therefore treats `level` as a continuously-valid envelope, re-samples it on a 60 Hz
//  tick, and integrates its own one-pole ballistics — which is what a real movement does anyway.
//
//  Redraw strategy (spec §2.5): two sibling `Canvas` layers, `TimelineView` only around the
//  moving one, and the static one wrapped in `.equatable()` so its ≈70 primitives are drawn once
//  and then skipped forever. Nothing here is `@Observable` or `@Published`, so not one SwiftUI
//  state invalidation occurs per frame.
//

import SwiftUI

// MARK: - Metrics

/// Meter geometry. Everything derives from the faceplate rect, so the instrument scales if
/// `D.size.meterSize` changes. Bracketed defaults are for 232 × 84, where the card is 224 × 76.
private enum M {

    // ---- Layout, as fractions of the card -------------------------------------------

    /// The pivot sits *below* the visible card, exactly as in the real movement. (112, 115.5)
    static let pivotDrop: Double = 0.52
    /// Needle length as a fraction of the pivot's depth. 108.6
    static let needleLength: Double = 0.94
    /// Printed scale radius, as a fraction of the needle. 97.7 — the tip overshoots the scale by
    /// 11pt, which is what makes it read as a needle *above* a card rather than a pointer drawn
    /// on one.
    static let arcRadius: Double = 0.90
    /// Numerals sit this far inside the arc. 82.7
    static let numeralInset: Double = 15
    /// Zone strip radius, as a fraction of the needle. 73.8 — inside the numerals, so the eye
    /// reads level → zone → number from the top down.
    static let zoneRadius: Double = 0.68
    static let zoneWidth: Double = 3

    // ---- Printed scale ----------------------------------------------------------------

    static let tickMajor: Double = 7
    static let tickMinor: Double = 3.5
    /// The screen-printed red band above the danger threshold: a second stroke just outside the
    /// arc. This is why `D.color.meterOverBand` exists separately from `D.color.meterRed` —
    /// ink on cream, not light in a well.
    static let overBandOffset: Double = 2
    static let overBandWidth: Double = 3
    static let refMarkBase: Double = 5
    static let refMarkHeight: Double = 4
    static let legendBaseline: Double = 8
    static let overLampDiameter: Double = 7
    static let overLampInsetX: Double = 20
    static let overLampInsetY: Double = 18
    /// Gap between the OVER lamp and its legend.
    static let overLegendDrop: Double = 12
    /// Half-width of the printed field rule under the numeric readout.
    static let readoutFieldWidth: Double = 30
    static let readoutInsetX: Double = 8
    static let readoutInsetY: Double = 9

    // ---- The needle --------------------------------------------------------------------

    /// A tapered blade, not a line.
    static let needleBaseHalf: Double = 1.6
    static let needleTipHalf: Double = 0.5
    /// The tail starts here and runs off the bottom of the card; the hub is under the bezel.
    static let needleTailRadius: Double = 0.25

    // ---- Integration -------------------------------------------------------------------

    /// The real frame delta is always used, never the nominal tick, so a dropped frame does not
    /// slow the movement down. The clamp stops a window that was occluded for two seconds from
    /// teleporting the needle on the next tick.
    static let dtFloor: TimeInterval = 0.004
    static let dtCeiling: TimeInterval = 0.100

    // ---- Degradation --------------------------------------------------------------------

    /// Below this the deck must not use `VUMeter` at all.
    static let compactWidth: CGFloat = 200
    /// Arcs are drawn as polylines at this angular resolution rather than with `Path.addArc`,
    /// whose `clockwise` flag means the opposite of what it says in a y-down space. 84° of sweep
    /// costs 84 segments, once, behind the `.equatable()` cache.
    static let arcStepDegrees: Double = 1
}

// MARK: - Scale geometry

/// The card's geometry, derived once per draw from the canvas size.
private struct MeterGeometry {
    let card: CGSize
    let pivot: CGPoint
    let needleLength: Double
    let arcRadius: Double
    let numeralRadius: Double
    let zoneRadius: Double

    init(card: CGSize) {
        self.card = card
        let pivotY = Double(card.height) + M.pivotDrop * Double(card.height)
        pivot = CGPoint(x: Double(card.width) / 2, y: pivotY)
        needleLength = M.needleLength * pivotY
        arcRadius = M.arcRadius * needleLength
        numeralRadius = arcRadius - M.numeralInset
        zoneRadius = M.zoneRadius * needleLength
    }

    /// Angles come from the tokens and are never computed locally. Degrees, 0° = straight up,
    /// positive = clockwise.
    func angle(dbfs: Double) -> Double {
        D.meter.angle(fraction: D.meter.fraction(dbfs: dbfs))
    }

    /// A point at radius `r` and angle `theta` (degrees, 0° = up, positive = clockwise).
    func point(radius: Double, degrees theta: Double) -> CGPoint {
        let radians = theta * .pi / 180
        return CGPoint(x: pivot.x + radius * sin(radians), y: pivot.y - radius * cos(radians))
    }

    /// An arc as a polyline. See `M.arcStepDegrees` for why this is not `Path.addArc`.
    func arcPath(radius: Double, from t0: Double, to t1: Double) -> Path {
        var path = Path()
        let span = t1 - t0
        let steps = max(1, Int((abs(span) / M.arcStepDegrees).rounded(.up)))
        for i in 0...steps {
            let theta = t0 + span * Double(i) / Double(steps)
            let p = point(radius: radius, degrees: theta)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    /// A radial line segment at one angle.
    func radialPath(degrees theta: Double, from r0: Double, to r1: Double) -> Path {
        var path = Path()
        path.move(to: point(radius: r0, degrees: theta))
        path.addLine(to: point(radius: r1, degrees: theta))
        return path
    }
}

// MARK: - Needle ballistics

/// The needle integrator. One per meter instance, `@State`-owned, and deliberately **not**
/// `@Observable`: its whole purpose is to mutate sixty times a second without invalidating
/// anything in SwiftUI. `@MainActor` isolation makes it implicitly `Sendable`, which is what
/// `@State` wants, and makes the `advance` call from a `TimelineView` content closure legal under
/// strict concurrency.
@MainActor
final class NeedleBallistics {

    /// Needle position as a 0…1 fraction of the printed scale.
    private(set) var position: Double = 0
    /// Peak high-water mark, in dBFS, for the witness marker and the OVER lamp. Tracked in dB and
    /// not in fraction, so its fall rate is a real dB/s.
    private(set) var peakDBFS: Double = D.meter.floorDBFS

    private var lastTick: Date?
    private var peakSetAt: Date?

    /// Advances to `date` using the real elapsed time, not the nominal frame interval.
    ///
    /// Damping and overshoot are **none, deliberately**. A one-pole filter is critically damped by
    /// construction and cannot overshoot. A real movement overshoots 1–1.5%, and reproducing that
    /// would mean a second-order system whose ringing — at 60 Hz and a 108pt needle — is a 1–2pt
    /// wobble at the tip, which does not read as a mechanical movement, it reads as a spring
    /// animation. The *hang* that makes the needle feel physical comes from the 2.3× asymmetry
    /// between `needleReleaseTau` and `needleAttackTau` (RECON §19), not from ringing.
    func advance(to date: Date, targetDBFS: Double) {
        let dt = min(max(date.timeIntervalSince(lastTick ?? date), M.dtFloor), M.dtCeiling)
        lastTick = date

        let target = D.meter.fraction(dbfs: targetDBFS)
        let k = D.motion.needleCoefficient(dt: dt, rising: target > position)
        position += (target - position) * k

        if targetDBFS > peakDBFS {
            peakDBFS = targetDBFS
            peakSetAt = date
        } else if let setAt = peakSetAt, date.timeIntervalSince(setAt) > D.motion.peakHoldDuration {
            peakDBFS = max(D.meter.floorDBFS, peakDBFS - D.motion.peakFallDBPerSecond * dt)
        }
    }

    func reset() {
        position = 0
        peakDBFS = D.meter.floorDBFS
        lastTick = nil
        peakSetAt = nil
    }
}

// MARK: - VUFaceplate

/// The static half of the meter: card, arc, 28 minor ticks, 10 major ticks, 10 numerals, zone
/// strip, reference mark, legends and the OVER lamp's dark surround.
///
/// `Equatable` on purpose. Wrapped in `.equatable()` by `VUMeter`, this is the single most
/// important line in the file: its only inputs besides the two flags below are the card size
/// (fixed) and the resolved palette (which changes only with appearance or contrast, and those
/// invalidate the whole view tree anyway), so ≈70 primitives are drawn once and then skipped.
public struct VUFaceplate: View, Equatable {

    private let showsNumericReadout: Bool
    private let compact: Bool
    private let increasedContrast: Bool

    public init(showsNumericReadout: Bool) {
        self.init(showsNumericReadout: showsNumericReadout, compact: false, increasedContrast: false)
    }

    init(showsNumericReadout: Bool, compact: Bool, increasedContrast: Bool) {
        self.showsNumericReadout = showsNumericReadout
        self.compact = compact
        self.increasedContrast = increasedContrast
    }

    /// `nonisolated` is required, not decorative: conforming to `View` puts a type's members on
    /// the main actor, and an `Equatable` conformance that inherits that isolation is rejected
    /// under Swift 6 strict concurrency ("conformance crosses into main actor-isolated code").
    /// The three stored properties are `Bool`s, so comparing them off the main actor is safe.
    nonisolated public static func == (a: Self, b: Self) -> Bool {
        a.showsNumericReadout == b.showsNumericReadout
            && a.compact == b.compact
            && a.increasedContrast == b.increasedContrast
    }

    public var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let g = MeterGeometry(card: size)

            // Resolved once per draw. Never pass a `Color` into `context.fill` in a loop over 28
            // ticks — resolution is not free and the loop is where it would be paid.
            let scale = GraphicsContext.Shading.color(D.color.meterScale)
            let overBand = GraphicsContext.Shading.color(D.color.meterOverBand)
            let hairline = increasedContrast ? D.border.thin : D.border.hairline

            drawScaleArc(&context, g, scale: scale, overBand: overBand, hairline: hairline)
            drawZoneStrip(&context, g)
            drawTicks(&context, g, scale: scale, hairline: hairline)
            if !compact {
                drawNumerals(&context, g)
            }
            drawReferenceMark(&context, g, scale: scale)
            if !compact {
                drawUnitLegend(&context, g, size: size)
            }
            drawOverLampSurround(&context, size: size, scale: scale, hairline: hairline)
            if showsNumericReadout {
                drawReadoutField(&context, size: size, scale: scale, hairline: hairline)
            }
        }
    }

    // MARK: Printed scale

    private func drawScaleArc(
        _ context: inout GraphicsContext,
        _ g: MeterGeometry,
        scale: GraphicsContext.Shading,
        overBand: GraphicsContext.Shading,
        hairline: CGFloat
    ) {
        let floor = g.angle(dbfs: D.meter.floorDBFS)
        let over = g.angle(dbfs: D.meter.overDBFS)
        let ceiling = g.angle(dbfs: D.meter.ceilingDBFS)

        context.stroke(g.arcPath(radius: g.arcRadius, from: floor, to: over), with: scale, lineWidth: hairline)
        context.stroke(
            g.arcPath(radius: g.arcRadius, from: over, to: ceiling),
            with: overBand,
            lineWidth: D.border.thin
        )
        // The screen-printed red band itself: a second, heavier stroke just outside the arc.
        context.stroke(
            g.arcPath(radius: g.arcRadius + M.overBandOffset, from: over, to: ceiling),
            with: overBand,
            lineWidth: M.overBandWidth
        )
    }

    private func drawZoneStrip(_ context: inout GraphicsContext, _ g: MeterGeometry) {
        let segments: [(Double, Double, Color)] = [
            (D.meter.floorDBFS, D.meter.hotDBFS, D.color.meterGreen),
            (D.meter.hotDBFS, D.meter.overDBFS, D.color.meterAmber),
            (D.meter.overDBFS, D.meter.ceilingDBFS, D.color.meterOverBand),
        ]
        for (from, to, colour) in segments {
            context.stroke(
                g.arcPath(radius: g.zoneRadius, from: g.angle(dbfs: from), to: g.angle(dbfs: to)),
                with: .color(colour),
                style: StrokeStyle(lineWidth: M.zoneWidth, lineCap: .butt)
            )
        }
    }

    /// Minor ticks every 2 dB (28 positions, 3.11° apart), majors every 6 dB (10 positions,
    /// 9.33° apart, at −54 … 0 dBFS).
    private func drawTicks(
        _ context: inout GraphicsContext,
        _ g: MeterGeometry,
        scale: GraphicsContext.Shading,
        hairline: CGFloat
    ) {
        var minor = Path()
        var major = Path()
        var dbfs = D.meter.floorDBFS
        while dbfs <= D.meter.ceilingDBFS + 0.001 {
            let theta = g.angle(dbfs: dbfs)
            // −54 is 0 dB from the floor, so `isMajor` is exact integer arithmetic on the offset.
            let offset = Int((dbfs - D.meter.floorDBFS).rounded())
            let isMajor = offset % 6 == 0
            let length = isMajor ? M.tickMajor : M.tickMinor
            let segment = g.radialPath(degrees: theta, from: g.arcRadius - length, to: g.arcRadius)
            if isMajor { major.addPath(segment) } else { minor.addPath(segment) }
            dbfs += 2
        }
        context.stroke(minor, with: scale, lineWidth: hairline)
        context.stroke(major, with: scale, lineWidth: D.border.thin)
    }

    /// A printed faceplate sets its numbers **upright**, so the numerals are not rotated.
    /// Magnitude only, no minus sign — the sign lives in the unit legend. At 8.5pt condensed a
    /// two-digit numeral is ≈9pt wide against 13.3pt of arc per major, so every major is labelled
    /// without collision.
    private func drawNumerals(_ context: inout GraphicsContext, _ g: MeterGeometry) {
        var dbfs = D.meter.floorDBFS
        while dbfs <= D.meter.ceilingDBFS + 0.001 {
            let label = Text(String(format: "%.0f", abs(dbfs)))
                .font(D.type.silkscreenTiny.font)
                .tracking(D.type.silkscreenTiny.tracking)
                .foregroundStyle(D.color.meterScale)
            context.draw(
                context.resolve(label),
                at: g.point(radius: g.numeralRadius, degrees: g.angle(dbfs: dbfs)),
                anchor: .center
            )
            dbfs += 6
        }
    }

    /// At −18 dBFS = 0 VU, which lands at +14° — right of centre, exactly as on a real movement.
    private func drawReferenceMark(
        _ context: inout GraphicsContext,
        _ g: MeterGeometry,
        scale: GraphicsContext.Shading
    ) {
        let theta = g.angle(dbfs: D.meter.referenceDBFS)
        let apex = g.point(radius: g.arcRadius + M.overBandOffset, degrees: theta)
        let base = g.arcRadius + M.overBandOffset + M.refMarkHeight
        let halfAngle = atan2(M.refMarkBase / 2, base) * 180 / .pi
        var path = Path()
        path.move(to: apex)
        path.addLine(to: g.point(radius: base, degrees: theta - halfAngle))
        path.addLine(to: g.point(radius: base, degrees: theta + halfAngle))
        path.closeSubpath()
        context.fill(path, with: scale)
    }

    /// The only text on the card that is a genuine acronym, so it is passed already in caps
    /// (spec §0.2) and is correct for both eye and screen reader.
    private func drawUnitLegend(_ context: inout GraphicsContext, _ g: MeterGeometry, size: CGSize) {
        let label = Text("dBFS")
            .font(D.type.silkscreenTiny.font)
            .tracking(D.type.silkscreenTiny.tracking)
            .foregroundStyle(D.color.meterScale)
        context.draw(
            context.resolve(label),
            at: CGPoint(x: size.width / 2, y: size.height - M.legendBaseline),
            anchor: .center
        )
    }

    /// Dark, the OVER lamp is a *printed disc*: a lamp behind a cream card reads as a dark disc
    /// when off, never as a hole. The lit fill is dynamic and therefore lives in the needle layer.
    private func drawOverLampSurround(
        _ context: inout GraphicsContext,
        size: CGSize,
        scale: GraphicsContext.Shading,
        hairline: CGFloat
    ) {
        let centre = VUOverLamp.centre(in: size)
        let rect = CGRect(
            x: centre.x - M.overLampDiameter / 2,
            y: centre.y - M.overLampDiameter / 2,
            width: M.overLampDiameter,
            height: M.overLampDiameter
        )
        context.fill(
            Path(ellipseIn: rect),
            with: .color(D.color.meterScale.opacity(D.opacity.disabled))
        )
        context.stroke(Path(ellipseIn: rect), with: scale, lineWidth: hairline)

        let legend = Text("OVER")
            .font(D.type.silkscreenTiny.font)
            .tracking(D.type.silkscreenTiny.tracking)
            .foregroundStyle(D.color.meterScale)
        context.draw(
            context.resolve(legend),
            at: CGPoint(x: centre.x, y: centre.y + M.overLegendDrop),
            anchor: .center
        )
    }

    /// The printed field the numeric readout is set into — a hairline rule under the number, the
    /// way a real card marks a printed value box. Static, so it belongs on this layer.
    private func drawReadoutField(
        _ context: inout GraphicsContext,
        size: CGSize,
        scale: GraphicsContext.Shading,
        hairline: CGFloat
    ) {
        let y = size.height - M.readoutInsetY + 5
        var path = Path()
        path.move(to: CGPoint(x: M.readoutInsetX, y: y))
        path.addLine(to: CGPoint(x: M.readoutInsetX + M.readoutFieldWidth, y: y))
        context.stroke(path, with: scale, lineWidth: hairline)
    }
}

/// Where the OVER lamp sits, shared by the static surround and the dynamic fill so the two can
/// never drift apart.
private enum VUOverLamp {
    static func centre(in size: CGSize) -> CGPoint {
        CGPoint(x: Double(size.width) - M.overLampInsetX, y: Double(size.height) - M.overLampInsetY)
    }
}

// MARK: - Needle layer

/// The moving half: needle, its cast shadow, the peak witness marker, the OVER lamp's lit fill,
/// and the numeric readout. Eight primitives at most.
///
/// Every input is a plain `Double`, passed *into* the canvas, so the renderer closure mutates
/// nothing and needs no isolation ceremony.
private struct NeedleLayer: View {
    /// 0…1 along the printed scale.
    let fraction: Double
    /// `nil` while parked — a still needle has no witness mark.
    let peakDBFS: Double?
    /// Numeric readout value in dBFS, or `nil` to omit it.
    let readoutDBFS: Double?
    let increasedContrast: Bool

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            let g = MeterGeometry(card: size)
            let boost = increasedContrast ? 0.5 : 0.0
            let needle = needlePath(g, boost: boost)

            // The cast shadow on the card is what sells the air gap under the glass. It must be a
            // second path inside the canvas rather than a `.shadow` modifier, because a canvas
            // shadow would also shade the ticks. Dropped under Increase Contrast: on a cream card
            // it is the one thing that reduces the needle's edge contrast.
            if !increasedContrast {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: D.shadow.needle.radius))
                    layer.opacity = D.opacity.halo
                    layer.translateBy(x: D.shadow.needle.x, y: D.shadow.needle.y)
                    layer.fill(needle, with: .color(D.color.meterNeedleShadow))
                }
            }

            context.fill(needle, with: .color(D.color.meterNeedle))

            if let peakDBFS {
                let theta = g.angle(dbfs: peakDBFS)
                context.stroke(
                    g.radialPath(
                        degrees: theta,
                        from: g.arcRadius - M.tickMajor - 2,
                        to: g.arcRadius + M.overBandOffset
                    ),
                    with: .color(D.meter.zoneColor(dbfs: peakDBFS)),
                    lineWidth: D.border.thin + boost
                )

                // Lit whenever the peak is over, so the lamp inherits the 1.5 s peak hold for
                // free: a clip that lasted one buffer is still visible a second and a half later.
                if peakDBFS >= D.meter.overDBFS {
                    let centre = VUOverLamp.centre(in: size)
                    let rect = CGRect(
                        x: centre.x - M.overLampDiameter / 2,
                        y: centre.y - M.overLampDiameter / 2,
                        width: M.overLampDiameter,
                        height: M.overLampDiameter
                    )
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .color(D.meter.zoneColor(dbfs: peakDBFS))
                    )
                }
            }

            if let readoutDBFS {
                let text = Text(String(format: "%.1f", max(readoutDBFS, D.meter.floorDBFS)))
                    .font(D.type.numeralTiny.font)
                    .tracking(D.type.numeralTiny.tracking)
                    .foregroundStyle(D.color.meterScale)
                context.draw(
                    context.resolve(text),
                    at: CGPoint(x: M.readoutInsetX, y: Double(size.height) - M.readoutInsetY),
                    anchor: .bottomLeading
                )
            }
        }
    }

    /// A tapered blade: half-width `needleBaseHalf` at the tail radius, `needleTipHalf` at full
    /// length. The tail runs off the bottom of the card and is clipped by the faceplate, which is
    /// correct — the hub is under the bezel.
    private func needlePath(_ g: MeterGeometry, boost: Double) -> Path {
        let theta = D.meter.angle(fraction: min(max(fraction, 0), 1))
        let radians = theta * .pi / 180
        // Perpendicular to the blade, so the taper is measured across the needle and not in x.
        let across = CGPoint(x: cos(radians), y: sin(radians))
        let tail = g.point(radius: M.needleTailRadius * g.needleLength, degrees: theta)
        let tip = g.point(radius: g.needleLength, degrees: theta)
        let baseHalf = M.needleBaseHalf + boost
        let tipHalf = M.needleTipHalf + boost

        var path = Path()
        path.move(to: CGPoint(x: tail.x + across.x * baseHalf, y: tail.y + across.y * baseHalf))
        path.addLine(to: CGPoint(x: tip.x + across.x * tipHalf, y: tip.y + across.y * tipHalf))
        path.addLine(to: CGPoint(x: tip.x - across.x * tipHalf, y: tip.y - across.y * tipHalf))
        path.addLine(to: CGPoint(x: tail.x - across.x * baseHalf, y: tail.y - across.y * baseHalf))
        path.closeSubpath()
        return path
    }
}

// MARK: - VUMeter

/// A moving-coil VU meter, driven from the current `AudioFrame`.
///
/// Fixed size: `D.size.meterSize`, via `.frame(width:height:)` and **not** a flexible frame. A VU
/// meter with a variable aspect ratio is not a VU meter; the faceplate proportions are the
/// instrument. Below `M.compactWidth` (200) the deck must **not** use `VUMeter` at all — it uses
/// the horizontal level trough (`D.size.troughHeight`), which is what the HUD and the menu-bar
/// popover show.
public struct VUMeter: View {

    private let level: AudioFrame
    private let isLive: Bool
    private let showsNumericReadout: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.edictIncreasedContrast) private var increasedContrast

    /// Not `@Observable`: see `NeedleBallistics`.
    @State private var ballistics = NeedleBallistics()
    /// Where the needle was when capture ended, so it falls from there rather than snapping.
    @State private var parkFrom: Double = 0
    @State private var parkProgress: Double = 0
    @State private var measuredWidth: CGFloat = D.size.meterSize.width

    /// - Parameters:
    ///   - level: the most recent frame. May be stale by up to 400 ms; the meter treats it as a
    ///     continuously-valid envelope and re-samples it every tick, so no sequence number,
    ///     change detection or stream subscription is needed. Only `dbfs` is used — `rms` and
    ///     `peak` are already display-smoothed by the audio layer, and smoothing twice is how a
    ///     needle ends up feeling dead.
    ///   - isLive: true while capturing. False parks the needle and stops the render schedule.
    ///   - showsNumericReadout: prints the integrated value in `D.type.numeralTiny` on the
    ///     faceplate's lower left. Forced on under Reduce Motion, so the value is legible without
    ///     watching the needle.
    public init(level: AudioFrame, isLive: Bool, showsNumericReadout: Bool = false) {
        self.level = level
        self.isLive = isLive
        self.showsNumericReadout = showsNumericReadout
    }

    public var body: some View {
        // `clipsContent: false` for the one case it exists for: the needle's tail runs under the
        // bezel.
        RecessedWell(fill: .faceplate, radius: D.radius.well, inset: 0, clipsContent: true) {
            ZStack {
                VUFaceplate(
                    showsNumericReadout: printsReadout,
                    compact: isCompact,
                    increasedContrast: increasedContrast
                )
                .equatable()

                if isLive {
                    // Redraws come off the display's refresh rather than off SwiftUI state, and
                    // the schedule stops entirely when idle, so a parked meter costs zero.
                    TimelineView(.animation(minimumInterval: D.motion.needleTickInterval, paused: false)) { ctx in
                        // Legal under strict concurrency: the content closure is main-actor
                        // isolated, and `NeedleBallistics` is a `@MainActor` class.
                        let _ = ballistics.advance(to: ctx.date, targetDBFS: Double(level.dbfs))
                        NeedleLayer(
                            fraction: ballistics.position,
                            peakDBFS: ballistics.peakDBFS,
                            // The *integrated* value, not the raw frame: the printed number and
                            // the needle must never disagree, and the raw frame is up to 400 ms
                            // stale (RECON §19) while the needle is current.
                            readoutDBFS: printsReadout ? Self.dbfs(fraction: ballistics.position) : nil,
                            increasedContrast: increasedContrast
                        )
                    }
                } else {
                    NeedleLayer(
                        fraction: parkFrom * parkProgress,
                        peakDBFS: nil,
                        readoutDBFS: nil,
                        increasedContrast: increasedContrast
                    )
                    .animation(D.motion.needleRest, value: parkProgress)
                }
            }
        }
        .padding(D.space.xs)
        .frame(width: D.size.meterSize.width, height: D.size.meterSize.height)
        .brushedFace(radius: D.radius.bezel)
        .bezelRing(radius: D.radius.bezel, width: D.border.bezel)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
        .onChange(of: isLive) { _, live in live ? arm() : park() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input level")
        .accessibilityValue(spokenValue)
        .accessibilityAddTraits(isLive ? .updatesFrequently : [])
    }

    // MARK: Parking

    private func arm() {
        ballistics.reset()
        parkProgress = 0
    }

    /// The needle falls to the low peg in 0.42 s from wherever it actually was. A needle that
    /// snaps to zero when you stop talking destroys the illusion in one frame.
    private func park() {
        parkFrom = ballistics.position
        parkProgress = 1
        ballistics.reset()
        // A hop, so the 1 → 0 change lands in its own transaction and actually interpolates
        // rather than being coalesced away with the assignment above.
        Task { @MainActor in
            withAnimation(D.motion.needleRest) { parkProgress = 0 }
        }
    }

    // MARK: Degradation and accessibility

    /// Inverse of `D.meter.fraction(dbfs:)`, for printing what the needle is actually showing.
    private static func dbfs(fraction: Double) -> Double {
        D.meter.floorDBFS + min(max(fraction, 0), 1) * (D.meter.ceilingDBFS - D.meter.floorDBFS)
    }

    /// Reduce Motion keeps the needle — it is the data, and freezing it would leave the app with
    /// no level indication at all. What it changes is that the number is always printed.
    private var printsReadout: Bool { showsNumericReadout || reduceMotion }

    /// Below the nominal width the card drops its numerals and unit legend but keeps ticks, zone
    /// strip, reference mark, needle and OVER lamp.
    private var isCompact: Bool { measuredWidth < D.size.meterSize.width }

    /// Spoken, not silkscreened. `String(format:)` so no locale introduces its own digits.
    private var spokenValue: String {
        let dbfs = isLive ? Double(ballistics.peakDBFS) : D.meter.floorDBFS
        let zone: String =
            if dbfs >= D.meter.overDBFS { "over" }
            else if dbfs >= D.meter.hotDBFS { "hot" }
            else { "safe" }
        return String(format: "%.0f decibels, %@", dbfs, zone)
    }
}

// MARK: - Previews

#if DEBUG
#Preview("VUMeter") {
    VStack(alignment: .leading, spacing: D.space.lg) {
        // Quiet room, ordinary speech, hot, clipping, and parked. The four live rows are the
        // calibration RECON §19 measured: quiet −61…−48, speech −18…−13.
        ForEach([-54.0, -18.0, -9.0, -2.0], id: \.self) { dbfs in
            HStack(spacing: D.space.md) {
                VUMeter(level: AudioFrame(rms: 0, peak: 0, dbfs: Float(dbfs)), isLive: true,
                        showsNumericReadout: true)
                SegmentCounter(.decibels(dbfs), scale: .tiny)
            }
        }
        VUMeter(level: AudioFrame(rms: 0, peak: 0, dbfs: -60), isLive: false)
    }
    .padding(D.space.xl)
    .background(D.surface.deckPaint)
}
#endif
