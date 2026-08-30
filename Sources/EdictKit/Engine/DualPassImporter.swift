//
//  DualPassImporter.swift
//  Transcribes an imported file's sections in two languages and keeps, per section, whichever
//  transcript reads more like the language that produced it.
//
//  WHAT THIS IS, IN ONE SENTENCE
//
//  A heuristic over two finished transcripts. Apple's speech framework has no language
//  identification: `DictationTranscriber` and `SpeechTranscriber` are each constructed for exactly
//  one `Locale`, and a model handed the wrong language does not fail — it returns fluent nonsense in
//  the language it was built for. So there is nothing to *ask*. The only way to choose is to
//  transcribe twice and read the two results, which is what `LanguageScorer` does, and the UI must
//  never imply otherwise.
//
//  WHERE IT HELPS, AND WHERE IT DOES NOT
//
//  It helps, and by a lot, on clean bilingual audio. Measured on the 17-second four-turn fixture
//  (two speakers alternating English and Indonesian, close mic) against its ground truth:
//
//      single pass, SpeechTranscriber en-US ....... 41.5 % word error   0.29 s
//      single pass, DictationTranscriber id-ID .... 51.2 % word error   0.81 s
//      dual pass, per section ......................  7.3 % word error   1.25 s
//
//  All four sections were found, all four chose the right language, and all four cleared
//  `LanguageScorer`'s confidence thresholds (margins 0.80–1.00). The three remaining word errors are
//  one number rendered "12%" where the ground truth says "dua belas persen".
//
//  It does not help on the audio this project was diagnosed against. Measured on a 300-second slice
//  of a real 70-minute far-field meeting (stereo 48 kHz, two-plus speakers, Indonesian and English
//  code-switched), and this is the number that matters:
//
//      file                          words   wpm   mean word confidence   words under 0.30
//      clean bilingual, 17 s            38    158                 0.941                0 %
//      English script, 377 s          1008    188                 0.930                0 %
//      the real meeting, 300 s         245     49                 0.288               57 %
//
//  Read that carefully, because it is the opposite of what it looks like. Cutting the meeting into
//  sections raised the word count from 91 (one pass over the whole file) to 245 — and the mean word
//  confidence collapsed to 0.288, with 57 % of words under 0.30, against 0.93 and 0 % on both
//  recordings that are genuinely fine. Short sections do not make the model transcribe better; they
//  make it **guess**, because it has less context on which to decide it heard nothing. More words at
//  a third of the confidence is worse than fewer words and honest gaps, and it is why
//  `ImportQueue.assess` will not judge a transcript on rate alone.
//
//  Dual pass must therefore never be presented as a fix for difficult audio. `RecognitionQuality` is
//  what speaks to that case.
//
//  WHY PER SECTION AND NOT PER FILE
//
//  One decision for 70 minutes of audio is one decision too few: a bilingual meeting switches
//  language mid-sentence, and a whole-file verdict would render the losing language as nonsense for
//  as long as it was spoken. `SpeechSegmenter` cuts the file at silences first, which turns one
//  decision into a few hundred over stretches short enough to plausibly be one language.
//
//  WHY THE TWO PASSES ARE SERIAL
//
//  Measured, on the first section of the 17-second fixture, three runs each:
//
//      serial     ....... 0.223 s mean
//      async let  ....... 0.207 s mean, 0 failures
//
//  A 7 % difference is noise, and the reason is structural: `SpeechEngine` holds exactly one analyzer
//  slot, so `async let` does not overlap the two passes, it queues the second one behind the first.
//  Serial is therefore the same speed and strictly safer — `claimSlot` gives up after 1.5 s, and on a
//  section approaching `maxSectionDuration` (30 s at `standard`) a queued second claimant would time
//  out and throw `.sessionAlreadyRunning` instead of merely waiting. The slot is deliberate (RECON §3:
//  a module and analyzer are per-utterance and never reused), not an oversight worth routing around.
//
//  COST, MEASURED — AND IT IS NOT 2x
//
//      file                     single pass   dual pass   ratio   sections x passes
//      clean bilingual, 17 s         0.29 s      1.25 s    4.3x        4 x 2 =   8
//      English script, 377 s         4.34 s     22.31 s    5.1x       84 x 2 = 168
//
//  "Twice the transcription work" would predict 2x and is wrong, so it is worth naming what the rest
//  is: per-utterance **finalize latency**. RECON §8 measured 0.15 s from end-of-audio to the final
//  result on a 4.7-second clip, and a dual pass pays that once per pass rather than once per file —
//  168 x ~0.12 s accounts for essentially the whole 18-second gap above. The analyzer builds
//  themselves are the cheap part (~2.5 ms warm each, RECON §3).
//
//  On top of that the whole decoded file stays in memory, because `SpeechSegmenter` needs a whole
//  buffer and every section is replayed twice: 32 KB per second of audio, so 0.5 MB for the
//  17-second fixture, 9 MB for a 5-minute slice, 128 MB for the 70-minute meeting.
//
//  A 5x slowdown and a memory footprint linear in file length are both why this is off by default,
//  and why the progress reported for it has to be a measurement rather than an estimate.
//

