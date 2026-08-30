import AVFoundation
import Foundation
import Speech
import Testing

@testable import EdictKit

// Tests for the dual-pass import and the difficult-audio warning.
//
// The transcription itself is injected, so nothing here needs a speech model, a microphone or a
// download. What is being tested is the part that can be wrong without anything crashing: which
// candidate wins, what the fallback does when the evidence is thin, that section-relative times
// become file-relative ones, that a language's share is measured in audio and not in words, and that
// the quality warning fires on the right recordings and stays silent on the rest.

// MARK: - Fixtures

/// 16 kHz mono Int16, the analyzer's format and the one `DecodedAudio` is always in.
private let analyzerFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16,
    sampleRate: 16_000,
    channels: 1,
    interleaved: true
)!

/// Speech-like audio for `seconds`, then silence for `then`.
///
/// A 200 Hz square-ish tone at a healthy level, which is all `SpeechSegmenter` needs: its gate is a
/// percentile of the file's own energy, so what matters is that the loud part is well above the quiet
/// part, not that it sounds like a voice.
private func tone(_ seconds: Double, then silence: Double, amplitude: Int16 = 12_000) -> [Int16] {
    let rate = 16_000.0
    var out: [Int16] = []
    let voiced = Int(seconds * rate)
    for i in 0..<voiced {
        out.append(Int(Double(i) / rate * 200) % 2 == 0 ? amplitude : -amplitude)
    }
    out.append(contentsOf: [Int16](repeating: 0, count: Int(silence * rate)))
    return out
}

private func decoded(_ samples: [Int16]) -> DecodedAudio {
    DecodedAudio(samples: samples, sampleRate: 16_000, stats: ImportStats())
}

/// A pass that returns canned text, in order, one entry per section.
private func scriptedPass(
    _ locale: String,
    module: TranscriptionModule = .dictation,
    texts: [String]
) -> DualPassImporter.Pass {
    let box = TextBox(texts)
    return DualPassImporter.Pass(localeIdentifier: locale, module: module) { stream in
        // The stream still has to be drained: the production `transcribe` consumes it, and a pass
        // that did not would let a bug where the audio is never built pass unnoticed.
        var frames = 0
        for await input in stream { frames += Int(input.buffer.frameLength) }
        let text = box.next()
        return TranscriptionOutcome(
            text: text,
            confidence: nil,
            latency: 0,
            audioDuration: Double(frames) / 16_000,
            words: runs(in: text)
        )
    }
}

/// Per-word runs with plausible section-relative timings, one word every 0.4 s.
private func runs(in text: String, confidence: Double? = 0.9) -> [WordConfidence] {
    text.split(whereSeparator: { $0.isWhitespace }).enumerated().map { index, word in
        WordConfidence(
            text: String(word),
            confidence: confidence,
            startSeconds: Double(index) * 0.4,
            endSeconds: Double(index) * 0.4 + 0.3
        )
    }
}

/// Hands out scripted texts in order, and repeats the last one forever so a test does not have to
/// know exactly how many sections the segmenter found.
private final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String]
    private var index = 0
    init(_ texts: [String]) { self.texts = texts }
    func next() -> String {
        lock.withLock {
            defer { index += 1 }
            return texts.isEmpty ? "" : texts[min(index, texts.count - 1)]
        }
    }
}

// MARK: - Section audio

@Suite("Dual pass — section audio")
struct DualPassAudioTests {

    @Test("A section's stream carries exactly that section's samples, in ~100 ms chunks")
    func sectionStream() async {
        // A ramp, so a mis-sliced range is detectable in the values and not only in the count.
        let samples = (0..<16_000).map { Int16($0 % 1000) }
        let stream = DualPassImporter.stream(
            from: samples,
            range: 4_000..<12_000,
            format: analyzerFormat,
            chunkFrames: 1_600
        )
        var collected: [Int16] = []
        var chunks = 0
        for await input in stream {
            chunks += 1
            let buffer = input.buffer
            let count = Int(buffer.frameLength)
            collected.append(contentsOf: UnsafeBufferPointer(start: buffer.int16ChannelData![0], count: count))
        }
        #expect(chunks == 5)
        #expect(collected == Array(samples[4_000..<12_000]))
    }

