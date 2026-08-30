import Foundation
import Testing
@testable import EdictKit

// MARK: - Ballistics

/// The VU movement, pinned to its measured numbers.
///
/// Why this suite exists: `LevelBallistics` is one of the two pieces of the audio path that carry
/// published exact constants and, until now, no coverage at all — the other is the buffer maths, in
/// AudioBufferMathTests. A grep of `Tests/` for `LevelBallistics` and `LevelMeter` found zero hits
/// before this file, so a sign flip on the integrator line or a swapped `min`/`max` in the `dt`
/// clamp could change the needle's whole character with nothing anywhere to fail. Both mutations
/// were made to check that is no longer true; both are now caught here.
///
/// Every number asserted here comes from a measurement rather than from taste (RECON §19,
/// "VU BALLISTICS (validated numerically at a 60 Hz tick)"): attack tau 0.065 s reaches 0.9901 of
/// full deflection at exactly 300 ms, which is the ANSI C16.5 VU integration time; release tau is
/// 0.150 s; the peak marker holds 1.5 s then falls at 20 dB/s; the scale runs −54…0 dBFS with the
/// red band above −6.
///
/// Nothing here reads a clock. `advance(dt:...)` takes the elapsed time as an argument precisely so
/// this is possible, so these tests cannot flake on a loaded machine — which matters, because
/// wall-clock assertions are the flakiest thing in this suite (RECON, "Wall-clock assertions").
@Suite("VU ballistics")
struct LevelBallisticsTests {

    /// A tick of 5 ms, comfortably inside the honoured `[0.004, 0.100]` window, so 60 of them are
    /// exactly the 300 ms the ANSI figure is quoted at.
    private static let tick: Double = 0.005

    /// Silence, as the tap reports it: `audioDBFS` floors at −140, and anything at or below
    /// `D.meter.floorDBFS` maps to fraction 0. −60 is below the floor without being the floor
    /// itself, which keeps the peak branch on its falling path (`newPeak >= peakDBFS` would latch
    /// if the reading and the marker were both exactly −54).
    private static let silence: Double = -60

    /// Run `count` ticks at one steady reading and hand back the movement.
    private static func driven(
        count: Int,
        rmsDBFS: Double,
        peakDBFS: Double,
        dt: Double = tick,
        from start: LevelBallistics = LevelBallistics()
    ) -> LevelBallistics {
        var ballistics = start
        for _ in 0..<count {
            ballistics.advance(dt: dt, rmsDBFS: rmsDBFS, peakDBFS: peakDBFS)
        }
        return ballistics
    }

    // MARK: attack

