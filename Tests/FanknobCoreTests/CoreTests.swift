// CoreTests.swift — unit tests for the pure logic in FanknobCore.
//
// Everything here runs without SMC hardware, root, or the daemon: codecs,
// knob math, temperature clustering, and the daemon protocol parser.

import Testing
import Foundation
@testable import FanknobCore

// MARK: - FourCC

@Suite struct FourCCTests {
    @Test func roundtrip() {
        for name in ["FNum", "F0Ac", "TC0P", "#KEY", "flt ", "ui8 "] {
            #expect(fourCCString(fourCC(name)) == name)
        }
    }

    @Test func knownValue() {
        // 'FNum' = 0x464E756D
        #expect(fourCC("FNum") == 0x464E_756D)
    }
}

// MARK: - Value decoding

@Suite struct DecodeTests {
    @Test func flt() {
        var f = Float32(1.5)
        let bytes = withUnsafeBytes(of: &f) { Array($0) }
        #expect(decodeToDouble(type: fourCC("flt "), bytes: bytes) == 1.5)
    }

    @Test func fpe2() {
        // fpe2 is big-endian fixed point with 2 fraction bits: raw / 4.
        // 3000 rpm -> raw 12000 = 0x2EE0
        #expect(decodeToDouble(type: fourCC("fpe2"), bytes: [0x2E, 0xE0]) == 3000)
    }

    @Test func ui8() {
        #expect(decodeToDouble(type: fourCC("ui8 "), bytes: [7]) == 7)
    }

    @Test func ui16() {
        #expect(decodeToDouble(type: fourCC("ui16"), bytes: [0x0B, 0xB8]) == 3000)
    }

    @Test func ui32() {
        #expect(decodeToDouble(type: fourCC("ui32"), bytes: [0, 0, 0x0B, 0xB8]) == 3000)
    }

    @Test func truncatedBytesReturnNil() {
        #expect(decodeToDouble(type: fourCC("flt "), bytes: [1, 2]) == nil)
        #expect(decodeToDouble(type: fourCC("fpe2"), bytes: [1]) == nil)
        #expect(decodeToDouble(type: fourCC("ui16"), bytes: []) == nil)
        #expect(decodeToDouble(type: fourCC("ui32"), bytes: [1, 2, 3]) == nil)
        #expect(decodeToDouble(type: fourCC("ui8 "), bytes: []) == nil)
    }

    @Test func unknownTypeReturnsNil() {
        #expect(decodeToDouble(type: fourCC("ch8*"), bytes: [1, 2, 3, 4]) == nil)
    }
}

// MARK: - RPM encoding

@Suite struct EncodeTests {
    @Test func fltRoundtrips() {
        let bytes = encodeRPM(type: fourCC("flt "), value: 4200)
        #expect(decodeToDouble(type: fourCC("flt "), bytes: bytes) == 4200)
    }

    @Test func fpe2RoundtripsBigEndian() {
        let bytes = encodeRPM(type: fourCC("fpe2"), value: 3000)
        #expect(bytes == [0x2E, 0xE0])
        #expect(decodeToDouble(type: fourCC("fpe2"), bytes: bytes) == 3000)
    }
}

// MARK: - Knob math

@Suite struct KnobTests {
    private func fan(min: Double, max: Double, target: Double) -> Fan {
        Fan(index: 0, actual: target, min: min, max: max, target: target, managed: true)
    }

    @Test func midRange() {
        #expect(fan(min: 2000, max: 6000, target: 4000).knob == 50)
    }

    @Test func atMinAndMax() {
        #expect(fan(min: 2317, max: 6800, target: 2317).knob == 0)
        #expect(fan(min: 2317, max: 6800, target: 6800).knob == 100)
    }

    @Test func clampsOutOfRangeTargets() {
        #expect(fan(min: 2000, max: 6000, target: 1000).knob == 0)
        #expect(fan(min: 2000, max: 6000, target: 9000).knob == 100)
    }

    @Test func degenerateRangeIsZero() {
        // max == min must not divide by zero.
        #expect(fan(min: 3000, max: 3000, target: 3000).knob == 0)
    }

    @Test func clampedExtension() {
        #expect((150.0).clamped(0, 100) == 100)
        #expect((-3.0).clamped(0, 100) == 0)
        #expect((42.0).clamped(0, 100) == 42)
    }
}

// MARK: - Temperature clustering

@Suite struct TempReportTests {
    @Test func clusterAverages() {
        let sensors = [
            TempSensor(key: "Tp01", celsius: 100),
            TempSensor(key: "Tp02", celsius: 80),
            TempSensor(key: "Tg0D", celsius: 60),
            TempSensor(key: "TB0T", celsius: 40),
        ]
        let report = tempReport(from: sensors)
        #expect(report.cpu == 90)
        #expect(report.gpu == 60)
        #expect(report.overall == 70)
    }

    @Test func missingClustersAreNil() {
        let report = tempReport(from: [TempSensor(key: "TB0T", celsius: 40)])
        #expect(report.cpu == nil)
        #expect(report.gpu == nil)
        #expect(report.overall == 40)
    }

    @Test func emptyIsAllNil() {
        let report = tempReport(from: [])
        #expect(report.cpu == nil)
        #expect(report.gpu == nil)
        #expect(report.overall == nil)
    }

