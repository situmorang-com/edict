import AppKit
import Foundation
import SwiftUI
import Testing
@testable import EdictKit

// MARK: - Printing a language

/// How a language is *printed* in a fixed-width column, and the one case where two letters lie.
///
/// This is the smallest piece of the feature and the easiest to get quietly wrong. RECON amendment 45
/// is about the wrong acoustic model producing confident nonsense; a column that printed `EN` for both
/// `en-US` and `en-GB` would reproduce exactly that failure one level down — an indicator that
/// indicates nothing while looking like it works, which is worse than no column at all.
@Suite("Import language — printing")
struct LanguageCodePrintingTests {

    @Test("A badge is the language subtag, uppercased, whichever separator it arrived with")
    func badges() {
        #expect(LanguageCode.badge("id-ID") == "ID")
        // The framework hands back underscores (`DictationTranscriber.supportedLocales`) while
        // Settings and history store hyphens; both must badge the same.
        #expect(LanguageCode.badge("id_ID") == "ID")
        #expect(LanguageCode.badge("en-US") == "EN")
        #expect(LanguageCode.badge("en") == "EN")
        #expect(LanguageCode.badge("zh-Hant-TW") == "ZH")
    }

    @Test("Hyphenation is one spelling, so a readout never changes separator between panes")
    func hyphenation() {
        #expect(LanguageCode.hyphenated("id_ID") == "id-ID")
        #expect(LanguageCode.hyphenated("id-ID") == "id-ID")
    }

    @Test("Two languages sharing a subtag are ambiguous; a language is never ambiguous with itself")
    func ambiguity() {
        let mixedEnglish = ["en-US", "en-GB", "id-ID"]
        #expect(LanguageCode.isAmbiguous("en-US", among: mixedEnglish))
        #expect(LanguageCode.isAmbiguous("en-GB", among: mixedEnglish))
        // Indonesian shares its subtag with nothing here, so it stays a two-letter read even while
        // English on the same pane does not.
        #expect(!LanguageCode.isAmbiguous("id-ID", among: mixedEnglish))

        // The set always contains the identifier being asked about — every caller builds it by
        // collecting what is on screen — so self-comparison must not count.
        #expect(!LanguageCode.isAmbiguous("en-US", among: ["en-US", "id-ID"]))
        #expect(!LanguageCode.isAmbiguous("en-US", among: ["en-US", "en-US", "en_US"]))
        #expect(!LanguageCode.isAmbiguous("en-US", among: ["EN-us"]))
    }

    @Test("An ambiguous language prints its whole tag, an unambiguous one its badge")
    func codes() {
        #expect(LanguageCode.code("en-US", ambiguous: false) == "EN")
        #expect(LanguageCode.code("en-US", ambiguous: true) == "en-US")
        #expect(LanguageCode.code("id_ID", ambiguous: true) == "id-ID")
    }

    @Test("A language is spoken as a name, never as a code")
    func names() {
        // VoiceOver spells `ID` out letter by letter, so nothing accessible may be the code.
        let indonesian = LanguageCode.name("id-ID")
        #expect(indonesian != "ID")
        #expect(indonesian != "id-ID")
        #expect(!indonesian.isEmpty)
        // Underscored input must resolve too: the queue's picker list arrives that way.
        #expect(LanguageCode.name("id_ID") == indonesian)
        // An identifier nothing can name still says something more use than an empty label.
        #expect(LanguageCode.name("qq-QQ") == "qq-QQ")
    }
}

// MARK: - The row

/// What a queue row claims about its own language, and when it offers a second reading.
@Suite("Import language — the queue row")
struct ImportLanguageRowTests {

    private func finished(_ verdict: RecognitionQuality.Verdict?) -> ImportQueueRow {
        let quality = verdict.map {
            RecognitionQuality(verdict: $0, wordsPerMinute: 16, coverage: 0.2, explanation: "x")
        }
        let transcript = Transcript(
            rawText: "a", text: "a",
            localeIdentifier: "en-US",
            source: .imported(filename: "f.m4a"),
            quality: quality
        )
        return ImportQueueRow(filename: "f.m4a", state: .finished(transcript))
    }

    @Test("A finished row the recogniser under-read offers a language re-run; a good one does not")
    func rerunGate() {
        #expect(finished(.sparse).offersLanguageRerun)
        #expect(finished(.veryPoor).offersLanguageRerun)
        // Nothing to remedy, so nothing is offered. A key on every row is a key nobody reads, and the
        // one row that needed it would go past unremarked — the same argument `State.detail` makes.
        #expect(!finished(.good).offersLanguageRerun)
        // An older transcript with no verdict at all must not grow a button out of a missing field.
        #expect(!finished(nil).offersLanguageRerun)
    }

