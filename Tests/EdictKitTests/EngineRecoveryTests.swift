import AVFoundation
import CoreMedia
import Foundation
import Speech
import Testing

@testable import EdictKit

/// What happens when the engine layer goes wrong: a failed utterance, a download that belongs to a
/// different language, and the five reservation slots.
///
/// Every test here pins a loss that was **silent**. That is what they have in common and why they are
/// worth their length: a throw from `finalizeAndFinishThroughEndOfInput()` discarded a whole
/// dictation with the words still on the HUD, an import's finished download reported the *secondary
/// dictation* language as installed, and touching the language picker after an import released the
/// reservation behind a model the app was still using. None of the three produced an error message,
/// a log line the user would see, or a failing test.
@Suite("Engine recovery")
@MainActor
struct EngineRecoveryTests {

    // MARK: - Fixtures

    /// A session that never touches the framework, so the failure path can be driven on demand.
    ///
    /// `finalizeAndFinishThroughEndOfInput()` cannot be made to throw against a real analyzer —
    /// RECON never observed it — so a double is the only way to reach `failUtterance` at all.
    /// It records the ORDER of what the controller does to it, because that ordering is the fix:
    /// reading the sink after `abort()` is not wrong here by luck, it is wrong by contract
    /// (`finishAndCommit` sets `terminated` first, so the later `abort()` returns at its
    /// already-done guard and drains nothing).
    private final class FakeSession: TranscriptionSession, @unchecked Sendable {
        private let lock = NSLock()
        private let text: String
        private var events: [String] = []

        init(finalText: String) {
            self.text = finalText
        }

        var log: [String] { lock.withLock { events } }

        var snapshot: TranscriptionUpdate {
            lock.withLock { events.append("snapshot") }
            return TranscriptionUpdate(finalText: text, volatileText: "and this bit is volatile", isFinal: false)
        }

        func feed(_ input: AnalyzerInput) {}

        func finishAndCommit() async throws -> TranscriptionOutcome {
            throw SpeechEngineError.notPrepared
        }

        func abort() async {
            lock.withLock { events.append("abort") }
        }
    }

    /// A controller with a history store pointed at a real temporary file, because the assertion is
    /// that the words *reach history* — `/dev/null` would make an empty store indistinguishable from
    /// a working one on the read side.
    private func controller() -> (DictationController, HistoryStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-recovery-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let history = HistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let settings = Settings(defaults: EphemeralDefaults())
        let controller = DictationController(
            settings: settings,
            dictionary: DictionaryStore(fileURL: directory.appendingPathComponent("dictionary.json")),
            history: history,
            permissions: Permissions()
        )
        return (controller, history, directory)
    }

    private func rule(_ heard: String, _ write: String) -> CorrectionRule {
        CorrectionRule(entryID: UUID(), heard: heard, write: write)
    }

    // MARK: - A failed utterance keeps its words

    /// The whole of finding #3, stated as the loss: three minutes of speech, a throw at the very end,
    /// and every word gone. The words were on the HUD the entire time — `AppModel.apply(phase:)`
    /// clears only the active-locale fields on `.error` — so the app had shown the user text it then
    /// destroyed without saying so.
    @Test("A throw at the end of an utterance keeps the committed words in history")
    func failedUtteranceKeepsItsWords() async throws {
        let (controller, history, directory) = self.controller()
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = FakeSession(finalText: "This is the part the engine had already committed.")
        let message = await controller.failUtterance(
            session: session,
            error: SpeechEngineError.notPrepared,
            target: InjectionTarget(bundleID: "com.mitchellh.ghostty", appName: "Ghostty"),
            corrector: Corrector(rules: []),
            localeIdentifier: "en-US",
            dropped: 0
        )

        #expect(history.transcripts.count == 1, "the salvaged words never reached history")
        let kept = try #require(history.transcripts.first)
        #expect(kept.rawText == "This is the part the engine had already committed.")
        // Volatile text is materially worse and frequently wrong mid-word (RECON §4), so it must not
        // be in the salvage either — `finalText`, never `displayText`.
        #expect(!kept.text.contains("volatile"))
        // `.failed`, not `.clipboardOnly` and certainly not a success: nothing was injected, and the
        // row's own COPY key is the recovery.
        #expect(kept.injection == .failed)
        #expect(kept.injection.isSuccess == false)
        #expect(kept.targetAppName == "Ghostty")
        #expect(kept.localeIdentifier == "en-US")

        // And the sentence says where they went, without claiming an insertion that did not happen.
        #expect(message.contains("Edict's history"))
        #expect(message.contains("The 9 words heard so far are"))
        #expect(message.contains("not in your document"))
    }

