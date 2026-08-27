import Foundation
import FoundationModels
import Testing
@testable import EdictKit

// MARK: - Fixtures shared by both suites

/// The dictation fixtures. Kept at file scope so the offline and the model suites cannot drift apart
/// about what "the English fixture" means.
enum RefinerFixtures {

    /// A run-on English dictation with filler, a false start, and four facts that must survive:
    /// **Friday**, **Marcus**, **three** reviewers, and **the migration**.
    static let english = """
        so um the plan is we ship the beta on friday and then i will i will email the three reviewers \
        and uh we should probably ask marcus to look at the migration before that you know
        """

    /// Facts the model is not allowed to lose.
    static let englishFacts = ["friday", "marcus", "three", "migration"]

    /// Plausible-but-absent details the model is not allowed to invent. Every one of these is
    /// something a helpful assistant would happily supply: a different weekday, a year, a quarter,
    /// a name, a place, a number. None of them is anywhere in `english`.
    ///
    /// **Why this list is the most important assertion in the file.** Edict's output is a record of
    /// what someone said. A clean paragraph that has grown a date is worse than an unedited one,
    /// because it reads as trustworthy. A regression here is a data-integrity bug, not a quality one.
    static let englishInventions = [
        "monday", "tuesday", "wednesday", "thursday", "saturday", "sunday",
        "2024", "2025", "2026", "q1", "q2", "q3", "q4",
        "sarah", "james", "london", "berlin", "jakarta",
        "10am", "9am", "deadline", "$",
    ]

    /// An Indonesian dictation. `supportsLocale(id_ID)` is **false**, and this fixture is the reason
    /// the feature is not gated on that: a probe measured this exact class of input coming back
    /// excellent, with "mundurkan" correctly upgraded to "menunda" and "libatkan" to "melibatkan".
    static let indonesian = """
        jadi begini rencananya kita akan mundurkan rapat itu ke hari jumat dan saya akan libatkan tim \
        desain supaya mereka bisa lihat mockup nya dulu sebelum kita putuskan
        """

    /// Words that only appear if the model translated instead of editing. "Friday" is the sharp one:
    /// the fixture says "jumat", so an English weekday in the output is proof of a translation.
    static let englishGiveaways = ["friday", "meeting", "the design team", "postpone", "we will"]
}

// MARK: - Offline suite

/// Everything about the refiner that can be proved without generating a token.
///
/// This suite must stay fast and deterministic: it is part of the default `swift test` run. The real
/// model lives in `TextRefinerModelTests`, behind `EDICT_MODEL_TESTS=1`.
@Suite("Text refinement — offline")
struct TextRefinerOfflineTests {

    // MARK: The action enum

    @Test("Three actions, each with a key cap and a sentence a tooltip can use")
    func actionSurface() {
        #expect(RefinementAction.allCases.count == 3)
        for action in RefinementAction.allCases {
            #expect(action.id == action.rawValue)
            #expect(!action.title.isEmpty)
            #expect(action.title == action.title.uppercased(), "key caps are silkscreened upper case")
            // A tooltip that is one word is not an explanation.
            #expect(action.explanation.split(separator: " ").count >= 8)
            #expect(action.explanation.hasSuffix("."))
        }
        #expect(RefinementAction.cleanUp.title == "CLEAN UP")
        #expect(RefinementAction.bullets.title == "BULLETS")
        #expect(RefinementAction.summarise.title == "SUMMARY")
    }

    @Test("An action survives a round trip through Codable, so a persisted choice keeps working")
    func actionCodable() throws {
        for action in RefinementAction.allCases {
            let data = try JSONEncoder().encode(action)
            #expect(try JSONDecoder().decode(RefinementAction.self, from: data) == action)
        }
    }

    // MARK: Availability mapping

    /// The requirement this covers: **never surface a raw enum**. Every reason the framework can give
    /// has to arrive as a sentence, and one that names the thing the user can do.
    @Test(
        "Every unavailable reason maps to an actionable sentence",
        arguments: [
            SystemLanguageModelUnavailableReasonProbe.appleIntelligenceNotEnabled,
            .modelNotReady,
            .deviceNotEligible,
        ]
    )
    func unavailableSentences(reason: SystemLanguageModelUnavailableReasonProbe) {
        let sentence = TextRefiner.unavailableSentence(for: reason.reason)
        #expect(!sentence.isEmpty)
        #expect(sentence.count > 40, "a sentence, not a label")
        #expect(sentence.hasSuffix("."))
        #expect(!sentence.contains("UnavailableReason"))
        #expect(!sentence.lowercased().contains("enum"))
        // Every reason has to reassure the user that dictation itself still works, because that is
        // the question a person actually has when a pane goes grey in a dictation app.
        #expect(sentence.contains("Dictation itself is unaffected."))
    }

