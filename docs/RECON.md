# Edict — recon findings

Everything below was established empirically on this machine by probe agents that compiled and ran real code
(macOS 27.0, Apple M5 Pro, Xcode 26.5, Swift 6.3.2). Verified working snippets are in the scratchpad at
`recon/snippets/` — prefer copying those over re-deriving anything here.

Treat this file as the authority when it disagrees with your instincts about these APIs. They are new and
under-documented, and most of the findings below are counter-intuitive.


---

## Speech engine — DictationTranscriber / SpeechAnalyzer

**Verified:** True

### Summary

Built and RAN a SwiftPM probe at <scratch> (17 files, clean `swift build`, Swift 6 mode, platform .macOS("26.0")). SpeechTranscriber.isAvailable=true; 45 supported locales, 9 installed (all English incl. en-US); en-US/en_US both resolve via supportedLocale(equivalentTo:); assets were already installed so downloadAndInstall() was never needed (request returned nil in 0.07s). THE HEADLINE FINDING IS NEGATIVE-THEN-POSITIVE: AnalysisContext.contextualStrings[.general] has ZERO measurable effect on SpeechTranscriber (byte-identical output across 4 audio files x {no ctx, 9 strings, 200 strings, setContext mid-stream}), but it WORKS on DictationTranscriber — "Visa and soup base and anthropic" became "Vercel and Supabase and Anthropic", "Claude code" became "Claude Code", deterministically and repeatably. Edict must therefore use DictationTranscriber, not SpeechTranscriber. setContext() mid-stream is a silent no-op in both modules: context must be passed to SpeechAnalyzer.init(analysisContext:). The SFSpeechLanguageModel / ContentHint.customizedLanguage custom-LM path builds and loads without error but also had ZERO effect at weights nil/0.3/1.0 — do not use it. Volatile results REPLACE a tail whose range.start equals the previous final's range end, so committed = concat(finals in arrival order) and display = committed + volatileTail; naive appending produced 7310 chars vs 412 correct (17.7x bloat). One SpeechAnalyzer CANNOT be reused per utterance: finalize(through:) deadlocks forever while the AsyncStream is open, and start() on a finished analyzer silently no-ops with a dead results sequence — rebuild per utterance, which costs only ~2.5ms once the process is warm (~50ms cold). transcriptionConfidence requires an explicit custom Preset (named presets have attributeOptions=[]) and is strongly discriminative: misheard "Visa" scored 0.05, "Versa" 0.37, vs "deploy" 0.998.

### Traps

**contextualStrings[.general] is a COMPLETE NO-OP on SpeechTranscriber. Verified across 4 audio files x 4 configurations (no context / 9 strings at init / setContext mid-stream / 200 strings at init) — every transcript was byte-identical. The context IS retained (reading back `await analyzer.context.contextualStrings[.general]` returns the 9 strings), it just does not influence decoding.**

> Use DictationTranscriber instead of SpeechTranscriber. There, contextualStrings demonstrably works: long.aiff went from "...proper nouns like Visa and soup base and anthropic." to "...proper nouns like Vercel and Supabase and Anthropic" and "Claude code" -> "Claude Code", repeatably and deterministically. DictationTranscriber is also the semantically correct module for a dictation app and adds TranscriptionOption.punctuation.

**SpeechAnalyzer.setContext(_:) mid-stream silently does nothing. It does not throw, but the transcript is byte-identical to the no-context run in every single test (all 4 files, both modules). You cannot change the dictionary during an utterance.**

> Pass AnalysisContext to SpeechAnalyzer.init(inputSequence:modules:options:analysisContext:) before prepareToAnalyze. Since Edict rebuilds the analyzer per utterance anyway, read the user dictionary at key-down and hand it to init. Dictionary edits take effect on the NEXT utterance.

**The documented custom-language-model path (SFCustomLanguageModelData -> export(to:) -> SFSpeechLanguageModel.prepareCustomLanguageModel -> DictationTranscriber.ContentHint.customizedLanguage) builds successfully (lm + vocab files created, no error thrown, 0.6s prepare) but has ZERO effect on output. Tested at weight nil, 0.3, and 1.0 with phrase counts and template generators; all three produced transcripts byte-identical to the no-hint baseline.**

> Do not build this. It is ~200 lines of machinery and a 0.6s per-dictionary-change compile step for no benefit on this OS build. Use contextualStrings on DictationTranscriber instead — it is one line and it works.

**Naive appending of result.text is the classic catastrophic bug. Volatile results are cumulative-from-the-last-final, so concatenating every event on a 24s utterance produced 7310 characters instead of the correct 412 (17.7x bloat).**

> Volatile results REPLACE the tail; final results append. Empirically: a volatile result's range.start always equals the previous final's range.end (and 0 before the first final). So committed = concat(finals in arrival order), display = committed + volatileTail, and volatileTail is cleared on every final. Final segment text already carries its own leading space (" It runs entirely...") — do NOT insert separators yourself.

**Final result ranges are disjoint and monotonic but NOT always contiguous. On the 24s clip the ranges were [0..3.300], [3.300..7.800], [7.800..14.520], [14.640..24.120] — note the 120ms gap before the last one. Code that asserts range.start == previousEnd will fail.**

> Do not require contiguity. Append finals in arrival order and only dedupe on exact CMTimeRangeEqual. Also note the volatile range.end runs ahead of the final's end (24.188 vs 24.120), so never use volatile ranges for bookkeeping.

**One SpeechAnalyzer CANNOT be reused across push-to-talk utterances. `finalize(through: exactEndTime)` DEADLOCKS FOREVER while the AsyncStream continuation is still open (verified: blocked past a 6s watchdog, process had to be SIGKILLed). And after finalizeAndFinishThroughEndOfInput(), calling start(inputSequence:) again does NOT throw — it silently no-ops because transcriber.results is a one-shot sequence that has already terminated, so the second utterance is lost with no error.**

> Build a fresh module + fresh SpeechAnalyzer per utterance. It is cheap: after the first one in the process, module init + analyzer init + prepareToAnalyze totals ~2.5ms (vs ~26-50ms for the very first). Call a throwaway warmUp() at app launch to pay the cold cost before the user's first hotkey press.

**SpeechAnalyzer(inputAudioFile:modules:) ALREADY STARTS analysis. Calling analyzeSequence(from:) afterwards is an unrecoverable EXC_BREAKPOINT trap (not a throw): "Failed precondition: SpeechAnalyzer: Cannot simultaneously analyze multiple input sequences". Process exits 133.**

> Pick one: either init(inputAudioFile:...finishAfterFile:) and just consume results, OR the plain init(modules:options:) followed by analyzeSequence(from: file). Never both. (The plain-init + analyzeSequence path transcribed a 3.375s file in 0.267s wall = ~12.6x realtime.)

**AssetInventory.reserve(locale:) is effectively REQUIRED, and omitting it is silent today but fatal later. Without it the framework logs "Cannot use modules with unallocated locales [en_US (fixed en_US)]. Currently allocated locales are []. This will be an error in a future release!" — transcription still works now, but will break on a future OS.**

> Call AssetInventory.reserve(locale: canonicalLocale) once at launch, before constructing any module. Note reserve() returns false when the locale was ALREADY reserved (false is not an error) and throws SFSpeechErrorDomain Code=11 "Too many allocated locales, 5 maximum" when the 5 slots are full.

**AssetInventory.release(reservedLocale:) matches on the raw Locale.identifier STRING, not on locale equivalence. release(Locale(identifier: "en-US")) returns false and does nothing, because the stored reservation's identifier is "en_US" (underscore). Since reservations PERSIST ACROSS PROCESS LAUNCHES (keyed by client id / bundle identifier), an app that reserves with hyphens and releases with hyphens permanently leaks all 5 slots and then can never reserve again.**

> Only ever pass Locale objects obtained from `await AssetInventory.reservedLocales` to release(). Doing that returned true and correctly emptied the list. Edict should also implement the eviction fallback shown in prepareLocale(): on a Code=11 throw, release everything from reservedLocales then retry.

**AssetInventory.status(forModules:) returns .supported — not .installed — for a locale whose assets ARE on disk but which this app has not reserved. Proven directly: with en-AU/en-CA/en-GB/en-US/ja-JP reserved, all 9 installed English locales reported .installed if reserved and .supported if not. Gating a download on `status != .installed` will therefore trigger pointless install flows.**

> Reserve FIRST, then check status. Or check membership in `await SpeechTranscriber.installedLocales` (which correctly listed all 9 regardless of reservation). Also note assetInstallationRequest(supporting:) implicitly reserves the locale as a side effect — that is what silently consumed a ja-JP slot during probing.

**supportedLocale(equivalentTo:) resolves a bare language tag arbitrarily and reservation-dependently. Locale(identifier: "en") resolved to en-AU on a clean system, then to en-US after en-US was reserved. Worse, this machine's Locale.current is en_ID, which resolves to en-IN (Indian English) — silently wrong acoustic model for a US-English speaker.**

> Never derive the dictation locale from Locale.current or from a bare language code. Default to an explicit "en-US" and expose a locale picker in Edict's settings, validating the choice through supportedLocale(equivalentTo:) and checking it is non-nil. NOTE, corrected after this probe: id-ID returns nil for SpeechTranscriber but resolves to id_ID for DictationTranscriber, which is the module actually shipped. The two modules have different locale sets.

**The analyzer accepts ONLY 1ch/16000Hz/Int16/interleaved or 1ch/8000Hz/Int16/interleaved (availableCompatibleAudioFormats returned exactly those two). An AVAudioEngine input tap is typically 44.1 or 48kHz Float32 non-interleaved, so feeding tap buffers straight into AnalyzerInput will fail. (The file-based path does convert internally — it swallowed a 22050Hz AIFF — but the streaming path Edict uses does not.)**

> Query SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) and run every mic buffer through an AVAudioConverter into that format before wrapping in AnalyzerInput. See the conversion snippet. Feed ~100ms chunks; the engine emits results in bursts roughly every 0.9s of audio regardless of your chunk size.

**Passing a non-empty contextualStrings list carries a real per-utterance setup cost, and long lists both slow things down and DILUTE the biasing. Measured begin() cost: 0 strings 6.4ms, 5 strings 71ms, 25 strings 99ms, 50 strings 141ms, 100 strings 228ms, 200 strings 577ms, 500 strings 1.61s. And quality degrades: on nouns.aiff a 9-string dictionary fixed both "Wispr Flow" and "Obsidian", but a 200-string dictionary fixed neither.**

> Cap Edict's dictionary at roughly 50 terms and build the Session at key-DOWN so the ~100ms is hidden behind the user's speech onset. If the user needs a larger dictionary, do NOT push it all into contextualStrings — send the top-N most relevant terms and handle the rest with a post-hoc string-replacement pass.

**Volatile text is materially worse than final text and must never be injected. Observed volatile "speecheech transcriber API" -> final "speech transcriber API"; volatile "Val and s the bas and Anthropic" -> final "Versal and Soup the Basin Anthropic"; volatile mid-word fragments like "cl", "whis", "Access" appear constantly.**

> Inject only Sink.committed (finals). Show volatile in the UI as a visually distinct live tail. Note the converse also happens — one segment's volatile said "Claude code" while its final said "claw code" — so never try to 'repair' finals from volatiles.

**cancelAndFinishNow() silently DISCARDS the pending final result. Measured on the same audio: finalizeAndFinishThroughEndOfInput gave 16 events / 1 final / full transcript in 0.129s, while cancelAndFinishNow gave 0 events / 0 finals / empty string in 0.000s.**

> Use finalizeAndFinishThroughEndOfInput() for normal key-release, and cancelAndFinishNow() ONLY for an explicit user abort (Esc). The teardown order that works is exactly: stop feeding -> continuation.finish() -> await finalizeAndFinishThroughEndOfInput() -> await the results-consumer task.

**Named presets carry attributeOptions == [] , so result.text is a single run with no confidence and no time range. Code that iterates runs looking for ConfidenceAttribute will silently find nothing and appear to 'work'.**

> Construct an explicit Preset (or use the full DictationTranscriber initializer) with attributeOptions: [.transcriptionConfidence, .audioTimeRange]. Only then does the AttributedString split into per-word runs carrying a Double confidence.

**Swift 6 strict concurrency rejects the obvious results-consumer shape. `let t = Task { for try await r in transcriber.results { localVar += ... } }` fails with "sending value of non-Sendable type '() async throws -> ()' risks causing data races" because the closure captures mutable local state.**

> Hoist `let results = module.results` (it is Sendable) outside the Task, and accumulate into a lock-protected `final class ... : @unchecked Sendable` (the Sink in the snippet). SpeechTranscriber/DictationTranscriber themselves ARE Sendable (SpeechModule: AnyObject & Sendable), so capturing the module is fine; only raw local vars are the problem. Same issue bites inside AVAudioConverter.convert's @Sendable input block — box the eof flag in a class.

**A SwiftPM executable has no bundle identifier, and Speech logs "Application does not have a bundle identifier; using unstable 'probe-speech' as client identifier". Because locale reservations are keyed to that client id, reservation state is tied to app identity.**

> Harmless for the real Edict.app (it will have a CFBundleIdentifier), but it means probe-measured reservation state does not carry over, and changing Edict's bundle id would orphan its reservations. Keep the bundle id stable.

### Recommendations

