import Foundation

// MARK: - Rule

/// A prepared, order-sensitive replacement rule. Immutable and `Sendable` so the correction pass can
/// run off the main actor while the store that produced it stays main-actor isolated.
public struct CorrectionRule: Sendable, Hashable, Identifiable {
    /// Same identity as the originating `DictionaryEntry`, so hits can be attributed back to it.
    public var id: UUID

    /// The regex the rule is *equivalent* to, exposed for the UI's "explain this rule" affordance.
    ///
    /// The matcher does not actually run this pattern — see `Corrector.apply(to:)` for why a single
    /// left-to-right scan is required instead — but it is generated from the same tokens and separator
    /// class, so it describes what the rule matches. Two deliberate simplifications: the real separator
    /// class also accepts the Unicode hyphens U+2010/U+2011, and the real word-boundary check treats a
    /// Latin↔CJK seam as a boundary where ICU's `\b` would not.
    public var pattern: String

    /// Inserted verbatim, exactly as the user typed it (CONTRACTS corrector rule 2).
    public var replacement: String

    /// Higher sorts first. Longer/more-specific rules win; see `Corrector.init(rules:)`.
    public var sortWeight: Int

    /// The `heard` side split into tokens, in original case. The matcher compares these
    /// case-insensitively and allows an optional `[\s\-_]*` separator between adjacent tokens.
    let tokens: [String]

    /// True when this rule exists only to fix capitalisation of an already-correct word (produced by
    /// `.term` entries under `Settings.termCaseNormalisation`). Such rules lose ties against real
    /// corrections and, when the text already matches, must produce no `CorrectionHit` at all.
    let isCaseNormalisationOnly: Bool

    public init(entryID: UUID, heard: String, write: String) {
        let tokens = CorrectionRule.tokenise(heard)
        self.id = entryID
        self.tokens = tokens
        self.replacement = write
        self.isCaseNormalisationOnly = heard.compare(write, options: [.caseInsensitive]) == .orderedSame
        self.pattern = CorrectionRule.regexPattern(for: tokens)

        // Primary key is matched-phrase length in characters, secondary is token count
        // (CONTRACTS corrector rule 3). The trailing bit demotes case-normalisation rules so that a
        // real correction always beats a normalisation rule of the same length.
        let charCount = tokens.reduce(0) { $0 + $1.count }
        self.sortWeight = charCount * 1000 + min(tokens.count, 99) * 10 + (isCaseNormalisationOnly ? 0 : 1)
    }

    /// True when the rule can never match anything (blank `heard`).
    var isUsable: Bool { !tokens.isEmpty }

    /// Split on exactly the separator class the matcher allows *between* tokens, so a `heard` of
    /// `cloud-code` and one of `cloud code` compile to the identical rule — which is what a user
    /// hand-editing dictionary.json expects.
    static func tokenise(_ heard: String) -> [String] {
        heard.split(whereSeparator: Corrector.isSeparator)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    static func regexPattern(for tokens: [String]) -> String {
        guard !tokens.isEmpty else { return "" }
        let escaped = tokens.map { NSRegularExpression.escapedPattern(for: $0) }
        return "\\b" + escaped.joined(separator: "[\\s\\-_]*") + "\\b"
    }
}

// MARK: - Corrector

/// Layer 2 of the two-layer dictionary: the guaranteed find-and-replace pass that runs on the raw
/// transcript. RECON §5 is explicit that acoustic biasing (layer 1) alone is not reliable, so this is
/// where "cloud code" is *made* to become "Claude Code" rather than merely encouraged to.
///
/// ## Why this is a hand-written scan and not `replacingOccurrences` or a big alternation
///
/// Chaining `replacingOccurrences` cascades: rule B happily rewrites rule A's output, so
/// `cloud`→`Claude` followed by `Claude`→`Claude Code` yields `Claude Code Code`. CONTRACTS corrector
/// rule 6 forbids that outright. A single regex alternation would fix the cascade but not the
/// longest-match requirement — ICU alternation is leftmost-*first*, not leftmost-longest, so
/// `cloud code|cloud code assistant` would match the short branch and strand the rest.
///
/// So: one left-to-right pass. At every candidate position, try every rule, keep the longest actual
/// match, emit the replacement into an output buffer, and jump past it. Output is never re-examined.
public struct Corrector: Sendable {
    /// Sorted highest weight first, ties broken by original array order — which `DictionaryStore`
    /// supplies in entry-creation order, satisfying the "deterministic tie-break" requirement.
    private let rules: [CorrectionRule]

