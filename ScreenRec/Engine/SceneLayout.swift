import CoreGraphics

/// Geometrie eines Ausgabebilds nach `Look`: wo das Bild sitzt, wie die Zoom-Kamera es
/// verschiebt und wo die Kamera-Einblendung liegt.
///
/// Koordinaten wie in Core Image: in Pixeln der Ausgabe, Ursprung unten links.
/// Relative Positionen (Cursor, Zoom-Blickpunkt) haben dagegen den Ursprung oben links.
struct SceneLayout: Equatable, Sendable {
    let output: CGSize
    /// Bereich, in dem die Aufnahme liegt.
    let contentRect: CGRect
    let cornerRadius: CGFloat

    init(output: CGSize, sourceSize: CGSize, look: Look) {
        self.output = output
        let shortSide = min(output.width, output.height)
        let inset = look.hasFrame ? shortSide * min(max(look.padding, Look.paddingRange.lowerBound), Look.paddingRange.upperBound) : 0
        let available = CGRect(origin: .zero, size: output).insetBy(dx: inset, dy: inset)
        contentRect = Self.aspectFit(sourceSize, in: available)
        cornerRadius = look.hasFrame
            ? min(contentRect.width, contentRect.height) * min(max(look.cornerRadius, 0), Look.cornerRadiusRange.upperBound)
            : 0
    }

    /// Relativer Punkt im Bild (oben links) → Ausgabepixel (unten links).
    func point(forNormalized point: CGPoint) -> CGPoint {
        CGPoint(x: contentRect.minX + point.x * contentRect.width, y: contentRect.maxY - point.y * contentRect.height)
    }

    /// Punkt einer Einblendung → Ausgabepixel. Was mitzoomt, bezieht sich auf die Aufnahme und
    /// zeigt so auch nach einer Änderung des Rahmens auf dieselbe Stelle, alles andere auf die Ausgabe.
    func point(for point: AnnotationPoint, followsZoom: Bool) -> CGPoint {
        if followsZoom { return self.point(forNormalized: CGPoint(x: point.x, y: point.y)) }
        return CGPoint(x: point.x * output.width, y: (1 - point.y) * output.height)
    }

    /// Umkehrung von `point(for:followsZoom:)`.
    func annotationPoint(for point: CGPoint, followsZoom: Bool) -> AnnotationPoint {
        let rect = followsZoom ? contentRect : CGRect(origin: .zero, size: output)
        guard rect.width > 0, rect.height > 0 else { return AnnotationPoint(x: 0.5, y: 0.5) }
        return AnnotationPoint(x: (point.x - rect.minX) / rect.width, y: (rect.maxY - point.y) / rect.height)
    }

    /// Bildet die Ausgabe auf den vergrößerten Ausschnitt um `focus` ab.
    ///
    /// Passt der Ausschnitt in die Aufnahme, bleibt er ganz darin, damit am Rand kein Hintergrund
    /// hereinragt; ist er größer, enthält er die ganze Aufnahme. Beide Grenzen fallen genau dann
    /// zusammen, wenn der Ausschnitt so groß ist wie die Aufnahme: Beim Einzoomen springt nichts.
    func zoomTransform(_ state: ZoomPath.State) -> CGAffineTransform {
        guard state.scale > 1 else { return .identity }
        let scale = state.scale
        let focus = point(forNormalized: state.focus)
        let halfWidth = output.width / scale / 2, halfHeight = output.height / scale / 2
        func clamp(_ value: CGFloat, half: CGFloat, content: (min: CGFloat, max: CGFloat), length: CGFloat) -> CGFloat {
            let a = content.min + half, b = content.max - half
            let lower = max(min(a, b), half), upper = min(max(a, b), length - half)
            return min(max(value, lower), max(upper, lower))
        }
        let center = CGPoint(
            x: clamp(focus.x, half: halfWidth, content: (contentRect.minX, contentRect.maxX), length: output.width),
            y: clamp(focus.y, half: halfHeight, content: (contentRect.minY, contentRect.maxY), length: output.height))
        return CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: output.width / 2, y: output.height / 2))
    }

    /// Quadrat der Kamera-Einblendung in der gewählten Ecke.
    func cameraRect(_ style: CameraStyle) -> CGRect {
        let shortSide = min(output.width, output.height)
        let size = shortSide * min(max(style.size, CameraStyle.sizeRange.lowerBound), CameraStyle.sizeRange.upperBound)
        let margin = shortSide * 0.04
        let x = style.corner == .topLeft || style.corner == .bottomLeft ? margin : output.width - margin - size
        let y = style.corner == .bottomLeft || style.corner == .bottomRight ? margin : output.height - margin - size
        return CGRect(x: x, y: y, width: size, height: size)
    }

    /// Ausgabegröße für das gewählte Seitenverhältnis. Die lange Seite der Aufnahme bleibt erhalten.
    static func renderSize(source: CGSize, aspect: Look.Aspect) -> CGSize {
        guard let ratio = aspect.ratio else { return source }
        let long = max(source.width, source.height)
        let size = ratio >= 1 ? CGSize(width: long, height: long / ratio) : CGSize(width: long * ratio, height: long)
        return CGSize(width: max(2, (size.width / 2).rounded() * 2), height: max(2, (size.height / 2).rounded() * 2))
    }

    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale, height = size.height * scale
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}
