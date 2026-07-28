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
        }
        print("shots: wrote \(written) images to \(dir.path)")
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

// MARK: - Fixtures
//
// Values are carried over from the captures these replaced, so the page's copy
// (which quotes fan 0 at 3,132 rpm) keeps agreeing with the pictures.

private extension FanModel {
    static var automatic: FanModel {
        let model = FanModel(fixture: ())
        model.popoverShown = true   // the speed slider's easing is paused otherwise
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
