//
//  SpeechSegmenter.swift
//  Splits a file's audio into speech sections at natural silences, so each section can be
//  transcribed on its own and a language chosen per section.
//
//  WHY THIS EXISTS
//
//  A 70-minute meeting handed to one analyzer is one language decision for 70 minutes of audio, and
//  one 40-minute run of unbroken speech if the speaker never pauses. Cutting the file at silences
//  first turns that into a few hundred independent decisions, each over audio short enough to be a
//  single language and short enough to retry.
//
//  WHY ENERGY AND NOT A MODEL
//
//  Zero third-party dependencies is a hard project rule, and the platform's own voice-activity
//  surface is not separable from the transcriber. Energy is also enough: we are not classifying
//  voice against music, we are finding pauses. What energy CANNOT do is tell speakers apart — see
//  "WHAT THIS IS NOT" below, which is measured, not hedged.
//
//  WHY THE GATE IS ADAPTIVE
//
//  RECON §19 calibrated this machine: a quiet room measures -61..-48 dBFS RMS and speech -18..-13.
//  A fixed gate anywhere in that gap looks safe and is not. The real 70-minute meeting this project
//  was diagnosed against measures mean -29.6 dB overall — far-field, so its speech sits near where a
//  fixed gate would expect quiet, while a clean fixture recorded on the same machine peaks 30 dB
//  higher. One constant cannot serve both, and the proof is in the fixtures: the same 17-second
//  recording at full level and attenuated by 30 dB produces byte-identical section boundaries here,
//  with the gate moving from -47.5 to -77.5 dBFS to follow it. A -40 dBFS constant finds nothing at
//  all in the quiet copy.
//
//  Method, stated plainly. Frame the audio into non-overlapping 25 ms hops, take RMS in dBFS per
//  frame, and then take one of three routes:
//
//   1. NORMAL. Noise floor = 10th percentile of the frame values, speech level = 95th. Percentiles,
//      not min/max, because one clipped sample or one digital-silence frame would otherwise set the
//      whole scale. Gate = floor + max(6 dB, 35 % of the span between them), clamped to sit no more
//      than 35 dB and no less than 6 dB below the speech level.
//   2. NO SILENCE PRESENT. If that 10th percentile is itself above -35 dBFS, the file has no quiet
//      passage to measure and the "floor" is really the bottom of the speech. The gate goes below
//      everything and `maxSectionDuration` does the cutting instead. Skipping this check put the
//      gate 8.5 dB under the voice on a pauseless recording and cut it in 23 places, all mid-word.
//   3. TOO LITTLE TO GO ON. Under 20 frames, or a span under 12 dB: an absolute -40 dBFS gate, which
//      is correct at both degenerate ends — digital silence passes nothing and returns an empty
//      array, a level-constant voice passes everything and is cut by length.
//
//  WHY SECTIONS ARE GROWN, NOT MERGED
//
//  The obvious shape — cut at every silence, then merge the fragments that came out too short — has
//  to pick a direction for each merge, and on real audio that choice is a coin flip that lands on
//  the wrong side. Measured on the two-speaker fixture: the pauses *between* the four speaker turns
//  are 0.20-0.30 s, and the pauses *inside* the turns are also 0.20-0.30 s. Merging each short
//  fragment into its nearer neighbour crosses two of the three turn boundaries.
//
//  So a section is grown instead: open at the first speech, keep absorbing runs, and close at a
//  silence that is long enough and late enough — or at one long enough to settle the matter alone
//  (`decisiveSilence`). Nothing is ever merged, so the direction question never arises, and every
//  ambiguous case resolves the same way: forward, into the next section.
//
//  MEASURED, against ground truth rather than against itself
//
//    fixture                                     sections     mean |boundary error|
//    two speakers, four turns, 17 s (real)         4 of 4               101 ms
//    four utterances split by exactly 1.0 s        4 of 4               157 ms
//      the same, attenuated 30 dB                  4 of 4               157 ms  (identical bounds)
//      the same, plus pink noise at -45 dBFS       4 of 4               154 ms
//    103 s with every pause stripped out           5, all <= 30 s        n/a  (cut by length)
//    5 s of digital silence                        0                     n/a
//    10 ms, shorter than one frame                 1                     n/a
//
//  Both fixture sets are biased outward by the 150 ms `edgePadding`, which is deliberate; the raw
//  gate crossings land within 0-16 ms of the true onsets. On the real 70-minute meeting: 1043
//  sections at `standard` (median 3.3 s) or 374 at `longForm` (median 12.5 s), 58.6 % of the file
//  voiced against 41.4 % silence, segmented in 39 ms — about 100,000x realtime.
//
//  WHAT THIS IS NOT
//
//  Not diarization. Energy finds pauses; a speaker change with no pause is invisible, and a pause
//  inside one speaker's turn is indistinguishable from a handover. The 17-second fixture is proof:
//  its intra-turn pauses are *longer* than its inter-turn ones, and the four sections come out right
//  because of `minSectionDuration`, not because the boundaries were recognised as handovers. Do not
//  present a section as a speaker.
//
//  Not a fix for bad audio either. The measurements above say where the *cuts* land, and nothing
//  about whether the model will transcribe what is inside them. On the 70-minute meeting it will
//  largely not, and no amount of segmentation changes that.
//

