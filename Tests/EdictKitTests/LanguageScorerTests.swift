import Foundation
import Testing
@testable import EdictKit

/// The scorer, tested against **real measured output** from the two speech models rather than against
/// invented sentences.
///
/// Every string in `Acceptance` below is text one of the two models actually produced from the
/// 70-minute Indonesian/English meeting recording: the `id-ID` `DictationTranscriber` pass reads as
/// fluent Indonesian, the `en-US` `SpeechTranscriber` pass reads as phonetic mush ("Sayasudasiapkan la
/// poranka yuangan"). That asymmetry *is* the signal the dual-pass import selects on, so these are the
/// only strings whose classification is load-bearing. Synthetic sentences would test the tables; these
/// test the decision.
///
/// The second half of the file is the honesty half: the inputs that must **not** produce a verdict —
/// a fragment, a code-switched sentence, proper nouns, punctuation, CJK. On those the integrator keeps
/// the user's primary locale, and a confident wrong answer would silently re-transcribe an entire file
/// with the wrong acoustic model.
@Suite("Language scorer")
struct LanguageScorerTests {

    let scorer = LanguageScorer()

    /// Classifies one string by scoring it under both locales — the same code path the dual-pass
    /// import uses on two *different* transcripts, pointed at one.
    private func classify(_ text: String) -> LanguageVerdict {
        scorer.verdict(for: [(locale: "en-US", text: text), (locale: "id-ID", text: text)])
    }

    // MARK: - Acceptance: the eight measured strings

    /// `expected` is the locale identifier the string must resolve to.
    enum Acceptance {
        static let all: [(text: String, expected: String)] = [
            // The en-US model's attempt at Indonesian speech: mangled, but the closed class survives
            // ("ini", plus the "-kan"/"-an" endings inside the run-together words).
            ("Sayasudasiapkan la poranka yuangan unto cuarta ini", "id-ID"),
            // The id-ID model on the same audio.
            ("baik saya sudah siapkan laporan keuangan untuk kuartal ini", "id-ID"),
            // "demanding" is a real English -ing hit inside Indonesian speech; it must lose anyway.
            ("Tantu Saja. Pundapatan kitanai duablas percent demanding bulan lalu", "id-ID"),
            // "dibanding" carries an Indonesian di- prefix *and* an English -ing suffix at once.
            ("tentu saja pendapatan kita naik 12% dibanding bulan lalu", "id-ID"),
            // Heavy function-word Indonesian with an English loanword ("sekuriti", "eksposur").
            ("Ini dibilang sekuriti hal-hal yang seperti itu justru itu juga jadi salah satu eksposur", "id-ID"),
            ("Okay, team, let's review the quarterly numbers before we start.", "en-US"),
            // The id-ID model's attempt at English speech — still English underneath.
            ("Oke gym let's with the cord number for", "en-US"),
            ("Great. Can you walk us through the revenue side 1st?", "en-US"),
        ]
    }

    @Test("Each measured string resolves to the language actually spoken", arguments: Acceptance.all)
    func measuredStringResolves(text: String, expected: String) {
        let verdict = classify(text)
        #expect(verdict.chosen == expected, "chose \(verdict.chosen) for: \(text)")
        #expect(verdict.isConfident, "unconfident (margin \(verdict.margin)) for: \(text)")
    }

    /// The headline number, asserted so it cannot quietly regress: **8 of 8**.
    @Test("Accuracy on the measured set is 8/8")
    func accuracyOnMeasuredSet() {
        let correct = Acceptance.all.filter { classify($0.text).chosen == $0.expected }.count
        #expect(correct == 8)
        #expect(correct == Acceptance.all.count)
    }

    /// The margin gap that `marginThreshold` was chosen from. If a table edit narrows it, this fails
    /// before the threshold silently stops separating anything.
    @Test("Every measured string clears the threshold with headroom")
    func measuredMarginsClearThreshold() {
        let margins = Acceptance.all.map { classify($0.text).margin }
        #expect(margins.min()! >= 0.75)
        #expect(margins.min()! > LanguageScorer.marginThreshold * 1.5)
    }

