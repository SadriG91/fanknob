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
        .animation(.easeOut(duration: 0.28), value: value)
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

struct PopoverView: View {
    var model: FanModel
    @State private var showingHelp = false

    var body: some View {
        Group {
            if showingHelp {
                HelpView { showingHelp = false }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HeaderSection(model: model) { showingHelp = true }
                    Divider()
                    TempsSection(model: model)
                    Divider()
                    FansSection(model: model)
                    Divider()
                    ControlSection(model: model)
                    Divider()
                    if model.shouldOfferLogin {
                        LoginOffer(model: model)
                        Divider()
                    }
                    StatusSection(model: model)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { model.popoverOpened() }   // fresh data the moment it opens
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
            if model.watchdogTripped {
                Label("too hot — back to auto", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .help("The thermal watchdog returned the fans to firmware control")
            } else {
                Text(model.chip).font(.caption).foregroundStyle(.secondary)
            }
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
    @State private var angle = 0.0
    @State private var lastTick: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { context in
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

    private var settled: Bool { abs(model.displayKnob - shown) < 0.1 }

    private var binding: Binding<Double> {
        Binding(get: { model.mode == .manual ? model.knob : shown },
                set: { if model.mode == .manual { model.knob = $0; shown = $0 } })
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                paused: !model.popoverShown || model.editing
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
            Text("\(Int(model.fanKnobs[index] ?? 0))%")
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
    }
}

private struct PresetRow: View {
    @Bindable var model: FanModel

    private var presetBinding: Binding<CurvePreset> {
        Binding(get: { model.preset }, set: { model.selectPreset($0) })
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Curve").font(.subheadline).foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            Picker("", selection: presetBinding) {
                ForEach(CurvePreset.allCases, id: \.self) { p in
                    Text(p.label).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.canWrite)
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

// MARK: - Launch at login

/// A one-time offer to keep fanknob in the menu bar.
///
/// Asked here rather than as an alert on first launch: this is a menu-bar
/// agent with no windows, so a modal appearing out of nowhere would have no
/// obvious source. Either button answers it for good — see
/// `FanModel.askedAboutLogin`.
private struct LoginOffer: View {
    @Bindable var model: FanModel

    var body: some View {
        // Text on its own row: at 320 pt wide, sharing a line with two buttons
        // wrapped the question onto four cramped lines.
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Keep fanknob in your menu bar?")
                    .font(.subheadline)
                Text("Otherwise it's gone after a restart.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Spacer()
                Button("Not now") { model.askedAboutLogin = true }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Keep it") { model.launchAtLogin = true }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
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
                Toggle("Open at login", isOn: loginBinding)
                if model.daemonPresent {
                    Picker("Thermal watchdog", selection: watchdogBinding) {
                        Text("Off").tag(Double?.none)
                        Text("90 °C").tag(Double?.some(90))
                        Text("95 °C").tag(Double?.some(95))
                        Text("100 °C").tag(Double?.some(100))
                    }
                }
                Divider()
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