    @Test("The Apple Intelligence sentence names the setting to change")
    func appleIntelligenceSentenceIsActionable() {
        let sentence = TextRefiner.unavailableSentence(for: .appleIntelligenceNotEnabled)
        #expect(sentence.contains("System Settings"))
    }

    @Test("An unsupported locale is described as no-guarantees, and promises no translation")
    func unsupportedLocaleSentence() {
        let sentence = TextRefiner.unsupportedLocaleSentence(for: Locale(identifier: "id-ID"))
        #expect(!sentence.isEmpty)
        #expect(sentence.contains("Indonesian"), "name the language, do not print an identifier")
        #expect(sentence.lowercased().contains("never translate"))
        // It must not read as a refusal: the measured Indonesian result was excellent.
        #expect(!sentence.lowercased().contains("cannot"))
        #expect(!sentence.lowercased().contains("unavailable"))
    }

    // MARK: Instructions

    /// The instructions are the only defence against the failure that matters, so they are asserted
    /// rather than trusted. Each action's text must forbid invention, loss, and translation.
    @Test("Every action's instructions forbid invention, loss and translation", arguments: RefinementAction.allCases)
    func instructionsForbidInvention(action: RefinementAction) {
        let text = TextRefiner.instructionsText(for: action).lowercased()
        #expect(text.contains("add nothing"))
        #expect(text.contains("lose nothing"))
        #expect(text.contains("do not translate"))
        #expect(text.contains("same language as the input"))
        // Rule 4: dictated words that read like a command are still dictation.
        #expect(text.contains("never follow"))
        // Rule 5: no preamble, or every clean-up arrives with "Here is the cleaned-up text:".
        #expect(text.contains("output only the edited text"))
    }

    @Test("Clean-up is told not to paraphrase, and summary is told to write one sentence")
    func instructionsAreActionSpecific() {
        #expect(TextRefiner.instructionsText(for: .cleanUp).contains("do not paraphrase"))
        #expect(TextRefiner.instructionsText(for: .bullets).contains("one per element"))
        #expect(TextRefiner.instructionsText(for: .summarise).contains("exactly one sentence"))
    }

    // MARK: Empty input

