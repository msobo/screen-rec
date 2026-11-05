import CoreMedia

/// Was aus der Timeline abgespielt wird, noch ohne AVFoundation-Objekte.
///
/// Hier fallen alle inhaltlichen Entscheidungen (Übergänge, A/B-Spuren, Lautstärke- und
/// Deckkraftverläufe); `CompositionBuilder` setzt sie nur noch in eine Composition um.
/// So lässt sich die Logik ohne Mediendateien testen.
struct CompositionPlan: Sendable {
    /// Ein Clip, wie er auf einer Composition-Spur landet.
    struct Segment: Sendable {
        var clipID: Clip.ID
        var assetID: MediaAsset.ID
        var kind: MediaKind
        /// Bildschirm, Kamera, Ton …; bestimmt, wie der Compositor das Bild verwendet.
        var role: MediaAsset.Role
        /// Index der Spur in `Timeline.tracks`.
        var trackIndex: Int
        /// A/B-Spur innerhalb der Timeline-Spur, damit sich Clips bei Überblendungen überlappen können.
        var slot: Int
        /// Inklusive des zusätzlichen Materials für Überblendungen.
        var timelineRange: RationalTimeRange
        var sourceRange: RationalTimeRange
        var speed: Double
        /// Lautstärke (Ton) bzw. Deckkraft (Bild) über die Timeline-Zeit.
        var envelope: GainEnvelope

        var compositionTrackKey: CompositionTrackKey { CompositionTrackKey(trackIndex: trackIndex, slot: slot) }
    }

    struct CompositionTrackKey: Hashable, Sendable {
        var trackIndex: Int
        var slot: Int
    }

    /// Ein Übergang, wie er tatsächlich gespielt wird.
    struct ResolvedTransition: Sendable {
        var transitionID: Transition.ID
        var kind: Transition.Kind
        var trackIndex: Int
        /// Schnittpunkt zwischen den beiden Clips; der Übergang liegt symmetrisch darum.
        var cut: RationalTime
        /// Halbe tatsächliche Dauer. Kann kürzer sein als gewünscht, wenn Material fehlt.
        var halfDuration: RationalTime

        var duration: RationalTime { halfDuration + halfDuration }
    }

    /// Abschnitt der Video-Timeline mit gleichbleibender Ebenenfolge.
    struct VideoInterval: Sendable {
        var range: RationalTimeRange
        /// Indizes in `segments`, von unten nach oben.
        var layers: [Int]
    }

    /// Raster für die Grenzen der Bild-Abschnitte: eine Nanosekunde.
    private static let intervalTimescale: Int32 = 1_000_000_000

    private(set) var segments: [Segment] = []
    private(set) var transitions: [ResolvedTransition] = []
    let duration: RationalTime

    init(project: Project) {
        duration = project.timeline.duration
        let assetDurations = Dictionary(project.assets.map { ($0.id, $0.duration) }, uniquingKeysWith: { a, _ in a })
        let roles = Dictionary(project.assets.map { ($0.id, $0.role) }, uniquingKeysWith: { a, _ in a })

        for (trackIndex, track) in project.timeline.tracks.enumerated() where !track.isMuted {
            let clips = track.clips.sorted { $0.timelineStart < $1.timelineStart }
            let resolved = clips.indices.dropLast().map { index in
                Self.resolveTransition(between: clips[index], and: clips[index + 1], trackIndex: trackIndex,
                                       in: project.timeline, assetDurations: assetDurations)
            }
            transitions += resolved.compactMap { $0 }

            var slot = 0
            for (index, clip) in clips.enumerated() {
                let incoming = index > 0 ? resolved[index - 1] : nil
                let outgoing = index < resolved.count ? resolved[index] : nil
                if incoming?.kind == .crossfade { slot = 1 - slot }
                let base = track.kind == .audio ? (clip.isMuted ? 0 : Double(track.volume * clip.volume)) : 1
                segments.append(Self.segment(for: clip, kind: track.kind, role: roles[clip.assetID] ?? .imported,
                                             trackIndex: trackIndex, slot: slot,
                                             base: base, incoming: incoming, outgoing: outgoing,
                                             assetDuration: assetDurations[clip.assetID]))
            }
        }
    }