import Foundation

// MARK: - A section

/// One contiguous stretch of a file that contains speech, in seconds from the start of the file.
///
/// Sections carry an identity so a UI can list them and a queue can track them across a re-run.
/// That identity is part of equality, so two sections spanning the same seconds are *not* equal —
/// compare `start` and `end` when what you mean is "the same span".
public struct SpeechSection: Sendable, Hashable, Identifiable {
    /// Stable per-instance identity, for `List`/`ForEach` and for progress bookkeeping.
    public var id: UUID
    /// Seconds from the start of the file. Always `>= 0` and `< end`.
    public var start: TimeInterval
    /// Seconds from the start of the file. Never past the file's own duration.
    public var end: TimeInterval

    /// Length in seconds. Never negative, even if a caller writes `end` backwards.
    public var duration: TimeInterval { max(0, end - start) }

    public init(id: UUID = UUID(), start: TimeInterval, end: TimeInterval) {
        self.id = id
        self.start = start
        self.end = end
    }
}

// MARK: - The segmenter

/// Energy-based speech segmentation over one PCM buffer. Pure, synchronous, and free of I/O — the
/// caller already has the samples, and everything decided here is decided from those samples alone,
/// so every branch is reachable from a unit test without an audio device or a model on disk.
public struct SpeechSegmenter: Sendable {

    // MARK: Options

    public struct Options: Sendable {
        /// How much quiet has to pass before a section is allowed to end. 0.20 s is a normal
        /// inter-phrase pause, and it is what the real two-speaker fixture needs: its speaker
        /// handovers are only 0.20-0.30 s of quiet. Swept on that fixture, holding everything else:
        /// 0.15 s and 0.20 s both recover all four turns, 0.30 s finds two, 0.35 s finds one. Growing
        /// sections (see the file header) is what keeps a threshold this small from fragmenting.
        public var minSilenceDuration: TimeInterval

        /// The floor on a section's length, and in practice its target length — a section closes at
        /// the first qualifying silence *after* this much speech, so sections come out a little
        /// longer than this and rarely much longer.
        ///
        /// This is the one knob with a real trade-off, and it is a trade-off between two files:
        /// short values track speaker changes in a dense conversation, long values give a language
        /// chooser more material and cost fewer transcription passes on an hour-long recording.
        /// Swept on the 17 s four-turn fixture: 2.0, 2.5 and 3.0 s all recover all four turns, 4.0 s
        /// merges two of them. Swept on the real 70-minute meeting, it is the difference between
        /// 1043 sections and 374. Hence 2.5 for `standard`, comfortably inside the range that is
        /// right on the short file; hence also `longForm`, for the long one.
        public var minSectionDuration: TimeInterval

        /// The cap that keeps a speaker who never pauses from yielding one section the length of the
        /// file. A section over this length is cut at its quietest interior point and the halves are
        /// re-checked. This is a real cut through audio that contains no silence, so it is a last
        /// resort, not a preference: it is why the value is well above `minSectionDuration`.
        public var maxSectionDuration: TimeInterval