    /// The ordering trap the audit found, pinned so it cannot be "tidied" back: the salvage has to be
    /// read *before* `abort()`. It is not merely a preference — `abort()` on an already-terminated
    /// session returns at its guard without draining the sink, so a read placed after it can only be
    /// correct by accident.
    @Test("The salvage is read before the session is aborted")
    func salvageIsReadBeforeAbort() async throws {
        let (controller, _, directory) = self.controller()
        defer { try? FileManager.default.removeItem(at: directory) }

        let session = FakeSession(finalText: "Words worth keeping.")
        await controller.failUtterance(
            session: session,
            error: SpeechEngineError.noAudioFormat,
            target: InjectionTarget(),
            corrector: Corrector(rules: []),
            localeIdentifier: "en-US",
            dropped: 0
        )
        #expect(session.log == ["snapshot", "abort"], "the sink was read after the abort, or not at all")
    }

    /// Layer 2 of the dictionary still runs, because the row's text is what the user will copy out of
    /// it — the version that would have been inserted, not the raw one.
    @Test("The salvaged row is corrected, and its hits are recorded on the row")
    func salvageRunsTheCorrectionPass() async throws {
        let (controller, history, directory) = self.controller()
        defer { try? FileManager.default.removeItem(at: directory) }

        await controller.failUtterance(
            session: FakeSession(finalText: "Deployed on visa this morning."),
            error: SpeechEngineError.notPrepared,
            target: InjectionTarget(),
            corrector: Corrector(rules: [rule("visa", "Vercel")]),
            localeIdentifier: "en-US",
            dropped: 0
        )

        let kept = try #require(history.transcripts.first)
        #expect(kept.text == "Deployed on Vercel this morning.")
        #expect(kept.rawText == "Deployed on visa this morning.")
        #expect(kept.corrections.count == 1)
    }

    /// A failure with nothing transcribed must not leave an empty row behind, and must not tell the
    /// user their words are somewhere they are not.
    @Test("A failure with nothing committed writes nothing and promises nothing")
    func nothingToSalvage() async throws {
        let (controller, history, directory) = self.controller()
        defer { try? FileManager.default.removeItem(at: directory) }

        for session in [FakeSession(finalText: ""), FakeSession(finalText: "   \n ")] {
            let message = await controller.failUtterance(
                session: session,
                error: AudioError.microphoneDenied,
                target: InjectionTarget(),
                corrector: Corrector(rules: []),
                localeIdentifier: "en-US",
                dropped: 0
            )
            #expect(!message.contains("history"))
        }
        // And the no-session case, which is every failure before `engine.begin` returned.
        let message = await controller.failUtterance(
            session: nil,
            error: AudioError.microphoneDenied,
            target: InjectionTarget(),
            corrector: Corrector(rules: []),
            localeIdentifier: "en-US",
            dropped: 0
        )
        #expect(!message.contains("history"))
        #expect(history.transcripts.isEmpty)
    }

    @Test("The salvage sentence counts one word as one word")
    func salvageMessageGrammar() {
        #expect(DictationController.salvageMessage("It failed.", words: 1)
            == "It failed. The 1 word heard so far is in Edict's history, not in your document.")
        #expect(DictationController.salvageMessage("It failed.", words: 2)
            .contains("The 2 words heard so far are"))
    }

    // MARK: - The salvage source

    /// `TranscriptionSession.snapshot` had zero call sites in Sources and Tests before finding #3, so
    /// the thing the whole recovery now rests on was unasserted. Two properties matter and both are
    /// checked here: `finalText` is exactly the committed finals, and the volatile tail — which RECON
    /// §4 measured saying "speecheech transcriber API" where the final said "speech transcriber API"
    /// — is kept out of it.
    @Test("A sink's snapshot is the committed finals, without the volatile tail")
    func snapshotIsTheCommittedText() {
        let sink = TranscriptSink(onUpdate: { _ in })
        sink.ingest(isFinal: true, range: Self.range(0, 1), text: AttributedString("One."))
        sink.ingest(isFinal: false, range: Self.range(1, 2), text: AttributedString(" volat"))
        #expect(sink.snapshot.finalText == "One.")
        #expect(sink.snapshot.volatileText == " volat")

        sink.ingest(isFinal: true, range: Self.range(1, 2), text: AttributedString(" Two."))
        #expect(sink.snapshot.finalText == "One. Two.")
        #expect(sink.snapshot.volatileText.isEmpty)
        #expect(sink.snapshot.finalText == sink.committed)
    }

    private static func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
    }
}

