import Foundation
import Testing
@testable import EdictKit

/// Every shape `RefinementFailure` comes in. File-scope and `nonisolated` because `@Test(arguments:)`
/// reads it from outside the main actor the suite is pinned to.
let everyRefinementFailure: [RefinementFailure] = [
    .nothingToRefine,
    .modelUnavailable(TextRefiner.unavailableSentence(for: .appleIntelligenceNotEnabled)),
    .tooLong(words: 4_000, supportedWords: 1_200),
    .tooLong(words: nil, supportedWords: nil),
    .declined("The on-device model declined to work on this text. Your transcript is unchanged."),
    .failed("Refinement failed for a reason nobody has seen yet. Your transcript is unchanged."),
]

// MARK: - Offline

/// The refinement *surface*: the strings it prints, the state it keeps, and the two invariants that
/// matter more than any of it — the stored transcript is never rewritten, and nothing here is ever a
/// dead control.
///
/// No `SystemLanguageModel` is touched anywhere in this suite. Everything the model itself does is
/// covered by `TextRefinerTests` / `TextRefinerModelTests`; what is proved here is that the pane
/// cannot lie about it.
@Suite("Refinement surface")
@MainActor
struct RefinementSurfaceTests {

    // MARK: The invariant

    @Test("Refining never touches the stored transcript")
    func transcriptSurvivesRefinement() {
        let store = RefinementStore()
        let transcript = RefinementFixtures.english
        let before = transcript.text

        store.seedForRender(transcript.id, result: RefinementResult(
            action: .cleanUp,
            text: RefinementFixtures.englishCleanUp,
            duration: 1.02,
            localeIdentifier: "en-US",
            wasLocaleUnsupported: false
        ))

        #expect(transcript.text == before)
        #expect(store.result(for: transcript.id)?.text == RefinementFixtures.englishCleanUp)
        // The two must genuinely differ, or this test would pass on a store that did nothing.
        #expect(store.result(for: transcript.id)?.text != before)
    }

    @Test("A history store holding a refined transcript still holds the original words")
    func historyIsNotRewritten() throws {
        let dir = try makeTempDir()
        let history = HistoryStore(fileURL: dir.appendingPathComponent("history.json"))
        history.append(RefinementFixtures.autoRefined)
        try history.save()

        let reloaded = HistoryStore(fileURL: dir.appendingPathComponent("history.json"))
        try reloaded.load()
        let row = try #require(reloaded.transcripts.first)

        #expect(row.text == RefinementFixtures.englishDictation)
        #expect(row.rawText == RefinementFixtures.englishDictation)
        #expect(row.refinement?.text == RefinementFixtures.englishCleanUp)
    }

    @Test("A refinement record round-trips, and history written before it existed still loads")
    func recordCoding() throws {
        let record = RefinementRecord(
            action: .bullets,
            text: "One thing.\nAnother thing.",
            duration: 1.03,
            localeIdentifier: "id-ID",
            localeUnsupported: true
        )
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(RefinementRecord.self, from: data) == record)

        // The key the older schema does not have. RECON §39's lesson is about writes, but a decoder
        // that failed here would lose the whole entry, which is the same damage by another route.
        let legacy = Data(#"[{"id":"\#(UUID().uuidString)","rawText":"hello","text":"hello"}]"#.utf8)
        let decoded = try JSONDecoder().decode([Transcript].self, from: legacy)
        #expect(decoded.count == 1)
        #expect(decoded[0].refinement == nil)
    }

    @Test("A record with no text, or empty text, does not claim it was inserted")
    func didInsertRefinedText() {
        #expect(RefinementRecord(action: .cleanUp).didInsertRefinedText == false)
        #expect(RefinementRecord(action: .cleanUp, text: "").didInsertRefinedText == false)
        #expect(RefinementRecord(action: .cleanUp, text: "Hello.").didInsertRefinedText)
    }

