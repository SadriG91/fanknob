// CLI.swift — fanknob command-line client.
//
// Reads (status/temp/keys/tui) go straight to the SMC (no privileges). Control
// commands go to the root daemon over a Unix socket; without a daemon, running
// as root falls back to writing in-process (except curves, which need the
// daemon's evaluation loop to mean anything).

import Foundation
import Darwin
import FanknobCore

func knobBar(_ pct: Double) -> String {
    let width = 10
    let filled = Int((pct / 100 * Double(width)).rounded())
    return String(repeating: "#", count: filled) + String(repeating: "·", count: width - filled)
}

// MARK: - Reads

func cmdStatus(_ smc: SMC) {
    let n = fanCount(smc)
    if n == 0 { print("No fans reported (FNum = 0).") }
    else {
        print("Fans: \(n)")
        for i in 0..<n {
            guard let f = readFan(smc, i) else { print("  fan \(i): unreadable"); continue }
            print(String(format: "  fan %d  %4.0f rpm  [%@]  min %4.0f  max %4.0f",
                         i, f.actual, knobBar(f.knob) as CVarArg, f.min, f.max))
            print(String(format: "         mode: %@   target %4.0f rpm  ≈ knob %3.0f%%",
                         f.managed ? "MANUAL" : "auto", f.target, f.knob))
        }
    }

    let t = readTempReport(smc)
    if t.cpu != nil || t.gpu != nil || t.overall != nil {
        var parts: [String] = []
        if let c = t.cpu { parts.append(String(format: "CPU %.0f°C", c)) }
        if let g = t.gpu { parts.append(String(format: "GPU %.0f°C", g)) }
        if parts.isEmpty, let o = t.overall { parts.append(String(format: "avg %.0f°C", o)) }
        print("\nTemp: " + parts.joined(separator: "   ") + "   (\(t.all.count) sensors)")
    }

    printDaemonState()
}

/// What the daemon is driving, if it's running.
func printDaemonState() {
    let reply: String
    switch sendToDaemon("state") {
    case .ok(let r): reply = r
    case .unavailable:
        print("\nDaemon: not running — fan control unavailable without sudo")
        return
    case .failed(let m):
        print("\nDaemon: unreachable (\(m))")
        return
    }
    guard let s = DaemonState.decode(reply) else {
        print("\nDaemon: running an older version — upgrade for curves (brew upgrade fanknob)")
        return
    }
    var line: String
    switch s.mode {
    case "curve":
        let name = s.preset ?? "custom"
        line = "curve (\(name))"
        if let c = s.curve { line += "  \(c)" }
        if let k = s.knob { line += String(format: "  → %.0f%%", k) }
    case "manual":
        line = "manual" + (s.knob.map { String(format: " %.0f%%", $0) } ?? "")
        if s.holdRemaining > 0 { line += "  (reverts in \(s.holdRemaining)s)" }
    default:
        line = "auto"
    }
    let wd = s.watchdogCelsius.map { "\(Int($0))°C" } ?? "off"
    print("\nDaemon: \(line)   watchdog \(wd)")
    if s.watchdogTripped {
        print("        ⚠︎ watchdog tripped — fans were returned to the firmware")
    }
}

func cmdTemp(_ smc: SMC) {
    let t = readTempReport(smc)
    guard !t.all.isEmpty else { print("No temperature sensors readable."); return }
    var head: [String] = []
    if let c = t.cpu { head.append(String(format: "CPU %.1f°C", c)) }
    if let g = t.gpu { head.append(String(format: "GPU %.1f°C", g)) }
    if let o = t.overall { head.append(String(format: "all %.1f°C", o)) }
    print("Temperature — \(head.joined(separator: "   "))   (\(t.all.count) sensors)\n")
    for s in t.all {
        print(String(format: "  %-5@  %5.1f°C", s.key as CVarArg, s.celsius))
    }
}

func cmdKeys(_ smc: SMC, prefix: String) {
    let count = smc.keyCount()
    guard count > 0 else { print("Could not enumerate keys."); return }
    print("Scanning \(count) SMC keys with prefix '\(prefix)'...\n")
    for i in 0..<count {
        guard let key = smc.keyAtIndex(i) else { continue }
        let name = fourCCString(key)
        guard name.hasPrefix(prefix) else { continue }
        guard let (t, b) = smc.read(key) else { continue }
        let val = decodeToDouble(type: t, bytes: b)
            .map { String(format: "%.2f", $0) } ?? b.map { String(format: "%02x", $0) }.joined()
        print("  \(name)  [\(fourCCString(t))]  \(val)")
    }
}

// Hidden dev command: time the SMC read paths the app's poller uses.
func cmdBench(_ smc: SMC) {
    func ms(_ t: TimeInterval) -> String { String(format: "%7.2f ms", t * 1000) }

    var t0 = Date()
    let keys = discoverTempKeys(smc)
    print("discoverTempKeys (\(keys.count) keys): \(ms(Date().timeIntervalSince(t0)))")

    let iters = 20
    t0 = Date()
    for _ in 0..<iters { _ = readTempsCached(smc, keys) }
    let tempAvg = Date().timeIntervalSince(t0) / Double(iters)
    print("readTempsCached  avg over \(iters):   \(ms(tempAvg))")

    t0 = Date()
    for _ in 0..<iters { _ = (0..<fanCount(smc)).compactMap { readFan(smc, $0) } }
    let fanAvg = Date().timeIntervalSince(t0) / Double(iters)
    print("fan scan         avg over \(iters):   \(ms(fanAvg))")
    print("≈ one app poll (temps + fans):  \(ms(tempAvg + fanAvg))")
}