    /// The headline calibration point. 300 ms of full-scale input must land the needle at 0.9901,
    /// which is what makes this a VU meter rather than a level bar with a fade on it.
    ///
    /// The closed form is `1 - exp(-T/tau)` with T = 0.300 and tau = 0.065, because the per-tick
    /// coefficient `1 - exp(-dt/tau)` composes: the *remaining* distance is multiplied by
    /// `exp(-dt/tau)` each tick, so 60 ticks of 5 ms are indistinguishable from one step of 300 ms.
    @Test("60 ticks of 5 ms at 0 dBFS reach 0.9901 of full deflection")
    func attackReachesTheANSIFigure() {
        let ballistics = Self.driven(count: 60, rmsDBFS: 0, peakDBFS: 0)
        #expect(abs(ballistics.position - 0.9901) < 1e-3,
                "position \(ballistics.position), not 0.9901 — attack tau is no longer 0.065 s")
    }

    /// The needle rises monotonically and never overshoots the printed scale. This is the assertion
    /// a sign flip on `position += (target - position) * coefficient` fails first and hardest: with
    /// the sign reversed the movement runs away from the target instead of towards it, and position
    /// goes negative on the first tick.
    @Test("The needle rises monotonically and stays on the scale")
    func attackIsMonotonicAndBounded() {
        var ballistics = LevelBallistics()
        var previous = ballistics.position
        for _ in 0..<60 {
            ballistics.advance(dt: Self.tick, rmsDBFS: 0, peakDBFS: 0)
            #expect(ballistics.position > previous, "position fell to \(ballistics.position) while rising")
            #expect(ballistics.position <= 1, "position \(ballistics.position) is off the top of the scale")
            previous = ballistics.position
        }
    }

    // MARK: release

    /// The fall, and the trap in testing it: `position` is `private(set)`, so a decay case cannot be
    /// set up by assignment — the needle has to be driven up with real attack ticks first, and the
    /// expected value is then `p = p0 · exp(-T/releaseTau)`.
    ///
    /// It is emphatically **not** `p0 · (1 - exp(-T/tau))`. That form is the *distance travelled*
    /// towards the target, which for a fall towards zero is the part that has already been given up,
    /// not what is left — it would predict 0.856 here against the correct 0.134, so writing the test
    /// the wrong way round would pass on a broken implementation and fail on the shipped one.
    @Test("300 ms of silence decays the needle by exp(-T/0.150)")
    func releaseFollowsTheDecayingExponential() {
        let raised = Self.driven(count: 60, rmsDBFS: 0, peakDBFS: 0)
        let start = raised.position

        let elapsed = 0.300
        let fallen = Self.driven(count: 60, rmsDBFS: Self.silence, peakDBFS: Self.silence, from: raised)

        let expected = start * exp(-elapsed / 0.150)
        #expect(abs(fallen.position - expected) < 1e-6,
                "position \(fallen.position), not \(expected) — release tau is no longer 0.150 s")
        // Guards the direction independently of the constant: 0.134 versus the 0.856 the mirrored
        // form predicts is a difference no tolerance can absorb.
        #expect(fallen.position < start)
    }

    /// The asymmetry itself: the same elapsed time falls further than it rises, because release tau
    /// is 2.3× attack tau. A movement with one shared tau reads as a spring animation, which is the
    /// thing D.motion's comment says these constants exist to avoid.
    @Test("The fall is slower than the rise")
    func releaseIsSlowerThanAttack() {
        let rise = Self.driven(count: 20, rmsDBFS: 0, peakDBFS: 0).position

        let raised = Self.driven(count: 200, rmsDBFS: 0, peakDBFS: 0)   // effectively pinned at 1
        let fall = raised.position - Self.driven(count: 20,
                                                rmsDBFS: Self.silence,
                                                peakDBFS: Self.silence,
                                                from: raised).position

        #expect(rise > fall, "rise \(rise) did not outpace fall \(fall) over the same 100 ms")
    }

    // MARK: the dt clamp

    /// A window occluded for two seconds must not teleport the needle on its first tick back. The
    /// clamp is `min(max(dt, 0.004), 0.100)`, so a 2 s step and a 100 ms step are the *same*
    /// arithmetic — hence equality rather than an inequality, which is the stronger claim and the
    /// one that fails if the ceiling is ever raised or removed.
    @Test("A two-second step moves no further than a 100 ms step")
    func longStepsAreClampedToTheCeiling() {
        let occluded = Self.driven(count: 1, rmsDBFS: 0, peakDBFS: 0, dt: 2.0)
        let ceiling = Self.driven(count: 1, rmsDBFS: 0, peakDBFS: 0, dt: LevelBallistics.maximumStep)

        #expect(abs(occluded.position - ceiling.position) < 1e-12,
                "a 2 s step moved to \(occluded.position) against the clamped \(ceiling.position)")
    }

    /// The other end. Below 4 ms the coefficient is noise, so a burst of near-zero steps must not
    /// stall the movement — it is floored, not discarded.
    @Test("A 0.1 ms step moves no less than a 4 ms step")
    func shortStepsAreClampedToTheFloor() {
        let tiny = Self.driven(count: 1, rmsDBFS: 0, peakDBFS: 0, dt: 0.0001)
        let floor = Self.driven(count: 1, rmsDBFS: 0, peakDBFS: 0, dt: LevelBallistics.minimumStep)

        #expect(abs(tiny.position - floor.position) < 1e-12,
                "a 0.1 ms step moved to \(tiny.position) against the clamped \(floor.position)")
    }

    // MARK: the peak marker

    /// The peak marker is held in dBFS rather than as a fraction, so this rate is a real dB/s and a
    /// resize cannot change it. Hold is 1.5 s exactly: at 1.5 s of accumulated age the marker has
    /// not moved, because the fall is gated on `peakAge > peakHoldDuration`.
    @Test("The peak marker holds for 1.5 s then falls at 20 dB/s")
    func peakHoldsThenFalls() {
        // One loud buffer, then silence.
        var ballistics = LevelBallistics()
        ballistics.advance(dt: Self.tick, rmsDBFS: -20, peakDBFS: -10)
        #expect(ballistics.peakDBFS == -10)

        // 1.5 s of silence: 300 ticks of 5 ms. The marker is still where the transient put it.
        let held = Self.driven(count: 300, rmsDBFS: Self.silence, peakDBFS: Self.silence, from: ballistics)
        #expect(abs(held.peakDBFS - (-10)) < 1e-9,
                "peak moved to \(held.peakDBFS) inside the 1.5 s hold")

        // One further second: 20 dB/s, so −10 → −30. Stated as ±1 dB rather than an equality because
        // the fall is gated on `peakAge > peakHoldDuration` and therefore on where a tick boundary
        // lands; at these 5 ms ticks it happens to come out exactly on −30.
        let falling = Self.driven(count: 200, rmsDBFS: Self.silence, peakDBFS: Self.silence, from: held)
        #expect(abs(falling.peakDBFS - (-30)) < 1,
                "peak fell to \(falling.peakDBFS) after 1 s, not to −30 (20 dB/s)")
    }

    /// The marker rests on the bottom of the printed scale, never below it. Without the `max` it
    /// keeps falling past −54 (measured: −54.0000000000005 on the very next tick, then −54.1, −54.2…)
    /// while `D.meter.fraction` clamps the *drawn* position to 0 — so a meter would look right and
    /// the public `peakDBFS`, which is what a numeric readout prints, would be wrong.
    @Test("The peak marker never falls below the −54 dBFS floor")
    func peakStopsAtTheFloor() {
        var ballistics = LevelBallistics()
        ballistics.advance(dt: Self.tick, rmsDBFS: -20, peakDBFS: -10)

        // 6 s of silence: hold plus 4.5 s of fall would be 90 dB, far past the floor.
        for _ in 0..<1200 {
            ballistics.advance(dt: Self.tick, rmsDBFS: Self.silence, peakDBFS: Self.silence)
            #expect(ballistics.peakDBFS >= D.meter.floorDBFS,
                    "peak reached \(ballistics.peakDBFS), below the \(D.meter.floorDBFS) floor")
        }
        #expect(abs(ballistics.peakDBFS - D.meter.floorDBFS) < 1e-9,
                "peak settled at \(ballistics.peakDBFS), not on the floor")
    }

    /// A louder reading always wins immediately and re-arms the hold — that is what makes a
    /// single-buffer clip still visible a second and a half later.
    @Test("A louder peak takes the marker at once and restarts the hold")
    func peakLatchesUpwards() {
        var ballistics = LevelBallistics()
        ballistics.advance(dt: Self.tick, rmsDBFS: -20, peakDBFS: -10)

        // Let the hold expire and the marker start falling.
        ballistics = Self.driven(count: 400, rmsDBFS: Self.silence, peakDBFS: Self.silence, from: ballistics)
        #expect(ballistics.peakDBFS < -10)

        ballistics.advance(dt: Self.tick, rmsDBFS: -20, peakDBFS: -2)
        #expect(ballistics.peakDBFS == -2)

        // Hold re-armed: 1.5 s later it has still not moved.
        let held = Self.driven(count: 300, rmsDBFS: Self.silence, peakDBFS: Self.silence, from: ballistics)
        #expect(abs(held.peakDBFS - (-2)) < 1e-9, "the hold did not restart on the new peak")
    }

    // MARK: the OVER lamp

    /// `isOver` is `peakDBFS >= D.meter.overDBFS`, i.e. −6 dBFS, and it reads the *marker* — so it
    /// inherits the 1.5 s hold for free and a clip cannot flash past unseen.
    @Test("OVER lights at −5.9 dBFS and not at −6.1")
    func overLampStraddlesMinusSix() {
        var hot = LevelBallistics()
        hot.advance(dt: Self.tick, rmsDBFS: -10, peakDBFS: -5.9)
        #expect(hot.isOver)

        var clean = LevelBallistics()
        clean.advance(dt: Self.tick, rmsDBFS: -10, peakDBFS: -6.1)
        #expect(!clean.isOver)
    }

    // MARK: degenerate readings

    /// An `-inf` reading is survivable, and this is here because the opposite was written down as
    /// fact. `audioDBFS`' comment used to say the −140 floor existed "so true digital silence does
    /// not produce `-inf` and poison the ballistics filter" — measured, it does not: `D.meter.
    /// fraction` clamps `-inf` to 0 before the integrator ever sees it, and the movement steps
    /// normally towards the low peg.
    ///
    /// So the floor is a contract with the one raw reader of `AudioFrame.dbfs` that has no clamp in
    /// front of its integrator — `LevelTrace.tick` in Design/Waveform.swift, where an `-inf` turns
    /// into a permanent `NaN` on the following tick — and not with this filter. The comment on
    /// `audioDBFS` now says so, and `AudioLevelMathTests.silenceFloorKeepsTheTraceFinite` drives it.
    ///
    /// `NaN` is the one reading that *would* propagate here — `D.meter.fraction(dbfs: .nan)` returns
    /// `NaN` — but it cannot arrive: `audioDBFS`' gate is `amplitude > 1e-7`, which is false for
    /// `NaN`, so a buffer of `NaN` samples comes out as −140 like any other silence. That is asserted
    /// in `AudioLevelMathTests.dbfsMapping`.
    @Test("An -inf reading is clamped rather than poisoning the movement")
    func minusInfinityIsSurvivable() {
        var ballistics = Self.driven(count: 60, rmsDBFS: 0, peakDBFS: 0)
        #expect(ballistics.position > 0.9)

        for _ in 0..<60 {
            ballistics.advance(dt: Self.tick, rmsDBFS: -.infinity, peakDBFS: -.infinity)
            #expect(ballistics.position.isFinite, "position became \(ballistics.position)")
        }

        // Same result as any other below-floor reading: a plain release towards zero.
        let reference = Self.driven(count: 60, rmsDBFS: Self.silence, peakDBFS: Self.silence,
                                    from: Self.driven(count: 60, rmsDBFS: 0, peakDBFS: 0))
        #expect(abs(ballistics.position - reference.position) < 1e-12,
                "an -inf reading decayed differently from a −60 dBFS one")
        #expect(ballistics.peakDBFS.isFinite)
    }

    // MARK: reset

    /// `reset()` is what an utterance's end calls, and it must return both pegs — the needle to 0
    /// and the marker to the floor — or the meter opens its next session lit.
    @Test("reset() returns the needle and the marker to the pegs")
    func resetReturnsToThePegs() {
        var ballistics = Self.driven(count: 60, rmsDBFS: 0, peakDBFS: 0)
        #expect(ballistics.position > 0.9)
        #expect(ballistics.isOver)

        ballistics.reset()

        #expect(ballistics.position == 0)
        #expect(ballistics.peakDBFS == D.meter.floorDBFS)
        #expect(!ballistics.isOver)
        #expect(ballistics == LevelBallistics(), "reset() left state a fresh movement does not have")
    }
}