- Use DictationTranscriber, NOT SpeechTranscriber, as Edict's engine. It is the only one where contextualStrings biasing works, it exposes TranscriptionOption.punctuation, and it was independently better on proper nouns in the baseline (it produced "Claude code" where SpeechTranscriber produced "claw code"/"code code"). Presets to use: .progressiveLongDictation, or the full initializer with reportingOptions: [.volatileResults] and attributeOptions: [.transcriptionConfidence].
- Adopt a TWO-LAYER dictionary. Layer 1: pass the user's terms as contextualStrings[.general] at analyzer init — this genuinely fixed Vercel, Supabase, Anthropic, Obsidian, and the capitalization of Claude Code. Layer 2: keep a post-hoc string-replacement pass, because biasing is not reliable for every term ("Wispr Flow" was fixed with a 9-term list but not with a 200-term list, and "whisper flow" survived biasing in several runs). Layer 1 alone is not sufficient; layer 2 alone loses the acoustic-level wins.
- Build a fresh module + analyzer per utterance and never attempt reuse. Call a throwaway warmUp() at app launch (0.11-0.15s) to pay the cold model-load cost; every subsequent utterance then costs ~2.5ms of setup with no dictionary, or ~60-140ms with a 5-50 term dictionary. Create the Session on hotkey key-DOWN so even the dictionary cost is hidden behind the user's speech onset.
- Cap the user dictionary at ~50 terms for the contextualStrings layer. Cost is ~65ms fixed plus ~1.5ms per term, and hit rate measurably degrades with list length. If the user's dictionary is larger, rank and send the top ~50 (e.g. by recency/frequency) and let the post-hoc replacement pass handle the tail.
- Drive the UI from Sink.display (committed + volatile tail) but inject only Sink.committed. Render the volatile tail in a dimmed/italic style so the user understands it is provisional — it is frequently wrong mid-word and occasionally disagrees with the final.
- Use transcriptionConfidence to power the dictionary UX. Confidence is strongly discriminative (misheard "Visa"=0.05, "Versa"=0.37, "claw"=0.31, "Superbase"=0.55 versus correct "deploy"=0.998, "I"=0.996). Surface sub-0.5 words in Edict's history view as one-click "add correction to dictionary" suggestions — this makes the dictionary self-populating, which is a genuinely better UX than Wispr Flow's manual list.
- Do NOT build the SFCustomLanguageModelData / SFSpeechLanguageModel custom-LM path. It compiles, exports, and prepares without error but had zero effect on output at every weight tested. It is pure cost.
- Set up locale handling defensively at launch: resolve via supportedLocale(equivalentTo: Locale(identifier: "en-US")), reserve it, and only release Locale objects taken from reservedLocales. Do not trust Locale.current (this machine's en_ID silently resolves to en-IN). Expose an explicit locale picker limited to supportedLocales. Corrected: Indonesian IS supported by DictationTranscriber (verified end to end - a say-generated Indonesian sentence transcribed word-perfect in 0.36s after a 31s asset download); it is only SpeechTranscriber that lacks it.
- Expect ~0.2-0.5s from hotkey release to injectable text (measured: 0.15s for a 4.7s clip, 0.53s for a 24s clip, realtime-paced). Budget the accessibility text-injection work inside that window and show a brief "finalizing" state rather than blocking the UI.
- Skip Parakeet. Integrating NVIDIA Parakeet via Hugging Face on this machine would mean shipping a Python/MLX or CoreML-converted model (roughly 0.6-2.4GB of weights) plus its runtime inside an app that currently has zero third-party dependencies and no Developer ID for signing/notarizing embedded binaries. Apple's engine is already ~12x realtime on-device with working vocabulary biasing and per-word confidence, so put Parakeet behind a `protocol TranscriptionEngine` seam (begin/feed/finishAndCommit mirrors the Session API exactly) and leave it unimplemented unless Apple's accuracy proves inadequate in real use.

### Still unknown

- All audio in this probe came from `say`-generated files converted offline. A live AVAudioEngine mic tap was NOT tested — the format conversion, buffer cadence, and bufferStartTime clocking under a real tap (and whether passing bufferStartTime: nil is preferable to a self-maintained clock) still need a dedicated mic probe. TCC prompts (NSMicrophoneUsageDescription, and whether the new API needs any speech-recognition authorization — we never called SFSpeechRecognizer.requestAuthorization and it worked fine) are unverified for a real .app bundle.
- Why contextualStrings works on DictationTranscriber but not SpeechTranscriber is undocumented and could plausibly change in a point release. Worth re-running phase 5/5d after any macOS update, since Edict's whole dictionary feature depends on it.
- Biasing was inconsistent for "Wispr Flow" specifically (fixed with a 9-term list on one file, not fixed on others). Unclear whether this is about term length, acoustic distance from "whisper", or list position. Testing with real human speech rather than `say` synthesis may behave differently — synthetic TTS audio is unusually clean and may not represent real biasing behaviour.
- SFSpeechLanguageModel.Configuration exposes a `weight` (0.0-1.0, macOS 26+) that had no observable effect here because the whole custom-LM path was inert. If a future OS build activates that path, re-testing weight would be worthwhile.
- Whether contextualStrings weighting can be influenced at all (e.g. by repeating a term in the array) was not tested. If Edict needs stronger biasing for a few critical terms, that is a cheap experiment.
- modelRetention showed no measurable difference in prepareToAnalyze cost (whileInUse/lingering/processLifetime all ~2ms warm), so its real effect is presumably on memory residency over longer idle periods. Not characterized — if Edict's RSS matters when idle, measure .lingering vs .processLifetime over minutes and consider SpeechModels.endRetention().
- DictationTranscriber's volatile/final range semantics were assumed to match SpeechTranscriber's (the Sink accumulator relies on this and produced correct output on all test files), but the range structure was only traced in detail for SpeechTranscriber. Worth a targeted trace before shipping.
- The probe leaked reservation slots during exploration (ja-JP, en-AU, en-CA, en-GB were reserved and later released). Since reservations persist per client id and max out at 5, Edict should log its reservation state at launch during development to catch leaks early.

### Verified snippets

- `speech--…` — EdictTranscriber (production engine, per-utterance): The complete push-to-talk transcription engine: DictationTranscriber + dictionary biasing + correct accumulation + correct teardown. Copy this shape directly. Verified end-to-end in phase 8.
- `speech--…` — Mic/file -> analyzer format conversion: The analyzer accepts ONLY 16000Hz or 8000Hz mono Int16 interleaved. Any other source (AVAudioEngine tap is typically 44.1/48kHz Float32 non-interleaved) must be converted. This is the conversion the streaming path needs.
- `speech--…` — Reading transcriptionConfidence + audioTimeRange off runs: Per-word confidence Double and CMTimeRange. Requires a CUSTOM Preset — the named presets (.transcription, .progressiveTranscription) have attributeOptions == [] and yield a single attribute-free run.

---

## Global push-to-talk hotkey — CGEventTap

**Verified:** True

### Summary

Built and ran <scratch> (swift-tools 6.2, Swift 6 language mode, debug + release, warning-free for the deliverable file). PERMISSION TRUTH: this probe NEVER got Input Monitoring, so I could not observe a single real keystroke — AXIsProcessTrusted()=false, IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)=kIOHIDAccessTypeDenied, CGPreflightListenEventAccess()=false. Everything about press/release *delivery* below is therefore mechanism-level (SDK headers + tap-server readback), not observed-in-the-wild; everything about the decoder, permission APIs, tap lifecycle, mask negotiation and threading IS empirically measured. Mechanism verdict: use CGEvent.tapCreate(.cgSessionEventTap, .headInsertEventTap, .listenOnly) — NSEvent.addGlobalMonitorForEvents is disqualified by two lines in the macOS 26.5 SDK NSEvent.h:541: key events "may only be monitored if ... your application is trusted for accessibility access" (the scarier Accessibility TCC prompt, not Input Monitoring) and "your handler will not be called for events that are sent to your own application" (so PTT would die whenever Edict's own window is focused). Three hard permission gotchas measured: (a) a .listenOnly tapCreate returns a NON-NIL CFMachPort even when access is denied, and that port is permanently disabled — 5 retries of CGEvent.tapEnable never flipped tapIsEnabled; .defaultTap returns nil instead, so the nil-check is not a uniform gate; (b) the window server silently STRIPS keyDown/keyUp from eventsOfInterest when access is missing — requested 0x1c00, CGGetEventTapList reported 0x1000 granted (flagsChanged survives, keyDown/keyUp cleared); (c) launched from the terminal the process inherits Ghostty/claude as TCC-responsible and reads "denied", while the same ad-hoc-signed .app launched via `open` read "unknown (not yet asked)" on its first launch — TCC identity requires a real signed bundle. Threading is settled empirically: a dedicated .userInteractive Thread with its own CFRunLoop ticked 151/150 expected times while the main thread was blocked 3s, whereas the identical source on CFRunLoopGetMain() ticked 0 times. Lifecycle is leak-free only with CFMachPortInvalidate: 500 taps without it leaked exactly 500 Mach ports 1:1; with tapEnable(false)+CFMachPortInvalidate the delta was a constant 21 at 50, 500 and 3000 iterations (one-time run-loop cost, not a leak). MACHINE-SPECIFIC BOMBSHELL: CGGetEventTapList shows 751 installed taps, 729 of them from Karabiner-Core-Service, plus Karabiner DriverKit VirtualHIDKeyboard 1.8.0 active in the IORegistry — every keystroke Edict sees is re-synthesized by Karabiner's virtual keyboard. The ACTIVE Karabiner profile ("x") already consumes right_command (→Hyper held / Escape on tap), caps_lock (→symbol-mode layer) and fn (fn+esc, fn+N), while right_option and right_control appear 0 times. Only "Apple Internal Keyboard / Trackpad" is attached, which has no Right Control key. Therefore: default to Right Option (keyCode 61, NX_DEVICERALTKEYMASK 0x40).

### Traps

**CGEvent.tapCreate with options: .listenOnly returns a NON-NIL CFMachPort even when Input Monitoring is denied. Measured at all three tap locations (.cghidEventTap, .cgSessionEventTap, .cgAnnotatedSessionEventTap): create=OK, tapIsEnabled=false. Calling CGEvent.tapEnable(tap:enable:true) five times over one second never flipped it. A naive `guard let port = CGEvent.tapCreate(...) else { showPermissionUI() }` therefore reports SUCCESS and then silently receives nothing, forever.**

> Never treat non-nil as success. Gate on CGPreflightListenEventAccess() BEFORE creating, and assert CGEvent.tapIsEnabled(tap: port) == true immediately AFTER tapEnable. A tap created while denied is permanently dead — after the user grants the permission you must DESTROY and RE-CREATE the tap, not re-enable it. (Note the asymmetry: options: .defaultTap returns nil instead of a dead port, so the nil-check is not a portable gate.)

**The window server silently STRIPS keyDown/keyUp out of eventsOfInterest when access is missing, exactly as documented in CGEvent.h ("the appropriate bits in the mask are cleared. If that results in an empty mask, then NULL is returned"). Measured: requested 0x1c00 (keyDown|keyUp|flagsChanged), CGGetEventTapList reported 0x1000 granted — only flagsChanged survived. Requesting keyboard+mouse (0x401c20) yielded 0x401020: the mouse bits kept the mask non-empty so the tap was created anyway. So a tap that mixes mouse and keyboard events can come back with a non-empty mask and look healthy while being keyboard-blind.**

> Keep the hotkey tap keyboard-only, and read back what you were actually granted via CGGetEventTapList, filtering on tappingProcess == getpid(). Require `granted & requested == requested` before declaring the monitor live. The PushToTalkMonitor snippet does exactly this in installTap().

**NSEvent.addGlobalMonitorForEvents(matching:) returns a non-nil token even with zero permissions — there is no failure signal at all. Worse, the macOS 26.5 SDK NSEvent.h:541 states two disqualifiers verbatim: key-related events require ACCESSIBILITY trust (AXIsProcessTrusted), not Input Monitoring; and "your handler will not be called for events that are sent to your own application."**

> Do not use NSEvent global monitors for push-to-talk. The self-exclusion means the hotkey dies whenever Edict's own window (history browser, dictionary editor) has focus — a guaranteed bug report. Also global monitors are delivered on the main run loop of an NSApplication, which the isolation measurement shows goes to zero delivery during main-thread hitches. Use the CGEventTap on a dedicated thread. Keep NSEvent.addLocalMonitorForEvents only for in-app shortcut handling.

**NSEvent.ModifierFlags.deviceIndependentFlagsMask == 0xffff0000 (measured at runtime). The idiomatic-looking `event.modifierFlags.intersection(.deviceIndependentFlagsMask)` throws away the entire low 16 bits, which is exactly where NX_DEVICERALTKEYMASK (0x40), NX_DEVICELALTKEYMASK (0x20), NX_DEVICERCMDKEYMASK (0x10), NX_DEVICELCMDKEYMASK (0x08), NX_DEVICERCTLKEYMASK (0x2000) etc. live. After masking, Left Option and Right Option are indistinguishable.**

> Work on the raw UInt64: `event.flags.rawValue` (CGEvent) or `event.modifierFlags.rawValue` (NSEvent). Never intersect with .deviceIndependentFlagsMask when you care about left vs right. Observed raw down-flag values (verified via constructed CGEvents, 10/10 decoder PASS): L-Option 0x00080020, R-Option 0x00080040, L-Command 0x00100008, R-Command 0x00100010, L-Control 0x00040001, R-Control 0x00042000, L-Shift 0x00020002, R-Shift 0x00020004. Release is always the same keyCode with the device bit cleared.

**fn/Globe has NO device-dependent bit — there is no NX_DEVICEFN. It is visible only through maskSecondaryFn / NSEvent.ModifierFlags.function (both measured as 0x00800000), and that same bit is set on the keyDown of every arrow key and every fn-row key. Verified by construction: Left Arrow (keyCode 123) and F5 (keyCode 96) both carry fnFlagSet=true.**

> Discriminate on event TYPE plus keyCode, never on the flag: a real fn press is (.flagsChanged && keyCode == 63 && maskSecondaryFn SET); a real fn release is (.flagsChanged && keyCode == 63 && maskSecondaryFn CLEAR). Incidental function flags only ever appear on .keyDown/.keyUp, which carry the arrow/F-key's own keyCode. Never infer fn from maskSecondaryFn alone.

**kAXTrustedCheckOptionPrompt is imported into Swift as a mutable global `var` (the C decl in HIServices/AXUIElement.h:66 is a non-const CFStringRef), so the textbook `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true])` is a HARD COMPILE ERROR under the Swift 6 language mode: "reference to var 'kAXTrustedCheckOptionPrompt' is not concurrency-safe because it involves shared mutable state". `nonisolated(unsafe)` on a local binding does NOT suppress it.**

> Use the literal string key: AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary). I confirmed at runtime via dlsym(RTLD_DEFAULT, "kAXTrustedCheckOptionPrompt") that the symbol's value is exactly "AXTrustedCheckOptionPrompt".

**Forgetting CFMachPortInvalidate leaks one Mach port per tap, 1:1. Measured: 500 create-without-teardown cycles moved the task's Mach port-name count from 32 to 532 (delta exactly 500). Just dropping the Swift reference is not enough because the CFRunLoopSource holds the port.**

> Teardown order: CFRunLoopRemoveSource(rl, src, .commonModes) -> CGEvent.tapEnable(tap: p, enable: false) -> CFMachPortInvalidate(p) -> nil out the refs. With that, 3000 create/destroy cycles produced a CONSTANT delta of 21 ports (one-time run-loop setup, identical at 50, 500 and 3000 iterations), i.e. no leak. Also: pass context with Unmanaged.passUnretained — CGEventTapCreate never releases userInfo, so passRetained is an unconditional leak of the monitor object and its captured handler, and there is nowhere to legally call takeRetainedValue since the callback may fire many times.

**.tapDisabledByTimeout and .tapDisabledByUserInput arrive as CGEventTypes 0xFFFFFFFE / 0xFFFFFFFF through the same callback. They are not real events and are NOT covered by your eventsOfInterest mask — you get them whether you asked or not, and if you fall through to a `default: return Unmanaged.passUnretained(event)` you will re-enable nothing and go permanently deaf. Timeout fires when your callback is too slow; userInput fires when the user hits the security override.**

> Handle both explicitly, call CGEvent.tapEnable(tap: port, enable: true), and return nil (not the event). Critically, also ABORT any push-to-talk hold in progress and tell the UI — while the tap was down you may have missed the key RELEASE, so a naive implementation records forever. Add the belt-and-braces watchdog too: check CGEvent.tapIsEnabled every run-loop slice, because the OS can kill a tap without delivering the disable event. Keep the callback body allocation-free and under ~1ms so timeout never fires; do all transcription work by handing the transition to an actor.

**TCC identity: a bare SwiftPM executable can never hold Input Monitoring stably. Running the probe binary from the terminal reported IOHIDCheckAccess = kIOHIDAccessTypeDenied because TCC attributes responsibility to the launching terminal (here Ghostty / claude.app). Wrapping the SAME binary in an ad-hoc-signed .app with CFBundleIdentifier and launching via `open` reported kIOHIDAccessTypeUnknown (not yet asked, i.e. promptable) on first launch. Also note this machine has ZERO codesigning identities (`security find-identity -v -p codesigning` = 0 valid identities), so Edict can only be ad-hoc signed — and ad-hoc signatures have no stable designated requirement, so macOS may drop the TCC grant on every rebuild.**

> Ship Edict as a real .app bundle with a stable CFBundleIdentifier and LSUIElement, launched via LaunchServices — never test the hotkey by running the SwiftPM binary from a terminal, you will chase a phantom permission bug. Sign with a stable ad-hoc identifier (`codesign --force --sign - --identifier dev.local.edict`) so the identity at least does not change per build. Expect the user to have to re-add Edict to Input Monitoring after some rebuilds; handle kIOHIDAccessTypeDenied by deep-linking rather than re-prompting, and detect grant-arrival by polling CGPreflightListenEventAccess() and re-creating the tap.

