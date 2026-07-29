// CLI.swift — command-line client and privacy-safe diagnostics.

import Foundation
import Darwin
import FanknobCore

private func stderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func knobBar(_ percent: Double) -> String {
    let width = 10
    let filled = Int((percent.clamped(0, 100) / 100 * Double(width)).rounded())
    return String(repeating: "#", count: filled)
        + String(repeating: "·", count: width - filled)
}

// MARK: - Machine-readable status / diagnostics

private struct FanJSON: Codable {
    let index: Int
    let actualRPM: Double
    let minimumRPM: Double
    let maximumRPM: Double
    let targetRPM: Double
    let percent: Double
    let managed: Bool

    init(_ fan: Fan) {
        index = fan.index
        actualRPM = fan.actual
        minimumRPM = fan.min
        maximumRPM = fan.max
        targetRPM = fan.target
        percent = fan.knob
        managed = fan.managed
    }
}

private struct TemperatureJSON: Codable {
    let cpuCelsius: Double?
    let gpuCelsius: Double?
    let overallCelsius: Double?
    let sensorCount: Int
    let groups: [String: Int]
}

private struct StatusJSON: Codable {
    let version: String
    let generatedAt: Date
    let chip: String
    let macOS: String
    let fans: [FanJSON]
    let temperatures: TemperatureJSON
    let daemon: DaemonState?
}

private struct DiagnoseJSON: Codable {
    let generatedAt: Date
    let chip: String
    let macOS: String
    let cliVersion: String
    let installedAppVersion: String?
    let daemonVersion: String?
    let fans: [FanJSON]
    let temperatures: TemperatureJSON
    let daemonMode: String?
    let recentErrors: [String]
}

private func collectStatus(_ smc: SMC) -> StatusJSON {
    let fans = (0..<fanCount(smc)).compactMap { readFan(smc, $0) }
    let temperatures = readTempReport(smc)
    var groups: [String: Int] = [:]
    for sensor in temperatures.all {
        let prefix = String(sensor.key.prefix(2))
        groups[prefix, default: 0] += 1
    }
    let daemon: DaemonState?
    if case .ok(let reply) = sendToDaemon("state") {
        daemon = DaemonState.decode(reply)
    } else {
        daemon = nil
    }
    return StatusJSON(
        version: fanknobVersion,
        generatedAt: Date(),
        chip: chipName(),
        macOS: ProcessInfo.processInfo.operatingSystemVersionString,
        fans: fans.map(FanJSON.init),
        temperatures: TemperatureJSON(
            cpuCelsius: temperatures.cpu,
            gpuCelsius: temperatures.gpu,
            overallCelsius: temperatures.overall,
            sensorCount: temperatures.all.count,
            groups: groups
        ),
        daemon: daemon
    )
}

private func collectDiagnostics(_ smc: SMC) -> DiagnoseJSON {
    let status = collectStatus(smc)
    let installedAppVersion = Bundle(path: "/Applications/Fanknob.app")?
        .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    return DiagnoseJSON(
        generatedAt: status.generatedAt,
        chip: status.chip,
        macOS: status.macOS,
        cliVersion: status.version,
        installedAppVersion: installedAppVersion,
        daemonVersion: status.daemon?.daemonVersion,
        fans: status.fans,
        temperatures: status.temperatures,
        daemonMode: status.daemon?.mode,
        recentErrors: [status.daemon?.safetyReason].compactMap { $0 }
    )
}

@discardableResult
private func printJSON<T: Encodable>(_ value: T) -> Bool {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    do {
        let data = try encoder.encode(value)
        print(String(decoding: data, as: UTF8.self))
        return true
    } catch {
        stderr("Could not encode JSON: \(error)")
        return false
    }
}

// MARK: - Human-readable reads

@discardableResult
func cmdStatus(_ smc: SMC, json: Bool = false) -> Bool {
    if json { return printJSON(collectStatus(smc)) }

    let count = fanCount(smc)
    if count == 0 {
        print("No fans reported (FNum = 0).")
    } else {
        print("Fans: \(count)")
        for index in 0..<count {
            guard let fan = readFan(smc, index) else {
                print("  fan \(index): unreadable")
                continue
            }
            print(String(format: "  fan %d  %4.0f rpm  [%@]  min %4.0f  max %4.0f",
                         index, fan.actual, knobBar(fan.knob) as CVarArg,
                         fan.min, fan.max))
            print(String(format: "         mode: %@   target %4.0f rpm  ≈ knob %3.0f%%",
                         fan.managed ? "MANUAL" : "auto", fan.target, fan.knob))
        }
    }

    let temperatures = readTempReport(smc)
    if temperatures.cpu != nil || temperatures.gpu != nil || temperatures.overall != nil {
        var parts: [String] = []
        if let cpu = temperatures.cpu {
            parts.append(String(format: "CPU %.0f°C", cpu))
        }
        if let gpu = temperatures.gpu {
            parts.append(String(format: "GPU %.0f°C", gpu))
        }
        if parts.isEmpty, let overall = temperatures.overall {
            parts.append(String(format: "avg %.0f°C", overall))
        }
        print("\nTemp: " + parts.joined(separator: "   ")
              + "   (\(temperatures.all.count) sensors)")
    }
    printDaemonState()
    return true
}

