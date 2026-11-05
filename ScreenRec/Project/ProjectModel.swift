import CoreMedia
import Foundation

/// Bearbeitungsstand eines Screen-Recordings, gespeichert als `project.json`.
///
/// Alles ist non-destruktiv: Clips verweisen nur auf Bereiche der Originaldateien in `media/`.
struct Project: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 5

    var schemaVersion = Project.currentSchemaVersion
    var assets: [MediaAsset]
    var timeline: Timeline
    var editorState = EditorState()
    /// Zuletzt benutzte Exporteinstellungen.
    var exportSettings = ExportSettings()
    /// Hintergrund, Rahmen, Cursor, Kamera und Tastenkürzel.
    var look = Look.neutral

    func asset(withID id: MediaAsset.ID) -> MediaAsset? {
        assets.first { $0.id == id }
    }
}

enum MediaKind: String, Codable, Sendable {
    case video, audio
}

/// Eine Originaldatei im Paket.
struct MediaAsset: Codable, Equatable, Identifiable, Sendable {
    enum Role: String, Codable, Sendable { case screen, systemAudio, microphone, camera, imported }

    var id: UUID
    var kind: MediaKind
    var role: Role
    /// Pfad relativ zum Paket, z. B. `media/screen.mov`.
    var path: String
    var duration: RationalTime
    var pixelWidth: Int?
    var pixelHeight: Int?
}

struct Timeline: Codable, Equatable, Sendable {
    var tracks: [Track] = []
    var transitions: [Transition] = []
    /// Zoom-Spur: nach Start sortiert, ohne Überlappung, in Timeline-Zeit.
    var zooms: [ZoomRegion] = []
    /// Tasten, Texte und Symbole, verankert in der Bildschirmaufnahme (siehe `AnnotationPlacement`).
    var annotations: [Annotation] = []

    var duration: RationalTime {
        tracks.flatMap(\.clips).map(\.timelineEnd).max() ?? .zero
    }

    func clip(withID id: Clip.ID) -> Clip? {
        for track in tracks {
            if let clip = track.clips.first(where: { $0.id == id }) { return clip }
        }
        return nil
    }
}

struct Track: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: MediaKind
    var name: String
    var isMuted = false
    var volume: Float = 1
    /// Nach `timelineStart` sortiert und ohne Überlappung.
    var clips: [Clip] = []

    /// `name` steht unübersetzt im Projekt, damit Projekte beim Sprachwechsel gleich bleiben.
    var title: String { Bundle.main.localizedString(forKey: name, value: name, table: nil) }
}

struct Clip: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var assetID: MediaAsset.ID
    /// Verwendeter Bereich der Originaldatei.
    var sourceRange: RationalTimeRange
    var timelineStart: RationalTime
    /// 1 = normal, 2 = doppelt so schnell. Erlaubt: 0.25 … 16.
    var speed: Double = 1
    var volume: Float = 1
    /// Nur Ton: Clip stumm, z. B. in beschleunigten Abschnitten. Die Lautstärke bleibt erhalten.
    var isMuted = false
    var fadeIn: RationalTime = .zero
    var fadeOut: RationalTime = .zero
    /// Clips derselben Gruppe (z. B. Bild + Ton) werden gemeinsam bearbeitet.
    var linkGroupID: UUID?

    static let speedRange = 0.25...16.0

    /// Dauer auf der Timeline nach Anwendung der Geschwindigkeit.
    var timelineDuration: RationalTime {
        TimeMapping.timelineDuration(forSourceDuration: sourceRange.duration, speed: speed)
    }

    var timelineEnd: RationalTime { timelineStart + timelineDuration }
    var timelineRange: RationalTimeRange { RationalTimeRange(start: timelineStart, duration: timelineDuration) }
}

struct Transition: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case crossfade
        case fadeThroughBlack

        var title: String {
            switch self {
            case .crossfade: String(localized: "Überblenden")
            case .fadeThroughBlack: String(localized: "Durch Schwarz")
            }
        }
    }

    var id = UUID()
    var fromClipID: Clip.ID
    var toClipID: Clip.ID
    var kind: Kind
    var duration: RationalTime
}

/// Abschnitt der Zoom-Spur: Das Bild wird hineingezoomt und folgt dem Cursor oder einem festen Punkt.
struct ZoomRegion: Codable, Equatable, Identifiable, Sendable {
    enum Focus: String, Codable, CaseIterable, Sendable {
        case cursor, point

        var title: String { self == .cursor ? String(localized: "Cursor folgen") : String(localized: "Fester Punkt") }
    }

    var id = UUID()
    var start: RationalTime
    var duration: RationalTime
    /// Vergrößerung, z. B. 2 = doppelt so groß.
    var scale = 2.0
    var focus = Focus.cursor
    /// Fester Punkt, relativ zum Bild (0 … 1, Ursprung oben links).
    var pointX = 0.5
    var pointY = 0.5
    /// Von „Auto-Zoom“ erzeugt; wird beim nächsten Auto-Zoom ersetzt.
    var isAutomatic = false

    static let scaleRange = 1.1...4.0
    /// Kürzeste Dauer, damit Ein- und Auszoomen Platz haben.
    static let minimumDuration = RationalTime(value: 1, timescale: 2)

    var end: RationalTime { start + duration }
    var range: RationalTimeRange { RationalTimeRange(start: start, duration: duration) }
}

/// Zustand des Editors, der mitgespeichert wird, damit man dort weitermacht, wo man aufgehört hat.
struct EditorState: Codable, Equatable, Sendable {
    var playhead: RationalTime = .zero
    /// Timeline-Zoom in Punkten pro Sekunde.
    var pixelsPerSecond: Double = 100
}
