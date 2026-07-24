// FanModel.swift — observable state for the menu-bar app.
//
// Threading model (the important part):
//   - ALL FanController/SMC access is confined to one serial workQueue. The
//     controller is even *created* there, keeping the ~0.4 s sensor discovery
//     off the main thread at launch.
//   - All published state is touched only on the main queue.
//   - Polls coalesce: a new poll is never queued while one is in flight, so
//     slow reads can't stack up and delay user actions behind them.
//   - `writesInFlight` guards against the "toggle bounce": a poll snapshotted
//     BEFORE a user action would otherwise publish AFTER it and yank the
//     optimistic UI state (Auto/Manual, knob) backwards for a beat.
//   - While dragging, the knob applies live but throttled (~6 writes/s).

import SwiftUI
import Observation
import FanknobCore

@Observable
final class FanModel {
    // workQueue-confined (created there in init; serial queue orders all access)
    @ObservationIgnored private var controller: FanController!
    @ObservationIgnored private let workQueue =
        DispatchQueue(label: "com.fanknob.app.smc", qos: .userInitiated)
    @ObservationIgnored private var timer: Timer?

    // main-queue-confined bookkeeping
    @ObservationIgnored private var pollInFlight = false
    @ObservationIgnored private var writesInFlight = 0
    @ObservationIgnored private var lastLiveApply = Date.distantPast
    @ObservationIgnored private var pendingLiveApply: DispatchWorkItem?

    @ObservationIgnored let chip = chipName()

    // MARK: Published state (main queue only)

    var fans: [Fan] = []
    var cpu: Double?
    var gpu: Double?
    var canWrite = false
    /// False until the first hardware snapshot lands (sensor discovery ~0.4 s).
    var ready = false

    var knob: Double = 0
    var holdSeconds = 0
    var holdDeadline: Date?
    /// Seconds left on an armed hold; ticks down with each poll.
    var holdRemaining = 0

    /// True while the user is dragging the slider.
    var editing = false
    /// Optimistic mode for the UI; reconciled with hardware when no write is
    /// in flight and the user isn't dragging.
    var manual = false

    init() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.controller = FanController()   // opens SMC + discovers sensors
            let snap = self.controller.snapshot()
            let writable = self.controller.canWrite
            DispatchQueue.main.async {
                self.ready = true
                self.publish(snap: snap, writable: writable)
                if !self.manual { self.knob = snap.fans.first?.knob ?? 0 }
            }
        }
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
        String(format: "%d:%02d", holdRemaining / 60, holdRemaining % 60)
    }

    // MARK: Polling (pollOnce/publish run on the main queue)

    private func pollOnce() {
        guard !pollInFlight else { return }   // coalesce: never stack polls
        pollInFlight = true
        workQueue.async { [weak self] in
            guard let self, self.controller != nil else {
                DispatchQueue.main.async { self?.pollInFlight = false }
                return
            }
            let snap = self.controller.snapshot()
            let writable = self.controller.canWrite
            DispatchQueue.main.async {
                self.pollInFlight = false
                self.publish(snap: snap, writable: writable)
            }
        }
    }

    private func publish(snap: Snapshot, writable: Bool) {
        fans = snap.fans
        cpu = snap.temps.cpu
        gpu = snap.temps.gpu
        canWrite = writable
        // Reconcile mode/knob with hardware ONLY when the user isn't mid-action:
        // a poll snapshotted before a write must not undo the optimistic state.
        if !editing && writesInFlight == 0 {
            manual = snap.fans.contains { $0.managed }
            if !manual, let k = snap.fans.first?.knob { knob = k }
        }
        if let d = holdDeadline {
            holdRemaining = max(0, Int(d.timeIntervalSinceNow.rounded()))
            if holdRemaining == 0 { holdDeadline = nil }
        }
    }

    /// Run a controller write on the workQueue, tracking it so polls can't
    /// clobber optimistic UI state, then refresh immediately after it lands.
    private func performWrite(_ op: @escaping (FanController) -> Void) {
        writesInFlight += 1
        workQueue.async { [weak self] in
            guard let self else { return }
            op(self.controller)
            DispatchQueue.main.async {
                self.writesInFlight -= 1
                self.pollOnce()
            }
        }
    }

    // MARK: Control (called from the UI on the main queue)

    func setMode(_ toManual: Bool) {
        if toManual { applyKnob() } else { setAuto() }
    }

    func setAuto() {
        guard canWrite else { return }
        pendingLiveApply?.cancel(); pendingLiveApply = nil
        manual = false
        holdDeadline = nil
        holdRemaining = 0
        performWrite { $0.auto() }
    }

    /// Authoritative apply: slider release, mode switch, or hold change.
    func applyKnob() {
        guard canWrite else { return }
        pendingLiveApply?.cancel(); pendingLiveApply = nil
        manual = true
        lastLiveApply = Date()
        let k = knob, h = holdSeconds
        holdDeadline = h > 0 ? Date().addingTimeInterval(Double(h)) : nil
        holdRemaining = h
        performWrite { $0.setKnob(k, holdSeconds: h) }
    }

    /// Live apply while dragging, throttled to ~6 writes/s with a trailing
    /// edge so the final drag position is never dropped.
    func liveApply() {
        guard editing, canWrite else { return }
        manual = true
        let now = Date()
        if now.timeIntervalSince(lastLiveApply) >= 0.15 {
            lastLiveApply = now
            let k = knob, h = holdSeconds
            performWrite { $0.setKnob(k, holdSeconds: h) }
        } else if pendingLiveApply == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.pendingLiveApply = nil
                self?.liveApply()
            }
            pendingLiveApply = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
        }
    }
}