    @Test func partialClusterDoesNotProduceFalseLowAverage() {
        let expected = ["Tp01", "Tp02", "Tp03", "Tp04"].map(fourCC)

        let incomplete = tempReport(
            from: [TempSensor(key: "Tp01", celsius: 45)],
            expectedKeys: expected
        )
        #expect(incomplete.cpu == nil)

        let sufficient = tempReport(
            from: [
                TempSensor(key: "Tp01", celsius: 60),
                TempSensor(key: "Tp02", celsius: 62),
                TempSensor(key: "Tp03", celsius: 64),
            ],
            expectedKeys: expected
        )
        #expect(sufficient.cpu == 62)
    }

    @Test func implausiblyColdReadingsAreRejected() {
        #expect(!isPlausibleTemperature(6))
        #expect(isPlausibleTemperature(45))
        #expect(ThermalSample(temperatures: [6]) == nil)
        #expect(ThermalSample(temperatures: [6, 45])?.average == 45)
    }

    @Test func transientFailureRetainsLastReliableReading() {
        var latch = TemperatureReadingLatch()
        #expect(latch.update(65) == 65)
        #expect(latch.update(nil) == 65)
        #expect(latch.update(nil) == 65)
        #expect(latch.update(nil) == nil)
        #expect(latch.update(45) == 45)
    }

    @Test func omittedClusterIsNotReportedOrAged() {
        var latch = TemperatureReadingLatch()
        #expect(latch.reading(60, sampled: true) == 60)  // full poll

        // Light polls omit this cluster: do not expose 60 as current and do
        // not count the omissions as failures.
        for _ in 0..<5 {
            #expect(latch.reading(nil, sampled: false) == nil)
        }

        // The next full poll may bridge a real transient failure, proving the
        // omitted light polls did not age the retained value out.
        #expect(latch.reading(nil, sampled: true) == 60)
        #expect(latch.reading(62, sampled: true) == 62)
    }
}

// MARK: - Fan curves

@Suite struct FanCurveTests {
    private let curve = FanCurve([
        .init(celsius: 50, knob: 0),
        .init(celsius: 70, knob: 50),
        .init(celsius: 90, knob: 100),
    ])!

    @Test func flatOutsideEndpoints() {
        #expect(curve.knob(at: 20) == 0)
        #expect(curve.knob(at: 50) == 0)
        #expect(curve.knob(at: 90) == 100)
        #expect(curve.knob(at: 120) == 100)
    }

    @Test func interpolatesBetweenPoints() {
        #expect(curve.knob(at: 60) == 25)    // midpoint of 50→70 / 0→50
        #expect(curve.knob(at: 70) == 50)
        #expect(curve.knob(at: 80) == 75)
    }

    @Test func sortsUnorderedPoints() {
        let c = FanCurve([
            .init(celsius: 90, knob: 100),
            .init(celsius: 50, knob: 0),
        ])!
        #expect(c.points.first?.celsius == 50)
        #expect(c.knob(at: 70) == 50)
    }

    @Test func pointInitializerClampsKnobValues() {
        #expect(FanCurve.Point(celsius: 50, knob: -20).knob == 0)
        #expect(FanCurve.Point(celsius: 90, knob: 500).knob == 100)
    }

    @Test func needsAtLeastTwoPoints() {
        #expect(FanCurve([]) == nil)
        #expect(FanCurve([.init(celsius: 50, knob: 10)]) == nil)
    }

    @Test func parseRoundtrip() {
        let parsed = FanCurve.parse("55:0,72:20,85:60,93:100")
        #expect(parsed != nil)
        #expect(parsed?.wireFormat == "55:0,72:20,85:60,93:100")
        #expect(parsed?.knob(at: 72) == 20)
    }

    @Test func parseRejectsGarbage() {
        #expect(FanCurve.parse("") == nil)
        #expect(FanCurve.parse("hot:fast") == nil)
        #expect(FanCurve.parse("55:0") == nil)          // single point
        #expect(FanCurve.parse("55,72:20") == nil)      // missing knob
        #expect(FanCurve.parse("nan:0,72:20") == nil)
        #expect(FanCurve.parse("10:0,72:20") == nil)    // outside useful range
        #expect(FanCurve.parse("55:0,55:20") == nil)    // duplicate temperature
        #expect(FanCurve.parse("55:0,55.5:20") == nil)  // wire-safe 1 °C spacing
        #expect(FanCurve.parse("55:50,72:20") == nil)   // speed falls as heat rises
        #expect(FanCurve.parse("55:-1,72:20") == nil)
        #expect(FanCurve.parse("55:0,72:101") == nil)
    }

    @Test func presetsRiseWithTemperature() {
        for preset in CurvePreset.allCases {
            let c = preset.curve
            let knobs = c.points.map(\.knob)
            #expect(zip(knobs, knobs.dropFirst()).allSatisfy { $0 <= $1 },
                    "\(preset.rawValue) should never cool down as it heats up")
            #expect(c.knob(at: 100) == 100, "\(preset.rawValue) should reach full at high temps")
        }
    }
}

// MARK: - Version comparison

@Suite struct VersionComparisonTests {
    @Test func numericComponentComparison() {
        #expect(isVersion("1.4.4", newerThan: "1.4.3"))
        #expect(isVersion("1.5.0", newerThan: "1.4.9"))
        #expect(isVersion("2.0.0", newerThan: "1.9.9"))
        #expect(!isVersion("1.4.3", newerThan: "1.4.3"))
        #expect(!isVersion("1.4.2", newerThan: "1.4.3"))
    }

