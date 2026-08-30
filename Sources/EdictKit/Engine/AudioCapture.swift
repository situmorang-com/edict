//
//  AudioCapture.swift
//  Microphone capture and the audio bridge into SpeechAnalyzer.
//
//  Almost every non-obvious decision in this file is a measured finding from
//  docs/RECON.md §"Microphone capture and the analyzer audio bridge" (§17–§22). The probe that
//  produced those findings compiled and RAN this pipeline on this machine; where a comment cites
//  a RECON section, the code is that way because the obvious alternative was observed to crash,
//  abort the process, or silently destroy audio. Do not "simplify" those spots from memory.
//
//  Data flow:
//
//      AVAudioEngine.inputNode --tap(100–400 ms)--> AVAudioConverter --> AsyncStream<AnalyzerInput>
//                                     |
//                                     +--> Mutex<LevelSnapshot>  --(polled at 60 Hz)--> LevelMeter
//

import AVFoundation
import Foundation
import Speech
import Synchronization

// MARK: - Public value types

/// One display-ready level reading.
///
/// `dbfs` is the raw instantaneous RMS of the newest tap buffer and is the value the VU meter and
/// the waveform integrate themselves (they run their own ballistics off the render timeline —
/// see DESIGN-COMPONENTS §2.3/§11.2). `rms` and `peak` are the same information already mapped
/// onto the printed 0…1 sweep, for readouts that want a number they can draw without doing any
/// filtering of their own.
///
/// `Equatable` is deliberate: the tap only produces a new reading 2.5–10 times a second
/// (RECON §19), so a 60 Hz consumer can skip the vast majority of its updates.
public struct AudioFrame: Sendable, Equatable, Hashable {
    /// Smoothed RMS as a fraction of the printed scale, 0…1.
    public var rms: Float
    /// Peak high-water mark as a fraction of the printed scale, 0…1.
    public var peak: Float
    /// Raw RMS level in dBFS. `D.meter.floorDBFS` (−54) is the bottom of the meter's sweep;
    /// silence reads about −140.
    public var dbfs: Float

    public init(rms: Float, peak: Float, dbfs: Float) {
        self.rms = rms
        self.peak = peak
        self.dbfs = dbfs
    }

    /// The needle at rest. Used before capture starts and after it stops.
    public static let silent = AudioFrame(rms: 0, peak: 0, dbfs: Float(D.meter.floorDBFS))
}

/// The newest reading the audio tap wrote, in dB, plus a monotonic sequence number.
///
/// This is the raw hand-off across the thread boundary: the tap writes it under a `Mutex` at
/// 2.5–10 Hz and the main actor polls it at 60 Hz. `seq` lets a poller tell "nothing new" from
/// "genuinely silent" without comparing floats.
public struct LevelSnapshot: Sendable, Equatable {
    public var rmsDBFS: Float
    public var peakDBFS: Float
    /// Incremented once per tap buffer. Wraps; only ever compared for inequality.
    public var seq: UInt64

    public init(rmsDBFS: Float = -140, peakDBFS: Float = -140, seq: UInt64 = 0) {
        self.rmsDBFS = rmsDBFS
        self.peakDBFS = peakDBFS
        self.seq = seq
    }

    public static let silent = LevelSnapshot()
}

/// Anything a `LevelMeter` can poll for levels.
///
/// The accessor is deliberately synchronous and non-isolated: the meter reads it from inside a
/// `TimelineView` content closure 60 times a second, where an `await` is not available and an
/// actor hop per frame would be absurd. `AudioCapture` satisfies it with a `Mutex`-backed read.
public protocol LevelSource: AnyObject, Sendable {
    var levelSnapshot: LevelSnapshot { get }
}

/// Health counters for one utterance. A garbled transcript out of this pipeline is almost always
/// dropped buffers or a device change mid-sentence, not the speech model (RECON, "Instrument
/// `dropped` and `conversionFailures` from day one"), so these are surfaced rather than logged
/// and forgotten.
public struct CaptureStats: Sendable, Hashable {
    /// Tap callbacks seen since the utterance began.
    public var tapBuffers: Int = 0
    /// Converted buffers successfully handed to the analyzer.
    public var enqueued: Int = 0
    /// Buffers the consumer was too slow to take. **Non-zero means audio was lost, and because
    /// `.bufferingNewest` evicts the OLDEST element it is the START of the utterance that went
    /// missing** (RECON §20). Callers must mark the transcript incomplete.
    public var dropped: Int = 0
    /// Buffers `AVAudioConverter` refused. Almost always a format mismatch after a route change.
    public var conversionFailures: Int = 0
    /// `AVAudioEngineConfigurationChange` notifications handled during the utterance. Any value
    /// above zero means the input device changed mid-sentence and audio was lost across the gap.
    public var deviceChanges: Int = 0
    /// Longest observed time spent inside the tap block, nanoseconds. Sanity check only: the
    /// budget is one buffer period, i.e. ≥100 ms.
    public var maxTapWorkNanos: UInt64 = 0

