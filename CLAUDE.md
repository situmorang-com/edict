# Edict

Push-to-talk dictation for macOS. Everything runs on the user's machine.

`docs/RECON.md` holds every measurement this project has taken — the speech engine, the hotkey tap,
injection, file import, the on-device refinement model, per-app Accessibility. Read the relevant
section before changing any of those, and add what you measure to it.

`docs/CONTRACTS.md` holds the layer boundaries and who owns which file. Read it before adding a type
or moving one.

## Measure, then claim

A number in prose is a claim, and this project has had to retract several. Derive counts and sizes
where they are printed; where a measurement has to be written down, put it in `docs/RECON.md` with
the conditions it was taken under.

State plainly what you did not verify. A unit test cannot press a key, speak into a microphone or
prove a paste landed in somebody else's app, so a feature covered only by tests is untried, and
saying so is part of finishing it.

## The traps that cost real data

**Set `EDICT_SUPPORT_DIR` before running anything that exercises the installed app.** Without it the
run writes to `~/Library/Application Support/Edict`, which is the user's own history. A verification
run once cut thirty transcripts to two, with no backup anywhere.

The default suite is offline and deterministic. The live ones are gated: `EDICT_SPEECH_TESTS=1`
(speech engine), `EDICT_MODEL_TESTS=1` (Foundation Models), `EDICT_TAP_TESTS=1` (event tap). Run the
gate that covers what you changed, and say which ones you ran.

## Working with the on-device models

A prompt is not a guard. Anything that must hold — the language never changes, nothing is
translated, no fact is added — needs a deterministic check in code beside the instruction.
`TextRefiner.languageDrifted` is the pattern: the model is asked, and the answer is then verified.

Keep model instructions short. On this ~3B model a fourth clause measurably diluted the first three.
Anything mechanical belongs in Swift, not in the prompt.

Build a fresh `LanguageModelSession` per refinement, and sample greedily. A reused session lets the
previous dictation condition the next one, and temperature is what turns transcription into
paraphrase.

Treat capability flags as advisory and measure instead: `supportsLocale(id_ID)` reports false while
Indonesian clean-up measures excellent.

## Showing UI work

Screen Recording is denied to any process an agent starts, so a view is proved by rendering it, not
by photographing it: `EDICT_RENDER_<SURFACE>=1 EDICT_RENDER_DIR=<dir> swift test --filter render`
writes proof sheets in light and dark. `ImageRenderer` will not rasterise a `ScrollView`'s contents,
which is what the fixtures' `unbounded` hatch exists for.

## What is never written down

The user's dictated text, their transcript filenames and the contents of other apps' fields stay out
of logs, telemetry and stored metrics. Keep outcomes and counts instead — `EditCheck` is the shape to
follow.

This repository is public. Fixtures use placeholder names: `Contoso`, `Northwind`, `Budi Santoso`.

## Commits

Write the subject as the change the user gets, in the imperative: "Stop restoring the clipboard
before the target has read the paste". Use the body for what was wrong, what it now does, and what
is still unproven. Sign off with the message alone — no trailers, no attribution lines.
