// PopoverView.swift — the menu-bar popover UI.

import SwiftUI
import AppKit
import FanknobCore

// MARK: - Shared bits

/// Green→red gradient for a temperature value.
func tempColor(_ c: Double) -> Color {
    switch c {
    case ..<45: return .teal
    case ..<58: return .green
    case ..<70: return Color(red: 0.72, green: 0.78, blue: 0.16)
    case ..<80: return .yellow
    case ..<88: return .orange
    default:    return .red
    }
}

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
            .foregroundStyle(managed ? Color.pink : Color.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((managed ? Color.pink : Color.secondary).opacity(0.14), in: Capsule())
    }
}

// MARK: - Popover

struct PopoverView: View {
    @ObservedObject var model: FanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            temps
            if !model.fans.isEmpty { Divider(); fans }
            Divider()
            knob
            Divider()
            statusBar
        }
        .padding(16)
        .frame(width: 320)
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "fanblades")
                .foregroundStyle(.cyan)
                .font(.system(size: 15, weight: .medium))
            Text("fanknob").font(.headline)
            Spacer()
            Text(model.chip).font(.caption).foregroundStyle(.secondary)
        }
    }

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

    private var fans: some View {
        VStack(spacing: 10) {
            ForEach(model.fans, id: \.index) { f in
                HStack(spacing: 10) {
                    Text("Fan \(f.index)").font(.callout).foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    GaugeBar(value: f.max > f.min ? (f.actual - f.min) / (f.max - f.min) : 0,
                             tint: .cyan)
                    Text("\(Int(f.actual.rounded()))")
                        .font(.callout.monospacedDigit())
                        .frame(width: 44, alignment: .trailing)
                    ModeBadge(managed: f.managed)
                }
            }
        }
    }

    private var knob: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Knob").font(.headline)
                Spacer()
                Text("\(Int(model.knob))%")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(model.canWrite ? .pink : .secondary)
            }

            Slider(value: $model.knob, in: 0...100, step: 1) { editing in
                if !editing { model.applyKnob() }
            }
            .tint(.pink)
            .disabled(!model.canWrite)

            HStack(spacing: 8) {
                Button {
                    model.setAuto()
                } label: {
                    Label("Auto", systemImage: "a.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!model.canWrite)

                Picker("", selection: $model.holdSeconds) {
                    Text("Off").tag(0)
                    Text("30s").tag(30)
                    Text("1m").tag(60)
                    Text("2m").tag(120)
                    Text("5m").tag(300)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!model.canWrite)
                .onChange(of: model.holdSeconds) { _ in
                    if model.anyManual { model.applyKnob() }
                }
            }

            if model.holdDeadline != nil {
                HStack(spacing: 5) {
                    Image(systemName: "timer").font(.caption2)
                    Text("reverts to auto in \(model.countdown)")
                }
                .font(.caption).foregroundStyle(.pink)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            Circle().fill(model.canWrite ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(model.canWrite ? "helper connected"
                                : "helper not installed — run “sudo make install”")
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
