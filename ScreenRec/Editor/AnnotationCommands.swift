import Foundation

/// Bearbeitungen der Einblendungen. Wie `ZoomCommands` reine Funktionen auf der `Timeline`,
/// allerdings dürfen sich Einblendungen überlappen.
enum AnnotationCommands {
    /// Standardlänge neuer Texte und Symbole.
    static let defaultDuration = RationalTime(value: 3, timescale: 1)
    /// Vorgabe beim Maskieren.
    static let defaultMask = "***"

    // MARK: Einfügen

    @discardableResult
    static func add(_ timeline: inout Timeline, _ content: Annotation.Content, at time: RationalTime,
                    screenAssetIDs: Set<MediaAsset.ID>) -> Annotation.ID? {
        guard let anchor = AnnotationPlacement.anchor(forTimelineTime: time, in: timeline,
                                                      screenAssetIDs: screenAssetIDs)
        else { return nil }
        let annotation = Annotation(anchor: anchor, duration: defaultDuration, content: content)
        timeline.annotations.append(annotation)
        return annotation.id
    }

    /// Neues Symbol; Nummern zählen hoch.
    static func newShape(_ kind: ShapeMark.Kind, in timeline: Timeline) -> Annotation.Content {
        var mark = ShapeMark(kind: kind)
        switch kind {
        case .arrow: break
        case .ellipse, .rectangle:
            mark.start = AnnotationPoint(x: 0.38, y: 0.38)
            mark.end = AnnotationPoint(x: 0.62, y: 0.62)
        case .badge:
            mark.start = AnnotationPoint(x: 0.5, y: 0.5)
            mark.number = nextBadgeNumber(in: timeline)
        }
        return .shape(mark)
    }

    static func nextBadgeNumber(in timeline: Timeline) -> Int {
        let numbers = timeline.annotations.compactMap { annotation -> Int? in
            if case .shape(let mark) = annotation.content, mark.kind == .badge { mark.number } else { nil }
        }
        return (numbers.max() ?? 0) + 1
    }

    // MARK: Bearbeiten

    /// Legt die Einblendung auf einen neuen Timeline-Zeitpunkt.
    static func move(_ timeline: inout Timeline, _ id: Annotation.ID, to time: RationalTime,
                     screenAssetIDs: Set<MediaAsset.ID>) {
        guard let index = timeline.annotations.firstIndex(where: { $0.id == id }),
              let anchor = AnnotationPlacement.anchor(forTimelineTime: max(time, .zero), in: timeline,
                                                      screenAssetIDs: screenAssetIDs)
        else { return }
        timeline.annotations[index].anchor = anchor
    }

    /// Setzt eine Kante auf einen Timeline-Zeitpunkt. `placement` ist die Lage vor der Änderung.
    static func trim(_ timeline: inout Timeline, _ placement: AnnotationPlacement, edge: EditCommands.Edge,
                     to time: RationalTime, screenAssetIDs: Set<MediaAsset.ID>) {
        let id = placement.annotation.id
        guard let index = timeline.annotations.firstIndex(where: { $0.id == id }) else { return }
        switch edge {
        case .start:
            let start = min(max(time, .zero), placement.end - Annotation.minimumDuration)
            guard let anchor = AnnotationPlacement.anchor(forTimelineTime: start, in: timeline,
                                                          screenAssetIDs: screenAssetIDs)
            else { return }
            timeline.annotations[index].anchor = anchor
            timeline.annotations[index].duration = placement.end - start
        case .end:
            timeline.annotations[index].duration = max(time - placement.start, Annotation.minimumDuration)
        }
    }

    static func update(_ timeline: inout Timeline, _ id: Annotation.ID, _ change: (inout Annotation) -> Void) {
        guard let index = timeline.annotations.firstIndex(where: { $0.id == id }) else { return }
        change(&timeline.annotations[index])
    }

    static func delete(_ timeline: inout Timeline, _ id: Annotation.ID) {
        timeline.annotations.removeAll { $0.id == id }
    }