    public init() {}

    /// True when anything happened that could plausibly corrupt the transcript.
    public var isSuspect: Bool { dropped > 0 || conversionFailures > 0 || deviceChanges > 0 }
}

public enum AudioError: Error, Sendable {
    case microphoneDenied
    case engineStartFailed(String)
    case noInputDevice
    case converterUnavailable
}

// MARK: - Format resolution

/// Format helpers, kept separate because the hardware-format read has a crash trap in it.
enum AudioFormats {

    /// The system default input device's negotiated output format, read at runtime.
    ///
    /// CRASH TRAP (RECON §18): the idiomatic one-liner
    /// `AVAudioEngine().inputNode.outputFormat(forBus: 0)` **segfaults** — the temporary engine is
    /// released before `-[AVAudioNode outputFormatForBus:]` runs and `AVAudioIONodeImpl` then
    /// dereferences the dead engine. The engine must outlive every node access, hence the local
    /// binding plus `withExtendedLifetime`.
    static func hardwareInput() -> AVAudioFormat {
        let engine = AVAudioEngine()
        let format = engine.inputNode.outputFormat(forBus: 0)
        withExtendedLifetime(engine) {}
        return format
    }

    /// The format the analyzer actually accepts, measured on this machine: 16 kHz mono **Int16
    /// interleaved**, `isStandard == false`. Used only when the caller passes `targetFormat: nil`
    /// (i.e. `SpeechEngine.bestAudioFormat()` returned nothing).
    ///
    /// Deliberately NOT "fall back to the hardware format unchanged": the analyzer rejects
    /// 24/48 kHz Float32 non-interleaved outright, so passing it through would look like a
    /// working pipeline that transcribes nothing.
    static func analyzerFallback() -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)
    }

    /// True when the device is absent or not yet negotiated. `engine.start()` on this throws a
    /// useless CoreAudio code, so it is worth its own error case.
    static func isUsable(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }
}

// MARK: - Level maths (runs on the tap thread; allocation-free)

/// How an `AVAudioPCMBuffer`'s samples are actually laid out, derived from the buffer rather than
/// assumed.
///
/// This matters because the tap is installed with `format: nil` (RECON §18), so the format is
/// whatever the current device negotiated and can change under us on a route change. For a
/// **non-interleaved** buffer there is one plane per channel and `stride == 1`; for an
/// **interleaved** buffer there is exactly ONE plane and `stride == channelCount`. Walking
/// `0..<channelCount` planes on an interleaved buffer reads past the end of `channelData` — hence
/// `planes`, which is the only correct loop bound for both.
@inline(__always)
private func audioPlanes(_ buffer: AVAudioPCMBuffer) -> (planes: Int, samplesPerPlane: Int, total: Int)? {
    let frames = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)
    guard frames > 0, channels > 0 else { return nil }
    let planes = buffer.format.isInterleaved ? 1 : channels
    let samplesPerPlane = frames * buffer.stride
    return (planes, samplesPerPlane, frames * channels)
}

/// RMS and peak across every sample of one buffer, whatever its layout.
@inline(__always)
func audioRMSPeak(_ buffer: AVAudioPCMBuffer) -> (rms: Float, peak: Float) {
    guard let layout = audioPlanes(buffer) else { return (0, 0) }

    var sumSquares: Float = 0
    var peak: Float = 0

    if let data = buffer.floatChannelData {
        for plane in 0..<layout.planes {
            let samples = data[plane]
            for index in 0..<layout.samplesPerPlane {
                let value = samples[index]
                sumSquares += value * value
                let magnitude = abs(value)
                if magnitude > peak { peak = magnitude }
            }
        }
    } else if let data = buffer.int16ChannelData {
        let scale: Float = 1.0 / 32768.0
        for plane in 0..<layout.planes {
            let samples = data[plane]
            for index in 0..<layout.samplesPerPlane {
                let value = Float(samples[index]) * scale
                sumSquares += value * value
                let magnitude = abs(value)
                if magnitude > peak { peak = magnitude }
            }
        }
    } else {
        // Neither Float32 nor Int16 — no other common format reaches here, and reporting silence
        // is better than parking the meter on a stale reading.
        return (0, 0)
    }

    return (sqrt(sumSquares / Float(layout.total)), peak)
}

