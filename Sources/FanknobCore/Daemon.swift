// Daemon.swift — client side of the fanknob daemon protocol (part of FanknobCore).
//
// The unprivileged CLI and app connect to the root daemon's Unix socket to send
// "set <0-100> [seconds]" and "auto" commands.

import Foundation
import Darwin

public enum DaemonResult: Equatable, Sendable {
    case ok(String)
    case unavailable
    case failed(String)
}

// MARK: - Singleton lock

public let fanknobdLockPath = "/var/run/fanknobd.lock"
public let daemonProtocolVersion = 2
public let maximumHoldSeconds = 24 * 60 * 60
public let maximumDaemonLineBytes = 2048
public let maximumWatchdogCelsius: Double = 120

/// The one definition of an acceptable watchdog threshold. The CLI, the
/// protocol parser and persisted-config validation must all agree — a value
/// one of them accepts but another rejects gets silently discarded as corrupt
/// on the next daemon boot.
public func isValidWatchdogCelsius(_ celsius: Double) -> Bool {
    celsius.isFinite && celsius > 0 && celsius <= maximumWatchdogCelsius
}

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
public enum DaemonCommand: Equatable, Sendable {
    case auto
    case set(pct: Double, holdSeconds: Int)
    case setFan(index: Int, pct: Double, holdSeconds: Int)
    case curve(FanCurve, preset: CurvePreset?)
    case watchdog(celsius: Double?)
    case state
}

public enum DaemonCommandError: Error, Equatable, Sendable {
    case empty
    case badSet
    case badFan
    case badCurve
    case badWatchdog
    case unknown(String)
}

/// Versioned response used by v2 clients. The server continues to accept and
/// answer the original text protocol so an already-running app from the
/// previous build remains usable during an upgrade.
public struct DaemonReply: Codable, Equatable, Sendable {
    public let ok: Bool
    public let protocolVersion: Int
    public let message: String
    public let state: DaemonState?

    public init(ok: Bool, message: String, state: DaemonState? = nil,
                protocolVersion: Int = daemonProtocolVersion) {
        self.ok = ok
        self.protocolVersion = protocolVersion
        self.message = message
        self.state = state
    }

    public func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"protocolVersion":2,"message":"response encoding failed"}"#
        }
        return text
    }

    public static func decode(_ text: String) -> DaemonReply? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DaemonReply.self, from: data)
    }
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

    func hold(_ index: Int) -> Int? {
        guard parts.count > index else { return 0 }
        guard let seconds = Int(parts[index]),
              (0...maximumHoldSeconds).contains(seconds) else { return nil }
        return seconds
    }

    switch verb {
    case "auto":
        guard parts.count == 1 else { return .failure(.unknown(verb)) }
        return .success(.auto)

    case "state":
        guard parts.count == 1 else { return .failure(.unknown(verb)) }
        return .success(.state)

    case "set":
        guard (2...3).contains(parts.count),
              let v = Double(parts[1]), v.isFinite,
              let seconds = hold(2) else {
            return .failure(.badSet)
        }
        return .success(.set(pct: v.clamped(0, 100), holdSeconds: seconds))

    case "setfan":
        guard (3...4).contains(parts.count),
              let i = Int(parts[1]), i >= 0, i < 64,
              let v = Double(parts[2]), v.isFinite,
              let seconds = hold(3) else {
            return .failure(.badFan)
        }
        return .success(.setFan(index: i, pct: v.clamped(0, 100), holdSeconds: seconds))

    case "curve":
        guard parts.count == 2, let curve = FanCurve.parse(parts[1]) else {
            return .failure(.badCurve)
        }
        return .success(.curve(curve, preset: nil))

    case "preset":
        guard parts.count == 2,
              let preset = CurvePreset(rawValue: parts[1].lowercased()) else {
            return .failure(.badCurve)
        }
        return .success(.curve(preset.curve, preset: preset))

    case "watchdog":
        guard parts.count == 2 else { return .failure(.badWatchdog) }
        if parts[1].lowercased() == "off" { return .success(.watchdog(celsius: nil)) }
        guard let c = Double(parts[1]), isValidWatchdogCelsius(c) else {
            return .failure(.badWatchdog)
        }
        return .success(.watchdog(celsius: c))

    default:
        return .failure(.unknown(verb))
    }
}

