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

    /// True while the user is dragging the slider (don't sync from hardware then).
    @Published var editing = false
    /// Optimistic current mode for the UI. Updated instantly on user action and
    /// reconciled with the hardware each tick.
    @Published var manual = false

    let chip = chipName()

    init() {
        opened = controller.opened
        let snap = controller.snapshot()
        publish(snap: snap, writable: controller.canWrite)
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

    var countdown: String {
        guard let d = holdDeadline else { return "" }
        let s = max(0, Int(d.timeIntervalSinceNow.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Polling

    private func refresh() { pollOnce() }

    /// Must be called on the main queue.
    private func publish(snap: Snapshot, writable: Bool) {
        fans = snap.fans
        cpu = snap.temps.cpu
        gpu = snap.temps.gpu
        sensorCount = snap.temps.all.count
        canWrite = writable
        // Reflect reality when the user isn't turning the knob. The knob is
        // synced from hardware ONLY in auto mode — in manual the knob is the
        // user's setpoint, and syncing it would race with a just-applied value
        // and yank the slider back for a frame.
        if !editing {
            manual = snap.fans.contains { $0.managed }
            if !manual, let k = snap.fans.first?.knob { knob = k }
        }
        if let d = holdDeadline, Date() >= d { holdDeadline = nil }
    }

    /// Read hardware once, off the main queue, then publish. Used both by the
    /// periodic timer and right after a write so the UI updates immediately.
    private func pollOnce() {
        workQueue.async { [weak self] in
            guard let self else { return }
            let snap = self.controller.snapshot()
            let writable = self.controller.canWrite
            DispatchQueue.main.async { self.publish(snap: snap, writable: writable) }
        }
    }

    // MARK: Control (called from the UI on the main queue)

    /// Segmented Auto/Manual control.
    func setMode(_ toManual: Bool) {
        if toManual { enterManual() } else { setAuto() }
    }

    func enterManual() {
        guard canWrite else { return }
        applyKnob()   // takes manual control at the current knob position
    }

    func setAuto() {
        guard canWrite else { return }
        manual = false
        holdDeadline = nil
        // Serial queue: the write runs first, then pollOnce reads the new state.
        workQueue.async { [weak self] in self?.controller.auto() }
        pollOnce()
    }

    func applyKnob() {
        guard canWrite else { return }
        manual = true
        let k = knob, h = holdSeconds
        holdDeadline = h > 0 ? Date().addingTimeInterval(Double(h)) : nil
        workQueue.async { [weak self] in self?.controller.setKnob(k, holdSeconds: h) }
        pollOnce()
    }
}
