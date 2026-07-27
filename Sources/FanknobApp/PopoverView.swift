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

struct ModeBadge: View {
    var managed: Bool
    var body: some View {
        Text(managed ? "MANUAL" : "AUTO")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(managed ? activeAccent : Color.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((managed ? activeAccent : Color.secondary).opacity(0.14), in: Capsule())
    }
}

// MARK: - Popover (container only; sections are isolated child views)

struct PopoverView: View {
    var model: FanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HeaderSection(model: model)
            Divider()
            TempsSection(model: model)
            Divider()
            FansSection(model: model)
            Divider()
            ControlSection(model: model)
            Divider()
            StatusSection(model: model)
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { model.popoverOpened() }   // fresh data the moment it opens
    }
}

// MARK: - Header

private struct HeaderSection: View {
    var model: FanModel

    var body: some View {
        HStack(spacing: 8) {
            SpinningFanIcon(revsPerSecond: model.iconRevsPerSecond,
                            tint: model.overriding ? activeAccent : .secondary,
                            paused: !model.popoverShown)
            Text("fanknob").font(.headline)
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

// MARK: - Temperatures

private struct TempsSection: View {
    var model: FanModel

    var body: some View {
        VStack(spacing: 10) {
            if let c = model.cpu { row("CPU", c) }
            if let g = model.gpu { row("GPU", g) }
            if model.cpu == nil && model.gpu == nil {
                if model.ready {
                    Text("No temperature sensors").font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                }
            }
        }
    }

    private func row(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.callout).foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            GaugeBar(value: value / 100, tint: tempColor(value))
            Text("\(Int(value.rounded()))°")
                .font(.callout.monospacedDigit().weight(.medium))
                .frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: - Fans

private struct FansSection: View {
    var model: FanModel

    var body: some View {
        VStack(spacing: 10) {
            ForEach(model.fans, id: \.index) { f in
                HStack(spacing: 10) {
                    Text("Fan \(f.index)").font(.callout).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    GaugeBar(value: f.max > f.min ? (f.actual - f.min) / (f.max - f.min) : 0,
                             tint: f.managed ? activeAccent : .secondary)
                    Text("\(Int(f.actual.rounded()))")
                        .font(.callout.monospacedDigit())
                        .frame(width: 46, alignment: .trailing)
                    ModeBadge(managed: f.managed)
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

    /// Only manual mode writes back; in auto/curve the slider is a live
    /// readout of what the firmware or the curve is doing.
    private var sliderBinding: Binding<Double> {
        Binding(get: { model.displayKnob },
                set: { if model.mode == .manual { model.knob = $0 } })
    }

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
                switch model.mode {
                case .auto:
                    Text("auto").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                case .manual, .curve:
                    Text("\(Int(model.displayKnob))%")
                        .font(.subheadline.monospacedDigit().weight(.bold))
                        .foregroundStyle(activeAccent)
                }
            }

            if model.mode == .manual && !model.linkFans {
                ForEach(model.fans, id: \.index) { fan in
                    PerFanSlider(model: model, index: fan.index)
                }
            } else {
                Slider(value: sliderBinding, in: 0...100) { editing in
                    model.editing = editing
                    if !editing { model.applyKnob() }
                }
                .onChange(of: model.knob) { _, _ in model.liveApply() }
                .tint(model.mode == .manual ? activeAccent : Color.secondary)
                // Interactive only in manual — elsewhere it's a live gauge, so
                // a poll landing mid-click can't cancel anything.
                .disabled(!model.canWrite || model.mode != .manual)
                .help(model.mode == .manual ? ""
                      : "Switch to Manual to set the speed yourself")
            }
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

// MARK: - Status

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
            Text(model.canWrite ? "helper connected — fan control available"
                                : "helper not installed — see the README")
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
