// Daemon.swift — client side of the fanknob daemon protocol (part of FanknobCore).
//
// The unprivileged CLI and app connect to the root daemon's Unix socket to send
// "set <0-100> [seconds]" and "auto" commands.

import Foundation
import Darwin

public enum DaemonResult {
    case ok(String)
    case unavailable
    case failed(String)
}

// MARK: - Singleton lock

public let fanknobdLockPath = "/var/run/fanknobd.lock"

/// Try to become the single fanknobd instance system-wide (e.g. a Homebrew-
/// managed daemon and a `make install` one must not fight over the socket).
///
/// Returns the lock's file descriptor — the caller must keep it open for the
/// daemon's lifetime — or nil if another live daemon holds the lock. flock
/// releases automatically when the holder exits or dies, so with launchd
/// keep-alive the losing daemon's periodic retries become automatic failover.
public func acquireDaemonLock(path: String = fanknobdLockPath) -> Int32? {
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { return nil }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        close(fd)
        return nil
    }
    return fd
}

// MARK: - Protocol

/// A validated daemon command. The daemon accepts nothing else, which is what
/// keeps the root socket safe to expose to all local users.
public enum DaemonCommand: Equatable {
    case auto
    case set(pct: Double, holdSeconds: Int)
    case setFan(index: Int, pct: Double, holdSeconds: Int)
    case curve(FanCurve, preset: CurvePreset?)
    case watchdog(celsius: Double?)
    case state
}

public enum DaemonCommandError: Error, Equatable {
    case empty
    case badSet
    case badFan
    case badCurve
    case badWatchdog
    case unknown(String)
}

/// Parse one protocol line. Pure function — clamping and validation happen
/// here so they're unit-testable, and so nothing unvalidated reaches the SMC.
///
///   auto
///   set <0-100> [seconds]
///   setfan <index> <0-100> [seconds]
///   curve <°C>:<%>,<°C>:<%>[,...]
///   preset quiet|balanced|turbo
///   watchdog <°C>|off
///   state
public func parseDaemonCommand(_ line: String) -> Result<DaemonCommand, DaemonCommandError> {
    let parts = line.split(separator: " ").map(String.init)
    guard let verb = parts.first else { return .failure(.empty) }

    func hold(_ index: Int) -> Int {
        parts.count > index ? max(0, Int(parts[index]) ?? 0) : 0
    }

    switch verb {
    case "auto":
        return .success(.auto)

    case "state":
        return .success(.state)

    case "set":
        guard parts.count >= 2, let v = Double(parts[1]), v.isFinite else {
            return .failure(.badSet)
        }
        return .success(.set(pct: v.clamped(0, 100), holdSeconds: hold(2)))

    case "setfan":
        guard parts.count >= 3, let i = Int(parts[1]), i >= 0, i < 64,
              let v = Double(parts[2]), v.isFinite else {
            return .failure(.badFan)
        }
        return .success(.setFan(index: i, pct: v.clamped(0, 100), holdSeconds: hold(3)))

    case "curve":
        guard parts.count >= 2, let curve = FanCurve.parse(parts[1]) else {
            return .failure(.badCurve)
        }
        return .success(.curve(curve, preset: nil))

    case "preset":
        guard parts.count >= 2, let preset = CurvePreset(rawValue: parts[1].lowercased()) else {
            return .failure(.badCurve)
        }
        return .success(.curve(preset.curve, preset: preset))

    case "watchdog":
        guard parts.count >= 2 else { return .failure(.badWatchdog) }
        if parts[1].lowercased() == "off" { return .success(.watchdog(celsius: nil)) }
        guard let c = Double(parts[1]), c.isFinite, c > 0, c <= 120 else {
            return .failure(.badWatchdog)
        }
        return .success(.watchdog(celsius: c))

    default:
        return .failure(.unknown(verb))
    }
}

public func sendToDaemon(_ command: String) -> DaemonResult {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return .failed("socket() failed") }
    defer { Darwin.close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = fanknobdSocketPath.utf8CString
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in pathBytes.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: b) }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard connected == 0 else { return .unavailable }

    let msg = command + "\n"
    _ = msg.withCString { send(fd, $0, strlen($0), 0) }

    var buf = [UInt8](repeating: 0, count: 1024)
    let n = recv(fd, &buf, buf.count, 0)
    let reply = n > 0 ? String(bytes: buf[0..<n], encoding: .utf8) ?? "" : ""
    return .ok(reply.trimmingCharacters(in: .whitespacesAndNewlines))
}

public func daemonReachable() -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { Darwin.close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pb = fanknobdSocketPath.utf8CString
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in pb.enumerated() where i < raw.count { raw[i] = UInt8(bitPattern: b) }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) == 0 }
    }
}
