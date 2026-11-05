import CoreMedia

/// Exakter Zeitwert (Bruch aus `value / timescale`) für das Projektmodell.
///
/// `CMTime` ist nicht `Codable`; Gleitkomma-Sekunden würden bei vielen Schnitten
/// driften. Gerechnet wird über `CMTime`, gespeichert als `{ "value", "timescale" }`.
struct RationalTime: Codable, Hashable, Comparable, Sendable {
    var value: Int64
    var timescale: Int32

    static let zero = RationalTime(value: 0, timescale: 1)
    /// Standard-Zeitbasis für Werte, die aus Sekunden entstehen.
    static let defaultTimescale: Int32 = 60_000

    init(value: Int64, timescale: Int32) {
        precondition(timescale > 0, "timescale muss positiv sein")
        self.value = value
        self.timescale = timescale
    }

    init(_ time: CMTime) {
        precondition(time.isNumeric, "Nur numerische CMTime-Werte sind erlaubt")
        self.init(value: time.value, timescale: time.timescale)
    }

    init(seconds: Double, timescale: Int32 = RationalTime.defaultTimescale) {
        self.init(CMTime(seconds: seconds, preferredTimescale: timescale))
    }

    var cmTime: CMTime { CMTime(value: value, timescale: timescale) }
    var seconds: Double { Double(value) / Double(timescale) }

    /// Derselbe Zeitpunkt auf der Zeitbasis `timescale`, im Zweifel aufgerundet.
    func rounded(toTimescale timescale: Int32) -> Self {
        Self(CMTimeConvertScale(cmTime, timescale: timescale, method: .roundTowardPositiveInfinity))
    }

    static func + (lhs: Self, rhs: Self) -> Self { Self(lhs.cmTime + rhs.cmTime) }
    static func - (lhs: Self, rhs: Self) -> Self { Self(lhs.cmTime - rhs.cmTime) }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.cmTime < rhs.cmTime }

    /// Gleichheit nach Wert, nicht nach Darstellung: 1/2 == 30/60.
    static func == (lhs: Self, rhs: Self) -> Bool { CMTimeCompare(lhs.cmTime, rhs.cmTime) == 0 }

    func hash(into hasher: inout Hasher) {
        let divisor = Self.gcd(abs(value), Int64(timescale))
        hasher.combine(value / max(divisor, 1))
        hasher.combine(Int64(timescale) / max(divisor, 1))
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        b == 0 ? a : gcd(b, a % b)
    }
}

/// Zeitbereich aus Start und Dauer.
struct RationalTimeRange: Codable, Hashable, Sendable {
    var start: RationalTime
    var duration: RationalTime

    var end: RationalTime { start + duration }
    var cmTimeRange: CMTimeRange { CMTimeRange(start: start.cmTime, duration: duration.cmTime) }

    func contains(_ time: RationalTime) -> Bool { time >= start && time < end }
}
