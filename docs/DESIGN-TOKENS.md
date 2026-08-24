# Edict — design tokens

Everything visual in Edict comes from `Sources/EdictKit/Design/Tokens.swift`. No view is
permitted a one-off colour, font, spacing, radius, or duration. If a view needs something that
is not in this document, the token is missing and should be added here first.

**Visual direction.** An early-1980s portable field recorder — Sony TC-D5, Marantz PMD-430,
Nakamichi decks, Braun-era industrial design. Brushed aluminium and matte plastic. Muted warm
greys, off-black, cream, silver. Exactly one accent: the red of a record lamp. Amber and green
belong to the level indicators and nowhere else. Controls look *pressed*, not tinted. Labels are
silkscreened onto the panel. The recording indicator is a needle, not a bar.

**Call-site shape.**

```swift
D.color.recordLamp      D.space.md          D.type.silkscreen
D.radius.panel          D.motion.needle     D.surface.brushedAluminium
D.shadow.wellInner      D.meter.fraction(dbfs:)

Text("HISTORY").engravedLabel()
VStack { … }.raisedPanel()
List { … }.recessedWell()
cap.pressedCap(isHeld)
```

The nested namespaces (`D.color`, `D.space`, …) are deliberately lower-cased *types*, not values.
They are namespaces, so they cost nothing at runtime, and `D.color.deck` reads as a property path
instead of shouting a type name in the middle of every view body.

---

## How light and dark are handled

Every colour is built by one private helper:

```swift
private func dyn(_ light: UInt32, _ dark: UInt32,
                 lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color
```

which wraps `NSColor(name:dynamicProvider:)` and resolves through
`appearance.bestMatch(from:)`. Consequences worth knowing:

- **There is no such thing as a single-appearance token.** The helper takes both values or it does
  not compile. Nothing in the file can define a colour for only one appearance.
- The resolver matches against four appearances, not two: `.aqua`, `.darkAqua`,
  `.accessibilityHighContrastAqua`, `.accessibilityHighContrastDarkAqua`, folding each
  high-contrast appearance onto its base. A high-contrast user gets the chassis, not a fallback grey.
- Colours are specified in **sRGB**, not device RGB. The palette is designed, not sampled, and must
  look the same on every display.
- Resolution happens at draw time inside AppKit, so a token used in a `LinearGradient`, a
  `strokeBorder`, or a `Shadow` still tracks the appearance the view is actually drawn in.

Dark mode is **not** an inversion. The chassis goes from painted aluminium to off-black, but the
VU faceplate stays cream in both appearances (`D.color.meterFace`) — a lit meter is lit — and
`D.color.displayInk` stays light in both, because it is only ever used inside a dark well.

---

