import CoreMedia
import Foundation

/// Alle Bearbeitungen der Timeline als reine Funktionen, damit sie ohne Oberfläche testbar sind.
///
/// Verknüpfte Clips (gleiche `linkGroupID`) werden beim Schneiden, Verschieben, Trimmen,
/// Löschen und bei Geschwindigkeitsänderungen immer mitgenommen, damit Bild und Ton synchron
/// bleiben. Nach jeder Bearbeitung gilt: jede Spur ist sortiert, ohne Überlappung, und
/// Übergänge gibt es nur zwischen direkt aneinanderliegenden Clips.
enum EditCommands {
    /// Kürzeste erlaubte Cliplänge auf der Timeline.
    static let minimumClipDuration = RationalTime(value: 1, timescale: 30)

    enum Edge: Sendable { case start, end }

    // MARK: Schneiden

    /// Teilt alle Clips, die `time` enthalten. Mit `clips` nur diese (plus verknüpfte).
    /// Die rechten Hälften verknüpfter Clips bilden wieder eine gemeinsame Gruppe.
    @discardableResult
    static func split(_ timeline: inout Timeline, at time: RationalTime, clips ids: Set<Clip.ID>? = nil) -> Bool {
        let candidates = ids.map { timeline.linkedClipIDs($0) }
        var newGroups: [UUID: UUID] = [:]
        var didSplit = false

        for trackIndex in timeline.tracks.indices {
            var result: [Clip] = []
            for clip in timeline.tracks[trackIndex].clips {
                guard candidates?.contains(clip.id) ?? true,
                      time - clip.timelineStart >= minimumClipDuration,
                      clip.timelineEnd - time >= minimumClipDuration,
                      let sourceTime = TimeMapping.sourceTime(forTimelineTime: time, in: clip)
                else {
                    result.append(clip)
                    continue
                }
                var left = clip, right = clip
                right.id = UUID()
                left.sourceRange = RationalTimeRange(start: clip.sourceRange.start, duration: sourceTime - clip.sourceRange.start)
                left.fadeOut = .zero
                right.sourceRange = RationalTimeRange(start: sourceTime, duration: clip.sourceRange.end - sourceTime)
                right.timelineStart = time
                right.fadeIn = .zero
                if let group = clip.linkGroupID {
                    let newGroup = newGroups[group] ?? UUID()
                    newGroups[group] = newGroup
                    right.linkGroupID = newGroup
                }
                for index in timeline.transitions.indices where timeline.transitions[index].fromClipID == clip.id {
                    timeline.transitions[index].fromClipID = right.id
                }
                result += [left, right]
                didSplit = true
            }
            timeline.tracks[trackIndex].clips = result
        }
        return didSplit
    }

    // MARK: Trimmen

