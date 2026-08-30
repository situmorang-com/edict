import AppKit
import CoreText
import Foundation
import Testing
@testable import EdictKit

// MARK: - The rule

/// Which dictation outcomes owe the user a sentence, and what that sentence is allowed to claim.
///
/// This is the whole of the fix behind `DictationNotice`, expressed where it can be tested. The
/// failure it exists to prevent has two halves and this suite covers the second of each: an outcome
/// that landed on the clipboard used to produce **no** report anywhere — `AppModel.lastOutcome` was
/// recorded and read by nothing — and the obvious repair, a cheerful "Done", would be worse than
/// silence, because a report that claims an insertion is the one thing that stops the user looking
/// for their words.
@Suite("Dictation notices — the rule")
struct DictationNoticeRuleTests {

    private func notice(
        _ outcome: InjectionOutcome,
        app: String? = "Ghostty",
        keptInHistory: Bool = false
    ) -> DictationNotice? {
        AppModel.notice(for: outcome, appName: app, keptInHistory: keptInHistory)
    }

    @Test("An outcome that landed says nothing at all")
    func successIsSilent() {
        // The three rungs of the ladder that reached the document. The text is where the user was
        // looking, so a panel telling them about it would be Edict interrupting a success.
        #expect(notice(.accessibility) == nil)
        #expect(notice(.paste) == nil)
        #expect(notice(.keystrokes) == nil)
    }

    @Test("A deliberate no-op says nothing either")
    func notAttemptedIsSilent() {
        // `.notAttempted` is three deliberate cases — dictated from Edict's own window, `autoInject`
        // switched off, or an empty transcript — and in none of them is the user waiting for text to
        // appear somewhere else. Reporting it would be the app inventing a problem.
        #expect(notice(.notAttempted) == nil)
    }

    @Test("Clipboard-only names the app, says where the words are, and how to paste them")
    func clipboardOnly() throws {
        let notice = try #require(self.notice(.clipboardOnly, app: "Ghostty"))
        #expect(notice.sentence.contains("Ghostty"))
        #expect(notice.sentence.contains("clipboard"))
        #expect(notice.sentence.contains("⌘V"))
        // The one thing it must never do. `TextInjector` ends at this rung precisely because nothing
        // reached the document.
        #expect(notice.sentence.contains("could not"))
    }

    @Test("With no recorded app name the sentence still reads as a sentence")
    func clipboardOnlyWithoutAnAppName() throws {
        // `Transcript.targetAppName` is optional and is nil for a dictation aimed at an application
        // that would not name itself. A sentence with a hole in it would look like a bug in Edict
        // rather than a report about the user's text.
        let notice = try #require(self.notice(.clipboardOnly, app: nil))
        #expect(!notice.sentence.contains("nil"))
        #expect(!notice.sentence.contains("  "))
        #expect(notice.sentence.contains("the app you were in"))
        #expect(notice.sentence.contains("⌘V"))
    }

    @Test("A total failure offers no paste, and names history only when the words are in it")
    func failed() throws {
        let lost = try #require(notice(.failed, keptInHistory: false))
        // `.failed` means even the clipboard write failed, so there is nothing to paste and the
        // sentence must not imply there is.
        #expect(!lost.sentence.contains("⌘V"))
        #expect(!lost.sentence.lowercased().contains("history"))

        let kept = try #require(notice(.failed, keptInHistory: true))
        #expect(kept.sentence.lowercased().contains("history"))
        #expect(!kept.sentence.contains("⌘V"))
        // The claim is only made when the caller has checked it. `AppModel.lastNotice` is what does
        // the checking; this is the half that cannot invent it.
        #expect(kept.sentence != lost.sentence)
    }

    @Test("Every outcome is either silent or fully legible, and none of them claims an insertion",
          arguments: InjectionOutcome.allCases)
    func everyOutcome(outcome: InjectionOutcome) {
        let notice = AppModel.notice(for: outcome, appName: "Notes", keptInHistory: true)
        guard let notice else {
            #expect(outcome.isSuccess || outcome == .notAttempted)
            return
        }
        #expect(!outcome.isSuccess, "a rung that landed is reporting a failure")
        #expect(!notice.label.isEmpty)
        // The status channel reserves the width of "Transcribing" and truncates anything longer
        // (`StatusReadout.reservedText`), so a label is two or three words or it is not a label.
        #expect(notice.label.count <= "Transcribing".count,
                "label too long for the status channel: \(notice.label)")
        #expect(notice.sentence.count > 20, "not a sentence: \(notice.sentence)")
        #expect(notice.sentence.hasSuffix("."))
        // Every failure sentence says what did not happen. This is the rule stated as an assertion:
        // no wording that could be read as "the text is in your document".
        #expect(notice.sentence.contains("could not"))
        for claim in ["Done", "Inserted", "inserted into", "successfully"] {
            #expect(!notice.sentence.contains(claim), "the sentence claims an outcome: \(claim)")
        }
    }
}

