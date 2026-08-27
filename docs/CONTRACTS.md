# Edict — implementation contracts

> ## RECON AMENDMENTS — read these first, they override anything later in this file
>
> Five probe agents compiled and ran real code on this machine before any of this was written. Their findings are
> in [`RECON.md`](RECON.md) and their verified snippets are in the scratchpad under `recon/snippets/`.
> **`RECON.md` outranks this file, and both outrank your instincts about these APIs.** Several findings are
> counter-intuitive and cost an agent hours to establish. Do not re-litigate them; do not "fix" them from memory.
>
> 1. **The engine is `DictationTranscriber`, NOT `SpeechTranscriber`** — *for live dictation*. This is the single most important finding.
>    `AnalysisContext.contextualStrings[.general]` is a measured, complete **no-op on `SpeechTranscriber`**
>    (byte-identical output across 4 audio files × 4 configurations) but demonstrably **works on
>    `DictationTranscriber`** — "Visa and soup base and anthropic" became "Vercel and Supabase and Anthropic".
>    The whole dictionary-biasing feature depends on this. `DictationTranscriber` also exposes
>    `TranscriptionOption.punctuation` and was independently better on proper nouns.
>    **Amended for file import** (RECON, "File transcription — module choice"): on a whole file,
>    biasing is not the deciding factor and `SpeechTranscriber` measured 4.2 % word error at 66x
>    realtime against `DictationTranscriber`'s 10.1 % at 15x on the same 377 s audio. Imports
>    therefore default to `SpeechTranscriber`, falling back to `DictationTranscriber` for the 9
>    locales it does not cover (Indonesian among them) or when its assets are not installed. The
>    switch is `Settings.importUsesGeneralModel`. Live dictation is unchanged.
> 2. **Context must be passed to `SpeechAnalyzer.init(analysisContext:)`.** `setContext(_:)` mid-stream is a silent
>    no-op. Dictionary edits therefore take effect on the *next* utterance — read the dictionary at key-down.
> 3. **Build a fresh module + analyzer per utterance. Never reuse.** `finalize(through:)` deadlocks forever while the
>    input stream is open, and `start()` on a finished analyzer silently no-ops, losing the utterance with no error.
>    Warm cost is ~2.5 ms; call a throwaway `warmUp()` at launch to pay the ~50 ms cold cost.
> 4. **Volatile results REPLACE a tail; finals APPEND.** Naive appending produced 7310 characters where 412 was
>    correct. `committed = concat(finals in arrival order)`, `display = committed + volatileTail`, tail cleared on
>    every final. Final ranges are disjoint and monotonic but **not** contiguous — never assert `start == prevEnd`.
>    **Inject only `committed`.** Volatile text is materially worse and frequently wrong mid-word.
> 5. **Cap `biasingLimit` at 50, not 100.** Cost is ~65 ms + ~1.5 ms/term at analyzer init, and hit rate measurably
>    *degrades* with list length — a 9-term list fixed "Wispr Flow" and "Obsidian" where a 200-term list fixed
>    neither. Rank and send the top ~50; the correction pass handles the tail. This is why the two-layer dictionary
>    is not optional: layer 1 alone is unreliable, layer 2 alone loses the acoustic-level wins.
> 6. **`AssetInventory.reserve(locale:)` is effectively required** (framework logs "will be an error in a future
>    release"). Reserve *before* constructing any module. `release()` matches on the raw identifier **string**, so
>    only ever release `Locale` objects taken from `await AssetInventory.reservedLocales` — otherwise the 5
>    reservation slots leak permanently across process launches. Do not gate downloads on
>    `AssetInventory.status(...)`; it returns `.supported` for locales that are installed but unreserved. Gate on
>    `assetInstallationRequest(supporting:) == nil` instead.
> 7. **Never derive the locale from `Locale.current`.** This machine's locale is `en_ID`, which resolves to `en-IN`
>    — silently the wrong acoustic model. Default to an explicit `en-US`. Note the two modules have *different* locale sets: `id-ID` is unsupported by
>    `SpeechTranscriber` but IS supported by `DictationTranscriber`, which is what we use (54 locales vs 45).
> 8. **The default hotkey is Right Option** (keyCode 61, device bit `0x40`, full down-flags `0x00080040`).
>    This machine runs **Karabiner-Elements with 729 event taps** and its active profile already claims
>    `right_command` (→Hyper/Escape), `caps_lock` (→symbol layer) and `fn`. Siri and SiriNCService hold
>    `.defaultTap` taps on `flagsChanged` ahead of us, so `fn` is contested. `right_option` and `right_control`
>    appear zero times in the active profile — but the only attached keyboard is the MacBook's internal one, which
>    has no Right Control key. Right Option is therefore the only good default. The picker must still allow rebinding.
> 9. **Never intersect modifier flags with `.deviceIndependentFlagsMask`** (measured `0xffff0000`) — it discards
>    exactly the low bits that distinguish left from right. Work on the raw `UInt64`.
> 10. **`kAXTrustedCheckOptionPrompt` does not compile under Swift 6** (imported as a mutable global `var`).
>     Use the literal string key `"AXTrustedCheckOptionPrompt"`.
> 11. **A `.listenOnly` `CGEvent.tapCreate` returns a non-nil, permanently-dead port when access is denied**, and the
>     window server silently strips `keyDown`/`keyUp` from your mask. Gate on `CGPreflightListenEventAccess()`
>     *before* creating, assert `CGEvent.tapIsEnabled` after, and verify the granted mask via `CGGetEventTapList`
>     filtered on `getpid()`. After the user grants permission you must **destroy and re-create** the tap.
> 12. **Run the tap on a dedicated `.userInteractive` thread with its own CFRunLoop.** Measured: with the main thread
>     blocked 3 s, a dedicated run loop serviced 151/150 ticks and the main run loop serviced 0/150. Teardown must be
>     `CFRunLoopRemoveSource` → `tapEnable(false)` → `CFMachPortInvalidate`, or you leak one Mach port per tap, 1:1.
>     Pass context with `Unmanaged.passUnretained`. Handle `.tapDisabledByTimeout` / `.tapDisabledByUserInput`
>     explicitly — and **abort any hold in progress**, because you may have missed the key release and would
>     otherwise record forever.
> 13. **Use `.listenOnly`, never suppress the hotkey.** Right Option is AltGr on many layouts. Disambiguate in
>     software instead: require the modifier held alone (cancel on any other key or modifier) and require a ~120 ms
>     minimum hold before committing to a recording.
> 14. **`CGEvent.post` has no error channel and is silently dropped without permission.** Pre-flight with
>     `CGPreflightPostEventAccess()` **and** `IsSecureEventInputEnabled()` (a focused password field drops every
>     posted event). The only success signal Strategies B and C have is an AX read-back fingerprint poll.
> 15. **Never hardcode `kVK_ANSI_V` for the synthetic Cmd-V.** On some layouts keycode 9 is Cmd-W, which closes the
>     user's browser tab — destructive, not merely broken. Resolve from the live layout via
>     `TISCopyCurrentKeyboardLayoutInputSource` + `UCKeyTranslate`.
> 16. **Never use a fixed sleep before restoring the clipboard.** Post Cmd-V, floor at ~35 ms, then poll the AX
>     fingerprint every 20 ms up to 400 ms, then restore — and **skip the restore entirely if `changeCount` moved**
>     (a clipboard manager or the user wrote after us). `changeCount` does *not* increment on paste, so it cannot
>     verify success. Snapshot **all** types of **all** items, skipping flavors whose `data(forType:)` is nil
>     (`public.utf16-external-plain-text` is listed but synthesized lazily; force-unwrapping it crashes).
> 17. **`AVAudioConverter` is always required.** Hardware is 24 kHz or 48 kHz Float32 non-interleaved; the analyzer
>     accepts only 16 kHz (or 8 kHz) **Int16 interleaved**. One reused converter per utterance — creating one per
>     buffer resets the resampler and inserts a discontinuity every buffer boundary.
> 18. **`AVAudioEngine().inputNode.outputFormat(forBus: 0)` segfaults** as a one-liner; the temporary engine dies
>     first. Bind the engine to a local and `withExtendedLifetime`. Pass `format: nil` to `installTap` — passing an
>     explicit format after a device change throws an **uncatchable** ObjC exception that aborts the process.
> 19. **`installTap`'s `bufferSize` is advisory, hard-clamped to [100 ms, 400 ms].** Level updates therefore arrive
>     at only 2.5–10 Hz. Never animate the VU needle from the tap: store `(rmsDB, peakDB, seq)` under a `Mutex` and
>     run the ballistics on a 60 Hz main-actor tick. Verified ballistics: one-pole
>     `needle += (target - needle) * (1 - exp(-dt/tau))`, `attackTau = 0.065 s` (ANSI C16.5 300 ms integration),
>     `releaseTau = 0.150 s`; map −54 dBFS → 0 dBFS onto the sweep, "0 VU" at −18 dBFS, red above −6 dBFS; peak
>     holds 1.5 s then falls at 20 dB/s. Calibration: quiet room −61…−48 dBFS, speech −18…−13 dBFS.
> 20. **`.bufferingNewest(n)` discards the OLDEST element** — a consumer stall silently deletes the *beginning* of
>     the utterance and looks like a model failure. Size the buffer in **seconds** (16 kHz mono Int16 is 32 KB/s, so
>     100 s costs ~3 MB), count `.dropped`, and surface a "transcript may be incomplete" flag when non-zero.
> 21. **Yielding directly from the tap block is safe** — it is not a real-time render thread (measured
>     `QOS_CLASS_DEFAULT`, `sched_priority` 31) and `yield` costs ≤50 µs against a ≥100 ms budget. Never yield or
>     store the tap's own buffer; always yield the converter's output.
> 22. **Default to start-on-keydown, not a pre-warmed mic.** Measured loss is only 14–27 ms, well inside human
>     press-then-speak reaction time, and a pre-warmed mic keeps the orange indicator lit for the whole session —
>     which for a dictation tool reads as "always listening". Offer pre-warm as an explicit opt-in mode.
> 23. **Sign with a stable self-signed certificate from day one, not ad-hoc.** Ad-hoc's designated requirement is a
>     bare `cdhash`, so TCC drops Accessibility and Input Monitoring on **every rebuild**. A self-signed cert yields
>     `identifier "com.edict.app" and certificate root = H"…"`, verified stable across clean rebuilds and source
>     mutation. Creating it needs **no sudo and no admin password**, but `security set-key-partition-list` is
>     mandatory or `codesign` hangs forever on an invisible GUI prompt. Ignore `find-identity -v` reporting
>     "0 valid identities" — that is the cert being untrusted, and trust is unnecessary. Do **not** run
>     `security add-trusted-cert`; it hangs on an admin prompt.
> 24. **Never declare `resources:` on the app target.** `Bundle.module` resolves to `Edict.app/Edict_Edict.bundle`
>     at the bundle root, which makes `codesign` fail outright ("unsealed contents present in the bundle root"), and
>     its fallback path is a hardcoded absolute reference into `.build`. Keep assets in the top-level `Resources/`
>     and have the build script copy them into `Contents/Resources`. Use `Bundle.main` only.
> 25. **`swift run` is not a valid dev loop for this app** — no bundle identifier, no Info.plist, no Dock icon,
>     `.accessory` activation policy. Always iterate through `scripts/build-app.sh` (~1 s incremental).
>     Ship non-sandboxed: App Sandbox breaks CGEventTap and the AX API, and a test-signed sandboxed build leaves an
>     undeletable container behind. Leave `LSUIElement` out entirely — an `NSStatusItem` needs no plist key, and the
>     probe confirmed a Dock icon, a full app menu, the main window and a menu-bar extra all coexist.
> 26. **Pre-warm the injection path at launch**, off the hot path: retain one long-lived
>     `CGEventSource(stateID: .privateState)`, create and discard one `CGEvent`, call `AXIsProcessTrusted()`, and do
>     one throwaway system-wide AX read. Cold start otherwise costs 55–90 ms (once 1422 ms) on the first dictation.
> 27. **`CGEventSource.flagsState(.privateState)` blocks forever.** Use `.combinedSessionState`.
>
> 28. **Never replace the binary of a running copy of the app.** Observed for real: a fresh binary was hand-copied
>     into `build/Edict.app/Contents/MacOS/Edict` while a copy launched three minutes earlier was still running.
>     macOS validates `__TEXT` pages lazily, on first fault, so nothing happened immediately — then 30 s later the
>     menu-bar extra's code path was touched for the first time, that page no longer matched the signature the
>     process had launched with, and the kernel SIGKILLed it: `EXC_BAD_ACCESS (SIGKILL (Code Signature Invalid))`,
>     `Namespace CODESIGNING, Code 2, Invalid Page`, crashing inside `NSClassFromString` on
>     `com.apple.frontboardservices.workspace`. It reads exactly like an app bug and is not one.
>     **Always go through `./scripts/build-app.sh`** — never `swift build` plus a manual `cp`/`codesign` into a live
>     bundle. The script now calls `ensure_not_running` twice (once up front, once immediately before it replaces the
>     bundle, since the release build between them takes long enough for the app to get launched) and refuses to
>     proceed while a copy is running. Pass `EDICT_KILL=1` to have it quit the running copy for you.
>
> 29. **`defaults delete` does not reach a running app — `cfprefsd` serves a cached value.** This invalidated a
>     "decisive" experiment during diagnosis: deleting the saved window frame and relaunching produced a
>     byte-identical frame every time, which was read as proof that frame restoration was not involved. It was.
>     Adding `killall -HUP cfprefsd` after the delete made `defaults read` return `{}` and the window open at its
>     real default of 1180x760. **Any test that clears a preference must flush `cfprefsd` first**, or you will
>     measure the stale value and draw a confident wrong conclusion.
>
> 30. **An external Accessibility client resizes this app's windows after creation. Do not chase it as a SwiftUI
>     bug.** Edict's window is created at exactly the requested 1180x760, and then three AX writes arrive whose
>     backtrace is `_AXXMIGSetAttributeValue` -> `SetAttributeValue` ->
>     `NSAccessibilityEntryPointSetValueForAttribute` -> `-[NSWindow _setFrameCommon:display:fromServer:]`,
>     snapping it to a half-screen strip (900x1114 on the built-in display, a 3820-wide strip on the 4K). A 40-line
>     SwiftUI app reproduces it identically **once placed in a signed .app bundle**, and not as a bare executable.
>     It also beats a hard `.frame(width:height:)`, so no layout change can prevent it. This machine runs
>     BetterTouchTool with snap areas enabled (`BSTDisableSnapAreas = 0`, `BSTIncreaseSnappingArea = 1`) alongside
>     Karabiner, Raycast and Alfred; BTT is the leading suspect, but the attribution is circumstantial.
>     **Do not add code that fights the user's window manager** by re-asserting a size on a timer — that was tried
>     during diagnosis and is not shippable. Diagnose window-size complaints by attaching a `didResize`/`didMove`
>     observer and reading the backtrace before assuming the bug is ours.
>
> 31. **Bit-test modifier flags; never compare a raw flag word for equality.** Verified on the real
>     keyboard: Right Option arrives as `0x00080140`, not the expected `0x00080040`, because Karabiner's
>     virtual keyboard stamps `0x100` (`kCGEventFlagMaskNonCoalesced`) on **every** event it synthesizes,
>     release included. The good news from the same measurement: Karabiner *does* preserve the left/right
>     device bit, which was the project's biggest open unknown.
>
> 32. **An `AsyncStream` has exactly one consumer.** `HotkeyMonitor.events` hands back a stored stream;
>     cancelling its consumer and starting a second one leaves the replacement receiving nothing for ever.
>     That is what made RESTART appear to do nothing while the monitor logged healthy arms and releases and
>     no error appeared anywhere. Create such a consumer **once** and never cancel it on a restart — safe
>     because the continuations are finished only in `deinit`. Never hand a stored `AsyncStream` to a
>     second iterator.
>
> 33. **Claim the session slot before any `await`.** `beginSession` awaits an asset check, a format query
>     and `prepareToAnalyze`, so a gate on `activeSession == nil` lets two presses both build an analyzer,
>     the second orphaning the first and wedging the engine. The user saw a recording open and close itself
>     on alternating presses. The 1.5 s wait ceiling is a safety valve for a wedged analyzer, **not** the
>     fix; widening it treats a leak as a race.
>
> 34. **Use `Window`, not `WindowGroup`.** `WindowGroup` is a template: every `application(_:open:)`
>     instantiated another copy and SwiftUI restored them all on the next launch, reaching 18 windows.
>     Purge `~/Library/Saved Application State/<bundleid>.savedState` once when fixing this.
>
> 35. **No XML comments in `.entitlements`.** `codesign` parses entitlements with `AMFIUnserializeXML`,
>     which rejects comments, while `plutil -lint` passes the same file. Nothing gets signed at all. Grep
>     for `<!--` in the pre-sign check; lint is not sufficient.
>
> 36. **Text Input Services is main-thread-only.** `TISGetInputSourceProperty` reaches
>     `dispatch_assert_queue(main)` and `SIGTRAP`s rather than erroring, which crashed the app on every
>     injection pre-warm from `TextInjector`'s actor queue.
>
> 37. **Apple's models emit nothing rather than guessing, and no amount of audio work changes that.**
>     A real far-field multi-speaker meeting yielded 16 words per minute against ~150 for speech, with
>     levels fine, zero dropped buffers and full timeline coverage. Clean audio through the same code path
>     gives 819 words per 300 s; the meeting gives 61, and conditioning it moves that only to 75.
>     **Do not build a de-noising pipeline, and never offer the user a setting that claims to fix this.**
>     This class of recording needs a Whisper-class model, which this app deliberately does not ship.
>
> 38. **A word-count quality metric can be fooled by our own features.** Per-section transcription raised
>     a difficult slice from 91 to 245 words while mean confidence collapsed to 0.288 with 57% of words
>     under 0.30. Any quality verdict must gate on confidence as well as rate, and must measure rate
>     against **detected speech** rather than wall clock, or a mostly-silent voice memo gets slandered.
>
> 39. **Atomic writes protect against a torn file, not a wrong one.** A verification run wrote to the live
>     store and a user's transcript history went from thirty entries to two, with no backup anywhere —
>     not in the support directory, not a temp file, and Time Machine held only OS-update snapshots.
>     **Anything automated that exercises the real app must set `EDICT_SUPPORT_DIR` before it starts**, and
>     `AppPaths.writeAtomically` now keeps the outgoing version as `<name>.bak`.
>
> 40. **UI cannot be photographed from an automated run.** Screen Recording is denied to any process an
>     agent starts (`screencapture -l` fails, ScreenCaptureKit returns `-3811`), and `ImageRenderer` does
>     not rasterise a `ScrollView`'s contents. Proof sheets are offline renders, not live windows, and
>     views needing offline proof expose an `unbounded` hatch used only by fixtures. When a screenshot of
>     the running app is genuinely required, it has to come from the user's own session — and must capture
>     **only the app's window by id**, never a display.
>
> 41. **Refinement runs on-device and must never make a network request.** The README's privacy claim is
>     load-bearing. Build a **fresh `LanguageModelSession` per refinement** (a reused one accumulates a
>     transcript, so the previous dictation conditions the next), use `@Generable` rather than parsing
>     markdown, and use greedy sampling — temperature is what decides whether the model paraphrases, and
>     paraphrasing is invention in a transcription tool. `supportsLocale == false` means "no guarantees",
>     not "refuse": Indonesian measured excellent with the flag false, so caption the result rather than
>     disabling the feature. Keep instructions short; a fourth clause measurably diluted the others on
>     this ~3B model.
>
> 42. **Amendment 13 ("`.listenOnly`, never suppress") has exactly two sanctioned exceptions.**
>     *Amended by amendment 50, which added the second and rewrote the tap inventory below.* The first
>     is the popup: while the selection popup is on screen, `HotkeyMonitor` installs a **consuming**
>     tap on the same thread and run loop, alive only for that window, so that `1`/`2`/`3`/`Esc` choose
>     an action instead of typing over the very selection about to be replaced. Without it, pressing
>     `1` replaces the user's selected text with the character "1" — measured. The second is the refine
>     *trigger* (amendment 50). **At idle Edict holds exactly two taps: one `.listenOnly` on
>     `keyDown|keyUp|flagsChanged` for the hotkey, and one `.defaultTap` on `keyDown` alone for the
>     trigger.** Verify with `CGGetEventTapList` filtered on `getpid()` after any change here — there is
>     a test that does exactly that (`HotkeyChordLive.tapInventory`). Suppression anywhere else, and for
>     any other reason, is still forbidden.
>
> 43. **`CGEventSource.flagsState` cannot be trusted to say whether a chord is still held.** Measured
>     latched at `maskCommand` for over three seconds with no key down. The trustworthy signal is
>     `HotkeyMonitor`'s own event tap. (Amendment 27 already forbids `.privateState`, which blocks
>     forever; this is about `.combinedSessionState` being stale rather than hanging.)
>
> 44. **A replace is destructive where an insert is additive, so it must be stricter.** `SelectionBridge`
>     refuses when the frontmost app changed under it, and an AX write it cannot verify **stops** the
>     ladder at `clipboardOnly` rather than pasting over a write that may already have landed. Losing
>     the user's selected text is a worse failure than not refining it.
>
> ### Amended API surface
>
> These supersede the signatures below where they conflict:
>
> - `Settings.biasingLimit` — default **50**, clamp `0...50`; warn in the UI above 50.
> - `Settings.engine` — remove any `SpeechTranscriber` option. `Transcript.engine` is `"apple.dictationtranscriber"`.
> - `PermissionKind` — cases are `microphone`, `accessibility`, `inputMonitoring`, `postEvent`.
>   **Drop `speechRecognition`**: the probe never called `SFSpeechRecognizer.requestAuthorization` and transcription
>   worked, so it is not required.
> - `Transcript` — add `var droppedBuffers: Int` (surface "transcript may be incomplete" when non-zero) and
>   `var lowConfidenceWords: [String]`.
> - `SpeechEngine` — add `func warmUp() async` and `func reserveLocale(_:) async throws`.
>   `transcribe` must return per-word confidence so low-confidence words can be surfaced.
> - `TextInjector` — add a persisted, **learned** per-bundle-id policy map. Any app that produces
>   `confirmedNotInserted` or `cannotVerify` is demoted to paste-only permanently. Seed it with the known-bad list
>   in `RECON.md`. This turns the blog post's complaint into a self-healing system instead of a hardcoded blocklist.
>
> 45. **Sampling the language modifier at arm time is the wrong contract, and the failure is invisible.**
>     The modifier was read once, ~120 ms after key-down, and the locale could never change afterwards
>     because `SpeechAnalyzer` is built around one `Locale` (§3). A `⇧` landing a moment late was
>     therefore silently discarded — and the English model handed Indonesian speech does not fail, it
>     resolves unfamiliar phoneme runs into English proper nouns. Measured on the same 15.2 s Indonesian
>     fixture, same code path, locale the only variable:
>
>         id-ID   33 words,  0 of 33 low-confidence
>                 "Dan ada workshop karena sekarang timnya dia itu sangat kecil dan dia interested…"
>         en-US   23 words, 19 of 23 low-confidence, 90 wpm
>                 "Then other workshop Karna Saka Ito Sanga Dunia interested in workshop to my DR info…"
>
>     The user's own history holds the same shape verbatim ("Dhanya Sanga interested AI Kanaya Sushma
>     Manga Cheil Danka", 21 of 24 words low-confidence, 45 s of audio for 24 words). **Decide the
>     locale when the modifier window closes, not when the hold arms**: `.pressed` opens the microphone
>     at `armDelay` and the audio buffers; `.alternateSettled`, up to `HotkeyMonitor.alternateWindow`
>     (400 ms) later, is what an analyzer may be built from. A hold shorter than the window settles at
>     the release instead of waiting for it.
>
>     **This costs nothing measurable.** Buffered audio is consumed at **45–48x realtime**, so a 400 ms
>     head start is ~9 ms of chewing; measured end to end at realtime pace on 8.7 s of speech, key-up →
>     committed text was **0.049 s with the window against 0.057 s without it** (-9 ms and -5 ms over
>     two runs — the reordering is, if anything, marginally faster, because `engine.begin` no longer
>     delays the microphone). The window's real ceiling is legibility, not latency: the HUD's language
>     tag must settle while the user is still speaking, and the shortest real dictations in the user's
>     history are 0.9–1.3 s of audio.
>
>     **Two preconditions, both enforced in code.** The two prepared locales must accept the same audio
>     format, because `AudioCapture`'s converter is configured before the language is known
>     (`DictationController.localeDecisionDeferrable` falls back to the arm-time contract otherwise);
>     and the capture stream's `.bufferingNewest` capacity must be sized in seconds, because §20's
>     oldest-first eviction would now delete the head of *every* utterance rather than only a stalled
>     one. Measured: 243 661 frames captured, 243 661 delivered, 0 dropped.
>
> 46. **`AnalyzerInput.buffer` materialises a fresh `AVAudioPCMBuffer` on every access.** It is a
>     computed property, not a stored one, and `input.buffer !== theBufferYouPassedIn`. So
>     `input.buffer.int16ChannelData![0][0]` dereferences a pointer into an object destroyed at the end
>     of that expression — an immediate `EXC_BAD_ACCESS`, reproduced in a four-line probe. Bind the
>     buffer to a local first and read through that. The app is unaffected because `SpeechSession.feed`
>     only ever reads `frameLength`, which is a value; anything that reads *samples* back out of the
>     capture stream must know this.
>
> ### One new feature the recon earned us
>
> Per-word `transcriptionConfidence` is strongly discriminative — misheard "Visa" scored 0.05 and "claw" 0.31,
> against 0.998 for correctly-heard "deploy". **Surface sub-0.5 words in the history view as one-click
> "add correction to dictionary" suggestions.** That makes the dictionary self-populating, which is a genuinely
> better UX than the manual list Wispr Flow ships. Requires an explicit `Preset` with
> `attributeOptions: [.transcriptionConfidence, .audioTimeRange]` — the named presets carry `attributeOptions == []`
> and silently yield a single run with no confidence at all.
>
> 47. **The refine gesture is `⌘⌥/`, and a trigger must not insert text.** Measured with
>     `UCKeyTranslate` on this machine's ABC layout: `/`→`/`, `⌥/`→`÷`, `⌃⌥/`→`/`, `⇧⌥/`→`¿`. A trigger
>     that types **replaces the user's selection before it can be read**, which is the exact failure the
>     feature exists to prevent. A Command chord is a key equivalent and inserts nothing, so `⌘⌥/`
>     needs **no consuming tap**. Control and Shift are *forbidden* rather than ignored, so this user's
>     four-modifier Safari slash mapping cannot fire it. **Superseded in part by amendment 50:** `⌘⌥/`
>     is no longer the default (Alfred owns it on this machine) and it is no longer true that Edict
>     holds only one tap at idle. What survives intact is the rule this amendment exists for — a
>     trigger must not insert text *unless Edict swallows it*, and swallowing has to be paid for.
>
> 48. **`fn` is not a portable modifier.** Third-party keyboards — Logitech, Keychron, Das —
>     resolve `fn` in their own firmware and macOS never sees the key, so `maskSecondaryFn` is never set
>     and no application can observe it. It was measured on the built-in keyboard only and shipped as a
>     default, which was wrong. It survives as an explicitly Apple-keyboard-only option. A stored
>     `fnThenDictationKey` is **not** migrated: it was a deliberate choice, and rewriting a user's
>     setting under them is worse than showing the caveat.
>
> 49. **Decide the dictation locale when the modifier window closes, not when the hold arms.**
>     Sampling the language modifier at `armDelay` (~120 ms) is too tight for a two-key gesture, and the
>     locale cannot change afterwards because the analyzer is built before audio is analysed. Observed
>     in the user's real history: Indonesian speech ran through the en-US model and came back as
>     plausible proper nouns — "Kanaya Sushma Manga Cheil Danka" — because an English lexicon is most
>     permissive around names. The microphone now opens first, audio buffers in a stream sized in
>     seconds (RECON §20), and the analyzer is built only once `.alternateSettled` fires. A hold shorter
>     than the window settles from whatever is held at release.


