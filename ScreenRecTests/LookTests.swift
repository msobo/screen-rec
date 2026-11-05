import AppKit
import Testing
@testable import ScreenRec

struct SceneLayoutTests {
    private let output = CGSize(width: 1920, height: 1080)

    @Test func neutralLookFillsOutput() {
        let layout = SceneLayout(output: output, sourceSize: CGSize(width: 3840, height: 2160), look: .neutral)
        #expect(layout.contentRect == CGRect(origin: .zero, size: output))
        #expect(layout.cornerRadius == 0)
    }

    @Test func paddingInsetsAndKeepsAspect() {
        var look = Look.neutral
        look.padding = 0.1
        let layout = SceneLayout(output: output, sourceSize: CGSize(width: 1600, height: 1000), look: look)
        // 10 % der kürzeren Seite (108 px) Abstand; das 16:10-Bild füllt die verbleibende Höhe.
        #expect(abs(layout.contentRect.height - 864) < 0.001)
        #expect(abs(layout.contentRect.width - 1382.4) < 0.001)
        #expect(abs(layout.contentRect.midX - 960) < 0.001)
    }

    @Test func zoomStaysInsideOutput() {
        let layout = SceneLayout(output: output, sourceSize: output, look: .neutral)
        // Blickpunkt ganz oben links: Der Ausschnitt stößt an die Ecke, statt darüber hinauszugehen.
        let transform = layout.zoomTransform(ZoomPath.State(scale: 2, focus: CGPoint(x: 0, y: 0)))
        let topLeft = CGPoint(x: 0, y: output.height).applying(transform)
        #expect(abs(topLeft.x) < 0.001)
        #expect(abs(topLeft.y - output.height) < 0.001)
        // Mitte: Die Bildmitte bleibt in der Mitte.
        let centered = layout.zoomTransform(ZoomPath.State(scale: 3, focus: CGPoint(x: 0.5, y: 0.5)))
        let center = CGPoint(x: 960, y: 540).applying(centered)
        #expect(abs(center.x - 960) < 0.001 && abs(center.y - 540) < 0.001)
    }

    @Test func zoomedViewStaysInsideRecording() {
        var look = Look.neutral
        look.padding = 0.1
        let layout = SceneLayout(output: output, sourceSize: output, look: look)
        // 2× in die obere linke Ecke: Der Ausschnitt beginnt an der Ecke der Aufnahme, nicht im Abstand.
        let transform = layout.zoomTransform(ZoomPath.State(scale: 2, focus: CGPoint(x: 0, y: 0)))
        let corner = CGPoint(x: layout.contentRect.minX, y: layout.contentRect.maxY).applying(transform)
        #expect(abs(corner.x) < 0.001 && abs(corner.y - output.height) < 0.001)
        // Knapp über 1×: Der Ausschnitt ist größer als die Aufnahme und enthält sie ganz.
        let slight = layout.zoomTransform(ZoomPath.State(scale: 1.05, focus: CGPoint(x: 0, y: 0)))
        let bottomRight = CGPoint(x: layout.contentRect.maxX, y: layout.contentRect.minY).applying(slight)
        #expect(bottomRight.x <= output.width + 0.001 && bottomRight.y >= -0.001)
    }

    @Test func cameraSitsInChosenCorner() {
        let layout = SceneLayout(output: output, sourceSize: output, look: .neutral)
        var style = CameraStyle()
        style.corner = .bottomRight
        let rect = layout.cameraRect(style)
        #expect(rect.width == rect.height)
        #expect(rect.maxX < output.width && rect.minY > 0 && rect.minY < output.height / 2)
        style.corner = .topLeft
        let topLeft = layout.cameraRect(style)
        #expect(topLeft.minX < output.width / 2 && topLeft.maxY > output.height / 2)
    }

    @Test func renderSizeFollowsAspect() {
        let source = CGSize(width: 3024, height: 1964)
        #expect(SceneLayout.renderSize(source: source, aspect: .source) == source)
        #expect(SceneLayout.renderSize(source: source, aspect: .landscape) == CGSize(width: 3024, height: 1702))
        #expect(SceneLayout.renderSize(source: source, aspect: .square) == CGSize(width: 3024, height: 3024))
        #expect(SceneLayout.renderSize(source: source, aspect: .portrait) == CGSize(width: 1702, height: 3024))
    }
}

struct CursorPathTests {
    private func data(_ samples: [(Double, Double, Double)]) -> CursorData {
        var data = CursorData()
        data.samples = samples.map { CursorData.Sample(t: $0.0, x: $0.1, y: $0.2, cursor: nil) }
        return data
    }

