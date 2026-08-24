//
//  Waveform.swift
//  EdictKit — Design
//
//  The scrolling level trace shown while recording. A chart recorder, not an oscilloscope.
//
//  This is deliberately *not* a rotation of the VU meter. They answer different questions and are
//  drawn from different statistics: the meter integrates one value under ANSI C16.5 ballistics
//  that hide short transients on purpose, while the trace keeps a per-column peak so a clipped
//  syllable stays visible. If the trace were drawn from the needle's value it would be a smeared
//  duplicate of the meter and would not catch the failure it exists to catch — a dead microphone,
//  a gap mid-sentence, a device change.
//
//  Bottom-anchored, never mirrored about a centre line. A symmetric waveform is an oscilloscope
//  trace or — far more damningly — the Voice Memos / dictation-app cliché. A level recorder draws
//  from a baseline, and that is what this is.
//

import SwiftUI

// MARK: - Metrics

private enum M {
    /// Fixed ring capacity, larger than `maxColumns`, allocated once. A resize changes how many
    /// stored columns are drawn; it never reallocates and never clears history.
    static let traceCapacity = 256
    /// **Never faster than 10 Hz.** RECON §19: the audio tap's buffer size is hard-clamped to
    /// 100–400 ms, so levels arrive at 2.5–10 Hz. A column rate above the source rate is invented
    /// data, and chunky honest columns look more like equipment than a dense fake waveform does.
    static let minColumnPeriod: TimeInterval = 0.1
    static let minColumns = 40
    static let maxColumns = 160
    /// 6pt per column, which at the default 8 s window in a 600pt strip lands on 80 columns, a
    /// 0.1 s period and a 7.5pt pitch: a 5pt bar with a 2.5pt gap.
    static let targetPitch = D.space.xs * 1.5
    static let barWidthRatio: Double = 0.67
    /// 30 Hz, half the needle's rate: between commits the only thing changing is one translation,
    /// and the ballistics integration is stable at 30 Hz because the clamped real `dt` goes into
    /// `needleCoefficient` exactly as it does in the meter.
    static let traceTickInterval: TimeInterval = 1.0 / 30.0
    /// Same clamps as the needle: a real delta, but never a teleport after an occluded window.
    static let dtFloor: TimeInterval = 0.004
    static let dtCeiling: TimeInterval = 0.100
}

// MARK: - LevelTrace

/// The ring buffer behind the trace. `@State`-owned, `@MainActor`, and **not** `@Observable` —
/// the same contract as `NeedleBallistics`: it must mutate every render tick without invalidating
/// anything in SwiftUI.
@MainActor
final class LevelTrace {

    /// Both values are stored in **dB**, not as a 0…1 fraction, so a resize re-maps the drawing
    /// without touching the buffer.
    struct Column {
        var meanDBFS: Double
        var peakDBFS: Double
    }

    /// Fixed capacity, allocated once, written as a ring.
    private(set) var columns: [Column]
    private var writeIndex = 0
    private(set) var filled = 0

    /// The integrated envelope. Integrating *first* is what stops a 400 ms buffer from producing
    /// four identical columns and a visible staircase.
    private var integrated: Double = D.meter.floorDBFS
    private var accumulatedSum: Double = 0
    private var accumulatedCount = 0
    private var accumulatedPeak: Double = D.meter.floorDBFS

    private var lastTick: Date?
    private var lastCommit: Date?

    /// How far into the current column period we are, 0…1. Drives the interpolated scroll.
    private(set) var commitPhase: Double = 0

    init() {
        columns = Array(repeating: Column(meanDBFS: D.meter.floorDBFS, peakDBFS: D.meter.floorDBFS),
                        count: M.traceCapacity)
    }

    /// Integrates the envelope on every render tick and commits one column per `columnPeriod`.
    func tick(at date: Date, dbfs: Double, columnPeriod: TimeInterval) {
        let dt = min(max(date.timeIntervalSince(lastTick ?? date), M.dtFloor), M.dtCeiling)
        lastTick = date

        // The same one-pole filter the needle uses, so the trace and the movement agree about
        // what "the level" is even though they report different statistics of it.
        let k = D.motion.needleCoefficient(dt: dt, rising: dbfs > integrated)
        integrated += (dbfs - integrated) * k

        accumulatedSum += integrated
        accumulatedCount += 1
        accumulatedPeak = max(accumulatedPeak, dbfs)

        let since = date.timeIntervalSince(lastCommit ?? date)
        if lastCommit == nil {
            lastCommit = date
        } else if since >= columnPeriod {
            commit()
            // Advance by whole periods rather than snapping to `date`, so the column grid does not
            // drift when a tick lands late.
            lastCommit = (lastCommit ?? date).addingTimeInterval(
                columnPeriod * (since / columnPeriod).rounded(.down)
            )
        }
        commitPhase = min(max(date.timeIntervalSince(lastCommit ?? date) / columnPeriod, 0), 1)
    }

