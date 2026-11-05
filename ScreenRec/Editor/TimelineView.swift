import AppKit
import SwiftUI

/// Maße der Timeline, gemeinsam für Zeichenfläche und Spurköpfe.
enum TimelineMetrics {
    static let rulerHeight: CGFloat = 24
    /// Streifen unter dem Lineal für markierte Bereiche und Geschwindigkeitsabschnitte.
    static let markerLaneHeight: CGFloat = 16
    /// Zoom-Spur zwischen Bereichsstreifen und erster Spur.
    static let zoomLaneHeight: CGFloat = 28
    static var zoomLaneTop: CGFloat { rulerHeight + markerLaneHeight }
    /// Aufgezeichnete Tasten.
    static let keyLaneHeight: CGFloat = 22
    static var keyLaneTop: CGFloat { zoomLaneTop + zoomLaneHeight }
    /// Texte und Symbole, in zwei Reihen, weil sie sich oft überlappen.
    static let noteLaneRows = 2
    static let noteLaneHeight: CGFloat = 36
    static var noteLaneTop: CGFloat { keyLaneTop + keyLaneHeight }
    /// Oberkante der ersten Spur.
    static var tracksTop: CGFloat { noteLaneTop + noteLaneHeight }
    /// Abstand von Zeitpunkt 0 zum linken Rand.
    static let leadingInset: CGFloat = 12
    static let headerWidth: CGFloat = 176
    static let edgeHitWidth: CGFloat = 6
    static let snapDistance: CGFloat = 8
    /// Ab dieser Mausbewegung wird aus einem Klick ein Ziehen.
    static let dragThreshold: CGFloat = 3

    static func rowHeight(for kind: MediaKind) -> CGFloat {
        kind == .video ? 64 : 48
    }

    static func totalHeight(of timeline: Timeline) -> CGFloat {
        tracksTop + timeline.tracks.reduce(0) { $0 + rowHeight(for: $1.kind) }
    }
}

/// Die Timeline: Zeitlineal, eine Zeile pro Spur, Playhead. Gezeichnet in AppKit, damit es auch
/// bei langen Aufnahmen flüssig bleibt; nur der sichtbare Ausschnitt wird gezeichnet.
struct TimelineView: NSViewRepresentable {
    let editor: TimelineEditor
    let timeline: Timeline
    let assets: [MediaAsset]
    let selection: Set<Clip.ID>
    let selectedTransitionID: Transition.ID?
    let selectedZoomID: ZoomRegion.ID?
    let selectedAnnotationID: Annotation.ID?
    let rangeSelection: RationalTimeRange?
    let playhead: RationalTime
    let isPlaying: Bool
    let pixelsPerSecond: Double
    let isSnappingEnabled: Bool

    func makeNSView(context: Context) -> TimelineScrollView {
        let scrollView = TimelineScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        scrollView.scrollerKnobStyle = .light
        scrollView.documentView = TimelineCanvas(editor: editor)
        return scrollView
    }

    func updateNSView(_ scrollView: TimelineScrollView, context: Context) {
        scrollView.canvas?.update(timeline: timeline, assets: assets, selection: selection,
                                  selectedTransitionID: selectedTransitionID, selectedZoomID: selectedZoomID,
                                  selectedAnnotationID: selectedAnnotationID,
                                  rangeSelection: rangeSelection, playhead: playhead,
                                  isPlaying: isPlaying, pixelsPerSecond: pixelsPerSecond,
                                  isSnappingEnabled: isSnappingEnabled)
    }

    /// Immer genau den angebotenen Platz nehmen. Sonst meldet das Scroll-View die Größe der
    /// Zeichenfläche als Wunschgröße, die wiederum dem sichtbaren Bereich folgt: Das Fenster
    /// wuchs bei jeder Aktualisierung bis an den Bildschirmrand.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TimelineScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? TimelineMetrics.totalHeight(of: timeline))
    }
}

/// Scrollt nur horizontal; ein normales Mausrad (vertikal) scrollt ebenfalls horizontal.
final class TimelineScrollView: NSScrollView {
    var canvas: TimelineCanvas? { documentView as? TimelineCanvas }