    @Test("The transcript well stops calling itself Inserted when something else was inserted")
    func transcriptLabelling() {
        // The label is derived in `TranscriptDetail`, so this asserts the fact it is derived from:
        // a refined dictation is one whose inserted text is not its transcript.
        #expect(RefinementFixtures.autoRefined.refinement?.didInsertRefinedText == true)
        #expect(RefinementFixtures.autoRefined.refinement?.text != RefinementFixtures.autoRefined.text)
        // A declined refinement did *not* replace what was inserted, so the well keeps its name.
        #expect(RefinementFixtures.autoRefineDeclined.refinement?.didInsertRefinedText == false)
        #expect(RefinementFixtures.autoRefineDeclined.refinement?.failure?.isEmpty == false)
    }

    // MARK: Nothing is a dead control

    @Test("Every failure prints a short word on the key and a whole sentence in the well",
          arguments: everyRefinementFailure)
    func failuresAreLegible(failure: RefinementFailure) {
        let cap = RefinementStore.cap(for: failure)
        #expect(!cap.isEmpty)
        // A key cap is a key cap. Anything longer than this is a paragraph on a button.
        #expect(cap.count <= 10, "cap too long for a key: \(cap)")

        let sentence = RefinementStore.sentence(for: failure)
        #expect(sentence.count > 20, "not a sentence: \(sentence)")
        #expect(sentence.last == "." || sentence.last == "?")
        // No framework noise on screen, the same rule `TextRefinerTests` holds the engine to.
        #expect(!sentence.contains("GenerationError"))
        #expect(!sentence.contains("LanguageModelSession"))
    }

    @Test("An error that is not a RefinementFailure still produces a cap and a sentence")
    func unknownErrorIsStillLegible() {
        struct Odd: Error {}
        #expect(RefinementStore.cap(for: Odd()) == "Failed")
        #expect(RefinementStore.sentence(for: Odd()).contains("unchanged"))
    }

    // MARK: Captions

    @Test("Each action gets its own past-tense heading, and none of them is the key's legend")
    func resultLabels() {
        var seen = Set<String>()
        for action in RefinementAction.allCases {
            let label = RefinementBlock.resultLabel(action)
            #expect(!label.isEmpty)
            #expect(label != action.title, "the heading over the well repeats the key cap: \(label)")
            #expect(seen.insert(label).inserted, "two actions share a heading: \(label)")
        }
    }

    @Test("The result caption names the language it ran in and what it cost")
    func resultCaption() {
        let caption = RefinementBlock.caption(for: RefinementResult(
            action: .cleanUp,
            text: RefinementFixtures.indonesianCleanUp,
            duration: 1.21,
            localeIdentifier: "id-ID",
            wasLocaleUnsupported: true
        ))
        #expect(caption.contains("Indonesian"))
        #expect(caption.contains("1.2 s"))
    }

    @Test("Durations are printed to one decimal, and a negative one cannot appear")
    func seconds() {
        #expect(RefinementStore.seconds(1.02) == "1.0 s")
        #expect(RefinementStore.seconds(2.89) == "2.9 s")
        #expect(RefinementStore.seconds(-1) == "0.0 s")
    }

    @Test("The unsupported-language sentence names it, promises nothing, and rules out translation")
    func unsupportedSentence() {
        let sentence = RefinementBlock.unsupportedSentence(for: "id-ID")
        #expect(sentence.contains("Indonesian"))
        #expect(sentence.lowercased().contains("no guarantees"))
        #expect(sentence.lowercased().contains("never translated"))
        // It must not read as a refusal — the measured Indonesian result was excellent.
        #expect(!sentence.lowercased().contains("cannot"))
        #expect(!sentence.lowercased().contains("unavailable"))
    }

    @Test("A result carrying the unsupported flag is what puts the sentence on screen")
    func unsupportedFlagDrivesTheNotice() {
        let store = RefinementStore()
        store.seedForRender(RefinementFixtures.indonesian.id, result: RefinementResult(
            action: .cleanUp,
            text: RefinementFixtures.indonesianCleanUp,
            duration: 1.21,
            localeIdentifier: "id-ID",
            wasLocaleUnsupported: true
        ))
        #expect(store.result(for: RefinementFixtures.indonesian.id)?.wasLocaleUnsupported == true)
    }

