<div align="center">

# Edict

**Push-to-talk dictation for macOS. Hold a key, talk, and the words land where your cursor already is.**

Runs on your machine. Nothing you say or import leaves the computer, there is no account,
and there is nothing to pay for.

[![macOS 26+](https://img.shields.io/badge/macOS-26%2B-1d1d1f?style=flat-square)](https://www.apple.com/macos/)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![Zero dependencies](https://img.shields.io/badge/dependencies-0-4C8A3A?style=flat-square)](Package.swift)
[![763 tests](https://img.shields.io/badge/tests-763-4C8A3A?style=flat-square)](Tests)
[![MIT](https://img.shields.io/badge/licence-MIT-blue?style=flat-square)](LICENSE)

![Edict's main window](docs/images/history.png)

</div>

---

## What it does

Hold **⌥** (Right Option), say something, let go. The text is inserted at your cursor in whatever
app has focus — editor, terminal, browser, chat.

Transcription is Apple's on-device `DictationTranscriber`. Your audio is never uploaded, there is no
account and no subscription, and zero third-party dependencies ship in the app.

The one thing that does touch the network: macOS downloads each language's speech model from Apple
once, the first time you choose that language. Edict shows the progress in Settings and tells you if it
fails. After that the language works offline forever. Nothing you say is part of that exchange — this
README used to claim "no network round trip", which was simply wrong.

| | |
|---|---|
| **Hold to talk** | ⌥ for English, **⇧⌥ for Indonesian** — the language is chosen per utterance, not by a mode you can forget you are in |
| **Text at your cursor** | A verified fallback ladder. Every insertion is *confirmed*, never assumed |
| **A dictionary you teach** | Two mechanisms at once: the engine is biased toward your terms, and a guaranteed correction pass runs afterwards |
| **File transcription** | Drop in audio or video — m4a, mp3, wav, aiff, caf, **mp4, mov**. Batch queue, per-word timestamps, TXT/SRT/VTT export |
| **Searchable history** | With the raw-versus-corrected diff, so you can see what the dictionary actually did |
| **33 languages, 54 locales** | Including Indonesian and Malay |
| **A real app** | Dock icon, app menu, resizable window, Settings on ⌘, and a menu-bar extra |

## Transcribing files

Drop a file on the window, press ⌘O, or open it from Finder. The audio track is pulled out of the
container, so a video costs nothing extra.

![Importing a nine-minute recording](docs/images/import.gif)

*A nine-minute recording, transcribed in about eight seconds.*

Each queued file carries **its own language**, editable while it waits and re-runnable afterwards in
another one — and the acoustic model is resolved per item, so an English file and an Indonesian file in
the same batch run on different modules. A missing model downloads or says so; it never quietly borrows
another language.

Measured on an M5 Pro: **11.5–31.9× realtime** (11.5 is the cold first file; 27.4 is a video track;
31.9 is Indonesian), **75×** on a six-minute file, with **4.1% word error** against the source script.
Imports land in history with timestamps and never touch your cursor — that is the line between
dictating and transcribing.

### What this does not do

**Far-field, multi-speaker recordings come back nearly empty.** A 70-minute meeting recorded across a
room produced about 16 words per minute where the same voice close to the mic produces ~130. Apple's
models are conservative rather than wrong: given audio they cannot resolve, they emit nothing instead of
guessing. No setting in Edict recovers that, and none of them claims to — Edict measures the
words-per-minute it achieved and flags the transcript when it looks like this, so you find out from the
app rather than from reading the result. For that class of audio, use a tool built around a model
trained for it.

**There is no automatic language detection**, because the framework has no language-identification
head. Live dictation uses ⇧⌥ to pick the second language per utterance. Imports can opt into a
two-transcript scorer, off by default, which transcribes twice and keeps the better-scoring result — it
helps when the *language* was wrong, and it does not help the far-field case above.

## Clean it up afterwards, on-device

Dictation gives you what you said, filler and all. Any transcript can then be turned into clean prose,
a bullet list, or a one-sentence summary — **on this machine**, with Apple's on-device model. No API
key, no network, nothing leaving the computer.

    in   so um i think we should like move the meeting to thursday because uh mark
         is out on wednesday and we need him for the budget bit

    out  So I think we should move the meeting to Thursday because Mark is out on
         Wednesday and we need him for the budget bit.

Measured: clean-up 0.8–1.0 s, bullets ~1.0 s, summary ~0.8 s. It works in Indonesian too, which Apple
reports as an unsupported locale — so the result is captioned as carrying no guarantees rather than
quietly disabled.

The refined text always sits **beside** the transcript, never over it: the raw dictation is the record
of what was actually said. Refining before insertion is available as a setting, off by default, because
it adds a second or so to every dictation.

## Refine text you already have

Select text in any app, press **🌐/** (Globe and slash), and a small panel offers the same three
actions — clean up, bullets, summarise. Pick one and the selection is replaced in place. It never
activates Edict, so you stay where you were typing.

The Globe shape is the one keystroke Edict swallows, and only while the panel is up. That costs nothing
in practice: 🌐/ produces no character on any layout Edict measured, so there is nothing to intercept.

If Globe is awkward on your keyboard, Settings offers **⌘⌥/**, **⌥⌘R** and **⌃⌥R**, none of which
Edict swallows. One caveat worth knowing: the *Globe-then-dictation-key* option only works on Apple
keyboards, because the Fn bit is not reported by every third-party keyboard — the picker says so rather
than letting you discover it.

**A replace it cannot verify refuses.** If Edict cannot confirm the replacement landed, it leaves the
refined text on your clipboard and tells you, rather than pasting over your selection and hoping. The
same rule as dictation: never claim an outcome it did not check.

## The dictionary is the interesting part

Every dictation tool mangles proper nouns. Edict attacks that from two directions, because neither
alone is enough.

**Before transcription**, your terms are passed to the speech engine as contextual strings, so it
leans toward producing them. This genuinely works — `"Visa and soup base and anthropic"` became
`"Vercel and Supabase and Anthropic"`.

**After transcription**, a guaranteed pass rewrites what biasing missed. It is a single
left-to-right scan, earliest-then-longest across all rules, emitting into a buffer — so a rule can
never fire on another rule's output. It catches the forms these models glue together:

```
cloud code · cloud-code · cloud_code · CloudCode · Cloud Code   →   Claude Code
```

...while never touching `Cloudflare`, `clouds`, `iCloud`, or `CloudCodeBase`. There are 30 tests on
that behaviour alone, because it is the difference between a useful feature and one that quietly
corrupts your prose.

The history view shows when a rule fired and what it changed, so you can tell whether the dictionary
is earning its place.

## Install

Requires macOS 26 or later and Xcode 26+. No Xcode project, no Developer ID, no `sudo`.

```bash
git clone https://github.com/situmorang-com/edict.git
cd edict
./scripts/build-app.sh install     # → ~/Applications/Edict.app
```

The script bootstraps a **local self-signed identity** into its own keychain. That detail matters
more than it sounds: macOS keys Accessibility and Input Monitoring grants to the *code signature*,
and an ad-hoc signature's designated requirement is a bare `cdhash` — so your permissions would be
dropped on **every rebuild**. A stable certificate makes the requirement `identifier + certificate`,
and the grants survive.

> `swift run` is not a valid way to run this app: no bundle identifier, no `Info.plist`, and it lands
> in `.accessory` activation policy. Always go through the script.

### Permissions

Four — three of them critical — granted once, each explained in plain language in the app's own
Permissions pane.

| Permission | Why |
|---|---|
| **Microphone** | To hear you. Prompted on first recording |
| **Input Monitoring** | To notice the hold-to-talk key while you are in another app |
| **Accessibility** | To read the focused text field, so it can confirm your words actually landed |
| **Send Keystrokes** | Lets Edict paste your words at the cursor. Granted together with Accessibility |

Send Keystrokes is the one that is not critical: without it Edict still inserts through the
Accessibility path, and falls back to leaving the text on your clipboard and telling you so.

After granting Input Monitoring, press **RESTART** in the Permissions pane. This is not optional: a
`CGEventTap` created while permission was denied comes back **non-nil but permanently dead**, and no
amount of re-enabling revives it. The tap has to be rebuilt.

## Two languages, one key

Hold **⌥** for your primary language. Hold **⇧⌥** for your second.

The modifier is sampled at *arm* time, so either press order works. Either Shift counts. The
HUD shows which language is live while you speak — mid-utterance is the only moment a mis-registered
chord is free to redo.

Configure both in Settings (⌘,). The model for a new language downloads on first use, about 30
seconds. If it is missing, the first press says so rather than transcribing Indonesian with an
English model, which produces confident nonsense.

## Notable findings

Building this meant probing APIs that are new and thinly documented. Several results contradict what
the documentation implies, and all of them were established by compiling and running code rather
than by reading. The full set is in [`docs/RECON.md`](docs/RECON.md); these are the ones that changed
the design.

**`contextualStrings` is a no-op on `SpeechTranscriber`.** Measured byte-identical output across four
audio files and four configurations. It works on `DictationTranscriber` — which is why Edict uses
that module, and why the dictionary's biasing layer exists at all. The distinction is undocumented.

**Vocabulary biasing gets *worse* with more terms.** A 9-term list fixed proper nouns that a
200-term list did not, and analyzer setup grows from 6 ms to 577 ms. Hence the 50-term cap, and hence
the second correction pass behind it. Biasing is a nudge, not a promise.

**The Accessibility API reports success on writes it silently ignores.** Electron apps return
`kAXErrorSuccess` and do nothing. So every insertion is verified by reading back, and an app that
cannot be verified is demoted to paste-only and *remembered*. That turns a hardcoded blocklist into
something self-healing.

**Volatile results replace, finals append.** Naive concatenation produced 7,310 characters where 412
was correct — a 17.7× bloat.

**One analyzer per utterance, never reused.** `finalize` deadlocks forever while the input stream is
open, and `start()` on a finished analyzer silently no-ops, losing the utterance with no error.

**The two modules have different locale sets** — 45 versus 54. Indonesian exists only in
`DictationTranscriber`. Imports prefer `SpeechTranscriber` (4.2% word error at 66× realtime, against
10.1% at 15×) and fall back when the locale is uncovered.

## What it deliberately does not do

**Speaker identification.** Apple's Speech framework ships three modules — `SpeechTranscriber`,
`DictationTranscriber`, `SpeechDetector` — and none separates voices. A multi-person recording
arrives as one block of text with no names and no turn breaks. The app states this where you would
look for it rather than letting you find out on a meeting recording. Doing it properly needs Whisper
plus pyannote, which is gigabytes of weights against this app's few megabytes.

**Automatic language detection.** `DictationTranscriber` takes a fixed locale and has no
language-identification head. The only multilingual entry in the framework is `mul_IN`, on the module
that has no Indonesian. Hence ⇧⌥ for live dictation, a language per file on import, and the optional
two-transcript scorer described above — which picks between two languages you nominate rather than
identifying one.

Both would fit behind the `TranscriptionEngine` seam in
[`Engine/Transcriber.swift`](Sources/EdictKit/Engine/Transcriber.swift), which exists for exactly
that reason.

## How it stays small

| | |
|---|---|
| Executable, release, stripped | ~3.9 MB |
| Icon | ~1.0 MB |
| Embedded frameworks | **none** |

`./scripts/build-app.sh` prints the executable, icon and bundle byte totals at the end of every build.
Those are the numbers to trust: the figures published here were wrong in four places for several
commits, because restating a measurement by hand is how it goes stale. The build strips ~4.6 MB of
local symbols before signing — it has to be before, or the signature is invalidated and the process is
killed on first page-in.

Every dependency resolves to `/System` — AppKit, SwiftUI, AVFoundation, Speech, CoreGraphics, IOKit.
The speech models are the OS's, shared by every app that asks, and managed by it.

For comparison: MacWhisper ships Whisper weights measured in gigabytes.

## Repo layout

```
Sources/EdictKit/
  App/       scene graph, app model, the dictation controller
  Engine/    hotkey tap, audio capture, speech, text injection, file import
  Data/      settings, dictionary, corrector, history, export
  Design/    tokens, components, VU meter, waveform
  Views/     main window, history, dictionary, import, settings, permissions
  Support/   the shared os.Logger
Sources/Edict/          thin launcher; calls EdictApp.main()
Tests/EdictKitTests/    unit tests; `swift test list | wc -l` for the count
docs/                   RECON.md, CONTRACTS.md, design system
scripts/build-app.sh    swift build → stripped, signed, launchable .app
```

The test count is deliberately not written here. It was wrong in three mutually contradictory places
across this file, because a number that changes every commit and is maintained by hand only ever drifts.
The badge at the top is the one place it appears, and `swift test list | wc -l` is the source of truth.

Everything real lives in the `EdictKit` library so the corrector, stores and exporters are unit
testable; the executable only calls `EdictApp.main()`.

## Design

The direction is a **1980s portable field recorder** — Sony TC-D5, Marantz PMD, Nakamichi, Braun.
Brushed aluminium and matte plastic, warm greys and cream, one red for the record lamp, amber and
green for level. Buttons that look pressed rather than tinted. The recording indicator is a VU meter
with a needle on a printed arc, not a progress bar.

It is defined as tokens before any view exists — colour, type, spacing, radius, border, shadow,
motion — and no view is permitted a one-off value. The needle's ballistics are the measured ANSI
C16.5 integration time, not an invented animation curve. See
[`docs/DESIGN-TOKENS.md`](docs/DESIGN-TOKENS.md) and
[`docs/DESIGN-COMPONENTS.md`](docs/DESIGN-COMPONENTS.md).

## Documentation

- [`docs/RECON.md`](docs/RECON.md) — empirical findings from probing these APIs
- [`docs/CONTRACTS.md`](docs/CONTRACTS.md) — interfaces, and the amendments that override them
- [`docs/DESIGN-TOKENS.md`](docs/DESIGN-TOKENS.md) · [`docs/DESIGN-COMPONENTS.md`](docs/DESIGN-COMPONENTS.md)

## Licence

MIT. See [LICENSE](LICENSE).
