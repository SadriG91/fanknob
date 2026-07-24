// SMC.swift — shared SMC engine for the fanknob client and daemon.
//
// Talks to the Apple System Management Controller over IOKit: reads fan RPM and
// temperature sensors, and (when run as root) writes fan target/mode keys.

import Foundation
import IOKit

// Where the root daemon listens and the client connects.
let fanknobdSocketPath = "/var/run/fanknobd.sock"

// MARK: - SMC parameter struct (must match the kernel's SMCKeyData_t, 80 bytes)

typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

let zeroBytes: SMCBytes = (
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
)

struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    // Explicit trailing padding to 12 bytes. Without this Swift reuses this
    // struct's tail padding for the next field (unlike C), packing the whole
    // param struct to 76 bytes and making every IOConnectCallStructMethod call
    // fail with kIOReturnBadArgument. The kernel expects exactly 80 bytes.
    var pad0: UInt8 = 0
    var pad1: UInt8 = 0
    var pad2: UInt8 = 0
}

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = zeroBytes
}

enum SMCSelector: UInt8 {
    case readKey = 5
    case writeKey = 6
    case getKeyFromIndex = 8
    case getKeyInfo = 9
}

let kernelIndexSMC: UInt32 = 2

// MARK: - FourCC helpers

func fourCC(_ s: String) -> UInt32 {
    var r: UInt32 = 0
    for b in s.utf8.prefix(4) { r = (r << 8) | UInt32(b) }
    return r
}

func fourCCString(_ v: UInt32) -> String {
    let chars = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                 UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    return String(bytes: chars, encoding: .ascii) ?? "?"
}

// MARK: - Tuple <-> array

func tupleToArray(_ t: SMCBytes, count: Int) -> [UInt8] {
    var t = t
    return withUnsafeBytes(of: &t) { Array($0.prefix(count)) }
}

func arrayToTuple(_ a: [UInt8]) -> SMCBytes {
    var t = zeroBytes
    withUnsafeMutableBytes(of: &t) { raw in
        for i in 0..<min(a.count, 32) { raw[i] = a[i] }
    }
    return t
}

// MARK: - SMC connection

enum SMCError: Error, CustomStringConvertible {
    case open(String)
    case call(String)
    var description: String {
        switch self {
        case .open(let m): return "Could not open SMC: \(m)"
        case .call(let m): return "SMC call failed: \(m)"
        }
    }
}

final class SMC {
    private var conn: io_connect_t = 0

    func open() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.open("AppleSMC service not found") }
        let rc = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        guard rc == kIOReturnSuccess else { throw SMCError.open("IOServiceOpen -> \(rc)") }
    }

    func close() { if conn != 0 { IOServiceClose(conn); conn = 0 } }

    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        var output = SMCParamStruct()
        let inSize = MemoryLayout<SMCParamStruct>.stride
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let rc = withUnsafePointer(to: &input) { inPtr in
            withUnsafeMutablePointer(to: &output) { outPtr in
                IOConnectCallStructMethod(conn, kernelIndexSMC, inPtr, inSize, outPtr, &outSize)
            }
        }
        guard rc == kIOReturnSuccess else { throw SMCError.call("IOKit rc \(rc)") }
        guard output.result == 0 else {
            throw SMCError.call("SMC result 0x\(String(output.result, radix: 16))")
        }
        return output
    }

    struct KeyInfo { let dataSize: UInt32; let dataType: UInt32 }

    func keyInfo(_ key: UInt32) throws -> KeyInfo {
        var input = SMCParamStruct()
        input.key = key
        input.data8 = SMCSelector.getKeyInfo.rawValue
        let out = try call(&input)
        return KeyInfo(dataSize: out.keyInfo.dataSize, dataType: out.keyInfo.dataType)
    }

    func read(_ key: UInt32) -> (type: UInt32, bytes: [UInt8])? {
        guard let info = try? keyInfo(key), info.dataSize > 0 else { return nil }
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = info.dataSize
        input.data8 = SMCSelector.readKey.rawValue
        guard let out = try? call(&input) else { return nil }
        return (info.dataType, tupleToArray(out.bytes, count: Int(info.dataSize)))
    }

    func write(_ key: UInt32, type: UInt32, bytes: [UInt8]) throws {
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = UInt32(bytes.count)
        input.keyInfo.dataType = type
        input.data8 = SMCSelector.writeKey.rawValue
        input.bytes = arrayToTuple(bytes)
        _ = try call(&input)
    }

    func keyCount() -> UInt32 {
        guard let (t, b) = read(fourCC("#KEY")) else { return 0 }
        return decodeToDouble(type: t, bytes: b).map { UInt32($0) } ?? 0
    }

    func keyAtIndex(_ i: UInt32) -> UInt32? {
        var input = SMCParamStruct()
        input.data8 = SMCSelector.getKeyFromIndex.rawValue
        input.data32 = i
        guard let out = try? call(&input) else { return nil }
        return out.key
    }
}

// MARK: - Value decoding / encoding
// SMC integers and fpe2 are big-endian; flt is native little-endian on arm64.