    /// Verschiebt eine Kante des Clips um `delta` (Timeline-Zeit) und gibt die tatsächlich
    /// angewendete, begrenzte Verschiebung zurück.
    ///
    /// Verknüpfte Clips mit derselben Kante folgen. Ist die Kante die äußere Kante der
    /// Gruppe, werden verknüpfte Clips, in die sie hineinwandert, ebenfalls gekürzt
    /// (z. B. das später einsetzende Mikrofon, wenn man den Anfang des Videos wegschneidet).
    /// Begrenzt wird durch das vorhandene Material, Nachbarclips und die Mindestlänge.
    @discardableResult
    static func trim(_ timeline: inout Timeline, clip id: Clip.ID, edge: Edge, by delta: RationalTime,
                     assetDurations: [MediaAsset.ID: RationalTime]) -> RationalTime {
        guard let grabbed = timeline.clip(withID: id) else { return .zero }
        let edgeTime = edge == .start ? grabbed.timelineStart : grabbed.timelineEnd
        let group = timeline.linkedClipIDs([id])
        let groupClips = timeline.tracks.flatMap(\.clips).filter { group.contains($0.id) }
        let isOuterEdge = edge == .start
            ? groupClips.allSatisfy { $0.timelineStart >= edgeTime }
            : groupClips.allSatisfy { $0.timelineEnd <= edgeTime }

        var limits = Limits()
        var sharing: Set<Clip.ID> = []
        var cutInto: Set<Clip.ID> = []
        for track in timeline.tracks {
            for (index, clip) in track.clips.enumerated() where group.contains(clip.id) {
                let duration = clip.timelineDuration
                switch edge {
                case .start where clip.timelineStart == edgeTime:
                    sharing.insert(clip.id)
                    let previousEnd = index > 0 ? track.clips[index - 1].timelineEnd : .zero
                    limits.raiseLower(.zero - TimeMapping.timelineDuration(forSourceDuration: clip.sourceRange.start, speed: clip.speed))
                    limits.raiseLower(previousEnd - clip.timelineStart)
                    limits.lowerUpper(duration - minimumClipDuration)
                case .end where clip.timelineEnd == edgeTime:
                    sharing.insert(clip.id)
                    let material = (assetDurations[clip.assetID] ?? clip.sourceRange.end) - clip.sourceRange.end
                    limits.raiseLower(minimumClipDuration - duration)
                    limits.lowerUpper(TimeMapping.timelineDuration(forSourceDuration: max(material, .zero), speed: clip.speed))
                    if index + 1 < track.clips.count {
                        limits.lowerUpper(track.clips[index + 1].timelineStart - clip.timelineEnd)
                    }
                case .start where isOuterEdge:
                    cutInto.insert(clip.id)
                    limits.lowerUpper(clip.timelineEnd - minimumClipDuration - edgeTime)
                case .end where isOuterEdge:
                    cutInto.insert(clip.id)
                    limits.raiseLower(clip.timelineStart + minimumClipDuration - edgeTime)
                default:
                    break
                }
            }
        }

        guard let applied = limits.clamp(delta), applied != .zero else { return .zero }
        let newEdge = edgeTime + applied
        for trackIndex in timeline.tracks.indices {
            for clipIndex in timeline.tracks[trackIndex].clips.indices {
                let clip = timeline.tracks[trackIndex].clips[clipIndex]
                let shift: RationalTime
                if sharing.contains(clip.id) {
                    shift = applied
                } else if cutInto.contains(clip.id), edge == .start, newEdge > clip.timelineStart {
                    shift = newEdge - clip.timelineStart
                } else if cutInto.contains(clip.id), edge == .end, newEdge < clip.timelineEnd {
                    shift = newEdge - clip.timelineEnd
                } else {
                    continue
                }
                timeline.tracks[trackIndex].clips[clipIndex] = moveEdge(of: clip, edge: edge, by: shift)
            }
        }
        timeline.pruneTransitions()
        return applied
    }

    private static func moveEdge(of clip: Clip, edge: Edge, by shift: RationalTime) -> Clip {
        var clip = clip
        let sourceShift = TimeMapping.sourceDuration(forTimelineDuration: shift, speed: clip.speed)
        switch edge {
        case .start:
            clip.timelineStart = clip.timelineStart + shift
            clip.sourceRange = RationalTimeRange(start: clip.sourceRange.start + sourceShift,
                                                 duration: clip.sourceRange.duration - sourceShift)
        case .end:
            clip.sourceRange.duration = clip.sourceRange.duration + sourceShift
        }
        return clip
    }

    /// Untere und obere Grenze für eine Verschiebung; offen, solange nichts sie begrenzt.
    private struct Limits {
        var lower: RationalTime?
        var upper: RationalTime?

        mutating func raiseLower(_ value: RationalTime) { lower = lower.map { max($0, value) } ?? value }
        mutating func lowerUpper(_ value: RationalTime) { upper = upper.map { min($0, value) } ?? value }

        /// `nil`, wenn sich die Grenzen widersprechen.
        func clamp(_ value: RationalTime) -> RationalTime? {
            if let lower, let upper, lower > upper { return nil }
            var result = value
            if let lower { result = max(result, lower) }
            if let upper { result = min(result, upper) }
            return result
        }
    }

