import Foundation

/// How much of the audio the recogniser actually turned into words, and one honest sentence about it.
///
/// **Why this type exists.** A real 70-minute meeting recording (stereo 48 kHz, two-plus
/// speakers, Indonesian and English code-switched, recorded at a distance) was imported and produced
/// 1,128 words for 4,197 seconds: about 16 words per minute against ~150 for ordinary speech. The
/// output was largely filler and empty runs. Every number needed to say so was already in hand —
/// word count, audio duration, segment ranges — and the app said nothing, so the failure was only
/// discoverable by reading 1,128 words of filler. That silence is the defect this type closes.
///
/// **What it is not.** It is not a fix. Measured on a 300-second slice of that same file:
///
///     clean synthetic speech, SpeechTranscriber en-US ......... 819 words / 300 s = 164 wpm
///     the real meeting, SpeechTranscriber en-US ................ 61 words / 300 s =  12 wpm
///     the real meeting, +7 dB / highpass / compressed .......... 75 words / 300 s =  15 wpm
///     the real meeting, DictationTranscriber id-ID ............. 18 words / 300 s =   4 wpm
///     the real meeting, DictationTranscriber en-US .............. 0 words / 300 s =   0 wpm
///
/// Levels were fine throughout (mean −29.6 dB, I = −25.9 LUFS, `droppedBuffers` 0, segments spanning
/// 131 s to 4,117 s), so nothing was lost or unread — Apple's on-device models are simply
/// conservative, and on far-field overlapping reverberant speech they emit nothing rather than guess.
/// Conditioning the audio moved 61 words to 75, which is noise. **Nothing in Edict's settings
/// recovers audio like this, and no explanation this type produces may pretend otherwise.**
public struct RecognitionQuality: Sendable, Hashable, Codable {

    /// How the assessment came out. Three levels, because that is as much resolution as the
    /// measurements above support: plainly fine, plainly broken, and an honest middle.
    public enum Verdict: String, Sendable, Codable, CaseIterable {
        /// The rate is consistent with someone speaking. Nothing to warn about.
        case good
        /// Words came back, but well under any plausible speaking rate — passages are missing.
        case sparse
        /// The rate is in the range measured on audio the models could not read at all.
        case veryPoor
    }

    public var verdict: Verdict
    /// Words per minute on the basis named in `explanation` — detected speech where a
    /// `SpeechSegmenter` measurement was available, otherwise wall-clock audio.
    public var wordsPerMinute: Double
    /// Fraction of the timeline covered by recognised segments, 0...1.
    public var coverage: Double
    public var meanConfidence: Double?
    /// One plain sentence for the UI. Never blames the user's file in vague terms.
    public var explanation: String?

    public init(
        verdict: Verdict,
        wordsPerMinute: Double,
        coverage: Double = 0,
        meanConfidence: Double? = nil,
        explanation: String? = nil
    ) {
        self.verdict = verdict
        self.wordsPerMinute = wordsPerMinute
        self.coverage = coverage
        self.meanConfidence = meanConfidence
        self.explanation = explanation
    }

    // MARK: - Thresholds

    /// Boundaries, all derived from the table in this type's doc comment rather than invented.
    ///
    /// Ordinary conversational speech runs 120–150 wpm and the clean-speech control measured 164.
    /// Every failing measurement — 4, 12, 15, and 16 wpm — sat under 20.
    public enum Threshold {
        /// At or above this, the transcript is not flagged: 60 wpm is half of the *slowest* ordinary
        /// conversational rate, which leaves room for a deliberate speaker, thinking pauses, or a
        /// dictation full of hesitation, while still sitting almost 4x above the worst measurement
        /// taken on audio that genuinely failed.
        public static let goodWordsPerMinute: Double = 60

        /// At or below this, the verdict is `.veryPoor`: 30 wpm is a quarter of the slowest ordinary
        /// rate and nearly double the 16 wpm the full 70-minute import managed, so the whole
        /// measured failure band falls comfortably inside it without reaching any rate a human
        /// speaking continuously could produce.
        public static let veryPoorWordsPerMinute: Double = 30

        /// Below this much speech there is no rate worth trusting. At 120 wpm ten seconds is twenty
        /// words, so a couple of words either way swings the estimate by tens of wpm — which is how
        /// a perfectly good two-second clip would otherwise be flagged as a failure.
        public static let minimumAssessableSeconds: TimeInterval = 10

        /// Coverage under this, combined with a plausible rate *inside* the recognised stretches, is
        /// read as dropouts rather than as uniformly weak recognition. Continuous speech with pauses
        /// still covers well over half a timeline; that meeting import covered about 8 %.
        public static let dropoutCoverage: Double = 0.5

