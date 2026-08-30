import Foundation
import Testing
@testable import EdictKit

/// The jump from a finished import row to its transcript.
///
/// The interesting cases are not the happy one. A jump arrives with whatever the user last typed
/// still in the search field, and the destination may have been deleted or trimmed away between the
/// press and the adoption — so the decision is a pure function and it is tested here rather than
/// argued for in a view body.
///
/// Why there is no test for the context menu itself: it is a `contextMenu` on a row, and this package
/// cannot render a view. What is testable is the rule, which is where the two ways to get this wrong
/// live — selecting a row the filter hides, and selecting a row that no longer exists.
@Suite("Show in Log")
@MainActor
struct ShowInLogTests {

    private func transcript(_ text: String, at seconds: TimeInterval, filename: String? = nil) -> Transcript {
        Transcript(
            createdAt: Date(timeIntervalSince1970: seconds),
            rawText: text,
            text: text,
            audioDuration: 10,
            transcribeDuration: 1,
            injection: .notAttempted,
            source: filename.map { TranscriptSource.imported(filename: $0) } ?? TranscriptSource.dictated
        )
    }

    @Test("A visible row is selected and the search is left alone")
    func visibleRowKeepsTheQuery() {
        let a = transcript("board review notes", at: 1, filename: "Pertamina.m4a")
        let b = transcript("something else", at: 2)
        let rows = [a, b]

        let adopted = HistoryPane.adoption(of: a.id, rows: rows, allTranscripts: rows)

        #expect(adopted?.selection == a.id)
        #expect(adopted?.clearQuery == false,
                "a search the user may still want was thrown away even though the target was visible")
    }

    @Test("A row the active search hides gets the search cleared")
    func hiddenRowClearsTheQuery() {
        let target = transcript("board review notes", at: 1, filename: "Pertamina.m4a")
        let other = transcript("kalimantan site visit", at: 2)
        // What `search("kalimantan")` would have returned: the target is not in it.
        let rows = [other]

        let adopted = HistoryPane.adoption(of: target.id, rows: rows, allTranscripts: [target, other])

        #expect(adopted?.selection == target.id)
        #expect(adopted?.clearQuery == true,
                """
                the row was selected while the filter still hid it, so the table would show no rows \
                and the detail block would show one that is not in it — the pane contradicting itself
                """)
    }

    @Test("A transcript that no longer exists drops the jump instead of selecting nothing")
    func deletedRowDropsTheJump() {
        let survivor = transcript("still here", at: 2)
        let deleted = transcript("deleted between the press and the adoption", at: 1)

        let adopted = HistoryPane.adoption(
            of: deleted.id,
            rows: [survivor],
            allTranscripts: [survivor]
        )

        #expect(adopted == nil,
                "a jump to a deleted or trimmed transcript selected an id that is not in the store")
    }

    @Test("showInLog switches to the history pane and leaves the signal for it to adopt")
    func showInLogSetsBothHalves() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-showinlog-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Ephemeral stores: AppModel's defaults are the shared singletons, which read and write the
        // real support directory (RECON amendment 39).
        let model = AppModel(
            settings: Settings(defaults: EphemeralDefaults()),
            dictionary: DictionaryStore(fileURL: root.appendingPathComponent("dictionary.json")),
            history: HistoryStore(fileURL: root.appendingPathComponent("history.json")),
            loginItem: LoginItem(service: nil)
        )
        model.pane = Pane.imports
        let id = UUID()

        model.showInLog(id)

        #expect(model.pane == Pane.history)
        #expect(model.pendingHistorySelection == id,
                "the pane switched but nothing told it which row to select")
    }
}
