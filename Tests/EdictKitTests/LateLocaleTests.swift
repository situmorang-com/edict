import AVFoundation
import CoreGraphics
import Foundation
import Speech
import Synchronization
import Testing
@testable import EdictKit

// MARK: - The bug this file exists for

/// A late `⇧` used to pick the wrong acoustic model, silently, and the result was garbage.
///
/// The language modifier was sampled once, `armDelay` (~120 ms) after key-down, and the locale could
/// never change afterwards because `SpeechAnalyzer` is built around one `Locale` (RECON §3). Press the
/// dictation key and add `⇧` a moment later and the utterance had already committed to English.
///
/// The cost is not a missing feature. An English model handed Indonesian speech does not fail — it
/// resolves unfamiliar phoneme runs into proper nouns, because that is where an English lexicon is
/// most permissive. Six consecutive dictations from the user's real history, verbatim:
///
///     id-ID   "Good nih gua baru diskusi dengan David dari"                     ← correct
///     en-US   "KB financial"
///     en-US   "Dhanya Sanga interested AI Kanaya Sushma Manga Cheil Danka,"     ← garbage
///     en-US   "Bro"
///     id-ID   "Dan ada workshop karena sekarang timnya dia itu sangat kecil"     ← correct
///
/// Every garbage segment is `en-US`. The user read it as "the model invents names". It was the wrong
/// model, chosen by a 120 ms race.
///
/// The fix decouples *start capturing* from *choose the locale*: `.pressed` still fires at `armDelay`
/// and opens the microphone, the audio buffers, and `.alternateSettled` — up to
/// `HotkeyMonitor.alternateWindow` later — is what decides which analyzer gets built.
///
/// Three things therefore have to be true, and all three are tested below:
///
/// 1. A modifier arriving anywhere inside the window is seen.
/// 2. **No audio is lost.** The buffered head must reach the analyzer. RECON §20 is the trap:
///    `.bufferingNewest` discards the OLDEST element, which would silently delete the beginning of
///    the utterance and look like exactly the model failure this change is fixing.
/// 3. Nothing that already worked regresses — a plain hold is still the primary language, a hold
///    shorter than the window still gets a language, and every `.pressed` is still paired.
@Suite("The language window")
struct LanguageWindowTests {

    // MARK: Flag words, measured on this keyboard

    /// Right Option held alone. `0x140`, not the textbook `0x40`: Karabiner's virtual keyboard
    /// stamps `0x100` (`kCGEventFlagMaskNonCoalesced`) on every event it synthesises (RECON §31).
    static let rightOptionAlone: UInt64 = 0x0008_0140
    /// Right Option and Shift together.
    static let rightOptionAndShift: UInt64 = 0x0008_0142 | UInt64(CGEventFlags.maskShift.rawValue)
    /// Shift alone, after Right Option came back up — what the tap reports if the user lets go of the
    /// dictation key first and is still holding the modifier.
    static let shiftAlone: UInt64 = UInt64(CGEventFlags.maskShift.rawValue) | 0x0000_0002

    /// A monitor with no tap and a stubbed flags poll.
    ///
    /// The poll has to be stubbed rather than inherited: the production implementation reads the
    /// user's live keyboard, so `#expect(alternate == false)` against the real one would be an
    /// assertion about where the user's hands happen to be. RECON §43 measured it latched at
    /// `maskCommand` for over three seconds with no key down.
    private static func monitor(window: TimeInterval = 0.40,
                               polled: UInt64 = 0) -> HotkeyMonitor {
        HotkeyMonitor(armDelay: 0.12, alternateWindow: window, pollFlags: { polled })
    }

    /// Collect the events a closure produces, then stop listening. The monitor's `events` stream is
    /// unbounded (a lost `.released` would leave the app recording for ever), so nothing is dropped
    /// while the timeline runs and the drain afterwards is exact.
    private static func events(from monitor: HotkeyMonitor,
                              expecting count: Int,
                              timeline: () -> Void) async -> [HotkeyEvent] {
        let collected = Mutex<[HotkeyEvent]>([])
        let collector = Task {
            for await event in monitor.events {
                let reached = collected.withLock { events -> Bool in
                    events.append(event)
                    return events.count >= count
                }
                if reached { return }
            }
        }
        // Every step of the timeline runs synchronously on the tap thread in production too, so the
        // whole sequence is already queued on the (unbounded) events stream before anything is read.
        timeline()
        // Bounded, so a missing event is a failed expectation rather than a hung suite. The stream is
        // unbounded and the events are already in it, so this is a scheduling wait, not a timing one.
        let deadline = ContinuousClock.now + .seconds(2)
        while collected.withLock({ $0.count < count }), ContinuousClock.now < deadline {
            await Task.yield()
        }
        // One more yield past the expected count, so a test asserting "exactly these three" would
        // still see a spurious fourth.
        await Task.yield()
        collector.cancel()
        return collected.withLock { $0 }
    }

    // MARK: - The decision, ordered