/// Amplitude → dBFS, floored at −140 rather than allowed to reach `-inf` on true digital silence.
///
/// The floor is **not** protecting the ballistics filter, which is what this comment used to claim.
/// Measured while writing AudioBufferMathTests: `D.meter.fraction(dbfs: -.infinity)` clamps to 0 and
/// `LevelBallistics.advance` then steps normally, so an `-inf` reading is survivable there (a `NaN`
/// would not be — `fraction` propagates it — but `log10f(0)` is `-inf`, not `NaN`).
///
/// What the floor protects is everything that reads `AudioFrame.dbfs`, which `LevelMeter` leaves
/// deliberately **raw** and unsmoothed so a meter can run its own ballistics off it: an `-inf` there
/// is an `-inf` in a numeric readout and in whatever a view multiplies it by. −140 also sits below
/// `D.meter.floorDBFS` (−54), so silence still reads as the bottom of the printed scale.
@inline(__always)
func audioDBFS(_ amplitude: Float) -> Float {
    amplitude > 1e-7 ? 20 * log10f(amplitude) : -140
}

// MARK: - Cross-thread shared state

/// State the tap thread writes and the main actor reads, held apart from any one `AVAudioEngine`
/// so it survives a device-change rebuild (and so `AudioCapture.levelSnapshot` can be
/// `nonisolated` — it reads this object, never the actor's own mutable properties).
final class CaptureShared: Sendable {
    let levels = Mutex(LevelSnapshot.silent)
    let stats = Mutex(CaptureStats())

    /// Reset at the start of each utterance so the counters describe one recording.
    func resetStats() { stats.withLock { $0 = CaptureStats() } }

    func noteDeviceChange() { stats.withLock { $0.deviceChanges += 1 } }
}

/// Bounded ring of converted, analyzer-format buffers captured while the gate was shut, so a
/// pre-warmed engine can flush the audio from just *before* the key-down and never clip the first
/// syllable (RECON, pre-roll snippet).
///
/// This cannot be a `Mutex<[AVAudioPCMBuffer]>`: `Mutex.withLock` takes its value as
/// `inout sending`, and `AVAudioPCMBuffer` is not `Sendable`, so the compiler correctly refuses to
/// let a task-isolated buffer be stored into shared state. An explicitly-locked box carries the
/// same guarantee — every access is under `lock`, and the buffers are ours by construction because
/// they came out of the converter, never off the tap.
final class PreRollRing: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var collecting = false

    /// Tap buffers are ≥100 ms by API contract, so a count is a ceiling on real duration.
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    var isCollecting: Bool {
        lock.lock(); defer { lock.unlock() }
        return collecting
    }

    func setCollecting(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        collecting = value
        if !value { buffers.removeAll(keepingCapacity: true) }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        buffers.append(buffer)
        if buffers.count > limit { buffers.removeFirst(buffers.count - limit) }
    }

    /// Take everything and reset. Called once per utterance, from `beginUtterance()`.
    func drain() -> [AVAudioPCMBuffer] {
        lock.lock(); defer { lock.unlock() }
        let taken = buffers
        buffers.removeAll(keepingCapacity: true)
        return taken
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        buffers.removeAll(keepingCapacity: false)
    }
}

/// `AVAudioConverterInputBlock` is annotated `NS_SWIFT_SENDABLE`, so under Swift 6 it is
/// `@Sendable` and can capture neither the non-`Sendable` `AVAudioPCMBuffer` nor a mutable
/// `var supplied = false` (RECON §17). Boxing both in an `@unchecked Sendable` class is the
/// documented answer, and it is genuinely race-free because `convert(to:error:withInputFrom:)`
/// calls the block synchronously on the calling thread before it returns.
final class OneShotFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if let buffer {
            self.buffer = nil
            outStatus.pointee = .haveData
            return buffer
        }
        outStatus.pointee = .noDataNow
        return nil
    }
}

// MARK: - The capture node

/// One `AVAudioEngine` plus the one `AVAudioConverter` that belongs to it.
///
/// `@unchecked Sendable` is correct here and is one of the two places in the project where it is:
/// every field is either immutable after `init` or guarded by a `Mutex`, and the class exists
/// precisely to be touched from the tap thread. RECON measured that thread as non-main,
/// `QOS_CLASS_DEFAULT`, `sched_priority` 31, `SCHED_OTHER` — a normal worker, **not** a real-time
/// render thread — so locking, allocating and yielding inside the tap are all safe (§21).
///
/// A node is never reused across a stop/start. RECON measured a cached stopped engine as *slower*
/// than a fresh one (22–40 ms of audio lost versus 14–27 ms), so there is no reason to keep one.
final class CaptureNode: @unchecked Sendable {

    /// Advisory only: `installTap` hard-clamps `bufferSize` to [100 ms, 400 ms] (RECON §19).
    /// 4800 frames is 200 ms at 24 kHz and 100 ms at 48 kHz, i.e. the clamp's own floor on the
    /// devices on this machine — asking for less achieves nothing.
    private static let requestedBufferFrames: AVAudioFrameCount = 4800

