import Foundation
import Testing
@testable import EdictKit

// MARK: - Synthetic PCM

/// A tiny signal builder, because the interesting cases here are all *levels* and *durations* and
/// both need to be exact.
///
/// Why synthetic and not audio files: the package declares no `resources:` clause and must not — see
/// RECON §24, where `Bundle.module` breaks codesigning — so a test fixture cannot be a .wav on disk.
/// That is a real limit, so the segmenter was also verified against six actual recordings (a real
/// two-speaker meeting, `say` output split by exact one-second silences, that same file attenuated
/// 30 dB and again with pink noise, a recording with every pause stripped, and the real 70-minute
/// meeting). Those results are recorded in the header of `SpeechSegmenter.swift` with their boundary
/// errors in milliseconds; what follows is the part that can live in CI.
private struct PCM {
    static let sampleRate: Double = 16_000

    var samples: [Int16] = []

    var duration: TimeInterval { Double(samples.count) / Self.sampleRate }

    /// Band-limited noise at a given RMS in dBFS. Noise rather than a sine because a sine's RMS is
    /// stable inside every 25 ms frame while real speech is not, and because a square wave — the lazy
    /// choice — has a perfectly flat envelope that would make the gate look better than it is.
    /// Deterministic: a fixed-seed LCG, so a failure is reproducible.
    mutating func addNoise(seconds: TimeInterval, dBFS: Double, seed: UInt64 = 0x2545F491) {
        let amplitude = pow(10, dBFS / 20) * 32767 * 1.732  // 1.732 = sqrt(3), uniform RMS -> peak
        var state = seed
        for _ in 0..<Int(seconds * Self.sampleRate) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double(Int64(bitPattern: state >> 11)) / Double(1 << 53) - 0.5
            samples.append(Int16(clamping: Int(unit * 2 * amplitude)))
        }
    }

    /// Speech-like: noise bursts whose level rises and falls, so frames inside one "word" span a
    /// realistic ~20 dB rather than sitting at one value.
    mutating func addSpeech(seconds: TimeInterval, peakDBFS: Double = -14, seed: UInt64 = 0x9E3779B9) {
        let syllable = 0.18
        var remaining = seconds
        var i = 0
        while remaining > 0.001 {
            let chunk = min(syllable, remaining)
            // Alternate a loud nucleus with a much quieter margin, the vowel/consonant contrast.
            let level = i % 3 == 2 ? peakDBFS - 18 : peakDBFS - Double(i % 2) * 4
            addNoise(seconds: chunk, dBFS: level, seed: seed &+ UInt64(i))
            remaining -= chunk
            i += 1
        }
    }

    mutating func addSilence(seconds: TimeInterval) {
        samples.append(contentsOf: repeatElement(0, count: Int(seconds * Self.sampleRate)))
    }

    /// Room tone: quiet noise instead of digital zeroes, which is what a microphone actually records
    /// and what the adaptive gate is supposed to measure.
    mutating func addRoomTone(seconds: TimeInterval, dBFS: Double = -55) {
        addNoise(seconds: seconds, dBFS: dBFS, seed: 0xDEADBEEF)
    }

    /// One loud frame and nothing around it — a mouse click, a chair creak.
    mutating func addClick() {
        addNoise(seconds: 0.03, dBFS: -8, seed: 0xC11C)
    }

    func run<T>(_ body: (UnsafeBufferPointer<Int16>) -> T) -> T {
        samples.withUnsafeBufferPointer(body)
    }
}

extension SpeechSegmenter {
    fileprivate func sections(_ pcm: PCM) -> [SpeechSection] {
        pcm.run { sections(inPCM: $0, sampleRate: PCM.sampleRate) }
    }
    fileprivate func speechDuration(_ pcm: PCM) -> TimeInterval {
        pcm.run { speechDuration(inPCM: $0, sampleRate: PCM.sampleRate) }
    }
    fileprivate func profile(_ pcm: PCM) -> Profile? {
        pcm.run { profile(inPCM: $0, sampleRate: PCM.sampleRate) }
    }
}