        /// Mean word confidence at or below this is worth mentioning. RECON: under ~0.5 is strongly
        /// indicative of a mishearing (0.05 for a misheard "Visa", against 0.998 for a correct word).
        public static let lowConfidence: Double = 0.5
    }

    // MARK: - Assessment

    /// Assess a finished transcription.
    ///
    /// - Parameters:
    ///   - wordCount: Words in the transcript.
    ///   - audioDuration: Wall-clock length of the audio.
    ///   - speechDuration: Seconds of *detected speech*, from `SpeechSegmenter` where one ran. When
    ///     present this is the rate's denominator, because a voice memo that is 80 % silence is
    ///     quiet, not badly recognised — judging it against wall clock would flag it wrongly.
    ///   - segments: Timed segments as the engine reported them, used for coverage and confidence.
    public static func assess(
        wordCount: Int,
        audioDuration: TimeInterval,
        speechDuration: TimeInterval?,
        segments: [TranscriptSegment]
    ) -> RecognitionQuality {
        let words = max(0, wordCount)
        let audio = audioDuration.isFinite ? max(0, audioDuration) : 0
        let covered = coveredSeconds(in: segments, audioDuration: audio)
        let clampedCoverage = audio > 0 ? min(1, max(0, covered / audio)) : 0
        let confidence = meanConfidence(of: segments)

        // A file with no measurable length says nothing about the recogniser — an empty import, a
        // zero-length capture, a caller that has not filled the duration in yet. Refusing to judge
        // is the honest answer, and a false alarm here would teach the user to ignore the real ones.
        //
        // Rate against detected speech when we have it; clamped to the audio, since a segmenter
        // total longer than the file is a bug in the caller, not a very fast talker.
        let speech = speechDuration.flatMap { value -> TimeInterval? in
            guard value.isFinite, value > 0 else { return nil }
            return audio > 0 ? min(value, audio) : value
        }
        guard audio > 0 || (speech ?? 0) > 0 else {
            return RecognitionQuality(
                verdict: .good,
                wordsPerMinute: 0,
                coverage: 0,
                meanConfidence: confidence,
                explanation: nil
            )
        }

        let basis: Basis = speech == nil ? .audio : .detectedSpeech
        let basisSeconds = speech ?? audio
        let rate = basisSeconds > 0 ? Double(words) * 60 / basisSeconds : 0

        // Nothing at all came back. There is no rate to be noisy about, so the short-clip guard
        // below does not apply: silence is a result the user needs told either way.
        if words == 0 {
            return RecognitionQuality(
                verdict: .veryPoor,
                wordsPerMinute: 0,
                coverage: clampedCoverage,
                meanConfidence: confidence,
                explanation: noSpeechExplanation(audioDuration: audio, basisSeconds: basisSeconds)
            )
        }

        // Too little speech to judge a rate on. See `Threshold.minimumAssessableSeconds`.
        if basisSeconds < Threshold.minimumAssessableSeconds {
            return RecognitionQuality(
                verdict: .good,
                wordsPerMinute: rate,
                coverage: clampedCoverage,
                meanConfidence: confidence,
                explanation: nil
            )
        }

        let verdict: Verdict
        if rate >= Threshold.goodWordsPerMinute {
            verdict = .good
        } else if rate <= Threshold.veryPoorWordsPerMinute {
            verdict = .veryPoor
        } else {
            verdict = .sparse
        }

        guard verdict != .good else {
            return RecognitionQuality(
                verdict: .good,
                wordsPerMinute: rate,
                coverage: clampedCoverage,
                meanConfidence: confidence,
                explanation: nil
            )
        }

        // Coverage is the second signal, and it separates two different faults. That meeting import
        // had segments spanning 131 s to 4,117 s — the whole file was read — but only ~1,130 of them
        // over 70 minutes, so the recognised stretches ran at a normal rate and the gaps between
        // them were enormous. That is recognition dropping out, not recognition degrading evenly,
        // and it is worth saying differently. It does not change the verdict: the overall rate is
        // still what determines whether the transcript is usable.
        let localRate = covered > 0 ? Double(words) * 60 / covered : 0
        let droppedOut = !segments.isEmpty
            && clampedCoverage > 0
            && clampedCoverage < Threshold.dropoutCoverage
            && localRate >= Threshold.goodWordsPerMinute

        let explanation = droppedOut
            ? dropoutExplanation(
                verdict: verdict,
                rate: rate,
                basis: basis,
                coverage: clampedCoverage,
                localRate: localRate,
                audioDuration: audio,
                confidence: confidence
            )
            : uniformExplanation(
                verdict: verdict,
                rate: rate,
                basis: basis,
                basisSeconds: basisSeconds,
                confidence: confidence
            )

        return RecognitionQuality(
            verdict: verdict,
            wordsPerMinute: rate,
            coverage: clampedCoverage,
            meanConfidence: confidence,
            explanation: explanation
        )
    }

