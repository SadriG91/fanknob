// PopoverView.swift — the menu-bar popover UI.
//
// Each section is a separate child View struct on purpose: @Observable tracks
// dependencies per View.body, so with separate children the 1 Hz poll (fans,
// temps) re-renders only the rows that changed — it can no longer re-render
// the mode toggle / slider mid-click, which is what made them feel sticky.

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

/// The single accent used for the active/manual state — the user's system
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
    }
}

// MARK: - Header

private struct HeaderSection: View {
    var model: FanModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "fanblades")
                .foregroundStyle(model.manual ? activeAccent : .secondary)
                .font(.system(size: 15, weight: .medium))
                .symbolEffect(.pulse, isActive: model.manual)
            Text("fanknob").font(.headline)
            Spacer()
            Text(model.chip).font(.caption).foregroundStyle(.secondary)
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
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
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

// MARK: - Control (mode toggle, knob, hold)

private struct ControlSection: View {
    @Bindable var model: FanModel

    private var modeBinding: Binding<Bool> {
        Binding(get: { model.manual }, set: { model.setMode($0) })
    }

    var body: some View {
        let _ = UILog.log("ControlSection body eval (manual=\(model.manual))")
        return VStack(alignment: .leading, spacing: 12) {
            // Mode — the clear source of truth.
            Picker("", selection: modeBinding) {
                Text("Auto").tag(false)
                Text("Manual").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)   // full-width = bigger click targets
            .disabled(!model.canWrite)

            // Knob
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Fan speed").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    // Both value variants share the same text metrics, so the
                    // row height is naturally constant across mode switches —
                    // the accent color + bold weight carry the emphasis.
                    if model.manual {
                        Text("\(Int(model.knob))%")
                            .font(.subheadline.monospacedDigit().weight(.bold))
                            .foregroundStyle(activeAccent)
                    } else {
                        Text("auto").font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Slider(value: $model.knob, in: 0...100) { editing in
                    model.editing = editing
                    if editing { model.manual = true }   // grabbing = manual intent
                    else { model.applyKnob() }           // release = authoritative apply
                }
                .onChange(of: model.knob) { _, _ in
                    model.liveApply()                    // throttled live apply mid-drag
                }
                .tint(model.manual ? activeAccent : Color.secondary)
                .disabled(!model.canWrite)
            }

            // Hold — only meaningful in manual mode. The label swaps to the
            // ticking countdown while a hold is armed (same line, same height),
            // so the popover never resizes and there's no reserved blank line.
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
                    if model.manual { model.applyKnob() }
                }
            }
            .disabled(!model.canWrite || !model.manual)
            .opacity(model.manual ? 1 : 0.4)
        }
    }
}

/// The Hold row's leading label: "Hold" normally, or the ticking countdown
/// while a hold is armed. Isolated child view on purpose — `holdRemaining`
/// ticks every second, and this boundary keeps those updates from rebuilding
/// the pickers (a rebuild mid-click cancels AppKit's control tracking).
private struct HoldLabel: View {
    var model: FanModel

    var body: some View {
        if model.holdDeadline != nil {
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
    var model: FanModel
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            // Generous hit area (a bare 7 pt circle is nearly impossible to
            // hover). The status text reveals INSTANTLY on hover — the system
            // .help() tooltip needs ~2 s of stationary cursor and reads as
            // "not working".
            Circle()
                .fill(model.canWrite ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
            // "setup needed" is always visible; the healthy state only on hover.
            Text(model.canWrite ? "helper connected — fan control available"
                                : "helper not installed — run “sudo make install”")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
                .opacity(model.canWrite && !hovering ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: hovering)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
