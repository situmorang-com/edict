import Foundation

// MARK: - Why this file is a table and not a dictionary

/// A language marker: a function word or an affix, with the weight its presence is worth.
///
/// The tables below deliberately contain **no content words**. The measurements that motivated this
/// file (a 70-minute Indonesian/English business meeting, transcribed twice — once by
/// `DictationTranscriber` at `id-ID`, once by `SpeechTranscriber` at `en-US`) produced output like
///
///     "Sayasudasiapkan la poranka yuangan unto cuarta ini"      (en-US model, Indonesian speech)
///     "baik saya sudah siapkan laporan keuangan untuk kuartal ini"  (id-ID model, same speech)
///
/// Neither string can be classified by looking up its nouns: the nouns are mangled beyond matching
/// ("poranka" for "laporan", "yuangan" for "keuangan"), and the ones that survive are loanwords that
/// belong to both languages anyway — team, revenue, security, platform, percent/persen. What *does*
/// survive the acoustic mangling is the closed class: function words and affixes. They are the most
/// frequent tokens in any language, the shortest, the most reduced, and the most language-specific,
/// so a sentence-length chunk classifies from a few hundred entries. A 50,000-word dictionary would
/// be bigger, slower, and score *worse* on exactly this input.
///
/// Compiled into Swift source rather than shipped as a resource: RECON §24 — a `resources:` clause on
/// the app target breaks codesigning, so small tables live in code.
public struct LanguageMarker: Sendable, Hashable {

    /// Where in the token the marker has to appear.
    public enum Position: Sendable, Hashable {
        /// Matches the whole token, exactly (compared lowercased).
        case word
        /// Matches the start of a longer token.
        case prefix
        /// Matches the end of a longer token.
        case suffix
    }

    /// The marker text, always lowercase.
    public var text: String

    /// Where it has to match.
    public var position: Position

    /// Evidence weight of one hit.
    ///
    /// Whole-word weight is *derived from length* by the scorer (a five-letter function word is
    /// stronger evidence than a two-letter one), so `.word` markers carry weight `0` here and the
    /// field is only meaningful for affixes. Affix weights are hand-set per affix, because affixes
    /// differ enormously in how much they leak into the other language: Indonesian `-kan` and `-nya`
    /// are nearly unambiguous, while `di-` also opens English "different", "discussion", "digital".
    public var weight: Double

    public init(text: String, position: Position, weight: Double = 0) {
        self.text = text
        self.position = position
        self.weight = weight
    }
}

// MARK: - Profile

/// One language's markers, keyed by its ISO 639-1 subtag.
///
/// The scorer never sees a region — `id-ID`, `id`, and `id_ID` all resolve to the `id` profile —
/// because the closed class does not vary by region in any way this scorer could measure.
public struct LanguageProfile: Sendable, Hashable {

    /// Language subtag, lowercase: `"en"`, `"id"`.
    public var languageCode: String

    /// Whole tokens. 100-200 per language is the useful range; past that the additions are content
    /// words, which is where the noise starts.
    public var functionWords: Set<String>

    /// Affixes, which catch the inflected forms a word list misses ("laporan", "siapkan",
    /// "dibanding", "quarterly", "demanding").
    public var affixes: [LanguageMarker]

    public init(languageCode: String, functionWords: Set<String>, affixes: [LanguageMarker]) {
        self.languageCode = languageCode
        self.functionWords = functionWords
        self.affixes = affixes
    }
}

// MARK: - The tables

/// The shipped profiles.
///
/// **Adding a language.** Append one `LanguageProfile` to `all` and nothing else changes: the scorer
/// discovers profiles from this array, normalises scores across however many there are, and drops any
/// marker that more than one profile claims (see `LanguageScorer` — a shared marker cannot break a tie
/// between the languages sharing it, so it is removed rather than double-counted). Two rules for a new
/// table:
///
/// 1. **Function words only.** Pronouns, determiners, prepositions, conjunctions, auxiliaries,
///    negators, discourse particles. No nouns, no verbs of content, no loanwords.
/// 2. **Affix weights are a leakage budget, not a linguistics grade.** Ask "how often does this affix
///    appear at the same position in a *different* language's word?" and price it accordingly.
public enum LanguageProfiles {

