/// Einrastpunkte beim Ziehen: Playhead, Timeline-Anfang und die Kanten aller übrigen Clips.
struct SnapTargets: Sendable {
    private(set) var times: [RationalTime]

    init(timeline: Timeline, excluding excluded: Set<Clip.ID>, playhead: RationalTime?) {
        var times: Set<RationalTime> = [.zero]
        if let playhead { times.insert(playhead) }
        for clip in timeline.tracks.flatMap(\.clips) where !excluded.contains(clip.id) {
            times.insert(clip.timelineStart)
            times.insert(clip.timelineEnd)
        }
        self.times = times.sorted()
    }

    /// Kleinste Korrektur, mit der einer der `edges` auf einem Einrastpunkt landet,
    /// sofern sie höchstens `tolerance` beträgt.
    func snap(_ edges: [RationalTime], tolerance: RationalTime) -> (offset: RationalTime, target: RationalTime)? {
        var best: (offset: RationalTime, target: RationalTime)?
        for edge in edges {
            for target in times {
                let offset = target - edge
                let distance = max(offset, .zero - offset)
                guard distance <= tolerance else { continue }
                if let current = best, max(current.offset, .zero - current.offset) <= distance { continue }
                best = (offset, target)
            }
        }
        return best
    }
}