## Colour
| Token | Light | Dark | Purpose |
|---|---|---|---|
| `D.color.deck` | `#BEB9AE` | `#232220` | The window's ground: the painted chassis everything else is bolted to. |
| `D.color.panelRaised` | `#D2CDC2` | `#322F2B` | A panel sitting proud of the deck. Default background for grouped controls. |
| `D.color.panelRecessed` | `#A6A198` | `#1A1918` | A panel sunk into the deck. Backing for lists, tables, and text areas. |
| `D.color.panelPlastic` | `#33312D` | `#191817` | Matte black plastic insert — button caps, the transport block, the HUD body. |
| `D.color.metalBase` | `#C8C3B8` | `#3A3835` | Mid tone of a brushed-aluminium face. Used by `D.surface.brushedAluminium`. |
| `D.color.metalHighlight` | `#EDE9DF` | `#55524C` | Top-lit edge of brushed aluminium. |
| `D.color.metalShadow` | `#8F8B81` | `#171615` | Bottom shade of brushed aluminium. |
| `D.color.wellFill` | `#1C1B19` | `#121110` | The darkness inside a well: meter face surround, display cut-outs, level trough. |
| `D.color.seam` | `#858177` | `#100F0E` | The dark line where two panels meet. One hairline, never a fat rule. |
| `D.color.seamHighlight` | `#E4E0D6` | `#454239` | The light catch immediately below a seam. Together they read as a real joint. |
| `D.color.bezel` | `#9B968C` | `#302E2B` | Body of a bezel ring around a meter, lamp, or display. |
| `D.color.bezelHighlight` | `#EFEBE2` | `#504C45` | Top-left of the bezel, catching the light. |
| `D.color.bezelShadow` | `#6E6A62` | `#0C0B0A` | Bottom-right of the bezel, in shade. |
| `D.color.textPrimary` | `#201F1C` | `#E9E5DA` | Transcript text, list content, anything the user reads for meaning. |
| `D.color.textSecondary` | `#4A4741` | `#9C988D` | Timestamps, counts, secondary metadata. |
| `D.color.textSilkscreen` | `#4A463E` | `#B0AB9E` | Silkscreened equipment labels printed onto the panel. Never for prose. |
| `D.color.displayInk` | `#E6E2D6` | `#E9E5DA` | Ink used *inside* a dark well — counter digits, HUD text. Light in both appearances. |
| `D.color.recordLamp` | `#B0241A` | `#E33C2B` | The record light. This red appears nowhere else in the app. |
| `D.color.recordLampOff` | `#7A5A54` | `#4A2E2A` | The same lens, unlit: a dead red-brown, not a grey hole. |
| `D.color.recordLampHalo` | `#E8564A` | `#FF6A55` | Bloom around a lit lamp. Used at low opacity, never as a glow effect on text. |
| `D.color.meterFace` | `#D9D2BF` | `#C4BDA9` | Cream VU faceplate. Stays warm and pale in dark mode — a lit meter is lit. |
| `D.color.meterScale` | `#3A3833` | `#2A2925` | Printed scale, tick marks, and the "VU" legend on the faceplate. |
| `D.color.meterNeedle` | `#23221F` | `#1A1917` | The needle itself. |
| `D.color.meterNeedleShadow` | `#8F887A` | `#7C776B` | The needle's cast shadow on the faceplate; sells the air gap under the glass. |
| `D.color.meterGreen` | `#4C8A3A` | `#6FBE51` | Safe zone: normal speech level. |
| `D.color.meterAmber` | `#C08618` | `#E4A733` | Hot zone: loud but usable. |
| `D.color.meterRed` | `#CE3826` | `#DC4230` | Over: clipping, in the bargraph/trough. Tuned against `wellFill`, not the faceplate. Deliberately close to, but not the same as, `recordLamp`. |
| `D.color.meterOverBand` | `#A82418` | `#8E1C12` | The red band screen-printed above 0 VU on the cream faceplate. Ink on cream in both appearances, which is why it cannot reuse `meterRed`. |
| `D.color.selectionFill` | `#CDC3A6` | `#4A4230` | Selected row fill. A dim amber wash, like a backlit tape counter. |
| `D.color.selectionStroke` | `#8A7C55` | `#8E7C4C` | Selected row edge. |
| `D.color.selectionText` | `#1B1A17` | `#F0ECE0` | Text on top of `selectionFill`. |
| `D.color.focusRing` | `#7E7150` | `#C9B57A` | Keyboard focus ring. Same family as selection so focus never introduces a new hue. |
| `D.color.alert` | `#76400C` | `#DE9A34` | The single alert colour: permissions missing, injection failed, clipping sustained. Amber, not red — red belongs to the record lamp alone. |
| `D.color.shadowHard` | `#000000` · 30% | `#000000` · 62% | Tight contact shadow directly under a raised part. |
| `D.color.shadowSoft` | `#000000` · 16% | `#000000` · 40% | Ambient shadow further out. |
| `D.color.shadowInner` | `#000000` · 42% | `#000000` · 72% | The dark rim cast *inside* a recessed well from its top edge. |
| `D.color.highlightInner` | `#FFFFFF` · 55% | `#FFFFFF` · 14% | The light rim on the *bottom* inside edge of a well, and the top edge of a raised panel. |
| `D.color.metalGrain` | `#FFFFFF` · 3.2% | `#FFFFFF` · 2.2% | Fine longitudinal grain drawn over brushed metal. |
| `D.color.metalGrainDark` | `#000000` · 2.8% | `#000000` · 8.5% | Counter-grain, the dark half of the striation pair. |

