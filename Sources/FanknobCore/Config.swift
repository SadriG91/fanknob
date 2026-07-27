// Config.swift — persisted daemon state and the wire format for querying it.
//
// The daemon owns this file; it reloads and re-applies on boot so a curve or a
// fixed speed survives restarts. Only root can write it, and every value is
// re-validated on load, so it isn't a privilege-escalation surface.

import Foundation

/// One fan's manual setpoint.
public struct FanKnob: Codable, Equatable {
    public let index: Int
    public let pct: Double
    public init(index: Int, pct: Double) {
        self.index = index
        self.pct = pct.clamped(0, 100)
    }
}

public enum ControlMode: Codable, Equatable {
    /// Firmware controls the fans.
    case auto
    /// Fixed setpoints (one entry per controlled fan).
    case manual([FanKnob])
    /// Temperature-driven. `preset` is kept so the UI can name it.
    case curve(FanCurve, preset: CurvePreset?)

    public var name: String {
        switch self {
        case .auto: return "auto"
        case .manual: return "manual"
        case .curve: return "curve"
        }
    }
}

public struct DaemonConfig: Codable, Equatable {
    public var mode: ControlMode
    /// Hand control back to the firmware above this CPU-cluster temperature.
    /// nil disables the watchdog.
    public var watchdogCelsius: Double?

    public static let defaultWatchdogCelsius: Double = 95
    public static let directory = "/Library/Application Support/fanknob"
    public static let path = directory + "/config.json"

    public init(mode: ControlMode = .auto,
                watchdogCelsius: Double? = DaemonConfig.defaultWatchdogCelsius) {
        self.mode = mode
        self.watchdogCelsius = watchdogCelsius
    }

    public static func load(from path: String = DaemonConfig.path) -> DaemonConfig? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(DaemonConfig.self, from: data)
    }

    @discardableResult
    public func save(to path: String = DaemonConfig.path) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return false }
        return FileManager.default.createFile(atPath: path, contents: data,
                                              attributes: [.posixPermissions: 0o644])
    }
}

/// What the daemon reports for the `state` command — one JSON line, so the CLI
/// and the app can show what's actually driving the fans.
public struct DaemonState: Codable, Equatable {
    public var mode: String              // "auto" | "manual" | "curve"
    public var preset: String?           // preset name, when the curve came from one
    public var curve: String?            // wire-format curve, when in curve mode
    public var knob: Double?             // effective knob right now
    public var watchdogCelsius: Double?
    public var watchdogTripped: Bool
    public var holdRemaining: Int        // seconds left on a timed hold, 0 if none

    public init(mode: String, preset: String? = nil, curve: String? = nil,
                knob: Double? = nil, watchdogCelsius: Double? = nil,
                watchdogTripped: Bool = false, holdRemaining: Int = 0) {
        self.mode = mode
        self.preset = preset
        self.curve = curve
        self.knob = knob
        self.watchdogCelsius = watchdogCelsius
        self.watchdogTripped = watchdogTripped
        self.holdRemaining = holdRemaining
    }

    public func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    public static func decode(_ text: String) -> DaemonState? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DaemonState.self, from: data)
    }
}