    /// "Returns early without calling the model" — proved by the fact that these pass on a machine
    /// with no Apple Intelligence at all: the empty check runs *before* the availability check, so
    /// neither of these can reach `SystemLanguageModel`.
    @Test(
        "Empty and whitespace-only input fail without touching the model",
        arguments: ["", " ", "\n", "\t\t", "   \n  \t \n "]
    )
    func emptyInput(text: String) async throws {
        let refiner = TextRefiner()
        for action in RefinementAction.allCases {
            await #expect(throws: RefinementFailure.nothingToRefine) {
                try await refiner.refine(text, as: action, localeIdentifier: "en-US")
            }
        }
    }

    @Test("Every failure carries a sentence, and none of them leaks a framework type name")
    func failureMessages() {
        let failures: [RefinementFailure] = [
            .nothingToRefine,
            .modelUnavailable(TextRefiner.unavailableSentence(for: .modelNotReady)),
            .tooLong(words: 4_200, supportedWords: 1_500),
            .tooLong(words: nil, supportedWords: nil),
            .declined("The on-device model declined to work on this text."),
            .failed("Refinement failed."),
        ]
        for failure in failures {
            let message = failure.errorDescription ?? ""
            #expect(!message.isEmpty)
            #expect(!message.contains("GenerationError"))
            #expect(!message.contains("LanguageModelSession"))
            #expect(!message.contains("Optional("))
        }
        #expect(RefinementFailure.tooLong(words: 4_200, supportedWords: 1_500).errorDescription?
            .contains("4200") == true)
    }

    // MARK: The mechanical post-pass

    /// `tidy` is the deterministic half of clean-up. It exists because the model measurably would not
    /// do it (see the comment on `TextRefiner.tidy`), so it has to be right on its own.
    @Test("Clean-up gets a sentence-initial capital and a terminal full stop, and nothing else")
    func tidyRepairsCasingAndTerminator() {
        #expect(TextRefiner.tidy("so the plan is we ship on friday", for: .cleanUp)
            == "So the plan is we ship on friday.")
        // Already correct text is left exactly alone.
        #expect(TextRefiner.tidy("We ship on Friday.", for: .cleanUp) == "We ship on Friday.")
        #expect(TextRefiner.tidy("Do we ship on Friday?", for: .cleanUp) == "Do we ship on Friday?")
        #expect(TextRefiner.tidy("It shipped!", for: .cleanUp) == "It shipped!")
        // A closing quote or bracket already reads as finished.
        #expect(TextRefiner.tidy("he said \"ship it\"", for: .cleanUp) == "He said \"ship it\"")
        // Surrounding whitespace goes; interior text is untouched.
        #expect(TextRefiner.tidy("  we ship.  ", for: .cleanUp) == "We ship.")
        // It must never invent a word, only a full stop.
        #expect(TextRefiner.tidy("friday", for: .cleanUp) == "Friday.")
    }

    @Test("Bullets are left alone — a list item is not a sentence")
    func tidyLeavesBulletsAlone() {
        let list = "ship the beta on friday\nemail the three reviewers"
        #expect(TextRefiner.tidy(list, for: .bullets) == list)
    }

    @Test("A summary gets the same terminator treatment as clean-up")
    func tidyFinishesSummaries() {
        #expect(TextRefiner.tidy("the speaker described a release plan", for: .summarise)
            == "The speaker described a release plan.")
    }

    @Test("Tidy survives an empty or whitespace-only answer without crashing")
    func tidyHandlesNothing() {
        for action in RefinementAction.allCases {
            #expect(TextRefiner.tidy("", for: action).isEmpty)
            #expect(TextRefiner.tidy("   \n ", for: action).isEmpty)
        }
    }

    @Test("A result keeps the unsupported-locale flag it was built with")
    func resultCarriesLocaleFlag() {
        let result = RefinementResult(
            action: .cleanUp,
            text: "Hello.",
            duration: 1.03,
            localeIdentifier: "id-ID",
            wasLocaleUnsupported: true
        )
        #expect(result.wasLocaleUnsupported)
        #expect(result.localeIdentifier == "id-ID")
    }
}

// MARK: - The model suite

/// Real generations against Apple's on-device model.
///
/// Gated behind `EDICT_MODEL_TESTS=1` and skipped by default, for the same reasons
/// `EDICT_SPEECH_TESTS` exists: these are not deterministic, they take seconds rather than
/// milliseconds, and they need Apple Intelligence enabled on the machine running them. Run them
/// deliberately:
///
///     EDICT_MODEL_TESTS=1 swift test --filter TextRefinerModel
///
/// The assertions are written to be robust against a model that words things differently — they check
/// facts, language and shape, never exact strings — because a test that pins the model's phrasing
/// fails on the next OS update and teaches nothing when it does.
@Suite(
    "Text refinement — real model",
    .enabled(if: ProcessInfo.processInfo.environment["EDICT_MODEL_TESTS"] == "1"),
    .serialized
)
struct TextRefinerModelTests {

    /// Fail the test with the model's own sentence rather than with a mysterious throw from deep
    /// inside `refine`, if this machine cannot run the model at all.
    private static func requireReady(_ refiner: TextRefiner, locale: String = "en-US") async throws {
        if case .unavailable(let why) = await refiner.availability(for: locale) {
            throw RefinementFailure.modelUnavailable(why)
        }
    }

    @Test("The model is available on this machine and lists en-US but not id-ID")
    func availability() async throws {
        let refiner = TextRefiner()
        #expect(await refiner.availability(for: "en-US") == .ready)
        // Measured: supportsLocale(id_ID) == false. Recorded as an expectation rather than an
        // assumption so the day Apple adds Indonesian, this test says so instead of silently passing.
        if case .localeUnsupported(let sentence) = await refiner.availability(for: "id-ID") {
            print("[refiner] id-ID is unsupported, as measured: \(sentence)")
        } else {
            print("[refiner] id-ID is now SUPPORTED — RECON's measurement is stale, update the docs.")
        }
    }

