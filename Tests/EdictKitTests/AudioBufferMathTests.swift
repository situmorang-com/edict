import AVFoundation
import Foundation
import Testing
@testable import EdictKit

// MARK: - Buffer construction

/// Everything in this file builds its `AVAudioPCMBuffer`s by hand. No audio device is opened, no tap
/// is installed and nothing is recorded, which is what makes these tests runnable on any machine —
/// the hardware half of `AudioCapture` is untestable here (RECON §18/§22: the format is
/// device-dependent, the tap's buffer size is hard-clamped by the OS, and the orange microphone
/// indicator lights the moment an engine starts), but the maths the tap calls into is pure.
private enum Fixture {

    /// The two formats the real pipeline sits between. Hardware is Float32 non-interleaved at 24 or
    /// 48 kHz depending on the device; the analyzer accepts only 16 kHz Int16 **interleaved**
    /// (RECON §17), so every buffer changes rate, depth and interleaving in one converter.
    static var hardwareMono: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
    }

    static var analyzer: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    }

    static func float(channels: AVAudioChannelCount, interleaved: Bool, rate: Double = 48_000) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                      channels: channels, interleaved: interleaved)!
    }

    static func int16(channels: AVAudioChannelCount, interleaved: Bool, rate: Double = 48_000) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate,
                      channels: channels, interleaved: interleaved)!
    }

    /// 480 frames — 10 ms at 48 kHz — of a 440 Hz sine at half scale.
    ///
    /// Deliberately not a whole number of cycles and deliberately short: the assertions below
    /// compare two *layouts* of the same samples, and Float32 accumulation of a longer buffer starts
    /// to drift by more than the 1e-6 the comparison is quoted at purely from summation order.
    static let sine: [Float] = (0..<480).map { index in
        0.5 * sinf(2 * .pi * 440 * Float(index) / 48_000)
    }

    /// Same waveform, quantised the way an Int16 device would deliver it.
    static let sineInt16: [Int16] = sine.map { Int16((Double($0) * 32_767).rounded()) }

    /// Write one frame-indexed waveform into every channel of a buffer, honouring the layout.
    ///
    /// This is the whole point of the exercise: for a **non-interleaved** buffer there is one plane
    /// per channel and consecutive samples of one channel are adjacent; for an **interleaved**
    /// buffer there is exactly ONE plane holding `frames * channels` samples, channel-major within
    /// each frame. Both carry the identical multiset of samples, so any correct RMS/peak must agree.
    static func floatBuffer(_ waveform: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(waveform.count)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channels = Int(format.channelCount)
        let data = buffer.floatChannelData!
        if format.isInterleaved {
            for frame in 0..<waveform.count {
                for channel in 0..<channels {
                    data[0][frame * channels + channel] = waveform[frame]
                }
            }
        } else {
            for channel in 0..<channels {
                for frame in 0..<waveform.count { data[channel][frame] = waveform[frame] }
            }
        }
        return buffer
    }

    static func int16Buffer(_ waveform: [Int16], format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(waveform.count)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channels = Int(format.channelCount)
        let data = buffer.int16ChannelData!
        if format.isInterleaved {
            for frame in 0..<waveform.count {
                for channel in 0..<channels {
                    data[0][frame * channels + channel] = waveform[frame]
                }
            }
        } else {
            for channel in 0..<channels {
                for frame in 0..<waveform.count { data[channel][frame] = waveform[frame] }
            }
        }
        return buffer
    }

    /// The reference RMS, accumulated in `Double` over the same multiset of samples, so the layout
    /// results are anchored to an independently-computed number and not only to each other.
    static func referenceRMS(_ waveform: [Float], channels: Int) -> Double {
        let sum = waveform.reduce(0.0) { $0 + Double($1) * Double($1) } * Double(channels)
        return (sum / Double(waveform.count * channels)).squareRoot()
    }
}

// MARK: - Level maths