    // MARK: Store bookkeeping

    @Test("Availability is cached per language, because the answer differs per language")
    func availabilityIsPerLocale() {
        let store = RefinementStore()
        #expect(store.availability(for: "en-US") == nil)
        store.seedForRender("en-US", availability: .ready)
        store.seedForRender("id-ID", availability: .localeUnsupported("no guarantees"))
        #expect(store.availability(for: "en-US") == .ready)
        #expect(store.availability(for: "id-ID") == .localeUnsupported("no guarantees"))
        // Still unasked, and "unasked" must not read as "unavailable".
        #expect(store.availability(for: "ja-JP") == nil)
    }

    @Test("Deleting a transcript forgets its refinement")
    func forgetting() {
        let store = RefinementStore()
        let id = RefinementFixtures.english.id
        store.seedForRender(id, result: RefinementResult(
            action: .summarise,
            text: "A meeting was moved.",
            duration: 1.05,
            localeIdentifier: "en-US",
            wasLocaleUnsupported: false
        ))
        store.seedForRender(id, failure: "Something went wrong.")
        store.forget(id)
        #expect(store.result(for: id) == nil)
        #expect(store.failure(for: id) == nil)
    }

    @Test("Nothing is running before anything is asked for")
    func nothingRunning() {
        let store = RefinementStore()
        #expect(store.running(for: RefinementFixtures.english.id) == nil)
    }

    // MARK: The setting

    @Test("Refine-before-insert is off by default, persists, and comes back off on a reset")
    func settingDefaultsOff() {
        let defaults = EphemeralDefaults()
        let settings = Settings(defaults: defaults)
        #expect(settings.refineBeforeInsert == false)
        #expect(Settings.Default.refineBeforeInsert == false)
        settings.refineBeforeInsert = true
        // A second `Settings` over the same store is how a relaunch reads it.
        #expect(Settings(defaults: defaults).refineBeforeInsert)
        settings.resetToDefaults()
        #expect(Settings(defaults: defaults).refineBeforeInsert == false)
    }

    // MARK: Refine before inserting

    @Test("With the switch off, nothing is refined and nothing is recorded")
    func refineBeforeInsertOff() async {
        let settings = Settings(defaults: EphemeralDefaults())
        #expect(settings.refineBeforeInsert == false)
        let controller = DictationController(
            settings: settings,
            dictionary: DictionaryStore(fileURL: URL(fileURLWithPath: "/dev/null")),
            history: HistoryStore(fileURL: URL(fileURLWithPath: "/dev/null")),
            permissions: Permissions()
        )
        let record = await controller.refineBeforeInserting(
            RefinementFixtures.englishDictation,
            localeIdentifier: "en-US"
        )
        #expect(record == nil, "the model was consulted for a user who did not ask")
    }

    @Test("An empty transcript is never handed to the model, even with the switch on")
    func refineBeforeInsertSkipsEmpty() async {
        let settings = Settings(defaults: EphemeralDefaults())
        settings.refineBeforeInsert = true
        let controller = DictationController(
            settings: settings,
            dictionary: DictionaryStore(fileURL: URL(fileURLWithPath: "/dev/null")),
            history: HistoryStore(fileURL: URL(fileURLWithPath: "/dev/null")),
            permissions: Permissions()
        )
        #expect(await controller.refineBeforeInserting("   \n ", localeIdentifier: "en-US") == nil)
    }

    // MARK: The phase

    @Test("Refining blocks a new utterance, holds no microphone, and is never mistaken for idle")
    func refiningPhase() {
        #expect(DictationPhase.refining.isActive)
        #expect(DictationPhase.refining.isCapturing == false)
        #expect(DictationPhase.refining.errorMessage == nil)
        #expect(DictationPhase.refining != DictationPhase.injecting)
    }