    @Test("Only a finished row offers a re-run — there is nothing to re-run before there is a result")
    func rerunNeedsAResult() {
        for state: ImportQueueRow.State in [
            .waiting, .reading(0.2), .transcribing(0.5), .failed("no"), .cancelled,
        ] {
            #expect(!ImportQueueRow(filename: "f.m4a", state: state).offersLanguageRerun)
        }
    }

    @Test("A row defaults to inheriting its language, and to not being editable")
    func defaults() {
        let row = ImportQueueRow(filename: "f.m4a")
        // The defaults have to match the *safe* reading. `localeWasChosen: false` means the surface
        // flags it as worth checking; `localeIsEditable: false` means a fixture cannot accidentally
        // offer to change the language of something already running.
        #expect(!row.localeWasChosen)
        #expect(!row.localeIsEditable)
        #expect(row.secondPassLocaleIdentifier == nil)
        #expect(!row.isRerun)
        #expect(row.localeIdentifier == Settings.Default.localeIdentifier)
    }
}

// MARK: - Honesty

/// The re-run copy, held to the measurement rather than to taste.
///
/// A language re-run helps when the language was wrong and not otherwise. Measured on a real
/// far-field multi-speaker meeting, Apple's model recognised ~16 words per minute in **either**
/// language, and conditioning the audio moved it only from 61 to 75 words. So the button is not
/// allowed to imply it is a remedy for difficult audio: someone who believes it is will spend another
/// 70 minutes waiting for the same nonsense. This is a wording test because the wording is the
/// deliverable — the requirement is "must not promise", which nothing else can check.
@MainActor
@Suite("Import language — honest wording")
struct ImportLanguageWordingTests {

    @Test("The re-run offer says what it will do, and refuses to promise a fix for bad audio")
    func rerunCopy() {
        let copy = ImportQueueRow.languageRerunExplanation

        // Says what happens, in the specific terms the brief asks for: a new row, the old transcript
        // kept, so the two can be compared. The user cannot tell the second transcript is better
        // without the first still on screen.
        #expect(copy.contains("as a new row"))
        #expect(copy.localizedCaseInsensitiveContains("kept"))
        #expect(copy.localizedCaseInsensitiveContains("compare"))

        // Names the case it actually helps with.
        #expect(copy.localizedCaseInsensitiveContains("language was wrong"))

        // And the disclaimer, which is the half a cheerful rewrite would drop first.
        #expect(copy.localizedCaseInsensitiveContains("will not rescue difficult audio"))
        #expect(copy.localizedCaseInsensitiveContains("either language"))
    }

    @Test("The dual-pass rule the pane prints is the rule the queue applies")
    func dualPassRule() {
        // The pane must not paraphrase this. `ImportQueue.dualPassRule` is the queue's own one-sentence
        // statement of what a per-item locale means when dual pass is on, and the surface quotes it
        // verbatim precisely so the two cannot drift into describing different behaviour.
        let rule = ImportQueue.dualPassRule
        #expect(rule.localizedCaseInsensitiveContains("first of the two"))
        #expect(rule.localizedCaseInsensitiveContains("second dictation language"))
    }
}

// MARK: - Wiring

/// That the surface is fed the *item's* language, and that nothing reads `Settings` behind its back.
///
/// This is the regression the whole feature exists to prevent, expressed at the seam the views use:
/// `AppModel.importRows`. The original bug was `resolvedImportModule()` reading
/// `Settings.localeIdentifier` at transcription time; a row that re-derived its tag from Settings
/// would put the honest-looking tag on a dishonest transcript, which is worse than no tag.
@MainActor
@Suite("Import language — surface wiring")
struct ImportLanguageWiringTests {

    private func model() -> AppModel {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-import-lang-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return AppModel(
            settings: Settings(defaults: EphemeralDefaults()),
            dictionary: DictionaryStore(fileURL: root.appendingPathComponent("dictionary.json")),
            history: HistoryStore(fileURL: root.appendingPathComponent("history.json"))
        )
    }

    private let file = URL(fileURLWithPath: "/tmp/edict-import-language-fixture.m4a")

    @Test("A queued row keeps the language it was enqueued with when the dictation language changes")
    func rowKeepsItsLanguage() {
        let model = model()
        model.settings.localeIdentifier = "id-ID"
        model.enqueueImports([file])

        #expect(model.importRows.count == 1)
        #expect(model.importRows[0].localeIdentifier == "id-ID")
        // Inherited, not chosen — which is what makes the surface flag it as worth a second look.
        #expect(!model.importRows[0].localeWasChosen)

        // The setting moves; the row must not. This is the bug, exactly: a file sitting in the queue
        // changed language under the user if they touched the dictation picker.
        model.settings.localeIdentifier = "en-US"
        #expect(model.importRows[0].localeIdentifier == "id-ID")
    }