    /// The gate flag and the continuation live under ONE lock. Reading them separately is a race
    /// that shows up as a yield onto an already-finished stream.
    private struct Sink {
        var isOpen = false
        var continuation: AsyncStream<AnalyzerInput>.Continuation?
    }

    private let engine = AVAudioEngine()
    private let shared: CaptureShared
    private let sink = Mutex(Sink())

    /// Converted, analyzer-format buffers captured while the gate was shut, newest last.
    /// Only ever non-empty in pre-warm mode.
    private let preRoll: PreRollRing

    let hardwareFormat: AVAudioFormat
    let analyzerFormat: AVAudioFormat

    /// Exactly one converter per node, reused for every buffer of every utterance it serves.
    /// Creating one per buffer resets the polyphase resampler and inserts an audible
    /// discontinuity at every 100–400 ms boundary (RECON §17).
    private let converter: AVAudioConverter?

    /// `.bufferingNewest(n)` capacity, in buffers. Sized in *seconds* on purpose: `n` is a count
    /// of tap buffers, each ≥100 ms by API contract, and at 16 kHz mono Int16 (32 KB/s) even 100 s
    /// of headroom costs ~3 MB. A small `n` here is the difference between a complete transcript
    /// and one silently missing its first sentence (RECON §20).
    private let bufferedCount: Int

    /// Tap buffers per second of headroom. `installTap`'s `bufferSize` is hard-clamped to
    /// [100 ms, 400 ms] (RECON §19), so 100 ms is the floor and therefore the only safe divisor:
    /// assuming anything larger would under-size the queue on the very devices that deliver fastest.
    static let tapBufferFloorSeconds = 0.100

    /// The `.bufferingNewest` capacity for a given number of seconds of headroom.
    ///
    /// Exposed, and used by the initialiser below, so the "sized in seconds" requirement is pinned by
    /// a test rather than by a comment. It is load-bearing twice over now: the queue absorbs a
    /// consumer stall (RECON §20) *and* it holds the head of the utterance for the few hundred
    /// milliseconds between the microphone opening and the language being decided, during which there
    /// is deliberately no consumer at all.
    static func bufferedBufferCount(forSeconds seconds: Double) -> Int {
        max(8, Int(seconds / tapBufferFloorSeconds))
    }

    init(shared: CaptureShared,
         hardwareFormat: AVAudioFormat,
         analyzerFormat: AVAudioFormat,
         bufferedSeconds: Double = 100,
         preRollSeconds: Double = 0.5) throws {
        self.shared = shared
        self.hardwareFormat = hardwareFormat
        self.analyzerFormat = analyzerFormat
        self.bufferedCount = Self.bufferedBufferCount(forSeconds: bufferedSeconds)
        self.preRoll = PreRollRing(limit: max(1, Int((preRollSeconds / 0.100).rounded(.up))))

        // Conversion is not optional and it is not just a resample: hardware is 24 or 48 kHz
        // Float32 non-interleaved, the analyzer takes only 16 kHz Int16 *interleaved*
        // (RECON §17). Rate, depth and interleaving all change, in one converter.
        if hardwareFormat == analyzerFormat {
            self.converter = nil
        } else {
            guard let converter = AVAudioConverter(from: hardwareFormat, to: analyzerFormat) else {
                throw AudioError.converterUnavailable
            }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            self.converter = converter
        }
    }

    var needsConversion: Bool { converter != nil }
    var isRunning: Bool { engine.isRunning }

    // MARK: engine lifecycle

    /// Install the tap and start the engine. The orange microphone indicator lights here, which is
    /// why pre-warm is opt-in rather than the default (RECON §22).
    func startEngine() throws {
        guard !engine.isRunning else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)

        // `format: nil` means "use the bus's own format". Passing an explicit `AVAudioFormat`
        // after anything has changed the device throws an **uncatchable** ObjC exception
        // ("Failed to create tap due to format mismatch") that aborts the process — Swift cannot
        // catch NSException, so this is not defensible at the call site (RECON §18). The real
        // format is read off `buffer.format` inside the callback instead.
        input.installTap(onBus: 0, bufferSize: Self.requestedBufferFrames, format: nil) { [weak self] buffer, _ in
            self?.handleTap(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioError.engineStartFailed(String(describing: error))
        }
    }