    @Test("A range past the end of the samples yields nothing rather than reading off the end")
    func emptyRange() async {
        let stream = DualPassImporter.stream(
            from: [Int16](repeating: 0, count: 100),
            range: 500..<600,
            format: analyzerFormat,
            chunkFrames: 1_600
        )
        var chunks = 0
        for await _ in stream { chunks += 1 }
        #expect(chunks == 0)
    }

    @Test("DecodedAudio.range clamps to what was decoded")
    func rangeClamping() {
        let audio = decoded([Int16](repeating: 0, count: 16_000))   // 1 s
        #expect(audio.range(from: 0, to: 0.5) == 0..<8_000)
        #expect(audio.range(from: 0.5, to: 99) == 8_000..<16_000)
        #expect(audio.range(from: 5, to: 6) == 16_000..<16_000)
        #expect(audio.range(from: -1, to: 0.25) == 0..<4_000)
    }
}

// MARK: - Choosing

@Suite("Dual pass — choosing a language")
struct DualPassChoiceTests {

    /// Two sections separated by a full second of silence, so the segmenter reliably finds two.
    private func twoSections() -> DecodedAudio {
        decoded(tone(3, then: 1.0) + tone(3, then: 0.4))
    }

    @Test("Each section keeps the transcript that reads like the language that produced it")
    func perSectionChoice() async throws {
        let runner = DualPassImporter()
        let audio = twoSections()
        #expect(runner.sections(in: audio).count == 2)

        let outcome = try await runner.run(
            decoded: audio,
            format: analyzerFormat,
            passes: [
                scriptedPass("en-US", texts: [
                    "Okay team let us review the quarterly numbers before we start",
                    "By saya sudasiapkan la poranca uangan untokuarta ini",
                ]),
                scriptedPass("id-ID", texts: [
                    "Oke gym let with the cordy numbers for",
                    "Baik saya sudah siapkan laporan keuangan untuk kuartal ini",
                ]),
            ]
        )

        #expect(outcome.sections.count == 2)
        #expect(outcome.sections[0].chosenLocale == "en-US")
        #expect(outcome.sections[1].chosenLocale == "id-ID")
        #expect(outcome.sections.count { $0.isConfident } == 2)
        #expect(outcome.passesRun == 4)
        #expect(outcome.text.contains("quarterly numbers"))
        #expect(outcome.text.contains("laporan keuangan"))
        // Both languages contributed, so the transcript is mixed and the dominant one is whichever
        // won more *audio* — here they are the same length, so the order is the tie-break.
        #expect(outcome.isMixed)
        #expect(Set(outcome.localeIdentifiers) == ["en-US", "id-ID"])
    }

    @Test("A section with no language evidence falls back to the primary locale")
    func fallbackToPrimary() async throws {
        let runner = DualPassImporter()
        // Proper nouns only: no function words for either profile, so `LanguageScorer` cannot reach
        // `isConfident` and the primary must win by fallback rather than by margin.
        let outcome = try await runner.run(
            decoded: decoded(tone(3, then: 0.4)),
            format: analyzerFormat,
            passes: [
                scriptedPass("en-US", texts: ["Pertamina Jakarta Anthropic"]),
                scriptedPass("id-ID", texts: ["Pertamina Jakarta Anthropic"]),
            ]
        )
        let section = try #require(outcome.sections.first)
        #expect(section.isConfident == false)
        #expect(section.chosenLocale == "en-US")
        #expect(outcome.localeIdentifiers == ["en-US"])
        #expect(outcome.isMixed == false)
    }

    @Test("Passing the secondary first makes IT the fallback — order is the caller's choice")
    func fallbackFollowsOrder() async throws {
        let runner = DualPassImporter()
        let outcome = try await runner.run(
            decoded: decoded(tone(3, then: 0.4)),
            format: analyzerFormat,
            passes: [
                scriptedPass("id-ID", texts: ["Pertamina Jakarta Anthropic"]),
                scriptedPass("en-US", texts: ["Pertamina Jakarta Anthropic"]),
            ]
        )
        #expect(outcome.sections.first?.chosenLocale == "id-ID")
    }