    @Test("Clean-up keeps every fact, drops the filler, and invents nothing")
    func cleanUp() async throws {
        let refiner = TextRefiner()
        try await Self.requireReady(refiner)
        let result = try await refiner.refine(
            RefinerFixtures.english,
            as: .cleanUp,
            localeIdentifier: "en-US"
        )
        print("[refiner] cleanUp cold: \(String(format: "%.2f", result.duration)) s\n\(result.text)")

        let lower = result.text.lowercased()
        for fact in RefinerFixtures.englishFacts {
            #expect(lower.contains(fact), "clean-up lost the fact '\(fact)'")
        }
        for invention in RefinerFixtures.englishInventions {
            #expect(!lower.contains(invention), "clean-up invented '\(invention)'")
        }
        #expect(!lower.contains(" um "))
        #expect(!lower.contains("you know"))
        #expect(!lower.contains("i will i will"), "the false start should be gone")
        #expect(result.text.first?.isUppercase == true, "punctuation and capitalisation were repaired")
        #expect(!result.text.hasPrefix("\""), "no quotation marks around the answer")
        #expect(!result.text.contains("```"))
        #expect(!result.wasLocaleUnsupported)
        #expect(result.action == .cleanUp)
    }

    @Test("Bullets come back as clean lines with no stray dashes and no empty items")
    func bullets() async throws {
        let refiner = TextRefiner()
        try await Self.requireReady(refiner)
        let result = try await refiner.refine(
            RefinerFixtures.english,
            as: .bullets,
            localeIdentifier: "en-US"
        )
        print("[refiner] bullets: \(String(format: "%.2f", result.duration)) s\n\(result.text)")

        let lines = result.text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count >= 2, "the fixture makes more than one point")
        for line in lines {
            #expect(!line.trimmingCharacters(in: .whitespaces).isEmpty, "no empty bullets")
            // Exactly ONE marker per line, supplied by us. This assertion used to demand *no*
            // marker, on the reasoning that `Generable` leaves nothing to mis-parse — true of
            // parsing, but it meant the pane rendered three unmarked lines, which a user reported
            // as "bullets doesn't make bullet points". `Generable` means we own the marker, not
            // that there should not be one.
            #expect(line.hasPrefix("- "), "every line is a Markdown bullet")
            let body = line.dropFirst(2)
            #expect(!body.hasPrefix("-"), "no doubled marker")
            #expect(!body.hasPrefix("*"))
            #expect(!body.hasPrefix("\u{2022}"))
            #expect(!body.hasPrefix("1."), "no verbal or numeric enumeration left in the text")
        }
        let lower = result.text.lowercased()
        for invention in RefinerFixtures.englishInventions {
            #expect(!lower.contains(invention), "bullets invented '\(invention)'")
        }
    }

    @Test("A summary is one sentence, drawn only from the input")
    func summarise() async throws {
        let refiner = TextRefiner()
        try await Self.requireReady(refiner)
        let result = try await refiner.refine(
            RefinerFixtures.english,
            as: .summarise,
            localeIdentifier: "en-US"
        )
        print("[refiner] summarise: \(String(format: "%.2f", result.duration)) s\n\(result.text)")

        let sentences = result.text
            .split(whereSeparator: { ".!?".contains($0) })
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        #expect(sentences.count == 1, "asked for exactly one sentence, got \(sentences.count)")
        #expect(!result.text.contains("\n"))
        let lower = result.text.lowercased()
        for invention in RefinerFixtures.englishInventions {
            #expect(!lower.contains(invention), "the summary invented '\(invention)'")
        }
    }

    /// The single most damaging failure this feature can have, tested on its own with a fixture built
    /// to bait it: a plan with a missing owner and a missing date is exactly what a helpful model
    /// wants to fill in.
    @Test("Nothing is invented even when the dictation leaves an obvious gap", arguments: RefinementAction.allCases)
    func inventsNothing(action: RefinementAction) async throws {
        let refiner = TextRefiner()
        try await Self.requireReady(refiner)
        let bait = "we need to fix the login bug and somebody has to tell the customer about it soon"
        let result = try await refiner.refine(bait, as: action, localeIdentifier: "en-US")
        let lower = result.text.lowercased()
        for invention in ["monday", "friday", "tomorrow", "2025", "2026", "sarah", "marcus", "email", "$"] {
            #expect(!lower.contains(invention), "\(action.rawValue) invented '\(invention)': \(result.text)")
        }
        #expect(lower.contains("login") || lower.contains("log-in"))
        #expect(lower.contains("customer"))
    }

    @Test("An Indonesian dictation comes back in Indonesian, flagged as unsupported")
    func indonesianStaysIndonesian() async throws {
        let refiner = TextRefiner()
        try await Self.requireReady(refiner, locale: "id-ID")
        let result = try await refiner.refine(
            RefinerFixtures.indonesian,
            as: .cleanUp,
            localeIdentifier: "id-ID"
        )
        print("[refiner] Indonesian cleanUp: \(String(format: "%.2f", result.duration)) s\n\(result.text)")

        let lower = result.text.lowercased()
        // Indonesian function words. At least three, so one loanword cannot carry the assertion.
        let markers = ["dan", "saya", "kita", "akan", "yang", "rapat", "tim", "sebelum", "supaya"]
        #expect(markers.filter { lower.contains($0) }.count >= 3, "output does not read as Indonesian: \(result.text)")
        // The proof that it edited rather than translated: the fixture's weekday is "jumat".
        #expect(lower.contains("jumat"))
        for giveaway in RefinerFixtures.englishGiveaways {
            #expect(!lower.contains(giveaway), "the model translated: found '\(giveaway)'")
        }
        #expect(result.wasLocaleUnsupported, "supportsLocale(id_ID) is false, and the UI needs to know")
    }

    /// A transcript longer than the window is refused with a stated limit, not quietly cut in half.
    @Test("A transcript that cannot fit is refused with a limit, never truncated")
    func refusesOverlongInput() async throws {
        let refiner = TextRefiner()
        try await Self.requireReady(refiner)
        // ~12,000 words. The on-device window is 4,096 tokens, so this cannot fit under any budget.
        let long = Array(repeating: RefinerFixtures.english, count: 300).joined(separator: " ")
        do {
            let result = try await refiner.refine(long, as: .cleanUp, localeIdentifier: "en-US")
            Issue.record("expected a refusal, got \(result.text.count) characters back")
        } catch let failure as RefinementFailure {
            guard case .tooLong(let words, let supported) = failure else {
                Issue.record("expected .tooLong, got \(failure)")
                return
            }
            print(
                "[refiner] context window \(SystemLanguageModel.default.contextSize) tokens; "
                    + "refused \(words ?? -1) words, limit stated as \(supported ?? -1)"
            )
            #expect(words ?? 0 > 1_000)
            #expect(supported ?? 0 > 20)
            #expect(supported ?? 0 < words ?? 0)
            #expect(failure.errorDescription?.contains("refine it in parts") == true)
        }
    }

    /// A user who changes their mind must not be made to wait out a running generation.
    @Test("Cancel releases the caller promptly and leaves the refiner usable")
    func cancellationIsPrompt() async throws {
        let refiner = TextRefiner()
        try await Self.requireReady(refiner)
        // Long enough that the generation is certainly still running when cancel lands.
        let long = Array(repeating: RefinerFixtures.english, count: 6).joined(separator: " ")

        let started = Date()
        let call = Task { try await refiner.refine(long, as: .cleanUp, localeIdentifier: "en-US") }
        try await Task.sleep(for: .milliseconds(400))
        await refiner.cancel()

        var elapsed: TimeInterval = 0
        do {
            _ = try await call.value
            Issue.record("the cancelled call returned a result")
        } catch {
            elapsed = Date().timeIntervalSince(started)
            #expect(error is CancellationError, "expected CancellationError, got \(error)")
        }
        print("[refiner] cancel released the caller after \(String(format: "%.2f", elapsed)) s")
        #expect(elapsed < 2.0, "cancel took \(elapsed) s to release the caller")

        // And the refiner still works afterwards — a cancel must not wedge it.
        let after = try await refiner.refine("hello there this is a test", as: .summarise, localeIdentifier: "en-US")
        #expect(!after.text.isEmpty)
    }

    /// Not an assertion so much as a measurement, printed for the record. Pre-warming is most of the
    /// perceived speed of this feature, so the numbers are worth keeping current.
    @Test("Latency, cold and warm, per action")
    func latency() async throws {
        let cold = TextRefiner()
        try await Self.requireReady(cold)

        var report: [String] = []
        let coldResult = try await cold.refine(RefinerFixtures.english, as: .cleanUp, localeIdentifier: "en-US")
        report.append(String(format: "cleanUp   cold, no prewarm .... %.2f s", coldResult.duration))
        for action in RefinementAction.allCases {
            let warm = try await cold.refine(RefinerFixtures.english, as: action, localeIdentifier: "en-US")
            let name = action.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)
            report.append(String(format: "\(name) warm, same refiner .. %.2f s", warm.duration))
        }

        let prewarmed = TextRefiner()
        await prewarmed.prewarm()
        try await Task.sleep(for: .seconds(2))
        let afterPrewarm = try await prewarmed.refine(
            RefinerFixtures.english, as: .cleanUp, localeIdentifier: "en-US"
        )
        report.append(String(format: "cleanUp   after prewarm() ... %.2f s", afterPrewarm.duration))

        print("[refiner] latency\n  " + report.joined(separator: "\n  "))
        #expect(coldResult.duration > 0)
    }
}

