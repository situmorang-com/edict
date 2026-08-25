import Foundation
import Testing
@testable import EdictKit

/// Subtitle players are unforgiving about whitespace, separators and indices, so most of these are
/// byte-exact string comparisons rather than "contains" checks.
@Suite("TranscriptExport")
struct TranscriptExportTests {

    // MARK: Fixtures

    /// One segment per word, which is what the engine actually produces.
    private func perWordSegments(_ words: [String], start: TimeInterval = 0, step: TimeInterval = 0.5)
        -> [TranscriptSegment]
    {
        words.enumerated().map { index, word in
            TranscriptSegment(
                start: start + Double(index) * step,
                end: start + Double(index + 1) * step,
                text: word
            )
        }
    }

    private func imported(
        _ segments: [TranscriptSegment],
        filename: String = "recording.m4a",
        text: String? = nil
    ) -> Transcript {
        let joined = segments.map(\.text).joined(separator: " ")
        return Transcript(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            rawText: joined,
            text: text ?? joined,
            audioDuration: segments.last?.end ?? 0,
            source: .imported(filename: filename),
            segments: segments
        )
    }

    private let sentencePair = ["The", "quick", "brown", "fox", "jumps", "over", "the", "lazy", "dog", ".",
                                "It", "was", "fine", "."]

    // MARK: Byte-exact subtitle output

