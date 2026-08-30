//
//  ImportLocaleTests.swift
//  A locale that travels with the file.
//
//  The defect these tests exist for is not a crash and not an exception. `resolvedImportModule()`
//  read `Settings.localeIdentifier`, so an imported file was transcribed in whatever language the
//  *dictation* picker happened to hold — and the English model handed Indonesian speech does not
//  fail, it resolves unfamiliar phoneme runs into confident English proper nouns. A real 70-minute
//  Indonesian meeting came back as 900 words of nonsense ("Kanaya Sushma Manga Cheil Danka") and was
//  read to the end before anyone suspected the cause. RECON amendment 45 has the measurement.
//
//  So there are two layers here. The plumbing suite uses fake closures and proves the *contract*:
//  the locale is frozen at enqueue, travels with the row, is overridable per row, and a language
//  that cannot be served fails the row instead of quietly borrowing another model. The engine suite
//  is gated behind `EDICT_SPEECH_TESTS=1` — it reserves locales, shells out to `say`, and runs the
//  real on-device models — and proves the point: the same audio, enqueued twice under two locales,
//  comes back as two measurably different transcripts, and the Indonesian one is Indonesian.
//

import AVFoundation
import Foundation
import Speech
import Testing

@testable import EdictKit

// MARK: - Shared helpers

/// Records what a fake engine was asked for, across the concurrency domains the queue hops through.
private final class LocaleLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    private var formats: [String] = []

    func transcribed(_ identifier: String) { lock.withLock { seen.append(identifier) } }
    func formatAsked(_ identifier: String) { lock.withLock { formats.append(identifier) } }
    var transcribedLocales: [String] { lock.withLock { seen } }
    var formatLocales: [String] { lock.withLock { formats } }
}

/// A mutable locale the environment closures read, so a test can move the "dictation language"
/// underneath a queue the way the settings picker does.
private final class LocaleSetting: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    init(_ value: String?) { self.value = value }
    var current: String? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Gate a fake transcription on an explicit release, so a test can inspect a queue mid-flight.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    func release() { lock.withLock { open = true } }
    func wait() async {
        while !lock.withLock({ open }) {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

/// A real WAV file of the requested length — quiet, so it is not degenerate, and real, because the
/// queue drives `AVAssetReader` and a fake importer would prove nothing about the plumbing under it.
private func writeWave(seconds: Double, to url: URL) throws {
    let rate = 16_000.0
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false
    ) else { throw CocoaError(.fileWriteUnknown) }
    let file = try AVAudioFile(
        forWriting: url,
        settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ]
    )
    let frames = AVAudioFrameCount(seconds * rate)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
        throw CocoaError(.fileWriteUnknown)
    }
    buffer.frameLength = frames
    if let channel = buffer.floatChannelData?[0] {
        for frame in 0..<Int(frames) {
            channel[frame] = Float(0.1 * sin(2 * .pi * 440 * Double(frame) / rate))
        }
    }
    try file.write(from: buffer)
}

/// One fixture set for the whole plumbing suite, written once.
///
/// Shared rather than per test because the suite is `.serialized` and the files are read-only: 15
/// tests each writing their own WAVs cost 15 `AVAudioFile` sessions and 15 directories, and that CPU
/// lands as latency in the wall-clock timing suites sharing the process (see `drain`). A `static let`
/// is initialised exactly once, lazily, and thread-safely.
private enum Fixtures {
    static let directory: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-import-locale-fixtures", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Real, tiny (0.12 s at 16 kHz mono), and written only if it is not already there.
    static let files: [URL] = (0..<3).map { index in
        let url = directory.appendingPathComponent("fixture-\(index).wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? writeWave(seconds: 0.12, to: url)
        }
        return url
    }

    /// A path with no file behind it, for a test that only cares about the queue's bookkeeping: the
    /// row fails on `open()` in microseconds, with no decode, no segmenter and no transcription.
    static func absent(_ index: Int) -> URL {
        directory.appendingPathComponent("absent-\(index)-\(UUID().uuidString).wav")
    }
}

