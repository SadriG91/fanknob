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

    @Test func clampsKnobValues() {
        let c = FanCurve([.init(celsius: 50, knob: -20), .init(celsius: 90, knob: 500)])!
        #expect(c.knob(at: 50) == 0)
        #expect(c.knob(at: 90) == 100)
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

    @Test func negativeOrJunkHoldBecomesZero() {
        #expect(parseDaemonCommand("set 40 -10") == .success(.set(pct: 40, holdSeconds: 0)))
        #expect(parseDaemonCommand("set 40 xyz") == .success(.set(pct: 40, holdSeconds: 0)))
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
