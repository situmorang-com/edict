import Foundation
import Testing
@testable import EdictKit

/// The corrector is the guaranteed half of the two-layer dictionary, so these tests are written as a
/// specification of CONTRACTS "Corrector semantics" rules 1–8 rather than as coverage.
@Suite("Corrector")
struct CorrectorTests {

    // MARK: Helpers

    private func rule(_ heard: String, _ write: String, id: UUID = UUID()) -> CorrectionRule {
        CorrectionRule(entryID: id, heard: heard, write: write)
    }

    private func apply(_ rules: [CorrectionRule], to text: String) -> CorrectionResult {
        Corrector(rules: rules).apply(to: text)
    }

    /// Every hit's `offset` must index the *raw* string, so this is checkable directly against it.
    private func assertOffsetsIndexRaw(_ raw: String, _ result: CorrectionResult) {
        let ns = raw as NSString
        for hit in result.hits {
            let length = (hit.from as NSString).length
            #expect(hit.offset >= 0)
            #expect(hit.offset + length <= ns.length)
            guard hit.offset + length <= ns.length else { continue }
            #expect(ns.substring(with: NSRange(location: hit.offset, length: length)) == hit.from)
        }
    }

    // MARK: Rule 1 — whole-word only

    @Test("A single-token rule never fires inside a longer word")
    func singleTokenDoesNotCorruptRealWords() {
        let rules = [rule("cloud", "Claude")]
        let raw = "Cloudflare, clouds, iCloud, cloudy and cloud."
        let result = apply(rules, to: raw)
        #expect(result.text == "Cloudflare, clouds, iCloud, cloudy and Claude.")
        #expect(result.hits.count == 1)
        #expect(result.hits[0].from == "cloud")
        #expect(result.hits[0].to == "Claude")
        assertOffsetsIndexRaw(raw, result)
    }

    @Test("Underscore counts as a word character, matching ICU \\b")
    func underscoreIsAWordCharacter() {
        // `cloud` alone must not fire inside `cloud_code` — but the two-token rule must, because there
        // the underscore is consumed as a separator.
        #expect(apply([rule("cloud", "Claude")], to: "cloud_code").text == "cloud_code")
        #expect(apply([rule("cloud code", "Claude Code")], to: "cloud_code").text == "Claude Code")
    }

    @Test("Digits are word characters")
    func digitsBlockAMatch() {
        #expect(apply([rule("cloud", "Claude")], to: "cloud2 2cloud").text == "cloud2 2cloud")
    }

    // MARK: Rule 2 — case-insensitive match, verbatim replacement

    @Test("Matching ignores case; the write side is inserted exactly as typed")
    func replacementIsVerbatim() {
        let raw = "swift ui and Swift-UI and SWIFTUI and swiftui"
        let result = apply([rule("swift ui", "SwiftUI")], to: raw)
        #expect(result.text == "SwiftUI and SwiftUI and SwiftUI and SwiftUI")
        #expect(result.hits.count == 4)
        // `from` records what the engine actually produced, casing intact, for the history diff.
        #expect(result.hits.map(\.from) == ["swift ui", "Swift-UI", "SWIFTUI", "swiftui"])
        assertOffsetsIndexRaw(raw, result)
    }

    // MARK: Rule 3 — longest match first

    @Test("The longest matching rule wins regardless of the order rules arrive in")
    func longestMatchWins() {
        let short = rule("cloud code", "SHORT")
        let long = rule("cloud code assistant", "LONG")
        for rules in [[short, long], [long, short]] {
            let result = apply(rules, to: "open cloud code assistant now")
            #expect(result.text == "open LONG now")
            #expect(result.hits.count == 1)
        }
    }

    @Test("Longest-match is measured on the text actually matched, not on the rule's length")
    func longestMatchUsesActualMatchLength() {
        // "cloud code" spells 10 characters here but the glued form only 9, so the arbiter has to be
        // the runtime match, not the compiled heard string.
        let result = apply([rule("cloud", "A"), rule("cloud code", "B")], to: "CloudCode")
        #expect(result.text == "B")
    }

    @Test("Equal-length matches are broken by rule order, which is entry creation order")
    func tiesBreakDeterministicallyByOrder() {
        let first = rule("cloud code", "FIRST")
        let second = rule("cloud code", "SECOND")
        #expect(apply([first, second], to: "cloud code").text == "FIRST")
        #expect(apply([second, first], to: "cloud code").text == "SECOND")
    }

    @Test("A real correction beats a case-normalisation rule of the same length")
    func correctionOutranksCaseNormalisation() {
        let normalise = rule("Cloud Code", "Cloud Code")   // what a `.term` entry compiles to
        let correction = rule("cloud code", "Claude Code")
        // Both orders, because the outcome must come from sortWeight and not from array position.
        #expect(apply([normalise, correction], to: "cloud code").text == "Claude Code")
        #expect(apply([correction, normalise], to: "cloud code").text == "Claude Code")
    }

