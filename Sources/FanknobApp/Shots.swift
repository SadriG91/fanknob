// Shots.swift — renders the documentation screenshots from the real views.
//
// The images in README.md and on the landing page used to be hand-captured at
// 1x, which meant they were a blurry upscale everywhere they were displayed.
// Rendering them instead makes them reproducible, arbitrarily sharp, and
// regenerable whenever the UI changes:
//
//     make shots
//
// Debug-only: this never reaches a shipped build. It also runs before the app
// launches, so nothing here touches the SMC — every value is a fixture.

#if DEBUG

import SwiftUI
import AppKit
import AVFoundation
import FanknobCore

enum Shots {
    /// Rendered through an offscreen window rather than SwiftUI's
    /// ImageRenderer: the popover's pickers, slider and gear menu are all
    /// AppKit-backed, and ImageRenderer draws those as yellow "unsupported"
    /// placeholders. Hosting the view gives them a real backing store, so the
    /// snapshot is the actual control set.

    /// Pixels per point. Set explicitly rather than inherited from a screen —
    /// an offscreen window reports 1x, and the output should not depend on
    /// which Mac ran `make shots`. The images are displayed at their natural
    /// point size, so 2x is exactly Retina.
    static let scale: CGFloat = 2

    /// Popover material, approximated opaquely. The real thing is translucent
    /// over whatever is behind it, which is exactly what made the old captures
    /// look muddy — a flat surface reproduces better.
    static let surface: [ColorScheme: Color] = [
        .light: Color(red: 0.96, green: 0.96, blue: 0.965),
        .dark:  Color(red: 0.13, green: 0.13, blue: 0.14),
    ]

    @MainActor
    static func run(into directory: String) {
        // ImageRenderer wants AppKit up, but we never show a window.
        NSApplication.shared.setActivationPolicy(.prohibited)

        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var written = 0
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .light ? "-light" : "-dark"
            let shots: [(String, AnyView)] = [
                ("popover-auto",  AnyView(PopoverView(model: .automatic))),
                ("popover-curve", AnyView(PopoverView(model: .followingCurve))),
                ("menubar",       AnyView(MenuBarStrip())),
            ]
            for (name, view) in shots {
                let url = dir.appendingPathComponent(name + suffix + ".png")
                if render(view, scheme: scheme, to: url) {
                    written += 1
                } else {
                    FileHandle.standardError.write(
                        Data("shots: failed to render \(url.lastPathComponent)\n".utf8))
                }
            }
            if Reel.record(scheme: scheme, into: dir) { written += 2 }
        }
        print("shots: wrote \(written) files to \(dir.path)")
    }

    // MARK: Rendering

    @MainActor
    private static func render(_ view: AnyView, scheme: ColorScheme, to url: URL) -> Bool {
        // The padding leaves room for the shadow to fall inside the bitmap;
        // that margin stays transparent, so the page background shows through
        // and the image needs no border of its own.
        let content = view
            .background(surface[scheme]!)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(scheme == .light ? 0.18 : 0.55),
                    radius: 12, y: 5)
            .padding(26)

        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        // AppKit controls only draw once they belong to a window.
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        // The speed slider eases its thumb toward the target over ~0.4 s on a
        // frame timer instead of animating implicitly, so give the run loop
        // long enough to settle before snapshotting — otherwise the thumb is
        // caught at zero while the label already reads the real percentage.
        let deadline = Date().addingTimeInterval(1.2)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        window.displayIfNeeded()

        // A rep whose pixel count exceeds its point size makes AppKit redraw at
        // that scale rather than upscaling the 1x result.
        let size = hosting.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        rep.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: url); return true } catch { return false }
    }
}

// MARK: - The hero reel
//
// A scripted tour of the popover, captured frame by frame from the real view
// and encoded to H.264. Every transition you see is the app's own: the speed
// slider's hand-rolled easing, the badges, the spinning fan icon. Nothing here
// re-implements the UI — the script only moves the model, exactly as a poll
// landing after a write would, and the view reacts on its own.
//
// No rounded corners or shadow are baked in: the page adds those in CSS, which
// keeps the video rectangular and opaque (and so a few hundred KB rather than
// the several MB an alpha-preserving animated PNG would cost).

private enum Reel {
    static let fps = 30
    static let scale: CGFloat = 2

    /// One step of the tour. `apply` receives progress through the beat, 0...1,
    /// so a drag can be interpolated across its frames.
    struct Beat {
        let seconds: Double
        let apply: (FanModel, Double) -> Void
    }

