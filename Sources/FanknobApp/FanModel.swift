// FanModel.swift — observable state for the menu-bar app.
//
// Uses the Observation framework (@Observable) so SwiftUI only re-renders the
// views that read a given property — dragging the knob doesn't thrash the temp
// and fan gauges. Polls the FanController on a background serial queue (~1 Hz)
// and publishes state back on the main queue.

import SwiftUI
import Observation
import FanknobCore

@Observable
final class FanModel {
    @ObservationIgnored private let controller = FanController()
    @ObservationIgnored private let workQueue = DispatchQueue(label: "com.fanknob.app.smc")
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored let chip = chipName()

    var fans: [Fan] = []
    var cpu: Double?
    var gpu: Double?
    var sensorCount = 0
    var canWrite = false
    var opened = true

    var knob: Double = 0
    var holdSeconds = 0
    var holdDeadline: Date?

    /// True while the user is dragging the slider (don't sync from hardware then).
    var editing = false
    /// Optimistic current mode for the UI. Updated instantly on user action and
    /// reconciled with the hardware each tick.
    var manual = false

    init() {
        opened = controller.opened
        let snap = controller.snapshot()
        publish(snap: snap, writable: controller.canWrite)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollOnce()
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

    /// Read hardware once, off the main queue, then publish. Used by the periodic
    /// timer and right after a write so the UI updates immediately.
    private func pollOnce() {
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
        // Sync the knob from hardware ONLY in auto mode — in manual the knob is
        // the user's setpoint, and syncing would race with a just-applied value.
        if !editing {
            manual = snap.fans.contains { $0.managed }
            if !manual, let k = snap.fans.first?.knob { knob = k }
        }
        if let d = holdDeadline, Date() >= d { holdDeadline = nil }
    }

    // MARK: Control (called from the UI on the main queue)

    func setMode(_ toManual: Bool) {
        if toManual { enterManual() } else { setAuto() }
    }

    func enterManual() {
        guard canWrite else { return }
        applyKnob()
    }

    func setAuto() {
        guard canWrite else { return }
        manual = false
        holdDeadline = nil
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
