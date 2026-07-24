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

// Diagnostics: timestamped event log at /tmp/fanknob-ui.log.
// Off by default; launch with FANKNOB_DEBUG=1 to enable.
enum UILog {
    private static let enabled =
        ProcessInfo.processInfo.environment["FANKNOB_DEBUG"] == "1"
    private static let q = DispatchQueue(label: "com.fanknob.uilog")
    private static let handle: FileHandle? = {
        let path = "/tmp/fanknob-ui.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    static func log(_ s: String) {
        guard enabled else { return }
        let t = Date().timeIntervalSince1970
        q.async {
            handle?.write(String(format: "%.3f  %@\n", t, s).data(using: .utf8)!)
        }
    }
}

@Observable
final class FanModel {
    // workQueue-confined (created there in init; serial queue orders all access)
    @ObservationIgnored private var controller: FanController!
    @ObservationIgnored private let workQueue =
        DispatchQueue(label: "com.fanknob.app.smc", qos: .userInitiated)
    @ObservationIgnored private var timer: Timer?

    // main-queue-confined bookkeeping
    @ObservationIgnored private var pollInFlight = false
    @ObservationIgnored private var pollAgain = false
    @ObservationIgnored private var writesInFlight = 0
    @ObservationIgnored private var lastLiveApply = Date.distantPast
    @ObservationIgnored private var pendingLiveApply: DispatchWorkItem?
    // Mode intent guard: the SMC reports the OLD fan mode for tens of ms after
    // a write (the fan firmware applies mode changes asynchronously), so a
    // poll right after a completed write reads stale hardware and would yank
    // the toggle back. After a user action we suspend mode reconciliation
    // until the hardware AGREES with the intent — or a timeout passes (write
    // genuinely failed / external change), at which point hardware wins again.
    @ObservationIgnored private var pendingMode: Bool?
    @ObservationIgnored private var pendingModeUntil = Date.distantPast

    @ObservationIgnored let chip = chipName()

    // MARK: Published state (main queue only)

    var fans: [Fan] = []
    var cpu: Double?
    var gpu: Double?
    var canWrite = false
    /// False until the first hardware snapshot lands (sensor discovery ~0.4 s).
    var ready = false
    /// Menu-bar degrees. Separate from `cpu` and updated only when the shown
    /// integer changes, so the status-item label re-renders rarely instead of
    /// every poll.
    var menuTemp: Int?

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
        if let t = menuTemp { return "\(t)°" }
        return "—"
    }

    var countdown: String {
        String(format: "%d:%02d", holdRemaining / 60, holdRemaining % 60)
    }

    /// Spin rate for the popover's fan icon: gentle at idle, brisk at full
    /// blast, tracking the fastest fan's position in its RPM range.
    var iconRevsPerSecond: Double {
        let fraction = fans
            .compactMap { $0.max > $0.min ? ($0.actual - $0.min) / ($0.max - $0.min) : nil }
            .max() ?? 0
        return 0.4 + 2.6 * fraction.clamped(0, 1)
    }

    // MARK: Polling (pollOnce/publish run on the main queue)

    private func pollOnce() {
        // Coalesce, but never drop a request: if a poll is in flight, run one
        // more right after it. This guarantees the immediate refresh after a
        // write can't be swallowed by an overlapping timer poll.
        guard !pollInFlight else { pollAgain = true; return }
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
                if self.pollAgain { self.pollAgain = false; self.pollOnce() }
            }
        }
    }

    private func publish(snap: Snapshot, writable: Bool) {
        // Assign only when values actually change: @Observable notifies on
        // every set (no equality check), and spurious sets re-render the
        // control views each poll — interrupting the toggle's click animation.
        if fans != snap.fans { fans = snap.fans }
        if cpu != snap.temps.cpu { cpu = snap.temps.cpu }
        if gpu != snap.temps.gpu { gpu = snap.temps.gpu }
        if canWrite != writable { canWrite = writable }
        let shownTemp = (snap.temps.cpu ?? snap.temps.gpu).map { Int($0.rounded()) }
        if menuTemp != shownTemp { menuTemp = shownTemp }
        // Reconcile mode with hardware ONLY when the user isn't mid-action:
        // a poll snapshotted before a write must not undo the optimistic state.
        //
        // Deliberately NO knob sync here: in auto the firmware target drifts
        // across whole-% boundaries almost every poll, and each sync re-rendered
        // the control section — if that rebuild landed between mouse-down and
        // mouse-up on the mode toggle, AppKit cancelled the click ("sticky
        // toggle"). The knob is the user's setpoint; it's seeded on entering
        // Manual instead.
        if !editing {
            let hwManual = snap.fans.contains { $0.managed }
            // Clear the intent once hardware catches up (or on timeout).
            if let want = pendingMode, hwManual == want || Date() >= pendingModeUntil {
                pendingMode = nil
            }
            if pendingMode == nil && writesInFlight == 0 && manual != hwManual {
                UILog.log("publish: manual \(manual) -> \(hwManual)")
                manual = hwManual
            }
        }
        if let d = holdDeadline {
            let left = max(0, Int(d.timeIntervalSinceNow.rounded()))
            if holdRemaining != left { holdRemaining = left }
            if left == 0 { holdDeadline = nil }
        }
    }

    /// Run a controller write on the workQueue, tracking it so polls can't
    /// clobber optimistic UI state, then refresh immediately after it lands.
    private func performWrite(_ op: @escaping (FanController) -> Void) {
        writesInFlight += 1
        UILog.log("write enqueued (inFlight=\(writesInFlight))")
        workQueue.async { [weak self] in
            guard let self else { return }
            let t = Date()
            op(self.controller)
            UILog.log(String(format: "write op done in %.0f ms", -t.timeIntervalSinceNow * 1000))
            DispatchQueue.main.async {
                self.writesInFlight -= 1
                self.pollOnce()
            }
        }
    }

    // MARK: Control (called from the UI on the main queue)

    func setMode(_ toManual: Bool) {
        UILog.log("setMode(\(toManual)) manual=\(manual) canWrite=\(canWrite)")
        if toManual {
            // Seed the knob from the current speed so Manual takes over right
            // where the firmware left off (fans data is ≤1 s old).
            if !manual, let k = fans.first?.knob { knob = k.rounded() }
            applyKnob()
        } else {
            setAuto()
        }
    }

    func setAuto() {
        guard canWrite else { return }
        pendingLiveApply?.cancel(); pendingLiveApply = nil
        manual = false
        pendingMode = false
        pendingModeUntil = Date().addingTimeInterval(1.5)
        holdDeadline = nil
        holdRemaining = 0
        performWrite { $0.auto() }
    }

    /// Authoritative apply: slider release, mode switch, or hold change.
    func applyKnob() {
        guard canWrite else { return }
        pendingLiveApply?.cancel(); pendingLiveApply = nil
        manual = true
        pendingMode = true
        pendingModeUntil = Date().addingTimeInterval(1.5)
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