    public init(rules: [CorrectionRule]) {
        // `sort` is not documented as stable, so the index is folded into the comparison explicitly.
        self.rules = rules
            .filter(\.isUsable)
            .enumerated()
            .sorted { a, b in
                a.element.sortWeight != b.element.sortWeight
                    ? a.element.sortWeight > b.element.sortWeight
                    : a.offset < b.offset
            }
            .map(\.element)
    }

    public var isEmpty: Bool { rules.isEmpty }

    public func apply(to text: String) -> CorrectionResult {
        guard !rules.isEmpty, !text.isEmpty else { return CorrectionResult(text: text, hits: []) }

        // Grapheme clusters are the scanning unit: it is the only unit that cannot slice an emoji or a
        // combining sequence in half. `CorrectionHit.offset` must be a UTF-16 offset though (that is
        // what AppKit/SwiftUI text ranges want), so a parallel prefix-sum table is built alongside.
        let chars = Array(text)
        var utf16Offsets = [Int](repeating: 0, count: chars.count + 1)
        var running = 0
        for (i, ch) in chars.enumerated() {
            utf16Offsets[i] = running
            running += ch.utf16.count
        }
        utf16Offsets[chars.count] = running

        var out = String()
        out.reserveCapacity(text.utf8.count)
        var hits: [CorrectionHit] = []

        var i = 0
        while i < chars.count {
            // A match can only begin on a word boundary (CONTRACTS corrector rule 1). Checking this
            // first also stops the scan from ever considering `loudCodeBase` inside `CloudCodeBase`.
            guard Self.isWordStart(chars, i) else {
                out.append(chars[i])
                i += 1
                continue
            }

            var best: (rule: CorrectionRule, length: Int)?
            for rule in rules {
                guard let length = Self.matchLength(of: rule, in: chars, at: i) else { continue }
                // Strict `>` so that among equal-length matches the first rule in sorted order wins.
                if best == nil || length > best!.length {
                    best = (rule, length)
                }
            }

            guard let match = best else {
                out.append(chars[i])
                i += 1
                continue
            }

            let matched = String(chars[i ..< i + match.length])
            out.append(match.rule.replacement)

            // CONTRACTS corrector rule 8: a case-normalisation rule that changed nothing is not news.
            // Generalised to any rule — reporting `"Claude Code" → "Claude Code"` in the history diff
            // would be pure noise.
            if matched != match.rule.replacement {
                hits.append(CorrectionHit(
                    entryID: match.rule.id,
                    from: matched,
                    to: match.rule.replacement,
                    offset: utf16Offsets[i]
                ))
            }

            i += match.length
        }

        return CorrectionResult(text: out, hits: hits)
    }

    // MARK: Matching primitives

    /// How many characters of `chars` starting at `at` this rule consumes, or nil if it does not match.
    ///
    /// Tokens match case-insensitively; between adjacent tokens any run of whitespace, hyphens and
    /// underscores is allowed — **including none at all**, which is what makes `CloudCode` match a
    /// `cloud code` rule (CONTRACTS corrector rule 4). Because the separator may be empty, `\b` at the
    /// internal joins would be meaningless; correctness rests entirely on the trailing boundary check,
    /// which is what rejects `CloudCodeBase`.
    private static func matchLength(of rule: CorrectionRule, in chars: [Character], at start: Int) -> Int? {
        var p = start
        for (index, token) in rule.tokens.enumerated() {
            if index > 0 {
                while p < chars.count, isSeparator(chars[p]) { p += 1 }
            }
            guard let next = matchToken(token, in: chars, at: p) else { return nil }
            p = next
        }
        guard isWordEnd(chars, p) else { return nil }
        return p == start ? nil : p - start
    }

