// DaemonEngine.swift — testable safety and state machine for fanknobd.
//
// Hardware, wall-clock time, persistence location and logging are injected so
// watchdog, hold, sensor-failure and write-failure behavior can be exercised
// without root privileges or an Apple SMC.

import Foundation

public struct ThermalSample: Equatable, Sendable {
    public let average: Double
    public let hottest: Double

    public init?(temperatures: [Double]) {
        self.init(averageTemperatures: temperatures,
                  safetyTemperatures: temperatures)
    }

    public init?(averageTemperatures: [Double],
                 safetyTemperatures: [Double]) {
        let averageValues = averageTemperatures.filter {
            $0.isFinite && $0 > 1 && $0 < 130
        }
        let safetyValues = safetyTemperatures.filter {
            $0.isFinite && $0 > 1 && $0 < 130
        }
        guard !averageValues.isEmpty, let hottest = safetyValues.max() else {
            return nil
        }
        self.average = averageValues.reduce(0, +) / Double(averageValues.count)
        self.hottest = hottest
    }
}

public protocol FanHardware: AnyObject {
    var fanIndices: [Int] { get }
    func thermalSample() -> ThermalSample?
    func setFan(_ index: Int, percent: Double) throws -> Double
    func setAutomatic(_ index: Int) throws
}

/// Production adapter around the low-level SMC implementation.
public final class SMCFanHardware: FanHardware {
    private let smc: SMC
    private let tempKeys: [UInt32]

    public init(smc: SMC) {
        self.smc = smc
        tempKeys = discoverTempKeys(smc)
    }

    public var fanIndices: [Int] { Array(0..<fanCount(smc)) }

    public func thermalSample() -> ThermalSample? {
        // Read every discovered key once. Curves retain the stable CPU-cluster
        // average; the watchdog sees the hottest CPU or GPU die probe.
        //
        // The safety set is deliberately NOT "every T* key": some SMC keys
        // under the T prefix aren't die thermals and sit above the watchdog
        // default chronically (measured: Tf06 ≈ 104 °C on an idle-ish M-series
        // machine) — feeding those to the watchdog cancels every override two
        // ticks after it's applied. The default limit is calibrated for die
        // temperatures, so die probes are what it compares against.
        let sensors = readTempsCached(smc, tempKeys)
        let all = sensors.map(\.celsius)
        let cpu = sensors.filter { $0.key.hasPrefix("Tp") }.map(\.celsius)
        let gpu = sensors.filter { $0.key.hasPrefix("Tg") }.map(\.celsius)
        let dies = cpu + gpu
        return ThermalSample(
            averageTemperatures: cpu.isEmpty ? all : cpu,
            safetyTemperatures: dies.isEmpty ? all : dies
        )
    }

    public func setFan(_ index: Int, percent: Double) throws -> Double {
        try setFanKnob(smc, index, pct: percent)
    }

    public func setAutomatic(_ index: Int) throws {
        try setFanAuto(smc, index)
    }
}

/// The daemon confines every call to one serial queue. `@unchecked Sendable`
/// records that external synchronization contract for the socket worker
/// closures without pretending the mutable engine is internally concurrent.
public final class DaemonEngine: @unchecked Sendable {
    public static let sensorFailureLimit = 3
    /// Consecutive over-limit samples before the watchdog fires. The trigger is
    /// the raw hottest sensor anywhere in the machine, and a single board or
    /// core probe can burst past the limit for one 2 s sample under load — one
    /// spike must not cancel and persist away the user's mode.
    public static let watchdogStrikeLimit = 2
    /// Headroom required before the watchdog stands down. Forcing 100% is what
    /// brings the temperature back, so without a margin the fans would drop the
    /// instant it dipped under the limit and trip again moments later.
    public static let watchdogReleaseMargin = 5.0

    private let hardware: FanHardware
    private let configPath: String
    private let now: () -> Date
    private let logger: (String) -> Void

