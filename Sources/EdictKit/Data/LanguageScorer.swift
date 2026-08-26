import Foundation

// MARK: - Results

/// How much one text looks like one language, relative to every other language the scorer knows.
public struct LanguageScore: Sendable, Hashable {

    /// The locale identifier this score was requested for, echoed back verbatim (`"id-ID"`, not
    /// `"id"`), so a caller can match a score to the candidate it came from.
    public var localeIdentifier: String

    /// `0...1`, and **comparable across candidates**: it is this language's share of all the
    /// language-specific evidence in the text, so a long chunk is not automatically more confident
    /// than a short one and two different transcripts can be compared directly. `0` when the text
    /// carries no evidence at all, or when the identifier names a language with no profile.
    public var score: Double

    /// Tokens that contributed evidence *for this language*. A token counts once however many markers
    /// it matched.
    public var matchedTokens: Int

    /// Word-like tokens in the text, matched or not. Digits, punctuation and emoji are not tokens.
    public var totalTokens: Int

    public init(localeIdentifier: String, score: Double, matchedTokens: Int, totalTokens: Int) {
        self.localeIdentifier = localeIdentifier
        self.score = score
        self.matchedTokens = matchedTokens
        self.totalTokens = totalTokens
    }
}

/// Which candidate won, by how much, and whether the margin is worth acting on.
public struct LanguageVerdict: Sendable, Hashable {

    /// The winning candidate's locale identifier. Empty only when there were no candidates.
    public var chosen: String

    /// Winner's score minus the runner-up's. With a single candidate the runner-up is `0`, so the
    /// margin is that candidate's score.
    public var margin: Double

    /// True when the margin cleared the threshold *and* the winner rests on enough evidence to mean
    /// it. When this is false the caller should keep its primary locale — see `LanguageScorer`
    /// for the measurements behind the two thresholds.
    public var isConfident: Bool

    /// One score per candidate, best first. Ties keep the candidates' input order, so passing the
    /// primary locale first makes the fallback the natural winner of a tie.
    public var scores: [LanguageScore]

    public init(chosen: String, margin: Double, isConfident: Bool, scores: [LanguageScore]) {
        self.chosen = chosen
        self.margin = margin
        self.isConfident = isConfident
        self.scores = scores
    }
}

// MARK: - Scorer

/// Decides which language was actually spoken, given transcripts of the same audio.
///
/// Pure and deterministic: no I/O, no `Locale` lookups, no state. Cheap enough to construct per call,
/// though the tables are flattened in `init` so a long-lived instance is preferable.
///
/// ## What it is for
///
/// A dual-pass import transcribes one recording twice, once per candidate locale, and has to pick an
/// answer. The two transcripts are *different text*, and each one claims a language, so the question
/// is not "what language is this string" but "which model's output reads like the language that model
/// claims". `verdict(for:)` answers exactly that. Passing the *same* string under two locales — which
/// the tests do — turns the same machinery into a plain classifier.
///
/// ## How it scores
///
/// Function words and affixes only; see `LanguageProfiles` for why a word list is the wrong tool on
/// this input. Three rules do the real work:
///
/// * **Longer markers weigh more.** A five-letter function word is much better evidence than a
///   two-letter one, which is why `.word` weight is derived from length here rather than stored in
///   the table.
/// * **Markers claimed by more than one profile are discarded.** They cannot break a tie between the
///   languages that share them, and counting them for both only shrinks the margin. In this domain
///   that mostly means loanwords, which are everywhere: team, revenue, security, platform,
///   percent/persen. Discarding generalises safely as languages are added.
/// * **Scores are shares, not sums.** Each language's score is its evidence divided by *all*
///   languages' evidence, so the number means the same thing in a six-word chunk and a six-minute one.
///
/// ## Confidence
///
/// Margin alone is not enough: a one-word chunk can produce a margin of `1.0`. Confidence therefore
/// also requires a floor on the winner's raw evidence. Both numbers were picked by measurement — see
/// `marginThreshold` and `minimumEvidence`.
public struct LanguageScorer: Sendable {

    // MARK: Thresholds

    /// Minimum score gap for `isConfident`.
    ///
    /// Measured, not guessed. Run against the real dual-model output of the 70-minute meeting (the
    /// eight strings in `LanguageScorerTests`), every correctly-classified chunk cleared a margin of
    /// **0.767**, and the genuinely ambiguous inputs — a code-switched sentence, proper nouns only, a
    /// single word — came in at **0.263 or below**. Anything in that gap separates them; `0.40` sits
    /// nearer the ambiguous end because the two errors do not cost the same. A false "confident"
    /// re-transcribes a whole file with the wrong acoustic model; a false "unconfident" just keeps the
    /// primary locale the user already chose. `0.40` still leaves the worst measured true positive a
    /// factor of nearly two in hand.
    public static let marginThreshold: Double = 0.40