> 50. **The refine trigger is `fn + /`, with `⌃⌘/` as a keyboard-independent alias, and it is the one
>     trigger Edict swallows.** This widens amendment 42 — read that first — and it is the only
>     widening of amendment 13 that has been allowed on a *trigger*.
>
>     **Why a consuming tap here, when it was refused for `⌥/`.** Measured with `UCKeyTranslate` on
>     this machine's ABC layout: `/`→`/`, `⌥/`→`÷`, `⌃/`→`/`, `⌃⌥/`→`/`, `⇧⌥/`→`¿`, `fn/`→`/`. Only a
>     `⌘`-bearing chord inserts nothing. So every short slash chord must either be swallowed or
>     abandoned, and the deciding question is what swallowing *costs the user*: eating `⌥/` would take
>     away their only way to type `÷`, and `⌥'` their only `æ`. `fn + /` costs nothing at all, because
>     it is a redundant way to type a character that is already on an unmodified key. That asymmetry
>     is the whole argument. It does not generalise to any other chord, and a future trigger that
>     inserts a character the user cannot type otherwise must be refused again.
>
>     **Why one setting has two chords.** `fn` is resolved in firmware on third-party keyboards and
>     macOS never sees it (amendment 48), and this user works on both a MacBook internal keyboard and
>     a Logitech. `fnSlash` therefore fires on two shapes, both keycode 44: `maskSecondaryFn` set with
>     every other modifier forbidden (**consumed**), or Control+Command with Option and Shift
>     forbidden (**passed through**, since it inserts nothing). `⌃⌘/` was checked against the machine,
>     not assumed: no keycode-44 hotkey in either Alfred's synced prefs or its local storage, and
>     neither Karabiner `slash` rule matches it. The picker states both in plain words; do **not**
>     split them into two settings.
>
>     **The shape of the tap.** A *second* port, never a mode on the hotkey tap: that one is
>     `.listenOnly` because it watches modifier holds, and a consuming tap on `.flagsChanged` would eat
>     the user's Option key. `eventsOfInterest` is `keyDown` **only** — the minimum surface that can
>     swallow a character, and small enough that a stripped keyboard mask is an *empty* mask, so
>     `tapCreate` returning nil is a complete permission gate (unlike the listen-only case in
>     RECON §11). The callback returns `nil` for one exact `(keyCode, flags)` shape and the unmodified
>     event for everything else; it allocates nothing and builds no `String`, because RECON §12's
>     budget is what keeps `.tapDisabledByTimeout` from making the tap deaf. `.tapDisabledBy*` is
>     handled and re-enabled on this tap too, and the 0.25 s watchdog polls it — a silently disabled
>     consuming tap does not go quiet, it goes *transparent*, and `fn + /` would start typing slashes
>     into the user's document with no popup and no error. Teardown is the measured order
>     (`CFRunLoopRemoveSource` → `tapEnable(false)` → `CFMachPortInvalidate`) on the thread that
>     created the port, or it leaks one Mach port per creation.
>
>     **How the two taps cannot double-fire.** Each shape is claimed by exactly one tap, by whether it
>     needs swallowing (`RefineChord.Discrete.consumesTrigger`): the consuming tap answers
>     `matchesConsuming`, the hotkey tap answers `matchesListenOnly`, and the sets are disjoint by
>     construction. Correctness therefore does not depend on which tap the window server serves first.
>
>     **Measured on this machine.** `CGGetEventTapList` filtered on `getpid()` reports exactly two taps
>     while the monitor runs — `consuming/mask=0x400/enabled=true` and
>     `listenOnly/mask=0x1c00/enabled=true` — and none after `stop()`; ten start/stop cycles moved the
>     task's Mach port count by **0**. Against a scratch app of our own (never the user's frontmost
>     window), a posted `fn + /` reached the document as **nothing** while a posted plain `/` inserted
>     `/`, and the gesture fired exactly once. **No agent has ever pressed the physical `fn` key**;
>     every `fn` observation in this project is a posted `maskSecondaryFn`, and the claim that a real
>     `fn + /` carries that bit on keycode 44 comes from the user's own measurement, not from ours.
>
>     **One known edge, deliberately not papered over.** With Globe as the *dictation* key the `fn`
>     shape is dropped rather than masked — `fn` is holding a recording open, so `fn + /` cannot also
>     mean this — and only `⌃⌘/` fires. The row still reads as live, because it is.