    @Test("A pass that throws costs its candidate, not the file")
    func oneFailingPass() async throws {
        let runner = DualPassImporter()
        let failing = DualPassImporter.Pass(localeIdentifier: "id-ID", module: .dictation) { stream in
            for await _ in stream {}
            throw SpeechEngineError.notPrepared
        }
        let outcome = try await runner.run(
            decoded: decoded(tone(3, then: 0.4)),
            format: analyzerFormat,
            passes: [
                scriptedPass("en-US", texts: ["Okay team let us review the numbers before we start"]),
                failing,
            ]
        )
        #expect(outcome.sections.count == 1)
        #expect(outcome.sections[0].candidates.count == 1)
        #expect(outcome.sections[0].chosenLocale == "en-US")
        #expect(outcome.passesRun == 1)
        #expect(outcome.text.contains("review the numbers"))
    }

    @Test("Silence yields no sections and no text, rather than one section covering the quiet")
    func silence() async throws {
        let runner = DualPassImporter()
        let outcome = try await runner.run(
            decoded: decoded([Int16](repeating: 0, count: 16_000 * 5)),
            format: analyzerFormat,
            passes: [
                scriptedPass("en-US", texts: ["this must never appear"]),
                scriptedPass("id-ID", texts: ["ini juga tidak boleh muncul"]),
            ]
        )
        #expect(outcome.sections.isEmpty)
        #expect(outcome.text.isEmpty)
        #expect(outcome.passesRun == 0)
        // Still attributed to the primary: a caller writing this to history needs a locale, and
        // "no speech" is not a language.
        #expect(outcome.localeIdentifiers == ["en-US"])
    }

    @Test("An empty pass list is refused rather than silently transcribing nothing")
    func noPasses() async {
        await #expect(throws: SpeechEngineError.self) {
            _ = try await DualPassImporter().run(
                decoded: decoded(tone(3, then: 0.4)),
                format: analyzerFormat,
                passes: []
            )
        }
    }
}

// MARK: - Stitching

@Suite("Dual pass — stitching and segments")
struct DualPassStitchTests {

    @Test("Segment times are shifted into the file's own timeline and tagged with their locale")
    func segmentOffsets() {
        let words = runs(in: "one two three")
        let segments = DualPassImporter.segments(
            from: words,
            offsetBy: 10,
            limit: 20,
            locale: "id-ID"
        )
        #expect(segments.count == 3)
        #expect(segments[0].start == 10)
        #expect(segments[1].start == 10.4)
        #expect(segments.allSatisfy { $0.locale == "id-ID" })
    }

    @Test("A run whose range overshoots the section is clamped, so cues cannot overlap the next one")
    func segmentClamping() {
        let words = [
            WordConfidence(text: "late", confidence: 0.9, startSeconds: 4.9, endSeconds: 6.2)
        ]
        let segments = DualPassImporter.segments(from: words, offsetBy: 0, limit: 5, locale: "en-US")
        #expect(segments.count == 1)
        #expect(segments[0].end == 5)
        #expect(segments[0].start <= segments[0].end)
    }

    @Test("A run with no time range contributes no segment")
    func untimedRun() {
        let words = [WordConfidence(text: "untimed", confidence: 0.9)]
        #expect(DualPassImporter.segments(from: words, offsetBy: 0, limit: 5, locale: "en-US").isEmpty)
    }

    @Test("Language share is measured in audio seconds, not in words")
    func shareIsAudio() {
        // The language that produced *fewer words over more audio* must still be dominant: word
        // counts are exactly the quantity a weaker acoustic model deflates.
        let ordered = DualPassImporter.order(["id-ID": 40, "en-US": 12], fallback: "en-US")
        #expect(ordered == ["id-ID", "en-US"])
    }