        public init(
            minSilenceDuration: TimeInterval = 0.20,
            minSectionDuration: TimeInterval = 2.5,
            maxSectionDuration: TimeInterval = 30
        ) {
            self.minSilenceDuration = minSilenceDuration
            self.minSectionDuration = minSectionDuration
            self.maxSectionDuration = maxSectionDuration
        }

        /// Tuned on the real fixtures this was verified against. Tracks speaker changes in a dense
        /// conversation; on the real 70-minute meeting it produces 1043 sections, median 3.3 s.
        public static let standard = Options()

        /// For hour-long recordings, where `standard` would produce more sections than a caller
        /// wants to run two transcription passes over: 374 instead of 1043 on the 70-minute meeting,
        /// median 12.5 s instead of 3.3 s.
        ///
        /// The cost is explicit, not hidden: at a 0.35 s idea of a pause this preset finds *one*
        /// section in the 17-second four-turn fixture, where `standard` finds all four. Use it when
        /// section count is the problem, not when boundary accuracy is.
        public static let longForm = Options(
            minSilenceDuration: 0.35,
            minSectionDuration: 12,
            maxSectionDuration: 45
        )
    }

    // MARK: Tuning that is not a caller's business

    /// Frame hop, and also the frame length — non-overlapping. 25 ms sits in the middle of the
    /// 20-30 ms band that voice activity detection has used since forever: long enough for a stable
    /// RMS at speech frequencies, short enough that a boundary lands inside one frame's width.
    private static let frameSeconds: TimeInterval = 0.025

    /// How far a section reaches past the speech that defined it, capped at half the adjoining
    /// silence so two sections can touch but never overlap.
    ///
    /// Not cosmetic. An energy gate always loses the ramp at a word's edges — the onset of a
    /// fricative crosses the gate late and its tail crosses back early — so a section cut exactly
    /// at the gate crossings starts and ends mid-phoneme. It also has a measurable effect on
    /// accuracy against ground truth: on the two-speaker fixture, padding moves the boundary error
    /// from -253 ms (systematically early, since every boundary sits at the *start* of the silence
    /// that follows the turn) to -142 ms, centred in the silence where a human would put it.
    private static let edgePadding: TimeInterval = 0.15

    /// Percentiles of the frame-energy distribution used for the noise floor and the speech level.
    private static let floorPercentile = 10.0
    private static let speechPercentile = 95.0

    /// Below this floor-to-speech span the distribution has no two modes to separate, so the
    /// percentile method has nothing to work with and the absolute gate takes over.
    private static let minDynamicRange = 12.0

    /// Fallback gate. Chosen from RECON §19's calibration to sit in the empty band between a quiet
    /// room (-61..-48 dBFS) and speech (-18..-13), used only when the adaptive method is inapplicable.
    private static let absoluteGateDB = -40.0

    /// Fewer frames than this and a percentile is a guess about a handful of numbers.
    private static let minFramesForAdaptiveGate = 20

    /// How far below the 95th-percentile speech level the gate may ever sit. Speech's own
    /// frame-to-frame range — a stressed vowel against a weak fricative — spans roughly 30 dB, so a
    /// gate further down than this is not catching quieter speech, it is catching the room. It also
    /// stops a file with an enormous span (digital silence against loud speech) from computing a
    /// gate 70 dB below the voice.
    private static let maxGateDepthBelowSpeech = 35.0

    /// Shortest run of above-gate frames that counts as speech. Energy alone cannot tell a syllable
    /// from a mouse click, a chair creak, or a lip smack, and every one of those is a single loud
    /// frame in an otherwise quiet passage. Without this, a click surrounded by silence becomes its
    /// own 75 ms section — a transcription pass over nothing, and a section in the UI that is not a
    /// thing the user said. 100 ms is under the shortest real syllable.
    private static let minRunSeconds: TimeInterval = 0.10

    /// A tenth-percentile frame energy above this is not a room, it is a voice: the file contains no
    /// silence to measure. RECON §19 calibrated the alternative — a quiet room is -61..-48 dBFS and
    /// speech is -18..-13 — and the far-field 70-minute meeting floors at -48.5 dBFS, so -35 leaves
    /// real headroom above any plausible room tone. See `GateBasis.noSilencePresent`.
    private static let noiseFloorCeilingDB = -35.0

