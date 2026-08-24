# Edict — design components

The implementation spec for the three files owned by the **design** agent:

    Sources/EdictKit/Design/Components.swift   TapeButton, TapeButtonStyle, RecordLamp, SilkscreenLabel,
                                                SegmentCounter, PanelSurface, RecessedWell, SeamDivider,
                                                RockerSwitch, RockerSwitchStyle, TranscriptRow,
                                                EquipmentSearchField, StatusReadout
    Sources/EdictKit/Design/VUMeter.swift      VUMeter, VUFaceplate, NeedleBallistics
    Sources/EdictKit/Design/Waveform.swift     Waveform, LevelTrace

Read [`DESIGN-TOKENS.md`](DESIGN-TOKENS.md) first; this document is written entirely in its vocabulary.
Read [`CONTRACTS.md`](CONTRACTS.md) for the views these components serve and the data types they render.

This spec is meant to be implementable without invention. Every colour, font, spacing, radius, border,
duration and curve names a `D.*` token. Every remaining number — a needle length, a column pitch, a
table column width — is fixed here by value, and is declared in the implementation as a `private enum M`
(metrics) at the top of the file that owns it. Nothing outside `Design/` ever sees an `M`.

---

## 0. Conventions that apply to every component

### 0.1 Metrics, not magic numbers

Each file opens with its own metrics namespace, and every value in it appears in this document:

```swift
/// Component metrics. Geometry that belongs to one component and is not a design token.
/// Anything with a token *must* use the token; this holds only the shapes' own proportions.
private enum M {
    static let capSeatOutset: CGFloat = 1
    …
}
```

Where a metric is a multiple of a token, write it as the multiplication so the relationship survives a
token change: `static let transportMinWidth = D.size.buttonHeight * 2.6   // 78`.

### 0.2 Casing and accessibility of silkscreen text

`D.type.silkscreen`, `silkscreenTiny`, `silkscreenHeading` and `buttonCap` all carry
`textCase: .uppercase`. **Call sites therefore pass natural, mixed-case strings** — `"History"`,
`"Record"`, `"Transcribing"` — and the type style does the shouting. This is not cosmetic: an
all-caps string handed to VoiceOver is frequently spelled out letter by letter, and passing natural
case means the accessibility label is correct with no extra work. The `.engravedLabel()` modifier from
the tokens file stays available for genuine acronyms (`"VU"`, `"dBFS"`, `"CLR"`), which are correct in
caps for both eye and screen reader.

Where a component draws text that is *not* a `Text` view (numerals inside a `Canvas`), it must carry an
explicit `.accessibilityLabel` / `.accessibilityValue` on the enclosing view, because canvas content is
invisible to accessibility.

### 0.3 Environment inputs every component reads

| Environment | Read by | Effect |
|---|---|---|
| `\.isEnabled` | every interactive component | drives the disabled state; never a separate `isDisabled` parameter |
| `\.accessibilityReduceMotion` | TapeButton, RecordLamp, StatusReadout, VUMeter, Waveform, TranscriptRow | see each component's Reduce Motion clause |
| `\.colorSchemeContrast` | all | see 0.4 |
| `\.controlActiveState` | TapeButton, RecordLamp, StatusReadout | when `.inactive` (window not frontmost), lamps and readouts drop to `D.opacity.ghost`; **geometry never changes** |

Nothing reads `\.colorScheme` directly. Every colour is a dynamic token and resolves itself; a component
that branches on `colorScheme` is a bug.

### 0.4 Increase Contrast

The palette already folds the two high-contrast appearances onto their base appearances, so **no
component changes colour** under Increase Contrast. What changes is weight, and only these four things:

1. Any `D.border.hairline` stroke that carries *structural* meaning (a seam inside a control, a tick, a
   scale line) is drawn at `D.border.thin` instead.
2. Any *text* drawn below full opacity is drawn at full opacity. `D.opacity.disabled` continues to apply
   to disabled controls, because "unavailable" must stay legible as a state.
3. `D.shadow.engraved` is dropped from silkscreen text — the light offset costs edge contrast on the
   letterform, and under Increase Contrast legibility beats material.
4. The needle, peak marker and waveform bars gain `+0.5` line width / bar width.

Implement as a single helper in `Components.swift`, so the rule exists once:

```swift
extension EnvironmentValues {
    /// True when the user has asked for increased contrast, in either appearance.
    var edictIncreasedContrast: Bool { colorSchemeContrast == .increased }
}
```

### 0.5 Reduce Motion, in one sentence

Motion that *is* the data survives; motion that decorates a state change does not. So the needle keeps
its ballistics and the counter keeps counting, while lamp breathing, alarm pulsing, crossfades and the
waveform's interpolated scroll are all replaced by their end states.

### 0.6 Concurrency

No component type is annotated `@MainActor` and none is `Sendable`; SwiftUI's `body` is already
main-actor isolated, so plain non-`Sendable` `() -> Void` action closures are correct and impose nothing
on callers. Mutable per-view machinery (needle ballistics, the waveform ring buffer) lives in a
`@MainActor final class` held in `@State`: main-actor isolation makes the class implicitly `Sendable`,
which is what `@State` wants, and **the class must not be `@Observable`** — its whole purpose is to
mutate 60 times a second without invalidating anything.

### 0.7 Previews

Every component ships a `#Preview` that renders **all** of its states in one column, on
`D.surface.deckPaint`, and the file's last preview is a `ComponentGallery` containing one of everything.
Previews are the only verification this layer gets before the views agent starts, so a state that is not
in a preview is a state that has not been checked.

---

## 1. `TapeButton`

A moulded plastic key in a seat cut into the panel. RECORD and STOP on the transport deck; the small
square utility keys in the history rows and the search field.

### API

```swift
/// A physical push key. The press is geometry, never a tint: the cap travels down into its seat,
/// its shading inverts, and its contact shadow disappears because it is no longer standing off
/// the panel.
public struct TapeButton<Label: View>: View {

    /// `Role` and `Size` live on `TapeButtonStyle`, not here, so a control that cannot be a
    /// `Button` can name them without spelling a generic parameter it does not have.
    public typealias Role = TapeButtonStyle.Role
    public typealias Size = TapeButtonStyle.Size

    public init(
        role: Role = .neutral,
        size: Size = .standard,
        isLatched: Bool = false,
        minWidth: CGFloat? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    )
}

public extension TapeButton where Label == Text {
    /// Convenience for the overwhelmingly common case: a moulded legend.
    /// Pass the legend in natural case — `D.type.buttonCap` uppercases it (see §0.2).
    init(
        _ title: String,
        role: Role = .neutral,
        size: Size = .standard,
        isLatched: Bool = false,
        minWidth: CGFloat? = nil,
        action: @escaping () -> Void
    )
}

/// The cap treatment on its own, exposed so a control that cannot be a `Button` — a segmented
/// selector in the left rail, say — can still be the same physical object.
public struct TapeButtonStyle: ButtonStyle {

    /// What the key is for. Role decides the latching contract, the default width, and the
    /// accessibility traits — never the colour.
    public enum Role: Sendable, Hashable {
        /// Starts an utterance. Latches: stays down for as long as `isLatched` is true.
        case record
        /// Ends an utterance. Momentary.
        case stop
        /// Everything else. Momentary.
        case neutral
    }

    public enum Size: Sendable, Hashable {
        /// `D.size.buttonHeight` tall, `M.transportMinWidth` wide by default.
        case standard
        /// A `D.size.iconButton` square, for a glyph.
        case icon
    }

    public init(role: Role = .neutral, size: Size = .standard, isLatched: Bool = false)
    public func makeBody(configuration: Configuration) -> some View
}
```

`TapeButton` is a thin wrapper: `Button(action:label:)` with `.buttonStyle(TapeButtonStyle(...))`. It is
a real `Button` because that buys, for free and correctly, the traits VoiceOver expects, Space/Return
activation, Full Keyboard Access focus, and press-drag-out cancellation — `configuration.isPressed`
already goes false when the pointer leaves the cap while held, which a hand-rolled
`DragGesture` gets wrong on the first try.

### Anatomy, bottom to top

| # | Layer | Drawn with |
|---|---|---|
| 0 | **Seat** — the hole the key travels in. `RoundedRectangle(cornerRadius: D.radius.control + M.capSeatOutset, style: .continuous)`, outset `M.capSeatOutset` (1) on all sides from the cap, filled `D.color.wellFill`, then `.innerShadow(seatShape, D.shadow.wellInner)`. | tokens |
| 1 | **Cap** — the content, padded, then `.pressedCap(isDown, radius: D.radius.control)`. That single modifier supplies the inverted `D.surface.buttonCap(pressed:)` shading, the `pressedInner`/`capInnerLight` inner shadow, the `recessedEdge`/`raisedEdge` border at `medium`/`thin`, the 1pt sink, the `D.shadow.cap` contact shadow when up, and the `press`/`release` animation. Do not re-implement any of it. |
| 2 | **Hover lift** — `.offset(y: isHovering && !isDown ? -M.hoverLift : 0)` where `M.hoverLift = 0.5`, animated `D.motion.release`. Applied *inside* `pressedCap` so the two offsets compose. |
| 3 | **Legend** — `.typeStyle(D.type.buttonCap)`, `.foregroundStyle(D.color.displayInk)`, `.shadow(D.shadow.engraved)`. The cap is matte black plastic in **both** appearances (`D.surface.buttonCap` is built from `panelPlastic`/`wellFill`), which is why the legend uses `displayInk` and not `textPrimary` — `textPrimary` is near-black in the light appearance and would vanish. |
| 4 | **Focus** — `.focusRing(isFocused, radius: D.radius.control + M.capSeatOutset)` on the seat, plus `.focusEffectDisabled()` on the `Button` so the system ring never draws. |

### States

`isDown` is the union of two independent facts: `configuration.isPressed` (a finger is on the key) and
`isLatched` (state holds the key down). `isDown = configuration.isPressed || isLatched`.

| State | Geometry |
|---|---|
| idle | cap up, `D.shadow.cap` present, `capInnerLight` on the top inside edge, edge `D.border.thin` |
| hover | idle, lifted `0.5` further, edge `D.border.medium`. Nothing tints. A key is not a hyperlink. |
| pressed | `pressedCap(true)`: cap sunk 1pt, shading inverted, `pressedInner`, no contact shadow, edge `medium` |
| latched (RECORD while recording) | identical to pressed, and it must be *identical* — a latched key and a held key are the same physical position |
| latched + pressed | no further travel; the press is absorbed. On release the caller un-latches. Do not double-sink. |
| disabled | idle geometry, whole button at `D.opacity.disabled`, seat inner shadow retained. A disabled key still looks like a key, just unlit. |
| focused | focus ring on the seat; unaffected by press |

Latching is not owned by the component. `isLatched` is a plain input, so `AppModel.phase` is the single
source of truth and the key cannot disagree with the recorder.