/// The reservation ladder and the per-language download state, against the real framework.
///
/// Gated like every other suite that talks to `AssetInventory` or builds a real module: these hold
/// and release genuine reservation slots, which persist across process launches keyed by the bundle
/// identifier (RECON §6), so they must not run interleaved with a plain unit-test pass.
///
/// **Nothing here downloads anything, and that is now enforced rather than asserted.** It used to be
/// asserted, by a comment above a locale list read off one machine's installed set — and the comment
/// was wrong everywhere else, because `resolveImportPass` answers a language whose general model is
/// missing by falling through to the dictation module and, finding nothing there either, calling
/// `downloadAndInstall()` in a detached task. That download starts *before* the `try #require` that
/// was supposed to report the problem, so on any other machine every test below was minutes of
/// somebody's bandwidth. It is why this suite could not be run at all while the fixes it covers were
/// being written, and why three of them shipped as stubs underneath it.
///
/// So every test asks `SpeechEngine.assetsInstalled` first and returns early when the answer is no —
/// with the *real* module, because RECON's second `AssetInventory` trap makes a cheap probe a liar:
/// installed state depends on `attributeOptions`, and `fr-FR` reads installed with `[]` and missing
/// with the `[.transcriptionConfidence, .audioTimeRange]` this app always requests.
///
/// Every test also runs inside `withRestoredInventory`, which puts the five slots back on the
/// failure path as well as the success one. One exception to the old claim that every test keeps
/// `en_US` and `id_ID` reserved, stated because it is true and the claim was not:
/// `clearSecondaryKeepsAnImportPassLocale` has to prepare the import language as its *secondary*, so
/// it cannot also hold `id_ID`, and its prune does release `id_ID` — restored when it finishes.
///
/// **Every claim below now has an ungated twin.** The three reservation tests are reproduced in
/// `ReservationLadderTests`, driven through the same production entry points against
/// `FakeReservations` — which reproduces the two behaviours this suite exists to observe: Code=11 on
/// the sixth distinct locale, and a `release` that refuses anything whose identifier does not match
/// byte for byte. The download-completion routing is reproduced in `DownloadCompletionRoutingTests`
/// further down this file. Those two suites are what actually protect this code, because they run on
/// every machine and every run. What is left here, and only here, is whether the *framework* still
/// behaves the way RECON measured it: run this deliberately after an OS update, not as coverage.
@Suite("Engine recovery — reservations",
       .enabled(if: ProcessInfo.processInfo.environment["EDICT_SPEECH_TESTS"] == "1"),
       .serialized)
struct EngineReservationRecoveryTests {

    /// Candidate locales for the **general** module: where their assets are on disk,
    /// `preferGeneral: true` resolves them without a download. Whether they are on disk is checked
    /// per test rather than assumed — see the suite comment. Ordered: the eviction test resolves
    /// them in this order and expects the first to go.
    private static let generalCandidates = ["en-GB", "en-AU", "en-CA"]
    /// A locale supported by the dictation module whose assets are expected **not** to be on disk.
    /// Only ever asset-*checked*, never downloaded.
    private static let uninstalled = "fr-FR"

    // MARK: - Skipping, and putting the inventory back