    private var config: DaemonConfig
    private var lastApplied: [Int: Double] = [:]
    private var smoothed: Double?
    private var hottest: Double?
    private var consecutiveSensorFailures = 0
    private var watchdogStrikes = 0
    /// Consecutive samples with real headroom, counted only while holding
    /// maximum. See `watchdogReleaseMargin`.
    private var watchdogCoolStrikes = 0
    /// Driving every fan flat out because the watchdog limit was crossed.
    /// Cleared once the temperature comes back under the limit.
    private var watchdogCoolingActive = false
    /// Fans that could not be forced to maximum on the latest attempt. Those
    /// fans are handed to the firmware individually while the others remain at
    /// maximum, and every tick retries the failed write.
    private var watchdogMaximumFailures: Set<Int> = []
    private var watchdogTripReason: String?
    private var watchdogTripped = false
    private var safetyReason: String?
    private var automaticRetryPending = false

    public init(hardware: FanHardware,
                configPath: String = DaemonConfig.path,
                now: @escaping () -> Date = Date.init,
                logger: @escaping (String) -> Void = { _ in }) {
        self.hardware = hardware
        self.configPath = configPath
        self.now = now
        self.logger = logger
        self.config = DaemonConfig.load(from: configPath, logger: logger)
            ?? DaemonConfig()
    }

    // MARK: Lifecycle

    public func start() {
        let wd = config.watchdogCelsius.map { "\(Int($0))°C" } ?? "off"
        logger("state: mode=\(config.mode.name) watchdog=\(wd)")

        if let deadline = config.revertAt {
            guard case .manual = config.mode, deadline > now() else {
                transitionToAutomatic(reason: "expired hold found at startup",
                                      watchdog: false)
                return
            }
        }

        let startupSample = config.mode.name == "auto" ? nil : sampleTemperatures()
        if let sample = startupSample, let limit = config.watchdogCelsius,
           sample.raw.hottest >= limit {
            // A restart loses the in-memory strike counter. Applying a persisted
            // low setpoint before rebuilding two strikes would create a cooling
            // gap at the worst possible time, so a hot startup clamps
            // immediately. A false positive is noisy, but safely noisy.
            beginWatchdogCooling(hottest: sample.raw.hottest, limit: limit)
            return
        }

        switch config.mode {
        case .auto:
            automaticRetryPending = !applyAutomatic()
            if automaticRetryPending {
                logger("could not confirm automatic control at startup; will retry")
            }
        case .manual(let knobs):
            guard restoreManualMode(knobs) else {
                transitionToAutomatic(reason: "could not restore manual setpoints",
                                      watchdog: false)
                return
            }
            logger("restored manual setpoints: "
                   + knobs.map { "fan \($0.index) \(Int($0.pct))%" }
                       .joined(separator: ", "))
        case .curve(let curve, let preset):
            // Say what actually happened. Sensors can be unreadable this early
            // after a hard power-off — the tick picks the curve up a moment
            // later — but claiming a restore that never applied is worst
            // exactly when someone is reading the log to explain a boot.
            let name = preset?.rawValue ?? "custom"
            if let sample = startupSample {
                _ = applyCurve(curve, temperature: sample.smoothed, force: true)
                logger("restored curve: \(name)")
            } else {
                logger("curve \(name) is active but no temperature was readable"
                       + " at startup; applying on the next check")
            }
        }
    }

    /// Return hardware ownership without changing persisted intent. If launchd
    /// restarts us, the mode (and any unexpired hold) is restored.
    public func shutdown() {
        _ = applyAutomatic()
        logger("returned the fans to the firmware")
    }

    /// Forget an episode entirely.
    ///
    /// The active clamp has to be cleared everywhere the strike counters are;
    /// otherwise a later mode can inherit stale safety state.
    private func clearWatchdogEpisode() {
        watchdogStrikes = 0
        watchdogCoolStrikes = 0
        watchdogCoolingActive = false
        watchdogMaximumFailures.removeAll()
        watchdogTripReason = nil
    }

    // MARK: Periodic safety loop