private func scratchDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("edict-import-locale-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - The plumbing

/// Everything about a per-item locale that does not need a speech model.
///
/// `.serialized`, and not for tidiness. Each test here holds a live `ImportQueue`, which is
/// `@MainActor` and, while an item runs, ticks a progress estimate at 10 Hz and is polled by `drain`
/// at 100 Hz. Fifteen of those in parallel saturate the main actor: measured, the *whole* run stalled
/// — 441 of 563 tests finished and the remaining 57 never completed, across suites that have nothing
/// to do with this file, while the same suite on its own finished in 0.65 s. Serialised, the full
/// suite is back to ~5.5 s.
@Suite("Import locale — plumbing", .serialized)
@MainActor
struct ImportLocalePlumbingTests {

    // MARK: Fixtures

    private nonisolated static func outcome(_ text: String) -> TranscriptionOutcome {
        let words = text.split(separator: " ").enumerated().map { index, word in
            WordConfidence(
                text: String(word),
                confidence: 0.9,
                startSeconds: Double(index) * 0.3,
                endSeconds: Double(index + 1) * 0.3
            )
        }
        return TranscriptionOutcome(
            text: text,
            confidence: 0.9,
            latency: 0.01,
            audioDuration: Double(words.count) * 0.3,
            words: words,
            lowConfidenceWords: []
        )
    }

    /// A fake engine that echoes the locale it was asked for straight into the transcript, which is
    /// the only way to prove *which* language each row actually ran under.
    private func environment(
        dictation: LocaleSetting,
        partner: LocaleSetting = LocaleSetting(nil),
        log: LocaleLog,
        gate: Gate? = nil,
        failing: Set<String> = [],
        busyAttempts: Counter? = nil
    ) -> ImportQueue.Environment {
        return ImportQueue.Environment(
            analyzerFormat: { locale in
                log.formatAsked(locale)
                return AudioFormats.analyzerFallback()
            },
            transcribe: { locale, stream, onUpdate in
                // Drained rather than ignored: the importer is back-pressured, so a consumer that
                // never reads parks the reader for ever instead of failing.
                for await _ in stream {}
                await gate?.wait()
                if let busyAttempts, busyAttempts.next() < 1 {
                    // Exactly the error a live dictation produces, and it must escape unwrapped for
                    // `ImportQueue` to recognise it.
                    throw SpeechEngineError.sessionAlreadyRunning
                }
                // `Settings.localeKey` is main-actor-isolated and this closure is not, so the same
                // normalisation is spelled out here: `en-US`, `en_US` and `EN-us` are one locale.
                if failing.contains(locale.replacingOccurrences(of: "-", with: "_").lowercased()) {
                    throw ImportLocaleUnavailable(
                        localeIdentifier: locale,
                        reason: "Downloading the \(locale) speech model. Try this file again in a moment."
                    )
                }
                log.transcribed(locale)
                let result = Self.outcome("transcribed in \(locale)")
                onUpdate(TranscriptionUpdate(finalText: result.text, volatileText: "", isFinal: true))
                return result
            },
            dictationLocaleIdentifier: { dictation.current ?? Settings.Default.localeIdentifier },
            supportedLocaleIdentifiers: { ["en_US", "id_ID", "fr_FR", "en-US"] },
            dualPassPartnerLocaleIdentifier: { partner.current }
        )
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
        var count: Int { lock.withLock { value } }
    }

    /// Polled at 40 Hz rather than 100, and every fixture below is written on a detached task, for
    /// one measured reason: this suite shares the process with wall-clock timing tests, and main-actor
    /// work here lands as *latency* there. `AVAudioFile` writes on the main actor pushed
    /// `LateLocaleTests`' 400 ms language window from 0.53 s to 0.56–0.58 s against its 0.55 s
    /// ceiling — three runs, three failures, and zero failures with this suite disabled.
    private func drain(_ queue: ImportQueue, timeout: Duration = .seconds(20)) async throws {
        let deadline = ContinuousClock.now + timeout
        while queue.pendingCount > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(queue.pendingCount == 0, "the queue did not finish inside \(timeout)")
    }

    /// `count` real WAVs from the shared fixture set. See `Fixtures` for why they are shared.
    private func files(_ count: Int) async -> [URL] {
        await Task.detached(priority: .utility) { Array(Fixtures.files.prefix(count)) }.value
    }

    /// `count` paths with no file behind them, for the bookkeeping-only tests: the row fails on
    /// `open()` in microseconds, with no decode, no segmenter and no transcription.
    private func absentFiles(_ count: Int) -> [URL] { (0..<count).map(Fixtures.absent) }

    // MARK: Inheritance

    @Test("A row inherits the dictation language at enqueue and then stops listening to it")
    func inheritsAtEnqueueAndFreezes() async throws {
        let urls = await files(2)

        let dictation = LocaleSetting("en-US")
        let log = LocaleLog()
        let gate = Gate()
        let queue = ImportQueue(environment: environment(dictation: dictation, log: log, gate: gate))

        queue.enqueue(urls, localeIdentifier: nil)
        #expect(queue.items.map(\.localeIdentifier) == ["en-US", "en-US"])
        #expect(queue.items.allSatisfy { !$0.localeWasChosen }, "an inherited locale is not a chosen one")

        // The picker moves while the files are queued. This is the case the old code got wrong: it
        // re-read `Settings` inside the transcribe, so both files would have run as Indonesian.
        dictation.current = "id-ID"
        gate.release()
        try await drain(queue)

        #expect(log.transcribedLocales == ["en-US", "en-US"])
        #expect(queue.items.map(\.localeIdentifier) == ["en-US", "en-US"])
    }

    @Test("An explicit locale is chosen, normalised, and beats the dictation language")
    func explicitLocaleWins() async throws {
        let urls = await files(1)

        let log = LocaleLog()
        let queue = ImportQueue(
            environment: environment(dictation: LocaleSetting("en-US"), log: log)
        )
        // Underscored on the way in, because `DictationTranscriber.supportedLocales` reports
        // `id_ID` while Settings and history store `id-ID`; one spelling has to win at the boundary.
        queue.enqueue(urls, localeIdentifier: "id_ID")
        #expect(queue.items[0].localeIdentifier == "id-ID")
        #expect(queue.items[0].localeWasChosen)
        try await drain(queue)
        #expect(log.transcribedLocales == ["id-ID"])
        // The format is asked for the item's language too — the module is resolved from the locale,
        // and `availableCompatibleAudioFormats` is a property of the module.
        #expect(log.formatLocales == ["id-ID"])
    }

    // MARK: Per row, not per queue

    @Test("Three files can hold three languages in one queue, and each runs under its own")
    func mixedBatchRunsPerItem() async throws {
        let urls = await files(3)

        let log = LocaleLog()
        let queue = ImportQueue(
            environment: environment(dictation: LocaleSetting("en-US"), log: log)
        )
        var finished: [String: String] = [:]
        queue.onFinish = { result in
            finished[result.url.lastPathComponent] = result.localeIdentifier
            return UUID()
        }

        queue.enqueue([urls[0]], localeIdentifier: "en-US")
        queue.enqueue([urls[1]], localeIdentifier: "id-ID")
        queue.enqueue([urls[2]], localeIdentifier: "fr-FR")
        try await drain(queue)

        #expect(log.transcribedLocales == ["en-US", "id-ID", "fr-FR"])
        #expect(finished[urls[0].lastPathComponent] == "en-US")
        #expect(finished[urls[1].lastPathComponent] == "id-ID")
        #expect(finished[urls[2].lastPathComponent] == "fr-FR")
    }

    @Test("Dedup is per file *and* language: the same file in two languages is two rows")
    func dedupIsPerLanguage() async throws {
        let urls = absentFiles(1)

        let gate = Gate()
        let queue = ImportQueue(
            environment: environment(dictation: LocaleSetting("en-US"), log: LocaleLog(), gate: gate)
        )
        queue.enqueue(urls, localeIdentifier: "en-US")
        queue.enqueue(urls, localeIdentifier: "id-ID")
        // Same file, same language, still queued: the accident the dedup is for.
        queue.enqueue(urls, localeIdentifier: "en-US")
        #expect(queue.items.count == 2)
        #expect(queue.items.map(\.localeIdentifier) == ["en-US", "id-ID"])
        gate.release()
        try await drain(queue)
    }

    @Test("setLocale moves a queued row, records a confirmation, and refuses a finished one")
    func setLocaleRespectsState() async throws {
        // Bookkeeping only: an absent file drives the row to a terminal state as surely as a finished
        // transcription does, and "the moved locale is the one that runs" is proved by the mixed
        // batch below without a second set of decodes.
        let urls = absentFiles(2)

        let log = LocaleLog()
        let queue = ImportQueue(
            environment: environment(dictation: LocaleSetting("en-US"), log: log)
        )
        let ids = queue.enqueue(urls)
        // No await between enqueue and here, so the worker has not started: both rows are `.queued`
        // and both are editable.
        #expect(queue.items[0].localeWasChosen == false)
        // Confirming the language a row already inherited moves nothing — but the user has now
        // *looked* at it, so the row stops flagging itself as an unchecked default.
        #expect(queue.setLocale("en-US", for: ids[0]) == false)
        #expect(queue.items[0].localeWasChosen)
        #expect(queue.setLocale("id-ID", for: ids[1]))
        #expect(queue.items[1].localeIdentifier == "id-ID")
        #expect(queue.items[1].localeWasChosen)

        try await drain(queue)

        // Terminal: the analyzer is built from one `Locale` and never rebuilt, so the answer for a
        // finished row is `rerun`, not a mutation.
        #expect(queue.setLocale("fr-FR", for: ids[1]) == false)
        #expect(queue.items[1].localeIdentifier == "id-ID")
        #expect(queue.items[1].localeIsEditable == false)
    }

    @Test("retry keeps the row's own language and its provenance")
    func retryKeepsTheLanguage() async throws {
        let urls = absentFiles(1)

        let dictation = LocaleSetting("en-US")
        let log = LocaleLog()
        let queue = ImportQueue(environment: environment(dictation: dictation, log: log))
        let ids = queue.enqueue(urls)
        try await drain(queue)

        // The picker moved after the row finished. RETRY means "try that again", not "try it in
        // whatever language I am dictating in now".
        dictation.current = "fr-FR"
        queue.retry(ids[0])
        #expect(queue.items[0].localeIdentifier == "en-US")
        #expect(queue.items[0].localeWasChosen == false, "a retried row keeps its provenance")
        try await drain(queue)
        #expect(log.transcribedLocales.isEmpty, "an absent file never reaches the model")
    }

    // MARK: Re-running in another language

    @Test("rerun refuses an unfinished row, and otherwise adds a row and a transcript")
    func rerunIsAdditive() async throws {
        let urls = await files(1)

        let log = LocaleLog()
        let queue = ImportQueue(
            environment: environment(dictation: LocaleSetting("en-US"), log: log)
        )
        var history: [(locale: String, id: UUID)] = []
        queue.onFinish = { result in
            let id = UUID()
            history.append((result.localeIdentifier, id))
            return id
        }

        let first = try #require(queue.enqueue(urls).first)
        // Still `.queued` — the worker starts on a `Task`, and nothing has awaited yet. A row that
        // has not finished has nothing to compare against, so `rerun` must refuse it.
        #expect(queue.rerun(first, localeIdentifier: "id-ID") == nil)
        #expect(queue.items.count == 1)
        try await drain(queue)
        let firstTranscript = queue.items[0].transcriptID

        let second = try #require(queue.rerun(first, localeIdentifier: "id-ID"))
        #expect(queue.items.count == 2, "the first row must survive for the user to compare against")
        #expect(queue.items[1].id == second)
        #expect(queue.items[1].rerunOf == first, "the pair has to be identifiable")
        #expect(queue.items[1].localeWasChosen)
        try await drain(queue)

        #expect(log.transcribedLocales == ["en-US", "id-ID"])
        #expect(history.map(\.locale) == ["en-US", "id-ID"])
        #expect(history[0].id != history[1].id, "a re-run must not overwrite the first transcript")
        #expect(queue.items[0].transcriptID == firstTranscript, "the first row still points at its own")
        #expect(queue.items[1].transcriptID == history[1].id)

        // Re-running the re-run still points at the original, not at the middle of a chain.
        let third = try #require(queue.rerun(second, localeIdentifier: "fr-FR"))
        #expect(queue.items.first(where: { $0.id == third })?.rerunOf == first)
    }

    // MARK: No silent fallback

    @Test("A language whose model is missing fails the row with its own words, and never transcribes")
    func missingModelFailsRatherThanFallsBack() async throws {
        let urls = await files(2)

        let log = LocaleLog()
        let queue = ImportQueue(
            environment: environment(
                dictation: LocaleSetting("en-US"),
                log: log,
                failing: ["id_id"]
            )
        )
        var finishes = 0
        queue.onFinish = { _ in finishes += 1; return UUID() }

        queue.enqueue([urls[0]], localeIdentifier: "id-ID")
        queue.enqueue([urls[1]], localeIdentifier: "en-US")
        try await drain(queue)

        guard case .failed(let reason) = queue.items[0].state else {
            Issue.record("the Indonesian row is \(queue.items[0].state), not failed")
            return
        }
        #expect(reason.contains("Downloading"), "the row must carry the engine's own sentence")
        #expect(queue.items[1].state == .done, "one bad language must not stop the batch")
        // The whole point: nothing was transcribed under a substituted language.
        #expect(log.transcribedLocales == ["en-US"])
        #expect(finishes == 1, "a failed language must not write a transcript")
    }

    @Test("A live dictation holding the engine makes the import wait, not fail")
    func engineBusyRetries() async throws {
        let urls = await files(1)

        let attempts = Counter()
        let log = LocaleLog()
        let queue = ImportQueue(
            environment: environment(
                dictation: LocaleSetting("en-US"), log: log, busyAttempts: attempts
            )
        )
        queue.enqueue(urls, localeIdentifier: "id-ID")
        try await drain(queue)

        #expect(attempts.count == 2, "one refusal then a success")
        #expect(queue.items[0].state == .done)
        // The retried attempts must carry the *item's* locale, not re-resolve it.
        #expect(log.transcribedLocales == ["id-ID"])
    }

    // MARK: Dual pass

    @Test("Dual pass is offered the item's locale as its first pass")
    func dualPassGetsTheItemLocale() async throws {
        let urls = await files(1)

        let log = LocaleLog()
        var base = environment(dictation: LocaleSetting("en-US"), log: log)
        let dualLog = LocaleLog()
        base.dualPass = { _, locale, _ in
            dualLog.transcribed(locale)
            // Declining, so the single pass runs and the row still finishes — this test is about
            // which locale the closure is handed.
            return nil
        }
        let queue = ImportQueue(environment: base)
        queue.enqueue(urls, localeIdentifier: "id-ID")
        try await drain(queue)

        #expect(dualLog.transcribedLocales == ["id-ID"])
        #expect(log.transcribedLocales == ["id-ID"], "a declined dual pass falls back to one pass, same language")
    }

    @Test("The second pass's language is reported per row, and suppressed when it would be the same")
    func secondPassLocaleIsReportedPerRow() async throws {
        let urls = absentFiles(2)

        let partner = LocaleSetting("id-ID")
        let gate = Gate()
        let queue = ImportQueue(
            environment: environment(
                dictation: LocaleSetting("en-US"),
                partner: partner,
                log: LocaleLog(),
                gate: gate
            )
        )
        let ids = queue.enqueue([urls[0]], localeIdentifier: "en-US")
            + queue.enqueue([urls[1]], localeIdentifier: "id-ID")

        #expect(queue.secondPassLocaleIdentifier(for: ids[0]) == "id-ID")
        // Same language on both sides: there is no pair left to compare, so one pass and the UI must
        // not promise two.
        #expect(queue.secondPassLocaleIdentifier(for: ids[1]) == nil)

        partner.current = nil
        #expect(queue.secondPassLocaleIdentifier(for: ids[0]) == nil)
        gate.release()
        try await drain(queue)
    }

    // MARK: What the surface renders

    @Test("The picker gets the superset, deduplicated, hyphenated and named")
    func supportedLocalesForThePicker() async throws {
        let queue = ImportQueue(
            environment: environment(dictation: LocaleSetting("en-US"), log: LocaleLog())
        )
        #expect(queue.supportedLocaleIdentifiers.isEmpty, "nothing before the await lands")
        await queue.loadSupportedLocales()
        // `en_US` and `en-US` are the same locale in two spellings and must not both be offered.
        #expect(queue.supportedLocaleIdentifiers == ["en-US", "fr-FR", "id-ID"])
        #expect(ImportQueue.localeDisplayName("id_ID") == "Indonesian (Indonesia)")
        #expect(ImportQueue.localeDisplayName("id-ID") == "Indonesian (Indonesia)")
        #expect(ImportQueue.localeDisplayName("xx-YY") == "xx-YY", "an unknown identifier is still a label")
        #expect(ImportQueue.dualPassRule.contains("first of the two"))
    }
}

// MARK: - The engine

/// The same plumbing, against the real on-device models.
///
/// Gated behind `EDICT_SPEECH_TESTS=1` for the reasons the other engine suites give: it takes locale
/// reservations (5 maximum, persisting across launches keyed by bundle id), it shells out to `say`,
/// and it runs real transcriptions. Run it deliberately:
///
///     EDICT_SPEECH_TESTS=1 swift test --filter ImportLocaleEngine
///
/// Everything in the plumbing suite proves the contract. This proves the *claim*: that the file's own
/// locale reaches the model, that two locales over one file produce two different transcripts, and
/// that the Indonesian one is Indonesian rather than a page of invented English names.
@Suite("Import locale — engine end to end",
       .enabled(if: ProcessInfo.processInfo.environment["EDICT_SPEECH_TESTS"] == "1"),
       .serialized)
@MainActor
struct ImportLocaleEngineTests {

    /// Indonesian in the register the user actually dictates in — code-switched English nouns inside
    /// Indonesian grammar, which is the exact material the English model turns into proper nouns.
    static let indonesian = """
        Selamat pagi semuanya. Dan ada workshop karena sekarang timnya dia itu sangat kecil. \
        Dan dia interested dengan workshop itu. Cuma memang dia diinfo oleh teman teman \
        kalau harganya sangat murah, jadi kita harus cari cara untuk membandingkan harganya.
        """

    static let english = """
        Good morning everyone. Today we will discuss the project plan and the budget for the next \
        quarter, and then we will look at the numbers together before we decide anything.
        """

    /// The third language of the mixed batch.
    ///
    /// `en-GB` rather than a fourth *language*, and the choice is a measurement rather than a
    /// preference: on this machine only `en-US` and `id-ID` have models installed for the modules
    /// `SpeechEngine` actually builds — `es-ES`, `de-DE`, `ja-JP` and `fr-FR` all report their assets
    /// missing and correctly *fail* the row with a download notice, which is the feature working but
    /// not a demonstration of three languages running. `en-GB` is a distinct locale with a distinct
    /// acoustic model, its `SpeechTranscriber` assets are installed, and asking about it downloads
    /// nothing.
    static let british = """
        Good afternoon. The lorry is parked outside the aluminium warehouse near the roundabout, \
        and the schedule for the privatisation has already been published.
        """

    /// Words that only appear in a genuine Indonesian transcript. The English model produces names,
    /// not function words, which is what makes this a usable discriminator rather than a vibe.
    static let indonesianMarkers = [
        "dan", "yang", "itu", "dia", "kita", "untuk", "sangat", "harganya", "sekarang", "karena",
        "jadi", "memang", "teman", "cari", "cara", "pagi", "semuanya",
    ]

    // MARK: Fixtures

    private static func synthesise(_ text: String, voice: String, into directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(voice)-\(UUID().uuidString).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-r", "175", "-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AudioImportError.unreadable(filename: url.lastPathComponent, reason: "say failed")
        }
        return url
    }

    /// Re-wrap one fixture through `ffmpeg` into an m4a, so at least one file in the mixed batch
    /// arrives in a compressed container rather than as raw AIFF. Skipped if ffmpeg is absent.
    private static func transcode(_ url: URL) -> URL? {
        let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let ffmpeg else { return nil }
        let output = url.deletingPathExtension().appendingPathExtension("m4a")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-y", "-loglevel", "error", "-i", url.path, output.path]
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? output : nil
    }

    /// A controller wired exactly as the app wires it, minus the microphone. `EphemeralDefaults` and
    /// `/dev/null` stores keep this off the user's real settings and history — RECON amendment 39.
    private func controller(dictationLocale: String) -> (DictationController, HistoryStore) {
        let settings = Settings(defaults: EphemeralDefaults())
        settings.localeIdentifier = dictationLocale
        // Dual pass off: it has its own suite, and a second pass would make every number below a
        // measurement of two models rather than one.
        settings.importDualPass = false
        let history = HistoryStore(fileURL: URL(fileURLWithPath: "/dev/null"))
        let controller = DictationController(
            settings: settings,
            dictionary: DictionaryStore(fileURL: URL(fileURLWithPath: "/dev/null")),
            history: history,
            permissions: Permissions()
        )
        return (controller, history)
    }

    private func drain(_ queue: ImportQueue, timeout: Duration = .seconds(180)) async throws {
        let deadline = ContinuousClock.now + timeout
        while queue.pendingCount > 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(queue.pendingCount == 0, "the queue did not finish inside \(timeout)")
    }

    /// Whether an import of `identifier` can resolve without starting a model download.
    ///
    /// Both modules, in the order `resolveImportPass` tries them: the general one where it covers the
    /// language, then the dictation one. If neither has its assets on disk, resolving the language
    /// calls `downloadAndInstall()` from a detached task, which is why this has to be asked *before*
    /// anything is enqueued rather than inferred from the row's failure afterwards.
    ///
    /// Asked through `SpeechEngine.assetsInstalled`, which builds the probe the way a real session
    /// would. A hand-rolled probe lies: RECON's second `AssetInventory` trap is that installed state
    /// depends on `attributeOptions`, and `fr-FR` on the general module reads installed with `[]` and
    /// missing with the `[.transcriptionConfidence, .audioTimeRange]` Edict always requests.
    ///
    /// Asking is not free — each check reserves the locale it asks about (RECON §6) — which is
    /// acceptable here only because this whole suite is gated and takes real reservations anyway.
    private static func importResolvesWithoutDownloading(_ identifier: String) async -> Bool {
        let asked = Locale(identifier: identifier)
        if let general = await SpeechTranscriber.supportedLocale(equivalentTo: asked),
           await SpeechEngine.assetsInstalled(module: .general, locale: general) {
            return true
        }
        if let dictation = await DictationTranscriber.supportedLocale(equivalentTo: asked),
           await SpeechEngine.assetsInstalled(module: .dictation, locale: dictation) {
            return true
        }
        return false
    }

    private static func markerHits(_ text: String) -> Int {
        let words = Set(
            text.lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
        )
        return indonesianMarkers.count { words.contains($0) }
    }

    // MARK: The whole point

    /// One Indonesian file, enqueued twice: once as `en-US`, once as `id-ID`.
    ///
    /// The dictation language is left at `en-US` for both, which is the configuration that produced
    /// the original disaster — under the old code both rows would have run the English model.
    @Test("The same Indonesian file under two locales gives two different transcripts")
    func sameFileTwoLocales() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try Self.synthesise(Self.indonesian, voice: "Damayanti", into: directory)

        let (controller, history) = controller(dictationLocale: "en-US")
        let queue = ImportQueue(environment: controller.importEnvironment())
        var transcripts: [String: Transcript] = [:]
        queue.onFinish = { result in
            let id = controller.completeImport(result)
            if let id, let transcript = history.transcripts.first(where: { $0.id == id }) {
                transcripts[result.localeIdentifier] = transcript
            }
            return id
        }

        let english = try #require(queue.enqueue(audio, localeIdentifier: "en-US"))
        let indonesian = try #require(queue.enqueue(audio, localeIdentifier: "id-ID"))
        #expect(english != indonesian, "the same file in two languages is two rows")
        try await drain(queue)

        let asEnglish = try #require(transcripts["en-US"])
        let asIndonesian = try #require(transcripts["id-ID"])

        print("""
            [import-locale] one Indonesian file, two locales
              en-US  \(asEnglish.wordCount) words, \(asEnglish.engine), \
            \(String(format: "%.1f", asEnglish.audioDuration / max(0.001, asEnglish.transcribeDuration)))x, \
            markers \(Self.markerHits(asEnglish.text))/\(Self.indonesianMarkers.count), \
            low-confidence \(asEnglish.lowConfidenceWords.count)
                \(asEnglish.text)
              id-ID  \(asIndonesian.wordCount) words, \(asIndonesian.engine), \
            \(String(format: "%.1f", asIndonesian.audioDuration / max(0.001, asIndonesian.transcribeDuration)))x, \
            markers \(Self.markerHits(asIndonesian.text))/\(Self.indonesianMarkers.count), \
            low-confidence \(asIndonesian.lowConfidenceWords.count)
                \(asIndonesian.text)
            """)

        // Measurably different, not "probably different".
        #expect(asEnglish.text != asIndonesian.text)
        #expect(
            Self.markerHits(asIndonesian.text) >= 6,
            "the id-ID transcript is not Indonesian: \(asIndonesian.text)"
        )
        #expect(
            Self.markerHits(asIndonesian.text) > Self.markerHits(asEnglish.text),
            "the two locales did not produce distinguishable languages"
        )
        // Each row is filed under the language that actually ran, and Indonesian is one of the nine
        // locales only the dictation module covers.
        #expect(asIndonesian.localeIdentifier == "id-ID")
        #expect(asEnglish.localeIdentifier == "en-US")
        #expect(asIndonesian.engine == TranscriptionModule.dictation.engineIdentifier)
        #expect(asEnglish.engine == TranscriptionModule.general.engineIdentifier)
    }

    /// The module is resolved per locale, not once for the app: this is the measurement behind that.
    @Test("The general module covers 45 locales, the dictation module 54, and id-ID is in the gap")
    func moduleCoverageIsPerLocale() async throws {
        let general = await SpeechTranscriber.supportedLocales
        let dictation = await DictationTranscriber.supportedLocales
        print("""
            [import-locale] locale coverage: general \(general.count), dictation \(dictation.count)
            """)
        #expect(general.count < dictation.count)
        #expect(await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "id-ID")) == nil)
        #expect(await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: "id-ID")) != nil)
    }

    /// Three files, three languages, one queue run.
    ///
    /// The three locales are chosen because all three have their models on this machine, which had to
    /// be *measured* rather than assumed — and the measurement turned up something worth writing down:
    /// `AssetInventory.assetInstallationRequest` answers differently depending on the module's
    /// `attributeOptions`. `fr-FR` reports installed for a `SpeechTranscriber` built with
    /// `attributeOptions: []` and **missing** for the same locale built with
    /// `[.transcriptionConfidence, .audioTimeRange]`, which is what `SpeechEngine.build` always asks
    /// for (RECON §7 explains why it must). So "is this language ready" is only answerable through the
    /// module the app actually builds.
    ///
    /// The en-GB row is **enqueued only if its model is on disk**, and that is a safety measure
    /// rather than tidiness. `resolveImportPass` answers a language whose model is missing by calling
    /// `downloadAndInstall()` from a detached task — minutes of somebody's bandwidth, started before
    /// the row can report anything — and on the machine this was written on the models for
    /// `en-GB`/`en-AU`/`en-CA` are all absent. The old version enqueued it unconditionally and
    /// accommodated the resulting `.failed` row, which read as handling the case while in fact paying
    /// for the download every run. A Mac without British assets has nothing wrong with it, so the row
    /// is skipped with a printed line saying so.
    ///
    /// The `.failed` branch in the loop stays, because it is still the invariant worth pinning: a
    /// language that cannot be served fails carrying its own language's sentence, and no transcript is
    /// ever written under a substituted locale. On a machine with all three models the expectation is
    /// `.done` for all three, and the loop says which case each row took.
    @Test("A mixed batch transcribes each file under its own locale")
    func mixedBatch() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let englishAudio = try Self.synthesise(Self.english, voice: "Samantha", into: directory)
        let indonesianAudio = try Self.synthesise(Self.indonesian, voice: "Damayanti", into: directory)

        // Asked before anything is enqueued, so the answer can keep the row out of the queue rather
        // than letting the queue discover it and start a download.
        let britishReady = await Self.importResolvesWithoutDownloading("en-GB")

        let (controller, history) = controller(dictationLocale: "en-US")
        let queue = ImportQueue(environment: controller.importEnvironment())
        var byFile: [String: Transcript] = [:]
        queue.onFinish = { result in
            let id = controller.completeImport(result)
            if let id, let transcript = history.transcripts.first(where: { $0.id == id }) {
                byFile[result.url.lastPathComponent] = transcript
            }
            return id
        }

        queue.enqueue([englishAudio], localeIdentifier: "en-US")
        queue.enqueue([indonesianAudio], localeIdentifier: "id-ID")
        var expectedLocales = ["en-US", "id-ID"]
        if britishReady {
            let britishAiff = try Self.synthesise(Self.british, voice: "Daniel", into: directory)
            // One compressed container in the batch, because the import path's whole reason for using
            // `AVAssetReader` is that it opens more than raw PCM.
            queue.enqueue([Self.transcode(britishAiff) ?? britishAiff], localeIdentifier: "en-GB")
            expectedLocales.append("en-GB")
        } else {
            print("""
                [import-locale] skipped the en-GB row: neither module has British assets on this Mac, \
                so enqueueing it would start a real model download rather than fail.
                """)
        }
        #expect(queue.items.map(\.localeIdentifier) == expectedLocales)
        try await drain(queue)

        for item in queue.items {
            let transcript = byFile[item.filename]
            print("""
                [import-locale] \(item.filename) asked \(item.localeIdentifier) \
                -> got \(transcript?.localeIdentifier ?? "nil") \
                (\(transcript?.engine ?? "-"), \(transcript?.wordCount ?? 0) words, \
                state \(item.state))
                  \(transcript?.text ?? "")
                """)
            switch item.state {
            case .done:
                #expect(
                    transcript?.localeIdentifier == item.localeIdentifier,
                    "\(item.filename) ran under the wrong locale"
                )
            case .failed(let reason):
                // The only acceptable failure: this language's model is not on disk, said in this
                // language's own words, with nothing written.
                #expect(transcript == nil, "a failed language must not have written a transcript")
                #expect(
                    reason.contains(ImportQueue.localeDisplayName(item.localeIdentifier)
                        .components(separatedBy: " ")[0]),
                    "\(item.filename) failed for a reason unrelated to its language: \(reason)"
                )
            default:
                Issue.record("\(item.filename) ended as \(item.state)")
            }
        }

        // The two that carry the whole point: an English file under the general model and an
        // Indonesian one under the dictation model, in the same run, with the dictation language
        // sitting at en-US throughout.
        #expect(queue.items[0].state == .done)
        #expect(queue.items[1].state == .done)
        #expect(byFile[englishAudio.lastPathComponent]?.engine == TranscriptionModule.general.engineIdentifier)
        #expect(byFile[indonesianAudio.lastPathComponent]?.engine == TranscriptionModule.dictation.engineIdentifier)
        #expect(Self.markerHits(byFile[indonesianAudio.lastPathComponent]?.text ?? "") >= 6)
        // Distinct languages, so distinct text — a queue that leaked one locale onto every row would
        // produce transcripts of the same shape.
        #expect(Set(byFile.values.map(\.text)).count == byFile.count)
    }

    /// What re-running costs, against a first run of the same file.
    @Test("rerun costs one more decode and one more transcription, and adds a transcript")
    func rerunCost() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try Self.synthesise(Self.indonesian, voice: "Damayanti", into: directory)

        let (controller, history) = controller(dictationLocale: "en-US")
        let queue = ImportQueue(environment: controller.importEnvironment())
        var results: [ImportQueue.Result] = []
        queue.onFinish = { result in
            results.append(result)
            return controller.completeImport(result)
        }

        let firstStart = ContinuousClock.now
        let first = try #require(queue.enqueue(audio, localeIdentifier: "en-US"))
        try await drain(queue)
        let firstWall = seconds(ContinuousClock.now - firstStart)

        let rerunStart = ContinuousClock.now
        _ = try #require(queue.rerun(first, localeIdentifier: "id-ID"))
        try await drain(queue)
        let rerunWall = seconds(ContinuousClock.now - rerunStart)

        let entries = history.transcripts
        print("""
            [import-locale] rerun cost on \(String(format: "%.1f", results[0].info.duration))s of audio
              first run (en-US)  \(String(format: "%.2f", firstWall))s wall, \
            \(String(format: "%.2f", results[0].stats.readWallSeconds))s decode, \
            \(String(format: "%.1f", results[0].realtimeFactor))x end to end
              rerun    (id-ID)  \(String(format: "%.2f", rerunWall))s wall, \
            \(String(format: "%.2f", results[1].stats.readWallSeconds))s decode, \
            \(String(format: "%.1f", results[1].realtimeFactor))x end to end
              history entries: \(entries.count)
            """)

        #expect(results.count == 2)
        #expect(entries.count == 2, "a re-run must add a transcript, not replace one")
        #expect(queue.items.count == 2, "the first row must still be on screen to compare against")
        #expect(entries[0].text != entries[1].text)
    }

    /// A live dictation and an import contending for the engine's one analyzer slot.
    ///
    /// One `SpeechEngine`, reached through `engineForTesting`, because the slot is per instance and
    /// two engines would never contend at all.
    @Test("A live dictation wins the engine slot and the import waits for it")
    func liveDictationWinsTheSlot() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try Self.synthesise(Self.indonesian, voice: "Damayanti", into: directory)

        let (controller, history) = controller(dictationLocale: "en-US")
        let engine = controller.engineForTesting
        try await engine.prepare(localeIdentifier: "en-US")
        let format = try #require(await engine.bestAudioFormat())

        // Take the slot exactly as a hotkey press does: `begin` → `feed` → hold.
        let session = try await engine.begin(locale: .primary, onUpdate: { _ in })
        #expect(await engine.isSlotClaimed)

        let queue = ImportQueue(environment: controller.importEnvironment())
        queue.onFinish = { controller.completeImport($0) }
        queue.enqueue(audio, localeIdentifier: "id-ID")

        // Long enough to be past several of the queue's 250 ms retries.
        try await Task.sleep(for: .milliseconds(900))
        #expect(queue.items[0].state.isRunning, "the import gave up instead of waiting")
        #expect(queue.items[0].transcriptID == nil)

        // Release the slot the way a key-up does.
        let frames = AVAudioFrameCount(format.sampleRate * 0.4)
        if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) {
            buffer.frameLength = frames
            session.feed(AnalyzerInput(buffer: buffer))
        }
        _ = try await session.finishAndCommit()

        try await drain(queue)
        #expect(queue.items[0].state == .done, "the import did not recover the slot")
        let transcript = history.transcripts
            .first(where: { $0.id == queue.items[0].transcriptID })
        print("""
            [import-locale] slot contention: dictation held the engine, import retried and finished \
            as \(transcript?.localeIdentifier ?? "nil")
            """)
        #expect(transcript?.localeIdentifier == "id-ID", "the wait must not lose the item's locale")
    }

    /// Reservations are the one piece of global state this feature touches, and RECON §6 records how
    /// they leak: `release` matches on the raw identifier string, and there are only five slots.
    ///
    /// `#expect(after.count <= 5)` used to close this test and **could not fail**. The framework
    /// throws at six and `reserve` catches the throw and evicts, so the count is five or fewer by
    /// construction — including in the state the assertion was written to rule out, where Edict has
    /// permanently leaked all five slots to languages nobody is using. What replaces it is a
    /// subtraction against the inventory as it stood before the import: what the import must have
    /// done is *add* its own language. Subtraction rather than equality because resolving a pass
    /// asset-checks other locales and each check reserves one (RECON §6), so `after` is not `before`
    /// plus one entry.
    ///
    /// The disjunct on that assertion is not slack. Reservations persist across process launches
    /// keyed to the bundle identifier, and `id-ID` is Edict's own default second language, so a
    /// developer's inventory very often holds `id_ID` before this test starts — and a bare
    /// subtraction would then be empty for a reason that has nothing to do with the code.
    ///
    /// What this test deliberately does **not** assert is the other half — that nothing *else* was
    /// left behind. `added.subtracting(["en_US", "id_ID"]).isEmpty` stood here and is not sound from
    /// a gated suite: the five slots are shared per bundle identifier, and the other two gated suites
    /// — `SecondaryLocaleEngineTests` and `EngineReservationRecoveryTests` — reserve languages of
    /// their own, so anything they take between `before` and `after` lands in `added` and fails a
    /// test that had nothing to do with it. The `.serialized` on this suite does not prevent that:
    /// measured in this target with two throwaway `.serialized` suites, the two ran *concurrently
    /// with each other* while each kept its own tests in order. The leak claim is made against the
    /// fake and on every machine, by `ReservationLadderTests.pruneLeavesExactlyThePreparedLanguages`.
    /// The `print` below is what is left here: the inventory is reported, not judged.
    @Test("Importing in a second language reserves it and leaves the reservations sane")
    func reservationsStaySane() async throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = try Self.synthesise(Self.indonesian, voice: "Damayanti", into: directory)

        let (controller, _) = controller(dictationLocale: "en-US")
        let engine = controller.engineForTesting
        let before = await engine.reservedLocaleIdentifiers()

        let queue = ImportQueue(environment: controller.importEnvironment())
        queue.onFinish = { controller.completeImport($0) }
        queue.enqueue(audio, localeIdentifier: "id-ID")
        try await drain(queue)

        let after = await engine.reservedLocaleIdentifiers()
        let added = Set(after).subtracting(before)
        print("""
            [import-locale] reservations before \(before) after \(after) \
            added \(added.sorted())
            """)
        #expect(queue.items[0].state == .done)
        #expect(after.contains { Settings.localeKey($0) == Settings.localeKey("id-ID") })
        #expect(
            added.contains("id_ID") || before.contains("id_ID"),
            "the import ran without a reservation for its own language: added \(added.sorted())"
        )
        // The two languages this run can justify are the dictation primary the controller prepared
        // and the import's own; a third would be a slot Edict took and forgot, persisting into every
        // future launch. That is not asserted here — see the note above the test — because a
        // concurrently running gated suite's reservation is indistinguishable from a leak from
        // inside this process. It is printed above so a human reading a gated run can see it.
    }
}
