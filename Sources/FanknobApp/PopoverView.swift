// PopoverView.swift — the menu-bar popover UI.
//
// Each section is a separate child View struct on purpose: @Observable tracks
// dependencies per View.body, so with separate children the 1 Hz poll (fans,
// temps) re-renders only the rows that changed — it can no longer re-render
// the mode toggle / slider mid-click, which is what made them feel sticky.
//
// The control block keeps a constant height across modes (one mode picker, one
// speed row, one segmented row) so switching Auto/Manual/Curve never resizes
// the popover. Only the explicit "individual fans" disclosure changes height.

import SwiftUI
import AppKit
import FanknobCore

// MARK: - Shared bits

/// Restrained heat cue: calm grey through normal (warm) temps, warming only
/// when it's genuinely hot. Apple Silicon idles warm, so keep the grey range
/// generous.
func tempColor(_ c: Double) -> Color {
    switch c {
    case ..<82: return .secondary
    case ..<92: return .orange
    default:    return .red
    }
}

/// The single accent used for the active/override state — the user's system
/// accent color, so it stays tasteful and neutral. Everything else is greyscale.
let activeAccent = Color.accentColor

/// Shared row metrics, so temperature and fan labels (and the gauges after
/// them) line up in one column down the whole panel.
let disclosureGutter: CGFloat = 10
let disclosureGap: CGFloat = 4
let rowLabelWidth: CGFloat = 42
/// The row labels are all capitals or digits, so their optical centre sits
/// above the line box's geometric centre by about half a descender. Nudge the
/// chevron up to match, or it reads as sitting low.
let disclosureBaselineNudge: CGFloat = -0.5

/// A smooth, animated gauge bar (value is 0…1).
struct GaugeBar: View {
    var value: Double
    var tint: Color
    var height: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.65), tint],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: value)
    }
}

/// Per-fan badge. See `FanModel.badge(for:)` for why the label comes from the
/// app's mode rather than the SMC's `managed` flag.
struct ModeBadge: View {
    var badge: FanBadge

    var body: some View {
        let tint = badge.overridden ? activeAccent : Color.secondary
        Text(badge.rawValue)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            // Fixed slot so the gauge next to it doesn't resize when the
            // label changes length.
            .frame(width: 56, alignment: .trailing)
    }
}

// MARK: - Popover (container only; sections are isolated child views)

/// The outgoing pane's half of a navigation push: it slides a fraction of the
/// distance and dims while the incoming pane covers it at full speed — the
/// parallax that makes the swap read as layered pages rather than one flat
/// view scooting sideways. Symmetric, so the same modifier plays the reverse
/// role when navigating back.
private struct ParallaxUnder: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        content
            .offset(x: active ? -110 : 0)
            .opacity(active ? 0.3 : 1)
    }
}

/// Secondary panes (editor, help) slide in from the right as an OPAQUE card
/// with a soft leading-edge shadow. The opacity is the load-bearing part:
/// transparent panes let the receding main view bleed through the incoming
/// content mid-flight, text blending with text. At rest the card fills the
/// window, so the backing color and the (clipped) off-edge shadow are
/// invisible; both only show while the card is travelling over the page
/// beneath it.
private struct SlideOverCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .windowBackgroundColor))
            .shadow(color: .black.opacity(0.35), radius: 12, x: -6)
            .transition(.move(edge: .trailing))
    }
}

struct PopoverView: View {
    var model: FanModel
    @State private var showingHelp = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The main view recedes underneath an incoming pane with parallax.
    private static let recede: AnyTransition = .modifier(
        active: ParallaxUnder(active: true),
        identity: ParallaxUnder(active: false)
    )

    var body: some View {
        Group {
            if model.showCurveEditor {
                CurveEditorView(model: model) { model.showCurveEditor = false }
                    .padding(16)
                    .modifier(SlideOverCard())
            } else if showingHelp {
                HelpView { showingHelp = false }
                    .padding(16)
                    .modifier(SlideOverCard())
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HeaderSection(model: model) { showingHelp = true }
                    if let error = model.controlError {
                        ErrorBanner(message: error) { model.controlError = nil }
                    }
                    if model.watchdogTripped && !model.watchdogNoticeDismissed {
                        ErrorBanner(message: model.watchdogNotice) {
                            model.watchdogNoticeDismissed = true
                        }
                    }
                    if let check = model.updateCheck {
                        UpdateBanner(model: model, state: check) {
                            model.dismissUpdateNotice()
                        }
                    }
                    Divider()
                    TempsSection(model: model)
                    Divider()
                    FansSection(model: model)
                    // HistorySection gates itself on history.count, keeping
                    // the 5 s history append from invalidating this whole body.
                    HistorySection(model: model)
                    Divider()
                    ControlSection(model: model)
                    Divider()
                    // No divider after the offer: the card's own background
                    // separates it from the status row.
                    if model.shouldOfferLogin {
                        LoginOffer(model: model)
                    }
                    StatusSection(model: model)
                }
                // Padding INSIDE each pane, not around the Group: an inset
                // pane sliding within a static margin frame is exactly what
                // read as "the view moving inside its container".
                .padding(16)
                .transition(Self.recede)
            }
        }
        .frame(width: model.showCurveEditor ? 420 : 320)
        .clipped()
        // One spring drives the pane slide AND the 320↔420 width change,
        // so the window grows while the editor slides in instead of snapping.
        .animation(reduceMotion ? nil : .smooth(duration: 0.3),
                   value: model.showCurveEditor)
        .animation(reduceMotion ? nil : .smooth(duration: 0.3),
                   value: showingHelp)
        .onAppear {
            model.popoverOpened()   // fresh data the moment it opens
            // Reopen on the main view, never mid-help (the editor's version
            // of this lives in FanModel.resetToMainPane).
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { showingHelp = false }
        }
    }
}