Fixed interfaces. Every implementation agent codes against these signatures exactly.
If you believe a signature is wrong, implement it as written and note the objection in your report —
do not silently change a shared type, because another agent is compiling against it right now.

## Ground rules

- Swift 6 language mode, strict concurrency. macOS 26 minimum. SwiftUI + AppKit only, zero third-party deps.
- Everything lives in the `EdictKit` library target. `Sources/Edict/main.swift` only calls `EdictApp.main()`.
- UI state types are `@MainActor @Observable final class`. Engine types that touch real-time audio or C callbacks
  are `actor` or explicitly-isolated classes — never `@MainActor` on an audio path.
- No `print`. Use the shared logger: `Log.engine`, `Log.audio`, `Log.hotkey`, `Log.inject`, `Log.stt`, `Log.data`
  (`os.Logger`, subsystem `com.edict.app`). Declared in `Sources/EdictKit/Support/Log.swift`.
- No one-off colors, fonts, spacings, radii, or durations in any view. Everything comes from `D.*` design tokens.
- Comment density: match a well-kept Swift codebase. Explain *why* for anything non-obvious (concurrency hops,
  AX quirks, timing constants). Do not narrate *what* for ordinary code.

## File ownership

Each file has exactly one owner. Never edit a file you do not own; if you need a change in someone else's file,
report it instead.

    Sources/EdictKit/Support/Log.swift              OWNER: data
    Sources/EdictKit/Data/Settings.swift            OWNER: data
    Sources/EdictKit/Data/DictionaryStore.swift     OWNER: data
    Sources/EdictKit/Data/Corrector.swift           OWNER: data
    Sources/EdictKit/Data/HistoryStore.swift        OWNER: data
    Sources/EdictKit/Data/AppPaths.swift            OWNER: data
    Tests/EdictKitTests/CorrectorTests.swift        OWNER: data
    Tests/EdictKitTests/DictionaryStoreTests.swift  OWNER: data
    Tests/EdictKitTests/HistoryStoreTests.swift     OWNER: data

    Sources/EdictKit/Engine/Permissions.swift       OWNER: hotkey
    Sources/EdictKit/Engine/HotkeyMonitor.swift     OWNER: hotkey
    Sources/EdictKit/Engine/TextInjector.swift      OWNER: hotkey

    Sources/EdictKit/Engine/AudioCapture.swift      OWNER: audio
    Sources/EdictKit/Engine/LevelMeter.swift        OWNER: audio

    Sources/EdictKit/Engine/Transcriber.swift       OWNER: stt
    Sources/EdictKit/Engine/SpeechEngine.swift      OWNER: stt

    Sources/EdictKit/Design/Tokens.swift            OWNER: (already written by orchestrator)
    Sources/EdictKit/Design/Components.swift        OWNER: design
    Sources/EdictKit/Design/VUMeter.swift           OWNER: design
    Sources/EdictKit/Design/Waveform.swift          OWNER: design

    Sources/EdictKit/App/EdictApp.swift            OWNER: shell
    Sources/EdictKit/App/AppModel.swift             OWNER: shell
    Sources/EdictKit/App/DictationController.swift  OWNER: shell
    Sources/EdictKit/App/MenuBarExtra.swift         OWNER: shell
    Sources/EdictKit/App/HUDWindow.swift            OWNER: shell

    Sources/EdictKit/Views/MainWindow.swift         OWNER: views
    Sources/EdictKit/Views/HistoryPane.swift        OWNER: views
    Sources/EdictKit/Views/DictionaryPane.swift     OWNER: views
    Sources/EdictKit/Views/SettingsWindow.swift     OWNER: views
    Sources/EdictKit/Views/PermissionsPane.swift    OWNER: views