### Interaction and animation

- Press and release come from `pressedCap`: `D.motion.press` down, `D.motion.release` up. Nothing else
  animates. Total travel is 1pt and 55 ms — deliberately below the threshold where it reads as an
  animation and just reads as a key.
- Hover uses `.onHover` and animates with `D.motion.release`.
- **Reduce Motion:** the travel is kept (1pt in 55 ms is not vestibular motion and it is the entire
  affordance) but the hover lift is dropped, so the only movement is one the user caused.
- No sound, no haptics.

### Accessibility

- Label: from `label` for the `Text` convenience init; for the `@ViewBuilder` init the caller **must**
  supply `.accessibilityLabel` and the component asserts nothing — document it in the doc comment.
- `role == .record` with `isLatched` adds `.isSelected` to the traits, so VoiceOver says "Record,
  selected", which is how a latched key should read. `role == .stop` adds nothing.
- Value: none. A button with a value is a control that should have been a `Toggle`.
- `.accessibilityHint` is left to the caller; the deck's RECORD key gets "Starts dictation".
- Increase Contrast: per §0.4 the legend loses `D.shadow.engraved` and disabled caps keep
  `D.opacity.disabled`.

### Layout and cramping

- `.standard`: height exactly `D.size.buttonHeight`; horizontal padding `D.space.md`; width
  `max(minWidth ?? M.transportMinWidth, intrinsic)`. `M.transportMinWidth = D.size.buttonHeight * 2.6`
  (78). RECORD and STOP therefore come out the same width without the call site coordinating, which is
  the invariant that matters on the deck.
- `.icon`: exactly `D.size.iconButton` square, padding `D.space.xxs`, no `minWidth`.
- The seat adds `M.capSeatOutset` on every side, so the *view's* footprint is 2pt larger than the cap in
  each axis. Callers lay out against the view; the deck's spacing tokens already account for it.
- Cramped: the cap never shrinks below its `.standard` height and the legend never wraps or scales.
  `.lineLimit(1)` and `.fixedSize(horizontal: true, vertical: false)`. If the container cannot afford the
  key, the container is wrong — a transport key that has been squeezed is worse than a clipped panel.

---

## 2. `VUMeter`

The instrument the app is built around. A moving-coil VU movement behind glass: cream faceplate, printed
arc, ten major ticks with numerals, a green/amber/red zone strip, a reference mark at 0 VU, a peak
witness marker, an OVER lamp, and a needle with real ballistics.

### API

```swift
/// A moving-coil VU meter. Driven from the current `AudioFrame`; integrates its own ballistics
/// on a 60 Hz tick, because the audio tap delivers levels at only 2.5–10 Hz (RECON §19) and a
/// needle animated from arrivals visibly steps.
public struct VUMeter: View {

    /// - Parameters:
    ///   - level: the most recent frame. May be stale by up to 400 ms; the meter treats it as a
    ///     continuously-valid envelope and re-samples it every tick, so no sequence number,
    ///     change detection, or stream subscription is needed.
    ///   - isLive: true while capturing. False parks the needle and stops the render schedule.
    ///   - showsNumericReadout: prints the integrated value in `D.type.numeralTiny` on the
    ///     faceplate's lower left. Forced on under Reduce Motion (see below).
    public init(level: AudioFrame, isLive: Bool, showsNumericReadout: Bool = false)
}

/// The static half of the meter: faceplate, ticks, numerals, zone strip, legends, reference mark.
/// `Equatable` on purpose — see §2.5.
public struct VUFaceplate: View, Equatable {
    public init(showsNumericReadout: Bool)
    public static func == (a: Self, b: Self) -> Bool
}

/// The needle integrator. One per meter instance, `@State`-owned, deliberately not `@Observable`.
@MainActor final class NeedleBallistics {
    /// Needle position as a 0…1 fraction of the printed scale.
    private(set) var position: Double
    /// Peak high-water mark, in dBFS, for the witness marker and the OVER lamp.
    private(set) var peakDBFS: Double
    /// Advances to `date` using the real elapsed time, not the nominal frame interval.
    func advance(to date: Date, targetDBFS: Double)
    func reset()
}
```

`AudioFrame` (`Engine/AudioCapture.swift`, owner: audio) is `struct AudioFrame: Sendable { rms, peak: Float; dbfs: Float }`.
The meter uses **`dbfs` only**. `rms` and `peak` are already display-smoothed by the audio layer and
smoothing twice is how a needle ends up feeling dead. Request from the audio owner that `AudioFrame`
also conform to `Equatable` and `Hashable`; if it does not, the meter still works — it simply cannot
skip a redundant view update, which costs nothing here because the render schedule is the timeline, not
the value.

### 2.1 Geometry

All of it derives from the faceplate rect `f`, so the meter scales if `D.size.meterSize` changes.
The values in brackets are for the default `D.size.meterSize` (232 × 84), where `f` = 224 × 76.

| Layer | Rule | Default |
|---|---|---|
| Housing | the component's frame, `.brushedFace(radius: D.radius.bezel)` then `.bezelRing(radius: D.radius.bezel, width: D.border.bezel)` | 232 × 84 |
| Faceplate | housing inset by `D.space.xs` on all sides. `RecessedWell(fill: .faceplate, radius: D.radius.well, inset: 0)` — the cream card sits in a cut-out, so the metal's overhang shades its top edge via `D.shadow.wellInner` | 224 × 76 at (4, 4) |
| Pivot `p` | `(f.width / 2, f.height + M.pivotDrop * f.height)`, `M.pivotDrop = 0.52`. Below the visible card, exactly as in the real movement | (112, 115.5) |
| Needle length `L` | `M.needleLength * p.y`, `M.needleLength = 0.94` | 108.6 |
| Scale arc radius `Ra` | `M.arcRadius * L`, `M.arcRadius = 0.90` | 97.7 |
| Numeral radius `Rn` | `Ra - M.numeralInset`, `M.numeralInset = 15` | 82.7 |
| Zone strip radius `Rz` | `M.zoneRadius * L`, `M.zoneRadius = 0.68`, stroked `M.zoneWidth = 3` | 73.8 |
| Major tick | inward from `Ra`, length `M.tickMajor = 7`, width `D.border.thin` | |
| Minor tick | inward from `Ra`, length `M.tickMinor = 3.5`, width `D.border.hairline` | |

Angles come from the tokens and are never computed locally:
`θ(dbfs) = D.meter.angle(fraction: D.meter.fraction(dbfs: dbfs))`, in degrees, **0° = straight up,
positive = clockwise**. A point at radius `r` and angle `θ` is
`(p.x + r·sin θ, p.y − r·cos θ)`.

The needle therefore sweeps `D.meter.restAngleDegrees` (−42°) to +42°, its tip travelling from
(39.3, 34.8) up through (112, 6.9) and down to (184.7, 34.8) — the classic shallow VU arc, tip
overshooting the printed scale by 11pt, which is what makes it read as a needle above a card rather
than a pointer drawn on one.

### 2.2 The printed scale

- **Minor ticks** every 2 dB from `D.meter.floorDBFS` to `D.meter.ceilingDBFS` — 28 positions, 3.11°
  apart. Drawn in `D.color.meterScale`.
- **Major ticks** every 6 dB — 10 positions, 9.33° apart, at −54, −48, −42, −36, −30, −24, −18, −12,
  −6, 0 dBFS, i.e. −42.00°, −32.67°, −23.33°, −14.00°, −4.67°, +4.67°, +14.00°, +23.33°, +32.67°,
  +42.00°. Drawn in `D.color.meterScale` at `D.border.thin`.
- **Numerals** at every major, `D.type.silkscreenTiny` in `D.color.meterScale`, centred at radius `Rn`
  and **not rotated** — a printed faceplate sets its numbers upright. Magnitude only, no minus sign
  (`54 48 42 36 30 24 18 12 6 0`); the sign lives in the unit legend. At 8.5pt condensed a two-digit
  numeral is ≈9pt wide against 13.3pt of arc per major, so every major is labelled without collision.
- **Scale arc**: a stroked arc at `Ra`, `D.border.hairline`, in `D.color.meterScale` from `floorDBFS` to
  `D.meter.overDBFS`, and in `D.color.meterOverBand` from `overDBFS` to `ceilingDBFS`. The over segment
  is additionally thickened to `D.border.thin` and duplicated at `Ra + M.overBandOffset` (2) with
  `M.overBandWidth` (3) — that second stroke *is* the red band screen-printed above the danger
  threshold, and it is the reason `D.color.meterOverBand` exists as a separate token from
  `D.color.meterRed` (ink on cream, not light in a well).
- **Zone strip**: an arc at `Rz`, `M.zoneWidth` wide, in three butt-jointed segments —
  `D.color.meterGreen` from `floorDBFS` to `D.meter.hotDBFS`, `D.color.meterAmber` to
  `D.meter.overDBFS`, `D.color.meterOverBand` to `ceilingDBFS`. It sits *inside* the numerals so the
  eye reads level → zone → number from the top down.
- **Reference mark**: at `D.meter.referenceDBFS` (−18 dBFS = 0 VU, which lands at +14°, right of centre
  exactly as on a real movement) a filled triangle, base `M.refMarkBase` (5), height
  `M.refMarkHeight` (4), apex pointing inward, drawn just outside the arc at `Ra + M.overBandOffset`,
  in `D.color.meterScale`.
- **Unit legend**: `"dBFS"` in `D.type.silkscreenTiny`, `D.color.meterScale`, centred at
  `(f.width / 2, f.height - M.legendBaseline)` where `M.legendBaseline = 8`. This is the only text on
  the card that is an acronym and is therefore passed already in caps (§0.2).
- **OVER lamp**: a circle of diameter `M.overLampDiameter` (7) centred at
  `(f.width - M.overLampInsetX, f.height - M.overLampInsetY)` = (204, 58) with `M.overLampInsetX = 20`,
  `M.overLampInsetY = 18`, and the legend `"OVER"` in `D.type.silkscreenTiny` centred 12pt below it.
  Dark, it is a printed disc: fill `D.color.meterScale.opacity(D.opacity.disabled)` with a
  `D.border.hairline` ring in `D.color.meterScale` — a lamp behind a cream card reads as a dark disc
  when off, never as a hole. Lit, the fill becomes `D.meter.zoneColor(dbfs: peakDBFS)`, which is amber
  in the hot zone and `D.color.meterRed` over.

**Why the OVER lamp may be red when `RecordLamp` is supposed to be the only red.** The rule is about
*status* red, and it holds: exactly one thing in the app says "recording" in red. `D.color.meterRed` is
a *level* colour, it is a deliberately different red from `D.color.recordLamp`, and the tokens define
`D.meter.zoneColor` as serving "the needle's over-lamp and the trough". Red-as-level is confined to the
inside of instrumentation — this lamp, the trough, the waveform crest — and never appears on the
chassis.