/// Every section a caller receives must satisfy these, on every input, no exceptions. Asserted from
/// each test rather than once, because a violation is only meaningful next to the input that caused
/// it — and because these are the properties the *integrator* is entitled to assume when they slice
/// a buffer by section and hand the slice to an analyzer. An overlap double-transcribes; a section
/// past the end of the file crashes on the slice.
private func expectWellFormed(
    _ sections: [SpeechSection],
    fileDuration: TimeInterval,
    _ label: Comment,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    var previousEnd = 0.0
    for section in sections {
        #expect(section.start >= 0, label, sourceLocation: sourceLocation)
        #expect(section.end <= fileDuration + 1e-9, label, sourceLocation: sourceLocation)
        #expect(section.duration > 0, label, sourceLocation: sourceLocation)
        #expect(section.start >= previousEnd - 1e-9, label, sourceLocation: sourceLocation)
        previousEnd = section.end
    }
}

// MARK: - Boundaries

/// Does it find the pauses, and does it find them in the right place?
///
/// Boundary accuracy is stated in milliseconds throughout. The tolerances are wide on purpose: the
/// segmenter deliberately pads each section outward by up to 150 ms (`edgePadding`) so a section does
/// not start mid-phoneme, so a boundary landing ~150 ms outside the true speech is the design working,
/// not drifting. What these assert is that it lands within one padding of truth and on the correct
/// *side* — sections reach into the silence, never into the neighbour's speech.
@Suite("SpeechSegmenter — boundaries")
struct SpeechSegmenterBoundaryTests {

    /// Four utterances separated by one second of room tone, which is the shape of a voice memo, a
    /// dictated list, or a two-person call. Boundaries known exactly because the buffer was built.
    @Test("Four utterances split by one-second pauses become four sections at the right seconds")
    func fourUtterances() {
        var pcm = PCM()
        var truth: [(start: TimeInterval, end: TimeInterval)] = []
        pcm.addRoomTone(seconds: 0.5)
        for length in [3.2, 3.8, 2.0, 3.8] {
            let start = pcm.duration
            pcm.addSpeech(seconds: length)
            truth.append((start, pcm.duration))
            pcm.addRoomTone(seconds: 1.0)
        }

        let sections = SpeechSegmenter().sections(pcm)
        expectWellFormed(sections, fileDuration: pcm.duration, "four utterances")
        #expect(sections.count == truth.count)
        guard sections.count == truth.count else { return }

        for (index, (section, want)) in zip(sections, truth).enumerated() {
            let startError = (section.start - want.start) * 1000
            let endError = (section.end - want.end) * 1000
            #expect(
                startError > -260 && startError < 60,
                "section \(index) starts \(startError) ms from the utterance; expected within one padding, biased early"
            )
            #expect(
                endError > -60 && endError < 260,
                "section \(index) ends \(endError) ms from the utterance; expected within one padding, biased late"
            )
        }
    }

    /// The 1.99-second utterance in the middle of the fixture above is *shorter* than
    /// `minSectionDuration`, and a bare length floor glued it to the next speaker across a full
    /// second of silence. This is that regression, isolated: three utterances of 3 s, 1.2 s, 3 s.
    @Test("A short utterance walled off by long silences is its own section, not the next one's prefix")
    func shortUtteranceIsNotGluedForward() {
        var pcm = PCM()
        pcm.addRoomTone(seconds: 0.4)
        pcm.addSpeech(seconds: 3.0)
        pcm.addRoomTone(seconds: 1.0)
        let shortStart = pcm.duration
        pcm.addSpeech(seconds: 1.2)
        let shortEnd = pcm.duration
        pcm.addRoomTone(seconds: 1.0)
        pcm.addSpeech(seconds: 3.0)
        pcm.addRoomTone(seconds: 0.4)

        let sections = SpeechSegmenter().sections(pcm)
        expectWellFormed(sections, fileDuration: pcm.duration, "short middle utterance")
        #expect(sections.count == 3, "expected the 1.2 s utterance to stand alone, got \(sections.count) sections")

        // Whatever the count, no section may span the whole short utterance *and* reach past the
        // silence into the next one — that is the specific error being guarded.
        for section in sections {
            let swallowsShort = section.start < shortStart + 0.2 && section.end > shortEnd + 0.9
            #expect(!swallowsShort, "a section ran from the short utterance across a 1 s silence: \(section.start)-\(section.end)")
        }
    }

    /// Brief pauses must not become boundaries, or an hour-long file becomes thousands of fragments.
    /// One utterance, breathing every 0.12 s, is one section.
    @Test("Pauses shorter than minSilenceDuration do not split a section")
    func briefPausesDoNotSplit() {
        var pcm = PCM()
        pcm.addRoomTone(seconds: 0.3)
        for _ in 0..<8 {
            pcm.addSpeech(seconds: 0.9)
            pcm.addRoomTone(seconds: 0.12)
        }
        pcm.addRoomTone(seconds: 0.3)

        let sections = SpeechSegmenter().sections(pcm)
        expectWellFormed(sections, fileDuration: pcm.duration, "breathing")
        #expect(sections.count == 1, "0.12 s pauses under a 0.20 s threshold produced \(sections.count) sections")
    }

    /// Sections are the unit a caller slices the buffer by, so the ordering and non-overlap
    /// guarantees are load-bearing across every input shape, not just the tidy ones.
    @Test("Ordering and non-overlap hold across ragged inputs", arguments: [
        [0.4, 1.0, 3.0, 0.25, 2.0, 0.9, 0.7, 1.4, 5.0],
        [3.0, 0.21, 3.0, 0.21, 3.0],
        [0.05, 0.05, 0.05, 12.0, 0.05, 0.05],
        [8.0, 2.5, 0.3, 0.3, 0.3, 0.3, 8.0],
    ])
    func raggedInputsStayWellFormed(_ lengths: [TimeInterval]) {
        var pcm = PCM()
        pcm.addRoomTone(seconds: 0.3)
        for (index, length) in lengths.enumerated() {
            if index.isMultiple(of: 2) { pcm.addSpeech(seconds: length) } else { pcm.addRoomTone(seconds: length) }
        }
        pcm.addRoomTone(seconds: 0.3)

        for options in [SpeechSegmenter.Options.standard, .longForm] {
            let sections = SpeechSegmenter(options: options).sections(pcm)
            expectWellFormed(sections, fileDuration: pcm.duration, "lengths \(lengths)")
        }
    }
}

