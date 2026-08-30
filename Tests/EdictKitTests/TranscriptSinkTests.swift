import CoreMedia
import Foundation
import Speech
import Testing

@testable import EdictKit

// MARK: - Why this file exists

/// `TranscriptSink.ingest(isFinal:range:text:)` assembles every word the app ever injects, and until
/// this file was written not one of its four rules was asserted anywhere.
///
/// It was not *unexercised*: `SessionLifecycleTests` drives `ingest` through a real analyzer on every
/// ungated run, and its own header says "nothing here asserts on the transcript". So the cost of
/// running it was already being paid and none of the protection was being bought. Everything else in
/// `Tests/` that mentions `TranscriptionUpdate` builds one by hand as a fake, which cannot reach the
/// accumulator at all.
///
/// These are **regression guards, not the fix for a live bug** — the four rules are correct in the
/// shipped code, and each was verified here by mutating the source, watching the matching test fail,
/// and restoring it. What they buy is that the next author cannot quietly undo a measurement that
/// cost RECON real time to make:
///
///  - Volatile results REPLACE the tail; finals APPEND (RECON §4 / amendment 4). Concatenating every
///    event on a 24 s utterance produced 7310 characters where 412 was correct — 17.7x.
///  - Final ranges are disjoint and monotonic but **not** contiguous. RECON §4 measured a 120 ms gap
///    mid-utterance, so a revised final is deduped on `CMTimeRangeEqual` alone and never on
///    `start == previousEnd`.
///  - The volatile tail is cleared on every final.
///  - A run is collected if it carries a confidence **or** a time range. Requiring confidence emptied
///    `segments` for every Indonesian transcript — RECON measured, on `id_ID`, 38 runs with a time
///    range and 0 with a confidence, with both attributes asked for explicitly.
///
/// Hardware-free and ungated on purpose. `ingest` takes an `AttributedString` and a `CMTimeRange` and
/// touches nothing else, so no speech model, no audio device and no support directory are involved.
/// The analyzer-driven suite next door needs an installed model for everything it does; this one runs
/// on any machine, which is the point — the rules below must not be guarded only where the assets are.
///
/// ## The five mutations, and what each one killed
///
/// Repeatable in a minute if you ever doubt these assertions bite. Each was applied to
/// `Transcriber.swift` alone, with `swift test --filter TranscriptSinkTests`:
///
///  1. `volatileTail = flat` → `+= flat` — 1 failure: the tail read " cl claw Claude co Claude code".
///  2. the volatile branch also `finals.append(…)` — 10 failures across 3 tests; `committed` reached
///     165 characters where 71 was correct, which is the 17.7x bug in miniature.
///  3. dedupe predicate `|| CMTimeCompare(CMTimeRangeGetEnd($0.range), range.start) == 0` — 12
///     failures across 4 tests; the 24 s transcript lost its first 7.8 seconds.
///  4. `volatileTail = ""` deleted from the final branch — 3 failures: a stale " whis" survived into
///     both the update and `snapshot`.
///  5. `guard confidence != nil` (dropping the OR) — 6 failures: `allWords` went to 0 of 3 on the
///     Indonesian fixture. And `runConfidences.append(confidence ?? 0)` — 3 failures: an unscored
///     result reported a confident 0.0 in place of nil, and a mixed one 0.375 in place of 0.5.

// MARK: - Fixtures

/// One attribute run as the engine emits it: some text, plus whichever of the two Speech attributes
/// were present on it.
///
/// The point of going through a real `AttributeContainer` rather than faking a `[WordConfidence]` is
/// that `ingest` reads `run.attributes[…ConfidenceAttribute.self]` and
/// `run.attributes[…TimeRangeAttribute.self]` off a real `AttributedString`, and run *coalescing* is
/// part of what it sees. Verified against the SDK before this suite was written: setting both keys
/// through `AttributeContainer` and reading them back through those same subscripts round-trips, and
/// three appended pieces with distinct attributes stay three distinct runs.
private struct SpeechRun {
    var text: String
    var confidence: Double?
    var span: CMTimeRange?