    // MARK: - Dual transcripts, which is what this is for

    /// The real call: two *different* texts, each claiming its own locale. Each candidate is scored
    /// against the language it claims, so the model whose output reads like its own language wins.
    @Test("The model whose output reads like its own language wins")
    func dualTranscriptSelection() {
        let verdict = scorer.verdict(for: [
            (locale: "en-US", text: "Sayasudasiapkan la poranka yuangan unto cuarta ini"),
            (locale: "id-ID", text: "baik saya sudah siapkan laporan keuangan untuk kuartal ini"),
        ])
        #expect(verdict.chosen == "id-ID")
        #expect(verdict.isConfident)
        #expect(verdict.scores.first?.localeIdentifier == "id-ID", "scores are ranked best-first")
    }

    /// The mirror case: clean English from the English model beats the Indonesian model's phonetic
    /// guess at the same audio.
    @Test("English audio keeps the English candidate")
    func dualTranscriptSelectionEnglish() {
        let verdict = scorer.verdict(for: [
            (locale: "en-US", text: "Great. Can you walk us through the revenue side 1st?"),
            (locale: "id-ID", text: "Oke gym let's with the cord number for"),
        ])
        #expect(verdict.chosen == "en-US")
        #expect(verdict.isConfident)
    }

    // MARK: - Honest refusals

    @Test("Empty text produces no verdict")
    func emptyText() {
        let verdict = classify("")
        #expect(verdict.margin == 0)
        #expect(!verdict.isConfident)
        #expect(verdict.scores.allSatisfy { $0.score == 0 && $0.totalTokens == 0 })
    }

    /// One function word can win 1.0-to-0.0 on margin alone. It must still not be confident — this is
    /// what `minimumEvidence` exists for.
    @Test("A single word wins on margin but is never confident")
    func singleWord() {
        let verdict = classify("yang")
        #expect(verdict.chosen == "id-ID", "the ranking is still honest")
        #expect(verdict.margin == 1.0)
        #expect(!verdict.isConfident)
        #expect(verdict.scores.first?.totalTokens == 1)
    }

    @Test("Digits and punctuation alone are not tokens")
    func digitsAndPunctuationOnly() {
        let verdict = classify("12 34 %$#@ ... 5,6 —— 99.9%")
        #expect(verdict.scores.allSatisfy { $0.totalTokens == 0 && $0.score == 0 })
        #expect(!verdict.isConfident)
    }

    /// A genuinely code-switched sentence — four English function words against two Indonesian ones.
    /// The margin has to come out low, because the honest answer is "both".
    @Test("A code-switched chunk scores a low margin and refuses to be confident")
    func mixedChunk() {
        let verdict = classify("Jadi the revenue untuk this quarter naik quite a lot")
        #expect(verdict.margin < LanguageScorer.marginThreshold)
        #expect(!verdict.isConfident)
        // Both languages must show evidence; a mixed chunk that scored 1.0/0.0 would mean the tables
        // had stopped seeing one of them.
        #expect(verdict.scores.allSatisfy { $0.score > 0 })
    }

    /// Proper nouns are the trap case: they look like words, they carry no closed class, and guessing
    /// from them would pick a language off someone's surname.
    @Test("Proper nouns only is a refusal, not a guess")
    func properNounsOnly() {
        let verdict = classify("Contoso Jakarta Anthropic Budi Santoso")
        #expect(!verdict.isConfident)
        #expect(verdict.margin == 0)
        #expect(verdict.scores.allSatisfy { $0.score == 0 })
        #expect(verdict.scores.first?.totalTokens == 5, "they are still counted as tokens")
    }

    @Test("CJK and emoji neither match nor crash")
    func cjkAndEmoji() {
        for text in ["会議の議事録です 😀🎉", "🎉🎉🎉", "한국어 텍스트", "混合 text with 漢字 😀"] {
            let verdict = classify(text)
            #expect(!verdict.isConfident || verdict.chosen == "en-US")
            #expect(verdict.scores.count == 2)
        }
        // Emoji are separators, not letters, so they contribute no tokens at all.
        #expect(LanguageScorer.tokens(in: "🎉🎉🎉").isEmpty)
    }

