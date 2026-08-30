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

    @Test("A write that lands reports it, and names the file it wrote")
    func successReportsWritten() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("board-meeting.txt")

        let outcome = TranscriptFileExport.write(transcript, as: .txt, to: url)
        #expect(outcome.isFault == false)
        // Named on purpose: "written" alone does not answer the question a user actually has after a
        // save panel, which is *where*. The name comes from the URL the panel returned, so this
        // reports the file that exists rather than the one that was asked for.
        #expect(outcome.sentence.contains("board-meeting.txt"))
        // The outcome is only worth anything if it tracks the file system rather than the intent.
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

        let outcome = TranscriptFileExport.write(transcript, as: .txt, to: url)
        #expect(outcome.isFault, "a failed write must not report success")
        #expect(!outcome.sentence.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test("Writing over an existing file replaces it — the panel owns the confirmation, not us")
    func overwriteIsThePanelsBusiness() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("board-meeting.txt")
        try Data("stale".utf8).write(to: url)

        #expect(TranscriptFileExport.write(transcript, as: .txt, to: url).isFault == false)
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(!written.contains("stale"))
    }

    // MARK: - The sentence the surface prints

    /// Four failures, four next moves. This is not tidiness: a full disk and a read-only volume need
    /// the user to do different things, and a folder that has not come down from iCloud needs a third.
    /// Collapsing them into one string would leave the report honest and useless.
    @Test("Each write failure a user can act on differently gets its own sentence")
    func reasonsAreDistinct() {
        let sentences = [
            TranscriptFileExport.failureSentence(for: CocoaError(.fileWriteOutOfSpace)),
            TranscriptFileExport.failureSentence(for: CocoaError(.fileWriteVolumeReadOnly)),
            TranscriptFileExport.failureSentence(for: CocoaError(.fileWriteNoPermission)),
            TranscriptFileExport.failureSentence(for: CocoaError(.fileNoSuchFile)),
        ]
        #expect(Set(sentences).count == 4)
        #expect(sentences.allSatisfy { !$0.isEmpty })
    }

    @Test("An unrecognised failure claims only that it did not work, and says where the reason is")
    func unknownReasonIsHonest() {
        let unknown = TranscriptFileExport.failureSentence(for: CocoaError(.fileWriteUnknown))
        // Not a guess dressed up as a diagnosis: it points at the log rather than inventing a cause.
        #expect(unknown.contains("Console"))
        // Not a Cocoa error at all — a different domain entirely, so there is nothing to map.
        #expect(TranscriptFileExport.failureSentence(for: SpeechEngineError.notPrepared) == unknown)
    }

    /// The invariant that matters most in the wording, and the one a future edit is most likely to
    /// drop: a user who reads "could not write" and does not know the transcript survived will go
    /// looking for a recovery that is not needed. The write is a copy; nothing was consumed.
    @Test("Every failure sentence says the transcript is still in HISTORY")
    func everyFailureSaysTheTranscriptSurvived() {
        let errors: [Error] = [
            CocoaError(.fileWriteOutOfSpace),
            CocoaError(.fileWriteVolumeReadOnly),
            CocoaError(.fileWriteNoPermission),
            CocoaError(.fileNoSuchFile),
            CocoaError(.fileWriteInvalidFileName),
            CocoaError(.fileWriteUnknown),
            SpeechEngineError.notPrepared,
        ]
        for error in errors {
            let sentence = TranscriptFileExport.failureSentence(for: error)
            #expect(sentence.contains("still in HISTORY"), "\(sentence) does not say the transcript survived")
        }
    }

    /// Not an `ActionReport`, and this pins the reason. `ActionReport`'s contract is one or two words
    /// because it is printed on a key cap; these are whole sentences for a caption channel, which is
    /// exactly why `TranscriptExportKeys` hands the outcome to its container instead of its cap. If
    /// these ever became short enough to fit a cap, that design note would be out of date.
    @Test("The sentences are sentences, not cap legends")
    func sentencesAreNotCapLegends() {
        let sentence = TranscriptFileExport.failureSentence(for: CocoaError(.fileWriteNoPermission))
        #expect(sentence.count > "couldn't write".count)
        #expect(sentence.hasSuffix("."))
    }
}