    // MARK: Verschieben

    /// Verschiebt die Clips (plus verknüpfte) um `delta`. Clips auf `sourceTrack` landen
    /// dabei auf `targetTrack` (gleicher Spurtyp). `nil`, wenn das Ergebnis ungültig wäre
    /// (Überlappung, Start vor 0, falscher Spurtyp).
    static func move(_ timeline: Timeline, clips ids: Set<Clip.ID>, by delta: RationalTime,
                     from sourceTrack: Track.ID? = nil, to targetTrack: Track.ID? = nil) -> Timeline? {
        let moving = timeline.linkedClipIDs(ids)
        guard !moving.isEmpty else { return nil }
        var targetIndex: Int?
        if let sourceTrack, let targetTrack, sourceTrack != targetTrack {
            guard let from = timeline.tracks.firstIndex(where: { $0.id == sourceTrack }),
                  let to = timeline.tracks.firstIndex(where: { $0.id == targetTrack }),
                  timeline.tracks[from].kind == timeline.tracks[to].kind
            else { return nil }
            targetIndex = to
        }

        var result = timeline
        var moved: [(trackIndex: Int, clip: Clip)] = []
        for trackIndex in result.tracks.indices {
            let isSource = result.tracks[trackIndex].id == sourceTrack
            result.tracks[trackIndex].clips.removeAll { clip in
                guard moving.contains(clip.id) else { return false }
                var shifted = clip
                shifted.timelineStart = clip.timelineStart + delta
                moved.append((isSource ? (targetIndex ?? trackIndex) : trackIndex, shifted))
                return true
            }
        }
        guard moved.allSatisfy({ $0.clip.timelineStart >= .zero }) else { return nil }
        for (trackIndex, clip) in moved {
            result.tracks[trackIndex].clips.append(clip)
        }
        result.sortClips()
        guard result.hasValidLayout else { return nil }
        result.pruneTransitions()
        return result
    }

    // MARK: Löschen

    /// Entfernt die Clips (plus verknüpfte). Beim Ripple-Löschen rücken spätere Clips
    /// derselben Spur um die entfernte Dauer nach, die Lücke schließt sich.
    static func delete(_ timeline: inout Timeline, clips ids: Set<Clip.ID>, ripple: Bool) {
        let removed = timeline.linkedClipIDs(ids)
        guard !removed.isEmpty else { return }
        for trackIndex in timeline.tracks.indices {
            let clips = timeline.tracks[trackIndex].clips
            let gone = clips.filter { removed.contains($0.id) }
            guard !gone.isEmpty else { continue }
            timeline.tracks[trackIndex].clips = clips.filter { !removed.contains($0.id) }.map { clip in
                guard ripple else { return clip }
                var clip = clip
                let shift = gone.filter { $0.timelineStart < clip.timelineStart }
                    .reduce(RationalTime.zero) { $0 + $1.timelineDuration }
                clip.timelineStart = clip.timelineStart - shift
                return clip
            }
        }
        timeline.transitions.removeAll { removed.contains($0.fromClipID) || removed.contains($0.toClipID) }
        timeline.pruneTransitions()
    }

    // MARK: Verknüpfen

    /// Fasst die Clips zu einer neuen Gruppe zusammen (bisherige Gruppen werden verlassen).
    static func link(_ timeline: inout Timeline, clips ids: Set<Clip.ID>) {
        guard ids.count >= 2 else { return }
        let group = UUID()
        timeline.updateClips(ids) { $0.linkGroupID = group }
    }

    /// Löst die Gruppen der Clips komplett auf.
    static func unlink(_ timeline: inout Timeline, clips ids: Set<Clip.ID>) {
        timeline.updateClips(timeline.linkedClipIDs(ids)) { $0.linkGroupID = nil }
    }

    // MARK: Geschwindigkeit