    /// Stop the engine and tear the tap down. Safe to call more than once.
    func stopEngine() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        endUtterance()
        preRoll.clear()
    }

    // MARK: utterance gating

    /// Open the gate and return the stream to hand to `SpeechAnalyzer`.
    ///
    /// In pre-warm mode the buffers captured just before this call are flushed into the stream
    /// first, so the leading syllable the user spoke while pressing the key is not clipped. They
    /// are already in analyzer format and already in order, because the single converter has been
    /// running continuously since the engine started — which is why the pre-roll is kept
    /// post-conversion rather than as raw hardware frames.
    func beginUtterance() -> AsyncStream<AnalyzerInput> {
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingNewest(bufferedCount))

        shared.resetStats()

        let flushed = preRoll.drain()
        for buffer in flushed {
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        if !flushed.isEmpty {
            let frames = flushed.reduce(0) { $0 + Int($1.frameLength) }
            Log.audio.debug("flushed pre-roll: \(flushed.count) buffers, \(Double(frames) / self.analyzerFormat.sampleRate, format: .fixed(precision: 3)) s")
        }

        sink.withLock { sink in
            sink.continuation = continuation
            sink.isOpen = true
        }
        return stream
    }

    /// Close the gate and terminate the stream. Finishing the stream is what makes
    /// `SpeechAnalyzer.finalizeAndFinishThroughEndOfInput()` return rather than hang.
    func endUtterance() {
        let continuation = sink.withLock { sink -> AsyncStream<AnalyzerInput>.Continuation? in
            sink.isOpen = false
            let continuation = sink.continuation
            sink.continuation = nil
            return continuation
        }
        continuation?.finish()
    }

    var isGateOpen: Bool { sink.withLock { $0.isOpen } }

    /// Whether the node keeps converting into the pre-roll ring while the gate is shut. Only ever
    /// true in pre-warm mode; turning it off discards whatever was collected.
    func setCollectsPreRoll(_ collects: Bool) {
        preRoll.setCollecting(collects)
    }

    // MARK: the tap thread

    private func handleTap(_ buffer: AVAudioPCMBuffer) {
        let started = DispatchTime.now().uptimeNanoseconds

        // Metering runs whether or not the gate is open, so the meter can show that the
        // microphone is alive before the user commits to a recording.
        let (rms, peak) = audioRMSPeak(buffer)
        shared.levels.withLock { levels in
            levels.rmsDBFS = audioDBFS(rms)
            levels.peakDBFS = audioDBFS(peak)
            levels.seq &+= 1
        }

        guard isGateOpen || preRoll.isCollecting else { return }

        // Never yield or retain the tap's own buffer — always the converter's output, which is a
        // buffer we allocated (RECON, "COPY QUESTION, DEFINITIVE ANSWER").
        guard let converted = Self.convert(buffer, converter: converter, target: analyzerFormat) else {
            shared.stats.withLock { $0.conversionFailures += 1; $0.tapBuffers += 1 }
            return
        }

        guard let continuation = sink.withLock({ $0.isOpen ? $0.continuation : nil }) else {
            // Gate shut but pre-warming: park the converted buffer so `beginUtterance()` can
            // flush it. Bounded, so a long idle pre-warm cannot grow without limit.
            preRoll.append(converted)
            return
        }

        // Yielding straight from the tap is safe and measured: ≤50 µs against a ≥100 ms budget
        // (RECON §21). A lock-free ring plus a dispatch hop would only add latency and a second
        // failure mode.
        let result = continuation.yield(AnalyzerInput(buffer: converted))
        let finished = DispatchTime.now().uptimeNanoseconds

        shared.stats.withLock { stats in
            stats.tapBuffers += 1
            stats.maxTapWorkNanos = max(stats.maxTapWorkNanos, finished - started)
            switch result {
            case .enqueued:
                stats.enqueued += 1
            case .dropped:
                // `.bufferingNewest` evicts the OLDEST queued element, so this deletes the
                // BEGINNING of the utterance and reads downstream as a model failure (RECON §20).
                stats.dropped += 1
            case .terminated:
                break
            @unknown default:
                break
            }
        }
    }

    /// Convert one tap buffer into a buffer we own, or deep-copy it when no conversion is needed.
    static func convert(_ input: AVAudioPCMBuffer,
                        converter: AVAudioConverter?,
                        target: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else { return deepCopy(input) }

        // Capacity for a sample-rate change: ceil(inFrames * outSR/inSR) + slack. The polyphase
        // resampler can emit a frame or two beyond the ideal ratio on any given call; without the
        // slack you silently truncate audio (RECON, converter capacity note).
        let ratio = target.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        let feed = OneShotFeed(input)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            feed.next(outStatus)
        }

        switch status {
        case .haveData, .inputRanDry:
            // `.inputRanDry` is the NORMAL result of the one-buffer-in pattern — "here is
            // everything I could make from what you gave me". Treating it as an error throws away
            // every buffer (RECON §17).
            return output.frameLength > 0 ? output : nil
        case .endOfStream, .error:
            if let error { Log.audio.error("converter failed: \(error.localizedDescription, privacy: .public)") }
            return nil
        @unknown default:
            return nil
        }
    }

    /// Only reachable when hardware and analyzer formats happen to match exactly, which has never
    /// been observed on this machine. Kept so that path cannot yield the engine's own buffer.
    static func deepCopy(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let layout = audioPlanes(source),
              let destination = AVAudioPCMBuffer(pcmFormat: source.format,
                                                 frameCapacity: source.frameLength) else { return nil }
        destination.frameLength = source.frameLength

        if let from = source.floatChannelData, let to = destination.floatChannelData {
            for plane in 0..<layout.planes {
                memcpy(to[plane], from[plane], layout.samplesPerPlane * MemoryLayout<Float>.size)
            }
            return destination
        }
        if let from = source.int16ChannelData, let to = destination.int16ChannelData {
            for plane in 0..<layout.planes {
                memcpy(to[plane], from[plane], layout.samplesPerPlane * MemoryLayout<Int16>.size)
            }
            return destination
        }
        return nil
    }
}

