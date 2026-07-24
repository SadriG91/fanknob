// TUI.swift — a live, interactive full-screen fan/temperature view.
//
// Pure ANSI + raw-terminal-mode (no dependencies). Renders fan and temperature
// gauges that refresh a few times a second, and exposes the fan control as a
// "knob" you turn with the arrow keys — changes apply live via the daemon (or
// directly if run as root).

import Foundation
import Darwin
import FanknobCore

// MARK: - ANSI helpers

enum Ansi {
    static let altOn  = "\u{1B}[?1049h"
    static let altOff = "\u{1B}[?1049l"
    static let hide   = "\u{1B}[?25l"
    static let show   = "\u{1B}[?25h"
    static let home   = "\u{1B}[H"
    static let clearBelow = "\u{1B}[J"
    static let clearEOL   = "\u{1B}[K"
    static let reset  = "\u{1B}[0m"
    static let bold   = "\u{1B}[1m"
    static let dim    = "\u{1B}[2m"
    static func fg(_ n: Int) -> String { "\u{1B}[38;5;\(n)m" }
}

// Green→red gradient for temperatures.
func tempColor(_ c: Double) -> Int {
    switch c {
    case ..<45: return 45     // cyan
    case ..<58: return 42     // green
    case ..<70: return 190    // yellow-green
    case ..<80: return 214    // amber
    case ..<88: return 208    // orange
    default:    return 196    // red
    }
}

// A smooth fractional bar using 1/8-block characters.
func bar(_ frac: Double, width: Int, color: Int) -> String {
    let f = max(0, min(1, frac))
    let units = f * Double(width)
    let full = Int(units)
    let eighths = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
    let partial = eighths[Int((units - Double(full)) * 8)]
    let filledCount = full + (partial.isEmpty ? 0 : 1)
    let filled = String(repeating: "█", count: full) + partial
    let empty = String(repeating: "░", count: max(0, width - filledCount))
    return Ansi.fg(color) + filled + Ansi.fg(236) + empty + Ansi.reset
}

// MARK: - Terminal raw mode (restored via signal handlers + defer)

var savedTermios = termios()

func restoreTerminal() {
    tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
    print(Ansi.show + Ansi.altOff, terminator: "")
    fflush(stdout)
}

let signalHandler: @convention(c) (Int32) -> Void = { _ in
    restoreTerminal()
    _exit(0)
}

func enableRawMode() {
    tcgetattr(STDIN_FILENO, &savedTermios)
    var raw = savedTermios
    raw.c_lflag &= ~tcflag_t(ECHO | ICANON)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
}

// Wait up to timeoutMs for a keypress; return the raw bytes (empty on timeout).
func waitKey(timeoutMs: Int) -> [UInt8] {
    var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    guard poll(&pfd, 1, Int32(timeoutMs)) > 0,
          (pfd.revents & Int16(POLLIN)) != 0 else { return [] }
    var buf = [UInt8](repeating: 0, count: 8)
    let n = read(STDIN_FILENO, &buf, 8)
    return n > 0 ? Array(buf[0..<n]) : []
}

// MARK: - Applying writes

func applyKnob(_ smc: SMC, _ pct: Double, seconds: Int = 0) {
    if geteuid() == 0 { for i in 0..<fanCount(smc) { _ = try? setFanKnob(smc, i, pct: pct) } }
    else { _ = sendToDaemon(seconds > 0 ? "set \(Int(pct)) \(seconds)" : "set \(Int(pct))") }
}

func applyAutoTUI(_ smc: SMC) {
    if geteuid() == 0 { for i in 0..<fanCount(smc) { try? setFanAuto(smc, i) } }
    else { _ = sendToDaemon("auto") }
}

// MARK: - Machine label

func sysctlString(_ name: String) -> String? {
    var size = 0
    sysctlbyname(name, nil, &size, nil, 0)
    guard size > 0 else { return nil }
    var buf = [CChar](repeating: 0, count: size)
    sysctlbyname(name, &buf, &size, nil, 0)
    return String(cString: buf)
}

// MARK: - Rendering

let holdCycle = [0, 30, 60, 120, 300]
func holdLabel(_ s: Int) -> String {
    switch s { case 0: return "off"; case 30: return "30s"; case 60: return "1m"
    case 120: return "2m"; case 300: return "5m"; default: return "\(s)s" }
}
func fmtClock(_ seconds: Int) -> String { String(format: "%d:%02d", seconds / 60, seconds % 60) }

