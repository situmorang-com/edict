import Foundation
import Speech
import Testing

@testable import EdictKit

//
//  ReservationLadderTests.swift
//  The five reservation slots, on every machine.
//
//  These exist because the answer to "would any test catch reservation exhaustion?" was no. `reserve`
//  was private, its Code=11 → evict-outside-keep → retry ladder went straight at `AssetInventory`
//  statics, and the only tests that could see any of it lived in `EngineReservationRecoveryTests` —
//  gated behind `EDICT_SPEECH_TESTS=1`, which cannot run on this machine: it resolves
//  `en-GB`/`en-AU`/`en-CA`, whose general-module assets are absent here, so `resolveImportPass` falls
//  through to the dictation branch and calls `downloadAndInstall()` in a detached task before the
//  `try #require` meant to report the problem can fire. Three bugs shipped underneath that gate in
//  one round — a hardcoded `let isSecondary = true`, an `if false,` dead-coding the memo eviction,
//  and a `keepSet()` whose one-line body contradicted its own ten-line doc comment — all with a
//  green suite.
//
//  So the ladder now runs against `FakeReservations`. No assets, no network, and — the part that
//  matters most — no real slots consumed, because the real ones persist across process launches keyed
//  to the bundle identifier and a test run that strands them strands the *user's* app.
//

// MARK: - The double

/// The five locale reservation slots, in memory, behaving the way RECON measured the real ones.
///
/// Three measured behaviours, and the tests below are worth very little without all three:
///
/// 1. **The sixth distinct locale throws.** `NSError(SFSpeechErrorDomain, code: 11)`, "Too many
///    allocated locales, 5 maximum" — the error the entire eviction ladder exists to answer.
/// 2. **`release` matches on the raw identifier string.** A rebuilt `Locale(identifier: "id-ID")`
///    against a stored `"id_ID"` returns false, releases nothing, and leaks the slot for every future
///    launch (RECON §6). Measured while writing this: `Locale(identifier:)` normalises *case* but not
///    the *separator* — `"ID_id"` and `"id_id"` both come back `"id_ID"`, while `"id-ID"` and
///    `"ID-ID"` both come back `"id-ID"` and `"id"` stays `"id"`. So the trap is exactly the hyphen,
///    which is the form Edict's own settings use, and storing what `reserve` was handed reproduces it
///    byte for byte rather than approximating it.
/// 3. **The installation check takes a reservation.** RECON §6 measured
///    `assetInstallationRequest(supporting:)` reserving the locale it is asked about as a side effect —
///    it is what silently consumed a `ja-JP` slot during probing, and it is the primary route to
///    exhaustion. A double that answered "is this installed" for free would leave the exhaustion
///    tests below proving the opposite of the truth: they would show four import languages fitting
///    comfortably where the real inventory has already run out.
///
/// In the test target rather than in `Sources` on purpose: a double in the library is a double in the
/// shipped binary.
final class FakeReservations: LocaleReservations, @unchecked Sendable {

    /// What a stand-in `downloadAndInstall()` does.
    enum Install: Sendable {
        case succeeds
        case fails(String)
        /// Still running. Not a wall-clock dependency — nothing is asserted on a deadline — it is
        /// the only deterministic way to observe the state `keepSet()` has to hold a slot through,
        /// since a download that completes clears `downloads` on an actor hop the test cannot see.
        case neverFinishes
    }

    /// `@unchecked Sendable` over one `NSLock` guarding every stored property below. The engine is an
    /// actor and the download tasks it spawns are not, so this is read from more than one isolation
    /// domain; the lock is never held across an `await`.
    private let lock = NSLock()
    private let slots: Int
    private let install: Install
    private let missing: Set<String>
    private var held: [Locale]
    private var reserveFailureCount = 0
    private var installationCheckCount = 0
    private var refusedReleaseCount = 0