// MARK: - AudioCapture

/// Microphone capture. Owns the `AVAudioEngine` and converts every buffer to the format the
/// analyzer wants.
///
/// Isolation: an `actor`, so all lifecycle calls serialise, but the two hot paths deliberately do
/// not go through the actor at all — the tap writes into `CaptureShared` under a `Mutex`, and
/// `levelSnapshot` reads it back `nonisolated`. That is what lets the main actor poll levels 60
/// times a second without an await.
///
/// There is intentionally **no input-device selection**. `AVAudioEngine` cannot be pinned to a
/// non-default input device on this OS: `inputFormat` reports the new rate while `outputFormat`
/// keeps the old one and `start()` then fails with −10868. The engine follows the system default
/// and is rebuilt wholesale when that changes (RECON, device-pinning trap).
public actor AudioCapture: LevelSource {

    /// Tap-visible state, outliving any individual engine so a rebuild does not lose the meter.
    private let shared = CaptureShared()

    private var node: CaptureNode?
    private var configurationObserver: NSObjectProtocol?

    /// Set by `prewarm`. When true the engine keeps running (and keeps filling the pre-roll)
    /// across `stop()`, and `start()` reuses it.
    private var isPrewarmed = false
    private var prewarmTargetFormat: AVAudioFormat?

    private var capturing = false

    /// Coalescing fan-out for `levels`. Multiple consumers are supported (the main window's meter,
    /// the HUD, the menu-bar extra) and each gets its own stream.
    private var levelConsumers: [UUID: AsyncStream<AudioFrame>.Continuation] = [:]
    private var levelPump: Task<Void, Never>?
    private var lastPublishedSeq: UInt64 = 0

    public init() {}

    // MARK: LevelSource

    /// The newest reading the tap wrote. `nonisolated` and lock-based on purpose — see the type
    /// comment on `LevelSource`.
    public nonisolated var levelSnapshot: LevelSnapshot {
        shared.levels.withLock { $0 }
    }

    /// Health counters for the current (or most recent) utterance. Also `nonisolated`, so the
    /// controller can read them straight after `stop()` without ordering against the actor.
    public nonisolated var statsSnapshot: CaptureStats {
        shared.stats.withLock { $0 }
    }

    // MARK: state

    public var isCapturing: Bool { capturing }

    /// True while the engine is running, whether or not an utterance is in progress. When this is
    /// true and `isCapturing` is false, the microphone indicator is lit for pre-warm.
    public var isEngineRunning: Bool { node?.isRunning ?? false }

    /// The format buffers are delivered in, once an engine exists.
    public var currentAnalyzerFormat: AVAudioFormat? { node?.analyzerFormat }

    // MARK: levels

    /// A stream of display frames, coalesced to at most `D.motion.needleTickHz` and de-duplicated
    /// against the tap's sequence number — so in practice it emits at the tap's own 2.5–10 Hz and
    /// goes quiet when nothing changes. **Never per-buffer ballistics**: the smoothing belongs to
    /// `LevelMeter` on the main actor (RECON §19).
    ///
    /// Each access returns a new stream; drop it to unsubscribe.
    public var levels: AsyncStream<AudioFrame> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AudioFrame>.makeStream(
            of: AudioFrame.self,
            // A meter only ever wants the newest frame; an unbounded buffer here would let a
            // stalled view accumulate stale levels.
            bufferingPolicy: .bufferingNewest(2))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeLevelConsumer(id) }
        }
        levelConsumers[id] = continuation
        // Prime the new consumer so a meter attached mid-utterance is not blank until the next
        // tap buffer arrives (up to 400 ms).
        continuation.yield(Self.frame(from: shared.levels.withLock { $0 }))
        startLevelPumpIfNeeded()
        return stream
    }

    private func removeLevelConsumer(_ id: UUID) {
        levelConsumers[id] = nil
        if levelConsumers.isEmpty { stopLevelPump() }
    }

    private func startLevelPumpIfNeeded() {
        guard levelPump == nil, !levelConsumers.isEmpty else { return }
        levelPump = Task { [weak self] in
            let interval = Duration.seconds(D.motion.needleTickInterval)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.publishLevelsIfChanged()
            }
        }
    }

    private func stopLevelPump() {
        levelPump?.cancel()
        levelPump = nil
    }

    private func publishLevelsIfChanged() {
        let snapshot = shared.levels.withLock { $0 }
        guard snapshot.seq != lastPublishedSeq else { return }
        lastPublishedSeq = snapshot.seq
        let frame = Self.frame(from: snapshot)
        for continuation in levelConsumers.values {
            continuation.yield(frame)
        }
    }

    /// Maps a raw dB reading onto the printed sweep. No filtering: `LevelMeter` and the design
    /// components integrate `dbfs` themselves against the render timeline, and smoothing here
    /// as well is how a needle ends up feeling dead (DESIGN-COMPONENTS §2).
    private static func frame(from snapshot: LevelSnapshot) -> AudioFrame {
        AudioFrame(rms: Float(D.meter.fraction(dbfs: Double(snapshot.rmsDBFS))),
                   peak: Float(D.meter.fraction(dbfs: Double(snapshot.peakDBFS))),
                   dbfs: snapshot.rmsDBFS)
    }

    // MARK: lifecycle

    /// Start the engine without opening an utterance stream.
    ///
    /// This is the opt-in low-latency mode, **not** the default (RECON §22): starting on key-down
    /// loses only 14–27 ms of real audio, well inside human press-then-speak reaction time,
    /// whereas a pre-warmed microphone keeps the orange indicator lit for the whole session — for
    /// a dictation tool that reads as "always listening" and is the likeliest reason a user
    /// uninstalls it. In exchange, pre-warm gets a ~0.5 s pre-roll for free, so the first syllable
    /// is never clipped.
    public func prewarm(targetFormat: AVAudioFormat?) async throws {
        try await ensureMicrophoneAccess()
        prewarmTargetFormat = targetFormat
        isPrewarmed = true
        let node = try buildNode(targetFormat: targetFormat)
        node.setCollectsPreRoll(true)
        try node.startEngine()
        installConfigurationObserverIfNeeded()
        startLevelPumpIfNeeded()
        Log.audio.info("""
            prewarmed: hw \(node.hardwareFormat.sampleRate, format: .fixed(precision: 0)) Hz \
            \(node.hardwareFormat.channelCount) ch -> analyzer \
            \(node.analyzerFormat.sampleRate, format: .fixed(precision: 0)) Hz int16 interleaved, \
            converting=\(node.needsConversion)
            """)
    }

    /// Begin an utterance. The returned stream ends when `stop()` is called.
    public func start(targetFormat: AVAudioFormat?) async throws -> AsyncStream<AnalyzerInput> {
        guard !capturing else {
            throw AudioError.engineStartFailed("start() called while already capturing")
        }
        try await ensureMicrophoneAccess()

        // In pre-warm mode reuse the running engine; the pre-roll is the whole point. Otherwise
        // build a fresh one — a cached *stopped* engine measured slower than a new one
        // (22–40 ms of audio lost versus 14–27 ms), so there is nothing to gain by keeping it.
        let node: CaptureNode
        if isPrewarmed, let running = self.node, running.isRunning {
            node = running
        } else {
            self.node?.stopEngine()
            node = try buildNode(targetFormat: targetFormat)
            node.setCollectsPreRoll(false)
            try node.startEngine()
            installConfigurationObserverIfNeeded()
        }

        let stream = node.beginUtterance()
        capturing = true
        startLevelPumpIfNeeded()
        Log.audio.info("capture started (prewarmed=\(self.isPrewarmed))")
        return stream
    }

    /// End the utterance. Finishing the stream is what lets the analyzer finalize; without it
    /// `finalizeAndFinishThroughEndOfInput()` waits forever.
    public func stop() async {
        guard let node else {
            capturing = false
            return
        }
        node.endUtterance()
        capturing = false

        if isPrewarmed {
            // Keep the engine (and the pre-roll) alive for the next key-down.
            node.setCollectsPreRoll(true)
        } else {
            node.stopEngine()
            self.node = nil
            stopLevelPump()
        }

        let stats = shared.stats.withLock { $0 }
        if stats.isSuspect {
            Log.audio.warning("""
                capture finished SUSPECT: buffers=\(stats.tapBuffers) enqueued=\(stats.enqueued) \
                dropped=\(stats.dropped) convFail=\(stats.conversionFailures) \
                deviceChanges=\(stats.deviceChanges)
                """)
        } else {
            Log.audio.info("""
                capture finished: buffers=\(stats.tapBuffers) enqueued=\(stats.enqueued) \
                maxTapWork=\(Double(stats.maxTapWorkNanos) / 1000, format: .fixed(precision: 1)) us
                """)
        }
    }

    /// Full shutdown: engine gone, tap removed, observer removed, level streams finished.
    public func teardown() async {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        node?.stopEngine()
        node = nil
        capturing = false
        isPrewarmed = false
        prewarmTargetFormat = nil
        stopLevelPump()
        for continuation in levelConsumers.values { continuation.finish() }
        levelConsumers.removeAll()
        shared.levels.withLock { $0 = .silent }
        Log.audio.info("audio torn down")
    }

    // MARK: node construction

    private func buildNode(targetFormat: AVAudioFormat?) throws -> CaptureNode {
        let hardware = AudioFormats.hardwareInput()
        guard AudioFormats.isUsable(hardware) else {
            Log.audio.error("no usable input device (format \(hardware))")
            throw AudioError.noInputDevice
        }

        let analyzer: AVAudioFormat
        if let targetFormat {
            analyzer = targetFormat
        } else {
            // `SpeechEngine.bestAudioFormat()` returned nil. Fall back to the format measured on
            // this machine rather than to the hardware format, which the analyzer rejects.
            guard let fallback = AudioFormats.analyzerFallback() else {
                throw AudioError.converterUnavailable
            }
            Log.audio.warning("no analyzer format supplied; using 16 kHz Int16 interleaved fallback")
            analyzer = fallback
        }

        let node = try CaptureNode(shared: shared,
                                   hardwareFormat: hardware,
                                   analyzerFormat: analyzer)
        self.node = node
        return node
    }

    // MARK: device / route changes

    private func installConfigurationObserverIfNeeded() {
        guard configurationObserver == nil else { return }
        // Use the typed constant. Its rawValue is "AVAudioEngineConfigurationChangeNotification",
        // NOT "AVAudioEngineConfigurationChange" — hand-typing the obvious string yields an
        // observer that never fires and an engine that stays stopped forever (RECON, notification
        // name trap).
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // AVAudioEngine.h warns explicitly that the engine must not be deallocated inside this
            // handler — it arrives on the engine's internal dispatch queue, and a synchronous
            // teardown from there deadlocks. Hopping to the main actor and then into this actor
            // guarantees every touch of the engine happens off that queue.
            //
            // `weak` is load-bearing, not defensive: NotificationCenter retains this block, and
            // the returned token is stored on `self`, so a strong capture would make the actor
            // immortal and keep the microphone engine alive for the life of the process.
            Task { @MainActor in
                await self?.handleConfigurationChange()
            }
        }
    }

    /// Rebuild everything after a route change.
    ///
    /// AVFAudio stops the engine itself when the hardware channel count or sample rate changes
    /// (AirPods connecting at 24 kHz over a built-in mic at 48 kHz, say). The input node's
    /// negotiated format cannot be renegotiated in place — every attempt to point a live engine at
    /// a device with a different rate failed with −10868 — so the only reliable response is to
    /// throw the whole node away and build a new `AVAudioEngine` *and* a new `AVAudioConverter`.
    ///
    /// An in-flight utterance is deliberately **continued** rather than cancelled: the new node
    /// converts into the same analyzer format, so the stream stays valid and the user keeps the
    /// words either side of the gap. The gap itself is recorded in `deviceChanges` so the
    /// transcript can be flagged. (RECON lists the finalize-versus-cancel question as unresolved;
    /// this is the choice that loses the least.)
    private func handleConfigurationChange() async {
        guard node != nil else { return }
        shared.noteDeviceChange()
        Log.audio.warning("AVAudioEngineConfigurationChange — rebuilding engine and converter")

        let wasCapturing = capturing
        let previous = node
        previous?.endUtterance()
        previous?.stopEngine()
        node = nil

        let target = prewarmTargetFormat ?? previous?.analyzerFormat
        do {
            let rebuilt = try buildNode(targetFormat: target)
            rebuilt.setCollectsPreRoll(isPrewarmed && !wasCapturing)
            try rebuilt.startEngine()
            if wasCapturing {
                // The old stream's continuation died with the old node, so the caller's stream has
                // already finished. Reflect that: the controller will finalize the utterance.
                capturing = false
                Log.audio.error("device changed mid-utterance; utterance terminated early")
            }
        } catch {
            capturing = false
            Log.audio.error("engine rebuild failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: permission

    /// Microphone permission is checked here and only *requested* when undetermined.
    ///
    /// The prompt requires `NSMicrophoneUsageDescription` in the bundle or TCC terminates the
    /// process, and RECON found that TCC identity differs between a terminal launch and a
    /// LaunchServices launch of the same binary — so this path is only meaningful from the real
    /// .app. Starting the engine without authorisation does not fail; it delivers silence, which
    /// is why the check is up front rather than after `engine.start()`.
    private func ensureMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw AudioError.microphoneDenied
            }
        case .denied, .restricted:
            throw AudioError.microphoneDenied
        @unknown default:
            throw AudioError.microphoneDenied
        }
    }
}