### Contrast check

Measured WCAG relative-luminance ratios against the background each token is actually drawn on.
Light appearance was the binding constraint throughout; several greys and the alert amber were
darkened until the 10–11pt styles cleared 4.5:1.

| Pair | Light | Dark |
|---|---|---|
| `textPrimary` on `deck` | 8.4 | 12.6 |
| `textPrimary` on `panelRaised` | 10.4 | 10.6 |
| `displayInk` on `wellFill` | 13.3 | 15.0 |
| `textSecondary` on `deck` | 4.7 | 5.5 |
| `textSilkscreen` on `deck` | 4.8 | 6.9 |
| `textSilkscreen` on `panelRaised` | 5.9 | 5.8 |
| `selectionText` on `selectionFill` | 9.9 | 8.4 |
| `meterScale` on `meterFace` | 7.8 | 7.8 |
| `meterNeedle` on `meterFace` | 10.6 | 9.4 |
| `meterOverBand` on `meterFace` | 4.8 | 4.3 |
| `alert` on `panelRaised` | 5.3 | 6.6 |
| `recordLamp` on `deck` | 3.5 | 3.7 |

`recordLamp` is a lens, not text, so it is held to the 3:1 bar for non-text UI components — and it
is always drawn inside a bezel ring, which raises its effective edge contrast further.

---

## Typography

Two faces, both shipped with every macOS install, so there is no `NSFont(name:)` lookup that can
return `nil` and no bundled font file to sign.

| Face | Reached via | Why |
|---|---|---|
| **SF Pro** | `Font.system(size:weight:)`, plus `.width(.condensed)` | A neutral grotesque — exactly the genre used for panel silkscreening in the period. The condensed width narrows the letterforms the way a real screen-printed label is narrowed to fit under a control, and it takes positive tracking without the counters closing up. |
| **SF Mono** | `Font.system(…, design: .monospaced)` | Fixed pitch for counters and timings, so a running clock never reflows. `.monospacedDigit()` is applied on top so a digit never jitters — a jittering digit reads as a software bug, not a mechanical counter. |

Tracking cannot live on `Font` in SwiftUI, so a font-only token would leak the most important part
of the silkscreen look back to every call site. `D.TypeStyle` carries face, tracking, casing, and
leading together and is applied with a single modifier:

```swift
Text("DICTIONARY").typeStyle(D.type.silkscreen)
```

| Token | Size / weight | Width | Tracking | Case | Leading | Purpose |
|---|---|---|---|---|---|---|
| `D.type.silkscreen` | 10 semibold | condensed | 1.15 | upper | — | The workhorse panel label. |
| `D.type.silkscreenTiny` | 8.5 semibold | condensed | 0.95 | upper | — | Scale legends, tick labels, unit suffixes. |
| `D.type.silkscreenHeading` | 12 bold | condensed | 1.60 | upper | — | Heading above a whole block of controls. |
| `D.type.buttonCap` | 10.5 bold | condensed | 1.30 | upper | — | Label moulded into a button cap; heavier so it survives the shadow. |
| `D.type.body` | 13 regular | — | 0 | — | 2 | Transcript text and list content. |
| `D.type.bodyEmphasis` | 13 semibold | — | 0 | — | — | The matched side of a correction pair. |
| `D.type.caption` | 11 regular | — | 0.10 | — | — | Timestamps, word counts, hit counts, file paths. |
| `D.type.explain` | 11.5 regular | — | 0 | — | 3 | One plain sentence explaining a permission or a risk. |
| `D.type.counter` | 26 medium mono | — | 1.00 | — | — | The elapsed counter on the transport deck. |
| `D.type.counterSmall` | 12 medium mono | — | 0.40 | — | — | Per-row duration, latency readout. |
| `D.type.numeralTiny` | 9 semibold mono | — | 0.50 | — | — | dBFS readout beside the meter. |
| `D.type.mono` | 11.5 regular mono | — | 0 | — | 2 | A rule's regex, or a raw-vs-corrected diff. |

