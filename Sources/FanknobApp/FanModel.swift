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
import UserNotifications
import UniformTypeIdentifiers
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

private let askedAboutLoginKey = "askedAboutLaunchAtLogin"
private let notificationsKey = "safetyNotificationsEnabled"
private let curveProfilesKey = "savedCurveProfiles"

struct HistorySample: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let cpu: Double?
    let gpu: Double?
    let fanPercent: Double?
    let fanRPM: Double?
}

struct CurveProfile: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var points: [FanCurve.Point]

    init(id: UUID = UUID(), name: String, points: [FanCurve.Point]) {
        self.id = id
        self.name = name
        self.points = points
    }
}

@MainActor
private func loadCurveProfiles() -> [CurveProfile] {
    guard let data = UserDefaults.standard.data(forKey: curveProfilesKey) else { return [] }
    return ((try? JSONDecoder().decode([CurveProfile].self, from: data)) ?? [])
        .filter { FanCurve($0.points) != nil }
}

/// What a per-fan badge should say.
enum FanBadge: String {
    case auto = "AUTO", manual = "MANUAL", curve = "CURVE"
    var overridden: Bool { self != .auto }
}

@MainActor
@Observable
final class FanModel: @unchecked Sendable {
    // workQueue-confined (created there in init; serial queue orders all access)
    // These two properties are intentionally excluded from main-actor
    // isolation: every access is serialized by workQueue. FanModel itself is
    // @unchecked Sendable only so those queue hops can retain it; all
    // observable UI state remains main-actor isolated.
    @ObservationIgnored nonisolated(unsafe) private var controller: FanController!
    @ObservationIgnored nonisolated private let workQueue =
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
    @ObservationIgnored private var lastHistoryDate = Date.distantPast
    @ObservationIgnored private var lastNotifiedSafetyReason: String?
    @ObservationIgnored private var helperFailurePolls = 0
    @ObservationIgnored private var helperFailureNotified = false
    @ObservationIgnored private var previousHoldRemaining = 0

    @ObservationIgnored let chip = chipName()

    // MARK: Published state (main queue only)

    var fans: [Fan] = []
    var cpu: Double?
    var gpu: Double?
    /// Every temperature sensor, hottest first. Only refreshed by full polls
    /// (a light poll reads the CPU cluster alone), which is exactly when the
    /// popover is open and the expanded lists are visible.
    var sensors: [TempSensor] = []
    var canWrite = false
    /// False until the first hardware snapshot lands (sensor discovery ~0.4 s).
    var ready = false
    /// Menu-bar degrees, updated only when the shown integer changes.
    var menuTemp: Int?
    /// Whether the popover window is on screen — drives poll cadence and
    /// pauses the spinner (MenuBarExtra keeps the view alive while closed).
    var popoverShown = false

    var mode: UIMode = .auto
    /// The user's manual setpoint (only meaningful in manual mode).
    var knob: Double = 0
    /// What the fans are actually doing, from the SMC. Drives the slider as a
    /// live readout in auto/curve so switching to manual never jumps.
    var hardwareKnob: Double = 0
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
    var safetyReason: String?
    var controlError: String?
    /// True when no daemon is running but the app could still drive fans as
    /// root — curves need the daemon, so the UI hides them.
    var daemonPresent = false
    var lastDaemonState: DaemonState?

    /// True while the user is dragging a slider.
    var editing = false
    var history: [HistorySample] = []
    var showCurveEditor = false
    var curveProfiles: [CurveProfile] = loadCurveProfiles()
    var notificationsEnabled = UserDefaults.standard.bool(forKey: notificationsKey)
    private(set) var loginItemStatus = SMAppService.mainApp.status
    var loginItemError: String?

    var launchAtLogin: Bool {
        get { loginItemStatus == .enabled }
        set { setLaunchAtLogin(newValue) }
    }

    /// Whether we've offered to keep fanknob in the menu bar.
    ///
    /// A menu-bar app that disappears at the next reboot looks broken, but
    /// registering a login item behind someone's back is worse — macOS lists it
    /// in Settings as something the app did on its own. So the popover asks,
    /// once, and remembers the answer either way.
    ///
    /// Stored rather than computed: @Observable only tracks stored properties,
    /// and a computed UserDefaults wrapper wouldn't re-render the popover when
    /// the offer is answered.
    var askedAboutLogin = UserDefaults.standard.bool(forKey: askedAboutLoginKey) {
        didSet { UserDefaults.standard.set(askedAboutLogin, forKey: askedAboutLoginKey) }
    }

