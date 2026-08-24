//
//  LevelMeter.swift
//  The 60 Hz ballistics driver that sits between the audio tap and anything that draws a level.
//
//  Why this file exists at all: `installTap`'s bufferSize is hard-clamped to [100 ms, 400 ms]
//  (docs/RECON.md §19), so levels arrive from the microphone at only 2.5–10 Hz. A needle animated
//  from those arrivals moves in visible 100–400 ms steps — the probe measured full deflection
//  reached in 8 callbacks over 683 ms, in staircase jumps. So the tap does nothing but write
//  `(rmsDB, peakDB, seq)` under a `Mutex`, and the integration happens here, on the main actor, at
//  the display's refresh rate.
//
//  Not `@Observable`, by design (DESIGN-COMPONENTS §0.6): the whole point is to mutate 60 times a
//  second without invalidating a SwiftUI view tree. Hold one in `@State` and read it from inside a
//  `TimelineView` content closure, or drive it from its own tick and take the `onFrame` callback.
//

import Foundation

// MARK: - Ballistics

/// A moving-coil VU movement, as a value type.
///
/// One-pole integrator: `position += (target - position) * (1 - exp(-dt/tau))`, asymmetric so the
/// needle rises fast and hangs on the way down. The constants are not taste — they live in
/// `D.motion` and were validated numerically at a 60 Hz tick (RECON §19): `attackTau` 0.065 s
/// reaches 0.9901 of full deflection at exactly 300 ms, which is the ANSI C16.5 VU integration
/// time, and `releaseTau` 0.150 s is roughly 2.3× that so the movement reads as weighted rather
/// than as a spring animation.
///
/// Nothing here reads the clock; callers pass the real elapsed time. That makes it testable and it
/// makes a dropped frame speed the filter up rather than slow the movement down.
public struct LevelBallistics: Sendable, Equatable {

    /// Shortest `dt` honoured. Below this the coefficient is noise (DESIGN-COMPONENTS §2.3).
    public static let minimumStep: Double = 0.004
    /// Longest `dt` honoured. Clamping stops a window that was occluded for two seconds from
    /// teleporting the needle on its first tick back.
    public static let maximumStep: Double = 0.100

    /// Needle position as a fraction of the printed scale, 0…1.
    public private(set) var position: Double = 0
    /// Peak high-water mark in **dBFS**, not in fraction, so the fall rate below is a real dB/s
    /// and a resize re-maps it without touching the value.
    public private(set) var peakDBFS: Double = D.meter.floorDBFS
    /// Seconds the peak marker has been sitting at its high-water mark.
    private var peakAge: Double = 0

    public init() {}

    /// Advance the movement by `dt` seconds towards the newest reading.
    public mutating func advance(dt: Double, rmsDBFS: Double, peakDBFS newPeak: Double) {
        let step = min(max(dt, Self.minimumStep), Self.maximumStep)

        let target = D.meter.fraction(dbfs: rmsDBFS)
        position += (target - position) * D.motion.needleCoefficient(dt: step, rising: target > position)

        if newPeak >= peakDBFS {
            peakDBFS = newPeak
            peakAge = 0
        } else {
            peakAge += step
            if peakAge > D.motion.peakHoldDuration {
                // The 1.5 s hold is what makes a single-buffer clip still visible a second and a
                // half later; the OVER lamp inherits it for free.
                peakDBFS = max(D.meter.floorDBFS, peakDBFS - D.motion.peakFallDBPerSecond * step)
            }
        }
    }

    /// Back to the low peg.
    public mutating func reset() {
        position = 0
        peakDBFS = D.meter.floorDBFS
        peakAge = 0
    }

    /// True while the peak marker is in the red band, i.e. the OVER lamp should be lit.
    public var isOver: Bool { peakDBFS >= D.meter.overDBFS }
}

// MARK: - LevelMeter

/// Turns the audio layer's 2.5–10 Hz level readings into a continuously-valid `AudioFrame`.
///
/// Two ways to drive it, pick one:
///
/// 1. **Render-timeline** (preferred in a view). Call `advance(to:)` from inside a
///    `TimelineView(.animation)` content closure. No timers, no state invalidation, and the
///    schedule stops with the view.
/// 2. **Self-ticking** (for a model object, e.g. keeping `AppModel.level` current). Call `start()`
///    and take frames from `onFrame`; call `stop()` when capture ends.
///
/// Either way the source is polled *synchronously* through `LevelSource.levelSnapshot`, which is
/// `nonisolated` and `Mutex`-backed precisely so this can happen 60 times a second without an
/// actor hop or an `await`.
@MainActor
public final class LevelMeter {