    /// The modifier arrives *after* the hold armed but *before* the window closed. This is the bug.
    @Test("A modifier that lands after arming but inside the window still selects the second language")
    func modifierInsideTheWindow() async {
        let monitor = Self.monitor()
        let hold = monitor.holdHarness
        let events = await Self.events(from: monitor, expecting: 3) {
            hold.bind(.rightOption, alternate: .shift)
            hold.flagsChanged(to: Self.rightOptionAlone)   // key down, no modifier yet
            hold.keyDown()
            hold.deadline()                                // armDelay: .pressed, provisionally EN
            hold.flagsChanged(to: Self.rightOptionAndShift) // ⇧ arrives late
            hold.deadline()                                // window closes: .alternateSettled(true)
            hold.keyUp()
        }
        #expect(events == [.pressed(alternate: false), .alternateSettled(alternate: true), .released])
    }

    /// The pin on the old behaviour: this is precisely the case that used to be lost.
    @Test("The provisional reading may disagree with the decision, and the decision is the later one")
    func provisionalIsNotTheDecision() async {
        let monitor = Self.monitor()
        let hold = monitor.holdHarness
        let events = await Self.events(from: monitor, expecting: 2) {
            hold.bind(.rightOption, alternate: .shift)
            hold.flagsChanged(to: Self.rightOptionAlone)
            hold.keyDown()
            hold.deadline()
            hold.flagsChanged(to: Self.rightOptionAndShift)
            hold.deadline()
        }
        guard case .pressed(let provisional) = events.first,
              case .alternateSettled(let settled) = events.last else {
            Issue.record("expected a pressed and a settled, got \(events)")
            return
        }
        #expect(provisional == false)
        #expect(settled == true)
    }

    /// Held from before key-down: the ordinary case, which must be unaffected.
    @Test("A modifier held from the start is seen at arming and again at the settle")
    func modifierHeldThroughout() async {
        let monitor = Self.monitor()
        let hold = monitor.holdHarness
        let events = await Self.events(from: monitor, expecting: 3) {
            hold.bind(.rightOption, alternate: .shift)
            hold.flagsChanged(to: Self.rightOptionAndShift)
            hold.keyDown()
            hold.deadline()
            hold.deadline()
            hold.keyUp()
        }
        #expect(events == [.pressed(alternate: true), .alternateSettled(alternate: true), .released])
    }

    /// **The regression that would cost the most.** A plain hold has to stay the primary language, and
    /// the stubbed poll is what makes this assertion mean anything.
    @Test("A plain hold with no modifier settles on the primary language")
    func plainHoldIsPrimary() async {
        let monitor = Self.monitor()
        let hold = monitor.holdHarness
        let events = await Self.events(from: monitor, expecting: 3) {
            hold.bind(.rightOption, alternate: .shift)
            hold.flagsChanged(to: Self.rightOptionAlone)
            hold.keyDown()
            hold.deadline()
            hold.deadline()
            hold.keyUp()
        }
        #expect(events == [.pressed(alternate: false), .alternateSettled(alternate: false), .released])
    }

    /// Past the window the modifier really is inert — by then the analyzer exists and the framework
    /// fixes the locale for the whole utterance, so there is nothing left to change.
    @Test("A modifier arriving after the window has closed does not change the language")
    func modifierAfterTheWindow() async {
        let monitor = Self.monitor()
        let hold = monitor.holdHarness
        let events = await Self.events(from: monitor, expecting: 3) {
            hold.bind(.rightOption, alternate: .shift)
            hold.flagsChanged(to: Self.rightOptionAlone)
            hold.keyDown()
            hold.deadline()
            hold.deadline()                                 // window closes with no modifier
            hold.flagsChanged(to: Self.rightOptionAndShift)  // too late
            hold.keyUp()
        }
        #expect(events == [.pressed(alternate: false), .alternateSettled(alternate: false), .released])
    }

    // MARK: - Short holds

    /// A hold that ends before the window closes must not lose the feature. The modifier held at the
    /// release is the decision — and `.alternateSettled` must arrive *before* `.released`, because the
    /// consumer needs the language before it can finish the utterance the release just ended.
    @Test("A hold released before the window closes settles from the release, and settles first")
    func releaseBeatsTheWindow() async {
        let monitor = Self.monitor()
        let hold = monitor.holdHarness
        let events = await Self.events(from: monitor, expecting: 3) {
            hold.bind(.rightOption, alternate: .shift)
            hold.flagsChanged(to: Self.rightOptionAndShift)
            hold.keyDown()
            hold.deadline()                       // armed
            hold.flagsChanged(to: Self.shiftAlone) // Right Option up, ⇧ still down
            hold.keyUp()                          // before the window's own deadline
        }
        #expect(events == [.pressed(alternate: true), .alternateSettled(alternate: true), .released])
    }