    // MARK: Rule 4 — glued, spaced, hyphenated and underscored forms

    @Test("Every separator form of a multi-token rule matches", arguments: [
        "cloud code", "cloud  code", "cloud-code", "cloud_code", "CloudCode", "Cloud Code",
        "cloud--code", "cloud \t code", "CLOUD_CODE", "Cloud-Code",
    ])
    func allSeparatorForms(_ input: String) {
        let result = apply([rule("cloud code", "Claude Code")], to: input)
        #expect(result.text == "Claude Code")
        #expect(result.hits.count == 1)
        #expect(result.hits[0].from == input)
        #expect(result.hits[0].offset == 0)
    }

    @Test("A hyphenated heard side compiles to the same rule as a spaced one")
    func heardSideSeparatorIsIrrelevant() {
        for heard in ["cloud code", "cloud-code", "cloud_code", "  cloud   code  "] {
            #expect(apply([rule(heard, "Claude Code")], to: "CloudCode").text == "Claude Code")
        }
    }

    @Test("The empty separator does not let a multi-token rule fire mid-word")
    func gluedFormStillRequiresATrailingBoundary() {
        // The whole point of the trailing \b: `cloud code` must not match inside `CloudCodeBase`.
        let rules = [rule("cloud code", "Claude Code"), rule("cloud", "Claude")]
        for input in ["CloudCodeBase", "MyCloudCode", "CloudCodeX", "precloudcode"] {
            let result = apply(rules, to: input)
            #expect(result.text == input, "\(input) should be untouched")
            #expect(result.hits.isEmpty)
        }
    }

    // MARK: Rule 6 — one pass, no cascading

    @Test("A replacement is never re-examined by another rule")
    func noCascading() {
        let rules = [rule("cloud", "Claude"), rule("Claude", "Claude Code")]
        // "cloud" -> "Claude" and stops. Chained replacingOccurrences would yield "Claude Code".
        #expect(apply(rules, to: "cloud").text == "Claude")
        // Sanity: the second rule does still work on input that genuinely contains it.
        #expect(apply(rules, to: "Claude").text == "Claude Code")
    }

    @Test("Replacements cannot chain into an infinite expansion")
    func selfReferentialRuleTerminates() {
        let result = apply([rule("go", "go go go")], to: "go go")
        #expect(result.text == "go go go go go go")
        #expect(result.hits.count == 2)
    }

    // MARK: Rule 7 — hits and offsets

    @Test("Several hits in one sentence, each with a correct pre-correction offset")
    func multipleHitsInOneSentence() {
        let raw = "I used cloud code with vercel and superbase."
        let result = apply([
            rule("cloud code", "Claude Code"),
            rule("vercel", "Vercel"),
            rule("superbase", "Supabase"),
        ], to: raw)
        #expect(result.text == "I used Claude Code with Vercel and Supabase.")
        #expect(result.hits.count == 3)
        #expect(result.hits.map(\.offset) == [7, 23, 34])
        assertOffsetsIndexRaw(raw, result)
    }

    @Test("Offsets are UTF-16, not character, offsets")
    func offsetsAreUTF16() {
        // 👨‍👩‍👧‍👦 is one Character but 11 UTF-16 code units, so a character-based offset would be wrong by 10.
        let raw = "👨‍👩‍👧‍👦cloud code"
        let result = apply([rule("cloud code", "Claude Code")], to: raw)
        #expect(result.text == "👨‍👩‍👧‍👦Claude Code")
        #expect(result.hits.count == 1)
        #expect(result.hits[0].offset == 11)
        assertOffsetsIndexRaw(raw, result)
    }

    @Test("Emoji count as non-word characters, so they form a boundary")
    func emojiAdjacentText() {
        let raw = "🎉cloud code🎉 and 🚀vercel"
        let result = apply([rule("cloud code", "Claude Code"), rule("vercel", "Vercel")], to: raw)
        #expect(result.text == "🎉Claude Code🎉 and 🚀Vercel")
        #expect(result.hits.count == 2)
        assertOffsetsIndexRaw(raw, result)
    }

    @Test("Latin rules fire when glued to CJK text")
    func cjkAdjacentText() {
        let raw = "我用cloud code写代码，很好。"
        let result = apply([rule("cloud code", "Claude Code")], to: raw)
        #expect(result.text == "我用Claude Code写代码，很好。")
        #expect(result.hits.count == 1)
        assertOffsetsIndexRaw(raw, result)
    }

    @Test("CJK rules match without a word boundary, because CJK has none")
    func cjkRulesMatchSubstrings() {
        let raw = "我在东京工作。"
        let result = apply([rule("东京", "Tokyo")], to: raw)
        #expect(result.text == "我在Tokyo工作。")
        #expect(result.hits.count == 1)
        assertOffsetsIndexRaw(raw, result)
    }