// MARK: - The arithmetic

/// That a notice actually fits the panel it is drawn in.
///
/// The HUD is a fixed 360×140 pt `NSPanel` and nothing inside it scrolls, wraps beyond its line limit
/// or scales, so "does this text fit" is arithmetic rather than an opinion — and it is arithmetic no
/// other test in this package can do, because the panel cannot be photographed from an automated run
/// (RECON amendment 40). So the strings are measured with CoreText against the container width, which
/// is the only thing that catches a sentence one word too long before a user meets it.
///
/// The font values below are the weak joint: a SwiftUI `Font` cannot be handed to CoreText, so
/// `D.type.explain`'s 11.5 pt and 3 pt of `lineSpacing`, and the two silkscreen sizes with their
/// tracking, are written out again here. If a token moves, move it here too — this test cannot notice
/// on its own.
@Suite("Dictation notices — the arithmetic")
struct NoticeLayoutTests {

    // Computed rather than stored: `NSFont` is not `Sendable`, so a `static let` of one is a
    // concurrency error under strict checking. Building one is a cache lookup.
    private static var explainFont: NSFont { .systemFont(ofSize: 11.5, weight: .regular) }
    private static let explainLineSpacing: CGFloat = 3        // D.type.explain.lineSpacing
    private static var tinyFont: NSFont {
        NSFontManager.shared.convert(
            .systemFont(ofSize: 8.5, weight: .semibold),
            toHaveTrait: .condensedFontMask
        )
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    /// How many lines `text` wraps to at `width`, as laid out rather than as guessed.
    private static func lineCount(_ text: String, width: CGFloat) -> Int {
        let attributed = NSAttributedString(string: text, attributes: [.font: explainFont])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 10_000), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        return (CTFrameGetLines(frame) as NSArray).count
    }

    /// The vertical room the sentence has, derived from the tokens the view actually uses.
    private static var textBudget: CGFloat {
        HUDMetrics.panelSize.height
            - D.space.xs * 2                 // HUDContent's shadow padding
            - D.space.panelInset * 2         // PanelSurface's inset
            - lineHeight(tinyFont)           // the SilkscreenLabel above the well
            - D.space.sm                     // the VStack's spacing
            - D.space.wellInset * 2          // RecessedWell's inset
    }

    /// Every sentence `AppModel.notice` can build, plus the app names that stretch them.
    private static var everySentence: [String] {
        let apps: [String?] = [
            nil,
            "Notes",
            "Ghostty",
            "Microsoft Visual Studio Code — Insiders",
            // Not real applications, and that is the point. 40 unbroken capitals is where the
            // sentence goes from three lines to four, and 60 is the last width that still fits: at
            // 65 the tail truncates. Both are pinned so a token change that narrows the well shows
            // up here rather than on somebody's screen.
            String(repeating: "W", count: 40),
            String(repeating: "W", count: 60),
        ]
        var sentences = apps.compactMap {
            AppModel.notice(for: .clipboardOnly, appName: $0, keptInHistory: false)?.sentence
        }
        for kept in [true, false] {
            if let notice = AppModel.notice(for: .failed, appName: "Notes", keptInHistory: kept) {
                sentences.append(notice.sentence)
            }
        }
        return sentences
    }

    @Test("Four lines of the notice type fit the panel, and five do not")
    func noticeLinesMatchesTheBudget() {
        let line = Self.lineHeight(Self.explainFont)
        func height(lines: Int) -> CGFloat {
            CGFloat(lines) * line + CGFloat(lines - 1) * Self.explainLineSpacing
        }
        // `HUDMetrics.noticeLines` is not a taste decision, so this pins it to the panel: one more
        // line than the budget allows would be clipped by a borderless window that cannot grow.
        #expect(height(lines: HUDMetrics.noticeLines) <= Self.textBudget)
        #expect(height(lines: HUDMetrics.noticeLines + 1) > Self.textBudget)
    }

