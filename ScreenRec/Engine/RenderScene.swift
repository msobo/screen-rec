import CoreImage
import Foundation

/// Alles, was der `RenderCompositor` über die Bildebenen hinaus braucht: Gestaltung,
/// Cursor-Pfad, Zoom-Kamera und vorbereitete Bilder.
///
/// `@unchecked Sendable`: Nach `init` unveränderlich; `CIImage` ist selbst unveränderlich
/// und wird von Core Image threadsicher gelesen.
final class RenderScene: @unchecked Sendable {
    struct CursorImage {
        var image: CIImage
        /// Größe und Hotspot in Punkten, Hotspot von oben links.
        var size: CGSize
        var hotSpot: CGPoint
    }

    /// So lange bleibt ein Klick-Ring sichtbar.
    static let clickDuration = 0.45
    /// So lange blenden Einblendungen ein und aus.
    static let overlayFade = 0.15

    let look: Look
    /// Pixelgröße der Bildschirmaufnahme, nach der sich die Lage im Bild richtet.
    let sourceSize: CGSize
    let backgroundImage: CIImage?
    /// Cursor und Klicks der Aufnahme, falls aufgezeichnet.
    let cursor: CursorPath?
    let cursorImages: [String: CursorImage]
    let zoom: ZoomPath
    /// Sichtbare Einblendungen, nach Start sortiert.
    let placements: [AnnotationPlacement]
    let capImages: [String: CIImage]

    init(look: Look, sourceSize: CGSize, backgroundImage: CIImage? = nil, cursor: CursorPath? = nil,
         cursorImages: [String: CursorImage] = [:], zoom: ZoomPath = .empty,
         placements: [AnnotationPlacement] = []) {
        self.look = look
        self.sourceSize = sourceSize
        self.backgroundImage = backgroundImage
        self.cursor = cursor
        self.cursorImages = cursorImages
        self.zoom = zoom
        let visible = placements.filter { placement in
            guard let group = placement.annotation.keys else { return true }
            return look.showsKeystrokes && !group.isHidden
        }
        self.placements = visible
        let caps = Set(visible.compactMap(\.annotation.keys).flatMap(\.keys).flatMap(\.caps))
        capImages = Dictionary(uniqueKeysWithValues: caps.compactMap { cap in
            OverlayRenderer.capImage(cap).map { (cap, $0) }
        })
    }

    /// Ohne Rahmen, Cursor, Zoom und Einblendungen; dann darf der Compositor Bilder durchreichen.
    var isNeutral: Bool {
        !look.hasFrame && !drawsCursor && zoom.isEmpty && placements.isEmpty
    }

    var drawsCursor: Bool { look.cursor.isVisible && cursor?.isEmpty == false }

    static func cursorImages(from data: CursorData) -> [String: CursorImage] {
        data.cursors.compactMapValues { cursor in
            guard let image = CIImage(data: cursor.png), cursor.width > 0, cursor.height > 0 else { return nil }
            return CursorImage(image: image, size: CGSize(width: cursor.width, height: cursor.height),
                               hotSpot: CGPoint(x: cursor.hotSpotX, y: cursor.hotSpotY))
        }
    }
}