### 2.3 Needle ballistics

Exact, and not a matter of taste. From `docs/RECON.md` §19 and the motion tokens:

```swift
func advance(to date: Date, targetDBFS: Double) {
    let dt = min(max(date.timeIntervalSince(lastTick ?? date), M.dtFloor), M.dtCeiling)
    lastTick = date
    let target = D.meter.fraction(dbfs: targetDBFS)
    let k = D.motion.needleCoefficient(dt: dt, rising: target > position)
    position += (target - position) * k
    // peak …
}
```

- `M.dtFloor = 0.004`, `M.dtCeiling = 0.100`. The real frame delta is used, never
  `D.motion.needleTickInterval`, so a dropped frame does not slow the movement down; the clamp stops a
  window that was occluded for two seconds from teleporting the needle on the next tick.
- Attack `D.motion.needleAttackTau` = 0.065 s, release `D.motion.needleReleaseTau` = 0.150 s, applied by
  `D.motion.needleCoefficient(dt:rising:)`. The attack corresponds to the ANSI C16.5 300 ms integration
  time: a real VU meter is *slow*, and a faster attack makes the needle twitch on plosives instead of
  tracking loudness.
- **Damping and overshoot: none, deliberately.** A one-pole filter is critically damped by
  construction and cannot overshoot. A real movement overshoots about 1–1.5%, and reproducing that would
  mean a second-order system whose ringing, at a 60 Hz sample rate and a 108pt needle, is a 1–2pt
  wobble at the tip — which does not read as a mechanical movement, it reads as a spring animation, and
  spring animations are exactly the modern idiom this app is avoiding. The *hang* that makes the needle
  feel physical comes from the 2.3× asymmetry between release and attack, not from ringing.
- **Sweep range**: `D.meter.floorDBFS` (−54) → `D.meter.ceilingDBFS` (0) maps onto
  `D.meter.restAngleDegrees` (−42°) → +42°, i.e. `D.meter.sweepDegrees` = 84° total, 1.556° per dB.
  Calibrated against measurement, not guessed: a quiet room sits at −61…−48 dBFS (needle on or just off
  the low peg) and ordinary speech at −18…−13 dBFS (needle at the reference mark, three-quarters up).
- **Peak marker**: tracked in dB, not in fraction, so its fall rate is a real dB/s.
  `if targetDBFS > peakDBFS { peakDBFS = targetDBFS; peakSetAt = date }`; once
  `date - peakSetAt > D.motion.peakHoldDuration` (1.5 s), `peakDBFS -= D.motion.peakFallDBPerSecond * dt`
  (20 dB/s), floored at `D.meter.floorDBFS`. Drawn as a radial line at `θ(peakDBFS)` from
  `Ra - M.tickMajor - 2` to `Ra + M.overBandOffset`, width `D.border.thin`, colour
  `D.meter.zoneColor(dbfs: peakDBFS)`.
- **OVER lamp** is lit whenever `peakDBFS >= D.meter.overDBFS`, so it inherits the 1.5 s hold for free —
  a clip that lasted one buffer is still visible a second and a half later.

### 2.4 The needle itself

A tapered blade, not a line: a filled path from half-width `M.needleBaseHalf` (1.6) at radius
`M.needleTailRadius * L` (0.25 · L = 27) to half-width `M.needleTipHalf` (0.5) at `L`, filled
`D.color.meterNeedle`. The tail runs off the bottom of the card and is clipped by the faceplate shape,
which is correct — the hub is under the bezel. Beneath it, the same path offset by
`D.shadow.needle`'s x/y and filled `D.color.meterNeedleShadow` at `D.opacity.halo`, blurred by
`D.shadow.needle.radius`; that cast shadow on the card is what sells the air gap under the glass, and it
must be drawn as a second path inside the canvas rather than with `.shadow`, because a canvas shadow
would also shade the ticks.

### 2.5 Redraw strategy

**Two sibling layers, `Canvas` for both, `TimelineView` only around the moving one. Not an `NSView`.**

```swift
public var body: some View {
    ZStack {
        VUFaceplate(showsNumericReadout: showsNumericReadout).equatable()
        if isLive {
            TimelineView(.animation(minimumInterval: D.motion.needleTickInterval, paused: false)) { ctx in
                let _ = ballistics.advance(to: ctx.date, targetDBFS: Double(level.dbfs))
                NeedleLayer(fraction: ballistics.position,
                            peakDBFS: ballistics.peakDBFS,
                            lineWidthBoost: contrastBoost)
            }
        } else {
            NeedleLayer(fraction: parkFrom * parkProgress, peakDBFS: nil, lineWidthBoost: contrastBoost)
                .animation(D.motion.needleRest, value: parkProgress)
        }
    }
    .frame(width: D.size.meterSize.width, height: D.size.meterSize.height)
}
```

- **The faceplate is a `Canvas` wrapped in `.equatable()`**, and `VUFaceplate.==` returns true whenever
  `showsNumericReadout` matches. Its only other inputs are the size (fixed) and the resolved palette
  (which changes only with appearance/contrast, and those invalidate the whole view tree anyway). So the
  ≈70 primitives of card, arc, 28 ticks, 10 numerals, zone strip, reference mark, legends and lamp
  surround are drawn once and then skipped, forever. This is the single most important line in the file.
- **The needle layer is a `Canvas` inside `TimelineView(.animation)`**, which drives redraws off the
  display's refresh rather than off SwiftUI state. `ballistics.advance` is called in the timeline's
  content closure — main-actor isolated, so the call is legal under strict concurrency — and the
  resulting numbers are passed *into* the canvas as plain `Double`s, so the renderer closure mutates
  nothing and needs no isolation ceremony. Nothing is `@Published`, nothing is `@Observable`, so **not
  one SwiftUI state invalidation occurs per frame**; the only work is ≤8 primitives (needle, its
  shadow, peak marker, lamp fill) into an existing layer.
- **`paused`**: the schedule stops when `isLive` is false, so an idle window costs zero. Parking is a
  separate, non-timeline path: `.onChange(of: isLive)` captures `parkFrom = ballistics.position`, sets
  `parkProgress = 1` without animation and then `withAnimation(D.motion.needleRest) { parkProgress = 0 }`,
  and calls `ballistics.reset()`. The needle falls to the low peg in 0.42 s from wherever it actually
  was — a needle that snaps to zero when you stop talking destroys the illusion in one frame.
- **`Color` resolution**: inside a `Canvas`, resolve each colour once per draw via
  `context.resolve(_:)` / `GraphicsContext.Shading.color(_:)` on locals declared at the top of the
  renderer; do not pass `Color` into `context.fill` in a loop over 28 ticks.
- **Why not an `NSView` + `CVDisplayLink`.** It would be a second render path with a non-main-thread
  callback (strict-concurrency ceremony for a job that is 8 primitives per frame), it would not receive
  `colorScheme`, `colorSchemeContrast`, `accessibilityReduceMotion` or `controlActiveState` without
  bridging each one by hand, its accessibility would have to be re-declared in `NSAccessibility` instead
  of the SwiftUI modifiers every other component uses, and it renders through the same GPU path `Canvas`
  does. The cost of `Canvas` is that the renderer closure runs per frame; the cached faceplate removes
  the only part of that which was expensive.

### 2.6 Accessibility

- `.accessibilityElement(children: .ignore)` on the whole meter — the canvas has no children worth
  exposing.
- `.accessibilityLabel("Input level")`.
- `.accessibilityValue` is spoken, not silkscreened: `"−18 decibels, hot"` /`", safe"` / `", over"`,
  taken from which zone `peakDBFS` falls in. Format the number with `String(format: "%.0f")` so no
  locale ever introduces its own digits.
- `.accessibilityAddTraits(.updatesFrequently)` while `isLive`, removed when parked, so VoiceOver does
  not narrate a still needle.
- **Reduce Motion**: the needle keeps moving — it is the data, and freezing it would leave the app with
  no level indication at all. What changes: `showsNumericReadout` is forced true so the value is legible
  without watching the needle, the peak marker snaps to its new angle instead of being redrawn each
  frame at an intermediate position (it already does — it is not interpolated), and the OVER lamp is
  steady rather than pulsing (it never pulses; there is nothing to remove, which is the point).
- **Increase Contrast**: needle base/tip half-widths and the peak marker gain +0.5; the scale arc and
  minor ticks go from `D.border.hairline` to `D.border.thin`; the needle's cast shadow is dropped
  entirely, because on a cream card it is the one thing that reduces needle edge contrast.

### 2.7 Layout and cramping

Fixed size: `D.size.meterSize`, via `.frame(width:height:)`, **not** a flexible frame. A VU meter with a
variable aspect ratio is not a VU meter; the faceplate proportions are the instrument.

The two degradations, in order, both driven by the *available width* the deck reports:

1. Below 232pt: fall back to a compact form — hide the numerals and the `"dBFS"` legend, keep ticks,
   zone strip, reference mark, needle and OVER lamp. Threshold `M.compactWidth = 200`.
2. Below `M.compactWidth`: the deck must not use `VUMeter` at all. It uses the horizontal level trough
   (`D.size.troughHeight`) instead, which is the HUD's and the menu-bar popover's indicator. Say so in
   the doc comment so the views agent does not try to squeeze one in.

---

## 3. `RecordLamp`

The one red thing in Edict. A domed lens in a machined ring, sunk into the panel.

### API

```swift
/// The record lamp. Exactly one of these exists in the main window; the HUD and the menu-bar
/// popover each own one more, and that is the whole census. If a fourth appears, the app has
/// two things claiming to be the recording indicator.
public struct RecordLamp: View {

    /// Named `Mode` and not `State` so it does not read as `@State` at every call site.
    public enum Mode: Sendable, Hashable {
        /// Not recording. The lens is a dead red-brown, not a grey hole.
        case off
        /// Armed: hotkey held past the 120 ms threshold, or the model still downloading.
        /// A slow breath, never a blink.
        case armed
        /// Capturing. Steady, full brightness.
        case recording
        /// Something failed. Three deliberate pulses, then off.
        case fault
    }

    public enum Fitting: Sendable, Hashable {
        /// `D.size.lampDiameter` (13). The deck.
        case standard
        /// `D.size.lampDiameter * 0.62` (≈8). The HUD and the menu-bar popover.
        case compact
    }

    public init(_ mode: Mode, fitting: Fitting = .standard)
}
```

`Fitting` is an enum rather than a `CGFloat` for a concrete reason: `D.surface.lampLens(lit:)` has
`endRadius: D.size.lampDiameter * 0.75` baked in, so a lens drawn at an arbitrary diameter gets the
wrong gradient falloff. `.compact` draws the lens fill into a `D.size.lampDiameter` square and applies
`.scaleEffect(0.62)` **to the fill only** — a gradient-filled `Circle` scales cleanly — while the bezel
is stroked at its true size so the hairlines stay hairlines.