import AVFoundation
import Foundation
import Speech

// MARK: - Results

/// One candidate transcript for one section: what one language's model made of that audio.
public struct DualPassCandidate: Sendable, Hashable {
    /// The locale identifier as the user spelled it — `"id-ID"`, not `"id_ID"`.
    public var localeIdentifier: String
    /// Which of Apple's two modules produced it.
    public var module: TranscriptionModule
    public var text: String
    /// `LanguageScorer`'s share for this candidate, 0…1 and comparable across candidates.
    public var score: Double
    /// Per-word runs, kept so the winner can contribute timed segments.
    public var words: [WordConfidence]

    public init(
        localeIdentifier: String,
        module: TranscriptionModule,
        text: String,
        score: Double,
        words: [WordConfidence]
    ) {
        self.localeIdentifier = localeIdentifier
        self.module = module
        self.text = text
        self.score = score
        self.words = words
    }
}

/// One section of the file, both its candidate transcripts, and which one was kept.
public struct DualPassSection: Sendable, Identifiable {
    public var id: UUID
    public var start: TimeInterval
    public var end: TimeInterval
    /// The locale whose transcript was kept.
    public var chosenLocale: String
    /// Winner's score minus the runner-up's, from `LanguageVerdict.margin`.
    public var margin: Double
    /// False when the margin or the evidence behind it did not clear `LanguageScorer`'s thresholds,
    /// in which case `chosenLocale` is the primary language by fallback rather than by evidence.
    public var isConfident: Bool
    /// The kept text, trimmed.
    public var text: String
    /// Both candidates, primary first.
    public var candidates: [DualPassCandidate]

    public init(
        id: UUID = UUID(),
        start: TimeInterval,
        end: TimeInterval,
        chosenLocale: String,
        margin: Double,
        isConfident: Bool,
        text: String,
        candidates: [DualPassCandidate]
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.chosenLocale = chosenLocale
        self.margin = margin
        self.isConfident = isConfident
        self.text = text
        self.candidates = candidates
    }

    public var duration: TimeInterval { max(0, end - start) }
}

/// Everything one dual-pass import produced.
public struct DualPassOutcome: Sendable {
    /// Sections in time order, each with its verdict.
    public var sections: [DualPassSection]
    /// The winners stitched in time order.
    public var text: String
    /// Timed segments, each carrying the locale of the section that produced it.
    public var segments: [TranscriptSegment]
    /// Locales that contributed text, ordered by share of *recognised audio seconds*, descending.
    /// One element when only one language ever won.
    public var localeIdentifiers: [String]
    /// Seconds of detected speech, from `SpeechSegmenter`, for `RecognitionQuality`'s denominator.
    public var speechDuration: TimeInterval
    /// Mean per-word confidence across the kept transcripts, or `nil` when no module supplied one.
    /// `DictationTranscriber` on `id_ID` supplies none, so a mixed transcript can legitimately be nil.
    public var meanConfidence: Double?
    /// Deduped low-confidence words from the kept transcripts, for the dictionary suggestions.
    public var lowConfidenceWords: [String]
    /// How many transcription passes actually ran. `2 × sections` unless a pass failed.
    public var passesRun: Int
    /// How many transcription passes were attempted and threw.
    ///
    /// Counted rather than merely logged because a failed pass is *missing transcript*, and the only
    /// thing worse than losing a section is losing it silently: at zero, no section was lost to a
    /// failing pass, and above zero the caller must say that part of the file is not in the text.
    /// Before this existed the catch in `run` only logged — the row still finished `.done`, and when
    /// nothing survived at all the surface reported that no speech had been found in the file.
    public var failedPasses: Int
    /// Read counters from the decode.
    public var stats: ImportStats
    /// Why the decode stopped early, or `nil`.
    public var failure: AudioImportError?

