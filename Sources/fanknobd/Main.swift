// Main.swift — privileged fan-control daemon (fanknobd).
//
// Runs as root under launchd. Everything the unprivileged CLI and app can ask
// for arrives on a Unix socket as one of a handful of validated commands, so
// even though any local user can connect, the daemon can't be driven to do
// anything but move fans.
//
// Beyond one-shot speeds it owns three things that need to live in a
// long-running root process:
//   * curves — re-evaluated every couple of seconds against CPU temperature,
//   * the thermal watchdog — hands the fans back to the firmware if things get
//     genuinely hot while a user override is active,
//   * persistence — the active mode is restored after a reboot.

import Foundation
import Darwin
import Dispatch
import FanknobCore

func log(_ s: String) {
    FileHandle.standardError.write("fanknobd: \(s)\n".data(using: .utf8)!)
}

/// All SMC access, timers and state live on this one serial queue.
let smcQueue = DispatchQueue(label: "com.fanknob.smc")

/// How often the curve/watchdog loop runs.
let tickSeconds = 2

final class Controller {
    private let smc: SMC
    private let tempKeys: [UInt32]

    private var config: DaemonConfig
    private var lastApplied: [Int: Double] = [:]
    private var smoothed: Double?
    private var watchdogTripped = false
    private var pendingRevert: DispatchWorkItem?
    private var holdDeadline: Date?

    init(smc: SMC) {
        self.smc = smc
        // Prefer the CPU cluster: it's the meaningful signal and a fraction of
        // the sensors, so each tick stays cheap.
        let all = discoverTempKeys(smc)
        let cpu = all.filter { fourCCString($0).hasPrefix("Tp") }
        tempKeys = cpu.isEmpty ? all : cpu
        config = DaemonConfig.load() ?? DaemonConfig()
    }

    // MARK: Lifecycle

    func start() {
        let wd = config.watchdogCelsius.map { "\(Int($0))°C" } ?? "off"
        log("state: mode=\(config.mode.name) watchdog=\(wd) sensors=\(tempKeys.count)")
        restorePersistedMode()
    }

    /// Re-apply whatever was active before the last shutdown.
    private func restorePersistedMode() {
        switch config.mode {
        case .auto:
            break   // the firmware already has the fans after boot
        case .manual(let knobs):
            for k in knobs where apply(k.pct, fan: k.index, force: true) { }
            log("restored manual setpoints")
        case .curve(let curve, let preset):
            log("restored curve: \(preset?.rawValue ?? "custom")")
            applyCurve(curve, force: true)
        }
    }

    // MARK: Sensing

    /// Smoothed CPU-cluster temperature. Individual sensors spike constantly,
    /// so an exponential moving average keeps curves from chasing noise.
    private func currentTemp() -> Double? {
        let sensors = readTempsCached(smc, tempKeys)
        guard !sensors.isEmpty else { return nil }
        let avg = sensors.reduce(0) { $0 + $1.celsius } / Double(sensors.count)
        smoothed = smoothed.map { $0 * 0.7 + avg * 0.3 } ?? avg
        return smoothed
    }

    private var fanIndices: [Int] { Array(0..<fanCount(smc)) }

    /// Write one fan. Curve ticks use a deadband so small drifts don't cause
    /// audible hunting; explicit user commands force the write.
    @discardableResult
    private func apply(_ pct: Double, fan: Int, force: Bool = false) -> Bool {
        if !force, let last = lastApplied[fan], abs(last - pct) < 2 { return true }
        guard (try? setFanKnob(smc, fan, pct: pct)) != nil else { return false }
        lastApplied[fan] = pct
        return true
    }

    private func applyCurve(_ curve: FanCurve, force: Bool = false) {
        guard let temp = currentTemp() else { return }
        let target = curve.knob(at: temp)
        for i in fanIndices { apply(target, fan: i, force: force) }
    }

    private func applyAuto() {
        for i in fanIndices { try? setFanAuto(smc, i) }
        lastApplied.removeAll()
    }

    private func cancelHold() {
        pendingRevert?.cancel()
        pendingRevert = nil
        holdDeadline = nil
    }

    private func scheduleRevert(_ seconds: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.config.mode = .auto
            self.applyAuto()
            self.config.save()
            self.holdDeadline = nil
            log("hold expired after \(seconds)s — back to automatic control")
        }
        pendingRevert = work
        holdDeadline = Date().addingTimeInterval(Double(seconds))
        smcQueue.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    // MARK: The loop

    func tick() {
        guard let temp = currentTemp() else { return }

        // Thermal watchdog: while the user is overriding, hand control back to
        // the firmware if it gets genuinely hot. Deliberately sticky — it
        // stays in auto until the user asks for something new, rather than
        // flapping in and out of an override that isn't keeping up.
        if let limit = config.watchdogCelsius, temp >= limit, config.mode.name != "auto" {
            log(String(format: "watchdog: %.0f°C >= %.0f°C — returning fans to the firmware",
                       temp, limit))
            cancelHold()
            config.mode = .auto
            watchdogTripped = true
            applyAuto()
            config.save()
            return
        }

        if case .curve(let curve, _) = config.mode {
            applyCurve(curve)
        }
    }