/// Result card for the gear menu's manual update check. Same geometry as
/// ErrorBanner, on the neutral panel tint the other cards use — it's
/// information, not a warning (except the failure case, which goes orange).
private struct UpdateBanner: View {
    var model: FanModel
    let state: FanModel.UpdateCheck
    let dismiss: () -> Void

    /// Icon in a fixed gutter, sized to the caption text it sits beside —
    /// at the default body size the symbols read as oversized and off-center
    /// against a single caption line.
    private func icon(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .font(.caption)
            .foregroundStyle(tint)
            .frame(width: 16, alignment: .center)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            switch state {
            case .checking:
                ProgressView().controlSize(.small).frame(width: 16)
                Text("Checking for updates…").font(.caption)
            case .downloading:
                ProgressView().controlSize(.small).frame(width: 16)
                Text("Downloading the update — Installer will open when it's ready…")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            case .upToDate:
                icon("checkmark.circle", .secondary)
                Text("You're up to date (\(fanknobVersion)).")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            case .available(let version, let url, let pkg):
                icon("arrow.down.circle.fill", activeAccent)
                Text("Version \(version) is available (installed: \(fanknobVersion)).")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if let pkg {
                    Button("Install…") { model.installUpdate(version: version, from: pkg) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                } else {
                    // Source installs: the pkg's preinstall would refuse to
                    // lay files over them, so point at the release instead.
                    Link("View release", destination: url)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(activeAccent)
                }
            case .failed(let message):
                icon("wifi.exclamationmark", .orange)
                Text("Update check failed: \(message)")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .available = state {} else { Spacer(minLength: 4) }
            if state != .checking && state != .downloading {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss update status")
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss error")
        }
        .padding(8)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Header

private struct HeaderSection: View {
    var model: FanModel
    var onHelp: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SpinningFanIcon(revsPerSecond: model.iconRevsPerSecond,
                            tint: model.overriding ? activeAccent : .secondary,
                            paused: !model.popoverShown)
            Text("fanknob").font(.headline)
            Button(action: onHelp) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("What do the modes do?")
            Spacer()
            // The watchdog trip is reported by a dismissible banner below the
            // header (with the daemon's measurement), not by swapping this
            // label — squeezing a warning into the header read as an
            // afterthought and couldn't say why the trip happened.
            Text(model.chip).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Fan icon spinning at a rate that tracks the real fan speed. The angle is
/// integrated frame-by-frame (angle += dt · speed) so speed changes are
/// seamless — no animation restarts.
private struct SpinningFanIcon: View {
    var revsPerSecond: Double
    var tint: Color
    /// MenuBarExtra(.window) keeps this view alive while the popover is
    /// closed, so the timeline must be paused explicitly or it ticks forever.
    var paused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var angle = 0.0
    @State private var lastTick: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                paused: paused || reduceMotion)) { context in
            Image(systemName: "fanblades")
                .foregroundStyle(tint)
                .font(.system(size: 15, weight: .medium))
                .rotationEffect(.degrees(angle))
                .onChange(of: context.date) { _, now in
                    // Clamp dt so a pause (popover closed) can't cause a jump.
                    let dt = (lastTick.map { now.timeIntervalSince($0) } ?? 0).clamped(0, 0.2)
                    lastTick = now
                    angle = (angle + dt * revsPerSecond * 360)
                        .truncatingRemainder(dividingBy: 360)
                }
        }
    }
}

// MARK: - Help

/// Replaces the panel contents rather than opening a nested popover — a
/// MenuBarExtra window dismisses itself when it loses key status, so a real
/// popover would take the whole thing down with it.
private struct HelpView: View {
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Fan modes").font(.headline)
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(activeAccent)
            }
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                row("a.circle", "Auto",
                    "Your Mac's firmware controls the fans. This is the default, and the safest option.")
                row("slider.horizontal.3", "Manual",
                    "You pick a fixed speed and it stays there. The firmware is no longer adjusting for heat, so use Hold — or a curve — if you're leaving it on.")
                row("chart.line.uptrend.xyaxis", "Curve",
                    "Fan speed follows CPU temperature automatically. Quiet stays silent until it's hot, Turbo keeps things cold, Balanced sits between.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                row("timer", "Hold",
                    "In Manual, return to Auto after 30 s – 5 min. The helper runs the timer, so it still happens if you close this window.")
                row("exclamationmark.shield", "Thermal watchdog",
                    "If it gets too hot while you're overriding, the fans go back to the firmware. Set the limit in the gear menu.")
            }