    /// The locale the transcript as a whole should be attributed to: the largest share.
    public var dominantLocale: String { localeIdentifiers.first ?? "" }

    /// True when more than one language won at least one section.
    public var isMixed: Bool { localeIdentifiers.count > 1 }

    /// Passes that were started, whether or not they returned a transcript — which for a run that
    /// was not cancelled is `sections × passes`, the denominator any "N of M" sentence needs.
    /// Derived rather than stored so it cannot drift from the two counters it is the sum of.
    public var passesAttempted: Int { passesRun + failedPasses }

    public init(
        sections: [DualPassSection],
        text: String,
        segments: [TranscriptSegment],
        localeIdentifiers: [String],
        speechDuration: TimeInterval,
        meanConfidence: Double?,
        lowConfidenceWords: [String],
        passesRun: Int,
        failedPasses: Int = 0,
        stats: ImportStats,
        failure: AudioImportError?
    ) {
        self.sections = sections
        self.text = text
        self.segments = segments
        self.localeIdentifiers = localeIdentifiers
        self.speechDuration = speechDuration
        self.meanConfidence = meanConfidence
        self.lowConfidenceWords = lowConfidenceWords
        self.passesRun = passesRun
        self.failedPasses = failedPasses
        self.stats = stats
        self.failure = failure
    }
}

// MARK: - The runner

/// Runs the dual pass over one already-decoded file.
///
/// Pure orchestration: it does not open files, own the engine, or know what a `SpeechAnalyzer` is.
/// Everything that touches the framework arrives through `Pass.transcribe`, which is what lets the
/// whole algorithm — segmentation, two passes, scoring, fallback, stitching, progress — be driven in
/// a test with two closures and no model on disk.
public struct DualPassImporter: Sendable {

    /// One language to transcribe every section in.
    public struct Pass: Sendable {
        /// Locale identifier as the user spelled it. Goes into the transcript and into the scorer.
        public var localeIdentifier: String
        /// Which module will run — recorded on the candidate so the UI can say so.
        public var module: TranscriptionModule
        /// Transcribe one section's audio. Called once per section, serially.
        public var transcribe: @Sendable (AsyncStream<AnalyzerInput>) async throws -> TranscriptionOutcome

        public init(
            localeIdentifier: String,
            module: TranscriptionModule,
            transcribe: @Sendable @escaping (AsyncStream<AnalyzerInput>) async throws -> TranscriptionOutcome
        ) {
            self.localeIdentifier = localeIdentifier
            self.module = module
            self.transcribe = transcribe
        }
    }

    /// Progress and liveness, both called off the main actor.
    public struct Reporting: Sendable {
        /// Fraction of the *whole job* complete, 0…1 — see `DualPassImporter.progressNote`.
        public var onProgress: @Sendable (Double) -> Void
        /// The stitched transcript so far, after each section is decided.
        public var onText: @Sendable (String) -> Void
        /// Passes **attempted** and passes to run — two per section. Reported alongside the fraction
        /// because "24 of 96" is a claim a user can check against the file, where "25 %" is not.
        ///
        /// Attempted, not succeeded, and that distinction closes a real bug: a pass that threw is
        /// finished work — nothing retries it — so counting only the successes made this counter and
        /// the bar advance at the *surviving* passes' rate. Measured on a two-section fixture whose
        /// second language failed everywhere: the last event was `(2, 4)` and the last measured
        /// fraction 0.51, on a job that was over. What is *missing* from a run is
        /// `DualPassOutcome.failedPasses`, said once at the end where there is room for a sentence,
        /// rather than squeezed into a progress readout.
        public var onSections: @Sendable (Int, Int) -> Void

        public init(
            onProgress: @Sendable @escaping (Double) -> Void = { _ in },
            onText: @Sendable @escaping (String) -> Void = { _ in },
            onSections: @Sendable @escaping (Int, Int) -> Void = { _, _ in }
        ) {
            self.onProgress = onProgress
            self.onText = onText
            self.onSections = onSections
        }
    }