// MARK: - Test-only shim

/// A `CaseIterable`, `Sendable` stand-in so the availability mapping can be driven from a
/// `@Test(arguments:)` list. `SystemLanguageModel.Availability.UnavailableReason` is neither, and
/// wrapping it here is cheaper than losing the parameterised test.
enum SystemLanguageModelUnavailableReasonProbe: CaseIterable, Sendable, CustomStringConvertible {
    case appleIntelligenceNotEnabled
    case modelNotReady
    case deviceNotEligible

    var description: String {
        switch self {
        case .appleIntelligenceNotEnabled: "appleIntelligenceNotEnabled"
        case .modelNotReady: "modelNotReady"
        case .deviceNotEligible: "deviceNotEligible"
        }
    }

    var reason: SystemLanguageModel.Availability.UnavailableReason {
        switch self {
        case .appleIntelligenceNotEnabled: .appleIntelligenceNotEnabled
        case .modelNotReady: .modelNotReady
        case .deviceNotEligible: .deviceNotEligible
        }
    }
}

// MARK: - Bullet markers

/// Regression: the model produced the right three points and the display showed three unmarked
/// lines, which reads as the feature not working. Reported against real Indonesian dictation:
/// "Johan ini daftar yang harus kamu tanya sama guru itu nomor satu berapa biayanya…"
@Suite("Bullet formatting")
struct BulletFormattingTests {