    @Test func numericNotLexicographic() {
        // "13" > "1.4.0" numerically; lexical comparison gets this wrong.
        #expect(isVersion("13", newerThan: "1.4.0"))
        #expect(isVersion("1.10.0", newerThan: "1.9.0"))
    }

    @Test func tagPrefixAndMissingComponents() {
        #expect(isVersion("v1.4.4", newerThan: "1.4.3"))
        #expect(isVersion("1.4.3.1", newerThan: "1.4.3"))
        #expect(!isVersion("v1.4", newerThan: "1.4.0"))
        #expect(!isVersion("garbage", newerThan: "1.4.3"))
    }
}

// MARK: - Config persistence

@Suite struct ConfigTests {
    private func roundtrip(_ config: DaemonConfig) -> DaemonConfig? {
        // Unique per call: Swift Testing runs these in parallel.
        let path = NSTemporaryDirectory() + "fanknob-config-\(UUID().uuidString).json"
        defer { unlink(path) }
        #expect(config.save(to: path))
        return DaemonConfig.load(from: path)
    }

    @Test func autoRoundtrips() {
        #expect(roundtrip(DaemonConfig(mode: .auto)) == DaemonConfig(mode: .auto))
    }

    @Test func manualRoundtrips() {
        let c = DaemonConfig(mode: .manual([FanKnob(index: 0, pct: 40),
                                            FanKnob(index: 1, pct: 55)]))
        #expect(roundtrip(c) == c)
    }

    @Test func curveRoundtripsWithPreset() {
        let c = DaemonConfig(mode: .curve(CurvePreset.quiet.curve, preset: .quiet),
                             watchdogCelsius: 90)
        #expect(roundtrip(c) == c)
    }

    @Test func missingFileLoadsNil() {
        #expect(DaemonConfig.load(from: "/nonexistent/fanknob.json") == nil)
    }

    // MARK: field-wise salvage (one bad field must not reset the others)

    private func scratchPath() -> String {
        NSTemporaryDirectory() + "fanknob-salvage-\(UUID().uuidString).json"
    }

    @Test func invalidPersistedCurveKeepsWatchdogAndFallsBackToAuto() throws {
        let path = scratchPath()
        defer { unlink(path) }
        #expect(DaemonConfig(mode: .curve(CurvePreset.quiet.curve, preset: .quiet),
                             watchdogCelsius: 90).save(to: path))
        // Corrupt the curve the way an older build's looser rules could have:
        // move the 55 °C point to 10 °C, outside today's supported range.
        let text = try String(contentsOfFile: path, encoding: .utf8)
            .replacingOccurrences(of: "55", with: "10")
        try text.write(toFile: path, atomically: true, encoding: .utf8)

        let loaded = DaemonConfig.load(from: path)
        #expect(loaded != nil)
        #expect(loaded?.mode == .auto)
        #expect(loaded?.watchdogCelsius == 90)   // the safety setting survives
    }

    @Test func outOfRangeWatchdogFallsBackToDefaultKeepingMode() {
        let path = scratchPath()
        defer { unlink(path) }
        let knobs = [FanKnob(index: 0, pct: 40)]
        #expect(DaemonConfig(mode: .manual(knobs), watchdogCelsius: 500).save(to: path))

        let loaded = DaemonConfig.load(from: path)
        #expect(loaded?.mode == .manual(knobs))
        #expect(loaded?.watchdogCelsius == DaemonConfig.defaultWatchdogCelsius)
    }

    @Test func explicitlyDisabledWatchdogSurvivesSalvage() throws {
        let path = scratchPath()
        defer { unlink(path) }
        #expect(DaemonConfig(mode: .curve(CurvePreset.quiet.curve, preset: .quiet),
                             watchdogCelsius: nil).save(to: path))
        let text = try String(contentsOfFile: path, encoding: .utf8)
            .replacingOccurrences(of: "55", with: "10")
        try text.write(toFile: path, atomically: true, encoding: .utf8)

        let loaded = DaemonConfig.load(from: path)
        #expect(loaded != nil)
        // "off" was a deliberate choice — salvage must not re-arm it at 95.
        #expect(loaded?.watchdogCelsius == Double?.none)
    }

    @Test func unreadableFileLoadsNil() throws {
        let path = scratchPath()
        defer { unlink(path) }
        try "not json at all".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(DaemonConfig.load(from: path) == nil)
    }

    @Test func stateWireFormatRoundtrips() {
        let s = DaemonState(mode: "curve", preset: "quiet", curve: "55:0,90:100",
                            knob: 42, watchdogCelsius: 95, watchdogTripped: true,
                            coolingAtMaximum: true,
                            holdRemaining: 30)
        #expect(DaemonState.decode(s.encoded()) == s)
    }
}

// MARK: - Daemon singleton lock

@Suite struct DaemonLockTests {
    @Test func secondAcquireFailsWhileHeldAndSucceedsAfterRelease() {
        let path = NSTemporaryDirectory() + "fanknob-lock-test-\(getpid())"
        defer { unlink(path) }

        let first = acquireDaemonLock(path: path)
        #expect(first != nil)

        // A second daemon must be refused while the first is alive...
        #expect(acquireDaemonLock(path: path) == nil)

        // ...and must succeed once the holder releases (or dies — flock
        // releases with the process), enabling automatic failover.
        if let fd = first { close(fd) }
        let successor = acquireDaemonLock(path: path)
        #expect(successor != nil)
        if let fd = successor { close(fd) }
    }

    @Test func unopenablePathReturnsNil() {
        #expect(acquireDaemonLock(path: "/nonexistent-dir/fanknob.lock") == nil)
    }
}