## Shared value types  (declared in Data/, used everywhere)

```swift
// Data/DictionaryStore.swift
public struct DictionaryEntry: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: Codable, Hashable, Sendable {
        /// A word or phrase the engine should know about. Biasing only (plus optional canonical-case fixups).
        case term(String)
        /// "When you hear `heard`, write `write`." The guaranteed path.
        case correction(heard: String, write: String)
    }
    public var id: UUID
    public var kind: Kind
    public var enabled: Bool
    public var note: String?
    public var createdAt: Date
    /// Bumped by the corrector each time this entry changes text. Persisted.
    public var hitCount: Int
    public var lastHitAt: Date?

    /// The text shown in the left column of the dictionary table.
    public var displayTerm: String { get }
    /// The text shown in the right column; nil for `.term`.
    public var displayReplacement: String? { get }
}

/// One correction that actually fired, recorded so history can show what the dictionary did.
public struct CorrectionHit: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var entryID: UUID
    public var from: String        // the literal text that was matched, as the engine produced it
    public var to: String          // what it became
    public var offset: Int         // UTF-16 offset in the *raw* transcript, for highlighting
}

/// The outcome of the post-transcription correction pass.
public struct CorrectionResult: Sendable, Hashable {
    public var text: String
    public var hits: [CorrectionHit]
}

/// Flagged at add/edit time so the UI can warn before a rule corrupts ordinary prose.
public struct EntryRisk: Sendable, Hashable {
    public enum Level: Int, Sendable, Comparable { case none, notice, warning }
    public var level: Level
    public var message: String?    // e.g. "\"cloud\" is a common English word; this will fire on ordinary prose."
}

// Data/HistoryStore.swift
public struct Transcript: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    /// Exactly what the speech engine produced, before the dictionary touched it.
    public var rawText: String
    /// What was actually injected.
    public var text: String
    public var corrections: [CorrectionHit]
    public var audioDuration: TimeInterval
    /// Wall clock from end-of-speech to final result. The number the blog post benchmarks.
    public var transcribeDuration: TimeInterval
    public var localeIdentifier: String
    public var engine: String                  // "apple.speechtranscriber"
    public var targetBundleID: String?         // app that had focus
    public var targetAppName: String?
    public var injection: InjectionOutcome

    public var wordCount: Int { get }
}

public enum InjectionOutcome: String, Codable, Hashable, Sendable, CaseIterable {
    case accessibility      // AX kAXSelectedTextAttribute insert, verified
    case paste              // pasteboard + synthetic Cmd-V
    case keystrokes         // CGEvent unicode fallback
    case clipboardOnly      // everything failed; text left on the clipboard for the user
    case notAttempted       // recorded from the app window, no injection wanted
    case failed
}
```

