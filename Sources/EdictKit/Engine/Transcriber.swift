import AVFoundation
import CoreMedia
import Foundation
import Speech

// MARK: - Values crossing the seam

/// One incremental report from a running utterance.
///
/// `finalText` is the only text that may ever be injected. `volatileText` is the engine's live guess at
/// the tail it has not committed yet; RECON §4 measured it saying "speecheech transcriber API" where the
/// final said "speech transcriber API", and mid-word fragments like "cl" / "whis" appear constantly.
/// Show it dimmed, never paste it.
public struct TranscriptionUpdate: Sendable, Hashable {
    /// Accumulated finalized text.
    public var finalText: String
    /// The unstable tail the engine may still revise. Display only — never inject this.
    public var volatileText: String
    public var isFinal: Bool
    public var confidence: Double?

    public init(finalText: String, volatileText: String, isFinal: Bool, confidence: Double? = nil) {
        self.finalText = finalText
        self.volatileText = volatileText
        self.isFinal = isFinal
        self.confidence = confidence
    }

    /// What the HUD should render: committed text plus the provisional tail.
    public var displayText: String { finalText + volatileText }
}

/// One word (strictly: one attribute run) as the engine heard it, with how sure it was.
///
/// Confidence is strongly discriminative — RECON §7 measured misheard "Visa" at 0.05 and "claw" at 0.31
/// against 0.998 for a correctly-heard "deploy" — which is what lets the history view offer sub-0.5 words
/// as one-click dictionary additions. Requires an explicit `Preset` carrying
/// `attributeOptions: [.transcriptionConfidence, .audioTimeRange]`; the named presets have
/// `attributeOptions == []` and silently yield a single attribute-free run.
public struct WordConfidence: Sendable, Hashable, Identifiable {
    public var id: Int { hashValue }
    /// The run's text, trimmed of the leading space the engine attaches to each segment.
    public var text: String
    public var confidence: Double
    /// Offset of the run within the utterance's audio, in seconds. `nil` if the run carried no time range.
    public var startSeconds: Double?
    public var endSeconds: Double?