// MARK: - Daemon protocol

@Suite struct DaemonProtocolTests {
    @Test func auto() {
        #expect(parseDaemonCommand("auto") == .success(.auto))
    }

    @Test func plainSet() {
        #expect(parseDaemonCommand("set 40") == .success(.set(pct: 40, holdSeconds: 0)))
    }

    @Test func setWithHold() {
        #expect(parseDaemonCommand("set 60 120") == .success(.set(pct: 60, holdSeconds: 120)))
    }

    @Test func percentIsClamped() {
        #expect(parseDaemonCommand("set 150") == .success(.set(pct: 100, holdSeconds: 0)))
        #expect(parseDaemonCommand("set -5") == .success(.set(pct: 0, holdSeconds: 0)))
    }

    @Test func rejectsInvalidOrExcessiveHold() {
        #expect(parseDaemonCommand("set 40 -10") == .failure(.badSet))
        #expect(parseDaemonCommand("set 40 xyz") == .failure(.badSet))
        #expect(parseDaemonCommand("set 40 \(maximumHoldSeconds + 1)") == .failure(.badSet))
    }

    @Test func rejectsMalformedSet() {
        #expect(parseDaemonCommand("set") == .failure(.badSet))
        #expect(parseDaemonCommand("set abc") == .failure(.badSet))
        // NaN/inf must not reach the SMC as an RPM.
        #expect(parseDaemonCommand("set nan") == .failure(.badSet))
        #expect(parseDaemonCommand("set inf") == .failure(.badSet))
    }

    @Test func rejectsEmptyAndUnknown() {
        #expect(parseDaemonCommand("") == .failure(.empty))
        #expect(parseDaemonCommand("reboot") == .failure(.unknown("reboot")))
        #expect(parseDaemonCommand("auto now") == .failure(.unknown("auto")))
        #expect(parseDaemonCommand("state please") == .failure(.unknown("state")))
    }

    @Test func perFanCommands() {
        #expect(parseDaemonCommand("setfan 1 60") == .success(.setFan(index: 1, pct: 60, holdSeconds: 0)))
        #expect(parseDaemonCommand("setfan 0 60 30") == .success(.setFan(index: 0, pct: 60, holdSeconds: 30)))
        #expect(parseDaemonCommand("setfan 150") == .failure(.badFan))     // no pct
        #expect(parseDaemonCommand("setfan -1 60") == .failure(.badFan))
        #expect(parseDaemonCommand("setfan x 60") == .failure(.badFan))
    }

    @Test func presetCommand() {
        #expect(parseDaemonCommand("preset quiet") == .success(.curve(CurvePreset.quiet.curve, preset: .quiet)))
        #expect(parseDaemonCommand("preset TURBO") == .success(.curve(CurvePreset.turbo.curve, preset: .turbo)))
        #expect(parseDaemonCommand("preset silent") == .failure(.badCurve))
        #expect(parseDaemonCommand("preset") == .failure(.badCurve))
    }

    @Test func curveCommand() {
        let expected = FanCurve.parse("55:0,90:100")!
        #expect(parseDaemonCommand("curve 55:0,90:100") == .success(.curve(expected, preset: nil)))
        #expect(parseDaemonCommand("curve nonsense") == .failure(.badCurve))
        #expect(parseDaemonCommand("curve") == .failure(.badCurve))
    }

    @Test func watchdogCommand() {
        #expect(parseDaemonCommand("watchdog 95") == .success(.watchdog(celsius: 95)))
        #expect(parseDaemonCommand("watchdog off") == .success(.watchdog(celsius: nil)))
        #expect(parseDaemonCommand("watchdog 0") == .failure(.badWatchdog))
        #expect(parseDaemonCommand("watchdog 500") == .failure(.badWatchdog))
        #expect(parseDaemonCommand("watchdog") == .failure(.badWatchdog))
    }

    @Test func stateCommand() {
        #expect(parseDaemonCommand("state") == .success(.state))
    }
}

// MARK: - Daemon safety engine

private enum MockHardwareError: Error { case write }

private final class MockFanHardware: FanHardware {
    var fanIndices = [0, 1]
    var samples: [[Double]] = [[60, 62]]
    var temperatureReads = 0
    var setCalls: [(Int, Double)] = []
    var automaticCalls: [Int] = []
    var failingFans: Set<Int> = []
    var failingAutomaticFans: Set<Int> = []

    func thermalSample() -> ThermalSample? {
        temperatureReads += 1
        let values = samples.count > 1 ? samples.removeFirst() : (samples.first ?? [])
        return ThermalSample(temperatures: values)
    }

    func setFan(_ index: Int, percent: Double) throws -> Double {
        setCalls.append((index, percent))
        if failingFans.contains(index) { throw MockHardwareError.write }
        return 2000 + percent * 40
    }

    func setAutomatic(_ index: Int) throws {
        automaticCalls.append(index)
        if failingAutomaticFans.contains(index) { throw MockHardwareError.write }
    }
}

@Suite struct DaemonEngineTests {
    private func path() -> String {
        NSTemporaryDirectory() + "fanknob-engine-\(UUID().uuidString).json"
    }