    @Test("SRT is byte-exact: 1-based indices, comma separator, blank line between cues, final newline")
    func srtByteExact() {
        let transcript = imported(perWordSegments(sentencePair))
        let srt = TranscriptExport.string(for: transcript, format: .srt)
        #expect(srt == """
        1
        00:00:00,000 --> 00:00:05,000
        The quick brown fox
        jumps over the lazy dog.

        2
        00:00:05,000 --> 00:00:07,000
        It was fine.

        """)
        // No trailing blank cue: exactly one newline at the end.
        #expect(srt.hasSuffix("It was fine.\n"))
        #expect(!srt.hasSuffix("\n\n"))
    }

    @Test("VTT is byte-exact: WEBVTT header, period separator, no cue identifiers")
    func vttByteExact() {
        let transcript = imported(perWordSegments(sentencePair))
        let vtt = TranscriptExport.string(for: transcript, format: .vtt)
        #expect(vtt == """
        WEBVTT

        00:00:00.000 --> 00:00:05.000
        The quick brown fox
        jumps over the lazy dog.

        00:00:05.000 --> 00:00:07.000
        It was fine.

        """)
        #expect(!vtt.hasSuffix("\n\n"))
    }

    @Test("Punctuation the engine emits as its own segment hugs the preceding word")
    func punctuationHugsPreviousWord() {
        let transcript = imported(perWordSegments(["Yes", ",", "really", "."]))
        #expect(TranscriptExport.cues(for: transcript).map(\.flatText) == ["Yes, really."])
    }

    // MARK: Timecodes

    @Test("Timecodes zero-pad hours and always carry exactly three decimal places")
    func timecodeFormatting() {
        #expect(TranscriptExport.timecode(0) == "00:00:00.000")
        #expect(TranscriptExport.timecode(1.24, decimalSeparator: ",") == "00:00:01,240")
        #expect(TranscriptExport.timecode(4.88) == "00:00:04.880")
        #expect(TranscriptExport.timecode(59.999) == "00:00:59.999")
        #expect(TranscriptExport.timecode(60) == "00:01:00.000")
        #expect(TranscriptExport.timecode(3723.004, decimalSeparator: ",") == "01:02:03,004")
        #expect(TranscriptExport.timecode(3600) == "01:00:00.000")
        // Negatives and non-finite values collapse to zero rather than trapping on the Int conversion.
        #expect(TranscriptExport.timecode(-5) == "00:00:00.000")
        #expect(TranscriptExport.timecode(.nan) == "00:00:00.000")
        #expect(TranscriptExport.timecode(.infinity) == "00:00:00.000")
        // A finite but absurd value is truncated at the 100-hour ceiling.
        #expect(TranscriptExport.timecode(1e12) == "99:59:59.999")
    }

    @Test("An hour-plus recording exports hour-plus timestamps")
    func hourPlusTimestamps() {
        let segments = [
            TranscriptSegment(start: 3723.004, end: 3725.5, text: "Still"),
            TranscriptSegment(start: 3725.5, end: 3727.25, text: "talking."),
        ]
        let srt = TranscriptExport.string(for: imported(segments), format: .srt)
        #expect(srt == """
        1
        01:02:03,004 --> 01:02:07,250
        Still talking.

        """)
    }

    @Test("Sub-second segments keep millisecond precision")
    func subSecondSegments() {
        let segments = [
            TranscriptSegment(start: 0.001, end: 0.4567, text: "Hi"),
            TranscriptSegment(start: 0.4567, end: 0.999, text: "there."),
        ]
        let vtt = TranscriptExport.string(for: imported(segments), format: .vtt)
        #expect(vtt == """
        WEBVTT

        00:00:00.001 --> 00:00:00.999
        Hi there.

        """)
    }

    @Test("A zero-length or inverted segment is widened, never emitted with end <= start")
    func zeroLengthSegmentsAreWidened() {
        let segments = [
            TranscriptSegment(start: 2, end: 2, text: "Zero."),
            TranscriptSegment(start: 4, end: 3, text: "Inverted."),
        ]
        let cues = TranscriptExport.cues(for: imported(segments))
        #expect(cues.count == 2)
        for cue in cues {
            #expect(cue.end > cue.start)
        }
        #expect(cues[0].start == 2)
        #expect(cues[0].end == 2 + TranscriptExport.minimumCueDuration)
        #expect(cues[1].start == 4)
        #expect(cues[1].end == 4 + TranscriptExport.minimumCueDuration)
        // And it still renders as a legal SRT block.
        #expect(TranscriptExport.string(for: imported(segments), format: .srt) == """
        1
        00:00:02,000 --> 00:00:02,080
        Zero.

        2
        00:00:04,000 --> 00:00:04,080
        Inverted.

        """)
    }

    // MARK: Cue merging

    @Test("Cues merge up to the character limit: at most two lines, each within 42 characters")
    func cueMergingRespectsTheCharacterLimit() {
        // A long run with no sentence boundary at all, so only the length rule can split it.
        let words = (1...60).map { "word\($0)" }
        let cues = TranscriptExport.cues(for: imported(perWordSegments(words)))
        #expect(cues.count > 1)
        for cue in cues {
            #expect(cue.lines.count <= 2)
            for line in cue.lines {
                #expect(line.count <= 42, "line over the limit: \(line)")
            }
        }
        // Nothing dropped and nothing duplicated.
        #expect(cues.map(\.flatText).joined(separator: " ") == words.joined(separator: " "))
        // Indices are 1-based and contiguous.
        #expect(cues.map(\.index) == Array(1...cues.count))
        // Cues stay in time order.
        for (previous, next) in zip(cues, cues.dropFirst()) {
            #expect(previous.start <= next.start)
        }
    }

    @Test("A cue breaks at a sentence boundary in preference to filling the line")
    func cueBreaksAtSentenceBoundary() {
        let cues = TranscriptExport.cues(
            for: imported(perWordSegments(["Stop", ".", "Go", "on", "then", "."]))
        )
        #expect(cues.map(\.flatText) == ["Stop.", "Go on then."])
    }

    @Test("A word longer than the line limit is never broken in half")
    func neverBreaksMidWord() {
        let long = String(repeating: "a", count: 60)
        let cues = TranscriptExport.cues(for: imported(perWordSegments(["short", long, "tail"])))
        let all = cues.flatMap(\.lines)
        #expect(all.contains(long), "the long word was split: \(all)")
        for line in all {
            // Every line is made only of whole words.
            for word in line.split(separator: " ") {
                #expect(["short", long, "tail"].contains(String(word)))
            }
        }
    }

    @Test("A one-line cue is emitted as one line, not padded to two")
    func shortCueStaysOneLine() {
        let cues = TranscriptExport.cues(for: imported(perWordSegments(["Just", "this", "."])))
        #expect(cues.count == 1)
        #expect(cues[0].lines == ["Just this."])
    }

    @Test("A multi-word segment is divided by word so one long final result cannot become one cue")
    func multiWordSegmentIsDivided() {
        // 96 characters in a single segment: too long for one cue, and only divisible if we split it.
        let sentence = String(repeating: "alpha beta gamma delta ", count: 4).trimmed
        let segment = TranscriptSegment(start: 0, end: 8, text: sentence)
        let cues = TranscriptExport.cues(for: imported([segment]))
        #expect(cues.count > 1)
        #expect(cues.map(\.flatText).joined(separator: " ") == sentence)
        for cue in cues {
            #expect(cue.end > cue.start)
            #expect(cue.start >= 0)
            #expect(cue.end <= 8)
        }
    }

    // MARK: Unicode

    @Test("Indonesian text survives intact, including punctuation as separate segments")
    func indonesianText() {
        let words = ["Ini", "adalah", "pengujian", "transkripsi", "bahasa", "Indonesia", ".",
                     "Terima", "kasih", "banyak", "."]
        let srt = TranscriptExport.string(for: imported(perWordSegments(words)), format: .srt)
        #expect(srt == """
        1
        00:00:00,000 --> 00:00:03,500
        Ini adalah pengujian
        transkripsi bahasa Indonesia.

        2
        00:00:03,500 --> 00:00:05,500
        Terima kasih banyak.

        """)
    }

    @Test("Non-ASCII characters count as one character each, and are not mangled")
    func unicodeCounting() {
        // Combining marks and emoji are single grapheme clusters, so the 42-character budget is
        // measured the way a reader sees it.
        let words = ["café", "naïve", "señor", "日本語", "🇮🇩", "e\u{0301}lan"]
        let cues = TranscriptExport.cues(for: imported(perWordSegments(words)))
        #expect(cues.count == 1)
        #expect(cues[0].lines == ["café naïve señor 日本語 🇮🇩 e\u{0301}lan"])
        let vtt = TranscriptExport.string(for: imported(perWordSegments(words)), format: .vtt)
        #expect(vtt.contains("🇮🇩"))
        #expect(String(data: TranscriptExport.data(for: imported(perWordSegments(words)), format: .vtt),
                       encoding: .utf8) == vtt)
    }

    // MARK: Empty and dictated

    @Test("No segments produces valid-but-empty subtitle output instead of crashing")
    func emptySegmentsAreValidButEmpty() {
        let empty = Transcript(rawText: "", text: "", source: .imported(filename: "silence.wav"))
        #expect(TranscriptExport.cues(for: empty).isEmpty)
        #expect(TranscriptExport.string(for: empty, format: .srt) == "")
        #expect(TranscriptExport.string(for: empty, format: .vtt) == "WEBVTT\n")
        #expect(TranscriptExport.string(for: empty, format: .txt) == "")
    }

    @Test("Segments that are pure whitespace are skipped rather than emitted as blank cues")
    func whitespaceOnlySegments() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "   "),
            TranscriptSegment(start: 1, end: 2, text: "\n\t"),
        ]
        #expect(TranscriptExport.cues(for: imported(segments)).isEmpty)
        #expect(TranscriptExport.string(for: imported(segments), format: .srt) == "")
    }

    @Test("A dictated transcript has no segments, so only TXT is offered")
    func dictatedExportsAsPlainTextOnly() {
        let dictated = Transcript(rawText: "hello there", text: "Hello there")
        #expect(dictated.source == .dictated)
        #expect(dictated.hasSegments == false)
        #expect(TranscriptExport.availableFormats(for: dictated) == [.txt])
        #expect(TranscriptExport.string(for: dictated, format: .txt) == "Hello there\n")
        #expect(TranscriptExport.string(for: dictated, format: .srt) == "")
        // Asking for timestamps on something with no timing falls back to the text, not to nothing.
        #expect(
            TranscriptExport.string(
                for: dictated,
                format: .txt,
                options: .init(includeTimestamps: true)
            ) == "Hello there\n"
        )
    }

    @Test("An imported transcript offers all three formats")
    func importedOffersAllFormats() {
        let transcript = imported(perWordSegments(["one", "two"]))
        #expect(TranscriptExport.availableFormats(for: transcript) == [.txt, .srt, .vtt])
        #expect(transcript.isImported)
    }

    // MARK: TXT

    @Test("TXT exports the corrected text, and timestamps only when asked")
    func plainTextRespectsTheCorrectedText() {
        let transcript = imported(perWordSegments(sentencePair), text: "Corrected version.")
        #expect(TranscriptExport.string(for: transcript, format: .txt) == "Corrected version.\n")
        #expect(TranscriptExport.string(
            for: transcript,
            format: .txt,
            options: .init(includeTimestamps: true)
        ) == """
        [00:00:00.000] The quick brown fox jumps over the lazy dog.
        [00:00:05.000] It was fine.

        """)
    }

    // MARK: Filenames and types

    @Test("The suggested filename swaps the source extension for the export's")
    func suggestedFilenames() {
        let transcript = imported(perWordSegments(["hi"]), filename: "recording.m4a")
        #expect(TranscriptExport.suggestedFilename(for: transcript, format: .srt) == "recording.srt")
        #expect(TranscriptExport.suggestedFilename(for: transcript, format: .vtt) == "recording.vtt")
        #expect(TranscriptExport.suggestedFilename(for: transcript, format: .txt) == "recording.txt")

        let video = imported(perWordSegments(["hi"]), filename: "Team Meeting 2026-08-24.mp4")
        #expect(TranscriptExport.suggestedFilename(for: video, format: .srt)
            == "Team Meeting 2026-08-24.srt")

        // A path or a path separator must not escape into the filename.
        let nasty = imported(perWordSegments(["hi"]), filename: "/Users/x/Movies/a:b.mov")
        #expect(TranscriptExport.suggestedFilename(for: nasty, format: .srt) == "a-b.srt")

        let blank = imported(perWordSegments(["hi"]), filename: "   ")
        #expect(TranscriptExport.suggestedFilename(for: blank, format: .txt).hasPrefix("Dictation-"))
    }

    @Test("A dictated transcript is named from its timestamp")
    func dictatedFilename() {
        let dictated = Transcript(createdAt: Date(timeIntervalSince1970: 0), rawText: "x", text: "x")
        let name = TranscriptExport.suggestedFilename(for: dictated, format: .txt)
        #expect(name.hasPrefix("Dictation-1970-01-0"))
        #expect(name.hasSuffix(".txt"))
        #expect(!name.contains("/"))
        #expect(!name.contains(":"))
    }

    @Test("Each format reports its own extension and a content type that keeps it")
    func formatMetadata() {
        #expect(TranscriptExportFormat.allCases.map(\.fileExtension) == ["txt", "srt", "vtt"])
        #expect(TranscriptExportFormat.txt.requiresSegments == false)
        #expect(TranscriptExportFormat.srt.requiresSegments)
        #expect(TranscriptExportFormat.vtt.requiresSegments)
        for format in TranscriptExportFormat.allCases {
            #expect(format.contentType.preferredFilenameExtension == format.fileExtension)
            #expect(format.contentType.conforms(to: .plainText))
            #expect(!format.displayName.isEmpty)
        }
    }

    // MARK: Degenerate options

    @Test("Absurd options cannot hang or crash the packer")
    func degenerateOptions() {
        let transcript = imported(perWordSegments(["alpha", "beta", "gamma", "delta"]))
        let zero = TranscriptExport.Options(charactersPerLine: 0, linesPerCue: 0)
        let cues = TranscriptExport.cues(for: transcript, options: zero)
        #expect(cues.count == 4)
        #expect(cues.map(\.flatText) == ["alpha", "beta", "gamma", "delta"])

        let negative = TranscriptExport.Options(charactersPerLine: -10, linesPerCue: -1)
        #expect(!TranscriptExport.string(for: transcript, format: .srt, options: negative).isEmpty)

        let generous = TranscriptExport.Options(charactersPerLine: 500, linesPerCue: 5)
        #expect(TranscriptExport.cues(for: transcript, options: generous).count == 1)
    }
}

// MARK: - Schema compatibility

/// The user has real transcripts in `~/Library/Application Support/Edict/history.json`. Adding
/// `source` and `segments` must not cost them a single one.
@Suite("Transcript schema compatibility")
@MainActor
struct TranscriptSchemaCompatibilityTests {

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// The pre-import on-disk shape, key for key, as `HistoryStore` wrote it before this change.
    private let legacyJSON = """
    [{"audioDuration":10.883375,"corrections":[],"createdAt":"2026-08-24T10:02:50Z",\
    "droppedBuffers":0,"engine":"apple.dictationtranscriber",\
    "id":"1CAAB372-5A55-47D9-8E33-AD3CCBB64FA4","injection":"notAttempted",\
    "localeIdentifier":"en-US","lowConfidenceWords":[],"rawText":"one two three",\
    "targetAppName":"Notes","targetBundleID":"com.apple.Notes","text":"One two three",\
    "transcribeDuration":0.0214},\
    {"audioDuration":38.19,"corrections":[],"createdAt":"2026-08-24T09:17:52Z","droppedBuffers":2,\
    "engine":"apple.dictationtranscriber","id":"38EDD6A8-8C01-4A85-88CE-F827DFC597F6",\
    "injection":"paste","localeIdentifier":"en-US","lowConfidenceWords":["a","."],\
    "rawText":"testing testing","text":"Testing testing","transcribeDuration":0.1995}]
    """

    @Test("A pre-import history file still decodes, defaulting to a dictated source and no segments")
    func legacyEntriesDecode() throws {
        let transcripts = try Self.decoder.decode([Transcript].self, from: Data(legacyJSON.utf8))
        #expect(transcripts.count == 2)
        for transcript in transcripts {
            #expect(transcript.source == .dictated)
            #expect(transcript.segments.isEmpty)
        }
        #expect(transcripts[0].text == "One two three")
        #expect(transcripts[0].droppedBuffers == 0)
        #expect(transcripts[1].droppedBuffers == 2)
        #expect(transcripts[1].lowConfidenceWords == ["a", "."])
        #expect(transcripts[1].targetAppName == nil)
    }

    @Test("A pre-import history file round-trips with nothing lost")
    func legacyRoundTripLosesNothing() throws {
        try assertRoundTripLosesNothing(Data(legacyJSON.utf8))
    }

    @Test("The real history.json on this machine round-trips with nothing lost")
    func realHistoryRoundTripLosesNothing() throws {
        let url = AppPaths.historyFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Nothing to verify on a machine that has never run the app.
            return
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return }
        try assertRoundTripLosesNothing(data)
    }

    @Test("Imported transcripts and their segments survive a round trip")
    func importedRoundTrip() throws {
        let original = Transcript(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            rawText: "hello world",
            text: "Hello world",
            audioDuration: 12.5,
            source: .imported(filename: "interview.mp4"),
            segments: [
                TranscriptSegment(start: 0, end: 0.5, text: "hello", confidence: 0.98),
                TranscriptSegment(start: 0.5, end: 1.0, text: "world"),
            ]
        )
        let data = try Self.encoder.encode([original])
        let decoded = try Self.decoder.decode([Transcript].self, from: data)

        // Everything a segment *means* survives. Its `id` deliberately does not: it is render-pass
        // identity, nothing persistent refers to it, and writing it was 45 of the ~100 bytes a
        // segment cost — which on a 377 s import (1007 segments) is the difference between 130 KB
        // and 72 KB per history entry. See `TranscriptSegment.encode(to:)`.
        #expect(decoded.count == 1)
        #expect(decoded[0].id == original.id)
        #expect(decoded[0].source == original.source)
        #expect(decoded[0].source.importedFilename == "interview.mp4")
        #expect(decoded[0].segments.map(\.start) == original.segments.map(\.start))
        #expect(decoded[0].segments.map(\.end) == original.segments.map(\.end))
        #expect(decoded[0].segments.map(\.text) == original.segments.map(\.text))
        #expect(decoded[0].segments[0].confidence == 0.98)
        #expect(decoded[0].segments[1].confidence == nil)
        // …and the id really is absent from the file, not merely tolerated on the way back in.
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains(original.segments[0].id.uuidString))
        // The transcript's own id is still written; only the segments' are dropped.
        #expect(json.contains(original.id.uuidString))
    }

    @Test("A segment id written by an older build is still read back")
    func legacySegmentIDIsRead() throws {
        let id = UUID()
        let json = """
        [{"createdAt":"2026-08-24T10:02:50Z","rawText":"a","text":"a",
          "source":{"kind":"imported","filename":"x.wav"},
          "segments":[{"id":"\(id.uuidString)","start":0,"end":1,"text":"a"}]}]
        """
        let decoded = try Self.decoder.decode([Transcript].self, from: Data(json.utf8))
        #expect(decoded[0].segments[0].id == id)
    }

    @Test("A malformed or unknown source degrades to dictated rather than failing the file")
    func malformedSourceIsTolerated() throws {
        let json = """
        [{"createdAt":"2026-08-24T10:02:50Z","rawText":"a","text":"a","source":{"kind":"telepathy"}},
         {"createdAt":"2026-08-24T10:02:51Z","rawText":"b","text":"b","source":"dictated"},
         {"createdAt":"2026-08-24T10:02:52Z","rawText":"c","text":"c","source":17,"segments":"nope"},
         {"createdAt":"2026-08-24T10:02:53Z","rawText":"d","text":"d","source":{"kind":"imported"}}]
        """
        let transcripts = try Self.decoder.decode([Transcript].self, from: Data(json.utf8))
        #expect(transcripts.count == 4)
        #expect(transcripts.map(\.source) == [
            .dictated, .dictated, .dictated, .imported(filename: ""),
        ])
        #expect(transcripts.allSatisfy { $0.segments.isEmpty })
    }

    @Test("A segment missing its optional keys still decodes")
    func lenientSegmentDecoding() throws {
        let json = """
        [{"start":1.5,"end":2.5,"text":"hi","confidence":0.4},{"text":"ho"},{"start":3}]
        """
        let segments = try Self.decoder.decode([TranscriptSegment].self, from: Data(json.utf8))
        #expect(segments.count == 3)
        #expect(segments[0].confidence == 0.4)
        #expect(segments[1].start == 0)
        #expect(segments[1].end == 0)
        #expect(segments[2].text == "")
        // A missing end defaults to the start, i.e. a zero-length segment the exporter then widens.
        #expect(segments[2].end == 3)
    }

    @Test("TranscriptSource reports its filename and display name")
    func sourceAccessors() {
        #expect(TranscriptSource.dictated.isImported == false)
        #expect(TranscriptSource.dictated.importedFilename == nil)
        #expect(TranscriptSource.dictated.displayName == "Dictated")
        let imported = TranscriptSource.imported(filename: "a.wav")
        #expect(imported.isImported)
        #expect(imported.importedFilename == "a.wav")
        #expect(imported.displayName == "a.wav")
        #expect(TranscriptSource.imported(filename: "").displayName == "Imported")
    }

    // MARK: Helper

    /// Decodes, re-encodes, and asserts that (a) the model survives a second decode unchanged and
    /// (b) every key/value in the original JSON is still present and equal in the re-encoded JSON.
    private func assertRoundTripLosesNothing(_ original: Data) throws {
        let decoded = try Self.decoder.decode([Transcript].self, from: original)
        let reencoded = try Self.encoder.encode(decoded)
        let redecoded = try Self.decoder.decode([Transcript].self, from: reencoded)
        // Segment ids are minted per decode by design — `TranscriptSegment.encode(to:)` does not
        // write them — so they are normalised away before the models are compared. Everything else,
        // including every segment's timing, text and confidence, must be identical.
        #expect(
            Self.withNormalisedSegmentIDs(decoded) == Self.withNormalisedSegmentIDs(redecoded),
            "the model did not survive a re-decode"
        )

        let before = try #require(
            JSONSerialization.jsonObject(with: original) as? [[String: Any]],
            "the original file is not an array of objects"
        )
        let after = try #require(JSONSerialization.jsonObject(with: reencoded) as? [[String: Any]])
        #expect(before.count == after.count)

        for (index, originalEntry) in before.enumerated() {
            let id = originalEntry["id"] as? String
            // Match by id where there is one, positionally otherwise; HistoryStore sorts on load but
            // this helper decodes the raw array, so the order is the file's.
            let newEntry = after.first { ($0["id"] as? String) == id && id != nil } ?? after[index]
            for (key, value) in originalEntry {
                guard let newValue = newEntry[key] else {
                    Issue.record("key '\(key)' was lost from entry \(index)")
                    continue
                }
                #expect(
                    Self.valuesMatch(Self.stripSegmentIDs(value), Self.stripSegmentIDs(newValue)),
                    "key '\(key)' changed in entry \(index): \(value) -> \(newValue)"
                )
            }
        }
    }

    /// Replaces every segment id with a positional one, so two decodes of the same bytes compare
    /// equal. See `TranscriptSegment.encode(to:)` for why the id is not persisted.
    private static func withNormalisedSegmentIDs(_ transcripts: [Transcript]) -> [Transcript] {
        transcripts.map { transcript in
            var copy = transcript
            copy.segments = transcript.segments.enumerated().map { index, segment in
                var s = segment
                s.id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))
                    ?? UUID()
                return s
            }
            return copy
        }
    }

    /// Drops the `id` key from a `segments` array read out of raw JSON, so a file written by a build
    /// that still persisted segment ids compares equal to one written by this build.
    private static func stripSegmentIDs(_ value: Any) -> Any {
        guard let array = value as? [[String: Any]] else { return value }
        // Only segment objects carry all three of these; a `corrections` array does not, and its
        // `entryID` must never be stripped — it points at a dictionary entry.
        guard array.allSatisfy({ $0["start"] != nil && $0["end"] != nil && $0["text"] != nil }) else {
            return value
        }
        return array.map { element -> [String: Any] in
            var copy = element
            copy.removeValue(forKey: "id")
            return copy
        }
    }

    /// JSON equality with two allowances: numbers compare with a tolerance (a `Double` that made a
    /// round trip through text can differ in the last bit), and ISO-8601 date strings compare as
    /// instants (the encoder may normalise the spelling).
    private static func valuesMatch(_ lhs: Any, _ rhs: Any) -> Bool {
        if let l = lhs as? NSNumber, let r = rhs as? NSNumber {
            return abs(l.doubleValue - r.doubleValue) < 0.000_001
        }
        if let l = lhs as? String, let r = rhs as? String {
            if l == r { return true }
            let formatter = ISO8601DateFormatter()
            if let ld = formatter.date(from: l), let rd = formatter.date(from: r) {
                return abs(ld.timeIntervalSince(rd)) < 1
            }
            return false
        }
        guard let l = lhs as? NSObject, let r = rhs as? NSObject else { return false }
        return l.isEqual(r)
    }
}
