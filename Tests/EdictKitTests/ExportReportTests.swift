import Foundation
import Testing

@testable import EdictKit

// What the three export keys say after they have pressed.
//
// The bug these exist for is not a crash: `TranscriptFileExport.save` returned Void and its catch only
// logged, so a write that failed — a read-only volume, a full disk, an iCloud folder that has not
// materialised — looked exactly like one that succeeded. The panel dismissed itself, the key sprang
// back, and no file existed. Nothing was lost, because the transcript is still in HISTORY, but the app
// claimed an outcome it never verified, which is the one thing `ActionReport` exists to prevent
// (Components.swift, "a real hour lost" — the silent RESTART key).
//
// `NSSavePanel.runModal` is modal system UI and cannot be driven from a test, which is exactly why the
// write is a separate function: the panel's only job is to produce a URL or nothing, and everything
// worth pinning down happens after that.
@Suite("Transcript export — the key reports what the write did")
struct ExportReportTests {

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-export-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var transcript: Transcript {
        Transcript(
            rawText: "Okay team let us review the quarterly numbers",
            text: "Okay team let us review the quarterly numbers",
            source: .imported(filename: "board-meeting.m4a")
        )
    }

    // MARK: - The write

    @Test("A write that lands reports it, and the bytes are on disk")
    func successReportsWritten() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("board-meeting.txt")

        let report = TranscriptFileExport.write(transcript, as: .txt, to: url)
        #expect(report == .done("written"))
        #expect(report.isFault == false)
        // The report is only worth anything if it tracks the file system rather than the intent.
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("quarterly numbers"))
    }

    /// The whole finding, in the cheapest reproducible shape. A directory that is not there stands in
    /// for the read-only volume and the unmaterialised iCloud path: all three are a `write(to:)` that
    /// throws where the old code swallowed it and the key said nothing.
    @Test("A write that cannot land reports a fault instead of springing back silently")
    func failureReportsFault() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir
            .appendingPathComponent("no-such-folder", isDirectory: true)
            .appendingPathComponent("board-meeting.txt")

        let report = TranscriptFileExport.write(transcript, as: .txt, to: url)
        #expect(report.isFault, "a failed write must not report success")
        #expect(!report.text.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        // Whatever the reason turns out to be, it has to fit the cap the key reserves.
        #expect(report.text.count <= "couldn't write".count)
    }

    @Test("Writing over an existing file replaces it — the panel owns the confirmation, not us")
    func overwriteIsThePanelsBusiness() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("board-meeting.txt")
        try Data("stale".utf8).write(to: url)

        #expect(TranscriptFileExport.write(transcript, as: .txt, to: url) == .done("written"))
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(!written.contains("stale"))
    }

    // MARK: - The reason, in as many words as a key cap holds

    @Test("Each write failure a user can act on differently gets its own short reason")
    func reasonsAreDistinct() {
        let reasons = [
            TranscriptFileExport.shortReason(for: CocoaError(.fileWriteOutOfSpace)),
            TranscriptFileExport.shortReason(for: CocoaError(.fileWriteVolumeReadOnly)),
            TranscriptFileExport.shortReason(for: CocoaError(.fileWriteNoPermission)),
            TranscriptFileExport.shortReason(for: CocoaError(.fileNoSuchFile)),
        ]
        #expect(reasons == ["disk full", "read-only", "no permission", "bad path"])
        // Four remedies, four sentences: a full disk and a read-only volume need different actions,
        // and collapsing them into one word would make the key honest but useless.
        #expect(Set(reasons).count == 4)
    }

    @Test("An unrecognised failure claims only that it did not work")
    func unknownReasonIsHonest() {
        #expect(TranscriptFileExport.shortReason(for: CocoaError(.fileWriteUnknown)) == "couldn't write")
        // Not a Cocoa error at all — nothing to map, so nothing is claimed.
        #expect(TranscriptFileExport.shortReason(for: SpeechEngineError.notPrepared) == "couldn't write")
    }

    @Test("Every reason fits the cap width the key reserves for the template")
    func reasonsFitTheCap() {
        // `ReportingButton`'s cap is sized for `template`, which the call site sets to "couldn't
        // write". A longer legend would resize the key and nudge its two neighbours mid-report.
        let template = "couldn't write".count
        let all = [
            "written",
            TranscriptFileExport.shortReason(for: CocoaError(.fileWriteOutOfSpace)),
            TranscriptFileExport.shortReason(for: CocoaError(.fileWriteVolumeReadOnly)),
            TranscriptFileExport.shortReason(for: CocoaError(.fileWriteNoPermission)),
            TranscriptFileExport.shortReason(for: CocoaError(.fileNoSuchFile)),
            TranscriptFileExport.shortReason(for: CocoaError(.fileWriteInvalidFileName)),
            TranscriptFileExport.shortReason(for: CocoaError(.fileWriteUnknown)),
        ]
        #expect(all.allSatisfy { $0.count <= template })
    }
}