// MARK: - The adaptive gate

/// The claim that justifies computing a gate instead of writing one down. RECON §19 measured a quiet
/// room at -61..-48 dBFS and speech at -18..-13, and the real 70-minute meeting sits between them at
/// -29.6 dB mean — so no constant covers the range, and these tests are the proof rather than the
/// assertion.
@Suite("SpeechSegmenter — the adaptive gate")
struct SpeechSegmenterGateTests {

    private func threeUtterances(speechDB: Double, roomDB: Double) -> PCM {
        var pcm = PCM()
        pcm.addRoomTone(seconds: 0.5, dBFS: roomDB)
        for _ in 0..<3 {
            pcm.addSpeech(seconds: 3.0, peakDBFS: speechDB)
            pcm.addRoomTone(seconds: 1.0, dBFS: roomDB)
        }
        return pcm
    }

    /// The headline: the same programme at four wildly different recording levels segments the same
    /// way. A fixed -40 dBFS gate would find three sections in the first two rows, nothing at all in
    /// the third, and would cut inside every word of the fourth.
    @Test("The same programme segments identically from -14 dBFS down to -70 dBFS speech",
          arguments: [(-14.0, -55.0), (-24.0, -62.0), (-44.0, -78.0), (-70.0, -95.0)])
    func gateFollowsTheRecordingLevel(speechDB: Double, roomDB: Double) {
        let pcm = threeUtterances(speechDB: speechDB, roomDB: roomDB)
        let segmenter = SpeechSegmenter()
        let sections = segmenter.sections(pcm)
        expectWellFormed(sections, fileDuration: pcm.duration, "speech at \(speechDB) dBFS")
        #expect(sections.count == 3, "speech at \(speechDB) dBFS gave \(sections.count) sections")

        guard let profile = segmenter.profile(pcm) else {
            Issue.record("no profile for speech at \(speechDB) dBFS")
            return
        }
        #expect(profile.gateBasis == .adaptive)
        // The gate has to sit in the empty band between the two, or it is measuring nothing.
        #expect(profile.gateDB > roomDB, "gate \(profile.gateDB) is below the room tone at \(roomDB)")
        #expect(profile.gateDB < speechDB - 6, "gate \(profile.gateDB) is inside speech at \(speechDB)")
    }