    public func tick() {
        // Sample in EVERY mode, including auto. The curve EMA and `hottest`
        // must stay fresh while the daemon idles in auto, or the first curve
        // application after re-entry blends against minutes-old heat and
        // `state` reports a stale hottestCelsius indefinitely.
        let sample = sampleTemperatures()
        let holdExpired = config.revertAt.map { now() >= $0 } ?? false

        guard config.mode.name != "auto" else {
            if automaticRetryPending {
                automaticRetryPending = !applyAutomatic()
                if !automaticRetryPending {
                    logger("automatic control restored after retry")
                }
            }
            consecutiveSensorFailures = 0
            clearWatchdogEpisode()
            return
        }

        // Once maximum cooling is active, absence of a temperature reading is
        // not evidence that the machine cooled. Keep the clamp in place and
        // retry failed fan writes. Likewise, an automatic hold expiry records
        // that Auto is next, but cannot lower cooling until recovery. An
        // explicit `auto` command remains the user's immediate escape hatch.
        if watchdogCoolingActive {
            if let sample {
                consecutiveSensorFailures = 0
                if let limit = config.watchdogCelsius {
                    if sample.raw.hottest <= limit - Self.watchdogReleaseMargin {
                        watchdogCoolStrikes += 1
                    } else {
                        watchdogCoolStrikes = 0
                    }

                    if watchdogCoolStrikes >= Self.watchdogStrikeLimit {
                        if holdExpired {
                            logger("watchdog: cool enough to finish the expired hold")
                            transitionToAutomatic(reason: "hold expired",
                                                  watchdog: false)
                            return
                        }
                        guard restoreSelectedMode(using: sample) else {
                            transitionToAutomatic(reason: "could not restore selected mode after watchdog cooling",
                                                  watchdog: false)
                            return
                        }
                        watchdogTripped = false
                        clearWatchdogEpisode()
                        safetyReason = nil
                        logger("watchdog: back under the limit — resuming the selected mode")
                        return
                    }
                } else {
                    // Defensive path for a setting change racing an older
                    // client. The command handler normally restores immediately.
                    guard restoreSelectedMode(using: sample) else {
                        transitionToAutomatic(reason: "could not restore selected mode after disabling watchdog",
                                              watchdog: false)
                        return
                    }
                    watchdogTripped = false
                    clearWatchdogEpisode()
                    safetyReason = nil
                    return
                }
            } else {
                consecutiveSensorFailures += 1
                // Recovery requires consecutive readable samples with real
                // headroom. A missing sample breaks that sequence even though
                // it must not release the active maximum-cooling clamp.
                watchdogCoolStrikes = 0
            }
            _ = enforceMaximumCooling()
            return
        }

        if holdExpired {
            transitionToAutomatic(reason: "hold expired", watchdog: false)
            return
        }

        guard let sample else {
            consecutiveSensorFailures += 1
            if consecutiveSensorFailures >= Self.sensorFailureLimit {
                transitionToAutomatic(
                    reason: "temperature sensors unavailable for \(consecutiveSensorFailures) checks",
                    watchdog: false
                )
            }
            return
        }
        consecutiveSensorFailures = 0

        // Curves use the stable average; the safety boundary uses the raw
        // hottest sensor so smoothing or a cool neighboring probe cannot hide
        // a genuine hotspot. Debounced (watchdogStrikeLimit) so a single-sample
        // probe spike doesn't cancel the user's mode; while a strike is
        // pending, the curve below keeps responding to the heat.
        if let limit = config.watchdogCelsius, sample.raw.hottest >= limit {
            watchdogStrikes += 1
            if watchdogStrikes >= Self.watchdogStrikeLimit {
                beginWatchdogCooling(hottest: sample.raw.hottest, limit: limit)
                return
            }
        } else {
            watchdogStrikes = 0
        }

        if case .curve(let curve, _) = config.mode,
           !applyCurve(curve, temperature: sample.smoothed) {
            transitionToAutomatic(reason: "curve fan write failed", watchdog: false)
        }
    }

    // MARK: Commands