    static let script: [Beat] = [
        // Idling under firmware control.
        Beat(seconds: 1.6) { model, _ in
            model.mode = .auto
            model.hardwareKnob = 18
            model.fans = fans(atPercent: 18, managed: false)
        },
        // Take over. Manual reads the setpoint directly, so the slider starts
        // where automatic left it and then follows the drag up.
        Beat(seconds: 1.1) { model, t in
            model.mode = .manual
            model.knob = 18 + (65 - 18) * ease(t)
            model.fans = fans(atPercent: model.knob, managed: true)
        },
        Beat(seconds: 0.9) { _, _ in },
        // …and back down.
        Beat(seconds: 1.0) { model, t in
            model.knob = 65 - (65 - 35) * ease(t)
            model.fans = fans(atPercent: model.knob, managed: true)
        },
        Beat(seconds: 0.9) { _, _ in },
        // Hand it to a curve. The slider eases 35 -> 52 by itself.
        Beat(seconds: 2.4) { model, t in
            model.mode = .curve
            model.preset = .balanced
            model.curveKnob = 52
            if t * 2.4 > pollLag { model.fans = fans(atPercent: 52, managed: true) }
        },
        // Give it all back.
        Beat(seconds: 2.2) { model, t in
            model.mode = .auto
            model.curveKnob = nil
            model.hardwareKnob = 18
            if t * 2.2 > pollLag { model.fans = fans(atPercent: 18, managed: false) }
        },
    ]

    /// The real app writes immediately but only refreshes the fan rows on its
    /// next poll, so the rpm figures trail a mode change slightly. Worth
    /// keeping — it's honest — but as a fixed short delay rather than a
    /// fraction of the beat, which left the numbers disagreeing for over half
    /// a second on the longer ones.
    private static let pollLag = 0.35

    /// Smoothstep, so the simulated drags start and stop like a hand does.
    private static func ease(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    private static func fans(atPercent pct: Double, managed: Bool) -> [Fan] {
        let rpm = 2317 + (6800 - 2317) * pct / 100
        return [
            Fan(index: 0, actual: rpm, min: 2317, max: 6800, target: rpm, managed: managed),
            Fan(index: 1, actual: rpm - 11, min: 2317, max: 6800, target: rpm, managed: managed),
        ]
    }

    // MARK: Recording

    @MainActor
    static func record(scheme: ColorScheme, into dir: URL) -> Bool {
        let suffix = scheme == .light ? "-light" : "-dark"
        let videoURL = dir.appendingPathComponent("reel\(suffix).mp4")
        let posterURL = dir.appendingPathComponent("reel\(suffix).png")

        let model = FanModel(fixture: ())
        model.popoverShown = true
        model.cpu = 76
        model.gpu = 66
        model.menuTemp = 76
        script[0].apply(model, 0)

        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: AnyView(
            PopoverView(model: model).background(Shots.surface[scheme]!)))
        hosting.appearance = appearance
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let pixels = CGSize(width: (hosting.bounds.width * scale).rounded(),
                            height: (hosting.bounds.height * scale).rounded())
        guard let writer = Writer(url: videoURL, size: pixels, fps: fps) else { return false }

        // One clock for everything. The view's animations advance in real time
        // whatever we do, so the script is driven by elapsed time too and each
        // frame is stamped with the moment it was actually taken. Playback is
        // then exactly what happened, at whatever frame rate capture managed —
        // rather than smooth-but-too-fast, which is what stamping frames at a
        // nominal 30fps produced while each one took ~85 ms to grab.
        let step = 1.0 / Double(fps)
        let total = script.reduce(0) { $0 + $1.seconds }
        let bounds = hosting.bounds

        var frames = 0
        var lastStamp = -1.0
        let start = Date()

        while true {
            let now = Date().timeIntervalSince(start)
            if now >= total { break }
            apply(at: now, to: model)

            // Let SwiftUI pick up the change and move its own animations on.
            let target = Swift.max(now + 0.004, lastStamp + step)
            while Date().timeIntervalSince(start) < target {
                RunLoop.current.run(mode: .default,
                                    before: start.addingTimeInterval(target))
            }

            let stamp = Date().timeIntervalSince(start)
            writer.appendFrame(at: stamp, scale: scale) { context in
                hosting.displayIgnoringOpacity(bounds, in: context)
            }
            lastStamp = stamp
            frames += 1
        }

        guard writer.finish() else { return false }
        renderPoster(hosting, pixels: pixels, to: posterURL)
        print(String(format: "shots: reel%@ %.1fs, %d frames (%.0f fps)",
                     suffix, total, frames, Double(frames) / total))
        return true
    }

    /// Position in the script at `seconds`, applied to the model.
    private static func apply(at seconds: Double, to model: FanModel) {
        var elapsed = 0.0
        for beat in script {
            if seconds < elapsed + beat.seconds {
                beat.apply(model, (seconds - elapsed) / beat.seconds)
                return
            }
            elapsed += beat.seconds
        }
        script.last?.apply(model, 1)
    }

