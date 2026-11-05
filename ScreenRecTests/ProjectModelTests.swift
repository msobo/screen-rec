import CoreMedia
import Foundation
import Testing
@testable import ScreenRec

struct RationalTimeTests {
    @Test func equalityIgnoresRepresentation() {
        #expect(RationalTime(value: 1, timescale: 2) == RationalTime(value: 30, timescale: 60))
        #expect(Set([RationalTime(value: 1, timescale: 2), RationalTime(value: 30, timescale: 60)]).count == 1)
        #expect(RationalTime.zero == RationalTime(value: 0, timescale: 600))
    }

    @Test func arithmeticStaysExact() {
        var time = RationalTime.zero
        let frame = RationalTime(value: 1, timescale: 30)
        for _ in 0..<3_000 { time = time + frame }
        #expect(time == RationalTime(value: 100, timescale: 1))
        #expect(time - frame < time)
    }

    @Test func codableFormat() throws {
        let data = try JSONEncoder().encode(RationalTime(value: 1001, timescale: 30_000))
        #expect(String(decoding: data, as: UTF8.self).contains("\"timescale\":30000"))
        #expect(try JSONDecoder().decode(RationalTime.self, from: data) == RationalTime(value: 1001, timescale: 30_000))
    }
}

struct ClipTests {
    private func clip(seconds: Int64, speed: Double) -> Clip {
        Clip(assetID: UUID(),
             sourceRange: RationalTimeRange(start: .zero, duration: RationalTime(value: seconds, timescale: 1)),
             timelineStart: RationalTime(value: 1, timescale: 1), speed: speed)
    }

    @Test(arguments: [(1.0, 12.0), (2.0, 6.0), (4.0, 3.0), (0.5, 24.0), (1.5, 8.0)])
    func timelineDurationRespectsSpeed(speed: Double, expected: Double) {
        let clip = clip(seconds: 12, speed: speed)
        #expect(clip.timelineDuration == RationalTime(seconds: expected))
        #expect(clip.timelineEnd == RationalTime(seconds: expected + 1))
    }

    @Test func timelineDurationIsLatestClipEnd() {
        var timeline = Timeline()
        timeline.tracks = [Track(kind: .video, name: "V", clips: [clip(seconds: 4, speed: 1)]),
                           Track(kind: .audio, name: "A", clips: [clip(seconds: 4, speed: 2)])]
        #expect(timeline.duration == RationalTime(value: 5, timescale: 1))
    }
}

struct PersistenceTests {
    private func sampleProject() -> Project {
        let asset = MediaAsset(id: UUID(), kind: .video, role: .screen, path: "media/screen.mov",
                               duration: RationalTime(value: 10, timescale: 1), pixelWidth: 320, pixelHeight: 240)
        let first = Clip(assetID: asset.id,
                         sourceRange: RationalTimeRange(start: .zero, duration: RationalTime(value: 4, timescale: 1)),
                         timelineStart: .zero)
        let second = Clip(assetID: asset.id,
                          sourceRange: RationalTimeRange(start: RationalTime(value: 6, timescale: 1),
                                                         duration: RationalTime(value: 4, timescale: 1)),
                          timelineStart: RationalTime(value: 4, timescale: 1), speed: 2)
        var project = Project(assets: [asset], timeline: Timeline(tracks: [
            Track(kind: .video, name: "Bildschirm", clips: [first, second]),
        ]))
        project.timeline.transitions = [Transition(fromClipID: first.id, toClipID: second.id, kind: .crossfade,
                                                   duration: RationalTime(value: 1, timescale: 2))]
        project.editorState.playhead = RationalTime(value: 3, timescale: 1)
        return project
    }

    @Test func roundTrip() throws {
        let project = sampleProject()
        let decoded = try SchemaMigration.decodeProject(from: SchemaMigration.encode(project))
        #expect(decoded == project)
    }

    @Test func migratesVersion1Clips() throws {
        let project = sampleProject()
        var object = try #require(JSONSerialization.jsonObject(with: SchemaMigration.encode(project)) as? [String: Any])
        object["schemaVersion"] = 1
        var timeline = try #require(object["timeline"] as? [String: Any])
        var tracks = try #require(timeline["tracks"] as? [[String: Any]])
        tracks[0]["clips"] = (tracks[0]["clips"] as? [[String: Any]])?.map { clip in
            var clip = clip
            clip.removeValue(forKey: "isMuted")
            return clip
        }
        timeline["tracks"] = tracks
        object["timeline"] = timeline

        let decoded = try SchemaMigration.decodeProject(from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.schemaVersion == Project.currentSchemaVersion)
        #expect(decoded == project)
    }

