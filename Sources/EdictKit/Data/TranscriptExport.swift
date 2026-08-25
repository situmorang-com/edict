import Foundation
import UniformTypeIdentifiers

// MARK: - Format

/// The three text formats a transcript can be written as. SRT and VTT need timing, so they are only
/// offered for transcripts that have segments — see `TranscriptExport.availableFormats(for:)`.
public enum TranscriptExportFormat: String, Codable, Hashable, Sendable, CaseIterable {
    case txt
    case srt
    case vtt

    public var fileExtension: String { rawValue }

    public var displayName: String {
        switch self {
        case .txt: "Plain Text"
        case .srt: "SubRip"
        case .vtt: "WebVTT"
        }
    }

    /// True for the subtitle formats, which are meaningless without segment timings.
    public var requiresSegments: Bool { self != .txt }

    public var contentType: UTType {
        switch self {
        case .txt:
            .plainText
        case .srt, .vtt:
            // macOS declares no system type for SubRip or WebVTT. A dynamic type derived from the
            // extension still constrains a save panel to the right suffix, which is the only thing
            // we need it for; `.plainText` alone would let the panel rewrite `.srt` to `.txt`.
            UTType(filenameExtension: fileExtension, conformingTo: .plainText) ?? .plainText
        }
    }
}

// MARK: - Export

/// Renders a `Transcript` as plain text or subtitles.
///
/// The engine reports one segment per word (RECON §4: final results arrive as disjoint, monotonic but
/// *non-contiguous* ranges), and one subtitle cue per word is unreadable — so segments are merged into
/// cues of roughly `Options.charactersPerLine` characters over at most `Options.linesPerCue` lines,
/// preferring to break where a sentence ends and never breaking inside a word.
///
/// Uninhabited: this is a namespace, not a value.
public enum TranscriptExport: Sendable {

    // MARK: Options

    public struct Options: Hashable, Sendable {
        /// Include `[HH:MM:SS.mmm]` prefixes in TXT output. Ignored by SRT and VTT, which always
        /// carry timing.
        public var includeTimestamps: Bool
        /// Target line length. 42 is the long-standing subtitling convention — wider lines start to
        /// outrun the reader on a video frame.
        public var charactersPerLine: Int
        /// Hard ceiling on lines per cue. Two is the convention; more covers the frame.
        public var linesPerCue: Int

        public init(includeTimestamps: Bool = false, charactersPerLine: Int = 42, linesPerCue: Int = 2) {
            self.includeTimestamps = includeTimestamps
            self.charactersPerLine = charactersPerLine
            self.linesPerCue = linesPerCue
        }

        public static let `default` = Options()

        /// Guards against a caller passing 0 or a negative, which would loop or crash the packer.
        var safeCharactersPerLine: Int { max(1, charactersPerLine) }
        var safeLinesPerCue: Int { max(1, linesPerCue) }
    }

    // MARK: Cue

    /// One merged, line-broken subtitle cue. `index` is 1-based, as SRT requires.
    public struct Cue: Hashable, Sendable, Identifiable {
        public var index: Int
        public var start: TimeInterval
        public var end: TimeInterval
        public var lines: [String]

        public init(index: Int, start: TimeInterval, end: TimeInterval, lines: [String]) {
            self.index = index
            self.start = start
            self.end = end
            self.lines = lines
        }

        public var id: Int { index }
        /// The cue's text with its hard line breaks, exactly as written to the file.
        public var text: String { lines.joined(separator: "\n") }
        /// The cue's text on one line, for TXT output and for the UI.
        public var flatText: String { lines.joined(separator: " ") }
        public var duration: TimeInterval { max(0, end - start) }
    }

    /// A cue whose `end` is not after its `start` is invalid — players either drop it or flash it for
    /// a frame. When the engine hands us one (zero-length segments are real; RECON §4 warns that
    /// ranges are not contiguous) we widen it by this much: long enough to render, short enough not to
    /// collide with the next cue. Two frames at 25 fps.
    public static let minimumCueDuration: TimeInterval = 0.08

    /// Timecodes are clamped below 100 hours. A nonsense duration should truncate, never trap on the
    /// `Int` conversion.
    private static let maximumTimecode: TimeInterval = 359_999.999

    // MARK: Entry points

    public static func availableFormats(for transcript: Transcript) -> [TranscriptExportFormat] {
        TranscriptExportFormat.allCases.filter { !$0.requiresSegments || transcript.hasSegments }
    }

    public static func string(
        for transcript: Transcript,
        format: TranscriptExportFormat,
        options: Options = .default
    ) -> String {
        switch format {
        case .txt: plainText(for: transcript, options: options)
        case .srt: subRip(for: transcript, options: options)
        case .vtt: webVTT(for: transcript, options: options)
        }
    }

    /// UTF-8 bytes of `string(for:format:options:)`. Both subtitle formats are UTF-8 by spec.
    public static func data(
        for transcript: Transcript,
        format: TranscriptExportFormat,
        options: Options = .default
    ) -> Data {
        Data(string(for: transcript, format: format, options: options).utf8)
    }