    @Test("Every notice sentence fits the well without reaching the line limit")
    func sentencesFit() {
        let line = Self.lineHeight(Self.explainFont)
        for sentence in Self.everySentence {
            let lines = Self.lineCount(sentence, width: HUDMetrics.noticeTextWidth)
            let height = CGFloat(lines) * line + CGFloat(lines - 1) * Self.explainLineSpacing
            #expect(lines <= HUDMetrics.noticeLines,
                    "\(lines) lines at \(HUDMetrics.noticeTextWidth)pt, truncates: \(sentence)")
            #expect(height <= Self.textBudget, "\(height)pt of \(Self.textBudget)pt: \(sentence)")
        }
    }

    @Test("A notice label fits the panel on one line, because a silkscreen label never wraps")
    func labelsFitThePanel() {
        // `SilkscreenLabel` is `.lineLimit(1)` with `.truncationMode(.tail)` — its own comment says
        // two-line panel labels do not exist on equipment — so a label wider than the panel is not
        // a wrap, it is a lost word.
        for label in [AppModel.notInsertedLabel, "Dictation failed"] {
            let printed = Self.silkscreenWidth(label, size: 8.5, tracking: 0.95)
            #expect(printed <= HUDMetrics.contentWidth,
                    "\(printed)pt of \(HUDMetrics.contentWidth)pt: \(label)")
        }
    }

    @Test("The label fits the width the status channel reserves, in both of its weights")
    func labelFitsTheStatusChannel() {
        // `StatusReadout` reserves the rendered width of "Transcribing" with a hidden template and
        // truncates anything wider, so a label too long for it loses its last word in the one channel
        // that also announces itself to VoiceOver. Both weights, because the deck draws
        // `D.type.silkscreen` and the HUD and the popover draw `silkscreenTiny`.
        for (size, tracking) in [(10.0 as CGFloat, 1.15 as CGFloat), (8.5, 0.95)] {
            let reserved = Self.silkscreenWidth("Transcribing", size: size, tracking: tracking)
            let label = Self.silkscreenWidth(AppModel.notInsertedLabel, size: size, tracking: tracking)
            #expect(label <= reserved,
                    "\(AppModel.notInsertedLabel) is \(label)pt against \(reserved)pt at \(size)pt")
        }
    }

    /// A silkscreen label's rendered width. Uppercased, because `D.type.silkscreen` sets
    /// `textCase: .uppercase` and the caps are what get measured on screen.
    private static func silkscreenWidth(_ text: String, size: CGFloat, tracking: CGFloat) -> CGFloat {
        let font = NSFontManager.shared.convert(
            .systemFont(ofSize: size, weight: .semibold),
            toHaveTrait: .condensedFontMask
        )
        return NSAttributedString(
            string: text.uppercased(),
            attributes: [.font: font, .kern: tracking]
        ).size().width
    }
}

// MARK: - The wiring

/// That the rule is actually reached, and that the HUD stays on screen to show it.
///
/// The rule above is a pure function; nothing in it proves the app calls it. These are the call
/// sites: `finished(transcript:)`, the `.error` path, the phase transitions that must and must not
/// clear a standing notice, and `HUDWindowController.shouldShow`, which is what decides whether the
/// panel is on screen at the one moment it has something to say.
@Suite("Dictation notices — the wiring")
@MainActor
struct NoticeSurfaceTests {

    private func model() -> AppModel {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-notice-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // All three stores are ephemeral: `AppModel`'s defaults are the shared singletons, which
        // read and write the real support directory (RECON amendment 39).
        return AppModel(
            settings: Settings(defaults: EphemeralDefaults()),
            dictionary: DictionaryStore(fileURL: root.appendingPathComponent("dictionary.json")),
            history: HistoryStore(fileURL: root.appendingPathComponent("history.json")),
            loginItem: LoginItem(service: nil)
        )
    }

    private func transcript(_ outcome: InjectionOutcome, app: String? = "Ghostty") -> Transcript {
        Transcript(
            rawText: "the quick brown fox",
            text: "the quick brown fox",
            targetBundleID: app == nil ? nil : "com.mitchellh.ghostty",
            targetAppName: app,
            injection: outcome
        )
    }

    @Test("A dictation that only reached the clipboard raises a notice")
    func clipboardOnlyReportsItself() throws {
        let model = model()
        model.finished(transcript: transcript(.clipboardOnly))

        let notice = try #require(model.notice)
        #expect(notice.sentence.contains("Ghostty"))
        #expect(notice.sentence.contains("⌘V"))
        // The durable copy, for the surfaces that are not on a dwell.
        #expect(model.lastNotice == notice)
    }

    @Test("A dictation that landed raises nothing")
    func successRaisesNothing() {
        let model = model()
        model.finished(transcript: transcript(.paste))
        #expect(model.notice == nil)
        #expect(model.lastNotice == nil)
    }

    @Test("Landing on idle does not take the notice away again")
    func idleKeepsTheNotice() throws {
        // The ordering this whole feature rests on. `DictationController.complete` calls
        // `finished(transcript:)` and then `apply(phase: .idle)`, so a rule that cleared notices on
        // every non-active phase would delete the report one statement after raising it — and the
        // HUD would go on vanishing exactly as it did before, with a test suite still green.
        let model = model()
        model.finished(transcript: transcript(.clipboardOnly))
        model.apply(phase: .idle)
        #expect(model.notice != nil)
        #expect(HUDWindowController.shouldShow(phase: model.phase, notice: model.notice))
    }