    public func handle(_ line: String) -> DaemonReply {
        switch parseDaemonCommand(line) {
        case .failure(let error):
            return .init(ok: false, message: usage(for: error))

        case .success(.state):
            return .init(ok: true, message: "state", state: currentState())

        case .success(.auto):
            watchdogTripped = false
            clearWatchdogEpisode()
            safetyReason = nil
            config.mode = .auto
            config.revertAt = nil
            let automatic = applyAutomatic()
            automaticRetryPending = !automatic
            let saved = saveConfig()
            guard automatic else {
                return .init(ok: false, message: "failed to return one or more fans to automatic control")
            }
            guard saved else {
                return .init(ok: false, message: "automatic control restored, but settings could not be saved")
            }
            return .init(ok: true, message: "auto: returned to automatic control")

        case .success(.set(let pct, let seconds)):
            return setManual(percent: pct, fans: hardware.fanIndices,
                             holdSeconds: seconds)

        case .success(.setFan(let index, let pct, let seconds)):
            guard hardware.fanIndices.contains(index) else {
                return .init(ok: false, message: "no fan \(index)")
            }
            return setManual(percent: pct, fans: [index], holdSeconds: seconds)

        case .success(.curve(let curve, let preset)):
            let previousMode = config.mode
            let previousDeadline = config.revertAt
            config.mode = .curve(curve, preset: preset)
            config.revertAt = nil

            if watchdogCoolingActive {
                // Change the desired mode without lowering the effective
                // output. Recovery will force-apply this curve.
                let previousLastApplied = lastApplied
                if let target = smoothed.map({ curve.knob(at: $0) }) {
                    for index in hardware.fanIndices { lastApplied[index] = target }
                }
                guard saveConfig() else {
                    config.mode = previousMode
                    config.revertAt = previousDeadline
                    lastApplied = previousLastApplied
                    return .init(ok: false, message: "curve settings could not be saved")
                }
                let target = smoothed.map { curve.knob(at: $0) }
                let suffix = target.map { String(format: " (will resume at %.0f%%)", $0) }
                    ?? " (will resume after cooling)"
                return .init(ok: true, message:
                    "curve: \(preset?.label ?? "custom") \(curve.wireFormat)\(suffix)")
            }

            watchdogTripped = false
            clearWatchdogEpisode()
            safetyReason = nil
            guard let sample = sampleTemperatures() else {
                // Through transitionToAutomatic, not an inline revert: if the
                // hand-back write fails too, only the transition path arms the
                // retry flag and surfaces a safetyReason.
                transitionToAutomatic(reason: "temperature sensors unavailable; curve not applied",
                                      watchdog: false)
                return .init(ok: false, message: "temperature sensors unavailable; staying in automatic control")
            }
            guard applyCurve(curve, temperature: sample.smoothed, force: true) else {
                transitionToAutomatic(reason: "could not apply curve", watchdog: false)
                return .init(ok: false, message: "could not apply curve; returned to automatic control")
            }
            guard saveConfig() else {
                transitionToAutomatic(reason: "curve settings could not be saved",
                                      watchdog: false)
                return .init(ok: false, message:
                    "curve settings could not be saved; returned to automatic control")
            }
            let suffix = String(format: " (%.0f°C → %.0f%%)",
                                sample.smoothed, curve.knob(at: sample.smoothed))
            return .init(ok: true, message:
                "curve: \(preset?.label ?? "custom") \(curve.wireFormat)\(suffix)")

        case .success(.watchdog(let celsius)):
            let previous = config.watchdogCelsius
            config.watchdogCelsius = celsius
            guard saveConfig() else {
                config.watchdogCelsius = previous
                return .init(ok: false, message: "watchdog setting could not be saved")
            }

            // A threshold change starts a fresh debounce window. Disabling the
            // watchdog is explicit permission to remove an active clamp, so
            // restore the selected mode immediately (or fail safely to Auto).
            watchdogStrikes = 0
            watchdogCoolStrikes = 0
            if celsius == nil, watchdogCoolingActive {
                let sample = sampleTemperatures()
                guard restoreSelectedMode(using: sample) else {
                    transitionToAutomatic(reason: "could not restore selected mode after disabling watchdog",
                                          watchdog: false)
                    return .init(ok: false, message:
                        "watchdog disabled, but the selected mode could not be restored; returned to automatic control")
                }
                watchdogTripped = false
                clearWatchdogEpisode()
                safetyReason = nil
            }
            return .init(ok: true, message:
                celsius.map { "watchdog: \(Int($0))°C" } ?? "watchdog: off")
        }
    }

    public func currentState() -> DaemonState {
        var state = DaemonState(mode: config.mode.name,
                                daemonVersion: fanknobVersion)
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
        state.coolingAtMaximum = watchdogCoolingActive && watchdogMaximumFailures.isEmpty
        state.holdRemaining = config.revertAt.map {
            max(0, Int($0.timeIntervalSince(now()).rounded()))
        } ?? 0
        state.hottestCelsius = hottest
        state.sensorFailures = consecutiveSensorFailures
        state.safetyReason = safetyReason
        return state
    }

    // MARK: Internals