    init(_ text: String, confidence: Double? = nil, span: CMTimeRange? = nil) {
        self.text = text
        self.confidence = confidence
        self.span = span
    }
}

/// Build the `AttributedString` the engine would hand to `ingest` for one result.
private func attributed(_ runs: [SpeechRun]) -> AttributedString {
    var out = AttributedString()
    for run in runs {
        var attributes = AttributeContainer()
        if let confidence = run.confidence {
            attributes[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] = confidence
        }
        if let span = run.span {
            attributes[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = span
        }
        out.append(AttributedString(run.text, attributes: attributes))
    }
    return out
}

/// A plain result with no attributes at all — the shape the named presets produce
/// (`attributeOptions == []`), which is most of what the accumulation tests care about.
private func plain(_ text: String) -> AttributedString { AttributedString(text) }

/// Timescale 1000 because every range RECON recorded is a whole number of milliseconds, so the
/// `CMTimeRangeEqual` dedupe is comparing exact values rather than rounded ones.
private func span(_ start: Double, _ end: Double) -> CMTimeRange {
    CMTimeRange(
        start: CMTime(seconds: start, preferredTimescale: 1000),
        end: CMTime(seconds: end, preferredTimescale: 1000)
    )
}

/// Collects what `onUpdate` was handed.
///
/// The type exists at all because `onUpdate` is `@Sendable` and therefore cannot capture a mutable
/// local — the same Swift 6 restriction that made `TranscriptSink` itself a class. `@unchecked` is for
/// the mutable `items`, and the `NSLock` is what makes the claim true. Every `ingest` in this file is
/// called from the test's own thread and `onUpdate` runs synchronously inside it, so the lock is not
/// actually contended here; it is present so the conformance is earned rather than merely asserted.
private final class UpdateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TranscriptionUpdate] = []

    var record: @Sendable (TranscriptionUpdate) -> Void {
        { [self] update in lock.withLock { items.append(update) } }
    }

    var all: [TranscriptionUpdate] { lock.withLock { items } }
    var last: TranscriptionUpdate? { lock.withLock { items.last } }
}

private func makeSink() -> (TranscriptSink, UpdateLog) {
    let log = UpdateLog()
    return (TranscriptSink(onUpdate: log.record), log)
}

// MARK: - Tests

@Suite("Transcript sink")
struct TranscriptSinkTests {

    // MARK: Rule 1 — volatile replaces, final appends

    /// (a) The 17.7x bug. Three volatiles between two finals must leave `committed` equal to the
    /// concatenation of the two finals and nothing else.
    ///
    /// The volatile texts below are the real failure mode rather than invented noise: RECON §4
    /// measured a volatile "speecheech transcriber API" against a final "speech transcriber API", and
    /// recorded mid-word fragments arriving constantly. A sink that appended volatiles would commit
    /// every one of those fragments *and* the corrected final, which is where 412 characters became
    /// 7310.
    @Test("Volatiles between finals leave only the finals committed")
    func volatilesReplaceTheTail() {
        let (sink, log) = makeSink()

        let first = " It runs entirely on your Mac."
        let second = " The speech transcriber API is on-device."

        sink.ingest(isFinal: true, range: span(0, 3.300), text: plain(first))
        sink.ingest(isFinal: false, range: span(3.300, 4.100), text: plain(" The speecheech transcr"))
        sink.ingest(isFinal: false, range: span(3.300, 5.900), text: plain(" The speecheech transcriber API is"))
        sink.ingest(isFinal: false, range: span(3.300, 7.868), text: plain(" The speech transcriber API is on-dev"))
        sink.ingest(isFinal: true, range: span(3.300, 7.800), text: plain(second))

        #expect(sink.committed == first + second)
        // The crisp form of "no volatile fragment survived": any leak lengthens the string.
        #expect(sink.committed.count == first.count + second.count)
        #expect(sink.finalCount == 2)
        #expect(sink.snapshot.volatileText.isEmpty)

        // Five results in, five updates out, and every one of them reported a committed prefix that
        // only ever grew by a whole final.
        #expect(log.all.count == 5)
        #expect(log.all.map(\.isFinal) == [true, false, false, false, true])
        #expect(log.all.map(\.finalText) == [first, first, first, first, first + second])
    }

