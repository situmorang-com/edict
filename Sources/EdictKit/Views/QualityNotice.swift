//
//  QualityNotice.swift
//  The two things a transcript can need said about it that are not the transcript: how much of the
//  audio actually became words, and which languages produced it.
//
//  WHY THESE LIVE TOGETHER
//
//  They are the same conversation from two directions. A user looking at 1,128 words for 70 minutes
//  of a meeting has two questions — "is this all of it?" and "what language did it think this was?" —
//  and the app was silent on both. Neither answer is a control, so neither belongs in settings; both
//  belong next to the transcript they are about.
//
//  THE RULE THIS FILE OBEYS
//
//  **A good transcript shows nothing.** `RecognitionQuality.isConcerning` is false for anything at a
//  plausible speaking rate, and every view here renders to `EmptyView` in that case. A notice that
//  appears on most imports is a notice users stop reading, and the one recording that needed it would
//  then go past unremarked — which is exactly the failure this whole pass exists to close.
//
//  AND THE ONE IT OBEYS ABOUT REMEDIES
//
//  It does not offer a fix, because there is not one. Conditioning the real 70-minute meeting's audio
//  moved it from 61 words per 300 s to 75 — noise. Dual-language selection produced 18 fluent
//  Indonesian words where English produced 0, which is a better transcript of almost none of the
//  speech. The only honest alternative is a tool built on a different class of model, and Edict
//  deliberately does not ship one (RECON: shipping Parakeet would mean 0.6–2.4 GB of weights and a
//  Python/MLX runtime inside an app with zero third-party dependencies). So the notice says what was
//  measured, says what kind of audio does this, and stops.
//

import SwiftUI

// MARK: - QualityNotice

/// One sentence about a transcript the recogniser under-read, or nothing at all.
///
/// The sentence itself comes from `RecognitionQuality`, which owns the wording and the measurements
/// behind it. This view's whole job is to decide *whether* to speak and to paint it so it reads as a
/// statement about the recording rather than an error in the app.
struct QualityNotice: View {

    let quality: RecognitionQuality?
    /// `.detail` gets the marker square and the full sentence; `.inline` is the one-line form for a
    /// dense table row, where the sentence is already the row's only free space.
    let emphasis: Emphasis

    enum Emphasis { case detail, inline }

    @Environment(\.edictIncreasedContrast) private var increasedContrast

    init(_ quality: RecognitionQuality?, emphasis: Emphasis = .detail) {
        self.quality = quality
        self.emphasis = emphasis
    }

    var body: some View {
        if let quality, quality.isConcerning, let explanation = quality.explanation {
            content(quality, explanation)
        }
    }