    /// Whether the **general** model Edict would really build for `identifier` has its assets on
    /// disk — the same question `resolveImportPass`'s general branch asks, so this is predictive
    /// rather than an approximation of it.
    ///
    /// A locale the general module does not support at all answers `false`, which is the right skip:
    /// `resolveImportPass` would go straight to the dictation branch for it.
    private static func generalAssetsInstalled(_ identifier: String) async -> Bool {
        guard let canonical = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: identifier)
        ) else { return false }
        return await SpeechEngine.assetsInstalled(module: .general, locale: canonical)
    }

    /// Skip rather than fail — and, the reason this exists, skip rather than **download**.
    ///
    /// Printed rather than silent, because a test that quietly does nothing on the machine that
    /// needed it most is how the last round's stubs got through. Call it *after* the engine has
    /// pruned: asking costs a reservation slot each (RECON §6), and there are only five.
    private static func generalModelsPresent(_ identifiers: [String]) async -> Bool {
        for identifier in identifiers where !(await generalAssetsInstalled(identifier)) {
            print("""
                [engine-recovery] skipped: \(identifier) has no general-module assets on this Mac. \
                Resolving it would fall through to the dictation module and start a real model \
                download, so the test returns instead.
                """)
            return false
        }
        return true
    }

    /// Run `body`, then put the reservation inventory back — on the failure path as well as the
    /// success one.
    ///
    /// `restoreInventory()` used to be the last statement of each test and nothing more, so a
    /// failing `try #require` walked away holding up to five slots. That is not untidiness:
    /// reservations **persist across process launches** keyed to the bundle identifier (RECON §6),
    /// so one failed test run could leave the user's own app unable to reserve anything at all.
    ///
    /// A wrapper and not a `defer`, because `await` cannot appear in a `defer` body — that is a
    /// compile error, not a style preference. A final restore-everything test would also work, since
    /// the suite is `.serialized` and runs in source order, but this restores *between* tests rather
    /// than only after the last one, so a test never inherits four held slots from the test before
    /// it — and it still works when someone runs a single test under `--filter`.
    private func withRestoredInventory(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            // The original failure is what the reader needs, so a failure of the restore itself is
            // recorded beside it rather than replacing it.
            do {
                try await restoreInventory()
            } catch let restoreError {
                Issue.record("the reservation inventory could not be restored: \(restoreError)")
            }
            throw error
        }
        try await restoreInventory()
    }

    /// Both dictation languages prepared, and any leftover reservation from an earlier run released.
    ///
    /// `id-ID` is prepared even where the test does not need a second language, for two reasons: it
    /// makes the import budget 2 — the production shape, and the one a dual pass depends on — and it
    /// keeps `id_ID` in this engine's keep set so nothing here releases a slot another gated suite is
    /// using. `prepareSecondary` checks assets and never downloads.
    private func preparedEngine() async throws -> SpeechEngine {
        let engine = SpeechEngine()
        try await engine.prepare(localeIdentifier: "en-US")
        try await engine.prepareSecondary(localeIdentifier: "id-ID")
        await engine.pruneReservations()
        return engine
    }

    /// Leave the inventory as the running app expects it: the two dictation languages and nothing
    /// else.
    ///
    /// Only ever called through `withRestoredInventory`, which is what makes it run on the failure
    /// path too. It is not a nicety: reservations persist across process launches keyed to the bundle
    /// identifier (RECON §6) and there are five of them, so a run that walks away holding four
    /// leaves the *user's* app unable to reserve, not just the next test.
    ///
    /// Read the scope of that prune carefully, because it is wider than this suite.
    /// `pruneReservations()` releases every slot outside *this* engine's keep set, and the five slots
    /// are shared per bundle identifier — so this reaches into whatever the other two gated suites
    /// (`SecondaryLocaleEngineTests`, `ImportLocaleEngineTests`) are holding, and `.serialized` here
    /// does not stop it: measured in this target with two throwaway `.serialized` suites, the two ran
    /// concurrently with each other while each kept its own tests in order. What keeps the collateral
    /// survivable is the keep set, not the trait: preparing `en-US` and `id-ID` above means the prune
    /// keeps `en_US` and `id_ID`, which are the only reservations the other two gated suites assert
    /// on. A *third* language — an import pass's locale mid-resolution — is outside a fresh engine's
    /// keep set and can still be pulled out from under a concurrent gated run.
    /// Nothing serializes the three gated suites against each other; running one at a time with
    /// `--filter` is the only way to be sure.
    private func restoreInventory() async throws {
        let engine = SpeechEngine()
        try await engine.prepare(localeIdentifier: "en-US")
        try await engine.prepareSecondary(localeIdentifier: "id-ID")
        await engine.pruneReservations()
    }

    // MARK: - Finding #7: the keep sets

    /// The headline of finding #7. `pruneReservations()` runs from `prepareSecondary()`, which
    /// `settingsChanged()` calls — so importing a file and then touching the language picker was
    /// enough to release the reservation behind the import's own model, while `importPasses` went on
    /// memoising it as `.ready`. Both keep sets listed `generalLocale`, which is always nil in
    /// production, and omitted the locales genuinely in use.
    @Test("Pruning keeps the reservation an import pass is still using")
    func pruneKeepsImportPassLocales() async throws {
        try await withRestoredInventory {
            // Prepared first, so the installed check below runs against a pruned inventory rather
            // than whatever the last run left behind — the check itself takes a slot per locale.
            let engine = try await preparedEngine()
            let language = Self.generalCandidates[0]
            guard await Self.generalModelsPresent([language]) else { return }

            let resolution = await engine.resolveImportPass(
                preferGeneral: true,
                localeIdentifier: language
            )
            let pass = try #require(
                resolution.pass,
                "\(language) resolved to nothing despite installed assets: \(resolution.reason ?? "")"
            )
            #expect(pass.module == .general)
            let canonical = pass.canonicalIdentifier
            #expect(await engine.reservedLocaleIdentifiers().contains(canonical))

            let released = await engine.pruneReservations()
            #expect(!released.contains(canonical), "the prune released the import pass's own locale")
            #expect(await engine.reservedLocaleIdentifiers().contains(canonical))

            // And the memo still means something: the pass resolves from cache, against a locale
            // that is still reserved. The state this rules out is a `.ready` memo on an unreserved
            // locale, which the framework logs as "will be an error in a future release" and today
            // still transcribes, which is precisely why nothing would notice.
            #expect(await engine.resolveImportPass(
                preferGeneral: true,
                localeIdentifier: language
            ).pass?.canonicalIdentifier == canonical)
        }
    }

    /// Turning the language shortcut off must not release a slot an import is using — the user who
    /// dictates in a second language is the same user who imports files in it.
    @Test("Turning the language shortcut off keeps a reservation an import still needs")
    func clearSecondaryKeepsAnImportPassLocale() async throws {
        try await withRestoredInventory {
            let language = Self.generalCandidates[0]
            // Checked before anything is prepared here, because this test cannot use
            // `preparedEngine()` — it needs `language` as its own secondary. The check leaves at
            // most one extra reservation, which the prune inside `resolveImportPass` sweeps.
            guard await Self.generalModelsPresent([language]) else { return }

            let engine = SpeechEngine()
            try await engine.prepare(localeIdentifier: "en-US")
            // The same language as the import, which is the case that matters. `prepareSecondary`
            // only asset-*checks* — it does not download — so this is safe even though the
            // dictation model for this language is very likely missing.
            try await engine.prepareSecondary(localeIdentifier: language)

            let resolution = await engine.resolveImportPass(
                preferGeneral: true,
                localeIdentifier: language
            )
            let canonical = try #require(
                resolution.pass?.canonicalIdentifier,
                "\(language) resolved to nothing despite installed assets: \(resolution.reason ?? "")"
            )

            await engine.clearSecondary()
            #expect(
                await engine.reservedLocaleIdentifiers().contains(canonical),
                "clearing the secondary language released the import's reservation"
            )
        }
    }

    /// The other half of finding #7: nothing ever pruned the import reservations, so every import
    /// language ever resolved held one of the five slots for the life of the process — and beyond,
    /// because reservations persist. A later language then met a Code=11 whose eviction ladder had
    /// nothing left it was allowed to evict.
    ///
    /// The budget deliberately stops one short of filling the inventory, because RECON §6 measured
    /// `assetInstallationRequest(supporting:)` reserving the locale it is asked about as a side
    /// effect: the availability check itself consumes the slot the caller is about to want, and a
    /// full inventory also makes a dictation language change fail outright.
    @Test("A third import language evicts the least recently used one, memo and reservation together")
    func importReservationsAreEvictedLeastRecentlyUsed() async throws {
        try await withRestoredInventory {
            let engine = try await preparedEngine()
            guard await Self.generalModelsPresent(Self.generalCandidates) else { return }

            var canonical: [String: String] = [:]
            for identifier in Self.generalCandidates {
                let resolution = await engine.resolveImportPass(
                    preferGeneral: true,
                    localeIdentifier: identifier
                )
                canonical[identifier] = try #require(
                    resolution.pass?.canonicalIdentifier,
                    "\(identifier) resolved to nothing despite installed assets: \(resolution.reason ?? "")"
                )
            }

            let oldest = try #require(canonical[Self.generalCandidates[0]])
            let middle = try #require(canonical[Self.generalCandidates[1]])
            let newest = try #require(canonical[Self.generalCandidates[2]])

            let reserved = await engine.reservedLocaleIdentifiers()
            #expect(reserved.count <= 5, "the five slots were exceeded: \(reserved)")
            #expect(
                !reserved.contains(oldest),
                "the least recently used import language was never released"
            )
            #expect(reserved.contains(middle))
            #expect(reserved.contains(newest))
            // The two dictation languages are never candidates for eviction.
            #expect(reserved.contains("en_US"))
            #expect(reserved.contains("id_ID"))

            // Asking for the evicted language again re-resolves and re-reserves it, at the cost of
            // the next-oldest — which is the trade, and a cheap one: resolution is a reservation and
            // an asset check, not a download.
            #expect(await engine.resolveImportPass(
                preferGeneral: true,
                localeIdentifier: Self.generalCandidates[0]
            ).pass != nil)
            let after = await engine.reservedLocaleIdentifiers()
            #expect(after.contains(oldest))
            #expect(!after.contains(middle))
            #expect(after.count <= 5)
        }
    }

    // MARK: - Finding #4: one download slot for every language

    /// The indefensible half of finding #4. One `secondaryDownload` slot and one
    /// `secondaryDownloadFinished(error:)` were shared between the live secondary dictation language
    /// and every import language, and the completion wrote `secondaryAssetsReady = true`
    /// unconditionally — so on a machine where the secondary dictation language is not installed, a
    /// *third* language's successful download reported it as ready. `requireSecondaryAssets()`, whose
    /// own comment calls itself "the one place where falling back would be indefensible", then let an
    /// utterance run against a model that is not on disk: Indonesian speech into the English model
    /// does not fail, it returns fluent English nonsense and the injection ladder types it out.
    @Test("A finished download is applied to its own language, not to the secondary one")
    func downloadCompletionIsPerLanguage() async throws {
        try await withRestoredInventory {
            let engine = SpeechEngine()
            try await engine.prepare(localeIdentifier: "en-US")
            // Asset-checked, never downloaded — that is all `prepareSecondary` does.
            try await engine.prepareSecondary(localeIdentifier: Self.uninstalled)

            // A precondition, and a skip rather than a failure: this test needs a language whose
            // model is *missing*, and on a Mac where that language happens to be installed nothing
            // is wrong — there is just nothing here to stand in for a missing model.
            guard await engine.secondaryModelState != .ready else {
                print("""
                    [engine-recovery] skipped: \(Self.uninstalled) is installed on this Mac, so it \
                    cannot stand in for a language whose model is missing.
                    """)
                return
            }

            // Some unrelated language's download finishing — an import's, in production.
            await engine.downloadFinished(identifier: "de_DE", error: nil)
            #expect(
                await engine.secondaryModelState != .ready,
                "another language's download reported the secondary language as installed"
            )

            // And a failure for an unrelated language must not be reported as the secondary
            // language's.
            await engine.downloadFinished(
                identifier: "de_DE",
                error: NSError(
                    domain: "test",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "offline"]
                )
            )
            if case .unavailable(let why) = await engine.secondaryModelState {
                #expect(!why.contains("offline"))
            }

            // The secondary language's own completion still lands. Underscored: RECON §6 measured
            // the framework storing `fr_FR`, and matching on the raw identifier string is the whole
            // trap.
            await engine.downloadFinished(identifier: "fr_FR", error: nil)
            #expect(await engine.secondaryModelState == .ready)
        }
    }
}

