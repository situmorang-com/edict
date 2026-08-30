import AppKit
import CoreText
import Foundation
import Testing
@testable import EdictKit

/// The history pane's logic and its arithmetic.
///
/// Two different jobs in one file because they guard the same three changes. The logic suites test the
/// parts of the pane that were extracted out of view bodies precisely so they could be tested — which
/// tray the log draws, what the empty tray teaches, and whether the transcript well is hiding
/// anything. The width suite does what `ExportKeyWidthTests` does and for the same reason: the app
/// cannot be photographed from an automated run (RECON §40), a `TapeCap` neither wraps nor scales
/// ("If the container cannot afford the key, the container is wrong"), and the last round's overflow
/// was caught by measuring the legend rather than by any test of behaviour.
///
/// The width tests assert the *relation* — this key fits this container — and put the measured numbers
/// in the failure message, so a system-font update changes the numbers without failing the suite for
/// no reason a reader can act on.
@Suite("History pane")
struct HistoryPaneTests {

    // MARK: - Which tray

    @Suite("Log tray content")
    struct TrayContent {

        @Test("Rows win whenever there are any")
        func rows() {
            #expect(LogTrayContent(rowCount: 1, storeCount: 1, query: "") == .rows)
            #expect(LogTrayContent(rowCount: 1, storeCount: 40, query: "migration") == .rows)
        }

        @Test("An empty store teaches the gestures, with or without a query")
        func emptyLog() {
            #expect(LogTrayContent(rowCount: 0, storeCount: 0, query: "") == .emptyLog)
            // A query typed into an empty log is still an empty log: there is nothing to have
            // filtered out, and "no transcript matches" would be a strange first thing to read.
            #expect(LogTrayContent(rowCount: 0, storeCount: 0, query: "anything") == .emptyLog)
        }

        @Test("A query that filtered everything out says so, and says which query")
        func noMatch() {
            #expect(LogTrayContent(rowCount: 0, storeCount: 12, query: "zzz") == .noMatch(query: "zzz"))
            // Trimmed, because the query is echoed back into a sentence in quotation marks and
            // "no transcript matches "  zzz  "" reads as a bug.
            #expect(LogTrayContent(rowCount: 0, storeCount: 12, query: "  zzz  ") == .noMatch(query: "zzz"))
        }

        @Test("A whitespace-only query over a full store falls back to the empty log")
        func whitespaceQuery() {
            // `HistoryStore.search` trims too, so this combination cannot arise from the real store —
            // it is asserted because the alternative branch would print an empty pair of quotation
            // marks, and this is the cheapest place to pin which way the tie breaks.
            #expect(LogTrayContent(rowCount: 0, storeCount: 12, query: "   ") == .emptyLog)
        }
    }

    // MARK: - Which badges are ambiguous

    /// The badge set was a private computed property over the model, read from inside the `ForEach`
    /// content closure. Hoisting it into `body` made it a `static` function of the rows, which is
    /// also the first time anything could test it — so these pin the behaviour the move had to
    /// preserve rather than merely restating it.
    @Suite("Ambiguous language badges")
    // `HistoryPane` conforms to `View`, which SwiftUI declares `@MainActor @preconcurrency` — so a
    // static member of it compiles when called from anywhere and traps at runtime off the main
    // actor. Without this the suite exits with signal 5 rather than a failure.
    @MainActor
    struct AmbiguousBadges {

        private func transcript(_ locales: [String]) -> Transcript {
            Transcript(
                rawText: "x",
                text: "x",
                localeIdentifier: locales[0],
                localeIdentifiers: locales.count > 1 ? locales : []
            )
        }

        @Test("Two variants of one language make its badge ambiguous")
        func twoVariants() {
            let rows = [transcript(["en-US"]), transcript(["en-GB"])]
            #expect(HistoryPane.ambiguousBadges(in: rows) == ["EN"])
        }

        @Test("Two different languages are not ambiguous, and one language never is")
        func distinctLanguages() {
            #expect(HistoryPane.ambiguousBadges(in: [transcript(["en-US"]), transcript(["id-ID"])]).isEmpty)
            #expect(HistoryPane.ambiguousBadges(in: [transcript(["en-US"]), transcript(["en-US"])]).isEmpty)
            #expect(HistoryPane.ambiguousBadges(in: []).isEmpty)
        }