    override func tile() {
        super.tile()
        canvas?.updateFrameSize()
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) {
            canvas?.zoom(byScrolling: event)
        } else if !event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) {
            var origin = contentView.bounds.origin
            origin.x = max(0, origin.x - event.scrollingDeltaY * 10)
            contentView.scroll(to: origin)
            reflectScrolledClipView(contentView)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

final class TimelineCanvas: NSView {
    private enum Hit {
        case ruler
        case markerLane
        case zoomLane
        /// `edge`: an einer Kante gepackt, um die Dauer zu ändern.
        case zoom(ZoomRegion, edge: EditCommands.Edge?)
        case annotationLane
        /// `edge`: an einer Kante gepackt, um die Dauer zu ändern.
        case annotation(AnnotationPlacement, edge: EditCommands.Edge?)
        case clip(trackIndex: Int, clip: Clip, edge: EditCommands.Edge?)
        /// `edge`: an einer Kante gepackt, um die Dauer zu ändern.
        case transition(Transition, edge: Bool)
        case empty
    }

    /// Inhalt des Pasteboards beim Ziehen aus der Übergangsleiste, z. B. `screenrec-transition:crossfade`.
    static let transitionDragPrefix = "screenrec-transition:"

    private enum Drag {
        case scrub
        case move(clipID: Clip.ID, trackID: Track.ID, origin: NSPoint, original: Timeline, moving: Set<Clip.ID>, started: Bool)
        case trim(clipID: Clip.ID, edge: EditCommands.Edge, origin: NSPoint, original: Timeline)
        case marquee(origin: NSPoint, current: NSPoint, base: Set<Clip.ID>)
        /// Bereich markieren; `anchor` bleibt fest, die andere Grenze folgt der Maus.
        case range(anchor: RationalTime, origin: NSPoint, started: Bool)
        case transitionDuration(id: Transition.ID, cut: RationalTime, original: Timeline)
        case zoomMove(id: ZoomRegion.ID, origin: NSPoint, original: Timeline, started: Bool)
        case zoomTrim(id: ZoomRegion.ID, edge: EditCommands.Edge, origin: NSPoint, original: Timeline)
        /// Neuen Zoom aufziehen; `anchor` bleibt fest.
        case zoomCreate(anchor: RationalTime, current: RationalTime, origin: NSPoint, started: Bool)
        case annotationMove(placement: AnnotationPlacement, origin: NSPoint, original: Timeline, started: Bool)
        case annotationTrim(placement: AnnotationPlacement, edge: EditCommands.Edge, origin: NSPoint, original: Timeline)
    }

    private weak var editor: TimelineEditor?
    private var timeline = Timeline()
    private var assets: [MediaAsset.ID: MediaAsset] = [:]
    private var selection: Set<Clip.ID> = []
    private var selectedTransitionID: Transition.ID?
    private var selectedZoomID: ZoomRegion.ID?
    private var selectedAnnotationID: Annotation.ID?
    private var rangeSelection: RationalTimeRange?
    private var playhead = RationalTime.zero
    private var pixelsPerSecond = 100.0
    private var isSnappingEnabled = true

    /// Vorschau während eines Drags; übernommen wird erst beim Loslassen (ein Undo-Schritt).
    private var preview: Timeline?
    private var drag: Drag?
    private var snapIndicator: RationalTime?
    /// Schnitt, auf dem ein gezogener Übergang landen würde.
    private var dropCut: EditCommands.Cut?
    private let playheadView = PlayheadView()

    private var displayed: Timeline { preview ?? timeline }
    private var screenAssetIDs: Set<MediaAsset.ID> {
        Set(assets.values.filter { $0.role == .screen }.map(\.id))
    }

    init(editor: TimelineEditor) {
        self.editor = editor
        pixelsPerSecond = editor.pixelsPerSecond
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        addSubview(playheadView)
        let redraw: () -> Void = { [weak self] in self?.needsDisplay = true }
        editor.thumbnails?.onChange = redraw
        editor.waveforms?.onChange = redraw
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) wird nicht unterstützt")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Zustand

    func update(timeline: Timeline, assets: [MediaAsset], selection: Set<Clip.ID>, selectedTransitionID: Transition.ID?,
                selectedZoomID: ZoomRegion.ID?, selectedAnnotationID: Annotation.ID?, rangeSelection: RationalTimeRange?,
                playhead: RationalTime, isPlaying: Bool,
                pixelsPerSecond: Double, isSnappingEnabled: Bool) {
        var changed = false
        if self.timeline != timeline { self.timeline = timeline; changed = true }
        let assetMap = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if self.assets != assetMap { self.assets = assetMap; changed = true }
        if self.selection != selection { self.selection = selection; changed = true }
        if self.selectedTransitionID != selectedTransitionID { self.selectedTransitionID = selectedTransitionID; changed = true }
        if self.selectedZoomID != selectedZoomID { self.selectedZoomID = selectedZoomID; changed = true }
        if self.selectedAnnotationID != selectedAnnotationID { self.selectedAnnotationID = selectedAnnotationID; changed = true }
        if self.rangeSelection != rangeSelection { self.rangeSelection = rangeSelection; changed = true }
        self.isSnappingEnabled = isSnappingEnabled
        self.playhead = playhead
        if self.pixelsPerSecond != pixelsPerSecond { setPixelsPerSecond(pixelsPerSecond, anchor: nil) }
        if changed {
            updateFrameSize()
            needsDisplay = true
        }
        updatePlayhead()
        if isPlaying, drag == nil { followPlayhead() }
    }

    func updateFrameSize() {
        let visible = enclosingScrollView?.contentSize ?? bounds.size
        let width = max(visible.width, x(for: displayed.duration) + max(200, visible.width / 2))
        let size = NSSize(width: width, height: max(visible.height, TimelineMetrics.totalHeight(of: displayed)))
        if frame.size != size { setFrameSize(size) }
        editor?.visibleWidth = visible.width
        updatePlayhead()
    }

    private func updatePlayhead() {
        playheadView.frame = NSRect(x: x(for: playhead) - PlayheadView.width / 2, y: 0, width: PlayheadView.width,
                                    height: bounds.height)
    }

    /// Während der Wiedergabe seitenweise mitscrollen.
    private func followPlayhead() {
        let visible = visibleRect, position = x(for: playhead)
        guard position > visible.maxX - 20 || position < visible.minX else { return }
        scroll(NSPoint(x: max(0, position - 40), y: 0))
    }

    // MARK: Zoom

    /// Ändert den Zoom so, dass `anchor` (Standard: Playhead, sonst Bildmitte) an derselben Stelle bleibt.
    private func setPixelsPerSecond(_ value: Double, anchor: RationalTime?) {
        let visible = visibleRect
        let anchorTime = anchor ?? (visible.contains(NSPoint(x: x(for: playhead), y: visible.midY))
            ? playhead : time(atX: visible.midX))
        let offset = x(for: anchorTime) - visible.minX
        pixelsPerSecond = value
        updateFrameSize()
        scroll(NSPoint(x: max(0, x(for: anchorTime) - offset), y: 0))
        needsDisplay = true
    }

    private func zoom(by factor: Double, around point: NSPoint) {
        let value = min(max(pixelsPerSecond * factor, TimelineEditor.zoomRange.lowerBound), TimelineEditor.zoomRange.upperBound)
        setPixelsPerSecond(value, anchor: time(atX: point.x))
        editor?.setZoom(value)
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    func zoom(byScrolling event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 100 : event.scrollingDeltaY / 10
        zoom(by: 1 + delta, around: convert(event.locationInWindow, from: nil))
    }

    // MARK: Geometrie

    private func x(for time: RationalTime) -> CGFloat {
        TimelineMetrics.leadingInset + time.seconds * pixelsPerSecond
    }

    private func time(atX x: CGFloat) -> RationalTime {
        RationalTime(seconds: max(0, (x - TimelineMetrics.leadingInset) / pixelsPerSecond))
    }

    /// Zieh-Distanz als Zeit, auf ganze 1/60 s gerundet, damit die Timeline-Werte glatt bleiben.
    private func duration(forDistance distance: CGFloat) -> RationalTime {
        RationalTime(value: Int64((distance / pixelsPerSecond * 60).rounded()), timescale: 60)
    }

    /// Zeitpunkt unter der Maus, auf 1/60 s gerundet und an Kanten eingerastet.
    private func snappedTime(atX x: CGFloat) -> RationalTime {
        let time = duration(forDistance: max(0, x - TimelineMetrics.leadingInset))
        guard let snap = snap([time], in: timeline, excluding: []) else { return time }
        snapIndicator = snap.target
        return snap.target
    }

    private func rowRect(_ index: Int, in timeline: Timeline) -> NSRect {
        var y = TimelineMetrics.tracksTop
        for track in timeline.tracks.prefix(index) { y += TimelineMetrics.rowHeight(for: track.kind) }
        return NSRect(x: 0, y: y, width: bounds.width,
                      height: TimelineMetrics.rowHeight(for: timeline.tracks[index].kind))
    }

    private func trackIndex(atY y: CGFloat) -> Int? {
        timeline.tracks.indices.first { rowRect($0, in: timeline).minY <= y && y < rowRect($0, in: timeline).maxY }
    }

    private func clipRect(_ clip: Clip, in row: NSRect) -> NSRect {
        NSRect(x: x(for: clip.timelineStart), y: row.minY + 3,
               width: max(clip.timelineDuration.seconds * pixelsPerSecond, 1), height: row.height - 6)
    }

    private func transitionRect(_ transition: Transition, in timeline: Timeline) -> NSRect? {
        guard let index = timeline.tracks.firstIndex(where: { $0.clips.contains { $0.id == transition.fromClipID } }),
              let from = timeline.clip(withID: transition.fromClipID)
        else { return nil }
        let row = rowRect(index, in: timeline)
        let width = max(transition.duration.seconds * pixelsPerSecond, 16)
        return NSRect(x: x(for: from.timelineEnd) - width / 2, y: row.midY - 9, width: width, height: 18)
    }

    private func zoomRect(_ zoom: ZoomRegion) -> NSRect {
        NSRect(x: x(for: zoom.start), y: TimelineMetrics.zoomLaneTop + 3,
               width: max(zoom.duration.seconds * pixelsPerSecond, 2), height: TimelineMetrics.zoomLaneHeight - 6)
    }

    /// Lage in der Tasten- oder Notizenspur; `rows` kommt von `AnnotationCommands.rows`.
    private func annotationRect(_ placement: AnnotationPlacement, rows: [Annotation.ID: Int]) -> NSRect {
        let width = max(placement.duration.seconds * pixelsPerSecond, 3)
        if placement.annotation.keys != nil {
            return NSRect(x: x(for: placement.start), y: TimelineMetrics.keyLaneTop + 3, width: width,
                          height: TimelineMetrics.keyLaneHeight - 6)
        }
        let height = (TimelineMetrics.noteLaneHeight - 4) / CGFloat(TimelineMetrics.noteLaneRows)
        return NSRect(x: x(for: placement.start),
                      y: TimelineMetrics.noteLaneTop + 2 + CGFloat(rows[placement.annotation.id] ?? 0) * height,
                      width: width, height: height - 1)
    }

    private func noteRows(_ placements: [AnnotationPlacement]) -> [Annotation.ID: Int] {
        AnnotationCommands.rows(for: placements.filter { $0.annotation.keys == nil }, rowCount: TimelineMetrics.noteLaneRows)
    }

    private func hitAnnotation(at point: NSPoint) -> Hit {
        let placements = AnnotationPlacement.resolve(timeline, screenAssetIDs: screenAssetIDs)
        let rows = noteRows(placements)
        let inKeyLane = point.y < TimelineMetrics.noteLaneTop
        // Von hinten, damit gewinnt, was obenauf gezeichnet ist.
        for placement in placements.reversed() where (placement.annotation.keys != nil) == inKeyLane {
            let rect = annotationRect(placement, rows: rows)
            let edgeWidth = min(TimelineMetrics.edgeHitWidth, rect.width / 3)
            guard rect.insetBy(dx: -edgeWidth, dy: 0).contains(point) else { continue }
            if abs(point.x - rect.minX) <= edgeWidth { return .annotation(placement, edge: .start) }
            if abs(point.x - rect.maxX) <= edgeWidth { return .annotation(placement, edge: .end) }
            return .annotation(placement, edge: nil)
        }
        return .annotationLane
    }

    private func hit(at point: NSPoint) -> Hit {
        if point.y < TimelineMetrics.rulerHeight { return .ruler }
        if point.y < TimelineMetrics.zoomLaneTop { return .markerLane }
        if point.y >= TimelineMetrics.keyLaneTop, point.y < TimelineMetrics.tracksTop { return hitAnnotation(at: point) }
        if point.y < TimelineMetrics.tracksTop {
            for zoom in timeline.zooms {
                let rect = zoomRect(zoom)
                let edgeWidth = min(TimelineMetrics.edgeHitWidth, rect.width / 3)
                guard rect.insetBy(dx: -edgeWidth, dy: 0).contains(point) else { continue }
                if abs(point.x - rect.minX) <= edgeWidth { return .zoom(zoom, edge: .start) }
                if abs(point.x - rect.maxX) <= edgeWidth { return .zoom(zoom, edge: .end) }
                return .zoom(zoom, edge: nil)
            }
            return .zoomLane
        }
        for transition in timeline.transitions {
            guard let rect = transitionRect(transition, in: timeline), rect.insetBy(dx: -3, dy: 0).contains(point) else { continue }
            let edgeWidth: CGFloat = rect.width > 16 ? 4 : 0
            return .transition(transition, edge: abs(point.x - rect.minX) <= edgeWidth || abs(point.x - rect.maxX) <= edgeWidth)
        }
        guard let index = trackIndex(atY: point.y) else { return .empty }
        let row = rowRect(index, in: timeline)
        for clip in timeline.tracks[index].clips {
            let rect = clipRect(clip, in: row)
            let edgeWidth = min(TimelineMetrics.edgeHitWidth, rect.width / 3)
            guard rect.insetBy(dx: -edgeWidth, dy: 0).contains(point) else { continue }
            if abs(point.x - rect.minX) <= edgeWidth { return .clip(trackIndex: index, clip: clip, edge: .start) }
            if abs(point.x - rect.maxX) <= edgeWidth { return .clip(trackIndex: index, clip: clip, edge: .end) }
            if rect.contains(point) { return .clip(trackIndex: index, clip: clip, edge: nil) }
        }
        return .empty
    }

    // MARK: Maus

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch hit(at: point) {
        case .clip(_, _, edge: .some), .transition(_, edge: true), .zoom(_, edge: .some), .annotation(_, edge: .some):
            NSCursor.resizeLeftRight.set()
        case .markerLane where rangeEdgeAnchor(at: point) != nil:
            NSCursor.resizeLeftRight.set()
        default:
            NSCursor.arrow.set()
        }
    }

    /// Liegt `point` an einer Kante des markierten Bereichs, die gegenüberliegende Kante.
    private func rangeEdgeAnchor(at point: NSPoint) -> RationalTime? {
        guard let range = rangeSelection else { return nil }
        if abs(point.x - x(for: range.start)) <= TimelineMetrics.edgeHitWidth { return range.end }
        if abs(point.x - x(for: range.end)) <= TimelineMetrics.edgeHitWidth { return range.start }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let modifiers = event.modifierFlags

        switch hit(at: point) {
        case .ruler:
            drag = .scrub
            editor?.seek(to: time(atX: point.x))
        case .markerLane:
            drag = .range(anchor: rangeEdgeAnchor(at: point) ?? snappedTime(atX: point.x), origin: point, started: false)
            snapIndicator = nil
        case .annotationLane:
            setSelectedAnnotation(nil)
            setSelectedZoom(nil)
            editor?.seek(to: time(atX: point.x))
        case .annotation(let placement, let edge):
            setSelectedAnnotation(placement.annotation.id)
            // Die Griffe in der Vorschau gibt es nur, solange die Einblendung im Bild ist.
            if !(placement.start..<placement.end).contains(playhead) { editor?.seek(to: placement.start) }
            if let edge {
                drag = .annotationTrim(placement: placement, edge: edge, origin: point, original: timeline)
            } else {
                drag = .annotationMove(placement: placement, origin: point, original: timeline, started: false)
            }
        case .zoomLane:
            setSelectedAnnotation(nil)
            setSelectedZoom(nil)
            let time = snappedTime(atX: point.x)
            drag = .zoomCreate(anchor: time, current: time, origin: point, started: false)
            snapIndicator = nil
        case .zoom(let zoom, let edge):
            setSelectedZoom(zoom.id)
            if let edge {
                drag = .zoomTrim(id: zoom.id, edge: edge, origin: point, original: timeline)
            } else {
                drag = .zoomMove(id: zoom.id, origin: point, original: timeline, started: false)
            }
        case .transition(let transition, let edge):
            setSelectedTransition(transition.id)
            if edge, let from = timeline.clip(withID: transition.fromClipID) {
                drag = .transitionDuration(id: transition.id, cut: from.timelineEnd, original: timeline)
            }
        case .clip(let trackIndex, let clip, let edge):
            let group = timeline.linkedClipIDs([clip.id])
            if modifiers.contains(.command) {
                setSelection(selection.contains(clip.id) ? selection.subtracting(group) : selection.union(group))
                return
            } else if modifiers.contains(.shift) {
                setSelection(selection.union(group))
            } else if !selection.contains(clip.id) {
                setSelection(group)
            }
            if let edge {
                drag = .trim(clipID: clip.id, edge: edge, origin: point, original: timeline)
            } else {
                drag = .move(clipID: clip.id, trackID: timeline.tracks[trackIndex].id, origin: point, original: timeline,
                             moving: timeline.linkedClipIDs(selection), started: false)
            }
        case .empty:
            setSelectedAnnotation(nil)
            setSelectedZoom(nil)
            let base = modifiers.contains(.shift) ? selection : []
            if base.isEmpty { setSelection([]) }
            drag = .marquee(origin: point, current: point, base: base)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        autoscroll(with: event)
        let point = convert(event.locationInWindow, from: nil)
        snapIndicator = nil

        switch drag {
        case .scrub:
            editor?.seek(to: time(atX: point.x))
        case .move(let clipID, let trackID, let origin, let original, let moving, var started):
            guard started || abs(point.x - origin.x) > TimelineMetrics.dragThreshold
                    || abs(point.y - origin.y) > TimelineMetrics.dragThreshold else { return }
            started = true
            drag = .move(clipID: clipID, trackID: trackID, origin: origin, original: original, moving: moving, started: true)

            var delta = duration(forDistance: point.x - origin.x)
            let clips = original.tracks.flatMap(\.clips).filter { moving.contains($0.id) }
            if let snap = snap(clips.flatMap { [$0.timelineStart + delta, $0.timelineEnd + delta] },
                               in: original, excluding: moving) {
                delta = delta + snap.offset
                snapIndicator = snap.target
            }
            let sourceKind = original.tracks.first { $0.id == trackID }?.kind
            let targetTrack = trackIndex(atY: point.y).map { original.tracks[$0] }.flatMap { $0.kind == sourceKind ? $0.id : nil }
            if let result = EditCommands.move(original, clips: moving, by: delta, from: trackID, to: targetTrack ?? trackID) {
                preview = result
            }
        case .trim(let clipID, let edge, let origin, let original):
            guard let clip = original.clip(withID: clipID), let editor else { return }
            var delta = duration(forDistance: point.x - origin.x)
            let edgeTime = edge == .start ? clip.timelineStart : clip.timelineEnd
            if let snap = snap([edgeTime + delta], in: original, excluding: original.linkedClipIDs([clipID])) {
                delta = delta + snap.offset
                snapIndicator = snap.target
            }
            var result = original
            EditCommands.trim(&result, clip: clipID, edge: edge, by: delta, assetDurations: editor.project.assetDurations)
            preview = result
        case .marquee(let origin, _, let base):
            drag = .marquee(origin: origin, current: point, base: base)
            setSelection(base.union(clips(in: NSRect(from: origin, to: point))))
        case .range(let anchor, let origin, let started):
            guard started || abs(point.x - origin.x) > TimelineMetrics.dragThreshold else { return }
            drag = .range(anchor: anchor, origin: origin, started: true)
            editor?.setRange(from: anchor, to: snappedTime(atX: point.x))
            rangeSelection = editor?.rangeSelection
        case .transitionDuration(let id, let cut, let original):
            let half = duration(forDistance: abs(point.x - x(for: cut)))
            var result = original
            EditCommands.setTransitionDuration(&result, id, to: half + half)
            preview = result
        case .zoomMove(let id, let origin, let original, let started):
            guard started || abs(point.x - origin.x) > TimelineMetrics.dragThreshold else { return }
            drag = .zoomMove(id: id, origin: origin, original: original, started: true)
            guard let zoom = original.zooms.first(where: { $0.id == id }) else { return }
            var delta = duration(forDistance: point.x - origin.x)
            if let snap = snap([zoom.start + delta, zoom.end + delta], in: original, excluding: []) {
                delta = delta + snap.offset
                snapIndicator = snap.target
            }
            var result = original
            ZoomCommands.move(&result, id, by: delta)
            preview = result
        case .zoomTrim(let id, let edge, let origin, let original):
            guard let zoom = original.zooms.first(where: { $0.id == id }) else { return }
            var delta = duration(forDistance: point.x - origin.x)
            if let snap = snap([(edge == .start ? zoom.start : zoom.end) + delta], in: original, excluding: []) {
                delta = delta + snap.offset
                snapIndicator = snap.target
            }
            var result = original
            ZoomCommands.trim(&result, id, edge: edge, by: delta)
            preview = result
        case .zoomCreate(let anchor, _, let origin, let started):
            guard started || abs(point.x - origin.x) > TimelineMetrics.dragThreshold else { return }
            drag = .zoomCreate(anchor: anchor, current: snappedTime(atX: point.x), origin: origin, started: true)
        case .annotationMove(let placement, let origin, let original, let started):
            guard started || abs(point.x - origin.x) > TimelineMetrics.dragThreshold else { return }
            drag = .annotationMove(placement: placement, origin: origin, original: original, started: true)
            var delta = duration(forDistance: point.x - origin.x)
            if let snap = snap([placement.start + delta, placement.end + delta], in: original, excluding: []) {
                delta = delta + snap.offset
                snapIndicator = snap.target
            }
            var result = original
            AnnotationCommands.move(&result, placement.annotation.id, to: placement.start + delta,
                                    screenAssetIDs: screenAssetIDs)
            preview = result
        case .annotationTrim(let placement, let edge, let origin, let original):
            var target = (edge == .start ? placement.start : placement.end) + duration(forDistance: point.x - origin.x)
            if let snap = snap([target], in: original, excluding: []) {
                target = target + snap.offset
                snapIndicator = snap.target
            }
            var result = original
            AnnotationCommands.trim(&result, placement, edge: edge, to: target, screenAssetIDs: screenAssetIDs)
            preview = result
        case nil:
            return
        }
        updateFrameSize()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .move(_, _, _, let original, _, true):
            if let preview, preview != original { editor?.commit(preview, actionName: "Clips verschieben") }
        case .trim(_, _, _, let original):
            if let preview, preview != original { editor?.commit(preview, actionName: "Trimmen") }
        case .transitionDuration(_, _, let original):
            if let preview, preview != original { editor?.commit(preview, actionName: "Übergangsdauer ändern") }
        case .zoomMove(_, _, let original, true):
            if let preview, preview != original { editor?.commit(preview, actionName: "Zoom verschieben") }
        case .zoomTrim(_, _, _, let original):
            if let preview, preview != original { editor?.commit(preview, actionName: "Zoom-Dauer ändern") }
        case .annotationMove(_, _, let original, true):
            if let preview, preview != original { editor?.commit(preview, actionName: "Einblendung verschieben") }
        case .annotationTrim(_, _, _, let original):
            if let preview, preview != original { editor?.commit(preview, actionName: "Einblendungsdauer ändern") }
        case .zoomCreate(let anchor, let current, _, true):
            let start = min(anchor, current), end = max(anchor, current)
            editor?.addZoom(in: RationalTimeRange(start: start, duration: end - start))
            selectedZoomID = editor?.selectedZoomID
        case .zoomCreate(_, _, _, false):
            // Klick in die leere Zoom-Spur: Playhead dorthin.
            editor?.seek(to: time(atX: point.x))
        case .range(_, _, false):
            // Klick in den Streifen: Geschwindigkeitsabschnitt markieren oder Markierung aufheben.
            let time = time(atX: point.x)
            if let segment = timeline.speedSegments.first(where: { $0.range.contains(time) }) {
                editor?.rangeSelection = segment.range
            } else {
                editor?.clearRange()
            }
            rangeSelection = editor?.rangeSelection
        case .marquee(let origin, _, let base):
            if hypot(point.x - origin.x, point.y - origin.y) <= TimelineMetrics.dragThreshold {
                // Einfacher Klick ins Leere: Playhead dorthin.
                editor?.seek(to: time(atX: point.x))
            } else {
                setSelection(timeline.linkedClipIDs(base.union(clips(in: NSRect(from: origin, to: point)))))
            }
        default:
            break
        }
        drag = nil
        preview = nil
        snapIndicator = nil
        updateFrameSize()
        needsDisplay = true
    }

    private func snap(_ edges: [RationalTime], in timeline: Timeline, excluding: Set<Clip.ID>)
        -> (offset: RationalTime, target: RationalTime)? {
        guard isSnappingEnabled != NSEvent.modifierFlags.contains(.control) else { return nil }
        let targets = SnapTargets(timeline: timeline, excluding: excluding, playhead: playhead)
        return targets.snap(edges, tolerance: RationalTime(seconds: TimelineMetrics.snapDistance / pixelsPerSecond))
    }

    private func clips(in rect: NSRect) -> Set<Clip.ID> {
        var result: Set<Clip.ID> = []
        for (index, track) in timeline.tracks.enumerated() {
            let row = rowRect(index, in: timeline)
            for clip in track.clips where clipRect(clip, in: row).intersects(rect) { result.insert(clip.id) }
        }
        return result
    }

    private func setSelection(_ newSelection: Set<Clip.ID>) {
        selection = newSelection
        editor?.selection = newSelection
        needsDisplay = true
    }

    private func setSelectedTransition(_ id: Transition.ID) {
        selection = []
        selectedZoomID = nil
        selectedTransitionID = id
        editor?.selectedTransitionID = id
        needsDisplay = true
    }

    private func setSelectedZoom(_ id: ZoomRegion.ID?) {
        if let id {
            selection = []
            selectedTransitionID = nil
            editor?.selectedZoomID = id
        } else if editor?.selectedZoomID != nil {
            editor?.selectedZoomID = nil
        }
        selectedZoomID = id
        needsDisplay = true
    }

    private func setSelectedAnnotation(_ id: Annotation.ID?) {
        if id != nil {
            selection = []
            selectedTransitionID = nil
            selectedZoomID = nil
        }
        if editor?.selectedAnnotationID != id { editor?.selectedAnnotationID = id }
        selectedAnnotationID = id
        needsDisplay = true
    }

    // MARK: Tastatur und Kontextmenü

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == "s", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            editor?.splitAtPlayhead()
        } else {
            super.keyDown(with: event)
        }
    }

    /// „Bearbeiten > Alles auswählen“ (⌘A) über die Responder-Kette.
    @objc override func selectAll(_ sender: Any?) {
        editor?.selectAll()
    }

    override func cancelOperation(_ sender: Any?) {
        editor?.deselectAll()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let editor else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let point = convert(event.locationInWindow, from: nil)
        switch hit(at: point) {
        case .clip(let trackIndex, let clip, _):
            if !selection.contains(clip.id) { setSelection(timeline.linkedClipIDs([clip.id])) }
            menu.addItem(ActionMenuItem("Am Playhead teilen") { editor.splitAtPlayhead() })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Löschen") { editor.deleteSelection(ripple: false) })
            menu.addItem(ActionMenuItem("Löschen und Lücke schließen") { editor.deleteSelection(ripple: true) })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Verknüpfen", enabled: editor.canLink) { editor.linkSelection() })
            menu.addItem(ActionMenuItem("Verknüpfung aufheben", enabled: editor.canUnlink) { editor.unlinkSelection() })
            if let cut = nearestCut(to: point, trackIndex: trackIndex, involving: clip.id) {
                menu.addItem(.separator())
                for kind in Transition.Kind.allCases {
                    menu.addItem(ActionMenuItem("Übergang „\(kind.title)“ hinzufügen") {
                        editor.addTransition(kind, after: cut.fromClipID)
                    })
                }
            }
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Geschwindigkeit …") { editor.showSpeedSheet() })
        case .transition(let transition, _):
            setSelectedTransition(transition.id)
            for kind in Transition.Kind.allCases where kind != transition.kind {
                menu.addItem(ActionMenuItem("In „\(kind.title)“ ändern") {
                    editor.perform("Übergang ändern") { EditCommands.updateTransition(&$0, transition.id) { $0.kind = kind } }
                })
            }
            menu.addItem(ActionMenuItem("Übergang löschen") { editor.deleteSelection(ripple: false) })
        case .annotationLane:
            let time = time(atX: point.x)
            menu.addItem(ActionMenuItem("Text hier einfügen", enabled: editor.canAddAnnotation) { editor.addText(at: time) })
            for kind in ShapeMark.Kind.allCases {
                menu.addItem(ActionMenuItem("\(kind.title) hier einfügen", enabled: editor.canAddAnnotation) {
                    editor.addShape(kind, at: time)
                })
            }
        case .annotation(let placement, _):
            setSelectedAnnotation(placement.annotation.id)
            menu.addItem(ActionMenuItem("Einblendung löschen") { editor.deleteSelection(ripple: false) })
        case .zoomLane:
            let time = time(atX: point.x)
            menu.addItem(ActionMenuItem("Zoom hier hinzufügen") {
                var added: ZoomRegion.ID?
                editor.perform("Zoom hinzufügen") { added = ZoomCommands.add(&$0, at: time) }
                if let added { editor.selectedZoomID = added } else { NSSound.beep() }
            })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Auto-Zoom aus Klicks erzeugen", enabled: editor.canGenerateAutoZoom) {
                editor.generateAutoZoom()
            })
        case .zoom(let zoom, _):
            setSelectedZoom(zoom.id)
            for focus in ZoomRegion.Focus.allCases where focus != zoom.focus {
                menu.addItem(ActionMenuItem(focus.title) {
                    editor.updateZoom("Zoom ändern", zoom.id) { $0.focus = focus }
                })
            }
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Zoom löschen") { editor.deleteSelection(ripple: false) })
        case .markerLane:
            let time = time(atX: point.x)
            if rangeSelection?.contains(time) != true,
               let segment = timeline.speedSegments.first(where: { $0.range.contains(time) }) {
                editor.rangeSelection = segment.range
                rangeSelection = segment.range
                needsDisplay = true
            }
            let range = editor.rangeSelection
            menu.addItem(ActionMenuItem("Geschwindigkeit …", enabled: range != nil) { editor.showSpeedSheet() })
            menu.addItem(ActionMenuItem("Normale Geschwindigkeit", enabled: range != nil) {
                if let range { editor.setSpeed(1, in: range, muteAudio: false) }
            })
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Bereich aufheben", enabled: range != nil) { editor.clearRange() })
        default:
            return nil
        }
        return menu
    }

    /// Schnitt der Spur, an dem `clip` beteiligt ist und der `point` am nächsten liegt.
    private func nearestCut(to point: NSPoint, trackIndex: Int, involving clipID: Clip.ID) -> EditCommands.Cut? {
        let time = time(atX: point.x)
        return timeline.cuts
            .filter { $0.trackIndex == trackIndex && ($0.fromClipID == clipID || $0.toClipID == clipID) }
            .min { abs(($0.time - time).seconds) < abs(($1.time - time).seconds) }
    }

    // MARK: Übergang aus der Übergangsleiste ablegen

    /// Nächster Schnitt in der Spur unter `point`, höchstens 30 Punkte entfernt.
    private func dropCut(at point: NSPoint) -> EditCommands.Cut? {
        guard let index = trackIndex(atY: point.y) else { return nil }
        return timeline.cuts
            .filter { $0.trackIndex == index && abs(x(for: $0.time) - point.x) <= 30 }
            .min { abs(x(for: $0.time) - point.x) < abs(x(for: $1.time) - point.x) }
    }

    private static func transitionKind(in pasteboard: NSPasteboard) -> Transition.Kind? {
        guard let string = pasteboard.string(forType: .string), string.hasPrefix(transitionDragPrefix) else { return nil }
        return Transition.Kind(rawValue: String(string.dropFirst(transitionDragPrefix.count)))
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let cut = dropCut(at: convert(sender.draggingLocation, from: nil))
        if cut != dropCut {
            dropCut = cut
            needsDisplay = true
        }
        return cut == nil ? [] : .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropCut = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        defer {
            dropCut = nil
            needsDisplay = true
        }
        guard let cut = dropCut(at: convert(sender.draggingLocation, from: nil)),
              let kind = Self.transitionKind(in: sender.draggingPasteboard)
        else { return false }
        editor?.addTransition(kind, after: cut.fromClipID)
        return true
    }

    // MARK: Zeichnen

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tapeDeck.setFill()
        dirtyRect.fill()
        let timeline = displayed

        for (index, track) in timeline.tracks.enumerated() {
            let row = rowRect(index, in: timeline)
            guard row.intersects(dirtyRect) else { continue }
            (index % 2 == 0 ? NSColor.tapeDeckRowA : NSColor.tapeDeckRowB).setFill()
            row.fill()
            for clip in track.clips {
                let rect = clipRect(clip, in: row)
                if rect.intersects(dirtyRect) { draw(clip, of: track, in: rect, dirtyRect: dirtyRect) }
            }
        }
        drawRanges(dirtyRect, timeline: timeline)
        let assetDurations = assets.mapValues(\.duration)
        for transition in timeline.transitions {
            if let rect = transitionRect(transition, in: timeline), rect.intersects(dirtyRect) {
                let playable = CompositionPlan.playableDuration(of: transition, in: timeline, assetDurations: assetDurations)
                draw(transition, in: rect, playable: playable)
            }
        }
        if let dropCut, dropCut.trackIndex < timeline.tracks.count {
            let row = rowRect(dropCut.trackIndex, in: timeline)
            NSColor.tapePink.setFill()
            NSRect(x: x(for: dropCut.time) - 1.5, y: row.minY, width: 3, height: row.height).fill()
        }
        drawRuler(dirtyRect)
        drawMarkerLane(dirtyRect, timeline: timeline)
        drawZoomLane(dirtyRect, timeline: timeline)
        drawAnnotationLanes(dirtyRect, timeline: timeline)

        if case .marquee(let origin, let current, _) = drag {
            let rect = NSRect(from: origin, to: current)
            NSColor.tapeCream.withAlphaComponent(0.12).setFill()
            rect.fill(using: .sourceOver)
            NSColor.tapeCream.setStroke()
            NSBezierPath(rect: rect).stroke()
        }
        if let snapIndicator {
            NSColor.tapeYellow.setFill()
            NSRect(x: x(for: snapIndicator) - 0.5, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    /// Clips wie Bandstücke: Video orange mit Vorschaubildern, Ton als grünes LCD mit Wellenform.
    private func draw(_ clip: Clip, of track: Track, in rect: NSRect, dirtyRect: NSRect) {
        let isVideo = track.kind == .video
        let isSelected = selection.contains(clip.id)
        let alpha = track.isMuted || (!isVideo && clip.isMuted) ? 0.35 : 1
        let body = rect.insetBy(dx: 0, dy: 3)
        let path = NSBezierPath(roundedRect: body, xRadius: 6, yRadius: 6)

        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        (isVideo ? NSColor.tapeOrange : NSColor.tapeLCD).withAlphaComponent(alpha).setFill()
        body.fill()
        let content = body.intersection(dirtyRect)
        if let asset = assets[clip.assetID] {
            switch track.kind {
            case .video:
                // Unten bleibt eine dunklere Kante frei, wie bei einer Taste.
                let film = NSRect(x: body.minX, y: body.minY + 3, width: body.width, height: body.height - 9)
                drawThumbnails(of: clip, asset: asset, in: film, visible: content, alpha: alpha)
            case .audio:
                drawWaveform(of: clip, track: track, asset: asset, in: body.insetBy(dx: 0, dy: 3), visible: content,
                             color: NSColor.tapePhosphor.withAlphaComponent(0.9 * alpha))
            }
        }
        if isVideo {
            NSColor.tapeOrangeDark.withAlphaComponent(alpha).setFill()
            NSRect(x: body.minX, y: body.maxY - 6, width: body.width, height: 6).fill()
        }
        drawFades(of: clip, in: body)
        drawLabel(for: clip, track: track, in: body)
        NSGraphicsContext.restoreGraphicsState()

        let edge: NSColor = isSelected ? .tapePink : (isVideo ? .tapeOrangeLight : .tapePhosphorDim)
        edge.withAlphaComponent(isSelected ? 1 : alpha).setStroke()
        let border = NSBezierPath(roundedRect: body.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        border.lineWidth = isSelected ? 3 : 1.5
        border.stroke()
    }

    private func sourceSeconds(of clip: Clip, atX x: CGFloat, clipRect rect: NSRect) -> Double {
        clip.sourceRange.start.seconds + (x - rect.minX) / pixelsPerSecond * clip.speed
    }

    private func drawThumbnails(of clip: Clip, asset: MediaAsset, in rect: NSRect, visible: NSRect, alpha: Double) {
        guard let thumbnails = editor?.thumbnails else { return }
        let aspect = Double(asset.pixelWidth ?? 16) / Double(max(asset.pixelHeight ?? 9, 1))
        let tileWidth = max(rect.height * aspect, 8)
        let first = Int(((visible.minX - rect.minX) / tileWidth).rounded(.down))
        let last = Int(((visible.maxX - rect.minX) / tileWidth).rounded(.up))
        guard first <= last else { return }
        for index in max(first, 0)...last {
            let tile = NSRect(x: rect.minX + CGFloat(index) * tileWidth, y: rect.minY, width: tileWidth, height: rect.height)
            guard tile.minX < rect.maxX else { break }
            let time = RationalTime(seconds: sourceSeconds(of: clip, atX: tile.minX, clipRect: rect))
            guard let image = thumbnails.image(for: asset, at: time) else { continue }
            NSImage(cgImage: image, size: .zero).draw(in: tile, from: .zero, operation: .sourceOver, fraction: alpha,
                                                      respectFlipped: true, hints: nil)
        }
    }

    private func drawWaveform(of clip: Clip, track: Track, asset: MediaAsset, in rect: NSRect, visible: NSRect,
                              color: NSColor) {
        guard let peaks = editor?.waveforms?.peaks(for: asset), !peaks.isEmpty else { return }
        let gain = Double(clip.volume * track.volume)
        let rate = Double(WaveformCache.peaksPerSecond)
        let halfHeight = rect.height / 2 - 2
        let path = NSBezierPath()
        var x = max(visible.minX, rect.minX).rounded(.down)
        while x < min(visible.maxX, rect.maxX) {
            let from = Int(sourceSeconds(of: clip, atX: x, clipRect: rect) * rate)
            let to = max(Int(sourceSeconds(of: clip, atX: x + 1, clipRect: rect) * rate), from + 1)
            let lower = min(max(from, 0), peaks.count), upper = min(max(to, 0), peaks.count)
            if lower < upper {
                let peak = min(Double(peaks[lower..<upper].max() ?? 0) * gain, 1)
                // Leichte Kompression, damit leise Stellen sichtbar bleiben.
                let height = max(pow(peak, 0.6) * halfHeight, 0.5)
                path.appendRect(NSRect(x: x, y: rect.midY - height, width: 1, height: height * 2))
            }
            x += 1
        }
        color.setFill()
        path.fill()
    }

    private func drawFades(of clip: Clip, in rect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        let fadeIn = min(clip.fadeIn.seconds * pixelsPerSecond, rect.width)
        if fadeIn > 0 {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.minX, y: rect.minY))
            path.line(to: NSPoint(x: rect.minX + fadeIn, y: rect.minY))
            path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
            path.fill()
        }
        let fadeOut = min(clip.fadeOut.seconds * pixelsPerSecond, rect.width)
        if fadeOut > 0 {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.maxX, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX - fadeOut, y: rect.minY))
            path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            path.fill()
        }
    }

    /// Beschriftung als kleines Etikett oben links, das beim Scrollen am sichtbaren Rand bleibt.
    private func drawLabel(for clip: Clip, track: Track, in rect: NSRect) {
        guard rect.width > 30 else { return }
        var text = track.name.uppercased()
        if clip.speed != 1 { text += " · " + Self.formatSpeed(clip.speed) }
        if clip.isMuted, track.kind == .audio { text += " · STUMM" }
        if clip.linkGroupID != nil { text = "🔗 " + text }
        let isVideo = track.kind == .video
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: TapeFont.nsMono(10, weight: .bold),
            .foregroundColor: isVideo ? NSColor.tapeInk : NSColor.tapePhosphor,
            .paragraphStyle: paragraph,
        ]
        let label = NSAttributedString(string: text, attributes: attributes)
        let visibleMinX = max(rect.minX, visibleRect.minX)
        let available = rect.maxX - visibleMinX - 12
        guard available > 20 else { return }
        let size = label.size()
        let chip = NSRect(x: visibleMinX + 6, y: rect.minY + 5, width: min(size.width + 12, available),
                          height: ceil(size.height) + 2)
        let chipPath = NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4)
        (isVideo ? NSColor.tapeOrangeChip : NSColor.tapeLCDChip).withAlphaComponent(0.92).setFill()
        chipPath.fill()
        (isVideo ? NSColor.tapeInk : NSColor.tapePhosphorDim).setStroke()
        chipPath.lineWidth = 1
        chipPath.stroke()
        label.draw(in: chip.insetBy(dx: 6, dy: 1))
    }

    /// Übergang als Kästchen über dem Schnitt. Fehlt Material, wird nur der tatsächlich gespielte
    /// Teil gefüllt und der Rest gestrichelt umrandet; ganz ohne Material ist es rot.
    private func draw(_ transition: Transition, in rect: NSRect, playable: RationalTime?) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        let isShort = playable.map { $0 < transition.duration } ?? true
        if isShort {
            (playable == nil ? NSColor.tapeRed : NSColor.tapePurple).withAlphaComponent(0.3).setFill()
            path.fill()
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
            outline.setLineDash([3, 2], count: 2, phase: 0)
            NSColor.tapeYellow.setStroke()
            outline.stroke()
        }
        let playedWidth = isShort ? (playable?.seconds ?? 0) * pixelsPerSecond : rect.width
        let played = NSRect(x: rect.midX - playedWidth / 2, y: rect.minY, width: playedWidth, height: rect.height)
        if played.width >= 1 {
            let playedPath = NSBezierPath(roundedRect: played, xRadius: 4, yRadius: 4)
            NSColor.tapePurple.setFill()
            playedPath.fill()
            NSColor.tapePurpleLight.setStroke()
            playedPath.lineWidth = 1.5
            playedPath.stroke()
        }

        if isShort {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .heavy),
                .foregroundColor: NSColor.white,
            ]
            let mark = NSAttributedString(string: "!", attributes: attributes)
            let size = mark.size()
            mark.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
        } else {
            let cross = NSBezierPath()
            cross.move(to: NSPoint(x: rect.minX + 3, y: rect.minY + 3))
            cross.line(to: NSPoint(x: rect.maxX - 3, y: rect.maxY - 3))
            cross.move(to: NSPoint(x: rect.minX + 3, y: rect.maxY - 3))
            cross.line(to: NSPoint(x: rect.maxX - 3, y: rect.minY + 3))
            NSColor.tapePaper.withAlphaComponent(0.85).setStroke()
            cross.lineWidth = 1.5
            cross.stroke()
        }
        if transition.id == selectedTransitionID {
            NSColor.tapePink.setStroke()
            path.lineWidth = 3
            path.stroke()
        }
    }

    static func speedColor(_ speed: Double) -> NSColor {
        speed > 1 ? .tapeYellow : .tapeTeal
    }

    /// Leichte Tönung über den Spuren für Geschwindigkeitsabschnitte und den markierten Bereich.
    private func drawRanges(_ dirtyRect: NSRect, timeline: Timeline) {
        let top = TimelineMetrics.tracksTop
        func rect(_ range: RationalTimeRange) -> NSRect {
            NSRect(x: x(for: range.start), y: top, width: range.duration.seconds * pixelsPerSecond, height: bounds.height - top)
        }
        for segment in timeline.speedSegments {
            Self.speedColor(segment.speed).withAlphaComponent(0.1).setFill()
            rect(segment.range).intersection(dirtyRect).fill(using: .sourceOver)
        }
        if let range = rangeSelection {
            let area = rect(range)
            NSColor.tapePhosphor.withAlphaComponent(0.1).setFill()
            area.intersection(dirtyRect).fill(using: .sourceOver)
            NSColor.tapePhosphor.setFill()
            NSRect(x: area.minX - 0.5, y: top, width: 1, height: area.height).fill()
            NSRect(x: area.maxX - 0.5, y: top, width: 1, height: area.height).fill()
        }
    }

    /// Streifen unter dem Lineal: Geschwindigkeitsabschnitte mit Faktor und der markierte Bereich.
    private func drawMarkerLane(_ dirtyRect: NSRect, timeline: Timeline) {
        let lane = NSRect(x: dirtyRect.minX, y: TimelineMetrics.rulerHeight, width: dirtyRect.width,
                          height: TimelineMetrics.markerLaneHeight)
        guard lane.intersects(dirtyRect) else { return }
        NSColor.tapeDeckLane.setFill()
        lane.fill()
        NSColor.tapeDeckLine.setFill()
        NSRect(x: lane.minX, y: lane.maxY - 1, width: lane.width, height: 1).fill()

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: TapeFont.nsMono(9, weight: .bold),
            .foregroundColor: NSColor.tapeInk,
        ]
        // Markierter Bereich unter den Geschwindigkeitsabschnitten, damit deren Faktor lesbar bleibt.
        if let range = rangeSelection {
            NSColor.tapePhosphor.withAlphaComponent(0.3).setFill()
            NSRect(x: x(for: range.start), y: lane.minY, width: range.duration.seconds * pixelsPerSecond,
                   height: lane.height - 1).fill(using: .sourceOver)
        }
        let segments = timeline.speedSegments
        for segment in segments {
            let rect = NSRect(x: x(for: segment.range.start), y: lane.minY + 2,
                              width: max(segment.range.duration.seconds * pixelsPerSecond, 2), height: lane.height - 5)
            guard rect.intersects(dirtyRect) else { continue }
            Self.speedColor(segment.speed).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            let label = NSAttributedString(string: Self.formatSpeed(segment.speed), attributes: labelAttributes)
            if rect.width > label.size().width + 6 {
                let minX = max(rect.minX, visibleRect.minX)
                label.draw(at: NSPoint(x: min(minX + 4, rect.maxX - label.size().width - 3), y: rect.minY))
            }
        }

        if let range = rangeSelection {
            NSColor.tapePhosphor.setFill()
            NSRect(x: x(for: range.start) - 1, y: lane.minY, width: 2, height: lane.height - 1).fill()
            NSRect(x: x(for: range.end) - 1, y: lane.minY, width: 2, height: lane.height - 1).fill()
        } else if segments.isEmpty {
            let hint = NSAttributedString(string: "Hier ziehen, um einen Bereich zu markieren (z. B. zum Beschleunigen)",
                                          attributes: [.font: TapeFont.nsMono(9),
                                                       .foregroundColor: NSColor.tapeEdge])
            hint.draw(at: NSPoint(x: visibleRect.minX + TimelineMetrics.leadingInset, y: lane.minY + 1))
        }
    }

    /// Tasten- und Notizenspur: jede Einblendung als Block mit ihrem Inhalt.
    private func drawAnnotationLanes(_ dirtyRect: NSRect, timeline: Timeline) {
        let lanes = NSRect(x: dirtyRect.minX, y: TimelineMetrics.keyLaneTop, width: dirtyRect.width,
                           height: TimelineMetrics.keyLaneHeight + TimelineMetrics.noteLaneHeight)
        guard lanes.intersects(dirtyRect) else { return }
        NSColor.tapeDeckLane.setFill()
        lanes.fill()
        NSColor.tapeDeckLine.setFill()
        NSRect(x: lanes.minX, y: TimelineMetrics.noteLaneTop - 1, width: lanes.width, height: 1).fill()
        NSRect(x: lanes.minX, y: lanes.maxY - 1, width: lanes.width, height: 1).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: TapeFont.nsMono(9, weight: .bold),
            .foregroundColor: NSColor.tapeInk,
        ]
        let placements = AnnotationPlacement.resolve(timeline, screenAssetIDs: screenAssetIDs)
        let rows = noteRows(placements)
        for placement in placements {
            let rect = annotationRect(placement, rows: rows)
            guard rect.intersects(dirtyRect) else { continue }
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            Self.annotationColor(placement.annotation).setFill()
            path.fill()
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let label = NSAttributedString(string: placement.annotation.title, attributes: attributes)
            label.draw(at: NSPoint(x: max(rect.minX, visibleRect.minX) + 4, y: rect.midY - label.size().height / 2))
            NSGraphicsContext.restoreGraphicsState()
            if placement.annotation.id == selectedAnnotationID {
                let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3, yRadius: 3)
                NSColor.tapePink.setStroke()
                border.lineWidth = 2.5
                border.stroke()
            }
        }
    }

    private static func annotationColor(_ annotation: Annotation) -> NSColor {
        switch annotation.content {
        case .keys(let group): group.isHidden ? .tapeEdge : .tapeYellow
        case .text: .tapePurpleLight
        case .shape: .tapeOrangeLight
        }
    }

    /// Zoom-Spur: jeder Zoom als Block mit Faktor; automatisch erzeugte sind gestrichelt umrandet.
    private func drawZoomLane(_ dirtyRect: NSRect, timeline: Timeline) {
        let lane = NSRect(x: dirtyRect.minX, y: TimelineMetrics.zoomLaneTop, width: dirtyRect.width,
                          height: TimelineMetrics.zoomLaneHeight)
        guard lane.intersects(dirtyRect) else { return }
        NSColor.tapeDeckLane.setFill()
        lane.fill()
        NSColor.tapeDeckLine.setFill()
        NSRect(x: lane.minX, y: lane.maxY - 1, width: lane.width, height: 1).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: TapeFont.nsMono(10, weight: .bold),
            .foregroundColor: NSColor.tapeInk,
        ]
        for zoom in timeline.zooms {
            let rect = zoomRect(zoom)
            guard rect.intersects(dirtyRect) else { continue }
            let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
            NSColor.tapeTeal.setFill()
            path.fill()
            // Ein- und Auszoomen als hellere Rampen an den Enden.
            let ease = min(ZoomPath.maximumEase, zoom.duration.seconds / 2) * pixelsPerSecond
            NSColor.tapePaper.withAlphaComponent(0.25).setFill()
            NSRect(x: rect.minX, y: rect.minY, width: ease, height: rect.height).fill(using: .sourceOver)
            NSRect(x: rect.maxX - ease, y: rect.minY, width: ease, height: rect.height).fill(using: .sourceOver)

            var text = "🔍 " + Self.formatSpeed(zoom.scale)
            if zoom.focus == .point { text += " · FEST" }
            if zoom.isAutomatic { text += " · AUTO" }
            let label = NSAttributedString(string: text, attributes: attributes)
            if rect.width > label.size().width + 10 {
                let minX = max(rect.minX, visibleRect.minX)
                label.draw(at: NSPoint(x: min(minX + 6, rect.maxX - label.size().width - 4),
                                       y: rect.midY - label.size().height / 2))
            }
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 5, yRadius: 5)
            if zoom.id == selectedZoomID {
                NSColor.tapePink.setStroke()
                border.lineWidth = 3
            } else {
                NSColor.tapePaper.withAlphaComponent(0.7).setStroke()
                border.lineWidth = 1.5
                if zoom.isAutomatic { border.setLineDash([4, 3], count: 2, phase: 0) }
            }
            border.stroke()
        }

        if case .zoomCreate(let anchor, let current, _, true) = drag {
            let start = min(anchor, current), end = max(anchor, current)
            let rect = NSRect(x: x(for: start), y: TimelineMetrics.zoomLaneTop + 3,
                              width: (end - start).seconds * pixelsPerSecond, height: TimelineMetrics.zoomLaneHeight - 6)
            NSColor.tapeTeal.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        } else if timeline.zooms.isEmpty {
            let hint = NSAttributedString(string: "Zoom: hier ziehen, um einen Zoom aufzuziehen, oder Rechtsklick für Auto-Zoom",
                                          attributes: [.font: TapeFont.nsMono(9), .foregroundColor: NSColor.tapeEdge])
            hint.draw(at: NSPoint(x: visibleRect.minX + TimelineMetrics.leadingInset,
                                  y: lane.midY - hint.size().height / 2))
        }
    }

    private func drawRuler(_ dirtyRect: NSRect) {
        let ruler = NSRect(x: dirtyRect.minX, y: 0, width: dirtyRect.width, height: TimelineMetrics.rulerHeight)
        guard ruler.intersects(dirtyRect) else { return }
        NSColor.tapeDeck.setFill()
        ruler.fill()
        NSColor.tapeDeckLine.setFill()
        NSRect(x: ruler.minX, y: ruler.maxY - 1, width: ruler.width, height: 1).fill()

        let major = Self.majorTickInterval(forPixelsPerSecond: pixelsPerSecond)
        let minor = major / 5
        let attributes: [NSAttributedString.Key: Any] = [
            .font: TapeFont.nsLCD(16),
            .foregroundColor: NSColor.tapeRim,
        ]
        let startIndex = Int(((dirtyRect.minX - 60 - TimelineMetrics.leadingInset) / pixelsPerSecond / minor).rounded(.down))
        let endIndex = Int(((dirtyRect.maxX - TimelineMetrics.leadingInset) / pixelsPerSecond / minor).rounded(.up))
        for index in max(startIndex, 0)...max(endIndex, 0) {
            let seconds = Double(index) * minor
            let x = TimelineMetrics.leadingInset + seconds * pixelsPerSecond
            let isMajor = index % 5 == 0
            (isMajor ? NSColor.tapeDeckLine : NSColor.tapeDeckTick).setFill()
            if isMajor {
                NSRect(x: x, y: 0, width: 2, height: ruler.height).fill()
                NSAttributedString(string: TimeFormatting.ruler(seconds, interval: major), attributes: attributes)
                    .draw(at: NSPoint(x: x + 5, y: 1))
            } else {
                NSRect(x: x, y: ruler.maxY - 5, width: 1, height: 5).fill()
            }
        }
    }

    /// Abstand der beschrifteten Striche, sodass zwischen zwei Beschriftungen mindestens 80 Punkte liegen.
    static func majorTickInterval(forPixelsPerSecond pixelsPerSecond: Double) -> Double {
        let candidates = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1_800, 3_600]
        return candidates.first { $0 * pixelsPerSecond >= 80 } ?? candidates.last!
    }

    static func formatSpeed(_ speed: Double) -> String {
        speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

/// Playhead als leuchtend pinke Linie mit Kappe im Lineal; lässt Mausklicks zur Timeline durch.
private final class PlayheadView: NSView {
    static let width: CGFloat = 18

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.shadowColor = NSColor.tapePink.cgColor
        layer?.shadowOpacity = 0.8
        layer?.shadowRadius = 4
        layer?.shadowOffset = .zero
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.tapePink.setFill()
        NSRect(x: bounds.midX - 1.5, y: 0, width: 3, height: bounds.height).fill()
        let cap = NSBezierPath(roundedRect: NSRect(x: bounds.midX - 7, y: 1, width: 14, height: 17), xRadius: 4, yRadius: 4)
        cap.fill()
        NSColor.tapePaper.setStroke()
        cap.lineWidth = 1.5
        cap.stroke()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) wird nicht unterstützt")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Menüeintrag mit Closure statt Target/Action.
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) wird nicht unterstützt")
    }

    @objc private func run() { handler() }
}

private extension NSRect {
    init(from a: NSPoint, to b: NSPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