    /// Attenuating a whole file must not change where the cuts land. Verified on real audio too: the
    /// 17-second `say` fixture and a 30 dB-quieter copy produce byte-identical boundaries.
    @Test("Attenuating the whole file by 30 dB moves the gate 30 dB and the boundaries not at all")
    func attenuationMovesOnlyTheGate() {
        let loud = threeUtterances(speechDB: -14, roomDB: -55)
        let quiet = threeUtterances(speechDB: -44, roomDB: -85)
        let segmenter = SpeechSegmenter()

        let a = segmenter.sections(loud)
        let b = segmenter.sections(quiet)
        #expect(a.count == b.count)
        guard a.count == b.count else { return }
        for (x, y) in zip(a, b) {
            #expect(abs(x.start - y.start) < 0.05, "start moved \(x.start) -> \(y.start)")
            #expect(abs(x.end - y.end) < 0.05, "end moved \(x.end) -> \(y.end)")
        }

        guard let pl = segmenter.profile(loud), let pq = segmenter.profile(quiet) else {
            Issue.record("missing profile")
            return
        }
        #expect(abs((pl.gateDB - pq.gateDB) - 30) < 4, "gate moved \(pl.gateDB - pq.gateDB) dB, not ~30")
    }

    /// Steady background noise raises the floor, so the gate must rise with it rather than treating
    /// the room as speech.
    @Test("A noisy room raises the gate instead of turning the noise into sections")
    func noisyRoomRaisesTheGate() {
        var pcm = PCM()
        pcm.addRoomTone(seconds: 0.5, dBFS: -38)
        for _ in 0..<3 {
            pcm.addSpeech(seconds: 3.0, peakDBFS: -14)
            pcm.addRoomTone(seconds: 1.0, dBFS: -38)
        }
        let segmenter = SpeechSegmenter()
        let sections = segmenter.sections(pcm)
        expectWellFormed(sections, fileDuration: pcm.duration, "noisy room")
        #expect(sections.count == 3, "got \(sections.count) sections in a -38 dBFS room")
        if let profile = segmenter.profile(pcm) {
            #expect(profile.gateDB > -38, "gate \(profile.gateDB) sits at or below the -38 dBFS room tone")
        }
    }

    /// A recording with no quiet passage anywhere has no noise floor to estimate, so the percentile
    /// method must recognise that and stand down. Without this branch the gate landed inside the
    /// speech and cut a 103-second real recording in 23 mid-word places.
    @Test("Unbroken speech is not cut at invented silences")
    func unbrokenSpeechIsNotCutAtInventedSilences() {
        var pcm = PCM()
        pcm.addSpeech(seconds: 20.0, peakDBFS: -14)

        let segmenter = SpeechSegmenter()
        guard let profile = segmenter.profile(pcm) else {
            Issue.record("no profile")
            return
        }
        #expect(profile.gateBasis != .adaptive, "a file with no silence was treated as if it had a noise floor")
        #expect(profile.voicedFraction > 0.9, "only \(profile.voicedFraction) of unbroken speech read as voiced")

        let sections = segmenter.sections(pcm)
        expectWellFormed(sections, fileDuration: pcm.duration, "unbroken speech")
        #expect(sections.count == 1, "20 s of unbroken speech under a 30 s cap gave \(sections.count) sections")
    }

    /// Energy cannot tell a syllable from a chair creak, so a lone loud frame must not become a
    /// section. It would cost an analyzer setup and show the user a section they never spoke.
    @Test("A click in a silent passage is not a section")
    func clicksAreNotSections() {
        var pcm = PCM()
        pcm.addRoomTone(seconds: 1.0)
        pcm.addClick()
        pcm.addRoomTone(seconds: 1.0)
        pcm.addClick()
        pcm.addRoomTone(seconds: 1.0)

        let sections = SpeechSegmenter().sections(pcm)
        #expect(sections.isEmpty, "clicks produced \(sections.count) sections: \(sections.map(\.duration))")
    }
}

// MARK: - The length cap

/// A speaker who never pauses would otherwise yield one section the length of the file, which defeats
/// the whole point — one language decision, one un-retryable analyzer run.
@Suite("SpeechSegmenter — the length cap")
struct SpeechSegmenterLengthCapTests {