    /// A silence long enough to close a section on its own, even when the section has not reached
    /// `minSectionDuration`: `max(4 x minSilenceDuration, 0.8 s)`.
    ///
    /// `minSectionDuration` exists to stop brief pauses fragmenting a turn; it is not meant to refuse
    /// an unmistakable break. Measured: on a four-utterance fixture separated by exactly 1.0 s of
    /// silence, one utterance is only 1.99 s long, so a bare length floor of 2.5 s glued it to the
    /// *next speaker* across a full second of silence — precisely the error this file exists to avoid.
    ///
    /// The 0.8 s absolute term is why this is not simply a multiple. A pure multiple of 3x put the
    /// threshold at 0.6 s under `standard`, and on the real 70-minute meeting 0.6 s pauses are so
    /// common that the override fired constantly and effectively repealed `minSectionDuration`:
    /// 1300 sections, median 2.53 s. Anchoring at 0.8 s — long enough that no one would call it a
    /// breath — restores the floor's meaning on long-form audio while still catching the fixture's
    /// full-second breaks. The multiple then only matters for a preset like `longForm` that has
    /// deliberately raised its idea of a pause.
    private static func decisiveSilence(for options: Options) -> TimeInterval {
        max(4 * max(0, options.minSilenceDuration), 0.8)
    }

    /// Absolute floor on a section, below which the `decisiveSilence` override does not apply.
    ///
    /// Without it, a one-word interjection walled off by long pauses — a "ya", an "okay" — becomes
    /// its own section. On the real 70-minute meeting that produced sections as short as 0.38 s, and
    /// a section that short is not worth an analyzer: too little audio to identify a language from,
    /// and a fixed setup cost either way. Sections under this length keep growing forward instead,
    /// which is the same direction every other decision in this file takes.
    private static let minViableSectionSeconds: TimeInterval = 0.6

    /// Window for the smoothing used to locate a "quietest interior point". A single 25 ms frame's
    /// minimum lands on a glottal closure inside a vowel; 100 ms lands on an actual lull.
    private static let smoothingSeconds: TimeInterval = 0.1

    /// Guard against a pathological options set turning the splitter into a section factory.
    private static let maxSplitIterations = 100_000

    // MARK: State

    public let options: Options

    public init(options: Options = .standard) {
        self.options = options
    }

    // MARK: - Public API

    /// Energy-based segmentation over 16 kHz mono Int16 PCM — the analyzer's format.
    ///
    /// Guarantees, all of them tested: the result is ordered by `start`, no two sections overlap,
    /// every section lies inside `[0, frames.count / sampleRate]`, and every section has a positive
    /// duration. Audio with no speech in it returns an empty array rather than one section covering
    /// the silence.
    ///
    /// The buffer is expected mono. Interleaved stereo is not rejected — it segments, because both
    /// channels carry the same pauses — but the reported times would be halved, so resample first.
    public func sections(inPCM frames: UnsafeBufferPointer<Int16>, sampleRate: Double) -> [SpeechSection] {
        guard sampleRate.isFinite, sampleRate > 0, !frames.isEmpty else { return [] }

        let analysis = Self.analyse(frames, sampleRate: sampleRate)
        guard !analysis.frameDB.isEmpty else { return [] }

        let runs = speechRuns(in: analysis)
        guard !runs.isEmpty else { return [] }

        let grown = growSections(from: runs, hop: analysis.frameSeconds)
        let padded = pad(grown, fileDuration: analysis.fileDuration)
        let capped = splitOverlongSections(padded, analysis: analysis)
        return capped.map { SpeechSection(start: $0.start, end: $0.end) }
    }

