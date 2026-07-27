// Curve.swift — temperature → fan-speed curves.
//
// A curve is a list of (°C, knob%) points. Between points the knob is
// interpolated linearly; outside the endpoints it's held flat. The daemon
// evaluates the active curve every couple of seconds, so fans track heat
// instead of sitting at a fixed speed.

import Foundation

public struct FanCurve: Codable, Equatable {
    public struct Point: Codable, Equatable, Comparable {
        public let celsius: Double
        public let knob: Double

        public init(celsius: Double, knob: Double) {
            self.celsius = celsius
            self.knob = knob.clamped(0, 100)
        }

        public static func < (a: Point, b: Point) -> Bool { a.celsius < b.celsius }
    }

    /// Sorted by temperature, at least two points.
    public let points: [Point]

    public init?(_ points: [Point]) {
        guard points.count >= 2, points.allSatisfy({ $0.celsius.isFinite }) else { return nil }
        self.points = points.sorted()
    }

    /// Knob percentage for a temperature.
    public func knob(at celsius: Double) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if celsius <= first.celsius { return first.knob }
        if celsius >= last.celsius { return last.knob }
        for (a, b) in zip(points, points.dropFirst()) where celsius <= b.celsius {
            let span = b.celsius - a.celsius
            guard span > 0 else { return b.knob }
            let t = (celsius - a.celsius) / span
            return a.knob + (b.knob - a.knob) * t
        }
        return last.knob
    }

    /// Wire/CLI format: "55:0,70:15,82:45,92:100"
    public var wireFormat: String {
        points.map { "\(Int($0.celsius.rounded())):\(Int($0.knob.rounded()))" }
            .joined(separator: ",")
    }

    public static func parse(_ text: String) -> FanCurve? {
        var parsed: [Point] = []
        for chunk in text.split(separator: ",") {
            let parts = chunk.split(separator: ":")
            guard parts.count == 2,
                  let c = Double(parts[0]), let k = Double(parts[1]),
                  c.isFinite, k.isFinite else { return nil }
            parsed.append(Point(celsius: c, knob: k))
        }
        return FanCurve(parsed)
    }
}

/// Built-in curves. Tuned against Apple Silicon behavior: idle sits near
/// 45-55 °C, sustained compiles push 80-90 °C.
public enum CurvePreset: String, Codable, CaseIterable {
    case quiet, balanced, turbo

    public var label: String { rawValue.capitalized }

    public var curve: FanCurve {
        // Static literals with 4 valid points — construction cannot fail.
        switch self {
        case .quiet:
            return FanCurve([.init(celsius: 55, knob: 0), .init(celsius: 72, knob: 15),
                             .init(celsius: 84, knob: 45), .init(celsius: 94, knob: 100)])!
        case .balanced:
            return FanCurve([.init(celsius: 45, knob: 5), .init(celsius: 65, knob: 25),
                             .init(celsius: 80, knob: 60), .init(celsius: 90, knob: 100)])!
        case .turbo:
            return FanCurve([.init(celsius: 40, knob: 30), .init(celsius: 55, knob: 55),
                             .init(celsius: 70, knob: 80), .init(celsius: 80, knob: 100)])!
        }
    }
}
