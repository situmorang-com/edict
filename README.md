# Edict

A push-to-talk dictation app for macOS. Hold a key, talk, release, and the text lands where your
cursor already is — in any app. Transcription runs entirely on your machine: nothing you say leaves
the computer, there is no API to call, and there is nothing to pay for.

Built with Apple's on-device `DictationTranscriber` (macOS 26+), so there is no model to download
and no third-party dependency anywhere in the tree.

## What it does

- **Hold-to-talk.** Right Option by default, rebindable. Release ends the utterance.
- **Text at your cursor.** A verified fallback ladder — Accessibility insert, then pasteboard and a
  layout-correct Cmd-V, then synthetic keystrokes, then leaving it on the clipboard. Every rung is
  *verified*, never trusted, because the Accessibility API returns success on elements that silently
  ignore it.
- **A dictionary you can teach.** Two mechanisms at once: your terms are fed to the speech engine as
  contextual strings so it leans toward producing them, and a guaranteed correction pass runs
  afterwards. It catches the forms these models glue together — a `cloud code` rule matches
  `CloudCode` and `Cloud-Code` — without ever corrupting `Cloudflare`.
- **Searchable history**, with the raw-versus-corrected diff so you can see what the dictionary
  actually did, and per-word confidence surfacing likely mishearings as one-click dictionary entries.
- **A real app.** Dock icon, app menu, resizable window, Settings on `Cmd+,`, and a menu-bar extra as
  a secondary surface. Not a menu-bar utility.

## Build

Requires macOS 26+ and Xcode 26+. No Xcode project, no Developer ID, no sudo.

```bash
./scripts/build-app.sh          # -> build/Edict.app
./scripts/build-app.sh install  # -> ~/Applications
```

The script bootstraps a local self-signed code-signing identity into its own keychain. That matters:
macOS keys Accessibility and Input Monitoring grants to the code signature, and an ad-hoc signature's
designated requirement is a bare `cdhash` — so the grants would be dropped on **every rebuild**. A
stable certificate makes the requirement `identifier + certificate root`, and the grants survive.

`swift run` is not a valid way to run this app: it has no bundle identifier, no `Info.plist`, and
lands in `.accessory` activation policy. Always go through the script.

## Permissions

Three, granted once, all with a plain-language explanation in the app's Permissions pane:

| Permission | Why |
|---|---|
| Microphone | To hear you. Prompted on first recording |
| Input Monitoring | To see the hold-to-talk key while you are in another app |
| Accessibility | To read the focused text field, so it can confirm the text actually landed |

## Transcribing files

Drop an audio or video file on the window, pick one with `Cmd+O`, or open it from Finder. Audio and video
containers both work — m4a, mp3, wav, aiff, caf, mp4, mov — because the reader pulls the audio track out of the
container rather than assuming an audio file. Multiple files queue and run one at a time.

Imports land in **history with per-word timestamps**, exportable as **TXT, SRT or VTT**. They are never injected at
your cursor — that is the difference between dictating and transcribing.

Measured on this machine: about 9–27x realtime warm, and 75x on a six-minute file. Word error against the source
script was 4.1% on that file.

**Edict does not identify speakers.** Apple's on-device speech framework has no module that separates one voice from
another, so a meeting or interview arrives as one block of text with no names and no turn breaks. If you need who
said what, Edict cannot give you that, and the app says so where you would look for it.

Imports use `SpeechTranscriber`, which measured 4.2% word error at 66x realtime against `DictationTranscriber`'s
10.1% at 15x on identical audio. Live dictation keeps `DictationTranscriber`, because vocabulary biasing only works
there — and so does Indonesian, which imports fall back to it for.

## Languages

54 locales, including **Indonesian (`id_ID`)** and Malay (`ms_MY`). Pick one in Settings; the on-device model
for a new locale downloads on first use (~30 s). Verified: a spoken Indonesian sentence transcribed word-perfect
in 0.36 s.

Note that `SpeechTranscriber` and `DictationTranscriber` expose *different* locale sets — 45 versus 54, and
Indonesian is only in the latter. Edict uses `DictationTranscriber`.

macOS reserves at most 5 locales per app at a time; Edict evicts the least recently used when it needs a slot.

## Documentation

- [`docs/RECON.md`](docs/RECON.md) — empirical findings from probing these APIs. Most are
  counter-intuitive, several are undocumented, and all of them were established by compiling and
  running code rather than by reading the docs.
- [`docs/CONTRACTS.md`](docs/CONTRACTS.md) — interfaces, plus the amendments that override them.
- [`docs/DESIGN-TOKENS.md`](docs/DESIGN-TOKENS.md) and
  [`docs/DESIGN-COMPONENTS.md`](docs/DESIGN-COMPONENTS.md) — the design system.

The design direction is a 1980s portable field recorder — Sony TC-D5, Marantz PMD, Nakamichi, Braun.
Brushed aluminium and matte plastic, warm greys and cream, one red for the record lamp, amber and
green for level. The recording indicator is a VU meter with a needle, not a progress bar.

## Notable findings

Two are worth stating up front, because they contradict what the documentation implies:

- **`AnalysisContext.contextualStrings` is a no-op on `SpeechTranscriber`.** Measured byte-identical
  output across four audio files and four configurations. It works on `DictationTranscriber`, which
  is why this app uses that module. The entire dictionary-biasing feature depends on the distinction.
- **Vocabulary biasing degrades with list length.** A 9-term list fixed proper nouns that a 200-term
  list did not, and setup cost scales from 6 ms to 577 ms. Hence the 50-term cap, and hence the
  second correction pass — biasing is a nudge, not a promise.

## Status

The engine, dictionary, history and UI all work. Injection into other apps is implemented against a
verified strategy ladder but has not yet been exercised end-to-end with permissions granted.

## Licence

MIT. See [LICENSE](LICENSE).
