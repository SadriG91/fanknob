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
func statusImage(temp: Int?) -> NSImage {
    // 45 pt: snug gap for the normal "NN°" case, still fits a 3-digit "105°"
    // (which then just closes the gap) without ever changing the item width.
    let size = NSSize(width: 45, height: 18)
    let image = NSImage(size: size, flipped: false) { rect in
        if let symbol = NSImage(systemSymbolName: "fanblades", accessibilityDescription: "fanknob")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) {
            let s = symbol.size
            symbol.draw(in: NSRect(x: 0, y: (rect.height - s.height) / 2,
                                   width: s.width, height: s.height))
        }
        let text = temp.map { "\($0)°" } ?? "—"
        let str = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.black,   // template image: only alpha matters
        ])
        let ts = str.size()
        str.draw(at: NSPoint(x: rect.maxX - ts.width, y: (rect.height - ts.height) / 2))
        return true
    }
    image.isTemplate = true   // adapts to menu bar light/dark appearance
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
            Image(nsImage: statusImage(temp: model.menuTemp))
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