    /// The contract subtlety that looks like a bug and is not: two finals at different ranges join
    /// with **no glue**, because each final's text already carries its own leading space. So "AA" then
    /// " bcd" is "AA bcd", and a sink that helpfully inserted a separator would double it.
    @Test("Finals join with no glue, because each carries its own leading space")
    func finalsJoinWithoutSeparators() {
        let (sink, _) = makeSink()

        sink.ingest(isFinal: true, range: span(0, 1.000), text: plain("AA"))
        sink.ingest(isFinal: true, range: span(1.000, 2.000), text: plain(" bcd"))

        #expect(sink.committed == "AA bcd")
        #expect(sink.finalCount == 2)
    }

    // MARK: Rule 2 — dedupe on exact range equality only

    /// (b) The 120 ms gap. These are the four ranges RECON §4 recorded off a 24 s clip —
    /// [0..3.300], [3.300..7.800], [7.800..14.520], [14.640..24.120] — and the fourth does not start
    /// where the third ended. All four finals must survive.
    ///
    /// This is the test that fails if anyone "tidies" the dedupe into a contiguity check. Measured, by
    /// adding `|| CMTimeCompare(CMTimeRangeGetEnd($0.range), range.start) == 0` to the predicate and
    /// running this file: each contiguous final overwrites its predecessor, so only the two either
    /// side of the gap survive and the user's first 7.8 seconds are deleted outright.
    @Test("Four finals with a 120 ms gap mid-utterance all survive")
    func nonContiguousFinalsAllSurvive() {
        let (sink, _) = makeSink()

        let parts = [
            (span(0, 3.300), " Hold the right option key,"),
            (span(3.300, 7.800), " speak, and release,"),
            (span(7.800, 14.520), " and the text appears at the cursor."),
            (span(14.640, 24.120), " It runs entirely on your Mac."),
        ]
        for (range, text) in parts {
            sink.ingest(isFinal: true, range: range, text: plain(text))
        }

        #expect(sink.finalCount == 4)
        #expect(sink.committed == parts.map(\.1).joined())
        // Named explicitly, because this is the pair separated by the gap.
        #expect(sink.committed.contains(" and the text appears at the cursor. It runs entirely"))
    }

    /// (c) A revised final for a range already held replaces it — RECON §4's prescription is to append
    /// finals in arrival order and dedupe on exact `CMTimeRangeEqual`, which only means anything if the
    /// match replaces rather than adds. Appending instead would commit the superseded text as well, and
    /// the pair below is the flavour of correction that actually costs something: "claw code" and
    /// "Claude Code" are both plausible English, so a user skimming the result would not spot it.
    @Test("A revised final for a held range replaces it and adds no final")
    func revisedFinalReplacesInPlace() {
        let (sink, _) = makeSink()
        let held = span(0, 3.300)

        sink.ingest(isFinal: true, range: held, text: plain(" claw code"))
        #expect(sink.finalCount == 1)

        sink.ingest(isFinal: true, range: held, text: plain(" Claude Code"))

        #expect(sink.finalCount == 1)
        #expect(sink.committed == " Claude Code")
    }

    /// The replacement must happen **in place**, not as a remove-then-append: a revision to an early
    /// range must not jump to the end of the transcript.
    @Test("A revision to an early range keeps its position in the transcript")
    func revisionKeepsArrivalOrder() {
        let (sink, _) = makeSink()

        sink.ingest(isFinal: true, range: span(0, 1.000), text: plain("one"))
        sink.ingest(isFinal: true, range: span(1.000, 2.000), text: plain(" two"))
        sink.ingest(isFinal: true, range: span(0, 1.000), text: plain("ONE"))

        #expect(sink.finalCount == 2)
        #expect(sink.committed == "ONE two")
    }