**THIS MACHINE runs Karabiner-Elements with the DriverKit VirtualHIDKeyboard 1.8.0 driver active. CGGetEventTapList shows 751 installed taps, 729 of them belonging to Karabiner-Core-Service at tap point 0 (.cghidEventTap). Every keystroke Edict's session tap sees has been swallowed by Karabiner at the HID layer and re-synthesized by its virtual keyboard. The ACTIVE profile ("x", from ~/.config/karabiner/karabiner.json) already binds right_command (-> Hyper when held, Escape on tap), caps_lock (-> symbol-mode layer) and fn (fn+esc lock screen, fn+N network pane).**

> Do not pick a key Karabiner already claims. right_option and right_control appear ZERO times in the active profile. Also budget for the possibility that Karabiner's virtual keyboard normalizes the left/right device bits (it should preserve them, since it re-emits right_option as HID usage 0xE6, but I could not verify this without Input Monitoring) — so the dictionary/settings UI must let the user rebind, and the key picker should show the raw keyCode + flags it observed rather than assuming.

**Also live in the tap list right now: BetterTouchTool holds a .defaultTap at .cghidEventTap with a keyboard mask AND a separate .listenOnly tap on flagsChanged only (mask 0x1000); Siri and SiriNCService both hold .defaultTap taps with mask 0x1c00 (keyDown|keyUp|flagsChanged) at the session point — that is the hold-fn / double-fn Siri and system dictation handler. MacWhisper IS running (pid 16267) but does NOT appear in the tap list at all; its configured shortcut is KeyboardShortcuts_streamingOverlayActivation = {carbonModifiers:2048, carbonKeyCode:42} = Option+backslash, i.e. it uses Carbon RegisterEventHotKey.**

> Two consequences. (1) fn/Globe is contested by Siri at .defaultTap in front of us — avoid it. (2) Carbon RegisterEventHotKey (what MacWhisper uses) needs no TCC permission but CANNOT bind a bare modifier and cannot report release, so it is not an option for push-to-talk; the CGEventTap permission cost is unavoidable. Option+backslash is free of conflict if you also want a discrete toggle shortcut.

**Using options: .defaultTap to SUPPRESS the hotkey so it does not reach the focused app breaks the key for its real purpose. Right Option is AltGr on many layouts; this machine is on com.apple.keylayout.ABC where Option+letter produces dead keys and accented characters.**