    @Test("Diacritics are preserved and do not desynchronise offsets")
    func diacriticsPreserved() {
        let raw = "café cloud code café"
        let result = apply([rule("cloud code", "Claude Code")], to: raw)
        #expect(result.text == "café Claude Code café")
        assertOffsetsIndexRaw(raw, result)
    }

    // MARK: Rule 8 — term case normalisation

    @Test("A case-normalisation rule is a no-op and emits no hit when the casing already matches")
    func caseNormalisationNoOp() {
        let result = apply([rule("Vercel", "Vercel")], to: "we deploy on Vercel today")
        #expect(result.text == "we deploy on Vercel today")
        #expect(result.hits.isEmpty)
    }

    @Test("A case-normalisation rule fixes casing and reports the change")
    func caseNormalisationFixesCasing() {
        let raw = "we deploy on vercel and VERCEL"
        let result = apply([rule("Vercel", "Vercel")], to: raw)
        #expect(result.text == "we deploy on Vercel and Vercel")
        #expect(result.hits.count == 2)
        #expect(result.hits.map(\.from) == ["vercel", "VERCEL"])
        #expect(result.hits.allSatisfy { $0.to == "Vercel" })
        assertOffsetsIndexRaw(raw, result)
    }

    @Test("A correction whose output already appears in the text still reports nothing for it")
    func identityMatchEmitsNoHit() {
        let result = apply([rule("Claude Code", "Claude Code")], to: "Claude Code and CloudCode")
        #expect(result.text == "Claude Code and CloudCode")
        #expect(result.hits.isEmpty)
    }

    // MARK: Degenerate inputs

    @Test("An empty rule set leaves the text alone")
    func emptyRules() {
        let result = apply([], to: "cloud code stays exactly as it is")
        #expect(result.text == "cloud code stays exactly as it is")
        #expect(result.hits.isEmpty)
        #expect(Corrector(rules: []).isEmpty)
    }

    @Test("An empty input produces an empty output")
    func emptyInput() {
        let result = apply([rule("cloud code", "Claude Code")], to: "")
        #expect(result.text.isEmpty)
        #expect(result.hits.isEmpty)
    }

    @Test("A blank heard side is discarded rather than matching everywhere")
    func blankHeardIsDiscarded() {
        let corrector = Corrector(rules: [rule("   ", "X"), rule("-_-", "Y")])
        #expect(corrector.isEmpty)
        #expect(corrector.apply(to: "nothing happens here").text == "nothing happens here")
    }

    @Test("Whitespace and punctuation are preserved byte-for-byte outside matches")
    func nonMatchingTextIsPreserved() {
        let raw = "  line one\n\tline two \u{00A0}end.  "
        #expect(apply([rule("vercel", "Vercel")], to: raw).text == raw)
    }

    // MARK: Compiled rule surface

    @Test("The exposed pattern describes what the rule matches")
    func patternIsExplainable() {
        #expect(rule("cloud code", "Claude Code").pattern == #"\bcloud[\s\-_]*code\b"#)
        #expect(rule("c++", "C++").pattern == #"\bc\+\+\b"#)
    }

    @Test("sortWeight orders by matched length, then token count, then correction-over-normalisation")
    func sortWeightOrdering() {
        let longer = rule("cloud code assistant", "A")
        let shorter = rule("cloud code", "B")
        #expect(longer.sortWeight > shorter.sortWeight)

        let twoTokens = rule("foo bar", "A")     // 6 chars, 2 tokens
        let oneToken = rule("foobar", "B")       // 6 chars, 1 token
        #expect(twoTokens.sortWeight > oneToken.sortWeight)

        let correction = rule("cloud code", "Claude Code")
        let normalisation = rule("Cloud Code", "Cloud Code")
        #expect(correction.sortWeight > normalisation.sortWeight)
        #expect(normalisation.isCaseNormalisationOnly)
        #expect(!correction.isCaseNormalisationOnly)
    }

    @Test("Tokenising the heard side collapses every separator form")
    func tokenisation() {
        #expect(CorrectionRule.tokenise("cloud code") == ["cloud", "code"])
        #expect(CorrectionRule.tokenise("cloud-code") == ["cloud", "code"])
        #expect(CorrectionRule.tokenise("  cloud _ code  ") == ["cloud", "code"])
        #expect(CorrectionRule.tokenise("").isEmpty)
        #expect(CorrectionRule.tokenise("---").isEmpty)
    }

    // MARK: Realistic end-to-end

    @Test("A realistic misheard transcript comes out right")
    func realisticTranscript() {
        let raw = "I opened cloud code, deployed to visa, and stored it in soup base."
        let result = apply([
            rule("cloud code", "Claude Code"),
            rule("visa", "Vercel"),
            rule("soup base", "Supabase"),
            rule("whisper flow", "Wispr Flow"),
        ], to: raw)
        #expect(result.text == "I opened Claude Code, deployed to Vercel, and stored it in Supabase.")
        #expect(result.hits.count == 3)
        assertOffsetsIndexRaw(raw, result)
    }
}