    /// English. Function words from the standard closed-class inventory; affixes are the productive
    /// derivational and inflectional endings that survive a bad transcription.
    public static let english = LanguageProfile(
        languageCode: "en",
        functionWords: [
            // Determiners and pronouns
            "the", "a", "an", "this", "that", "these", "those", "i", "you", "he", "she", "it", "we",
            "they", "me", "him", "her", "us", "them", "my", "your", "his", "its", "our", "their",
            "myself", "yourself", "itself", "who", "whom", "whose", "which", "what", "someone",
            "something", "anything", "everything", "nothing", "everyone", "anyone",
            // Prepositions
            "of", "to", "in", "for", "with", "on", "as", "at", "by", "from", "into", "about", "over",
            "under", "between", "through", "during", "before", "after", "against", "without",
            "within", "upon", "across", "toward", "towards", "onto", "off",
            // Conjunctions and connectives
            "and", "or", "but", "if", "because", "while", "although", "though", "unless", "whether",
            "since", "than", "then", "so", "therefore", "however", "otherwise", "also", "besides",
            // Auxiliaries, copulas, modals
            "is", "are", "was", "were", "be", "been", "being", "am", "have", "has", "had", "having",
            "do", "does", "did", "will", "would", "shall", "should", "can", "could", "may", "might",
            "must", "let", "let's", "gonna", "wanna",
            // Negation, quantifiers, degree, discourse
            "not", "no", "never", "none", "nor", "all", "any", "some", "many", "much", "more", "most",
            "few", "less", "least", "both", "each", "every", "other", "another", "same", "such",
            "very", "quite", "just", "only", "even", "still", "yet", "too", "again", "always",
            "already", "almost", "really", "actually", "maybe", "perhaps", "here", "there", "when",
            "where", "why", "how", "now", "well", "yeah", "okay", "please", "thanks",
        ],
        affixes: [
            // -tion/-sion and -ment are the safest: Indonesian borrows them as -si and -men.
            LanguageMarker(text: "tion", position: .suffix, weight: 0.6),
            LanguageMarker(text: "sion", position: .suffix, weight: 0.6),
            LanguageMarker(text: "ment", position: .suffix, weight: 0.5),
            LanguageMarker(text: "ness", position: .suffix, weight: 0.5),
            // -ing leaks into Indonesian "dibanding", "sedang", "kurang" — but only when those words
            // are also carrying an Indonesian prefix, which scores against it. Priced mid.
            LanguageMarker(text: "ing", position: .suffix, weight: 0.5),
            LanguageMarker(text: "ous", position: .suffix, weight: 0.4),
            LanguageMarker(text: "ful", position: .suffix, weight: 0.4),
            LanguageMarker(text: "ly", position: .suffix, weight: 0.4),
            // -ed is cheap: two letters, and it lands on Indonesian names and loanwords.
            LanguageMarker(text: "ed", position: .suffix, weight: 0.3),
        ]
    )

    /// Indonesian. The function words are the ones that actually appeared in the measured meeting
    /// transcript, plus the rest of the closed class; the affixes are the standard derivational set.
    public static let indonesian = LanguageProfile(
        languageCode: "id",
        functionWords: [
            // Pronouns and person
            "saya", "aku", "kamu", "anda", "dia", "ia", "kita", "kami", "mereka", "beliau", "nya",
            "ku", "mu", "kalian",
            // Determiners, demonstratives, interrogatives
            "ini", "itu", "yang", "apa", "siapa", "mana", "dimana", "kemana", "bagaimana", "mengapa",
            "kenapa", "kapan", "sini", "situ", "sana", "begitu", "begini", "tersebut",
            // Prepositions
            "di", "ke", "dari", "untuk", "pada", "dengan", "oleh", "kepada", "dalam", "atas",
            "bawah", "antara", "tentang", "terhadap", "sampai", "hingga", "demi", "tanpa", "sejak",
            "buat",
            // Conjunctions and connectives
            "dan", "atau", "tapi", "tetapi", "namun", "kalau", "jika", "karena", "sebab", "sehingga",
            "agar", "supaya", "walaupun", "meskipun", "sedangkan", "serta", "maupun", "jadi",
            "kemudian", "lalu", "terus", "sementara", "ketika", "saat", "setelah", "sebelum",
            "selama", "justru", "bahkan", "misalnya", "seperti", "yaitu", "adapun",
            // Copulas, auxiliaries, aspect, modality
            "adalah", "ialah", "akan", "sudah", "telah", "belum", "sedang", "masih", "pernah",
            "bisa", "dapat", "boleh", "harus", "mesti", "mau", "ingin", "perlu", "mungkin", "ada",
            // Negation, quantifiers, degree, discourse particles
            "tidak", "tak", "bukan", "jangan", "gak", "nggak", "semua", "setiap", "seluruh",
            "banyak", "sedikit", "beberapa", "lebih", "paling", "sangat", "cukup", "hanya", "saja",
            "juga", "lagi", "sama", "sendiri", "masing", "sekali", "memang", "tentu", "bahwa",
            "baik", "hal", "iya", "ya", "kok", "sih", "deh", "dong", "nih", "aja", "kan", "pun",
            "kalo", "gitu", "banget",
            // Numerals that behave like function words in speech
            "satu", "dua", "tiga",
        ],
        affixes: [
            // The circumfixed noun/verb endings. -kan and -nya barely exist word-finally in English.
            LanguageMarker(text: "kan", position: .suffix, weight: 0.6),
            LanguageMarker(text: "nya", position: .suffix, weight: 0.6),
            LanguageMarker(text: "lah", position: .suffix, weight: 0.5),
            // -an is the most productive Indonesian ending and also English "human", "American":
            // priced low, and the scorer's minimum-stem rule already excludes "can", "plan", "than".
            LanguageMarker(text: "an", position: .suffix, weight: 0.4),
            // Nasalised me-/pe- prefixes are long enough to be safe.
            LanguageMarker(text: "meng", position: .prefix, weight: 0.5),
            LanguageMarker(text: "meny", position: .prefix, weight: 0.5),
            LanguageMarker(text: "peng", position: .prefix, weight: 0.5),
            LanguageMarker(text: "peny", position: .prefix, weight: 0.4),
            LanguageMarker(text: "memb", position: .prefix, weight: 0.4),
            LanguageMarker(text: "memp", position: .prefix, weight: 0.4),
            LanguageMarker(text: "pemb", position: .prefix, weight: 0.4),
            LanguageMarker(text: "ber", position: .prefix, weight: 0.4),
            // ter-/di- are the two that leak ("term", "territory", "different", "discussion"), and
            // di- is the one the measured transcript needs ("dibilang", "dibanding"). Kept, cheap.
            LanguageMarker(text: "ter", position: .prefix, weight: 0.35),
            LanguageMarker(text: "di", position: .prefix, weight: 0.3),
        ]
    )

    /// Every profile the scorer knows. Order fixes nothing — the scorer sorts its own output.
    public static let all: [LanguageProfile] = [english, indonesian]
}