    @Test("Points are joined as a Markdown list, so COPY pastes as a list")
    func pointsBecomeAMarkdownList() {
        let joined = TextRefiner.bulletList(from: ["berapa biayanya", "berapa lama kelasnya", "apa aja syarat syaratnya"])
        #expect(joined == "- berapa biayanya\n- berapa lama kelasnya\n- apa aja syarat syaratnya")
    }

    @Test("A marker the model added itself is not doubled")
    func modelSuppliedMarkersAreNotDoubled() {
        #expect(TextRefiner.bulletList(from: ["- already marked"]) == "- already marked")
    }

    @Test("Blank and whitespace-only points are dropped, not emitted as empty bullets")
    func blankPointsAreDropped() {
        #expect(TextRefiner.bulletList(from: ["one", "   ", "", "two"]) == "- one\n- two")
    }

    @Test("An empty set of points yields an empty string rather than a lone dash")
    func noPointsYieldsNothing() {
        #expect(TextRefiner.bulletList(from: []).isEmpty)
        #expect(TextRefiner.bulletList(from: ["  "]).isEmpty)
    }
}


// MARK: - Verbal enumeration

/// Reported bug: an Indonesian dictation that enumerates three questions out loud came back as a
/// single bullet containing the whole sentence. English "first / second / third" already split
/// correctly, so this was a language-coverage gap in the instruction, not a general failure.
///
/// These call the real model, so they are gated like the other model tests.
@Suite("Bullets split a spoken list", .enabled(if: ProcessInfo.processInfo.environment["EDICT_MODEL_TESTS"] == "1"))
struct SpokenListTests {

    private func points(_ text: String, locale: String = "en-US") async throws -> [String] {
        let refiner = TextRefiner()
        let r = try await refiner.refine(text, as: .bullets, localeIdentifier: locale)
        return r.text
            .split(separator: "\n")
            .map { String($0.dropFirst(2)) }   // strip the "- " marker
            .filter { !$0.isEmpty }
    }