/// `audioRMSPeak` and `audioDBFS`, which the tap calls on every buffer before anything else happens.
///
/// **READ THIS BEFORE TRUSTING A GREEN RUN HERE.** The interleaved cases are the reason this file
/// exists, and they do not fail the way a test normally fails.
///
/// `audioPlanes` (AudioCapture.swift:167) exists solely because the tap is installed with
/// `format: nil` — passing an explicit format after anything has changed the input device throws an
/// *uncatchable* ObjC exception that aborts the process (RECON §18) — so the layout genuinely
/// changes underneath the running app, and the file's own comment records the consequence: walking
/// `0..<channelCount` planes on an interleaved buffer reads past the end of `channelData`, which for
/// an interleaved buffer holds exactly ONE element.
///
/// The regression this guards is therefore `let planes = channels`, dropping the `isInterleaved`
/// branch — and it dereferences `channelData[1]`, which was never allocated. That is undefined
/// behaviour, and two independent reproductions of the identical edit did not agree on what it does.
/// Mine: the interleaved expectations first record nonsense read out of unrelated memory (`peak` of
/// 1.5e+13 against 0.5, `rms` differing by 4.9e+11) and then the process **faults** — `swift test`
/// reports "exited with unexpected signal code 5" and prints no run summary at all, so every other
/// test in the same process dies with it and the crashing suite is never named. A reviewer running
/// the same edit got the garbage reads with no fault at all.
///
/// So the layout disagreement is the invariant and the crash is not, and a maintainer needs both
/// facts. An unexplained signal-5 crash after touching `audioPlanes` is this test doing its job
/// rather than a broken test file — the failure arrives as a dead process, not as a failed `#expect`.
/// And because a read from an unallocated plane can land on any value, including a plausible one,
/// the layout cases below assert that the two layouts agree with *each other* first, and only then
/// that both sit near an independently computed reference.
@Suite("Audio buffer level maths")
struct AudioLevelMathTests {

    /// The headline claim: the *same* audio in the two layouts the tap can hand us must meter
    /// identically. The two sums differ only in accumulation order, hence 1e-6 rather than equality.
    @Test("A 2-channel sine meters the same interleaved and non-interleaved (Float32)")
    func floatLayoutsAgree() {
        let planar = Fixture.floatBuffer(Fixture.sine, format: Fixture.float(channels: 2, interleaved: false))
        let packed = Fixture.floatBuffer(Fixture.sine, format: Fixture.float(channels: 2, interleaved: true))

        // Sanity on the fixtures themselves, so a mis-built buffer cannot make this test vacuous.
        #expect(planar.stride == 1)
        #expect(packed.stride == 2)
        #expect(planar.frameLength == 480 && packed.frameLength == 480)

        let (planarRMS, planarPeak) = audioRMSPeak(planar)
        let (packedRMS, packedPeak) = audioRMSPeak(packed)

        #expect(abs(planarRMS - packedRMS) < 1e-6,
                "rms \(planarRMS) non-interleaved against \(packedRMS) interleaved")
        #expect(planarPeak == packedPeak, "peak \(planarPeak) against \(packedPeak)")