    /// What the reported progress is, and why it is better than the single-pass estimate.
    ///
    /// It is a **measurement**, not the elapsed-time guess `ImportQueue.progressNote` describes. A
    /// dual pass knows how many sections there are before it starts and works through them one at a
    /// time, so "passes attempted / passes to run" is a real fraction. That matters more here than it
    /// did before: the work has roughly doubled, and an estimate calibrated on single-pass throughput
    /// would have run to 99 % at the halfway mark and sat there — the exact dishonesty the
    /// single-pass note apologises for. The decode is credited a fixed small share because it is
    /// genuinely small: measured at 570–4300x realtime, a 377-second file decodes in 90 ms.
    ///
    /// **Attempted, not succeeded.** A pass that threw is finished work — nothing retries it — so
    /// crediting only the successes made the bar climb at the surviving passes' rate and then jump to
    /// the cap on the unconditional final report, which is the halfway-and-stuck dishonesty above
    /// wearing a different hat. The failures are counted in `DualPassOutcome.failedPasses` and
    /// stated in the row's warning instead.
    public static let progressNote = """
        Measured: transcription passes attempted against passes to run, two per section. \
        Not an estimate.
        """

    /// Share of the progress bar given to decoding and segmenting, before any transcription.
    static let decodeShare = 0.02

    /// ~100 ms per buffer, matching what `AudioFileImporter` hands the live import path. Small enough
    /// that the engine emits volatile results steadily rather than in half-second lurches.
    private static let chunkSeconds = 0.100

    /// Sections shorter than this are not worth two analyzers.
    ///
    /// `SpeechSegmenter` already refuses to emit sections under 0.6 s, so this only ever bites on a
    /// caller that hands in its own boundaries. Below roughly a second there is not enough text for
    /// `LanguageScorer` to reach `isConfident` anyway — its floor is two evidence-bearing tokens —
    /// so the second pass would be pure cost for a verdict that falls back to the primary regardless.
    public static let minimumSectionSeconds: TimeInterval = 0.6

    public let segmenter: SpeechSegmenter
    public let scorer: LanguageScorer

    public init(segmenter: SpeechSegmenter = SpeechSegmenter(), scorer: LanguageScorer = LanguageScorer()) {
        self.segmenter = segmenter
        self.scorer = scorer
    }

    // MARK: Run

