import Foundation
import Testing
@testable import EdictKit

/// The four calibration points are real measurements taken on this machine, not invented fixtures, so
/// they are pinned first and everything else is arranged around them. If a threshold is ever retuned,
/// these are the tests that must be argued with.
@Suite("RecognitionQuality")
struct RecognitionQualityTests {

    // MARK: Fixtures

    /// Per-word segments, which is what the engine actually produces: a short run of speech, then a
    /// gap. `stride` is the distance between the *starts*, so `stride == span` means continuous
    /// speech and a larger stride opens gaps.
    private func segments(
        count: Int,
        span: TimeInterval,
        stride: TimeInterval,
        start: TimeInterval = 0,
        confidence: Double? = nil
    ) -> [TranscriptSegment] {
        (0..<count).map { index in
            let begin = start + Double(index) * stride
            return TranscriptSegment(start: begin, end: begin + span, text: "w", confidence: confidence)
        }
    }

    // MARK: Calibration — the four measured points

    /// clean synthetic speech, SpeechTranscriber en-US: 819 words / 300 s = 164 wpm.
    @Test("Clean speech at 164 wpm is good and says nothing")
    func cleanSpeechIsGood() {
        let quality = RecognitionQuality.assess(
            wordCount: 819,
            audioDuration: 300,
            speechDuration: nil,
            segments: []
        )
        #expect(quality.verdict == .good)
        #expect(quality.wordsPerMinute > 163 && quality.wordsPerMinute < 165)
        #expect(quality.explanation == nil)
        #expect(quality.isConcerning == false)
    }

    /// the real meeting, SpeechTranscriber en-US: 61 words / 300 s = 12 wpm.
    @Test("The meeting slice on en-US, 12 wpm, is very poor")
    func meetingSliceGeneralModel() {
        let quality = RecognitionQuality.assess(
            wordCount: 61,
            audioDuration: 300,
            speechDuration: nil,
            segments: []
        )
        #expect(quality.verdict == .veryPoor)
        #expect(quality.explanation != nil)
    }

    /// the real meeting, DictationTranscriber id-ID: 18 words / 300 s = 4 wpm. Fluent, correct
    /// Indonesian — and still nowhere near enough of the meeting to be a transcript of it.
    @Test("The meeting slice on id-ID, 4 wpm, is very poor even though the words are correct")
    func meetingSliceIndonesian() {
        let quality = RecognitionQuality.assess(
            wordCount: 18,
            audioDuration: 300,
            speechDuration: nil,
            segments: []
        )
        #expect(quality.verdict == .veryPoor)
    }

    /// the full 70-minute import: 1128 words / 4197 s = 16 wpm. This is the transcript the user had
    /// to read in full to discover had failed.
    @Test("The full 70-minute import, 16 wpm, is very poor and names the rate")
    func fullImport() throws {
        let quality = RecognitionQuality.assess(
            wordCount: 1128,
            audioDuration: 4197,
            speechDuration: nil,
            segments: []
        )
        #expect(quality.verdict == .veryPoor)
        let explanation = try #require(quality.explanation)
        #expect(explanation.contains("16 words per minute"))
        #expect(explanation.contains("70 minutes"))
    }

    // MARK: Threshold boundaries