    @Test("No candidates yields an empty verdict rather than a crash")
    func noCandidates() {
        let verdict = scorer.verdict(for: [])
        #expect(verdict.chosen.isEmpty)
        #expect(verdict.margin == 0)
        #expect(!verdict.isConfident)
        #expect(verdict.scores.isEmpty)
    }

    /// A tie must resolve to the *first* candidate, so an integrator that passes its primary locale
    /// first keeps that locale when the evidence says nothing.
    @Test("A tie keeps the first candidate")
    func tieKeepsFirstCandidate() {
        let first = scorer.verdict(for: [(locale: "en-US", text: "Budi"), (locale: "id-ID", text: "Budi")])
        let reversed = scorer.verdict(for: [(locale: "id-ID", text: "Budi"), (locale: "en-US", text: "Budi")])
        #expect(first.chosen == "en-US")
        #expect(reversed.chosen == "id-ID")
        #expect(!first.isConfident && !reversed.isConfident)
    }

    // MARK: - Locale identifiers

    @Test("Region and separator are ignored when resolving a profile")
    func localeIdentifierForms() {
        let text = "baik saya sudah siapkan laporan keuangan untuk kuartal ini"
        let scores = ["id", "id-ID", "id_ID", "ID-id"].map { scorer.score(text, as: $0) }
        #expect(Set(scores.map(\.score)).count == 1)
        #expect(scores[0].score > 0.9)
        // The identifier is echoed back exactly as given, not normalised.
        #expect(scores[1].localeIdentifier == "id-ID")
    }

    @Test("An unsupported language scores zero without discarding the token count")
    func unsupportedLanguage() {
        let score = scorer.score("bonjour tout le monde et bienvenue", as: "fr-FR")
        #expect(score.score == 0)
        #expect(score.matchedTokens == 0)
        #expect(score.totalTokens == 6)
        #expect(!scorer.supportedIdentifiers.contains("fr"))
    }

    @Test("Supported identifiers are the language subtags, sorted")
    func supportedIdentifiers() {
        #expect(scorer.supportedIdentifiers == ["en", "id"])
    }

    @Test("Scoring is deterministic")
    func deterministic() {
        let text = "tentu saja pendapatan kita naik 12% dibanding bulan lalu"
        let runs = (0..<8).map { _ in LanguageScorer().score(text, as: "id-ID") }
        #expect(Set(runs).count == 1)
    }

    // MARK: - The table machinery, on toy profiles

    /// Nothing in the scorer assumes two languages. A third profile changes the arithmetic (scores are
    /// a share of *all* evidence, so they no longer sum to 1 across two candidates) without changing
    /// the ranking.
    @Test("A third language does not disturb the ranking")
    func threeProfiles() {
        let spanish = LanguageProfile(
            languageCode: "es",
            functionWords: ["que", "por", "para", "como", "pero", "porque", "cuando"],
            affixes: [LanguageMarker(text: "ción", position: .suffix, weight: 0.6)]
        )
        let scorer = LanguageScorer(profiles: LanguageProfiles.all + [spanish])
        #expect(scorer.supportedIdentifiers == ["en", "es", "id"])

        let verdict = scorer.verdict(for: [
            (locale: "en-US", text: "porque para cuando llega la información"),
            (locale: "es-ES", text: "porque para cuando llega la información"),
            (locale: "id-ID", text: "porque para cuando llega la información"),
        ])
        #expect(verdict.chosen == "es-ES")
        #expect(verdict.isConfident)

        // The Indonesian sentence still wins for Indonesian with a third table in play.
        let indonesian = scorer.verdict(for: [
            (locale: "en-US", text: "baik saya sudah siapkan laporan keuangan untuk kuartal ini"),
            (locale: "es-ES", text: "baik saya sudah siapkan laporan keuangan untuk kuartal ini"),
            (locale: "id-ID", text: "baik saya sudah siapkan laporan keuangan untuk kuartal ini"),
        ])
        #expect(indonesian.chosen == "id-ID")
    }