All numeral styles carry `.monospacedDigit()`.

---

## Spacing, radii, borders, metrics

### Spacing scale — 4pt based; nothing lands off the scale

| Token | Value | Purpose |
|---|---|---|
| `D.space.xxs` | `2` | hairline gaps, lamp-to-label. |
| `D.space.xs` | `4` | inside a control. |
| `D.space.sm` | `8` | between related controls. |
| `D.space.md` | `12` | default padding inside a panel. |
| `D.space.lg` | `16` | between panels in the same block. |
| `D.space.xl` | `24` | between functional blocks (transport deck vs. content). |
| `D.space.xxl` | `32` | window margin on the long axis. |
| `D.space.xxxl` | `48` | reserved for the top deck's breathing room. |
| `D.space.panelInset` | `12` | Inset used by every raised panel's content. |
| `D.space.wellInset` | `8` | Inset used inside a recessed well (tighter — the well already reads as a frame). |
| `D.space.rowInset` | `10` | Horizontal padding of a table row. |
| `D.space.labelGap` | `5` | Gap between a silkscreen label and the thing it labels. |

### Corner radii

Deliberately small. This is milled metal and injection-moulded plastic; a soft radius is the
fastest way to make it look like a web component.

| Token | Value | Purpose |
|---|---|---|
| `D.radius.square` | `0` | genuinely square: seams, scale ticks. |
| `D.radius.tight` | `2` | tick caps, tiny chips. |
| `D.radius.control` | `3` | button caps and toggles. |
| `D.radius.well` | `4` | recessed wells and text fields. |
| `D.radius.panel` | `5` | raised panels. |
| `D.radius.bezel` | `7` | bezel rings and the meter housing. |
| `D.radius.chassis` | `10` | the window chassis itself and the HUD. |
| `D.radius.pill` | `999` | A pill, for the level trough. |

### Border widths

Hairlines are specified in points and assume a backing scale of 2x or better.

| Token | Value | Purpose |
|---|---|---|
| `D.border.hairline` | `0.5` | seams, scale ticks, faint separations. |
| `D.border.thin` | `1` | standard panel edge. |
| `D.border.medium` | `1.5` | a pressed control's inner edge. |
| `D.border.bezel` | `2` | bezel ring. |
| `D.border.heavy` | `3` | focus ring, and the meter housing's outer wall. |

### Fixed metrics

Sizes that belong to the instrument's identity rather than to a single view.

| Token | Value | Purpose |
|---|---|---|
| `D.size.windowMin` | `900 × 600` | Minimum main-window content size, per the contracts. |
| `D.size.railWidth` | `172` | Left rail carrying HISTORY / DICTIONARY. Wide enough for a silkscreen label plus lamp. |
| `D.size.deckHeight` | `104` | The transport deck across the top of the main window. |
| `D.size.meterSize` | `232 × 84` | VU meter housing. |
| `D.size.lampDiameter` | `13` | Record lamp lens diameter. |
| `D.size.buttonHeight` | `30` | Standard transport button (RECORD / STOP). |
| `D.size.iconButton` | `22` | A small square utility button (copy, delete). |
| `D.size.rowHeight` | `26` | Table row height. Tight, like a printed log. |
| `D.size.troughHeight` | `6` | Height of the horizontal level trough used in compact places (HUD, menu bar popover). |
| `D.size.waveformHeight` | `44` | Waveform strip height. |
| `D.size.hudSize` | `360 × 96` | HUD panel size. |

### Opacity

Named so that "disabled" means one thing everywhere.

| Token | Value | Purpose |
|---|---|---|
| `D.opacity.disabled` | `0.38` |  |
| `D.opacity.ghost` | `0.55` |  |
| `D.opacity.halo` | `0.28` |  |
| `D.opacity.grain` | `1.0` |  |
| `D.opacity.scrim` | `0.72` |  |

---

## Shadows