// MARK: - Writes

/// Send a control command to the daemon. `fallback` runs instead when there's
/// no daemon but we are root; pass nil for commands that require the daemon.
func control(_ command: String, _ smc: SMC, fallback: ((SMC) -> Void)?) {
    switch sendToDaemon(command) {
    case .ok(let reply):
        print(reply.isEmpty ? "OK" : reply)
    case .failed(let m):
        print("Could not reach daemon: \(m)")
    case .unavailable:
        if geteuid() == 0, let fallback {
            fallback(smc)
            return
        }
        if fallback == nil && geteuid() == 0 {
            print("That needs the fanknob daemon running (it evaluates curves over time).")
        } else {
            print("""
            fanknob daemon not running, and this isn't root.
            The installer loads it for you; if it was stopped, start it with:
              sudo launchctl bootstrap system /Library/LaunchDaemons/com.fanknob.daemon.plist
            Not installed yet?  brew install --cask SadriG91/tap/fanknob
            Or run this command with sudo.
            """)
        }
    }
}

func usage() {
    print("""
    fanknob — knob-style fan control for Apple Silicon

      fanknob status                    fans, temperature, and what the daemon is doing
      fanknob tui                       live interactive dashboard
      fanknob temp                      list all temperature sensors
      fanknob keys [prefix]             dump SMC keys (default prefix 'F')
      fanknob version                   the installed version

      fanknob set <0-100> [options]     fixed speed
            --fan <n>                   just that fan (default: all)
            --for <seconds>             revert to auto afterwards
      fanknob auto                      return to firmware control

      fanknob preset <name>             temperature curve: quiet | balanced | turbo
      fanknob curve <°C>:<%>,...        custom curve, e.g. 55:0,72:20,85:60,93:100
      fanknob watchdog <°C>|off         hand back to firmware above this temp

    Reads need no privileges. Control goes through the root daemon, so no sudo
    per command once it's installed.
    """)
}

@main
struct Fanknob {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else { usage(); exit(0) }

        // Answered before the SMC is touched, so asking an install what it is
        // still works on a machine where the SMC won't open.
        if ["version", "--version", "-v"].contains(args[1]) {
            print("fanknob \(fanknobVersion)")
            exit(0)
        }

        let smc = SMC()
        do { try smc.open() }
        catch { FileHandle.standardError.write("\(error)\n".data(using: .utf8)!); exit(1) }
        defer { smc.close() }

        switch args[1] {
        case "status": cmdStatus(smc)
        case "temp":   cmdTemp(smc)
        case "tui", "top": runTUI(smc)
        case "bench":  cmdBench(smc)   // hidden: SMC read-path timings
        case "keys":   cmdKeys(smc, prefix: args.count >= 3 ? args[2] : "F")

        case "set":
            guard args.count >= 3, let v = Double(args[2]) else {
                print("usage: fanknob set <0-100> [--fan <n>] [--for <seconds>]"); exit(1)
            }
            let pct = v.clamped(0, 100)
            var seconds = 0
            var fan: Int?
            var i = 3
            while i < args.count {
                switch args[i] {
                case "--for":
                    if i + 1 < args.count, let s = Int(args[i + 1]) { seconds = max(0, s); i += 1 }
                case "--fan":
                    if i + 1 < args.count, let f = Int(args[i + 1]) { fan = f; i += 1 }
                default:
                    if let s = Int(args[i]) { seconds = max(0, s) }   // legacy: bare seconds
                }
                i += 1
            }
            var cmd = fan.map { "setfan \($0) \(Int(pct))" } ?? "set \(Int(pct))"
            if seconds > 0 { cmd += " \(seconds)" }
            control(cmd, smc) { s in
                let targets = fan.map { [$0] } ?? Array(0..<fanCount(s))
                for i in targets {
                    if let rpm = try? setFanKnob(s, i, pct: pct) {
                        print(String(format: "  fan %d -> %.0f rpm (knob %d%%)", i, rpm, Int(pct)))
                    } else { print("  fan \(i): write failed") }
                }
                if seconds > 0 {
                    print("holding for \(seconds)s, then reverting to auto... (keep this running)")
                    sleep(UInt32(seconds))
                    for i in targets { try? setFanAuto(s, i) }
                    print("reverted to auto")
                }
            }

        case "auto":
            control("auto", smc) { s in
                for i in 0..<fanCount(s) {
                    if (try? setFanAuto(s, i)) != nil { print("  fan \(i): auto") }
                    else { print("  fan \(i): write failed") }
                }
            }

        case "preset":
            guard args.count >= 3 else {
                print("usage: fanknob preset <\(CurvePreset.allCases.map(\.rawValue).joined(separator: "|"))>")
                exit(1)
            }
            control("preset \(args[2])", smc, fallback: nil)

        case "curve":
            guard args.count >= 3 else {
                print("usage: fanknob curve <°C>:<%>,<°C>:<%>[,...]   e.g. 55:0,72:20,85:60,93:100")
                exit(1)
            }
            control("curve \(args[2])", smc, fallback: nil)

        case "watchdog":
            guard args.count >= 3 else { print("usage: fanknob watchdog <°C>|off"); exit(1) }
            control("watchdog \(args[2])", smc, fallback: nil)

        default: usage()
        }
    }
}
