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

    @Test func watchdogUsesHottestRawSensorAfterConsecutiveStrikes() {
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
        #expect(state.mode == "auto")
        #expect(state.watchdogTripped)
        #expect(state.hottestCelsius == 100)
        #expect(hardware.automaticCalls == [0, 1])
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
    }
}