    /// The window's deadline fires after the key already came up. It must not produce a second
    /// decision, and it must not resurrect a finished hold.
    @Test("A window deadline arriving after the release is inert")
    func lateDeadlineIsInert() async {
        let monitor = Self.monitor()
        let hold = monitor.holdHarness
        let events = await Self.events(from: monitor, expecting: 3) {
            hold.bind(.rightOption, alternate: .shift)
            hold.flagsChanged(to: Self.rightOptionAndShift)
            hold.keyDown()
            hold.deadline()
            hold.keyUp()
            hold.deadline()   // the parked timer somehow fired anyway
            hold.deadline()
        }
        #expect(events == [.pressed(alternate: true), .alternateSettled(alternate: true), .released])
        #expect(events.filter { if case .alternateSettled = $0 { return true } else { return false } }.count == 1)
    }

    /// Below `armDelay` nothing was ever armed, so nothing is owed — least of all a language.
    @Test("A tap too short to arm produces no events at all")
    func tooShortProducesNothing() async {
        let monitor = Self.monitor()
        let hold = monitor.holdHarness
        let events = await Self.events(from: monitor, expecting: 1) {
            hold.bind(.rightOption, alternate: .shift)
            hold.flagsChanged(to: Self.rightOptionAndShift)
            hold.keyDown()
            hold.keyUp()      // released before the arm deadline
        }
        #expect(events.isEmpty)
    }

    // MARK: - Pairing invariants

    /// An abort commits what was already spoken (`DictationController.handle` calls `end()` on
    /// `.tapDisabled` and `.keyChanged`), so it owes a language just as much as a clean release does.
    @Test("An abort after arming still settles the language, then releases")
    func abortStillSettles() async {
        for reason in [HotkeyCancelReason.tapDisabled, .keyChanged, .chordedWithKey(0)] {
            let monitor = Self.monitor()
            let hold = monitor.holdHarness
            let events = await Self.events(from: monitor, expecting: 3) {
                hold.bind(.rightOption, alternate: .shift)
                hold.flagsChanged(to: Self.rightOptionAndShift)
                hold.keyDown()
                hold.deadline()
                hold.abort(reason)
            }
            #expect(events == [.pressed(alternate: true), .alternateSettled(alternate: true), .released],
                    "reason \(reason)")
        }
    }

    /// An abort *before* arming emitted no `.pressed`, so it must emit neither of the other two.
    @Test("An abort before arming settles nothing and releases nothing")
    func abortBeforeArmingIsSilent() async {
        let monitor = Self.monitor()
        let hold = monitor.holdHarness
        let events = await Self.events(from: monitor, expecting: 1) {
            hold.bind(.rightOption, alternate: .shift)
            hold.flagsChanged(to: Self.rightOptionAndShift)
            hold.keyDown()
            hold.abort(.chordedWithModifier(55))
        }
        #expect(events.isEmpty)
    }

    /// Two holds back to back. The second must get its own decision rather than inheriting the first's
    /// `settled` flag, which would leave `run(_:)` waiting for an event that already happened.
    @Test("Consecutive holds each get exactly one decision")
    func consecutiveHolds() async {
        let monitor = Self.monitor()
        let hold = monitor.holdHarness
        let events = await Self.events(from: monitor, expecting: 6) {
            hold.bind(.rightOption, alternate: .shift)
            hold.flagsChanged(to: Self.rightOptionAndShift)
            hold.keyDown(); hold.deadline(); hold.deadline(); hold.keyUp()
            hold.flagsChanged(to: Self.rightOptionAlone)
            hold.keyDown(); hold.deadline(); hold.deadline(); hold.keyUp()
        }
        #expect(events == [
            .pressed(alternate: true), .alternateSettled(alternate: true), .released,
            .pressed(alternate: false), .alternateSettled(alternate: false), .released,
        ])
    }

    /// A window at or inside `armDelay` is not a window. It collapses to the old arm-time contract in
    /// one step, so the pairing invariant holds for a monitor configured that way — and so the old
    /// behaviour has a name and a test rather than being unreachable.
    @Test("A window no wider than the arm delay collapses to the old arm-time behaviour")
    func collapsedWindow() async {
        let monitor = Self.monitor(window: 0.12)
        let hold = monitor.holdHarness
        let events = await Self.events(from: monitor, expecting: 3) {
            hold.bind(.rightOption, alternate: .shift)
            hold.flagsChanged(to: Self.rightOptionAlone)
            hold.keyDown()
            hold.deadline()                                  // arms AND settles
            hold.flagsChanged(to: Self.rightOptionAndShift)   // the old bug, deliberately reproduced
            hold.deadline()
            hold.keyUp()
        }
        #expect(events == [.pressed(alternate: false), .alternateSettled(alternate: false), .released])
    }

    // MARK: - The poll is a second yes, never a no

    /// The tap's own flags said nothing, but the session poll says the modifier is down — which is the
    /// case RECON could not rule out, where `flagsState` is the only source that works.
    @Test("The session poll alone is enough to see the modifier")
    func pollAloneSeesTheModifier() async {
        let monitor = Self.monitor(polled: Self.rightOptionAndShift)
        let hold = monitor.holdHarness
        let events = await Self.events(from: monitor, expecting: 2) {
            hold.bind(.rightOption, alternate: .shift)
            hold.flagsChanged(to: 0)
            hold.keyDown()
            hold.deadline()
            hold.deadline()
        }
        #expect(events == [.pressed(alternate: true), .alternateSettled(alternate: true)])
    }
}