    @Test("The pane's override decides what new files get, and leaves the dictation language alone")
    func overrideAppliesToNewFilesOnly() {
        let model = model()
        model.settings.localeIdentifier = "en-US"

        // Nothing set: follow the dictation language, and keep following it.
        #expect(model.importLocaleOverride == nil)

        model.importLocaleOverride = "id-ID"
        model.enqueueImports([file])
        #expect(model.importRows.first?.localeIdentifier == "id-ID")
        // Chosen, so the row stops flagging itself as a default.
        #expect(model.importRows.first?.localeWasChosen == true)
        // The dictation language is a different fact and must be untouched: this pane changes what
        // files are transcribed in, never what the hotkey does.
        #expect(model.settings.localeIdentifier == "en-US")

        // Clearing goes back to *tracking* Settings rather than to a frozen copy of it.
        model.importLocaleOverride = nil
        model.settings.localeIdentifier = "de-DE"
        model.enqueueImports([URL(fileURLWithPath: "/tmp/edict-import-language-second.m4a")])
        #expect(model.importRows.contains { $0.localeIdentifier == "de-DE" })
    }

    @Test("Five files dropped together can then be moved one at a time")
    func perFileNotGlobal() {
        let model = model()
        model.settings.localeIdentifier = "en-US"
        let urls = (1...5).map { URL(fileURLWithPath: "/tmp/edict-lang-\($0).m4a") }
        model.enqueueImports(urls)
        #expect(model.importRows.count == 5)

        // One row moves. The point of the feature: dropping five files must not force one language on
        // all of them.
        guard let target = model.importRows.first(where: { $0.localeIsEditable }) else {
            Issue.record("a freshly queued row must be editable")
            return
        }
        model.importQueue.setLocale("id-ID", for: target.id)

        let byID = Dictionary(uniqueKeysWithValues: model.importRows.map { ($0.id, $0) })
        #expect(byID[target.id]?.localeIdentifier == "id-ID")
        #expect(byID[target.id]?.localeWasChosen == true)
        #expect(model.importRows.count { $0.localeIdentifier == "en-US" } == 4)
    }

    @Test("A re-run is a new row beside the old one, in the new language, marked as a re-run")
    func rerunIsAPair() {
        let model = model()
        model.settings.localeIdentifier = "en-US"
        guard let first = model.importQueue.enqueue(file) else {
            Issue.record("enqueue produced no row")
            return
        }
        // Terminal is the precondition `rerun` enforces; drive it there the way a failure would.
        model.importQueue.cancel(first)

        let second = model.importQueue.rerun(first, localeIdentifier: "id-ID")
        #expect(second != nil)

        let rows = model.importRows
        #expect(rows.count == 2)
        // Adjacent, so the pair the user is comparing stays together in a tray of twenty.
        #expect(rows[0].id == first)
        #expect(rows[1].id == second)
        #expect(rows[0].localeIdentifier == "en-US")
        #expect(rows[1].localeIdentifier == "id-ID")
        // The surface marks the second row, because the comparison is the whole point.
        #expect(!rows[0].isRerun)
        #expect(rows[1].isRerun)
        #expect(rows[1].localeWasChosen)
    }

    @Test("A running or finished row is not offered an editable language")
    func editabilityFollowsState() {
        let model = model()
        guard let id = model.importQueue.enqueue(file) else {
            Issue.record("enqueue produced no row")
            return
        }
        #expect(model.importRows[0].localeIsEditable)

        model.importQueue.cancel(id)
        // The analyzer is built from exactly one `Locale` and never rebuilt (RECON §3), so there is no
        // such thing as changing a settled row's language. The surface must not offer it.
        #expect(!model.importRows[0].localeIsEditable)
        #expect(!model.importQueue.setLocale("id-ID", for: id))
        #expect(model.importRows[0].localeIdentifier == Settings.Default.localeIdentifier)
    }

    @Test("Dual pass is reported per row, and not at all when it is switched off")
    func dualPassOnTheRow() {
        let model = model()
        model.settings.localeIdentifier = "en-US"
        model.settings.secondaryLocaleIdentifier = "id-ID"
        model.settings.importDualPass = false
        #expect(model.importDualPassLocaleIdentifier == nil)

        model.settings.importDualPass = true
        #expect(model.importDualPassLocaleIdentifier == "id-ID")
        model.enqueueImports([file])
        // The row's own language is the *first* pass; this is the second. See `ImportQueue.dualPassRule`.
        #expect(model.importRows.first?.secondPassLocaleIdentifier == "id-ID")

        // A row already in the second language has nothing to pair with, so the pane must not print
        // an arrow from a language to itself.
        guard let id = model.importRows.first?.id else { return }
        model.importQueue.setLocale("id-ID", for: id)
        #expect(model.importRows.first?.secondPassLocaleIdentifier == nil)
    }
}

