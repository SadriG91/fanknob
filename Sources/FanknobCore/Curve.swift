// Curve.swift — temperature → fan-speed curves.
//
// A curve is a list of (°C, knob%) points. Between points the knob is
// interpolated linearly; outside the endpoints it's held flat. The daemon
// evaluates the active curve every couple of seconds, so fans track heat
// instead of sitting at a fixed speed.

import Foundation

public struct FanCurve: Codable, Equatable, Sendable {
    public static let temperatureRange = 20.0...110.0
    public static let maximumPointCount = 12

    public struct Point: Codable, Equatable, Comparable, Sendable {
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
        guard (2...Self.maximumPointCount).contains(points.count),
              points.allSatisfy({
                  $0.celsius.isFinite && $0.knob.isFinite
                      && Self.temperatureRange.contains($0.celsius)
                      && (0...100).contains($0.knob)
              }) else { return nil }
        let sorted = points.sorted()
        guard zip(sorted, sorted.dropFirst()).allSatisfy({
            $1.celsius - $0.celsius >= 1 && $0.knob <= $1.knob
        }) else { return nil }
        self.points = sorted
    }

    private enum CodingKeys: CodingKey { case points }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try container.decode([Point].self, forKey: .points)
        guard let validated = FanCurve(decoded) else {
            throw DecodingError.dataCorruptedError(
                forKey: .points, in: container,
                debugDescription: "curve temperatures must rise by at least 1°C and speeds must not decrease"
            )
        }
        self = validated
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
                  c.isFinite, k.isFinite, (0...100).contains(k) else {
                return nil
            }
            parsed.append(Point(celsius: c, knob: k))
        }
        return FanCurve(parsed)
    }
}

/// Built-in curves. Tuned against Apple Silicon behavior: idle sits near
/// 45-55 °C, sustained compiles push 80-90 °C.
public enum CurvePreset: String, Codable, CaseIterable, Sendable {
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