    /// True only while the offer is worth showing: we haven't asked, and it
    /// isn't already on (someone may have enabled it from a previous install).
    var shouldOfferLogin: Bool {
        (!askedAboutLogin && !launchAtLogin) || loginItemError != nil
            || loginItemStatus == .requiresApproval
    }

    #if DEBUG
    /// Builds a model that touches no hardware and starts no timer, so the
    /// documentation screenshots can be rendered from the real views with
    /// known values. See Shots.swift. Never compiled into a release build.
    init(fixture: Void) {
        // Property observers are not called during initialization, so this
        // suppresses the offer without writing screenshot state to UserDefaults.
        askedAboutLogin = true
        ready = true
        canWrite = true
        daemonPresent = true
    }
    #endif

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
            Task { @MainActor [weak self] in self?.timerFired() }
        }
    }

    private func timerFired() {
        tick += 1
        let visible = popoverIsVisible
        if popoverShown != visible { popoverShown = visible }
        if visible {
            pollOnce(.full)
        } else if tick % 5 == 0 {
            pollOnce(.light)
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
        refreshLoginItemStatus()
        pollOnce(.full)
    }

    // MARK: Derived

    var menuLabel: String {
        if let t = menuTemp { return "\(t)°" }
        return "—"
    }

    /// Sensors belonging to one cluster ("Tp" = CPU cores, "Tg" = GPU).
    func clusterSensors(prefix: String) -> [TempSensor] {
        sensors.filter { $0.key.hasPrefix(prefix) }
    }

    /// The user is overriding the firmware (manual or curve).
    var overriding: Bool { mode != .auto }

    /// True while a command is on its way to the hardware. The SMC reports the
    /// OLD fan mode for tens of ms after a write, so anything derived from
    /// `Fan.managed` has to ride that out.
    private var settling: Bool { pendingMode != nil || writesInFlight > 0 }

    /// What's actually driving a fan.
    ///
    /// Deliberately resolved from the app's mode, not from `Fan.managed`
    /// alone: the SMC can't tell a curve from a fixed speed (both are just
    /// "managed"), and it lags every write. Reading the flag directly made the
    /// badges flash a bogus MANUAL on the way from CURVE to AUTO.
    func badge(for fan: Fan) -> FanBadge {
        switch mode {
        case .auto:   return .auto      // the daemon releases every fan at once
        case .curve:  return .curve     // …and drives every fan at once
        case .manual: return (fan.managed || settling) ? .manual : .auto
        }
    }

    var countdown: String {
        String(format: "%d:%02d", holdRemaining / 60, holdRemaining % 60)
    }

    /// What the slider shows. In manual it's the user's setpoint; otherwise
    /// it's a live readout of what the curve or the firmware is doing — so
    /// entering manual can take over from exactly that position.
    var displayKnob: Double {
        switch mode {
        case .manual: return knob
        case .curve:  return curveKnob ?? hardwareKnob
        case .auto:   return hardwareKnob
        }
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
                self.publish(snap: snap, writable: writable, state: state, scope: scope)
                if self.pollAgain { self.pollAgain = false; self.pollOnce(.full) }
            }
        }
    }

    private func publish(snap: Snapshot, writable: Bool, state: DaemonState?,
                         scope: SnapshotScope = .full) {
        // Assign only when values change: @Observable notifies on every set,
        // and spurious sets re-render the control views each poll.
        if fans != snap.fans { fans = snap.fans }
        if cpu != snap.temps.cpu { cpu = snap.temps.cpu }
        if let g = snap.temps.gpu, gpu != g { gpu = g }   // light polls omit GPU
        if scope == .full { sensors = snap.temps.all }
        if canWrite != writable { canWrite = writable }
        if daemonPresent != (state != nil) { daemonPresent = state != nil }
        if lastDaemonState != state { lastDaemonState = state }
        recordHistory(snap)
        handleNotificationTransitions(state)

        let shownTemp = (snap.temps.cpu ?? snap.temps.gpu).map { Int($0.rounded()) }
        if menuTemp != shownTemp { menuTemp = shownTemp }

        // Live hardware position. Safe to update every poll: the slider is a
        // read-only gauge unless we're in manual, so this can't cancel a click
        // (the lesson from the sticky-toggle bug).
        if let hw = snap.fans.first?.knob.rounded(), hardwareKnob != hw { hardwareKnob = hw }

        // Clear the intent guard once reality agrees (or it times out).
        //
        // "Reality" is BOTH the daemon and the hardware: the daemon answers
        // instantly, but the SMC's per-fan `managed` flag lags a beat behind
        // it. Clearing on the daemon alone let the badges fall back to a stale
        // flag for one poll and flash the previous mode.
        if let want = pendingMode {
            let actual = observedMode(snap: snap, state: state)
            let fansAgree = want == .auto
                ? snap.fans.allSatisfy { !$0.managed }
                : snap.fans.contains { $0.managed }
            if (actual == want && fansAgree) || Date() >= pendingModeUntil {
                pendingMode = nil
            }
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
            if safetyReason != state.safetyReason { safetyReason = state.safetyReason }
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
    private func performWrite(_ op: @escaping @Sendable (FanController) -> Bool) {
        writesInFlight += 1
        workQueue.async { [weak self] in
            guard let self else { return }
            let succeeded = op(self.controller)
            let message = self.controller.lastError
            DispatchQueue.main.async {
                self.writesInFlight -= 1
                if succeeded {
                    self.controlError = nil
                } else {
                    self.controlError = message ?? "The fan-control request failed."
                }
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
        case .auto:
            setAuto()
        case .manual:
            // Take over from whatever the slider is already showing (the
            // firmware's speed, or the curve's output) so nothing jumps.
            knob = displayKnob
            applyKnob()
        case .curve:
            selectPreset(preset)
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

    func applyCustomCurve(_ curve: FanCurve) {
        guard canWrite, daemonPresent else { return }
        intend(.curve)
        holdRemaining = 0
        preset = .balanced
        performWrite { $0.setCurve(curve) }
    }

    func setWatchdog(_ celsius: Double?) {
        guard canWrite, daemonPresent else { return }
        watchdogCelsius = celsius
        performWrite { $0.setWatchdog(celsius) }
    }

    // MARK: History and notifications

    private func recordHistory(_ snapshot: Snapshot) {
        let date = Date()
        guard date.timeIntervalSince(lastHistoryDate) >= 5 else { return }
        lastHistoryDate = date
        history.append(HistorySample(
            date: date,
            cpu: snapshot.temps.cpu,
            gpu: snapshot.temps.gpu,
            fanPercent: snapshot.fans.first?.knob,
            fanRPM: snapshot.fans.first?.actual
        ))
        let cutoff = date.addingTimeInterval(-30 * 60)
        history.removeAll { $0.date < cutoff }
    }

    private func handleNotificationTransitions(_ state: DaemonState?) {
        if let state {
            helperFailurePolls = 0
            helperFailureNotified = false
            if let reason = state.safetyReason,
               reason != lastNotifiedSafetyReason {
                lastNotifiedSafetyReason = reason
                // A live hold transition gets the more useful dedicated
                // notification below; avoid delivering two alerts for it.
                if reason != "hold expired" {
                    notify(title: "Fanknob returned to Auto", body: reason)
                }
            } else if state.safetyReason == nil {
                lastNotifiedSafetyReason = nil
            }
            if previousHoldRemaining > 0, state.holdRemaining == 0,
               state.mode == "auto" {
                notify(title: "Fan hold finished",
                       body: "The fans are back under firmware control.")
            }
            previousHoldRemaining = state.holdRemaining
        } else {
            helperFailurePolls += 1
            if helperFailurePolls >= 3, !helperFailureNotified {
                helperFailureNotified = true
                notify(title: "Fanknob helper unavailable",
                       body: "Fan control is read-only until the helper reconnects.")
            }
        }
    }

    func setNotificationsEnabled(_ enabled: Bool) {
        if !enabled {
            notificationsEnabled = false
            UserDefaults.standard.set(false, forKey: notificationsKey)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.notificationsEnabled = granted
                UserDefaults.standard.set(granted, forKey: notificationsKey)
                if let error {
                    self.controlError = "Notifications could not be enabled: \(error.localizedDescription)"
                } else if !granted {
                    self.controlError = "Notifications are disabled in System Settings."
                }
            }
        }
    }

    private func notify(title: String, body: String) {
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Login item

    func refreshLoginItemStatus() {
        loginItemStatus = SMAppService.mainApp.status
        if loginItemStatus == .enabled { loginItemError = nil }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .requiresApproval {
                    loginItemStatus = .requiresApproval
                    loginItemError = "macOS needs your approval before Fanknob can open at login."
                    askedAboutLogin = true
                    return
                }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemStatus = SMAppService.mainApp.status
            askedAboutLogin = true
            if enabled && loginItemStatus == .requiresApproval {
                loginItemError = "macOS needs your approval before Fanknob can open at login."
            } else {
                loginItemError = nil
            }
        } catch {
            loginItemStatus = SMAppService.mainApp.status
            loginItemError = "Open at login could not be changed: \(error.localizedDescription)"
            UILog.log("launch-at-login \(enabled) failed: \(error)")
        }
    }

    func dismissLoginOffer() {
        askedAboutLogin = true
        loginItemError = nil
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: Curve profiles and diagnostic export

    @discardableResult
    func saveCurveProfile(id: UUID? = nil, name: String,
                          curve: FanCurve) -> UUID? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        if let id, let index = curveProfiles.firstIndex(where: { $0.id == id }) {
            curveProfiles[index].name = cleaned
            curveProfiles[index].points = curve.points
            persistCurveProfiles()
            return id
        }
        if let index = curveProfiles.firstIndex(where: {
            $0.name.localizedCaseInsensitiveCompare(cleaned) == .orderedSame
        }) {
            curveProfiles[index].points = curve.points
            persistCurveProfiles()
            return curveProfiles[index].id
        } else {
            let profile = CurveProfile(name: cleaned, points: curve.points)
            curveProfiles.append(profile)
            persistCurveProfiles()
            return profile.id
        }
    }

    func deleteCurveProfile(_ profile: CurveProfile) {
        curveProfiles.removeAll { $0.id == profile.id }
        persistCurveProfiles()
    }

    private func persistCurveProfiles() {
        if let data = try? JSONEncoder().encode(curveProfiles) {
            UserDefaults.standard.set(data, forKey: curveProfilesKey)
        }
    }

    func exportCurveProfile(name: String, curve: FanCurve) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(name.isEmpty ? "fanknob-curve" : name).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let profile = CurveProfile(name: name.isEmpty ? "Custom" : name,
                                   points: curve.points)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(profile).write(to: url, options: .atomic)
        } catch {
            controlError = "Curve export failed: \(error.localizedDescription)"
        }
    }

    func importCurveProfile() -> CurveProfile? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let profile = try JSONDecoder().decode(
                CurveProfile.self, from: Data(contentsOf: url))
            guard FanCurve(profile.points) != nil else {
                controlError = "The imported curve is not safe or valid."
                return nil
            }
            return profile
        } catch {
            controlError = "Curve import failed: \(error.localizedDescription)"
            return nil
        }
    }

    func exportDiagnostics() {
        struct DiagnosticFan: Codable {
            let index: Int
            let actualRPM: Double
            let minimumRPM: Double
            let maximumRPM: Double
            let managed: Bool
        }
        struct Diagnostic: Codable {
            let version: String
            let daemonVersion: String?
            let generatedAt: Date
            let chip: String
            let macOS: String
            let fans: [DiagnosticFan]
            let cpuCelsius: Double?
            let gpuCelsius: Double?
            let sensorGroups: [String: Int]
            let daemon: DaemonState?
            let recentErrors: [String]
        }
        var groups: [String: Int] = [:]
        for sensor in sensors { groups[String(sensor.key.prefix(2)), default: 0] += 1 }
        let diagnostic = Diagnostic(
            version: fanknobVersion,
            daemonVersion: lastDaemonState?.daemonVersion,
            generatedAt: Date(),
            chip: chip,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            fans: fans.map {
                DiagnosticFan(index: $0.index, actualRPM: $0.actual,
                              minimumRPM: $0.min, maximumRPM: $0.max,
                              managed: $0.managed)
            },
            cpuCelsius: cpu,
            gpuCelsius: gpu,
            sensorGroups: groups,
            daemon: lastDaemonState,
            recentErrors: [controlError, safetyReason].compactMap { $0 }
        )
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "fanknob-diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(diagnostic).write(to: url, options: .atomic)
        } catch {
            controlError = "Diagnostic export failed: \(error.localizedDescription)"
        }
    }
}