    private func usage(for error: DaemonCommandError) -> String {
        switch error {
        case .empty: return "empty command"
        case .badSet:
            return "usage: set <0-100> [seconds, max \(maximumHoldSeconds)]"
        case .badFan:
            return "usage: setfan <index> <0-100> [seconds, max \(maximumHoldSeconds)]"
        case .badCurve:
            return "usage: curve <°C>:<%>,<°C>:<%>[,...] | preset quiet|balanced|turbo"
        case .badWatchdog: return "usage: watchdog <°C>|off"
        case .unknown(let verb): return "unknown or malformed command: \(verb)"
        }
    }

    private func setManual(percent: Double, fans: [Int],
                           holdSeconds: Int) -> DaemonReply {
        // With no controllable fans (FNum unreadable) there is nothing to
        // write; persisting .manual([]) would report "manual" forever while
        // controlling nothing.
        guard !fans.isEmpty else {
            return .init(ok: false, message: "no fans detected; nothing to set")
        }
        let watchdogActive = watchdogCoolingActive
        if !watchdogActive {
            watchdogTripped = false
            clearWatchdogEpisode()
            safetyReason = nil
        }

        var setpoints: [Int: Double] = [:]
        switch config.mode {
        case .manual(let knobs):
            for knob in knobs { setpoints[knob.index] = knob.pct }
        case .curve, .auto:
            for (index, value) in lastApplied { setpoints[index] = value }
        }
        for index in fans { setpoints[index] = percent }
        let knobs = setpoints.map { FanKnob(index: $0.key, pct: $0.value) }
            .sorted { $0.index < $1.index }

        let previousMode = config.mode
        let previousDeadline = config.revertAt
        let previousLastApplied = lastApplied
        config.mode = .manual(knobs)
        config.revertAt = holdSeconds > 0
            ? now().addingTimeInterval(Double(holdSeconds))
            : nil

        if watchdogActive {
            // Preserve the watchdog's effective 100% output. These values are
            // desired intent only and will be applied after recovery.
            for index in fans { lastApplied[index] = percent }
            guard saveConfig() else {
                config.mode = previousMode
                config.revertAt = previousDeadline
                lastApplied = previousLastApplied
                return .init(ok: false, message: "manual settings could not be saved")
            }
            var message = "requested \(Int(percent))%; watchdog is holding maximum cooling"
            if holdSeconds > 0 {
                message += " for up to \(holdSeconds)s, then automatic control"
            }
            return .init(ok: true, message: message)
        }

        var lines: [String] = []
        for index in fans {
            do {
                let rpm = try hardware.setFan(index, percent: percent)
                lastApplied[index] = percent
                lines.append(String(format: "fan %d -> %.0f rpm (knob %d%%)",
                                    index, rpm, Int(percent)))
            } catch {
                // transitionToAutomatic rather than an inline revert: a
                // transient IOKit error can fail the hand-back write too, and
                // only the transition path arms automaticRetryPending — an
                // inline revert would leave already-written fans pinned while
                // reporting "auto" with no retry and no safetyReason.
                transitionToAutomatic(reason: "fan \(index) write failed",
                                      watchdog: false)
                return .init(ok: false, message:
                    "fan \(index) write failed; returned all fans to automatic control")
            }
        }

        if holdSeconds > 0 {
            lines.append("holding \(Int(percent))% for \(holdSeconds)s, then auto-revert")
        }
        guard saveConfig() else {
            transitionToAutomatic(reason: "manual settings could not be saved",
                                  watchdog: false)
            return .init(ok: false, message:
                "manual settings could not be saved; returned to automatic control")
        }
        return .init(ok: true, message: lines.joined(separator: "\n"))
    }

    private func sampleTemperatures() -> (raw: ThermalSample, smoothed: Double)? {
        guard let raw = hardware.thermalSample() else {
            return nil
        }
        smoothed = smoothed.map { $0 * 0.7 + raw.average * 0.3 } ?? raw.average
        hottest = raw.hottest
        return (raw, smoothed!)
    }

    /// Latch the safety override above the selected Manual/Curve intent.
    private func beginWatchdogCooling(hottest: Double, limit: Double) {
        watchdogCoolingActive = true
        watchdogTripped = true
        watchdogStrikes = 0
        watchdogCoolStrikes = 0
        watchdogTripReason = String(format: "watchdog: hottest %.0f°C >= %.0f°C",
                                    hottest, limit)
        safetyReason = watchdogTripReason
        logger(String(format: "watchdog: hottest %.0f°C >= %.0f°C — forcing maximum cooling",
                      hottest, limit))
        _ = enforceMaximumCooling()
    }