    /// Total detected speech time. The quality metric needs this, so low words-per-minute is not
    /// reported for a file that is mostly silence.
    ///
    /// This is the time above the gate — voiced frames only — and deliberately **not** the summed
    /// duration of `sections(inPCM:sampleRate:)`. The difference is not academic. Measured on the
    /// real 70-minute meeting: voiced time is 2458 s, 58.6 % of the file, while the sections that
    /// cover it sum to 3643 s, 86.8 %, because a section absorbs every pause shorter than
    /// `minSilenceDuration` by design. That file produced 1128 words. Divided by the section total it
    /// is 18.6 words per minute, barely different from the 16 you get from raw wall-clock duration
    /// and just as uninformative; divided by voiced time it is 27.5, which says the right thing —
    /// still far below the ~150 of normal speech, and not because nobody was talking.
    ///
    /// It also means this answer depends only on the gate, not on how sections were grown, so the
    /// quality metric does not move when someone retunes `Options`.
    public func speechDuration(inPCM frames: UnsafeBufferPointer<Int16>, sampleRate: Double) -> TimeInterval {
        guard sampleRate.isFinite, sampleRate > 0, !frames.isEmpty else { return 0 }
        let analysis = Self.analyse(frames, sampleRate: sampleRate)
        let voiced = analysis.frameDB.reduce(0) { $1 > analysis.gateDB ? $0 + 1 : $0 }
        return min(analysis.fileDuration, Double(voiced) * analysis.frameSeconds)
    }

    // MARK: - Diagnostics

    /// Which of the three rules set the gate for a given buffer.
    public enum GateBasis: String, Sendable, Hashable {
        /// The normal path: a percentile-derived gate between this file's own noise floor and its
        /// own speech level.
        case adaptive
        /// The file has no silence in it at all — its quietest tenth is above `noiseFloorCeilingDB`
        /// — so the gate was put below everything and `maxSectionDuration` does the cutting.
        case noSilencePresent
        /// Too few frames, or too flat a distribution, for a percentile to mean anything; the
        /// absolute -40 dBFS gate was used. Pure silence and very short buffers land here.
        case absolute
    }

    /// What the adaptive gate decided, and why. Exposed because when a file segments badly the first
    /// question is always "where did the gate land", and re-deriving it by hand from a 70-minute
    /// buffer is not a debugging session anybody enjoys.
    public struct Profile: Sendable, Hashable {
        /// Total buffer length in seconds.
        public var fileDuration: TimeInterval
        /// Number of 25 ms frames measured.
        public var frameCount: Int
        /// 10th-percentile frame RMS, dBFS. The noise-floor estimate.
        public var noiseFloorDB: Double
        /// 95th-percentile frame RMS, dBFS. The speech-level estimate.
        public var speechLevelDB: Double
        /// Mean frame RMS in dBFS, for comparison against a level meter.
        public var meanDB: Double
        /// The gate actually used, dBFS.
        public var gateDB: Double
        /// Which rule set `gateDB`.
        public var gateBasis: GateBasis
        /// Fraction of frames above the gate.
        public var voicedFraction: Double
    }

    /// Measure a buffer without segmenting it.
    public func profile(inPCM frames: UnsafeBufferPointer<Int16>, sampleRate: Double) -> Profile? {
        guard sampleRate.isFinite, sampleRate > 0, !frames.isEmpty else { return nil }
        let analysis = Self.analyse(frames, sampleRate: sampleRate)
        guard !analysis.frameDB.isEmpty else { return nil }
        let voiced = analysis.frameDB.reduce(0) { $1 > analysis.gateDB ? $0 + 1 : $0 }
        let mean = analysis.frameDB.reduce(0, +) / Double(analysis.frameDB.count)
        return Profile(
            fileDuration: analysis.fileDuration,
            frameCount: analysis.frameDB.count,
            noiseFloorDB: analysis.noiseFloorDB,
            speechLevelDB: analysis.speechLevelDB,
            meanDB: mean,
            gateDB: analysis.gateDB,
            gateBasis: analysis.gateBasis,
            voicedFraction: Double(voiced) / Double(analysis.frameDB.count)
        )
    }

    // MARK: - Framing and the gate

    private struct Analysis {
        var frameDB: [Double]
        var smoothedDB: [Double]
        var frameSeconds: TimeInterval
        var fileDuration: TimeInterval
        var noiseFloorDB: Double
        var speechLevelDB: Double
        var gateDB: Double
        var gateBasis: GateBasis
    }