    @Test("An exact tie in share is broken deterministically, not by dictionary order")
    func tieBreak() {
        #expect(DualPassImporter.order(["id-ID": 10, "en-US": 10], fallback: "en-US")
            == ["en-US", "id-ID"])
    }

    @Test("Low-confidence words are deduped, and a run with no confidence is not evidence")
    func lowConfidence() {
        let words = [
            WordConfidence(text: "Visa", confidence: 0.05),
            WordConfidence(text: "visa", confidence: 0.11),
            WordConfidence(text: "deploy", confidence: 0.998),
            // Every Indonesian run: a time range and no confidence. Must not be offered as a
            // mishearing — see `WordConfidence.confidence`.
            WordConfidence(text: "kuartal", confidence: nil),
        ]
        #expect(DualPassImporter.lowConfidenceWords(in: words) == ["Visa"])
    }

    @Test("Progress reserves a fixed share for the decode and reaches 1 at the last pass")
    func progressFraction() {
        #expect(DualPassImporter.fraction(0, of: 8) == DualPassImporter.decodeShare)
        #expect(DualPassImporter.fraction(8, of: 8) == 1)
        let half = DualPassImporter.fraction(4, of: 8)
        #expect(half > 0.5 && half < 0.52)
    }

    @Test("Progress and the section counter are reported, and the counter is monotonic")
    func reportedProgress() async throws {
        let seen = ProgressLog()
        _ = try await DualPassImporter().run(
            decoded: decoded(tone(3, then: 1.0) + tone(3, then: 0.4)),
            format: analyzerFormat,
            passes: [
                scriptedPass("en-US", texts: ["one two three four five"]),
                scriptedPass("id-ID", texts: ["satu dua tiga empat lima"]),
            ],
            reporting: DualPassImporter.Reporting(
                onProgress: { seen.progress($0) },
                onSections: { done, total in seen.section(done, total) }
            )
        )
        #expect(seen.progressValues.first == DualPassImporter.decodeShare)
        #expect(seen.progressValues.last == 1)
        #expect(seen.progressValues == seen.progressValues.sorted())
        // Two sections, two passes each. The total is known before any pass runs, which is the
        // whole reason this progress is a measurement rather than an estimate.
        #expect(seen.sectionEvents.first == [0, 4])
        #expect(seen.sectionEvents.last == [4, 4])
    }
}

// MARK: - Failed passes

/// A failed pass is missing transcript, and the file that loses one still looks fluent — it is simply
/// short. So the only defence is a count, and these pin the count and the two things driven off it.
@Suite("Dual pass — a pass that throws is counted, not swallowed")
struct DualPassFailureTests {

    /// Two sections separated by a full second of silence, so the segmenter reliably finds two.
    private func twoSections() -> DecodedAudio {
        decoded(tone(3, then: 1.0) + tone(3, then: 0.4))
    }

    /// A second language whose model is unavailable on every section — the shape of the real failure
    /// this exists for, where `SpeechEngine` throws rather than returning a poor transcript.
    private var alwaysFails: DualPassImporter.Pass {
        DualPassImporter.Pass(localeIdentifier: "id-ID", module: .dictation) { stream in
            // Drained anyway: the production `transcribe` consumes the stream before it can fail.
            for await _ in stream {}
            throw SpeechEngineError.notPrepared
        }
    }

    private var firstPass: DualPassImporter.Pass {
        scriptedPass("en-US", texts: [
            "Okay team let us review the quarterly numbers before we start",
            "And that is the last of the actions for this week thank you all",
        ])
    }

    @Test("Progress and the section counter follow passes ATTEMPTED, so a failing language cannot stall them")
    func progressCountsAttempts() async throws {
        let seen = ProgressLog()
        let outcome = try await DualPassImporter().run(
            decoded: twoSections(),
            format: analyzerFormat,
            passes: [firstPass, alwaysFails],
            reporting: DualPassImporter.Reporting(
                onProgress: { seen.progress($0) },
                onSections: { done, total in seen.section(done, total) }
            )
        )
        #expect(outcome.sections.count == 2)
        // Four passes were started and two of them threw. Both of these assertions were captured
        // failing against the pre-fix code, which counted only the successes: the counter's last
        // event was [2, 4] on a finished job, and the fraction after the first section was 0.265
        // where half the passes were already spent. That is the stalled bar in finding #1 — the same
        // bug as the silent failure, since a bar climbing at half rate is a bar that lies about how
        // much of the file was read.
        #expect(seen.sectionEvents.last == [4, 4])
        // The first section is half the file's passes, so the bar must be past halfway the moment it
        // is decided. `progressValues.first` is the decode's fixed share, so the section is next.
        let afterFirstSection = try #require(seen.progressValues.dropFirst().first)
        #expect(afterFirstSection > 0.5)
        #expect(seen.progressValues == seen.progressValues.sorted())
    }