## Data layer  (OWNER: data)

```swift
// Data/AppPaths.swift
public enum AppPaths {
    /// ~/Library/Application Support/Edict — created on first access.
    public static var supportDirectory: URL { get }
    public static var dictionaryFile: URL { get }   // dictionary.json
    public static var historyFile: URL { get }      // history.json
    public static func ensureSupportDirectory() throws
}

// Data/Settings.swift
public enum HotkeyChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    case rightOption, rightCommand, rightControl, fn, f13
    public var id: String { rawValue }
    public var displayName: String { get }     // "Right Option (⌥)"
    public var glyph: String { get }
}

@MainActor @Observable
public final class Settings {
    public static let shared: Settings

    public var hotkey: HotkeyChoice
    public var localeIdentifier: String            // "en-US"
    /// Hold-to-talk (release ends the utterance) vs press-once-to-start / press-again-to-stop.
    public var pushToTalk: Bool
    public var autoInject: Bool
    public var showHUD: Bool
    public var playSounds: Bool
    /// Feed dictionary terms to the engine as contextual strings.
    public var biasingEnabled: Bool
    /// Keep the list short — long contexts make these models drift. Default 100, clamp 0...400.
    public var biasingLimit: Int
    /// Run the guaranteed find-and-replace pass after transcription.
    public var correctionsEnabled: Bool
    /// A `.term` entry also normalises casing of that word in output.
    public var termCaseNormalisation: Bool
    /// Pre-warm the audio engine so no speech is lost at key-down. Costs a lit mic indicator.
    public var prewarmMicrophone: Bool
    public var historyLimit: Int                   // default 5000
    public var launchAtLogin: Bool

    public func resetToDefaults()
}
```