    /// - Parameters:
    ///   - slots: how many locales may be held at once. Five is what macOS allows and the default.
    ///   - held: locales already reserved before this engine existed, in the framework's own
    ///     spelling. Not a contrivance: reservations persist across process launches keyed to the
    ///     bundle identifier, so "four slots held by nobody" is the state a second launch starts in.
    ///   - missing: `key(module, identifier)` entries whose assets the fake reports as **not**
    ///     installed. Everything else answers installed. Keyed by module as well as locale because
    ///     RECON's second `AssetInventory` trap is that installed state depends on
    ///     `attributeOptions`: `fr-FR` on the general module reads installed with `[]` and missing
    ///     with the `[.transcriptionConfidence, .audioTimeRange]` this app always requests.
    ///   - install: what a returned installation request does when the engine runs it.
    init(
        slots: Int = 5,
        held: [String] = [],
        missing: Set<String> = [],
        install: Install = .neverFinishes
    ) {
        self.slots = slots
        self.held = held.map { Locale(identifier: $0) }
        self.missing = Set(missing.map { $0.replacingOccurrences(of: "-", with: "_") })
        self.install = install
    }

    /// The spelling-insensitive key `missing` uses. Only the *test's own expectation set* is
    /// normalised here — `release` below stays byte-exact, which is where the trap lives.
    static func key(_ module: TranscriptionModule, _ identifier: String) -> String {
        "\(module.rawValue)/\(identifier.replacingOccurrences(of: "-", with: "_"))"
    }

    // MARK: What the tests read

    var heldIdentifiers: Set<String> { lock.withLock { Set(held.map(\.identifier)) } }
    /// How many times `reserve` threw Code=11. The ladder's own retry makes this 2 for a reservation
    /// that fails outright and 1 for one that succeeds after evicting.
    var reserveFailures: Int { lock.withLock { reserveFailureCount } }
    /// How many times somebody asked whether a model was installed. Asking is not free.
    var installationChecks: Int { lock.withLock { installationCheckCount } }
    /// How many releases were refused for not matching a held identifier byte for byte.
    var refusedReleases: Int { lock.withLock { refusedReleaseCount } }

    // MARK: LocaleReservations

    var reservedLocales: [Locale] {
        get async { lock.withLock { held } }
    }

    @discardableResult
    func reserve(locale: Locale) async throws -> Bool {
        try lock.withLock {
            // Already held is `false` and not an error, exactly as the framework reports it.
            if held.contains(where: { $0.identifier == locale.identifier }) { return false }
            guard held.count < slots else {
                reserveFailureCount += 1
                throw Self.tooManyLocales
            }
            held.append(locale)
            return true
        }
    }

    @discardableResult
    func release(reservedLocale: Locale) async -> Bool {
        lock.withLock {
            // The trap, reproduced: raw string equality, no canonicalisation, no case folding.
            guard let index = held.firstIndex(where: { $0.identifier == reservedLocale.identifier })
            else {
                refusedReleaseCount += 1
                return false
            }
            held.remove(at: index)
            return true
        }
    }

    func installationRequest(
        module: TranscriptionModule,
        locale: Locale
    ) async throws -> (any AssetInstallation)? {
        lock.withLock { installationCheckCount += 1 }
        // The side effect that makes this the primary exhaustion route. It can throw Code=11 too,
        // which is the case a reserve/release-only double could never produce.
        try await reserve(locale: locale)
        guard lock.withLock({ missing.contains(Self.key(module, locale.identifier)) }) else {
            return nil
        }
        return FakeInstall(install: install)
    }

    /// `SFSpeechErrorDomain` Code=11, "Too many allocated locales, 5 maximum" — as measured. The code
    /// is not in the public `SFSpeechErrorCode` enum, which is why it is written out here.
    static let tooManyLocales = NSError(
        domain: SFSpeechErrorDomain,
        code: 11,
        userInfo: [NSLocalizedDescriptionKey: "Too many allocated locales, 5 maximum"]
    )