    @Test("failedPasses counts every pass that threw, and the file keeps what worked")
    func failedPassesAreCounted() async throws {
        let outcome = try await DualPassImporter().run(
            decoded: twoSections(),
            format: analyzerFormat,
            passes: [firstPass, alwaysFails]
        )
        #expect(outcome.passesRun == 2)
        #expect(outcome.failedPasses == 2)
        #expect(outcome.passesAttempted == 4)
        // Both sections still contributed: one failed pass costs a candidate, not the section.
        #expect(outcome.sections.count == 2)
        #expect(outcome.text.contains("quarterly numbers"))
        #expect(outcome.text.contains("last of the actions"))
    }

    @Test("Silence fails no passes, so a quiet file can never be reported as a failed transcription")
    func silenceFailsNothing() async throws {
        let outcome = try await DualPassImporter().run(
            decoded: decoded([Int16](repeating: 0, count: 16_000 * 5)),
            format: analyzerFormat,
            passes: [firstPass, alwaysFails]
        )
        // Both zero, and the difference between them is what `ImportQueue.runDualPass` gates on:
        // no sections means no passes to fail, and "no speech was found" is the true answer here.
        #expect(outcome.passesRun == 0)
        #expect(outcome.failedPasses == 0)
    }

    @Test("A file where every pass throws produces no transcript and says how many failed")
    func everyPassFails() async throws {
        let outcome = try await DualPassImporter().run(
            decoded: twoSections(),
            format: analyzerFormat,
            passes: [alwaysFails, alwaysFails]
        )
        #expect(outcome.passesRun == 0)
        #expect(outcome.failedPasses == 4)
        #expect(outcome.sections.isEmpty)
        #expect(outcome.text.isEmpty)
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var progressStore: [Double] = []
    private var sectionStore: [[Int]] = []
    func progress(_ value: Double) { lock.withLock { progressStore.append(value) } }
    func section(_ done: Int, _ total: Int) { lock.withLock { sectionStore.append([done, total]) } }
    var progressValues: [Double] { lock.withLock { progressStore } }
    var sectionEvents: [[Int]] { lock.withLock { sectionStore } }
}

// MARK: - The warning

@Suite("Recognition quality — which denominator, and when to speak")
struct QualityBasisTests {

    /// One segment per word at a steady rate, covering `coverage` of `audio`.
    private func segments(
        words: Int,
        over span: TimeInterval,
        from start: TimeInterval = 0,
        confidence: Double?
    ) -> [TranscriptSegment] {
        guard words > 0 else { return [] }
        let step = span / Double(words)
        return (0..<words).map { i in
            TranscriptSegment(
                start: start + Double(i) * step,
                end: start + Double(i) * step + step * 0.9,
                text: "w\(i)",
                confidence: confidence
            )
        }
    }

    private func text(_ words: Int) -> String {
        (0..<words).map { "w\($0)" }.joined(separator: " ")
    }

    @Test("A recording that is mostly silence but confidently transcribed is not flagged")
    func silenceIsNotAFailure() {
        // 120 s file, 40 s of speech, 100 words: 50 wpm against wall clock (flagged) but 150 wpm
        // against detected speech (fine), and the words came back at 0.93.
        let quality = ImportQueue.assess(
            text: text(100),
            audioDuration: 120,
            speechDuration: 40,
            segments: segments(words: 100, over: 40, confidence: 0.93)
        )
        #expect(quality.verdict == .good)
        #expect(quality.isConcerning == false)
        #expect(quality.explanation == nil)
    }