`D.Shadow` is a value type (`color`, `radius`, `x`, `y`) applied either as a normal drop shadow
(`.shadow(D.shadow.raised)`) or as an **inner** shadow (`.innerShadow(shape, D.shadow.wellInner)`).

SwiftUI has no inner shadow, and without one a pressed control and a recessed well are impossible
to draw: an outer shadow makes every element look like it is floating above the panel. `D.InnerShadow`
implements it as a heavily blurred stroke masked to the shape's interior, which is exactly what an
inner shadow is. This is the single most load-bearing part of the system — it is what makes a held
button read as *held* rather than merely darker.

| Token | Colour | Radius | Offset | Purpose |
|---|---|---|---|---|
| `D.shadow.raised` | `shadowHard` | 2 | y +1 | Contact shadow under a raised panel. |
| `D.shadow.raisedAmbient` | `shadowSoft` | 7 | y +3 | Ambient shadow further out; pair with `raised`. |
| `D.shadow.cap` | `shadowHard` | 1.5 | y +1 | A button cap standing off its panel. |
| `D.shadow.hud` | `shadowSoft` | 18 | y +6 | The floating HUD over another application. |
| `D.shadow.needle` | `meterNeedleShadow` | 1.5 | x +1, y +1.5 | Needle shadow on the faceplate; sells the air gap under the glass. |
| `D.shadow.wellInner` | `shadowInner` | 3 | y +2 | **Inner.** Cast from the top edge into a recessed well. |
| `D.shadow.wellInnerLight` | `highlightInner` | 2 | y −1 | **Inner.** Light catch on the bottom inside edge of a hole — the other half of the illusion. |
| `D.shadow.pressedInner` | `shadowInner` | 4 | y +3 | **Inner.** Deeper rim for a control actively held down. |
| `D.shadow.capInnerLight` | `highlightInner` | 1.5 | y +1 | **Inner.** Light catch on the *top* inside edge of a cap standing out. Distinct from `wellInnerLight`, which lights a hole. |
| `D.shadow.engraved` | `highlightInner` | 0 | y +0.5 | Under silkscreen text, so the letters read as printed into the surface. |

---

## Motion

The house style is short and mechanical: a control reaches its new position in well under a fifth
of a second, because a switch has no easing. The only slow thing in the app is a needle falling
back, and that is slow for a physical reason.

### Durations

| Token | Value | Purpose |
|---|---|---|
| `D.motion.pressDuration` | `0.055` | Key-down feedback. Deliberately near-instant. |
| `D.motion.releaseDuration` | `0.11` | Key-up recovery — a hair slower than the press, like a spring returning. |
| `D.motion.panelDuration` | `0.22` | A panel or pane changing state. |
| `D.motion.paneDuration` | `0.26` | Swapping the whole content pane (HISTORY ⇄ DICTIONARY). |
| `D.motion.hudDuration` | `0.16` | The HUD arriving or leaving over another application. |

### Curves

| Curve token | Definition |
|---|---|
| `D.motion.press` | `timingCurve(0.2, 0.9, 0.3, 1.0)` over `pressDuration` — fast out of the gate, no overshoot |
| `D.motion.release` | `timingCurve(0.3, 0.0, 0.2, 1.0)` over `releaseDuration` |
| `D.motion.panel` | `easeInOut` over `panelDuration` |
| `D.motion.pane` | `easeInOut` over `paneDuration` |
| `D.motion.hud` | `easeOut` over `hudDuration` |
| `D.motion.readout` | `easeOut(0.12)` — surrounding fade only; digits themselves never animate |
| `D.motion.lampOn` | `easeOut(0.07)` |
| `D.motion.lampOff` | `easeIn(0.24)` |
| `D.motion.lampBreathe` | `easeInOut(0.85).repeatForever(autoreverses:)` |
| `D.motion.lampAlarm` | `easeInOut(0.28).repeatCount(6, autoreverses:)` |
| `D.motion.needle` | `easeOut(0.18)` — fallback only, see below |
| `D.motion.needleRest` | `easeInOut(0.42)` |

### The record lamp

