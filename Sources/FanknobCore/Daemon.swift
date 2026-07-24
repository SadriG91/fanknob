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
