// FanModel.swift — observable state for the menu-bar app.
//
// Polls the FanController on a background serial queue (~1 Hz) and publishes
// fan/temp state back on the main queue. Writes (knob / auto) go through the
// daemon. Not @MainActor: threading is managed explicitly so the background SMC
// reads never touch @Published state off the main queue.

import SwiftUI
import Combine
import FanknobCore

final class FanModel: ObservableObject {
    private let controller = FanController()
    private let workQueue = DispatchQueue(label: "com.fanknob.app.smc")
    private var timer: Timer?

    @Published var fans: [Fan] = []
    @Published var cpu: Double?
    @Published var gpu: Double?
    @Published var sensorCount = 0
    @Published var canWrite = false
    @Published var opened = true

    @Published var knob: Double = 0
    @Published var holdSeconds = 0
    @Published var holdDeadline: Date?

    let chip = chipName()

    init() {
        opened = controller.opened
        // Seed from the current fan target (init runs before the timer, so this
        // is the only main-thread SMC access; afterwards it's workQueue-only).
        let snap = controller.snapshot()
        publish(snap: snap, writable: controller.canWrite)
        knob = snap.fans.first?.knob ?? 0

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: Derived

    var menuLabel: String {
        if let c = cpu { return "\(Int(c.rounded()))°" }
        if let g = gpu { return "\(Int(g.rounded()))°" }
        return "—"
    }

    var anyManual: Bool { fans.contains { $0.managed } }

    var countdown: String {
        guard let d = holdDeadline else { return "" }
        let s = max(0, Int(d.timeIntervalSinceNow.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Polling

    private func refresh() {
        workQueue.async { [weak self] in
            guard let self else { return }
            let snap = self.controller.snapshot()
            let writable = self.controller.canWrite
            DispatchQueue.main.async { self.publish(snap: snap, writable: writable) }
        }
    }

    /// Must be called on the main queue.
    private func publish(snap: Snapshot, writable: Bool) {
        fans = snap.fans
        cpu = snap.temps.cpu
        gpu = snap.temps.gpu
        sensorCount = snap.temps.all.count
        canWrite = writable
        if let d = holdDeadline, Date() >= d { holdDeadline = nil }
    }

    // MARK: Control (called from the UI on the main queue)

    func applyKnob() {
        guard canWrite else { return }
        let k = knob, h = holdSeconds
        holdDeadline = h > 0 ? Date().addingTimeInterval(Double(h)) : nil
        workQueue.async { [weak self] in self?.controller.setKnob(k, holdSeconds: h) }
    }

    func setAuto() {
        guard canWrite else { return }
        holdDeadline = nil
        workQueue.async { [weak self] in self?.controller.auto() }
    }
}
