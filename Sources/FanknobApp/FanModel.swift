// FanModel.swift — observable state for the menu-bar app.
//
// Threading model (the important part):
//   - ALL FanController/SMC access is confined to one serial workQueue. The
//     controller is even *created* there, keeping the ~0.4 s sensor discovery
//     off the main thread at launch.
//   - All published state is touched only on the main queue.
//   - Polls coalesce: a new poll is never queued while one is in flight, so
//     slow reads can't stack up and delay user actions behind them.
//   - `writesInFlight` and the mode intent guard stop a poll snapshotted
//     BEFORE a user action from publishing AFTER it and yanking the UI back.
//   - While dragging, the knob applies live but throttled (~6 writes/s).
//
// Mode of record is the DAEMON's own state when it's reachable: in curve mode
// the SMC just reports "manual", so only the daemon knows a curve is driving.

import SwiftUI
import Observation
import ServiceManagement
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

enum UIMode: String, CaseIterable {
    case auto, manual, curve
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
    // Mode intent guard, for the no-daemon case where the SMC reports the OLD
    // fan mode for tens of ms after a write.
    @ObservationIgnored private var pendingMode: UIMode?
    @ObservationIgnored private var pendingModeUntil = Date.distantPast
    @ObservationIgnored private var tick = 0

    @ObservationIgnored let chip = chipName()

    // MARK: Published state (main queue only)

    var fans: [Fan] = []
    var cpu: Double?
    var gpu: Double?
    var canWrite = false
    /// False until the first hardware snapshot lands (sensor discovery ~0.4 s).
    var ready = false
    /// Menu-bar degrees, updated only when the shown integer changes.
    var menuTemp: Int?
    /// Whether the popover window is on screen — drives poll cadence and
    /// pauses the spinner (MenuBarExtra keeps the view alive while closed).
    var popoverShown = false

    var mode: UIMode = .auto
    var knob: Double = 0
    /// Per-fan setpoints for unlinked manual control.
    var fanKnobs: [Int: Double] = [:]
    var linkFans = true

    var preset: CurvePreset = .balanced
    /// What the curve is asking for right now (daemon-reported).
    var curveKnob: Double?

    var holdSeconds = 0
    var holdRemaining = 0
    var watchdogCelsius: Double? = DaemonConfig.defaultWatchdogCelsius
    var watchdogTripped = false
    /// True when no daemon is running but the app could still drive fans as
    /// root — curves need the daemon, so the UI hides them.
    var daemonPresent = false