    // MARK: Filenames

    /// `recording.m4a` → `recording.srt`. Dictated transcripts, which have no source file, are named
    /// from their timestamp.
    public static func suggestedFilename(
        for transcript: Transcript,
        format: TranscriptExportFormat
    ) -> String {
        "\(suggestedBaseName(for: transcript)).\(format.fileExtension)"
    }

    public static func suggestedBaseName(for transcript: Transcript) -> String {
        let raw: String
        if let filename = transcript.source.importedFilename, !filename.trimmed.isEmpty {
            // `lastPathComponent` in case a full path ever reaches us; the extension goes so `.srt`
            // does not land on top of `.m4a`.
            raw = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        } else {
            raw = "Dictation-\(Self.filenameDateFormatter.string(from: transcript.createdAt))"
        }
        let sanitized = sanitizeForFilename(raw)
        return sanitized.isEmpty ? "Transcript" : sanitized
    }

    /// POSIX locale and a fixed pattern: a filename must not change shape with the user's region.
    private static let filenameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    private static func sanitizeForFilename(_ name: String) -> String {
        // `/` is the path separator and `:` still is in the Finder's eyes; control characters would
        // produce a filename nobody can retype.
        let mapped = name.map { ch -> Character in
            if ch == "/" || ch == ":" || ch == "\\" || ch.isNewline { return "-" }
            if let scalar = ch.unicodeScalars.first, scalar.properties.generalCategory == .control { return "-" }
            return ch
        }
        return String(mapped).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Timecode

    /// `HH:MM:SS` zero-padded, then exactly three decimal places. `,` for SRT, `.` for VTT — players
    /// reject the wrong separator outright.
    public static func timecode(_ seconds: TimeInterval, decimalSeparator: String = ".") -> String {
        let bounded = seconds.isFinite ? min(max(0, seconds), maximumTimecode) : 0
        let totalMilliseconds = Int((bounded * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        return String(
            format: "%02d:%02d:%02d%@%03d",
            totalSeconds / 3600,
            (totalSeconds % 3600) / 60,
            totalSeconds % 60,
            decimalSeparator,
            milliseconds
        )
    }

    // MARK: Cue building

    public static func cues(for transcript: Transcript, options: Options = .default) -> [Cue] {
        let tokens = timedTokens(from: transcript.segments)
        guard !tokens.isEmpty else { return [] }

        var cues: [Cue] = []
        var pending: [TimedToken] = []
        var clampedCount = 0

        func flush() {
            guard let first = pending.first, let last = pending.last else { return }
            let start = max(0, first.start)
            var end = max(0, last.end)
            if end <= start {
                end = start + minimumCueDuration
                clampedCount += 1
            }
            cues.append(
                Cue(
                    index: cues.count + 1,
                    start: start,
                    end: end,
                    lines: layout(pending.map(\.text), options: options)
                )
            )
            pending.removeAll(keepingCapacity: true)
        }

        for token in tokens {
            if pending.isEmpty {
                pending.append(token)
            } else if fits(pending.map(\.text) + [token.text], options: options) {
                pending.append(token)
            } else {
                flush()
                pending.append(token)
            }
            // Prefer a sentence boundary over a full cue: a cue that ends mid-clause reads worse than
            // a short one.
            if endsSentence(token.text) { flush() }
        }
        flush()

        if clampedCount > 0 {
            Log.data.notice(
                "Export widened \(clampedCount, privacy: .public) cue(s) whose end was not after their start"
            )
        }
        return cues
    }

    // MARK: Renderers

    private static func plainText(for transcript: Transcript, options: Options) -> String {
        guard options.includeTimestamps else {
            let body = transcript.text.trimmed
            // Valid-but-empty rather than a lone newline: an empty transcript should export an empty
            // file.
            return body.isEmpty ? "" : body + "\n"
        }
        let cues = cues(for: transcript, options: options)
        guard !cues.isEmpty else {
            // No timing available (a dictated transcript). Fall back rather than lose the text.
            let body = transcript.text.trimmed
            return body.isEmpty ? "" : body + "\n"
        }
        return cues
            .map { "[\(timecode($0.start))] \($0.flatText)" }
            .joined(separator: "\n") + "\n"
    }

    private static func subRip(for transcript: Transcript, options: Options) -> String {
        let cues = cues(for: transcript, options: options)
        guard !cues.isEmpty else { return "" }
        let blocks = cues.map { cue in
            """
            \(cue.index)
            \(timecode(cue.start, decimalSeparator: ",")) --> \(timecode(cue.end, decimalSeparator: ","))
            \(cue.text)
            """
        }
        // One blank line between cues, none trailing, and a final newline.
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func webVTT(for transcript: Transcript, options: Options) -> String {
        let cues = cues(for: transcript, options: options)
        // A header on its own is a valid, empty WebVTT file.
        guard !cues.isEmpty else { return "WEBVTT\n" }
        let blocks = cues.map { cue in
            """
            \(timecode(cue.start)) --> \(timecode(cue.end))
            \(cue.text)
            """
        }
        return "WEBVTT\n\n" + blocks.joined(separator: "\n\n") + "\n"
    }

    // MARK: Tokens

    private struct TimedToken {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
    }

    private static func timedTokens(from segments: [TranscriptSegment]) -> [TimedToken] {
        // Sorted defensively — a cue list out of order is a broken subtitle file. The original index
        // breaks ties so equal starts keep the order the engine reported them in.
        let ordered = segments.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)

        var tokens: [TimedToken] = []
        for segment in ordered {
            let words = segment.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !words.isEmpty else { continue }
            guard words.count > 1 else {
                tokens.append(TimedToken(text: words[0], start: segment.start, end: segment.end))
                continue
            }
            // A multi-word segment must still be divisible, or one long final result becomes a single
            // unreadable cue. Time is apportioned by character count: the word boundaries are real,
            // the instants between them are an estimate.
            let duration = max(0, segment.end - segment.start)
            let totalCharacters = words.reduce(0) { $0 + $1.count }
            var consumed = 0
            for word in words {
                let start = segment.start + duration * Double(consumed) / Double(totalCharacters)
                consumed += word.count
                let end = segment.start + duration * Double(consumed) / Double(totalCharacters)
                tokens.append(TimedToken(text: word, start: start, end: end))
            }
        }
        return tokens
    }

    // MARK: Line breaking

    /// Punctuation that belongs to the word before it. The engine emits `.` and `,` as separate
    /// tokens (observed in real history), so without this every sentence would read "word ."
    private static let hugsPreviousWord: Set<Character> = [
        ".", ",", ";", ":", "!", "?", "…", ")", "]", "}", "%",
        "’", "”", "»", "。", "，", "、", "！", "？", "；", "：",
    ]
    /// Punctuation the following word belongs to.
    private static let hugsNextWord: Set<Character> = ["(", "[", "{", "“", "«", "¿", "¡"]

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let closingMarks: Set<Character> = ["\"", "'", ")", "]", "}", "»", "’", "”"]

    private static func appending(_ token: String, to text: String) -> String {
        guard !text.isEmpty else { return token }
        if let first = token.first, hugsPreviousWord.contains(first) { return text + token }
        if let last = text.last, hugsNextWord.contains(last) { return text + token }
        return text + " " + token
    }

    private static func joinTokens(_ tokens: some Sequence<String>) -> String {
        tokens.reduce(into: "") { $0 = appending($1, to: $0) }
    }

    /// A quote or bracket after the full stop does not cancel it: `he said "stop."` still ends here.
    private static func endsSentence(_ token: String) -> Bool {
        var trimmed = Substring(token)
        while let last = trimmed.last, closingMarks.contains(last) { trimmed = trimmed.dropLast() }
        guard let last = trimmed.last else { return false }
        return sentenceTerminators.contains(last)
    }

    /// Greedy first-fit, which minimises the line count for a fixed word order — so it is exactly the
    /// right feasibility test. `nil` means the tokens need more than `linesPerCue` lines.
    private static func greedyLines(_ tokens: [String], options: Options) -> [String]? {
        let maxChars = options.safeCharactersPerLine
        let maxLines = options.safeLinesPerCue
        var lines: [String] = []
        var current = ""
        for token in tokens {
            if current.isEmpty {
                current = token
                continue
            }
            let candidate = appending(token, to: current)
            if candidate.count <= maxChars {
                current = candidate
            } else {
                lines.append(current)
                if lines.count == maxLines { return nil }
                current = token
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.count <= maxLines ? lines : nil
    }

    private static func fits(_ tokens: [String], options: Options) -> Bool {
        greedyLines(tokens, options: options) != nil
    }

    /// Final layout. Greedy packing leaves a long first line and a stub second one, so for the
    /// two-line case (the default, and the convention) the break is placed to balance them.
    private static func layout(_ tokens: [String], options: Options) -> [String] {
        let maxChars = options.safeCharactersPerLine
        let whole = joinTokens(tokens)
        if whole.count <= maxChars { return [whole] }

        if options.safeLinesPerCue == 2, tokens.count > 1 {
            var best: (index: Int, difference: Int)?
            for split in 1..<tokens.count {
                let first = joinTokens(tokens[..<split])
                let second = joinTokens(tokens[split...])
                guard first.count <= maxChars, second.count <= maxChars else { continue }
                let difference = abs(first.count - second.count)
                if best == nil || difference < best!.difference {
                    best = (split, difference)
                }
            }
            if let best {
                return [joinTokens(tokens[..<best.index]), joinTokens(tokens[best.index...])]
            }
            // No break keeps both lines inside the limit — a single word longer than a line. Fall
            // through: overflowing is the lesser evil, because breaking mid-word is not an option.
        }
        return greedyLines(tokens, options: options) ?? [whole]
    }
}