            Divider()

            Text("Speeds are a percentage of each fan's own minimum–maximum range, not of its top speed. With two fans, switch Linked to Individual to control them separately.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(activeAccent)
                .frame(width: 16, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Temperatures

private struct TempsSection: View {
    var model: FanModel
    /// Which cluster is expanded, if any ("CPU"/"GPU").
    @State private var expanded: String?

    var body: some View {
        VStack(spacing: 10) {
            if let c = model.cpu { cluster("CPU", c, prefix: "Tp") }
            if let g = model.gpu { cluster("GPU", g, prefix: "Tg") }
            if model.cpu == nil && model.gpu == nil {
                if model.ready {
                    Text("No temperature sensors").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                }
            }
        }
    }

    private func cluster(_ label: String, _ value: Double, prefix: String) -> some View {
        let isOpen = expanded == label
        let detail = model.clusterSensors(prefix: prefix)
        return VStack(spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    expanded = isOpen ? nil : label
                }
            } label: {
                HStack(spacing: 10) {
                    HStack(spacing: disclosureGap) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            // Square box FIRST, rotate inside it: rotating the
                            // glyph itself shifts layout, because chevron.right
                            // is taller than it is wide.
                            .frame(width: disclosureGutter, height: disclosureGutter)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .offset(y: disclosureBaselineNudge)
                        Text(label).font(.callout).foregroundStyle(.secondary)
                            .frame(width: rowLabelWidth, alignment: .leading)
                    }
                    GaugeBar(value: value / 100, tint: tempColor(value))
                    Text("\(Int(value.rounded()))°")
                        .font(.callout.monospacedDigit().weight(.medium))
                        .frame(width: 40, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(detail.isEmpty)
            .help(detail.isEmpty ? "" : "\(detail.count) sensors — click for detail")

            if isOpen { SensorList(sensors: detail) }
        }
    }
}

/// The per-sensor breakdown behind a cluster. Capped and scrollable: an M2 Pro
/// reports 54 CPU sensors, far more than its core count — they're die probes,
/// not one-per-core, so they're labelled by SMC key rather than pretending.
private struct SensorList: View {
    var sensors: [TempSensor]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let hottest = sensors.first, let coolest = sensors.last {
                Text("\(sensors.count) sensors · \(Int(coolest.celsius.rounded()))–\(Int(hottest.celsius.rounded()))°C")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(sensors, id: \.key) { s in
                        HStack(spacing: 8) {
                            Text(s.key)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 34, alignment: .leading)
                            GaugeBar(value: s.celsius / 100,
                                     tint: tempColor(s.celsius), height: 4)
                            Text("\(Int(s.celsius.rounded()))°")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, alignment: .trailing)
                        }
                    }
                }
                // Clearance for the overlay scrollbar, which would otherwise
                // sit on top of the values.
                .padding(.trailing, 14)
            }
            // A definite height: maxHeight alone lets a ScrollView collapse to
            // nothing inside a VStack. Grows with the list, capped so 54 CPU
            // sensors don't push the popover off screen.
            .frame(height: min(CGFloat(sensors.count) * 14 + 2, 132))
        }
        // Inset on both sides so the detail reads as nested under its row
        // rather than running the full width of the panel.
        .padding(.leading, 16)
        .padding(.trailing, 8)
    }
}

// MARK: - Fans

private struct FansSection: View {
    var model: FanModel

    var body: some View {
        VStack(spacing: 10) {
            ForEach(model.fans, id: \.index) { f in
                let badge = model.badge(for: f)
                HStack(spacing: 10) {
                    // Flush left — no chevron here, so the label gets the
                    // gutter's width too. Same total, so the gauges beside the
                    // temperature rows and the fan rows still share a column.
                    Text("Fan \(f.index)").font(.callout).foregroundStyle(.secondary)
                        .frame(width: rowLabelWidth + disclosureGutter + disclosureGap,
                               alignment: .leading)
                    GaugeBar(value: f.max > f.min ? (f.actual - f.min) / (f.max - f.min) : 0,
                             tint: badge.overridden ? activeAccent : .secondary)
                    Text("\(Int(f.actual.rounded()))")
                        .font(.callout.monospacedDigit())
                        .frame(width: 46, alignment: .trailing)
                    ModeBadge(badge: badge)
                }
            }
        }
    }
}

