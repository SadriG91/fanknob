// FanknobApp.swift — SwiftUI menu-bar app entry point.

import SwiftUI
import AppKit
import FanknobCore

@main
struct FanknobApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = FanModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            // Icon + live temperature in the menu bar. An explicit monospaced
            // font keeps the width fixed so the item doesn't jitter as the
            // number changes (the .monospacedDigit() modifier isn't honored in
            // the status-item rendering context).
            Image(systemName: "fanblades")
            Text(model.menuLabel)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
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