`Settings` persists to `UserDefaults.standard` under the `edict.` key prefix, writing on `didSet`.

```swift
// Data/DictionaryStore.swift
@MainActor @Observable
public final class DictionaryStore {
    public static let shared: DictionaryStore

    public private(set) var entries: [DictionaryEntry]
    public private(set) var lastLoadError: String?

    public func load() throws
    public func save() throws
    /// Watch dictionary.json and reload on external edits (the file is a documented plain-file interface).
    /// Must debounce (~250 ms) and must not fight our own writes.
    public func startWatchingFile()
    public func stopWatchingFile()

    @discardableResult public func add(_ entry: DictionaryEntry) -> DictionaryEntry
    public func update(_ entry: DictionaryEntry)
    public func remove(ids: Set<UUID>)
    public func search(_ query: String) -> [DictionaryEntry]

    /// Contextual strings for the speech engine, highest-value first, deduped, capped at `limit`.
    /// Includes `.term` values and the *write* side of `.correction` entries — we bias toward what we
    /// want produced, never toward the misheard form.
    public func biasingStrings(limit: Int) -> [String]

    /// Compiled rules for the post-pass, longest-first. Recompiled only when `entries` changes.
    public func compiledRules(includeTermCaseNormalisation: Bool) -> [CorrectionRule]

    /// Called by the controller after a correction pass so the table can show usage.
    public func recordHits(_ hits: [CorrectionHit])

    /// Warn the user at add/edit time if a rule looks like it will fire on ordinary prose.
    public static func assessRisk(for kind: DictionaryEntry.Kind) -> EntryRisk
}
```