    @Test("The same shortfall with unconfident words IS flagged — the measured far-field case")
    func lowConfidenceDefeatsTheSilenceExcuse() {
        // The 300-second slice of the real meeting, transcribed per section: 245 words, 131.5 s of
        // detected speech (112 wpm, which alone reads as fine), mean word confidence 0.288.
        let quality = ImportQueue.assess(
            text: text(245),
            audioDuration: 300,
            speechDuration: 131.5,
            segments: segments(words: 245, over: 105, confidence: 0.288)
        )
        #expect(quality.isConcerning)
        // Judged on wall clock, so the rate quoted is the honest 49 and not the flattering 112.
        #expect(quality.wordsPerMinute < 60)
        #expect(quality.explanation?.contains("49 words") == true)
        #expect(quality.explanation?.contains("confidence") == true)
    }

    @Test("Without a probe the wall-clock verdict stands on its own")
    func noProbe() {
        let quality = ImportQueue.assess(
            text: text(1128),
            audioDuration: 4197,
            speechDuration: nil,
            segments: segments(words: 1128, over: 1030, confidence: 0.17)
        )
        #expect(quality.verdict == .veryPoor)
        #expect(quality.explanation?.contains("16 words") == true)
    }

    @Test("A transcript with no confidence at all — every Indonesian one — is judged on speech alone")
    func indonesianHasNoConfidence() {
        // `DictationTranscriber` on `id_ID` reports a time range on every run and a confidence on
        // none, so requiring confidence here would flag every quiet Indonesian recording.
        let quality = ImportQueue.assess(
            text: text(100),
            audioDuration: 120,
            speechDuration: 40,
            segments: segments(words: 100, over: 40, confidence: nil)
        )
        #expect(quality.verdict == .good)
    }

    @Test("A good transcript shows nothing, on either basis")
    func goodTranscriptIsSilent() {
        for speech in [nil, 322.0] as [TimeInterval?] {
            let quality = ImportQueue.assess(
                text: text(1008),
                audioDuration: 377,
                speechDuration: speech,
                segments: segments(words: 1008, over: 373, confidence: 0.93)
            )
            #expect(quality.verdict == .good)
            #expect(quality.explanation == nil)
        }
    }

    @Test("Word count matches Transcript.wordCount, so the sentence and the row cannot disagree")
    func wordCountAgrees() {
        let body = "  one  two\nthree\tfour "
        let transcript = Transcript(rawText: body, text: body)
        #expect(ImportQueue.wordCount(body) == transcript.wordCount)
        #expect(ImportQueue.wordCount("") == 0)
    }
}

// MARK: - Persistence

@Suite("Mixed-language transcripts round-trip")
struct MixedTranscriptTests {

    @Test("A one-element locale list is normalised away — it is the same fact as localeIdentifier")
    func singleLocaleIsNotMixed() {
        let transcript = Transcript(
            rawText: "hello",
            text: "hello",
            localeIdentifier: "en-US",
            localeIdentifiers: ["en-US"]
        )
        #expect(transcript.isMixedLanguage == false)
        #expect(transcript.localeIdentifiers.isEmpty)
        #expect(transcript.contributingLocales == ["en-US"])
    }

    @Test("Per-segment locales and the quality block survive a save and load")
    func roundTrip() throws {
        let original = Transcript(
            rawText: "one dua",
            text: "one dua",
            localeIdentifier: "id-ID",
            localeIdentifiers: ["id-ID", "en-US"],
            source: .imported(filename: "meeting.m4a"),
            segments: [
                TranscriptSegment(start: 0, end: 1, text: "one", confidence: 0.9, locale: "en-US"),
                TranscriptSegment(start: 1, end: 2, text: "dua", confidence: nil, locale: "id-ID"),
            ],
            quality: RecognitionQuality(
                verdict: .sparse,
                wordsPerMinute: 49,
                coverage: 0.35,
                meanConfidence: 0.288,
                explanation: "Recognised speech covers only 35% of this 5-minute recording."
            )
        )
        let data = try JSONEncoder().encode([original])
        let loaded = try JSONDecoder().decode([Transcript].self, from: data)
        let copy = try #require(loaded.first)

        #expect(copy.localeIdentifier == "id-ID")
        #expect(copy.localeIdentifiers == ["id-ID", "en-US"])
        #expect(copy.isMixedLanguage)
        #expect(copy.segments.map(\.locale) == ["en-US", "id-ID"])
        #expect(copy.hasQualityConcern)
        #expect(copy.quality?.verdict == .sparse)
        #expect(copy.quality?.explanation?.hasPrefix("Recognised speech") == true)
    }