    /// Still frame of wherever the reel ended up, used as the video's poster
    /// and shown instead of it when the reader prefers reduced motion.
    @MainActor
    private static func renderPoster(_ view: NSView, pixels: CGSize, to url: URL) {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }

    // MARK: H.264 writer

    private final class Writer {
        private let writer: AVAssetWriter
        private let input: AVAssetWriterInput
        private let adaptor: AVAssetWriterInputPixelBufferAdaptor
        private let fps: Int

        init?(url: URL, size: CGSize, fps: Int) {
            try? FileManager.default.removeItem(at: url)
            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
            self.writer = writer
            self.fps = fps

            input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 1_600_000,
                    AVVideoMaxKeyFrameIntervalKey: fps * 2,
                ],
            ])
            input.expectsMediaDataInRealTime = false
            adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(size.width),
                    kCVPixelBufferHeightKey as String: Int(size.height),
                ])
            guard writer.canAdd(input) else { return nil }
            writer.add(input)
            guard writer.startWriting() else { return nil }
            writer.startSession(atSourceTime: .zero)
        }

        /// Vends a pixel buffer and lets the caller draw straight into it. The
        /// view used to be captured into a bitmap rep, turned into a CGImage
        /// and then blitted here — three copies of every frame, which cost
        /// more than the drawing. Rendering directly into the encoder's buffer
        /// roughly doubled the achievable frame rate.
        func appendFrame(at seconds: Double, scale: CGFloat,
                         draw: (NSGraphicsContext) -> Void) {
            while !input.isReadyForMoreMediaData { usleep(500) }
            guard let pool = adaptor.pixelBufferPool else { return }
            var maybeBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer) == kCVReturnSuccess,
                  let buffer = maybeBuffer else { return }

            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer),
                width: CVPixelBufferGetWidth(buffer),
                height: CVPixelBufferGetHeight(buffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                          | CGBitmapInfo.byteOrder32Little.rawValue) {
                context.scaleBy(x: scale, y: scale)
                let previous = NSGraphicsContext.current
                let graphics = NSGraphicsContext(cgContext: context, flipped: false)
                NSGraphicsContext.current = graphics
                draw(graphics)
                NSGraphicsContext.current = previous
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])

            adaptor.append(buffer, withPresentationTime:
                CMTime(seconds: seconds, preferredTimescale: 600))
        }

        func finish() -> Bool {
            input.markAsFinished()
            var done = false
            writer.finishWriting { done = true }
            while !done {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            return writer.status == .completed
        }
    }
}

// MARK: - Fixtures
//
// Values are carried over from the captures these replaced, so the page's copy
// (which quotes fan 0 at 3,132 rpm) keeps agreeing with the pictures.

private extension FanModel {
    static var automatic: FanModel {
        let model = FanModel(fixture: ())
        model.popoverShown = true   // the speed slider's easing is paused otherwise
        model.askedAboutLogin = true   // keep the first-run offer out of the docs
        model.fans = [
            Fan(index: 0, actual: 3132, min: 2317, max: 6800, target: 3132, managed: false),
            Fan(index: 1, actual: 3383, min: 2317, max: 6800, target: 3383, managed: false),
        ]
        model.cpu = 76
        model.gpu = 66
        model.menuTemp = 76
        model.mode = .auto
        model.hardwareKnob = 18
        return model
    }

    static var followingCurve: FanModel {
        let model = FanModel(fixture: ())
        model.popoverShown = true   // the speed slider's easing is paused otherwise
        model.askedAboutLogin = true   // keep the first-run offer out of the docs
        model.fans = [
            Fan(index: 0, actual: 4697, min: 2317, max: 6800, target: 4697, managed: true),
            Fan(index: 1, actual: 4686, min: 2317, max: 6800, target: 4686, managed: true),
        ]
        model.cpu = 76
        model.gpu = 67
        model.menuTemp = 76
        model.mode = .curve
        model.preset = .balanced
        model.curveKnob = 52
        model.hardwareKnob = 52
        return model
    }
}

// MARK: - Menu bar

/// A mock of the menu bar showing the fanknob item. Mirrors what
/// `statusImage(temp:manual:)` draws, rebuilt in SwiftUI so it renders at any
/// size and follows the rendered colour scheme (the AppKit version resolves
/// its colours against the live system appearance, which a render can't set).
private struct MenuBarStrip: View {
    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 5) {
                Image(systemName: "fanblades")
                    .foregroundStyle(Color.accentColor)
                Text("82°")
                    .font(.system(size: 14).monospacedDigit())
            }
            Text("100%")
                .foregroundStyle(.secondary)
            Image(systemName: "wifi")
                .foregroundStyle(.secondary)
            Text("Wed 21:04")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 14))
        .padding(.horizontal, 18)
        .padding(.vertical, 7)
    }
}

#endif
