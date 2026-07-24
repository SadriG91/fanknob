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

// MARK: - Protocol

/// A validated daemon command. The daemon accepts nothing else, which is what
/// keeps the root socket safe to expose to all local users.
public enum DaemonCommand: Equatable {
    case auto
    case set(pct: Double, holdSeconds: Int)
}

public enum DaemonCommandError: Error, Equatable {
    case empty
    case badSet
    case unknown(String)
}

/// Parse one protocol line ("auto" | "set <0-100> [seconds]"). Pure function —
/// clamping and validation happen here so they're unit-testable.
public func parseDaemonCommand(_ line: String) -> Result<DaemonCommand, DaemonCommandError> {
    let parts = line.split(separator: " ").map(String.init)
    guard let verb = parts.first else { return .failure(.empty) }
    switch verb {
    case "auto":
        return .success(.auto)
    case "set":
        guard parts.count >= 2, let v = Double(parts[1]), v.isFinite else {
            return .failure(.badSet)
        }
        let pct = v.clamped(0, 100)
        let seconds = parts.count >= 3 ? max(0, Int(parts[2]) ?? 0) : 0
        return .success(.set(pct: pct, holdSeconds: seconds))
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
