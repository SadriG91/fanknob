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
    /// Drive every controllable fan to maximum when the hottest sensor reaches
    /// this. nil disables the watchdog.
    public var watchdogCelsius: Double?
    /// Absolute expiry for a temporary manual hold. Persisting the deadline
    /// prevents a daemon restart or package upgrade from turning a short hold
    /// into an indefinite override.
    public var revertAt: Date?

    /// Compared against the raw hottest CPU/GPU die probe (see
    /// DaemonEngine.tick), with `watchdogStrikeLimit` consecutive samples
    /// required before it fires. Calibrated for that signal: a single core
    /// probe routinely runs 15-20 °C above the cluster average under load
    /// (95 tripped on every heavy compile), while Apple Silicon throttles
    /// itself around 105-110 °C — 100 still leaves margin below that.
    public static let defaultWatchdogCelsius: Double = 100
    public static let directory = "/Library/Application Support/fanknob"
    public static let path = directory + "/config.json"

    public init(mode: ControlMode = .auto,
                watchdogCelsius: Double? = DaemonConfig.defaultWatchdogCelsius,
                revertAt: Date? = nil) {
        self.mode = mode
        self.watchdogCelsius = watchdogCelsius
        self.revertAt = revertAt
    }

    public static func load(from path: String = DaemonConfig.path,
                            logger: (String) -> Void = { _ in }) -> DaemonConfig? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if let config = try? JSONDecoder().decode(DaemonConfig.self, from: data),
           config.watchdogCelsius.map({ isValidWatchdogCelsius($0) }) ?? true {
            return config
        }
        // Field-wise salvage. All-or-nothing decoding meant one field that
        // fails today's validation — e.g. a curve saved under an older build's
        // looser rules — silently reset EVERYTHING, including the watchdog (a
        // safety setting), with a log line indistinguishable from a fresh
        // install. Keep each field that still validates, and say what moved.
        guard let salvaged = try? JSONDecoder().decode(SalvagedConfig.self, from: data) else {
            logger("config at \(path) is unreadable; starting with defaults")
            return nil
        }
        var config = DaemonConfig()
        if let mode = salvaged.mode {
            config.mode = mode
            config.revertAt = salvaged.revertAt
        } else {
            logger("persisted mode is no longer valid; discarding it and staying in auto")
        }
        if salvaged.watchdogKeyPresent {
            if let celsius = salvaged.watchdogCelsius, isValidWatchdogCelsius(celsius) {
                config.watchdogCelsius = celsius
            } else {
                logger("persisted watchdog is no longer valid; "
                       + "resetting to \(Int(defaultWatchdogCelsius))°C")
            }
        } else {
            config.watchdogCelsius = nil   // the key's absence means explicitly off
        }
        return config
    }

    /// Lenient mirror of the strict Codable shape: every field decodes
    /// independently, so one invalid value can't take the others down.
    private struct SalvagedConfig: Decodable {
        let mode: ControlMode?
        let watchdogCelsius: Double?
        let watchdogKeyPresent: Bool
        let revertAt: Date?

        private enum CodingKeys: CodingKey { case mode, watchdogCelsius, revertAt }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            mode = (try? container.decodeIfPresent(ControlMode.self, forKey: .mode)) ?? nil
            watchdogKeyPresent = container.contains(.watchdogCelsius)
            watchdogCelsius = (try? container.decodeIfPresent(Double.self,
                                                              forKey: .watchdogCelsius)) ?? nil
            revertAt = (try? container.decodeIfPresent(Date.self, forKey: .revertAt)) ?? nil
        }
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
    /// The watchdog is holding every fan at full speed right now, so the
    /// hardware is at 100% regardless of what `knob` says the mode asks for.
    public var coolingAtMaximum = false
    public var holdRemaining: Int        // seconds left on a timed hold, 0 if none
    public var hottestCelsius: Double?
    public var sensorFailures: Int
    public var safetyReason: String?

    private enum CodingKeys: String, CodingKey {
        case mode, daemonVersion, preset, curve, knob, watchdogCelsius, watchdogTripped
        case coolingAtMaximum, holdRemaining, hottestCelsius, sensorFailures, safetyReason
    }

    public init(mode: String, daemonVersion: String? = nil,
                preset: String? = nil, curve: String? = nil,
                knob: Double? = nil, watchdogCelsius: Double? = nil,
                watchdogTripped: Bool = false, coolingAtMaximum: Bool = false,
                holdRemaining: Int = 0,
                hottestCelsius: Double? = nil, sensorFailures: Int = 0,
                safetyReason: String? = nil) {
        self.mode = mode
        self.daemonVersion = daemonVersion
        self.preset = preset
        self.curve = curve
        self.knob = knob
        self.watchdogCelsius = watchdogCelsius
        self.watchdogTripped = watchdogTripped
        self.coolingAtMaximum = coolingAtMaximum
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
        coolingAtMaximum = try container.decodeIfPresent(Bool.self,
                                                         forKey: .coolingAtMaximum) ?? false
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