```swift
// Data/Corrector.swift
/// A prepared, order-sensitive replacement rule. Immutable and Sendable so the pass can run off the main actor.
public struct CorrectionRule: Sendable, Hashable, Identifiable {
    public var id: UUID          // == the originating DictionaryEntry.id
    public var pattern: String   // the regex actually used, exposed for the UI's "explain this rule"
    public var replacement: String
    public var sortWeight: Int   // longer/more-specific first
    public init(entryID: UUID, heard: String, write: String)
}

public struct Corrector: Sendable {
    public init(rules: [CorrectionRule])
    /// Single left-to-right pass. Non-overlapping, longest-match-first, case-insensitive,
    /// never re-scans inside its own output.
    public func apply(to text: String) -> CorrectionResult
}
```

### Corrector semantics — get these exactly right, they are the point of the feature

1. **Whole-word only.** `\b`-anchored. A rule for `cloud` must never touch `Cloudflare`, `clouds`, or `iCloud`.
2. **Case-insensitive matching, literal replacement.** The `write` side is inserted verbatim as the user typed it.
3. **Longest match first.** `cloud code assistant` wins over `cloud code`. Sort by matched-phrase length
   (characters, then token count) descending; ties broken deterministically by entry creation order.
4. **Glued and hyphenated forms.** A multi-token `heard` must match with optional whitespace, hyphen, underscore, or
   nothing between its tokens: `cloud code` matches `cloud code`, `cloud  code`, `cloud-code`, `cloud_code`,
   `CloudCode`, `Cloud Code`. Build the pattern by joining escaped tokens with `[\s\-_]*`.
   Because the separator can be empty, `\b` alone is not sufficient at the internal joins — verify with tests that
   `CloudCodeBase` does **not** match a `cloud code` rule (the trailing `\b` must fail against `Base`).
5. **Single-token rules are the dangerous ones.** Still `\b`-anchored, and `assessRisk` must flag them when the
   `heard` side is a common English word or shorter than 3 characters.
6. **One pass, no cascading.** Replacements are not re-examined; a rule cannot fire on another rule's output.
   Implement by scanning for the earliest match across all rules at each position, emitting into an output buffer.
7. **Hits are reported** with the pre-correction UTF-16 offset so the UI can show `"cloud code" → "Claude Code"`.
8. **Term case normalisation** (when enabled): a `.term("Vercel")` yields an implicit rule
   `heard: "Vercel", write: "Vercel"` that only changes casing. It must be a no-op when the casing already matches,
   and must not produce a `CorrectionHit` in that case.

Tests must cover, at minimum: `Cloudflare` untouched by a `cloud`→`Claude` rule; all six glued/hyphenated forms of
`cloud code`; `CloudCodeBase` untouched; longest-match precedence; multiple hits in one sentence; empty rule set;
empty input; unicode/emoji-adjacent text; and that offsets in `hits` index the raw string correctly.

```swift
// Data/HistoryStore.swift
@MainActor @Observable
public final class HistoryStore {
    public static let shared: HistoryStore

    public private(set) var transcripts: [Transcript]   // newest first

    public func load() throws
    public func append(_ transcript: Transcript)
    public func remove(ids: Set<UUID>)
    public func removeAll()
    /// Case- and diacritic-insensitive substring match over `text` and `rawText`. Empty query returns everything.
    public func search(_ query: String) -> [Transcript]
    public var totalWords: Int { get }
}
```

Persistence is atomic (write to a temp file in the same directory, then `replaceItemAt`) and debounced (~500 ms)
so a burst of dictations does not thrash the disk. Trim to `Settings.historyLimit` on append.

## Engine layer