// MARK: - Against the real clock

/// The window arithmetic, measured rather than asserted.
///
/// `LanguageWindowTests` proves the *ordering* rule — which flags word is in force when the settle
/// deadline fires. This suite proves the thing the user actually experiences: a modifier that lands
/// 50, 150, 300 or 600 ms after key-down. The deadlines are fired by a task that sleeps the same two
/// intervals the production `CFRunLoopTimer` is set to (`start + armDelay`, then
/// `start + alternateWindow`), so the timeline is real wall-clock time and the only thing standing in
/// for the run loop is *when* it wakes.
@Suite("The language window, against the clock", .serialized)
struct LanguageWindowClockTests {

    private static let armDelay: TimeInterval = 0.12
    private static let window: TimeInterval = 0.40

    /// - Returns: the decision the monitor settled on, and how long after key-down it arrived.
    private func run(modifierAt offset: TimeInterval,
                     releaseAt release: TimeInterval) async -> (settled: Bool, at: TimeInterval) {
        let monitor = HotkeyMonitor(armDelay: Self.armDelay,
                                    alternateWindow: Self.window,
                                    pollFlags: { 0 })
        let hold = monitor.holdHarness
        hold.bind(.rightOption, alternate: .shift)
        hold.flagsChanged(to: LanguageWindowTests.rightOptionAlone)

        let settled = Mutex<(value: Bool, at: TimeInterval)?>(nil)
        let start = ContinuousClock.now
        let collector = Task {
            for await event in monitor.events {
                if case .alternateSettled(let alternate) = event {
                    let elapsed = Double((ContinuousClock.now - start).components.attoseconds) / 1e18
                        + Double((ContinuousClock.now - start).components.seconds)
                    settled.withLock { $0 = (alternate, elapsed) }
                    return
                }
            }
        }

        hold.keyDown()
        // The two deadlines the run-loop timer would fire, and the two keyboard events, all on the
        // real clock and all racing each other exactly as they do in the app.
        async let deadlines: Void = {
            try? await Task.sleep(for: .seconds(Self.armDelay))
            hold.deadline()
            try? await Task.sleep(for: .seconds(Self.window - Self.armDelay))
            hold.deadline()
        }()
        async let modifier: Void = {
            try? await Task.sleep(for: .seconds(offset))
            hold.flagsChanged(to: LanguageWindowTests.rightOptionAndShift)
        }()
        async let release: Void = {
            try? await Task.sleep(for: .seconds(release))
            hold.keyUp()
        }()
        _ = await (deadlines, modifier, release)
        _ = await collector.result

        let result = settled.withLock { $0 }
        return (result?.value ?? false, result?.at ?? .infinity)
    }

    /// The four offsets the brief asks for, against a 400 ms window and a 900 ms hold.
    ///
    /// 50, 150 and 300 ms are inside the window and select Indonesian; 600 ms is outside it and does
    /// not. 150 ms is the important one: it is past `armDelay`, so it is exactly the press the old
    /// code threw away, and it is the shape of the failure in the user's history.
    @Test("A modifier at 50, 150 and 300 ms selects the second language; at 600 ms it does not",
          arguments: [(0.050, true), (0.150, true), (0.300, true), (0.600, false)])
    func modifierOffsets(offset: TimeInterval, expected: Bool) async {
        let outcome = await run(modifierAt: offset, releaseAt: 0.9)
        #expect(outcome.settled == expected,
                "a modifier \(Int(offset * 1000)) ms after key-down should settle \(expected)")
        // And the decision is not merely correct, it is *early*: never later than the window itself,
        // so the HUD is settled while the user is still speaking.
        #expect(outcome.at < Self.window + 0.15,
                "the decision arrived \(Int(outcome.at * 1000)) ms after key-down")
    }

    /// A hold shorter than the window: the decision comes from the release, and it comes early.
    @Test("A 250 ms hold with a 150 ms modifier still selects the second language")
    func shortHoldStillSees() async {
        let outcome = await run(modifierAt: 0.150, releaseAt: 0.250)
        #expect(outcome.settled == true)
        #expect(outcome.at < Self.window,
                "a hold shorter than the window must not wait for it (waited \(Int(outcome.at * 1000)) ms)")
    }
}

// MARK: - The buffered head

/// **No audio may be lost.** The requirement with the sharpest failure mode in the whole change.
///
/// Capture now opens before the language is decided and nothing consumes the stream until the
/// analyzer exists, so for a few hundred milliseconds the utterance lives entirely in the stream's
/// own queue. RECON §20 is the trap: `.bufferingNewest(n)` discards the **oldest** element, so an
/// under-sized queue would silently delete the *beginning* of the utterance — and a transcript
/// missing its first sentence reads as a model failure, which is the exact symptom this whole change
/// is fixing. Sizing the queue in seconds is therefore not a style preference.
@Suite("The buffered head of an utterance")
struct BufferedHeadTests {

