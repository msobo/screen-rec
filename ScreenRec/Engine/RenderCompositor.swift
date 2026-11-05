import AVFoundation
import CoreImage
import os

/// Anweisung für einen Abschnitt der Video-Composition: welche Spuren mit welcher Deckkraft
/// übereinandergelegt werden. Überblendungen und Fades sind nur Deckkraftverläufe.
final class LayerInstruction: NSObject, AVVideoCompositionInstructionProtocol, Sendable {
    struct Layer: Sendable {
        var trackID: CMPersistentTrackID
        var opacity: GainEnvelope
        /// Bildschirm (mit Cursor und Zoom) oder Kamera (als Einblendung in der Ecke).
        var role: MediaAsset.Role
        /// Für den Cursor: Quellzeit = `sourceStart` + (Timeline-Zeit − `timelineStart`) · `speed`.
        var sourceStart: Double
        var timelineStart: Double
        var speed: Double

        func sourceTime(at time: Double) -> Double {
            sourceStart + (time - timelineStart) * speed
        }
    }

    let timeRange: CMTimeRange
    /// Von unten nach oben.
    let layers: [Layer]
    let scene: RenderScene

    let enablePostProcessing = false
    let containsTweening = true
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    var requiredSourceTrackIDs: [NSValue]? { layers.map { NSNumber(value: $0.trackID) } }

    init(timeRange: CMTimeRange, layers: [Layer], scene: RenderScene) {
        self.timeRange = timeRange
        self.layers = layers
        self.scene = scene
    }
}

