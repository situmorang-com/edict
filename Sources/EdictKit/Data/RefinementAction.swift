import Foundation

/// The three things Edict will do to a finished dictation, and nothing else.
///
/// **Why only three.** Every action here is a *transformation of words the user already said*. That
/// is the only category of help this app can offer without breaking the promise the rest of it is
/// built on: the transcript is a record of speech, and a record that quietly grows a fact it was
/// never told is worse than no help at all. "Rewrite in a friendlier tone", "expand this into an
/// email", "answer the question in the dictation" all require the model to invent, so they are not
/// here and should not be added.
///
/// **Measured on this machine** (Apple M5 Pro, macOS 27.0, `SystemLanguageModel.default`
/// `availability == .available`), which is why all three shipped rather than just one:
///
///     clean-up of a 60-word run-on dictation .......... 2.89 s cold, excellent
///     bullet list ..................................... 1.03 s warm, correct
///     one-sentence summary ............................ 1.05 s warm, accurate
///     Indonesian clean-up ............................. 1.45 s warm, excellent
///
/// The Indonesian run is the interesting one: `supportsLocale(id_ID)` returns **false**, yet the
/// model upgraded vocabulary correctly ("mundurkan" → "menunda", "libatkan" → "melibatkan"). So an
/// unsupported locale is treated as *"no guarantees"*, never as *"refuse"* — see
/// ``RefinerAvailability/localeUnsupported(_:)``.
public enum RefinementAction: String, Codable, CaseIterable, Sendable, Identifiable {

    /// Punctuation, capitalisation and sentence breaks repaired; filler and false starts removed.
    /// Meaning preserved exactly — this is copy-editing, not rewriting.
    case cleanUp

    /// The same content reorganised into concrete points, one per line.
    case bullets

    /// One sentence saying what the dictation was about.
    case summarise

    public var id: String { rawValue }

    /// The label for a silkscreen key. Upper case because that is what the key caps in
    /// `DESIGN-COMPONENTS.md` are set in; the view does not re-case it.
    public var title: String {
        switch self {
        case .cleanUp: "CLEAN UP"
        case .bullets: "BULLETS"
        case .summarise: "SUMMARY"
        }
    }

    /// One plain sentence for a tooltip or a settings row. Each one says what the action will *not*
    /// do as well as what it will, because "clean up" and "summarise" both sound to a first-time
    /// user like they might quietly reword things.
    public var explanation: String {
        switch self {
        case .cleanUp:
            "Fixes punctuation and capitalisation and drops filler words, keeping your own wording and every fact you said."
        case .bullets:
            "Splits what you said into separate points, one per line, without adding any point you did not make."
        case .summarise:
            "Writes a single sentence describing what you said, using only what is already in the transcript."
        }
    }
}