        // Anchored to a Double reference. The wider tolerance is the Float32 accumulation of 960
        // samples, not slack in the claim above.
        let reference = Fixture.referenceRMS(Fixture.sine, channels: 2)
        #expect(abs(Double(planarRMS) - reference) < 1e-4, "rms \(planarRMS), reference \(reference)")
        #expect(abs(Double(packedRMS) - reference) < 1e-4, "rms \(packedRMS), reference \(reference)")
    }

    /// The same pair in Int16, which is also where the fixed-point scale is pinned. The divisor is
    /// 32768, not 32767: `Float(Int16.min) * (1/32768)` is exactly −1, and because 1/32768 is a
    /// power of two the multiplication is exact, so the peak assertion can be an equality.
    @Test("A 2-channel sine meters the same in both Int16 layouts, on a 1/32768 scale")
    func int16LayoutsAgreeAndUseTheBinaryScale() {
        let planar = Fixture.int16Buffer(Fixture.sineInt16, format: Fixture.int16(channels: 2, interleaved: false))
        let packed = Fixture.int16Buffer(Fixture.sineInt16, format: Fixture.int16(channels: 2, interleaved: true))

        #expect(planar.stride == 1)
        #expect(packed.stride == 2)

        let (planarRMS, planarPeak) = audioRMSPeak(planar)
        let (packedRMS, packedPeak) = audioRMSPeak(packed)

        #expect(abs(planarRMS - packedRMS) < 1e-6,
                "rms \(planarRMS) non-interleaved against \(packedRMS) interleaved")
        #expect(planarPeak == packedPeak)

        let loudest = Fixture.sineInt16.map { abs(Int($0)) }.max()!
        #expect(planarPeak == Float(loudest) / 32_768,
                "peak \(planarPeak), not \(Float(loudest) / 32_768) — the scale is no longer 1/32768")
    }

    /// Full-scale Int16 must land on exactly ±1.0, i.e. 0 dBFS. With a 1/32767 divisor `Int16.min`
    /// reads as −1.0000305 (measured, by making that edit) and `audioDBFS` then returns +0.00026 dBFS
    /// — an over-scale reading on audio that is exactly at full scale.
    @Test("Full-scale Int16 reads exactly 1.0")
    func fullScaleInt16IsUnity() {
        let format = Fixture.int16(channels: 1, interleaved: true)
        let buffer = Fixture.int16Buffer([Int16.min, Int16.max, Int16.min, Int16.max], format: format)

        let (_, peak) = audioRMSPeak(buffer)
        #expect(peak == 1.0, "peak \(peak) for full-scale Int16")
    }

    /// A buffer with no valid frames is silence, not a crash and not a division by zero. `frames`
    /// is what guards the `sumSquares / total` at the end, and the tap can be handed an empty
    /// buffer while the engine is settling after a route change.
    ///
    /// Only the frame count is exercised, and the reason is a measurement rather than the obvious
    /// one. A zero-channel `AVAudioFormat` **is** constructible — `AVAudioFormat(commonFormat:
    /// sampleRate: 48_000, channels: 0, interleaved: false)` returns a perfectly good non-nil
    /// `0 ch, 48000 Hz` format — but `AVAudioPCMBuffer(pcmFormat:frameCapacity:)` on it raises an
    /// **uncatchable** ObjC exception ("required condition is false: isPCMFormat(fmt)") that aborts
    /// the process with SIGABRT, and Swift cannot catch NSException. So `audioPlanes`' `channels > 0`
    /// guard is unreachable from a test by construction, not merely awkward; it is defence against a
    /// format read off a half-negotiated device, which is a real state on this OS (RECON: `inputFormat`
    /// and `outputFormat` disagree after a device change).
    @Test("A zero-length buffer meters as silence")
    func emptyBufferIsSilent() {
        let buffer = AVAudioPCMBuffer(pcmFormat: Fixture.float(channels: 1, interleaved: false),
                                      frameCapacity: 512)!
        buffer.frameLength = 0

        let (rms, peak) = audioRMSPeak(buffer)
        #expect(rms == 0)
        #expect(peak == 0)
    }

    /// The dBFS mapping, including the floor on true digital silence.
    ///
    /// The floor is *not* what keeps the needle's filter safe, though that is the intuitive reading
    /// and was what `audioDBFS`' own comment claimed until this suite measured it: `LevelBallistics`
    /// survives an `-inf` reading, because `D.meter.fraction` clamps it to 0 (pinned by
    /// `LevelBallisticsTests.minusInfinityIsSurvivable`). What the floor buys is that the one raw
    /// reader with no clamp — `LevelTrace.tick` — never sees an `-inf`, which is the next test, and
    /// separately that `NaN` cannot get in at all, which is the reading every one of these filters
    /// would carry for ever.
    @Test("audioDBFS maps 0, 1 and 0.5 correctly and floors silence at −140")
    func dbfsMapping() {
        #expect(audioDBFS(0) == -140)
        #expect(audioDBFS(1) == 0)
        #expect(abs(audioDBFS(0.5) - -6.0206) < 1e-3, "0.5 read \(audioDBFS(0.5)) dBFS, not −6.02")

        // The gate is on amplitude, at 1e-7: below it the reading is the floor rather than the
        // −180 dBFS the logarithm would give, and just above it the real number comes through.
        #expect(audioDBFS(1e-9) == -140)
        #expect(audioDBFS(1e-6) < -100 && audioDBFS(1e-6) > -140,
                "1e-6 read \(audioDBFS(1e-6)) dBFS, not the real ~−120 the logarithm gives")
        #expect(audioDBFS(0) < Float(D.meter.floorDBFS),
                "the silence floor must sit below the meter's printed floor")

        // NaN takes the same exit, and this is load-bearing: `NaN` is the only reading that would
        // propagate through `D.meter.fraction` into the integrator and stick there. The gate is
        // `amplitude > 1e-7`, which is false for NaN, so a buffer of NaN samples reads as silence.
        #expect(audioDBFS(.nan) == -140, "a NaN amplitude read \(audioDBFS(.nan)) dBFS")
        #expect(D.meter.fraction(dbfs: .nan).isNaN,
                "if fraction ever clamped NaN, the note above would be stale")
    }

    /// What the −140 floor is actually buying, driven through the consumer that needs it.
    ///
    /// `LevelTrace.tick` (Design/Waveform.swift:85-92) is the app's other one-pole filter, and unlike
    /// `LevelBallistics` / `NeedleBallistics` it has no `D.meter.fraction` clamp in front of its
    /// integrator: Waveform.swift:235 hands it `Double(level.dbfs)` raw. So an `-inf` sets
    /// `integrated` to `-inf` on the first tick, and on the second `(dbfs - integrated)` is `+inf`
    /// (or `NaN` for another `-inf`), leaving `integrated` at `-inf + inf` = `NaN` — which then flows
    /// into `accumulatedSum`, `commit()`'s mean and every column height for the rest of the trace's
    /// life. NaN does not wash out of a one-pole filter.
    ///
    /// Both halves are asserted, because the comment on `audioDBFS` claims both. The first half is
    /// the one whose failure mode is in `audioDBFS` itself: replace the `-140` with `-.infinity` and
    /// all three committed columns come back NaN (measured). The second half pins the hazard rather
    /// than assuming it — if `LevelTrace` ever gains a clamp, that assertion fails and `audioDBFS`'
    /// comment has to be rewritten, which is the intended outcome.
    ///
    /// No clock: the ticks carry fixed dates, and `LevelTrace` is instance state, so nothing here can
    /// interleave with another suite.
    @Test("The −140 floor is what keeps the waveform trace out of NaN")
    @MainActor
    func silenceFloorKeepsTheTraceFinite() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let period: TimeInterval = 0.1

        // Four ticks one column period apart. The first only arms `lastCommit` (`tick` commits on
        // the *second* tick at the earliest), so three columns are committed, and the ring is read
        // back through the accessor the renderer uses rather than by touching `columns` directly.
        func meansAfterFourTicks(of dbfs: Double) -> [Double] {
            let trace = LevelTrace()
            for step in 0..<4 {
                trace.tick(at: t0.addingTimeInterval(Double(step) * period),
                           dbfs: dbfs, columnPeriod: period)
            }
            var means: [Double] = []
            trace.forEachRecent(16) { _, column in means.append(column.meanDBFS) }
            return means
        }

        // Digital silence as the tap actually reports it. The envelope starts at the printed floor
        // (−54) and integrates towards −140, so every committed mean sits inside that band.
        let floored = meansAfterFourTicks(of: Double(audioDBFS(0)))
        #expect(floored.count == 3, "\(floored.count) columns committed, not 3 — the fixture drifted")
        for mean in floored {
            #expect(mean.isFinite, "silence put \(mean) dBFS in the trace")
            #expect(mean <= D.meter.floorDBFS + 1e-9 && mean >= Double(audioDBFS(0)) - 1e-9,
                    "column mean \(mean) is outside the −140…−54 band silence can produce")
        }

        // The same trace handed the raw value the floor exists to prevent.
        let poisoned = meansAfterFourTicks(of: -.infinity)
        #expect(poisoned.contains { $0.isNaN },
                "raw -inf no longer poisons LevelTrace — audioDBFS' comment needs rewriting")
    }
}