    @Test("Starting the next utterance takes it away")
    func armingClearsTheNotice() {
        let model = model()
        model.finished(transcript: transcript(.clipboardOnly))
        model.apply(phase: .arming)
        #expect(model.notice == nil, "the HUD would describe the previous utterance over this one")
        // The status item still answers "what happened last?" — that copy is not on a dwell and is
        // replaced by the next completed dictation rather than by the next keypress.
        #expect(model.lastNotice != nil)
    }

    @Test("A hard error keeps talking, and CLEAR is what stops it")
    func errorReportsItselfAndClears() throws {
        let model = model()
        // The salvage sentence `DictationController.failUtterance` produces, printed verbatim: the
        // words are in history and only that sentence knows it.
        let message = DictationController.salvageMessage("Dictation failed: the analyzer stopped.", words: 137)
        model.apply(phase: .error(message))

        let notice = try #require(model.notice)
        #expect(notice.sentence == message)
        #expect(notice.label == "Dictation failed")
        // `shouldShow` returns false for `.error` on its own — that is the gap being closed, and the
        // notice is what holds the panel open over it.
        #expect(!HUDWindowController.shouldShow(phase: .error(message), notice: nil))
        #expect(HUDWindowController.shouldShow(phase: model.phase, notice: model.notice))

        model.clearError()
        #expect(model.notice == nil)
        #expect(model.phase == .idle)
    }

    @Test("The HUD is shown for a notice and for an utterance, and for nothing else")
    func hudVisibility() {
        let notice = DictationNotice(label: "Not inserted", sentence: "Edict could not put the text anywhere.")
        // The two states that used to take the panel away at the moment it had the most to say.
        #expect(HUDWindowController.shouldShow(phase: .idle, notice: notice))
        #expect(HUDWindowController.shouldShow(phase: .error("x"), notice: notice))
        #expect(!HUDWindowController.shouldShow(phase: .idle, notice: nil))
        #expect(!HUDWindowController.shouldShow(phase: .error("x"), notice: nil))
        // Unchanged: the whole utterance, including the finalize and inject tail.
        for phase in [DictationPhase.arming, .listening, .transcribing, .refining, .injecting] {
            #expect(HUDWindowController.shouldShow(phase: phase, notice: nil))
        }
    }

    @Test("The words are only said to be in history when they are in history")
    func historyClaimIsChecked() throws {
        let model = model()
        let row = transcript(.failed)

        model.finished(transcript: row)
        let unkept = try #require(model.notice)
        #expect(!unkept.sentence.lowercased().contains("history"))

        // Same outcome, this time with the row actually in the log — which is what
        // `DictationController.complete` does before it reports.
        model.history.append(row)
        model.finished(transcript: row)
        let kept = try #require(model.notice)
        #expect(kept.sentence.lowercased().contains("history"))
    }

    @Test("In the status channel a notice outranks the phase, and nothing else changes")
    func statusChannelCarriesIt() {
        let notice = DictationNotice(label: "Not inserted", sentence: "Edict could not put the text anywhere.")
        // The channel would otherwise read "Ready" over a sentence saying the words never arrived —
        // and `StatusReadout` announces a `.fault` to VoiceOver, which for a user who cannot see the
        // HUD is the only announcement they get.
        #expect(AppModel.condition(for: .idle, notice: notice) == .fault(notice.label))
        #expect(AppModel.condition(for: .idle, notice: nil) == .ready)
        // The phases either side, unchanged: a notice cannot be standing during one of these (a new
        // utterance clears it), and the phase is the only thing the channel has to say.
        #expect(AppModel.condition(for: .listening, notice: nil) == .listening)
        #expect(AppModel.condition(for: .refining, notice: nil) == .refining)
    }

    @Test("The menu-bar glyph's accessibility label is the notice, not the invitation to dictate")
    func statusLineCarriesIt() throws {
        let model = model()
        model.apply(modelState: .ready)
        model.apply(hotkeyLive: true)
        model.finished(transcript: transcript(.clipboardOnly))
        let notice = try #require(model.notice)

        // `statusLine` reads `Permissions`, which has no seam and reports denied in a test process,
        // and a missing permission legitimately outranks a report about one utterance. So this
        // asserts whichever of the two the machine is entitled to — and in both cases the thing it
        // rules out is the same: the idle invitation, which would mean the report lost to
        // "Hold ⌥ to dictate" rather than to a permission the user has to go and grant.
        if model.permissions.allCriticalGranted {
            #expect(model.statusLine == notice.sentence)
        } else {
            #expect(model.statusLine.hasSuffix("required"))
        }
        #expect(!model.statusLine.contains("to dictate"))
    }
}