    /// True while the user is dragging a slider.
    var editing = false

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                newValue ? try SMAppService.mainApp.register()
                         : try SMAppService.mainApp.unregister()
            } catch {
                UILog.log("launch-at-login \(newValue) failed: \(error)")
            }
        }
    }

    init() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.controller = FanController()   // opens SMC + discovers sensors
            let snap = self.controller.snapshot(.full)
            let writable = self.controller.canWrite
            let state = self.controller.daemonState()
            DispatchQueue.main.async {
                self.ready = true
                self.publish(snap: snap, writable: writable, state: state)
                if self.mode != .manual { self.knob = snap.fans.first?.knob ?? 0 }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            tick += 1
            let visible = popoverIsVisible
            if popoverShown != visible { popoverShown = visible }
            if visible {
                pollOnce(.full)
            } else if tick % 5 == 0 {
                pollOnce(.light)
            }
        }
    }

    /// The MenuBarExtra content window, when shown. The status item itself is
    /// also an NSWindow, so filter by height.
    private var popoverIsVisible: Bool {
        NSApp.windows.contains { $0.isVisible && $0.frame.height > 50 }
    }

    /// Called from the popover's onAppear: refresh everything immediately so
    /// the UI is fresh the moment it opens, instead of one tick later.
    func popoverOpened() {
        popoverShown = true
        pollOnce(.full)
    }

    // MARK: Derived

    var menuLabel: String {
        if let t = menuTemp { return "\(t)°" }
        return "—"
    }

    /// The user is overriding the firmware (manual or curve).
    var overriding: Bool { mode != .auto }

    var countdown: String {
        String(format: "%d:%02d", holdRemaining / 60, holdRemaining % 60)
    }

    /// Effective knob to display: the curve's output in curve mode, else the
    /// slider position.
    var displayKnob: Double {
        mode == .curve ? (curveKnob ?? 0) : knob
    }

    /// Spin rate for the popover's fan icon: gentle at idle, brisk at full
    /// blast, tracking the fastest fan's position in its RPM range.
    var iconRevsPerSecond: Double {
        let fraction = fans
            .compactMap { $0.max > $0.min ? ($0.actual - $0.min) / ($0.max - $0.min) : nil }
            .max() ?? 0
        return 0.4 + 2.6 * fraction.clamped(0, 1)
    }

    // MARK: Polling (all on the main queue)

    private func pollOnce(_ scope: SnapshotScope = .full) {
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
            let snap = self.controller.snapshot(scope)
            let writable = self.controller.canWrite
            let state = self.controller.daemonState()
            DispatchQueue.main.async {
                self.pollInFlight = false
                self.publish(snap: snap, writable: writable, state: state)
                if self.pollAgain { self.pollAgain = false; self.pollOnce(.full) }
            }
        }
    }

    private func publish(snap: Snapshot, writable: Bool, state: DaemonState?) {
        // Assign only when values change: @Observable notifies on every set,
        // and spurious sets re-render the control views each poll.
        if fans != snap.fans { fans = snap.fans }
        if cpu != snap.temps.cpu { cpu = snap.temps.cpu }
        if let g = snap.temps.gpu, gpu != g { gpu = g }   // light polls omit GPU
        if canWrite != writable { canWrite = writable }
        if daemonPresent != (state != nil) { daemonPresent = state != nil }

        let shownTemp = (snap.temps.cpu ?? snap.temps.gpu).map { Int($0.rounded()) }
        if menuTemp != shownTemp { menuTemp = shownTemp }

        // Clear the intent guard once reality agrees (or it times out).
        if let want = pendingMode {
            let actual = observedMode(snap: snap, state: state)
            if actual == want || Date() >= pendingModeUntil { pendingMode = nil }
        }

        guard !editing, writesInFlight == 0, pendingMode == nil else { return }

        let observed = observedMode(snap: snap, state: state)
        if mode != observed { mode = observed }

        if let state {
            if let p = state.preset.flatMap(CurvePreset.init(rawValue:)), preset != p { preset = p }
            if curveKnob != state.knob && observed == .curve { curveKnob = state.knob }
            if watchdogCelsius != state.watchdogCelsius { watchdogCelsius = state.watchdogCelsius }
            if watchdogTripped != state.watchdogTripped { watchdogTripped = state.watchdogTripped }
            if holdRemaining != state.holdRemaining { holdRemaining = state.holdRemaining }
        }

        // In manual mode the fans' targets ARE the setpoints, so mirroring them
        // keeps the UI honest when the CLI or TUI changes something. Never sync
        // in auto (the firmware target drifts constantly and would re-render
        // the controls mid-click).
        if observed == .manual {
            var perFan: [Int: Double] = [:]
            for f in snap.fans { perFan[f.index] = f.knob.rounded() }
            if fanKnobs != perFan { fanKnobs = perFan }
            if let first = snap.fans.first?.knob.rounded(), linkFans, knob != first { knob = first }
        }
    }

    /// Mode of record: the daemon knows about curves; the SMC only sees
    /// "managed". Fall back to the SMC when there's no daemon.
    private func observedMode(snap: Snapshot, state: DaemonState?) -> UIMode {
        if let state { return UIMode(rawValue: state.mode) ?? .auto }
        return snap.fans.contains { $0.managed } ? .manual : .auto
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

    private func intend(_ m: UIMode) {
        mode = m
        pendingMode = m
        pendingModeUntil = Date().addingTimeInterval(1.5)
        watchdogTripped = false
    }

    // MARK: Control (called from the UI on the main queue)

    func setMode(_ m: UIMode) {
        guard canWrite, m != mode else { return }
        switch m {
        case .auto:   setAuto()
        case .manual: applyKnob()
        case .curve:  selectPreset(preset)
        }
    }

    func setAuto() {
        guard canWrite else { return }
        pendingLiveApply?.cancel(); pendingLiveApply = nil
        intend(.auto)
        holdRemaining = 0
        curveKnob = nil
        performWrite { $0.auto() }
    }

    /// Authoritative apply: slider release, mode switch, or hold change.
    /// `fan` targets a single fan when the user has unlinked them.
    func applyKnob(fan: Int? = nil) {
        guard canWrite else { return }
        pendingLiveApply?.cancel(); pendingLiveApply = nil
        intend(.manual)
        lastLiveApply = Date()
        let pct = fan.flatMap { fanKnobs[$0] } ?? knob
        let hold = holdSeconds
        holdRemaining = hold
        if fan == nil && linkFans {
            for i in fans.map(\.index) { fanKnobs[i] = knob }
        }
        performWrite { $0.setKnob(pct, fan: fan, holdSeconds: hold) }
    }

    /// Live apply while dragging, throttled to ~6 writes/s with a trailing
    /// edge so the final drag position is never dropped.
    func liveApply(fan: Int? = nil) {
        guard editing, canWrite else { return }
        mode = .manual
        let now = Date()
        if now.timeIntervalSince(lastLiveApply) >= 0.15 {
            lastLiveApply = now
            let pct = fan.flatMap { fanKnobs[$0] } ?? knob
            let hold = holdSeconds
            performWrite { $0.setKnob(pct, fan: fan, holdSeconds: hold) }
        } else if pendingLiveApply == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.pendingLiveApply = nil
                self?.liveApply(fan: fan)
            }
            pendingLiveApply = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: work)
        }
    }

    func selectPreset(_ p: CurvePreset) {
        guard canWrite, daemonPresent else { return }
        preset = p
        intend(.curve)
        holdRemaining = 0
        performWrite { $0.setPreset(p) }
    }

    func setWatchdog(_ celsius: Double?) {
        guard canWrite, daemonPresent else { return }
        watchdogCelsius = celsius
        performWrite { $0.setWatchdog(celsius) }
    }
}
