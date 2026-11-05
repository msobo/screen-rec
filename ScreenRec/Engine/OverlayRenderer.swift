import CoreImage
import CoreText
import Foundation

/// Zeichnet Tastenkappen, Texte und Symbole als Bilder für den `RenderCompositor`.
///
/// Alle Maße hängen von der kurzen Bildseite ab, damit Vorschau und Export gleich aussehen.
/// Die Zeichenfläche hat wie Core Image ihren Ursprung unten links.
enum OverlayRenderer {
    /// Höhe, in der Tastenkappen vorab gezeichnet werden; reicht ohne Hochskalieren bis 4K.
    static let capImageHeight: CGFloat = 160
    /// Höhe einer Tastenkappe im Bild, relativ zur kurzen Seite.
    static let capHeight = 0.06
    /// Es bleiben nur die letzten Tasten stehen, damit eine Reihe nicht aus dem Bild läuft.
    static let maximumVisibleCaps = 24

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let plateColor = CGColor(red: 0.08, green: 0.07, blue: 0.06, alpha: 0.85)
    private static let shadowColor = CGColor(red: 0, green: 0, blue: 0, alpha: 0.55)

    // MARK: Tastenkappen

    /// Helle Taste mit dunkler Unterkante.
    static func capImage(_ label: String) -> CIImage? {
        let height = capImageHeight
        let line = textLine(label, size: height * (label.count > 1 ? 0.36 : 0.5),
                            color: CGColor(red: 0.12, green: 0.11, blue: 0.1, alpha: 1))
        let bounds = CTLineGetImageBounds(line, nil)
        let width = ceil(max(bounds.width + height * 0.5, height))
        let edge = height * 0.07

        guard let context = makeContext(width: Int(width), height: Int(height)) else { return nil }
        let radius = height * 0.2
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height - edge),
                               cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(CGColor(red: 0.5, green: 0.48, blue: 0.45, alpha: 1))
        context.fillPath()
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: edge, width: width, height: height - edge),
                               cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(CGColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1))
        context.fillPath()
        context.textPosition = CGPoint(x: (width - bounds.width) / 2 - bounds.minX,
                                       y: edge + (height - edge - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
        return context.makeImage().map { CIImage(cgImage: $0) }
    }

    /// Reihe aus Kappen, unten mittig im Bild. Passt sie nicht in die Breite, entfallen die ältesten.
    static func capRow(_ caps: [String], images: [String: CIImage], layout: SceneLayout) -> CIImage? {
        let height = min(layout.output.width, layout.output.height) * capHeight
        let gap = height * 0.14
        let scale = height / capImageHeight
        var row: [(image: CIImage, width: CGFloat)] = []
        var total: CGFloat = 0
        for cap in caps.suffix(maximumVisibleCaps).reversed() {
            guard let image = images[cap] else { continue }
            let width = image.extent.width * scale
            guard total + width <= layout.output.width * 0.9 else { break }
            row.insert((image, width), at: 0)
            total += width + gap
        }
        guard !row.isEmpty else { return nil }

        var x = (layout.output.width - (total - gap)) / 2
        var result = CIImage.empty()
        for cap in row {
            result = cap.image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: x, y: layout.output.height * 0.07)))
                .composited(over: result)
            x += cap.width + gap
        }
        return result
    }

    // MARK: Texte und Symbole

    /// Text oder Symbol an seiner Stelle im Ausgabebild.
    static func image(for annotation: Annotation, layout: SceneLayout) -> CIImage? {
        switch annotation.content {
        case .keys: nil
        case .text(let note): textImage(note, layout: layout)
        case .shape(let mark): shapeImage(mark, layout: layout)
        }
    }

    private static func textImage(_ note: TextNote, layout: SceneLayout) -> CIImage? {
        guard !note.text.isEmpty else { return nil }
        let shortSide = min(layout.output.width, layout.output.height)
        let fontSize = shortSide * note.size.scale
        let padding = fontSize * 0.6
        let string = attributedString(note.text, size: fontSize, color: cgColor(note.color.rgb))
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let limit = CGSize(width: layout.output.width * 0.8, height: layout.output.height * 0.8)
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil, limit, nil)
        let width = ceil(textSize.width) + padding * 2, height = ceil(textSize.height) + padding * 2

        guard let context = makeContext(width: Int(width), height: Int(height)) else { return nil }
        let radius = fontSize * 0.4
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: height),
                               cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(plateColor)
        context.fillPath()
        // Etwas Luft, damit Rundungsfehler keine letzte Zeile abschneiden.
        let frameRect = CGRect(x: padding, y: padding, width: ceil(textSize.width) + 1, height: ceil(textSize.height) + 1)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: frameRect, transform: nil), nil), context)
        guard let cgImage = context.makeImage() else { return nil }

        let center = layout.point(for: note.position, followsZoom: note.followsZoom)
        let x = min(max(center.x - width / 2, 0), max(layout.output.width - width, 0))
        let y = min(max(center.y - height / 2, 0), max(layout.output.height - height, 0))
        return CIImage(cgImage: cgImage).transformed(by: CGAffineTransform(translationX: x, y: y))
    }

    private static func shapeImage(_ mark: ShapeMark, layout: SceneLayout) -> CIImage? {
        let shortSide = min(layout.output.width, layout.output.height)
        let lineWidth = shortSide * 0.008
        let start = layout.point(for: mark.start, followsZoom: mark.followsZoom)
        let end = layout.point(for: mark.end, followsZoom: mark.followsZoom)
        let badgeRadius = shortSide * 0.04
        let box = mark.kind == .badge
            ? CGRect(x: start.x - badgeRadius, y: start.y - badgeRadius, width: badgeRadius * 2, height: badgeRadius * 2)
            : CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        // Platz für Pfeilspitze, Strichbreite und Schatten.
        let bounds = box.insetBy(dx: -lineWidth * 6, dy: -lineWidth * 6).integral
        guard let context = makeContext(width: Int(bounds.width), height: Int(bounds.height)) else { return nil }
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.setShadow(offset: CGSize(width: 0, height: -lineWidth * 0.4), blur: lineWidth * 1.5, color: shadowColor)
        context.beginTransparencyLayer(auxiliaryInfo: nil)

        let color = cgColor(mark.color.rgb)
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        switch mark.kind {
        case .arrow: drawArrow(from: start, to: end, lineWidth: lineWidth, in: context)
        case .ellipse: context.strokeEllipse(in: box)
        case .rectangle:
            let radius = min(lineWidth * 1.5, min(box.width, box.height) / 2)
            context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.strokePath()
        case .badge: drawBadge(mark, in: box, context: context)
        }
        context.endTransparencyLayer()
        return context.makeImage().map {
            CIImage(cgImage: $0).transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
        }
    }

    private static func drawArrow(from start: CGPoint, to end: CGPoint, lineWidth: CGFloat, in context: CGContext) {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return }
        let unit = CGPoint(x: dx / length, y: dy / length)
        let headLength = min(lineWidth * 4.5, length), headWidth = headLength * 0.75
        let base = CGPoint(x: end.x - unit.x * headLength, y: end.y - unit.y * headLength)

        context.move(to: start)
        context.addLine(to: base)
        context.strokePath()
        context.move(to: end)
        context.addLine(to: CGPoint(x: base.x - unit.y * headWidth, y: base.y + unit.x * headWidth))
        context.addLine(to: CGPoint(x: base.x + unit.y * headWidth, y: base.y - unit.x * headWidth))
        context.closePath()
        context.fillPath()
    }

    private static func drawBadge(_ mark: ShapeMark, in box: CGRect, context: CGContext) {
        context.fillEllipse(in: box)
        let isLight = mark.color == .white || mark.color == .yellow
        let textColor = isLight ? CGColor(red: 0.08, green: 0.07, blue: 0.06, alpha: 1)
            : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let line = textLine(String(mark.number), size: box.height * 0.56, color: textColor)
        let bounds = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(x: box.midX - bounds.width / 2 - bounds.minX,
                                       y: box.midY - bounds.height / 2 - bounds.minY)
        CTLineDraw(line, context)
    }

    // MARK: Hilfen

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func cgColor(_ color: RGBColor) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [color.red, color.green, color.blue, 1])
            ?? CGColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    private static func attributedString(_ string: String, size: CGFloat, color: CGColor) -> NSAttributedString {
        let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, size, nil)
            ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        return NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
    }

    private static func textLine(_ string: String, size: CGFloat, color: CGColor) -> CTLine {
        CTLineCreateWithAttributedString(attributedString(string, size: size, color: color))
    }
}
