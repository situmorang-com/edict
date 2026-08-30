import AVFoundation
import CoreGraphics
import Foundation
import Speech
import Testing
@testable import EdictKit

/// The plumbing behind "hold Right Option for English, add Shift for Indonesian".
///
/// Three layers, tested separately because they fail differently:
///
/// 1. **Settings** — persistence and, more importantly, the reconciliation that stops a stale locale
///    identifier from wedging dictation.
/// 2. **`HotkeyBinding`** — the bit tests. These are pure arithmetic over raw flag words, which is the
///    only part of the hotkey path that *can* be tested: the tap itself needs Input Monitoring and a
///    human finger. The raw values used here are the ones RECON measured on this machine, including
///    Karabiner's `nonCoalesced` (`0x100`) stamp, which is exactly what makes an equality test wrong.
/// 3. **The engine, end to end, in Indonesian** — gated behind `EDICT_SPEECH_TESTS=1` because it
///    reserves locales, may download ~100 MB of assets, and runs the real model. See
///    `SecondaryLocaleEngineTests`.
@Suite("Secondary locale — settings")
@MainActor
struct SecondaryLocaleSettingsTests {

    private func settings() -> Settings { Settings(defaults: EphemeralDefaults()) }

    @Test("The language shortcut is on by default, on Shift, for Indonesian")
    func defaults() {
        let s = settings()
        #expect(s.secondaryLocaleEnabled)
        #expect(s.secondaryLocaleIdentifier == "id-ID")
        #expect(s.secondaryLocaleModifier == .shift)
        #expect(s.effectiveSecondaryLocaleIdentifier == "id-ID")
    }

    @Test("All three preferences survive a round trip through the same defaults")
    func persistence() {
        let store = EphemeralDefaults()
        let first = Settings(defaults: store)
        first.secondaryLocaleEnabled = false
        first.secondaryLocaleIdentifier = "de-DE"
        first.secondaryLocaleModifier = .control

        let second = Settings(defaults: store)
        #expect(second.secondaryLocaleEnabled == false)
        #expect(second.secondaryLocaleIdentifier == "de-DE")
        #expect(second.secondaryLocaleModifier == .control)
    }

    @Test("A modifier value that is no longer a case falls back rather than crashing")
    func unknownModifierRawValue() {
        let store = EphemeralDefaults()
        store.set("hyper", forKey: "edict.secondaryLocaleModifier")
        #expect(Settings(defaults: store).secondaryLocaleModifier == .shift)
    }

    @Test("The shortcut is inert when it is off, empty, or points at the primary language")
    func effectiveIdentifier() {
        let s = settings()
        s.secondaryLocaleEnabled = false
        #expect(s.effectiveSecondaryLocaleIdentifier == nil)

        s.secondaryLocaleEnabled = true
        s.secondaryLocaleIdentifier = "   "
        #expect(s.effectiveSecondaryLocaleIdentifier == nil)

        // Same language written the other way round. Underscores and case must not fool this, or the
        // modifier would build a second analyzer for the language already running.
        s.localeIdentifier = "en-US"
        s.secondaryLocaleIdentifier = "en_us"
        #expect(s.effectiveSecondaryLocaleIdentifier == nil)

        s.secondaryLocaleIdentifier = "id-ID"
        #expect(s.effectiveSecondaryLocaleIdentifier == "id-ID")
    }

    @Test("Framework identifiers are underscored and ours are hyphenated; they must still match")
    func localeKeyNormalisation() {
        #expect(Settings.localeKey("id-ID") == Settings.localeKey("id_ID"))
        #expect(Settings.localeKey("EN-us") == Settings.localeKey("en_US"))
        #expect(Settings.localeKey("id-ID") != Settings.localeKey("en-US"))
    }

    @Test("An unsupported secondary locale is reset to the default, not left to throw on every press")
    func reconcileResetsToDefault() {
        let s = settings()
        s.secondaryLocaleIdentifier = "xx-XX"
        let changed = s.reconcileSecondaryLocale(supportedIdentifiers: ["en_US", "id_ID", "de_DE"])
        #expect(changed)
        #expect(s.secondaryLocaleIdentifier == "id-ID")
        #expect(s.secondaryLocaleEnabled)
    }

    @Test("A supported locale is left exactly as the user wrote it")
    func reconcileLeavesSupportedAlone() {
        let s = settings()
        s.secondaryLocaleIdentifier = "de-DE"
        #expect(s.reconcileSecondaryLocale(supportedIdentifiers: ["en_US", "de_DE"]) == false)
        #expect(s.secondaryLocaleIdentifier == "de-DE")
    }

    @Test("When the default is unsupported too, the shortcut turns itself off")
    func reconcileDisables() {
        let s = settings()
        s.secondaryLocaleIdentifier = "xx-XX"
        #expect(s.reconcileSecondaryLocale(supportedIdentifiers: ["en_US"]))
        #expect(s.secondaryLocaleEnabled == false)
    }

