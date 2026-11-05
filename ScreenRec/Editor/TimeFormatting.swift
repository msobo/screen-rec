import Foundation

enum TimeFormatting {
    /// „01:23.45“ für Zeitanzeigen.
    static func timecode(_ time: RationalTime) -> String {
        Duration.seconds(time.seconds).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 2, fractionalSecondsLength: 2)))
    }

    /// Beschriftung im Zeitlineal; Nachkommastellen nur, wenn die Striche enger als 1 s liegen.
    static func ruler(_ seconds: Double, interval: Double) -> String {
        let fraction = interval >= 1 ? 0 : (interval < 0.5 && interval != 0.1 ? 2 : 1)
        return Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1, fractionalSecondsLength: fraction)))
    }

    /// „1,5 s“
    static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " s"
    }
}