func decodeToDouble(type: UInt32, bytes: [UInt8]) -> Double? {
    let t = fourCCString(type).trimmingCharacters(in: .whitespaces)
    switch t {
    case "flt":
        guard bytes.count >= 4 else { return nil }
        let f = bytes.prefix(4).withUnsafeBytes { $0.load(as: Float32.self) }
        return Double(f)
    case "fpe2":
        guard bytes.count >= 2 else { return nil }
        return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
    case "ui8":
        guard let b = bytes.first else { return nil }
        return Double(b)
    case "ui16":
        guard bytes.count >= 2 else { return nil }
        return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
    case "ui32":
        guard bytes.count >= 4 else { return nil }
        let v = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16
              | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
        return Double(v)
    default:
        return nil
    }
}

func encodeRPM(type: UInt32, value: Double) -> [UInt8] {
    let t = fourCCString(type).trimmingCharacters(in: .whitespaces)
    switch t {
    case "fpe2":
        let raw = UInt16((value * 4.0).rounded())
        return [UInt8(raw >> 8), UInt8(raw & 0xff)]
    default: // "flt" and fallback
        var f = Float32(value)
        return withUnsafeBytes(of: &f) { Array($0) }
    }
}

extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}

// MARK: - Fans

struct Fan {
    let index: Int
    let actual: Double
    let min: Double
    let max: Double
    let target: Double
    let managed: Bool   // true = manual/forced

    var knob: Double {
        guard max > min else { return 0 }
        return ((target - min) / (max - min) * 100).clamped(0, 100)
    }
}

func fanCount(_ smc: SMC) -> Int {
    guard let (t, b) = smc.read(fourCC("FNum")) else { return 0 }
    return decodeToDouble(type: t, bytes: b).map { Int($0) } ?? 0
}

func readFan(_ smc: SMC, _ i: Int) -> Fan? {
    func num(_ suffix: String) -> Double? {
        guard let (t, b) = smc.read(fourCC("F\(i)\(suffix)")) else { return nil }
        return decodeToDouble(type: t, bytes: b)
    }
    guard let actual = num("Ac"), let mn = num("Mn"), let mx = num("Mx") else { return nil }
    return Fan(index: i, actual: actual, min: mn, max: mx,
               target: num("Tg") ?? actual, managed: (num("Md") ?? 0) >= 1)
}

// Privileged: take manual control of fan i and target a knob percentage.
// Returns the resolved RPM. Throws (needs root) on write failure.
@discardableResult
func setFanKnob(_ smc: SMC, _ i: Int, pct: Double) throws -> Double {
    guard let f = readFan(smc, i) else { throw SMCError.call("fan \(i) unreadable") }
    let rpm = f.min + (f.max - f.min) * pct.clamped(0, 100) / 100
    try smc.write(fourCC("F\(i)Md"), type: fourCC("ui8 "), bytes: [1])
    if let info = try? smc.keyInfo(fourCC("F\(i)Tg")) {
        try smc.write(fourCC("F\(i)Tg"), type: info.dataType,
                      bytes: encodeRPM(type: info.dataType, value: rpm))
    }
    return rpm
}

// Privileged: return fan i to automatic control.
func setFanAuto(_ smc: SMC, _ i: Int) throws {
    try smc.write(fourCC("F\(i)Md"), type: fourCC("ui8 "), bytes: [0])
}

// MARK: - Temperature

struct TempSensor { let key: String; let celsius: Double }

// Apple Silicon exposes many die/board temp sensors as 'T…' keys of type flt.
// There is no single documented "CPU temp" key, so we scan all plausible ones.
func readTemps(_ smc: SMC) -> [TempSensor] {
    let count = smc.keyCount()
    guard count > 0 else { return [] }
    var out: [TempSensor] = []
    for i in 0..<count {
        guard let key = smc.keyAtIndex(i) else { continue }
        let name = fourCCString(key)
        guard name.hasPrefix("T") else { continue }
        guard let (t, b) = smc.read(key),
              fourCCString(t).trimmingCharacters(in: .whitespaces) == "flt",
              let v = decodeToDouble(type: t, bytes: b),
              v > 1, v < 130 else { continue }   // filter unpopulated / bogus sensors
        out.append(TempSensor(key: name, celsius: v))
    }
    return out.sorted { $0.celsius > $1.celsius }
}

// A single representative reading: average across CPU-core (Tp*) and GPU (Tg*)
// sensor clusters. Individual sensors spike momentarily, so a cluster average
// is the meaningful number. Falls back to the overall average if a machine
// doesn't use the Tp/Tg naming.
struct TempReport {
    let all: [TempSensor]
    let cpu: Double?
    let gpu: Double?
    var overall: Double? {
        all.isEmpty ? nil : all.reduce(0) { $0 + $1.celsius } / Double(all.count)
    }
}

func readTempReport(_ smc: SMC) -> TempReport {
    let all = readTemps(smc)
    func avg(_ prefix: String) -> Double? {
        let xs = all.filter { $0.key.hasPrefix(prefix) }
        return xs.isEmpty ? nil : xs.reduce(0) { $0 + $1.celsius } / Double(xs.count)
    }
    return TempReport(all: all, cpu: avg("Tp"), gpu: avg("Tg"))
}