func printDaemonState() {
    let reply: String
    switch sendToDaemon("state") {
    case .ok(let response):
        reply = response
    case .unavailable:
        print("\nDaemon: not running — fan control unavailable without sudo")
        return
    case .failed(let message):
        print("\nDaemon: unreachable (\(message))")
        return
    }
    guard let state = DaemonState.decode(reply) else {
        print("\nDaemon: incompatible response — upgrade fanknob")
        return
    }

    var line: String
    switch state.mode {
    case "curve":
        line = "curve (\(state.preset ?? "custom"))"
        if let curve = state.curve { line += "  \(curve)" }
        if let knob = state.knob { line += String(format: "  → %.0f%%", knob) }
    case "manual":
        line = "manual" + (state.knob.map { String(format: " %.0f%%", $0) } ?? "")
        if state.holdRemaining > 0 {
            line += "  (reverts in \(state.holdRemaining)s)"
        }
    default:
        line = "auto"
    }
    let watchdog = state.watchdogCelsius.map { "\(Int($0))°C" } ?? "off"
    print("\nDaemon: \(line)   watchdog \(watchdog)")
    if let reason = state.safetyReason {
        print("        ⚠︎ \(reason)")
    }
}

@discardableResult
func cmdTemp(_ smc: SMC) -> Bool {
    let report = readTempReport(smc)
    guard !report.all.isEmpty else {
        stderr("No temperature sensors readable.")
        return false
    }
    var header: [String] = []
    if let cpu = report.cpu { header.append(String(format: "CPU %.1f°C", cpu)) }
    if let gpu = report.gpu { header.append(String(format: "GPU %.1f°C", gpu)) }
    if let overall = report.overall {
        header.append(String(format: "all %.1f°C", overall))
    }
    print("Temperature — \(header.joined(separator: "   "))"
          + "   (\(report.all.count) sensors)\n")
    for sensor in report.all {
        print(String(format: "  %-5@  %5.1f°C",
                     sensor.key as CVarArg, sensor.celsius))
    }
    return true
}

@discardableResult
func cmdKeys(_ smc: SMC, prefix: String) -> Bool {
    let count = smc.keyCount()
    guard count > 0 else {
        stderr("Could not enumerate keys.")
        return false
    }
    print("Scanning \(count) SMC keys with prefix '\(prefix)'...\n")
    for index in 0..<count {
        guard let key = smc.keyAtIndex(index) else { continue }
        let name = fourCCString(key)
        guard name.hasPrefix(prefix), let (type, bytes) = smc.read(key) else { continue }
        let value = decodeToDouble(type: type, bytes: bytes)
            .map { String(format: "%.2f", $0) }
            ?? bytes.map { String(format: "%02x", $0) }.joined()
        print("  \(name)  [\(fourCCString(type))]  \(value)")
    }
    return true
}

// Hidden developer command: time the SMC read paths used by the app.
func cmdBench(_ smc: SMC) {
    func milliseconds(_ value: TimeInterval) -> String {
        String(format: "%7.2f ms", value * 1000)
    }
    var start = Date()
    let keys = discoverTempKeys(smc)
    print("discoverTempKeys (\(keys.count) keys): \(milliseconds(Date().timeIntervalSince(start)))")
    let iterations = 20
    start = Date()
    for _ in 0..<iterations { _ = readTempsCached(smc, keys) }
    let temperatureAverage = Date().timeIntervalSince(start) / Double(iterations)
    start = Date()
    for _ in 0..<iterations {
        _ = (0..<fanCount(smc)).compactMap { readFan(smc, $0) }
    }
    let fanAverage = Date().timeIntervalSince(start) / Double(iterations)
    print("readTempsCached  avg over \(iterations):   \(milliseconds(temperatureAverage))")
    print("fan scan         avg over \(iterations):   \(milliseconds(fanAverage))")
    print("≈ one app poll (temps + fans):  \(milliseconds(temperatureAverage + fanAverage))")
}

