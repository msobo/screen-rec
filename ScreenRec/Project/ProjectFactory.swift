import AVFoundation

/// Erzeugt aus einer frischen Aufnahme das bearbeitbare Projekt.
enum ProjectFactory {
    private struct TrackSpec {
        var key: String
        var role: MediaAsset.Role
        var kind: MediaKind
        var name: String
    }

    private static let specs = [
        // Die Kamera liegt in der Timeline oben, wie ihre Einblendung im Bild.
        TrackSpec(key: CaptureWriter.Track.camera.rawValue, role: .camera, kind: .video, name: "Kamera"),
        TrackSpec(key: CaptureWriter.Track.screen.rawValue, role: .screen, kind: .video, name: "Bildschirm"),
        TrackSpec(key: CaptureWriter.Track.systemAudio.rawValue, role: .systemAudio, kind: .audio, name: "Systemton"),
        TrackSpec(key: CaptureWriter.Track.microphone.rawValue, role: .microphone, kind: .audio, name: "Mikrofon"),
    ]

    /// Eine Spur pro Datei, je ein Clip über die volle Länge, alle Clips verknüpft.
    /// Tonspuren, die später eingesetzt haben, beginnen an ihrem Startversatz.
    /// Dazu die Standard-Gestaltung und Auto-Zooms um die Klicks.
    static func makeProject(forRecordingAt package: URL) async throws -> Project {
        let media = package.appending(path: "media", directoryHint: .isDirectory)
        let info = try RecordingStorage.loadInfo(in: media)
        let linkGroupID = UUID()

        var assets: [MediaAsset] = []
        var tracks: [Track] = []
        for spec in specs {
            guard let fileName = info.files[spec.key] else { continue }
            let avAsset = AVURLAsset(url: media.appending(path: fileName))
            let duration = RationalTime(try await avAsset.load(.duration))
            guard duration > .zero else { continue }

            var asset = MediaAsset(id: UUID(), kind: spec.kind, role: spec.role, path: "media/\(fileName)",
                                   duration: duration)
            if spec.kind == .video, let track = try await avAsset.loadTracks(withMediaType: .video).first {
                let size = try await track.load(.naturalSize)
                asset.pixelWidth = Int(size.width)
                asset.pixelHeight = Int(size.height)
            }
            assets.append(asset)

            let clip = Clip(assetID: asset.id,
                            sourceRange: RationalTimeRange(start: .zero, duration: duration),
                            timelineStart: RationalTime(seconds: info.startOffsets[spec.key] ?? 0),
                            linkGroupID: linkGroupID)
            tracks.append(Track(kind: spec.kind, name: spec.name, clips: [clip]))
        }
        var project = Project(assets: assets, timeline: Timeline(tracks: tracks))
        project.look = .standard
        // Ein eingebrannter Cursor wird nicht noch einmal gezeichnet.
        project.look.cursor.isVisible = !info.showsCursor
        if let cursor = CursorData.load(fromPackage: package) {
            let screens = Set(assets.filter { $0.role == .screen }.map(\.id))
            project.timeline.zooms = ZoomCommands.automaticZooms(
                for: project.timeline, clickTimes: cursor.data.clicks.filter { $0.phase == .down }.map(\.t),
                screenAssetIDs: screens)
            project.timeline.annotations = KeystrokeGrouper.annotations(from: cursor.data.keystrokes)
        }
        return project
    }

    /// Schreibt `project.json` in das Paket der Aufnahme.
    ///
    /// Die Tastendrücke wandern dabei ganz ins Projekt: Nur dort lässt sich ein getipptes Passwort
    /// endgültig überschreiben, in `cursor.json` bliebe es erhalten.
    static func createProjectFile(forRecordingAt package: URL) async throws {
        let project = try await makeProject(forRecordingAt: package)
        try SchemaMigration.encode(project)
            .write(to: package.appending(path: ProjectDocument.projectFileName), options: .atomic)
        try CursorData.removeKeystrokes(fromPackage: package)
    }
}