    public init(text: String, confidence: Double, startSeconds: Double? = nil, endSeconds: Double? = nil) {
        self.text = text
        self.confidence = confidence
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// The threshold below which a word is treated as probably misheard and offered to the dictionary UI.
/// From RECON §7's measured distribution, not tuned by us.
public let lowConfidenceThreshold: Double = 0.5

/// The result of one complete utterance.
public struct TranscriptionOutcome: Sendable {
    public var text: String
    /// Mean per-word confidence over the whole utterance, or `nil` when no run carried the attribute.
    public var confidence: Double?
    /// End-of-audio to final result. Reported in history and used for the benchmark numbers.
    public var latency: TimeInterval
    public var audioDuration: TimeInterval
    /// Every attribute run of every final result, in arrival order.
    public var words: [WordConfidence]
    /// The subset of `words` below `lowConfidenceThreshold`, deduped, ready for the dictionary suggestion UI.
    public var lowConfidenceWords: [String]

    public init(
        text: String,
        confidence: Double?,
        latency: TimeInterval,
        audioDuration: TimeInterval,
        words: [WordConfidence] = [],
        lowConfidenceWords: [String] = []
    ) {
        self.text = text
        self.confidence = confidence
        self.latency = latency
        self.audioDuration = audioDuration
        self.words = words
        self.lowConfidenceWords = lowConfidenceWords
    }
}

public enum ModelState: Sendable, Hashable {
    case unavailable(String), needsDownload, downloading(Double), ready
}

public enum SpeechEngineError: Error, Sendable, Hashable {
    /// `DictationTranscriber.supportedLocale(equivalentTo:)` returned nil. Indonesian (`id-ID`) does this.
    case localeUnsupported(String)
    /// `prepare(localeIdentifier:)` has not run, or ran and failed.
    case notPrepared
    /// `SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)` returned nil.
    case noAudioFormat
    /// A locale reservation could not be obtained even after evicting the other reservations.
    case reservationFailed(String)
    case assetInstallFailed(String)
    /// `transcribe`/`begin` called while another utterance is still running.
    case sessionAlreadyRunning
}

// MARK: - The seam

/// One utterance in flight: feed audio, then either commit or abort.
///
/// RECON §3 is categorical that this object is single-use. `finalize(through:)` deadlocks forever while the
/// input stream is open, and `start()` on a finished analyzer silently no-ops and loses the utterance — so a
/// session owns exactly one module + one analyzer and is thrown away afterwards.
public protocol TranscriptionSession: Sendable {
    /// Hand over one already-format-converted buffer. Cheap and non-blocking.
    func feed(_ input: AnalyzerInput)
    /// Normal end of push-to-talk. Closes the input, flushes the pending final, and returns the outcome.
    func finishAndCommit() async throws -> TranscriptionOutcome
    /// Explicit user abort (Esc). RECON §5 measured that this **discards** the pending final result, so it
    /// must never be used for a normal key release.
    func abort() async
    /// Current committed + volatile text without waiting for anything.
    var snapshot: TranscriptionUpdate { get }
}

/// The backend seam. Apple's `SpeechAnalyzer` + `DictationTranscriber` is the only implementation.
///
/// A local Parakeet backend would slot in here — `begin` / `feed` / `finishAndCommit` was chosen to mirror
/// what a streaming CTC model needs — but RECON's recommendation is explicit that it is not worth shipping
/// 0.6–2.4 GB of weights and a Python/MLX runtime into an app with zero third-party dependencies while
/// Apple's engine runs at ~12x realtime on-device with working vocabulary biasing. Deliberately unimplemented.
public protocol TranscriptionEngine: Sendable {
    /// Resolve, reserve, and check assets for a locale. Must run before anything else.
    func prepare(localeIdentifier: String) async throws
    /// The audio format the backend wants; hand this to `AudioCapture`.
    func bestAudioFormat() async -> AVAudioFormat?
    /// Stage contextual strings for the **next** utterance. RECON §2: context can only be supplied at
    /// analyzer init, so a mid-utterance change is impossible by construction.
    func setBiasing(_ strings: [String]) async
    /// Pay the cold model-load cost at launch (~50 ms) so the user's first hotkey press costs ~2.5 ms.
    func warmUp() async
    /// Start one utterance.
    func begin(onUpdate: @Sendable @escaping (TranscriptionUpdate) -> Void) async throws -> any TranscriptionSession
    /// Abort whatever utterance is running, if any.
    func cancel() async
}

// NOTE — do not add the custom-language-model path here.
// `SFCustomLanguageModelData` → `export(to:)` → `SFSpeechLanguageModel.prepareCustomLanguageModel` →
// `DictationTranscriber.ContentHint.customizedLanguage` compiles, exports, and prepares without error, and
// RECON §1 measured byte-identical output to the no-hint baseline at weights nil, 0.3 and 1.0. It is ~200
// lines and a 0.6 s recompile on every dictionary edit for zero benefit. `contextualStrings` is the one that
// works, and only on `DictationTranscriber`.

// MARK: - Accumulator

/// Assembles final and volatile results into text, and collects per-word confidence off the results task.
///
/// The accumulation rule is the single most expensive thing in RECON §4 to get wrong: volatile results are
/// cumulative-from-the-last-final, so they **replace** the tail, while finals **append**. Concatenating every
/// event on a 24 s utterance produced 7310 characters where 412 was correct.
///
/// `@unchecked Sendable` is deliberate and RECON-sanctioned: Swift 6 rejects the obvious
/// `Task { for try await r in module.results { local += ... } }` shape because the closure captures mutable
/// local state. The prescribed fix is to hoist `let results = module.results` out of the `Task` and accumulate
/// into a lock-protected class. Every mutable field below is touched only under `lock`.
final class TranscriptSink: @unchecked Sendable {
    private let lock = NSLock()

    /// Finals in arrival order. Ranges are disjoint and monotonic but **not** contiguous — RECON §4 saw a
    /// 120 ms gap mid-utterance — so we never assert `start == previousEnd` and only dedupe on exact equality.
    private var finals: [(range: CMTimeRange, text: String)] = []
    private var volatileTail = ""
    private var words: [WordConfidence] = []
    private var framesFed: Int = 0
    private var resultsTask: Task<Void, Error>?
    private var failure: Error?

    private let onUpdate: @Sendable (TranscriptionUpdate) -> Void

    init(onUpdate: @escaping @Sendable (TranscriptionUpdate) -> Void) {
        self.onUpdate = onUpdate
    }

    // MARK: Input bookkeeping

    /// Counted so the outcome can report audio duration without trusting the engine's own ranges (the
    /// volatile range end runs ahead of the final's — 24.188 vs 24.120 in RECON §4 — so ranges are not a
    /// safe duration source).
    func countFrames(_ frames: Int) {
        lock.withLock { framesFed += frames }
    }

    func audioDuration(sampleRate: Double) -> TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return lock.withLock { Double(framesFed) / sampleRate }
    }

    // MARK: Results

    func ingest(isFinal: Bool, range: CMTimeRange, text: AttributedString) {
        let flat = String(text.characters)
        var runConfidences: [Double] = []

        let update: TranscriptionUpdate = lock.withLock {
            if isFinal {
                // Dedupe only on exact range equality; a revised final for a range we already hold replaces it.
                if let i = finals.firstIndex(where: { CMTimeRangeEqual($0.range, range) }) {
                    finals[i] = (range, flat)
                } else {
                    finals.append((range, flat))
                }
                volatileTail = ""

                for run in text.runs {
                    guard let confidence =
                        run.attributes[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self]
                    else { continue }
                    let timeRange = run.attributes[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self]
                    let raw = String(text[run.range].characters)
                    // Segment text carries its own leading space (" It runs entirely…"); keep it in the
                    // transcript but strip it from the word we surface in the dictionary UI.
                    let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !word.isEmpty else { continue }
                    runConfidences.append(confidence)
                    words.append(
                        WordConfidence(
                            text: word,
                            confidence: confidence,
                            startSeconds: timeRange.map { CMTimeGetSeconds($0.start) },
                            endSeconds: timeRange.map { CMTimeGetSeconds(CMTimeRangeGetEnd($0)) }
                        )
                    )
                }
            } else {
                // REPLACE, never append. See the class comment.
                volatileTail = flat
            }
            return TranscriptionUpdate(
                finalText: committedLocked,
                volatileText: volatileTail,
                isFinal: isFinal,
                confidence: runConfidences.isEmpty
                    ? nil
                    : runConfidences.reduce(0, +) / Double(runConfidences.count)
            )
        }
        onUpdate(update)
    }

    /// Finals already carry their own separators, so this is a plain join with no glue.
    private var committedLocked: String { finals.map(\.text).joined() }

    var snapshot: TranscriptionUpdate {
        lock.withLock {
            TranscriptionUpdate(finalText: committedLocked, volatileText: volatileTail, isFinal: false)
        }
    }

    var committed: String { lock.withLock { committedLocked } }

    var allWords: [WordConfidence] { lock.withLock { words } }

    /// Deduped, order-preserving list of the words the engine was unsure about.
    var lowConfidenceWords: [String] {
        lock.withLock {
            var seen = Set<String>()
            var out: [String] = []
            for word in words where word.confidence < lowConfidenceThreshold {
                let key = word.text.lowercased()
                if seen.insert(key).inserted { out.append(word.text) }
            }
            return out
        }
    }

    var meanConfidence: Double? {
        lock.withLock {
            guard !words.isEmpty else { return nil }
            return words.reduce(0.0) { $0 + $1.confidence } / Double(words.count)
        }
    }

    /// The error the results task threw, if it did. Surfaced by `finishAndCommit`.
    var consumerFailure: Error? { lock.withLock { failure } }

    // MARK: Consumer task lifecycle

    func attach(_ task: Task<Void, Error>) {
        lock.withLock { resultsTask = task }
    }

    /// Await the results consumer. Step 3 of the teardown order in RECON §5 — skipping it races the last
    /// final against the caller reading `committed`.
    func drain() async {
        let task = lock.withLock { resultsTask }
        guard let task else { return }
        do {
            _ = try await task.value
        } catch {
            lock.withLock { failure = error }
        }
    }
}