    /// Best-effort maximum cooling. A fan whose manual write fails is handed to
    /// the firmware individually; successfully written fans remain at maximum.
    /// The next tick retries every fan, so a transient SMC failure self-heals.
    @discardableResult
    private func enforceMaximumCooling() -> Bool {
        let previousFailures = watchdogMaximumFailures
        var failures: Set<Int> = []
        for index in hardware.fanIndices {
            do {
                _ = try hardware.setFan(index, percent: 100)
            } catch {
                failures.insert(index)
                do { try hardware.setAutomatic(index) }
                catch { logger("watchdog: fan \(index) could not be set to maximum or automatic control") }
            }
        }
        watchdogMaximumFailures = failures
        if failures.isEmpty {
            safetyReason = watchdogTripReason
            if !previousFailures.isEmpty {
                logger("watchdog: maximum cooling restored on every fan")
            }
        } else {
            let fanList = failures.sorted().map(String.init).joined(separator: ", ")
            safetyReason = "watchdog degraded: could not force fan \(fanList) to maximum"
            if failures != previousFailures {
                logger("watchdog: maximum write failed for fan \(fanList); using firmware control for affected fan(s) and retrying")
            }
        }
        return failures.isEmpty
    }

    /// Force-apply the selected intent after the watchdog releases. Curves must
    /// bypass their deadband because the physical fans are currently at 100%
    /// while `lastApplied` deliberately remembers the desired curve output.
    private func restoreSelectedMode(using sample: (raw: ThermalSample, smoothed: Double)?) -> Bool {
        switch config.mode {
        case .auto:
            return applyAutomatic()
        case .manual(let knobs):
            return restoreManualMode(knobs)
        case .curve(let curve, _):
            guard let sample else { return false }
            return applyCurve(curve, temperature: sample.smoothed, force: true)
        }
    }

    private func applyCurve(_ curve: FanCurve, temperature: Double,
                            force: Bool = false) -> Bool {
        let target = curve.knob(at: temperature)
        var success = true
        for index in hardware.fanIndices {
            if !force, let last = lastApplied[index], abs(last - target) < 2 {
                continue
            }
            do {
                _ = try hardware.setFan(index, percent: target)
                lastApplied[index] = target
            } catch {
                success = false
            }
        }
        return success
    }

    private func applySetpoints(_ knobs: [FanKnob]) -> Bool {
        var success = true
        for knob in knobs {
            guard hardware.fanIndices.contains(knob.index) else {
                success = false
                continue
            }
            do {
                _ = try hardware.setFan(knob.index, percent: knob.pct)
                lastApplied[knob.index] = knob.pct
            } catch {
                success = false
            }
        }
        return success
    }

    /// Restore a possibly per-fan manual mode after maximum cooling. Fans not
    /// represented in the persisted knob list belong to the firmware; they may
    /// currently be at the watchdog's manual 100%, so explicitly release them.
    private func restoreManualMode(_ knobs: [FanKnob]) -> Bool {
        var success = applySetpoints(knobs)
        let controlled = Set(knobs.map(\.index))
        for index in hardware.fanIndices where !controlled.contains(index) {
            do {
                try hardware.setAutomatic(index)
                lastApplied.removeValue(forKey: index)
            } catch {
                success = false
            }
        }
        return success
    }

    @discardableResult
    private func applyAutomatic() -> Bool {
        var success = true
        for index in hardware.fanIndices {
            do { try hardware.setAutomatic(index) }
            catch { success = false }
        }
        lastApplied.removeAll()
        return success
    }

    private func transitionToAutomatic(reason: String, watchdog: Bool) {
        logger("\(reason) — returning fans to the firmware")
        config.mode = .auto
        config.revertAt = nil
        watchdogTripped = watchdog
        clearWatchdogEpisode()
        safetyReason = reason
        automaticRetryPending = !applyAutomatic()
        if automaticRetryPending {
            logger("one or more automatic-control writes failed; will retry")
        }
        _ = saveConfig()
    }

    private func saveConfig() -> Bool {
        config.save(to: configPath)
    }
}
