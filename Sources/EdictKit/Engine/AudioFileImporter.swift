//
//  AudioFileImporter.swift
//  Turns an audio *or video* file on disk into the `AsyncStream<AnalyzerInput>` that
//  `SpeechEngine.transcribe(input:onUpdate:)` already consumes.
//
//  Why `AVAssetReader` and not `AVAudioFile`:
//
//  1. `AVAssetReader` opens video containers (mp4, mov, m4v) as well as audio ones, so the video
//     case costs nothing extra — the reader just pulls the first audio track out of the container.
//  2. It feeds the one engine route the project has already debugged, so there is no second
//     transcription code path to keep correct.
//  3. It sidesteps a hard trap. RECON records that `SpeechAnalyzer(inputAudioFile:)` *already
//     starts analysis*, so calling `analyzeSequence(from:)` afterwards is an unrecoverable
//     `EXC_BREAKPOINT` (process exit 133) rather than a catchable error. We never touch that
//     API pairing.
//  4. Reading a file gives natural progress reporting, which an hour-long recording needs.
//
//  Data flow:
//
//      AVURLAsset ─▶ AVAssetReader ─▶ AVAssetReaderTrackOutput (linear PCM @ analyzer format)
//                        │
//                        ▼
//                  CMSampleBuffer ─▶ AVAudioPCMBuffer ─▶ [one reused AVAudioConverter, only if
//                        │                                the reader could not deliver the
//                        │                                target format itself]
//                        ▼
//                  ~100 ms chunks ─▶ bounded channel (capacity in SECONDS) ─▶ AsyncStream
//
//  The channel is **pull-driven with back-pressure**, not `.bufferingNewest`. RECON §20 measured
//  `.bufferingNewest(n)` evicting the OLDEST queued element, which silently deletes the beginning
//  of the transcript and reads downstream as a model failure. A microphone cannot be told to wait,
//  so the live path has no choice but to size that buffer generously and count drops. A *file*
//  can be told to wait, so here the producer blocks instead of discarding, which makes that failure
//  mode structurally impossible rather than merely unlikely. The capacity is still expressed in
//  seconds, and drops are still counted — see `ImportStats.dropped`, which can only become
//  non-zero if the consumer disappears mid-file.
//

import AVFoundation
import CoreMedia
import Foundation
import Speech
import UniformTypeIdentifiers

// MARK: - Public value types

/// What a file actually turned out to be, read off the asset rather than guessed from its extension.
///
/// Reported before any audio is decoded so the UI can show duration and format on the queue row,
/// and so a file that cannot work (no audio track, DRM) is rejected up front instead of halfway
/// through a ten-minute transcription.
/// The extension of a filename, alone, for the log.
///
/// Filenames go out `privacy: .private(mask: .hash)`: that keeps every line of one import
/// correlatable without printing "HR grievance call 2026-08-24.m4a" into a log that any sysdiagnose
/// collects verbatim. But the question a failed import actually raises is "what format was it", and
/// that answer is not identifying — so it rides `.public` beside the hash.
///
/// A free function because `AudioFileInfo` and the `AudioFileImporter` actor each carry their own
/// `filename`, and two copies of three lines is how the two drift apart.
func audioFileKind(of filename: String) -> String {
    let ext = (filename as NSString).pathExtension.lowercased()
    return ext.isEmpty ? "no extension" : ext
}

public struct AudioFileInfo: Sendable, Hashable {
    /// The file the user picked or dropped.
    public var url: URL
    /// Last path component only. Everything user-visible uses this — a home directory is nobody's
    /// business, and `TranscriptSource.imported(filename:)` documents the same rule.
    public var filename: String

    /// The asset's real duration in seconds, loaded with
    /// `AVURLAssetPreferPreciseDurationAndTimingKey` so a VBR MP3 does not report an estimate.
    public var duration: TimeInterval
    /// Sample rate of the source audio track, before we resample it to the analyzer's 16 kHz.
    public var sampleRate: Double
    /// Channel count of the source audio track, before we downmix it to mono.
    public var channelCount: UInt32
    /// Human-readable codec name ("AAC", "MP3", "Linear PCM", …) or the raw four-character code
    /// when it is something we do not have a name for.
    public var codec: String
    /// True when the container also carries video. Purely informational — we read the audio track
    /// either way — but worth showing, because "this is a video" surprises people.
    public var hasVideo: Bool
    /// Size on disk, when the file system would tell us.
    public var byteCount: Int64?

    public init(
        url: URL,
        filename: String,
        duration: TimeInterval,
        sampleRate: Double,
        channelCount: UInt32,
        codec: String,
        hasVideo: Bool,
        byteCount: Int64? = nil
    ) {
        self.url = url
        self.filename = filename
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.codec = codec
        self.hasVideo = hasVideo
        self.byteCount = byteCount
    }