> Use .listenOnly and never suppress. Instead make the gesture unambiguous in software: require the modifier to be held ALONE (cancel the recording the moment any other keyDown or any other modifier's flagsChanged arrives) and require a minimum hold (~120ms) before you commit to recording. Both are implemented in the PushToTalkMonitor snippet's `chorded` / `minimumHold` logic. .listenOnly also has the side benefit that CGEvent.tapCreate degrades to a dead-but-non-nil port instead of nil, which is detectable via tapIsEnabled.

### Recommendations

- MECHANISM: CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: flagsChanged|keyDown). Not NSEvent global monitors — the SDK header rules them out twice over (Accessibility-gated, and blind to events destined for Edict itself).
- THREADING: put the tap on a dedicated Thread with qualityOfService = .userInteractive and its own CFRunLoop, pumped by `while !isCancelled { CFRunLoopRunInMode(.defaultMode, 0.25, false) }`. Measured proof: main blocked 3.0s -> dedicated-thread run loop serviced 151/150 expected ticks, main run loop serviced 0/150. On the main run loop, any synchronous SwiftUI hitch (rendering the history list, loading the dictionary, a Core Data fetch) delays press/release delivery by exactly the hitch duration AND risks .tapDisabledByTimeout, which silently kills the hotkey.
- CALLBACK DISCIPLINE: the C callback must be allocation-free and sub-millisecond. Decode the transition, then hand it to an actor (`Task { await recorder.begin() }`) or a lock-free ring buffer. Never touch @MainActor state, never do I/O, never allocate a String on the hot path — that is what earns you .tapDisabledByTimeout.
- DEFAULT HOTKEY: hold RIGHT OPTION (virtual keyCode 61, press = .flagsChanged with NX_DEVICERALTKEYMASK 0x40 SET in event.flags.rawValue, release = same keyCode with 0x40 CLEAR; full down-flags 0x00080040). Justification specific to this machine: (1) it is the only candidate the ACTIVE Karabiner profile does not already claim — grep of ~/.config/karabiner/karabiner.json profile "x" shows right_option occurring 0 times, versus right_command remapped to Hyper/Escape, caps_lock remapped to a symbol layer, and fn used for fn+esc and fn+N; (2) macOS itself binds hold-fn and double-fn to Siri/system dictation, and Siri + SiriNCService currently hold .defaultTap taps on flagsChanged AHEAD of any session tap we install; (3) MacWhisper uses Carbon RegisterEventHotKey on Option+backslash, no modifier-only conflict; BetterTouchTool listens on flagsChanged but in .listenOnly mode so it does not consume; (4) Right Option is physically present on the Apple Internal Keyboard / Trackpad, which is the only keyboard currently attached; (5) it has a genuine left/right device bit, so it is unambiguously distinguishable, unlike fn.
- FALLBACK/ALTERNATE, and why NOT Right Control as the default: Right Control (keyCode 62, NX_DEVICERCTLKEYMASK 0x2000) is equally unclaimed by Karabiner and would be my second choice — but the MacBook's built-in Apple keyboard has no Right Control key at all, so it is unreachable on the only keyboard attached to this machine. Offer it in the picker for users on full-size external keyboards, but do not ship it as the default.
- DANGEROUS KEYS — DO NOT GRAB: fn/Globe (owned by macOS for Siri/dictation; contested by Siri's .defaultTap; no device bit so left/right and incidental-flag disambiguation is fragile; and it is a layer modifier in the active Karabiner profile). Right Command (remapped to Hyper-when-held by the active Karabiner profile — you would fight the remapper on every press). Caps Lock (remapped to a symbol-mode layer in the active profile; also its .flagsChanged is a TOGGLE, not a hold, so it cannot express push-to-talk at all). Left Control (17 occurrences in the active profile, and it is tapped-to-Escape in the other profile). Left Option (25 occurrences in the active profile; also the primary AltGr/dead-key modifier). Left Command / Left Shift (universal chord modifiers — grabbing them makes every Cmd-shortcut and every capital letter arm the recorder). Any plain letter/number key (you would fight every text field on the system).
- PERMISSION UX FLOW: on launch call IOHIDCheckAccess(kIOHIDRequestTypeListenEvent). kIOHIDAccessTypeGranted -> start the tap. kIOHIDAccessTypeUnknown -> call CGRequestListenEventAccess() once to show the system prompt. kIOHIDAccessTypeDenied -> prompting is a no-op, so open x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent with clear instructions. Then poll CGPreflightListenEventAccess() (e.g. every 1s while the onboarding sheet is up, and once on NSApplication.didBecomeActiveNotification) and RE-CREATE the tap when it flips true — never try to re-enable the dead tap.
- PERMISSION SCOPE: the hotkey needs only Input Monitoring (kTCCServiceListenEvent). Accessibility (AXIsProcessTrusted) is a SEPARATE, scarier grant that Edict will need anyway for AX-based text injection at the cursor, and CGEvent.post-based injection needs Input Monitoring's sibling, PostEvent (CGPreflightPostEventAccess). Ask for them in stages tied to the feature the user just tried, not all at once on first launch — and note that on this machine all three currently read denied/false for anything launched from a terminal.
- DIAGNOSTICS: ship CGGetEventTapList behind a debug menu item. It needs no permission, and it is how I discovered Karabiner's 729 taps, BetterTouchTool's .defaultTap, and Siri's flagsChanged tap in under a second. When a user reports 'the hotkey does nothing', that one call plus `granted & requested == requested` will identify a conflicting remapper or a stripped mask immediately. Also assert machPortCount() stability across start/stop in debug builds.
- PACKAGE MANIFEST: use `// swift-tools-version:6.2` — `.macOS(.v26)` is unavailable at tools-version 6.0 ('v26' was introduced in PackageDescription 6.2). Add `swiftSettings: [.swiftLanguageMode(.v6)]`. IOKit HID access needs no bridging header, module map, or linker flag; plain `import IOKit` + `import IOKit.hid` resolves IOHIDCheckAccess, IOHIDRequestAccess, kIOHIDRequestTypeListenEvent, kIOHIDRequestTypePostEvent and the kIOHIDAccessType* constants. AXIsProcessTrusted comes from `import ApplicationServices` (HIServices), not CoreGraphics.

### Still unknown

- Does Karabiner-Elements' DriverKit VirtualHIDKeyboard 1.8.0 preserve the device-dependent left/right bits (NX_DEVICERALTKEYMASK 0x40 for right_option) when it re-synthesizes events, or does it normalize everything to the left-hand bits? It re-emits HID usage 0xE6 which SHOULD produce keyCode 61 + 0x40, but I could not observe a single real event to confirm. This is the single highest-risk unknown for the Right Option recommendation. Verify the moment Input Monitoring is granted, using the probe's `tap-thread` mode, and be ready to fall back to matching on the device-independent maskAlternate plus a user-visible 'which Option key did you press?' calibration step.
- Does macOS 26 still honour Accessibility (kTCCServiceAccessibility) as an implicit grant for CGEventTap keyboard events, as CGEvent.h's legacy 'access for assistive devices ... AXMakeProcessTrusted' wording implies, or is kTCCServiceListenEvent now strictly required? Both were denied here so I could not distinguish. Matters for onboarding: if Accessibility alone suffices, and Edict needs Accessibility anyway for text injection, you may be able to ask for one permission instead of two.
- Is CGEventSource.keyState(.hidSystemState, key:) / CGEventSource.flagsState(.hidSystemState) permission-free? Both returned all-false / 0x00000000 during a 310-sample 3-second poll, but nobody was pressing keys, so the result is inconclusive rather than negative. If they are permission-free they would give Edict a genuinely useful degraded mode: a ~8ms polling fallback that works with ZERO TCC grants, letting the app be usable while the user is still figuring out System Settings. Worth 10 minutes to confirm once someone can hold a key.
- Whether the internal Apple keyboard genuinely lacks a Right Control key. I inferred this from the standard Apple internal layout and confirmed only 'Apple Internal Keyboard / Trackpad' is attached via ioreg; I could not enumerate the device's HID elements because IOHIDDeviceOpen needs the same ListenEvent grant. If a Right Control does exist it becomes a strong second default.
- Real end-to-end latency from physical keydown to the .flagsChanged callback firing, with Karabiner and BetterTouchTool both sitting ahead of us in the tap chain. Zero measurements were possible. CGGetEventTapList exposes minUsecLatency/avgUsecLatency/maxUsecLatency per tap and resets them on each call, so this is directly measurable once permission exists — but note the values I read back (3.4s, 14s averages) are clearly cumulative-since-instantiation garbage, not per-event latency, so calibrate the interpretation before trusting it.
- Whether an ad-hoc signature (the only option on this machine — 0 valid codesigning identities) survives rebuilds without the user re-granting Input Monitoring. My repeated `open` launches flipped from kIOHIDAccessTypeUnknown to kIOHIDAccessTypeDenied between the first and second launch of an identically-signed bundle, which I could not explain. Worth pinning down, because if every rebuild costs a trip to System Settings it will dominate the development loop and should shape how Edict is built and run during development.

### Verified snippets

- `hotkey--…` — PushToTalkMonitor.swift: Production-ready push-to-talk hotkey monitor for Edict. Listen-only session tap on a dedicated .userInteractive thread with its own CFRunLoop; permission gate; granted-mask verification; tapDisabled re-enable; chord cancellation; leak-free teardown. Compiles warning-free under Swift 6 language mode, debug and release. Full file at <scratch>
- `hotkey--…` — DevBits + decodeFlagsChanged: The exact bit tests. Device-dependent modifier masks copied verbatim from $(xcrun --sdk macosx --show-sdk-path)/System/Library/Frameworks/IOKit.framework/Headers/hidsystem/IOLLEvent.h lines 253-262, and the press/release decoder. Verified 10/10 PASS by the `synth` probe mode which builds a CGEvent per case and decodes it. NOTE the asymmetry: there is NO NX_DEVICEFN bit, so fn/Globe must be read from maskSecondaryFn (0x00800000).
- `hotkey--…` — PermissionCheckAndDeepLink: Exact non-prompting checks, exact prompting calls, and the Settings deep-links. Compiled and run; all four x-apple.systempreferences URLs resolved to System Settings.app via NSWorkspace.urlForApplication(toOpen:). IOKit HID access functions are usable from plain Swift with NO bridging header — `import IOKit` plus `import IOKit.hid` is enough (IOHIDCheckAccess/IOHIDRequestAccess/kIOHIDRequestTypeListenEvent/kIOHIDAccessTypeGranted all resolve).
- `hotkey--…` — DedicatedThreadRunLoop_measured: The threading answer, measured. A 0.02s CFRunLoopTimer on a dedicated .userInteractive thread ticked 151 times (expected ~150) while the main thread slept 3.0s; the identical timer on CFRunLoopGetMain() ticked 0 times over the same 3.0s block. Worst tick gap on the tap thread was 23.2ms (that is the CFRunLoopRunInMode slice granularity, not delivery latency).
- `hotkey--…` — MachPortLeakDetector: Proves the teardown is correct. 500 create+stop cycles moved the task's Mach port-name count by a CONSTANT 21 (identical at 50, 500 and 3000 iterations = one-time run-loop cost). 500 create-without-stop cycles leaked exactly 500 ports, 1:1, and all 500 were reclaimed by a later explicit stop(). Use this in a debug assertion.

---

## Text injection at the cursor

**Verified:** True

### Summary

Built <scratch> (1259 lines, 9 files), compiling clean with ZERO warnings and ZERO errors in Swift 6 language mode, both debug and release. I ran every subcommand that does not require Accessibility. HONEST LIMIT: AXIsProcessTrusted()==false, CGPreflightPostEventAccess()==false, and I cannot grant Accessibility non-interactively (system TCC.db is root-owned; I have no Full Disk Access). I therefore did NOT observe text landing in TextEdit or any other app — every AX read returned an error and every CGEvent.post was silently dropped. What I DID verify empirically: AXValueCreate/AXValueGetValue .cfRange round-trip is exact for 5 range cases and correctly rejects a wrong-type read; NSPasteboard full-fidelity snapshot/restore is byte-lossless across 2 items carrying public.tiff + public.rtf + public.utf8-plain-text + public.file-url once derived flavors are excluded; layout-aware keycode lookup via TISCopyCurrentKeyboardLayoutInputSource + UCKeyTranslate returns v=9/a=0/z=6/q=12 on this layout; grapheme-safe chunking is lossless over ZWJ family emoji, regional-indicator flags, CJK and combining Latin; CGEventKeyboardSetUnicodeString retains at least 4096 UTF-16 units intact in the event payload (the folklore "20 char limit" is NOT the event buffer); a fresh CGEvent's default flags are 0x20000000 and `.flags = .maskCommand` fully replaces them; cold-start of the CG event path costs 55-90 ms (one 1422 ms outlier) versus 5 microseconds warm. I also found four hard API traps and proved that an ad-hoc code signature makes the designated requirement a bare cdhash, so a TCC Accessibility grant dies on every single rebuild, while a self-signed certificate yields the rebuild-stable DR `identifier "dev.edict.injectprobe" and certificate leaf = H"..."`.

### Traps

**`kAXTrustedCheckOptionPrompt` is imported into Swift as a MUTABLE GLOBAL `var CFStringRef`, so any reference to it is a hard compile ERROR under Swift 6 strict concurrency: "reference to var 'kAXTrustedCheckOptionPrompt' is not concurrency-safe because it involves shared mutable state". This will bite Edict on the very first permission-onboarding screen.**

> Use the literal key string instead of the imported constant: `let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary; AXIsProcessTrustedWithOptions(opts)`. (Alternative: wrap the constant behind a `nonisolated(unsafe) let` shim, but the literal is cleaner and equally correct.)

**`CGEventSource.flagsState(.privateState)` — i.e. CGEventSourceFlagsState(kCGEventSourceStatePrivate) — BLOCKS FOREVER. Measured: the process hung until SIGTERM at both 12 s and 120 s timeouts. `.combinedSessionState` and `.hidSystemState` both return promptly.**

> Never query flags state for the private state ID. To read the physically-held modifier state (needed to detect the still-held push-to-talk key) use `CGEventSource.flagsState(.combinedSessionState)` only.

**`CGEventSourceSetLocalEventsSuppressionInterval` does NOT import as a static func. It imports as a SETTER on an instance property (per CoreGraphics.apinotes: `setter:CGEventSource.localEventsSuppressionInterval(self:_:)`), so `CGEventSource.setLocalEventsSuppressionInterval(src, 0.0)` fails to compile. Separately, the measured default interval is 0.25 s and the measured default filter mask on a fresh private source is 0 (permit nothing), meaning every injection would suppress the user's real keyboard and mouse for a quarter second.**

> `src.localEventsSuppressionInterval = 0.0` and explicitly `src.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)`. The getter is `src.getLocalEventsFilterDuringSuppressionState(.eventSuppressionStateSuppressionInterval)`.

**When the process is NOT Accessibility-trusted, the system-wide element does not report .apiDisabled. Measured verbatim: `AXUIElementCreateSystemWide() -> kAXFocusedUIElementAttribute` returns **cannotComplete (-25204)**, and `kAXFocusedApplicationAttribute` also returns cannotComplete. Only the per-application element from `AXUIElementCreateApplication(pid)` returns **apiDisabled (-25211)**. Any code that detects "no permission" by checking for .apiDisabled will never see it on the systemWide route, and .cannotComplete is indistinguishable from a hung/unresponsive target app.**

> Gate on `AXIsProcessTrusted()` explicitly before any AX work; never infer permission state from an AXError. The AXErrors you must actually branch on for a write are: .success, .attributeUnsupported (-25205), .illegalArgument (-25201), .invalidUIElement (-25202), .cannotComplete (-25204), .noValue (-25212), .apiDisabled (-25211), .failure (-25200).

**`CGEvent.post(tap:)` returns Void and provides NO error channel whatsoever. Measured: while untrusted, `postCommandV` returned true, `UnicodeInject.type` reported chunks=1 failedChunk=nil, and both were complete no-ops — every event was silently discarded. This is exactly the failure mode the blog post describes, and it applies to Strategies B and C, not just to AX.**

> Pre-flight with `CGPreflightPostEventAccess()` (and `IsSecureEventInputEnabled()` from Carbon.HIToolbox — verified callable, currently false — because secure input, e.g. a focused password field, drops all posted events regardless of permission). Then post-verify with an AX read-back fingerprint poll (PostInjectVerifier snippet). There is no other way to know a paste landed.

**`NSPasteboard.PasteboardType.fileContentsType(forPathExtension: "")` TRAPS at runtime: "Fatal error: Unexpectedly found nil while implicitly unwrapping an Optional value". It is an implicitly-unwrapped-optional bridge of a nullable ObjC return.**

> Never call it with an empty extension. Hardcode the promise-type UTI strings you need.

**`item.data(forType:)` returns nil for flavors that ARE listed in `item.types`. Measured: `public.utf16-external-plain-text` is listed but yields nil data, because the pasteboard synthesizes it lazily from public.utf8-plain-text. A naive snapshot doing `item.data(forType: t)!` CRASHES. Worse, after a restore the pasteboard regenerates those derived flavors, so a byte-perfect restore reports typesMatch=false / bytesMatch=false and looks broken.**

> Skip nil data instead of force-unwrapping, and maintain an explicit derived-type deny-list (public.utf16-external-plain-text, public.utf16-plain-text, NSStringPboardType, "CorePasteboardFlavorType 0x75747874"). Compare only the types you actually captured. With that fix, restore is VERIFIED byte-lossless across a 2-item clipboard carrying public.tiff + public.rtf + public.utf8-plain-text + public.file-url.

**An ad-hoc code signature (`codesign -s -`) produces the designated requirement `cdhash H"18ed0074..."` — verified with `codesign -d -r-`. TCC keys the Accessibility grant to that DR, so the grant is invalidated by EVERY rebuild. On this machine (`security find-identity -v -p codesigning` => 0 valid identities, no Developer ID) that means the user must delete and re-add Edict in System Settings > Privacy & Security > Accessibility after every single build. Note also that SwiftPM already ad-hoc signs arm64 binaries by default (Signature=adhoc, Identifier=probe-inject).**

> Verified working alternative: create a self-signed codeSigning certificate, import it into a keychain, and sign with it. It reports CSSMERR_TP_NOT_TRUSTED and `find-identity -v` shows 0 valid identities, but `codesign --keychain <kc> --sign "Edict Dev Self Signed" --identifier dev.edict.injectprobe` still succeeds and yields the REBUILD-STABLE designated requirement `identifier "dev.edict.injectprobe" and certificate leaf = H"b47fc10c..."`. The Accessibility grant then survives rebuilds. Recipe that worked: openssl req -x509 with extendedKeyUsage=critical,codeSigning plus the Apple code-signing OID `1.2.840.113635.100.6.1.13=DER:0500`, then `openssl pkcs12 -export -legacy -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES` (a modern PKCS12 fails macOS import with "MAC verification failed"), then `security import ... -T /usr/bin/codesign -A`.

**Cold-start cost of the CoreGraphics event path. Measured per-call on a fresh process: CGEventSource(stateID:) #1 = 6-15 ms (#2 = 0.03 ms), CGEventSource.flagsState #1 = 34-35 ms, CGEvent(keyboardEventSource:) #1 = 44-50 ms (#2 = 0.00 ms), first post = 1.4 ms, AXIsProcessTrusted() #1 = 17-18 ms, first systemWide AX copy = 31-42 ms. Aggregate first create+post measured at 55-90 ms across three runs, with one 1422 ms outlier on a truly cold process. Warm median post is 0.005-0.007 ms. A fixed 150 ms clipboard-restore timer can therefore expire before the very first paste of a session is even delivered.**

> Pre-warm at app launch, off the hot path: create and retain a single long-lived `CGEventSource(stateID: .privateState)`, create and discard one CGEvent, and call AXIsProcessTrusted() plus one systemWide AX read. Reuse the retained source for every injection. Never use a fixed restore delay — use the verify-poll-then-restore shape.

**A freshly created CGEvent has default flags 0x20000000 (an undocumented bit, not in the public CGEventFlags list) regardless of which of the three source state IDs created it, and regardless of a nil source. Assigning `.flags = .maskCommand` wipes it, leaving exactly 0x100000. NOTE: I could not observe modifier inheritance from held hardware keys because the measured hardware flag state was 0 the whole time — this half is unverified.**

> Always ASSIGN `.flags`, never OR into the existing value. Combined with a `.privateState` source (independent modifier state table) and a pre-post wait for `CGEventSource.flagsState(.combinedSessionState)` to clear the dangerous bits, that is the belt-and-braces defence against push-to-talk modifier contamination.

**Hardcoding `kVK_ANSI_V` (9) for the synthetic Cmd-V. On non-QWERTY layouts keycode 9 is a different character; on some layouts Cmd-<keycode 9> is Cmd-W, which closes the frontmost browser tab. This is destructive, not merely broken.**

> Resolve the keycode from the user's live layout with TISCopyCurrentKeyboardLayoutInputSource + UCKeyTranslate scanning keycodes 0..127 (Keycodes snippet). Verified on this machine: v=9, a=0, z=6, q=12. Re-resolve on kTISNotifySelectedKeyboardInputSourceChanged rather than caching forever.

**`NSPasteboard.changeCount` does NOT increment when an app READS/pastes the clipboard — only when something writes. So changeCount polling cannot verify that a paste happened. Measured: our writeTransient bumped 306->307, restore bumped 307->308; a paste contributes nothing.**

> Use changeCount for the OTHER job it is good at: if `pb.changeCount != ourChangeCount` at restore time, a clipboard manager, the target app, or the user wrote after us — SKIP the restore entirely rather than clobbering them. For paste success, use the AX read-back verifier.

**Restoring a `public.file-url` flavor emits a benign stderr line `sandbox_extension_consume failed: 1 (Operation not permitted)`. It is a red herring: the restore still reported ok=true and the bytes compared identical.**

> Do not treat that log line as a failure signal; rely on `pb.writeObjects` returning true plus your own byte comparison.

**AXValue CFRange locations and lengths are UTF-16 code units, not Swift Characters and not grapheme clusters. Using `text.count` to advance the caret after inserting text containing emoji or combining marks puts the caret in the wrong place, and the verification delta check then reports a false silent-failure.**

> Always use `text.utf16.count`. Verified: AXValueCreate(.cfRange)/AXValueGetValue(.cfRange) round-trips exactly for (0,0), (7,0), (12,5), (2147483647,3) and (1000000,999), AXValueGetType returns 4, CFGetTypeID matches AXValueGetTypeID, and reading the same AXValue as .cgPoint correctly returns false rather than garbage.

### Recommendations

- ADOPT THIS LADDER. Rung 0: gate on AXIsProcessTrusted() && CGPreflightPostEventAccess() && !IsSecureEventInputEnabled(); if any is false, go straight to rung 4. Rung 1 (only when the per-bundle policy is axFirst): AX direct insert, attempted ONLY if AXUIElementIsAttributeSettable(kAXSelectedTextAttribute)==true AND the element exposes AXValue or AXSelectedTextRange; accept the result ONLY on read-back-confirmed insertion. Rung 2: pasteboard + layout-correct synthetic Cmd-V, with an AX fingerprint poll between the post and the clipboard restore. Rung 3 (opt-in, per-app): synthetic Unicode keystrokes. Rung 4: leave the text on the clipboard, show a persistent, dismissible notice naming the app that refused, and offer a one-click 'add to paste-only list'.
- THE DECISION RULE FOR 'IS AX INSERT TRUSTWORTHY HERE': trust it if and only if (a) the per-bundle policy is not pasteOnly, AND (b) AXUIElementIsAttributeSettable(el, kAXSelectedTextAttribute) returns .success with settable==true, AND (c) at least one of kAXValueAttribute / kAXNumberOfCharactersAttribute / kAXSelectedTextRangeAttribute is readable, AND (d) the post-write read-back shows the expected change. Verification strength ranking, strongest first: AXValue string compare (length delta AND content hash) > AXNumberOfCharacters delta > AXSelectedTextRange caret advance. If (c) fails the element is permanently untrustworthy for AX insert — cache that per (bundle id, AXRole) and never try AX there again this session.
- MAKE THE VERDICT STICKY AND LEARNED. Persist a per-bundle-id map {bundleID: InjectPolicy} in Edict's settings, seeded with the known-bad list and mutated at runtime: any app that produces confirmedNotInserted or cannotVerify gets demoted to pasteOnly permanently. This turns the blog post's complaint into a self-healing system instead of a hardcoded blocklist you have to maintain. Key on bundle id from NSWorkspace.shared.frontmostApplication.bundleIdentifier, and fall back to pasteOnly when bundleIdentifier is nil (unbundled/helper processes).
- KNOWN-BAD APP FAMILIES FOR AX INSERT (default these to pasteOnly): Electron/Chromium — Cursor (com.todesktop.230313mzl4w4u92), VS Code, Slack, Discord, Notion, Figma, Obsidian, Linear, Postman, Spotify; browsers where the target is a web text area — Safari, Chrome, Edge, Brave, Firefox; terminals — Terminal, iTerm2, Warp, kitty, Alacritty, WezTerm, Ghostty; Java/Qt/custom text engines — the JetBrains IDEs, Sublime Text, Microsoft Word/Excel. Terminals additionally need newlines stripped or converted to spaces before pasting, because a newline in a shell executes the line.
- DO NOT USE A FIXED SLEEP BEFORE RESTORING THE CLIPBOARD. Use the pasteVerified shape: post Cmd-V, sleep a 30-40 ms floor, then poll the focused element's AX fingerprint every 20 ms up to 400 ms, then restore. The poll time IS the settle delay, so native apps finish in ~40 ms while Electron gets the full budget. Restoring before the target has lazily read the pasteboard on its own run loop is precisely what produces the 'Cmd-V pasted my OLD clipboard' bug. And if pb.changeCount has moved when you get to the restore, skip the restore.
- AVOID CLOBBERING CLIPBOARD MANAGERS in three ways simultaneously: (1) mark our pasteboard item with the nspasteboard.org empty-data flavors org.nspasteboard.TransientType and org.nspasteboard.AutoGeneratedType so cooperating managers ignore it; (2) snapshot ALL types of ALL items and restore them byte-for-byte (verified lossless for TIFF/RTF/plain-text/file-url); (3) never restore when changeCount moved. Consider making 'restore the clipboard' a user preference — some users prefer the transcription to simply stay on the clipboard.
- STRATEGY C IS VIABLE ONLY AS A NARROW LAST RESORT. The event payload is not the constraint: CGEventKeyboardSetUnicodeString retained 4096 UTF-16 units intact (verified by reading back with keyboardGetUnicodeString), so the widely repeated '20 character limit' is about delivery, not the buffer. Recommended settings anyway: chunk on GRAPHEME boundaries at 20 UTF-16 units with a 2 ms inter-event delay, post down+up pairs with virtualKey 0 and flags cleared to []. Expect it to be the slowest rung and to be mangled by apps with input-method or auto-complete logic. Do not enable it by default; expose it as a per-app 'type character by character' escape hatch.
- PRE-WARM THE INJECTION PATH AT LAUNCH. Retain one CGEventSource(stateID: .privateState) for the app's lifetime, create and discard one CGEvent, call AXIsProcessTrusted(), and do one throwaway systemWide AX read. Otherwise the first dictation of a session pays 55-90 ms (once observed 1422 ms) of window-server and TCC bootstrap right when the user is watching, and any fixed-delay clipboard restore will fire before the paste is delivered.
- SIGN EDICT WITH A STABLE SELF-SIGNED CERTIFICATE FROM DAY ONE, not ad-hoc. Verified: ad-hoc gives designated requirement `cdhash H"..."` (Accessibility grant dies on every rebuild), self-signed gives `identifier "..." and certificate leaf = H"..."` (grant survives). Generate the cert once, keep it in a dedicated keychain, and make it part of the build script. This will save enormous friction because Edict must be re-granted Accessibility otherwise, and every re-grant needs the user to visit System Settings.
- HANDLE THE PUSH-TO-TALK MODIFIER EXPLICITLY. Before posting anything synthetic, poll CGEventSource.flagsState(.combinedSessionState) until shift/control/option/command/fn/capslock are all clear (10 ms steps, 400 ms cap), then post from a .privateState source with .flags ASSIGNED rather than OR'd. If the timeout expires with modifiers still held, log it and prefer rung 1 or rung 4 over posting a contaminated Cmd-V.

### Still unknown

- UNVERIFIED, THE CENTRAL QUESTION: does AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute, ...) actually return .success on elements that ignore it? I could not test this — AXIsProcessTrusted()==false and I cannot grant Accessibility non-interactively (the Accessibility TCC store is root-owned and I have no Full Disk Access; every AX read returned cannotComplete or apiDisabled). The verification machinery is built, compiled and wired in, but the claim itself remains reputational. NEXT STEP for an interactive session: the harness is ready at <scratch> (ad-hoc signed, bundle id dev.edict.injectprobe). Add it to System Settings > Privacy & Security > Accessibility, then run `EdictInjectProbe.app/Contents/MacOS/probe-inject focus` and `... delayed 6 "hello"` with TextEdit, Cursor, Slack, Safari and Terminal focused in turn. `focus` dumps every attribute with its read error and settable flag, which is exactly the per-app table Edict's policy list should be seeded from.
- Which apps expose a READABLE kAXValueAttribute versus returning attributeUnsupported or noValue is entirely unmeasured here, so the practical reach of the read-back verifier is unknown. The specific cases worth measuring first: Chromium <input> vs <textarea> vs contenteditable; Monaco's hidden textarea in VS Code and Cursor; Slack's Quill composer; Safari web areas; Terminal and iTerm2 (I expect no readable value at all, which would make rung 2 permanently unverifiable there).
- Whether the window server truncates a CGEventKeyboardSetUnicodeString payload on DELIVERY is untested. The event object holds 4096 UTF-16 units intact, but I could not post. The 20-unit chunk recommendation is therefore conservative folklore, not measurement — worth a direct sweep once permission exists.
- Modifier contamination could not be observed because the measured hardware flag state was 0 throughout: I never had a physically-held key to contaminate with. Specifically untested: whether a .privateState source genuinely isolates from held hardware modifiers, or whether the window server merges combinedSessionState at post time regardless of the source's state table. The mitigation (wait for clean flags, then assign flags explicitly) is correct either way, but the underlying mechanism is unconfirmed.
- How long real apps actually take to read the pasteboard after Cmd-V is unmeasured, so the 30 ms floor / 400 ms cap are guesses. Once permission exists, instrument the verify poll and record the observed latency per bundle id — that data should drive per-app settle budgets.
- The undocumented 0x20000000 default event flag bit: I do not know what it means or whether wiping it by assigning .flags matters to any consumer. Every working implementation assigns flags anyway, but if a specific app rejects synthetic pastes it is worth trying `ev.flags = CGEventFlags(rawValue: 0x20000000).union(.maskCommand)` as an experiment.
- Side effect to disclose: my clipboard probes overwrote the user's clipboard (it had held WebKit HTML). I left it cleared rather than holding probe junk. Also, a self-signed certificate now exists in a standalone keychain at .../scratchpad/certtest/probe.keychain — it is NOT in the user's keychain search list (I added it briefly and restored the original list, verified), but if the self-signed-signing approach is adopted the cert should be regenerated properly rather than reusing this throwaway.

