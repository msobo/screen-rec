import Foundation

/// Stückweise lineare Kurve über die Timeline-Zeit: Lautstärke bei Ton, Deckkraft bei Bild.
///
/// Vor dem ersten und nach dem letzten Punkt gilt der jeweilige Randwert.
struct GainEnvelope: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        var time: RationalTime
        var gain: Double
    }

    /// Nach Zeit sortiert, keine doppelten Zeitpunkte.
    private(set) var points: [Point]

    init(constant gain: Double) {
        points = [Point(time: .zero, gain: gain)]
    }

    init(points: [Point]) {
        precondition(!points.isEmpty, "Eine Hüllkurve braucht mindestens einen Punkt")
        self.points = points
    }

    var isConstant: Bool { points.allSatisfy { $0.gain == points[0].gain } }

    func value(at time: RationalTime) -> Double {
        guard let next = points.firstIndex(where: { $0.time > time }) else { return points.last!.gain }
        guard next > 0 else { return points[0].gain }
        let a = points[next - 1], b = points[next]
        let progress = (time - a.time).seconds / (b.time - a.time).seconds
        return a.gain + (b.gain - a.gain) * progress
    }

    /// Ein Faktor, der zwischen `start` und `end` linear von `from` nach `to` läuft.
    struct Ramp: Sendable {
        var start: RationalTime
        var end: RationalTime
        var from: Double
        var to: Double

        func value(at time: RationalTime) -> Double {
            if time <= start { return from }
            if time >= end { return to }
            return from + (to - from) * (time - start).seconds / (end - start).seconds
        }
    }

    /// Produkt aus Grundwert und Rampen, ausgewertet an allen Knickstellen innerhalb von `range`.
    ///
    /// Überlagern sich zwei Rampen, ist das Produkt eigentlich quadratisch; die lineare
    /// Näherung zwischen den Knickstellen ist für Fades hörbar und sichtbar nicht zu unterscheiden.
    static func product(base: Double, ramps: [Ramp], over range: RationalTimeRange) -> GainEnvelope {
        let times = Set([range.start, range.end] + ramps.flatMap { [$0.start, $0.end] })
            .filter { $0 >= range.start && $0 <= range.end }
            .sorted()
        let points = times.map { time in
            Point(time: time, gain: ramps.reduce(base) { $0 * $1.value(at: time) })
        }
        return GainEnvelope(points: points)
    }
}
