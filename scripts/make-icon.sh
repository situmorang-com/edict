#!/bin/bash
# Generates Resources/AppIcon.icns from scratch, no design assets.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/Resources/AppIcon.icns"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/MakeIcon.swift" <<'SWIFT'
import AppKit
let S: CGFloat = 1024
let out = CommandLine.arguments[1]
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let inset = S * 0.085          // macOS icons want ~8-10% transparent margin
let rect = CGRect(x: inset, y: inset, width: S - 2*inset, height: S - 2*inset)
let r = rect.width * 0.235     // squircle-ish corner radius
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil))
ctx.clip()
let g = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.36, green: 0.30, blue: 0.90, alpha: 1),
    CGColor(red: 0.10, green: 0.55, blue: 0.95, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY),
                       end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
let hs: [CGFloat] = [0.18, 0.34, 0.55, 0.80, 0.62, 0.95, 0.48, 0.30, 0.16]
let bw = rect.width * 0.052, gap = rect.width * 0.036
var x = rect.midX - (CGFloat(hs.count)*bw + CGFloat(hs.count-1)*gap)/2
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
for h in hs {
    let bh = rect.height * 0.62 * h
    let bar = CGRect(x: x, y: rect.midY - bh/2, width: bw, height: bh)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: bw/2, cornerHeight: bw/2, transform: nil))
    ctx.fillPath()
    x += bw + gap
}
ctx.restoreGState()
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
rep.size = NSSize(width: S, height: S)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
SWIFT

swiftc -O "$WORK/MakeIcon.swift" -o "$WORK/makeicon"
"$WORK/makeicon" "$WORK/icon.png"

SET="$WORK/AppIcon.iconset"; mkdir -p "$SET"
# These ten are the conventional full set, NOT a requirement — the comment that used to sit here
# claimed iconutil "requires EXACTLY these ten names, or it dies", and that is false. Measured
# against iconutil on macOS 26, from this script's own 1024 master:
#   * Any subset converts. A directory holding only icon_512x512@2x.png produced a valid
#     621,571-byte icns; a six-name set produced 772,115 bytes; a five-name @1x-only set, 181,996.
#   * The numbers in the filename are ignored. iconutil matches the shape icon_<W>x<H>[@2x].png,
#     then picks the icns slot from the file's REAL pixel dimensions and the presence of @2x —
#     a 16 px image named icon_512x512.png landed in ic04 (16x16), a 512 px one named
#     icon_16x16.png landed in ic09. So the numbers below document intent to a reader; the sips
#     line above them is what actually decides where each rep goes.
#   * Anything iconutil cannot place is dropped in silence — an unrecognised name (banana.png),
#     or a recognised one whose pixels have no home for its family (@1x takes 16/32/128/256/512 px
#     and @2x takes 32/64/256/512/1024, so a 64 px file with no @2x fits nowhere). Adding either
#     to the ten produced a byte-identical icns.
#   * "Failed to generate ICNS." therefore means NOTHING in the directory landed in a slot. That
#     is the whole of the RECON incident: a quoting bug left one file literally named ".png", so
#     the set was effectively empty. The ten names were never the point — an empty directory and a
#     lone unplaceable file fail identically.
#
# The ten stay anyway, and the reason is not the false rule. Four of them are pure duplication
# when every rep is scaled from one square master — ic13 comes out byte-identical to ic08 (34,082
# bytes, same md5) and ic14 to ic09 (133,745) — so ~168 KB of the 976 KB icns is the same two PNGs
# stored twice. Cutting them changes which rep the Dock and the Finder pick at each size, and
# CONTRACTS amendment 40 forbids an agent screenshotting the running UI, so nobody but the user
# could confirm the result. 168 KB of one developer's disk does not buy a rendering regression
# that only the user can see. Note also that the obvious cut is wrong on its own terms: dropping
# the "redundant" names takes icon_32x32@2x with them, and its 64 px rep duplicates nothing — it
# is exactly what a 32 pt row needs on a Retina display.
while read -r name px; do
  sips -z "$px" "$px" "$WORK/icon.png" --out "$SET/$name.png" >/dev/null
done <<'SIZES'
icon_16x16 16
icon_16x16@2x 32
icon_32x32 32
icon_32x32@2x 64
icon_128x128 128
icon_128x128@2x 256
icon_256x256 256
icon_256x256@2x 512
icon_512x512 512
icon_512x512@2x 1024
SIZES
iconutil -c icns "$SET" -o "$OUT"
echo "icon: $OUT"