`lampOn` is fast and `lampOff` is roughly 3.4× slower. That asymmetry is the whole reason the lamp
reads as a lamp rather than a coloured rectangle — a filament reaches brightness quickly and cools
slowly. Arming and model-download use `lampBreathe`, a slow breath and never a blink: a hard blink
in an always-visible window is an alarm, and arming is not an alarm. `lampAlarm` gives three
deliberate pulses and then stops — attention, then silence.

### VU needle ballistics

These are not taste values. Per `docs/RECON.md` §19, the audio tap on this machine delivers levels
at only **2.5–10 Hz**, so the needle is never animated from an audio callback. It is integrated on
a 60 Hz main-actor tick with a one-pole filter, which is what a real moving-coil movement does:

```swift
let k = D.motion.needleCoefficient(dt: dt, rising: target > needle)
needle += (target - needle) * k
```

| Constant | Value | Why |
|---|---|---|
| `needleTickHz` / `needleTickInterval` | 60 / 0.0167 s | The integration tick. |
| `needleAttackTau` | 0.065 s | Corresponds to the ANSI C16.5 VU standard's 300 ms integration time. A real VU meter is *slow*; a faster attack makes the needle twitch on plosives instead of tracking loudness. |
| `needleReleaseTau` | 0.150 s | ≈2.3× the attack, so the needle hangs and drifts back the way a weighted movement does. |
| `peakHoldDuration` | 1.5 s | How long the peak marker sits at its high-water mark. |
| `peakFallDBPerSecond` | 20 dB/s | Decay of the peak marker after the hold expires. |

`needleCoefficient(dt:rising:)` takes the *real* frame delta, not the nominal one, so a dropped
frame does not slow the movement down. `D.motion.needle` exists only for a jump that cannot be
integrated (resetting to the rest peg when capture stops).

---

## Meter scale

Calibration, not taste. Measured on this machine: a quiet room sits at −61…−48 dBFS and ordinary
speech at −18…−13 dBFS. A meter scaled 0…1 on linear amplitude would leave the needle on the
bottom peg for all normal use, which is why the scale is in decibels and starts at −54.

| Token | Value | Purpose |
|---|---|---|
| `D.meter.floorDBFS` | `-54` | Bottom of the sweep. Below this the needle rests on the low peg. |
| `D.meter.ceilingDBFS` | `0` | Top of the sweep. |
| `D.meter.referenceDBFS` | `-18` | The "0 VU" reference mark — where normal speech should sit. |
| `D.meter.overDBFS` | `-6` | Above this the scale is printed in red and the over-lamp arms. |
| `D.meter.hotDBFS` | `-12` | Green up to here, amber between here and `overDBFS`. |
| `D.meter.sweepDegrees` | `84` | Total needle sweep, in degrees, centred on vertical. |
| `D.meter.restAngleDegrees` | `-42` | Angle of the needle at `floorDBFS` (negative = anticlockwise from vertical). |

| Helper | Returns |
|---|---|
| `D.meter.fraction(dbfs:)` | dBFS normalised onto `0...1` across the printed scale, clamped. |
| `D.meter.angle(fraction:)` | Needle angle in degrees for a normalised position. |
| `D.meter.zoneColor(dbfs:)` | `meterGreen` / `meterAmber` / `meterRed` for the trough and the over-lamp. |

---

## Surface recipes

Materials are defined once, here, and never assembled in a view. They are computed properties
rather than stored constants so the token namespace holds no global state; a `LinearGradient` of
dynamic `Color`s costs almost nothing to build and resolves in whichever appearance it is drawn in.