    /// Floor for the log, so digital silence gets a finite number instead of -inf.
    ///
    /// -100 dBFS, not something arbitrarily lower, because this value goes into the noise-floor
    /// percentile and therefore into the gate. A -180 sentinel measurably breaks the gate: on the
    /// four-turn fixture, whose inter-turn silence is literal zeroes, the 10th percentile became
    /// -180 and 35 % of that span put the gate at -121 dBFS. -100 dBFS is a shade under the
    /// quantisation floor of 16-bit audio, so it is a real bound rather than a sentinel, and a frame
    /// of true digital silence still sits below any gate derived from it.
    private static let silenceFloorDB = -100.0

    private static func analyse(_ frames: UnsafeBufferPointer<Int16>, sampleRate: Double) -> Analysis {
        let hop = max(1, Int((frameSeconds * sampleRate).rounded()))
        let fileDuration = Double(frames.count) / sampleRate

        // A trailing partial frame is measured rather than dropped: on a file shorter than one hop
        // it is the only frame there is, and dropping it would make a one-second voice memo empty.
        var frameDB: [Double] = []
        frameDB.reserveCapacity(frames.count / hop + 1)
        var i = 0
        while i < frames.count {
            let end = min(i + hop, frames.count)
            var sum: Int64 = 0
            for j in i..<end {
                let v = Int64(frames[j])
                sum += v * v
            }
            let rms = (Double(sum) / Double(end - i)).squareRoot() / 32768.0
            // Clamped, not just guarded against zero. A frame holding a single +/-1 sample measures
            // -116 dBFS, and that poisons the noise-floor percentile exactly the way a -inf would:
            // caught by the -70 dBFS case of the level sweep, where the gate came out at -98 dBFS,
            // *below* the room tone it was supposed to sit above.
            frameDB.append(rms > 0 ? max(20 * log10(rms), silenceFloorDB) : silenceFloorDB)
            i = end
        }
        guard !frameDB.isEmpty else {
            return Analysis(
                frameDB: [], smoothedDB: [], frameSeconds: Double(hop) / sampleRate,
                fileDuration: fileDuration, noiseFloorDB: silenceFloorDB,
                speechLevelDB: silenceFloorDB, gateDB: absoluteGateDB, gateBasis: .absolute
            )
        }

        let sorted = frameDB.sorted()
        let floorDB = percentile(sorted, floorPercentile)
        let speechDB = percentile(sorted, speechPercentile)
        let span = speechDB - floorDB

        // Three ways to decide the gate, in priority order. Only the last is the interesting one.
        let gateDB: Double
        let basis: GateBasis
        if frameDB.count < minFramesForAdaptiveGate || span < minDynamicRange {
            // Not enough frames for a percentile to mean anything, or no two modes to separate.
            // The absolute gate is right at both degenerate ends: pure silence passes nothing and
            // returns an empty array, and a level-constant voice passes everything and gets cut by
            // `maxSectionDuration`.
            gateDB = absoluteGateDB
            basis = .absolute
        } else if floorDB > noiseFloorCeilingDB {
            // The quietest tenth of this file is still loud, so this file HAS no silence — nothing
            // here is a noise floor, and `floorDB` is just the bottom of the speech. Putting a gate
            // above it would cut inside words. Measured on a 103-second recording with every pause
            // stripped out: without this branch the gate landed 8.5 dB under the speech level and
            // produced 23 sections whose boundaries were all mid-speech; with it the file is one run
            // and `maxSectionDuration` cuts it at genuine energy minima, which is the honest answer
            // to "where would you break unbroken speech".
            //
            // -35 dBFS as the ceiling comes from RECON §19's calibration: a quiet room measures
            // -61..-48 dBFS and speech -18..-13, and even the far-field 70-minute meeting this
            // project was diagnosed against floors at -48.5. A tenth-percentile above -35 is not a
            // room, it is a voice.
            gateDB = floorDB - 6
            basis = .noSilencePresent
        } else {
            // 35 % up the span, floored 6 dB above the noise so room tone never passes, held 6 dB
            // below the speech level so a compressed recording is not gated into silence, and held
            // no more than `maxGateDepthBelowSpeech` under it — speech's own frame-to-frame range
            // does not reach further down than that, so anything lower is only admitting noise.
            let proposed = floorDB + max(6.0, 0.35 * span)
            gateDB = min(max(proposed, speechDB - maxGateDepthBelowSpeech), speechDB - 6.0)
            basis = .adaptive
        }

        return Analysis(
            frameDB: frameDB,
            smoothedDB: smooth(frameDB, windowFrames: max(1, Int((smoothingSeconds / (Double(hop) / sampleRate)).rounded()))),
            frameSeconds: Double(hop) / sampleRate,
            fileDuration: fileDuration,
            noiseFloorDB: floorDB,
            speechLevelDB: speechDB,
            gateDB: gateDB,
            gateBasis: basis
        )
    }