    @Test("The band boundaries fall where the thresholds say")
    func boundaries() {
        // 30 wpm exactly: the top of the measured-failure band, still very poor.
        #expect(
            RecognitionQuality.assess(wordCount: 30, audioDuration: 60, speechDuration: nil, segments: [])
                .verdict == .veryPoor
        )
        // 45 wpm: got real words, well under any conversational rate.
        #expect(
            RecognitionQuality.assess(wordCount: 45, audioDuration: 60, speechDuration: nil, segments: [])
                .verdict == .sparse
        )
        // 60 wpm exactly: a slow, deliberate speaker. Not a fault.
        #expect(
            RecognitionQuality.assess(wordCount: 60, audioDuration: 60, speechDuration: nil, segments: [])
                .verdict == .good
        )
    }

    // MARK: Short clips must not be flagged

    @Test("A 2-second clip with 4 words is short, not poor")
    func shortClipIsNotFlagged() {
        let quality = RecognitionQuality.assess(
            wordCount: 4,
            audioDuration: 2,
            speechDuration: nil,
            segments: segments(count: 4, span: 0.4, stride: 0.5)
        )
        #expect(quality.verdict == .good)
        #expect(quality.explanation == nil)
    }

    /// Below `minimumAssessableSeconds` a rate estimate is noise, so even a rate that would otherwise
    /// read as a failure is left alone. One word in a two-second clip is a keypress, not a defect.
    @Test("A very short clip is never flagged, even at a failing rate")
    func shortClipAtFailingRateIsNotFlagged() {
        let quality = RecognitionQuality.assess(
            wordCount: 1,
            audioDuration: 2,
            speechDuration: nil,
            segments: []
        )
        #expect(quality.wordsPerMinute == 30)
        #expect(quality.verdict == .good)
        #expect(quality.explanation == nil)
    }

    // MARK: Rate against detected speech, not wall clock

    /// The central requirement: a voice memo that is mostly silence is quiet, not badly recognised.
    /// The same 20 words read 150 wpm against detected speech and 10 wpm against wall clock — one is
    /// a clean recording, the other would be a false alarm shouted at the user.
    @Test("Mostly-silence audio with clear speech is good, judged against detected speech")
    func silenceIsNotPoorQuality() {
        let spoken = segments(count: 20, span: 0.4, stride: 0.4, start: 100)
        let quality = RecognitionQuality.assess(
            wordCount: 20,
            audioDuration: 120,
            speechDuration: 8,
            segments: spoken
        )
        #expect(quality.verdict == .good)
        #expect(quality.wordsPerMinute == 150)
        #expect(quality.explanation == nil)
        // Coverage is still reported honestly, and still does not drive the verdict.
        #expect(quality.coverage < 0.1)
    }

    @Test("The same words against wall clock alone would have been flagged")
    func wallClockWouldHaveFlaggedIt() {
        let quality = RecognitionQuality.assess(
            wordCount: 20,
            audioDuration: 120,
            speechDuration: nil,
            segments: []
        )
        #expect(quality.verdict == .veryPoor)
    }

    @Test("The explanation names which basis the rate was measured against")
    func explanationNamesTheBasis() throws {
        let onSpeech = try #require(
            RecognitionQuality.assess(wordCount: 20, audioDuration: 600, speechDuration: 120, segments: [])
                .explanation
        )
        #expect(onSpeech.contains("detected speech"))
        #expect(!onSpeech.contains("per minute of audio"))

        let onAudio = try #require(
            RecognitionQuality.assess(wordCount: 20, audioDuration: 120, speechDuration: nil, segments: [])
                .explanation
        )
        #expect(onAudio.contains("per minute of audio"))
        #expect(!onAudio.contains("detected speech"))
    }

    @Test("A segmenter total longer than the audio is clamped rather than trusted")
    func speechDurationIsClampedToTheAudio() {
        let quality = RecognitionQuality.assess(
            wordCount: 100,
            audioDuration: 60,
            speechDuration: 6000,
            segments: []
        )
        // Clamped to 60 s, so 100 words per minute — not the 1 wpm the bad input implies.
        #expect(quality.wordsPerMinute == 100)
        #expect(quality.verdict == .good)
    }

    // MARK: Coverage, and dropouts versus uniformly weak recognition

    @Test("Coverage is the merged union of the segment ranges, not their sum")
    func coverageMergesOverlaps() {
        let overlapping = [
            TranscriptSegment(start: 0, end: 30, text: "a"),
            TranscriptSegment(start: 10, end: 40, text: "b"),
            TranscriptSegment(start: 35, end: 50, text: "c")
        ]
        let quality = RecognitionQuality.assess(
            wordCount: 200,
            audioDuration: 100,
            speechDuration: nil,
            segments: overlapping
        )
        // Union is 0...50 of 100 s. Summing the three ranges would have given 75 s.
        #expect(abs(quality.coverage - 0.5) < 0.001)
    }

    /// The long-meeting shape: segments spanning 131 s to 4,117 s, so the whole file was read, but only
    /// ~1,130 of them across 70 minutes. The recognised stretches run at a normal rate; the gaps
    /// between them are enormous. That is a different fault from recognition weakening evenly, and
    /// the wording has to say so — while the verdict stays with the overall rate.
    @Test("Sparse coverage with a plausible local rate reads as dropouts")
    func dropoutsAreDistinguished() throws {
        let quality = RecognitionQuality.assess(
            wordCount: 1128,
            audioDuration: 4197,
            speechDuration: nil,
            segments: segments(count: 1128, span: 0.3, stride: 3.53, start: 131)
        )
        #expect(quality.verdict == .veryPoor)
        #expect(quality.coverage < 0.1)
        let explanation = try #require(quality.explanation)
        #expect(explanation.contains("dropped out"))
        #expect(explanation.contains("rather than"))
    }

    /// The 300-second en-US slice with its 61 words spread thinly but *evenly*: the local rate inside
    /// the recognised stretches is as bad as the overall rate, so this is not a dropout story.
    @Test("Broad coverage with a poor local rate reads as uniformly weak recognition")
    func uniformWeaknessIsDistinguished() throws {
        let quality = RecognitionQuality.assess(
            wordCount: 61,
            audioDuration: 300,
            speechDuration: nil,
            segments: segments(count: 61, span: 3.0, stride: 4.0)
        )
        #expect(quality.verdict == .veryPoor)
        #expect(quality.coverage > 0.5)
        let explanation = try #require(quality.explanation)
        #expect(!explanation.contains("dropped out"))
    }

    @Test("Coverage never rescues or condemns a verdict on its own")
    func coverageDoesNotDriveTheVerdict() {
        // Perfect coverage, hopeless rate.
        let covered = RecognitionQuality.assess(
            wordCount: 16,
            audioDuration: 60,
            speechDuration: nil,
            segments: [TranscriptSegment(start: 0, end: 60, text: "x")]
        )
        #expect(covered.coverage == 1)
        #expect(covered.verdict == .veryPoor)

        // Almost no coverage, healthy rate against detected speech.
        let uncovered = RecognitionQuality.assess(
            wordCount: 100,
            audioDuration: 600,
            speechDuration: 40,
            segments: segments(count: 100, span: 0.4, stride: 0.4)
        )
        #expect(uncovered.coverage < 0.1)
        #expect(uncovered.verdict == .good)
    }

    // MARK: Degenerate inputs

    @Test("Zero words is reported, and the wording covers silence as well as distance")
    func zeroWords() throws {
        let quality = RecognitionQuality.assess(
            wordCount: 0,
            audioDuration: 300,
            speechDuration: nil,
            segments: []
        )
        #expect(quality.verdict == .veryPoor)
        #expect(quality.wordsPerMinute == 0)
        let explanation = try #require(quality.explanation)
        #expect(explanation.contains("No words were recognised"))
        #expect(explanation.contains("5 minutes"))
        // Honest about all three causes rather than picking one and being wrong.
        #expect(explanation.contains("quiet"))
        #expect(explanation.contains("distant"))
    }

    /// Nothing to measure is not the same as a failure, and a false alarm here would teach the user
    /// to ignore the real ones.
    @Test("Zero duration is unassessable rather than poor")
    func zeroDuration() {
        let quality = RecognitionQuality.assess(
            wordCount: 0,
            audioDuration: 0,
            speechDuration: nil,
            segments: []
        )
        #expect(quality.verdict == .good)
        #expect(quality.wordsPerMinute == 0)
        #expect(quality.coverage == 0)
        #expect(quality.explanation == nil)
    }

    @Test("Non-finite and negative inputs do not produce a NaN verdict")
    func nonFiniteInputs() {
        let nan = RecognitionQuality.assess(
            wordCount: 10,
            audioDuration: .nan,
            speechDuration: .infinity,
            segments: [TranscriptSegment(start: .nan, end: .nan, text: "x")]
        )
        #expect(nan.verdict == .good)
        #expect(nan.wordsPerMinute.isFinite)
        #expect(nan.coverage == 0)

        let negative = RecognitionQuality.assess(
            wordCount: -5,
            audioDuration: -300,
            speechDuration: -10,
            segments: []
        )
        #expect(negative.verdict == .good)
        #expect(negative.wordsPerMinute == 0)
    }

    // MARK: Confidence is optional and never load-bearing

    /// `SpeechTranscriber` returns a confidence per word; `DictationTranscriber` on `id_ID` returned
    /// one on none of 38 measured runs. So the field must be absent without changing anything.
    @Test("Confidence absent versus present changes the field, not the verdict")
    func confidenceIsNotLoadBearing() {
        let without = RecognitionQuality.assess(
            wordCount: 61,
            audioDuration: 300,
            speechDuration: nil,
            segments: segments(count: 61, span: 3.0, stride: 4.0, confidence: nil)
        )
        let with = RecognitionQuality.assess(
            wordCount: 61,
            audioDuration: 300,
            speechDuration: nil,
            segments: segments(count: 61, span: 3.0, stride: 4.0, confidence: 0.31)
        )
        #expect(without.meanConfidence == nil)
        #expect(with.meanConfidence != nil)
        #expect(abs((with.meanConfidence ?? 0) - 0.31) < 0.001)
        #expect(without.verdict == with.verdict)
        #expect(without.wordsPerMinute == with.wordsPerMinute)
        #expect(without.coverage == with.coverage)
    }

    @Test("A high confidence does not soften a bad verdict, and is not mentioned")
    func highConfidenceDoesNotSoftenTheVerdict() throws {
        let quality = RecognitionQuality.assess(
            wordCount: 61,
            audioDuration: 300,
            speechDuration: nil,
            segments: segments(count: 61, span: 3.0, stride: 4.0, confidence: 0.99)
        )
        #expect(quality.verdict == .veryPoor)
        let explanation = try #require(quality.explanation)
        #expect(!explanation.contains("confidence"))
    }

    @Test("A low mean confidence is mentioned when the engine supplied one")
    func lowConfidenceIsMentioned() throws {
        let quality = RecognitionQuality.assess(
            wordCount: 61,
            audioDuration: 300,
            speechDuration: nil,
            segments: segments(count: 61, span: 3.0, stride: 4.0, confidence: 0.41)
        )
        let explanation = try #require(quality.explanation)
        #expect(explanation.contains("confidence"))
        #expect(explanation.contains("0.41"))
    }

    @Test("A mix of segments with and without confidence averages only the ones that have it")
    func partialConfidence() {
        let mixed = [
            TranscriptSegment(start: 0, end: 1, text: "a", confidence: 0.2),
            TranscriptSegment(start: 1, end: 2, text: "b", confidence: nil),
            TranscriptSegment(start: 2, end: 3, text: "c", confidence: 0.6)
        ]
        let quality = RecognitionQuality.assess(
            wordCount: 3,
            audioDuration: 60,
            speechDuration: nil,
            segments: mixed
        )
        #expect(abs((quality.meanConfidence ?? 0) - 0.4) < 0.001)
    }

    // MARK: The wording itself

    /// The brief on this is explicit, and the measurements back it: conditioning the audio moved 61
    /// words to 75, and the id-ID pass produced 18 fluent words where en-US produced 0. Dual-language
    /// selection helps clean bilingual audio and does nothing for a far-field meeting. So the
    /// explanation must not offer a remedy Edict does not have.
    @Test("No explanation promises that a setting would fix it")
    func noExplanationPromisesAFix() {
        let cases: [RecognitionQuality] = [
            .assess(wordCount: 1128, audioDuration: 4197, speechDuration: nil, segments: []),
            .assess(wordCount: 61, audioDuration: 300, speechDuration: nil, segments: []),
            .assess(wordCount: 18, audioDuration: 300, speechDuration: nil, segments: []),
            .assess(wordCount: 0, audioDuration: 300, speechDuration: nil, segments: []),
            .assess(wordCount: 200, audioDuration: 300, speechDuration: nil, segments: []),
            .assess(
                wordCount: 1128,
                audioDuration: 4197,
                speechDuration: nil,
                segments: segments(count: 1128, span: 0.3, stride: 3.53, start: 131)
            )
        ]
        let banned = [
            "try ", "settings", "enable", "switch to", "language setting", "instead", "should fix",
            "will fix", "improve the", "adjust"
        ]
        for quality in cases {
            guard let explanation = quality.explanation else { continue }
            let lowered = explanation.lowercased()
            for phrase in banned {
                #expect(!lowered.contains(phrase), "\"\(phrase)\" appears in: \(explanation)")
            }
        }
    }

    /// That recording was a competently captured meeting. Nothing was done wrong, and the
    /// sentence must describe the acoustics rather than the person holding the phone.
    @Test("No explanation blames the user or waves at bad quality")
    func noExplanationBlamesTheUser() {
        let cases: [RecognitionQuality] = [
            .assess(wordCount: 1128, audioDuration: 4197, speechDuration: nil, segments: []),
            .assess(wordCount: 200, audioDuration: 300, speechDuration: nil, segments: []),
            .assess(wordCount: 0, audioDuration: 300, speechDuration: nil, segments: [])
        ]
        let banned = ["your fault", "you should", "bad audio", "poor quality", "low quality", "bad recording"]
        for quality in cases {
            guard let explanation = quality.explanation else { continue }
            let lowered = explanation.lowercased()
            for phrase in banned {
                #expect(!lowered.contains(phrase), "\"\(phrase)\" appears in: \(explanation)")
            }
        }
    }

    /// Vague warnings get dismissed. Every explanation has to carry a number the user can act on.
    @Test("Every explanation is one sentence and names a measured number")
    func explanationsAreSpecificAndSingular() throws {
        let cases: [RecognitionQuality] = [
            .assess(wordCount: 1128, audioDuration: 4197, speechDuration: nil, segments: []),
            .assess(wordCount: 61, audioDuration: 300, speechDuration: nil, segments: []),
            .assess(wordCount: 200, audioDuration: 300, speechDuration: nil, segments: []),
            .assess(wordCount: 0, audioDuration: 300, speechDuration: nil, segments: []),
            .assess(
                wordCount: 1128,
                audioDuration: 4197,
                speechDuration: nil,
                segments: segments(count: 1128, span: 0.3, stride: 3.53, start: 131)
            )
        ]
        for quality in cases {
            let explanation = try #require(quality.explanation)
            let hasNumber = explanation.contains { $0.isNumber }
            #expect(hasNumber)
            #expect(explanation.hasSuffix("."))
            // One sentence: a single terminating period, at the end.
            #expect(explanation.filter { $0 == "." }.count == 1)
        }
    }

    @Test("Only the good verdict is silent")
    func onlyGoodIsSilent() {
        #expect(
            RecognitionQuality.assess(wordCount: 819, audioDuration: 300, speechDuration: nil, segments: [])
                .explanation == nil
        )
        #expect(
            RecognitionQuality.assess(wordCount: 200, audioDuration: 300, speechDuration: nil, segments: [])
                .verdict == .sparse
        )
        #expect(
            RecognitionQuality.assess(wordCount: 200, audioDuration: 300, speechDuration: nil, segments: [])
                .explanation != nil
        )
    }

    // MARK: Codable, because this is stored on the transcript

    @Test("Round-trips through JSON")
    func roundTrip() throws {
        let original = RecognitionQuality.assess(
            wordCount: 1128,
            audioDuration: 4197,
            speechDuration: nil,
            segments: segments(count: 1128, span: 0.3, stride: 3.53, start: 131, confidence: 0.42)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecognitionQuality.self, from: data)
        #expect(decoded == original)
    }

    @Test("A nil confidence is omitted from the JSON rather than written as null")
    func nilConfidenceIsOmitted() throws {
        let quality = RecognitionQuality.assess(
            wordCount: 61,
            audioDuration: 300,
            speechDuration: nil,
            segments: []
        )
        let json = try #require(String(data: try JSONEncoder().encode(quality), encoding: .utf8))
        #expect(!json.contains("meanConfidence"))
    }

    /// Lenient for the same reason `Transcript` is: this rides along in `history.json`, which is far
    /// too valuable to fail to load over one key.
    @Test("An unreadable or future verdict degrades to good rather than inventing a warning")
    func lenientDecoding() throws {
        let unknown = Data(#"{"verdict":"catastrophic","wordsPerMinute":16,"explanation":"…"}"#.utf8)
        let decoded = try JSONDecoder().decode(RecognitionQuality.self, from: unknown)
        #expect(decoded.verdict == .good)
        #expect(decoded.explanation == nil)

        let empty = try JSONDecoder().decode(RecognitionQuality.self, from: Data("{}".utf8))
        #expect(empty.verdict == .good)
        #expect(empty.wordsPerMinute == 0)
        #expect(empty.coverage == 0)
        #expect(empty.meanConfidence == nil)
    }

    @Test("A coverage outside 0...1 in a hand-edited file is clamped on the way in")
    func decodedCoverageIsClamped() throws {
        let high = try JSONDecoder().decode(
            RecognitionQuality.self,
            from: Data(#"{"verdict":"sparse","wordsPerMinute":40,"coverage":9}"#.utf8)
        )
        #expect(high.coverage == 1)
        let low = try JSONDecoder().decode(
            RecognitionQuality.self,
            from: Data(#"{"verdict":"sparse","wordsPerMinute":40,"coverage":-3}"#.utf8)
        )
        #expect(low.coverage == 0)
    }
}