    // MARK: Commands (called on smcQueue)

    func handle(_ line: String) -> String {
        switch parseDaemonCommand(line) {
        case .failure(.empty):
            return "empty command"
        case .failure(.badSet):
            return "usage: set <0-100> [seconds]"
        case .failure(.badFan):
            return "usage: setfan <index> <0-100> [seconds]"
        case .failure(.badCurve):
            return "usage: curve <°C>:<%>,<°C>:<%>[,...]  |  preset quiet|balanced|turbo"
        case .failure(.badWatchdog):
            return "usage: watchdog <°C>|off"
        case .failure(.unknown(let verb)):
            return "unknown command: \(verb)"

        case .success(.state):
            return currentState().encoded()

        case .success(.auto):
            cancelHold()
            watchdogTripped = false
            config.mode = .auto
            applyAuto()
            config.save()
            return "auto: returned to automatic control"

        case .success(.set(let pct, let seconds)):
            return setManual(pct: pct, fans: fanIndices, seconds: seconds)

        case .success(.setFan(let index, let pct, let seconds)):
            guard fanIndices.contains(index) else { return "no fan \(index)" }
            return setManual(pct: pct, fans: [index], seconds: seconds)

        case .success(.curve(let curve, let preset)):
            cancelHold()
            watchdogTripped = false
            config.mode = .curve(curve, preset: preset)
            config.save()
            applyCurve(curve, force: true)
            let now = smoothed.map { String(format: " (%.0f°C → %.0f%%)", $0, curve.knob(at: $0)) } ?? ""
            return "curve: \(preset?.label ?? "custom") \(curve.wireFormat)\(now)"

        case .success(.watchdog(let celsius)):
            config.watchdogCelsius = celsius
            config.save()
            return celsius.map { "watchdog: \(Int($0))°C" } ?? "watchdog: off"
        }
    }

    private func setManual(pct: Double, fans: [Int], seconds: Int) -> String {
        cancelHold()
        watchdogTripped = false

        // Carry existing setpoints forward so `setfan` only moves one fan —
        // including fans a curve was driving a moment ago.
        var setpoints: [Int: Double] = [:]
        switch config.mode {
        case .manual(let knobs): for k in knobs { setpoints[k.index] = k.pct }
        case .curve, .auto: for (i, v) in lastApplied { setpoints[i] = v }
        }
        for i in fans { setpoints[i] = pct }
        config.mode = .manual(setpoints
            .map { FanKnob(index: $0.key, pct: $0.value) }
            .sorted { $0.index < $1.index })

        var lines: [String] = []
        for i in fans {
            if apply(pct, fan: i, force: true), let f = readFan(smc, i) {
                lines.append(String(format: "fan %d -> %.0f rpm (knob %d%%)", i, f.target, Int(pct)))
            } else {
                lines.append("fan \(i): write failed")
            }
        }
        if seconds > 0 {
            scheduleRevert(seconds)
            lines.append("holding \(Int(pct))% for \(seconds)s, then auto-revert")
        }
        config.save()
        return lines.joined(separator: "\n")
    }

    private func currentState() -> DaemonState {
        var state = DaemonState(mode: config.mode.name)
        switch config.mode {
        case .auto:
            break
        case .manual(let knobs):
            state.knob = knobs.first?.pct
        case .curve(let curve, let preset):
            state.preset = preset?.rawValue
            state.curve = curve.wireFormat
            state.knob = smoothed.map { curve.knob(at: $0) }
        }
        state.watchdogCelsius = config.watchdogCelsius
        state.watchdogTripped = watchdogTripped
        state.holdRemaining = holdDeadline.map { max(0, Int($0.timeIntervalSinceNow.rounded())) } ?? 0
        return state
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

        let controller = Controller(smc: smc)
        smcQueue.sync { controller.start() }

        let timer = DispatchSource.makeTimerSource(queue: smcQueue)
        timer.schedule(deadline: .now() + .seconds(tickSeconds),
                       repeating: .seconds(tickSeconds))
        timer.setEventHandler { controller.tick() }
        timer.resume()

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

            var buf = [UInt8](repeating: 0, count: 512)
            let n = recv(clientFD, &buf, buf.count, 0)
            if n > 0 {
                let raw = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
                let line = raw.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
                    .first.map(String.init) ?? ""
                let reply = smcQueue.sync { controller.handle(line) } + "\n"
                if line != "state" { log("cmd '\(line)'") }   // don't spam on polls
                _ = reply.withCString { send(clientFD, $0, strlen($0), 0) }
            }
            Darwin.close(clientFD)
        }
    }
}