    @Test("Unbroken speech far past the cap is cut into sections that all respect it")
    func longUnbrokenSpeechIsCapped() {
        var pcm = PCM()
        pcm.addSpeech(seconds: 200.0, peakDBFS: -14)

        let options = SpeechSegmenter.Options(minSilenceDuration: 0.2, minSectionDuration: 2.5, maxSectionDuration: 30)
        let sections = SpeechSegmenter(options: options).sections(pcm)
        expectWellFormed(sections, fileDuration: pcm.duration, "200 s unbroken")
        #expect(sections.count >= 7, "200 s under a 30 s cap gave only \(sections.count) sections")
        for section in sections {
            #expect(section.duration <= 30 + 1e-6, "section of \(section.duration) s exceeds the 30 s cap")
        }
        // Nothing may be lost: cutting unbroken speech must partition it, not sample it.
        let covered = sections.reduce(0) { $0 + $1.duration }
        #expect(covered > pcm.duration * 0.95, "cutting lost \(pcm.duration - covered) s of speech")
    }

    /// The cap has to win over the length floor, or a pathological options set deadlocks the two
    /// against each other.
    @Test("The cap is honoured even when it is close to minSectionDuration")
    func capBeatsFloor() {
        var pcm = PCM()
        pcm.addSpeech(seconds: 60.0, peakDBFS: -14)

        let options = SpeechSegmenter.Options(minSilenceDuration: 0.2, minSectionDuration: 9, maxSectionDuration: 10)
        let sections = SpeechSegmenter(options: options).sections(pcm)
        expectWellFormed(sections, fileDuration: pcm.duration, "tight cap")
        #expect(!sections.isEmpty)
        for section in sections {
            #expect(section.duration <= 10 + 1e-6, "section of \(section.duration) s exceeds the 10 s cap")
        }
    }

    /// The cut should land at the quietest point available rather than at an arbitrary offset, since
    /// that is the point least likely to be inside a word.
    @Test("An over-long section is cut at its quietest interior point")
    func cutLandsAtTheQuietestPoint() {
        // 40 s of speech with one 0.3 s dip at 20 s — long enough to be the quietest point, too short
        // to be a section boundary under a 0.5 s silence threshold.
        var pcm = PCM()
        pcm.addSpeech(seconds: 20.0, peakDBFS: -14)
        let dipStart = pcm.duration
        pcm.addNoise(seconds: 0.3, dBFS: -60)
        pcm.addSpeech(seconds: 20.0, peakDBFS: -14)

        let options = SpeechSegmenter.Options(minSilenceDuration: 0.5, minSectionDuration: 2.5, maxSectionDuration: 25)
        let sections = SpeechSegmenter(options: options).sections(pcm)
        expectWellFormed(sections, fileDuration: pcm.duration, "one dip")
        #expect(sections.count == 2, "expected one cut, got \(sections.count) sections")
        if sections.count == 2 {
            let cut = sections[0].end
            #expect(abs(cut - (dipStart + 0.15)) < 0.5, "cut at \(cut) s, not at the \(dipStart) s dip")
        }
    }
}

// MARK: - Degenerate input

/// The inputs that make a segmenter return something absurd if nobody checked: nothing, almost
/// nothing, one frame, and options that contradict themselves. None of these may crash, hang, or
/// invent a section.
@Suite("SpeechSegmenter — degenerate input")
struct SpeechSegmenterDegenerateInputTests {

    @Test("An empty buffer yields no sections and no speech time")
    func emptyBuffer() {
        let empty = [Int16]()
        empty.withUnsafeBufferPointer { buffer in
            #expect(SpeechSegmenter().sections(inPCM: buffer, sampleRate: 16_000).isEmpty)
            #expect(SpeechSegmenter().speechDuration(inPCM: buffer, sampleRate: 16_000) == 0)
            #expect(SpeechSegmenter().profile(inPCM: buffer, sampleRate: 16_000) == nil)
        }
    }

    /// Explicitly required: pure silence returns an empty array, not one giant section. A single
    /// section covering an hour of nothing would send an hour of nothing to the transcriber and then
    /// report a words-per-minute of zero as if the model had failed.
    @Test("Digital silence returns an empty array, not one giant section")
    func digitalSilence() {
        var pcm = PCM()
        pcm.addSilence(seconds: 30)
        #expect(SpeechSegmenter().sections(pcm).isEmpty)
        #expect(SpeechSegmenter().speechDuration(pcm) == 0)
    }

    /// Room tone with nobody in the room is the realistic version of the case above: not zeroes, just
    /// quiet. It must also produce nothing.
    @Test("A recording of an empty room returns no sections")
    func roomToneOnly() {
        var pcm = PCM()
        pcm.addRoomTone(seconds: 30, dBFS: -58)
        let sections = SpeechSegmenter().sections(pcm)
        #expect(sections.isEmpty, "an empty room produced \(sections.count) sections")
    }