    /// Segment, transcribe every section in every pass, score, stitch.
    ///
    /// - Parameters:
    ///   - decoded: the whole file in the analyzer's format. See `DecodedAudio` for the memory cost.
    ///   - format: the format `decoded.samples` are in, used to build the analyzer's input buffers.
    ///   - passes: languages to try, **primary first**. Order is load-bearing: `LanguageScorer`
    ///     breaks a tie by input order, so a section with no evidence either way keeps the language
    ///     the user actually chose.
    ///   - reporting: progress and live text.
    public func run(
        decoded: DecodedAudio,
        format: AVAudioFormat,
        passes: [Pass],
        reporting: Reporting = Reporting()
    ) async throws -> DualPassOutcome {
        guard !passes.isEmpty else {
            throw SpeechEngineError.notPrepared
        }

        let sections = self.sections(in: decoded)
        let speech = speechDuration(in: decoded)
        reporting.onProgress(Self.decodeShare)

        guard !sections.isEmpty else {
            // No speech found. Returning empty rather than transcribing the whole file anyway is the
            // honest answer, and `RecognitionQuality` turns it into a sentence — a caller that
            // silently fell back to one long pass would hide exactly the finding the user needs.
            Log.stt.info("dual pass: no speech sections found")
            return DualPassOutcome(
                sections: [],
                text: "",
                segments: [],
                localeIdentifiers: [passes[0].localeIdentifier],
                speechDuration: speech,
                meanConfidence: nil,
                lowConfidenceWords: [],
                passesRun: 0,
                stats: decoded.stats,
                failure: decoded.failure
            )
        }

        let chunkFrames = max(160, Int((format.sampleRate * Self.chunkSeconds).rounded()))
        let totalPasses = sections.count * passes.count
        reporting.onSections(0, totalPasses)
        var passesRun = 0
        var failedPasses = 0
        /// Passes started, successful or not — the only counter progress may be driven from. See
        /// `Reporting.onSections`.
        var attempted: Int { passesRun + failedPasses }
        var decided: [DualPassSection] = []
        var stitched: [String] = []
        var words: [WordConfidence] = []
        var segments: [TranscriptSegment] = []
        /// Recognised audio seconds per locale — the share that decides `localeIdentifiers`.
        var secondsByLocale: [String: TimeInterval] = [:]

        for section in sections {
            try Task.checkCancellation()

            var candidates: [DualPassCandidate] = []
            for pass in passes {
                // Serial, and deliberately: see the file header. The engine's one analyzer slot
                // serialises these whatever we do here.
                let stream = Self.stream(
                    from: decoded.samples,
                    range: decoded.range(from: section.start, to: section.end),
                    format: format,
                    chunkFrames: chunkFrames
                )
                do {
                    let outcome = try await pass.transcribe(stream)
                    passesRun += 1
                    candidates.append(
                        DualPassCandidate(
                            localeIdentifier: pass.localeIdentifier,
                            module: pass.module,
                            text: outcome.text.trimmingCharacters(in: .whitespacesAndNewlines),
                            score: 0,
                            words: outcome.words
                        )
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // One failed pass is not a failed file: the section still has the other
                    // candidate. But it is not free either, and treating it as free is the defect —
                    // a section that loses *both* candidates contributes nothing, which is exactly
                    // what silence contributes, so to every caller downstream a file that could not
                    // be transcribed looked identical to a file with nothing on it. Hence the count;
                    // `ImportQueue.runDualPass` turns it into a sentence naming what is not there.
                    failedPasses += 1
                    Log.stt.warning("""
                        dual pass: \(pass.localeIdentifier, privacy: .public) failed on \
                        \(String(format: "%.1f", section.start), privacy: .public)s — \
                        \(String(describing: error), privacy: .public)
                        """)
                }
            }

            reporting.onProgress(Self.fraction(attempted, of: totalPasses))
            reporting.onSections(attempted, totalPasses)
            guard !candidates.isEmpty else { continue }

            let verdict = scorer.verdict(
                for: candidates.map { (locale: $0.localeIdentifier, text: $0.text) }
            )
            // Fall back to the primary when the evidence does not carry a verdict. The two errors
            // are not symmetric: keeping the language the user chose costs nothing they did not ask
            // for, while acting on a coin-flip margin renders a passage in the wrong language.
            let chosenLocale = verdict.isConfident ? verdict.chosen : passes[0].localeIdentifier
            let scoreByLocale = Dictionary(
                verdict.scores.map { ($0.localeIdentifier, $0.score) },
                uniquingKeysWith: { first, _ in first }
            )
            let scored = candidates.map { candidate in
                var copy = candidate
                copy.score = scoreByLocale[candidate.localeIdentifier] ?? 0
                return copy
            }
            guard let winner = scored.first(where: { $0.localeIdentifier == chosenLocale })
                ?? scored.first else { continue }

            decided.append(
                DualPassSection(
                    id: section.id,
                    start: section.start,
                    end: section.end,
                    chosenLocale: winner.localeIdentifier,
                    margin: verdict.margin,
                    isConfident: verdict.isConfident,
                    text: winner.text,
                    candidates: scored
                )
            )

            if !winner.text.isEmpty {
                stitched.append(winner.text)
                words.append(contentsOf: winner.words)
                segments.append(
                    contentsOf: Self.segments(
                        from: winner.words,
                        offsetBy: section.start,
                        limit: section.end,
                        locale: winner.localeIdentifier
                    )
                )
                // Only sections that produced text count towards a language's share: crediting a
                // silent section to whichever model was asked first would let the primary language
                // look dominant in a recording where it was barely spoken.
                secondsByLocale[winner.localeIdentifier, default: 0] += section.duration
                reporting.onText(stitched.joined(separator: " "))
            }
        }

        reporting.onProgress(1.0)

        let ordered = Self.order(secondsByLocale, fallback: passes[0].localeIdentifier)
        let confidences = words.compactMap(\.confidence).filter(\.isFinite)
        Log.stt.info("""
            dual pass: \(decided.count, privacy: .public) sections, \
            \(passesRun, privacy: .public) passes, \
            failed=\(failedPasses, privacy: .public), \
            locales=\(ordered.joined(separator: "+"), privacy: .public), \
            confident=\(decided.count { $0.isConfident }, privacy: .public)
            """)

        return DualPassOutcome(
            sections: decided,
            text: stitched.joined(separator: " "),
            segments: segments.sorted { $0.start < $1.start },
            localeIdentifiers: ordered,
            speechDuration: speech,
            meanConfidence: confidences.isEmpty
                ? nil
                : confidences.reduce(0, +) / Double(confidences.count),
            lowConfidenceWords: Self.lowConfidenceWords(in: words),
            passesRun: passesRun,
            failedPasses: failedPasses,
            stats: decoded.stats,
            failure: decoded.failure
        )
    }

    // MARK: Segmentation

    /// Sections worth transcribing, from the segmenter, filtered by `minimumSectionSeconds`.
    public func sections(in decoded: DecodedAudio) -> [SpeechSection] {
        guard decoded.sampleRate > 0, !decoded.samples.isEmpty else { return [] }
        let found = decoded.samples.withUnsafeBufferPointer {
            segmenter.sections(inPCM: $0, sampleRate: decoded.sampleRate)
        }
        return found.filter { $0.duration >= Self.minimumSectionSeconds }
    }

    /// Detected-speech seconds over the whole file, for `RecognitionQuality`'s denominator.
    public func speechDuration(in decoded: DecodedAudio) -> TimeInterval {
        guard decoded.sampleRate > 0, !decoded.samples.isEmpty else { return 0 }
        return decoded.samples.withUnsafeBufferPointer {
            segmenter.speechDuration(inPCM: $0, sampleRate: decoded.sampleRate)
        }
    }

    // MARK: Helpers

    /// Locales ordered by share, descending, ties broken alphabetically so the order is stable.
    static func order(_ seconds: [String: TimeInterval], fallback: String) -> [String] {
        guard !seconds.isEmpty else { return [fallback] }
        return seconds
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
    }

    /// Progress across the whole job, with the decode's fixed share already spent.
    static func fraction(_ done: Int, of total: Int) -> Double {
        guard total > 0 else { return 1 }
        let share = min(1, max(0, Double(done) / Double(total)))
        return decodeShare + share * (1 - decodeShare)
    }

    /// Deduped, order-preserving low-confidence words. Mirrors `TranscriptSink.lowConfidenceWords`,
    /// including its rule that a run with *no* confidence is not evidence of a mishearing — which is
    /// every Indonesian run, because `DictationTranscriber` on `id_ID` reports none.
    static func lowConfidenceWords(in words: [WordConfidence]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for word in words where (word.confidence ?? 1) < lowConfidenceThreshold {
            let key = word.text.lowercased()
            if seen.insert(key).inserted { out.append(word.text) }
        }
        return out
    }

    /// Per-word runs into file-relative timed segments.
    ///
    /// The engine reports times relative to the audio *it* was fed, which for a section is the
    /// section, so every range shifts by `offsetBy`. Clamped to the section's own end because the
    /// volatile range end can run ahead of the final's (RECON §4 measured 24.188 against 24.120) and
    /// a cue reaching into the next section would collide with it in an exported subtitle.
    static func segments(
        from words: [WordConfidence],
        offsetBy offset: TimeInterval,
        limit: TimeInterval,
        locale: String
    ) -> [TranscriptSegment] {
        words.compactMap { word in
            guard let start = word.startSeconds else { return nil }
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let from = min(max(offset, offset + start), limit)
            let to = min(max(from, offset + (word.endSeconds ?? start)), limit)
            return TranscriptSegment(start: from, end: to, text: text, confidence: word.confidence, locale: locale)
        }
    }

    // MARK: Section audio

    /// One section's samples as the stream `SpeechEngine.transcribe` consumes.
    ///
    /// Built eagerly and yielded into an unbounded stream rather than pulled: a section is bounded by
    /// `SpeechSegmenter.Options.maxSectionDuration` (30 s at `standard`), which at 16 kHz mono Int16
    /// is under a megabyte — so the back-pressure machinery `AudioFileImporter` needs for an
    /// hour-long file would be pure ceremony here, and the samples are already in memory anyway.
    static func stream(
        from samples: [Int16],
        range: Range<Int>,
        format: AVAudioFormat,
        chunkFrames: Int
    ) -> AsyncStream<AnalyzerInput> {
        var inputs: [AnalyzerInput] = []
        // Clamped here as well as in `DecodedAudio.range`, because the copy below is an unchecked
        // pointer write: a range past the end would read off the end of the buffer rather than
        // trapping. Belt and braces on the one line in this file that can corrupt memory.
        let lower = min(max(0, range.lowerBound), samples.count)
        let upper = min(max(lower, range.upperBound), samples.count)
        var offset = lower
        while offset < upper {
            let count = min(chunkFrames, upper - offset)
            guard count > 0,
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: format,
                      frameCapacity: AVAudioFrameCount(count)
                  ),
                  let destination = buffer.int16ChannelData else { break }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                destination[0].update(from: source.baseAddress! + offset, count: count)
            }
            // `AnalyzerInput` is `Sendable` and the buffer was allocated here, so nothing shared
            // crosses the boundary — the same rule the microphone and file paths already follow.
            inputs.append(AnalyzerInput(buffer: buffer))
            offset += count
        }
        return AsyncStream { continuation in
            for input in inputs { continuation.yield(input) }
            continuation.finish()
        }
    }
}