    private struct FakeInstall: AssetInstallation {
        let install: Install

        func downloadAndInstall() async throws {
            switch install {
            case .succeeds:
                return
            case .fails(let why):
                throw NSError(
                    domain: "FakeReservations",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: why]
                )
            case .neverFinishes:
                try await Task.sleep(for: .seconds(86_400))
            }
        }
    }
}

// MARK: - The ladder

/// The Code=11 eviction ladder, the keep set as the engine actually reads it, and the prune —
/// against the fake, so all of it runs in the default `swift test` pass.
///
/// Two real framework calls survive in here, and they are named rather than hidden.
/// `DictationTranscriber.supportedLocale(equivalentTo:)` answers which of the 54 locales exist and in
/// what spelling — metadata, and the reason no expectation below hardcodes an underscore. And
/// `prepare` asks `SpeechAnalyzer.bestAvailableAudioFormat` for a format, which builds a real
/// `DictationTranscriber` for `en-US`; it downloads nothing, and whether it takes a reservation has
/// never been measured — RECON §6 observed only `assetInstallationRequest` doing that, and the
/// ungated `SessionLifecycleTests` has been making the same call on every run for far longer.
/// Everything that touches a slot or asks about an asset goes through the fake.
@Suite("The reservation ladder")
struct ReservationLadderTests {

