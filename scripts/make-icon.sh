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
# iconutil requires EXACTLY these ten names, or it dies with "Failed to generate ICNS."
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