    /// "AAC · 44.1 kHz stereo" — one line for a queue row.
    public var formatSummary: String {
        let rate = sampleRate > 0
            ? String(format: "%g kHz", (sampleRate / 1000 * 10).rounded() / 10)
            : "unknown rate"
        let channels: String
        switch channelCount {
        case 0: channels = ""
        case 1: channels = "mono"
        case 2: channels = "stereo"
        default: channels = "\(channelCount) ch"
        }
        return [codec, rate, channels].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Health counters for one file. The same reasoning as `CaptureStats`: a garbled transcript out of
/// this pipeline is almost always a dropped or unconverted buffer, not the speech model, so the
/// numbers are surfaced rather than logged and forgotten.
public struct ImportStats: Sendable, Hashable {
    /// Sample buffers taken from `AVAssetReaderTrackOutput`.
    public var readerBuffers: Int = 0
    /// ~100 ms chunks handed to the analyzer.
    public var chunks: Int = 0
    /// Frames handed to the analyzer, at `sampleRate`.
    public var frames: Int = 0
    /// Analyzer-format sample rate the frame count is denominated in.
    public var sampleRate: Double = 0
    /// Audio the consumer never received because it went away mid-file. Non-zero means the
    /// transcript is missing its **tail** (the channel is FIFO with back-pressure, so unlike the
    /// live path's `.bufferingNewest` it can never lose the beginning).
    public var dropped: Int = 0
    /// Buffers `AVAudioConverter` refused. Non-zero means a format the converter could not handle,
    /// e.g. a multichannel layout the reader also declined to downmix.
    public var conversionFailures: Int = 0
    /// Wall-clock seconds from the first read to the last chunk handed over.
    public var readWallSeconds: Double = 0

    public init() {}

    /// Seconds of audio actually delivered to the analyzer.
    public var deliveredSeconds: Double {
        sampleRate > 0 ? Double(frames) / sampleRate : 0
    }

    /// How much faster than realtime the *read + convert* stage ran. This is the decode ceiling,
    /// not the end-to-end transcription speed — with back-pressure the reader is paced by the
    /// analyzer, so in a live run this number converges on the whole pipeline's throughput.
    public var realtimeFactor: Double {
        readWallSeconds > 0 ? deliveredSeconds / readWallSeconds : 0
    }

    /// True when something happened that could plausibly have truncated the transcript.
    public var isSuspect: Bool { dropped > 0 || conversionFailures > 0 }
}

/// Everything that can go wrong before or during a file read, each case distinct because each one
/// needs a different sentence in the UI.
public enum AudioImportError: Error, Sendable, Hashable, LocalizedError {
    /// The container parsed but carries no audio track — a silent screen recording, or a still image.
    case noAudioTrack(filename: String)
    /// FairPlay / iTunes-protected content. `AVAsset.hasProtectedContent` is true, and no amount of
    /// reader configuration will get samples out of it.
    case drmProtected(filename: String)
    /// The file exists but the OS will not read it: missing, unreadable permissions, or truncated.
    case unreadable(filename: String, reason: String)
    /// The bytes are readable but AVFoundation does not recognise the container or codec.
    case unsupportedContainer(filename: String, reason: String)
    /// `AVAssetReader` went to `.failed` partway through. Whatever was already transcribed is still
    /// good; the tail is missing.
    case readFailed(filename: String, reason: String)
    /// `cancel()` was called, or the consuming task was cancelled.
    case cancelled(filename: String)

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack(let filename):
            "“\(filename)” has no audio track."
        case .drmProtected(let filename):
            "“\(filename)” is copy-protected and cannot be transcribed."
        case .unreadable(let filename, let reason):
            "“\(filename)” could not be read: \(reason)"
        case .unsupportedContainer(let filename, let reason):
            "“\(filename)” is not an audio or video file Edict can open: \(reason)"
        case .readFailed(let filename, let reason):
            "Reading “\(filename)” stopped early: \(reason)"
        case .cancelled(let filename):
            "Transcription of “\(filename)” was cancelled."
        }
    }

    /// The file this error is about, for a queue row that already knows which item it is.
    public var filename: String {
        switch self {
        case .noAudioTrack(let filename),
             .drmProtected(let filename),
             .cancelled(let filename):
            filename
        case .unreadable(let filename, _),
             .unsupportedContainer(let filename, _),
             .readFailed(let filename, _):
            filename
        }
    }
}

// MARK: - Decoded audio

/// A whole file decoded into the analyzer's own format and held in memory.
///
/// Only the dual-pass import asks for this, and only because it has no alternative: `SpeechSegmenter`
/// takes a whole buffer (its gate is a percentile of the file's own energy distribution, so it cannot
/// be computed from a sliding window), and each section then has to be handed to the analyzer twice,
/// which means the samples must still be there after the reader has finished.
///
/// **The cost is linear and worth stating plainly.** 16 kHz mono Int16 is 32 KB per second of audio:
/// 0.5 MB for the 17-second bilingual fixture, 12 MB for a ten-minute call, about 134 MB for the
/// 70-minute meeting. That is the main reason dual pass is off by default. The ordinary single-pass
/// import is unchanged and still streams with a flat ~8-second window.
public struct DecodedAudio: Sendable {
    /// Interleaved — which for one channel means plain — Int16 at `sampleRate`.
    public var samples: [Int16]
    public var sampleRate: Double
    /// Read counters for the decode, so a caller can report throughput and spot dropped audio.
    public var stats: ImportStats
    /// Why the decode stopped early, or `nil` when the whole file was read. The samples up to that
    /// point are real.
    public var failure: AudioImportError?

    public init(samples: [Int16], sampleRate: Double, stats: ImportStats, failure: AudioImportError? = nil) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.stats = stats
        self.failure = failure
    }

    public var duration: TimeInterval {
        sampleRate > 0 ? Double(samples.count) / sampleRate : 0
    }

    /// Frames for `[start, end)` in seconds, clamped to what was actually decoded.
    public func range(from start: TimeInterval, to end: TimeInterval) -> Range<Int> {
        guard sampleRate > 0, !samples.isEmpty else { return 0..<0 }
        let lo = min(samples.count, max(0, Int((start * sampleRate).rounded(.down))))
        let hi = min(samples.count, max(lo, Int((end * sampleRate).rounded(.up))))
        return lo..<hi
    }
}

/// Enough decoded audio to ask `SpeechSegmenter` how many seconds of it are speech, and nothing else.
///
/// **Why the single-pass path collects this at all.** `RecognitionQuality` measures words per minute,
/// and the denominator decides whether a quiet recording is *badly recognised* or merely *quiet*. Its
/// preferred denominator is detected speech; its fallback is wall clock. On wall clock a two-minute
/// voice memo with ninety seconds of thinking-pauses in it reads as 40 wpm and gets flagged, which is
/// exactly the false alarm that teaches users to ignore the real ones.
///
/// **Why it is capped.** Accumulating the samples costs 32 KB per second, so the budget is a real
/// ceiling and past it this comes back `nil` and the assessment falls back to wall clock. That is the
/// right way round: the wall-clock estimate is *most* wrong on short files (where a single silent
/// stretch is a large share of the timeline) and converges on long ones (an hour-long meeting with
/// 40 % dead air still reads about 90 wpm, comfortably unflagged). So the accurate basis is spent
/// where it changes the answer.
public struct SpeechProbe: Sendable {
    public var samples: [Int16]
    public var sampleRate: Double