### Anatomy, bottom to top

| # | Layer |
|---|---|
| 0 | **Socket** — `Circle()` at `diameter + D.border.bezel * 2`, filled `D.color.wellFill`, `.innerShadow(Circle(), D.shadow.wellInner)`. The hole in the panel. |
| 1 | **Halo** — only when lit. `Circle()` at `diameter * M.haloScale` (1.55), filled a `RadialGradient` from `D.color.recordLampHalo` at `D.opacity.halo` (0.28) to `.clear` at 1.0, **clipped to the socket circle**. |
| 2 | **Lens** — `Circle()` at `diameter`, filled `D.surface.lampLens(lit:)`. |
| 3 | **Rim shade** — `Circle().strokeBorder(D.color.shadowInner, lineWidth: D.border.hairline)` inset to the lens edge, so the lens has a dark edge even lit. |
| 4 | **Bezel** — `.bezelRingCircular(width: D.border.bezel)` on the socket. |

### How it avoids reading as a glow

This is the whole design problem, and it is solved geometrically rather than by tuning opacity:

1. **The halo is clipped to the socket.** No light spills onto the aluminium. A real 3mm LED in a
   chromed bezel does not illuminate the panel around it, and a soft red bloom on brushed metal is the
   single clearest signal that a UI is a theme rather than an object.
2. **There is no `.shadow` and no `.blur` anywhere on the lamp**, in any mode. `D.color.recordLampHalo`
   at `D.opacity.halo` is a *painted* gradient inside a hole, not a light effect.
3. **The bezel is drawn last**, on top, so the brightest pixels are always bounded by a hard machined
   edge.
4. **Brightness is carried by the lens gradient's own centre stop**, i.e. by the lit/unlit switch inside
   `D.surface.lampLens`, so "brighter" means "the dome catches more light", not "the element got
   bigger or blurrier".

### States and behaviour

| Mode | Lens | Halo | Animation |
|---|---|---|---|
| `off` | `lampLens(lit: false)` | none | none |
| `armed` | `lampLens(lit: true)`, whole lamp opacity breathing `M.breatheLow` (0.42) ↔ `M.breatheHigh` (0.78) | present, opacity follows | `D.motion.lampBreathe` (`easeInOut(0.85).repeatForever(autoreverses: true)`) |
| `recording` | `lampLens(lit: true)`, opacity 1 | present, opacity 1 | in with `D.motion.lampOn` (0.07 s), out with `D.motion.lampOff` (0.24 s) |
| `fault` | `lampLens(lit: true)` pulsing 1 ↔ `M.breatheLow` | present | `D.motion.lampAlarm` (`easeInOut(0.28).repeatCount(6, autoreverses: true)`) then settles at `off` |

The 3.4× asymmetry between `lampOn` and `lampOff` is why this reads as a filament: it reaches brightness
fast and cools slowly. Arming *breathes* and never blinks — a hard blink in an always-visible window is
an alarm, and arming is not an alarm; `fault` is the only thing allowed to blink, three times, and then
it stops, because attention that does not end is noise.

Transitions between modes animate opacity only. The lens never changes size and the socket never moves.

### Accessibility

- `.accessibilityElement(children: .ignore)`, label `"Recorder"`, value `"Off"` / `"Armed"` /
  `"Recording"` / `"Fault"`.
- `.accessibilityAddTraits(.updatesFrequently)` only in `.armed`, where the visual is a repeating
  animation with no value change.
- The lamp is never the *only* indication of a state; `StatusReadout` always carries the same
  information in words, which is what makes the lamp safe for a colour-blind user.
- **Reduce Motion:** `armed` becomes steady at `M.breatheHigh`; `fault` becomes steady lit for
  `M.faultHold` (1.7 s ≈ the six-half-cycle duration of `lampAlarm`) and then off. No repeating
  animation ever runs.
- **Increase Contrast:** the halo layer is dropped (it is the only low-contrast element) and the rim
  shade goes to `D.border.thin`.

### Layout

Intrinsic size `diameter + D.border.bezel * 2` square — 17pt for `.standard`, 12pt for `.compact`. Never
flexible, never scaled by the container. A label placed next to it sits `D.space.xxs` away, which is the
gap that token exists for.

---

## 4. `SilkscreenLabel`

The uppercase label printed onto the panel. Everything gets one; nothing invents its own.

### API

```swift
/// A label screen-printed onto the chassis. Pass natural case — the type style uppercases it,
/// which keeps the accessible string readable (§0.2).
public struct SilkscreenLabel: View {

    public enum Weight: Sendable, Hashable {
        /// `D.type.silkscreen`. The workhorse: above a control, beside a lamp.
        case standard
        /// `D.type.silkscreenTiny`. Scale legends, unit suffixes, tick labels.
        case tiny
        /// `D.type.silkscreenHeading`. Above a whole block of controls.
        case heading
    }

    public init(_ text: String,
                weight: Weight = .standard,
                ruled: Bool = false,
                alignment: HorizontalAlignment = .leading)
}
```

### Anatomy

- The text, `.typeStyle(D.type.silkscreen | silkscreenTiny | silkscreenHeading)`,
  `.foregroundStyle(D.color.textSilkscreen)`, `.shadow(D.shadow.engraved)`. This is exactly what
  `.engravedLabel()` / `.engravedHeading()` do, and the component **calls those modifiers** rather than
  restating them, so there is one definition of printed ink.
- `ruled: true` appends, after `D.space.labelGap`, a horizontal `SeamDivider(.horizontal)` that expands
  to fill the remaining width. That is the equipment convention — `INPUT ─────────` — and it is the
  cheapest way to make a block of controls look bolted to a panel rather than floated on it. The rule is
  vertically centred on the label's cap height, not its baseline: offset the divider by
  `M.ruleCapOffset` (−1) so it strikes through the middle of the capitals.
- `alignment` positions the text within whatever width the container hands over; `ruled` forces
  `.leading` and asserts in debug if given anything else.

### States

None. It is ink. It does not hover, press, focus, or disable — a label inside a disabled control is
dimmed by the container's `D.opacity.disabled`, not by the label.

### Accessibility

- `.accessibilityHidden(true)` **when the label is decorating a control that already carries the same
  name** — which is most of the time. `SilkscreenLabel` cannot know that, so it exposes
  `.silkscreenDecorative()` as a call-site modifier and documents the rule: if the label names a control
  next to it, hide the label and put the name on the control; if it names a *region*, leave it visible
  and add `.accessibilityAddTraits(.isHeader)` for `.heading` weight.
- Under Increase Contrast the `D.shadow.engraved` offset is dropped (§0.4).
- Dynamic Type: silkscreen sizes are fixed by the panel and do not scale. This is a deliberate, stated
  exception — a silkscreen label that grows tears the panel apart, and the content the user actually
  reads (`D.type.body`, `caption`, `explain`) does scale. Apply `.dynamicTypeSize(.large)` explicitly on
  silkscreen text so a system-wide setting cannot break the deck, and note it in the doc comment.

### Layout and cramping

