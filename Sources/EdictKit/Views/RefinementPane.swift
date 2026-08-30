//
//  RefinementPane.swift
//  The surface for the on-device refinement: three keys under a transcript, and the well the result
//  lands in.
//
//  THE ONE RULE THIS FILE OBEYS
//
//  **The refined text never replaces the transcript.** It appears in a second well, below the first,
//  labelled with which of the three things was done to it. The transcript is the record of what a
//  person said out loud; a refinement is a reading of that record. An app that quietly swapped one
//  for the other would still look correct — which is exactly what makes it the worst available
//  failure, because the user would find out days later with no copy of the original anywhere.
//
//  WHY THE KEYS ARE NOT DISABLED WHEN THE LOCALE IS "UNSUPPORTED"
//
//  `SystemLanguageModel.default.supportsLocale(id_ID)` returns **false** on this machine, and
//  Indonesian clean-up works anyway. The project's earlier probe measured a vocabulary upgrade
//  ("mundurkan" → "menunda", "libatkan" → "melibatkan"); re-measured from this file's own fixture at
//  1.05–1.24 s it was more conservative — it kept both words and repaired sentence case, proper nouns
//  and punctuation instead. Both readings say the same thing about the switch: `supportsLocale ==
//  false` is Apple declining to make a promise, not Apple predicting a failure, and the *quality* of
//  what comes back is genuinely not guaranteed.
//
//  Refusing the feature on it would withhold something that works; hiding the caveat would leave an
//  uneven result looking like a bug in Edict. So the keys stay live and a sentence beside the result
//  says there is no guarantee and that nothing was translated.
//
//  WHAT IS NOT HERE
//
//  A keyboard shortcut. ⌥ is dictate and ⇧⌥ is the second language, and RECON §8 established that
//  the only unclaimed modifiers on this machine are `right_option` (taken) and `right_control`
//  (absent from the keyboard). There is no third chord to invent, so these are keys you click.
//

import SwiftUI

// MARK: - RefinementStore

/// The view-facing state of the refinement feature: one `TextRefiner`, its cached availability, and
/// the results and failures the history pane is currently showing.
///
/// **Results are held in memory and never written to disk.** A refinement of a stored transcript
/// costs about a second to ask for again, and persisting every one the user glanced at would grow
/// the history file with derived text nobody decided to keep. The one refinement that *is* stored is
/// the one that went into a document — that is a fact about what happened, and it lives on
/// `Transcript.refinement` (see `RefinementRecord`).
///
/// Keyed by transcript id rather than held as `@State` in the detail view because that view is
/// rebuilt with `.id(transcript.id)` on every selection change: local state would throw away a
/// result the moment the user clicked another row to compare, and would abandon a generation that
/// was already a second into its work.
@MainActor @Observable
public final class RefinementStore {

    /// Shared, so `DictationController`'s refine-before-insert path and the history pane use the same
    /// actor and therefore the same pre-warmed sessions. Two refiners would mean two cold starts.
    @ObservationIgnored public let refiner: TextRefiner

    /// Availability is a question about the *model plus a locale*, so it is cached per locale rather
    /// than once: `en-US` is supported here and `id-ID` is not, and a single cached answer would
    /// caption one of them wrongly.
    private var availabilityByLocale: [String: RefinerAvailability] = [:]

    private var resultsByTranscript: [UUID: RefinementResult] = [:]
    private var failuresByTranscript: [UUID: String] = [:]
    private var runningByTranscript: [UUID: RefinementAction] = [:]

    private var didPrewarm = false

    public init(refiner: TextRefiner = TextRefiner()) {
        self.refiner = refiner
    }

    // MARK: Reading

    /// The cached answer for `localeIdentifier`, or `nil` before ``refresh(for:)`` has run once.
    ///
    /// `nil` is a real state and the view shows it as such: it means "not asked yet", and printing
    /// "unavailable" during the one frame before the actor answers would flash a false claim.
    public func availability(for localeIdentifier: String) -> RefinerAvailability? {
        availabilityByLocale[localeIdentifier]
    }

    public func result(for id: UUID) -> RefinementResult? { resultsByTranscript[id] }
    public func failure(for id: UUID) -> String? { failuresByTranscript[id] }
    public func running(for id: UUID) -> RefinementAction? { runningByTranscript[id] }

    // MARK: Preparing