    /// Over the limit, the watchdog drives every fan flat out and keeps them —
    /// it does not hand back to the firmware.
    ///
    /// Releasing only helps if the firmware would run the fans harder than we
    /// are, and it cannot exceed 100%. In the field a curve already at maximum
    /// tripped at 104°C and the firmware took over at 2,390 rpm against a
    /// 2,317 minimum, so the old behavior cut cooling at the hottest moment.
    @Test func watchdogForcesMaximumCoolingAfterConsecutiveStrikes() {
        let hardware = MockFanHardware()
        hardware.samples = [[70, 100]]
        let configPath = path()
        defer { unlink(configPath) }
        let engine = DaemonEngine(hardware: hardware, configPath: configPath)

        #expect(engine.handle("set 40").ok)
        engine.tick()
        // One over-limit sample is a strike, not a trip.
        #expect(engine.currentState().mode == "manual")
        #expect(!engine.currentState().watchdogTripped)
        engine.tick()

        let state = engine.currentState()
        #expect(state.watchdogTripped)
        #expect(state.hottestCelsius == 100)
        // Still ours, and every fan is at full speed.
        #expect(state.mode == "manual")
        #expect(hardware.automaticCalls.isEmpty)
        #expect(hardware.setCalls.suffix(2).allSatisfy { $0.1 == 100 })
    }

    /// And it stands down again once there is real headroom, not at the first
    /// sample under the limit.
    @Test func watchdogReleasesMaximumOnceTemperatureRecovers() {
        let hardware = MockFanHardware()
        hardware.samples = [[70, 100], [70, 100], [70, 70]]
        let configPath = path()
        defer { unlink(configPath) }
        let engine = DaemonEngine(hardware: hardware, configPath: configPath)

        #expect(engine.handle("set 40").ok)
        engine.tick()
        engine.tick()
        #expect(hardware.setCalls.suffix(2).allSatisfy { $0.1 == 100 })

        engine.tick()   // first cool sample: debounced, still holding
        #expect(engine.currentState().watchdogTripped)
        engine.tick()   // second: stand down

        #expect(engine.currentState().mode == "manual")
        #expect(hardware.automaticCalls.isEmpty)
        // The user's own speed comes back. A curve re-applies itself on the
        // next tick, but a fixed speed has nothing else to restore it and
        // would otherwise stay stuck at the forced 100%.
        #expect(hardware.setCalls.suffix(2).allSatisfy { $0.1 == 40 })
        #expect(engine.currentState().watchdogTripped == false)
    }

    /// Forcing 100% is what cools the machine, so releasing at the first sample
    /// under the limit made it oscillate — fans dropping and re-pinning every
    /// few seconds, one notification per cycle. The release margin stops that.
    @Test func watchdogDoesNotFlapJustUnderTheLimit() {
        let hardware = MockFanHardware()
        // Hovering in the band between the release margin and the limit.
        hardware.samples = [[70, 101], [70, 101], [70, 97], [70, 99], [70, 97]]
        let configPath = path()
        defer { unlink(configPath) }
        let engine = DaemonEngine(hardware: hardware, configPath: configPath)

        #expect(engine.handle("set 40").ok)
        for _ in 0..<6 { engine.tick() }

        // Never dropped back to the user's speed while hovering.
        #expect(!hardware.setCalls.dropFirst(2).contains { $0.1 == 40 })
        #expect(engine.currentState().watchdogTripped)
    }

    /// A stale `watchdogAtMaximum` used to silence every later trip: the fans
    /// were pinned to 100% with no banner, no notification and no log line.
    @Test func watchdogStillReportsAfterAnEarlierEpisode() {
        let hardware = MockFanHardware()
        hardware.samples = [[70, 101]]
        let configPath = path()
        defer { unlink(configPath) }
        var lines: [String] = []
        let engine = DaemonEngine(hardware: hardware, configPath: configPath,
                                  logger: { lines.append($0) })

        #expect(engine.handle("set 40").ok)
        engine.tick(); engine.tick()
        #expect(engine.currentState().watchdogTripped)

        // Back to auto, then override again while it is still hot.
        #expect(engine.handle("auto").ok)
        #expect(!engine.currentState().watchdogTripped)
        #expect(engine.handle("set 30").ok)
        lines.removeAll()
        engine.tick(); engine.tick()

        let state = engine.currentState()
        #expect(state.watchdogTripped)
        #expect(state.safetyReason != nil)
        #expect(lines.contains { $0.contains("forcing maximum cooling") })
    }

    @Test func watchdogIgnoresSingleSampleSpike() {
        let hardware = MockFanHardware()
        hardware.samples = [[70, 100], [70, 72]]   // one probe burst, then normal
        let configPath = path()
        defer { unlink(configPath) }
        let engine = DaemonEngine(hardware: hardware, configPath: configPath)

        #expect(engine.handle("set 40").ok)
        engine.tick()
        engine.tick()
        engine.tick()

        #expect(engine.currentState().mode == "manual")
        #expect(!engine.currentState().watchdogTripped)
        #expect(hardware.automaticCalls.isEmpty)
    }

    @Test func manualChangeDuringWatchdogUpdatesIntentWithoutLoweringCooling() {
        let hardware = MockFanHardware()
        hardware.samples = [[70, 101], [70, 101], [70, 70]]
        let configPath = path()
        defer { unlink(configPath) }
        let engine = DaemonEngine(hardware: hardware, configPath: configPath)

        #expect(engine.handle("set 40").ok)
        engine.tick(); engine.tick()
        let callsAtMaximum = hardware.setCalls.count

        #expect(engine.handle("set 30").ok)
        #expect(engine.currentState().mode == "manual")
        #expect(engine.currentState().knob == 30)
        #expect(engine.currentState().coolingAtMaximum)
        #expect(hardware.setCalls.count == callsAtMaximum) // did not apply 30% while hot

        engine.tick() // first cool sample: remain at maximum
        #expect(hardware.setCalls.suffix(2).allSatisfy { $0.1 == 100 })
        engine.tick() // second cool sample: restore the new intent
        #expect(hardware.setCalls.suffix(2).allSatisfy { $0.1 == 30 })
        #expect(!engine.currentState().watchdogTripped)
    }