    /// Lückenlose Abschnitte von 0 bis `end` mit den jeweils sichtbaren Bild-Segmenten.
    ///
    /// Die Grenzen landen auf einem gemeinsamen Raster: Nach Schnitten und Tempowechseln haben die
    /// Zeiten unverträgliche Timescales, ihre Differenzen würden gerundet. Eine Grenze, die sich nur
    /// um Bruchteile einer Nanosekunde von der nächsten unterscheidet, ergäbe sonst einen Abschnitt
    /// der Länge null, und mit dem liefert AVFoundation für die ganze Composition kein Bild mehr.
    func videoIntervals(upTo end: RationalTime) -> [VideoInterval] {
        let video = segments.indices.filter { segments[$0].kind == .video }
        let end = end.rounded(toTimescale: Self.intervalTimescale)
        let ranges = Dictionary(uniqueKeysWithValues: video.map { index in
            let range = segments[index].timelineRange
            return (index, (start: range.start.rounded(toTimescale: Self.intervalTimescale),
                            end: range.end.rounded(toTimescale: Self.intervalTimescale)))
        })
        let boundaries = Set([.zero, end] + ranges.values.flatMap { [$0.start, $0.end] })
            .filter { $0 >= .zero && $0 <= end }
            .sorted()

        return zip(boundaries, boundaries.dropFirst()).map { start, stop in
            let layers = video
                .filter { ranges[$0]!.start <= start && ranges[$0]!.end >= stop }
                // Weiter oben in der Timeline liegende Spuren liegen auch im Bild oben;
                // innerhalb einer Spur liegt der spätere Clip über dem früheren (Überblendung).
                .sorted { a, b in
                    let lhs = segments[a], rhs = segments[b]
                    if lhs.trackIndex != rhs.trackIndex { return lhs.trackIndex > rhs.trackIndex }
                    return lhs.timelineRange.start < rhs.timelineRange.start
                }
            return VideoInterval(range: RationalTimeRange(start: start, duration: stop - start), layers: layers)
        }
    }

    /// Quellzeit der obersten Bildschirm-Ebene zum Timeline-Zeitpunkt (für Cursor und Zoom).
    /// Bei Überblendungen gewinnt der später beginnende Clip, wie im Bild.
    func screenSourceTime(at time: RationalTime) -> Double? {
        let visible = segments.filter {
            $0.kind == .video && $0.role != .camera && $0.timelineRange.start <= time && time < $0.timelineRange.end
        }
        guard let top = visible.min(by: { a, b in
            a.trackIndex != b.trackIndex ? a.trackIndex < b.trackIndex : a.timelineRange.start > b.timelineRange.start
        }) else { return nil }
        return top.sourceRange.start.seconds + (time - top.timelineRange.start).seconds * top.speed
    }

    /// Wie lange der Übergang tatsächlich spielt (unabhängig von stummen Spuren),
    /// oder `nil`, wenn er gar nicht gespielt werden kann.
    static func playableDuration(of transition: Transition, in timeline: Timeline,
                                 assetDurations: [MediaAsset.ID: RationalTime]) -> RationalTime? {
        guard let from = timeline.clip(withID: transition.fromClipID),
              let to = timeline.clip(withID: transition.toClipID)
        else { return nil }
        return resolveTransition(between: from, and: to, trackIndex: 0, in: timeline, assetDurations: assetDurations)?.duration
    }

    // MARK: Aufbau

    private static func half(_ time: RationalTime) -> RationalTime {
        RationalTime(CMTimeMultiplyByRatio(time.cmTime, multiplier: 1, divisor: 2))
    }

