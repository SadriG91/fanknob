// Main.swift — privileged fan-control daemon (fanknobd).
//
// The testable safety/state machine lives in FanknobCore.DaemonEngine. This
// executable owns only root startup, signals, timers and the Unix socket.

import Foundation
import Darwin
import Dispatch
import FanknobCore

func log(_ message: String) {
    FileHandle.standardError.write(Data("fanknobd: \(message)\n".utf8))
}

/// All hardware and engine state is confined to this queue.
let smcQueue = DispatchQueue(label: "com.fanknob.smc")
let clientQueue = DispatchQueue(label: "com.fanknob.clients",
                                qos: .userInitiated, attributes: .concurrent)
let clientSlots = DispatchSemaphore(value: 16)

let tickSeconds = 2

private func serveClient(_ clientFD: Int32, engine: DaemonEngine) {
    defer {
        Darwin.close(clientFD)
        clientSlots.signal()
    }
    configureDaemonSocket(clientFD)

    do {
        let incoming = try readDaemonLine(clientFD)
        let modern = incoming.hasPrefix("v2 ")
        let command = modern ? String(incoming.dropFirst(3)) : incoming
        let reply = smcQueue.sync { engine.handle(command) }

        if command != "state" { log("cmd '\(command)' -> \(reply.ok ? "ok" : "error")") }
        if modern {
            try writeDaemonLine(clientFD, reply.encoded())
        } else if let state = reply.state {
            // Backward compatibility for an app/CLI already running while the
            // package is upgraded underneath it.
            try writeDaemonLine(clientFD, state.encoded())
        } else {
            try writeDaemonLine(clientFD, reply.message)
        }
    } catch let error as DaemonSocketError {
        if error != .disconnected { log("client: \(error)") }
    } catch {
        log("client: \(error)")
    }
}

@main
struct Fanknobd {
    static func main() {
        guard geteuid() == 0 else { log("must run as root"); exit(1) }

        guard acquireDaemonLock() != nil else {
            log("another fanknobd already holds \(fanknobdLockPath) — refusing to start")
            log("keep ONE install: `brew uninstall --cask fanknob`, or `sudo make uninstall` for a from-source copy")
            exit(1)
        }

        let smc = SMC()
        do { try smc.open() } catch { log("\(error)"); exit(1) }

        let engine = DaemonEngine(hardware: SMCFanHardware(smc: smc), logger: log)
        smcQueue.sync { @Sendable in engine.start() }

        // The dispatch-source handlers below are @Sendable on purpose. Under
        // Swift 6, @main's main() is implicitly @MainActor, and a plain
        // closure formed here inherits that isolation — the runtime then
        // enforces it when the source fires on smcQueue and kills the daemon
        // with EXC_BREAKPOINT (dispatch_assert_queue_fail) on the first tick.
        // @Sendable opts the closure out of the inherited isolation.
        let timer = DispatchSource.makeTimerSource(queue: smcQueue)
        timer.schedule(deadline: .now() + .seconds(tickSeconds),
                       repeating: .seconds(tickSeconds))
        timer.setEventHandler { @Sendable in engine.tick() }
        timer.resume()

        // SO_NOSIGPIPE protects individual sockets; ignoring SIGPIPE is a
        // process-wide backstop for a client disconnecting during a reply.
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let signalSources = [SIGTERM, SIGINT].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber,
                                                         queue: smcQueue)
            source.setEventHandler { @Sendable in
                engine.shutdown()
                unlink(fanknobdSocketPath)
                exit(0)
            }
            source.resume()
            return source
        }

        unlink(fanknobdSocketPath)
        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { log("socket() failed"); exit(1) }
        configureDaemonSocket(listenFD)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = fanknobdSocketPath.utf8CString
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in pathBytes.enumerated() where index < raw.count {
                raw[index] = UInt8(bitPattern: byte)
            }
        }
        let addressLength = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, addressLength)
            }
        }
        guard bound == 0 else {
            log("bind() failed: \(String(cString: strerror(errno)))")
            exit(1)
        }
        guard chmod(fanknobdSocketPath, 0o666) == 0 else {
            log("chmod() failed: \(String(cString: strerror(errno)))")
            exit(1)
        }
        guard listen(listenFD, 16) == 0 else { log("listen() failed"); exit(1) }
        log("listening on \(fanknobdSocketPath), protocol v\(daemonProtocolVersion)")

        withExtendedLifetime((timer, signalSources)) {
            while true {
                let clientFD = accept(listenFD, nil, nil)
                if clientFD < 0 {
                    if errno != EINTR {
                        log("accept() failed: \(String(cString: strerror(errno)))")
                    }
                    continue
                }
                clientSlots.wait()
                clientQueue.async { serveClient(clientFD, engine: engine) }
            }
        }
    }
}