// MARK: - LevelMeter

/// The driver around the movement. Only the parts that do not need a clock or a capture actor are
/// exercised here: `advance(to:snapshot:)` takes the reading explicitly for exactly that reason.
///
/// The claim worth guarding is the one in `frame`'s doc comment — `rms` and `peak` are integrated
/// while **`dbfs` is deliberately left raw**, so a `VUMeter` handed this frame runs its own
/// ballistics off the same input it would have got straight from `AudioCapture.levels`. Smoothing
/// the same signal twice is how a needle ends up feeling dead (DESIGN-COMPONENTS §2).
///
/// Production does read `frame`: HUDWindow.swift:280 and Views/MainWindow.swift:175 both take it and
/// hand it to `Waveform` / `VUMeter`, which read `.dbfs` off it at Waveform.swift:235 and
/// VUMeter.swift:598. What did not exist before this file is any assertion — a grep of `Tests/` for
/// `LevelMeter` found nothing — so a regression that "helpfully" smoothed `dbfs` too would have
/// shipped green.
@Suite("LevelMeter frames")
@MainActor
struct LevelMeterFrameTests {

    /// A fixed instant. Nothing in these tests depends on the real time of day, and the first tick
    /// deliberately has no predecessor to measure against.
    private static let t0 = Date(timeIntervalSinceReferenceDate: 0)