// MARK: - Rendering

/// The pane draws, in every language state, and the proof sheets exist.
///
/// RECON amendment 40: Screen Recording is denied to any process an agent starts, so a rendered sheet
/// is the only way this surface gets looked at before it ships — and `ImageRenderer` does not
/// rasterise a `ScrollView`'s contents, which is why every queue sheet is `unbounded`.
@MainActor
@Suite("Import language — rendering")
struct ImportLanguageRenderTests {

    /// The sheets this pass added. Named here so the presence check and the PNG writer cannot
    /// drift apart — a sheet that stopped being rendered would otherwise still be "checked".
    static let languageSheetIDs = [
        "pane-import-languages",
        "pane-import-language-chosen",
        "pane-import-language-poor",
        "pane-import-language-dualpass",
        "import-language-tray",
        "import-language-rerun",
        "pane-history-languages",
    ]

    @Test("Every language sheet is present")
    func sheetsExist() {
        let ids = Set(ImportPreviewFixtures.renderSheets().map(\.id))
        for id in Self.languageSheetIDs {
            #expect(ids.contains(id), "missing sheet \(id)")
        }
    }

    @Test("The tags a two-language queue prints stay two letters, and go long only when they must")
    func fixtureTags() {
        // The shipped fixture pairs `en-US` with `id-ID`, which badge differently, so both rows stay
        // at the fast two-letter read.
        let locales = ImportPreviewFixtures.bilingualQueue.map(\.localeIdentifier)
        #expect(Set(locales) == ["en-US", "id-ID"])
        for locale in locales {
            #expect(!LanguageCode.isAmbiguous(locale, among: locales))
        }
        // And the fixture list the picker offers does contain the collision, so the picker sheet is
        // rendered against a list where disambiguation is reachable.
        #expect(ImportPreviewFixtures.sampleLocales.contains("en-GB"))
        #expect(LanguageCode.isAmbiguous("en-US", among: ImportPreviewFixtures.sampleLocales))
        // Indonesian is the case the feature exists for: present only in the dictation module.
        #expect(ImportPreviewFixtures.sampleLocales.contains("id-ID"))
    }

    @Test("The poor-quality fixture is the one that offers a re-run, and the good one is not")
    func poorQualityOffersRerun() {
        #expect(ImportPreviewFixtures.poorQualityQueue.allSatisfy { $0.offersLanguageRerun })
        // The English-on-Indonesian row is the point: its *rate* was fine, so no warning fires and the
        // language tag is the only thing that catches it. If this ever starts offering a re-run, the
        // gate has drifted onto something other than the verdict.
        #expect(!ImportPreviewFixtures.bilingualQueue.contains { $0.offersLanguageRerun })
    }

    /// Writes the sheets for a human to look at. `EDICT_RENDER_DIR` picks the directory.
    @Test("Render the language proof sheets")
    func renderLanguageSheets() throws {
        let directory = URL(
            fileURLWithPath: ProcessInfo.processInfo.environment["EDICT_RENDER_DIR"]
                ?? NSTemporaryDirectory(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let wanted = Set(Self.languageSheetIDs)
        let sheets = ImportPreviewFixtures.renderSheets().filter { wanted.contains($0.id) }
        #expect(sheets.count == wanted.count)

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            guard let nsAppearance = NSAppearance(named: appearance) else { continue }
            for sheet in sheets {
                // The tokens resolve through `NSColor(name:dynamicProvider:)`, which reads the
                // *current drawing appearance* rather than SwiftUI's `colorScheme`, so both have to
                // be set or the dark sheet comes back in light colours.
                var image: NSImage?
                nsAppearance.performAsCurrentDrawingAppearance {
                    let renderer = ImageRenderer(
                        content: sheet.view.environment(\.colorScheme, name == "dark" ? .dark : .light)
                    )
                    renderer.scale = 2
                    image = renderer.nsImage
                }
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else {
                    Issue.record("could not rasterise \(sheet.id) \(name)")
                    continue
                }
                // A blank sheet would pass a nil check while proving nothing. The queue tray is the
                // whole subject, so a sheet narrower than a pane means the `unbounded` hatch stopped
                // working and `ImageRenderer` swallowed the rows again.
                #expect(image.size.width > 100, "\(sheet.id) \(name) rasterised empty")
                try png.write(to: directory.appendingPathComponent("\(sheet.id)-\(name).png"))
            }
        }
    }
}
