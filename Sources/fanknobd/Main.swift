// Main.swift — privileged fan-control daemon (fanknobd).
//
// Runs as root under launchd. Listens on a Unix socket and accepts ONLY these
// commands — "set <0-100> [seconds]" and "auto" — so even though any local user
// can connect, the daemon can't be made to do anything but move the fans.
//
// Safety auto-revert: "set 60 120" holds 60% for 120 seconds, then the daemon
// returns the fans to automatic control. Because the timer lives here, the
// revert still happens if the client exits or the terminal is closed.

import Foundation
import Darwin
import Dispatch
import FanknobCore

func log(_ s: String) {
    FileHandle.standardError.write("fanknobd: \(s)\n".data(using: .utf8)!)
}

// All SMC access and the pending-revert timer are serialized through this queue.
let smcQueue = DispatchQueue(label: "com.fanknob.smc")
var pendingRevert: DispatchWorkItem?   // only touched on smcQueue

func applyAuto(_ smc: SMC) {
    let n = fanCount(smc)
    for i in 0..<n { try? setFanAuto(smc, i) }
}

// Must run on smcQueue. Returns the text reply for the client.
func handleLocked(_ line: String, _ smc: SMC) -> String {
    switch parseDaemonCommand(line) {
    case .failure(.empty):
        return "empty command"
    case .failure(.badSet):
        return "usage: set <0-100> [seconds]"
    case .failure(.unknown(let verb)):
        return "unknown command: \(verb)"

    case .success(.auto):
        pendingRevert?.cancel(); pendingRevert = nil
        applyAuto(smc)
        return "auto: returned to automatic control"

    case .success(.set(let pct, let seconds)):
        pendingRevert?.cancel(); pendingRevert = nil

        let n = fanCount(smc)
        var lines: [String] = []
        for i in 0..<n {
            if let rpm = try? setFanKnob(smc, i, pct: pct) {
                lines.append(String(format: "fan %d -> %.0f rpm (knob %d%%)", i, rpm, Int(pct)))
            } else {
                lines.append("fan \(i): write failed")
            }
        }

        if seconds > 0 {
            let work = DispatchWorkItem {
                applyAuto(smc)
                log("safety auto-revert fired after \(seconds)s")
            }
            pendingRevert = work
            smcQueue.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
            lines.append("holding \(Int(pct))% for \(seconds)s, then auto-revert")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Socket server

@main
struct Fanknobd {
    static func main() {
        guard geteuid() == 0 else { log("must run as root"); exit(1) }

        // Singleton guard: a Homebrew-managed daemon and a `make install` one
        // must not fight over the socket. The lock fd stays open for the
        // process lifetime; if the winner ever stops, launchd's keep-alive
        // retries let this instance take over automatically.
        guard acquireDaemonLock() != nil else {
            log("another fanknobd already holds \(fanknobdLockPath) — refusing to start")
            log("keep ONE install: `sudo make uninstall` (manual) or `sudo brew services stop fanknob` (Homebrew)")
            exit(1)
        }

        let smc = SMC()
        do { try smc.open() } catch { log("\(error)"); exit(1) }

        unlink(fanknobdSocketPath)

        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { log("socket() failed"); exit(1) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = fanknobdSocketPath.utf8CString
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in pathBytes.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: b) }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFD, $0, addrLen) }
        }
        guard bound == 0 else { log("bind() failed: \(String(cString: strerror(errno)))"); exit(1) }

        chmod(fanknobdSocketPath, 0o666)

        guard listen(listenFD, 8) == 0 else { log("listen() failed"); exit(1) }
        log("listening on \(fanknobdSocketPath)")

        while true {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 { continue }

            var buf = [UInt8](repeating: 0, count: 256)
            let n = recv(clientFD, &buf, buf.count, 0)
            if n > 0 {
                let raw = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
                let line = raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                    .first.map(String.init) ?? ""
                let reply = smcQueue.sync { handleLocked(line, smc) } + "\n"
                log("cmd '\(line)'")
                _ = reply.withCString { send(clientFD, $0, strlen($0), 0) }
            }
            Darwin.close(clientFD)
        }
    }
}
