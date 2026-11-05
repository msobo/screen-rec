import AVFoundation
import ImageIO
import Testing
@testable import ScreenRec

/// Rendert echte Bilder über den `RenderCompositor` (2 s Testaufnahme, 320 × 240).
@MainActor
struct RenderTests {
    private func frame(at seconds: Double, package: URL, project: Project) async throws -> CGImage {
        let built = try await CompositionBuilder(packageURL: package).build(project)
        // Die Composition wird danach nur noch vom Bildgenerator gelesen.
        nonisolated(unsafe) let composition = built.composition, videoComposition = built.videoComposition
        return try await Self.image(of: composition, videoComposition: videoComposition, at: seconds)
    }

    private nonisolated static func image(of composition: AVComposition, videoComposition: AVVideoComposition?,
                                          at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: composition)
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    @Test func standardLookDrawsBackgroundAroundTheFrame() async throws {
        let package = try await TestMedia.makeRecordingPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        var project = try await ProjectFactory.makeProject(forRecordingAt: package)
        #expect(project.look == .standard || project.look.background.kind == .gradient)
        project.look.background.kind = .color
        project.look.background.color = RGBColor(red: 1, green: 0, blue: 0)
        project.look.shadow = 0

        let image = try await frame(at: 1, package: package, project: project)
        #expect(image.width == 320 && image.height == 240)
        // Ecke: Hintergrund; Mitte: die Aufnahme.
        let corner = try TestMedia.pixel(image, x: 2, y: 2)
        #expect(corner.red > 0.9 && corner.green < 0.1 && corner.blue < 0.1)
        let center = try TestMedia.pixel(image, x: 160, y: 120)
        #expect(center.red < 0.5)
    }

    @Test func drawsRecordedCursor() async throws {
        let package = try await TestMedia.makeRecordingPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        var cursor = CursorData()
        cursor.cursors = ["square": try TestMedia.squareCursor()]
        // Mitte des aufgenommenen Bereichs (160 × 120 Punkte ab 0,0).
        cursor.samples = [.init(t: 0, x: 80, y: 60, cursor: "square")]
        try TestMedia.addCursorData(cursor, to: package)

        var project = try await ProjectFactory.makeProject(forRecordingAt: package)
        project.look = .neutral
        project.look.cursor.isVisible = true
        project.look.cursor.scale = 2

        let image = try await frame(at: 1, package: package, project: project)
        // 16 Punkte × 2 Pixel pro Punkt × Größe 2 = 64 Pixel ab dem Hotspot in der Bildmitte.
        let inside = try TestMedia.pixel(image, x: 190, y: 150)
        #expect(inside.red > 0.9 && inside.green > 0.9 && inside.blue > 0.9)
        let outside = try TestMedia.pixel(image, x: 100, y: 60)
        #expect(outside.red < 0.5)
    }

    @Test func zoomEnlargesTheCursorArea() async throws {
        let package = try await TestMedia.makeRecordingPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        var cursor = CursorData()
        cursor.cursors = ["square": try TestMedia.squareCursor(points: 8)]
        cursor.samples = [.init(t: 0, x: 80, y: 60, cursor: "square")]
        try TestMedia.addCursorData(cursor, to: package)

        var project = try await ProjectFactory.makeProject(forRecordingAt: package)
        project.look = .neutral
        project.look.cursor.isVisible = true
        project.look.cursor.scale = 1
        // Ohne Zoom: 8 Punkte × 2 = 16 Pixel; bei 2× Zoom auf den Cursor 32 Pixel.
        let plain = try await frame(at: 1, package: package, project: project)
        #expect(try TestMedia.pixel(plain, x: 185, y: 145).red < 0.5)
        project.timeline.zooms = [ZoomRegion(start: .zero, duration: RationalTime(seconds: 2), scale: 2)]
        let zoomed = try await frame(at: 1, package: package, project: project)
        let inside = try TestMedia.pixel(zoomed, x: 185, y: 145)
        #expect(inside.red > 0.9 && inside.green > 0.9)
    }

    private func neutralProject(package: URL) async throws -> Project {
        var project = try await ProjectFactory.makeProject(forRecordingAt: package)
        project.look = .neutral
        return project
    }

    private func annotation(_ content: Annotation.Content, anchor: Double = 0.5) -> Annotation {
        Annotation(anchor: RationalTime(seconds: anchor), duration: RationalTime(seconds: 1), content: content)
    }