// MARK: - Writes

/// Prefer the daemon even as root. A direct write while the daemon is following
/// a curve would be overwritten on its next tick.
@discardableResult
func control(_ command: String, _ smc: SMC,
             fallback: ((SMC) -> Bool)?) -> Bool {
    switch sendToDaemon(command) {
    case .ok(let reply):
        print(reply.isEmpty ? "OK" : reply)
        return true
    case .failed(let message):
        stderr("fanknob: \(message)")
        return false
    case .unavailable:
        if geteuid() == 0, let fallback { return fallback(smc) }
        if fallback == nil && geteuid() == 0 {
            stderr("That command needs the fanknob daemon running.")
        } else {
            stderr("""
            fanknob daemon not running, and this isn't root.
            Start or reinstall it, or run this command with sudo.
            """)
        }
        return false
    }
}

private func usage() {
    print("""
    fanknob — knob-style fan control for Apple Silicon

      fanknob status [--json]           fans, temperatures, and daemon state
      fanknob diagnose --json           privacy-safe compatibility report
      fanknob tui                       live interactive dashboard
      fanknob temp                      list all temperature sensors
      fanknob keys [prefix]             dump SMC keys (default prefix 'F')
      fanknob version                   installed version

      fanknob set <0-100> [options]     fixed speed
            --fan <n>                   just that fan (default: all)
            --for <seconds>             revert to auto (maximum 86400)
      fanknob auto                      return to firmware control
      fanknob preset quiet|balanced|turbo
      fanknob curve <°C>:<%>,...        strictly rising temperatures/speeds
      fanknob watchdog <°C>|off
    """)
}

/// Validate the complete invocation before opening the SMC. Besides producing
/// normal usage errors on machines where hardware access is unavailable, this
/// guarantees NaN/∞ and malformed options never reach integer conversion or a
/// control path.
private func invocationError(_ arguments: [String]) -> String? {
    guard let command = arguments.first else { return nil }
    switch command {
    case "status":
        return arguments.count == 1
            || (arguments.count == 2 && arguments[1] == "--json")
            ? nil : "usage: fanknob status [--json]"
    case "diagnose":
        return arguments == ["diagnose", "--json"]
            ? nil : "usage: fanknob diagnose --json"
    case "temp", "tui", "top", "bench", "auto":
        return arguments.count == 1 ? nil : "unexpected option for \(command)"
    case "keys":
        return arguments.count <= 2 ? nil : "usage: fanknob keys [prefix]"
    case "set":
        guard arguments.count >= 2,
              let value = Double(arguments[1]), value.isFinite else {
            return "usage: fanknob set <0-100> [--fan <n>] [--for <seconds>]"
        }
        var index = 2
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                return "missing value for \(arguments[index])"
            }
            switch arguments[index] {
            case "--for":
                guard let seconds = Int(arguments[index + 1]),
                      (0...maximumHoldSeconds).contains(seconds) else {
                    return "--for must be between 0 and \(maximumHoldSeconds)"
                }
            case "--fan":
                guard let fan = Int(arguments[index + 1]), fan >= 0 else {
                    return "--fan must be a non-negative integer"
                }
            default:
                return "unknown option: \(arguments[index])"
            }
            index += 2
        }
        return nil
    case "preset":
        guard arguments.count == 2,
              CurvePreset(rawValue: arguments[1].lowercased()) != nil else {
            return "usage: fanknob preset quiet|balanced|turbo"
        }
        return nil
    case "curve":
        guard arguments.count == 2, FanCurve.parse(arguments[1]) != nil else {
            return "curve requires 2–12 safe points formatted as °C:%"
        }
        return nil
    case "watchdog":
        guard arguments.count == 2 else {
            return "usage: fanknob watchdog <°C>|off"
        }
        let value = arguments[1].lowercased()
        guard value == "off"
                || (Double(value).map {
                    $0.isFinite && $0 > 0 && $0 <= 120
                } ?? false) else {
            return "watchdog must be a temperature from 1–120, or off"
        }
        return nil
    default:
        return "unknown command: \(command)"
    }
}

private func openSMC() -> SMC? {
    let smc = SMC()
    do {
        try smc.open()
        return smc
    } catch {
        stderr("\(error)")
        return nil
    }
}

@main
struct Fanknob {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { usage(); exit(0) }

        if ["version", "--version", "-v"].contains(command) {
            guard arguments.count == 1 else { usage(); exit(2) }
            print("fanknob \(fanknobVersion)")
            return
        }