`.lineLimit(1)`, `.fixedSize(horizontal: true, vertical: false)`, `.truncationMode(.tail)`. A silkscreen
label never wraps: two-line panel labels do not exist on equipment. If it does not fit, the container
must drop it (see each component's cramping order), and dropping a label is always better than wrapping
one.

---

## 5. `SegmentCounter`

Elapsed time, durations, word counts, and the dB readout. A mechanical counter: fixed pitch, fixed
field width, and digits that never animate.

### API

```swift
/// A counter in segmented numerals, seated in a lit display window.
public struct SegmentCounter: View {

    public enum Format: Sendable, Hashable {
        /// `MM:SS.T` — the running elapsed counter on the transport deck.
        case elapsed(TimeInterval)
        /// `MM:SS` — a finished duration, e.g. a history row.
        case duration(TimeInterval)
        /// An integer with a silkscreened unit suffix, e.g. `128 W`.
        case count(Int, unit: String)
        /// `-00.0` — the dBFS readout beside the meter.
        case decibels(Double)
    }

    public enum Scale: Sendable, Hashable {
        /// `D.type.counter` (26pt mono). One per window: the transport deck.
        case large
        /// `D.type.counterSmall` (12pt mono). Table rows, latency readouts.
        case small
        /// `D.type.numeralTiny` (9pt mono). Beside the meter, inside the HUD.
        case tiny
    }

    /// - Parameter seated: wraps the digits in a `RecessedWell(fill: .display)`, which is how the
    ///   deck's counter is drawn. False for a counter inside an existing well, e.g. a table row.
    public init(_ format: Format, scale: Scale = .small, seated: Bool = true)
}
```

`SegmentCounter` **never owns a timer**. `elapsed` is pushed in from `AppModel.elapsed`. A component that
runs its own clock will drift out of step with the recorder it claims to be measuring.

### Digit-width stability

Three mechanisms, all required; any one alone still jitters.

1. **Zero-padded fixed forms.** `.elapsed` renders `MM:SS.T` and `.duration` renders `MM:SS` — always
   two-digit minutes, always padded. `00:04.2`, not `0:04.2`. This is what a tape counter does, and it
   means the string length is constant for the entire useful range, so there is no re-layout at 10:00
   and no re-layout at 1:40.
2. **`.monospacedDigit()`**, which every mono `D.type` token already carries. Note that this is *not*
   sufficient on its own: the colon and the period are not digits and are not necessarily the same
   advance width, which is exactly why (1) fixes the whole shape of the string rather than only its
   digit count.
3. **A reserved field.** For `.count` and `.decibels`, whose lengths genuinely vary, render the digits
   right-aligned in a `ZStack(alignment: .trailing)` over a hidden template string
   (`.hidden()`, `.accessibilityHidden(true)`) whose width the field takes. Template for `.count` is
   `"0000"` plus the unit; for `.decibels` it is `"-00.0"`. Right alignment plus a fixed field means the
   last digit never moves, which is the axis the eye actually tracks.

Formatting is done with `String(format:)`, which is locale-independent, and **never** with
`DateComponentsFormatter` or `Text(_:format:)`: this machine's locale is `en_ID`, and a locale that
substitutes its own digit shapes would silently destroy both the monospacing and the look. Explicitly:

```swift
static func elapsedString(_ t: TimeInterval) -> String {
    let clamped = max(0, t)
    let total = Int(clamped)
    return String(format: "%02d:%02d.%d", total / 60, total % 60, Int((clamped - Double(total)) * 10))
}
```

The tenths digit is truncated, not rounded, so the counter never shows a time that has not happened yet.

### Anatomy

| # | Layer |
|---|---|
| 0 | **Window** (`seated` only) — `RecessedWell(fill: .display, radius: D.radius.well, inset: D.space.xs)`. Dark, so the digits are lit. |
| 1 | **Digits** — `.typeStyle(D.type.counter / counterSmall / numeralTiny)`, `.foregroundStyle(D.color.displayInk)`. |
| 2 | **Unit suffix** (`.count`) — `SilkscreenLabel(unit, weight: .tiny)` in `D.color.displayInk` at `D.opacity.ghost`, `D.space.xxs` after the digits, baseline-aligned via `.alignmentGuide(.firstTextBaseline)`. |

When `seated` is false the digits use `D.color.textPrimary` if the surrounding container is a panel and
`D.color.displayInk` if it is a display well. The component cannot know, so it takes the colour from the
environment: read `\.edictInkOnDark` — a custom environment key that `RecessedWell(fill: .display)` sets
to true and `PanelSurface` sets to false (§6.3). This one key removes the single most common bug in a
palette like this, which is dark ink on a dark well.

### States and animation

- **Digits never animate.** `.animation(nil, value: format)` and `.contentTransition(.identity)`. The
  tokens file is explicit that `D.motion.readout` is a *surrounding* fade only. A number that eases into
  another number is a spreadsheet, not a counter.
- The window's own appearance transitions (seated ↔ not, live ↔ frozen) use `D.motion.readout`.
- Disabled/idle: at `.idle` the deck's counter shows `00:00.0` at `D.opacity.ghost`, which is how a
  powered deck with no tape running looks — never blank, never hidden.

### Accessibility

- `.accessibilityLabel` from the call site (`"Elapsed"`, `"Duration"`, `"Words"`).
- `.accessibilityValue` is a *spoken* form, not the printed one: `"4.2 seconds"`, `"128 words"`,
  `"minus 18 decibels"`. `"00:04.2"` read aloud is gibberish.
- `.accessibilityAddTraits(.updatesFrequently)` for `.elapsed` while it is changing.
- Increase Contrast: `D.opacity.ghost` on the unit suffix goes to 1.

### Layout and cramping

Intrinsic width is the reserved field width; height is the type's line height plus, when seated,
`D.space.xs * 2`. `.fixedSize()`. The counter does not shrink and does not scale its font: `.large`
(26pt) is a fixed 104 × 40pt object on the deck. If the deck is too narrow, the deck drops the word
count first and the elapsed counter last — the elapsed counter and the meter are the two things that
must survive every layout.

---

## 6. `PanelSurface` and `RecessedWell`

The two structural containers. Everything in the app is inside one of them, and the rule that makes the
window read as a machine is that **there is no third option** — no bare `VStack` on the deck paint, no
floating card, no free-standing rectangle.

### 6.1 `PanelSurface`

```swift
/// A panel bolted to the deck. Standing proud of the chassis, with a lit top edge and a
/// contact shadow, so it reads as a separate piece of material.
public struct PanelSurface<Content: View>: View {

    public enum Material: Sendable, Hashable {
        /// `.raisedPanel()` — matte painted plastic. The default for a group of controls.
        case painted
        /// `.brushedFace()` — milled aluminium. The transport deck and the meter housing only.
        case brushed
        /// Matte black plastic insert: `D.surface.mattePlastic` fill, `D.surface.raisedEdge`
        /// border, `D.shadow.raised`. The transport block and the HUD body.
        case plastic
    }

    /// - Parameters:
    ///   - label: a silkscreened panel label, natural case, drawn ruled above the content.
    ///   - inset: content padding. Defaults to `D.space.panelInset`; pass `0` for a panel whose
    ///     content already insets itself (a table, a well).
    public init(_ label: String? = nil,
                material: Material = .painted,
                radius: CGFloat = D.radius.panel,
                inset: CGFloat = D.space.panelInset,
                @ViewBuilder content: () -> Content)
}
```

Anatomy: an optional `SilkscreenLabel(label, weight: .heading, ruled: true)`, then `D.space.labelGap`,
then the content, the whole thing padded by `inset` and finished with the material's modifier. The label
is *inside* the panel's inset, printed on the panel it belongs to — not floating above it in the deck's
gap, which is the layout mistake that makes panels look like web cards.

Sets `\.edictInkOnDark` to `false` in the environment for its content.

### 6.2 `RecessedWell`

```swift
/// An opening cut into the panel. Lists, text fields, counters, the waveform, the meter card.
public struct RecessedWell<Content: View>: View {

    /// **The most important choice in this file.** A "well" is two materially different things
    /// in this design and confusing them produces dark ink on a dark ground.
    public enum Fill: Sendable, Hashable {
        /// `D.surface.wellFill` — near-black in *both* appearances. A lit display: the counter
        /// window, the waveform strip, the HUD body, the status channel.
        /// Content ink is `D.color.displayInk`.
        case display
        /// `D.color.panelRecessed` — appearance-tracking (pale grey in light, near-black in dark).
        /// A sunken tray holding *readable content*: the history table, the dictionary table,
        /// a multi-line text area. Content ink is `D.color.textPrimary` / `textSecondary`.
        case list
        /// `D.surface.meterFace` — the cream VU card, which is warm and pale in both appearances
        /// because a lit meter is lit. Content ink is `D.color.meterScale`.
        case faceplate
    }

    public init(fill: Fill = .list,
                radius: CGFloat = D.radius.well,
                inset: CGFloat = D.space.wellInset,
                clipsContent: Bool = true,
                @ViewBuilder content: () -> Content)
}
```

Anatomy, all four layers required — an opening drawn with only some of them looks like a border:

1. Fill: the `Fill` case's shading.
2. `.innerShadow(shape, D.shadow.wellInner)` — the overhang shading the top of the opening.
3. `.innerShadow(shape, D.shadow.wellInnerLight)` — the light catch on the bottom inside edge. This is
   the half people leave out, and without it the well reads as a dark rectangle rather than a hole.
4. `shape.strokeBorder(D.surface.recessedEdge, lineWidth: D.border.thin)`.

`.list` uses exactly `.recessedWell(radius:)` from the tokens file with the fill overridden;
`.display` uses it unmodified; `.faceplate` overrides the fill only. `clipsContent: false` exists for
the one case where content must overhang the opening — the VU needle, whose tail runs under the bezel —
and it changes nothing else.

Sets `\.edictInkOnDark` to `true` for `.display` and `.faceplate` content, `false` for `.list`.

### 6.3 The ink environment key

```swift
/// True when the surrounding surface is dark in *both* appearances, so content must use
/// `D.color.displayInk` rather than `D.color.textPrimary`.
private struct EdictInkOnDarkKey: EnvironmentKey { static let defaultValue = false }
public extension EnvironmentValues {
    var edictInkOnDark: Bool { get set }
}
```

The palette's one real trap is that `D.color.textPrimary` is near-black in the light appearance while
`D.surface.wellFill` is near-black in *both*. Every component that draws text and can appear in either
container reads this key: `SegmentCounter`, `SilkscreenLabel`, `StatusReadout`, `TranscriptRow`,
`EquipmentSearchField`. Two lines of environment beats a convention nobody remembers.

### States, accessibility, cramping (both containers)

- No interactive states. Both are `.accessibilityElement(children: .contain)` with no label of their own;
  `PanelSurface`'s `label`, when present, becomes an `.accessibilityLabel` on the container **and** is
  hidden as a visual element's accessibility (one name, not two).
- Disabled propagates through `\.isEnabled` untouched — a container never dims itself.
- Cramping: the inset is the last thing to go. Below `M.tightWidth` (240) `PanelSurface` drops its label
  before it reduces `inset`, and it never reduces `inset` below `D.space.sm`. A panel whose padding has
  collapsed reads as broken; a panel that lost its label reads as unlabelled.
- Neither container ever adds a `minHeight`. An empty well is a legitimate object — it is an empty tray —
  and callers that want a floor pass one.

---

## 7. `SeamDivider`

Where two pieces of metal meet.

### API

```swift
/// A joint between two panels. A single grey line is a divider; two hairlines, one dark and one
/// light, are a seam — the dark one is the gap, the light one is the lower panel catching the
/// light below it.
public struct SeamDivider: View {

    public enum Depth: Sendable, Hashable {
        /// `D.Seam` exactly: `seam` + `seamHighlight`, 1pt total.
        case hairline
        /// A machined channel: `seam` hairline, a `D.color.wellFill` groove of `M.channelDepth`
        /// (1.5), then `seamHighlight`. 2.5pt total. For the joint between two *structural*
        /// blocks — the deck and the content area, the rail and the panes.
        case channel
    }

    public init(_ axis: Axis = .horizontal,
                depth: Depth = .hairline,
                inset: CGFloat = 0)
}
```

`.hairline` composes `D.Seam(direction)` from the tokens file rather than redrawing it. `.channel` exists
because a 1pt seam disappears at the scale of a whole-window boundary; the tokens file has no
three-layer variant, and one is needed exactly twice (below the deck, right of the rail).

`inset` shortens the seam at both ends along its own axis, which is how a real panel joint stops short of
a rounded corner. The deck's seam uses `inset: D.radius.chassis` so it does not run into the window's
corner radius — a seam that reaches the rounded corner is the detail that gives away a fake bezel.

### Everything else

- No states. `.allowsHitTesting(false)` (inherited from `D.Seam`) and `.accessibilityHidden(true)`.
- Intrinsic thickness 1pt (`.hairline`) or 2.5pt (`.channel`); infinite along its axis.
- Increase Contrast: `.hairline` draws its dark half at `D.border.thin`, keeping the light half hairline,
  so the joint gains definition without becoming a black rule.
- Never animated. Never coloured. If a divider needs to indicate something, the thing it separates should
  be indicating it instead.

---

## 8. `RockerSwitch`

The physical toggle for every boolean in Settings. A plate that pivots on its centre: one end goes down,
the other stands proud.

### API

```swift
/// A rocker toggle. Implemented as a `ToggleStyle` so it inherits the whole of `Toggle`'s
/// behaviour — the `.isToggle` trait, "on"/"off" as an accessibility value, Space to flip,
/// label association, Full Keyboard Access focus — rather than re-deriving any of it.
public struct RockerSwitchStyle: ToggleStyle {
    public init()
    public func makeBody(configuration: Configuration) -> some View
}

/// Convenience wrapper: `Toggle(label, isOn:).toggleStyle(RockerSwitchStyle())` plus the
/// explanatory caption that most settings need.
public struct RockerSwitch: View {
    /// - Parameters:
    ///   - label: natural case; `D.type.silkscreen` uppercases it.
    ///   - caption: one plain sentence in `D.type.explain`, or nil.
    public init(_ label: String, isOn: Binding<Bool>, caption: String? = nil)
}
```

### Anatomy

Plate size `M.rockerWidth` × `M.rockerHeight` = `D.size.buttonHeight + D.space.xs` (34) ×
`D.size.buttonHeight * 0.6` (18).

| # | Layer |
|---|---|
| 0 | **Seat** — `RoundedRectangle(cornerRadius: D.radius.control)` at plate size + `M.capSeatOutset` on each side, `D.color.wellFill`, `.innerShadow(shape, D.shadow.wellInner)`. |
| 1 | **Two halves** — the plate split down the middle into leading (`O`) and trailing (`I`) halves, each `M.rockerWidth / 2` wide, each a `RoundedRectangle(cornerRadius: D.radius.control)` (only the outer corners rounded — use `UnevenRoundedRectangle`). The **down** half: `D.surface.buttonCap(pressed: true)`, `.innerShadow(_, D.shadow.pressedInner)`, offset `y: +1`. The **up** half: `D.surface.buttonCap(pressed: false)`, `.innerShadow(_, D.shadow.capInnerLight)`, `.shadow(D.shadow.cap)`. |
| 2 | **Pivot seam** — `SeamDivider(.vertical)` down the centre, full plate height. This is the line the plate rocks about, and it is the reason the control reads as one plate rather than two buttons. |
| 3 | **Legends** — `"O"` on the leading half, `"I"` on the trailing half, `D.type.silkscreenTiny`, `D.color.displayInk`, `.shadow(D.shadow.engraved)`. The legend on the *down* half drops to `D.opacity.ghost` — it is in shadow. |
| 4 | **Label block** — `D.space.sm` after the plate: `SilkscreenLabel(label)` and, if present, the caption in `D.type.explain` / `D.color.textSecondary` on the next line. |
| 5 | **Focus** — `.focusRing(isFocused, radius: D.radius.control + M.capSeatOutset)` on the seat. |

**Off** = leading half down. **On** = trailing half down, so the `I` is pressed in. There is no colour
change in either direction and no track fill: the state is which end is down, exactly as on the hardware.
Resisting the urge to tint the "on" state green is what keeps this from being a system `Switch` in
costume — and the app has no spare accent to tint it with anyway.

### States

| State | Geometry |
|---|---|
| off / on | as above; the halves swap roles |
| hover | the *up* half lifts `M.hoverLift` (0.5), matching `TapeButton` |
| pressed | the half being pressed goes down immediately (`D.motion.press`) even before the value flips, so the control tracks the finger |
| disabled | current position held, whole control at `D.opacity.disabled` |
| focused | focus ring on the seat |

### Interaction and animation

- The whole row — plate, label and caption — is the hit target, because `Toggle`'s label is part of the
  control. `.contentShape(Rectangle())` over the row.
- The flip animates with `D.motion.press` on the way down and `D.motion.release` on the way up, applied
  to the two halves' offsets and shadows. Total travel 1pt each way. No rotation is drawn: a 3D tilt at
  18pt tall is a blur, and two offsets read as a tilt.
- **Reduce Motion:** the offsets change instantly. The state is still fully legible because it is
  geometry, not motion.

### Accessibility

- Free from `Toggle`: `.isToggle` trait, the label as the name, "on"/"off" as the value.
- The caption becomes `.accessibilityHint(caption)` and is `.accessibilityHidden(true)` as a visual
  element, so it is available on demand without being read twice.
- The `O`/`I` legends are `.accessibilityHidden(true)` — they are decoration once the toggle has a value.
- Increase Contrast: the down half's legend goes to full opacity; the pivot seam draws at `D.border.thin`.

### Layout and cramping

Plate is fixed at 34 × 18 and never scales. The row's height is
`max(M.rockerHeight + M.capSeatOutset * 2, label block height)`, with the plate `.firstTextBaseline`-aligned
to the label. Degradation order: the caption truncates to two lines and then drops; the label truncates;
the plate never moves and never shrinks. Minimum useful row width `M.rockerRowMin` (200).

---

## 9. `TranscriptRow`

One line of the printed log. This is the densest component in the app and the one the user reads most, so
its rules are the strictest.

### API

```swift
/// One row of the history table. Renders a `Transcript` (Data/HistoryStore.swift) and owns none
/// of its state: selection and hover fills are inputs, not internal.
public struct TranscriptRow: View {
    /// - Parameters:
    ///   - transcript: the record. `corrections`, `injection` and `droppedBuffers` all drive the
    ///     flag column; see §9.3.
    ///   - isSelected: driven by the pane's selection, never by a tap the row handled itself.
    ///   - onCopy: copies `transcript.text`. The row does not touch `NSPasteboard`.
    public init(_ transcript: Transcript,
                isSelected: Bool,
                onCopy: @escaping () -> Void)
}
```

The row lives inside `RecessedWell(fill: .list)`, whose fill is `D.color.panelRecessed` — appearance
tracking — which is what makes `D.color.textPrimary` and `D.color.textSecondary` the correct inks here.
If the list were built on `D.surface.wellFill` (near-black in both appearances) the transcript text
would be near-black on near-black in the light appearance. This is the single most likely bug in the
history pane; the `Fill` enum in §6.2 exists to prevent it and `\.edictInkOnDark` is asserted `false` in
a debug build.

### 9.1 Columns

Height is exactly `D.size.rowHeight` (26) in every state — collapsed *and* selected. Horizontal padding
`D.space.rowInset` (10) each side, inter-column gap `D.space.sm` (8).

| Column | Width | Content |
|---|---|---|
| Time | `M.colTime` = 38 | `HH:mm` from `transcript.createdAt`, 24-hour, `D.type.counterSmall`, `D.color.textSecondary`. 24-hour because a log is a log, and because it is fixed-width where `h:mm a` is not. Formatted with an explicit `Locale(identifier: "en_US_POSIX")` calendar so no locale substitutes digits. |
| Duration | `M.colDuration` = 44, trailing-aligned | `SegmentCounter(.duration(transcript.audioDuration), scale: .small, seated: false)` |
| Words | `M.colWords` = 40, trailing-aligned | `SegmentCounter(.count(transcript.wordCount, unit: "w"), scale: .tiny, seated: false)` |
| Flag | `M.colFlag` = 12 | one glyph, or empty. §9.3 |
| Text | flexible, `minWidth` 120 | `transcript.text`, `D.type.body`, `D.color.textPrimary`, `.lineLimit(1)`, `.truncationMode(.tail)` |
| Copy | `D.size.iconButton` (22) | `TapeButton(role: .neutral, size: .icon, action: onCopy) { Image(systemName: "square.on.square") }`, glyph at `M.iconGlyphSize` (9) semibold in `D.color.displayInk` |

**No row separators and no banding.** A 26pt row with a fixed-pitch time column already reads as a
printed log; a hairline under every row at this density turns the table into graph paper, and zebra
striping is a web table idiom. The well's own edge frames the list, and selection is the only fill. This
is a deliberate decision, not an omission.

### 9.2 States

| State | Treatment |
|---|---|
| normal | no fill |
| hover | full-bleed overlay of `D.color.highlightInner` at `D.opacity.halo` (→ ≈15% white in light, ≈4% in dark — a lift, not a tint), and the copy key becomes visible |
| selected | full-bleed `D.color.selectionFill`, a `D.border.hairline` rule in `D.color.selectionStroke` along the top **and** bottom edge, text `D.color.selectionText`, secondary text `D.color.selectionText` at `D.opacity.ghost`. A **full-width band with square ends**, never an inset rounded pill — a pill is a list-row idiom from the web; a band across the whole tray is a backlit line on a tape counter. |
| selected + hover | selected fill, plus the same `highlightInner` overlay |
| copy pressed | the icon key's own `pressedCap` |
| focused (row) | `.focusRing` is **not** used on rows; keyboard focus in a table is selection, and drawing both is noise |

The copy key is **present but invisible** on non-hovered rows: it occupies its 22pt column always, with
`.opacity(0)` and `.allowsHitTesting(false)`, so nothing in the row shifts when the pointer arrives.
Reveal is instant under Reduce Motion, otherwise `D.motion.readout` (0.12 s opacity only).

### 9.3 The flag column

At most one glyph, chosen by priority, because a row with three markers communicates nothing:

1. `transcript.injection == .failed || == .clipboardOnly` → a filled `M.flagSize` (6) square in
   `D.color.alert`. Value: "not inserted".
2. `transcript.droppedBuffers > 0` → a hollow `M.flagSize` square, `D.border.hairline` stroke in
   `D.color.alert`. Value: "may be incomplete".
3. `!transcript.corrections.isEmpty` → a filled `M.flagSize` diamond (a square rotated 45°) in
   `D.color.selectionStroke`. Value: "N dictionary corrections". Amber-ink family, deliberately *not*
   `D.color.alert` — the dictionary firing is the feature working, not a warning — and deliberately not
   red.

Each carries `.help(_:)` with the same text as its accessibility value, so the flag is discoverable with
a pointer as well as with VoiceOver. Shape, not just colour, distinguishes all three.

### 9.4 Long text

`.lineLimit(1)` with tail truncation and the system ellipsis. No fade mask (a gradient mask is a web
idiom and it makes the last legible word ambiguous), no `.minimumScaleFactor` (shrinking body text
breaks the row's optical rhythm), no wrapping (a variable-height row destroys the printed-log read and
makes the table scroll unpredictably). The full text is reachable three ways: `.help(transcript.text)`,
the copy key, and selecting the row — which is what reveals the raw-vs-corrected diff in the pane below.

### 9.5 Accessibility

- `.accessibilityElement(children: .combine)` so the row is one element, with `.isSelected` when selected.
- Label: the transcript text. Value: `"14:32, 4.2 seconds, 12 words"` plus the flag's phrase when
  present. Spoken forms, not the printed ones (§5).
- The copy key keeps its own element with `.accessibilityLabel("Copy transcript")`.
- Increase Contrast: the hover overlay doubles to `D.opacity.halo * 2`; the selected band's rules go to
  `D.border.thin`; secondary text drops `D.opacity.ghost`.

### 9.6 Cramping

Degradation order as the pane narrows, one step at a time:

1. < `M.rowWide` (620): drop the Words column.
2. < `M.rowMedium` (480): drop the Duration column.
3. < `M.rowNarrow` (360): drop the Time column. The row is now flag + text + copy.
4. The text column's 120pt minimum, the flag and the copy key never yield. Below that the window is
   below `D.size.windowMin` and cannot exist.

Widths are fixed, not proportional, so every row in the table is in the same place — the columns are what
makes it a log, and a percentage-based column ruins that at the first long transcript.

---

## 10. `EquipmentSearchField`

Search as a piece of instrumentation: a channel cut into the panel with a legend plate at one end and a
match count at the other.

### API

```swift
/// A search channel. Not a `TextField` in a rounded rect — the system field's focus ring, its
/// bezel and its magnifying glass all read as macOS chrome, which is the one thing this app
/// must never look like.
public struct EquipmentSearchField: View {
    /// - Parameters:
    ///   - legend: the plate at the leading edge. Natural case; uppercased by the type style.
    ///   - text: the live query. The field is fully controlled; it never debounces (the store does).
    ///   - resultCount: matches, printed at the trailing edge. Nil hides the readout entirely.
    public init(legend: String = "Find",
                text: Binding<String>,
                resultCount: Int? = nil,
                onSubmit: (() -> Void)? = nil)
}
```

### Anatomy

Height `M.fieldHeight` = `D.size.rowHeight` (26) — the same as a table row, so the field and the list it
filters share one rhythm.

| # | Layer |
|---|---|
| 0 | **Channel** — `RecessedWell(fill: .list, radius: D.radius.well, inset: 0)`. `.list`, not `.display`: the user's query is content to be read, so it must be `D.color.textPrimary` on `panelRecessed`. |
| 1 | **Legend plate** — leading, `D.space.wellInset` of padding, `SilkscreenLabel(legend, weight: .tiny)` on a `PanelSurface(material: .painted, radius: D.radius.tight, inset: D.space.xxs)`, followed by `SeamDivider(.vertical)` full-height. A raised plate inside a recess: the label is printed on metal, and the seam separates it from the channel. |
| 2 | **Field** — `TextField("", text: text)` with `.textFieldStyle(.plain)`, `.focusEffectDisabled()`, `.typeStyle(D.type.body)`, `.foregroundStyle(D.color.textPrimary)`, `.padding(.horizontal, D.space.sm)`, `.onSubmit(onSubmit ?? {})`. `.focusEffectDisabled()` is mandatory — without it the system draws its blue ring inside the machined channel. |
| 3 | **Placeholder** — not `TextField`'s prompt (which renders in the system's secondary colour): when `text.isEmpty && !isFocused`, an overlaid `SilkscreenLabel("Search", weight: .standard)` in `D.color.textSecondary` at `D.opacity.ghost`, `.allowsHitTesting(false)`. |
| 4 | **Count readout** — trailing, `SegmentCounter(.count(count, unit: "hit"), scale: .tiny, seated: false)` for the unwrapped `count` in `D.color.textSecondary`. Hidden when `resultCount == nil` **or** `text.isEmpty` — a count of everything is not information. |
| 5 | **Clear key** — trailing, `TapeButton(size: .icon)` with the legend `"Clr"` in `D.type.silkscreenTiny`. A text legend rather than an `xmark` glyph, because "CLR" is what the panel would actually say. Present only when `!text.isEmpty`, in a reserved 22pt column so nothing shifts. |
| 6 | **Focus** — `.focusRing(isFocused, radius: D.radius.well)` on the channel. |