// MARK: - Finding #4, without touching the network

/// The per-language half of finding #4, tested where it can be tested for free.
///
/// `EngineReservationRecoveryTests` above is gated behind `EDICT_SPEECH_TESTS=1` because it resolves
/// real import passes, and on a machine whose general-module assets differ from the author's that
/// resolution falls through to the dictation branch and starts a real model download. So the gated
/// suite could not be run here, and the bug it was written to catch shipped anyway:
/// `downloadFinished` opened with a hardcoded `let isSecondary = true`, which made every `else`
/// branch unreachable and made ANY completed download mark the live secondary dictation language as
/// ready.
///
/// This suite reaches the same defect through `secondaryModelState`, which is public, on an engine
/// that has prepared nothing. No assets, no network, no reservations — so it runs on every machine,
/// every time, which is the property the gated suite lacks.
@Suite("Engine recovery — download completions")
@MainActor
struct DownloadCompletionRoutingTests {

    @Test("A finished import download does not mark the secondary dictation language ready")
    func importCompletionDoesNotTouchSecondary() async {
        let engine = SpeechEngine()
        // Nothing prepared, so `secondaryLocale` is nil and no identifier can be the secondary one.
        #expect(await engine.secondaryModelState == .unavailable("not prepared"))

        await engine.downloadFinished(identifier: "fr_FR", error: nil)

        #expect(await engine.secondaryModelState == .unavailable("not prepared"),
                """
                a French import's download was applied to the secondary dictation language; the next \
                Shift-Right-Option would build its analyzer against a model that is not on disk
                """)
    }

    @Test("A failed import download does not mark the secondary dictation language unavailable")
    func importFailureDoesNotTouchSecondary() async {
        let engine = SpeechEngine()
        await engine.downloadFinished(
            identifier: "fr_FR",
            error: SpeechEngineError.assetInstallFailed("no space left on device")
        )

        // The reason must still be "not prepared" — the state this engine was born in — rather than
        // the French download's reason, which would show a French disk error under Indonesian in
        // Settings.
        #expect(await engine.secondaryModelState == .unavailable("not prepared"))
    }
}

