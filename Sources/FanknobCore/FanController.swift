// FanController.swift — high-level facade over the SMC engine + daemon client.
//
// This is the clean surface the SwiftUI app (and anything else) uses: read a
// snapshot of fans + temps, and drive the knob / auto without caring whether the
// write happens in-process (root) or via the daemon.

import Foundation
import Darwin

/// Human-readable chip name, e.g. "Apple M2 Pro".
public func chipName() -> String {
    var size = 0
    sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
    guard size > 0 else { return "Apple Silicon" }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
    return String(cString: buf)
}

public struct Snapshot {
    public let fans: [Fan]
    public let temps: TempReport
    public init(fans: [Fan], temps: TempReport) {
        self.fans = fans; self.temps = temps
    }
}

public final class FanController {
    private let smc = SMC()
    private let tempKeys: [UInt32]

    /// True if the SMC opened successfully (reads are possible).
    public let opened: Bool

    public init() {
        var ok = false
        do { try smc.open(); ok = true } catch { ok = false }
        opened = ok
        tempKeys = ok ? discoverTempKeys(smc) : []
    }

    /// Can we perform writes? True if root, or the daemon is reachable.
    public var canWrite: Bool { geteuid() == 0 || daemonReachable() }

    public func snapshot() -> Snapshot {
        guard opened else { return Snapshot(fans: [], temps: TempReport(all: [], cpu: nil, gpu: nil)) }
        let fans = (0..<fanCount(smc)).compactMap { readFan(smc, $0) }
        let temps = tempReport(from: readTempsCached(smc, tempKeys))
        return Snapshot(fans: fans, temps: temps)
    }

    /// Set all fans to a knob percentage, optionally with a timed auto-revert.
    @discardableResult
    public func setKnob(_ pct: Double, holdSeconds: Int = 0) -> Bool {
        if geteuid() == 0 {
            for i in 0..<fanCount(smc) { _ = try? setFanKnob(smc, i, pct: pct) }
            return true
        }
        let cmd = holdSeconds > 0 ? "set \(Int(pct)) \(holdSeconds)" : "set \(Int(pct))"
        if case .ok = sendToDaemon(cmd) { return true }
        return false
    }

    /// Return all fans to automatic control.
    @discardableResult
    public func auto() -> Bool {
        if geteuid() == 0 {
            for i in 0..<fanCount(smc) { try? setFanAuto(smc, i) }
            return true
        }
        if case .ok = sendToDaemon("auto") { return true }
        return false
    }
}