    @Test func migratesVersion2WithoutExportSettings() throws {
        var project = sampleProject()
        project.exportSettings.resolution = .p1440
        var object = try #require(JSONSerialization.jsonObject(with: SchemaMigration.encode(project)) as? [String: Any])
        object["schemaVersion"] = 2
        object.removeValue(forKey: "exportSettings")

        let decoded = try SchemaMigration.decodeProject(from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.exportSettings == ExportSettings())
        project.exportSettings = ExportSettings()
        #expect(decoded == project)
    }

    @Test func rejectsNewerSchema() throws {
        var object = try #require(JSONSerialization.jsonObject(with: SchemaMigration.encode(sampleProject())) as? [String: Any])
        object["schemaVersion"] = Project.currentSchemaVersion + 1
        #expect(throws: SchemaMigration.MigrationError.self) {
            try SchemaMigration.decodeProject(from: JSONSerialization.data(withJSONObject: object))
        }
    }

    @Test func rejectsNonProject() {
        #expect(throws: (any Error).self) {
            try SchemaMigration.decodeProject(from: Data("[1, 2]".utf8))
        }
    }
}

@MainActor
struct ProjectDocumentTests {
    @Test func undoAndRedoRestoreProject() throws {
        let track = Track(kind: .audio, name: "Mikrofon")
        let document = ProjectDocument(project: Project(assets: [], timeline: Timeline(tracks: [track])))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        undoManager.beginUndoGrouping()
        document.update("Stummschalten", undoManager: undoManager) { $0.timeline.tracks[0].isMuted = true }
        undoManager.endUndoGrouping()
        #expect(document.project.timeline.tracks[0].isMuted)
        #expect(undoManager.undoActionName == "Stummschalten")

        undoManager.undo()
        #expect(!document.project.timeline.tracks[0].isMuted)
        undoManager.redo()
        #expect(document.project.timeline.tracks[0].isMuted)
    }

    @Test func liveUpdateBecomesSingleUndoStep() {
        let track = Track(kind: .audio, name: "Mikrofon")
        let document = ProjectDocument(project: Project(assets: [], timeline: Timeline(tracks: [track])))
        let undoManager = UndoManager()
        undoManager.groupsByEvent = false

        undoManager.beginUndoGrouping()
        for volume: Float in [0.8, 0.6, 0.4] {
            document.liveUpdate { $0.timeline.tracks[0].volume = volume }
        }
        document.endLiveUpdate("Lautstärke ändern", undoManager: undoManager)
        undoManager.endUndoGrouping()

        #expect(document.project.timeline.tracks[0].volume == 0.4)
        #expect(undoManager.undoActionName == "Lautstärke ändern")
        undoManager.undo()
        #expect(document.project.timeline.tracks[0].volume == 1)
    }

    @Test func noUndoStepWithoutChange() {
        let document = ProjectDocument()
        let undoManager = UndoManager()
        document.update("Nichts", undoManager: undoManager) { _ in }
    }
}

struct ProjectFactoryTests {
    @Test func buildsLinkedTracksWithStartOffsets() async throws {
        let package = try await TestMedia.makeRecordingPackage(microphoneDelay: 0.5)
        defer { try? FileManager.default.removeItem(at: package) }

        try await ProjectFactory.createProjectFile(forRecordingAt: package)
        let project = try SchemaMigration.decodeProject(
            from: Data(contentsOf: package.appending(path: ProjectDocument.projectFileName)))

        #expect(project.timeline.tracks.map(\.name) == ["Bildschirm", "Systemton", "Mikrofon"])
        #expect(project.assets.count == 3)
        let clips = project.timeline.tracks.flatMap(\.clips)
        #expect(Set(clips.compactMap(\.linkGroupID)).count == 1)
        #expect(clips.allSatisfy { $0.linkGroupID != nil })

        let video = try #require(project.timeline.tracks[0].clips.first)
        let microphone = try #require(project.timeline.tracks[2].clips.first)
        #expect(video.timelineStart == .zero)
        #expect(abs(microphone.timelineStart.seconds - 0.5) < 0.001)
        // Der Ton endet dort, wo auch das Video endet: synchron trotz späterem Start.
        #expect(abs(microphone.timelineEnd.seconds - video.timelineEnd.seconds) < 0.05)

        let screenAsset = try #require(project.asset(withID: video.assetID))
        #expect(screenAsset.path == "media/screen.mov")
        #expect(screenAsset.pixelWidth == 320)
        for asset in project.assets {
            #expect(FileManager.default.fileExists(atPath: package.appending(path: asset.path).path))
        }
    }
}