    @Test("The HUD says Refining rather than Inserting, in words and on the lamp")
    func refiningIsAnnounced() {
        let model = RefinementFixtures.model()
        // The status line reports the model's own state ahead of the phase, so this has to be a
        // machine whose speech model is ready before the phase is the thing being described.
        model.apply(modelState: .ready)
        model.apply(hotkeyLive: true)
        model.apply(phase: .refining)
        // A missing permission outranks any phase in `statusLine`, correctly, and whether the test
        // process has Accessibility is not this test's business — so the phase sentence is only
        // asserted on a machine where the phase is what the line is about.
        if model.permissions.allCriticalGranted {
            #expect(model.statusLine.lowercased().contains("clean"))
        }
        #expect(model.lampMode == .armed)

        // `statusCondition` gates on permissions and a live hotkey ahead of the phase — correctly,
        // since a missing permission outranks any phase — and a test process has neither. So the
        // phase-to-condition mapping is asserted on the condition itself: it has to be a case of its
        // own, distinguishable from the two phases either side of it, or a 1–3 s wait would be
        // reported to the user as a 10 ms one.
        #expect(StatusReadout.Condition.refining != .injecting)
        #expect(StatusReadout.Condition.refining != .transcribing)
    }

    @Test("The refinement clock is separate from the speech clock and resets on idle")
    func refineElapsedIsItsOwnClock() async {
        let model = RefinementFixtures.model()
        #expect(model.refineElapsed == 0)
        model.apply(phase: .refining)
        // The ticker publishes at 10 Hz; two periods is enough to see it move without making this
        // test a timing gamble.
        try? await Task.sleep(for: .milliseconds(260))
        #expect(model.refineElapsed > 0, "the counter never moved, so the HUD would look frozen")
        #expect(model.elapsed == 0, "refinement seconds leaked into the speech counter")
        model.apply(phase: .idle)
        #expect(model.refineElapsed == 0)
    }

    // MARK: Fixtures are honest

    @Test("The render fixtures cover a result, a refusal, an unavailable model and a stored record")
    func fixtureCoverage() {
        let ids = RefinementFixtures.renderSheets().map(\.id)
        #expect(ids.contains("refine-english-narrow"))
        #expect(ids.contains("refine-english-wide"))
        #expect(ids.contains("refine-indonesian"))
        #expect(ids.contains("refine-declined"))
        #expect(ids.contains("refine-unavailable"))
        #expect(ids.contains("refine-inserted"))
        #expect(Set(ids).count == ids.count)
    }

    @Test("The Indonesian fixture is Indonesian, not a translation of the English one")
    func indonesianFixtureIsNotTranslated() {
        // The measured result on an officially unsupported locale: sentence case and proper nouns
        // repaired, punctuation added, and not a word of it in English.
        #expect(RefinementFixtures.indonesianCleanUp.contains("Kamis"))
        #expect(RefinementFixtures.indonesianCleanUp.contains("Pak Mark"))
        #expect(RefinementFixtures.indonesianCleanUp.hasSuffix("."))
        for english in ["meeting", "Thursday", "Wednesday", "budget"] {
            #expect(!RefinementFixtures.indonesianCleanUp.contains(english))
        }
        // The filler the clean-up removed, so the fixture cannot silently become a copy of its input.
        #expect(RefinementFixtures.indonesianDictation.contains(" eh "))
        #expect(!RefinementFixtures.indonesianCleanUp.contains(" eh "))
    }

    // MARK: Helpers

    private func makeTempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-refine-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Against the real model

/// The two things about the *surface* that only the real model can settle: that a refinement made
/// from the history pane leaves the stored transcript byte-identical, and that an Indonesian
/// transcript comes back in Indonesian rather than translated.
///
/// Gated the same way `TextRefinerModelTests` is — these cost seconds and need Apple Intelligence
/// enabled on the machine running them:
///
///     EDICT_MODEL_TESTS=1 swift test --filter RefinementSurfaceModel
@Suite(
    "Refinement surface — against the real model",
    .enabled(if: ProcessInfo.processInfo.environment["EDICT_MODEL_TESTS"] == "1"),
    .serialized
)
@MainActor
struct RefinementSurfaceModelTests {

    @Test("A refinement from the pane leaves the stored transcript byte-identical")
    func storedTranscriptUntouched() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-refine-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let history = HistoryStore(fileURL: dir.appendingPathComponent("history.json"))
        history.append(RefinementFixtures.english)
        try history.save()