    public init(samples: [Int16], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

// MARK: - Importer

/// One file, read once. Create an instance per file and throw it away afterwards.
///
/// Single-use by design, for the same reason `TranscriptionSession` is: an `AVAssetReader` cannot be
/// rewound (`startReading()` may only be called once), and the reused `AVAudioConverter` carries
/// resampler state that belongs to exactly one source format.
public actor AudioFileImporter {

    /// Content types worth accepting from a drag or a file picker. `public.audio` and `public.movie`
    /// cover every concrete type that conforms to them — m4a, mp3, wav, aiff, caf, mp4, mov, m4v —
    /// so enumerating extensions here would only be a list to forget to update. Whether the file
    /// *really* works is decided by `inspect(url:)`, not by its type.
    public static let supportedContentTypes: [UTType] = [.audio, .movie, .audiovisualContent]

    private let url: URL
    private let filename: String
    /// The format the analyzer accepts. RECON §17: 16 kHz mono **Int16 interleaved** is the only
    /// thing the streaming path takes, and it is both a rate change and a depth + interleaving
    /// change from anything a file will contain.
    private let target: AVAudioFormat
    /// ~100 ms of target-format audio. Small enough that the engine emits volatile results steadily
    /// rather than in half-second lurches; large enough that we are nowhere near per-buffer overhead.
    private let chunkFrames: AVAudioFrameCount
    /// Channel capacity, expressed in seconds of audio rather than "a small n" (RECON §20). At
    /// 16 kHz mono Int16 — 32 KB/s — even a very generous window costs a couple of megabytes.
    private let bufferedSeconds: Double

    private var info: AudioFileInfo?
    private var reader: AVAssetReader?
    private var trackOutput: AVAssetReaderTrackOutput?
    /// Exactly one converter for the whole file. Creating one per buffer resets the polyphase
    /// resampler and inserts a discontinuity at every buffer boundary (RECON §17).
    private var converter: AVAudioConverter?
    /// Partially-filled chunk waiting for more frames. Actor-isolated, so the non-`Sendable`
    /// `AVAudioPCMBuffer` never leaves this instance until it is wrapped in an `AnalyzerInput`.
    private var accumulator: AVAudioPCMBuffer?
    private var accumulated: AVAudioFrameCount = 0

    private var channel: ChunkChannel?
    private var producer: Task<Void, Never>?
    private var stats = ImportStats()
    private var isCancelled = false
    /// Set when the reader failed partway through. The stream is non-throwing, so the failure has
    /// to be collected here and read back by the caller once the stream ends.
    private var failure: AudioImportError?

    private var lastProgressAt: ContinuousClock.Instant?
    private var lastProgressValue: Double = -1

    /// Ceiling on the speech probe, in samples. See `SpeechProbe`.
    private let probeBudgetSamples: Int
    /// Target-format samples kept for the probe. Discarded the moment the budget is exceeded, so the
    /// high-water mark is the budget and not one chunk more.
    private var probeSamples: [Int16] = []
    private var probeOverflowed = false

    /// - Parameters:
    ///   - analyzerFormat: `SpeechEngine.bestAudioFormat()`. `nil` falls back to 16 kHz mono Int16,
    ///     which is what that call has always returned on this machine.
    ///   - chunkSeconds: size of the buffers handed to the analyzer.
    ///   - bufferedSeconds: read-ahead window. The reader runs this far in front of the analyzer and
    ///     then waits, which is what keeps memory flat on an hour-long file.
    ///   - speechProbeBudgetBytes: how much decoded audio may be retained for the recognition-quality
    ///     probe. 48 MB is 25 minutes at 16 kHz mono Int16; past it the probe is abandoned and
    ///     `RecognitionQuality` falls back to wall clock. Zero disables the probe entirely.
    public init(
        url: URL,
        analyzerFormat: AVAudioFormat?,
        chunkSeconds: Double = 0.100,
        bufferedSeconds: Double = 8,
        speechProbeBudgetBytes: Int = 48 << 20
    ) {
        self.url = url
        self.filename = url.lastPathComponent
        let format = analyzerFormat
            ?? AudioFormats.analyzerFallback()
            // Unreachable in practice: the fallback initialiser only fails on a nonsensical
            // rate/channel pair. Constructing the same thing again keeps `target` non-optional so
            // every downstream use is force-unwrap-free.
            ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
        self.target = format
        self.chunkFrames = max(160, AVAudioFrameCount((format.sampleRate * max(0.010, chunkSeconds)).rounded()))
        self.bufferedSeconds = max(0.5, bufferedSeconds)
        self.probeBudgetSamples = max(0, speechProbeBudgetBytes) / MemoryLayout<Int16>.size
        self.stats.sampleRate = format.sampleRate
    }

    // MARK: - Inspection

    /// Everything about the file that can be known without decoding a single sample.
    ///
    /// Static and cheap on purpose: drag-and-drop wants to reject a bad file while the pointer is
    /// still over the window, long before anything is enqueued.
    public static func inspect(url: URL) async throws -> AudioFileInfo {
        let filename = url.lastPathComponent

        // `AVURLAsset` is perfectly happy to be constructed for a path that does not exist and
        // only fails later with an opaque -11800, so check the file system first and give the user
        // a sentence they can act on.
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw AudioImportError.unreadable(filename: filename, reason: "the file no longer exists")
        }
        guard FileManager.default.isReadableFile(atPath: url.path(percentEncoded: false)) else {
            throw AudioImportError.unreadable(filename: filename, reason: "Edict does not have permission to read it")
        }

        // Precise timing matters: without it a VBR MP3 reports an *estimated* duration, which makes
        // every progress fraction wrong and can leave a long import stuck at "97%".
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )

        let isReadable: Bool
        let isProtected: Bool
        let duration: CMTime
        do {
            (isReadable, isProtected, duration) = try await asset.load(.isReadable, .hasProtectedContent, .duration)
        } catch {
            throw Self.classify(error, filename: filename)
        }

        // Checked before readability: a FairPlay asset can report itself readable and then hand out
        // zero samples, which would otherwise surface as "0 words transcribed" with no explanation.
        if isProtected { throw AudioImportError.drmProtected(filename: filename) }
        guard isReadable else {
            throw AudioImportError.unsupportedContainer(
                filename: filename,
                reason: "AVFoundation cannot read this container"
            )
        }

        let audioTracks: [AVAssetTrack]
        let videoTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw Self.classify(error, filename: filename)
        }