    @Test("A single-pass transcript writes no locale field on its segments")
    func singlePassSegmentsStayLean() throws {
        let transcript = Transcript(
            rawText: "hello",
            text: "hello",
            segments: [TranscriptSegment(start: 0, end: 1, text: "hello")]
        )
        let json = String(decoding: try JSONEncoder().encode([transcript]), as: UTF8.self)
        #expect(json.contains("\"locale\"") == false)
        #expect(json.contains("\"localeIdentifiers\"") == true)   // the transcript-level key is always written
    }

    @Test("A history file from before this change still loads, with no warning invented for it")
    func oldFileLoads() throws {
        let json = """
            [{"id":"\(UUID().uuidString)","createdAt":"2026-01-01T00:00:00Z","rawText":"a",\
            "text":"a","audioDuration":1,"transcribeDuration":1,"localeIdentifier":"en-US",\
            "engine":"apple.speechtranscriber","injection":"notAttempted","droppedBuffers":0,\
            "lowConfidenceWords":[],"corrections":[],\
            "segments":[{"start":0,"end":1,"text":"a"}]}]
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode([Transcript].self, from: Data(json.utf8))
        let transcript = try #require(loaded.first)
        #expect(transcript.quality == nil)
        #expect(transcript.hasQualityConcern == false)
        #expect(transcript.isMixedLanguage == false)
        #expect(transcript.segments.first?.locale == nil)
    }

    @Test("Language spans merge adjacent sections that agree, and drop untagged segments")
    func spans() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "a", locale: "en-US"),
            TranscriptSegment(start: 1, end: 2, text: "b", locale: "en-US"),
            TranscriptSegment(start: 2, end: 3, text: "c", locale: "id-ID"),
            TranscriptSegment(start: 3, end: 4, text: "d", locale: nil),
            TranscriptSegment(start: 4, end: 5, text: "e", locale: "en-US"),
        ]
        let spans = LanguageSpansView.spans(in: segments)
        #expect(spans.map(\.locale) == ["en-US", "id-ID", "en-US"])
        #expect(spans[0].words == 2)
        #expect(spans[0].end == 2)
        #expect(spans[2].start == 4)
    }

    @Test("A monolingual transcript produces one span, so the block renders nothing")
    func monolingualSpans() {
        let segments = (0..<5).map {
            TranscriptSegment(start: Double($0), end: Double($0) + 1, text: "w", locale: "en-US")
        }
        #expect(LanguageSpansView.spans(in: segments).count == 1)
        #expect(LanguageSpansView.spans(in: []).isEmpty)
    }
}

// MARK: - Settings

@MainActor
@Suite("Dual pass is off by default and needs a second language")
struct DualPassSettingsTests {

    @Test("Off by default")
    func offByDefault() {
        let settings = Settings(defaults: EphemeralDefaults())
        #expect(settings.importDualPass == false)
        #expect(settings.dualPassIsActive == false)
    }

    @Test("On, with a second language configured, it is active")
    func active() {
        let settings = Settings(defaults: EphemeralDefaults())
        settings.importDualPass = true
        #expect(settings.secondaryLocaleEnabled)
        #expect(settings.dualPassIsActive)
    }

    @Test("On, but the second language is off or the same as the first, it is inert")
    func inertWithoutASecondLanguage() {
        let settings = Settings(defaults: EphemeralDefaults())
        settings.importDualPass = true

        settings.secondaryLocaleEnabled = false
        #expect(settings.dualPassIsActive == false)

        settings.secondaryLocaleEnabled = true
        settings.secondaryLocaleIdentifier = settings.localeIdentifier
        #expect(settings.dualPassIsActive == false)
    }

    @Test("The preference persists")
    func persists() {
        let defaults = EphemeralDefaults()
        Settings(defaults: defaults).importDualPass = true
        #expect(Settings(defaults: defaults).importDualPass)
    }
}