/// Rendert ein Ausgabebild mit Core Image: Hintergrund mit Abstand, abgerundeten Ecken und
/// Schatten, darauf die Bildebenen der `LayerInstruction` samt Überblendungen, den neu
/// gezeichneten Cursor, die Zoom-Kamera, die Kamera-Einblendung und Tastenkürzel.
///
/// Ohne Gestaltung (`RenderScene.isNeutral`) sieht das Bild aus wie früher: Ebenen auf Schwarz,
/// ein einzelner, voll sichtbarer Clip in Ausgabegröße wird unverändert durchgereicht.
final class RenderCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    enum CompositorError: Error {
        case unexpectedInstruction
        case noOutputBuffer
    }

    // `@unchecked Sendable`: AVFoundation ruft den Compositor auf eigenen Queues auf, auch parallel.
    // Zustand: der threadsichere `CIContext` und der Hintergrund-Cache hinter einem Lock.
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    private struct BackdropKey: Equatable {
        var scene: ObjectIdentifier
        var size: CGSize
    }

    /// Hintergrund samt Schatten ändert sich nicht über die Zeit und wird einmal je Größe gerendert.
    private let backdrop = OSAllocatedUnfairLock<(key: BackdropKey, image: CIImage)?>(initialState: nil)
    private let overlays = OSAllocatedUnfairLock<(key: BackdropKey, images: [Annotation.ID: CIImage])?>(initialState: nil)

    private static let pixelBufferAttributes: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.pixelBufferAttributes }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.pixelBufferAttributes }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? LayerInstruction else {
            request.finish(with: CompositorError.unexpectedInstruction)
            return
        }
        let size = request.renderContext.size
        let time = RationalTime(request.compositionTime)
        let scene = instruction.scene

        // Häufigster Fall ohne Gestaltung: ein Clip, voll sichtbar, in Ausgabegröße. Dann ohne Rendern durchreichen.
        if scene.isNeutral, instruction.layers.count == 1, let layer = instruction.layers.first, layer.role != .camera,
           layer.opacity.value(at: time) >= 1,
           let source = request.sourceFrame(byTrackID: layer.trackID),
           CVPixelBufferGetWidth(source) == Int(size.width), CVPixelBufferGetHeight(source) == Int(size.height) {
            request.finish(withComposedVideoFrame: source)
            return
        }

        guard let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: CompositorError.noOutputBuffer)
            return
        }
        let bounds = CGRect(origin: .zero, size: size)
        let image = compose(instruction, at: time, size: size) { request.sourceFrame(byTrackID: $0) }
        context.render(image.cropped(to: bounds), to: output, bounds: bounds, colorSpace: colorSpace)
        request.finish(withComposedVideoFrame: output)
    }

    // MARK: Bild zusammensetzen

    private func compose(_ instruction: LayerInstruction, at time: RationalTime, size: CGSize,
                         frame: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage {
        let scene = instruction.scene
        let t = time.seconds
        let layout = SceneLayout(output: size, sourceSize: scene.sourceSize, look: scene.look)
        let bounds = CGRect(origin: .zero, size: size)

        // Bildschirm-Ebenen im Bildbereich, auf Schwarz.
        var content = CIImage(color: .black).cropped(to: layout.contentRect)
        var topScreen: LayerInstruction.Layer?
        for layer in instruction.layers where layer.role != .camera {
            let opacity = layer.opacity.value(at: time)
            guard opacity > 0, let source = frame(layer.trackID) else { continue }
            content = Self.withOpacity(Self.fit(CIImage(cvPixelBuffer: source), into: layout.contentRect), opacity)
                .composited(over: content)
            topScreen = layer
        }
        if let topScreen, let cursor = scene.cursor, scene.drawsCursor {
            content = drawCursor(cursor, scene: scene, at: topScreen.sourceTime(at: t), layout: layout, over: content)
        }
        content = content.cropped(to: layout.contentRect)

        var image: CIImage
        if scene.look.hasFrame {
            if layout.cornerRadius > 0 {
                content = content.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: Self.roundedRect(layout.contentRect, radius: layout.cornerRadius),
                ])
            }
            image = content.composited(over: backdropImage(for: scene, layout: layout))
        } else {
            image = content.composited(over: CIImage(color: .black).cropped(to: bounds))
        }

        image = drawOverlays(followingZoom: true, scene: scene, at: t, layout: layout, over: image)

        let zoom = scene.zoom.state(at: t)
        if zoom.scale > 1 {
            image = image.transformed(by: layout.zoomTransform(zoom)).cropped(to: bounds)
        }

        // Über dem Zoom: Kamera, Tasten und feste Einblendungen bleiben, wo sie sind.
        for layer in instruction.layers where layer.role == .camera {
            let opacity = layer.opacity.value(at: time)
            guard opacity > 0, let source = frame(layer.trackID) else { continue }
            image = drawCamera(CIImage(cvPixelBuffer: source), opacity: opacity, style: scene.look.camera,
                               layout: layout, over: image)
        }
        image = drawOverlays(followingZoom: false, scene: scene, at: t, layout: layout, over: image)
        return drawKeys(scene: scene, at: t, layout: layout, over: image)
    }

    /// Hintergrund und Schatten unter dem Bildbereich, gecacht je Szene und Größe.
    private func backdropImage(for scene: RenderScene, layout: SceneLayout) -> CIImage {
        let key = BackdropKey(scene: ObjectIdentifier(scene), size: layout.output)
        if let cached = backdrop.withLock({ $0 }), cached.key == key { return cached.image }

        let bounds = CGRect(origin: .zero, size: layout.output)
        var image = Self.background(scene.look.background, image: scene.backgroundImage, bounds: bounds)
        if scene.look.shadow > 0 {
            let shortSide = min(layout.output.width, layout.output.height)
            let strength = min(max(scene.look.shadow, 0), 1)
            let shadow = Self.roundedRect(layout.contentRect, radius: layout.cornerRadius)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.75 * strength),
                ])
                .applyingGaussianBlur(sigma: shortSide * 0.02 * (0.5 + strength))
                .transformed(by: CGAffineTransform(translationX: 0, y: -shortSide * 0.012))
            image = shadow.composited(over: image)
        }
        // Einmal rendern, damit Verlauf und Weichzeichner nicht in jedem Bild neu berechnet werden.
        if let cgImage = context.createCGImage(image.cropped(to: bounds), from: bounds, format: .RGBA8,
                                               colorSpace: colorSpace) {
            image = CIImage(cgImage: cgImage)
        }
        let rendered = image
        backdrop.withLock { $0 = (key, rendered) }
        return rendered
    }

    private static func background(_ background: Background, image: CIImage?, bounds: CGRect) -> CIImage {
        switch background.kind {
        case .none:
            return CIImage(color: .black).cropped(to: bounds)
        case .color:
            return CIImage(color: ciColor(background.color)).cropped(to: bounds)
        case .gradient:
            return CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: bounds.minX, y: bounds.maxY),
                "inputPoint1": CIVector(x: bounds.maxX, y: bounds.minY),
                "inputColor0": ciColor(background.gradient.from),
                "inputColor1": ciColor(background.gradient.to),
            ])?.outputImage?.cropped(to: bounds) ?? CIImage(color: .black).cropped(to: bounds)
        case .image:
            guard let image else { return CIImage(color: .black).cropped(to: bounds) }
            return fill(image, into: bounds)
        }
    }

    // MARK: Cursor und Einblendungen

    private func drawCursor(_ cursor: CursorPath, scene: RenderScene, at sourceTime: Double, layout: SceneLayout,
                            over content: CIImage) -> CIImage {
        guard let position = cursor.position(at: sourceTime),
              (-0.02...1.02).contains(position.x), (-0.02...1.02).contains(position.y)
        else { return content }
        var image = content
        let point = layout.point(forNormalized: position)
        // Pixel der Ausgabe pro Punkt auf dem aufgenommenen Bildschirm.
        let pixelsPerPoint = cursor.contentPointSize.width > 0 ? layout.contentRect.width / cursor.contentPointSize.width : 1
        let style = scene.look.cursor
        let scale = pixelsPerPoint * min(max(style.scale, CursorStyle.scaleRange.lowerBound), CursorStyle.scaleRange.upperBound)

        if style.highlightsClicks {
            for (click, age) in cursor.recentClicks(at: sourceTime, window: RenderScene.clickDuration) {
                let progress = age / RenderScene.clickDuration
                let radius = scale * (10 + 16 * progress)
                image = Self.ring(at: layout.point(forNormalized: click.position), radius: radius,
                                  width: max(scale * 3, 1.5), alpha: 0.8 * (1 - progress))
                    .composited(over: image)
            }
        }

        guard let id = cursor.imageID(at: sourceTime), let cursorImage = scene.cursorImages[id] else { return image }
        let extent = cursorImage.image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let width = cursorImage.size.width * scale, height = cursorImage.size.height * scale
        // Hotspot von oben links gemessen, Core Image zählt von unten.
        let origin = CGPoint(x: point.x - cursorImage.hotSpot.x * scale,
                             y: point.y - (cursorImage.size.height - cursorImage.hotSpot.y) * scale)
        let placed = cursorImage.image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
                .concatenating(CGAffineTransform(scaleX: width / extent.width, y: height / extent.height))
                .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y)))
        let shadow = placed
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.35),
            ])
            .applyingGaussianBlur(sigma: max(scale * 1.5, 1))
            .transformed(by: CGAffineTransform(translationX: 0, y: -scale * 1.5))
        return placed.composited(over: shadow.composited(over: image))
    }

    private func drawCamera(_ frame: CIImage, opacity: Double, style: CameraStyle, layout: SceneLayout,
                            over image: CIImage) -> CIImage {
        let rect = layout.cameraRect(style)
        let radius = style.shape == .circle ? rect.width / 2 : rect.width * 0.16
        let mask = Self.roundedRect(rect, radius: radius)
        let camera = Self.fill(frame, into: rect).applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask,
        ])
        let shadow = mask
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5),
            ])
            .applyingGaussianBlur(sigma: rect.width * 0.04)
            .transformed(by: CGAffineTransform(translationX: 0, y: -rect.width * 0.02))
        return Self.withOpacity(camera.composited(over: shadow), opacity).composited(over: image)
    }

    // MARK: Einblendungen

    /// Texte und Symbole, die entweder mit dem Bildinhalt zoomen oder fest im Bild stehen.
    private func drawOverlays(followingZoom: Bool, scene: RenderScene, at t: Double, layout: SceneLayout,
                              over image: CIImage) -> CIImage {
        var result = image
        for placement in scene.placements where placement.annotation.keys == nil
            && placement.annotation.followsZoom == followingZoom {
            let opacity = Self.overlayOpacity(placement, at: t)
            guard opacity > 0, let overlay = overlayImage(placement.annotation, scene: scene, layout: layout)
            else { continue }
            result = Self.withOpacity(overlay, opacity).composited(over: result)
        }
        return result
    }

    /// Die jüngste Tastengruppe; ihre Tasten erscheinen im Takt des Tippens.
    private func drawKeys(scene: RenderScene, at t: Double, layout: SceneLayout, over image: CIImage) -> CIImage {
        guard let placement = scene.placements.last(where: {
            $0.annotation.keys != nil && $0.start.seconds <= t && t < $0.end.seconds
        }), let group = placement.annotation.keys else { return image }
        let elapsed = (t - placement.start.seconds) * placement.speed
        let caps = group.keys.filter { $0.offset <= elapsed }.flatMap(\.caps)
        guard let row = OverlayRenderer.capRow(caps, images: scene.capImages, layout: layout) else { return image }
        return Self.withOpacity(row, Self.overlayOpacity(placement, at: t)).composited(over: image)
    }

    /// Texte und Symbole hängen von der Ausgabegröße ab und werden je Szene und Größe einmal gezeichnet.
    private func overlayImage(_ annotation: Annotation, scene: RenderScene, layout: SceneLayout) -> CIImage? {
        let key = BackdropKey(scene: ObjectIdentifier(scene), size: layout.output)
        if let cached = overlays.withLock({ $0?.key == key ? $0?.images[annotation.id] : nil }) { return cached }
        guard let image = OverlayRenderer.image(for: annotation, layout: layout) else { return nil }
        overlays.withLock { cache in
            if cache?.key != key { cache = (key, [:]) }
            cache?.images[annotation.id] = image
        }
        return image
    }

    private static func overlayOpacity(_ placement: AnnotationPlacement, at t: Double) -> Double {
        let start = placement.start.seconds, end = placement.end.seconds
        guard start <= t, t < end else { return 0 }
        // Kurze Tastendrücke sollen trotzdem voll sichtbar werden.
        let fade = min(RenderScene.overlayFade, (end - start) / 4)
        return fade > 0 ? min(min((t - start) / fade, (end - t) / fade), 1) : 1
    }

    // MARK: Hilfen

    private static func ciColor(_ color: RGBColor) -> CIColor {
        CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            ?? CIColor(red: color.red, green: color.green, blue: color.blue)
    }

    private static func withOpacity(_ image: CIImage, _ opacity: Double) -> CIImage {
        guard opacity < 1 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
    }

    private static func roundedRect(_ rect: CGRect, radius: CGFloat) -> CIImage {
        guard radius > 0 else { return CIImage(color: .white).cropped(to: rect) }
        return CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
            "inputExtent": CIVector(cgRect: rect),
            "inputRadius": radius,
            "inputColor": CIColor.white,
        ])?.outputImage ?? CIImage(color: .white).cropped(to: rect)
    }

    /// Ring aus zwei Kreisen: außen weiß, innen ausgestanzt.
    private static func ring(at center: CGPoint, radius: CGFloat, width: CGFloat, alpha: Double) -> CIImage {
        func disc(_ r: CGFloat) -> CIImage {
            CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: center.x, y: center.y),
                "inputRadius0": max(r - 1, 0),
                "inputRadius1": r,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: alpha),
                "inputColor1": CIColor(red: 1, green: 1, blue: 1, alpha: 0),
            ])?.outputImage?.cropped(to: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                ?? CIImage.empty()
        }
        return disc(radius).applyingFilter("CISourceOutCompositing", parameters: [
            kCIInputBackgroundImageKey: disc(max(radius - width, 0)),
        ])
    }

    /// Seitenverhältnis erhalten, ganz in `rect` einpassen.
    private static func fit(_ image: CIImage, into rect: CGRect) -> CIImage {
        place(image, into: rect, scale: min(rect.width / image.extent.width, rect.height / image.extent.height))
    }

    /// Seitenverhältnis erhalten, `rect` ganz füllen und überstehende Ränder abschneiden.
    private static func fill(_ image: CIImage, into rect: CGRect) -> CIImage {
        place(image, into: rect, scale: max(rect.width / image.extent.width, rect.height / image.extent.height))
            .cropped(to: rect)
    }

    private static func place(_ image: CIImage, into rect: CGRect, scale: CGFloat) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let x = rect.midX - extent.width * scale / 2, y = rect.midY - extent.height * scale / 2
        return image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: x, y: y)))
    }
}
