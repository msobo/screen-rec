import Foundation

/// Bearbeitungen der Zoom-Spur. Wie `EditCommands` reine Funktionen auf der `Timeline`;
/// die Zoom-Abschnitte bleiben sortiert und überlappen nie.
enum ZoomCommands {
    /// Standardlänge eines neu gesetzten Zooms.
    static let defaultDuration = RationalTime(value: 3, timescale: 1)

    // MARK: Auto-Zoom

    /// Klicks, die höchstens so weit auseinanderliegen, landen im selben Zoom.
    static let clusterGap = 2.5
    /// Vorlauf vor dem ersten und Nachlauf nach dem letzten Klick eines Zooms.
    static let leadIn = 0.6
    static let leadOut = 1.8
    static let minimumAutoDuration = 2.0
    static let autoScale = 2.0

    /// Zoom-Abschnitte um Gruppen von Klicks.
    ///
    /// - Parameter clickTimes: Klickzeitpunkte in Aufnahmezeit; sie werden über die Clips der
    ///   Bildschirmaufnahme auf die Timeline abgebildet. Klicks in herausgeschnittenen Stellen entfallen.
    static func automaticZooms(for timeline: Timeline, clickTimes: [Double],
                               screenAssetIDs: Set<MediaAsset.ID>) -> [ZoomRegion] {
        let screenClips = timeline.tracks.filter { $0.kind == .video && !$0.isMuted }.flatMap(\.clips)
            .filter { screenAssetIDs.contains($0.assetID) }
        let times = clickTimes.flatMap { t in
            screenClips.compactMap { TimeMapping.timelineTime(forSourceTime: RationalTime(seconds: t), in: $0)?.seconds }
        }.sorted()
        guard !times.isEmpty else { return [] }

        var clusters: [(first: Double, last: Double)] = []
        for time in times {
            if let last = clusters.last, time - last.last <= clusterGap {
                clusters[clusters.count - 1].last = time
            } else {
                clusters.append((time, time))
            }
        }

        let end = timeline.duration.seconds
        var ranges: [(start: Double, end: Double)] = []
        for cluster in clusters {
            var start = max(cluster.first - leadIn, 0)
            var stop = min(max(cluster.last + leadOut, start + minimumAutoDuration), end)
            if stop - start < minimumAutoDuration { start = max(stop - minimumAutoDuration, 0) }
            stop = min(stop, end)
            guard stop - start >= ZoomRegion.minimumDuration.seconds else { continue }
            if let last = ranges.last, start <= last.end {
                ranges[ranges.count - 1].end = max(last.end, stop)
            } else {
                ranges.append((start, stop))
            }
        }
        return ranges.map { range in
            let start = rounded(range.start)
            return ZoomRegion(start: start, duration: rounded(range.end) - start, scale: autoScale, isAutomatic: true)
        }
    }

    /// Ersetzt die automatisch erzeugten Zooms; von Hand gesetzte bleiben, neue Zooms, die sie
    /// überschneiden würden, entfallen.
    static func replaceAutomaticZooms(_ timeline: inout Timeline, with regions: [ZoomRegion]) {
        let manual = timeline.zooms.filter { !$0.isAutomatic }
        let added = regions.filter { region in !manual.contains { overlaps($0.range, region.range) } }
        timeline.zooms = (manual + added).sorted { $0.start < $1.start }
    }

    // MARK: Bearbeiten

    /// Setzt einen Zoom bei `time` in die Lücke, in der `time` liegt. Liefert dessen ID oder `nil`,
    /// wenn dort schon ein Zoom liegt oder kein Platz ist.
    @discardableResult
    static func add(_ timeline: inout Timeline, at time: RationalTime, duration: RationalTime = defaultDuration,
                    scale: Double = autoScale) -> ZoomRegion.ID? {
        let end = max(timeline.duration, time + ZoomRegion.minimumDuration)
        guard time >= .zero, !timeline.zooms.contains(where: { $0.range.contains(time) }) else { return nil }
        let next = timeline.zooms.first { $0.start > time }?.start ?? end
        let previous = timeline.zooms.last { $0.end <= time }?.end ?? .zero
        var start = time
        var stop = min(time + duration, next)
        // Reicht der Platz nach hinten nicht, nach vorne ausweichen.
        if stop - start < ZoomRegion.minimumDuration { start = max(stop - duration, previous) }
        if stop - start < ZoomRegion.minimumDuration { stop = min(start + ZoomRegion.minimumDuration, next) }
        guard stop - start >= ZoomRegion.minimumDuration else { return nil }
        let region = ZoomRegion(start: start, duration: stop - start, scale: scale)
        timeline.zooms.append(region)
        timeline.zooms.sort { $0.start < $1.start }
        return region.id
    }