    /// Cache availability for `localeIdentifier` and pay the model's cold-start cost once.
    ///
    /// Called from the detail block's `.task`, so nothing here happens until a user has actually
    /// looked at a transcript. Idempotent and cheap to call again — `prewarm()` is guarded on the
    /// actor and the availability read is a property access on `SystemLanguageModel`.
    public func refresh(for localeIdentifier: String) async {
        let answer = await refiner.availability(for: localeIdentifier)
        availabilityByLocale[localeIdentifier] = answer
        guard !didPrewarm else { return }
        didPrewarm = true
        // Only worth doing when the model can actually run: `prewarm()` returns immediately
        // otherwise, but asking for it on an ineligible Mac every time a row is opened is work done
        // on spec.
        if case .unavailable = answer { return }
        await refiner.prewarm()
    }

    // MARK: Refining

    /// Refine `transcript` and keep the outcome for the pane to draw.
    ///
    /// Returns what to print on the key that was pressed, or `nil` for a cancellation — the one
    /// outcome a key must stay quiet about, because the user is the one who caused it.
    ///
    /// The *sentence* always lands in the well below; the key gets a word or a duration. That split
    /// is deliberate: `ReportingButton` prints on a key cap, and a cap is not the place for
    /// "The on-device model declined to work on this text."
    public func refine(_ transcript: Transcript, as action: RefinementAction) async -> ActionReport? {
        let id = transcript.id
        // One generation per transcript at a time. `TextRefiner` keeps a session per action and would
        // run two happily, but `GenerationError.concurrentRequests` exists and two refinements of the
        // same text racing to fill one well is not a thing a user asked for.
        guard runningByTranscript[id] == nil else { return .failed("Busy") }
        runningByTranscript[id] = action
        defer { runningByTranscript[id] = nil }

        // Cleared up front: while a new refinement is running, a stale result or an old error message
        // sitting in the well is a claim about text that is being replaced.
        resultsByTranscript[id] = nil
        failuresByTranscript[id] = nil

        do {
            let result = try await refiner.refine(
                transcript.text,
                as: action,
                localeIdentifier: transcript.localeIdentifier
            )
            resultsByTranscript[id] = result
            // The duration, not "Done". It is the honest report of what the key just cost, it is the
            // number the settings copy is making a claim about, and it differs by 3x between a cold
            // and a warm model — so it is the one word here worth printing.
            return .done(Self.seconds(result.duration))
        } catch is CancellationError {
            return nil
        } catch {
            failuresByTranscript[id] = Self.sentence(for: error)
            return .failed(Self.cap(for: error))
        }
    }

    /// Forget the result and any error for `id`. Called when a transcript is deleted, so a result
    /// cannot outlive the transcript it describes.
    public func forget(_ id: UUID) {
        resultsByTranscript[id] = nil
        failuresByTranscript[id] = nil
    }

    // MARK: Render seam

    /// Plant a finished result without a model, for the offscreen proof sheets. RECON §40: UI cannot
    /// be photographed from an automated run, so the only way to prove this block draws correctly is
    /// to render it offline with a result already in place.
    func seedForRender(_ id: UUID, result: RefinementResult) {
        resultsByTranscript[id] = result
    }

    /// The same seam for the failure path, which is otherwise reachable only by finding a transcript
    /// the guardrails object to.
    func seedForRender(_ id: UUID, failure: String) {
        failuresByTranscript[id] = failure
    }

    func seedForRender(_ locale: String, availability: RefinerAvailability) {
        availabilityByLocale[locale] = availability
    }

    // MARK: Strings

    /// `"1.0 s"`. One decimal, because the difference that matters to the user is 1 s versus 3 s and
    /// the second decimal is noise on a number that varies with how warm the model daemon is.
    static func seconds(_ duration: TimeInterval) -> String {
        String(format: "%.1f s", max(0, duration))
    }

    /// One or two words for a key cap. The explanation goes in the well, not here.
    static func cap(for error: any Error) -> String {
        guard let failure = error as? RefinementFailure else { return "Failed" }
        switch failure {
        case .nothingToRefine: return "Empty"
        case .modelUnavailable: return "No model"
        case .tooLong: return "Too long"
        case .declined: return "Declined"
        case .failed: return "Failed"
        }
    }