    /// The first call has no previous tick, so it uses the nominal 1/60 s interval rather than a
    /// zero step — otherwise the needle would sit at the peg for one whole frame after a key-down.
    @Test("The first frame already moves the needle, and leaves dbfs raw")
    func firstFrameMovesTheNeedleAndKeepsDBFSRaw() {
        let meter = LevelMeter()
        let frame = meter.advance(to: Self.t0, snapshot: LevelSnapshot(rmsDBFS: -30, peakDBFS: -30, seq: 1))

        // −30 dBFS is 0.4444 of the −54…0 sweep; one nominal tick of attack covers
        // 1 - exp(-(1/60)/0.065) = 0.2262 of the distance to it.
        let target = D.meter.fraction(dbfs: -30)
        let expected = target * D.motion.needleCoefficient(dt: D.motion.needleTickInterval, rising: true)

        #expect(frame.rms > 0, "the first frame left the needle on the peg")
        #expect(abs(Double(frame.rms) - expected) < 1e-6,
                "rms \(frame.rms), not \(expected)")
        // The load-bearing half: raw, so it is neither the smoothed value nor the 0…1 fraction.
        #expect(frame.dbfs == -30, "dbfs \(frame.dbfs) is no longer the raw reading")
        #expect(frame.rms != frame.dbfs)
        #expect(meter.frame == frame, "the returned frame and the published one disagree")
    }

    /// The published `peak` is the marker mapped onto the sweep, which is what a readout draws;
    /// `peakDBFS` keeps the decibels, which is what the fall rate is quoted in.
    @Test("peak is the marker mapped onto the printed sweep")
    func peakIsMappedOntoTheSweep() {
        let meter = LevelMeter()
        let frame = meter.advance(to: Self.t0, snapshot: LevelSnapshot(rmsDBFS: -30, peakDBFS: -6, seq: 1))

        #expect(meter.peakDBFS == -6)
        #expect(abs(Double(frame.peak) - D.meter.fraction(dbfs: -6)) < 1e-6)
        #expect(meter.isOver, "−6 dBFS is the bottom of the red band and must arm OVER")
    }

    /// Subsequent calls integrate over the *real* gap between them, so a dropped frame speeds the
    /// filter up instead of slowing the movement down. Regression guard, not a bug fix: it pins the
    /// `lastTick` bookkeeping that makes `advance(to:)` safe to call from a `TimelineView`.
    @Test("The second frame integrates the elapsed gap, not the nominal tick")
    func secondFrameUsesTheRealElapsedTime() {
        let snapshot = LevelSnapshot(rmsDBFS: 0, peakDBFS: 0, seq: 1)

        let meter = LevelMeter()
        meter.advance(to: Self.t0, snapshot: snapshot)
        let gapped = meter.advance(to: Self.t0.addingTimeInterval(0.050), snapshot: snapshot)

        var reference = LevelBallistics()
        reference.advance(dt: D.motion.needleTickInterval, rmsDBFS: 0, peakDBFS: 0)
        reference.advance(dt: 0.050, rmsDBFS: 0, peakDBFS: 0)

        #expect(abs(Double(gapped.rms) - reference.position) < 1e-6,
                "rms \(gapped.rms), not \(reference.position) — the 50 ms gap was not honoured")
    }

    /// `reset()` on the meter has to clear the frame *and* the tick bookkeeping, so the next call
    /// after a reset behaves like a first call rather than integrating across the idle gap.
    @Test("reset() empties the frame and re-arms the first-tick rule")
    func resetClearsTheFrameAndTheTick() {
        let meter = LevelMeter()
        meter.advance(to: Self.t0, snapshot: LevelSnapshot(rmsDBFS: 0, peakDBFS: 0, seq: 1))
        #expect(meter.frame != .silent)

        meter.reset()
        #expect(meter.frame == .silent)
        #expect(meter.peakDBFS == D.meter.floorDBFS)
        #expect(!meter.isOver)

        // A whole minute of wall clock later, the step is still the nominal tick, not 60 seconds.
        let after = meter.advance(to: Self.t0.addingTimeInterval(60),
                                  snapshot: LevelSnapshot(rmsDBFS: -30, peakDBFS: -30, seq: 2))
        let expected = D.meter.fraction(dbfs: -30)
            * D.motion.needleCoefficient(dt: D.motion.needleTickInterval, rising: true)
        #expect(abs(Double(after.rms) - expected) < 1e-6,
                "rms \(after.rms), not \(expected) — reset() left lastTick behind")
    }

    /// With no source attached the poll yields `.silent`, which is −140 dBFS: below the floor, so
    /// the needle stays on the peg rather than reading the bottom of the scale as a signal.
    @Test("An unattached meter reads silence, not a signal")
    func unattachedMeterReadsSilence() {
        let meter = LevelMeter()
        let frame = meter.advance(to: Self.t0)

        #expect(frame.rms == 0)
        #expect(frame.dbfs == LevelSnapshot.silent.rmsDBFS)
        #expect(!meter.isRunning, "no self-tick was started")
    }
}