        guard let track = audioTracks.first else {
            throw AudioImportError.noAudioTrack(filename: filename)
        }

        var sampleRate: Double = 0
        var channels: UInt32 = 0
        var codec = "Unknown"
        if let descriptions = try? await track.load(.formatDescriptions),
           let description = descriptions.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
            sampleRate = asbd.pointee.mSampleRate
            channels = asbd.pointee.mChannelsPerFrame
            codec = Self.codecName(asbd.pointee.mFormatID)
        }

        let seconds = duration.isNumeric ? CMTimeGetSeconds(duration) : 0
        let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map(Int64.init)

        return AudioFileInfo(
            url: url,
            filename: filename,
            duration: max(0, seconds),
            sampleRate: sampleRate,
            channelCount: channels,
            codec: codec,
            hasVideo: !videoTracks.isEmpty,
            byteCount: byteCount
        )
    }

    /// Inspect the file and build the reader, without decoding anything yet.
    ///
    /// Split out from `start` so the queue can show duration and format on a row while it is still
    /// `queued`, and so a bad file fails fast.
    @discardableResult
    public func open() async throws -> AudioFileInfo {
        if let info { return info }
        if isCancelled { throw AudioImportError.cancelled(filename: filename) }

        let info = try await Self.inspect(url: url)
        self.info = info

        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioImportError.noAudioTrack(filename: filename)
        }

        // Two attempts, in order of preference.
        //
        // First, ask the reader itself for linear PCM at the analyzer's format: it then resamples
        // and downmixes internally and no `AVAudioConverter` is needed at all. Every container
        // tested here obliges, including a 6-channel WAV.
        //
        // Second, if it will not, decode to PCM at the track's own rate and channel count and let
        // one reused `AVAudioConverter` finish the job. Verified by forcing this branch: identical
        // transcripts for m4a, 44.1 kHz stereo WAV, 48 kHz AIFF, 5.1 WAV, mp4 and a 377 s file,
        // with the converter's priming costing ~90 ms off the head of the file.
        //
        // `startReading()` is the acceptance test rather than `canAdd` alone, because a reader can
        // accept an output configuration and only fail once it tries to honour it. It may only be
        // called once per reader and a failed reader stays failed, so each attempt gets a fresh
        // `AVAssetReader`.
        let attempts: [(label: String, settings: [String: Any])] = [
            ("analyzer format", Self.pcmSettings(for: target)),
            ("native rate, local conversion", Self.nativePCMSettings()),
        ]
        var lastReason = "no readable PCM output could be configured for this audio track"

        for attempt in attempts {
            let reader: AVAssetReader
            do {
                reader = try AVAssetReader(asset: asset)
            } catch {
                throw Self.classify(error, filename: filename)
            }
            guard let output = Self.makeOutput(track: track, settings: attempt.settings),
                  reader.canAdd(output) else {
                lastReason = "the reader rejected \(attempt.label)"
                continue
            }
            reader.add(output)
            guard reader.startReading() else {
                lastReason = reader.error?.localizedDescription ?? "the reader refused to start"
                reader.cancelReading()
                continue
            }

            self.reader = reader
            self.trackOutput = output
            Log.audio.info(
                """
                import \(self.filename, privacy: .private(mask: .hash)) opened via \(attempt.label, privacy: .public): \
                \(info.formatSummary, privacy: .public) \
                \(String(format: "%.1f", info.duration), privacy: .public)s \
                video=\(info.hasVideo ? "yes" : "no", privacy: .public)
                """
            )
            return info
        }

        throw AudioImportError.unsupportedContainer(filename: filename, reason: lastReason)
    }

    // MARK: - Reading

    /// Start decoding and return the stream to hand straight to
    /// `SpeechEngine.transcribe(input:onUpdate:)`.
    ///
    /// - Parameter onProgress: fraction of the file **handed to the transcriber**, 0…1, coalesced to
    ///   roughly 10 Hz. Called off the main actor; hop if it touches UI.
    ///
    ///   This is read progress, not analysis progress, and on this machine the two are three orders
    ///   of magnitude apart: measured decode throughput is 570–4300x realtime (6 s file in 10 ms,
    ///   377 s file in 90 ms) against ~15x realtime end to end. `SpeechEngine.transcribe` feeds the
    ///   analyzer through an unbounded `AsyncStream`, so it drains this stream as fast as we can fill
    ///   it and back-pressure never reaches us — which means no producer-side signal can report how
    ///   far the *model* has got. Treat this as "audio queued", show live text for liveness while it
    ///   sits at 1.0, and see `ImportQueue.Phase`.
    public func start(
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> AsyncStream<AnalyzerInput> {
        if channel != nil { throw AudioImportError.readFailed(filename: filename, reason: "already started") }
        let info = try await open()
        guard reader != nil, trackOutput != nil else {
            throw AudioImportError.unreadable(filename: filename, reason: "the reader was not configured")
        }
        if isCancelled { throw AudioImportError.cancelled(filename: filename) }

        // Capacity in seconds → capacity in chunks. Never smaller than 4, so a pathological
        // `chunkSeconds` cannot degenerate into a lock-step producer/consumer handshake.
        let chunkSeconds = Double(chunkFrames) / target.sampleRate
        let capacity = max(4, Int((bufferedSeconds / max(0.001, chunkSeconds)).rounded(.up)))
        let channel = ChunkChannel(capacity: capacity)
        self.channel = channel

        // The reader and its output stay in actor storage rather than being captured by the task:
        // both are non-`Sendable`, so handing them to a closure that runs elsewhere is exactly what
        // Swift 6 rejects ("sending 'reader' risks causing data races"). `pump` reads them back
        // under the actor instead.
        let duration = info.duration
        producer = Task { [weak self] in
            await self?.pump(duration: duration, onProgress: onProgress)
        }

        // Pull-driven: each `take()` is one ~100 ms chunk, and the producer is only allowed to run
        // `capacity` chunks ahead of it. That is what makes RECON §20's silent oldest-element
        // eviction impossible here rather than merely unlikely.
        return AsyncStream(
            unfolding: { await channel.take() },
            // The consumer's task was cancelled, so nothing will ever read the ring again.
            onCancel: { channel.finish(discardingQueued: true) }
        )
    }

    /// Stop mid-file, leaving no reader running.
    ///
    /// Safe to call at any point, including before `start` and more than once. The consumer's
    /// stream ends normally; the caller distinguishes "finished" from "cancelled" by reading
    /// `readFailure` afterwards.
    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        // Finishing the channel first unblocks a producer parked in `put`, so the read loop can see
        // the cancel flag and tear the reader down itself. Cancelling the reader from here instead
        // would race the loop's `copyNextSampleBuffer`. This is the one path that discards what is
        // still queued: the user asked for it to stop, so the read-ahead window is not wanted.
        channel?.finish(discardingQueued: true)
        producer?.cancel()
        if failure == nil { failure = .cancelled(filename: filename) }
        Log.audio.info("import \(self.filename, privacy: .private(mask: .hash)): cancelled")
    }

    /// Counters for the finished (or abandoned) read. Read after the stream ends.
    public var statistics: ImportStats { stats }

    /// Why the read stopped early, or `nil` when the whole file was delivered.
    ///
    /// The stream has to be non-throwing because that is what `SpeechEngine.transcribe` takes, so a
    /// mid-file failure can only end the stream. Whatever the analyzer already committed is real
    /// text and worth keeping — the caller decides whether to save it with a warning or discard it.
    public var readFailure: AudioImportError? { failure }

    /// The file as it was inspected, once `open()` or `start()` has run.
    public var fileInfo: AudioFileInfo? { info }

    // MARK: - The read loop

    private func pump(
        duration: TimeInterval,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async {
        guard let reader, let output = trackOutput else { return }
        let began = ContinuousClock.now
        defer {
            let elapsed = ContinuousClock.now - began
            stats.readWallSeconds =
                Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        }

        while !isCancelled, !Task.isCancelled {
            guard let sample = output.copyNextSampleBuffer() else { break }
            stats.readerBuffers += 1

            report(progress: Self.fraction(of: sample, duration: duration), onProgress: onProgress)

            guard let decoded = pcmBuffer(from: sample) else {
                stats.conversionFailures += 1
                continue
            }
            guard let converted = convertToTarget(decoded) else {
                stats.conversionFailures += 1
                continue
            }
            if !(await deliver(chunksFrom: converted)) { break }
        }

        // Flush the partial trailing chunk before deciding how this ended, or the last <100 ms of
        // every file would be silently discarded.
        if !isCancelled, !Task.isCancelled {
            if let tail = flushAccumulator() {
                _ = await deliver(chunk: tail)
            }
        }

        switch reader.status {
        case .failed:
            let reason = reader.error?.localizedDescription ?? "unknown reader failure"
            if failure == nil { failure = .readFailed(filename: filename, reason: reason) }
            Log.audio.error("import \(self.filename, privacy: .private(mask: .hash)) [\(audioFileKind(of: self.filename), privacy: .public)]: reader failed: \(reason, privacy: .public)")
        case .cancelled:
            if failure == nil { failure = .cancelled(filename: filename) }
        default:
            break
        }

        // Unconditional, and before anything else that could fail: an `AVAssetReader` left in
        // `.reading` holds its decoder and file descriptor open for as long as the object lives.
        reader.cancelReading()
        self.reader = nil
        self.trackOutput = nil
        self.converter = nil
        self.accumulator = nil

        channel?.finish()
        if failure == nil { onProgress(1.0) }

        Log.audio.info(
            """
            import \(self.filename, privacy: .private(mask: .hash)) read \
            \(String(format: "%.2f", self.stats.deliveredSeconds), privacy: .public)s in \
            \(String(format: "%.2f", self.stats.readWallSeconds), privacy: .public)s \
            (\(String(format: "%.1f", self.stats.realtimeFactor), privacy: .public)x) \
            chunks=\(self.stats.chunks, privacy: .public) \
            dropped=\(self.stats.dropped, privacy: .public) \
            convFail=\(self.stats.conversionFailures, privacy: .public)
            """
        )
    }

    /// Split (or merge) a target-format buffer into ~100 ms chunks and hand them over.
    /// Returns false when the consumer has gone away and reading should stop.
    private func deliver(chunksFrom buffer: AVAudioPCMBuffer) async -> Bool {
        for chunk in accumulate(buffer) {
            if !(await deliver(chunk: chunk)) { return false }
        }
        return true
    }

    private func deliver(chunk: AVAudioPCMBuffer) async -> Bool {
        collectProbe(from: chunk)
        guard let channel else { return false }
        // `AnalyzerInput` is `Sendable` and `chunk` is a buffer we allocated, so nothing the reader
        // owns ever crosses the isolation boundary — the same rule the microphone path follows
        // (RECON, "never yield or store the tap's own buffer").
        let accepted = await channel.put(AnalyzerInput(buffer: chunk))
        if accepted {
            stats.chunks += 1
            stats.frames += Int(chunk.frameLength)
            return true
        }
        if !isCancelled {
            // The consumer vanished while we still had audio. FIFO plus back-pressure means what is
            // lost is the TAIL, not the beginning — the opposite of the live path's failure mode.
            stats.dropped += Int(chunk.frameLength)
            if failure == nil {
                failure = .readFailed(filename: filename, reason: "the transcriber stopped accepting audio")
            }
        }
        return false
    }

    // MARK: - Recognition-quality probe

    /// Keep a copy of the target-format samples until the budget runs out. See `SpeechProbe`.
    private func collectProbe(from chunk: AVAudioPCMBuffer) {
        guard probeBudgetSamples > 0, !probeOverflowed else { return }
        let frames = Int(chunk.frameLength)
        guard frames > 0, let data = chunk.int16ChannelData else { return }
        guard probeSamples.count + frames <= probeBudgetSamples else {
            // Freed rather than truncated: a prefix of the file would give the segmenter a noise
            // floor and a speech level measured over the wrong material, and a *wrong* denominator
            // is worse than the honest wall-clock fallback.
            probeOverflowed = true
            probeSamples = []
            Log.audio.debug("import \(self.filename, privacy: .private(mask: .hash)): speech probe over budget, dropped")
            return
        }
        probeSamples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
    }

    /// Decoded audio for the recognition-quality measurement, or `nil` when there is none to give —
    /// nothing read yet, or the file was longer than the probe budget.
    public var speechProbe: SpeechProbe? {
        guard !probeOverflowed, !probeSamples.isEmpty else { return nil }
        return SpeechProbe(samples: probeSamples, sampleRate: target.sampleRate)
    }

    /// Release the probe's memory once the caller has taken what it needs.
    public func releaseProbe() {
        probeSamples = []
    }

    // MARK: - Whole-file decode

    /// Decode the entire file into memory in the analyzer's format.
    ///
    /// This is the dual-pass entry point and the *alternative* to `start()`, not a companion to it —
    /// an `AVAssetReader` cannot be rewound, so an instance does one or the other. Never throws for
    /// a partial read: a reader that fails halfway leaves real audio behind, and `DecodedAudio.failure`
    /// says so while the samples stay usable. It throws only when there is nothing at all — the file
    /// could not be opened, or the caller already started a read.
    ///
    /// See `DecodedAudio` for the memory cost, which is why this is not the default path.
    public func decodeAll(
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws -> DecodedAudio {
        if channel != nil || producer != nil {
            throw AudioImportError.readFailed(filename: filename, reason: "already started")
        }
        let info = try await open()
        guard let reader, let output = trackOutput else {
            throw AudioImportError.unreadable(filename: filename, reason: "the reader was not configured")
        }
        if isCancelled { throw AudioImportError.cancelled(filename: filename) }

        let began = ContinuousClock.now
        var samples: [Int16] = []
        // Pre-sized from the asset's own duration so an hour-long file is not grown by doubling from
        // empty, which would transiently need 1.5x the final allocation at the worst moment.
        if info.duration > 0, info.duration.isFinite {
            samples.reserveCapacity(Int(min(info.duration + 1, 6 * 3600) * target.sampleRate))
        }

        while !isCancelled, !Task.isCancelled {
            guard let sample = output.copyNextSampleBuffer() else { break }
            stats.readerBuffers += 1
            report(progress: Self.fraction(of: sample, duration: info.duration), onProgress: onProgress)

            guard let decoded = pcmBuffer(from: sample) else {
                stats.conversionFailures += 1
                continue
            }
            guard let converted = convertToTarget(decoded) else {
                stats.conversionFailures += 1
                continue
            }
            let frames = Int(converted.frameLength)
            guard frames > 0, let data = converted.int16ChannelData else { continue }
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            stats.chunks += 1
            stats.frames += frames
        }

        switch reader.status {
        case .failed:
            let reason = reader.error?.localizedDescription ?? "unknown reader failure"
            if failure == nil { failure = .readFailed(filename: filename, reason: reason) }
            Log.audio.error("import \(self.filename, privacy: .private(mask: .hash)) [\(audioFileKind(of: self.filename), privacy: .public)]: decode failed: \(reason, privacy: .public)")
        case .cancelled:
            if failure == nil { failure = .cancelled(filename: filename) }
        default:
            break
        }
        if isCancelled, failure == nil { failure = .cancelled(filename: filename) }

        // Same unconditional teardown as `pump`: a reader left in `.reading` holds its decoder and
        // file descriptor open for as long as the object lives.
        reader.cancelReading()
        self.reader = nil
        self.trackOutput = nil
        self.converter = nil
        self.accumulator = nil

        let elapsed = ContinuousClock.now - began
        stats.readWallSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        if failure == nil { onProgress(1.0) }

        Log.audio.info(
            """
            import \(self.filename, privacy: .private(mask: .hash)) decoded \
            \(String(format: "%.2f", Double(samples.count) / self.target.sampleRate), privacy: .public)s in \
            \(String(format: "%.2f", self.stats.readWallSeconds), privacy: .public)s \
            (\(String(format: "%.1f", self.stats.realtimeFactor), privacy: .public)x) \
            \(samples.count * 2 / 1_048_576, privacy: .public)MB
            """
        )

        return DecodedAudio(
            samples: samples,
            sampleRate: target.sampleRate,
            stats: stats,
            failure: failure
        )
    }

    // MARK: - CMSampleBuffer → AVAudioPCMBuffer

    /// Copy one decoded sample buffer into an `AVAudioPCMBuffer` we own.
    private func pcmBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }

        // Built from the sample buffer's own description rather than assumed, for the same reason
        // the microphone tap reads `buffer.format` inside the callback: the reader decides what it
        // hands back, and it is not always what we asked for.
        var layoutSize = 0
        let layoutPointer = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &layoutSize)
        let format: AVAudioFormat?
        if let layoutPointer, layoutSize >= MemoryLayout<AudioChannelLayout>.size {
            format = AVAudioFormat(
                streamDescription: asbd,
                channelLayout: AVAudioChannelLayout(layout: layoutPointer)
            )
        } else {
            format = AVAudioFormat(streamDescription: asbd)
        }
        guard let format else { return nil }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else {
            Log.audio.error("import \(self.filename, privacy: .private(mask: .hash)): PCM copy failed (\(status, privacy: .public))")
            return nil
        }
        return buffer
    }

    /// Resample/downmix into the analyzer's format, using the one converter for the whole file.
    private func convertToTarget(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == target { return buffer }

        if converter == nil || converter?.inputFormat != buffer.format {
            // A source format change mid-file is not something any tested container does, but the
            // reader is free to do it, and silently reusing a converter built for the old format
            // would produce noise rather than an error.
            guard let fresh = AVAudioConverter(from: buffer.format, to: target) else {
                Log.audio.error(
                    "import \(self.filename, privacy: .private(mask: .hash)): no converter from \(buffer.format, privacy: .public)"
                )
                return nil
            }
            fresh.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter = fresh
        }
        guard let converter else { return nil }

        // ceil(inFrames * outRate/inRate) + slack. The polyphase resampler can emit a frame or two
        // beyond the ideal ratio on any given call; without the slack you silently truncate audio.
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        let feed = OneShotFeed(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            feed.next(outStatus)
        }

        switch status {
        case .haveData, .inputRanDry:
            // `.inputRanDry` is the NORMAL result of the one-buffer-in pattern — "here is everything
            // I could make from what you gave me". Treating it as an error discards every buffer
            // (RECON §17).
            return output.frameLength > 0 ? output : nil
        case .endOfStream, .error:
            if let error {
                Log.audio.error("import \(self.filename, privacy: .private(mask: .hash)) [\(audioFileKind(of: self.filename), privacy: .public)]: converter failed: \(error.localizedDescription, privacy: .public)")
            }
            return nil
        @unknown default:
            return nil
        }
    }

    // MARK: - Chunking

    /// Repack target-format audio into fixed ~100 ms chunks.
    ///
    /// Both directions matter: the reader hands back half-second blocks for AAC, which need
    /// splitting so the engine emits volatile results steadily, and single-packet blocks for some
    /// codecs, which need merging so we are not yielding thousands of 20 ms buffers.
    private func accumulate(_ buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        let bytesPerFrame = Int(target.streamDescription.pointee.mBytesPerFrame)
        // Interleaved (or mono) is the only layout the analyzer accepts, so this is the only layout
        // that can reach here. A non-interleaved target would need per-plane copies; rather than
        // write untested code for a format that cannot occur, pass it straight through.
        guard target.isInterleaved || target.channelCount == 1,
              bytesPerFrame > 0,
              buffer.frameLength > 0,
              let source = buffer.audioBufferList.pointee.mBuffers.mData else {
            return [buffer]
        }

        var produced: [AVAudioPCMBuffer] = []
        var consumed: AVAudioFrameCount = 0

        while consumed < buffer.frameLength {
            if accumulator == nil {
                guard let fresh = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: chunkFrames) else {
                    return produced.isEmpty ? [buffer] : produced
                }
                // Set to capacity so `mutableAudioBufferList`'s `mDataByteSize` covers the whole
                // allocation while we fill it; the real length is written back before we emit.
                fresh.frameLength = chunkFrames
                accumulator = fresh
                accumulated = 0
            }
            guard let accumulator, let destination = accumulator.mutableAudioBufferList.pointee.mBuffers.mData else {
                return produced.isEmpty ? [buffer] : produced
            }

            let take = min(chunkFrames - accumulated, buffer.frameLength - consumed)
            memcpy(
                destination.advanced(by: Int(accumulated) * bytesPerFrame),
                source.advanced(by: Int(consumed) * bytesPerFrame),
                Int(take) * bytesPerFrame
            )
            accumulated += take
            consumed += take

            if accumulated == chunkFrames {
                accumulator.frameLength = chunkFrames
                produced.append(accumulator)
                self.accumulator = nil
                accumulated = 0
            }
        }
        return produced
    }

    /// The trailing partial chunk, if any.
    private func flushAccumulator() -> AVAudioPCMBuffer? {
        guard let accumulator, accumulated > 0 else {
            self.accumulator = nil
            accumulated = 0
            return nil
        }
        accumulator.frameLength = accumulated
        self.accumulator = nil
        accumulated = 0
        return accumulator
    }

    // MARK: - Progress

    /// Coalesced to ~10 Hz. A 100 ms chunk rate would otherwise push 10 main-actor updates a second
    /// per item, and with a queue running that is pure noise.
    private func report(progress: Double?, onProgress: @Sendable (Double) -> Void) {
        guard let progress else { return }
        let clamped = min(1, max(0, progress))
        let now = ContinuousClock.now
        if let last = lastProgressAt, now - last < .milliseconds(100), abs(clamped - lastProgressValue) < 0.01 {
            return
        }
        lastProgressAt = now
        lastProgressValue = clamped
        onProgress(clamped)
    }

    /// Progress from the sample's presentation timestamp against the asset's real duration — the
    /// only source that stays honest for a VBR file, where byte offset does not track time.
    private static func fraction(of sample: CMSampleBuffer, duration: TimeInterval) -> Double? {
        guard duration > 0 else { return nil }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric else { return nil }
        return CMTimeGetSeconds(pts) / duration
    }

    // MARK: - Reader configuration

    /// Linear PCM output settings for a target `AVAudioFormat`.
    ///
    /// These are exactly the keys `AVAssetReaderTrackOutput` documents as valid for audio; anything
    /// else raises an `NSInvalidArgumentException`, which Swift cannot catch. `AVNumberOfChannelsKey`
    /// is 1, which is the one value (along with 2) that does not additionally require
    /// `AVChannelLayoutKey`.
    private static func pcmSettings(for format: AVAudioFormat) -> [String: Any] {
        let asbd = format.streamDescription.pointee
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bitDepth = isFloat ? 32 : max(16, Int(asbd.mBitsPerChannel))
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: min(2, Int(format.channelCount)),
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Fallback settings: decode to PCM but leave rate and channel count alone, and let
    /// `AVAudioConverter` do the rest. Used only when the reader declines the analyzer's format.
    private static func nativePCMSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// The caller checks `canAdd` before `add`: adding an output a reader rejects raises an
    /// `NSException`, which Swift cannot catch.
    private static func makeOutput(track: AVAssetTrack, settings: [String: Any]) -> AVAssetReaderTrackOutput? {
        guard track.mediaType == .audio else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        // We copy every sample into a buffer of our own immediately, so the reader is free to hand
        // back memory it still owns. Measurably cheaper on long files.
        output.alwaysCopiesSampleData = false
        return output
    }

    // MARK: - Error mapping

    private static func classify(_ error: Error, filename: String) -> AudioImportError {
        let nsError = error as NSError
        guard nsError.domain == AVFoundationErrorDomain else {
            return .unreadable(filename: filename, reason: nsError.localizedDescription)
        }
        switch AVError.Code(rawValue: nsError.code) {
        case .fileFormatNotRecognized, .fileTypeDoesNotSupportSampleReferences, .undecodableMediaData:
            return .unsupportedContainer(filename: filename, reason: nsError.localizedDescription)
        case .contentIsProtected, .contentIsNotAuthorized, .applicationIsNotAuthorized:
            return .drmProtected(filename: filename)
        case .noSourceTrack:
            return .noAudioTrack(filename: filename)
        default:
            return .unreadable(filename: filename, reason: nsError.localizedDescription)
        }
    }

    /// Four-character codes are what CoreAudio speaks; nobody wants to read "mp4a" in a UI.
    private static func codecName(_ formatID: AudioFormatID) -> String {
        switch formatID {
        case kAudioFormatLinearPCM: "Linear PCM"
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD, kAudioFormatMPEG4AAC_Spatial: "AAC"
        case kAudioFormatMPEGLayer3: "MP3"
        case kAudioFormatMPEGLayer1: "MP1"
        case kAudioFormatMPEGLayer2: "MP2"
        case kAudioFormatAppleLossless: "Apple Lossless"
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatOpus: "Opus"
        case kAudioFormatAppleIMA4: "IMA4"
        case kAudioFormatALaw: "A-law"
        case kAudioFormatULaw: "µ-law"
        case kAudioFormatAMR, kAudioFormatAMR_WB: "AMR"
        case kAudioFormatiLBC: "iLBC"
        default: fourCC(formatID)
        }
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        let scalars = bytes.compactMap { byte -> Character? in
            (0x20...0x7E).contains(byte) ? Character(UnicodeScalar(byte)) : nil
        }
        return scalars.count == 4 ? String(scalars) : "Unknown"
    }
}