    @Test("An empty supported list changes nothing — it means the question could not be asked")
    func reconcileIgnoresEmptyList() {
        let s = settings()
        s.secondaryLocaleIdentifier = "xx-XX"
        #expect(s.reconcileSecondaryLocale(supportedIdentifiers: []) == false)
        #expect(s.secondaryLocaleIdentifier == "xx-XX")
    }

    @Test("Resetting to defaults restores the shortcut")
    func resetToDefaults() {
        let s = settings()
        s.secondaryLocaleEnabled = false
        s.secondaryLocaleIdentifier = "de-DE"
        s.secondaryLocaleModifier = .command
        s.resetToDefaults()
        #expect(s.secondaryLocaleEnabled)
        #expect(s.secondaryLocaleIdentifier == "id-ID")
        #expect(s.secondaryLocaleModifier == .shift)
    }
}

// MARK: - The bit tests

@Suite("Secondary locale — modifier bits")
struct SecondaryLocaleBindingTests {

    /// Raw flag words as RECON measured them on this machine. Every one carries `nonCoalesced`
    /// (`0x100`), which Karabiner's virtual keyboard stamps on every synthesised event — the reason
    /// these must be bit-tested and never compared for equality.
    private enum Raw {
        static let rightOption: UInt64 = 0x0008_0140
        static let rightOptionPlusRightShift: UInt64 = 0x0008_0144 | 0x0002_0000
        static let rightOptionPlusLeftShift: UInt64 = 0x0008_0142 | 0x0002_0000
        static let rightOptionPlusLeftCommand: UInt64 = 0x0008_0148 | 0x0010_0000
        static let none: UInt64 = 0x0000_0100
    }

    @Test("Right Option + Shift reads as alternate; Right Option alone does not")
    func shiftAlongsideRightOption() {
        let binding = HotkeyBinding(.rightOption, alternate: .shift)
        #expect(binding.isAlternateHeld(rawFlags: Raw.rightOptionPlusRightShift))
        #expect(binding.isAlternateHeld(rawFlags: Raw.rightOptionPlusLeftShift))
        #expect(binding.isAlternateHeld(rawFlags: Raw.rightOption) == false)
        #expect(binding.isAlternateHeld(rawFlags: Raw.none) == false)
        // A different modifier is not the language modifier.
        #expect(binding.isAlternateHeld(rawFlags: Raw.rightOptionPlusLeftCommand) == false)
    }

    @Test("Both Shift keys are exempt from chord cancellation, and nothing else is")
    func exemptKeyCodes() {
        let binding = HotkeyBinding(.rightOption, alternate: .shift)
        #expect(binding.alternateKeyCodes == [56, 60])
        #expect(binding.alternateKeyCodes.contains(55) == false)   // left command
        #expect(binding.alternateKeyCodes.contains(58) == false)   // left option
    }

    @Test("No modifier configured means no alternate and no exemption")
    func noModifier() {
        let binding = HotkeyBinding(.rightOption, alternate: nil)
        #expect(binding.alternateMask == 0)
        #expect(binding.alternateKeyCodes.isEmpty)
        #expect(binding.isAlternateHeld(rawFlags: Raw.rightOptionPlusRightShift) == false)
    }

    /// The collision case. Option as the language modifier while the hotkey *is* Right Option would,
    /// without the subtraction in `HotkeyBinding.init`, make every single hold look alternate — every
    /// English utterance would silently run the Indonesian model.
    @Test("A modifier that collides with the hotkey keeps only the other side")
    func collisionWithHotkey() {
        let binding = HotkeyBinding(.rightOption, alternate: .option)
        #expect(binding.alternateKeyCodes == [58])                       // left option only
        #expect(binding.isAlternateHeld(rawFlags: Raw.rightOption) == false)
        #expect(binding.isAlternateHeld(rawFlags: Raw.rightOption | 0x20))
    }

    @Test("Control collides with Right Control the same way")
    func collisionWithRightControl() {
        let binding = HotkeyBinding(.rightControl, alternate: .control)
        #expect(binding.alternateKeyCodes == [59])                       // left control only
        // Right Control's own down-flags must not satisfy its own modifier.
        #expect(binding.isAlternateHeld(rawFlags: 0x0004_2100) == false)
        #expect(binding.isAlternateHeld(rawFlags: 0x0004_2101))
    }

    @Test("Every modifier resolves to two sides and a shared bit")
    func allModifiers() {
        for modifier in HotkeyModifier.allCases {
            #expect(modifier.sides.count == 2)
            #expect(modifier.deviceIndependentBit != 0)
            // fn has no device bit and is therefore deliberately not a choice here.
            #expect(modifier.sides.allSatisfy { $0.deviceBit != 0 })
            let binding = HotkeyBinding(.f13, alternate: modifier)
            #expect(binding.alternateKeyCodes.count == 2)
        }
    }
}

// MARK: - The end-to-end proof