// MARK: - Control (mode, speed, hold/preset)

private struct ControlSection: View {
    @Bindable var model: FanModel

    private var modeBinding: Binding<UIMode> {
        Binding(get: { model.mode }, set: { model.setMode($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: modeBinding) {
                Text("Auto").tag(UIMode.auto)
                Text("Manual").tag(UIMode.manual)
                if model.daemonPresent { Text("Curve").tag(UIMode.curve) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Fan control mode")
            .accessibilityValue(model.mode.rawValue)
            .frame(maxWidth: .infinity)
            .disabled(!model.canWrite)

            SpeedControl(model: model)

            // Third row swaps by mode but keeps the same height.
            if model.mode == .curve {
                PresetRow(model: model)
            } else {
                HoldRow(model: model)
            }
        }
    }
}

private struct SpeedControl: View {
    @Bindable var model: FanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Fan speed").font(.subheadline).foregroundStyle(.secondary)
                if model.fans.count > 1 && model.mode == .manual {
                    Button(model.linkFans ? "Linked" : "Individual") {
                        withAnimation(.easeOut(duration: 0.15)) { model.linkFans.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(activeAccent)
                    .help("Control both fans together or separately")
                }
                Spacer()
                // Always the percentage, so it agrees with the slider — greyed
                // in auto, where it's a readout rather than a setting.
                Text("\(Int(model.displayKnob))%")
                    .font(.subheadline.monospacedDigit()
                        .weight(model.mode == .auto ? .medium : .bold))
                    .foregroundStyle(model.mode == .auto ? Color.secondary : activeAccent)
            }

            if model.mode == .manual && !model.linkFans {
                ForEach(model.fans, id: \.index) { fan in
                    PerFanSlider(model: model, index: fan.index)
                }
            } else {
                SmoothSlider(model: model)
            }
        }
    }
}

/// The main speed slider, with the value eased by hand.
///
/// SwiftUI's implicit `.animation(_:value:)` does not animate a Slider's thumb
/// on macOS — measured: even a 2.5 s animation snapped straight to the target.
/// So the position is integrated frame-by-frame toward whatever the mode is
/// asking for, which makes Auto↔Curve transitions glide instead of jump.
///
/// The timeline is paused unless something is actually moving, and never runs
/// in manual mode: re-rendering an interactive control at 60 fps is exactly
/// what made earlier controls swallow clicks.
private struct SmoothSlider: View {
    @Bindable var model: FanModel
    @State private var shown = 0.0
    @State private var lastTick: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var settled: Bool { abs(model.displayKnob - shown) < 0.1 }

    private var binding: Binding<Double> {
        Binding(get: {
                    model.mode == .manual || reduceMotion ? model.displayKnob : shown
                },
                set: { if model.mode == .manual { model.knob = $0; shown = $0 } })
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                paused: reduceMotion || !model.popoverShown || model.editing
                                        || model.mode == .manual || settled)) { context in
            Slider(value: binding, in: 0...100) { editing in
                model.editing = editing
                if !editing { model.applyKnob() }
            }
            .onChange(of: model.knob) { _, _ in model.liveApply() }
            .onChange(of: context.date) { _, now in
                let dt = (lastTick.map { now.timeIntervalSince($0) } ?? 0).clamped(0, 0.1)
                lastTick = now
                guard model.mode != .manual, !model.editing else {
                    shown = model.knob
                    return
                }
                let target = model.displayKnob
                // Exponential approach: ~0.12 s time constant, settles in ~0.4 s.
                shown += (target - shown) * (1 - exp(-dt * 8))
                if abs(target - shown) < 0.1 { shown = target }
            }
            .tint(model.mode == .manual ? activeAccent : Color.secondary)
            // Interactive only in manual — elsewhere it's a live gauge, so a
            // poll landing mid-click can't cancel anything.
            .disabled(!model.canWrite || model.mode != .manual)
            .help(model.mode == .manual ? "" : "Switch to Manual to set the speed yourself")
            .accessibilityLabel("Fan speed")
            .accessibilityValue("\(Int(model.displayKnob)) percent")
        }
    }
}

private struct PerFanSlider: View {
    @Bindable var model: FanModel
    let index: Int

    private var binding: Binding<Double> {
        Binding(get: { model.fanKnobs[index] ?? model.knob },
                set: { model.fanKnobs[index] = $0 })
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 10)
            Slider(value: binding, in: 0...100) { editing in
                model.editing = editing
                if !editing { model.applyKnob(fan: index) }
            }
            .onChange(of: model.fanKnobs[index] ?? 0) { _, _ in model.liveApply(fan: index) }
            .tint(activeAccent)
            .disabled(!model.canWrite)
            .accessibilityLabel("Fan \(index) speed")
            .accessibilityValue("\(Int(model.fanKnobs[index] ?? 0)) percent")
            Text("\(Int(model.fanKnobs[index] ?? 0))%")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }
}