    /// Minimum raw evidence weight behind the winner for `isConfident`.
    ///
    /// Roughly two solid function words. Below this the margin is arithmetic, not information: a lone
    /// "yang" wins 1.0-to-0.0 and means nothing. The measured full-sentence chunks carry 2.5 (the
    /// worst — the badly-mangled English-model pass) to 12 or more, so the floor only silences
    /// fragments.
    public static let minimumEvidence: Double = 2.0

    /// Minimum number of distinct evidence-bearing tokens behind the winner for `isConfident`.
    /// Guards the case where one long function word alone clears `minimumEvidence`.
    public static let minimumEvidenceTokens: Int = 2

    // MARK: Flattened tables

    /// Profiles in a fixed order; indices into this array are used throughout.
    private let profiles: [LanguageProfile]

    /// Function word → index of the single profile that claims it. Words claimed by two or more
    /// profiles are absent (see the type doc).
    private let wordOwner: [String: Int]

    /// Affixes that exactly one profile claims, paired with that profile's index. Longest first so a
    /// token is credited by its most specific affix, and only once per position.
    private let affixes: [(profile: Int, marker: LanguageMarker)]

    public init() {
        self.init(profiles: LanguageProfiles.all)
    }

    /// Testing seam: lets a test build a scorer over a two-profile toy table, or verify that the
    /// two-language assumption is nowhere baked in.
    init(profiles: [LanguageProfile]) {
        self.profiles = profiles

        var wordCounts: [String: Int] = [:]
        var wordFirstOwner: [String: Int] = [:]
        for (index, profile) in profiles.enumerated() {
            for word in profile.functionWords {
                let key = word.lowercased()
                wordCounts[key, default: 0] += 1
                if wordFirstOwner[key] == nil { wordFirstOwner[key] = index }
            }
        }
        self.wordOwner = wordFirstOwner.filter { wordCounts[$0.key] == 1 }

        var affixCounts: [LanguageMarker.Position: [String: Int]] = [:]
        for profile in profiles {
            for affix in profile.affixes {
                affixCounts[affix.position, default: [:]][affix.text.lowercased(), default: 0] += 1
            }
        }
        var flattened: [(profile: Int, marker: LanguageMarker)] = []
        for (index, profile) in profiles.enumerated() {
            for affix in profile.affixes {
                let text = affix.text.lowercased()
                guard affixCounts[affix.position]?[text] == 1 else { continue }
                flattened.append((index, LanguageMarker(text: text, position: affix.position, weight: affix.weight)))
            }
        }
        // Longest first: "meng" must beat "me" and "tion" must beat "on" if such a pair is ever added.
        self.affixes = flattened.sorted { $0.marker.text.count > $1.marker.text.count }
    }

    /// Language subtags this scorer can score, sorted. Anything else scores `0`.
    public var supportedIdentifiers: [String] {
        profiles.map(\.languageCode).sorted()
    }

    // MARK: Public scoring

    /// Scores one text against one locale. `localeIdentifier` may be a bare subtag or carry a region
    /// and any separator: `id`, `id-ID`, `id_ID` all score against the `id` profile.
    public func score(_ text: String, as localeIdentifier: String) -> LanguageScore {
        let tally = self.tally(text)
        guard let index = profileIndex(forLocale: localeIdentifier) else {
            return LanguageScore(
                localeIdentifier: localeIdentifier,
                score: 0,
                matchedTokens: 0,
                totalTokens: tally.totalTokens
            )
        }
        return LanguageScore(
            localeIdentifier: localeIdentifier,
            score: tally.share(of: index),
            matchedTokens: tally.matchedTokens[index],
            totalTokens: tally.totalTokens
        )
    }

    /// Picks the candidate whose text best matches the language that candidate claims.
    ///
    /// Each candidate is scored against *its own* locale, which is what makes this work on two
    /// different transcripts of the same audio. Passing the same text twice under two locales
    /// classifies that text instead.
    public func verdict(for candidates: [(locale: String, text: String)]) -> LanguageVerdict {
        guard !candidates.isEmpty else {
            return LanguageVerdict(chosen: "", margin: 0, isConfident: false, scores: [])
        }

        // Tally once per candidate; a candidate's own tally also supplies its evidence mass.
        let tallies = candidates.map { tally($0.text) }
        let scored: [(order: Int, score: LanguageScore, evidence: Double, evidenceTokens: Int)] =
            candidates.indices.map { i in
                let tally = tallies[i]
                let index = profileIndex(forLocale: candidates[i].locale)
                let score = LanguageScore(
                    localeIdentifier: candidates[i].locale,
                    score: index.map(tally.share(of:)) ?? 0,
                    matchedTokens: index.map { tally.matchedTokens[$0] } ?? 0,
                    totalTokens: tally.totalTokens
                )
                return (i, score, index.map { tally.weights[$0] } ?? 0, index.map { tally.matchedTokens[$0] } ?? 0)
            }

        // Descending by score, input order as the tie-break: `sorted(by:)` is not stable, so the
        // order is part of the comparator. A caller that passes its primary locale first therefore
        // keeps that locale whenever the two candidates score identically.
        let ranked = scored.sorted {
            $0.score.score == $1.score.score ? $0.order < $1.order : $0.score.score > $1.score.score
        }

        let winner = ranked[0]
        let runnerUp = ranked.count > 1 ? ranked[1].score.score : 0
        let margin = winner.score.score - runnerUp
        let isConfident = margin >= Self.marginThreshold
            && winner.evidence >= Self.minimumEvidence
            && winner.evidenceTokens >= Self.minimumEvidenceTokens

        return LanguageVerdict(
            chosen: winner.score.localeIdentifier,
            margin: margin,
            isConfident: isConfident,
            scores: ranked.map(\.score)
        )
    }

