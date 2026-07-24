// PopoverView.swift — the menu-bar popover UI.

import SwiftUI
import AppKit
import FanknobCore

// MARK: - Shared bits

/// Restrained heat cue: calm grey when cool, warming only when it matters.
func tempColor(_ c: Double) -> Color {
    switch c {
    case ..<68: return .secondary
    case ..<82: return .orange
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
        .animation(.easeOut(duration: 0.45), value: value)
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

// MARK: - Popover

struct PopoverView: View {
    @ObservedObject var model: FanModel

    private var modeBinding: Binding<Bool> {
        Binding(get: { model.manual }, set: { model.setMode($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            temps
            if !model.fans.isEmpty { Divider(); fans }
            Divider()
            control
            Divider()
            statusBar
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: Header

    private var header: some View {
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

    // MARK: Temps

    private var temps: some View {
        VStack(spacing: 10) {
            if let c = model.cpu { tempRow("CPU", c) }
            if let g = model.gpu { tempRow("GPU", g) }
            if model.cpu == nil && model.gpu == nil {
                Text("No temperature sensors").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func tempRow(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.callout).foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            GaugeBar(value: value / 100, tint: tempColor(value))
            Text("\(Int(value.rounded()))°")
                .font(.callout.monospacedDigit().weight(.medium))
                .frame(width: 40, alignment: .trailing)
        }
    }

    // MARK: Fans

    private var fans: some View {
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

    // MARK: Control

    private var control: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Mode — the clear source of truth.
            Picker("", selection: modeBinding) {
                Label("Auto", systemImage: "a.circle").tag(false)
                Label("Manual", systemImage: "hand.point.up.left").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(!model.canWrite)

            // Knob
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Fan speed").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    if model.manual {
                        Text("\(Int(model.knob))%")
                            .font(.title3.monospacedDigit().weight(.bold))
                            .foregroundStyle(activeAccent)
                    } else {
                        Text("auto").font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Slider(value: $model.knob, in: 0...100) { editing in
                    model.editing = editing
                    if editing { model.manual = true }   // grabbing = manual intent
                    else { model.applyKnob() }
                }
                .tint(model.manual ? activeAccent : Color.secondary)
                .disabled(!model.canWrite)
            }

            // Hold — only meaningful in manual mode.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Hold").font(.subheadline).foregroundStyle(.secondary)
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
                if model.holdDeadline != nil {
                    HStack(spacing: 5) {
                        Image(systemName: "timer").font(.caption2)
                        Text("reverts to auto in \(model.countdown)")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(!model.canWrite || !model.manual)
            .opacity(model.manual ? 1 : 0.4)
        }
    }

    // MARK: Status

    private var statusBar: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(model.canWrite ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
                .help(model.canWrite ? "Helper daemon connected"
                                     : "Helper not installed — run “sudo make install”")
            if !model.canWrite {
                Text("setup needed").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