### Verified snippets

- `inject--…` — AXBridge — exact CFTypeRef / AXValue bridging from Swift: Strategy A plumbing. These are the precise spellings that compile under Swift 6 strict concurrency. Note AXValueGetValue needs withUnsafeMutablePointer, AXValueCreate needs withUnsafePointer, and unsafeDowncast (not unsafeBitCast — release-mode Swift 6.3 warns on unsafeBitCast from AnyObject to a CF type). AXUIElementCopyAttributeValue is +1 retained into a CFTypeRef? var; Swift's ARC handles the release. Range locations/lengths are UTF-16 code units, NOT Characters.
- `inject--…` — AXFocus — three-route focused-element discovery: systemWide -> kAXFocusedUIElementAttribute is the documented route but returns cannotComplete on unresponsive/hardened apps. Fall back through kAXFocusedApplicationAttribute and then AXUIElementCreateApplication(NSWorkspace frontmost pid). Also carries the pid/bundle id needed for the per-bundle override table.
- `inject--…` — AXInsert — Strategy A with the silent-failure gate and read-back verification: The whole answer to item 2. `looksInsertable` is the pre-flight decision rule: only attempt AX insert when AXUIElementIsAttributeSettable(kAXSelectedTextAttribute) says true AND at least one readable channel exists (AXValue or AXSelectedTextRange), because without a readable channel a .success return is unfalsifiable. `insert` snapshots AXValue/AXNumberOfCharacters/AXSelectedTextRange, writes, re-reads, and returns confirmedInserted / confirmedNotInserted / cannotVerify. Only confirmedInserted stops the ladder.
- `inject--…` — PasteboardIO — byte-lossless all-types snapshot / restore, verified: Strategy B half one. VERIFIED byte-lossless against a real 2-item clipboard holding public.tiff + public.rtf + public.utf8-plain-text + public.file-url. Two traps baked in: derived flavors (public.utf16-external-plain-text) appear in item.types but data(forType:) returns nil and the pasteboard regenerates them, so they must be excluded or a perfect restore looks lossy; and promise types cannot be captured at all. writeTransient marks our item with nspasteboard.org types so clipboard managers skip it.
- `inject--…` — PasteInject — modifier-clean synthetic Cmd-V with verify-then-restore: Strategy B half two, plus the answers to the timing and modifier-contamination questions. waitForCleanModifiers polls CGEventSource.flagsState(.combinedSessionState) until the physically-held push-to-talk key is released (never call flagsState(.privateState) — it hangs forever). Events come from a .privateState source with an independent modifier state table, and .flags is ASSIGNED (not OR'd) so nothing leaks in. pasteVerified runs the verify poll BETWEEN posting and restoring, so the poll doubles as an adaptive settle delay; restore is skipped entirely if changeCount moved, which is how you avoid clobbering a clipboard manager.
- `inject--…` — PostInjectVerifier — the only success signal Strategy B and C have: CGEvent.post returns Void and drops events silently when untrusted (measured: postCommandV returned true while the process was untrusted and nothing happened). So fingerprint the focused AX element before posting and poll it after. This works even in apps where WRITING AXSelectedText is a silent no-op, because those apps still READ correctly — Chromium exposes AXValue on input/textarea, Monaco exposes AXNumberOfCharacters on its hidden textarea. Returns nil when the element exposes nothing readable.
- `inject--…` — Keycodes — layout-aware lookup for the 'v' key: Hardcoding kVK_ANSI_V (9) is a destructive bug: on Dvorak keycode 9 is '.', on some layouts it is 'w', and Cmd-W in a browser closes the tab. Scan every virtual keycode with UCKeyTranslate against the user's current layout. VERIFIED: returns v=9, a=0, z=6, q=12 on this machine's layout, and layout data is available.
- `inject--…` — UnicodeInject — Strategy C with grapheme-safe chunking: Last-resort synthetic Unicode typing. The chunker splits on grapheme-cluster boundaries, which is mandatory: chunking by raw UTF-16 index cuts surrogate pairs, combining sequences, regional-indicator flags and ZWJ families in half and produces tofu. VERIFIED lossless over a ZWJ family emoji + JP flag + combining Latin, CJK, and long ASCII. Flags are cleared to [] so a held push-to-talk modifier cannot turn every character into a menu shortcut.
- `inject--…` — InjectLadder + AppPolicy — the recommended fallback ladder: Item 5. Gate on AXIsProcessTrusted() first (never infer permission from an AXError). Identify the frontmost app via NSWorkspace.shared.frontmostApplication for the per-bundle-id override. Rung 1 AX-with-proof, rung 2 pasteboard+Cmd-V with AX post-verify, rung 3 opt-in Unicode typing, rung 4 leave it on the clipboard and TELL THE USER. Only confirmedInserted stops rung 1; cannotVerify falls through, which is the whole point.

---

## Microphone capture and the analyzer audio bridge

**Verified:** True

### Summary

Built and ran a Swift 6 SwiftPM package at <scratch> (14 probe subcommands, zero warnings in Swift 6 language mode) and proved the whole mic->transcript path end to end on this machine. Hardware input format is device-dependent and must be read at runtime: the current default input (AirPods Pro) reports 24000 Hz / 1 ch / Float32 / non-interleaved; MacBook Pro Microphone and the two virtual devices report 48000 Hz. SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:[SpeechTranscriber(locale:en-US)]) returns 16000 Hz / 1 ch / **Int16 / interleaved** / isStandard=false (the only other compatible format is the same at 8000 Hz), so AVAudioConverter is ALWAYS required — it is both a sample-rate change and a float32->int16 + deinterleaved->interleaved change. A reused AVAudioConverter with capacity = ceil(inFrames * outSR/inSR) + 32 and the one-shot input-block pattern converts a 170 ms tap buffer in <=125 us and returns .inputRanDry (normal, not an error); over 14 s it produced 4.094 s of output per 4.096 s of input (converter priming only). The tap block does NOT run on a real-time render thread (measured: non-main, QOS_CLASS_DEFAULT, sched_priority 31, SCHED_OTHER, 2 distinct tids over 15 callbacks) and heap allocation there costs 12-49 us while AsyncStream.Continuation.yield costs <=50 us, so yielding directly from the tap is safe and no lock-free hop is needed. Tap buffers are freshly allocated per callback and own their data — retaining 40/40 buffers over 4 s produced 40 distinct objects, 40 distinct mData pointers and zero content changes — but you convert into your own buffer anyway, so the copy question is moot in the real pipeline. installTap's bufferSize is advisory and hard-clamped to [100 ms, 400 ms] (verified: 1200 frames -> 2400; 12000 and 24000 frames -> 9600), which caps per-buffer metering at 2.5-10 Hz and forces UI-side ballistics. Starting the engine on keydown loses only 14-27 ms of real audio (fresh engine) or 22-40 ms (cached engine reused across stop/start) measured from AVAudioTime.hostTime of the first buffer's first sample; time-to-first-*delivery* is 115-240 ms but that is chunking latency, not loss. NOTE: the e2e probe recorded ambient speech from a live conversation in the room and transcribed it accurately (proof the pipeline works); I have not reproduced any of that content and the transcript file lives only in the scratchpad task log.

### Traps

**`AVAudioEngine().inputNode.outputFormat(forBus: 0)` — the idiomatic one-liner for reading the hardware format — SEGFAULTS. Crash report: EXC_BAD_ACCESS in AVAudioIONodeImpl::GetOutputFormat via -[AVAudioNode outputFormatForBus:]. The temporary engine is released before the node method runs.**

> Bind the engine to a local and keep it alive: `let e = AVAudioEngine(); let f = e.inputNode.outputFormat(forBus: 0); withExtendedLifetime(e) {}`. See EdictFormat.hardwareInputFormat().

**Conversion is NOT optional here and it is not just a resample. Hardware gives 24000 Hz Float32 non-interleaved (AirPods) or 48000 Hz (built-in); bestAvailableAudioFormat gives 16000 Hz **Int16 INTERLEAVED**, isStandard=false. A naive implementation that yields the raw tap buffer, or that only resamples, feeds the analyzer garbage.**

> Always build an AVAudioConverter when `hwFormat != analyzerFormat` and let it do rate + depth + interleaving in one step. Verified round-trip: 4.096 s in -> 4.094 s out.

**`AVAudioConverterInputBlock` is annotated NS_SWIFT_SENDABLE in AVAudioConverter.h (and so is AVAudioConverter itself), so under Swift 6 the input block is @Sendable and CANNOT capture the non-Sendable AVAudioPCMBuffer or a mutable `var supplied = false`. You get 'capture of input with non-Sendable type' plus 'mutation of captured var in concurrently-executing code'.**

> Route the buffer and the one-shot flag through a small `final class ... : @unchecked Sendable` box (OneShotFeed above). The block runs synchronously inside convert(), so this is genuinely race-free.

**`installTap(onBus:bufferSize:format:)`'s bufferSize is advisory and hard-clamped to [100 ms, 400 ms] (documented in AVAudioNode.h, verified: 1200 frames -> 2400 delivered; 2400 -> 2400; 4800 -> 4800; 9600 -> 9600; 12000 -> 9600; 24000 -> 9600). You cannot get sub-100 ms buffers, so per-buffer level updates arrive at only 2.5-10 Hz.**

> Request 4800 frames (100-200 ms depending on device rate). Never animate the VU needle from the tap — the needle would move in 100-400 ms steps. Store latest RMS/peak in a Mutex and run the ballistics on a 60 Hz UI tick.

**Passing an explicit AVAudioFormat to installTap after anything changed the device throws an UNCATCHABLE ObjC exception ('Failed to create tap due to format mismatch') that aborts the process — Swift cannot catch NSException.**