    /// Case-insensitive grapheme-by-grapheme compare. Deliberately not `text.lowercased()` on the whole
    /// string: lowercasing can change the grapheme count for some scripts, which would desynchronise
    /// the UTF-16 offset table.
    private static func matchToken(_ token: String, in chars: [Character], at start: Int) -> Int? {
        var p = start
        for tc in token {
            guard p < chars.count, equalIgnoringCase(chars[p], tc) else { return nil }
            p += 1
        }
        return p
    }

    private static func equalIgnoringCase(_ a: Character, _ b: Character) -> Bool {
        if a == b { return true }
        // Fast path for ASCII, which is the overwhelming majority of what a dictation engine emits.
        if a.isASCII, b.isASCII {
            guard let x = a.asciiValue, let y = b.asciiValue else { return false }
            return x | 0x20 == y | 0x20 && (x | 0x20) >= 0x61 && (x | 0x20) <= 0x7A
        }
        return String(a).lowercased() == String(b).lowercased()
    }

    fileprivate static func isSeparator(_ ch: Character) -> Bool {
        ch.isWhitespace || ch == "-" || ch == "_" || ch == "\u{2010}" || ch == "\u{2011}"
    }

    /// The `\b`-equivalent word-character predicate. Underscore counts as a word character, matching
    /// ICU: that is why `cloud` alone does not fire inside `cloud_code` while the two-token
    /// `cloud code` rule does (there the underscore is consumed as a separator).
    private static func isWordCharacter(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber || ch == "_"
    }

    /// Scripts written without spaces between words. A boundary is recognised at the seam between one
    /// of these and Latin text, because otherwise no rule could ever fire in CJK prose — every
    /// neighbour there is a letter, so a strict `\b` would reject every position.
    private static func isIdeographic(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x3040...0x30FF).contains(v)      // Hiragana, Katakana
            || (0x3400...0x4DBF).contains(v)      // CJK Unified Ideographs Extension A
            || (0x4E00...0x9FFF).contains(v)      // CJK Unified Ideographs
            || (0xF900...0xFAFF).contains(v)      // CJK Compatibility Ideographs
            || (0x1100...0x11FF).contains(v)      // Hangul Jamo
            || (0xAC00...0xD7AF).contains(v)      // Hangul Syllables
            || (0x20000...0x3FFFF).contains(v)    // CJK Extension B and later
    }

    /// `\b`-equivalent: a boundary exists where word-ness changes, at either end of the string, or at a
    /// Latin↔CJK seam. `outside` is the character just outside the candidate match, `inside` the
    /// adjacent character within it.
    private static func isBoundary(_ outside: Character?, _ inside: Character) -> Bool {
        guard let outside else { return true }                       // start or end of string
        // Scripts written without spaces carry no word-boundary information at all, so requiring one
        // would make it impossible for a CJK rule ever to fire. Substring matching is the normal
        // expectation for find-and-replace in those scripts.
        if isIdeographic(inside) { return true }
        if isWordCharacter(outside) != isWordCharacter(inside) { return true }
        guard isWordCharacter(inside) else { return true }            // punctuation abutting punctuation
        return isIdeographic(outside) != isIdeographic(inside)       // Latin↔CJK seam
    }

    private static func isWordStart(_ chars: [Character], _ i: Int) -> Bool {
        guard i < chars.count else { return false }
        return isBoundary(i > 0 ? chars[i - 1] : nil, chars[i])
    }

    private static func isWordEnd(_ chars: [Character], _ end: Int) -> Bool {
        guard end > 0 else { return false }
        return isBoundary(end < chars.count ? chars[end] : nil, chars[end - 1])
    }
}
