import CoreMedia

/// Umrechnung zwischen Timeline-Zeit und Quellzeit unter Berücksichtigung der Clip-Geschwindigkeit.
///
/// Die Geschwindigkeit wird als ganzzahliger Bruch (Promille) angewendet, damit gängige
/// Faktoren (0.5, 1.5, 2, 4 …) exakt bleiben und Hin- und Rückrechnung zusammenpassen.
enum TimeMapping {
    /// Geschwindigkeit als Bruch `multiplier / divisor` (z. B. 1.5 → 1500/1000).
    static func speedRatio(_ speed: Double) -> (multiplier: Int32, divisor: Int32) {
        (Int32((speed * 1_000).rounded()), 1_000)
    }

    /// Wie lange eine Quelldauer auf der Timeline dauert.
    static func timelineDuration(forSourceDuration duration: RationalTime, speed: Double) -> RationalTime {
        let ratio = speedRatio(speed)
        return RationalTime(CMTimeMultiplyByRatio(duration.cmTime, multiplier: ratio.divisor, divisor: ratio.multiplier))
    }

    /// Wie viel Quellmaterial eine Timeline-Dauer verbraucht.
    static func sourceDuration(forTimelineDuration duration: RationalTime, speed: Double) -> RationalTime {
        let ratio = speedRatio(speed)
        return RationalTime(CMTimeMultiplyByRatio(duration.cmTime, multiplier: ratio.multiplier, divisor: ratio.divisor))
    }

    /// Quellzeit zu einem Timeline-Zeitpunkt, oder `nil`, wenn der Clip dort nicht liegt.
    static func sourceTime(forTimelineTime time: RationalTime, in clip: Clip) -> RationalTime? {
        guard clip.timelineRange.contains(time) else { return nil }
        return clip.sourceRange.start + sourceDuration(forTimelineDuration: time - clip.timelineStart, speed: clip.speed)
    }

    /// Timeline-Zeitpunkt zu einer Quellzeit, oder `nil`, wenn der Clip diese Stelle nicht verwendet.
    static func timelineTime(forSourceTime time: RationalTime, in clip: Clip) -> RationalTime? {
        guard clip.sourceRange.contains(time) else { return nil }
        return clip.timelineStart + timelineDuration(forSourceDuration: time - clip.sourceRange.start, speed: clip.speed)
    }
}

extension Timeline {
    /// Alle Clips, die zum Zeitpunkt `time` sichtbar bzw. hörbar sind, mit ihrer Spur.
    func clips(at time: RationalTime) -> [(track: Track, clip: Clip)] {
        tracks.flatMap { track in
            track.clips.filter { $0.timelineRange.contains(time) }.map { (track, $0) }
        }
    }
}