```swift
// Engine/Permissions.swift
public enum PermissionKind: String, CaseIterable, Sendable, Identifiable {
    case microphone, accessibility, inputMonitoring, speechRecognition
    public var id: String { rawValue }
    public var title: String { get }
    public var why: String { get }              // one plain sentence for the UI
    public var settingsURL: URL? { get }        // deep link into the right System Settings pane
}

public enum PermissionState: Sendable, Hashable { case granted, denied, notDetermined, unknown }

@MainActor @Observable
public final class Permissions {
    public static let shared: Permissions
    public private(set) var states: [PermissionKind: PermissionState]
    public var allCriticalGranted: Bool { get }          // microphone + accessibility + inputMonitoring
    public func refresh()                                // never prompts
    public func request(_ kind: PermissionKind) async     // may prompt
    public func openSettings(for kind: PermissionKind)
    /// Poll while a settings pane is open so the UI updates when the user flips the switch.
    public func beginPolling(); public func endPolling()
}

// Engine/HotkeyMonitor.swift
public enum HotkeyEvent: Sendable, Hashable { case pressed, released }

/// Watches for the push-to-talk key globally. Runs its event tap on a dedicated thread with its own
/// run loop so UI work can never delay event delivery, and hops to the main actor to publish.
public final class HotkeyMonitor: Sendable {
    public init()
    /// Emits `.pressed`/`.released` for the configured key. Replacing the key while running is supported.
    public var events: AsyncStream<HotkeyEvent> { get }
    public func start(key: HotkeyChoice) throws
    public func update(key: HotkeyChoice)
    public func stop()
    public var isRunning: Bool { get }
    /// Re-arms the tap after `.tapDisabledByTimeout` / `.tapDisabledByUserInput`.
    /// Non-negotiable: without this the hotkey silently dies after a heavy-load hiccup.
}

public enum HotkeyError: Error, Sendable { case tapCreationFailed, permissionDenied }

// Engine/TextInjector.swift
public struct InjectionTarget: Sendable, Hashable {
    public var bundleID: String?
    public var appName: String?
}

/// Puts text where the user's cursor is. Tries a ladder of strategies and REPORTS WHICH ONE WORKED —
/// silent success is the documented failure mode of the Accessibility path (Electron apps return
/// `.success` and do nothing), so every strategy must be verified, not trusted.
public actor TextInjector {
    public init()
    public static func currentTarget() -> InjectionTarget      // NSWorkspace.frontmostApplication
    /// Ladder: verified AX insert -> pasteboard + synthetic Cmd-V -> unicode keystrokes -> clipboard only.
    public func inject(_ text: String, into target: InjectionTarget) async -> InjectionOutcome
    /// Per-bundle-id overrides for apps known to lie about AX success. Seeded with the Electron/Chromium family.
    public func preferredStrategy(for bundleID: String?) -> InjectionOutcome?
}

// Engine/AudioCapture.swift
public struct AudioFrame: Sendable {
    public var rms: Float          // 0...1, already smoothed for display
    public var peak: Float         // 0...1
    public var dbfs: Float
}

/// Microphone capture. Owns the AVAudioEngine and converts every buffer to the format the analyzer wants.
public actor AudioCapture {
    public init()
    /// Prepared once, reused. `prewarm` starts the engine without opening a session stream.
    public func prewarm(targetFormat: AVAudioFormat?) async throws
    /// Begins an utterance. The returned stream ends when `stop()` is called.
    public func start(targetFormat: AVAudioFormat?) async throws -> AsyncStream<AnalyzerInput>
    public func stop() async
    public func teardown() async
    /// Coalesced to ~60 Hz for the meter; never per-buffer.
    public var levels: AsyncStream<AudioFrame> { get }
    public var isCapturing: Bool { get }
}

public enum AudioError: Error, Sendable {
    case microphoneDenied, engineStartFailed(String), noInputDevice, converterUnavailable
}

// Engine/SpeechEngine.swift
public struct TranscriptionUpdate: Sendable, Hashable {
    /// Accumulated finalized text.
    public var finalText: String
    /// The unstable tail the engine may still revise. Display only — never inject this.
    public var volatileText: String
    public var isFinal: Bool
    public var confidence: Double?
}

public struct TranscriptionOutcome: Sendable {
    public var text: String
    public var confidence: Double?
    /// End-of-audio to final result. Reported in history and used for the benchmark numbers.
    public var latency: TimeInterval
    public var audioDuration: TimeInterval
}

public enum ModelState: Sendable, Hashable {
    case unavailable(String), needsDownload, downloading(Double), ready
}

/// Wraps SpeechAnalyzer + SpeechTranscriber. One instance per app run; a session per utterance.
public actor SpeechEngine {
    public init()
    public var modelState: ModelState { get }
    public func prepare(localeIdentifier: String) async throws
    public func installModelIfNeeded(progress: @Sendable (Double) -> Void) async throws
    /// The audio format the analyzer wants; hand this to `AudioCapture`.
    public func bestAudioFormat() async -> AVAudioFormat?
    /// Contextual strings pushed into `AnalysisContext.contextualStrings[.general]`.
    public func setBiasing(_ strings: [String]) async
    /// Runs one utterance. Consumes `input` until it finishes, then finalizes and returns the last result.
    public func transcribe(
        input: AsyncStream<AnalyzerInput>,
        onUpdate: @Sendable @escaping (TranscriptionUpdate) -> Void
    ) async throws -> TranscriptionOutcome
    public func cancel() async
    public var supportedLocales: [Locale] { get async }
}
```

## App layer  (OWNER: shell)

```swift
// App/AppModel.swift
public enum DictationPhase: Sendable, Hashable {
    case idle, arming, listening, transcribing
    case injecting
    case error(String)
}

@MainActor @Observable
public final class AppModel {
    public static let shared: AppModel

    public private(set) var phase: DictationPhase
    public private(set) var level: AudioFrame            // drives the VU needle
    public private(set) var elapsed: TimeInterval        // drives the segment counter
    public private(set) var liveText: String             // final + volatile, for the HUD
    public private(set) var modelState: ModelState
    public private(set) var lastOutcome: InjectionOutcome?
    public var statusLine: String { get }                // the menu-bar / window status string

    public let settings: Settings
    public let dictionary: DictionaryStore
    public let history: HistoryStore
    public let permissions: Permissions

    public func bootstrap() async        // called once from EdictApp
    public func toggleRecording()        // the Record/Stop button
    public func startRecording()
    public func stopRecording()
    public func cancelRecording()
}
```

`DictationController` (also owned by shell) is the seam between `AppModel` and the engine actors. It owns the
sequence: hotkey down → (prewarmed) capture start → stream into `SpeechEngine` → hotkey up → finalize →
`Corrector.apply` → `TextInjector.inject` → `HistoryStore.append` → `DictionaryStore.recordHits`.
It must be cancellable at every step and must never leave the audio engine running after an error.

## Views  (OWNER: views)

- **Main window** — resizable, min 900×600, restores size. A left rail selects HISTORY / DICTIONARY, laid out as
  a labelled equipment panel, not a sidebar. Top deck holds the VU meter, the record lamp, the elapsed counter,
  and the RECORD / STOP `TapeButton`. `Cmd+,` opens Settings. Not `LSUIElement`; real Dock icon and app menu.
- **History pane** — searchable table, newest first. Each row: time, duration, word count, the text, a copy button.
  Rows where the dictionary fired show a marker; selecting a row reveals the raw-vs-corrected diff and lists each
  `CorrectionHit` as `"cloud code" → "Claude Code"`. This is how the user can tell the dictionary is doing anything.
- **Dictionary pane** — searchable, editable table over `DictionaryStore`. Add/edit/delete. The add sheet picks entry
  kind (term vs correction pair), shows `EntryRisk` inline as a warning before saving, and reveals the file path so
  the user knows it is a plain editable file.
- **Settings window** — hotkey picker (live-updating), locale/model picker with the download state and progress,
  behaviour toggles from `Settings`, and the permissions pane.
- **Permissions pane** — one row per `PermissionKind` with state, the plain-language reason, and a button that deep
  links to the exact System Settings pane. Reachable from the main window when something critical is missing.

Every view is built from `Design/Components.swift` and `D.*` tokens. If you need a component that does not exist,
report it — do not inline a bespoke one.