    // NOTE — there is deliberately no test here for a zero-duration final, or for one range enclosing
    // another. Both would sharpen the "predicate too loose" direction, but neither shape has been
    // observed coming out of either module, and a test that pins a shape the engine never emits is a
    // test that will one day be defended for the wrong reason. `nonContiguousFinalsAllSurvive` covers
    // the loose direction with ranges RECON actually recorded.

    // MARK: Rule 3 — the volatile tail clears on every final

    /// (d) A final clears a pending volatile tail, in the returned update *and* in `snapshot`.
    ///
    /// Both are asserted because they are separate expressions over the same state, built at different
    /// times: the update is composed inside `ingest` and is what the HUD renders, while `snapshot`
    /// recomposes one on demand and is what `TranscriptionSession.snapshot` exposes to any later
    /// unsynchronised reader. A tail that outlived its final would leave the stale, wrong-mid-word
    /// fragment hanging off the corrected text for the rest of the utterance.
    @Test("A final clears the pending volatile tail")
    func finalClearsVolatileTail() {
        let (sink, log) = makeSink()

        sink.ingest(isFinal: true, range: span(0, 3.300), text: plain(" Committed."))
        sink.ingest(isFinal: false, range: span(3.300, 4.500), text: plain(" whis"))

        #expect(sink.snapshot.volatileText == " whis")
        #expect(log.last?.volatileText == " whis")
        #expect(log.last?.displayText == " Committed. whis")
        // A volatile must not touch the committed text at all.
        #expect(sink.committed == " Committed.")
        #expect(sink.finalCount == 1)

        sink.ingest(isFinal: true, range: span(3.300, 7.800), text: plain(" Whisper."))

        #expect(log.last?.volatileText.isEmpty == true)
        #expect(sink.snapshot.volatileText.isEmpty)
        #expect(sink.committed == " Committed. Whisper.")
    }

    /// Each volatile replaces the last, so the tail never grows by accumulation — the same rule as
    /// (a), observed through `snapshot` instead of through `committed`.
    @Test("Each volatile replaces the previous tail rather than extending it")
    func volatileTailIsReplacedNotExtended() {
        let (sink, _) = makeSink()

        for text in [" cl", " claw", " Claude co", " Claude code"] {
            sink.ingest(isFinal: false, range: span(0, 1.200), text: plain(text))
        }

        #expect(sink.snapshot.volatileText == " Claude code")
        #expect(sink.committed.isEmpty)
        #expect(sink.finalCount == 0)
    }

    // MARK: Rule 4 — a run counts if it carries EITHER attribute

    /// (e) The Indonesian case, and the reason `WordConfidence.confidence` is optional. RECON's
    /// file-transcription measurements — quoted in full on that property — record
    /// `DictationTranscriber` on `id_ID` returning a time range on all 38 runs of an 18.8 s clip and a
    /// confidence on none of them, with both attributes asked for explicitly.
    ///
    /// So: runs with a time range and no confidence must populate `allWords` **with their seconds** —
    /// `ImportQueue.segments(from:)` drops any word whose `startSeconds` is nil, so those seconds are
    /// the whole of what SRT/VTT export has to work from — while contributing nothing to
    /// `lowConfidenceWords` or `meanConfidence`. A sink that required confidence would leave `allWords`
    /// empty here, which is exactly the bug the first integration pass had, caught only because
    /// someone actually ran the Indonesian file: an empty `segments` array and no subtitle export for
    /// that language, with nothing looking broken.
    @Test("Runs with a time range and no confidence still become words")
    func timeRangeOnlyRunsAreCollected() {
        let (sink, log) = makeSink()

        let runs = [
            SpeechRun(" Selamat", span: span(0, 0.520)),
            SpeechRun(" pagi", span: span(0.520, 0.940)),
            SpeechRun(" semuanya", span: span(0.940, 1.680)),
        ]
        sink.ingest(isFinal: true, range: span(0, 1.680), text: attributed(runs))

        let words = sink.allWords
        #expect(words.count == 3)
        #expect(words.map(\.text) == ["Selamat", "pagi", "semuanya"])
        #expect(words.allSatisfy { $0.confidence == nil })
        #expect(words.compactMap(\.startSeconds).count == 3)
        // The seconds are checked on the middle word, reached without a subscript on purpose: the
        // regression this test exists to catch empties `allWords`, and `words[1]` would then trap and
        // take the whole test process down instead of reporting a failure.
        let middle = words.dropFirst().first
        #expect(closeEnough(middle.flatMap(\.startSeconds), 0.520))
        #expect(closeEnough(middle.flatMap(\.endSeconds), 0.940))

        // Nothing scored, so nothing to offer the dictionary and nothing to average.
        #expect(sink.lowConfidenceWords.isEmpty)
        #expect(sink.meanConfidence == nil)
        #expect(log.last?.confidence == nil)

        // The transcript itself is unaffected — including the leading space the engine attaches to
        // each segment, which is stripped only from the surfaced word.
        #expect(sink.committed == " Selamat pagi semuanya")
    }