    @Test func curveChangeDuringWatchdogStaysAtMaximumUntilRecovery() {
        let hardware = MockFanHardware()
        hardware.samples = [[70, 101], [70, 101], [70, 70]]
        let configPath = path()
        defer { unlink(configPath) }
        let engine = DaemonEngine(hardware: hardware, configPath: configPath)

        #expect(engine.handle("set 40").ok)
        engine.tick(); engine.tick()
        let callsAtMaximum = hardware.setCalls.count

        #expect(engine.handle("preset quiet").ok)
        #expect(engine.currentState().mode == "curve")
        #expect(engine.currentState().preset == "quiet")
        #expect(engine.currentState().coolingAtMaximum)
        #expect(hardware.setCalls.count == callsAtMaximum)

        engine.tick(); engine.tick()
        #expect(!engine.currentState().watchdogTripped)
        #expect(hardware.setCalls.suffix(2).allSatisfy { $0.1 < 100 })
    }

    @Test func watchdogRecoveryReleasesFansOutsidePartialManualMode() {
        let hardware = MockFanHardware()
        hardware.samples = [[70, 101], [70, 101], [70, 70]]
        let configPath = path()
        defer { unlink(configPath) }
        let engine = DaemonEngine(hardware: hardware, configPath: configPath)

        #expect(engine.handle("setfan 0 40").ok)
        engine.tick(); engine.tick()
        #expect(engine.currentState().coolingAtMaximum)

        engine.tick(); engine.tick()
        #expect(!engine.currentState().watchdogTripped)
        #expect(hardware.setCalls.last?.0 == 0)
        #expect(hardware.setCalls.last?.1 == 40)
        #expect(hardware.automaticCalls == [1])
    }

    @Test func disablingWatchdogDuringTripRestoresSelectedMode() {
        let hardware = MockFanHardware()
        hardware.samples = [[70, 101]]
        let configPath = path()
        defer { unlink(configPath) }
        let engine = DaemonEngine(hardware: hardware, configPath: configPath)

        #expect(engine.handle("set 40").ok)
        engine.tick(); engine.tick()
        #expect(engine.currentState().coolingAtMaximum)

        #expect(engine.handle("watchdog off").ok)
        let state = engine.currentState()
        #expect(state.watchdogCelsius == nil)
        #expect(!state.watchdogTripped)
        #expect(!state.coolingAtMaximum)
        #expect(state.mode == "manual")
        #expect(hardware.setCalls.suffix(2).allSatisfy { $0.1 == 40 })
    }

    @Test func expiredHoldWaitsForWatchdogRecoveryBeforeAutomaticControl() {
        let hardware = MockFanHardware()
        hardware.samples = [[70, 101]]
        let configPath = path()
        defer { unlink(configPath) }
        var clock = Date(timeIntervalSince1970: 10_000)
        let engine = DaemonEngine(hardware: hardware, configPath: configPath,
                                  now: { clock })

        #expect(engine.handle("set 40 5").ok)
        engine.tick(); engine.tick()
        clock = clock.addingTimeInterval(6)
        engine.tick()
        #expect(engine.currentState().mode == "manual")
        #expect(engine.currentState().coolingAtMaximum)
        #expect(hardware.automaticCalls.isEmpty)

        hardware.samples = [[70, 70]]
        engine.tick()
        #expect(hardware.automaticCalls.isEmpty)
        engine.tick()
        #expect(engine.currentState().mode == "auto")
        #expect(hardware.automaticCalls == [0, 1])
    }

    @Test func expiredHoldAtHotRestartClampsUntilWatchdogRecovery() {
        let configPath = path()
        defer { unlink(configPath) }
        var clock = Date(timeIntervalSince1970: 10_000)

        let first = DaemonEngine(hardware: MockFanHardware(),
                                 configPath: configPath, now: { clock })
        #expect(first.handle("set 40 5").ok)
        clock = clock.addingTimeInterval(6)

        let restartedHardware = MockFanHardware()
        restartedHardware.samples = [[70, 101], [70, 70]]
        let restarted = DaemonEngine(hardware: restartedHardware,
                                     configPath: configPath, now: { clock })
        restarted.start()

        #expect(restarted.currentState().mode == "manual")
        #expect(restarted.currentState().coolingAtMaximum)
        #expect(restartedHardware.automaticCalls.isEmpty)
        #expect(restartedHardware.setCalls.allSatisfy { $0.1 == 100 })

        restarted.tick()
        #expect(restarted.currentState().coolingAtMaximum)
        restarted.tick()
        #expect(restarted.currentState().mode == "auto")
        #expect(restartedHardware.automaticCalls == [0, 1])
    }