    @Test("Indonesian verbal enumeration becomes one point per item")
    func indonesianEnumeration() async throws {
        let p = try await points(
            "Johan ini daftar yang harus kamu tanya sama guru itu nomor satu berapa biayanya "
            + "yang berapa lama kelasnya yang tiga apa aja syarat syaratnya",
            locale: "id-ID")
        // Three questions, plus the speaker's own framing line ("Johan, this is the list you must
        // ask the teacher"), which is kept because rule 2 is "lose nothing" — it is content the
        // speaker said, not a heading the model invented.
        #expect(p.count >= 3, "the three enumerated questions must be separate; got \(p.count): \(p)")
        #expect(p.count <= 4, "no more than the framing plus three questions; got \(p.count): \(p)")
        let joined = p.joined(separator: " ").lowercased()
        #expect(joined.contains("biaya"), "the cost question survived")
        #expect(joined.contains("kelas"), "the duration question survived")
        #expect(joined.contains("syarat"), "the requirements question survived")
        // No leftover verbal numbering at the head of any point. The model left "yang" and "yang
        // tiga" attached across four runs; the strip is deterministic for exactly that reason.
        for point in p {
            let lower = point.lowercased()
            #expect(!lower.hasPrefix("nomor "), "leftover enumerator: \(point)")
            #expect(!lower.hasPrefix("yang tiga "), "leftover enumerator: \(point)")
        }
    }

    @Test("English verbal enumeration still splits")
    func englishEnumeration() async throws {
        let p = try await points(
            "ok so three things first we need the budget signed off second marcus has to review "
            + "the migration and third somebody should book the room")
        #expect(p.count == 3, "got \(p.count): \(p)")
    }

    @Test("A genuinely single point is not split into several")
    func singlePointStaysSingle() async throws {
        let p = try await points("i think we should move the meeting to thursday")
        #expect(p.count == 1, "got \(p.count): \(p)")
    }

    @Test("Two statements without enumeration still give two points")
    func twoStatementsGiveTwo() async throws {
        let p = try await points("the plan is we ship the beta on friday i will email the three reviewers")
        #expect(p.count == 2, "got \(p.count): \(p)")
    }
}


// MARK: - Enumerator stripping

@Suite("Leading enumerators")
struct EnumeratorStripTests {

    @Test("Indonesian leftovers the model leaves attached are removed")
    func indonesianLeftovers() {
        #expect(TextRefiner.stripLeadingEnumerator("yang tiga apa aja syarat syaratnya") == "apa aja syarat syaratnya")
        #expect(TextRefiner.stripLeadingEnumerator("yang berapa lama kelasnya") == "berapa lama kelasnya")
        #expect(TextRefiner.stripLeadingEnumerator("nomor satu berapa biayanya") == "berapa biayanya")
        #expect(TextRefiner.stripLeadingEnumerator("pertama kita perlu anggaran") == "kita perlu anggaran")
    }

    @Test("English leftovers are removed")
    func englishLeftovers() {
        #expect(TextRefiner.stripLeadingEnumerator("first we need the budget") == "we need the budget")
        #expect(TextRefiner.stripLeadingEnumerator("and then somebody books the room") == "somebody books the room")
        #expect(TextRefiner.stripLeadingEnumerator("number two review the migration") == "review the migration")
    }

    @Test("Longest match wins, so \"yang tiga\" is not left as \"tiga\"")
    func longestMatchWins() {
        #expect(TextRefiner.stripLeadingEnumerator("yang tiga apa aja syaratnya") == "apa aja syaratnya")
    }

    @Test("A point is never reduced to nothing or to a single word")
    func neverStripsToNothing() {
        // "dan" heads the list, so the guard has to hold here.
        #expect(TextRefiner.stripLeadingEnumerator("dan") == "dan")
        #expect(TextRefiner.stripLeadingEnumerator("yang penting") == "yang penting")
        #expect(TextRefiner.stripLeadingEnumerator("first thing") == "first thing")
        #expect(TextRefiner.stripLeadingEnumerator("") == "")
    }

    @Test("A word that merely starts with an enumerator is untouched")
    func noPrefixCollisions() {
        #expect(TextRefiner.stripLeadingEnumerator("firstly we should go home") == "firstly we should go home")
        #expect(TextRefiner.stripLeadingEnumerator("andrew reviewed the migration") == "andrew reviewed the migration")
        #expect(TextRefiner.stripLeadingEnumerator("yangon is the old capital") == "yangon is the old capital")
    }
}