    /// A canonical identifier in the framework's own spelling, so no expectation below hardcodes a
    /// guess at where the underscores fall or at what `DictationTranscriber` covers.
    private static func canonical(_ identifier: String) async throws -> String {
        try #require(
            await DictationTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: identifier)
            )?.identifier,
            "\(identifier) is not one of the locales DictationTranscriber covers on this machine"
        )
    }

    // MARK: A sixth locale

    /// The headline of the ladder: the sixth distinct locale throws, and what gets evicted to make
    /// room is only ever something Edict has stopped depending on.
    ///
    /// The four locales held up front are the shape a second launch really starts in — reservations
    /// persist across process launches keyed to the bundle identifier (RECON §6), so a previous run
    /// that forgot to release leaves exactly this.
    @Test("A sixth locale evicts what is outside the keep set, and succeeds")
    func sixthLocaleEvictsOnlyOutsideTheKeepSet() async throws {
        let stale = ["de_DE", "fr_FR", "ja_JP", "es_ES"]
        let fake = FakeReservations(slots: 5, held: stale)
        let engine = SpeechEngine(reservations: fake)

        // One language prepared, so the keep set is non-empty and specific. `prepareSecondary` only
        // asset-checks; it never downloads.
        try await engine.prepareSecondary(localeIdentifier: "id-ID")
        let indonesian = try await Self.canonical("id-ID")
        #expect(fake.heldIdentifiers.count == 5, "the inventory should be full before the sixth ask")

        // The sixth.
        let english = try await engine.reserveLocale("en-US")

        #expect(fake.reserveFailures == 1, "the Code=11 ladder never ran, so nothing was evicted")
        #expect(fake.heldIdentifiers.contains(english.identifier))
        #expect(
            fake.heldIdentifiers.contains(indonesian),
            """
            the eviction released the prepared secondary dictation language — the keep set is what \
            stops the language shortcut throwing halfway through a session for no visible reason
            """
        )
        #expect(
            fake.heldIdentifiers.isDisjoint(with: stale),
            "the ladder kept slots for languages Edict had stopped depending on"
        )
        #expect(fake.refusedReleases == 0, """
            a release was refused, which means the ladder handed back a rebuilt Locale instead of one \
            taken from reservedLocales — RECON §6: release matches on the raw identifier string
            """)
    }

    /// The other end of the ladder: when every held slot is one Edict still depends on, the
    /// reservation **fails** rather than evicting the language the user is speaking.
    ///
    /// Built entirely out of production paths, with all five slots genuinely in the keep set. Two of
    /// them are held by in-flight downloads, which is how the state is reachable in production even
    /// though `importReservationBudget` deliberately stops one short of filling the inventory: the
    /// keep set holds a downloading language whether or not it was ever memoised as a pass.
    @Test("With every slot in the keep set, the sixth reservation fails instead of evicting")
    func everySlotInTheKeepSetThrowsRatherThanEvicting() async throws {
        let fake = FakeReservations(
            slots: 5,
            missing: [
                FakeReservations.key(.dictation, "fr-FR"),
                FakeReservations.key(.dictation, "ja-JP"),
            ],
            install: .neverFinishes
        )
        let engine = SpeechEngine(reservations: fake)

        try await engine.prepare(localeIdentifier: "en-US")
        try await engine.prepareSecondary(localeIdentifier: "id-ID")

        // One import language that resolves, so a memo and its reservation are both in the keep set.
        let resolved = await engine.resolveImportPass(preferGeneral: false, localeIdentifier: "de-DE")
        #expect(resolved.pass != nil, "de-DE did not resolve: \(resolved.reason ?? "")")

        // Two whose models are missing. Each takes a slot and starts a download, and the download is
        // what keeps the slot: releasing it under a running `downloadAndInstall()` would buy a model
        // that never arrives.
        for identifier in ["fr-FR", "ja-JP"] {
            let pending = await engine.resolveImportPass(
                preferGeneral: false,
                localeIdentifier: identifier
            )
            #expect(pending.pass == nil, "\(identifier) resolved despite a missing model")
            #expect(
                pending.reason?.contains("Downloading") == true,
                "\(identifier): \(pending.reason ?? "no reason")"
            )
        }

        let full = fake.heldIdentifiers
        #expect(full.count == 5, "the five slots were not all taken: \(full.sorted())")

        // The reserve half of a dictation language change — `prepare` and `prepareSecondary` both
        // go through `reserveLocale` — with nothing evictable left. Checked for support first so an
        // OS that stopped covering Portuguese would say so rather than throwing
        // `.localeUnsupported`, which is a `SpeechEngineError` too and would satisfy the expectation
        // below for the wrong reason.
        _ = try await Self.canonical("pt-BR")
        await #expect(throws: SpeechEngineError.self) {
            _ = try await engine.reserveLocale("pt-BR")
        }

        #expect(fake.reserveFailures == 2, """
            the ladder did not run its evict-and-retry: it should fail once on the first reserve and \
            once on the retry after finding nothing it is allowed to evict
            """)
        #expect(fake.heldIdentifiers == full, """
            the ladder evicted a locale that was still in the keep set — with all five in use the \
            honest outcome is a failed reservation, not a released model somebody is transcribing with
            """)
    }

    // MARK: The check that costs a slot

    /// RECON §6's measured side effect, and the reason the seam wraps the asset check at all: asking
    /// "is this model installed" reserves the locale it asks about.
    ///
    /// Both halves are asserted because both are load-bearing. That the check costs a slot is what
    /// `importReservationBudget` leaves a spare one for; that an unanswerable check reads `false` is
    /// what makes `assetsInstalled` safe to use as a skip decision, since "cannot tell" and "not
    /// installed" belong on the same branch and the branch that does less is the safe one.
    @Test("Asking whether a model is installed costs a reservation, and cannot answer when full")
    func theInstallationCheckTakesASlot() async throws {
        let french = try await Self.canonical("fr-FR")

        let spare = FakeReservations(slots: 5, held: ["en_US"])
        #expect(await SpeechEngine.assetsInstalled(
            module: .dictation,
            locale: Locale(identifier: french),
            reservations: spare
        ))
        #expect(
            spare.heldIdentifiers == ["en_US", french],
            "the check answered without taking the slot RECON measured it taking"
        )

        let full = FakeReservations(
            slots: 5,
            held: ["en_US", "id_ID", "de_DE", "ja_JP", "es_ES"]
        )
        #expect(await SpeechEngine.assetsInstalled(
            module: .dictation,
            locale: Locale(identifier: french),
            reservations: full
        ) == false, """
            a check that could not run answered "installed", which as a skip decision is the wrong \
            way round: it is what sends a caller into the branch that starts a real download
            """)
        #expect(full.heldIdentifiers.count == 5)
    }

    // MARK: The prune

    /// An empty keep set means "nothing is prepared yet", never "keep nothing".
    ///
    /// Falsifiable by deleting one line: without the `guard !keep.isEmpty` in `pruneReservations`, a
    /// prune before either language is prepared releases every slot the inventory holds — including
    /// the ones a *concurrently running copy of the app* is using, since the five are shared per
    /// bundle identifier.
    @Test("Pruning with an empty keep set releases nothing")
    func pruneWithAnEmptyKeepSetReleasesNothing() async throws {
        let fake = FakeReservations(slots: 5, held: ["en_US", "id_ID", "fr_FR"])
        let engine = SpeechEngine(reservations: fake)

        let released = await engine.pruneReservations()

        #expect(released.isEmpty, "an unprepared engine released \(released)")
        #expect(fake.heldIdentifiers == ["en_US", "id_ID", "fr_FR"])
    }

    /// Two languages prepared, prune, exactly two slots held.
    ///
    /// This replaces the assertion the two gated suites used to close on.
    /// `#expect(reserved.count <= 5)` cannot fail — the framework throws at six and `reserve` catches
    /// the throw and evicts, so the count is five or fewer by construction, including in the state it
    /// was written to rule out, where Edict has permanently leaked all five slots. Naming the exact
    /// set after a prune is what turns "did not exceed the cap" into "is not holding anything it
    /// cannot justify". `SecondaryLocaleEngineTests` now makes the same claim against the real
    /// framework; this one makes it on every machine.
    @Test("A prune after preparing both languages leaves exactly those two")
    func pruneLeavesExactlyThePreparedLanguages() async throws {
        let fake = FakeReservations(slots: 5, held: ["fr_FR", "de_DE", "ja_JP"])
        let engine = SpeechEngine(reservations: fake)

        try await engine.prepare(localeIdentifier: "en-US")
        try await engine.prepareSecondary(localeIdentifier: "id-ID")
        let english = try await Self.canonical("en-US")
        let indonesian = try await Self.canonical("id-ID")

        let released = await engine.pruneReservations()

        #expect(Set(released) == ["fr_FR", "de_DE", "ja_JP"])
        #expect(fake.heldIdentifiers == [english, indonesian])
        #expect(fake.refusedReleases == 0, """
            a release was refused: the prune handed back a rebuilt Locale rather than one taken from \
            reservedLocales, which RECON §6 measured as a silent permanent leak
            """)
    }

    // MARK: The id-ID vs id_ID trap

    /// The trap itself, on the double. A regression guard on `FakeReservations`, not on the app —
    /// labelled as one, because it is what every assertion above about `refusedReleases` depends on.
    @Test("A rebuilt Locale releases nothing and the slot stays held")
    func aRebuiltLocaleCannotRelease() async throws {
        let fake = FakeReservations(slots: 5, held: ["id_ID"])

        // The hyphenated form is the one Edict's own settings hold, which is what makes this the
        // trap and not a curiosity. `Locale(identifier:)` normalises case but not the separator —
        // measured: "ID_id" comes back "id_ID" while "ID-ID" comes back "id-ID" — so a hyphen is
        // the whole difference, and a bare language subtag stays bare.
        #expect(await fake.release(reservedLocale: Locale(identifier: "id-ID")) == false)
        #expect(await fake.release(reservedLocale: Locale(identifier: "id")) == false)
        #expect(fake.heldIdentifiers == ["id_ID"], "the slot was released by a non-matching spelling")
        #expect(fake.refusedReleases == 2)

        // And the one form that does match, so the fake is not simply refusing everything.
        let stored = try #require(await fake.reservedLocales.first)
        #expect(await fake.release(reservedLocale: stored) == true)
        #expect(fake.heldIdentifiers.isEmpty)
    }

    /// The production half of the same trap: `clearSecondary` releases for real.
    ///
    /// One thing measured while proving this test, worth writing down because it narrows the trap.
    /// Rebuilding the `Locale` from `secondaryLocale.identifier` — the obvious "simplification" of
    /// the loop over `reservedLocales` — does **not** break: that identifier is already the
    /// framework's canonical `"id_ID"`, and `Locale(identifier:)` round-trips it unchanged, so this
    /// test passes against that edit and is not evidence about it. What it does catch is the edit
    /// that reaches for the *settings* spelling: releasing `Locale(identifier: "id-ID")` leaves
    /// `id_ID` held for every future launch of the app, and nothing else in the suite would notice.
    /// Verified by mutation: the hyphenated form fails this test on `refusedReleases`, the canonical
    /// rebuild does not.
    @Test("Turning the language shortcut off actually releases its slot")
    func clearSecondaryReleasesTheSlotItHolds() async throws {
        let fake = FakeReservations(slots: 5)
        let engine = SpeechEngine(reservations: fake)

        try await engine.prepareSecondary(localeIdentifier: "id-ID")
        let indonesian = try await Self.canonical("id-ID")
        #expect(fake.heldIdentifiers == [indonesian])

        await engine.clearSecondary()

        #expect(fake.heldIdentifiers.isEmpty, """
            the reservation survived clearSecondary — which is a slot lost for every future launch, \
            since reservations persist keyed to the bundle identifier (RECON §6)
            """)
        #expect(fake.refusedReleases == 0)
    }
}

// MARK: - The gated reservation tests, ported

/// `EngineReservationRecoveryTests` without the gate.
///
/// Every test here is the same claim as its namesake in that suite, driven through the same
/// production entry points, with `FakeReservations` in place of `AssetInventory`. The gated suite is
/// still the only place the framework's own behaviour is checked; this is the place the *app's*
/// behaviour is checked, on every machine and every run — which is what the originals could not be,
/// and why two of the three bugs they were written for shipped underneath them.
@Suite("The reservation ladder — import passes")
struct ImportPassReservationTests {

    private static func canonical(_ identifier: String) async throws -> String {
        try #require(
            await DictationTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: identifier)
            )?.identifier,
            "\(identifier) is not one of the locales DictationTranscriber covers on this machine"
        )
    }

    /// Both dictation languages prepared, which is what makes the import budget 2 — the production
    /// shape, and the one a dual pass depends on.
    private static func preparedEngine(_ fake: FakeReservations) async throws -> SpeechEngine {
        let engine = SpeechEngine(reservations: fake)
        try await engine.prepare(localeIdentifier: "en-US")
        try await engine.prepareSecondary(localeIdentifier: "id-ID")
        return engine
    }

    /// The headline of finding #7, now reachable ungated. `pruneReservations()` runs from
    /// `prepareSecondary()`, which `settingsChanged()` calls — so importing a file and then touching
    /// the language picker was enough to release the reservation behind the import's own model, while
    /// `importPasses` went on memoising it as `.ready`.
    @Test("Pruning keeps the reservation an import pass is still using")
    func pruneKeepsImportPassLocales() async throws {
        let fake = FakeReservations(slots: 5)
        let engine = try await Self.preparedEngine(fake)

        let resolution = await engine.resolveImportPass(
            preferGeneral: false,
            localeIdentifier: "de-DE"
        )
        let pass = try #require(resolution.pass, "de-DE did not resolve: \(resolution.reason ?? "")")
        let german = try await Self.canonical("de-DE")
        #expect(pass.canonicalIdentifier == german)
        #expect(fake.heldIdentifiers.contains(german))

        let released = await engine.pruneReservations()

        #expect(!released.contains(german), "the prune released the import pass's own locale")
        #expect(fake.heldIdentifiers.contains(german))
        // And the memo still means something: the pass resolves from cache against a locale that is
        // still reserved. The state ruled out is a `.ready` memo on an unreserved locale, which the
        // framework logs as "will be an error in a future release" and today still transcribes —
        // precisely why nothing would notice.
        #expect(await engine.resolveImportPass(
            preferGeneral: false,
            localeIdentifier: "de-DE"
        ).pass?.canonicalIdentifier == german)
    }

    /// Turning the language shortcut off must not release a slot an import is using: the user who
    /// dictates in a second language is the same user who imports files in it.
    @Test("Turning the language shortcut off keeps a reservation an import still needs")
    func clearSecondaryKeepsAnImportPassLocale() async throws {
        let fake = FakeReservations(slots: 5)
        let engine = SpeechEngine(reservations: fake)
        try await engine.prepare(localeIdentifier: "en-US")
        // The same language as the import, which is the case that matters.
        try await engine.prepareSecondary(localeIdentifier: "de-DE")
        let german = try await Self.canonical("de-DE")

        let resolution = await engine.resolveImportPass(
            preferGeneral: false,
            localeIdentifier: "de-DE"
        )
        #expect(resolution.pass?.canonicalIdentifier == german)

        await engine.clearSecondary()

        #expect(
            fake.heldIdentifiers.contains(german),
            "clearing the secondary language released the import's reservation"
        )
    }

    /// The other half of finding #7: nothing ever pruned the import reservations, so every import
    /// language ever resolved held one of the five slots for the life of the process — and beyond,
    /// because reservations persist. A later language then met a Code=11 whose eviction ladder had
    /// nothing left it was allowed to evict.
    ///
    /// This is the test the `if false, importPassOrder.count > budget {` stub would fail. It could
    /// not fail then, because it did not exist outside a suite that cannot run here.
    @Test("A third import language evicts the least recently used one, memo and reservation together")
    func importReservationsAreEvictedLeastRecentlyUsed() async throws {
        let fake = FakeReservations(slots: 5)
        let engine = try await Self.preparedEngine(fake)

        let requested = ["de-DE", "fr-FR", "ja-JP"]
        var canonical: [String: String] = [:]
        for identifier in requested {
            let resolution = await engine.resolveImportPass(
                preferGeneral: false,
                localeIdentifier: identifier
            )
            canonical[identifier] = try #require(
                resolution.pass?.canonicalIdentifier,
                "\(identifier) did not resolve: \(resolution.reason ?? "")"
            )
        }

        let oldest = try #require(canonical["de-DE"])
        let middle = try #require(canonical["fr-FR"])
        let newest = try #require(canonical["ja-JP"])
        let english = try await Self.canonical("en-US")
        let indonesian = try await Self.canonical("id-ID")

        #expect(fake.heldIdentifiers == [english, indonesian, middle, newest], """
            the least recently used import language was never released — every language ever imported \
            held a slot for the life of the process and beyond: \(fake.heldIdentifiers.sorted())
            """)
        #expect(!fake.heldIdentifiers.contains(oldest))
        #expect(fake.reserveFailures == 0, "the budget is meant to prevent Code=11, not survive it")

        // Asking for the evicted language again re-resolves and re-reserves it, at the cost of the
        // next-oldest — the trade, and a cheap one: resolution is a reservation and an asset check,
        // not a download.
        #expect(await engine.resolveImportPass(
            preferGeneral: false,
            localeIdentifier: "de-DE"
        ).pass != nil)
        #expect(fake.heldIdentifiers == [english, indonesian, newest, oldest])
        #expect(!fake.heldIdentifiers.contains(middle))
    }

    /// A memo may never outlive its reservation. The eviction drops both in one step, and the
    /// re-resolution proves the memo went with the slot rather than surviving it as a `.ready` lie.
    @Test("An evicted import language is re-resolved rather than served from a stale memo")
    func anEvictedMemoIsGoneWithItsReservation() async throws {
        let fake = FakeReservations(slots: 5)
        let engine = try await Self.preparedEngine(fake)

        for identifier in ["de-DE", "fr-FR", "ja-JP"] {
            _ = await engine.resolveImportPass(preferGeneral: false, localeIdentifier: identifier)
        }
        let german = try await Self.canonical("de-DE")
        #expect(!fake.heldIdentifiers.contains(german))

        // A cached hit costs no asset check; a re-resolution costs one. That is how the test can tell
        // which happened without reaching into the actor's private memo.
        let before = fake.installationChecks
        _ = await engine.resolveImportPass(preferGeneral: false, localeIdentifier: "de-DE")
        #expect(fake.installationChecks > before, """
            de-DE came back from a memo whose reservation had already been released — an unreserved \
            module the framework still transcribes while logging "will be an error in a future \
            release", which is exactly why nothing would notice
            """)
        #expect(fake.heldIdentifiers.contains(german))
    }

    /// The module choice is per language, and the general module is preferred where it covers one.
    ///
    /// The expectation is derived from `SpeechTranscriber.supportedLocales` rather than written down,
    /// because which 45 locales it covers is a property of the OS and not of this test.
    @Test("An import pass prefers the general module where that module covers the language")
    func generalModuleIsPreferredWhereItCovers() async throws {
        let fake = FakeReservations(slots: 5)
        let engine = try await Self.preparedEngine(fake)

        let generalCovers = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "de-DE")
        ) != nil
        let resolution = await engine.resolveImportPass(
            preferGeneral: true,
            localeIdentifier: "de-DE"
        )
        let pass = try #require(resolution.pass, "de-DE did not resolve: \(resolution.reason ?? "")")

        #expect(pass.module == (generalCovers ? .general : .dictation))
        // Indonesian is in the gap between the two modules' locale sets, so it can only ever be the
        // dictation module — the fallback that stops `resolveImportPass` refusing 9 languages.
        #expect(await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: "id-ID")
        ) == nil)
        let indonesian = await engine.resolveImportPass(
            preferGeneral: true,
            localeIdentifier: "id-ID"
        )
        #expect(indonesian.pass?.module == .dictation)
    }

    /// A missing model reports the download rather than substituting a language, and its slot is held
    /// for as long as the download is running.
    ///
    /// Substituting is the failure this refuses: transcribing Indonesian with the English model does
    /// not fail, it returns fluent English proper nouns, and a real 70-minute meeting was read to the
    /// end before anyone suspected the cause.
    @Test("A missing model downloads under its own language and keeps its slot while it does")
    func aMissingModelKeepsItsSlotWhileItDownloads() async throws {
        let fake = FakeReservations(
            slots: 5,
            missing: [FakeReservations.key(.dictation, "fr-FR")],
            install: .neverFinishes
        )
        let engine = try await Self.preparedEngine(fake)

        let resolution = await engine.resolveImportPass(
            preferGeneral: false,
            localeIdentifier: "fr-FR"
        )
        let french = try await Self.canonical("fr-FR")

        #expect(resolution.pass == nil, "a language with no model on disk resolved to a pass")
        #expect(
            resolution.reason?.contains("Downloading") == true,
            "\(resolution.reason ?? "no reason")"
        )
        #expect(fake.heldIdentifiers.contains(french))

        // The prune must not take the slot back out from under the running download. Nothing has
        // measured what releasing a locale mid-`downloadAndInstall()` does, and the cost of being
        // wrong is a model that never arrives.
        let released = await engine.pruneReservations()
        #expect(!released.contains(french))
        #expect(fake.heldIdentifiers.contains(french))
    }
}