private struct PresetRow: View {
    @Bindable var model: FanModel

    /// Optional selection: nil (nothing highlighted) while a custom curve is
    /// active, so the picker never claims a preset is driving the fans.
    private var presetBinding: Binding<CurvePreset?> {
        Binding(get: { model.customCurve == nil ? model.preset : nil },
                set: { if let p = $0 { model.selectPreset(p) } })
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Curve").font(.subheadline).foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            Picker("", selection: presetBinding) {
                ForEach(CurvePreset.allCases, id: \.self) { p in
                    Text(p.label).tag(CurvePreset?.some(p))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Temperature curve preset")
            .disabled(!model.canWrite)
            Button {
                model.showCurveEditor = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.plain)
            .help("Edit a custom curve")
            .accessibilityLabel("Edit custom curve")
        }
        .help("Fan speed follows CPU temperature automatically")
    }
}

private struct HoldRow: View {
    @Bindable var model: FanModel

    var body: some View {
        HStack(spacing: 8) {
            HoldLabel(model: model)
                .frame(width: 38, alignment: .leading)
            Picker("", selection: $model.holdSeconds) {
                Text("Off").tag(0)
                Text("30s").tag(30)
                Text("1m").tag(60)
                Text("2m").tag(120)
                Text("5m").tag(300)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Manual hold duration")
            .onChange(of: model.holdSeconds) { _, _ in
                if model.mode == .manual { model.applyKnob() }
            }
        }
        .disabled(!model.canWrite || model.mode != .manual)
        .opacity(model.mode == .manual ? 1 : 0.4)
    }
}

/// The Hold row's leading label: "Hold" normally, or the ticking countdown
/// while a hold is armed. Isolated child view on purpose — `holdRemaining`
/// ticks every second, and this boundary keeps those updates from rebuilding
/// the pickers (a rebuild mid-click cancels AppKit's control tracking).
private struct HoldLabel: View {
    var model: FanModel