    /// A buffer shorter than one 25 ms frame still has to be handled, and a short loud one is real
    /// audio the caller would rather have than lose.
    @Test("A buffer shorter than one frame is handled without crashing")
    func shorterThanOneFrame() {
        var loud = PCM()
        loud.addNoise(seconds: 0.010, dBFS: -14)
        let sections = SpeechSegmenter().sections(loud)
        expectWellFormed(sections, fileDuration: loud.duration, "10 ms of speech")
        #expect(sections.count <= 1)

        var quiet = PCM()
        quiet.addNoise(seconds: 0.010, dBFS: -70)
        #expect(SpeechSegmenter().sections(quiet).isEmpty, "10 ms of near-silence produced a section")

        // One sample, the smallest buffer that is not empty.
        [Int16(12_000)].withUnsafeBufferPointer { buffer in
            let sections = SpeechSegmenter().sections(inPCM: buffer, sampleRate: 16_000)
            #expect(sections.count <= 1)
            for section in sections { #expect(section.end <= 1.0 / 16_000 + 1e-9) }
        }
    }

    /// A whole file shorter than `minSectionDuration` must still come back, or a two-second voice
    /// memo transcribes as nothing at all.
    @Test("A file shorter than minSectionDuration is still returned as one section")
    func fileShorterThanMinSection() {
        var pcm = PCM()
        pcm.addRoomTone(seconds: 0.2)
        pcm.addSpeech(seconds: 1.0)
        pcm.addRoomTone(seconds: 0.2)

        let sections = SpeechSegmenter().sections(pcm)  // minSectionDuration is 2.5 s
        expectWellFormed(sections, fileDuration: pcm.duration, "1 s memo")
        #expect(sections.count == 1, "a 1 s utterance gave \(sections.count) sections")
    }

    @Test("A non-positive or non-finite sample rate is refused rather than dividing by zero")
    func badSampleRate() {
        var pcm = PCM()
        pcm.addSpeech(seconds: 2)
        for rate in [0.0, -16_000.0, Double.nan, .infinity] {
            pcm.run { buffer in
                #expect(SpeechSegmenter().sections(inPCM: buffer, sampleRate: rate).isEmpty, "rate \(rate)")
                #expect(SpeechSegmenter().speechDuration(inPCM: buffer, sampleRate: rate) == 0, "rate \(rate)")
            }
        }
    }

    /// Options a caller could plausibly get wrong — zeroes, negatives, a cap under the floor, a cap
    /// of infinity. The contract is only that the result stays well-formed and the call returns.
    @Test("Contradictory options still return a well-formed result", arguments: [
        SpeechSegmenter.Options(minSilenceDuration: 0, minSectionDuration: 0, maxSectionDuration: 0),
        SpeechSegmenter.Options(minSilenceDuration: -1, minSectionDuration: -1, maxSectionDuration: -1),
        SpeechSegmenter.Options(minSilenceDuration: 0.2, minSectionDuration: 60, maxSectionDuration: 1),
        SpeechSegmenter.Options(minSilenceDuration: 0.2, minSectionDuration: 2.5, maxSectionDuration: .infinity),
        SpeechSegmenter.Options(minSilenceDuration: 100, minSectionDuration: 100, maxSectionDuration: 100),
    ])
    func contradictoryOptions(_ options: SpeechSegmenter.Options) {
        var pcm = PCM()
        pcm.addRoomTone(seconds: 0.3)
        for _ in 0..<4 {
            pcm.addSpeech(seconds: 2.5)
            pcm.addRoomTone(seconds: 0.6)
        }
        let sections = SpeechSegmenter(options: options).sections(pcm)
        expectWellFormed(sections, fileDuration: pcm.duration, "options \(options)")
    }

    /// Pure, so the same buffer must give the same answer every time — an integrator caches these
    /// against a file and re-derives them on a retry.
    @Test("Segmentation is deterministic")
    func deterministic() {
        var pcm = PCM()
        pcm.addRoomTone(seconds: 0.3)
        for _ in 0..<5 {
            pcm.addSpeech(seconds: 2.0)
            pcm.addRoomTone(seconds: 0.5)
        }
        let segmenter = SpeechSegmenter()
        let first = segmenter.sections(pcm).map { [$0.start, $0.end] }
        let second = segmenter.sections(pcm).map { [$0.start, $0.end] }
        #expect(first == second)
    }
}

// MARK: - speechDuration

/// The number the quality metric divides by. Getting it wrong does not crash anything — it quietly
/// makes "16 words per minute" either unexplained or wrongly excused.
@Suite("SpeechSegmenter — speechDuration")
struct SpeechSegmenterSpeechDurationTests {

