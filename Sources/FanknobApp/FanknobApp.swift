// FanknobApp.swift — SwiftUI menu-bar app entry point.

import SwiftUI
import AppKit
import FanknobCore

/// The menu-bar label rendered as a single fixed-size template image.
///
/// SwiftUI text in a MenuBarExtra label gets re-typeset by the status-item
/// pipeline: monospaced fonts and fixed frames are both ignored (measured —
/// the item width tracked the digits shown, 62↔64 pt). An NSImage with a
/// constant canvas is the only reliable way to pin the width.
func statusImage(temp: Int?, manual: Bool) -> NSImage {
    // 45 pt: snug gap for the normal "NN°" case, still fits a 3-digit "105°"
    // (which then just closes the gap) without ever changing the item width.
    let size = NSSize(width: 45, height: 18)
    let image = NSImage(size: size, flipped: false) { rect in
        var config = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if manual {
            // Accent-colored fan while the user is overriding the firmware.
            config = config.applying(.init(paletteColors: [.controlAccentColor]))
        }
        if let symbol = NSImage(systemSymbolName: "fanblades", accessibilityDescription: "fanknob")?
            .withSymbolConfiguration(config) {
            let s = symbol.size
            symbol.draw(in: NSRect(x: 0, y: (rect.height - s.height) / 2,
                                   width: s.width, height: s.height))
        }
        let text = temp.map { "\($0)°" } ?? "—"
        let str = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            // Template mode only uses alpha; in manual (non-template) mode the
            // drawing handler runs at draw time, so labelColor still resolves
            // against the current menu-bar appearance.
            .foregroundColor: manual ? NSColor.labelColor : NSColor.black,
        ])
        let ts = str.size()
        str.draw(at: NSPoint(x: rect.maxX - ts.width, y: (rect.height - ts.height) / 2))
        return true
    }
    // Template = system-tinted monochrome. Must be off in manual so the
    // accent color survives.
    image.isTemplate = !manual
    return image
}

@main
struct FanknobApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = FanModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            Image(nsImage: statusImage(temp: model.menuTemp, manual: model.overriding))
        }
        .menuBarExtraStyle(.window)   // rich popover content (sliders, gauges)
    }
}

// Hide the dock icon at runtime so this behaves as a menu-bar agent without
// needing an Info.plist LSUIElement key (keeps the no-Xcode SwiftPM build).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