// MARK: - Conversion and copying

/// `CaptureNode.convert` and `CaptureNode.deepCopy` — the two functions that decide whether the
/// buffer handed to `SpeechAnalyzer` is one we own.
///
/// Samples are read straight off the returned `AVAudioPCMBuffer` and never through an
/// `AnalyzerInput`. That is not an arbitrary choice: `AnalyzerInput.buffer` materialises a *fresh*
/// buffer on every access (RECON amendment 46), so `input.buffer.int16ChannelData![0][0]`
/// dereferences a pointer into an object destroyed at the end of that expression — an immediate
/// `EXC_BAD_ACCESS`. Nothing here needs `AnalyzerInput`, so nothing here uses it.
@Suite("Audio conversion")
struct AudioConversionTests {

    private static func converter(from input: AVAudioFormat, to output: AVAudioFormat) throws -> AVAudioConverter {
        let converter = try #require(AVAudioConverter(from: input, to: output))
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        return converter
    }

    /// 48 kHz in, 16 kHz out: about a third of the frames — and the "about" is the whole point.
    ///
    /// MEASURED ON THIS MACHINE, and it is not what a ratio argument predicts. 4,800 input frames at
    /// `AVAudioQuality.max` yield **1,349** frames on a converter's first call, not 1,600: the
    /// polyphase resampler holds 251 frames (15.7 ms of 16 kHz audio) in its priming pipeline.
    /// Deterministic — 1,349 on all 200 fresh converters measured, and 1,354 / 1,360 at `.high` /
    /// `.medium`, so it is the filter's latency rather than jitter.
    ///
    /// That shortfall is 15.7 ms off the start of a converter's life — the same order as the 14–27 ms
    /// of audio RECON measured as already lost to starting the engine on key-down, and a converter is
    /// built with its engine, so in pre-warm mode it is paid long before the user presses anything.
    ///
    /// The window here is deliberately loose: a different input rate or a different OS will move the
    /// latency, and this test's job is to catch a *ratio* regression — a converter wired 48 → 48 or
    /// 48 → 8 — not to pin one machine's filter length. The next test pins what is load-bearing.
    @Test("A 48 kHz buffer converts to about a third as many 16 kHz frames")
    func downsampleKeepsTheFrameRatio() throws {
        let source = Fixture.hardwareMono
        let target = Fixture.analyzer
        let converter = try Self.converter(from: source, to: target)

        let inFrames = 4_800                                    // 100 ms at 48 kHz
        let input = Fixture.floatBuffer(Array(repeating: 0.25, count: inFrames), format: source)

        let output = try #require(CaptureNode.convert(input, converter: converter, target: target),
                                  "convert returned nil — see inputRanDryIsSuccess")
        #expect(output.format == target)