    /// Setzt die Geschwindigkeit der Clips (plus verknüpfte). Der Anfang jeder Gruppe bleibt
    /// stehen, versetzt beginnende verknüpfte Clips rücken passend mit, und spätere Clips der
    /// betroffenen Spuren rücken nach (Ripple). `false`, wenn dadurch etwas überlappen würde.
    @discardableResult
    static func setSpeed(_ timeline: inout Timeline, clips ids: Set<Clip.ID>, to speed: Double) -> Bool {
        applySpeed(&timeline, exactly: timeline.linkedClipIDs(ids), to: speed)
    }

    /// Beschleunigt einen Zeitbereich: Alle Clips darin werden an den Bereichsgrenzen geteilt
    /// (verknüpfte Spuren gemeinsam), die Stücke dazwischen bekommen `speed`, spätere Clips
    /// rücken nach. Mit `muteAudio` werden die Tonclips im Bereich stumm, bei 1× wieder laut.
    /// Gibt den Bereich danach zurück, oder `nil`, wenn dort kein Clip liegt oder etwas überlappen würde.
    @discardableResult
    static func setSpeed(_ timeline: inout Timeline, in range: RationalTimeRange, to speed: Double,
                         muteAudio: Bool) -> RationalTimeRange? {
        var result = timeline
        split(&result, at: range.start)
        split(&result, at: range.end)
        // Liegt eine Grenze zu nah an einer Clipkante, wird dort nicht geteilt; dann zählt,
        // ob der Clip überwiegend im Bereich liegt.
        let inside = Set(result.tracks.flatMap(\.clips).filter { clip in
            let overlap = min(clip.timelineEnd, range.end) - max(clip.timelineStart, range.start)
            return overlap + overlap > clip.timelineDuration
        }.map(\.id))
        guard !inside.isEmpty, applySpeed(&result, exactly: inside, to: speed) else { return nil }

        let audio = Set(result.tracks.filter { $0.kind == .audio }.flatMap(\.clips).map(\.id))
        result.updateClips(inside.intersection(audio)) { $0.isMuted = muteAudio && speed != 1 }
        let changed = result.tracks.flatMap(\.clips).filter { inside.contains($0.id) }
        let start = changed.map(\.timelineStart).min() ?? range.start
        timeline = result
        return RationalTimeRange(start: start, duration: (changed.map(\.timelineEnd).max() ?? start) - start)
    }

    /// Wie `setSpeed`, aber ohne verknüpfte Clips hinzuzunehmen.
    private static func applySpeed(_ timeline: inout Timeline, exactly changed: Set<Clip.ID>, to speed: Double) -> Bool {
        let speed = min(max(speed, Clip.speedRange.lowerBound), Clip.speedRange.upperBound)
        let clips = timeline.tracks.flatMap(\.clips).filter { changed.contains($0.id) }
        guard !clips.isEmpty else { return false }

        // Gruppenanfang als fester Punkt; Clips ohne Gruppe bilden ihre eigene.
        var anchors: [UUID: RationalTime] = [:]
        for clip in clips {
            let key = clip.linkGroupID ?? clip.id
            anchors[key] = min(anchors[key] ?? clip.timelineStart, clip.timelineStart)
        }

        var result = timeline
        for trackIndex in result.tracks.indices {
            var shift = RationalTime.zero
            result.tracks[trackIndex].clips = result.tracks[trackIndex].clips.map { clip in
                var clip = clip
                guard changed.contains(clip.id) else {
                    clip.timelineStart = clip.timelineStart + shift
                    return clip
                }
                let oldEnd = clip.timelineEnd
                let anchor = anchors[clip.linkGroupID ?? clip.id] ?? clip.timelineStart
                let realOffset = TimeMapping.sourceDuration(forTimelineDuration: clip.timelineStart - anchor, speed: clip.speed)
                clip.speed = speed
                clip.timelineStart = anchor + TimeMapping.timelineDuration(forSourceDuration: realOffset, speed: speed) + shift
                shift = clip.timelineEnd - oldEnd
                return clip
            }
        }
        result.sortClips()
        guard result.hasValidLayout else { return false }
        result.pruneTransitions()
        timeline = result
        return true
    }

