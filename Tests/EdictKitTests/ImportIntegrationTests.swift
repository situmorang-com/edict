import AVFoundation
import Foundation
import Testing
@testable import EdictKit

/// The wiring between `AudioFileImporter`, `ImportQueue` and the store — everything except the
/// speech model itself, which is replaced by a closure so these run without assets, a microphone or
/// a locale reservation.
///
/// Real files on real disk, though. `AVAssetReader` is the whole reason the import path can open a
/// video container, and a fake importer would test nothing about it.
@Suite("Import integration")
@MainActor
struct ImportIntegrationTests {

    // MARK: - Fixtures

    /// A directory that cleans itself up when the test ends.
    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-import-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a real WAV file of the given length: a quiet sine, so the file is not degenerate.
    @discardableResult
    private func writeWave(seconds: Double, to url: URL, sampleRate: Double = 44_100) throws -> URL {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ]
        )
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = frames
        if let channel = buffer.floatChannelData?[0] {
            for frame in 0..<Int(frames) {
                channel[frame] = 0.1 * sin(2 * .pi * 440 * Double(frame) / sampleRate).float
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// A canned outcome whose words carry the per-word time ranges the real engine only supplies
    /// when the module is built with `attributeOptions: [.transcriptionConfidence, .audioTimeRange]`.
    private nonisolated static func outcome(_ words: [String], step: Double = 0.4) -> TranscriptionOutcome {
        let confidences = words.enumerated().map { index, word in
            WordConfidence(
                text: word,
                confidence: index == 1 ? 0.2 : 0.95,
                startSeconds: Double(index) * step,
                endSeconds: Double(index + 1) * step
            )
        }
        return TranscriptionOutcome(
            text: words.joined(separator: " "),
            confidence: 0.9,
            latency: 0.05,
            audioDuration: Double(words.count) * step,
            words: confidences,
            lowConfidenceWords: words.count > 1 ? [words[1]] : []
        )
    }

    /// An environment that drains the audio stream and hands back a fixed outcome, recording what it
    /// saw. `drain` matters: the importer is back-pressured, so a consumer that never reads would
    /// park the reader forever rather than fail.
    private func environment(
        returning outcomes: @escaping @Sendable (Int) -> TranscriptionOutcome,
        counter: Counter
    ) -> ImportQueue.Environment {
        ImportQueue.Environment(
            analyzerFormat: { AudioFormats.analyzerFallback() },
            transcribe: { stream, onUpdate in
                var frames = 0
                for await input in stream { frames += Int(input.buffer.frameLength) }
                let index = counter.next()
                counter.record(frames: frames)
                let result = outcomes(index)
                onUpdate(TranscriptionUpdate(
                    finalText: result.text, volatileText: "", isFinal: true
                ))
                return result
            }
        )
    }

    /// Shared, `Sendable` bookkeeping for the fake engine.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var frames: [Int] = []
        func next() -> Int { lock.withLock { defer { calls += 1 }; return calls } }
        func record(frames count: Int) { lock.withLock { frames.append(count) } }
        var callCount: Int { lock.withLock { calls } }
        var framesSeen: [Int] { lock.withLock { frames } }
    }

    /// Runs the queue to quiescence, or fails the test.
    private func drain(_ queue: ImportQueue, timeout: Duration = .seconds(20)) async throws {
        let deadline = ContinuousClock.now + timeout
        while queue.pendingCount > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(queue.pendingCount == 0, "the queue did not finish inside \(timeout)")
    }

    // MARK: - Segment derivation

    @Test("Only runs that carried a time range become segments, and they come out sorted")
    func segmentsAreTimedAndSorted() {
        let words = [
            WordConfidence(text: "second", confidence: 0.9, startSeconds: 1.0, endSeconds: 1.4),
            WordConfidence(text: "untimed", confidence: 0.9),
            WordConfidence(text: "first", confidence: 0.9, startSeconds: 0.0, endSeconds: 0.5),
            WordConfidence(text: "  ", confidence: 0.9, startSeconds: 2.0, endSeconds: 2.1),
        ]
        let segments = ImportQueue.segments(from: words)
        #expect(segments.map(\.text) == ["first", "second"])
        #expect(segments[0].start == 0)
        #expect(segments[1].start == 1.0)
    }

    /// The Indonesian case, in a unit test. Measured on this machine: `DictationTranscriber` on
    /// `id_ID` returns a time range on every run and a confidence on none, so requiring confidence
    /// produced an empty segment list and silently broke subtitle export for that language.
    @Test("A run with timings but no confidence still becomes a segment")
    func timedRunWithoutConfidence() {
        let words = (0..<3).map { index in
            WordConfidence(
                text: "kata\(index)",
                confidence: nil,
                startSeconds: Double(index) * 0.5,
                endSeconds: Double(index + 1) * 0.5
            )
        }
        let segments = ImportQueue.segments(from: words)
        #expect(segments.count == 3)
        #expect(segments.allSatisfy { $0.confidence == nil })
        // Which is what matters: an SRT can be cut from these.
        let transcript = Transcript(
            rawText: "kata0 kata1 kata2",
            text: "kata0 kata1 kata2",
            source: .imported(filename: "indonesian.m4a"),
            segments: segments
        )
        #expect(TranscriptExport.availableFormats(for: transcript).contains(.srt))
        #expect(TranscriptExport.string(for: transcript, format: .srt).hasPrefix("1\n00:00:00,000 --> "))
    }

    @Test("A zero-length run still yields a segment whose end is not before its start")
    func zeroLengthRun() {
        let segments = ImportQueue.segments(
            from: [WordConfidence(text: "tick", confidence: 0.9, startSeconds: 3.0, endSeconds: nil)]
        )
        #expect(segments.count == 1)
        #expect(segments[0].end >= segments[0].start)
    }

    // MARK: - One file end to end

    @Test("A real file is read, transcribed, and handed to onFinish with timed segments")
    func oneFileEndToEnd() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeWave(seconds: 1.0, to: dir.appendingPathComponent("clip.wav"))

        let counter = Counter()
        let queue = ImportQueue(
            environment: environment(returning: { _ in Self.outcome(["Hello", "wrold", "there"]) },
                                     counter: counter)
        )

        let received = Box<ImportQueue.Result?>(nil)
        queue.onFinish = { result in
            received.value = result
            return UUID()
        }

        queue.enqueue(url)
        try await drain(queue)

        let result = try #require(received.value)
        #expect(result.info.filename == "clip.wav")
        #expect(result.info.hasVideo == false)
        // 1 s at 16 kHz mono is 16 000 frames; the reader's last chunk may be short, so this is a
        // range rather than an equality.
        #expect(counter.framesSeen.first ?? 0 > 15_000)
        #expect(result.segments.count == 3)
        #expect(result.segments.map(\.text) == ["Hello", "wrold", "there"])
        #expect(result.incompleteReason == nil)
        #expect(result.stats.dropped == 0)
        #expect(queue.items.first?.state == .done)
    }

    // MARK: - Serial batching

    @Test("Files run one at a time, in the order they were dropped")
    func batchIsSerialAndOrdered() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let urls = try (0..<3).map { index in
            try writeWave(seconds: 0.3, to: dir.appendingPathComponent("take-\(index).wav"))
        }

        let counter = Counter()
        let queue = ImportQueue(
            environment: environment(returning: { index in Self.outcome(["file", "\(index)"]) },
                                     counter: counter)
        )

        let order = Box<[String]>([])
        queue.onFinish = { result in
            order.value.append(result.info.filename)
            return UUID()
        }

        queue.enqueue(urls)
        #expect(queue.pendingCount == 3)
        try await drain(queue)

        #expect(order.value == ["take-0.wav", "take-1.wav", "take-2.wav"])
        #expect(counter.callCount == 3)
        #expect(queue.items.allSatisfy { $0.state == .done })
        #expect(queue.overallProgress == 1.0)
    }

    @Test("Dropping the same file twice while it is still queued does not transcribe it twice")
    func duplicatesAreIgnoredWhileQueued() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeWave(seconds: 0.3, to: dir.appendingPathComponent("dupe.wav"))

        let counter = Counter()
        let queue = ImportQueue(
            environment: environment(returning: { _ in Self.outcome(["once"]) }, counter: counter)
        )
        queue.onFinish = { _ in UUID() }

        queue.enqueue([url, url, url])
        #expect(queue.items.count == 1)
        try await drain(queue)
        #expect(counter.callCount == 1)
    }

    // MARK: - Failures and cancellation

    @Test("A file with no audio track fails its own row and does not stop the batch")
    func aBadFileDoesNotStopTheQueue() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("not-audio.wav")
        try Data("this is not a wave file".utf8).write(to: bad)
        let good = try writeWave(seconds: 0.3, to: dir.appendingPathComponent("good.wav"))

        let counter = Counter()
        let queue = ImportQueue(
            environment: environment(returning: { _ in Self.outcome(["fine"]) }, counter: counter)
        )
        let finished = Box<[String]>([])
        queue.onFinish = { result in
            finished.value.append(result.info.filename)
            return UUID()
        }

        queue.enqueue([bad, good])
        try await drain(queue)

        // The engine ran exactly once — for the good file. The bad one never reached it.
        #expect(counter.callCount == 1)
        #expect(finished.value == ["good.wav"])
        let badRow = try #require(queue.items.first { $0.filename == "not-audio.wav" })
        guard case .failed(let reason) = badRow.state else {
            Issue.record("expected a failed row, got \(badRow.state)")
            return
        }
        // The string is shown verbatim in the queue, so it has to be a sentence.
        #expect(!reason.isEmpty)
        #expect(queue.items.first { $0.filename == "good.wav" }?.state == .done)
    }

    @Test("A queued file that is cancelled before it starts is never transcribed")
    func cancelBeforeStart() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try writeWave(seconds: 0.5, to: dir.appendingPathComponent("a.wav"))
        let second = try writeWave(seconds: 0.5, to: dir.appendingPathComponent("b.wav"))

        let counter = Counter()
        let queue = ImportQueue(
            environment: environment(returning: { _ in Self.outcome(["x"]) }, counter: counter)
        )
        queue.onFinish = { _ in UUID() }

        let ids = queue.enqueue([first, second])
        queue.cancel(ids[1])
        try await drain(queue)

        #expect(counter.callCount == 1)
        #expect(queue.items.last?.state == .cancelled)
        // A cancelled row is excluded from the batch weighting, so one done file is 100 %.
        #expect(queue.overallProgress == 1.0)
    }

    @Test("Retry replaces a terminal row rather than adding a second one for the same file")
    func retryReplacesTheRow() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeWave(seconds: 0.3, to: dir.appendingPathComponent("again.wav"))

        let counter = Counter()
        let queue = ImportQueue(
            environment: environment(returning: { _ in Self.outcome(["twice"]) }, counter: counter)
        )
        queue.onFinish = { _ in UUID() }

        let id = try #require(queue.enqueue(url))
        try await drain(queue)
        #expect(counter.callCount == 1)

        queue.retry(id)
        #expect(queue.items.count == 1, "retry must not leave two rows for one file")
        try await drain(queue)
        #expect(counter.callCount == 2)
    }

    @Test("A file that produced no text leaves nothing in history and no id on the row")
    func silentFileWritesNothing() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeWave(seconds: 0.3, to: dir.appendingPathComponent("mute.wav"))

        let counter = Counter()
        let queue = ImportQueue(
            environment: environment(
                returning: { _ in
                    TranscriptionOutcome(text: "", confidence: nil, latency: 0, audioDuration: 0.3)
                },
                counter: counter
            )
        )
        // Mirrors `DictationController.completeImport`, which refuses to write an empty transcript.
        queue.onFinish = { result in
            result.outcome.text.trimmed.isEmpty ? nil : UUID()
        }

        queue.enqueue(url)
        try await drain(queue)

        #expect(queue.items.first?.state == .done)
        #expect(queue.items.first?.transcriptID == nil)
    }

    // MARK: - Video

    @Test("A video container is opened for its audio track and tagged as video")
    func videoContainer() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A real .mov with one audio track, written by AVFoundation rather than hand-rolled.
        let source = try writeWave(seconds: 0.5, to: dir.appendingPathComponent("src.wav"))
        let movie = dir.appendingPathComponent("clip.m4a")
        try await export(source, to: movie)

        let info = try await AudioFileImporter.inspect(url: movie)
        #expect(info.duration > 0.4)
        #expect(info.channelCount == 1)

        let counter = Counter()
        let queue = ImportQueue(
            environment: environment(returning: { _ in Self.outcome(["mp", "four"]) }, counter: counter)
        )
        let received = Box<ImportQueue.Result?>(nil)
        queue.onFinish = { received.value = $0; return UUID() }
        queue.enqueue(movie)
        try await drain(queue)

        let result = try #require(received.value)
        #expect(result.segments.count == 2)
        #expect(counter.framesSeen.first ?? 0 > 6_000)
    }

    /// Transcodes to AAC in an MPEG-4 container, so the reader has a compressed track to decode
    /// rather than the linear PCM it could pass straight through.
    private func export(_ source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try await session.export(to: destination, as: .m4a)
    }
}

// MARK: - Helpers

/// A reference cell, so a `@Sendable` callback can report back into a test body.
/// `@unchecked` is honest here: every access is on the main actor, and the tests are serial.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private extension Double {
    var float: Float { Float(self) }
}