        @Test("A mixed-language transcript contributes every locale it used")
        func mixedTranscript() {
            // One row can be ambiguous with itself: a dual-pass import that landed on en-US and
            // en-GB prints `EN` twice in its own language column.
            #expect(HistoryPane.ambiguousBadges(in: [transcript(["en-US", "en-GB"])]) == ["EN"])
        }

        @Test("Underscored and hyphenated spellings of one locale are the same locale")
        func spellingsAgree() {
            // `DictationTranscriber.supportedLocales` reports `id_ID` where the store holds `id-ID`,
            // so a naive comparison would call one language two and badge it as ambiguous.
            #expect(HistoryPane.ambiguousBadges(in: [transcript(["id_ID"]), transcript(["id-ID"])]).isEmpty)
        }
    }

    // MARK: - What the empty tray teaches

    @Suite("Empty log gestures")
    @MainActor
    struct Gestures {

        private func settings() -> Settings { Settings(defaults: EphemeralDefaults()) }

        @Test("At the shipped defaults all four gestures are named")
        func allFour() {
            let lines = GestureCopy.lines(settings: settings(), secondaryLocaleReady: true)
            #expect(lines.count == 4)
            #expect(lines[0] == "Hold Right Option (⌥) and speak. Edict puts the text at your cursor.")
            #expect(lines[1] == "Add ⇧ while you hold it to dictate in Indonesian (Indonesia).")
            #expect(lines[2].hasPrefix("🌐/ cleans up"))
            #expect(lines[3].hasPrefix("Drop an audio or video file"))
        }

        @Test("The hold line follows the key the user actually bound")
        func rebindingTheKey() {
            let s = settings()
            s.hotkey = .f13
            #expect(GestureCopy.lines(settings: s, secondaryLocaleReady: false)[0].hasPrefix("Hold F13 and speak."))
        }

        @Test("With hold-to-talk off the line says press twice, not hold")
        func pressToToggle() {
            let s = settings()
            s.pushToTalk = false
            let first = GestureCopy.lines(settings: s, secondaryLocaleReady: false)[0]
            #expect(first.hasPrefix("Press Right Option (⌥) to start, and press it again to stop."))
        }

        @Test("With automatic insertion off the line promises the clipboard, not the cursor")
        func autoInjectOff() {
            let s = settings()
            s.autoInject = false
            let first = GestureCopy.lines(settings: s, secondaryLocaleReady: false)[0]
            #expect(first.hasSuffix("Edict leaves the text on your clipboard."))
            #expect(!first.contains("cursor"))
        }

        @Test("The second-language line is withheld until its model is on disk")
        func secondaryNotReady() {
            // Same gate as `AppModel.statusLine`: naming the modifier before the assets are
            // installed teaches a gesture whose first use is an error message.
            let lines = GestureCopy.lines(settings: settings(), secondaryLocaleReady: false)
            #expect(lines.count == 3)
            #expect(!lines.contains { $0.contains("Indonesian") })
        }

        @Test("Switching the second language off removes its line")
        func secondaryDisabled() {
            let s = settings()
            s.secondaryLocaleEnabled = false
            let lines = GestureCopy.lines(settings: s, secondaryLocaleReady: true)
            #expect(lines.count == 3)
            #expect(!lines.contains { $0.contains("hold it to dictate") })
        }

        @Test("Switching refinement off removes its line")
        func refineDisabled() {
            let s = settings()
            s.refineSelectionEnabled = false
            let lines = GestureCopy.lines(settings: s, secondaryLocaleReady: true)
            #expect(lines.count == 3)
            #expect(!lines.contains { $0.contains("cleans up") })
        }

        @Test("The refine line prints the chord in force, not the default")
        func refineChordRebound() {
            let s = settings()
            s.refineSelectionChord = .controlOptionR
            let lines = GestureCopy.lines(settings: s, secondaryLocaleReady: true)
            #expect(lines.contains { $0.hasPrefix("⌃⌥R cleans up") })
        }

        @Test("The drop line survives every switch, because dropping a file cannot be turned off")
        func dropAlwaysNamed() {
            let s = settings()
            s.secondaryLocaleEnabled = false
            s.refineSelectionEnabled = false
            let lines = GestureCopy.lines(settings: s, secondaryLocaleReady: false)
            #expect(lines.count == 2)
            #expect(lines.last?.contains("anywhere on this window") == true)
        }

        @Test("Nothing claims an outcome with an exclamation mark or a promise about the app")
        func wordingDiscipline() {
            for line in GestureCopy.lines(settings: settings(), secondaryLocaleReady: true) {
                #expect(!line.contains("!"))
                #expect(line.hasSuffix(".") || line.hasSuffix("here."))
            }
        }
    }