    private func commit() {
        let mean = accumulatedCount > 0
            ? accumulatedSum / Double(accumulatedCount)
            : integrated
        columns[writeIndex] = Column(meanDBFS: mean, peakDBFS: accumulatedPeak)
        writeIndex = (writeIndex + 1) % M.traceCapacity
        filled = min(filled + 1, M.traceCapacity)
        accumulatedSum = 0
        accumulatedCount = 0
        accumulatedPeak = D.meter.floorDBFS
    }

    /// The `n` newest columns, newest first. Walks the ring in place: no allocation per frame.
    func forEachRecent(_ n: Int, _ body: (Int, Column) -> Void) {
        let available = min(n, filled)
        for i in 0..<available {
            let index = ((writeIndex - 1 - i) % M.traceCapacity + M.traceCapacity) % M.traceCapacity
            body(i, columns[index])
        }
    }

    var isEmpty: Bool { filled == 0 }

    /// History from the previous utterance in the current utterance's strip is a lie.
    func clear() {
        writeIndex = 0
        filled = 0
        integrated = D.meter.floorDBFS
        accumulatedSum = 0
        accumulatedCount = 0
        accumulatedPeak = D.meter.floorDBFS
        lastTick = nil
        lastCommit = nil
        commitPhase = 0
    }
}

// MARK: - Waveform

/// A scrolling level trace. Owns a ring buffer of decimated columns and samples the incoming
/// envelope on its own tick; like `VUMeter` it treats `level` as continuously valid and needs no
/// stream, no sequence number and no change detection.
///
/// The strip is `.accessibilityHidden(true)`: it is a redundant view of the same signal `VUMeter`
/// already exposes with a label and a value, and two elements narrating the same level is worse
/// than one. The single piece of information only this component has — "No input" — is announced
/// through `StatusReadout`, not here.
public struct Waveform: View {

    /// Seconds of history shown across the full width.
    public static let defaultWindow: TimeInterval = 8

    private let level: AudioFrame
    private let isLive: Bool
    private let window: TimeInterval
    private let isTranscribing: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.edictIncreasedContrast) private var increasedContrast

    @State private var trace = LevelTrace()
    @State private var measuredWidth: CGFloat = 0

    /// - Parameters:
    ///   - isLive: true while capturing. False freezes the trace and stops the render schedule.
    ///   - isTranscribing: the audio is finished but the utterance is not, so the frozen trace
    ///     stays at full opacity instead of dropping to `ghost`. Defaulted, because the state
    ///     exists in the spec's state table but not in its initialiser.
    public init(
        level: AudioFrame,
        isLive: Bool,
        window: TimeInterval = Waveform.defaultWindow,
        isTranscribing: Bool = false
    ) {
        self.level = level
        self.isLive = isLive
        self.window = window
        self.isTranscribing = isTranscribing
    }

    public var body: some View {
        RecessedWell(fill: .display, radius: D.radius.well, inset: D.space.xs) {
            ZStack {
                if isEnabled {
                    // `paused` when not live, so an idle window costs nothing. Under Reduce Motion
                    // the interval relaxes to the column period, because nothing between commits
                    // changes any more — which incidentally makes that the cheapest path.
                    TimelineView(
                        .animation(
                            minimumInterval: reduceMotion ? M.minColumnPeriod : M.traceTickInterval,
                            paused: !isLive
                        )
                    ) { ctx in
                        let _ = tickIfLive(ctx.date)
                        TraceCanvas(
                            trace: trace,
                            columns: columnCount,
                            phase: reduceMotion || !isLive ? 0 : trace.commitPhase,
                            showsWriteHead: isLive,
                            increasedContrast: increasedContrast
                        )
                    }
                    .opacity(traceOpacity)
                } else {
                    // Not a placeholder waveform — a fake trace in an idle strip is the kind of
                    // decoration this app does not do.
                    SilkscreenLabel("No input", weight: .tiny)
                        .foregroundStyle(D.color.alert)
                }
            }
        }
        .frame(height: D.size.waveformHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
        .onChange(of: isLive) { _, live in if live { trace.clear() } }
        .accessibilityHidden(true)
    }

    /// Called from the timeline's content closure — main-actor isolated, so the call is legal
    /// under strict concurrency, and the resulting values are passed into the canvas as plain
    /// numbers. No state invalidation per frame, no mutation inside the renderer.
    private func tickIfLive(_ date: Date) {
        guard isLive else { return }
        trace.tick(at: date, dbfs: Double(level.dbfs), columnPeriod: columnPeriod)
    }

    /// | state | treatment |
    /// | --- | --- |
    /// | live | scrolling, write head visible |
    /// | idle, never recorded | empty well, baseline only, at `ghost` |
    /// | idle, after an utterance | last trace frozen at `ghost`, write head hidden |
    /// | transcribing | frozen trace at full opacity, write head hidden |
    private var traceOpacity: Double {
        if isLive || isTranscribing { return 1 }
        return D.opacity.ghost
    }

    // MARK: Column rate
    //
    // Derived, never chosen at the call site: the column count is bounded by both the strip's
    // width and the source's real update rate, and the period follows from it.

    private var columnCount: Int {
        let byWidth = Int(max(measuredWidth, 1) / M.targetPitch)
        let byRate = Int(window / M.minColumnPeriod)
        return min(max(min(byWidth, byRate), M.minColumns), M.maxColumns)
    }

    private var columnPeriod: TimeInterval { window / Double(columnCount) }
}

