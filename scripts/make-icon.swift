// make-icon.swift — turn the raw logo PNG into macOS app-icon artwork.
//
// The source logo has its dark rounded square baked onto an opaque white
// background, with a "FANKNOB" wordmark inside the square. This tool:
//   1. finds the square's bounding box by scanning for dark pixels,
//   2. strips the wordmark (icons shouldn't contain text — HIG — and at small
//      sizes it's just noise): white "FAN" rows are located INSIDE the square
//      only (the white canvas around the square would otherwise match), then
//      the region is refilled by interpolating the background horizontally per
//      row, which follows the vertical gradient seamlessly,
//   3. crops the square, applies a rounded-rect alpha mask so the white
//      corners become transparent, and composites it centered on a transparent
//      1024x1024 canvas at ~82% (Apple's standard icon-grid proportion).
//
// Usage: swiftc -O scripts/make-icon.swift -o /tmp/make-icon
//        /tmp/make-icon assets/fanknob_logo.png assets/AppIcon-1024.png

import AppKit

guard CommandLine.arguments.count >= 3 else {
    print("usage: make-icon <input.png> <output.png>"); exit(1)
}
let inPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]

guard let image = NSImage(contentsOfFile: inPath),
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    print("could not read \(inPath)"); exit(1)
}

let w = rep.pixelsWide, h = rep.pixelsHigh

func brightness(_ x: Int, _ y: Int) -> CGFloat {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return 1 }
    return (c.redComponent + c.greenComponent + c.blueComponent) / 3
}

// Detection mode: if the source has real transparency (corner alpha ≈ 0), the
// tile is already cleanly matted — find it by alpha and use its own corners.
// Otherwise (artwork baked onto opaque white) fall back to the dark-pixel scan
// plus wordmark strip plus rounded mask.
let cornerAlpha = rep.colorAt(x: 3, y: 3)?.alphaComponent ?? 1
let alphaMatted = cornerAlpha < 0.1
print(alphaMatted ? "mode: alpha-matted source" : "mode: opaque white background")

// 1. Bounding box of the artwork.
var minX = w, maxX = 0, minY = h, maxY = 0
for y in stride(from: 0, to: h, by: 2) {
    for x in stride(from: 0, to: w, by: 2) {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        let hit: Bool
        if alphaMatted {
            hit = c.alphaComponent > 0.5
        } else {
            let b = (c.redComponent + c.greenComponent + c.blueComponent) / 3
            hit = b < 0.6 && c.alphaComponent > 0.5
        }
        if hit {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
guard maxX > minX, maxY > minY else { print("no artwork found"); exit(1) }
print("artwork bbox: x \(minX)-\(maxX), y \(minY)-\(maxY)")

// 2. Strip the wordmark — searching only well INSIDE the square so the white
// canvas around it can't match.
func stripWordmark() {
    let inset = (maxX - minX) / 10
    let sx0 = minX + inset, sx1 = maxX - inset
    let sy0 = minY + (maxY - minY) * 2 / 3, sy1 = maxY - inset

    var tMinY = h, tMaxY = 0
    for y in sy0...sy1 where (sx0...sx1).contains(where: { brightness($0, y) > 0.85 }) {
        tMinY = min(tMinY, y); tMaxY = max(tMaxY, y)
    }
    guard tMaxY > tMinY else { print("no wordmark found; skipping strip"); return }

    var tMinX = w, tMaxX = 0
    for y in tMinY...tMaxY {
        for x in sx0...sx1 where brightness(x, y) > 0.30 {
            tMinX = min(tMinX, x); tMaxX = max(tMaxX, x)
        }
    }
    guard tMaxX > tMinX else { return }

    let pad = 10
    let x0 = max(minX + 2, tMinX - pad), x1 = min(maxX - 2, tMaxX + pad)
    let y0 = max(minY + 2, tMinY - pad), y1 = min(maxY - 2, tMaxY + pad)
    print("stripping wordmark: x \(x0)-\(x1), y \(y0)-\(y1)")

    // Bilinear fill: blend the horizontal and vertical edge gradients so the
    // background's vignette continues through the patch without a visible seam.
    func comps(_ x: Int, _ y: Int) -> (CGFloat, CGFloat, CGFloat) {
        let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
        return (c?.redComponent ?? 0, c?.greenComponent ?? 0, c?.blueComponent ?? 0)
    }
    for y in y0...y1 {
        let l = comps(x0 - 1, y), r = comps(x1 + 1, y)
        let v = CGFloat(y - y0) / CGFloat(y1 - y0)
        for x in x0...x1 {
            let t = CGFloat(x - x0) / CGFloat(x1 - x0)
            let top = comps(x, y0 - 1), bot = comps(x, y1 + 1)
            let hr = l.0 * (1 - t) + r.0 * t, hg = l.1 * (1 - t) + r.1 * t, hb = l.2 * (1 - t) + r.2 * t
            let vr = top.0 * (1 - v) + bot.0 * v, vg = top.1 * (1 - v) + bot.1 * v, vb = top.2 * (1 - v) + bot.2 * v
            rep.setColor(NSColor(deviceRed: (hr + vr) / 2, green: (hg + vg) / 2,
                                 blue: (hb + vb) / 2, alpha: 1), atX: x, y: y)
        }
    }
}
if !alphaMatted { stripWordmark() }   // alpha-matted sources carry no wordmark

// Draw from the edited bitmap, not the original file.
let editedImage = NSImage(size: NSSize(width: w, height: h))
editedImage.addRepresentation(rep)

// NSBitmapImageRep y is top-down; drawing coordinates are bottom-up.
let cropRect = NSRect(x: CGFloat(minX), y: CGFloat(h - 1 - maxY),
                      width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))

// 3. Rounded-mask the crop and center it on a transparent 1024 canvas,
// preserving the crop's aspect ratio (soft shadows can make it non-square).
let canvas = 1024
let box = NSRect(x: CGFloat(canvas) * 0.09, y: CGFloat(canvas) * 0.09,
                 width: CGFloat(canvas) * 0.82, height: CGFloat(canvas) * 0.82)
let fit = min(box.width / cropRect.width, box.height / cropRect.height)
let target = NSRect(x: box.midX - cropRect.width * fit / 2,
                    y: box.midY - cropRect.height * fit / 2,
                    width: cropRect.width * fit,
                    height: cropRect.height * fit)
// Mask radius fractionally above the artwork's own corner radius so no white
// corner slivers survive.
let cornerRadius = target.width * 0.21

let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
if !alphaMatted {
    // Only opaque-white sources need their corners cut; alpha-matted tiles
    // bring their own transparency, and clipping could shave their corners.
    NSBezierPath(roundedRect: target, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
}
editedImage.draw(in: target, from: cropRect, operation: .sourceOver, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

guard let png = out.representation(using: .png, properties: [:]) else {
    print("png encode failed"); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(canvas)x\(canvas))")