func renderFrame(_ smc: SMC, tempKeys: [UInt32], knob: Double, canWrite: Bool,
                 chip: String, holdSeconds: Int, holdDeadline: Date?) -> String {
    let W = 24  // gauge width
    var L: [String] = []

    // Header
    L.append(" \(Ansi.bold)\(Ansi.fg(45))fanknob\(Ansi.reset)   \(Ansi.dim)\(chip)\(Ansi.reset)")
    L.append(" \(Ansi.fg(240))" + String(repeating: "─", count: 46) + Ansi.reset)

    // Fans
    let fans = (0..<fanCount(smc)).compactMap { readFan(smc, $0) }
    let anyManual = fans.contains { $0.managed }
    for f in fans {
        let frac = (f.max > f.min) ? (f.actual - f.min) / (f.max - f.min) : 0
        let mode = f.managed
            ? "\(Ansi.fg(213))MANUAL\(Ansi.reset)"
            : "\(Ansi.dim)auto\(Ansi.reset)"
        L.append(String(format: " \(Ansi.fg(250))Fan %d\(Ansi.reset) %5.0f rpm  %@  %@",
                        f.index, f.actual, bar(frac, width: W, color: 45) as CVarArg, mode as CVarArg))
    }

    // Temps
    let sensors = readTempsCached(smc, tempKeys)
    let t = tempReport(from: sensors)
    L.append(" \(Ansi.fg(240))" + String(repeating: "─", count: 46) + Ansi.reset)
    func tempLine(_ label: String, _ value: Double?) {
        guard let v = value else { return }
        let frac = v / 100.0
        L.append(String(format: " \(Ansi.fg(250))%@\(Ansi.reset) %4.0f°C  %@",
                        label as CVarArg, v, bar(frac, width: W, color: tempColor(v)) as CVarArg))
    }
    tempLine("CPU", t.cpu)
    tempLine("GPU", t.gpu)
    if t.cpu == nil && t.gpu == nil { tempLine("Tmp", t.overall) }

    // Knob
    L.append(" \(Ansi.fg(240))" + String(repeating: "─", count: 46) + Ansi.reset)
    let knobColor = 213
    let state = canWrite
        ? (anyManual ? "\(Ansi.fg(213))MANUAL\(Ansi.reset)" : "\(Ansi.dim)auto\(Ansi.reset)")
        : "\(Ansi.fg(208))read-only\(Ansi.reset)"
    L.append(String(format: " \(Ansi.bold)KNOB\(Ansi.reset) %3.0f%%  %@  %@",
                    knob, bar(knob / 100, width: W, color: knobColor) as CVarArg, state as CVarArg))

    // Hold / auto-revert
    let holdText: String
    if let d = holdDeadline {
        let left = max(0, Int(d.timeIntervalSinceNow.rounded()))
        holdText = "\(Ansi.fg(213))\(fmtClock(left))\(Ansi.reset) \(Ansi.dim)→ auto\(Ansi.reset)"
    } else if holdSeconds > 0 {
        holdText = "\(Ansi.fg(250))\(holdLabel(holdSeconds))\(Ansi.reset) \(Ansi.dim)armed\(Ansi.reset)"
    } else {
        holdText = "\(Ansi.dim)off\(Ansi.reset)"
    }
    L.append(" \(Ansi.fg(250))HOLD\(Ansi.reset) \(holdText)")

    // Footer
    L.append(" \(Ansi.fg(240))" + String(repeating: "─", count: 46) + Ansi.reset)
    if canWrite {
        L.append(" \(Ansi.dim)←/→ ±5  ↑/↓ ±1  1-9 preset  t hold  a auto  q quit\(Ansi.reset)")
    } else {
        L.append(" \(Ansi.dim)q quit   ·   run 'sudo make install' to enable control\(Ansi.reset)")
    }

    return Ansi.home + L.map { $0 + Ansi.clearEOL }.joined(separator: "\r\n") + "\r\n" + Ansi.clearBelow
}

// MARK: - Main loop

func runTUI(_ smc: SMC) {
    let canWrite = (geteuid() == 0) || daemonReachable()
    let chip = sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
    let tempKeys = discoverTempKeys(smc)

    var knob = (0..<fanCount(smc)).compactMap { readFan(smc, $0) }.first?.knob ?? 0
    var holdSeconds = 0
    var holdDeadline: Date? = nil

    enableRawMode()
    signal(SIGINT, signalHandler)
    signal(SIGTERM, signalHandler)
    print(Ansi.altOn + Ansi.hide, terminator: "")
    defer { restoreTerminal() }

    func arm() {
        guard canWrite else { return }
        applyKnob(smc, knob, seconds: holdSeconds)
        holdDeadline = holdSeconds > 0 ? Date().addingTimeInterval(Double(holdSeconds)) : nil
    }

    var running = true
    while running {
        if let d = holdDeadline, Date() >= d {
            if canWrite { applyAutoTUI(smc) }
            holdDeadline = nil
        }

        print(renderFrame(smc, tempKeys: tempKeys, knob: knob, canWrite: canWrite,
                          chip: chip, holdSeconds: holdSeconds, holdDeadline: holdDeadline),
              terminator: "")
        fflush(stdout)

        let keys = waitKey(timeoutMs: 700)
        if keys.isEmpty { continue }

        if keys.count >= 3, keys[0] == 0x1B, keys[1] == 0x5B {
            switch keys[2] {
            case 0x41: knob = min(100, knob + 1); arm()   // up
            case 0x42: knob = max(0, knob - 1); arm()     // down
            case 0x43: knob = min(100, knob + 5); arm()   // right
            case 0x44: knob = max(0, knob - 5); arm()     // left
            default: break
            }
        } else if let c = keys.first {
            switch c {
            case UInt8(ascii: "q"), UInt8(ascii: "Q"), 0x03:
                running = false
            case UInt8(ascii: "a"), UInt8(ascii: "A"):
                if canWrite { applyAutoTUI(smc) }
                holdDeadline = nil
            case UInt8(ascii: "t"), UInt8(ascii: "T"):
                let idx = holdCycle.firstIndex(of: holdSeconds) ?? 0
                holdSeconds = holdCycle[(idx + 1) % holdCycle.count]
                arm()
            case UInt8(ascii: "+"), UInt8(ascii: "="): knob = min(100, knob + 5); arm()
            case UInt8(ascii: "-"), UInt8(ascii: "_"): knob = max(0, knob - 5); arm()
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                knob = Double(c - UInt8(ascii: "0")) * 10   // 1→10% … 9→90%, 0→0%
                arm()
            default: break
            }
        }
    }
}