    @Test func missingSensorsDoNotReleaseAnActiveWatchdog() {
        let hardware = MockFanHardware()
        hardware.samples = [[70, 101]]
        let configPath = path()
        defer { unlink(configPath) }
        let engine = DaemonEngine(hardware: hardware, configPath: configPath)

        #expect(engine.handle("set 35").ok)
        engine.tick(); engine.tick()
        hardware.samples = [[]]
        for _ in 0..<4 { engine.tick() }

        let state = engine.currentState()
        #expect(state.mode == "manual")
        #expect(state.watchdogTripped)
        #expect(state.coolingAtMaximum)
        #expect(state.sensorFailures == 4)
        #expect(hardware.automaticCalls.isEmpty)
    }

    @Test func missingSampleBreaksConsecutiveWatchdogRecovery() {
        let hardware = MockFanHardware()
        hardware.samples = [[70, 101], [70, 101], [70, 70], [],
                            [70, 70], [70, 70]]
        let configPath = path()
        defer { unlink(configPath) }
        let engine = DaemonEngine(hardware: hardware, configPath: configPath)

        #expect(engine.handle("set 35").ok)
        engine.tick(); engine.tick() // trip
        engine.tick()                // first cool sample
        engine.tick()                // missing: reset the recovery sequence
        engine.tick()                // first cool sample after the gap
        #expect(engine.currentState().watchdogTripped)
        engine.tick()                // second consecutive cool sample: release
        #expect(!engine.currentState().watchdogTripped)
    }

    @Test func maximumWriteFailureDegradesOnlyAffectedFanAndRetries() {
        let hardware = MockFanHardware()
        hardware.samples = [[70, 101]]
        let configPath = path()
        defer { unlink(configPath) }
        let engine = DaemonEngine(hardware: hardware, configPath: configPath)

        #expect(engine.handle("set 40").ok)
        hardware.failingFans = [1]
        engine.tick(); engine.tick()

        var state = engine.currentState()
        #expect(state.mode == "manual")
        #expect(state.watchdogTripped)
        #expect(!state.coolingAtMaximum)
        #expect(state.safetyReason?.hasPrefix("watchdog degraded: ") == true)
        #expect(hardware.setCalls.contains { $0.0 == 0 && $0.1 == 100 })
        #expect(hardware.automaticCalls == [1])

        hardware.failingFans = []
        engine.tick()
        state = engine.currentState()
        #expect(state.coolingAtMaximum)
        #expect(hardware.setCalls.suffix(2).allSatisfy { $0.1 == 100 })
    }

    @Test func hotRestartClampsBeforeRestoringPersistedLowSetpoint() {
        let configPath = path()
        defer { unlink(configPath) }
        let firstHardware = MockFanHardware()
        let first = DaemonEngine(hardware: firstHardware, configPath: configPath)
        #expect(first.handle("set 20").ok)

        let restartedHardware = MockFanHardware()
        restartedHardware.samples = [[70, 101]]
        let restarted = DaemonEngine(hardware: restartedHardware, configPath: configPath)
        restarted.start()

        #expect(restarted.currentState().watchdogTripped)
        #expect(restarted.currentState().coolingAtMaximum)
        #expect(restartedHardware.setCalls.count == 2)
        #expect(restartedHardware.setCalls.allSatisfy { $0.1 == 100 })
    }

    @Test func thermalSampleSeparatesCurveAverageFromSafetyMaximum() {
        let sample = ThermalSample(
            averageTemperatures: [50, 60],
            safetyTemperatures: [50, 60, 101]
        )
        #expect(sample?.average == 55)
        #expect(sample?.hottest == 101)
    }

    @Test func missingSensorsFailSafeAfterThreeChecks() {
        let hardware = MockFanHardware()
        hardware.samples = [[]]
        let configPath = path()
        defer { unlink(configPath) }
        let engine = DaemonEngine(hardware: hardware, configPath: configPath)

        #expect(engine.handle("set 35").ok)
        engine.tick()
        engine.tick()
        #expect(engine.currentState().mode == "manual")
        engine.tick()
        #expect(engine.currentState().mode == "auto")
        #expect(engine.currentState().safetyReason?.contains("unavailable") == true)
    }

    @Test func curveTickSamplesOnlyOnce() {
        let hardware = MockFanHardware()
        let configPath = path()
        defer { unlink(configPath) }
        let engine = DaemonEngine(hardware: hardware, configPath: configPath)

        #expect(engine.handle("preset balanced").ok)
        let before = hardware.temperatureReads
        engine.tick()
        #expect(hardware.temperatureReads == before + 1)
    }

    @Test func holdSurvivesRestartAndExpiresSafely() {
        let configPath = path()
        defer { unlink(configPath) }
        var clock = Date(timeIntervalSince1970: 10_000)

        let firstHardware = MockFanHardware()
        let first = DaemonEngine(hardware: firstHardware, configPath: configPath,
                                 now: { clock })
        #expect(first.handle("set 45 30").ok)
        #expect(DaemonConfig.load(from: configPath)?.revertAt
            == clock.addingTimeInterval(30))

        let secondHardware = MockFanHardware()
        let restarted = DaemonEngine(hardware: secondHardware, configPath: configPath,
                                     now: { clock })
        restarted.start()
        #expect(restarted.currentState().mode == "manual")
        #expect(secondHardware.setCalls.count == 2)