    private static func resolveTransition(between from: Clip, and to: Clip, trackIndex: Int, in timeline: Timeline,
                                          assetDurations: [MediaAsset.ID: RationalTime]) -> ResolvedTransition? {
        guard from.timelineEnd == to.timelineStart,
              let transition = timeline.transitions.first(where: { $0.fromClipID == from.id && $0.toClipID == to.id })
        else { return nil }

        var halfDuration = min(half(transition.duration), half(from.timelineDuration), half(to.timelineDuration))
        if transition.kind == .crossfade {
            // Überblenden braucht Material hinter dem Ende des ersten und vor dem Anfang des zweiten Clips.
            let afterFrom = max((assetDurations[from.assetID] ?? from.sourceRange.end) - from.sourceRange.end, .zero)
            let beforeTo = max(to.sourceRange.start, .zero)
            halfDuration = min(halfDuration,
                               TimeMapping.timelineDuration(forSourceDuration: afterFrom, speed: from.speed),
                               TimeMapping.timelineDuration(forSourceDuration: beforeTo, speed: to.speed))
        }
        guard halfDuration > .zero else { return nil }
        return ResolvedTransition(transitionID: transition.id, kind: transition.kind, trackIndex: trackIndex,
                                  cut: from.timelineEnd, halfDuration: halfDuration)
    }

    private static func segment(for clip: Clip, kind: MediaKind, role: MediaAsset.Role, trackIndex: Int, slot: Int,
                                base: Double,
                                incoming: ResolvedTransition?, outgoing: ResolvedTransition?,
                                assetDuration: RationalTime?) -> Segment {
        var timelineRange = clip.timelineRange
        var sourceRange = clip.sourceRange
        var ramps: [GainEnvelope.Ramp] = []

        if let incoming {
            let start = incoming.cut - incoming.halfDuration, end = incoming.cut + incoming.halfDuration
            switch incoming.kind {
            case .crossfade:
                let extra = TimeMapping.sourceDuration(forTimelineDuration: incoming.halfDuration, speed: clip.speed)
                let sourceStart = max(sourceRange.start - extra, .zero)
                sourceRange = RationalTimeRange(start: sourceStart, duration: sourceRange.end - sourceStart)
                timelineRange = RationalTimeRange(start: start, duration: timelineRange.end - start)
                // Bild: der neue Clip liegt oben und wird eingeblendet. Ton: beide werden überblendet.
                ramps.append(.init(start: start, end: end, from: 0, to: 1))
            case .fadeThroughBlack:
                ramps.append(.init(start: incoming.cut, end: end, from: 0, to: 1))
            }
        }
        if let outgoing {
            let start = outgoing.cut - outgoing.halfDuration, end = outgoing.cut + outgoing.halfDuration
            switch outgoing.kind {
            case .crossfade:
                let extra = TimeMapping.sourceDuration(forTimelineDuration: outgoing.halfDuration, speed: clip.speed)
                let sourceEnd = min(sourceRange.end + extra, assetDuration ?? sourceRange.end + extra)
                sourceRange = RationalTimeRange(start: sourceRange.start, duration: sourceEnd - sourceRange.start)
                timelineRange = RationalTimeRange(start: timelineRange.start, duration: end - timelineRange.start)
                if kind == .audio { ramps.append(.init(start: start, end: end, from: 1, to: 0)) }
            case .fadeThroughBlack:
                ramps.append(.init(start: start, end: outgoing.cut, from: 1, to: 0))
            }
        }

        let length = timelineRange.duration
        if clip.fadeIn > .zero {
            ramps.append(.init(start: timelineRange.start, end: timelineRange.start + min(clip.fadeIn, length), from: 0, to: 1))
        }
        if clip.fadeOut > .zero {
            ramps.append(.init(start: timelineRange.end - min(clip.fadeOut, length), end: timelineRange.end, from: 1, to: 0))
        }

        return Segment(clipID: clip.id, assetID: clip.assetID, kind: kind, role: role, trackIndex: trackIndex, slot: slot,
                       timelineRange: timelineRange, sourceRange: sourceRange, speed: clip.speed,
                       envelope: .product(base: base, ramps: ramps, over: timelineRange))
    }
}