> Pass `format: nil` (use the bus's own format) and read the real format off `buffer.format` inside the callback.

**AVAudioEngine cannot be pinned to a non-default input device on this OS. Setting kAudioOutputUnitProperty_CurrentDevice or calling inputNode.auAudioUnit.setDeviceID() makes inputFormat report the new rate (48000) while outputFormat stays at the old rate (24000), and engine.start() then fails with -10868 (kAudioUnitErr_FormatNotSupported, AUGraphParser::InitializeActiveNodesInInputChain). All four orderings tried failed (set-then-read, read-then-set, set-before-any-format-read, explicit connect to a sink mixer).**

> Do not offer a device picker that changes the engine's device. Use the system default input device, read its format at runtime, and rebuild the entire AVAudioEngine + AVAudioConverter when AVAudioEngineConfigurationChangeNotification fires.

**`Notification.Name.AVAudioEngineConfigurationChange` has rawValue "AVAudioEngineConfigurationChangeNotification" — not "AVAudioEngineConfigurationChange". Hand-typing the obvious string produces an observer that never fires, and the engine silently stays stopped forever after a route change.**

> Use the typed constant `.AVAudioEngineConfigurationChange`. Also: AVAudioEngine.h explicitly warns the engine must NOT be deallocated inside the handler (internal dispatch queue, deadlock on synchronous teardown) — bounce to the main actor.

**`.bufferingNewest(n)` discards the OLDEST queued element, not the newest. Verified with ints: policy newest(3), yielding 1...8, the consumer saw [6, 7, 8] and yield returned .dropped(1) ... .dropped(5). For dictation that means a consumer stall silently deletes the BEGINNING of the utterance and the transcript looks like a model failure. `.bufferingOldest(3)` is worse — consumer saw [1, 2, 3] and everything after was discarded.**

> Use `.bufferingNewest(N)` sized in SECONDS not in 'a small n'. 16 kHz mono Int16 is 32 KB/s, so 100 s of headroom costs ~3 MB. Count `.dropped` in the tap and surface a 'transcript may be incomplete' flag whenever it is non-zero. Confirmed working: with capacity 4 and a 6x-slow consumer, 27 of 37 buffers were dropped; with capacity 100, zero drops.

**AssetInventory.status(forModules:[SpeechTranscriber(en-US)]) returns `.supported`, NOT `.installed`, even though SpeechTranscriber.installedLocales lists en_US (plus en_GB/AU/CA/IE/IN/NZ/SG/ZA) and transcription works perfectly. Gating startup on `status == .installed` would show a bogus 'downloading model' state forever.**

> Call `AssetInventory.assetInstallationRequest(supporting:)`; if it returns nil the assets are ready. Do not branch on `status`.

**TCC identity: the SAME binary reports `.authorized` when run from a terminal (responsible process is the terminal, which already has mic access; bundleIdentifier is nil, no Info.plist, no prompt) and `.notDetermined` when the .app is launched via LaunchServices (`open`, ppid=1). Probe results about permissions from a CLI are therefore meaningless for the shipping app.**

> Test permission behavior only from a real .app launched by LaunchServices/Finder. NSMicrophoneUsageDescription is mandatory in the bundle or TCC kills the process on requestAccess.

**With no Developer ID on this machine (`security find-identity -v -p codesigning` => 0 valid identities), the ad-hoc designated requirement is literally `cdhash H"..."`. Verified: re-signing after a rebuild changed the cdhash from 98eb5941... to 3b26b521.... TCC keys the grant to that cdhash, so EVERY rebuild is a new TCC subject and macOS will re-prompt for Microphone (and later Accessibility, which Edict also needs for text injection).**

> Create a self-signed code-signing certificate in the login keychain and sign with a stable `--identifier`, so the designated requirement becomes identifier+cert rather than a per-build cdhash. NOT verified empirically (would require creating a keychain certificate); budget a probe for it, and expect repeated permission prompts during development regardless.

**Reusing one AVAudioEngine across stop()/start() is SLOWER than building a fresh one, not faster: audio lost was 22-40 ms (cached) vs 14-27 ms (fresh), and time-to-first-buffer p50 was 141 ms vs 116 ms over 8 trials each.**

> Do not cache a stopped engine as a latency optimization. Either keep the engine RUNNING (pre-warm) or build a fresh one per utterance.

**AVAudioTime.hostTime is mach_absolute_time TICKS, not nanoseconds. Dividing by 1e9 produced a 393,652,633 ms 'capture time'. On Apple silicon the timebase is 125/3.**

> Use `AVAudioTime.seconds(forHostTime:)`. It shares the epoch with DispatchTime.uptimeNanoseconds, so the two are directly comparable. `when.isSampleTimeValid` is true and `sampleTime` restarts at 0 on every engine.start().

**The tap block's AVAudioPCMBuffer object identity is NOT stable, and it can be delivered on more than one thread over the life of a session (2 distinct pthread tids over 15 callbacks, though never concurrently).**

> Never use thread-local state in the tap. Guard every piece of shared state with a lock (Synchronization.Mutex works fine here — measured cost is trivial against a 100 ms buffer period).

### Recommendations

- PRE-WARM THE ENGINE AND GATE THE STREAM — but make it a user-visible mode, not the default. Measured facts: starting on keydown loses only 14-27 ms of real audio (fresh engine, from AVAudioTime.hostTime of the first buffer's first sample vs the engine.start() call). A pre-warmed engine loses 0 ms and additionally gives you a free pre-roll (verified: 1.0 s of pre-keypress audio sitting in a ring buffer at the moment of the simulated keypress). The privacy cost is that the orange mic indicator in the menu bar stays lit for the entire session, which for a dictation tool reads as 'this app is always listening' and is the single most likely reason a user uninstalls it. RECOMMENDATION: default to start-on-keydown (mic indicator only lit while the key is held; 14-27 ms of clipped leading audio is well inside human press-then-speak reaction time), and offer a 'Low-latency mode (mic stays active)' preference that pre-warms plus flushes a 300-500 ms pre-roll for users who complain about clipped first syllables.
- Do not fight the 100 ms tap granularity. Request bufferSize 4800 (200 ms at 24 kHz, 100 ms at 48 kHz). Transcription does not care — SpeechTranscriber emitted volatile results continuously with 170 ms buffers. The only consumer that cares is the VU meter, which must interpolate.
- VU BALLISTICS (validated numerically at a 60 Hz tick): one-pole `needle += (target - needle) * (1 - exp(-dt/tau))` with attackTau = 0.065 s reaches 0.9901 of full deflection at exactly 300 ms, matching the ANSI C16.5 VU integration time. Use releaseTau = 0.150 s (needle falls to 0.0164 in 600 ms) for a needle that does not chatter, or set releaseTau = attackTau for a spec-exact symmetric VU. Map -54 dBFS (rest) to 0 dBFS (full deflection) onto the sweep; mark '0 VU' at -18 dBFS (needle 0.667) and the red zone above -6 dBFS (needle 0.889). Peak indicator: hold 1.5 s then fall at 20 dB/s (verified decaying from 1.000 to 0.473 over the following 1.3 s). Measured room/voice levels for calibration: quiet room RMS -61 to -48 dBFS, speech RMS -18 to -13 dBFS, peaks up to +1.7 dBFS.
- UPDATE RATE: run the ballistics on a 60 Hz main-actor tick reading the last RMS/peak out of a Mutex. Driving the same ballistics from the tap instead reaches full deflection in 8 callbacks (683 ms) in visible 100-400 ms steps — proven in the probe. The tap writes a `(rmsDB, peakDB, seq)` struct under a lock at 2.5-10 Hz; the UI interpolates. Do NOT publish an @Observable/@Published value per buffer and do NOT publish per UI frame from the audio side.
- YIELD DIRECTLY FROM THE TAP. No hop needed. The tap is not a real-time render thread — measured non-main, QOS_CLASS_DEFAULT, sched_priority 31, SCHED_OTHER; an AVAudioPCMBuffer allocation inside it costs 12-49 us and AsyncStream.Continuation.yield costs <= 50 us, against a >= 100 ms budget. Adding a lock-free ring + dispatch hop would only add latency and a second failure mode.
- COPY QUESTION, DEFINITIVE ANSWER: you do not have to copy, but in Edict you always will anyway. AVAudioNode.h documents the tap block as receiving 'copies of the output of an AVAudioNode', and empirically retaining all 40 tap buffers over 4 s produced 40 distinct objects, 40 distinct mData pointers, and 0 content changes — the engine allocates a fresh buffer per callback that owns its data. (Earlier confusion: with only 8 buffers pinned, 17 callbacks showed 9 distinct addresses — that is malloc reusing freed addresses, not the engine reusing a live buffer.) Since the analyzer format differs from hardware, every buffer goes through AVAudioConverter into a buffer you allocated, so the yielded buffer is yours by construction. Rule for the codebase: NEVER yield or store the tap's buffer object; always yield the converter output (or EdictCapture.deepCopy for the no-conversion path).
- ONE AVAudioConverter INSTANCE, reused across every buffer of an utterance, touched only from the tap. Creating a converter per buffer resets the polyphase resampler state and inserts a discontinuity at every 100-400 ms boundary. Create a fresh converter whenever you rebuild the engine (device change), because the input format changed.
- Handle the `bestAvailableAudioFormat == nil` case by falling back to `transcriber.availableCompatibleAudioFormats` (returns [16 kHz Int16, 8 kHz Int16] here; pick the highest rate) and only then to the hardware format unchanged. Never force-unwrap it.
- STREAM LIFECYCLE: one AsyncStream + one SpeechAnalyzer per utterance. `continuation.finish()` on key-up is what makes `analyzer.finalizeAndFinishThroughEndOfInput()` return; verified working over a 14 s session producing 5 final results and a complete transcript. Keep the gate flag and the continuation under a single Mutex — reading them separately races into yielding onto a finished stream.
- Instrument `dropped` and `conversionFailures` from day one and surface them in the history UI. A garbled transcript in this pipeline is almost always dropped buffers or a converter/format mismatch, not the model. In every clean run the counters were tapBuffers=87, yielded=87, dropped=0, convErrors=0.
- PRIVACY NOTE for the product: while running the end-to-end probe, the AirPods mic picked up and accurately transcribed a live conversation happening in the room, not the synthesized test phrase. This is direct evidence of how much a pre-warmed mic captures. Whatever mode you ship, the history store must be local-only and easy to purge, and 'delete this transcript' should be one click.

### Still unknown

- Built-in MacBook Pro Microphone (48000 Hz, 512-frame HW buffer, 26-frame device latency) was never measured directly — AVAudioEngine refuses to target a non-default input device (-10868), and changing the system default input is a system-settings change I did not make. All timing numbers above are AirPods Pro (24000 Hz, 480-frame HW buffer, 240-frame = 10 ms device latency, Bluetooth). Expect the built-in mic to lose LESS than the measured 14-27 ms on keydown, and to deliver 100 ms rather than 200 ms buffers for a bufferSize of 4800. Re-run `probe-audio loss` and `probe-audio clamp` with the built-in mic as system default before finalizing the pre-warm decision.
- Whether a self-signed (non-ad-hoc) code-signing certificate actually stabilizes the TCC designated requirement across rebuilds. Verified that ad-hoc gives `designated => cdhash H"..."` and that the cdhash changes every rebuild; the fix is inferred, not tested, because it requires creating a keychain certificate.
- Behavior when the input device disappears mid-utterance (AirPods disconnect, USB mic unplug). AVAudioEngine.h says the engine stops itself and posts AVAudioEngineConfigurationChangeNotification, and EdictCaptureHost is written for that, but the notification was never observed firing — no hardware was unplugged. Also unknown: whether the in-flight SpeechAnalyzer should be finalized or cancelled on that path.
- Virtual and aggregate input devices (conferencing loopbacks, camera-app audio) can become the system default input while their host app is running, and at least one on the test machine reported a 6000-frame (125 ms) device latency. A device with that much latency would change the keydown-audio-loss numbers substantially. Untested.
- AnalysisContext.contextualStrings was set ([.general: [...]]) and did not error, but its effect on the user dictionary was not measured — no probe drove known-hard words through it. That belongs to the dictionary-correction probe, not this one.
- Whether SpeechAnalyzer tolerates a gap in the input stream (gate closed then reopened on the same stream) or whether a fresh analyzer per utterance is mandatory. The reference implementation creates a new stream + analyzer per utterance, which sidesteps the question but costs whatever prepareToAnalyze() costs on each keypress (not separately timed).

### Verified snippets

- `audio--…` — Package.swift: SwiftPM manifest that compiles Speech + AVFAudio under Swift 6 strict concurrency on this toolchain.
- `audio--…` — EdictAudio.swift (full reference implementation): Complete, compiled, and RUN mic->converter->AsyncStream<AnalyzerInput>->SpeechAnalyzer bridge plus VU metering, permission, and device-change handling. `probeReference` is the smoke test that actually produced a transcript. Zero warnings in Swift 6 language mode.
- `audio--…` — Ring-buffer pre-roll (pre-warmed engine): Proves a pre-warmed engine gives you audio from BEFORE the keypress for free. Ran: 'at simulated keypress: ring holds 24000 frames = 1.0 s of PRE-KEYPRESS audio'. Fold this into EdictCapture.handleTap so beginUtterance() can flush the pre-roll into the stream first.
- `audio--…` — Info.plist for the .app (verified by building and ad-hoc signing a real bundle): Minimum keys for the mic prompt to work. Verified: the same binary reports .authorized when launched from a terminal and .notDetermined when launched via LaunchServices, so only the real .app path exercises the prompt.

---

## Building a real, permission-stable .app

**Verified:** True

### Summary

Built, signed, installed and LAUNCHED a real SwiftUI .app from a bare SwiftPM executable target on this exact machine (macOS 27.0 / Xcode 26.5 / Swift 6.3.2, zero signing identities). Confirmed window + Dock-regular activation policy + full app menu (["Edict","File","Edit","View","Window","Help"]) + a simultaneous NSStatusItem, all with LSUIElement absent. Ad-hoc signing works but its designated requirement is `cdhash H"..."` ONLY, so TCC forgets Accessibility/Input-Monitoring on every rebuild; worse, clean rebuilds of identical source are NOT bit-identical (the linker embeds the .o mtime in the N_OSO debug-map stabs, which then perturbs LC_UUID). `-Xlinker -S` makes the build byte-reproducible and the cdhash stable across 3 clean rebuilds — but `-Xlinker -no_uuid` is a trap: dyld on macOS 27 refuses to load ("missing LC_UUID load command"). The real answer is a locally generated self-signed cert: creatable fully non-interactively with NO sudo and NO admin password, and its DR is `identifier "com.edict.app" and certificate root = H"<cert sha1>"` — invariant across source changes, verified by mutating source and rebuilding. Two hard non-obvious blockers found: (1) `security set-key-partition-list` is mandatory or `codesign` hangs forever on an invisible GUI keychain prompt, and `security find-identity -v -p codesigning` still reports "0 valid identities" even though signing works (the cert is untrusted — CSSMERR_TP_NOT_TRUSTED — and trusting it via `add-trusted-cert` DOES need an interactive admin prompt, which is unnecessary); (2) SwiftPM `resources:`/`Bundle.module` is fundamentally incompatible with a signed .app, because the generated accessor looks for `<App>.app/<Target>_<Target>.bundle` at the bundle ROOT and codesign then fails with "unsealed contents present in the bundle root". Icon pipeline (CoreGraphics PNG -> sips -> iconutil -> .icns) works and the icon renders in the Dock with the system's standard shadow treatment.

### Traps

**A file named `main.swift` makes `@main struct EdictApp: App` a hard compile error: "'main' attribute cannot be used in a module that contains top-level code".**

> Name the file anything else (EdictApp.swift). Verified.

**Declaring `resources: [.process("Resources")]` on the app target generates `Bundle.module`, whose accessor resolves to `Bundle.main.bundleURL/Edict_Edict.bundle` — i.e. `Edict.app/Edict_Edict.bundle`, at the bundle ROOT. Putting it there makes codesign fail outright: "ProbeBundle.app: unsealed contents present in the bundle root", exit 1. So SwiftPM resource bundles and a signable .app are mutually exclusive.**

> Do not declare `resources:` on the app target. Keep asset files OUTSIDE Sources/ (e.g. a top-level Resources/ dir) and have build-app.sh copy them into Contents/Resources; read them with Bundle.main. Note that `Bundle.module` also stops compiling when no resources are declared ("type 'Bundle' has no member 'module'"), which is a useful tripwire.

**The Bundle.module accessor has a HARDCODED ABSOLUTE FALLBACK to the .build directory. Verified: an assembled .app with no resource bundle at its root silently resolved `Bundle.module` to `/private/tmp/.../.build/arm64-apple-macosx/release/Edict_Edict.bundle`. It works on the dev machine and `fatalError`s ("could not load resource bundle") anywhere else, or after `rm -rf .build`.**

> Never rely on Bundle.module in a hand-assembled .app. Use Bundle.main only.

**Clean rebuilds of byte-identical source do NOT produce byte-identical binaries. Three clean builds gave three different sha256s and three different cdhashes. Root cause located precisely: 115 differing bytes, of which the meaningful ones are a little-endian unix timestamp (0x6a8bb61e vs 0x6a8bb62b) in the N_OSO debug-map stabs — the .o file mtime — plus the derived LC_UUID and the linker's own ad-hoc signature.**

> `swift build -c release -Xlinker -S` -> bit-identical across 3 clean rebuilds. (`-Xswiftc -gnone` also works.) With a self-signed cert this does not matter at all, so only bother if you insist on ad-hoc signing.

**`-Xlinker -no_uuid` is a trap. It DOES make the binary reproducible (verified identical sha256 x3), but the resulting app will not run: `dyld[83827]: missing LC_UUID load command in .../Contents/MacOS/ProbeApp`.**

> Use `-Xlinker -S` instead, which keeps a real (and now deterministic) LC_UUID. Note `-Xlinker -S` prints a harmless `warning: no debug symbols in executable (-arch arm64)` from dsymutil and yields no usable dSYM.

**Ad-hoc signing pins the TCC identity to the binary hash. `codesign -d -r-` on an ad-hoc-signed .app yields `designated => cdhash H"..."` and nothing else — no identifier clause. Any source change therefore makes macOS treat the app as a different program and silently drop Accessibility / Input Monitoring.**

> Sign with a local self-signed cert instead. Verified DR becomes `identifier "com.edict.app" and certificate root = H"<cert sha1>"`, which stayed byte-identical across a clean rebuild AND across a deliberate source mutation (cdhash changed from 48473a91… to 9c491e79…, DR unchanged).

**`codesign -s "Edict Local Signing"` HANGS FOREVER (killed at 25s and 30s) after printing "replacing existing signature". It is blocked on an invisible/orphaned GUI keychain-access prompt (SecurityAgent spawns). `security import ... -A -T /usr/bin/codesign` alone is NOT enough on this OS.**

> Run `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PW" "$KEYCHAIN"` after importing. With that one line, codesign completes instantly and non-interactively. This is why the identity must live in a DEDICATED keychain with a script-known password — doing it in login.keychain would require the user's real login password.

**`security find-identity -v -p codesigning` still reports "0 valid identities found" with the working self-signed cert installed — because the cert is untrusted (`security find-identity -p codesigning` without -v shows `1) 54145D02… "Edict Local Signing" (CSSMERR_TP_NOT_TRUSTED)`). This looks like failure but is not.**

> Ignore find-identity -v; it is not the right check. Codesign works fine with an untrusted codeSigning cert. Do NOT try to fix it with `security add-trusted-cert`: attempted in the user domain (no -d, no sudo) and it hung on a GUI authorization prompt until killed at 25s, leaving an orphaned SecurityAgent dialog and no trust settings written. Trust is unnecessary. If you ever genuinely want it, that command needs the user to type their password: `security add-trusted-cert -d -r trustRoot -p codeSign -k /Library/Keychains/System.keychain <cert.pem>` (requires sudo — hand it to the user, do not automate).

**An interrupted/killed codesign run leaves a `Contents/MacOS/Edict.cstemp` file that gets sealed into CodeResources, after which `codesign --verify --strict` fails with "a sealed resource is missing or invalid / file missing: …Edict.cstemp".**

> `find "$APP" -name '*.cstemp' -delete` immediately before signing (in the script), or rebuild the bundle from scratch each time (the script does `rm -rf "$APP"`).

**Setting `LSUIElement` to true flips `NSApp.activationPolicy()` from .regular to .accessory: no Dock icon and no menu bar. Verified by A/B test on the signed app.**

> Leave LSUIElement out entirely. An NSStatusItem menu-bar extra needs no plist key at all — the probe showed activationPolicy=regular, a full 6-item app menu, the main window, AND the status item simultaneously (NSApp.windows.count == 2, an AppKitWindow at level 0 plus NSStatusBarWindow at level 25). If you later want to hide the Dock icon at runtime, call NSApp.setActivationPolicy(.accessory) instead.

**Removing CFBundleIdentifier does NOT stop the app from launching — it launches happily with `Bundle.main.bundleIdentifier == nil`. That silently destroys the TCC identity, UserDefaults suite scoping, `open -b`, and single-instance behaviour. A/B tested: every other plist key (NSPrincipalClass, LSApplicationCategoryType, CFBundleName, CFBundlePackageType, LSMinimumSystemVersion, CFBundleInfoDictionaryVersion, NSHighResolutionCapable, even CFBundleExecutable) could be removed and the app still launched as a regular app.**

> Treat CFBundleIdentifier as the one load-bearing key and assert on it in a smoke test. Keep the rest anyway (NSPrincipalClass=NSApplication and NSHighResolutionCapable are conventional; LSApplicationCategoryType only affects Finder/App-Store categorisation and is cosmetic here).

**Signing with `com.apple.security.app-sandbox = true` gives the app a container: NSHomeDirectory() was redirected to ~/Library/Containers/com.example.probebundle/Data, and that directory is unreadable AND UNDELETABLE from a normal shell ("Operation not permitted" even for rm -rf).**

> Ship non-sandboxed (app-sandbox = false), and never even test-sign a sandboxed build using the production bundle id — the stale container survives and can only be removed from Finder or by a process with Full Disk Access. I left one behind at ~/Library/Containers/com.example.probebundle from this probe; the user can delete it in Finder.

**Running the executable directly (`swift run` / `.build/release/Edict`) is NOT a valid dev loop for this app: verified bundleIdentifier=nil, all Info.plist keys nil, Bundle.main resources MISSING, and activationPolicy=.accessory (no Dock icon, no real menu bar).**

> Always iterate through ./scripts/build-app.sh. Incremental swift build + reassemble + re-sign takes ~1s here.

**`spctl -a -t exec Edict.app` reports `rejected / origin=Edict Local Signing` — a self-signed app is not notarized.**

> Irrelevant for a locally built app: `xattr -l` showed no com.apple.quarantine, so Gatekeeper is never consulted and `open` works. It only bites if the .app is zipped/AirDropped/downloaded; then the recipient needs right-click > Open once, or `xattr -dr com.apple.quarantine Edict.app`. The build script already runs `xattr -cr` before signing.

**`iconutil -c icns` fails with the unhelpful "Edict.iconset:Failed to generate ICNS." if any of the ten expected filenames is wrong or missing (I hit it when a shell quoting bug produced a single file literally named ".png").**

> Emit exactly icon_16x16, icon_16x16@2x, icon_32x32, icon_32x32@2x, icon_128x128, icon_128x128@2x, icon_256x256, icon_256x256@2x, icon_512x512, icon_512x512@2x. Avoid `set -- $spec` inside the loop under zsh; the make-icon.sh here uses a `while read name px` heredoc instead.

**SwiftPM emits `warning: 'edict': found 1 file(s) which are unhandled; explicitly declare them as resources or exclude from the target` for any non-source file left under Sources/.**

> It is only a warning, but keep assets in a top-level Resources/ directory outside Sources/ so it never appears. (Alternative: `exclude:` in the target.)

**`NSStatusBarWindow` is not a public type — `$0 is NSStatusBarWindow` is "cannot find type ... in scope".**

> Filter with `NSApp.windows.first { $0.canBecomeMain }` to find the real app window.

**Using `osascript -e 'tell application id "..." to quit'` in the build script to close a running copy would trigger a macOS Automation consent prompt for the terminal.**

> Use SIGTERM to the pids from `pgrep -f "/Edict\.app/Contents/MacOS/Edict"`, poll for exit, then SIGKILL as a fallback. No permission needed. The pgrep pattern deliberately matches both ./build/Edict.app and ~/Applications/Edict.app.

**`--options runtime` (Hardened Runtime) enables library validation, so the app can then only load code signed by the same certificate or Apple.**

> Fine for Edict (system frameworks only), and verified the app launches with it and the DR is identical with or without it. If you ever load a third-party dylib or plugin, either drop `--options runtime` or add `com.apple.security.cs.disable-library-validation`.

### Recommendations

- Deliver via a hand-assembled .app + a stable SELF-SIGNED certificate, not ad-hoc. This is the single highest-value decision: it makes the TCC designated requirement `identifier "com.edict.app" and certificate root = H"..."`, so the Accessibility and Input Monitoring grants survive every rebuild, and it means you do not need reproducible builds at all (keep your debug symbols).
- Provision the identity into a DEDICATED keychain (~/Library/Keychains/edict-signing.keychain-db) with a password baked into the script, and always follow `security import` with `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <pw> <keychain>`. Pass `--keychain <path>` to codesign so the user's keychain search list is never modified (verified working with the keychain absent from the search list). Zero sudo, zero GUI prompts, verified from a completely clean state.
- Back up (or commit, encrypted) the .p12 of that certificate — or at least document that deleting the keychain forces a new cert and therefore a one-time re-grant of Accessibility/Input Monitoring. This is now the only thing that can break the dev loop.
- Never declare `resources:` on the app target. Put assets in a top-level Resources/ dir, copy them into Contents/Resources in build-app.sh, and read them with Bundle.main. Add a startup assertion that Bundle.main.bundleIdentifier != nil and that a known seed resource resolves, so a broken bundle fails loudly instead of at first use.
- Ship non-sandboxed with `com.apple.security.app-sandbox = false`, `com.apple.security.device.audio-input = true` (required by the hardened runtime, harmless otherwise), and `com.apple.security.automation.apple-events = true` only if you actually fall back to AppleEvents for text insertion. Do not test-sign a sandboxed build with the production bundle id — the container it creates is undeletable from a shell.
- Do not set LSUIElement. Edict is a regular windowed app that also shows a menu-bar extra; both were verified to coexist with activationPolicy == .regular. Use NSApp.setActivationPolicy(.accessory) at runtime if you later want an optional "hide Dock icon" preference.
- Install to ~/Applications with `ditto` (preserves the signature), then `lsregister -f` so Finder/Dock pick up the new icon and Info.plist. Grant permissions against the installed path, not ./build, so the path shown in System Settings is stable.
- Have build-app.sh refuse to overwrite a running copy: pgrep on the executable path, prompt when on a tty, `die` when not, and honour EDICT_KILL=1 for CI/agents. Both branches were exercised.
- Keep the CoreGraphics icon generator in-repo (scripts/make-icon.sh) rather than committing a binary .icns; it regenerates in ~2s, needs no design assets, and the build script auto-invokes it when Resources/AppIcon.icns is missing.
- Do not iterate with `swift run` — a bare binary has no bundle identifier, no Info.plist, no resources, and comes up as an .accessory app. Make ./scripts/build-app.sh the only way anyone launches Edict.

### Still unknown

- I did NOT empirically confirm that a TCC grant actually persists across a rebuild, because granting Accessibility/Input Monitoring requires the user to click in System Settings. The evidence is strong but indirect: `codesign -d -r-` shows the designated requirement is cert+identifier based and stayed byte-identical across a clean rebuild and a deliberate source change. Worth a 2-minute manual confirmation: grant Accessibility, rebuild, re-check that AXIsProcessTrusted() is still true.
- Whether `com.apple.security.device.audio-input` is strictly required for mic access on a NON-sandboxed app under `--options runtime` was not tested, because doing so would pop a microphone consent dialog at the user. It is included (harmless) and verified to embed correctly. If the mic probe elsewhere in this project already exercised AVAudioEngine input from an .app, that answers it.
- Whether CGEventTapCreate / AXUIElement text injection works under this exact self-signed + hardened-runtime configuration was not exercised here (it needs Input Monitoring and Accessibility grants). The non-sandbox requirement is established from the sandbox container redirection, not from a failed tap.
- macOS 26+ also supports the new Icon Composer `.icon` asset format. The classic `.icns` route works and the system applies its standard shadow/masking treatment, but I did not test whether a `.icon` file yields a better result on Tahoe-style icon rendering (liquid glass / tinted modes).
- `-Xlinker -S` discards debug symbols and produces no usable dSYM (`warning: no debug symbols in executable`). With the self-signed-cert route it is unnecessary, so this only matters if you want BOTH ad-hoc signing and symbolicated crash reports — in that case you would need to patch LC_UUID to a content-derived value post-strip, which I did not build.
- Leftover from this probe that I could not remove: ~/Library/Containers/com.example.probebundle (created by the sandbox A/B test; "Operation not permitted" from a shell). Delete it from Finder if you want a clean machine. Everything else was cleaned up: keychains removed, keychain search list restored to the original two entries, ~/Applications/Edict.app removed, `security find-identity -v -p codesigning` back to 0 identities.

### Verified snippets

- `bundle--…` — Package.swift: SwiftPM manifest for a GUI app target. Note: NO `resources:` — declaring them creates Bundle.module, which cannot live inside a signable .app.
- `bundle--…` — Sources/Edict/EdictApp.swift: Minimal @main SwiftUI app + AppDelegate with an NSStatusItem menu-bar extra, compiled in Swift 6 language mode and verified to launch as a regular Dock app. FILENAME MUST NOT BE main.swift.
- `bundle--…` — Resources/Edict.entitlements: Minimal entitlements. MUST be non-sandboxed. Verified to embed correctly and the app runs with them, with and without --options runtime.
- `bundle--…` — Contents/Info.plist (generated): The complete Info.plist that was actually signed and launched. Empirically: only CFBundleIdentifier is truly load-bearing (removing it leaves Bundle.main.bundleIdentifier == nil, which destroys TCC identity); every other key here is optional for launch but keep them all.
- `bundle--…` — scripts/make-icon.sh: Generates Resources/AppIcon.icns from nothing (no design assets). Verified: renders, converts, and the Dock shows it with the system shadow treatment.
- `bundle--…` — scripts/build-app.sh: swift build -> signed, launchable Edict.app, plus `install` to ~/Applications. Ran end-to-end from a totally clean state (no keychain, no .build, no icon): bootstraps the signing identity, builds, generates the icon, signs, installs, verifies. Idempotent (3 consecutive runs -> identical designated requirement), no sudo, no GUI prompts.
- `bundle--…` — ad-hoc fallback (only if you refuse the cert): If you insist on ad-hoc signing, this is the ONLY way to keep the cdhash (and therefore TCC grants) stable across clean rebuilds of identical source. Verified: 3 clean rebuilds -> identical bundle cdhash 43c1fdeb17a62a0c17791d801eb9d7a4e7042825.

---

## File transcription — module choice, measured (integration pass)

**Verified:** True — measured on this machine during the file-import integration, with a probe that
ran both modules over the same files through `SpeechAnalyzer(inputAudioFile:)`, and then end to end
through the shipped `Edict.app`.

### Summary

**§1's "use `DictationTranscriber`, never `SpeechTranscriber`" is correct for *live dictation* and
wrong for *file import*.** The two conclusions do not conflict, because they rest on different
measurements: §1 measured vocabulary biasing (which only works on `DictationTranscriber`), and this
section measures bulk accuracy and throughput on a whole file, where biasing is not the deciding
factor and there is no speech onset to hide its setup cost behind.

Same 377 s English script (`long.aiff`, `say`-generated), same explicit
`attributeOptions: [.transcriptionConfidence, .audioTimeRange]`, word error computed by Levenshtein
against the source script:

| module                 | word error | wall  | realtime | final results |
|------------------------|-----------:|------:|---------:|--------------:|
| `DictationTranscriber` |     10.1 % | 25.0s |    15.1x |             7 |
| `SpeechTranscriber`    |  **4.2 %** |  5.7s | **66.4x**|            64 |

`DictationTranscriber` produced "It is a push to talk. Dictation tool for macOS" and "the text
appears that the cursor"; `SpeechTranscriber` produced "Edict is a push to talk dictation tool for
macOS" and "the text appears at the cursor". The ~9x higher final-result count also matters for
subtitles, since a cue can only be cut at a result boundary.

End to end through the running app (drop/`open -a`, `AVAssetReader` → the streaming
`AsyncStream<AnalyzerInput>` path → history), `SpeechTranscriber`, en-US:

| file                        | audio   | wall  | realtime | segments | note                |
|-----------------------------|--------:|------:|---------:|---------:|---------------------|
| `short-mono.wav` 16 kHz mono|   6.05s | 0.53s |    11.5x |       16 | first file, cold    |
| `short.m4a`                 |   6.05s | 0.26s |    23.1x |       16 |                     |
| `video_audio.mp4`           |   6.00s | 0.22s |    27.4x |       17 | video container     |
| `short.mp3`                 |   6.11s | 0.36s |    17.0x |       16 |                     |
| `long.m4a`                  | 377.46s | 5.00s |    75.5x |     1007 | 4.1 % word error    |
| `indonesian.aiff` (id-ID)   |  18.81s | 0.59s |    31.9x |       38 | dictation fallback  |

### Traps

**`SpeechTranscriber` covers 45 locales against `DictationTranscriber`'s 54, and Indonesian is in
the gap: `SpeechTranscriber.supportedLocale(equivalentTo: id-ID)` returns nil.** Refusing the file
would be the obvious bug; silently transcribing it with the wrong locale would be the worse one.

> `SpeechEngine.resolveImportModule(preferGeneral:localeIdentifier:)` falls back to
> `DictationTranscriber`, which transcribed an 18.8 s Indonesian clip word-perfect at 31.9x realtime.
> It also falls back when `SpeechTranscriber` supports the locale but its assets are **not
> installed** — downloading inside an import would stall a queue the user is watching for an
> unbounded time.

**On `id_ID`, `DictationTranscriber` returns `audioTimeRange` on every attribute run and
`transcriptionConfidence` on NONE of them.** Measured: 38 runs, 38 with a time range, 0 with a
confidence — with both attributes asked for explicitly. Code that requires confidence in order to
collect a run therefore drops every Indonesian word, which produces an **empty `segments` array**
and makes subtitle export impossible for that language while nothing looks broken. This was a real
bug in the first integration pass, caught only because the Indonesian file was actually run.

> Collect a run when it carries *either* attribute. `WordConfidence.confidence` is `Double?` for
> exactly this reason, and a run with no confidence is not offered to the dictionary as a
> low-confidence suggestion (`(word.confidence ?? 1) < threshold`).

**`SpeechTranscriber.TranscriptionOption` has exactly one case, `etiquetteReplacements` (profanity
masking) — there is no `.punctuation`.** It punctuates and capitalises by default; measured output
"Hold the right option key, speak, and release, and the text appears at the cursor." Do not go
looking for the option `DictationTranscriber` has.

**The named `SpeechTranscriber` presets carry the same `attributeOptions == []` problem as
`DictationTranscriber`'s** (§7). `.timeIndexedTranscriptionWithAlternatives` exists and looks like
the right thing, but the explicit initializer is still what the code uses, because it is the only way
to be sure both attributes are on.

### Recommendations

- Live dictation stays on `DictationTranscriber` — §1 stands. Imports default to `SpeechTranscriber`
  where the locale allows, with `Settings.importUsesGeneralModel` to put them back on the dictation
  model for a user who would rather have the vocabulary biasing.
- The correction pass (layer 2 of the dictionary) runs for both modules, and it is the only
  dictionary layer an import gets when the general model is in use.
- One module and one analyzer per file, never reused — §3 applies unchanged, and `ImportQueue` is
  serial partly because of it.

---

## Findings from building and running the app

Everything above came from probes written before the app existed. Everything below was found by
*running* Edict on a real machine with permissions actually granted — which is where the probes' two
biggest unknowns finally got answered, and where several things the probes could not have predicted
turned up.

### The push-to-talk key, finally observed

**Karabiner DOES preserve the left/right device bit.** This was the single highest-risk open question
in the whole project: the probe could not observe one real keystroke, and if Karabiner's DriverKit
virtual keyboard normalised the device bits, Right Option could never be distinguished. Measured with
a tap running from a terminal that holds Input Monitoring:

    press    keyCode=61  raw=0x00080140    <- 0x40 present, right Option
    release  keyCode=61  raw=0x00000100
    (left control, for comparison)  keyCode=59  raw=0x00040101

**But every synthesized event carries an extra bit: `0x100`, `kCGEventFlagMaskNonCoalesced`.** Note it
is present even on release, where all modifiers are otherwise clear. So the expected `0x00080040`
arrives as `0x00080140`.

> Consequence: **bit-test, never compare raw flag values for equality.** Any code that matches an
> expected raw word will silently never fire on a machine with a keyboard remapper. `isHeld` is a
> bit test and was correct; anything new must be too.

**A live tap is diagnosable without any permission.** `CGGetEventTapList` needs nothing, reports every
tap's owning pid, whether it is enabled, and the mask it was actually granted. On this machine a
healthy Edict reads:

    pid    enabled  mask      process
    41381  YES      0x1c00    Edict            <- keyDown|keyUp|flagsChanged, nothing stripped
    24968  YES      0x4c00    BetterTouchTool

That single call distinguishes "permission denied" (mask stripped to `0x1000`, or a dead port) from
"permission fine, bug is ours" in about a second. It is the first thing to run on any "the hotkey does
nothing" report.

### `AsyncStream` has exactly one consumer, and RESTART broke it

`HotkeyMonitor.events` returned a **single stored `AsyncStream`**. `startHotkey()` cancelled the
existing consumer task and started a new one over that same stream — so after the user pressed RESTART,
the replacement iterator received nothing, for ever.

The symptom was maximally misleading. The monitor kept working perfectly and logged so:

    hotkey armed
    hotkey released after 7365 ms

Tap alive, keycode matched, device bit intact, arm and release clean — while the controller sat behind
a dead iterator, so `begin()` was never reached and **not one error appeared anywhere**. The key simply
did nothing.

> Fix: create the consumer **once** and never cancel it on a restart. Safe because the continuations
> are finished only in the monitor's `deinit`, so one long-lived iterator survives any number of tap
> stop/start cycles. Generally: an `AsyncStream` is not a broadcast channel, and a stored one must
> never be handed to a second iterator.

### The speech session leaked, and a bounded wait was the wrong fix

Users saw "I press the key, it opens, then closes after a few seconds" — on alternating presses.

    17:24:21.717  utterance done: 3 words, injection paste
    17:24:23.836  hotkey armed
    17:24:25.395  previous session still active after 1.5 s; refusing to start a second
    17:24:27.015  hotkey armed
    17:24:27.205  capture started              <- the next press works

`activeSession` was still held **3.7 s after `utterance done`**. Root cause: `beginSession` awaits an
asset check, a format query and `prepareToAnalyze` *between* testing `activeSession == nil` and
assigning it. Two presses could both pass the gate, both build an analyzer, and the second overwrite
the first — orphaning a live analyzer and wedging the engine.

> Fix: claim the slot **before** any of those awaits. The 1.5 s ceiling that predated this is a safety
> valve for a genuinely wedged analyzer, not the fix — finalize measures 0.15–0.53 s, so a healthy
> hand-back has ~3x headroom. A first attempt that merely widened that ceiling treated a leak as a
> race and would have delayed the same failure.

### `WindowGroup` multiplies windows; use `Window`

`WindowGroup` is a *template*. Every `application(_:open:)` file-open request instantiated another copy,
and SwiftUI restored all of them on the next launch, so the count compounded — **18 windows** after a
handful of test imports. Edict has exactly one main window and is not a document app.

> Fix: a plain `Window` scene. Also purge `~/Library/Saved Application State/<bundleid>.savedState`
> once, or the accumulated windows come back.

### XML comments in an entitlements file break codesigning

`codesign` parses entitlements with `AMFIUnserializeXML`, **which rejects XML comments**, while
`plutil -lint` passes the same file happily. The failure is
`AMFIUnserializeXML: syntax error near line 10` and no `.app` gets signed at all.

> Fix: no comments in `.entitlements`. Put the rationale in the build script. `plutil -lint` is not a
> sufficient pre-flight check — grep for `<!--` as well.

### Text Input Services must be called on the main thread

`TISGetInputSourceProperty` (used for the layout-correct Cmd-V keycode lookup, RECON §15) reaches
`dispatch_assert_queue(main)` and **`SIGTRAP`s** rather than returning an error. `TextInjector` is an
actor on its own queue, so the lookup crashed the app 1.6 s after launch on every pre-warm.

> Fix: mark the keycode lookup `@MainActor` and hop for it.

### `defaults delete` does not reach a running app

`cfprefsd` serves a cached value. This invalidated an experiment and produced a confident wrong
conclusion: deleting a saved window frame and relaunching gave a byte-identical frame every time, which
was read as proof that frame restoration was not involved.

> Fix: `killall -HUP cfprefsd` after any `defaults delete`, before measuring.

### An external Accessibility client resizes this app's windows

The window is created at exactly the requested size, and then three AX writes arrive:

    _AXXMIGSetAttributeValue -> SetAttributeValue
      -> NSAccessibilityEntryPointSetValueForAttribute
      -> -[NSWindow _setFrameCommon:display:fromServer:]

snapping it to a half-screen strip. A 40-line SwiftUI app reproduces it **only once placed in a signed
`.app` bundle**, and it beats a hard `.frame(width:height:)`, so no layout change prevents it. This
machine runs BetterTouchTool with snap areas enabled; the attribution is circumstantial but the
mechanism is proven.

> **Do not add code that fights the user's window manager** by re-asserting a size on a timer. That was
> tried during diagnosis and is not shippable. Diagnose window-size complaints by attaching a
> `didResize` observer and reading the backtrace before assuming the bug is ours.

### `SMAppService` works for a self-signed, non-notarized app

Verified with a signed probe bundle in `/Applications`: `register()` -> `enabled`, persisting across
process launches (the record lives in launchd), `unregister()` -> `notRegistered`.

> Also: do **not** mirror the state into a stored preference. `SMAppService.mainApp.status` is the truth,
> and the user can change Login Items behind the app's back, so a cached copy can only go stale.

### A test suite cannot clean up its own `UserDefaults` suites

`removePersistentDomain(forName:)` leaves a 42-byte `{}` plist; `synchronize` plus `removeSuite` changes
nothing; deleting the file makes it vanish and then **`cfprefsd` rewrites it about 4 s later**. No
`deinit` or per-test hook wins that race. 85 stray `com.edict.tests.<UUID>.plist` files accumulated in
`~/Library/Preferences`.

> Fix: a `UserDefaults` subclass holding values in memory that never touches
> `~/Library/Preferences` at all. A suite never written to leaves no file.

### Apple's on-device models are conservative, not merely worse

The most consequential finding for what this app can honestly claim. A real 70-minute business meeting —
two-plus speakers, Indonesian and English code-switched, far-field — produced **1,128 words for 4,197
seconds: about 16 words per minute**, against ~150 for normal speech. The output was largely filler and
empty runs.

It was not a pipeline fault. `droppedBuffers` 0, segments spanning 131 s to 4,117 s, mean level
−29.6 dB / −25.9 LUFS. Measured on a 300-second slice:

    clean synthetic speech, SpeechTranscriber en-US ....... 819 words   (the engine is fine)
    the real meeting, SpeechTranscriber en-US .............. 61 words
    the real meeting, conditioned +7dB/highpass/compress ... 75 words
    the real meeting, DictationTranscriber id-ID ........... 18 words   (fluent, CORRECT Indonesian)
    the real meeting, DictationTranscriber en-US ............ 0 words

> On far-field, overlapping, reverberant audio these models **emit nothing rather than guessing**. That
> is why a bad transcript is sparse rather than confidently wrong, and why `DictationTranscriber` — tuned
> for close-mic dictation — returned literally zero. **Audio conditioning does not rescue it** (61 -> 75),
> so do not build a de-noising pipeline. This class of recording needs a Whisper-class model, which this
> app deliberately does not ship. Note the Indonesian output, though tiny, was accurate: the models are
> not broken, they are quiet when unsure.

### Short sections make the model guess, so word count alone is a liar

Transcribing per-section (for language detection) raised a difficult slice from **91 to 245 words** while
mean confidence collapsed to **0.288 with 57% of words below 0.30** — against 0.94 and 0% on two clean
files.

> Consequence: more words is not better, and a words-per-minute quality metric can be fooled by the very
> feature meant to improve quality. Any quality verdict must gate on confidence as well as rate. And rate
> must be measured against *detected speech*, not wall clock, or a mostly-silent voice memo is slandered.

### Language detection over two transcripts is viable, with a measured margin

Each model is excellent on its own language and turns the other into phonetic mush that is not words in
either language, which is trivially separable without any ML. Function words and affixes — a few hundred
entries compiled into the binary — scored **8 of 8** on strings the two models actually produced, with a
worst true-positive margin of 0.767 against 0.263 for genuinely ambiguous input.

On a clean bilingual fixture, four alternating turns: 4 of 4 sections chose correctly and word error fell
from 41.5% (en-US alone) and 51.2% (id-ID alone) to **7.3%**. Cost is **4.3–5.1x**, not 2x — the overhead
is per-utterance finalize latency, not analyzer construction.

> A marker claimed by more than one language must be **discarded outright**. Loanwords are everywhere in
> this domain (team, revenue, persen) and counting them only dilutes the margin.

### Atomic writes protect against a torn file, not a wrong one

An automated verification run exercised the import path against the installed app — which writes to the
real `~/Library/Application Support/Edict` — and a user's transcript history came back with two entries
where there had been thirty. **No backup existed anywhere**: not in the support directory, not a temp
file, and Time Machine held only OS-update snapshots.

> Two fixes, both in `AppPaths`. `EDICT_SUPPORT_DIR` redirects every path, so automation is isolated by
> construction rather than by remembering. And `writeAtomically` keeps the outgoing version as
> `<name>.bak`. Anything automated that exercises the real app must set the override *before* it starts.

### Two things that constrain how UI can be verified

**Screen Recording is denied to any process an agent starts** — `screencapture -l` fails and
ScreenCaptureKit returns `-3811` even from a locally-signed bundle. Proof sheets are therefore
`ImageRenderer` output of the real views, not photographs of a live window.

**`ImageRenderer` does not rasterise a `ScrollView`'s contents** — lists and transcript trays come out
empty. Views that need proving offline expose an `unbounded` hatch used only by fixtures.

---

## On-device text refinement — `FoundationModels`

Post-dictation clean-up, bullets and summaries run on Apple's on-device model, which keeps the app's
central privacy property intact: nothing leaves the machine and there is no key to manage.

    SystemLanguageModel.default.availability ......... available
    contextSize ..................................... 8192 tokens on macOS 27
    supportsLocale(en_US) ........................... true
    supportsLocale(id_ID) .......................... FALSE

**`supportsLocale == false` means "no guarantees", not "refuse".** Indonesian clean-up measured
excellent despite the flag, so the feature stays enabled and captions the result instead of disabling
it. Never silently substitute a language.

**Latency, measured (M5 Pro):** clean-up 0.84–1.04 s, bullets 0.97–1.17 s, summary 0.78–0.88 s,
Indonesian clean-up 1.05–1.24 s.

**The cold cost is daemon-level, not per-process.** An early probe measured 2.89 s for the first call
and it was read as a per-process warm-up. It is not: the model runs in its own daemon, and the first
call in a brand-new process measures ~1.0 s whenever that daemon is resident. `prewarm()` helps a cold
machine, not a warm one.

**Build a fresh `LanguageModelSession` per refinement.** A reused session accumulates a transcript, so
the previous dictation conditions the next one — a correctness bug in this app, not an inefficiency.

**Use `@Generable` for the bullet list** rather than parsing markdown out of a string. Parsing a model's
own formatting is how bullet lists acquire stray dashes and empty items.

**Greedy sampling.** Temperature is the knob that decides whether the model paraphrases, and
paraphrasing is invention in a tool whose job is faithful transcription.

**Instruction bloat measurably dilutes rules on this ~3B model.** Adding a fourth clause to a
clean-up instruction fixed nothing and made a filler word reappear. Keep instructions short and put
anything deterministic in code.

**Capitalisation:** with the instruction "Repair punctuation, capitalisation and sentence breaks…
Preserve every fact. Add nothing. Answer in the same language as the input", sentence case *and*
proper nouns came back correct in 6 of 6 greedy runs across two fixtures — `Thursday`, `Mark`,
`Pertamina`, `Azure`, `Microsoft`. An agent working from slightly different wording saw output stay
lowercase and added a deterministic sentence-case-and-terminator pass in `TextRefiner.tidy`; that pass
is a no-op on these fixtures and harmless either way. Worth re-measuring before trusting either claim
after an OS update.

**Cancellation is genuinely honoured.** `LanguageModelSession.respond` released its caller 0.40 s into
a multi-second generation when the task was cancelled, so no watchdog race is needed.

**Model-backed tests are gated behind `EDICT_MODEL_TESTS=1`**, mirroring `EDICT_SPEECH_TESTS`, so the
default suite stays fast and offline-deterministic.

**A Claude API path was considered and deliberately not built.** A claude.ai subscription is not API
access, Swift has no official Anthropic SDK (so it would be hand-rolled HTTP), and — decisively — it
would send dictated text off the machine for a marginal gain on this task. The local model is good
enough here; revisit only if long or subtle text proves otherwise.