    /// The sentence for the well. `RefinementFailure` already writes screen-ready copy for every
    /// case, so this only has to cover the impossible one rather than paraphrase the possible ones.
    static func sentence(for error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription
            ?? "Refinement could not run. Your transcript is unchanged."
    }
}

// MARK: - RefinementBlock

/// CLEAN UP / BULLETS / SUMMARY, and the well their result lands in.
///
/// Sits inside the existing transcript panel rather than in a panel of its own: it acts on the text
/// in the well above it, and a separate panel would put a milled edge between a control and the
/// thing it controls.
struct RefinementBlock: View {

    let transcript: Transcript
    let store: RefinementStore

    /// See `HistoryPane.unbounded`. True only in the offscreen render harness, where there is no
    /// model to await and the availability probe must not run.
    var unbounded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: D.space.sm) {
            SeamDivider(.horizontal)

            SilkscreenLabel("Refine", weight: .tiny)
                .silkscreenDecorative()

            Text(Self.intro)
                .typeStyle(D.type.explain)
                .foregroundStyle(D.color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let sentence = unavailableSentence { notice(sentence) }

            keys

            if let result = store.result(for: transcript.id) {
                resultBlock(result)
            } else if let failure = store.failure(for: transcript.id) {
                notice(failure)
            }

            // Placed after the result on purpose: this is the sentence that has to be read *beside*
            // an uneven output, and before there is one it is equally correct as a warning about what
            // the keys above will do.
            if showsUnsupportedLocale { unsupportedLocaleNotice }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Refine")
        // Keyed on the locale so a different transcript's language re-asks the question rather than
        // captioning `id-ID` with the answer cached for `en-US`.
        .task(id: taskKey) {
            guard !unbounded else { return }
            await store.refresh(for: transcript.localeIdentifier)
        }
    }

    /// One identity for the `.task`: the locale decides the answer, and the transcript decides
    /// nothing here — but re-running on a new row is free and keeps a stale `nil` from persisting.
    private var taskKey: String { "\(transcript.id)|\(transcript.localeIdentifier)" }

    static let intro = """
        Rewrite what you said using Apple's on-device model. It runs on this Mac, nothing is sent \
        anywhere, and the transcript above is never changed.
        """

    // MARK: Keys

    private var keys: some View {
        HStack(spacing: D.space.sm) {
            ForEach(RefinementAction.allCases) { action in
                ReportingButton(
                    action.title,
                    // The longest legend any of these three keys can show is a reported one, not its
                    // own name, so every cap reserves the same width and the row never twitches.
                    template: Self.capTemplate,
                    minWidth: Self.keyWidth
                ) {
                    await store.refine(transcript, as: action)
                }
                .disabled(isDisabled)
                .help(action.explanation)
            }
            Spacer(minLength: D.space.xs)
        }
    }

    /// Wide enough for `"Declined"` at `D.type.buttonCap`, which is the longest thing printed here.
    private static let capTemplate = "Declined"
    private static let keyWidth = D.size.buttonHeight * 3.4

    /// Disabled while this transcript already has a generation in flight, and when the model cannot
    /// run at all — in which case the sentence above says why, so the key is explained rather than
    /// merely dead.
    private var isDisabled: Bool {
        if store.running(for: transcript.id) != nil { return true }
        if case .unavailable = store.availability(for: transcript.localeIdentifier) { return true }
        return transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var unavailableSentence: String? {
        guard case .unavailable(let why) = store.availability(for: transcript.localeIdentifier) else {
            return nil
        }
        return why
    }

    // MARK: Result

    private func resultBlock(_ result: RefinementResult) -> some View {
        VStack(alignment: .leading, spacing: D.space.labelGap) {
            HStack(spacing: D.space.sm) {
                SilkscreenLabel(Self.resultLabel(result.action), weight: .tiny)
                    .silkscreenDecorative()
                Spacer(minLength: D.space.xs)
                Text(Self.caption(for: result))
                    .typeStyle(D.type.caption)
                    .foregroundStyle(D.color.textSecondary)
                    .lineLimit(1)
                    .help(Self.caption(for: result))
                ReportingButton("Copy", template: "Copied") {
                    ViewClipboard.put(result.text)
                    return .done("Copied")
                }
                .accessibilityLabel("Copy the refined text")
            }
            RecessedWell(fill: .list) {
                Text(result.text)
                    .typeStyle(D.type.body)
                    .foregroundStyle(D.color.textPrimary)
                    .textSelection(.enabled)
                    // No line limit, unlike the transcript well above it. That well is a reminder of
                    // text the user has already read; this is the thing they pressed a key to see, and
                    // a bullet list truncated at four lines would hide the points it was asked for.
                    // The detail block is inside a scroll view, which is where a long one belongs.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.resultLabel(result.action))
        .accessibilityValue(result.text)
    }

    /// The heading over the result well. Past tense, and never the key's own legend: "CLEAN UP" over
    /// a filled well reads as a second button.
    static func resultLabel(_ action: RefinementAction) -> String {
        switch action {
        case .cleanUp: "Cleaned up"
        case .bullets: "As points"
        case .summarise: "Summary"
        }
    }

    /// `"Indonesian (Indonesia) · 1.2 s"`. The language is first because it is the fact that changes
    /// how much the output can be trusted.
    static func caption(for result: RefinementResult) -> String {
        LocaleNames.display(result.localeIdentifier)
            + " · " + RefinementStore.seconds(result.duration)
    }

    // MARK: Notices

    /// Alert ink and a hollow square, the same shape vocabulary `TranscriptDetail` already spends on
    /// "may be incomplete". A refinement that did not happen is a statement about this block, not a
    /// fault in the transcript, so it never touches the transcript's own wells.
    private func notice(_ sentence: String) -> some View {
        HStack(alignment: .top, spacing: D.space.sm) {
            Rectangle()
                .strokeBorder(D.color.alert, lineWidth: D.border.thin)
                .frame(width: D.size.troughHeight, height: D.size.troughHeight)
                .padding(.top, D.space.xs)
                .accessibilityHidden(true)
            Text(sentence)
                .typeStyle(D.type.explain)
                .foregroundStyle(D.color.alert)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// True when Apple does not list this transcript's language — either measured just now, or
    /// recorded on the result that is already on screen.
    private var showsUnsupportedLocale: Bool {
        if let result = store.result(for: transcript.id) { return result.wasLocaleUnsupported }
        if case .localeUnsupported = store.availability(for: transcript.localeIdentifier) { return true }
        return false
    }

    /// Secondary ink, not alert. This is the Indonesian case, and Indonesian measured excellent —
    /// painting it as a warning would tell the user their good output is a problem. What they need is
    /// the fact that there is no guarantee and that nothing was translated.
    private var unsupportedLocaleNotice: some View {
        Text(Self.unsupportedSentence(for: transcript.localeIdentifier))
            .typeStyle(D.type.explain)
            .foregroundStyle(D.color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Written here rather than taken from `RefinerAvailability.localeUnsupported`, because that
    /// string is also used before a result exists and this one has to read correctly *beside* one.
    static func unsupportedSentence(for localeIdentifier: String) -> String {
        "Apple does not list \(LocaleNames.display(localeIdentifier)) as supported by its on-device "
            + "model, so a result in this language carries no guarantees — it may read unevenly, or "
            + "the model may decline it. It is never translated: refinement always answers in the "
            + "language you dictated."
    }
}

// MARK: - InsertedRefinement

/// What refinement did to a dictation *before* it reached the cursor, for a transcript that has one.
///
/// A separate view from `RefinementBlock` because it is a different kind of statement. That block is
/// a control the user is operating now; this is a record of something that already happened to a
/// document, and it must be legible without any model being available — the machine it is read on
/// may not be the machine it was refined on, and the model may have been turned off since.
struct InsertedRefinement: View {

    let record: RefinementRecord

    var body: some View {
        VStack(alignment: .leading, spacing: D.space.labelGap) {
            if let text = record.text, !text.isEmpty {
                HStack(spacing: D.space.sm) {
                    SilkscreenLabel("Inserted", weight: .tiny)
                        .silkscreenDecorative()
                    Spacer(minLength: D.space.xs)
                    Text(caption)
                        .typeStyle(D.type.caption)
                        .foregroundStyle(D.color.textSecondary)
                        .lineLimit(1)
                        .help(caption)
                    ReportingButton("Copy", template: "Copied") {
                        ViewClipboard.put(text)
                        return .done("Copied")
                    }
                    .accessibilityLabel("Copy the inserted text")
                }
                RecessedWell(fill: .list) {
                    Text(text)
                        .typeStyle(D.type.body)
                        .foregroundStyle(D.color.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                if record.localeUnsupported {
                    Text(RefinementBlock.unsupportedSentence(for: record.localeIdentifier))
                        .typeStyle(D.type.explain)
                        .foregroundStyle(D.color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let failure = record.failure {
                // The dictation still landed — that is the point of saying this rather than staying
                // quiet. Without the sentence the user sees unrefined text from a switch they turned
                // on and concludes the switch does nothing.
                HStack(alignment: .top, spacing: D.space.sm) {
                    Rectangle()
                        .strokeBorder(D.color.alert, lineWidth: D.border.thin)
                        .frame(width: D.size.troughHeight, height: D.size.troughHeight)
                        .padding(.top, D.space.xs)
                        .accessibilityHidden(true)
                    Text("Clean-up before inserting did not run, so what you said was inserted "
                         + "unchanged. \(failure)")
                        .typeStyle(D.type.explain)
                        .foregroundStyle(D.color.alert)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var caption: String {
        RefinementBlock.resultLabel(record.action)
            + " · " + LocaleNames.display(record.localeIdentifier)
            + " · " + RefinementStore.seconds(record.duration)
    }
}

// Everything below here is preview and render-harness scaffolding, and it is behind `#if DEBUG` for
// one reason: the fixture enums are `public` so an out-of-tree render harness can link them, which
// also means they cannot be dead-stripped. They were 588 symbols of the shipped binary. The `#Preview`
// blocks are gated with them because they reference the fixtures — gating a fixture enum on its own
// stops the file compiling in release, which is why all six files had to change together.
//
// Tests and the render harness both build the library in debug, so every reference in Tests/ keeps
// working. Nothing here has any behavioural effect on the app.
#if DEBUG
// MARK: - Render fixtures

/// Sheets for the offscreen renderer, covering the three states of this block that a live run cannot
/// be relied on to produce: a finished result, a guardrail refusal, and an ineligible Mac.
///
/// A parallel of `RecoveryFixtures` and `DualPassFixtures` rather than an addition to `PreviewFixtures`,
/// for the same reason those are — `MainWindow.swift` is not this agent's file to edit.
///
/// **The refined strings here are the real measured outputs**, produced by
/// `RefinementSurfaceModelTests` against `TextRefiner` on this machine (0.84–1.18 s per action). They
/// are pasted verbatim, including where the model was more conservative than the brief expected: it
/// kept the colloquial "bit" in English and kept "mundurkan" and "libatkan" in Indonesian rather than
/// upgrading them, repairing punctuation, sentence case and proper nouns instead. A fixture that
/// showed a better result than the code produces would be the one kind of dishonesty a proof sheet
/// can commit.
///
/// The Indonesian pair is the finding worth keeping visible: `supportsLocale(id_ID)` is **false** and
/// the output is nonetheless correct Indonesian — "Kamis", "Pak Mark" and "Rabu" capitalised, commas
/// and a full stop added, not one word translated.
@MainActor
public enum RefinementFixtures {

    public static let englishDictation = """
        so um i think we should like move the meeting to thursday because uh mark is out on \
        wednesday and we need him for the the budget bit you know
        """

    public static let englishCleanUp = """
        So I think we should move the meeting to Thursday because Mark is out on Wednesday and we \
        need him for the budget bit.
        """

    public static let indonesianDictation = """
        jadi eh saya mau mundurkan rapatnya ke hari kamis karena pak mark tidak ada hari rabu dan \
        kita perlu libatkan dia untuk bagian anggaran
        """

    public static let indonesianCleanUp = """
        Jadi, saya mau mundurkan rapatnya ke hari Kamis karena Pak Mark tidak ada hari Rabu dan \
        kita perlu libatkan dia untuk bagian anggaran.
        """

    /// A history holding the two transcripts the fixtures refine, plus a third recorded while
    /// refine-before-insert was on, so the stored-record block has something to draw.
    ///
    /// The history file goes to a throwaway directory, never `AppPaths.historyFile`: RECON §39 is a
    /// verification run that wrote to the live store and took a user's transcripts down from thirty
    /// entries to two.
    public static func model() -> AppModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-refine-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let history = HistoryStore(fileURL: dir.appendingPathComponent("history.json"), limit: { 100 })
        history.append(english)
        history.append(indonesian)
        history.append(autoRefined)
        return AppModel(
            settings: Settings(defaults: EphemeralDefaults()),
            history: history,
            loginItem: LoginItem(service: nil)
        )
    }

    public static let english = Transcript(
        id: UUID(uuidString: "5E11EEFD-0000-4000-8000-000000000001")!,
        rawText: englishDictation,
        text: englishDictation,
        audioDuration: 11.2,
        transcribeDuration: 0.31,
        localeIdentifier: "en-US",
        targetBundleID: "com.apple.Notes",
        targetAppName: "Notes",
        injection: .accessibility
    )

    public static let indonesian = Transcript(
        id: UUID(uuidString: "5E11EEFD-0000-4000-8000-000000000002")!,
        rawText: indonesianDictation,
        text: indonesianDictation,
        audioDuration: 9.8,
        transcribeDuration: 0.28,
        localeIdentifier: "id-ID",
        targetBundleID: "com.apple.Notes",
        targetAppName: "Notes",
        injection: .accessibility
    )

    /// A dictation recorded with `Settings.refineBeforeInsert` on, so what went into the document is
    /// not the transcript. Both strings are the measured English pair above.
    public static let autoRefined = Transcript(
        id: UUID(uuidString: "5E11EEFD-0000-4000-8000-000000000003")!,
        rawText: englishDictation,
        text: englishDictation,
        audioDuration: 11.2,
        transcribeDuration: 0.31,
        localeIdentifier: "en-US",
        targetBundleID: "com.apple.Notes",
        targetAppName: "Notes",
        injection: .accessibility,
        refinement: RefinementRecord(
            action: .cleanUp,
            text: englishCleanUp,
            duration: 1.02,
            localeIdentifier: "en-US"
        )
    )

    /// A dictation whose refinement the model declined, which must show the sentence *and* the
    /// unrefined text that was inserted instead.
    public static let autoRefineDeclined = Transcript(
        id: UUID(uuidString: "5E11EEFD-0000-4000-8000-000000000004")!,
        rawText: englishDictation,
        text: englishDictation,
        audioDuration: 11.2,
        transcribeDuration: 0.31,
        localeIdentifier: "en-US",
        targetBundleID: "com.apple.Notes",
        targetAppName: "Notes",
        injection: .accessibility,
        refinement: RefinementRecord(
            action: .cleanUp,
            duration: 0.9,
            localeIdentifier: "en-US",
            failure: "The on-device model declined to work on this text. Your transcript is "
                + "unchanged — you can still copy it exactly as dictated."
        )
    )

    /// A model whose store already holds the measured English clean-up.
    public static func withEnglishResult() -> AppModel {
        let model = model()
        model.refinement.seedForRender("en-US", availability: .ready)
        model.refinement.seedForRender(english.id, result: RefinementResult(
            action: .cleanUp,
            text: englishCleanUp,
            duration: 1.02,
            localeIdentifier: "en-US",
            wasLocaleUnsupported: false
        ))
        return model
    }

    /// A model whose store holds the measured Indonesian clean-up, with the unsupported-locale flag
    /// set — the case the caption and the notice have to read correctly for.
    public static func withIndonesianResult() -> AppModel {
        let model = model()
        model.refinement.seedForRender(
            "id-ID",
            availability: .localeUnsupported(
                TextRefiner.unsupportedLocaleSentence(for: Locale(identifier: "id-ID"))
            )
        )
        model.refinement.seedForRender(indonesian.id, result: RefinementResult(
            action: .cleanUp,
            text: indonesianCleanUp,
            duration: 1.21,
            localeIdentifier: "id-ID",
            wasLocaleUnsupported: true
        ))
        return model
    }

    /// A guardrail refusal, which is not a bug and has to read as such.
    public static func withRefusal() -> AppModel {
        let model = model()
        model.refinement.seedForRender("en-US", availability: .ready)
        model.refinement.seedForRender(
            english.id,
            failure: RefinementFailure.declined(
                "The on-device model declined to work on this text. Your transcript is unchanged — "
                    + "you can still copy it exactly as dictated."
            ).errorDescription ?? ""
        )
        return model
    }

    /// A Mac that cannot run the model at all.
    public static func unavailable() -> AppModel {
        let model = model()
        model.refinement.seedForRender("en-US", availability: .unavailable(
            TextRefiner.unavailableSentence(for: .appleIntelligenceNotEnabled)
        ))
        return model
    }

    public static func renderSheets() -> [PreviewFixtures.RenderSheet] {
        let pane = CGSize(width: D.size.windowMin.width - D.size.railWidth, height: 760)
        let wide = CGSize(width: 1_240, height: 760)
        let block = CGSize(width: 620, height: 340)

        func sheet(_ id: String, _ size: CGSize, _ view: some View) -> PreviewFixtures.RenderSheet {
            PreviewFixtures.RenderSheet(
                id: id,
                size: size,
                view: AnyView(
                    view
                        .frame(width: size.width, height: size.height, alignment: .top)
                        .background(D.surface.deckPaint)
                )
            )
        }

        func history(_ model: AppModel, _ id: UUID, _ size: CGSize) -> some View {
            HistoryPane(model: model, initialSelection: id, unbounded: true)
                .frame(width: size.width, height: size.height, alignment: .top)
        }

        let inserted = model()

        return [
            // The two window widths the brief asks to be checked: the narrow default pane and a wide
            // one, both with a result on screen.
            sheet("refine-english-narrow", pane, history(withEnglishResult(), english.id, pane)),
            sheet("refine-english-wide", wide, history(withEnglishResult(), english.id, wide)),
            sheet("refine-indonesian", pane, history(withIndonesianResult(), indonesian.id, pane)),
            sheet("refine-declined", pane, history(withRefusal(), english.id, pane)),
            sheet("refine-unavailable", pane, history(unavailable(), english.id, pane)),
            sheet("refine-inserted", pane, history(inserted, autoRefined.id, pane)),
            // The keys alone, at rest and mid-report, so the cap widths can be checked without the
            // rest of the pane around them.
            sheet("refine-keys", block, keyBank()),
            // The switch, with the latency it costs printed on it. `RefineSection` is private, so
            // the whole settings column is the smallest thing that can render it.
            sheet("refine-settings", CGSize(width: 620, height: 1_900),
                  SettingsWindow(model: model(), unbounded: true)),
        ]
    }

    /// The key row frozen at rest and mid-report. `ReportingButton` prints a report handed to it at
    /// construction, so the dwell can be photographed rather than described.
    static func keyBank() -> some View {
        PanelSurface("Refine") {
            VStack(alignment: .leading, spacing: D.space.md) {
                HStack(spacing: D.space.sm) {
                    ForEach(RefinementAction.allCases) { action in
                        ReportingButton(action.title, template: "Declined",
                                        minWidth: D.size.buttonHeight * 3.4) { nil }
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: D.space.sm) {
                    ReportingButton("Clean up", template: "Declined",
                                    minWidth: D.size.buttonHeight * 3.4,
                                    report: .done("1.0 s")) { nil }
                    ReportingButton("Bullets", template: "Declined",
                                    minWidth: D.size.buttonHeight * 3.4,
                                    report: .failed("Declined")) { nil }
                    ReportingButton("Summary", template: "Declined",
                                    minWidth: D.size.buttonHeight * 3.4,
                                    report: .failed("Too long")) { nil }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(D.space.md)
    }
}

// MARK: - Previews

#Preview("Refine — English result") {
    HistoryPane(model: RefinementFixtures.withEnglishResult(),
                initialSelection: RefinementFixtures.english.id)
        .frame(width: 900, height: 700)
        .background(D.surface.deckPaint)
}

#Preview("Refine — Indonesian, locale unsupported") {
    HistoryPane(model: RefinementFixtures.withIndonesianResult(),
                initialSelection: RefinementFixtures.indonesian.id)
        .frame(width: 900, height: 700)
        .background(D.surface.deckPaint)
}

#Preview("Refine — declined") {
    HistoryPane(model: RefinementFixtures.withRefusal(),
                initialSelection: RefinementFixtures.english.id)
        .frame(width: 900, height: 700)
        .background(D.surface.deckPaint)
}

#Preview("Refine — model unavailable") {
    HistoryPane(model: RefinementFixtures.unavailable(),
                initialSelection: RefinementFixtures.english.id)
        .frame(width: 900, height: 700)
        .background(D.surface.deckPaint)
}

#Preview("Refine — keys") {
    RefinementFixtures.keyBank()
        .frame(width: 620)
        .background(D.surface.deckPaint)
}
#endif