    // MARK: Übergänge

    static let defaultTransitionDuration = RationalTime(value: 1, timescale: 2)
    static let minimumTransitionDuration = RationalTime(value: 1, timescale: 10)

    /// Schnitt zwischen zwei direkt aneinanderliegenden Clips einer Spur.
    struct Cut: Equatable, Sendable {
        var trackIndex: Int
        var fromClipID: Clip.ID
        var toClipID: Clip.ID
        var time: RationalTime
    }

    /// Fügt am Schnitt hinter `fromClipID` einen Übergang ein. Schnitte verknüpfter Clips an
    /// derselben Stelle (Bild und Ton) bekommen denselben Übergang; vorhandene werden ersetzt.
    /// Gibt den Übergang an `fromClipID` zurück, oder `nil`, wenn dort kein Schnitt ist.
    @discardableResult
    static func addTransition(_ timeline: inout Timeline, after fromClipID: Clip.ID, kind: Transition.Kind,
                              duration: RationalTime = defaultTransitionDuration) -> Transition.ID? {
        let cuts = timeline.cuts
        guard let cut = cuts.first(where: { $0.fromClipID == fromClipID }) else { return nil }
        let fromGroup = timeline.linkedClipIDs([cut.fromClipID]), toGroup = timeline.linkedClipIDs([cut.toClipID])
        var primary: Transition.ID?
        for companion in cuts where companion.time == cut.time
            && fromGroup.contains(companion.fromClipID) && toGroup.contains(companion.toClipID) {
            timeline.transitions.removeAll { $0.fromClipID == companion.fromClipID }
            let transition = Transition(fromClipID: companion.fromClipID, toClipID: companion.toClipID,
                                        kind: kind, duration: duration)
            timeline.transitions.append(transition)
            if companion == cut { primary = transition.id }
        }
        return primary
    }

    /// Ändert den Übergang und die zu ihm gehörenden an verknüpften Clips.
    static func updateTransition(_ timeline: inout Timeline, _ id: Transition.ID, _ change: (inout Transition) -> Void) {
        for companion in timeline.companionTransitionIDs(of: id) {
            timeline.updateTransition(companion, change)
        }
    }

    /// Setzt die Dauer, begrenzt auf die kürzere Länge der beiden Clips.
    static func setTransitionDuration(_ timeline: inout Timeline, _ id: Transition.ID, to duration: RationalTime) {
        guard let transition = timeline.transitions.first(where: { $0.id == id }),
              let from = timeline.clip(withID: transition.fromClipID),
              let to = timeline.clip(withID: transition.toClipID)
        else { return }
        let upper = max(min(from.timelineDuration, to.timelineDuration), minimumTransitionDuration)
        let duration = min(max(duration, minimumTransitionDuration), upper)
        updateTransition(&timeline, id) { $0.duration = duration }
    }

    static func deleteTransition(_ timeline: inout Timeline, _ id: Transition.ID) {
        let ids = timeline.companionTransitionIDs(of: id)
        timeline.transitions.removeAll { ids.contains($0.id) }
    }
}

extension Timeline {
    /// Alle Schnitte, an denen ein Übergang möglich ist.
    var cuts: [EditCommands.Cut] {
        tracks.enumerated().flatMap { trackIndex, track in
            zip(track.clips, track.clips.dropFirst()).compactMap { from, to in
                from.timelineEnd == to.timelineStart
                    ? EditCommands.Cut(trackIndex: trackIndex, fromClipID: from.id, toClipID: to.id, time: from.timelineEnd)
                    : nil
            }
        }
    }