### States

| State | Treatment |
|---|---|
| empty, unfocused | placeholder visible, no count, no clear key |
| focused | focus ring; placeholder hidden even when empty (the caret is the invitation) |
| typing | count updates with `D.motion.readout` on the *container*; the digits themselves never animate |
| no matches | the count reads `0 hit` in `D.color.alert`. That is the whole no-results treatment — no empty-state illustration, no message inside the channel |
| disabled | `D.opacity.disabled` over everything; channel keeps its inner shadow |

### Accessibility

- `.accessibilitySearchField()` trait via `.accessibilityAddTraits(.isSearchField)`, label from `legend`,
  value from `text`.
- The count is announced by making it the field's `.accessibilityValue` suffix — `"cloud, 3 matches"` —
  rather than as a separate element, so a screen-reader user gets the result of typing without hunting
  for a sibling label.
- The clear key is its own element, `.accessibilityLabel("Clear search")`.
- `Escape` clears the field when non-empty (`.onExitCommand`), which is macOS-standard and free.
- Increase Contrast: placeholder to full opacity; the vertical seam to `D.border.thin`.

### Cramping

Degradation order: count readout → legend plate and its seam → clear key never. Minimum width
`M.fieldMin` (140), below which the field is still usable as a bare channel. Height never changes; the
field never becomes a magnifying-glass icon that expands on click.