        let store = RefinementStore()
        await store.refresh(for: "en-US")
        let report = await store.refine(RefinementFixtures.english, as: .cleanUp)

        let result = try #require(store.result(for: RefinementFixtures.english.id))
        print("[refine] clean-up \(String(format: "%.2f", result.duration)) s -> \(result.text)")
        #expect(!result.text.isEmpty)
        #expect(report?.isFault == false)

        let reloaded = HistoryStore(fileURL: dir.appendingPathComponent("history.json"))
        try reloaded.load()
        #expect(reloaded.transcripts.first?.text == RefinementFixtures.englishDictation)
        #expect(reloaded.transcripts.first?.rawText == RefinementFixtures.englishDictation)
        #expect(reloaded.transcripts.first?.refinement == nil)
    }

    @Test("All three actions run on one transcript, and each is captioned with its own language")
    func allThreeActions() async throws {
        let store = RefinementStore()
        await store.refresh(for: "en-US")
        for action in RefinementAction.allCases {
            let report = await store.refine(RefinementFixtures.english, as: action)
            let result = try #require(store.result(for: RefinementFixtures.english.id))
            print("""
                [refine] \(action.rawValue) \(String(format: "%.2f", result.duration)) s \
                | cap "\(report?.text ?? "-")" | caption "\(RefinementBlock.caption(for: result))"
                \(result.text)
                """)
            #expect(!result.text.isEmpty)
            #expect(result.action == action)
            #expect(RefinementBlock.caption(for: result).contains("English"))
        }
    }

    @Test("Refine-before-insert produces the text that goes to the cursor, and records the cost")
    func refineBeforeInsertProducesTheInsertedText() async throws {
        let settings = Settings(defaults: EphemeralDefaults())
        settings.refineBeforeInsert = true
        let controller = DictationController(
            settings: settings,
            dictionary: DictionaryStore(fileURL: URL(fileURLWithPath: "/dev/null")),
            history: HistoryStore(fileURL: URL(fileURLWithPath: "/dev/null")),
            permissions: Permissions()
        )
        let record = try #require(
            await controller.refineBeforeInserting(
                RefinementFixtures.englishDictation,
                localeIdentifier: "en-US"
            )
        )
        print("""
            [refine-before-insert] \(String(format: "%.2f", record.duration)) s \
            -> \(record.text ?? "(nothing: \(record.failure ?? "-"))")
            """)
        // Either it refined, or it said why — never both nil, which would be the dictation vanishing
        // into a silent failure.
        #expect(record.text != nil || record.failure != nil)
        if let text = record.text {
            #expect(text != RefinementFixtures.englishDictation, "nothing was actually cleaned up")
            #expect(record.action == .cleanUp)
            #expect(record.duration > 0)
        }
    }

    @Test("An Indonesian transcript comes back in Indonesian, flagged as carrying no guarantees")
    func indonesianStaysIndonesian() async throws {
        let store = RefinementStore()
        await store.refresh(for: "id-ID")
        // Deliberately not skipped when Apple reports the locale unsupported: that is the case being
        // tested, and it measured excellent.
        _ = await store.refine(RefinementFixtures.indonesian, as: .cleanUp)

        let result = try #require(store.result(for: RefinementFixtures.indonesian.id))
        print("[refine] id-ID clean-up \(String(format: "%.2f", result.duration)) s -> \(result.text)")
        #expect(result.wasLocaleUnsupported, "id-ID is expected to be unsupported and still work")
        #expect(RefinementBlock.caption(for: result).contains("Indonesian"))
        // Indonesian function words that a translation into English could not keep.
        let indonesian = ["yang", "untuk", "tidak", "hari", "dan", "saya", "kita", "ke", "rapat"]
        #expect(
            indonesian.contains { result.text.lowercased().contains($0) },
            "the output does not look like Indonesian: \(result.text)"
        )
        for english in ["meeting", "Thursday", "Wednesday", "budget"] {
            #expect(!result.text.contains(english), "translated into English: \(result.text)")
        }
    }
}