    /// Der Übergang plus die am selben Schnitt zwischen denselben verknüpften Clips.
    func companionTransitionIDs(of id: Transition.ID) -> Set<Transition.ID> {
        guard let transition = transitions.first(where: { $0.id == id }),
              let cut = clip(withID: transition.fromClipID)?.timelineEnd
        else { return [] }
        let fromGroup = linkedClipIDs([transition.fromClipID]), toGroup = linkedClipIDs([transition.toClipID])
        return Set(transitions.filter { other in
            fromGroup.contains(other.fromClipID) && toGroup.contains(other.toClipID)
                && clip(withID: other.fromClipID)?.timelineEnd == cut
        }.map(\.id))
    }

    /// Bereiche mit veränderter Geschwindigkeit, über alle Spuren zusammengefasst
    /// (für die Markierung über der Timeline).
    var speedSegments: [(range: RationalTimeRange, speed: Double)] {
        let changed = tracks.flatMap(\.clips).filter { $0.speed != 1 }.sorted { $0.timelineStart < $1.timelineStart }
        var result: [(range: RationalTimeRange, speed: Double)] = []
        for clip in changed {
            if let index = result.lastIndex(where: { $0.speed == clip.speed && clip.timelineStart <= $0.range.end }) {
                let end = max(result[index].range.end, clip.timelineEnd)
                result[index].range.duration = end - result[index].range.start
            } else {
                result.append((clip.timelineRange, clip.speed))
            }
        }
        return result
    }

    mutating func updateTransition(_ id: Transition.ID, _ change: (inout Transition) -> Void) {
        guard let index = transitions.firstIndex(where: { $0.id == id }) else { return }
        change(&transitions[index])
    }

    /// Die Clips plus alle mit ihnen verknüpften.
    func linkedClipIDs(_ ids: Set<Clip.ID>) -> Set<Clip.ID> {
        let all = tracks.flatMap(\.clips)
        let groups = Set(all.filter { ids.contains($0.id) }.compactMap(\.linkGroupID))
        return ids.union(all.filter { $0.linkGroupID.map(groups.contains) ?? false }.map(\.id))
    }

    func track(containing clipID: Clip.ID) -> Track? {
        tracks.first { track in track.clips.contains { $0.id == clipID } }
    }

    var assetIDs: Set<MediaAsset.ID> { Set(tracks.flatMap(\.clips).map(\.assetID)) }

    mutating func updateClips(_ ids: Set<Clip.ID>, _ change: (inout Clip) -> Void) {
        for trackIndex in tracks.indices {
            for clipIndex in tracks[trackIndex].clips.indices where ids.contains(tracks[trackIndex].clips[clipIndex].id) {
                change(&tracks[trackIndex].clips[clipIndex])
            }
        }
    }

    mutating func sortClips() {
        for index in tracks.indices {
            tracks[index].clips.sort { $0.timelineStart < $1.timelineStart }
        }
    }

    /// Jede Spur sortiert, ohne Überlappung und nicht vor 0.
    var hasValidLayout: Bool {
        tracks.allSatisfy { track in
            track.clips.first.map { $0.timelineStart >= .zero } ?? true
                && zip(track.clips, track.clips.dropFirst()).allSatisfy { $0.timelineEnd <= $1.timelineStart }
        }
    }

    /// Entfernt Übergänge, deren Clips fehlen oder nicht mehr direkt aneinander auf einer Spur liegen.
    mutating func pruneTransitions() {
        let tracks = tracks
        transitions.removeAll { transition in
            guard let track = tracks.first(where: { $0.clips.contains { $0.id == transition.fromClipID } }),
                  let index = track.clips.firstIndex(where: { $0.id == transition.fromClipID }),
                  index + 1 < track.clips.count
            else { return true }
            let next = track.clips[index + 1]
            return next.id != transition.toClipID || next.timelineStart != track.clips[index].timelineEnd
        }
    }
}

extension Project {
    var assetDurations: [MediaAsset.ID: RationalTime] {
        Dictionary(assets.map { ($0.id, $0.duration) }, uniquingKeysWith: { first, _ in first })
    }
}