// MARK: - Bounded channel

/// A FIFO channel with back-pressure: one producer, one consumer, capacity fixed at init.
///
/// This exists instead of `AsyncStream(bufferingPolicy: .bufferingNewest(n))` because that policy
/// evicts the OLDEST queued element (RECON §20, measured with ints: capacity 3, yielding 1…8, the
/// consumer saw `[6, 7, 8]`). For a microphone that is the least-bad option. For a file it is
/// simply wrong: the producer can wait, so it does.
///
/// Single producer and single consumer is a real invariant, not a simplification — it is why at
/// most one continuation of each kind can ever be parked, and why storing them in a plain optional
/// is safe.
final class ChunkChannel: @unchecked Sendable {

    /// What `put` should do once the lock is released. Resuming a continuation while holding the
    /// lock would let the resumed task re-enter and deadlock, so the decision and the resume are
    /// deliberately two steps.
    private enum PutOutcome {
        case accepted(CheckedContinuation<Void, Never>?)
        case full
        case closed
    }

    private enum TakeOutcome {
        case element(AnalyzerInput, CheckedContinuation<Void, Never>?)
        case ended(CheckedContinuation<Void, Never>?)
        case empty
    }

    private let capacity: Int
    private let lock = NSLock()
    private var queue: [AnalyzerInput] = []
    private var isFinished = false
    private var waitingConsumer: CheckedContinuation<Void, Never>?
    private var waitingProducer: CheckedContinuation<Void, Never>?

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// Enqueue one chunk, suspending while the channel is full.
    /// Returns false when the channel has been finished — i.e. the consumer is gone.
    func put(_ element: AnalyzerInput) async -> Bool {
        while true {
            let outcome: PutOutcome = lock.withLock {
                if isFinished { return .closed }
                guard queue.count < capacity else { return .full }
                queue.append(element)
                let consumer = waitingConsumer
                waitingConsumer = nil
                return .accepted(consumer)
            }
            switch outcome {
            case .closed:
                return false
            case .accepted(let consumer):
                consumer?.resume()
                return true
            case .full:
                await park(asProducer: true)
            }
        }
    }