    private let frame = CGRect(x: 100, y: 50, width: 200, height: 100)

    @Test func normalizesToContentFrame() throws {
        let path = CursorPath(data: data([(0, 200, 100)]), fallbackFrame: frame, duration: 1, smoothing: 0)
        let position = try #require(path.position(at: 0.5))
        #expect(abs(position.x - 0.5) < 1e-6 && abs(position.y - 0.5) < 1e-6)
    }

    @Test func smoothingLagsBehindButArrives() throws {
        // Sprung von links nach rechts bei 1 s.
        let samples = [(0.0, 100.0, 100.0), (1.0, 300.0, 100.0)]
        let raw = CursorPath(data: data(samples), fallbackFrame: frame, duration: 3, smoothing: 0)
        let smooth = CursorPath(data: data(samples), fallbackFrame: frame, duration: 3, smoothing: 0.6)
        #expect(try #require(raw.position(at: 1.05)).x == 1)
        let lagging = try #require(smooth.position(at: 1.05)).x
        #expect(lagging > 0 && lagging < 0.9)
        #expect(abs(try #require(smooth.position(at: 2.5)).x - 1) < 0.01)
        // Kritisch gedämpft: kein Überschwingen.
        for step in 0..<180 {
            #expect(try #require(smooth.position(at: Double(step) / 60)).x <= 1.0001)
        }
    }

    @Test func followsMovingWindow() throws {
        var data = data([(0, 150, 100), (2, 250, 100)])
        // Das Fenster wird mit dem Cursor verschoben: relativ bleibt er an derselben Stelle.
        data.contentFrames = [.init(t: 0, x: 100, y: 50, width: 200, height: 100),
                              .init(t: 2, x: 200, y: 50, width: 200, height: 100)]
        let path = CursorPath(data: data, fallbackFrame: .zero, duration: 3, smoothing: 0)
        #expect(abs(try #require(path.position(at: 1)).x - 0.25) < 1e-6)
        #expect(abs(try #require(path.position(at: 2.5)).x - 0.25) < 1e-6)
    }

}

struct KeystrokeLabelTests {
    @Test func formatsShortcuts() {
        #expect(KeystrokeLabel.label(keyCode: 1, characters: "s", modifiers: [.command, .shift]) == "⇧⌘S")
        #expect(KeystrokeLabel.label(keyCode: 123, characters: nil, modifiers: [.control, .option]) == "⌃⌥←")
        #expect(KeystrokeLabel.label(keyCode: 36, characters: "\r", modifiers: []) == "↩")
    }

    @Test func ignoresPlainTyping() {
        #expect(KeystrokeLabel.label(keyCode: 0, characters: "a", modifiers: []) == nil)
        #expect(KeystrokeLabel.label(keyCode: 0, characters: "A", modifiers: .shift) == nil)
    }
}

struct LookMigrationTests {
    @Test func version3KeepsOldLookAndGetsEmptyZoomTrack() throws {
        var project = Project(assets: [], timeline: Timeline())
        project.exportSettings.resolution = .p2160
        var object = try #require(JSONSerialization.jsonObject(with: SchemaMigration.encode(project)) as? [String: Any])
        object["schemaVersion"] = 3
        object.removeValue(forKey: "look")
        var timeline = try #require(object["timeline"] as? [String: Any])
        timeline.removeValue(forKey: "zooms")
        object["timeline"] = timeline
        var export = try #require(object["exportSettings"] as? [String: Any])
        export.removeValue(forKey: "gifSize")
        export.removeValue(forKey: "gifFrameRate")
        object["exportSettings"] = export

        let decoded = try SchemaMigration.decodeProject(from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.look == .neutral)
        #expect(decoded.timeline.zooms.isEmpty)
        #expect(decoded.exportSettings.resolution == .p2160)
        #expect(decoded.exportSettings.gifSize == ExportSettings().gifSize)
    }

    @Test func cursorDataVersion1StillDecodes() throws {
        let json = #"{"version":1,"coordinateSpace":"global-points-top-left","samples":[{"t":0,"x":1,"y":2}],"clicks":[],"cursors":{}}"#
        let data = try JSONDecoder().decode(CursorData.self, from: Data(json.utf8))
        #expect(data.samples.count == 1)
        #expect(data.contentFrames.isEmpty && data.keystrokes.isEmpty)
    }

    @Test func gifDelaysAddUpToDuration() {
        let total = (0..<15).map { GIFExporter.delay(ofFrame: $0, frameRate: 15) }.reduce(0, +)
        #expect(abs(total - 1) < 1e-9)
    }
}