// MARK: - Finding #5's teardown, without a framework

/// The half-built analyzer teardown, tested where the framework cannot get in the way.
///
/// The teardown itself is right: `halfBuilt` is armed immediately after the analyzer init and
/// cleared only once `activeSession` is assigned, the order is `continuation.finish()` then
/// `cancelAndFinishNow()` as RECON §5 verified, and the original error is rethrown rather than
/// swallowed. What review found is what it did to the *slot*: it inserted an `await` between the
/// throw and `releaseSlot`, on an analyzer whose `prepareToAnalyze(in:)` had just thrown — a state
/// nothing on this machine has measured. If that await never returns, `slotHolder` stays set while
/// `activeSession` is still nil, and `claimSlot`'s stale-holder reclaim needs a **non-nil**
/// `activeSession` to fire, so nothing can ever clear it: every later press fails with
/// `.sessionAlreadyRunning` for the rest of the process.
///
/// No assets, no reservations, no analyzer, no network — the slot bookkeeping is all this asserts
/// on, and `abandonHalfBuilt` takes its teardown as a parameter precisely so a test can stand in
/// for a hang that cannot be produced any other way.
@Suite("Engine recovery — the half-built teardown")
struct HalfBuiltTeardownTests {

    @Test("The slot is handed back before a half-built analyzer's teardown is awaited")
    func slotIsFreeWhileTheTeardownRuns() async throws {
        let engine = SpeechEngine()
        let serial = try await engine.claimSlot(module: .dictation, locale: .primary)
        #expect(await engine.isSlotClaimed)

        // A teardown that outlives the assertions, standing in for `cancelAndFinishNow()` on an
        // analyzer whose `prepareToAnalyze(in:)` has just thrown. Bounded at two seconds rather
        // than forever on purpose: a regression should turn this test red, not hang the run, and a
        // hung test run is a worse kind of red than a failing expectation.
        let abandoning = Task {
            await engine.abandonHalfBuilt(serial: serial, reason: "test: a teardown that hangs") {
                try? await Task.sleep(for: .seconds(2))
            }
        }

        // Polled rather than slept past, for the reason RECON's "wall-clock assertions" note gives:
        // the property is "the slot comes back without waiting for the teardown", and a sleep long
        // enough to be safe under a parallel run would also sleep past the two-second stand-in.
        var freed = false
        for _ in 0..<50 {
            if await engine.isSlotClaimed == false {
                freed = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(freed, """
            the slot was still held while the half-built teardown ran — if that teardown never \
            returns, claimSlot's stale-holder reclaim cannot fire (it needs a non-nil \
            activeSession) and every press for the rest of the process fails
            """)

        // And the release is real, not just a cleared flag: the next press can take the slot while
        // the doomed analyzer is still being cancelled.
        let next = try await engine.claimSlot(module: .dictation, locale: .primary)
        #expect(next != serial, "the next press did not get a claim of its own")

        // Cancelled rather than awaited to completion, so the suite does not pay the stand-in's two
        // seconds. `Task.sleep` is the only thing in there and it returns immediately on cancel.
        abandoning.cancel()
        await abandoning.value
    }
}

// MARK: - Finding #7's keep set, without the framework

/// The keep set and the memo eviction, tested where they can be tested on every machine.
///
/// These two decisions are the whole of finding #7, and both of them shipped broken:
/// `keepSet()` returned only the two dictation locales while its own ten-line doc comment asserted it
/// included the import pass locales and the in-flight downloads, and the memo eviction was wrapped in
/// `if false, importPassOrder.count > budget {`, which swiftc accepts in silence. Neither was caught,
/// because the only tests that could see either were in `EngineReservationRecoveryTests` — gated
/// behind `EDICT_SPEECH_TESTS=1` and unrunnable on this machine, since resolving `en-GB` here falls
/// through to the dictation module and starts a real model download.
///
/// So the two decisions are now values. No `AssetInventory`, no reservations, no modules, no network:
/// this suite runs in the default `swift test` pass, which is the only place a stub would have been
/// caught. The gated suite still owns everything that needs the real framework — that a prune leaves a
/// reservation alone, that `clearSecondary` does, that eviction releases the slot it dropped the memo
/// for.
@Suite("Engine recovery — the keep set")
struct KeepSetTests {

    /// The `en-GB` → `en_GB` shift the whole finding turns on: the memo is keyed by what the caller
    /// asked for, the reservation is held under what the framework handed back, and
    /// `AssetInventory.release` matches on the raw string (RECON §6).
    private func canonical(_ requested: String) -> String {
        requested.replacingOccurrences(of: "-", with: "_")
    }

    @Test("A resolved import pass's locale is kept, not just the two dictation languages")
    func importPassLocalesAreKept() {
        let keep = SpeechEngine.keepSet(
            canonical: "en_US",
            secondary: "id_ID",
            importPassLocales: [canonical("en-GB")],
            downloading: []
        )

        #expect(keep.contains("en_GB"), """
            the sweep would release the reservation under a live import pass, while `importPasses` \
            went on memoising it as `.ready` — an unreserved module the framework still transcribes, \
            logging "will be an error in a future release", which is why nothing would notice
            """)
        #expect(keep.contains("en_US"))
        #expect(keep.contains("id_ID"))
    }

    @Test("A language whose model is downloading is kept")
    func inFlightDownloadsAreKept() {
        let keep = SpeechEngine.keepSet(
            canonical: "en_US",
            secondary: nil,
            importPassLocales: [],
            downloading: ["fr_FR"]
        )

        // Releasing the slot under a running `downloadAndInstall()` is not a case anything on this
        // machine has measured, and the cost of being wrong is a model that never arrives.
        #expect(keep.contains("fr_FR"))
        #expect(keep.contains("en_US"))
    }

    @Test("Nothing prepared keeps nothing, which is what makes the empty-set guard meaningful")
    func nothingPreparedKeepsNothing() {
        let keep = SpeechEngine.keepSet(
            canonical: nil,
            secondary: nil,
            importPassLocales: [],
            downloading: []
        )

        // `pruneReservations` reads emptiness as "no language is prepared yet" and releases nothing
        // rather than everything, so this case has to stay reachable.
        #expect(keep.isEmpty)
    }

    @Test("A language that is both the secondary and an import pass appears once")
    func overlappingRolesCollapse() {
        let keep = SpeechEngine.keepSet(
            canonical: "en_US",
            secondary: "id_ID",
            importPassLocales: ["id_ID"],
            downloading: ["id_ID"]
        )

        // The user who dictates in Indonesian is the user who imports Indonesian files. A set, so
        // `clearSecondary` dropping its own claim on the language cannot drop the import's.
        #expect(keep == ["en_US", "id_ID"])
    }

    @Test("Memos are evicted least recently used first, and only once the budget is exceeded")
    func memoEvictionIsLeastRecentlyUsed() {
        // Two import languages with room for two: nothing goes. An order that exactly fills the
        // budget is the ordinary state of a dual-pass import between two files.
        #expect(SpeechEngine.memosToEvict(order: ["en-GB", "en-AU"], budget: 2).isEmpty)
        // The production shape: both dictation languages prepared makes the import budget 2, so one
        // memo may be held while a second is resolved.
        #expect(SpeechEngine.memosToEvict(order: ["en-GB"], budget: 1).isEmpty)
        #expect(SpeechEngine.memosToEvict(order: ["en-GB", "en-AU"], budget: 1) == ["en-GB"])
        #expect(SpeechEngine.memosToEvict(order: ["en-GB", "en-AU", "en-CA"], budget: 1)
            == ["en-GB", "en-AU"])
        #expect(SpeechEngine.memosToEvict(order: ["en-GB"], budget: 0) == ["en-GB"])
        #expect(SpeechEngine.memosToEvict(order: [], budget: 0).isEmpty)
    }

    @Test("Every memo that survives eviction is still in the keep set")
    func survivingMemosAreStillReserved() {
        let order = ["en-GB", "en-AU", "en-CA"]
        let dropped = SpeechEngine.memosToEvict(order: order, budget: 1)
        let survivors = order.filter { !dropped.contains($0) }

        let keep = SpeechEngine.keepSet(
            canonical: "en_US",
            secondary: "id_ID",
            importPassLocales: survivors.map(canonical),
            downloading: []
        )

        // The invariant the two halves exist to hold together, and the one the stubs broke from both
        // sides: a memo may never outlive its reservation, and a reservation may never outlive its
        // memo. `pruneImportPasses` drops the memos and then sweeps everything outside this set, so
        // "survivor" and "kept" have to be the same list.
        for survivor in survivors {
            #expect(keep.contains(canonical(survivor)), "\(survivor) kept its memo but lost its slot")
        }
        for gone in dropped {
            #expect(!keep.contains(canonical(gone)), "\(gone) lost its memo but kept its slot")
        }
    }
}