    private static func frame(_ marker: Int16, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!   // 100 ms at 16 kHz
        buffer.frameLength = 1600
        // One distinguishable sample value per buffer, so an out-of-order or missing buffer is
        // identifiable rather than merely a count that does not add up.
        if let channel = buffer.int16ChannelData?[0] {
            for index in 0..<1600 { channel[index] = marker }
        }
        return buffer
    }

    /// Read one buffer's marker back out of an `AnalyzerInput`.
    ///
    /// **`AnalyzerInput.buffer` materialises a fresh `AVAudioPCMBuffer` on every access**, so
    /// `input.buffer.int16ChannelData![0][0]` dereferences a pointer into an object that was already
    /// destroyed at the end of the expression — an immediate `EXC_BAD_ACCESS`, measured, not
    /// theoretical. The buffer must be bound to a local and outlive the read. Nothing in the app hits
    /// this because `SpeechSession.feed` only ever reads `frameLength`, which is a value.
    private static func marker(of input: AnalyzerInput) -> Int16 {
        let held = input.buffer
        return held.int16ChannelData?[0][0] ?? 0
    }

    private static var analyzerFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    }

    /// The core claim: buffers yielded while no consumer exists are all still there, in order, when
    /// one arrives — and `finish()` does not throw them away, which is what makes a hold shorter than
    /// the set-up still deliver every sample it captured.
    @Test("Everything captured before the analyzer existed reaches it, in order, even after finish()")
    func headSurvivesUntilTheConsumerArrives() async {
        let format = Self.analyzerFormat
        let capacity = CaptureNode.bufferedBufferCount(forSeconds: 100)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(capacity))

        // 40 buffers is 4 s of speech with nobody listening — ten times the widest window.
        var dropped = 0
        for marker in 1...40 {
            if case .dropped = continuation.yield(AnalyzerInput(buffer: Self.frame(Int16(marker), format: format))) {
                dropped += 1
            }
        }
        // The key release: the stream is finished before the analyzer has read a single buffer.
        continuation.finish()

        var markers: [Int16] = []
        for await input in stream {
            markers.append(Self.marker(of: input))
        }

        #expect(dropped == 0)
        #expect(markers == (1...40).map(Int16.init))
        // Said explicitly: the FIRST buffer is present. That is the one `.bufferingNewest` evicts, and
        // the one whose loss looks like the model mishearing the opening of the sentence.
        #expect(markers.first == 1)
    }

    /// The trap itself, reproduced, so the sizing argument is evidence rather than a claim. With a
    /// queue sized like a hand-picked small `n`, it is the beginning that disappears.
    @Test("An under-sized queue deletes the BEGINNING of the utterance, not the end")
    func undersizedQueueEatsTheHead() async {
        let format = Self.analyzerFormat
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(4))
        var dropped = 0
        for marker in 1...10 {
            if case .dropped = continuation.yield(AnalyzerInput(buffer: Self.frame(Int16(marker), format: format))) {
                dropped += 1
            }
        }
        continuation.finish()

        var markers: [Int16] = []
        for await input in stream { markers.append(Self.marker(of: input)) }
        #expect(dropped == 6)
        #expect(markers == [7, 8, 9, 10])   // the head is gone; `dropped` is the only trace
    }

    /// The queue is sized in *seconds*, and the divisor is `installTap`'s clamped floor rather than a
    /// guess: a device delivering 100 ms buffers fills the queue four times faster than one delivering
    /// 400 ms buffers, so the floor is the only safe assumption (RECON §19).
    @Test("Capacity is derived from seconds of audio, at the tap's clamped 100 ms floor")
    func capacityIsSecondsNotACount() {
        #expect(CaptureNode.tapBufferFloorSeconds == 0.100)
        #expect(CaptureNode.bufferedBufferCount(forSeconds: 100) == 1000)
        #expect(CaptureNode.bufferedBufferCount(forSeconds: 1) == 10)
        // Never below a floor, however small the request: eight buffers is 0.8 s, which still covers
        // the whole modifier window twice over.
        #expect(CaptureNode.bufferedBufferCount(forSeconds: 0.1) == 8)
        // 100 s of headroom against a 400 ms window is 250x, and costs ~3 MB at 32 KB/s.
        let headroom = Double(CaptureNode.bufferedBufferCount(forSeconds: 100)) * CaptureNode.tapBufferFloorSeconds
        #expect(headroom / 0.40 > 100)
    }
}

// MARK: - End to end, against the real model

/// The proof that the transcript actually changes: real Indonesian audio, a modifier that arrives
/// *after* the hold would have armed, and the whole capture-buffer-settle-analyze path.
///
/// Gated behind `EDICT_SPEECH_TESTS=1` for the reasons `SecondaryLocaleEngineTests` gives — it takes
/// locale reservations (5 maximum, persisting across launches), it may download Indonesian assets,
/// and it shells out to `say`. Run it deliberately:
///
///     EDICT_SPEECH_TESTS=1 swift test --filter LateLocaleEngine
///
/// It exists because everything above proves the *plumbing*. This proves the point: that the same
/// audio comes back as Indonesian instead of a page of invented English proper nouns, and that the
/// audio buffered while the decision was open is all still in the transcript.
@Suite("Late locale — engine end to end",
       .enabled(if: ProcessInfo.processInfo.environment["EDICT_SPEECH_TESTS"] == "1"),
       .serialized)