    @ViewBuilder
    private func content(_ quality: RecognitionQuality, _ explanation: String) -> some View {
        switch emphasis {
        case .detail:
            HStack(alignment: .top, spacing: D.space.sm) {
                // A hollow triangle, and the shape is load-bearing: `TranscriptRow` already spends a
                // filled square on "not inserted" and a hollow square on "may be incomplete", and a
                // third alert-ink square would be indistinguishable from both at 6pt. Shape carries
                // the meaning; colour only carries the severity (spec §0.4 — never colour alone).
                Triangle()
                    .stroke(
                        D.color.alert,
                        lineWidth: increasedContrast ? D.border.medium : D.border.thin
                    )
                    .frame(width: D.size.troughHeight, height: D.size.troughHeight)
                    // Nudged onto the first text baseline; a triangle's optical centre sits low.
                    .padding(.top, D.space.xxs)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: D.space.xxs) {
                    Text(explanation)
                        .typeStyle(D.type.explain)
                        .foregroundStyle(D.color.alert)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Self.alternative)
                        .typeStyle(D.type.caption)
                        // Secondary ink, not alert: this line is context, and painting it as a second
                        // warning would double the apparent severity of one finding.
                        .foregroundStyle(D.color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(Self.spokenVerdict(quality)). \(explanation) \(Self.alternative)")

        case .inline:
            Text(explanation)
                .typeStyle(D.type.caption)
                .foregroundStyle(D.color.alert)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("\(Self.spokenVerdict(quality)). \(explanation)")
        }
    }

    /// The one alternative worth naming, and it is not a setting.
    ///
    /// Every setting Edict has was measured against this class of audio and none of them recover it:
    /// conditioning moved 61 words to 75, and the second language produced 18 where the first produced
    /// 0. Naming a Whisper-based tool is the only true thing left to say, and saying nothing at all
    /// would leave the user to try each switch in turn.
    static let alternative = """
        Nothing in Edict's settings changes this — it is what the on-device models do with distant \
        or overlapping speech. Recordings like this need a Whisper-class model, which Edict does \
        not ship.
        """

    private static func spokenVerdict(_ quality: RecognitionQuality) -> String {
        switch quality.verdict {
        case .veryPoor: "Warning, this transcript is substantially incomplete"
        case .sparse: "Warning, passages are likely missing from this transcript"
        case .good: ""
        }
    }
}

// MARK: - Triangle

/// An upward hollow triangle. Its own shape rather than `Image(systemName:)` because the flag family
/// in this app is drawn geometry at fixed pixel sizes, and an SF Symbol at 6–8pt renders as a blur
/// with a different optical weight from the squares beside it.
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Language spans

/// Which language produced which stretch of a transcript.
///
/// Drawn from `TranscriptSegment.locale`, so it is the *recorded* per-section decision rather than
/// anything recomputed here. Renders to nothing unless more than one language actually contributed:
/// a monolingual transcript already says its language in the header, and repeating it as a one-row
/// table would be furniture.
struct LanguageSpansView: View {

    let transcript: Transcript