    /// The other half of the OR: a run with a confidence and no time range is collected too, with nil
    /// seconds. `WordConfidence.startSeconds`/`.endSeconds` are optional for exactly this shape.
    @Test("Runs with a confidence and no time range still become words")
    func confidenceOnlyRunsAreCollected() {
        let (sink, _) = makeSink()

        sink.ingest(
            isFinal: true,
            range: span(0, 1.000),
            text: attributed([SpeechRun(" deploy", confidence: 0.998), SpeechRun(" Visa", confidence: 0.05)])
        )

        #expect(sink.allWords.map(\.text) == ["deploy", "Visa"])
        #expect(sink.allWords.allSatisfy { $0.startSeconds == nil && $0.endSeconds == nil })
        #expect(sink.lowConfidenceWords == ["Visa"])
    }

    /// A run carrying neither attribute is not a word. RECON §7 measured the *named* presets carrying
    /// `attributeOptions == []`, which yields one attribute-free run for the whole result — so
    /// collecting such a run would put an entire sentence into the dictionary UI as a single "word".
    @Test("A run with neither attribute is skipped, and whitespace-only runs with attributes too")
    func attributelessAndBlankRunsAreSkipped() {
        let (sink, _) = makeSink()

        sink.ingest(
            isFinal: true,
            range: span(0, 2.000),
            text: attributed([
                SpeechRun(" kept", confidence: 0.9),
                SpeechRun(" dropped for having no attributes"),
                SpeechRun("   ", confidence: 0.3),  // attributed, but no word in it
            ])
        )

        #expect(sink.allWords.map(\.text) == ["kept"])
        #expect(sink.lowConfidenceWords.isEmpty)
        // Text is text regardless: everything the engine sent is still committed.
        #expect(sink.committed == " kept dropped for having no attributes   ")
    }

    /// Volatile results never contribute words, however well attributed. Volatile text is materially
    /// worse (RECON §4: "speecheech transcriber API" against a final "speech transcriber API"), and
    /// RECON also recorded the converse — one segment's volatile said "Claude code" where its final
    /// said "claw code" — which is why neither may be repaired from the other. A volatile run must
    /// therefore not reach the dictionary suggestion UI, where it would offer the user a mid-word
    /// fragment to add to their vocabulary.
    @Test("Volatile results contribute no words")
    func volatileResultsContributeNoWords() {
        let (sink, _) = makeSink()

        sink.ingest(
            isFinal: false,
            range: span(0, 1.000),
            text: attributed([SpeechRun(" whis", confidence: 0.11, span: span(0, 1.000))])
        )

        #expect(sink.allWords.isEmpty)
        #expect(sink.lowConfidenceWords.isEmpty)
        #expect(sink.meanConfidence == nil)
    }

    // MARK: Confidence arithmetic