    // MARK: - Is the well hiding anything

    @Suite("Transcript well text")
    struct WellText {

        /// The width the well's text is laid out at when the window is at its minimum size —
        /// `HistoryPaneMetrics.narrowestPanelWidth` less `RecessedWell`'s inset on both sides.
        private static var wellTextWidth: CGFloat {
            HistoryPaneMetrics.narrowestPanelWidth - 2 * D.space.wellInset
        }

        @Test("A four-word dictation is not truncated")
        func shortTextFits() {
            #expect(!TranscriptWellText.exceeds(
                lineLimit: HistoryPaneMetrics.collapsedLineLimit,
                text: "run the migration now",
                width: Self.wellTextWidth
            ))
        }

        @Test("A 70-minute transcript is truncated, and answering that does not need to read it all")
        func longTextOverflows() {
            let long = Self.transcript(words: 10_500)
            #expect(TranscriptWellText.exceeds(
                lineLimit: HistoryPaneMetrics.collapsedLineLimit,
                text: long,
                width: Self.wellTextWidth
            ))
        }

        @Test("Hard newlines count as lines")
        func newlinesCount() {
            // The reason there is no paragraph loop in `exceeds`: `CTTypesetterSuggestLineBreak` was
            // measured to break at `\n` on its own. If that ever stops being true, a five-line
            // bulleted refinement would report as one line and its key would disappear.
            #expect(TranscriptWellText.exceeds(lineLimit: 4, text: "a\nb\nc\nd\ne", width: Self.wellTextWidth))
            #expect(!TranscriptWellText.exceeds(lineLimit: 4, text: "a\nb\nc", width: Self.wellTextWidth))
            #expect(!TranscriptWellText.exceeds(lineLimit: 4, text: "a b c d e", width: Self.wellTextWidth))
        }

        @Test("An unmeasured width offers no key rather than a key on every dictation")
        func zeroWidth() {
            // The first frame, before `onGeometryChange` reports: at width 0 the typesetter breaks
            // after roughly every character, so the honest answer is "not yet known".
            #expect(!TranscriptWellText.exceeds(lineLimit: 4, text: "run the migration now", width: 0))
            #expect(!TranscriptWellText.exceeds(lineLimit: 4, text: "", width: Self.wellTextWidth))
        }

        @Test("Short text is one block, byte for byte")
        func shortTextIsOneBlock() {
            let text = "run the migration now"
            #expect(TranscriptWellText.blocks(text, targetWords: 300) == [text])
            // The path every dictation takes, so it has to be the exact stored string: this is what
            // keeps selection inside one `Text` for everything but a long import.
            let multiline = "- one thing\n- another thing\n\n- a third"
            #expect(TranscriptWellText.blocks(multiline, targetWords: 300) == [multiline])
            #expect(TranscriptWellText.blocks("", targetWords: 300).isEmpty)
        }

        @Test("A long transcript is broken up, and every word survives in order")
        func longTextKeepsEveryWord() {
            let long = Self.transcript(words: 10_500)
            let blocks = TranscriptWellText.blocks(long, targetWords: HistoryPaneMetrics.chunkTargetWords)

            #expect(blocks.count > 1)
            #expect(Self.words(blocks.joined(separator: " ")) == Self.words(long))
            #expect(blocks.allSatisfy { !$0.isEmpty })
            #expect(blocks.allSatisfy { $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        }

        @Test("A block ends at a sentence, and no block runs away")
        func blocksEndAtSentences() {
            let blocks = TranscriptWellText.blocks(Self.transcript(words: 10_500), targetWords: 300)
            let target = 300

            for block in blocks.dropLast() {
                #expect(block.hasSuffix("."), "a block ended mid-sentence: \(String(block.suffix(40)))")
                let count = Self.words(block).count
                #expect(count >= target && count <= target * 2, "block of \(count) words against a \(target)-word target")
            }
        }

        @Test("Text with no sentence end is still broken up, at twice the target")
        func unpunctuatedTextIsStillBroken() {
            // The case that most needs breaking up: a recogniser that returned no punctuation would
            // otherwise hand the well one 10,000-word `Text`, which is the 146 ms layout.
            let unpunctuated = Array(repeating: "word", count: 1_000).joined(separator: " ")
            let blocks = TranscriptWellText.blocks(unpunctuated, targetWords: 300)
            #expect(blocks.count == 2)
            #expect(blocks.allSatisfy { Self.words($0).count <= 600 })
            #expect(Self.words(blocks.joined(separator: " ")) == Self.words(unpunctuated))
        }

        @Test("Non-ASCII text is cut on a character boundary, not inside one")
        func unicodeIsSafe() {
            // The splitter scans UTF-8 for speed (0.32 ms against 3.6 ms, measured), so this is the
            // property that keeps that legal: cuts only ever land on an ASCII space, which is always
            // a character boundary. A crash here would be a trap inside `String.subscript`.
            let indonesian = "Dan ada workshop 🎧 karena sekarang timnya dia sangat kecil. 会議の内容です。"
            let long = Array(repeating: indonesian, count: 400).joined(separator: " ")
            let blocks = TranscriptWellText.blocks(long, targetWords: 50)
            #expect(blocks.count > 1)
            #expect(Self.words(blocks.joined(separator: " ")) == Self.words(long))
        }

        // MARK: Fixture

        /// Roughly `words` words of plausible transcript, with sentence ends where a recogniser
        /// would put them. 10,500 words is 70 minutes of speech at 150 wpm — the recording the
        /// README sells and the length the block splitting exists for.
        private static func transcript(words: Int) -> String {
            let sentence = "we should probably align on the deliverables before Thursday "
                + "because the client asked for a revised timeline."
            let perSentence = sentence.split(whereSeparator: { $0.isWhitespace }).count
            let count = max(1, words / perSentence)
            return Array(repeating: sentence, count: count).joined(separator: " ")
        }

        private static func words(_ text: String) -> [String] {
            text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
    }

    // MARK: - Widths

    @Suite("History pane widths")
    @MainActor
    struct Widths {

        /// `D.type.buttonCap` rebuilt through AppKit, exactly as `ExportKeyWidthTests` rebuilds it:
        /// `.system(size: 10.5, weight: .bold, width: .condensed)`, `tracking: 1.3`, uppercased.
        private static let capFont: NSFont = {
            let base = NSFont.systemFont(ofSize: 10.5, weight: .bold)
            let condensed = base.fontDescriptor.withSymbolicTraits(.condensed)
            return NSFont(descriptor: condensed, size: 10.5) ?? base
        }()

        /// `D.type.explain`: `.system(size: 11.5, weight: .regular)`, no tracking.
        private static let explainFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        /// `D.type.silkscreenHeading`: 12pt bold condensed, `tracking: 1.6`, uppercased.
        private static let headingFont: NSFont = {
            let base = NSFont.systemFont(ofSize: 12, weight: .bold)
            return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.condensed), size: 12) ?? base
        }()

        /// Tracking is added after every glyph including the last, which is what `Text` reserves.
        /// Leaving the trailing unit out makes every number optimistic — the direction that lets a
        /// legend the container cannot afford through.
        private static func legendWidth(_ legend: String, font: NSFont, tracking: CGFloat) -> CGFloat {
            let text = legend.uppercased()
            return (text as NSString).size(withAttributes: [.font: font]).width
                + tracking * CGFloat(text.count)
        }

        private static func capWidth(_ legend: String) -> CGFloat {
            legendWidth(legend, font: capFont, tracking: 1.3)
                + 2 * D.space.md
                + 2 * HistoryPaneMetrics.capSeatOutset
        }

        @Test("Every legend the transcript well's key can print fits the narrowest panel")
        func theKeyFitsItsRow() {
            // The label the key shares its row with, at its longest, plus the stack's spacing and
            // the `Spacer`'s minimum. "Show all (999,999 words)" is not a realistic transcript; it
            // is the widest legend the formatter can produce, and the row has room for it.
            let label = Self.legendWidth("As dictated", font: NSFont.systemFont(ofSize: 8.5, weight: .semibold), tracking: 0.95)
            let gaps = D.space.sm + D.space.xs

            for legend in ["Show all (1,240 words)", "Show all (10,500 words)", "Show all (999,999 words)", "Show less"] {
                let row = label + gaps + Self.capWidth(legend)
                #expect(row <= HistoryPaneMetrics.narrowestPanelWidth, """
                    "\(legend)" makes the label row measure \(String(format: "%.1f", row))pt inside \
                    HistoryPaneMetrics.narrowestPanelWidth = \
                    \(String(format: "%.1f", HistoryPaneMetrics.narrowestPanelWidth))pt. TapeCap does not wrap \
                    or scale, so the overflow is not clipped: it draws leftwards over the label and \
                    the well below it. Shorten the legend.
                    """)
            }
        }

        @Test("The empty tray's copy fits the height the tray is capped at")
        func theEmptyTrayFitsItsCap() {
            // The failure this exists to catch is the mirror of an overflowing key: a tray capped at
            // eight rows with more than eight rows of prose in it, which clips the last gesture — and
            // the last gesture is the drop hint, the one nothing else in the window mentions.
            let lines = GestureCopy.lines(
                settings: Settings(defaults: EphemeralDefaults()),
                secondaryLocaleReady: true
            )
            let copyHeight = lines.reduce(CGFloat.zero) { total, line in
                total + Self.wrappedHeight(
                    line,
                    font: Self.explainFont,
                    width: HistoryPaneMetrics.emptyCopyWidth,
                    lineSpacing: 3
                )
            } + D.space.xs * CGFloat(lines.count - 1)

            let headingHeight = Self.wrappedHeight(
                "Nothing recorded yet",
                font: Self.headingFont,
                width: HistoryPaneMetrics.emptyCopyWidth,
                lineSpacing: 0
            )
            let total = headingHeight + D.space.sm + copyHeight + 2 * D.space.lg
            let cap = D.size.rowHeight * HistoryPaneMetrics.emptyTrayRows

            // And the same sum with every line wrapped one line further than CoreText says it needs.
            // At the shipped measure of 460pt the three short gestures lay out at 326.5, 368.0 and
            // 390.3pt and the drop hint needs 528.1pt, i.e. two lines — so nothing here is at the
            // edge, but whether a line wraps is still SwiftUI's decision to make rather than
            // CoreText's, and if it disagrees the tray must hold the copy rather than clip the drop
            // hint, which is the one gesture nothing else in the window mentions.
            //
            // This is the assertion that rejected `emptyTrayRows = 8`: 208pt against 219.6pt.
            let ifEveryLineWrapped = headingHeight + D.space.sm + copyHeight * 2 + 2 * D.space.lg
            #expect(ifEveryLineWrapped <= cap, """
                the empty log tray fits at \(String(format: "%.1f", total))pt as CoreText breaks it, but \
                needs \(String(format: "%.1f", ifEveryLineWrapped))pt if SwiftUI wraps every line once more, \
                against a cap of \(String(format: "%.1f", cap))pt. That margin is what makes the tray safe \
                without a rendered layout to check.
                """)

            #expect(total <= cap, """
                the empty log tray needs \(String(format: "%.1f", total))pt \
                (heading \(String(format: "%.1f", headingHeight))pt, \(lines.count) gesture lines \
                \(String(format: "%.1f", copyHeight))pt, padding \(String(format: "%.1f", 2 * D.space.lg))pt) \
                against a cap of \(String(format: "%.1f", cap))pt \
                (D.size.rowHeight x HistoryPaneMetrics.emptyTrayRows). Either shorten a gesture line, \
                widen HistoryPaneMetrics.emptyCopyWidth, or raise the cap — a clipped tray hides the \
                last gesture.
                """)
        }

        @Test("The heading fits on one line at the measure the copy is set to")
        func theHeadingDoesNotWrap() {
            let heading = Self.legendWidth("Nothing recorded yet", font: Self.headingFont, tracking: 1.6)
            #expect(heading <= HistoryPaneMetrics.emptyCopyWidth, """
                "NOTHING RECORDED YET" measures \(String(format: "%.1f", heading))pt against \
                HistoryPaneMetrics.emptyCopyWidth = \(String(format: "%.1f", HistoryPaneMetrics.emptyCopyWidth))pt, \
                so it wraps and the height above is one line short.
                """)
        }

        /// The height `Text` needs for one string at a given measure: CoreText line count times the
        /// font's line height plus `lineSpacing` between lines.
        private static func wrappedHeight(
            _ text: String,
            font: NSFont,
            width: CGFloat,
            lineSpacing: CGFloat
        ) -> CGFloat {
            let attributed = NSAttributedString(string: text, attributes: [.font: font])
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
            let frame = CTFramesetterCreateFrame(setter, CFRangeMake(0, 0), path, nil)
            let lines = (CTFrameGetLines(frame) as? [CTLine])?.count ?? 1
            let lineHeight = font.ascender - font.descender + font.leading
            return CGFloat(lines) * lineHeight + CGFloat(max(0, lines - 1)) * lineSpacing
        }
    }
}
