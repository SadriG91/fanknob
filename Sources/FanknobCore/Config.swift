// Config.swift — persisted daemon state and the wire format for querying it.
//
// The daemon owns this file; it reloads and re-applies on boot so a curve or a
// fixed speed survives restarts. Only root can write it, and every value is
// re-validated on load, so it isn't a privilege-escalation surface.

import Foundation

/// One fan's manual setpoint.
public struct FanKnob: Codable, Equatable, Sendable {
    public let index: Int
    public let pct: Double
    public init(index: Int, pct: Double) {
        self.index = index
        self.pct = pct.clamped(0, 100)
    }

    private enum CodingKeys: CodingKey { case index, pct }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let index = try container.decode(Int.self, forKey: .index)
        let pct = try container.decode(Double.self, forKey: .pct)
        guard (0..<64).contains(index), pct.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .pct, in: container,
                debugDescription: "fan index or percentage is outside the supported range"
            )
        }
        self.init(index: index, pct: pct)
    }
}

public enum ControlMode: Codable, Equatable, Sendable {
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

public struct DaemonConfig: Codable, Equatable, Sendable {
    public var mode: ControlMode
    /// Hand control back to the firmware when the hottest sensor reaches this.
    /// nil disables the watchdog.
    public var watchdogCelsius: Double?
    /// Absolute expiry for a temporary manual hold. Persisting the deadline
    /// prevents a daemon restart or package upgrade from turning a short hold
    /// into an indefinite override.
    public var revertAt: Date?

    public static let defaultWatchdogCelsius: Double = 95
    public static let directory = "/Library/Application Support/fanknob"
    public static let path = directory + "/config.json"

    public init(mode: ControlMode = .auto,
                watchdogCelsius: Double? = DaemonConfig.defaultWatchdogCelsius,
                revertAt: Date? = nil) {
        self.mode = mode
        self.watchdogCelsius = watchdogCelsius
        self.revertAt = revertAt
    }

    public static func load(from path: String = DaemonConfig.path) -> DaemonConfig? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let config = try? JSONDecoder().decode(DaemonConfig.self, from: data),
              config.watchdogCelsius.map({ $0.isFinite && $0 > 0 && $0 <= 120 }) ?? true
        else { return nil }
        return config
    }

    @discardableResult
    public func save(to path: String = DaemonConfig.path) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return false }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                  ofItemAtPath: path)
            return true
        } catch {
            return false
        }
    }
}

/// What the daemon reports for the `state` command — one JSON line, so the CLI
/// and the app can show what's actually driving the fans.
public struct DaemonState: Codable, Equatable, Sendable {
    public var mode: String              // "auto" | "manual" | "curve"
    public var daemonVersion: String?
    public var preset: String?           // preset name, when the curve came from one
    public var curve: String?            // wire-format curve, when in curve mode
    public var knob: Double?             // effective knob right now
    public var watchdogCelsius: Double?
    public var watchdogTripped: Bool
    public var holdRemaining: Int        // seconds left on a timed hold, 0 if none
    public var hottestCelsius: Double?
    public var sensorFailures: Int
    public var safetyReason: String?

    private enum CodingKeys: String, CodingKey {
        case mode, daemonVersion, preset, curve, knob, watchdogCelsius, watchdogTripped
        case holdRemaining, hottestCelsius, sensorFailures, safetyReason
    }

    public init(mode: String, daemonVersion: String? = nil,
                preset: String? = nil, curve: String? = nil,
                knob: Double? = nil, watchdogCelsius: Double? = nil,
                watchdogTripped: Bool = false, holdRemaining: Int = 0,
                hottestCelsius: Double? = nil, sensorFailures: Int = 0,
                safetyReason: String? = nil) {
        self.mode = mode
        self.daemonVersion = daemonVersion
        self.preset = preset
        self.curve = curve
        self.knob = knob
        self.watchdogCelsius = watchdogCelsius
        self.watchdogTripped = watchdogTripped
        self.holdRemaining = holdRemaining
        self.hottestCelsius = hottestCelsius
        self.sensorFailures = sensorFailures
        self.safetyReason = safetyReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(String.self, forKey: .mode)
        daemonVersion = try container.decodeIfPresent(String.self,
                                                      forKey: .daemonVersion)
        preset = try container.decodeIfPresent(String.self, forKey: .preset)
        curve = try container.decodeIfPresent(String.self, forKey: .curve)
        knob = try container.decodeIfPresent(Double.self, forKey: .knob)
        watchdogCelsius = try container.decodeIfPresent(Double.self,
                                                        forKey: .watchdogCelsius)
        watchdogTripped = try container.decodeIfPresent(Bool.self,
                                                        forKey: .watchdogTripped) ?? false
        holdRemaining = try container.decodeIfPresent(Int.self,
                                                      forKey: .holdRemaining) ?? 0
        hottestCelsius = try container.decodeIfPresent(Double.self,
                                                       forKey: .hottestCelsius)
        sensorFailures = try container.decodeIfPresent(Int.self,
                                                       forKey: .sensorFailures) ?? 0
        safetyReason = try container.decodeIfPresent(String.self,
                                                     forKey: .safetyReason)
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