    /// (f) `TranscriptionUpdate.confidence` is the mean of the confidences **present in that result**,
    /// and nil when there are none. Runs with only a time range are not counted as zero: averaging
    /// them in as zero would drag every mixed mean toward the floor, and on Indonesian — where no run
    /// is scored at all — it would report a confident 0.0 where the honest answer is "not measured".
    @Test("An update's confidence is the mean of the confidences present in that result")
    func updateConfidenceIsTheMeanOfPresentConfidences() {
        let (sink, log) = makeSink()

        sink.ingest(
            isFinal: true,
            range: span(0, 2.000),
            text: attributed([
                SpeechRun(" alpha", confidence: 0.2),
                SpeechRun(" bravo", confidence: 0.4),
                SpeechRun(" charlie", confidence: 0.9),
                SpeechRun(" delta", span: span(1.500, 2.000)),  // present, unscored
            ])
        )

        // (0.2 + 0.4 + 0.9) / 3 — four runs collected, three of them scored.
        #expect(closeEnough(log.last?.confidence, 0.5))
        #expect(sink.allWords.count == 4)
    }

    @Test("An update's confidence is nil when no run in that result carried one")
    func updateConfidenceIsNilWithoutScores() {
        let (sink, log) = makeSink()

        sink.ingest(isFinal: true, range: span(0, 1.000), text: plain(" unattributed"))
        #expect(log.last?.confidence == nil)

        sink.ingest(
            isFinal: true,
            range: span(1.000, 2.000),
            text: attributed([SpeechRun(" pagi", span: span(1.000, 2.000))])
        )
        #expect(log.last?.confidence == nil)
    }

    /// The per-result mean and the whole-utterance mean are deliberately different quantities, computed
    /// by two separate expressions over two different collections — `runConfidences`, local to one
    /// `ingest`, and `words`, cumulative. Pinned together so a refactor cannot quietly collapse them
    /// into one and make `meanConfidence` report only the last result's runs.
    ///
    /// Worth knowing before trusting either: `meanConfidence` is what fills
    /// `TranscriptionOutcome.confidence`, and grep finds no reader for that property anywhere in
    /// `Sources` — the quality verdict recomputes its own mean from `Transcript.segments`
    /// (`RecognitionQuality.meanConfidence(of:)`). So this assertion guards arithmetic that is
    /// currently only ever read by a test.
    @Test("meanConfidence averages every scored word of the utterance, not just the last result")
    func meanConfidenceSpansTheWholeUtterance() {
        let (sink, log) = makeSink()

        sink.ingest(
            isFinal: true,
            range: span(0, 1.000),
            text: attributed([SpeechRun(" one", confidence: 0.2), SpeechRun(" two", confidence: 0.4)])
        )
        sink.ingest(
            isFinal: true,
            range: span(1.000, 2.000),
            text: attributed([SpeechRun(" three", confidence: 1.0)])
        )

        #expect(closeEnough(log.last?.confidence, 1.0))  // that result alone
        #expect(closeEnough(sink.meanConfidence, (0.2 + 0.4 + 1.0) / 3))
    }

    /// `lowConfidenceWords` is deduped case-insensitively, order-preserving, and keeps the first
    /// spelling it saw — that list is offered straight to the dictionary UI as one-click additions.
    /// The threshold is `< 0.5` exactly, from RECON §7's measured distribution.
    @Test("lowConfidenceWords dedupes case-insensitively and preserves first-seen order")
    func lowConfidenceWordsAreDedupedAndOrdered() {
        let (sink, _) = makeSink()

        sink.ingest(
            isFinal: true,
            range: span(0, 3.000),
            text: attributed([
                SpeechRun(" Visa", confidence: 0.05),
                SpeechRun(" deploy", confidence: 0.998),
                SpeechRun(" claw", confidence: 0.31),
                SpeechRun(" visa", confidence: 0.12),  // same word, different case
                SpeechRun(" edge", confidence: 0.5),  // exactly at the threshold: not low
                SpeechRun(" under", confidence: 0.499),
            ])
        )

        #expect(sink.lowConfidenceWords == ["Visa", "claw", "under"])
    }
}

// MARK: - Helpers

/// `startSeconds`/`endSeconds` come out of `CMTimeGetSeconds`, so compare with a tolerance rather
/// than betting on a division landing on the same Double as the literal.
private func closeEnough(_ value: Double?, _ expected: Double, tolerance: Double = 1e-9) -> Bool {
    guard let value else { return false }
    return abs(value - expected) < tolerance
}