    /// Fügt einen Zoom für genau diesen Bereich ein, z. B. aus einem gezogenen Rahmen.
    @discardableResult
    static func add(_ timeline: inout Timeline, range: RationalTimeRange) -> ZoomRegion.ID? {
        guard range.duration >= ZoomRegion.minimumDuration, range.start >= .zero,
              !timeline.zooms.contains(where: { overlaps($0.range, range) })
        else { return nil }
        let region = ZoomRegion(start: range.start, duration: range.duration)
        timeline.zooms.append(region)
        timeline.zooms.sort { $0.start < $1.start }
        return region.id
    }

    /// Verschiebt einen Zoom, höchstens bis an die Nachbarn und nicht vor 0.
    static func move(_ timeline: inout Timeline, _ id: ZoomRegion.ID, by delta: RationalTime) {
        guard let index = timeline.zooms.firstIndex(where: { $0.id == id }) else { return }
        let region = timeline.zooms[index]
        let lower = index > 0 ? timeline.zooms[index - 1].end : .zero
        let upper = index + 1 < timeline.zooms.count ? timeline.zooms[index + 1].start : nil
        var start = max(region.start + delta, lower)
        if let upper, start + region.duration > upper { start = max(upper - region.duration, lower) }
        timeline.zooms[index].start = start
        timeline.zooms[index].isAutomatic = false
    }

    /// Verschiebt eine Kante, mindestens `ZoomRegion.minimumDuration` lang und ohne Überlappung.
    static func trim(_ timeline: inout Timeline, _ id: ZoomRegion.ID, edge: EditCommands.Edge, by delta: RationalTime) {
        guard let index = timeline.zooms.firstIndex(where: { $0.id == id }) else { return }
        let region = timeline.zooms[index]
        switch edge {
        case .start:
            let lower = index > 0 ? timeline.zooms[index - 1].end : .zero
            let start = min(max(region.start + delta, lower), region.end - ZoomRegion.minimumDuration)
            timeline.zooms[index].start = start
            timeline.zooms[index].duration = region.end - start
        case .end:
            let upper = index + 1 < timeline.zooms.count ? timeline.zooms[index + 1].start : nil
            var end = max(region.end + delta, region.start + ZoomRegion.minimumDuration)
            if let upper { end = min(end, upper) }
            timeline.zooms[index].duration = end - region.start
        }
        timeline.zooms[index].isAutomatic = false
    }

    static func update(_ timeline: inout Timeline, _ id: ZoomRegion.ID, _ change: (inout ZoomRegion) -> Void) {
        guard let index = timeline.zooms.firstIndex(where: { $0.id == id }) else { return }
        change(&timeline.zooms[index])
        timeline.zooms[index].isAutomatic = false
    }

    static func delete(_ timeline: inout Timeline, _ id: ZoomRegion.ID) {
        timeline.zooms.removeAll { $0.id == id }
    }

    // MARK: Hilfen

    static func overlaps(_ a: RationalTimeRange, _ b: RationalTimeRange) -> Bool {
        a.start < b.end && b.start < a.end
    }

    /// Auf 1/60 s gerundet, wie die übrigen Timeline-Werte.
    private static func rounded(_ seconds: Double) -> RationalTime {
        RationalTime(value: Int64((seconds * 60).rounded()), timescale: 60)
    }
}

extension Timeline {
    /// Zoom-Abschnitte sortiert, ohne Überlappung und mit Mindestlänge.
    var hasValidZooms: Bool {
        zooms.allSatisfy { $0.start >= .zero && $0.duration >= ZoomRegion.minimumDuration }
            && zip(zooms, zooms.dropFirst()).allSatisfy { $0.end <= $1.start }
    }
}