public enum DaemonSocketError: Error, Equatable, CustomStringConvertible, Sendable {
    case timeout
    case disconnected
    case tooLarge
    case invalidUTF8
    case system(String)

    public var description: String {
        switch self {
        case .timeout: return "daemon timed out"
        case .disconnected: return "daemon disconnected"
        case .tooLarge: return "daemon message exceeded \(maximumDaemonLineBytes) bytes"
        case .invalidUTF8: return "daemon sent invalid UTF-8"
        case .system(let message): return message
        }
    }
}

public func configureDaemonSocket(_ fd: Int32, timeoutSeconds: Int = 2) {
    var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                   socklen_t(MemoryLayout<timeval>.size))
    var noSignal: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                   socklen_t(MemoryLayout<Int32>.size))
}

public func readDaemonLine(_ fd: Int32,
                           maximumBytes: Int = maximumDaemonLineBytes) throws -> String {
    var bytes: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 256)
    while bytes.count <= maximumBytes {
        let count = recv(fd, &chunk, chunk.count, 0)
        if count > 0 {
            for byte in chunk.prefix(count) {
                if byte == 0x0A || byte == 0x0D {
                    guard let line = String(bytes: bytes, encoding: .utf8) else {
                        throw DaemonSocketError.invalidUTF8
                    }
                    return line
                }
                bytes.append(byte)
                if bytes.count > maximumBytes { throw DaemonSocketError.tooLarge }
            }
            continue
        }
        if count == 0 { throw DaemonSocketError.disconnected }
        if errno == EINTR { continue }
        if errno == EAGAIN || errno == EWOULDBLOCK { throw DaemonSocketError.timeout }
        throw DaemonSocketError.system(String(cString: strerror(errno)))
    }
    throw DaemonSocketError.tooLarge
}

public func writeDaemonLine(_ fd: Int32, _ line: String) throws {
    let bytes = Array((line + "\n").utf8)
    var sentCount = 0
    while sentCount < bytes.count {
        let sent = bytes.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return send(fd, base.advanced(by: sentCount), bytes.count - sentCount, 0)
        }
        if sent > 0 {
            sentCount += sent
            continue
        }
        if sent < 0 && errno == EINTR { continue }
        if sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
            throw DaemonSocketError.timeout
        }
        throw DaemonSocketError.system(String(cString: strerror(errno)))
    }
}

private func connectToDaemon() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    configureDaemonSocket(fd)

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
    guard connected == 0 else {
        Darwin.close(fd)
        return nil
    }
    return fd
}

private func requestDaemon(_ command: String) -> Result<String, DaemonSocketError>? {
    guard let fd = connectToDaemon() else { return nil }
    defer { Darwin.close(fd) }
    do {
        try writeDaemonLine(fd, command)
        return .success(try readDaemonLine(fd))
    } catch let error as DaemonSocketError {
        return .failure(error)
    } catch {
        return .failure(.system(error.localizedDescription))
    }
}

public func sendToDaemon(_ command: String) -> DaemonResult {
    // Negotiate v2 without breaking a daemon from the previous release. An old
    // daemon answers "unknown command: v2", at which point the request is
    // retried using the original protocol.
    guard let modern = requestDaemon("v2 \(command)") else { return .unavailable }
    switch modern {
    case .failure(let error):
        return .failed(error.description)
    case .success(let raw):
        if let reply = DaemonReply.decode(raw) {
            guard reply.ok else { return .failed(reply.message) }
            if let state = reply.state { return .ok(state.encoded()) }
            return .ok(reply.message)
        }
    }

    guard let legacy = requestDaemon(command) else { return .unavailable }
    switch legacy {
    case .success(let reply):
        return .ok(reply.trimmingCharacters(in: .whitespacesAndNewlines))
    case .failure(let error):
        return .failed(error.description)
    }
}

public func daemonReachable() -> Bool {
    guard let fd = connectToDaemon() else { return false }
    Darwin.close(fd)
    return true
}