    /// Nearest-rank percentile over an already-sorted array.
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return silenceFloorDB }
        let idx = Int((p / 100 * Double(sorted.count - 1)).rounded())
        return sorted[min(max(idx, 0), sorted.count - 1)]
    }

    /// Centred moving average, used only to locate lulls. Averaging decibels rather than power is
    /// deliberate: we want the point that is quietest for the longest, not the point with least
    /// energy, and the log scale weights a sustained lull over one deep dip.
    private static func smooth(_ values: [Double], windowFrames: Int) -> [Double] {
        guard windowFrames > 1, values.count > windowFrames else { return values }
        var prefix: [Double] = [0]
        prefix.reserveCapacity(values.count + 1)
        for v in values { prefix.append(prefix[prefix.count - 1] + v) }
        let half = windowFrames / 2
        return (0..<values.count).map { i in
            let lo = max(0, i - half)
            let hi = min(values.count, i + half + 1)
            return (prefix[hi] - prefix[lo]) / Double(hi - lo)
        }
    }

    // MARK: - Runs, sections, padding, splitting

    /// Half-open frame ranges whose energy is above the gate, transients discarded. See `minRunSeconds`.
    private func speechRuns(in analysis: Analysis) -> [Range<Int>] {
        let minRunFrames = max(1, Int((Self.minRunSeconds / analysis.frameSeconds).rounded()))
        var runs: [Range<Int>] = []
        var start: Int?
        for (i, db) in analysis.frameDB.enumerated() {
            if db > analysis.gateDB {
                if start == nil { start = i }
            } else if let s = start {
                if i - s >= minRunFrames { runs.append(s..<i) }
                start = nil
            }
        }
        if let s = start, analysis.frameDB.count - s >= minRunFrames {
            runs.append(s..<analysis.frameDB.count)
        }
        // One exception to the transient filter: if it rejected *everything*, the file is shorter
        // than the filter or is one brief utterance, and returning nothing would lose real audio.
        if runs.isEmpty, analysis.frameDB.count <= minRunFrames,
           analysis.frameDB.contains(where: { $0 > analysis.gateDB }) {
            return [0..<analysis.frameDB.count]
        }
        return runs
    }

    private struct Span {
        var start: TimeInterval
        var end: TimeInterval
        var duration: TimeInterval { end - start }
    }

    /// Grow sections run by run, closing at a silence that is long enough *and* late enough — or at
    /// one that is long enough to settle the matter on its own. See the file header for why this
    /// replaces a cut-then-merge pass, and `decisiveSilenceMultiple` for the override.
    ///
    /// Comparisons are done in frames and converted once at the end — `hop` is the *actual* frame
    /// length, which is `frameSeconds` only when `frameSeconds * sampleRate` happens to be integral.
    private func growSections(from runs: [Range<Int>], hop: TimeInterval) -> [Span] {
        let minSilenceFrames = max(0, options.minSilenceDuration) / hop
        let minSectionFrames = max(0, options.minSectionDuration) / hop
        let decisiveSilenceFrames = Self.decisiveSilence(for: options) / hop
        let minViableFrames = Self.minViableSectionSeconds / hop

        var sections: [Span] = []
        var closedOnDecisiveSilence = false
        var openStart = runs[0].lowerBound
        var lastEnd = runs[0].upperBound

        for run in runs.dropFirst() {
            let gap = Double(run.lowerBound - lastEnd)
            let grown = Double(lastEnd - openStart)
            let qualifies = gap >= minSilenceFrames && grown >= minSectionFrames
            let decisive = gap >= decisiveSilenceFrames && grown >= minViableFrames
            if qualifies || decisive {
                sections.append(Span(start: Double(openStart) * hop, end: Double(lastEnd) * hop))
                closedOnDecisiveSilence = decisive
                openStart = run.lowerBound
            }
            lastEnd = run.upperBound
        }
        sections.append(Span(start: Double(openStart) * hop, end: Double(lastEnd) * hop))

        // A short *last* section usually means the file simply ended before a qualifying silence
        // arrived, so fold it back rather than emit a stub. Not, however, if the silence that opened
        // it was decisive: then it is a genuinely short final utterance and folding it into the
        // previous speaker across a long pause would be the same mistake, in reverse. And a whole
        // file shorter than `minSectionDuration` stays one section — losing a short voice memo
        // entirely would be worse than returning one that is under the floor.
        if sections.count > 1, !closedOnDecisiveSilence,
           let last = sections.last, last.duration < options.minSectionDuration {
            let prev = sections[sections.count - 2]
            sections.removeLast(2)
            sections.append(Span(start: prev.start, end: last.end))
        }
        return sections
    }

    /// Reach each section out into the silence around it, symmetrically, so neighbours can touch but
    /// never overlap. See `edgePadding`.
    private func pad(_ sections: [Span], fileDuration: TimeInterval) -> [Span] {
        guard !sections.isEmpty else { return [] }
        var out = sections
        for i in out.indices {
            let precedingQuiet = i == 0 ? out[0].start : out[i].start - sections[i - 1].end
            let pad = min(Self.edgePadding, max(0, precedingQuiet) / (i == 0 ? 1 : 2))
            out[i].start = max(0, out[i].start - pad)
            if i > 0 { out[i - 1].end += pad }
        }
        if let last = out.last {
            let trailingQuiet = max(0, fileDuration - last.end)
            out[out.count - 1].end = min(fileDuration, last.end + min(Self.edgePadding, trailingQuiet))
        }
        return out
    }

    /// Cut any section over `maxSectionDuration` at its quietest interior point, then re-check the
    /// halves. Both halves are kept away from the edges so the cut cannot produce a sliver, which
    /// also bounds the recursion.
    private func splitOverlongSections(_ sections: [Span], analysis: Analysis) -> [Span] {
        let maxSection = options.maxSectionDuration
        guard maxSection.isFinite, maxSection > 0 else { return sections }

        var queue = sections
        var out: [Span] = []
        var iterations = 0
        while let span = queue.first {
            queue.removeFirst()
            iterations += 1
            if span.duration <= maxSection || iterations > Self.maxSplitIterations {
                out.append(span)
                continue
            }
            // Look for the cut only in the middle half of the span. Searching the whole interior
            // instead lets the quietest frame sit near an edge, and the recursion then peels the
            // section rather than halving it: measured on a 103-second pauseless recording, an
            // unrestricted search gave 24.5 s, five of 10.3 s, and 26.9 s, where the middle-half
            // search gives four even ones. It also bounds the recursion — each half keeps at least a
            // quarter of the span, so this terminates in log(duration / maxSectionDuration) rounds.
            let margin = span.duration * 0.25
            let lo = span.start + margin
            let hi = span.end - margin
            guard hi > lo, let cut = quietestPoint(from: lo, to: hi, analysis: analysis) else {
                out.append(span)
                continue
            }
            queue.insert(Span(start: cut, end: span.end), at: 0)
            queue.insert(Span(start: span.start, end: cut), at: 0)
        }
        return out.sorted { $0.start < $1.start }
    }

    private func quietestPoint(from lo: TimeInterval, to hi: TimeInterval, analysis: Analysis) -> TimeInterval? {
        let source = analysis.smoothedDB.isEmpty ? analysis.frameDB : analysis.smoothedDB
        guard !source.isEmpty else { return nil }
        let first = max(0, Int((lo / analysis.frameSeconds).rounded(.up)))
        let last = min(source.count - 1, Int((hi / analysis.frameSeconds).rounded(.down)))
        guard first <= last else { return nil }
        var bestIndex = first
        for i in first...last where source[i] < source[bestIndex] { bestIndex = i }
        // Centre of the quietest frame, clamped inside the window so the halves stay non-empty.
        let t = (Double(bestIndex) + 0.5) * analysis.frameSeconds
        return min(max(t, lo), hi)
    }
}