---

## 11. `Waveform`

The scrolling level trace shown while recording. A chart recorder, not an oscilloscope.

### API

```swift
/// A scrolling level trace. Owns a ring buffer of decimated columns and samples the incoming
/// envelope on its own tick; like `VUMeter` it treats `level` as continuously valid and needs
/// no stream, no sequence number and no change detection.
public struct Waveform: View {
    /// Seconds of history shown across the full width.
    public static let defaultWindow: TimeInterval = 8

    public init(level: AudioFrame, isLive: Bool, window: TimeInterval = Waveform.defaultWindow)
}

/// The ring buffer. `@State`-owned, `@MainActor`, not `@Observable` — same contract as
/// `NeedleBallistics` (§0.6).
@MainActor final class LevelTrace {
    /// Fixed capacity, allocated once. `M.traceCapacity = 256`.
    private(set) var columns: [Column]      // Column { meanDBFS, peakDBFS: Double }
    /// Integrates the envelope every render tick and commits one column per `columnPeriod`.
    func tick(at date: Date, dbfs: Double, columnPeriod: TimeInterval)
    func clear()
}
```

### 11.1 Why this is not the VU meter

They answer different questions and are drawn from different statistics, which is why one is not a
rotation of the other:

| | `VUMeter` | `Waveform` |
|---|---|---|
| Question | "Am I at the right level *right now*?" | "Did it hear me for the last eight seconds?" |
| Statistic | one integrated value | 80-ish columns of (mean, peak) history |
| Ballistics | ANSI C16.5, deliberately slow — short transients are *hidden* on purpose | per-column peak deliberately *preserved*, so a clipped syllable stays visible |
| Calibration | against a printed scale with a reference mark; the numbers mean something | none; the strip is relative and unlabelled |
| Failure it catches | speaking too quietly, or clipping | a dead microphone, a gap mid-sentence, a device change |

The second row is the substantive one. If the waveform were drawn from the needle's value it would be a
smeared duplicate of the meter and would not catch the failure it exists to catch.

### 11.2 Data window and decimation

The audio tap's buffer size is hard-clamped to 100–400 ms (RECON §19), so levels arrive at **2.5–10 Hz**.
Everything about the column rate follows from that number:

- The trace integrates the incoming `dbfs` with the *same* one-pole filter the needle uses
  (`D.motion.needleCoefficient`, attack 0.065 s, release 0.150 s) on every render tick, and commits the
  integrated value as a column every `columnPeriod`. Integrating first is what stops a 400 ms buffer
  from producing four identical columns and a visible staircase.
- `columnPeriod` is derived, never chosen at the call site:

```swift
let targetPitch: CGFloat = D.space.xs * 1.5          // 6pt per column
let byWidth  = Int(size.width / targetPitch)
let byRate   = Int(window / M.minColumnPeriod)        // M.minColumnPeriod = 0.1
let count    = min(max(min(byWidth, byRate), M.minColumns), M.maxColumns)   // 40 … 160
let columnPeriod = window / Double(count)
```

  At the default 8 s window in a 600pt strip that is `min(100, 80)` = 80 columns, a 0.1 s period and a
  7.5pt pitch: a 5pt bar with a 2.5pt gap. **Never faster than 10 Hz**, because a column rate above the
  source rate is invented data, and chunky honest columns look more like equipment than a dense fake
  waveform does.
