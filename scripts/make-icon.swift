// make-icon.swift — turn the raw logo PNG into macOS app-icon artwork.
//
// The source logo has its dark rounded square baked onto an opaque white
// background. This tool: (1) finds the square's bounding box by scanning for
// dark pixels, (2) crops it and applies a rounded-rect alpha mask so the white
// corners become transparent, (3) composites it centered on a transparent
// 1024x1024 canvas at ~82% (Apple's standard icon-grid proportion, so it sits
// at the same visual size as other app icons).
//
// Usage: swiftc -O scripts/make-icon.swift -o /tmp/make-icon
//        /tmp/make-icon fanknob_logo.png assets/AppIcon-1024.png

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

// 1. Bounding box of the dark artwork (the logo square). The white background
// and its soft grey shadow stay above the brightness threshold.
var minX = w, maxX = 0, minY = h, maxY = 0
for y in stride(from: 0, to: h, by: 2) {
    for x in stride(from: 0, to: w, by: 2) {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        let brightness = (c.redComponent + c.greenComponent + c.blueComponent) / 3
        if brightness < 0.6 && c.alphaComponent > 0.5 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
}
guard maxX > minX, maxY > minY else { print("no artwork found"); exit(1) }
let side = max(maxX - minX, maxY - minY)
print("artwork bbox: x \(minX)-\(maxX), y \(minY)-\(maxY) (side \(side))")

// NSBitmapImageRep y is top-down; drawing coordinates are bottom-up.
let cropRect = NSRect(x: CGFloat(minX), y: CGFloat(h - 1 - maxY),
                      width: CGFloat(maxX - minX), height: CGFloat(maxY - minY))

// 2+3. Rounded-mask the crop and center it on a transparent 1024 canvas.
let canvas = 1024
let target = NSRect(x: CGFloat(canvas) * 0.09, y: CGFloat(canvas) * 0.09,
                    width: CGFloat(canvas) * 0.82, height: CGFloat(canvas) * 0.82)
// Mask radius fractionally above the artwork's own corner radius so no white
// corner slivers survive.
let cornerRadius = target.width * 0.21

let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                           isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
NSBezierPath(roundedRect: target, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
image.draw(in: target, from: cropRect, operation: .copy, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

guard let png = out.representation(using: .png, properties: [:]) else {
    print("png encode failed"); exit(1)
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath) (\(canvas)x\(canvas))")
