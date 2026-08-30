import AppKit
import Foundation
import Testing
@testable import EdictKit

/// The measurement `TranscriptExportKeys` reasons from, held to the font.
///
/// A `ReportingButton` with `template: "couldn't write"` was added to the export bank and the suite
/// stayed green, because nothing in this package could see a layout. `TapeCap` neither wraps nor
/// scales — `.lineLimit(1)` plus `.fixedSize(horizontal: true, vertical: false)`, whose own comment
/// reads "If the container cannot afford the key, the container is wrong" — so an unaffordable legend
/// is not clipped: it draws over the row it sits in. Three of them, right-aligned, drew across the
/// filename, duration, language and progress of every finished row in the import tray.
///
/// So this file exists to make one class of mistake fail a test instead of a screenshot: a legend the
/// bank cannot afford. It asserts the RELATION (the bank fits its column) rather than pinning exact
/// point values, because the system font's advances are Apple's to change and a test that fails on a
/// font update teaches nobody anything. The measured numbers go in the failure messages, so a run
/// that does fail says what it measured.
///
/// What this does NOT do: render a view or check a real layout. It measures the string advances the
/// cap will use and applies `TapeCap`'s own documented geometry. A change to that geometry — the
/// horizontal padding, the seat outset — is invisible here and belongs to whoever changes it.
@Suite("Export key widths")
@MainActor
struct ExportKeyWidthTests {

    // MARK: The cap's own geometry

    /// `D.type.buttonCap` is `.system(size: 10.5, weight: .bold, width: .condensed)` with
    /// `tracking: 1.3` and `textCase: .uppercase`. SwiftUI's `Font` cannot be measured, so this is the
    /// same face built through AppKit. If the token changes and this does not, the numbers below stop
    /// describing the shipped cap — which is why the token's values are named here in one place.
    private static let capFont: NSFont = {
        let base = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        let condensed = base.fontDescriptor.withSymbolicTraits(.condensed)
        return NSFont(descriptor: condensed, size: 10.5) ?? base
    }()

    private static let tracking: CGFloat = 1.3

    /// Width of one legend as the cap will draw it: uppercased, tracked, in the cap face.
    ///
    /// Tracking is added per character the way `.tracking(_:)` applies it — after every glyph,
    /// including the last. That trailing unit is what `Text` reserves, so leaving it out would make
    /// every number here optimistic, which is the direction that lets a bad legend through.
    private static func legendWidth(_ legend: String) -> CGFloat {
        let text = legend.uppercased()
        let measured = (text as NSString)
            .size(withAttributes: [.font: capFont])
            .width
        return measured + tracking * CGFloat(text.count)
    }

    /// One standard `TapeCap`'s width: the legend, `D.space.md` of padding each side, floored at
    /// `minWidth`, plus a 1pt `capSeatOutset` seat on each side.
    private static func capWidth(_ legend: String, minWidth: CGFloat) -> CGFloat {
        let cap = max(minWidth, legendWidth(legend) + 2 * D.space.md)
        return cap + 2 * ExportKeyMetrics.capSeatOutset
    }

    /// The whole export bank: three caps with `D.space.xs` between them.
    private static func bankWidth(legend: (TranscriptExportFormat) -> String) -> CGFloat {
        let formats = TranscriptExportFormat.allCases
        let caps = formats.reduce(CGFloat.zero) { $0 + capWidth(legend($1), minWidth: ExportKeyMetrics.keyWidth) }
        return caps + D.space.xs * CGFloat(formats.count - 1)
    }

    // MARK: The invariant that matters

    @Test("Every legend the export keys can display fits the column they sit in")
    func theShippedBankFitsItsColumn() {
        let bank = Self.bankWidth { $0.fileExtension }

        #expect(bank <= ExportKeyMetrics.columnWidth, """
            the export bank measures \(String(format: "%.1f", bank))pt inside ExportKeyMetrics.columnWidth = \
            \(String(format: "%.1f", ExportKeyMetrics.columnWidth))pt. TapeCap does not wrap or scale, so the overflow \
            is not clipped — it draws leftwards over the filename, duration, language and progress \
            of every finished row. Either shorten the legends or widen the column.
            """)
    }

    @Test("A word-length report on the cap does not fit, which is why the container prints it")
    func aTemplatedReportWouldNotFit() {
        // The exact legend that shipped and had to be reverted, plus the shortest word anyone would
        // reach for next. `ReportingButton` reserves its template's width on EVERY key in the bank,
        // resting and reported alike, so the template — not the report — is what has to fit.
        for template in ["couldn't write", "failed", "no permission"] {
            let bank = Self.bankWidth { _ in template }
            #expect(bank > ExportKeyMetrics.columnWidth, """
                template "\(template)" now measures \(String(format: "%.1f", bank))pt against \
                ExportKeyMetrics.columnWidth = \(String(format: "%.1f", ExportKeyMetrics.columnWidth))pt. If a report legend genuinely \
                fits now, TranscriptExportKeys' documentation is out of date and the outcome could \
                move back onto the cap — but check the history detail header too, which is the \
                tighter of the two containers once its seated counters are counted.
                """)
        }
    }

    @Test("The three-letter width is not close to the edge")
    func thereIsHeadroomForOneMoreFormat() {
        let bank = Self.bankWidth { $0.fileExtension }
        let oneMore = bank + Self.capWidth("xxx", minWidth: ExportKeyMetrics.keyWidth) + D.space.xs

        // Not a hard requirement — a fourth format would be a design decision, not an accident. The
        // point is that the answer is written down: today it does not fit, so adding one means
        // widening the column on purpose rather than discovering the overlap in a screenshot.
        #expect(oneMore > ExportKeyMetrics.columnWidth, """
            a fourth three-letter format would now fit in \(String(format: "%.1f", ExportKeyMetrics.columnWidth))pt \
            (\(String(format: "%.1f", oneMore))pt). Update this test and TranscriptExportKeys' note.
            """)
    }

    @Test("The legend sets the cap width, not the minWidth floor — and all three come out level")
    func theLegendIsWhatSetsTheWidth() {
        // Worth pinning because it is the opposite of what the `minWidth: M.keyWidth` at the call
        // site suggests. Measured: a three-letter legend is ~21.9pt of text plus 2 x D.space.md of
        // padding = ~45.9pt, well over the 30pt floor. So `minWidth` never binds here, and the reason
        // the bank looks level is that TXT, SRT and VTT happen to measure within a fraction of a point
        // of each other in a condensed face — not that a floor is holding them equal.
        let widths = TranscriptExportFormat.allCases.map {
            Self.capWidth($0.fileExtension, minWidth: ExportKeyMetrics.keyWidth)
        }

        #expect(widths.allSatisfy { $0 > ExportKeyMetrics.keyWidth }, """
            a legend now fits inside the \(String(format: "%.1f", ExportKeyMetrics.keyWidth))pt floor,             so minWidth has started deciding the width. Harmless, but the note above is then wrong.
            """)

        let spread = (widths.max() ?? 0) - (widths.min() ?? 0)
        #expect(spread < 1, """
            the three export keys differ by \(String(format: "%.2f", spread))pt, so the bank is             ragged. Nothing enforces equal widths — if a format's extension is ever renamed to             something wider, either give the bank a shared width or accept the ragged edge on purpose.
            """)
    }
}
