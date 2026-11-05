import SwiftUI

/// Griffe über der Vorschau, mit denen man Text und Symbole dort platziert, wo sie im Bild stehen.
///
/// Während des Ziehens wird nur der Umriss bewegt. Das Bild selbst folgt beim Loslassen, weil jede
/// Änderung die Composition neu aufbaut.
struct AnnotationOverlayView: View {
    private enum Handle: Hashable { case start, end, body }

    let editor: TimelineEditor
    let playback: PlaybackController
    @State private var dragged: [Handle: AnnotationPoint] = [:]

    private static let handleSize: CGFloat = 14

    var body: some View {
        if let placement = editor.selectedPlacement, placement.annotation.keys == nil,
           let scene = playback.current?.scene, let renderSize = playback.current?.videoComposition?.renderSize,
           placement.start <= playback.currentTime, playback.currentTime < placement.end {
            GeometryReader { proxy in
                let mapping = Mapping(layout: SceneLayout(output: renderSize, sourceSize: scene.sourceSize, look: scene.look),
                                      zoom: scene.zoom.state(at: playback.currentTime.seconds),
                                      view: proxy.size, followsZoom: placement.annotation.followsZoom)
                let points = dragged.isEmpty ? Self.points(of: placement.annotation) : dragged
                ZStack(alignment: .topLeading) {
                    outline(of: placement.annotation, points: points, mapping: mapping)
                        .stroke(Tape.pink, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .allowsHitTesting(false)
                    ForEach(Array(points.keys), id: \.self) { handle in
                        if let point = points[handle] {
                            grip(handle, at: point, annotation: placement.annotation, mapping: mapping)
                        }
                    }
                }
            }
        }
    }

    private func grip(_ handle: Handle, at point: AnnotationPoint, annotation: Annotation, mapping: Mapping) -> some View {
        let position = mapping.viewPoint(for: point)
        return Circle()
            .fill(handle == .body ? Tape.pink : Tape.paper)
            .overlay { Circle().strokeBorder(Tape.ink, lineWidth: 1.5) }
            .frame(width: Self.handleSize, height: Self.handleSize)
            .contentShape(Circle().inset(by: -6))
            .position(position)
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .local)
                .onChanged { drag in
                    let target = mapping.annotationPoint(for: drag.location).clamped()
                    dragged = Self.moved(Self.points(of: annotation), handle: handle, to: target)
                }
                .onEnded { _ in commit(annotation) })
            .accessibilityLabel("Einblendung verschieben")
    }

    /// Lage aller Griffe, wenn `handle` nach `target` gezogen wird. Der mittlere Griff bewegt alles.
    private static func moved(_ points: [Handle: AnnotationPoint], handle: Handle,
                              to target: AnnotationPoint) -> [Handle: AnnotationPoint] {
        var result = points
        if handle == .body, let body = points[.body] {
            let dx = target.x - body.x, dy = target.y - body.y
            for (key, point) in points {
                result[key] = AnnotationPoint(x: point.x + dx, y: point.y + dy).clamped()
            }
        } else {
            result[handle] = target
            if let start = result[.start], let end = result[.end], result[.body] != nil {
                result[.body] = AnnotationPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
            }
        }
        return result
    }

    /// Gespeicherte Lage der Griffe.
    private static func points(of annotation: Annotation) -> [Handle: AnnotationPoint] {
        switch annotation.content {
        case .keys: return [:]
        case .text(let note): return [.body: note.position]
        case .shape(let mark):
            if mark.kind == .badge { return [.body: mark.start] }
            return [.start: mark.start, .end: mark.end,
                    .body: AnnotationPoint(x: (mark.start.x + mark.end.x) / 2, y: (mark.start.y + mark.end.y) / 2)]
        }
    }

    private func outline(of annotation: Annotation, points: [Handle: AnnotationPoint], mapping: Mapping) -> Path {
        var path = Path()
        guard case .shape(let mark) = annotation.content, mark.kind != .badge,
              let start = points[.start].map(mapping.viewPoint), let end = points[.end].map(mapping.viewPoint)
        else { return path }
        let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        switch mark.kind {
        case .ellipse: path.addEllipse(in: rect)
        case .rectangle: path.addRect(rect)
        default:
            path.move(to: start)
            path.addLine(to: end)
        }
        return path
    }

    private func commit(_ annotation: Annotation) {
        let points = dragged
        dragged = [:]
        guard !points.isEmpty else { return }
        editor.perform("Einblendung verschieben") { timeline in
            AnnotationCommands.update(&timeline, annotation.id) { annotation in
                switch annotation.content {
                case .keys: break
                case .text(var note):
                    note.position = points[.body] ?? note.position
                    annotation.content = .text(note)
                case .shape(var mark):
                    if mark.kind == .badge {
                        mark.start = points[.body] ?? mark.start
                    } else {
                        mark.start = points[.start] ?? mark.start
                        mark.end = points[.end] ?? mark.end
                    }
                    annotation.content = .shape(mark)
                }
            }
        }
    }

    /// Rechnet zwischen Einblendung und Ansicht um, auch durch den aktuellen Zoom hindurch.
    private struct Mapping {
        let layout: SceneLayout
        let zoom: ZoomPath.State
        let view: CGSize
        let followsZoom: Bool

        private var transform: CGAffineTransform { followsZoom ? layout.zoomTransform(zoom) : .identity }

        func viewPoint(for point: AnnotationPoint) -> CGPoint {
            let pixel = layout.point(for: point, followsZoom: followsZoom).applying(transform)
            return CGPoint(x: pixel.x / layout.output.width * view.width,
                           y: (1 - pixel.y / layout.output.height) * view.height)
        }

        func annotationPoint(for point: CGPoint) -> AnnotationPoint {
            let pixel = CGPoint(x: point.x / view.width * layout.output.width,
                                y: (1 - point.y / view.height) * layout.output.height)
            return layout.annotationPoint(for: pixel.applying(transform.inverted()), followsZoom: followsZoom)
        }
    }
}
