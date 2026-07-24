// fanknob.swift — client CLI.
//
// Reads (status/temp/keys) go straight to the SMC (no privileges needed).
// Writes (set/auto) are sent to the root daemon over a Unix socket, so the user
// never needs sudo. If run as root directly, writes happen in-process.

import Foundation
import Darwin

// MARK: - Talking to the daemon

enum DaemonResult { case ok(String); case unavailable; case failed(String) }

func sendToDaemon(_ command: String) -> DaemonResult {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return .failed("socket() failed") }
    defer { Darwin.close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = fanknobdSocketPath.utf8CString
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in pathBytes.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: b) }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard connected == 0 else { return .unavailable }  // daemon not running

    let msg = command + "\n"
    _ = msg.withCString { send(fd, $0, strlen($0), 0) }

    var buf = [UInt8](repeating: 0, count: 1024)
    let n = recv(fd, &buf, buf.count, 0)
    let reply = n > 0 ? String(bytes: buf[0..<n], encoding: .utf8) ?? "" : ""
    return .ok(reply.trimmingCharacters(in: .whitespacesAndNewlines))
}

// MARK: - Presentation

func knobBar(_ pct: Double) -> String {
    let width = 10
    let filled = Int((pct / 100 * Double(width)).rounded())
    return String(repeating: "#", count: filled) + String(repeating: "·", count: width - filled)
}

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

// set/auto: run in-process if root, else ask the daemon.
func cmdWrite(_ smc: SMC, command: String, apply: (SMC) -> Void) {
    if geteuid() == 0 { apply(smc); return }
    switch sendToDaemon(command) {
    case .ok(let reply):
        print(reply.isEmpty ? "OK" : reply)
    case .unavailable:
        print("""
        fanknob daemon not running, and this isn't root.
        Install the daemon (one time):   sudo make install
        Or run this command with sudo:   sudo fanknob \(command)
        """)
    case .failed(let m):
        print("Could not reach daemon: \(m)")
    }
}

// MARK: - Entry

func usage() {
    print("""
    fanknob — knob-style fan control for Apple Silicon

      fanknob status          fans + temperature
      fanknob tui             live interactive dashboard (turn the knob)
      fanknob temp            list all temperature sensors
      fanknob keys [prefix]   dump SMC keys (default prefix 'F')
      fanknob set <0-100>     set all fans to knob % of their range
      fanknob set <0-100> --for <sec>
                              ... then auto-revert after <sec> (safety)
      fanknob auto            return all fans to automatic control

    Reads need no privileges. set/auto go through the root daemon if installed
    (sudo make install), otherwise run them with sudo.
    """)
}

@main
struct Fanknob {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else { usage(); exit(0) }

        let smc = SMC()
        do { try smc.open() }
        catch { FileHandle.standardError.write("\(error)\n".data(using: .utf8)!); exit(1) }
        defer { smc.close() }

        switch args[1] {
        case "status": cmdStatus(smc)
        case "temp":   cmdTemp(smc)
        case "tui", "top": runTUI(smc)
        case "keys":   cmdKeys(smc, prefix: args.count >= 3 ? args[2] : "F")
        case "set":
            guard args.count >= 3, let v = Double(args[2]) else {
                print("usage: fanknob set <0-100> [--for <seconds>]"); exit(1)
            }
            let pct = v.clamped(0, 100)
            // Optional timed auto-revert: "--for 120" or a bare "120".
            var seconds = 0
            if args.count >= 4 {
                if args[3] == "--for", args.count >= 5, let s = Int(args[4]) { seconds = max(0, s) }
                else if let s = Int(args[3]) { seconds = max(0, s) }
            }
            let cmd = seconds > 0 ? "set \(Int(pct)) \(seconds)" : "set \(Int(pct))"
            cmdWrite(smc, command: cmd) { s in
                let n = fanCount(s)
                print("Setting knob to \(Int(pct))% on \(n) fan(s)...")
                for i in 0..<n {
                    if let rpm = try? setFanKnob(s, i, pct: pct) {
                        print(String(format: "  fan %d -> %.0f rpm (knob %d%%)", i, rpm, Int(pct)))
                    } else { print("  fan \(i): write failed") }
                }
                if seconds > 0 {
                    print("holding for \(seconds)s, then reverting to auto... (keep this running)")
                    sleep(UInt32(seconds))
                    for i in 0..<n { try? setFanAuto(s, i) }
                    print("reverted to auto")
                }
            }
        case "auto":
            cmdWrite(smc, command: "auto") { s in
                let n = fanCount(s)
                print("Returning \(n) fan(s) to automatic control...")
                for i in 0..<n {
                    if (try? setFanAuto(s, i)) != nil { print("  fan \(i): auto") }
                    else { print("  fan \(i): write failed") }
                }
            }
        default: usage()
        }
    }
}