    /// The current display frame.
    ///
    /// `rms` and `peak` are integrated — the smoothed values a readout can draw directly.
    /// **`dbfs` is deliberately left raw**, so a `VUMeter` or `Waveform` handed this frame runs its
    /// own ballistics off exactly the same input it would get straight from `AudioCapture.levels`.
    /// Smoothing the same signal in two places is how a needle ends up feeling dead
    /// (DESIGN-COMPONENTS §2).
    public private(set) var frame: AudioFrame = .silent

    /// Peak high-water mark in dBFS, for an OVER lamp or a numeric readout.
    public var peakDBFS: Double { ballistics.peakDBFS }

    /// True while the peak marker is in the red band above `D.meter.overDBFS` (−6 dBFS).
    public var isOver: Bool { ballistics.isOver }

    /// True while the self-ticking driver is running. Unrelated to whether audio is being captured.
    public private(set) var isRunning = false

    /// Fired on every tick whose frame differs from the previous one. `AudioFrame` is `Equatable`
    /// so a silent room does not wake a consumer 60 times a second.
    public var onFrame: ((AudioFrame) -> Void)?

    private var ballistics = LevelBallistics()
    private weak var source: (any LevelSource)?
    private var lastTick: Date?
    private var ticker: Task<Void, Never>?

    public init(source: (any LevelSource)? = nil) {
        self.source = source
    }

    // MARK: source

    /// Point the meter at a capture actor. `weak`, because the meter is view-owned state and the
    /// capture actor outlives any one window.
    public func attach(to source: (any LevelSource)?) {
        self.source = source
        lastTick = nil
    }

    // MARK: render-timeline driving

    /// Advance to `date` using the real elapsed time since the previous call.
    ///
    /// Safe to call from a `TimelineView` content closure: it is main-actor isolated, it touches no
    /// SwiftUI state, and it returns the numbers rather than publishing them, so not one view
    /// invalidation occurs per frame.
    @discardableResult
    public func advance(to date: Date) -> AudioFrame {
        let snapshot = source?.levelSnapshot ?? .silent
        return advance(to: date, snapshot: snapshot)
    }

    /// The same step with the reading supplied explicitly — for previews, tests, and any caller
    /// already holding a snapshot.
    @discardableResult
    public func advance(to date: Date, snapshot: LevelSnapshot) -> AudioFrame {
        // First tick has no predecessor; use the nominal interval rather than a zero step, so the
        // needle moves immediately instead of waiting a frame.
        let dt = lastTick.map { date.timeIntervalSince($0) } ?? D.motion.needleTickInterval
        lastTick = date

        ballistics.advance(dt: dt,
                           rmsDBFS: Double(snapshot.rmsDBFS),
                           peakDBFS: Double(snapshot.peakDBFS))

        frame = AudioFrame(rms: Float(ballistics.position),
                           peak: Float(D.meter.fraction(dbfs: ballistics.peakDBFS)),
                           dbfs: snapshot.rmsDBFS)
        return frame
    }

    // MARK: self-ticking driving

    /// Start an internal 60 Hz tick. Idempotent.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        lastTick = nil
        ticker = Task { [weak self] in
            let interval = Duration.seconds(D.motion.needleTickInterval)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                // `weak` here is what lets a discarded meter's tick die on its own, rather than
                // relying on a `deinit` that cannot touch main-actor state.
                guard let self, self.isRunning else { return }
                let previous = self.frame
                let current = self.advance(to: Date())
                if current != previous { self.onFrame?(current) }
            }
        }
    }

    /// Stop the internal tick, leaving `frame` where it was.
    ///
    /// The needle is *not* snapped to zero here: parking is a view concern, animated over
    /// `D.motion.needleRest` from wherever the needle actually was, because a needle that snaps to
    /// the peg the instant you stop talking destroys the illusion in one frame
    /// (DESIGN-COMPONENTS §2.5).
    public func stop() {
        isRunning = false
        ticker?.cancel()
        ticker = nil
        lastTick = nil
    }

    /// Return the movement to the low peg immediately. Call when an utterance ends and the meter
    /// should read empty next time it is shown.
    public func reset() {
        ballistics.reset()
        frame = .silent
        lastTick = nil
    }
}