        clock = clock.addingTimeInterval(31)
        restarted.tick()
        #expect(restarted.currentState().mode == "auto")
        #expect(secondHardware.automaticCalls == [0, 1])
    }

    @Test func partialWriteFailureRollsEverythingBack() {
        let hardware = MockFanHardware()
        hardware.failingFans = [1]
        let configPath = path()
        defer { unlink(configPath) }
        let engine = DaemonEngine(hardware: hardware, configPath: configPath)

        let reply = engine.handle("set 50")
        #expect(!reply.ok)
        #expect(engine.currentState().mode == "auto")
        #expect(hardware.automaticCalls == [0, 1])
    }

    @Test func persistenceFailureRollsManualWriteBack() {
        let hardware = MockFanHardware()
        let engine = DaemonEngine(
            hardware: hardware,
            configPath: "/dev/null/fanknob-config.json"
        )

        let reply = engine.handle("set 50 30")
        #expect(!reply.ok)
        #expect(engine.currentState().mode == "auto")
        #expect(hardware.automaticCalls == [0, 1])
    }

    @Test func failedManualRevertSetsReasonAndIsRetried() {
        let hardware = MockFanHardware()
        hardware.failingFans = [1]
        hardware.failingAutomaticFans = [0]
        let configPath = path()
        defer { unlink(configPath) }
        let engine = DaemonEngine(hardware: hardware, configPath: configPath)

        // Fan 0 is written, fan 1 fails, and the hand-back write for fan 0
        // fails too — the exact stranding scenario: the revert must arm the
        // retry machinery and surface a reason, not silently report "auto".
        #expect(!engine.handle("set 60").ok)
        #expect(engine.currentState().mode == "auto")
        #expect(engine.currentState().safetyReason != nil)

        hardware.failingAutomaticFans = []
        engine.tick()
        #expect(hardware.automaticCalls == [0, 1, 0, 1])
    }

    @Test func manualSetWithZeroFansIsRejected() {
        let hardware = MockFanHardware()
        hardware.fanIndices = []
        let configPath = path()
        defer { unlink(configPath) }
        let engine = DaemonEngine(hardware: hardware, configPath: configPath)

        #expect(!engine.handle("set 50").ok)
        #expect(engine.currentState().mode == "auto")
        #expect(hardware.setCalls.isEmpty)
        // Nothing must be persisted: a daemon restart should come up in auto.
        #expect(DaemonConfig.load(from: configPath) == nil)
    }

    @Test func autoModeKeepsSamplingSoStateStaysFresh() {
        let hardware = MockFanHardware()
        hardware.samples = [[60, 96], [40, 45]]
        let configPath = path()
        defer { unlink(configPath) }
        let engine = DaemonEngine(hardware: hardware, configPath: configPath)

        engine.tick()
        #expect(engine.currentState().hottestCelsius == 96)
        // Idle in auto: hottest (and the curve EMA) must track reality, not
        // freeze at the value from whenever the daemon last left auto.
        engine.tick()
        #expect(engine.currentState().hottestCelsius == 45)
    }

    @Test func failedAutomaticWritesAreRetried() {
        let hardware = MockFanHardware()
        hardware.samples = [[]]
        hardware.failingAutomaticFans = [1]
        let configPath = path()
        defer { unlink(configPath) }
        let engine = DaemonEngine(hardware: hardware, configPath: configPath)

        #expect(engine.handle("set 35").ok)
        engine.tick()
        engine.tick()
        engine.tick()
        #expect(engine.currentState().mode == "auto")
        #expect(hardware.automaticCalls == [0, 1])

        hardware.failingAutomaticFans = []
        engine.tick()
        #expect(hardware.automaticCalls == [0, 1, 0, 1])
    }
}

// MARK: - Socket framing / protocol compatibility

@Suite struct SocketProtocolTests {
    @Test func lineRoundtripOverSocketPair() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        configureDaemonSocket(descriptors[0])
        configureDaemonSocket(descriptors[1])
        try writeDaemonLine(descriptors[0], "preset balanced")
        #expect(try readDaemonLine(descriptors[1]) == "preset balanced")
    }

    @Test func oversizedLineIsRejected() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        try writeDaemonLine(descriptors[0], String(repeating: "x", count: 32))
        #expect(throws: DaemonSocketError.tooLarge) {
            _ = try readDaemonLine(descriptors[1], maximumBytes: 16)
        }
    }

    /// A client that gives up before we answer is normal — its own timeout —
    /// and must be reported as a disconnect, not a system error. The daemon
    /// only logs non-disconnects, so mapping this wrong buried a real incident
    /// under hundreds of "Broken pipe" lines.
    @Test func writingToAClosedPeerReportsDisconnect() throws {
        var descriptors: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { close(descriptors[0]) }
        configureDaemonSocket(descriptors[0])

        close(descriptors[1])                 // the client walks away
        var ignored: Int32 = 1
        _ = setsockopt(descriptors[0], SOL_SOCKET, SO_NOSIGPIPE, &ignored,
                       socklen_t(MemoryLayout<Int32>.size))

        #expect(throws: DaemonSocketError.disconnected) {
            // Enough data that at least one send() reaches the dead peer.
            try writeDaemonLine(descriptors[0], String(repeating: "x", count: 512))
        }
    }

    @Test func structuredReplyRoundtrips() {
        let reply = DaemonReply(ok: true, message: "state",
                                state: DaemonState(mode: "curve", knob: 42))
        #expect(DaemonReply.decode(reply.encoded()) == reply)
    }

    @Test func oldStatePayloadUsesDefaultsForNewFields() {
        let old = #"{"mode":"auto","watchdogTripped":false,"holdRemaining":0}"#
        let state = DaemonState.decode(old)
        #expect(state?.mode == "auto")
        #expect(state?.sensorFailures == 0)
        #expect(state?.safetyReason == nil)
        #expect(state?.coolingAtMaximum == false)
    }
}