    // MARK: - Convenience

    /// True when there is something for the UI to say. Equivalently: `explanation` may be non-nil.
    public var isConcerning: Bool { verdict != .good }

    // MARK: - Derived measurements

    /// Which denominator the rate was computed against. Named in the explanation, because "16 words
    /// a minute" means two different things depending on whether the silence was counted.
    private enum Basis {
        case detectedSpeech
        case audio

        var phrase: String {
            switch self {
            case .detectedSpeech: "detected speech"
            case .audio: "audio"
            }
        }
    }

    /// Union of the segment ranges, in seconds. Merged rather than summed: engine ranges are
    /// monotonic but not guaranteed disjoint, and double-counting an overlap would inflate coverage
    /// past 1 and hide exactly the dropouts this measurement exists to find.
    private static func coveredSeconds(in segments: [TranscriptSegment], audioDuration: TimeInterval) -> TimeInterval {
        let ranges: [(start: TimeInterval, end: TimeInterval)] = segments.compactMap { segment in
            guard segment.start.isFinite, segment.end.isFinite else { return nil }
            let start = max(0, segment.start)
            let end = audioDuration > 0 ? min(segment.end, audioDuration) : segment.end
            guard end > start else { return nil }
            return (start, end)
        }
        .sorted { $0.start < $1.start }

        var total: TimeInterval = 0
        var open: (start: TimeInterval, end: TimeInterval)?
        for range in ranges {
            guard var current = open else {
                open = range
                continue
            }
            if range.start <= current.end {
                current.end = max(current.end, range.end)
                open = current
            } else {
                total += current.end - current.start
                open = range
            }
        }
        if let open { total += open.end - open.start }
        return total
    }