    /// Dequeue one chunk, suspending while the channel is empty. `nil` means end of stream.
    func take() async -> AnalyzerInput? {
        while true {
            let outcome: TakeOutcome = lock.withLock {
                if !queue.isEmpty {
                    let element = queue.removeFirst()
                    let producer = waitingProducer
                    waitingProducer = nil
                    return .element(element, producer)
                }
                if isFinished {
                    let producer = waitingProducer
                    waitingProducer = nil
                    return .ended(producer)
                }
                return .empty
            }
            switch outcome {
            case .element(let element, let producer):
                producer?.resume()
                return element
            case .ended(let producer):
                producer?.resume()
                return nil
            case .empty:
                await park(asProducer: false)
            }
        }
    }

    /// End the stream. Idempotent, synchronous, and safe from either side — `cancel()` needs to be
    /// able to unblock a parked producer without awaiting anything.
    ///
    /// **`discardingQueued` defaults to false and must stay that way.** `finish()` is the *normal*
    /// end-of-file path: the reader stops, and whatever is still in the ring is audio the analyzer
    /// has not seen yet. An earlier version cleared the queue here "to release the read-ahead
    /// window", which silently deleted up to a full window of audio and made every file shorter
    /// than the window transcribe as the empty string — the read counters still said 6.04 s
    /// delivered, because they count what was *put*, so it looked exactly like a model failure.
    /// Only an explicit cancel discards.
    func finish(discardingQueued: Bool = false) {
        let waiters: (CheckedContinuation<Void, Never>?, CheckedContinuation<Void, Never>?) =
            lock.withLock {
                if discardingQueued { queue.removeAll() }
                guard !isFinished else { return (nil, nil) }
                isFinished = true
                let pair = (waitingConsumer, waitingProducer)
                waitingConsumer = nil
                waitingProducer = nil
                return pair
            }
        waiters.0?.resume()
        waiters.1?.resume()
    }

    /// Suspend until the other side makes progress. The re-check inside the continuation closes the
    /// window where the counterpart acted between our lock release and our parking.
    private func park(asProducer: Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeImmediately: Bool = lock.withLock {
                if isFinished { return true }
                if asProducer {
                    guard queue.count >= capacity else { return true }
                    waitingProducer = continuation
                } else {
                    guard queue.isEmpty else { return true }
                    waitingConsumer = continuation
                }
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }
}
