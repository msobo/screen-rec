import Foundation

/// Wo eine `Annotation` nach Schnitten und Tempowechseln auf der Timeline liegt.
struct AnnotationPlacement: Equatable, Sendable {
    var annotation: Annotation
    var start: RationalTime
    var duration: RationalTime
    /// Geschwindigkeit des Clips am Anker; danach richtet sich der Takt der Tasten.
    var speed: Double

    var end: RationalTime { start + duration }

    /// Clips der Bildschirmaufnahme, nach Timeline-Zeit sortiert.
    static func screenClips(in timeline: Timeline, screenAssetIDs: Set<MediaAsset.ID>) -> [Clip] {
        timeline.tracks.filter { $0.kind == .video && !$0.isMuted }.flatMap(\.clips)
            .filter { screenAssetIDs.contains($0.assetID) }
            .sorted { $0.timelineStart < $1.timelineStart }
    }

    /// Alle Einblendungen, deren Anker noch im Schnitt vorkommt, nach Start sortiert. Wird eine
    /// Stelle mehrfach verwendet, zählt das erste Vorkommen. Herausgeschnittene entfallen und
    /// kommen zurück, sobald ihre Stelle wieder im Schnitt liegt.
    static func resolve(_ timeline: Timeline, screenAssetIDs: Set<MediaAsset.ID>) -> [AnnotationPlacement] {
        let clips = screenClips(in: timeline, screenAssetIDs: screenAssetIDs)
        let end = timeline.duration
        return timeline.annotations.compactMap { annotation -> AnnotationPlacement? in
            for clip in clips {
                guard let start = TimeMapping.timelineTime(forSourceTime: annotation.anchor, in: clip) else { continue }
                return AnnotationPlacement(annotation: annotation, start: start,
                                           duration: min(annotation.duration, end - start), speed: clip.speed)
            }
            return nil
        }
        .sorted { $0.start < $1.start }
    }

    /// Quellzeit zu einem Timeline-Zeitpunkt. Liegt dort kein Bildschirm-Clip, gilt die nächste
    /// Kante eines Clips; ohne Clips `nil`.
    static func anchor(forTimelineTime time: RationalTime, in timeline: Timeline,
                       screenAssetIDs: Set<MediaAsset.ID>) -> RationalTime? {
        let clips = screenClips(in: timeline, screenAssetIDs: screenAssetIDs)
        if let exact = clips.lazy.compactMap({ TimeMapping.sourceTime(forTimelineTime: time, in: $0) }).first {
            return exact
        }
        let nearest = clips.min { distance(from: time, to: $0) < distance(from: time, to: $1) }
        guard let nearest else { return nil }
        if time < nearest.timelineStart { return nearest.sourceRange.start }
        // Das Ende selbst gehört nicht mehr zum Clip, also knapp davor.
        return nearest.sourceRange.end - RationalTime(value: 1, timescale: 60)
    }

    private static func distance(from time: RationalTime, to clip: Clip) -> Double {
        min(abs((time - clip.timelineStart).seconds), abs((time - clip.timelineEnd).seconds))
    }
}

extension Project {
    var screenAssetIDs: Set<MediaAsset.ID> {
        Set(assets.filter { $0.role == .screen }.map(\.id))
    }

    var annotationPlacements: [AnnotationPlacement] {
        AnnotationPlacement.resolve(timeline, screenAssetIDs: screenAssetIDs)
    }
}