    /// Mean of the confidences the engine supplied, or `nil` when it supplied none.
    ///
    /// Optional and never load-bearing: `SpeechTranscriber` returns a confidence per word, while
    /// `DictationTranscriber` on `id_ID` returned time ranges on all 38 measured runs and a
    /// confidence on **none** of them. A verdict that needed this number would be silently
    /// unavailable for Indonesian, so no branch above reads it.
    private static func meanConfidence(of segments: [TranscriptSegment]) -> Double? {
        let values = segments.compactMap(\.confidence).filter(\.isFinite)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    // MARK: - Wording
    //
    // Rules these sentences obey, all of them earned:
    //  * Name the measured rate and its basis. "Quality may be poor" is not information.
    //  * Describe the acoustics — distance, overlapping voices, reverberation — not the user. The
    //    recording behind these numbers was a competently captured meeting; nothing was done wrong.
    //  * Never promise that a setting recovers it. Conditioning moved 61 words to 75, and the
    //    id-ID pass produced 18 fluent words where en-US produced 0. Dual-language selection helps
    //    *clean* bilingual audio and does nothing for this, so it must not be offered as a remedy.

    private static func noSpeechExplanation(
        audioDuration: TimeInterval,
        basisSeconds: TimeInterval
    ) -> String {
        let length = duration(audioDuration > 0 ? audioDuration : basisSeconds)
        return "No words were recognised in \(length) of audio — on-device recognition returns nothing "
            + "rather than guessing, so this is what silence, a very quiet recording, or voices too "
            + "distant for the model all look like, and no Edict setting changes it."
    }

    private static func uniformExplanation(
        verdict: Verdict,
        rate: Double,
        basis: Basis,
        basisSeconds: TimeInterval,
        confidence: Double?
    ) -> String {
        let measured = "\(words(perMinute: rate)) per minute of \(basis.phrase) over \(duration(basisSeconds))"
        let confidenceClause = clause(for: confidence)
        switch verdict {
        case .veryPoor:
            return "Edict recognised only \(measured), against 120–150 for ordinary speech\(confidenceClause) "
                + "— on-device recognition emits nothing rather than guessing when voices are distant, "
                + "overlapping or in a reverberant room, and no Edict setting recovers that, so read this "
                + "transcript as substantially incomplete."
        case .sparse, .good:
            return "Edict recognised \(measured), well under the 120–150 of ordinary "
                + "speech\(confidenceClause), so passages are likely missing; recordings made close to one "
                + "speaker at a time transcribe far better than distant or overlapping ones."
        }
    }

    private static func dropoutExplanation(
        verdict: Verdict,
        rate: Double,
        basis: Basis,
        coverage: Double,
        localRate: Double,
        audioDuration: TimeInterval,
        confidence: Double?
    ) -> String {
        let percent = Int((coverage * 100).rounded())
        let shape = "Recognised speech covers only \(min(max(percent, 1), 99))% of this \(durationAdjective(audioDuration)) "
            + "recording, and the stretches that were recognised run at \(words(perMinute: localRate)) per "
            + "minute while the recording as a whole manages \(words(perMinute: rate)) per minute of \(basis.phrase)"
        let confidenceClause = clause(for: confidence)
        switch verdict {
        case .veryPoor:
            return shape + "\(confidenceClause) — recognition dropped out across long gaps rather than "
                + "weakening evenly, which is what distant or overlapping voices do to on-device models, "
                + "and no Edict setting recovers it, so whole passages are missing from this transcript."
        case .sparse, .good:
            return shape + "\(confidenceClause) — recognition dropped out across long gaps rather than "
                + "weakening evenly, so passages are missing between the parts that came through."
        }
    }

    /// Mentioned only when the engine supplied confidences and they are low. Never load-bearing, and
    /// absent entirely for locales where the engine reports no confidence at all.
    private static func clause(for confidence: Double?) -> String {
        guard let confidence, confidence <= Threshold.lowConfidence else { return "" }
        return ", with mean word confidence at only \(twoDecimals(confidence))"
    }

    // MARK: - Formatting
    //
    // Hand-formatted rather than `NumberFormatter`/`Measurement`: these strings are compared exactly
    // in tests, and a locale-sensitive formatter would make them depend on the machine. This one
    // reports `en_ID` (RECON §7), which is exactly the sort of surprise not worth inviting here.

    private static func words(perMinute rate: Double) -> String {
        let rounded = Int(rate.rounded())
        return rounded == 1 ? "1 word" : "\(rounded) words"
    }

    private static func twoDecimals(_ value: Double) -> String {
        let scaled = min(100, max(0, Int((value * 100).rounded())))
        if scaled == 100 { return "1.00" }
        return "0.\(scaled < 10 ? "0" : "")\(scaled)"
    }

    /// The attributive form — "70-minute", not "70 minutes" — for "this 70-minute recording".
    private static func durationAdjective(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0-second" }
        if seconds < 90 { return "\(max(1, Int(seconds.rounded())))-second" }
        if seconds < 7200 { return "\(max(1, Int((seconds / 60).rounded())))-minute" }
        return "\(max(1, Int((seconds / 3600).rounded())))-hour"
    }

    /// Whole seconds under 90, whole minutes under two hours, hours and minutes beyond. Chosen so the
    /// 4,197-second import reads as "70 minutes", which is what it is called in conversation.
    private static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 seconds" }
        if seconds < 90 {
            let whole = max(1, Int(seconds.rounded()))
            return whole == 1 ? "1 second" : "\(whole) seconds"
        }
        if seconds < 7200 {
            let minutes = max(1, Int((seconds / 60).rounded()))
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        let totalMinutes = Int((seconds / 60).rounded())
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        let hourPart = hours == 1 ? "1 hour" : "\(hours) hours"
        guard minutes > 0 else { return hourPart }
        return "\(hourPart) \(minutes == 1 ? "1 minute" : "\(minutes) minutes")"
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case verdict, wordsPerMinute, coverage, meanConfidence, explanation
    }

    /// Lenient, for the same reason `Transcript` is: this is stored on a transcript so history can
    /// show it later, and a history file is far too valuable to fail to load over one key. An
    /// unreadable or future verdict degrades to `.good` with no explanation — a missing warning is a
    /// smaller harm than a warning invented from a value we could not parse.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdict = (try? c.decode(Verdict.self, forKey: .verdict)) ?? .good
        wordsPerMinute = (try? c.decodeIfPresent(Double.self, forKey: .wordsPerMinute)) ?? 0
        coverage = min(1, max(0, (try? c.decodeIfPresent(Double.self, forKey: .coverage)) ?? 0))
        meanConfidence = try? c.decodeIfPresent(Double.self, forKey: .meanConfidence)
        explanation = verdict == .good
            ? nil
            : (try? c.decodeIfPresent(String.self, forKey: .explanation)) ?? nil
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(verdict, forKey: .verdict)
        try c.encode(wordsPerMinute, forKey: .wordsPerMinute)
        try c.encode(coverage, forKey: .coverage)
        try c.encodeIfPresent(meanConfidence, forKey: .meanConfidence)
        try c.encodeIfPresent(explanation, forKey: .explanation)
    }
}
