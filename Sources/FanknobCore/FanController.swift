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
    return String(decoding: buf.prefix { $0 != 0 }.map {
        UInt8(bitPattern: $0)
    }, as: UTF8.self)
}

public struct Snapshot: Sendable {
    public let fans: [Fan]
    public let temps: TempReport
    public init(fans: [Fan], temps: TempReport) {
        self.fans = fans; self.temps = temps
    }
}

/// How much of the hardware to read in one snapshot.
public enum SnapshotScope: Sendable {
    /// Everything: all temp sensors + fans. ~30 ms of SMC calls.
    case full
    /// Just enough for a menu-bar readout: the CPU-cluster sensors (falling
    /// back to GPU, then all, on machines without Tp*/Tg* naming) + fans.
    /// A few ms instead of ~30.
    case light
}

public final class FanController {
    private let smc = SMC()
    private let tempKeys: [UInt32]
    private let lightKeys: [UInt32]

    /// True if the SMC opened successfully (reads are possible).
    public let opened: Bool
    public private(set) var lastError: String?

    public init() {
        var ok = false
        do { try smc.open(); ok = true } catch { ok = false }
        opened = ok
        tempKeys = ok ? discoverTempKeys(smc) : []
        let cpuKeys = tempKeys.filter { fourCCString($0).hasPrefix("Tp") }
        let gpuKeys = tempKeys.filter { fourCCString($0).hasPrefix("Tg") }
        lightKeys = cpuKeys.isEmpty ? (gpuKeys.isEmpty ? tempKeys : gpuKeys) : cpuKeys
    }

    /// Can we perform writes? True if root, or the daemon is reachable.
    public var canWrite: Bool { geteuid() == 0 || daemonReachable() }

    public func snapshot(_ scope: SnapshotScope = .full) -> Snapshot {
        guard opened else { return Snapshot(fans: [], temps: TempReport(all: [], cpu: nil, gpu: nil)) }
        let fans = (0..<fanCount(smc)).compactMap { readFan(smc, $0) }
        let keys = scope == .full ? tempKeys : lightKeys
        let temps = tempReport(from: readTempsCached(smc, keys))
        return Snapshot(fans: fans, temps: temps)
    }

    /// Set fans to a knob percentage, optionally one fan and/or with a timed
    /// auto-revert. `fan: nil` means every fan.
    @discardableResult
    public func setKnob(_ pct: Double, fan: Int? = nil, holdSeconds: Int = 0) -> Bool {
        guard pct.isFinite, (0...maximumHoldSeconds).contains(holdSeconds) else {
            lastError = "Invalid fan speed or hold duration."
            return false
        }
        if geteuid() == 0 && !daemonReachable() {
            // Direct write; the daemon isn't there to keep any curve running.
            let targets = fan.map { [$0] } ?? Array(0..<fanCount(smc))
            var applied: [Int] = []
            for index in targets {
                do {
                    _ = try setFanKnob(smc, index, pct: pct)
                    applied.append(index)
                } catch {
                    for written in applied { try? setFanAuto(smc, written) }
                    lastError = "Fan \(index) write failed; restored automatic control."
                    return false
                }
            }
            lastError = nil
            return true
        }
        var cmd = fan.map { "setfan \($0) \(Int(pct))" } ?? "set \(Int(pct))"
        if holdSeconds > 0 { cmd += " \(holdSeconds)" }
        return runDaemonCommand(cmd)
    }

    /// Hand the fans to a temperature curve. Requires the daemon — it's what
    /// evaluates the curve over time.
    @discardableResult
    public func setPreset(_ preset: CurvePreset) -> Bool {
        runDaemonCommand("preset \(preset.rawValue)")
    }

    @discardableResult
    public func setCurve(_ curve: FanCurve) -> Bool {
        runDaemonCommand("curve \(curve.wireFormat)")
    }

    /// Temperature above which the daemon returns the fans to the firmware.
    /// nil disables the watchdog.
    @discardableResult
    public func setWatchdog(_ celsius: Double?) -> Bool {
        let arg = celsius.map { String(Int($0)) } ?? "off"
        return runDaemonCommand("watchdog \(arg)")
    }

    /// What the daemon is currently doing (nil if it isn't running).
    public func daemonState() -> DaemonState? {
        guard case .ok(let reply) = sendToDaemon("state") else { return nil }
        return DaemonState.decode(reply)
    }

    /// Return all fans to automatic control. Prefers the daemon even when
    /// root: a direct write wouldn't stop a curve the daemon is driving.
    @discardableResult
    public func auto() -> Bool {
        switch sendToDaemon("auto") {
        case .ok:
            lastError = nil
            return true
        case .failed(let message):
            lastError = message
            return false
        case .unavailable:
            break
        }
        if geteuid() == 0 {
            var success = true
            for index in 0..<fanCount(smc) {
                do { try setFanAuto(smc, index) }
                catch { success = false }
            }
            lastError = success ? nil : "One or more fans could not be returned to automatic control."
            return success
        }
        lastError = "The fanknob helper is not available."
        return false
    }

    private func runDaemonCommand(_ command: String) -> Bool {
        switch sendToDaemon(command) {
        case .ok:
            lastError = nil
            return true
        case .unavailable:
            lastError = "The fanknob helper is not available."
            return false
        case .failed(let message):
            lastError = message
            return false
        }
    }
}