- Each column stores two values: `meanDBFS` (the integrated envelope, i.e. the mean of the tick samples
  in that column's period) and `peakDBFS` (their maximum). Both are stored in **dB**, not in fraction, so
  a resize re-maps the drawing without touching the buffer.
- Capacity is a fixed 256-element array — larger than `M.maxColumns`, allocated once, written as a ring.
  A resize changes `count` and therefore how many of the stored columns are drawn; it never reallocates
  and never clears history.
- `clear()` on `isLive` false→true. History from the previous utterance in the current utterance's strip
  is a lie.

### 11.3 Anatomy

Fixed height `D.size.waveformHeight` (44), flexible width, inside
`RecessedWell(fill: .display, radius: D.radius.well, inset: D.space.xs)`. One `Canvas`.

| # | Layer |
|---|---|
| 0 | **Baseline** — a `D.border.hairline` rule in `D.color.displayInk` at `D.opacity.halo`, along the bottom inside edge of the well. |
| 1 | **Bars** — bottom-anchored rectangles, `M.barWidth` = pitch × 0.67, height `D.meter.fraction(dbfs: meanDBFS) × usableHeight`, filled `D.meter.zoneColor(dbfs: meanDBFS)` — green below `hotDBFS`, amber to `overDBFS`, `D.color.meterRed` above. This is the one place besides the meter where `meterRed` is allowed, and it is exactly the case the token was tuned for: red against `D.surface.wellFill`. |
| 2 | **Peak caps** — a `D.border.thin` horizontal tick at `D.meter.fraction(dbfs: peakDBFS) × usableHeight`, same bar width, in `D.color.displayInk` at `D.opacity.ghost`. This is the column's transient, and it is why the strip catches a clip the needle deliberately smoothed away. |
| 3 | **Scroll** — the whole bar set is translated by the fraction of `columnPeriod` elapsed since the last commit, times the pitch, so the trace moves continuously instead of jumping once per column. |
| 4 | **Leading edge marker** — a `D.border.thin` vertical rule in `D.color.displayInk` at the write head (the trailing edge of the strip). The paper always moves *toward* the head, so the newest column is on the right. |

`usableHeight = D.size.waveformHeight - D.space.xs * 2 - D.border.hairline`.

**Bottom-anchored, not mirrored.** A symmetric waveform about a centre line is an oscilloscope trace or
— far more damningly — the Voice Memos / dictation-app cliché. A level recorder draws from a baseline,
and that is what this is.

### 11.4 Redraw

- `TimelineView(.animation(minimumInterval: M.traceTickInterval, paused: !isLive))` at
  `M.traceTickInterval = 1.0 / 30.0`. 30 Hz, half the needle's rate: between commits the only thing
  changing is one translation, and the ballistics integration is stable at 30 Hz because the clamped
  real `dt` goes into `needleCoefficient` exactly as in §2.3.
- `LevelTrace.tick` is called from the timeline's content closure, and the resulting `[Column]` slice
  plus the scroll offset are passed into the `Canvas` as plain values. Same contract as the meter: no
  state invalidation per frame, no mutation inside the renderer.
- Colours are resolved once per draw before the column loop.
- `paused` when not live, so an idle window costs nothing.
- Budget: ≤ 160 rects + 160 ticks + 2 rules = under 350 primitives, one draw, no shadows, no blurs, no
  `.drawingGroup()`.

### 11.5 States

| State | Treatment |
|---|---|
| live | scrolling, write head visible |
| idle (never recorded) | empty well, baseline only, at `D.opacity.ghost`. No placeholder waveform — a fake trace in an idle strip is the kind of decoration this app does not do. |
| idle (after an utterance) | the last trace stays, frozen, at `D.opacity.ghost`, write head hidden. The user gets to see what was just captured. |
| transcribing | frozen trace at full opacity, write head hidden — the audio is finished but the utterance is not |
| disabled / no input device | empty well plus a centred `SilkscreenLabel("No input", weight: .tiny)` in `D.color.alert` |

### 11.6 Accessibility and Reduce Motion

- `.accessibilityHidden(true)`. The strip is a redundant view of the same signal `VUMeter` already
  exposes with a value and a label, and two elements narrating the same level is worse than one.
  The one exception is the "No input" state, which is real information: it is announced through
  `StatusReadout`, not here.
- **Reduce Motion:** the interpolated scroll is dropped. Columns shift only when one is committed, so the
  strip updates in discrete steps at the column rate (≈10 Hz) instead of moving continuously. The
  `minimumInterval` also relaxes to `M.minColumnPeriod`, since nothing between commits changes any more —
  which incidentally makes the Reduce Motion path the cheapest one.
- **Increase Contrast:** peak caps go to full opacity; the baseline rule to `D.border.thin`; bar width
  +0.5 (gaps narrow correspondingly, pitch is unchanged).

---

## 12. `StatusReadout`

The small lit channel that says, in words, what the machine is doing. Everything the record lamp
indicates is also written here, which is what makes the lamp safe as a colour-only signal.

### API

```swift
/// The status channel. `Condition` is declared *here*, in the design layer, and the shell maps
/// `DictationPhase` + `ModelState` onto it — the design layer must not import App types, and a
/// component that switched on `DictationPhase` would drag the whole app model into the previews.
public struct StatusReadout: View {

    public enum Condition: Sendable, Hashable {
        case ready
        case armed
        case listening
        case transcribing
        case injecting
        /// 0…1. Model download.
        case downloading(Double)
        /// Terminal, user-visible failure. The string is shown verbatim.
        case fault(String)
        /// A permission is missing; the string names it.
        case needsPermission(String)
    }

    /// - Parameter compact: drops the tell-tale and uses `D.type.silkscreenTiny`. For the HUD and
    ///   the menu-bar popover.
    public init(_ condition: Condition, compact: Bool = false)
}
```

### Anatomy

Height `M.statusHeight` = `D.size.troughHeight * 3` (18), or `D.size.troughHeight * 2` (12) when compact.

| # | Layer |
|---|---|
| 0 | **Channel** — `RecessedWell(fill: .display, radius: D.radius.tight, inset: D.space.xs)`. Dark in both appearances, so the readout is lit. |
| 1 | **Tell-tale** — a `M.tellTaleSize` (5) square, leading, `D.space.xs` from the text. Dark: `D.color.displayInk` at `D.opacity.disabled`. Lit: `D.color.displayInk`. Alert: `D.color.alert`. A square, not a circle — the round lit thing in this app is the record lamp, and there is one of those. |
| 2 | **Text** — `.typeStyle(D.type.silkscreen)` (or `silkscreenTiny` when compact), `D.color.displayInk`, `.lineLimit(1)`, `.truncationMode(.tail)`. |
| 3 | **Progress rule** (`.downloading` only) — a `M.progressHeight` (1.5) bar along the channel's bottom inside edge, `D.color.displayInk`, width `= fraction × channel width`. A hairline creeping along the bottom of the channel, not a progress bar with a track: the channel *is* the track. |

### Conditions

| Condition | Text (natural case, uppercased by the style) | Tell-tale | Notes |
|---|---|---|---|
| `ready` | `"Ready"` | lit | |
| `armed` | `"Armed"` | lit at `D.opacity.ghost` | pairs with `RecordLamp(.armed)` |
| `listening` | `"Listening"` | lit | |
| `transcribing` | `"Transcribing"` | lit | the longest string; it sets the reserved width |
| `injecting` | `"Inserting"` | lit | |
| `downloading(p)` | `"Model 42%"` — `String(format: "Model %.0f%%", p * 100)` | lit | plus the progress rule |
| `fault(msg)` | `msg`, verbatim | `D.color.alert` | text in `D.color.alert` |
| `needsPermission(what)` | `"\(what) required"` | `D.color.alert` | text in `D.color.alert` |

`D.color.alert` is the only colour this component ever introduces, and it is amber: red belongs to the
record lamp alone, and a red error string next to a red record lamp makes both meaningless.

### Width stability

The channel **never resizes as the condition changes**. Reserve the width of the longest fixed string —
`"Transcribing"` at `D.type.silkscreen` — with the hidden-template trick from §5:
a `ZStack(alignment: .leading)` over `Text("Transcribing").typeStyle(D.type.silkscreen).hidden()`.
`fault` and `needsPermission` carry arbitrary text and truncate into that same reserved width with
`.help(fullText)` for the rest; they never widen the deck. Minimum useful width `M.statusMin` (110) —
tell-tale, gap, and the reserved text field.

### Animation

- The text swaps with `D.motion.readout` (0.12 s), **opacity only, no slide and no
  `.contentTransition(.numericText)`**. Use `.id(condition)` + `.transition(.opacity)` so the crossfade
  is between two whole words rather than a character-level morph, which at 10pt condensed is illegible
  mush.
- The tell-tale uses `D.motion.lampOn` / `D.motion.lampOff` so it shares the filament asymmetry with the
  record lamp. It does **not** breathe or blink; `armed` is expressed by opacity, not by motion, because
  a blinking word is unreadable.
- The progress rule animates its width with `D.motion.panel`.
- **Reduce Motion:** the text swap is instant, the tell-tale switches instantly, the progress rule jumps.

### Accessibility

- `.accessibilityElement(children: .ignore)`, `.accessibilityLabel("Status")`,
  `.accessibilityValue(spokenText)` where `spokenText` is the natural-case string (`"Transcribing"`,
  `"Model 42 percent"`, the fault message) — never the uppercased display string.
- `.accessibilityAddTraits(.updatesFrequently)`.
- `fault` and `needsPermission` post an `AccessibilityNotification.Announcement` once on transition, at
  `.high` priority, because a failure the user cannot see must still reach them.
- Increase Contrast: the dark tell-tale goes from `D.opacity.disabled` to `D.opacity.ghost` and gains a
  `D.border.hairline` border in `D.color.displayInk`; `armed`'s ghosted tell-tale goes to full opacity.

---

## Composition rules

### The top deck

`D.size.deckHeight` (104) tall, full width, **one** `PanelSurface(material: .brushed, inset: D.space.md)`
— a single piece of milled aluminium, closed at the bottom by
`SeamDivider(.horizontal, depth: .channel, inset: D.radius.chassis)`. Left to right, separated by
`D.space.xl` (24):

```
┌──────────────────────────────────────────────────────────────────────────────────────────┐
│  ┌────────────────────┐   ┌──────────────┐   ┌────────────────────────────────────────┐  │
│  │   VUMeter          │   │ 00:04.2      │   │  ●  LISTENING      ┌───────┐ ┌───────┐ │  │
│  │   232 × 84         │   │ ELAPSED      │   │                    │RECORD │ │ STOP  │ │  │
│  │                    │   │ 12 W  WORDS  │   │  [ waveform 44pt ] └───────┘ └───────┘ │  │
│  └────────────────────┘   └──────────────┘   └────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

- **Block 1 — the movement.** `VUMeter`, fixed 232 × 84, hard against the deck's leading inset.
- **Block 2 — the counters.** `SegmentCounter(.elapsed, scale: .large)` seated in its display window,
  with `SilkscreenLabel("Elapsed")` beneath it at `D.space.labelGap`, and
  `SegmentCounter(.count(words, unit: "w"), scale: .small)` + `SilkscreenLabel("Words")` below that.
- **Block 3 — the transport.** A `PanelSurface(material: .plastic)` holding, on its top line,
  `RecordLamp(lampMode, fitting: .standard)` then `D.space.xxs` then `StatusReadout`, and on its bottom line the `Waveform`
  strip followed by `TapeButton("Record", role: .record, isLatched: phase == .listening)` and
  `TapeButton("Stop", role: .stop)`. The transport block is the only plastic on the deck, which is what
  makes the keys read as inserted into the metal rather than milled from it.

The left rail (`D.size.railWidth` = 172) is a `PanelSurface(material: .painted)` separated from the panes
by `SeamDivider(.vertical, depth: .channel)`. Its HISTORY / DICTIONARY selector is two full-width
`TapeButtonStyle` controls in a latching pair, not a `List` and not a `Picker`.

### The invariants

**1. One optical centre line, and blocks — not widgets — along it.** Everything on the deck is vertically
centred on the deck's own centre line, and the deck's content is exactly the three blocks above. New
controls join a block; they never appear between blocks. This is the rule that keeps the deck from
accreting into a toolbar.

**2. Every opening is a well and every control is a cap. Nothing floats.** If an element has no seat, no
inner shadow and no seam, it is wrong — there is no third material and no bare rectangle. Concretely: any
text the user *reads* sits in `RecessedWell(fill: .list)`; any number the machine *displays* sits in
`RecessedWell(fill: .display)`; any control is a cap in a seat; any group of controls is a
`PanelSurface`. `RecessedWell.Fill`'s three cases and `PanelSurface.Material`'s three are the complete inventory of
surfaces in the app.

**3. Red exactly once, amber only for alerts, green and amber only inside instrumentation.**
`D.color.recordLamp` appears on exactly one object per window — the `RecordLamp`. `D.color.meterRed`,
`meterAmber` and `meterGreen` appear only inside a `VUMeter` or a `Waveform`, i.e. only against
`D.surface.wellFill` or `D.surface.meterFace`. `D.color.alert` is the only colour permitted on the
chassis, and only for a fault. Everything else — selection, focus, hover, pressed, hits, flags — is grey,
ink, or the `selectionFill`/`selectionStroke` amber family. A new hue is a design change, not a feature.

**4. One inset grid, four values.** `D.space.panelInset` inside a panel, `D.space.wellInset` inside a
well, `D.space.rowInset` inside a row, `D.space.xl` between blocks. No view invents a fifth. This is what
makes the seams line up down the whole window, and lined-up seams are most of what "one machine" means.

**5. Fixed instrument sizes; the content area is what flexes.** `VUMeter`, `RecordLamp`,
`SegmentCounter`, `TapeButton`, `RockerSwitch` and `StatusReadout` are all intrinsically sized and never
scale with the window. When space runs short the *content* — the table, the text column, the waveform's
width — gives way, in the order each component's cramping clause specifies. A resized window changes how
much log you can see; it never changes the size of the deck.

---

## Appendix — three metrics that should become tokens

Not blocking, and deliberately left as `M` values rather than edited into `Tokens.swift`, which this agent
does not own. If a later pass touches the tokens file, these three earn promotion because more than one
component needs them:

| Suggested token | Value | Used by |
|---|---|---|
| `D.size.capSeatOutset` | `1` | `TapeButton`, `RockerSwitch`, and any future cap-in-seat control — it is the width of the gap that makes a cap read as inserted |
| `D.size.statusHeight` | `D.size.troughHeight * 3` (18) | `StatusReadout`, and the HUD's own status line, which must match it exactly |
| `D.motion.traceTickInterval` | `1.0 / 30.0` | `Waveform`, and the HUD's compact trough, which should share one cadence |