    var body: some View {
        let spans = Self.spans(in: transcript.segments)
        if spans.count > 1 {
            VStack(alignment: .leading, spacing: D.space.labelGap) {
                SilkscreenLabel("Languages", weight: .tiny)
                    .silkscreenDecorative()
                // Deliberately worded as a *choice between transcripts*, not as detection. Apple's
                // framework has no language identification; Edict transcribed each section twice and
                // compared the two results. Implying otherwise would be a claim about the OS.
                Text("Each section was transcribed in both languages and the closer match kept.")
                    .typeStyle(D.type.caption)
                    .foregroundStyle(D.color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                RecessedWell(fill: .list, inset: 0) {
                    VStack(spacing: 0) {
                        ForEach(spans) { span in
                            LanguageSpanRow(span: span)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Languages by section")
        }
    }

    /// One run of consecutive segments that share a locale.
    struct Span: Identifiable, Hashable {
        var id: Int
        var locale: String
        var start: TimeInterval
        var end: TimeInterval
        var words: Int
    }

    /// Collapse per-word segments into per-language runs.
    ///
    /// Runs, not sections: a dual-pass import produces one locale decision per *section*, and
    /// neighbouring sections very often agree — the 70-minute meeting produces 374 sections at
    /// `longForm` — so listing every section would bury the two or three places the language actually
    /// changed under hundreds of identical rows. Merging adjacent same-locale sections shows the
    /// changes, which is the whole information content.
    nonisolated static func spans(in segments: [TranscriptSegment]) -> [Span] {
        var spans: [Span] = []
        for segment in segments {
            guard let locale = segment.locale, !locale.isEmpty else { continue }
            if var last = spans.last, last.locale == locale {
                last.end = max(last.end, segment.end)
                last.words += 1
                spans[spans.count - 1] = last
            } else {
                spans.append(
                    Span(id: spans.count, locale: locale, start: segment.start, end: segment.end, words: 1)
                )
            }
        }
        return spans
    }
}

private struct LanguageSpanRow: View {

    let span: LanguageSpansView.Span

    var body: some View {
        HStack(spacing: D.space.sm) {
            Text(LocaleNames.short(span.locale))
                .typeStyle(D.type.mono)
                .foregroundStyle(D.color.textPrimary)
                .frame(width: 56, alignment: .leading)
            Text(LocaleNames.display(span.locale))
                .typeStyle(D.type.caption)
                .foregroundStyle(D.color.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            SegmentCounter(.count(span.words, unit: "w"), scale: .tiny, seated: false)
            SegmentCounter(.duration(max(0, span.end - span.start)), scale: .small, seated: false)
        }
        .padding(.horizontal, D.space.rowInset)
        .frame(height: D.size.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(LocaleNames.display(span.locale)), \(span.words) words, "
                + String(format: "%.1f seconds", max(0, span.end - span.start))
        )
    }
}

// MARK: - Locale naming

/// Language names for the UI, resolved through an explicit English locale.
///
/// Never `Locale.current`: RECON §7 measured this machine reporting `en_ID`, which resolves language
/// tags in ways nobody expects (`en` → `en-IN`). The identifier is always shown alongside the name
/// for the same reason the settings picker shows it — the name is friendly and the tag is the fact.
enum LocaleNames {
    private static let reference = Locale(identifier: "en-US")

    /// `"id-ID"` as the user spelled it, with the framework's underscores normalised away so a
    /// transcript written before or after a canonicalisation change looks the same.
    static func short(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-")
    }

    /// `"Indonesian (Indonesia)"`, falling back to the identifier when the system has no name.
    static func display(_ identifier: String) -> String {
        reference.localizedString(forIdentifier: short(identifier).replacingOccurrences(of: "-", with: "_"))
            ?? reference.localizedString(forIdentifier: identifier)
            ?? short(identifier)
    }

    /// `"English + Indonesian"` for a header, or just the one name.
    static func summary(_ identifiers: [String]) -> String {
        let names = identifiers.map { display($0) }
        guard !names.isEmpty else { return "" }
        return names.joined(separator: " + ")
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

/// Sheets for the offscreen renderer, covering the two things this pass added to a transcript: the
/// difficult-audio warning and the per-section languages.
///
/// A parallel of `RecoveryFixtures` rather than an addition to it, for the same reason that one is a
/// parallel of `PreviewFixtures` — `MainWindow.swift` is not this agent's file to edit.
///
/// **Every number in the warned fixture is measured, not invented.** They are the real figures from a
/// 300-second slice of the 70-minute meeting, transcribed per section: 245 words, 131.5 s of detected
/// speech, 35 % coverage, mean word confidence 0.288. The *text* is synthetic, deliberately — that
/// recording is private and no fixture may carry a line of it.
@MainActor
public enum DualPassFixtures {

    /// A history holding one mixed-language import and one the recogniser under-read.
    public static func model() -> AppModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-dualpass-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let history = HistoryStore(fileURL: dir.appendingPathComponent("history.json"), limit: { 100 })
        history.append(warned)
        history.append(mixed)
        return AppModel(
            settings: Settings(defaults: EphemeralDefaults()),
            history: history,
            loginItem: LoginItem(service: nil)
        )
    }

    /// The clean bilingual fixture exactly as the app transcribed it: four sections, four confident
    /// verdicts, 7.3 % word error against the ground truth.
    public static let mixed: Transcript = {
        let turns: [(String, String, TimeInterval, TimeInterval)] = [
            ("Okay, team, let's review the quarterly numbers before we start.", "en-US", 0, 3.80),
            ("Baik saya sudah siapkan laporan keuangan untuk kuartal ini", "id-ID", 3.80, 8.48),
            ("Great. Can you walk us through the revenue side first?", "en-US", 8.48, 11.55),
            ("Tentu saja pendapatan kita naik 12% dibanding bulan lalu", "id-ID", 11.55, 16.88),
        ]
        var segments: [TranscriptSegment] = []
        for (text, locale, start, end) in turns {
            let words = text.split(separator: " ")
            let step = (end - start) / Double(max(1, words.count))
            for (index, word) in words.enumerated() {
                segments.append(
                    TranscriptSegment(
                        start: start + Double(index) * step,
                        end: start + Double(index) * step + step * 0.85,
                        text: String(word),
                        confidence: locale == "en-US" ? 0.94 : nil,
                        locale: locale
                    )
                )
            }
        }
        let body = turns.map(\.0).joined(separator: " ")
        return Transcript(
            createdAt: Date(timeIntervalSinceNow: -120),
            rawText: body,
            text: body,
            audioDuration: 16.95,
            transcribeDuration: 1.25,
            localeIdentifier: "id-ID",
            // Indonesian first: it won 10.0 s of recognised audio against English's 6.9 s.
            localeIdentifiers: ["id-ID", "en-US"],
            engine: Transcript.currentEngine,
            injection: .notAttempted,
            source: .imported(filename: "mixed-meeting.mp3"),
            segments: segments,
            quality: RecognitionQuality.assess(
                wordCount: 38,
                audioDuration: 16.95,
                speechDuration: 14.45,
                segments: segments
            )
        )
    }()

    /// The far-field meeting: real measurements, synthetic words.
    public static let warned: Transcript = {
        // 245 words over 105 s of recognised stretches inside a 300 s file — 35 % coverage, which is
        // the shape that earns the dropout wording rather than the even-degradation one.
        let segments: [TranscriptSegment] = (0..<245).map { index in
            let start = 12 + Double(index) * (105.0 / 245.0)
            return TranscriptSegment(
                start: start,
                end: start + 0.3,
                text: "w\(index)",
                confidence: 0.288
            )
        }
        let body = String(repeating: "the ", count: 244) + "meeting"
        return Transcript(
            createdAt: Date(timeIntervalSinceNow: -60),
            rawText: body,
            text: body,
            audioDuration: 299.98,
            transcribeDuration: 7.9,
            localeIdentifier: "en-US",
            engine: Transcript.generalEngine,
            injection: .notAttempted,
            source: .imported(filename: "board-meeting.m4a"),
            segments: segments,
            quality: ImportQueue.assess(
                text: body,
                audioDuration: 299.98,
                speechDuration: 131.53,
                segments: segments
            )
        )
    }()

    /// Queue rows: one file that came back clean, one the recogniser under-read, and one mid-run so
    /// the dual pass's measured progress note is visible.
    public static var queueRows: [ImportQueueRow] {
        [
            ImportQueueRow(
                filename: "mixed-meeting.mp3",
                duration: 16.95,
                state: .finished(mixed)
            ),
            ImportQueueRow(
                filename: "board-meeting.m4a",
                duration: 299.98,
                state: .transcribing(0.49),
                note: "Two languages per section — 68 of 144 passes done"
            ),
            ImportQueueRow(
                filename: "board-meeting.m4a",
                duration: 299.98,
                state: .finished(warned)
            ),
        ]
    }

    public static func renderSheets() -> [PreviewFixtures.RenderSheet] {
        let pane = CGSize(width: D.size.windowMin.width - D.size.railWidth, height: 760)
        let queue = CGSize(width: 1_100, height: 300)

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

        let model = Self.model()
        let mixedID = model.history.transcripts.first { $0.isMixedLanguage }?.id
        let warnedID = model.history.transcripts.first { $0.hasQualityConcern }?.id

        return [
            sheet("dp-queue", queue, ImportPane(rows: queueRows)),
            sheet("dp-history-mixed", pane,
                  HistoryPane(model: Self.model(), initialSelection: mixedID, unbounded: true)),
            sheet("dp-history-warned", pane,
                  HistoryPane(model: Self.model(), initialSelection: warnedID, unbounded: true)),
        ]
    }
}

// MARK: - Previews

#Preview("Quality notice") {
    VStack(alignment: .leading, spacing: D.space.lg) {
        QualityNotice(DualPassFixtures.warned.quality)
        QualityNotice(DualPassFixtures.mixed.quality)   // renders nothing: the transcript is fine
        LanguageSpansView(transcript: DualPassFixtures.mixed)
    }
    .padding(D.space.lg)
    .background(D.surface.deckPaint)
}
#endif