| Recipe | Kind | What it is |
|---|---|---|
| `D.surface.brushedAluminium` | `LinearGradient` | Base shading of a milled metal face: lit from above, in shade below. |
| `D.surface.brushedGrain` | `LinearGradient` | The scratch pattern. **Overlay on `brushedAluminium`; never use alone.** |
| `D.surface.mattePlastic` | `LinearGradient` | Matte injection-moulded plastic — almost flat, just enough falloff to read as a solid object. |
| `D.surface.deckPaint` | `LinearGradient` | The painted chassis the whole window sits on. |
| `D.surface.raisedPanelFill` | `LinearGradient` | A panel standing proud of the deck. |
| `D.surface.wellFill` | `LinearGradient` | Inside a recessed well; darkest at the top where the overhang shades it. |
| `D.surface.meterFace` | `LinearGradient` | The cream VU faceplate, lit from the bottom bezel the way these meters always were. |
| `D.surface.raisedEdge` | `LinearGradient` | The 1pt edge that gives a panel thickness: light on top, dark underneath. |
| `D.surface.recessedEdge` | `LinearGradient` | The inverse, for an opening: dark on top, light underneath. |
| `D.surface.bezelRing` | `LinearGradient` | A machined ring, lit from the top-left. |
| `D.surface.lampLens(lit:)` | `RadialGradient` | A domed red lens over a point source; bright spot above centre, rim dark even when lit. |
| `D.surface.buttonCap(pressed:)` | `LinearGradient` | A cap. Held, it is darker at the top — shaded by its own overhang. |
| `D.surface.scrim` | `Color` | Dimming layer behind the HUD or a sheet. |

**On the brushed grain.** Real brushed aluminium is anisotropic: fine parallel scratches from the
abrasive, running along the long axis. A noise image would mean shipping and signing an asset and
would tile visibly. Instead the striations are 170 irregular gradient stops along the *cross*-grain
axis, so the streaks run *with* the grain, generated once from a fixed seed — a chassis does not get
re-brushed between launches. Amplitude is ~3% so it reads as a finish, not as corduroy.

---

## Physical treatments

Views must never hand-roll these. Each is a `View` extension over the tokens above.

| Modifier | What it draws |
|---|---|
| `.raisedPanel(radius:)` | Matte fill, lit top edge, contact + ambient shadow. Default for any grouped block of controls. |
| `.brushedFace(radius:)` | Same geometry as `raisedPanel` but milled metal — the transport deck and the meter housing. |
| `.recessedWell(radius:)` | Dark fill, inner shadow from the top edge, light catch on the bottom inside edge, recessed edge stroke. Backing for lists, text fields, the waveform. |
| `.pressedCap(_:radius:)` | A control being held. Swaps the shading, swaps the inner shadow for a deeper one, and sinks the content 1pt, so the cap genuinely moves rather than merely darkening. Animates itself with `press` / `release`. |
| `.engravedLabel()` | `silkscreen` type in `textSilkscreen` with the `engraved` shadow — printed into the surface. |
| `.engravedHeading()` | The same at `silkscreenHeading` weight. |
| `.bezelRing(radius:width:)` | A machined ring plus a hairline inner shade. |
| `.bezelRingCircular(width:)` | The circular version, for the record lamp. |
| `.focusRing(_:radius:)` | Keyboard focus, in the selection family so focus introduces no new hue. |
| `.innerShadow(_:_:)` | Any `D.Shadow` drawn inside any `Shape`. |
| `.shadow(_:)` | Any `D.Shadow` as an ordinary drop shadow. |
| `.typeStyle(_:)` | A complete `D.TypeStyle`. Never set `.font` and `.tracking` separately. |
| `D.Seam(.horizontal / .vertical)` | A joint between two panels: one dark hairline, one light hairline. A single grey line is a divider; a pair is a seam between two pieces of metal. |

---

## Concurrency

The file is entirely immutable value data on nonisolated types, so it is usable from any actor
under `.swiftLanguageMode(.v6)`. Colours, fonts, type styles, shadows, and animations are
`static let` on `Sendable` value types; gradients are `static var` computed properties, which
sidesteps any question of global-state isolation. `D.TypeStyle` and `D.Shadow` are
`Sendable, Hashable`. Nothing here needs `@MainActor`, and nothing needs `nonisolated(unsafe)`.

## Verification

`swift build` in the package is clean with zero warnings. The tokens were additionally rendered to
PNG in both appearances via `ImageRenderer` from a throwaway probe package, and the palette's
contrast ratios were computed rather than eyeballed — the light-appearance greys, the alert amber,
and the meter reds were all adjusted as a result.