        let ideal = inFrames / 3                                // 1,600
        #expect((1_200...1_700).contains(Int(output.frameLength)),
                "first call produced \(output.frameLength) frames, not near \(ideal) (measured: 1,349)")
    }

    /// The `+ 32` output slack at AudioCapture.swift:549, turned into a falsifiable claim.
    ///
    /// MEASURED: with the capacity the code actually asks for — `ceil(inFrames · outSR/inSR) + 32`,
    /// i.e. 1,632 — the *second* call returns 1,632 frames, thirty-two MORE than the 1,600 the ratio
    /// allows. The converter is bounded by the output capacity, not by the input: given the room it
    /// gives back frames its priming latency was holding.
    ///
    /// Remove the `+ 32` and every call after the first returns exactly 1,600: measured 1,349 then
    /// 1,600 × 19, totalling 31,749 of an ideal 32,000 — the 251-frame hole at the start of the
    /// utterance is then never recovered. With the slack the same 20 calls total 31,823. So `> 1600`
    /// is the assertion, and it is the one that dies when the slack goes.
    @Test("The +32 output slack lets the converter emit more than the ideal ratio")
    func outputSlackIsLoadBearing() throws {
        let source = Fixture.hardwareMono
        let target = Fixture.analyzer
        let converter = try Self.converter(from: source, to: target)

        var lengths: [Int] = []
        for _ in 0..<2 {
            let input = Fixture.floatBuffer(Array(repeating: 0.25, count: 4_800), format: source)
            let output = try #require(CaptureNode.convert(input, converter: converter, target: target))
            lengths.append(Int(output.frameLength))
        }

        #expect(lengths[0] < 1_600, "first call produced \(lengths[0]); the resampler primes on it")
        // At exactly 1,600 the capacity has no slack and the priming deficit is lost for good.
        #expect(lengths[1] > 1_600,
                "second call produced \(lengths[1]) frames, not the measured 1,632")
    }

    /// The rule this test exists for, and the reason it is a *single* buffer in: `.inputRanDry` is
    /// the NORMAL result of the one-buffer-in pattern — "here is everything I could make from what
    /// you gave me" — and treating it as an error throws away every buffer of every utterance
    /// (RECON §17). Verified by moving `.inputRanDry` out of `convert`'s success case and into its
    /// error case: every call in this suite then returns nil and four tests fail, this one on the
    /// explicit non-nil below.
    @Test("One buffer in is a success, not an error, even though the converter runs dry")
    func inputRanDryIsSuccess() throws {
        let source = Fixture.hardwareMono
        let target = Fixture.analyzer
        let converter = try Self.converter(from: source, to: target)

        // Two consecutive calls, because the first primes the resampler and a rule that only held
        // for a primed converter would still lose the start of every utterance.
        for call in 1...2 {
            let input = Fixture.floatBuffer(Array(repeating: 0.25, count: 4_800), format: source)
            let output = CaptureNode.convert(input, converter: converter, target: target)
            #expect(output != nil, "call \(call) returned nil: .inputRanDry is being treated as an error")
            #expect((output?.frameLength ?? 0) > 0)
        }
    }

    /// The claim that actually protects the user: audio does not leak away as an utterance runs on.
    /// One converter reused across every buffer of the utterance (never one per buffer — that resets
    /// the polyphase state and inserts a discontinuity at every 100–400 ms boundary, RECON §17) must
    /// stay within a whisker of the ideal over its whole life, not fall a little further behind on
    /// each call.
    ///
    /// MEASURED, deterministically over 40 runs: 20 × 4,800 input frames is 2.0 s of audio and the
    /// run produces 31,823 of the ideal 32,000 frames — a standing 177-frame (11 ms) shortfall. At 12
    /// calls it was 166 of an ideal 19,200, so it is a standing offset near the resampler's priming
    /// latency and not a per-call leak. The 1 % window below is what a cumulative-loss regression
    /// breaks; a single-call assertion would not see it.
    @Test("Twenty consecutive buffers convert without cumulative loss")
    func converterReuseDoesNotLoseFrames() throws {
        let source = Fixture.hardwareMono
        let target = Fixture.analyzer
        let converter = try Self.converter(from: source, to: target)

        var total = 0
        for _ in 0..<20 {
            let input = Fixture.floatBuffer(Array(repeating: 0.25, count: 4_800), format: source)
            let output = try #require(CaptureNode.convert(input, converter: converter, target: target))
            total += Int(output.frameLength)
        }

        let ideal = 20 * 1_600
        #expect(Double(total) > Double(ideal) * 0.99,
                "20 buffers produced \(total) frames of \(ideal) (measured: 31,823)")
    }

    /// Conversion also changes depth and interleaving, not just the rate (RECON §17). A constant
    /// input must come back as a constant of the same amplitude in Int16, or the pipeline is feeding
    /// the analyzer something quieter or louder than the microphone heard.
    @Test("Conversion carries the amplitude across Float32 → Int16")
    func conversionPreservesAmplitude() throws {
        let source = Fixture.hardwareMono
        let target = Fixture.analyzer
        let converter = try Self.converter(from: source, to: target)

        let input = Fixture.floatBuffer(Array(repeating: 0.5, count: 4_800), format: source)
        let output = try #require(CaptureNode.convert(input, converter: converter, target: target))

        let (_, peak) = audioRMSPeak(output)
        // 0.5 → 16384/32768. Generous tolerance: this is a resampler, not a memcpy, and the edges
        // of the block ramp.
        #expect(abs(peak - 0.5) < 0.05, "peak came out at \(peak), not ~0.5")
    }

    /// With no converter the code deep-copies instead. This is the path RECON's "COPY QUESTION,
    /// DEFINITIVE ANSWER" is about: the tap's own buffer must never be yielded or stored, so the
    /// no-conversion path has to hand back something we allocated.
    @Test("With no converter, convert deep-copies rather than passing the tap's buffer through")
    func noConverterMeansACopy() throws {
        let format = Fixture.hardwareMono
        let input = Fixture.floatBuffer(Fixture.sine, format: format)

        let output = try #require(CaptureNode.convert(input, converter: nil, target: format))
        #expect(output !== input, "convert handed back the tap's own buffer")
        #expect(output.frameLength == input.frameLength)
    }

    /// `deepCopy` itself, in both layouts — it walks `audioPlanes` too, so the interleaved case here
    /// has the same out-of-bounds failure mode described on `AudioLevelMathTests`: garbage values,
    /// and possibly a dead process rather than a failed `#expect`.
    ///
    /// "Distinct" is asserted by mutating the source afterwards: identity and pointer inequality
    /// would both be satisfied by a buffer that aliased the same `mData`.
    @Test("deepCopy returns a buffer that does not share storage", arguments: [false, true])
    func deepCopyIsAnIndependentBuffer(interleaved: Bool) throws {
        let format = Fixture.float(channels: 2, interleaved: interleaved)
        let source = Fixture.floatBuffer(Fixture.sine, format: format)

        let copy = try #require(CaptureNode.deepCopy(source))
        #expect(copy !== source)
        #expect(copy.frameLength == source.frameLength)
        #expect(copy.format == source.format)

        let before = audioRMSPeak(copy)
        #expect(abs(before.rms - audioRMSPeak(source).rms) < 1e-9, "the copy does not hold equal samples")

        // Scribble over the original. A copy that shared storage would follow it.
        let planes = interleaved ? 1 : 2
        let perPlane = Fixture.sine.count * (interleaved ? 2 : 1)
        for plane in 0..<planes {
            for index in 0..<perPlane { source.floatChannelData![plane][index] = 0 }
        }

        #expect(audioRMSPeak(source).rms == 0, "the scribble did not take")
        let after = audioRMSPeak(copy)
        #expect(after.rms == before.rms, "the copy changed with the source — it is aliasing mData")
        #expect(after.rms > 0)
    }

    /// The Int16 half of `deepCopy`, which is the branch the no-conversion path would actually take
    /// if hardware and analyzer formats ever matched exactly.
    @Test("deepCopy copies Int16 buffers too")
    func deepCopyHandlesInt16() throws {
        let source = Fixture.int16Buffer(Fixture.sineInt16, format: Fixture.analyzer)
        let copy = try #require(CaptureNode.deepCopy(source))

        #expect(copy !== source)
        #expect(copy.frameLength == source.frameLength)
        for index in 0..<Fixture.sineInt16.count {
            #expect(copy.int16ChannelData![0][index] == Fixture.sineInt16[index])
        }
    }
}