struct LateLocaleEngineTests {

    /// Indonesian in the user's own register — code-switched English nouns ("workshop", "interested")
    /// inside Indonesian grammar, which is the exact material the English model turns into names.
    private static let indonesian = """
        Dan ada workshop karena sekarang timnya dia itu sangat kecil. \
        Dan dia interested dengan workshop. Cuma memang dia diinfo oleh teman teman \
        kalau harganya sangat murah, nah kita harus cari cara untuk membandingkan.
        """

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private static func synthesise(_ text: String, voice: String, into directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-r", "175", "-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AudioImportError.unreadable(filename: url.lastPathComponent, reason: "say failed")
        }
        return url
    }

    /// Read the whole fixture into analyzer-format buffers up front, so the timeline below is
    /// measuring the pipeline rather than a file read.
    private static func buffers(from url: URL, format: AVAudioFormat) async throws -> [AVAudioPCMBuffer] {
        try await inputs(from: url, format: format).map(\.buffer)
    }

    /// The same, kept as `AnalyzerInput`s.
    ///
    /// `AVAudioPCMBuffer` is not `Sendable`, so an array of them cannot cross into a `Task` — which
    /// the realtime-pace tests below need. `AnalyzerInput` is, which is why the whole pipeline is
    /// built on it rather than on raw buffers.
    private static func inputs(from url: URL, format: AVAudioFormat) async throws -> [AnalyzerInput] {
        let importer = AudioFileImporter(url: url, analyzerFormat: format)
        let stream = try await importer.start(onProgress: { _ in })
        var all: [AnalyzerInput] = []
        for await input in stream { all.append(input) }
        return all
    }

    /// The whole point, in one test.
    ///
    /// Timeline, matching `DictationController.run(_:)` exactly:
    ///
    ///     t=0     microphone opens; buffers start piling into the stream, nobody consuming
    ///     t=Δ     the modifier arrives — after arming, which is where the old code lost it
    ///     t=400ms the window closes; NOW the analyzer is built, for Indonesian
    ///     then    the whole stream drains into it, head first
    @Test("A modifier arriving after arming produces an Indonesian transcript, with no lost head")
    func lateModifierTranscribesIndonesian() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-late-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let engine = SpeechEngine()
        try await engine.prepare(localeIdentifier: "en-US")
        try await engine.prepareSecondary(localeIdentifier: "id-ID")

        // The formats must agree, or `DictationController.localeDecisionDeferrable` refuses to defer
        // at all and the whole feature is off. Asserted here because it is the precondition.
        let primaryFormat = try #require(await engine.bestAudioFormat())
        let secondaryFormat = try #require(await engine.bestAudioFormat(secondary: true))
        #expect(primaryFormat.sampleRate == secondaryFormat.sampleRate)
        #expect(primaryFormat.channelCount == secondaryFormat.channelCount)
        #expect(primaryFormat.commonFormat == secondaryFormat.commonFormat)
        #expect(primaryFormat.isInterleaved == secondaryFormat.isInterleaved)

        let audio = try Self.synthesise(Self.indonesian, voice: "Damayanti", into: scratch)
        let all = try await Self.buffers(from: audio, format: primaryFormat)
        let totalFrames = all.reduce(0) { $0 + Int($1.frameLength) }
        #expect(totalFrames > 0)

        // ── t=0: capture opens, with no consumer and no analyzer ────────────────────────────────
        let capacity = CaptureNode.bufferedBufferCount(forSeconds: 100)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            of: AnalyzerInput.self, bufferingPolicy: .bufferingNewest(capacity))
        var dropped = 0
        // The head of the utterance: 400 ms of speech buffered before the decision, at the tap's
        // 100 ms granularity. This is the audio the old ordering never had a problem with and the new
        // ordering must not lose.
        let headBuffers = min(4, all.count)
        for buffer in all.prefix(headBuffers) {
            if case .dropped = continuation.yield(AnalyzerInput(buffer: buffer)) { dropped += 1 }
        }
        #expect(dropped == 0, "the head of the utterance was evicted before the analyzer existed")

        // ── t=400ms: the window closes. Only NOW is the analyzer built, and in Indonesian. ──────
        let buildStart = ContinuousClock.now
        let session = try await engine.begin(locale: .secondary, onUpdate: { _ in })
        let buildCost = Self.seconds(buildStart.duration(to: ContinuousClock.now))

        // The rest of the audio arrives as the user goes on speaking.
        for buffer in all.dropFirst(headBuffers) {
            if case .dropped = continuation.yield(AnalyzerInput(buffer: buffer)) { dropped += 1 }
        }
        continuation.finish()

        // The feed loop, draining the buffered head first.
        let drainStart = ContinuousClock.now
        var fed = 0
        for await input in stream {
            fed += Int(input.buffer.frameLength)
            session.feed(input)
        }
        let drain = Self.seconds(drainStart.duration(to: ContinuousClock.now))
        let outcome = try await session.finishAndCommit()

        // ── What the user gets ──────────────────────────────────────────────────────────────────
        let text = outcome.text.lowercased()
        print("""

            LATE-MODIFIER END TO END
              audio            \(String(format: "%.2f", outcome.audioDuration)) s \
            (\(totalFrames) frames captured, \(fed) delivered)
              buffered head    \(headBuffers) buffers before the analyzer existed, \(dropped) dropped
              analyzer build   \(String(format: "%.1f", buildCost * 1000)) ms
              stream drain     \(String(format: "%.3f", drain)) s
              commit latency   \(String(format: "%.3f", outcome.latency)) s
              low confidence   \(outcome.lowConfidenceWords.count) of \(outcome.text.split(separator: " ").count)
              text             \(outcome.text)

            """)

        // No audio lost: every frame captured before the decision reached the analyzer.
        #expect(fed == totalFrames)
        #expect(dropped == 0)
        // `audioDuration` is counted from the frames the session was actually fed, so this is the
        // same claim measured from the other end.
        #expect(abs(outcome.audioDuration - Double(totalFrames) / primaryFormat.sampleRate) < 0.05)

        // And it is Indonesian. Function words with no plausible English homophone in this audio.
        #expect(!text.isEmpty)
        #expect(text.contains("dan") || text.contains("dia") || text.contains("kita"))
        #expect(text.contains("workshop") || text.contains("sangat") || text.contains("harus"))
    }

    /// The counterfactual, and the reason the fix matters: the *same* audio through the primary
    /// English model, which is what a modifier lost at 120 ms actually produced.
    ///
    /// Asserted loosely on purpose. The failure is that the English model returns confident nonsense,
    /// and nonsense is not stable enough to pin word for word — what *is* stable is that it does not
    /// return the Indonesian function words the previous test requires, and that its per-word
    /// confidence collapses. Both are checked, and the transcript is printed so the difference is
    /// legible rather than merely numeric.
    @Test("The same Indonesian audio through the English model is confident nonsense")
    func wrongModelIsNotAFailure() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-wrong-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let engine = SpeechEngine()
        try await engine.prepare(localeIdentifier: "en-US")
        let format = try #require(await engine.bestAudioFormat())
        let audio = try Self.synthesise(Self.indonesian, voice: "Damayanti", into: scratch)
        let importer = AudioFileImporter(url: audio, analyzerFormat: format)
        let input = try await importer.start(onProgress: { _ in })

        let outcome = try await engine.transcribe(
            input: input, module: .dictation, locale: .primary, biasing: [], onUpdate: { _ in })

        let words = outcome.text.split(separator: " ").count
        print("""

            WRONG MODEL, SAME AUDIO (this is what a 120 ms race produced)
              words            \(words) in \(String(format: "%.2f", outcome.audioDuration)) s \
            (\(words > 0 ? Int(Double(words) / outcome.audioDuration * 60) : 0) wpm)
              low confidence   \(outcome.lowConfidenceWords.count)
              text             \(outcome.text)

            """)

        // It does NOT fail. That is the whole problem: there is no error to catch and no flag to read.
        #expect(!outcome.text.isEmpty)
        // What it does instead. Either signal is enough — a low word rate against real speech
        // (RECON §38) or a pile of sub-0.5 words (RECON's confidence finding).
        let rate = Double(words) / max(outcome.audioDuration, 0.001) * 60
        let lowConfidenceShare = Double(outcome.lowConfidenceWords.count) / Double(max(words, 1))
        #expect(rate < 90 || lowConfidenceShare > 0.3,
                "the English model on Indonesian audio should be slow or unconfident, got \(Int(rate)) wpm and \(outcome.lowConfidenceWords.count) low-confidence words")
    }

    /// **The number the change has to justify: what does the window cost a normal dictation?**
    ///
    /// Measured the only way that means anything — the same audio, at realtime pace, through both
    /// orderings, timing what the user actually waits for: the gap between the last audio being handed
    /// over (the key coming up) and the transcript being committed.
    ///
    /// * OLD: analyzer built first, then audio streamed into it as it arrives. The analyzer is never
    ///   behind, so the wait is `finalizeAndFinishThroughEndOfInput` and nothing else.
    /// * NEW: audio buffers for the length of the window with no analyzer at all, the analyzer is
    ///   built when the window closes, and the feed loop then has a backlog to chew through before it
    ///   catches up.
    ///
    /// If the backlog were expensive this would show up as a straight addition to every dictation.
    @Test("The window adds no perceptible latency to a normal dictation, measured both ways")
    func addedLatencyOnANormalDictation() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-latency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let engine = SpeechEngine()
        try await engine.prepare(localeIdentifier: "en-US")
        // Warm, as it is in the running app: `DictationController` calls `warmUp()` at launch, so
        // measuring a cold first analyzer would slander the new ordering with a cost the user never
        // pays (RECON §3 puts cold at ~50 ms and warm at ~2.5 ms).
        await engine.warmUp()
        let format = try #require(await engine.bestAudioFormat())
        let audio = try Self.synthesise(
            "Need to update on some of my projects. Please remove the active map from the amount "
                + "that I will be receiving as a goal, because another person handles it now.",
            voice: "Samantha", into: scratch)
        let all = try await Self.inputs(from: audio, format: format)
        let seconds = Double(all.reduce(0) { $0 + Int($1.buffer.frameLength) }) / format.sampleRate

        /// One run. `windowSeconds == 0` is the old ordering; `0.40` is the new one.
        func run(windowSeconds: Double) async throws -> (wait: Double, text: String) {
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
                of: AnalyzerInput.self,
                bufferingPolicy: .bufferingNewest(CaptureNode.bufferedBufferCount(forSeconds: 100)))

            // The microphone, at realtime pace: one 100 ms buffer every 100 ms, exactly as
            // `installTap`'s clamped floor delivers them (RECON §19).
            let lastYield = Mutex<ContinuousClock.Instant?>(nil)
            let microphone = Task {
                for input in all {
                    try? await Task.sleep(for: .seconds(CaptureNode.tapBufferFloorSeconds))
                    _ = continuation.yield(input)
                }
                lastYield.withLock { $0 = ContinuousClock.now }   // the key coming up
                continuation.finish()
            }

            if windowSeconds > 0 {
                try await Task.sleep(for: .seconds(windowSeconds))
            }
            let session = try await engine.begin(locale: .primary, onUpdate: { _ in })
            for await input in stream { session.feed(input) }
            let outcome = try await session.finishAndCommit()
            await microphone.value

            let released = try #require(lastYield.withLock { $0 })
            return (Self.seconds(released.duration(to: ContinuousClock.now)), outcome.text)
        }

        let old = try await run(windowSeconds: 0)
        let new = try await run(windowSeconds: 0.40)

        print("""

            ADDED LATENCY, \(String(format: "%.2f", seconds)) s OF SPEECH AT REALTIME PACE
              old ordering (analyzer first)   key-up → text  \(String(format: "%.3f", old.wait)) s
              new ordering (400 ms window)    key-up → text  \(String(format: "%.3f", new.wait)) s
              added                                          \(String(format: "%+.0f", (new.wait - old.wait) * 1000)) ms
              old text  \(old.text)
              new text  \(new.text)

            """)

        // Identical transcripts: the reordering must not change what the model hears, only when it
        // starts hearing it.
        #expect(new.text == old.text)
        // The budget. 100 ms is already generous against a 400 ms window: anything approaching the
        // window itself would mean the backlog is not being absorbed and the design is wrong.
        #expect(new.wait - old.wait < 0.100,
                "the window added \(Int((new.wait - old.wait) * 1000)) ms to a normal dictation")
    }

    /// The claim the whole design rests on: buffered audio is consumed far faster than realtime, so a
    /// few hundred milliseconds of head start is absorbed rather than added to the user's wait.
    ///
    /// Verified rather than assumed, because if it were false the window would be a latency budget the
    /// user pays on every dictation instead of free insurance.
    @Test("A buffered head is consumed far faster than realtime, so the window costs no perceptible latency")
    func catchUpIsFasterThanRealtime() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-catchup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let engine = SpeechEngine()
        try await engine.prepare(localeIdentifier: "en-US")
        let format = try #require(await engine.bestAudioFormat())
        let audio = try Self.synthesise(
            "Please update the financial spreadsheet and also the presentation for Wednesday.",
            voice: "Samantha", into: scratch)
        let all = try await Self.inputs(from: audio, format: format)
        let seconds = Double(all.reduce(0) { $0 + Int($1.buffer.frameLength) }) / format.sampleRate

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingNewest(CaptureNode.bufferedBufferCount(forSeconds: 100)))
        for input in all { _ = continuation.yield(input) }
        continuation.finish()

        // Everything is already queued. Time from "the analyzer exists" to "the transcript is
        // committed" is therefore the catch-up cost for a whole utterance's worth of backlog — a far
        // harsher test than the 400 ms the window actually buffers.
        let start = ContinuousClock.now
        let session = try await engine.begin(locale: .primary, onUpdate: { _ in })
        for await chunk in stream { session.feed(chunk) }
        let outcome = try await session.finishAndCommit()
        let elapsed = Self.seconds(start.duration(to: ContinuousClock.now))

        let factor = seconds / max(elapsed, 0.0001)
        print("""

            CATCH-UP
              buffered         \(String(format: "%.2f", seconds)) s of audio
              consumed in      \(String(format: "%.3f", elapsed)) s  (\(String(format: "%.1f", factor))x realtime)
              a 0.40 s window therefore costs \(String(format: "%.1f", 0.40 / max(factor, 0.0001) * 1000)) ms
              text             \(outcome.text)

            """)

        #expect(!outcome.text.isEmpty)
        // The design claim, with a wide margin: even 5x would make a 400 ms head start cost 80 ms.
        #expect(factor > 5, "buffered audio was consumed at only \(String(format: "%.1f", factor))x realtime")
    }
}