        if let error = invocationError(arguments) {
            stderr(error)
            exit(2)
        }

        guard let smc = openSMC() else { exit(1) }
        defer { smc.close() }
        var success = true

        switch command {
        case "status":
            guard arguments.count == 1
                    || (arguments.count == 2 && arguments[1] == "--json")
            else { usage(); exit(2) }
            success = cmdStatus(smc, json: arguments.count == 2)

        case "diagnose":
            guard arguments == ["diagnose", "--json"] else { usage(); exit(2) }
            success = printJSON(collectDiagnostics(smc))

        case "temp":
            guard arguments.count == 1 else { usage(); exit(2) }
            success = cmdTemp(smc)

        case "tui", "top":
            guard arguments.count == 1 else { usage(); exit(2) }
            runTUI(smc)

        case "bench":
            guard arguments.count == 1 else { usage(); exit(2) }
            cmdBench(smc)

        case "keys":
            guard arguments.count <= 2 else { usage(); exit(2) }
            success = cmdKeys(smc, prefix: arguments.count == 2 ? arguments[1] : "F")

        case "set":
            guard arguments.count >= 2,
                  let value = Double(arguments[1]), value.isFinite else {
                stderr("usage: fanknob set <0-100> [--fan <n>] [--for <seconds>]")
                exit(2)
            }
            let percent = value.clamped(0, 100)
            var hold = 0
            var fan: Int?
            var index = 2
            while index < arguments.count {
                guard index + 1 < arguments.count else { usage(); exit(2) }
                switch arguments[index] {
                case "--for":
                    guard let seconds = Int(arguments[index + 1]),
                          (0...maximumHoldSeconds).contains(seconds) else {
                        stderr("--for must be between 0 and \(maximumHoldSeconds)")
                        exit(2)
                    }
                    hold = seconds
                case "--fan":
                    guard let parsed = Int(arguments[index + 1]), parsed >= 0 else {
                        stderr("--fan must be a non-negative integer")
                        exit(2)
                    }
                    fan = parsed
                default:
                    stderr("unknown option: \(arguments[index])")
                    exit(2)
                }
                index += 2
            }
            var wire = fan.map { "setfan \($0) \(Int(percent))" }
                ?? "set \(Int(percent))"
            if hold > 0 { wire += " \(hold)" }
            success = control(wire, smc) { hardware in
                let targets = fan.map { [$0] } ?? Array(0..<fanCount(hardware))
                var applied: [Int] = []
                for target in targets {
                    do {
                        let rpm = try setFanKnob(hardware, target, pct: percent)
                        applied.append(target)
                        print(String(format: "fan %d -> %.0f rpm (knob %d%%)",
                                     target, rpm, Int(percent)))
                    } catch {
                        for index in applied { try? setFanAuto(hardware, index) }
                        stderr("fan \(target) write failed; restored automatic control")
                        return false
                    }
                }
                if hold > 0 {
                    print("holding for \(hold)s, then reverting to auto...")
                    sleep(UInt32(hold))
                    for target in targets { try? setFanAuto(hardware, target) }
                    print("reverted to auto")
                }
                return true
            }

        case "auto":
            guard arguments.count == 1 else { usage(); exit(2) }
            success = control("auto", smc) { hardware in
                var ok = true
                for index in 0..<fanCount(hardware) {
                    do {
                        try setFanAuto(hardware, index)
                        print("fan \(index): auto")
                    } catch {
                        stderr("fan \(index): write failed")
                        ok = false
                    }
                }
                return ok
            }

        case "preset":
            guard arguments.count == 2,
                  let preset = CurvePreset(rawValue: arguments[1].lowercased()) else {
                stderr("usage: fanknob preset quiet|balanced|turbo")
                exit(2)
            }
            success = control("preset \(preset.rawValue)", smc, fallback: nil)

        case "curve":
            guard arguments.count == 2, let curve = FanCurve.parse(arguments[1]) else {
                stderr("curve requires 2–12 points with increasing temperatures and speeds")
                exit(2)
            }
            success = control("curve \(curve.wireFormat)", smc, fallback: nil)

        case "watchdog":
            guard arguments.count == 2 else { usage(); exit(2) }
            let value = arguments[1].lowercased()
            if value != "off" {
                guard let temperature = Double(value), temperature.isFinite,
                      temperature > 0, temperature <= 120 else {
                    stderr("watchdog must be a temperature from 1–120, or off")
                    exit(2)
                }
            }
            success = control("watchdog \(value)", smc, fallback: nil)

        default:
            usage()
            exit(2)
        }
        if !success { exit(1) }
    }
}