    // MARK: Tasten

    /// Ersetzt die Tasten durch `text`, ein Zeichen je Kappe. Vorhandene Abstände bleiben, soweit
    /// es sie gibt.
    static func setKeys(_ timeline: inout Timeline, _ id: Annotation.ID, text: String) {
        updateKeys(&timeline, id) { group in
            let offsets = group.keys.map(\.offset)
            group.isHidden = false
            group.keys = text.enumerated().map { index, character in
                KeyGroup.Key(offset: index < offsets.count ? offsets[index] : offsets.last ?? 0,
                             caps: [character == " " ? KeystrokeLabel.spaceCap : String(character)])
            }
        }
    }

    /// Zeigt statt der Eingabe `mask`. Das Original wird überschrieben, nicht nur verdeckt, und
    /// mit ihm der Takt des Tippens: So bleibt nach dem Speichern nichts davon im Projekt.
    static func mask(_ timeline: inout Timeline, _ id: Annotation.ID, with mask: String) {
        updateKeys(&timeline, id) { group in
            group.keys = mask.map { KeyGroup.Key(offset: 0, caps: [String($0)]) }
            group.isHidden = false
        }
    }

    /// Blendet die Eingabe aus. Wie beim Maskieren verschwindet das Original, der Eintrag bleibt
    /// in der Spur sichtbar.
    static func hide(_ timeline: inout Timeline, _ id: Annotation.ID) {
        updateKeys(&timeline, id) { group in
            group.keys = [KeyGroup.Key(offset: 0, caps: [KeyGroup.hiddenSymbol])]
            group.isHidden = true
        }
    }

    /// Teilt eine Tastengruppe vor der ersten Taste ab `offset` Sekunden Quellzeit nach dem Anker,
    /// z. B. um nur einen Teil zu maskieren. Liefert die ID der hinteren Gruppe.
    @discardableResult
    static func split(_ timeline: inout Timeline, _ id: Annotation.ID, atOffset offset: Double) -> Annotation.ID? {
        guard let index = timeline.annotations.firstIndex(where: { $0.id == id }),
              let group = timeline.annotations[index].keys,
              let cut = group.keys.firstIndex(where: { $0.offset >= offset }), cut > 0
        else { return nil }
        let annotation = timeline.annotations[index]
        let splitOffset = group.keys[cut].offset
        let splitTime = RationalTime(seconds: splitOffset)

        var front = group
        front.keys = Array(group.keys[..<cut])
        var back = group
        back.keys = group.keys[cut...].map { KeyGroup.Key(offset: $0.offset - splitOffset, caps: $0.caps) }

        timeline.annotations[index].content = .keys(front)
        timeline.annotations[index].duration = min(splitTime, annotation.duration)
        let rest = Annotation(anchor: annotation.anchor + splitTime,
                              duration: max(annotation.duration - splitTime, Annotation.minimumDuration),
                              content: .keys(back))
        timeline.annotations.append(rest)
        return rest.id
    }

    private static func updateKeys(_ timeline: inout Timeline, _ id: Annotation.ID, _ change: (inout KeyGroup) -> Void) {
        update(&timeline, id) { annotation in
            guard var group = annotation.keys else { return }
            change(&group)
            annotation.content = .keys(group)
        }
    }

    // MARK: Spur

    /// Verteilt Einblendungen auf `rowCount` Reihen; was nirgends frei ist, landet in der letzten.
    static func rows(for placements: [AnnotationPlacement], rowCount: Int) -> [Annotation.ID: Int] {
        var ends = [RationalTime](repeating: .zero, count: rowCount)
        var rows: [Annotation.ID: Int] = [:]
        for placement in placements {
            let row = ends.firstIndex { $0 <= placement.start } ?? rowCount - 1
            rows[placement.annotation.id] = row
            ends[row] = max(ends[row], placement.end)
        }
        return rows
    }
}