// MARK: - TraceCanvas

/// One `Canvas`, ≤ 160 bars + 160 peak caps + 2 rules — under 350 primitives, one draw, no
/// shadows, no blurs, no `.drawingGroup()`.
private struct TraceCanvas: View {
    let trace: LevelTrace
    let columns: Int
    let phase: Double
    let showsWriteHead: Bool
    let increasedContrast: Bool

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            // Resolved once, before the column loop.
            let ink = GraphicsContext.Shading.color(D.color.displayInk)
            let hairline = increasedContrast ? D.border.thin : D.border.hairline
            let usableHeight = Double(size.height) - hairline
            let pitch = Double(size.width) / Double(columns)
            let barWidth = pitch * M.barWidthRatio + (increasedContrast ? 0.5 : 0)
            let baselineY = Double(size.height) - hairline

            // 0 — the baseline the recorder draws from.
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: baselineY))
            baseline.addLine(to: CGPoint(x: Double(size.width), y: baselineY))
            context.stroke(baseline, with: ink, lineWidth: hairline)
            context.opacity = 1

            // The paper always moves *toward* the write head, so the newest column is on the
            // right and the set slides left as the current period fills.
            let scroll = phase * pitch

            trace.forEachRecent(columns + 1) { index, column in
                let right = Double(size.width) - Double(index) * pitch - scroll
                let x = right - barWidth
                guard right > 0 else { return }

                let meanHeight = D.meter.fraction(dbfs: column.meanDBFS) * usableHeight
                if meanHeight > 0 {
                    context.fill(
                        Path(CGRect(x: x, y: baselineY - meanHeight, width: barWidth, height: meanHeight)),
                        with: .color(D.meter.zoneColor(dbfs: column.meanDBFS))
                    )
                }

                // The column's transient, and the reason the strip catches a clip the needle
                // deliberately smoothed away.
                let peakY = baselineY - D.meter.fraction(dbfs: column.peakDBFS) * usableHeight
                context.opacity = increasedContrast ? 1 : D.opacity.ghost
                context.fill(
                    Path(CGRect(x: x, y: peakY - D.border.thin, width: barWidth, height: D.border.thin)),
                    with: ink
                )
                context.opacity = 1
            }

            if showsWriteHead {
                var head = Path()
                head.move(to: CGPoint(x: Double(size.width) - D.border.thin, y: 0))
                head.addLine(to: CGPoint(x: Double(size.width) - D.border.thin, y: baselineY))
                context.stroke(head, with: ink, lineWidth: D.border.thin)
            }
        }
    }
}

// MARK: - Previews

#if DEBUG
#Preview("Waveform") {
    VStack(alignment: .leading, spacing: D.space.lg) {
        // live, frozen after an utterance, frozen while transcribing, and no input device
        Waveform(level: AudioFrame(rms: 0.2, peak: 0.3, dbfs: -16), isLive: true)
        Waveform(level: AudioFrame(rms: 0, peak: 0, dbfs: -60), isLive: false)
        Waveform(level: AudioFrame(rms: 0, peak: 0, dbfs: -60), isLive: false, isTranscribing: true)
        Waveform(level: AudioFrame(rms: 0, peak: 0, dbfs: -60), isLive: false).disabled(true)
    }
    .frame(width: 520)
    .padding(D.space.xl)
    .background(D.surface.deckPaint)
}
#endif
