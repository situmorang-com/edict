import AVFoundation
import Foundation
import Speech
import Testing

@testable import EdictKit

/// The engine's one-analyzer-slot rule, driven the way the app actually drives it.
///
/// These tests exist because of a defect that survived every other test in the suite: the live
/// dictation path does not call `SpeechEngine.transcribe(input:…)` — it calls
/// `begin(locale:onUpdate:)` and then drives the returned session itself, because it needs the
/// session object to feed microphone buffers into and to `abort()` on Esc. Only `transcribe`'s
/// `defer` released the engine's slot, so **every successful hotkey dictation leaked it** and the
/// next press was refused. The suite passed throughout, because the suite only ever used
/// `transcribe`.
///
/// So the shape of `utterance(…)` below is the whole point: `begin` → `feed` → `finishAndCommit`,
/// exactly `DictationController.run`. Anything that only exercises `transcribe` cannot see the bug.
///
/// Real model, real analyzer. There is no fake — the leak lives in the bookkeeping *around* the
/// analyzer, and a stub engine would have no bookkeeping to leak.
@Suite("Session lifecycle")
struct SessionLifecycleTests {

    // MARK: - Fixtures

    /// One chunk of analyzer-ready audio: 1 ch / 16 kHz / Int16 / interleaved, the only format the
    /// analyzer accepts (RECON §6). A quiet tone rather than silence, so the analyzer has something
    /// to run on; nothing here asserts on the transcript.
    private static func chunk(format: AVAudioFormat, seconds: Double) throws -> AnalyzerInput {
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw CocoaError(.formatting)
        }
        buffer.frameLength = frames
        if let channel = buffer.int16ChannelData?[0] {
            for frame in 0..<Int(frames) {
                let phase = 2 * Double.pi * 220 * Double(frame) / format.sampleRate
                channel[frame] = Int16(3_000 * sin(phase))
            }
        }
        return AnalyzerInput(buffer: buffer)
    }

    /// `DictationController.run`, minus the microphone and the injection ladder.
    @discardableResult
    private func utterance(
        _ engine: SpeechEngine,
        format: AVAudioFormat,
        seconds: Double = 0.4,
        holdBeforeFinish: Duration? = nil
    ) async throws -> TranscriptionOutcome {
        let session = try await engine.begin(locale: .primary, onUpdate: { _ in })
        session.feed(try Self.chunk(format: format, seconds: seconds))
        if let holdBeforeFinish { try await Task.sleep(for: holdBeforeFinish) }
        return try await session.finishAndCommit()
    }

    private func preparedEngine() async throws -> (SpeechEngine, AVAudioFormat) {
        let engine = SpeechEngine()
        try await engine.prepare(localeIdentifier: "en-US")
        let format = try #require(await engine.bestAudioFormat())
        return (engine, format)
    }

    // MARK: - The leak

    /// The regression test for the reported bug, stated as the user experiences it: press, speak,
    /// release, press again — and the second press must work.
    ///
    /// Against the code before the fix this failed on the very first `#expect`, and then the second
    /// `utterance` threw `sessionAlreadyRunning` after burning the full 1.5 s wait. Four gaps,
    /// because the report said "after a few seconds": the leak is not time-dependent, and showing
    /// that a 3 s gap fails exactly like a 100 ms one is what rules a race out.
    @Test("Back-to-back utterances leave no session held, at every gap")
    func backToBackUtterances() async throws {
        let (engine, format) = try await preparedEngine()

        for gap in [Duration.milliseconds(100), .milliseconds(500), .seconds(1), .seconds(3)] {
            try await utterance(engine, format: format)
            // The invariant that was broken: when `finishAndCommit` has returned, the slot is free.
            #expect(
                await engine.isSlotClaimed == false,
                "the analyzer slot is still held after a completed utterance (gap \(gap))"
            )

            try await Task.sleep(for: gap)

            // And the consequence the user reported. This is the line that threw before the fix.
            try await utterance(engine, format: format)
            #expect(await engine.isSlotClaimed == false)
        }
    }

    /// The abort path leaks the same way if it is not hooked up: Esc, a lost permission, or a
    /// hotkey chord cancellation all end at `session.abort()` rather than `finishAndCommit()`.
    @Test("An aborted utterance releases the slot too")
    func abortReleasesTheSlot() async throws {
        let (engine, format) = try await preparedEngine()

        let session = try await engine.begin(locale: .primary, onUpdate: { _ in })
        session.feed(try Self.chunk(format: format, seconds: 0.3))
        await session.abort()
        #expect(await engine.isSlotClaimed == false)

        // …and the next press is not punished for it.
        try await utterance(engine, format: format)
        #expect(await engine.isSlotClaimed == false)
    }

    /// `engine.cancel()` is the controller's other teardown door — `permissionLost` and quit both
    /// go through it — and it must leave the engine reusable.
    @Test("engine.cancel() releases the slot")
    func engineCancelReleasesTheSlot() async throws {
        let (engine, format) = try await preparedEngine()

        let session = try await engine.begin(locale: .primary, onUpdate: { _ in })
        session.feed(try Self.chunk(format: format, seconds: 0.3))
        await engine.cancel()
        #expect(await engine.isSlotClaimed == false)

        try await utterance(engine, format: format)
    }

    /// `warmUp()` builds a whole session at launch and throws it away. If that one leaks, the
    /// user's *first* press is the one that fails.
    @Test("warmUp leaves nothing held")
    func warmUpLeavesNothingHeld() async throws {
        let (engine, format) = try await preparedEngine()

        await engine.warmUp()
        #expect(await engine.isSlotClaimed == false)

        try await utterance(engine, format: format)
        #expect(await engine.isSlotClaimed == false)
    }

    // MARK: - Serialisation

    /// The mechanism, not just the symptom: a second utterance arriving while the first is still
    /// finalizing must **wait and then run**, not be dropped. RECON §8 measures finalize at
    /// 0.15–0.53 s, which is comfortably inside a press-pause-press rhythm, so this window is real.
    ///
    /// Both utterances must produce an outcome, and the slot must be free at the end — the failure
    /// this pins is the second `begin` overwriting `activeSession` while the first was still live,
    /// which orphans the first session's claim and wedges the engine for good.
    @Test("Two overlapping utterances serialise instead of colliding")
    func overlappingUtterancesSerialise() async throws {
        let (engine, format) = try await preparedEngine()

        async let first: TranscriptionOutcome = utterance(
            engine,
            format: format,
            holdBeforeFinish: .milliseconds(250)
        )
        // Long enough that `first` is provably mid-flight, short enough to stay inside the wait
        // ceiling once it is not leaking.
        try await Task.sleep(for: .milliseconds(80))
        async let second: TranscriptionOutcome = utterance(engine, format: format)

        _ = try await (first, second)
        #expect(await engine.isSlotClaimed == false)
    }

    /// An import and a dictation share the one engine, and they reach it through *different* entry
    /// points — the import through `transcribe(input:…)`, the dictation through `begin` — which is
    /// exactly the asymmetry the leak lived in. Interleaving them proves both doors release.
    @Test("A dictation immediately after an import gets the engine")
    func dictationAfterImport() async throws {
        let (engine, format) = try await preparedEngine()

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(try Self.chunk(format: format, seconds: 0.4))
        continuation.finish()
        _ = try await engine.transcribe(
            input: stream,
            module: .dictation,
            biasing: [],
            onUpdate: { _ in }
        )
        #expect(await engine.isSlotClaimed == false)

        // No gap at all: this is the drop-a-file-then-press-the-key case.
        try await utterance(engine, format: format)
        #expect(await engine.isSlotClaimed == false)

        // And the other order, which is the one `ImportQueue` retries around.
        try await utterance(engine, format: format)
        let (second, secondContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        secondContinuation.yield(try Self.chunk(format: format, seconds: 0.4))
        secondContinuation.finish()
        _ = try await engine.transcribe(
            input: second,
            module: .dictation,
            biasing: [],
            onUpdate: { _ in }
        )
        #expect(await engine.isSlotClaimed == false)
    }

    /// Ten in a row, no gaps. The reported symptom was that it *alternated* — a refused press
    /// creates no session, so the following press finds a clean slot — and an alternating failure
    /// is invisible to a test that runs the sequence twice.
    @Test("Ten consecutive utterances all run")
    func tenConsecutiveUtterances() async throws {
        let (engine, format) = try await preparedEngine()

        for index in 1...10 {
            try await utterance(engine, format: format, seconds: 0.2)
            #expect(
                await engine.isSlotClaimed == false,
                "the slot was still held after utterance \(index)"
            )
        }
    }
}