    var body: some View {
        if model.holdRemaining > 0 {
            Text(model.countdown)
                .font(.subheadline.monospacedDigit().weight(.medium))
                .foregroundStyle(activeAccent)
                .help("Reverts to automatic control when the countdown ends")
        } else {
            Text("Hold").font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Thirty-minute history

private struct HistorySection: View {
    var model: FanModel

    var body: some View {
        // The count read lives HERE, not in PopoverView.body: @Observable
        // tracks per View.body, and history changes every 5 s. The `if`'s
        // children flatten into the parent VStack, so layout is unchanged.
        // showHistory first: when hidden, the short-circuit means history is
        // never read, so the 5 s appends re-render nothing at all.
        if model.showHistory, model.history.count >= 2 {
            Divider()
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Last 30 minutes").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.history.count) samples")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            HistoryRow(label: "CPU", tint: .orange,
                       values: model.history.map(\.cpu), maximum: 110,
                       suffix: "°")
            HistoryRow(label: "RPM", tint: activeAccent,
                       values: model.history.map(\.fanRPM),
                       maximum: max(1, model.fans.map(\.max).max() ?? 7000),
                       suffix: "")
            HistoryRow(label: "Knob", tint: .secondary,
                       values: model.history.map(\.fanPercent), maximum: 100,
                       suffix: "%")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thirty minute temperature and fan history")
    }
}

private struct HistoryRow: View {
    let label: String
    let tint: Color
    let values: [Double?]
    let maximum: Double
    let suffix: String

    var body: some View {
        HStack(spacing: 7) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
            Sparkline(values: values, maximum: maximum, tint: tint)
                .frame(height: 18)
            if let latest = values.last ?? nil {
                Text("\(Int(latest.rounded()))\(suffix)")
                    .font(.system(size: 9, design: .monospaced))
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }
}

private struct Sparkline: View {
    let values: [Double?]
    let maximum: Double
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let points = values.enumerated().compactMap { index, value -> CGPoint? in
                guard let value else { return nil }
                let denominator = max(1, values.count - 1)
                return CGPoint(
                    x: CGFloat(index) / CGFloat(denominator) * size.width,
                    y: size.height * (1 - CGFloat((value / maximum).clamped(0, 1)))
                )
            }
            guard let first = points.first else { return }
            var path = Path()
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            context.stroke(path, with: .color(tint), lineWidth: 1.5)
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - Custom curve editor

private struct CurveEditorView: View {
    @Bindable var model: FanModel
    let onClose: () -> Void
    @State private var name = "Custom"
    @State private var points: [FanCurve.Point]
    @State private var selectedPoint = 0
    @State private var profileID: UUID?

    init(model: FanModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        // customCurve second: when the daemon state is briefly nil, an active
        // custom curve must not fall through to a preset's points.
        let initial = model.lastDaemonState?.curve.flatMap(FanCurve.parse)
            ?? model.customCurve
            ?? model.preset.curve
        _points = State(initialValue: initial.points)
    }

    private var curve: FanCurve? { FanCurve(points) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(action: onClose) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Back")
                Spacer()
                Text("Custom curve").font(.headline)
                Spacer()
                Button("Apply") {
                    if let curve { model.applyCustomCurve(curve); onClose() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(curve == nil)
                .keyboardShortcut(.defaultAction)
            }

            CurveGraph(points: $points, selectedPoint: $selectedPoint,
                       currentTemperature: model.cpu)
                .frame(height: 180)
                .accessibilityLabel("Custom temperature curve")
                .accessibilityHint("Drag points to change temperature and fan speed")

            HStack {
                Text(points.map {
                    "\(Int($0.celsius.rounded()))°:\(Int($0.knob.rounded()))%"
                }.joined(separator: "  "))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Spacer()
                Button {
                    addPoint()
                } label: { Image(systemName: "plus") }
                    .disabled(points.count >= FanCurve.maximumPointCount
                              || widestGap < 2)
                    .help("Add curve point")
                    .accessibilityLabel("Add curve point")
                Button {
                    guard points.count > 2 else { return }
                    points.remove(at: selectedPoint)
                    selectedPoint = min(selectedPoint, points.count - 1)
                } label: { Image(systemName: "minus") }
                    .disabled(points.count <= 2)
                    .help("Remove selected curve point")
                    .accessibilityLabel("Remove selected curve point")
            }
            .buttonStyle(.borderless)

            if points.indices.contains(selectedPoint) {
                HStack(spacing: 12) {
                    Stepper(
                        value: temperatureBinding(for: selectedPoint),
                        in: temperatureBounds(for: selectedPoint),
                        step: 1
                    ) {
                        Text("Point \(selectedPoint + 1): "
                             + "\(Int(points[selectedPoint].celsius)) °C")
                    }
                    Stepper(
                        value: speedBinding(for: selectedPoint),
                        in: speedBounds(for: selectedPoint),
                        step: 1
                    ) {
                        Text("\(Int(points[selectedPoint].knob))%")
                    }
                }
                .font(.caption.monospacedDigit())
                .accessibilityElement(children: .contain)
            }

            if let temperature = model.cpu, let curve {
                HStack {
                    Label("\(Int(temperature.rounded())) °C now",
                          systemImage: "thermometer.medium")
                    Spacer()
                    Text("curve requests \(Int(curve.knob(at: temperature).rounded()))%")
                        .foregroundStyle(activeAccent)
                }
                .font(.caption)
            }

            Divider()

            HStack {
                TextField("Profile name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Curve profile name")
                Button("Save") {
                    if let curve {
                        profileID = model.saveCurveProfile(
                            id: profileID, name: name, curve: curve)
                    }
                }
                .disabled(curve == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                Menu("Profiles") {
                    if model.curveProfiles.isEmpty {
                        Text("No saved profiles")
                    }
                    ForEach(model.curveProfiles) { profile in
                        Button(profile.name) {
                            if let loaded = FanCurve(profile.points) {
                                name = profile.name
                                points = loaded.points
                                selectedPoint = 0
                                profileID = profile.id
                            }
                        }
                    }
                    if !model.curveProfiles.isEmpty {
                        Divider()
                        Menu("Delete") {
                            ForEach(model.curveProfiles) { profile in
                                Button(profile.name, role: .destructive) {
                                    model.deleteCurveProfile(profile)
                                }
                            }
                        }
                    }
                }
                Menu {
                    Button("Import…") {
                        if let profile = model.importCurveProfile(),
                           let loaded = FanCurve(profile.points) {
                            name = profile.name
                            points = loaded.points
                            selectedPoint = 0
                            profileID = nil
                        }
                    }
                    Button("Export…") {
                        if let curve { model.exportCurveProfile(name: name, curve: curve) }
                    }
                    .disabled(curve == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Curve import and export")
            }
        }
    }

    /// A new point needs 1 °C of clearance to each neighbor (the spacing rule
    /// FanCurve enforces), so only a gap of at least 2 °C can host one.
    private var widestGap: Double {
        zip(points, points.dropFirst()).map { $1.celsius - $0.celsius }.max() ?? 0
    }

    private func addPoint() {
        guard points.count < FanCurve.maximumPointCount,
              let curve else { return }
        let gaps = zip(points.indices, points.indices.dropFirst())
            .filter { points[$0.1].celsius - points[$0.0].celsius >= 2 }
        guard let pair = gaps.max(by: {
            points[$0.1].celsius - points[$0.0].celsius
                < points[$1.1].celsius - points[$1.0].celsius
        }) else { return }
        let temperature = ((points[pair.0].celsius + points[pair.1].celsius) / 2)
            .rounded()
        let point = FanCurve.Point(celsius: temperature,
                                   knob: curve.knob(at: temperature).rounded())
        points.insert(point, at: pair.1)
        selectedPoint = pair.1
    }

    private func temperatureBounds(for index: Int) -> ClosedRange<Double> {
        let lower = index == 0
            ? FanCurve.temperatureRange.lowerBound : points[index - 1].celsius + 1
        let upper = index == points.count - 1
            ? FanCurve.temperatureRange.upperBound : points[index + 1].celsius - 1
        // Neighbors sitting exactly 1 °C apart make lower == upper; anything
        // tighter must not invert the range — Stepper traps on lower > upper.
        return lower...max(lower, upper)
    }

    private func speedBounds(for index: Int) -> ClosedRange<Double> {
        let lower = index == 0 ? 0 : points[index - 1].knob
        let upper = index == points.count - 1 ? 100 : points[index + 1].knob
        return lower...max(lower, upper)
    }

    private func temperatureBinding(for index: Int) -> Binding<Double> {
        Binding(
            get: { points[index].celsius },
            set: {
                points[index] = FanCurve.Point(celsius: $0,
                                                knob: points[index].knob)
            }
        )
    }

    private func speedBinding(for index: Int) -> Binding<Double> {
        Binding(
            get: { points[index].knob },
            set: {
                points[index] = FanCurve.Point(celsius: points[index].celsius,
                                                knob: $0)
            }
        )
    }
}

private struct CurveGraph: View {
    @Binding var points: [FanCurve.Point]
    @Binding var selectedPoint: Int
    let currentTemperature: Double?

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Canvas { context, canvas in
                    for fraction in [0.25, 0.5, 0.75] {
                        var grid = Path()
                        grid.move(to: CGPoint(x: 0, y: canvas.height * fraction))
                        grid.addLine(to: CGPoint(x: canvas.width,
                                                 y: canvas.height * fraction))
                        context.stroke(grid, with: .color(.secondary.opacity(0.15)),
                                       lineWidth: 0.5)
                    }
                    if let currentTemperature {
                        let x = xPosition(currentTemperature, width: canvas.width)
                        var marker = Path()
                        marker.move(to: CGPoint(x: x, y: 0))
                        marker.addLine(to: CGPoint(x: x, y: canvas.height))
                        context.stroke(marker, with: .color(.orange.opacity(0.65)),
                                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                    guard let first = points.first else { return }
                    var curvePath = Path()
                    curvePath.move(to: position(first, size: canvas))
                    for point in points.dropFirst() {
                        curvePath.addLine(to: position(point, size: canvas))
                    }
                    context.stroke(curvePath, with: .color(activeAccent), lineWidth: 2)
                }

                ForEach(points.indices, id: \.self) { index in
                    Circle()
                        .fill(index == selectedPoint ? activeAccent : Color(nsColor: .windowBackgroundColor))
                        .stroke(activeAccent, lineWidth: 2)
                        .frame(width: 13, height: 13)
                        .position(position(points[index], size: size))
                        .gesture(DragGesture(coordinateSpace: .named("curve-graph"))
                            .onChanged { dragPoint(index, location: $0.location,
                                                   size: size) })
                        .onTapGesture { selectedPoint = index }
                        .accessibilityLabel("Curve point \(index + 1)")
                        .accessibilityValue(
                            "\(Int(points[index].celsius)) degrees, \(Int(points[index].knob)) percent")
                }
            }
            .coordinateSpace(name: "curve-graph")
            .background(Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topLeading) {
                Text("100%").font(.system(size: 8)).foregroundStyle(.tertiary)
                    .padding(5)
            }
            .overlay(alignment: .bottomLeading) {
                Text("20°C").font(.system(size: 8)).foregroundStyle(.tertiary)
                    .padding(5)
            }
            .overlay(alignment: .bottomTrailing) {
                Text("110°C").font(.system(size: 8)).foregroundStyle(.tertiary)
                    .padding(5)
            }
        }
    }

    private func position(_ point: FanCurve.Point, size: CGSize) -> CGPoint {
        CGPoint(x: xPosition(point.celsius, width: size.width),
                y: size.height * (1 - CGFloat(point.knob / 100)))
    }

    private func xPosition(_ temperature: Double, width: CGFloat) -> CGFloat {
        CGFloat((temperature - FanCurve.temperatureRange.lowerBound)
                / (FanCurve.temperatureRange.upperBound
                   - FanCurve.temperatureRange.lowerBound)) * width
    }

    private func dragPoint(_ index: Int, location: CGPoint, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let rawTemperature = FanCurve.temperatureRange.lowerBound
            + Double((location.x / size.width).clamped(0, 1))
            * (FanCurve.temperatureRange.upperBound
               - FanCurve.temperatureRange.lowerBound)
        let rawKnob = Double((1 - location.y / size.height).clamped(0, 1)) * 100
        let minimumTemperature = index == 0
            ? FanCurve.temperatureRange.lowerBound : points[index - 1].celsius + 1
        let maximumTemperature = index == points.count - 1
            ? FanCurve.temperatureRange.upperBound : points[index + 1].celsius - 1
        let minimumKnob = index == 0 ? 0 : points[index - 1].knob
        let maximumKnob = index == points.count - 1 ? 100 : points[index + 1].knob
        points[index] = FanCurve.Point(
            celsius: rawTemperature.clamped(minimumTemperature, maximumTemperature).rounded(),
            knob: rawKnob.clamped(minimumKnob, maximumKnob).rounded()
        )
        selectedPoint = index
    }
}

// MARK: - Launch at login

/// A one-time offer to keep fanknob in the menu bar.
///
/// Asked here rather than as an alert on first launch: this is a menu-bar
/// agent with no windows, so a modal appearing out of nowhere would have no
/// obvious source. Either button answers it for good — see
/// `FanModel.askedAboutLogin`.
private struct LoginOffer: View {
    @Bindable var model: FanModel

    private var failed: Bool { model.loginItemError != nil }

    var body: some View {
        // Styled like the app's other inset panels (ErrorBanner, the graph
        // backgrounds): icon column + caption text on a tinted rounded card,
        // so the one-time offer reads as part of the popover rather than a
        // banner dropped on top of it. Text on its own row: at 320 pt wide,
        // sharing a line with two buttons wrapped it onto four cramped lines.
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: failed ? "exclamationmark.triangle.fill" : "pin")
                    .font(.system(size: 12))
                    .foregroundStyle(failed ? Color.orange : activeAccent)
                    .frame(width: 16, alignment: .center)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep fanknob in your menu bar?")
                        .font(.subheadline.weight(.semibold))
                    Text(model.loginItemError ?? "Otherwise it's gone after a restart.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Not now") { model.dismissLoginOffer() }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.loginItemStatus == .requiresApproval {
                    Button("Open Settings") { model.openLoginItemSettings() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(failed ? "Try again" : "Keep it") {
                        model.setLaunchAtLogin(true)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Status

/// Where someone whose helper isn't running gets sent. A static literal, so the
/// unwrap can't fail (same reasoning as the curve presets in Curve.swift).
private let troubleshootingURL =
    URL(string: "https://sadrig91.github.io/fanknob/#troubleshooting")!

private struct StatusSection: View {
    @Bindable var model: FanModel
    @State private var hovering = false

    private var watchdogBinding: Binding<Double?> {
        Binding(get: { model.watchdogCelsius }, set: { model.setWatchdog($0) })
    }

    private var loginBinding: Binding<Bool> {
        Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 })
    }

    var body: some View {
        HStack(spacing: 6) {
            // Generous hit area (a bare 7 pt circle is nearly impossible to
            // hover). The status text reveals INSTANTLY on hover — the system
            // .help() tooltip needs ~2 s of stationary cursor.
            Circle()
                .fill(model.canWrite ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
            // Without the helper this warning is permanently on screen, so make
            // it actionable: underlined rather than accent-colored, since accent
            // means "you're overriding the firmware" everywhere else in here.
            Group {
                if model.canWrite {
                    Text("helper connected — fan control available")
                } else {
                    Link("helper not installed — how to fix",
                         destination: troubleshootingURL)
                        .underline()
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            .lineLimit(1).minimumScaleFactor(0.8)
            .opacity(model.canWrite && !hovering ? 0 : 1)
            .animation(.easeOut(duration: 0.15), value: hovering)
            Spacer()

            Menu {
                if model.loginItemStatus == .requiresApproval {
                    Button("Allow Open at Login…") { model.openLoginItemSettings() }
                } else {
                    Toggle("Open at login", isOn: loginBinding)
                }
                Toggle("Safety notifications",
                       isOn: Binding(get: { model.notificationsEnabled },
                                     set: { model.setNotificationsEnabled($0) }))
                Toggle("Show 30-minute history", isOn: $model.showHistory)
                if model.daemonPresent {
                    Picker("Thermal watchdog", selection: watchdogBinding) {
                        Text("Off").tag(Double?.none)
                        Text("90 °C").tag(Double?.some(90))
                        Text("95 °C").tag(Double?.some(95))
                        Text("100 °C").tag(Double?.some(100))
                    }
                }
                Divider()
                Button("Check for updates…") { model.checkForUpdates() }
                Button("Export diagnostics…") { model.exportDiagnostics() }
                Button("Quit fanknob") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
        }
    }
}