    /// Die Testaufnahme ist grün, eine rote Plakette hebt sich davon ab.
    private func isRed(_ pixel: (red: Double, green: Double, blue: Double)) -> Bool {
        pixel.red > 0.7 && pixel.green < 0.4
    }

    @Test func drawsShapeWithNeutralLook() async throws {
        let package = try await TestMedia.makeRecordingPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        var project = try await neutralProject(package: package)
        var mark = ShapeMark(kind: .badge, color: .red)
        mark.start = AnnotationPoint(x: 0.25, y: 0.75)
        // Die Plakette ist voll gefüllt, die Zahl steht nur in der Mitte.
        mark.number = 1
        project.timeline.annotations = [annotation(.shape(mark))]

        let during = try await frame(at: 1, package: package, project: project)
        let edge = try TestMedia.pixel(during, x: 80 - 7, y: 180 - 5)
        #expect(isRed(edge))
        let after = try await frame(at: 1.8, package: package, project: project)
        #expect(!isRed(try TestMedia.pixel(after, x: 80 - 7, y: 180 - 5)))
    }

    @Test func shapeZoomsWithTheContentButTextStays() async throws {
        let package = try await TestMedia.makeRecordingPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        var project = try await neutralProject(package: package)
        var mark = ShapeMark(kind: .badge, color: .red)
        mark.start = AnnotationPoint(x: 0.25, y: 0.25)
        project.timeline.annotations = [annotation(.shape(mark))]
        project.timeline.zooms = [ZoomRegion(start: .zero, duration: RationalTime(seconds: 2), scale: 2, focus: .point,
                                             pointX: 0.25, pointY: 0.25)]

        // Bei 2× um denselben Punkt rückt die Plakette in die Bildmitte.
        let zoomed = try await frame(at: 1, package: package, project: project)
        #expect(isRed(try TestMedia.pixel(zoomed, x: 160 - 14, y: 120 - 10)))

        mark.followsZoom = false
        project.timeline.annotations = [annotation(.shape(mark))]
        let fixed = try await frame(at: 1, package: package, project: project)
        #expect(isRed(try TestMedia.pixel(fixed, x: 80 - 7, y: 60 - 5)))
        #expect(!isRed(try TestMedia.pixel(fixed, x: 160 - 14, y: 120 - 10)))
    }

    @Test func drawsTextPlateAndKeys() async throws {
        let package = try await TestMedia.makeRecordingPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        var project = try await neutralProject(package: package)
        let plain = try await frame(at: 1, package: package, project: project)

        project.timeline.annotations = [
            annotation(.text(TextNote(text: "Hinweis", position: AnnotationPoint(x: 0.5, y: 0.2)))),
            annotation(.keys(KeyGroup(keys: [.init(offset: 0, caps: ["⌘"]), .init(offset: 0, caps: ["S"])]))),
        ]
        project.look.showsKeystrokes = true
        let image = try await frame(at: 1, package: package, project: project)

        // Rand der Textplatte: dunkel, wo vorher die Aufnahme war.
        let plate = try TestMedia.pixel(image, x: 136, y: 48)
        let before = try TestMedia.pixel(plain, x: 136, y: 48)
        #expect(plate.red + plate.green + plate.blue < before.red + before.green + before.blue)
        // Tastenkappe unten mittig: hell.
        let cap = try TestMedia.pixel(image, x: 150, y: 240 - Int(240 * 0.07) - 6)
        #expect(cap.red > 0.8 && cap.green > 0.8 && cap.blue > 0.75)
    }

    @Test func hiddenKeysAndSwitchedOffKeysStayOutOfTheVideo() async throws {
        let package = try await TestMedia.makeRecordingPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        var project = try await neutralProject(package: package)
        let keys = KeyGroup(keys: [.init(offset: 0, caps: ["A"])], isHidden: true)
        project.look.showsKeystrokes = true
        project.timeline.annotations = [annotation(.keys(keys))]
        let built = try await CompositionBuilder(packageURL: package).build(project)
        #expect(built.scene.placements.isEmpty && built.scene.isNeutral)

        var visible = keys
        visible.isHidden = false
        project.timeline.annotations = [annotation(.keys(visible))]
        #expect(try await CompositionBuilder(packageURL: package).build(project).scene.placements.count == 1)
        project.look.showsKeystrokes = false
        #expect(try await CompositionBuilder(packageURL: package).build(project).scene.placements.isEmpty)
    }