    @Test("Speech time counts the speech and not the silence between it")
    func excludesSilence() {
        var pcm = PCM()
        pcm.addRoomTone(seconds: 0.5)
        for _ in 0..<4 {
            pcm.addSpeech(seconds: 3.0)
            pcm.addRoomTone(seconds: 3.0)
        }
        let segmenter = SpeechSegmenter()
        let speech = segmenter.speechDuration(pcm)

        // 12 s of speech in a ~27 s file. The gate loses word edges, so allow a generous band, but a
        // number anywhere near the file duration means the silence is being counted.
        #expect(speech > 9 && speech < 14, "12 s of speech in a \(pcm.duration) s file measured \(speech) s")
        #expect(speech < pcm.duration * 0.6)
    }

    /// The distinction that makes this method worth having separately from summing sections: on the
    /// real 70-minute meeting, voiced time is 58.6 % of the file where the sections sum to 86.8 %.
    /// Whichever way a caller measures, they must not measure the same thing twice by accident.
    @Test("Speech time is strictly less than the summed sections when the pauses are short")
    func differsFromSectionSum() {
        var pcm = PCM()
        pcm.addRoomTone(seconds: 0.3)
        for _ in 0..<12 {
            pcm.addSpeech(seconds: 1.0)
            pcm.addRoomTone(seconds: 0.15)  // under minSilenceDuration, so absorbed into a section
        }
        let segmenter = SpeechSegmenter()
        let sectionSum = segmenter.sections(pcm).reduce(0) { $0 + $1.duration }
        let speech = segmenter.speechDuration(pcm)
        #expect(speech < sectionSum, "voiced \(speech) s was not below the \(sectionSum) s the sections cover")
    }

    @Test("Silence has no speech time and unbroken speech has nearly all of it")
    func extremes() {
        var silence = PCM()
        silence.addRoomTone(seconds: 10, dBFS: -58)
        #expect(SpeechSegmenter().speechDuration(silence) == 0)

        var talking = PCM()
        talking.addSpeech(seconds: 10, peakDBFS: -14)
        let speech = SpeechSegmenter().speechDuration(talking)
        #expect(speech > talking.duration * 0.85, "unbroken speech measured only \(speech) of \(talking.duration) s")
        #expect(speech <= talking.duration + 1e-9)
    }

    @Test("Speech time does not change when section options change")
    func independentOfOptions() {
        var pcm = PCM()
        pcm.addRoomTone(seconds: 0.3)
        for _ in 0..<6 {
            pcm.addSpeech(seconds: 2.0)
            pcm.addRoomTone(seconds: 0.8)
        }
        let a = SpeechSegmenter(options: .standard).speechDuration(pcm)
        let b = SpeechSegmenter(options: .longForm).speechDuration(pcm)
        #expect(a == b, "retuning Options moved the quality metric from \(a) to \(b)")
    }
}

// MARK: - Value semantics

@Suite("SpeechSection")
struct SpeechSectionTests {

    @Test("Duration is the span, and never negative")
    func duration() {
        #expect(SpeechSection(start: 1.5, end: 4.0).duration == 2.5)
        #expect(SpeechSection(start: 4.0, end: 1.5).duration == 0, "a backwards section reported a negative length")
        #expect(SpeechSection(start: 2, end: 2).duration == 0)
    }

    /// Identity is part of equality, which is the right behaviour for a `ForEach` but surprising if
    /// you assumed two identical spans compare equal. Pinned so nobody has to find out by debugging.
    @Test("Identity participates in equality, so equal spans are not equal sections")
    func identityIsPartOfEquality() {
        let a = SpeechSection(start: 0, end: 1)
        let b = SpeechSection(start: 0, end: 1)
        #expect(a != b)
        #expect(a == SpeechSection(id: a.id, start: 0, end: 1))
        #expect(Set([a, a]).count == 1)
    }
}