    // MARK: Tally

    /// Raw evidence for one text: weight and matched-token count per profile index.
    private struct Tally {
        var weights: [Double]
        var matchedTokens: [Int]
        var totalTokens: Int

        /// This profile's share of all the evidence in the text.
        func share(of index: Int) -> Double {
            let total = weights.reduce(0, +)
            guard total > 0 else { return 0 }
            return weights[index] / total
        }
    }

    private func tally(_ text: String) -> Tally {
        var weights = [Double](repeating: 0, count: profiles.count)
        var matched = [Int](repeating: 0, count: profiles.count)
        var totalTokens = 0

        for token in Self.tokens(in: text) {
            totalTokens += 1

            if let owner = wordOwner[token] {
                weights[owner] += Self.wordWeight(length: token.count)
                matched[owner] += 1
                continue
            }

            // Affix credit only goes to tokens that are nobody's function word — otherwise "can" pays
            // English as a modal and Indonesian as a `-an` noun off the same three letters.
            var creditedProfiles = Set<Int>()
            var usedPositions = Set<LanguageMarker.Position>()
            for entry in affixes {
                guard !usedPositions.contains(entry.marker.position) else { continue }
                guard Self.matches(entry.marker, token) else { continue }
                usedPositions.insert(entry.marker.position)
                weights[entry.profile] += entry.marker.weight
                creditedProfiles.insert(entry.profile)
            }
            for profile in creditedProfiles { matched[profile] += 1 }
        }

        return Tally(weights: weights, matchedTokens: matched, totalTokens: totalTokens)
    }

    /// Whole-word evidence weight, from length. Deliberately flat-topped: past five characters a
    /// function word is not getting any more diagnostic, and letting long tokens run away would let a
    /// single word decide a sentence.
    private static func wordWeight(length: Int) -> Double {
        switch length {
        case ...2: 1.0
        case 3...4: 1.5
        default: 2.0
        }
    }

    /// The stem an affix has to leave behind.
    ///
    /// Three characters. Without it every English "can", "plan" and "than" pays the Indonesian `-an`
    /// suffix, and "did" pays the `di-` prefix — the short words are exactly the frequent ones, so the
    /// leak would be constant rather than occasional.
    private static let minimumStem = 3

    private static func matches(_ marker: LanguageMarker, _ token: String) -> Bool {
        guard token.count >= marker.text.count + minimumStem else { return false }
        switch marker.position {
        case .word: return token == marker.text
        case .prefix: return token.hasPrefix(marker.text)
        case .suffix: return token.hasSuffix(marker.text)
        }
    }

    // MARK: Locale resolution

    /// `id-ID` → the `id` profile. Parsed by hand rather than through `Locale`, so the result cannot
    /// drift with the system's ICU data — RECON §7 is a standing reminder that locale resolution on
    /// this machine does surprising things (`en_ID` resolves to `en-IN`).
    private func profileIndex(forLocale identifier: String) -> Int? {
        let subtag = identifier
            .lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" })
            .first
            .map(String.init) ?? ""
        guard !subtag.isEmpty else { return nil }
        return profiles.firstIndex { $0.languageCode == subtag }
    }

    // MARK: Tokenisation

    /// Splits text into lowercase word-like tokens.
    ///
    /// A token is a run of alphabetic scalars, with an apostrophe kept when it sits *between* letters
    /// so "let's" survives as one token. Everything else separates: digits, punctuation, emoji, and
    /// the hyphen — which is deliberate, because Indonesian reduplication ("hal-hal") should count as
    /// two function words rather than one unknown token. A run with no letters at all ("12", "%") is
    /// not a token, so a digits-and-punctuation string tokenises to nothing and scores `0` honestly.
    /// CJK scalars are alphabetic, so CJK text tokenises to unmatched runs — no matches, no crash.
    static func tokens(in text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var pendingApostrophe = false

        func flush() {
            if !current.isEmpty { tokens.append(current.lowercased()) }
            current = ""
            pendingApostrophe = false
        }

        for scalar in text.unicodeScalars {
            if scalar.properties.isAlphabetic {
                if pendingApostrophe {
                    current.unicodeScalars.append("'")
                    pendingApostrophe = false
                }
                current.unicodeScalars.append(scalar)
            } else if scalar == "'" || scalar == "\u{2019}" {
                // Held, not appended: a trailing apostrophe ("boys'") is punctuation, not part of the
                // token, and only a following letter proves otherwise.
                if !current.isEmpty { pendingApostrophe = true }
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }
}