    /// A marker two profiles claim carries no signal and must be dropped rather than counted twice —
    /// the loanword rule ("team", "revenue", "percent"/"persen"), tested on a toy table where the
    /// collision can be made total.
    @Test("A marker claimed by two profiles is discarded")
    func sharedMarkersAreDiscarded() {
        let a = LanguageProfile(
            languageCode: "aa",
            functionWords: ["alpha", "shared", "common"],
            affixes: [LanguageMarker(text: "xyz", position: .suffix, weight: 0.5)]
        )
        let b = LanguageProfile(
            languageCode: "bb",
            functionWords: ["beta", "shared", "common"],
            affixes: [LanguageMarker(text: "xyz", position: .suffix, weight: 0.5)]
        )
        let scorer = LanguageScorer(profiles: [a, b])

        // Nothing but shared markers: no evidence at all, for either side.
        let shared = scorer.verdict(for: [(locale: "aa", text: "shared common"), (locale: "bb", text: "shared common")])
        #expect(shared.margin == 0)
        #expect(!shared.isConfident)
        #expect(shared.scores.allSatisfy { $0.score == 0 && $0.matchedTokens == 0 })
        #expect(shared.scores.first?.totalTokens == 2, "discarded markers are still tokens")

        // A shared affix is discarded the same way, while the unshared words still decide.
        let mixed = scorer.verdict(for: [(locale: "aa", text: "alpha shared foobarxyz"), (locale: "bb", text: "alpha shared foobarxyz")])
        #expect(mixed.chosen == "aa")
        #expect(mixed.scores.first?.score == 1.0)
    }

    /// The two profiles as shipped happen to share no function word. That is a property of the tables
    /// worth pinning: if a future edit introduces an overlap, the marker is silently dropped from both
    /// sides, and this test is where that gets noticed.
    @Test("The shipped English and Indonesian tables do not overlap")
    func shippedTablesDoNotOverlap() {
        let overlap = LanguageProfiles.english.functionWords
            .intersection(LanguageProfiles.indonesian.functionWords)
        #expect(overlap.isEmpty, "overlapping function words: \(overlap.sorted())")
    }

    // MARK: - Tokenisation

    @Test("Tokenisation keeps intra-word apostrophes and splits everything else")
    func tokenisation() {
        #expect(LanguageScorer.tokens(in: "let's go") == ["let's", "go"])
        #expect(LanguageScorer.tokens(in: "let\u{2019}s go") == ["let's", "go"], "curly apostrophe")
        #expect(LanguageScorer.tokens(in: "the boys' room") == ["the", "boys", "room"], "trailing is punctuation")
        // Indonesian reduplication: two function words, not one unknown token.
        #expect(LanguageScorer.tokens(in: "hal-hal") == ["hal", "hal"])
        #expect(LanguageScorer.tokens(in: "Okay, TEAM: let's—go!") == ["okay", "team", "let's", "go"])
        #expect(LanguageScorer.tokens(in: "naik 12% dibanding") == ["naik", "dibanding"])
        #expect(LanguageScorer.tokens(in: "  \n\t ").isEmpty)
    }

    /// The minimum-stem rule: without it every English "can", "plan" and "than" would pay the
    /// Indonesian `-an` suffix, and the short words are the frequent ones.
    @Test("Short words do not pay a suffix they merely end with")
    func minimumStemRule() {
        for word in ["can", "plan", "than", "did"] {
            let score = scorer.score(word, as: "id-ID")
            #expect(score.matchedTokens == 0, "\(word) should not match an Indonesian affix")
        }
        // The stem rule is a length rule, not a word list: a long English word does leak a little.
        #expect(scorer.score("keuangan", as: "id-ID").matchedTokens == 1)
    }
}