/// Proves an utterance can actually run in the secondary locale, against the real model.
///
/// Gated behind `EDICT_SPEECH_TESTS=1` and skipped by default, for three reasons that all make it a
/// bad citizen of a unit-test suite: it takes locale *reservations* (which persist across process
/// launches and cap at 5), it may download ~100 MB of Indonesian assets on a cold machine, and it
/// shells out to `say` to synthesise speech. Run it deliberately:
///
///     EDICT_SPEECH_TESTS=1 swift test --filter SecondaryLocaleEngine
///
/// It exists because the hotkey chord itself cannot be tested — the tap needs Input Monitoring and a
/// human finger — so this is the only way to prove the half that matters: that `.secondary` builds a
/// module for the second locale, that the audio format is right, and that Indonesian speech comes back
/// as Indonesian words rather than the confident English nonsense a silent fallback would produce.
@Suite("Secondary locale — engine end to end", .enabled(if: ProcessInfo.processInfo.environment["EDICT_SPEECH_TESTS"] == "1"))
struct SecondaryLocaleEngineTests {

    /// One Indonesian sentence, spoken by the system voice. Words chosen to be unambiguous and to
    /// share no plausible English homophone, so a wrong-model transcript cannot accidentally pass.
    private static let sentence = "Halo, nama saya Edmund dan saya sedang menguji aplikasi dikte ini."

    private func synthesise(_ text: String, voice: String, into directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", url.path, text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AudioImportError.unreadable(filename: url.lastPathComponent, reason: "say failed")
        }
        return url
    }

    @Test("Both locales are reserved, and an Indonesian utterance transcribes as Indonesian")
    func secondaryUtterance() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("edict-secondary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let engine = SpeechEngine()
        try await engine.prepare(localeIdentifier: "en-US")
        try await engine.prepareSecondary(localeIdentifier: "id-ID")

        // Both slots held at once — and only those two. RECON §6: 5 maximum, they persist across
        // process launches keyed to the bundle identifier, and a leak is invisible until reservation
        // starts failing outright.
        //
        // `#expect(reserved.count <= 5)` used to stand here and could not fail: the framework throws
        // at six and `reserve` catches the throw and evicts, so the count is five or fewer by
        // construction — including in the state the assertion was written to rule out, where Edict
        // has permanently leaked all five slots. Pruning first, which is exactly what the app does at
        // launch, and then naming the exact set is the version that can fail: after preparing two
        // languages, a slot held for any third one is a slot Edict took and forgot.
        await engine.pruneReservations()
        let reserved = Set(await engine.reservedLocaleIdentifiers())
        #expect(reserved.contains("en_US"))
        #expect(reserved.contains("id_ID"))
        #expect(
            reserved == ["en_US", "id_ID"],
            "slots are held for languages this engine never prepared: \(reserved.sorted())"
        )

        // Assets may need fetching on a cold machine. The engine deliberately refuses to run the
        // utterance in the wrong language while that is happening, so wait for it here instead.
        var attempts = 0
        while await engine.secondaryModelState != .ready, attempts < 300 {
            _ = try? await engine.begin(locale: .secondary, onUpdate: { _ in })
            await engine.cancel()
            try await Task.sleep(for: .seconds(1))
            attempts += 1
        }
        #expect(await engine.secondaryModelState == .ready)

        let format = await engine.bestAudioFormat(secondary: true)
        #expect(format?.sampleRate == 16_000)
        #expect(format?.channelCount == 1)

        let audio = try synthesise(Self.sentence, voice: "Damayanti", into: scratch)
        let importer = AudioFileImporter(url: audio, analyzerFormat: format)
        let stream = try await importer.start(onProgress: { _ in })

        let outcome = try await engine.transcribe(
            input: stream,
            module: .dictation,
            locale: .secondary,
            biasing: [],
            onUpdate: { _ in }
        )

        let text = outcome.text.lowercased()
        #expect(!text.isEmpty)
        // Two Indonesian function words that no English acoustic model would produce from this audio.
        #expect(text.contains("saya"))
        #expect(text.contains("nama") || text.contains("menguji") || text.contains("aplikasi"))

        // And the primary still works afterwards, from the same engine instance — the two locales
        // must not be fighting over one prepared module.
        let english = try synthesise("This is an English sentence for the primary model.", voice: "Samantha", into: scratch)
        let englishImporter = AudioFileImporter(url: english, analyzerFormat: await engine.bestAudioFormat())
        let englishStream = try await englishImporter.start(onProgress: { _ in })
        let englishOutcome = try await engine.transcribe(
            input: englishStream,
            module: .dictation,
            locale: .primary,
            biasing: [],
            onUpdate: { _ in }
        )
        #expect(englishOutcome.text.lowercased().contains("english"))

        await engine.clearSecondary()
        let afterRelease = await engine.reservedLocaleIdentifiers()
        #expect(afterRelease.contains("id_ID") == false)
    }
}