    @Test func exportedFilesContainOverlays() async throws {
        let package = try await TestMedia.makeRecordingPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        var project = try await neutralProject(package: package)
        var mark = ShapeMark(kind: .badge, color: .red)
        mark.start = AnnotationPoint(x: 0.25, y: 0.75)
        project.timeline.annotations = [annotation(.shape(mark))]
        let built = try await CompositionBuilder(packageURL: package).build(project)

        // Video: Die Maße der Plakette wachsen mit der Exportgröße.
        var settings = ExportSettings()
        settings.frameRate = 30
        let format = ExportController.format(for: settings, built: built)
        let movie = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(format.fileExtension)")
        defer { try? FileManager.default.removeItem(at: movie) }
        try await Exporter(built, format: format, to: movie).run { _ in }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
        let center = (x: Int(Double(frame.width) * 0.25), y: Int(Double(frame.height) * 0.75))
        let offset = frame.height / 40
        #expect(isRed(try TestMedia.pixel(frame, x: center.x - offset, y: center.y - offset)))

        // GIF
        settings.preset = .gif
        settings.gifSize = 160
        settings.gifFrameRate = 10
        let gifFormat = ExportController.format(for: settings, built: built)
        let gif = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: gif) }
        try await GIFExporter(built, format: gifFormat, to: gif).run { _ in }
        let source = try #require(CGImageSourceCreateWithURL(gif as CFURL, nil))
        let gifFrame = try #require(CGImageSourceCreateImageAtIndex(source, 10, nil))
        #expect(isRed(try TestMedia.pixel(gifFrame, x: 40 - 3, y: 90 - 2)))
    }

    @Test func overlaysCameraInCorner() async throws {
        let package = try await TestMedia.makeRecordingPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        var project = try await ProjectFactory.makeProject(forRecordingAt: package)
        project.look = .neutral
        project.look.background.kind = .color
        project.look.background.color = RGBColor(red: 1, green: 0, blue: 0)
        project.look.padding = 0.25
        project.look.camera.corner = .bottomRight
        project.look.camera.shape = .roundedRectangle
        // Als Kamera dient hier dieselbe Testdatei wie für den Bildschirm.
        let screen = try #require(project.assets.first { $0.role == .screen })
        var camera = screen
        camera.id = UUID()
        camera.role = .camera
        project.assets.append(camera)
        let clip = Clip(assetID: camera.id, sourceRange: RationalTimeRange(start: .zero, duration: screen.duration),
                        timelineStart: .zero)
        project.timeline.tracks.insert(Track(kind: .video, name: "Kamera", clips: [clip]), at: 0)

        let image = try await frame(at: 1, package: package, project: project)
        // Ohne Kamera wäre die Ecke unten rechts roter Hintergrund; oben links bleibt sie es.
        let layout = SceneLayout(output: CGSize(width: 320, height: 240), sourceSize: CGSize(width: 320, height: 240),
                                 look: project.look)
        let rect = layout.cameraRect(project.look.camera)
        let cameraPixel = try TestMedia.pixel(image, x: Int(rect.midX), y: 240 - Int(rect.midY))
        #expect(cameraPixel.red < 0.5)
        let free = try TestMedia.pixel(image, x: 4, y: 4)
        #expect(free.red > 0.9 && free.green < 0.1)
    }

    @Test func exportsGIF() async throws {
        let package = try await TestMedia.makeRecordingPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let project = try await ProjectFactory.makeProject(forRecordingAt: package)
        let built = try await CompositionBuilder(packageURL: package).build(project)
        var settings = ExportSettings()
        settings.preset = .gif
        settings.gifSize = 160
        settings.gifFrameRate = 10
        let format = ExportController.format(for: settings, built: built)
        #expect(format.fileExtension == "gif")
        #expect(format.renderSize == CGSize(width: 160, height: 120))

        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        try await GIFExporter(built, format: format, to: url).run { _ in }

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 20)
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(first.width == 160 && first.height == 120)
        let delays = (0..<CGImageSourceGetCount(source)).compactMap { index -> Double? in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return gif?[kCGImagePropertyGIFDelayTime] as? Double
        }
        #expect(abs(delays.reduce(0, +) - 2) < 0.05)
    }
}
