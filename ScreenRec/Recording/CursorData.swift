import Foundation

/// Inhalt von `media/cursor.json`: Mausbewegung, Klicks, Cursor-Bilder und Tastenkürzel einer Aufnahme.
///
/// Zeiten sind Aufnahmezeit in Sekunden, also dieselbe Uhr wie das Video und ohne Pausen.
/// Version 1 kennt nur Bewegung, Klicks und Cursor-Bilder.
struct CursorData: Codable, Sendable {
    struct Sample: Codable, Sendable {
        var t: Double
        var x: Double
        var y: Double
        /// ID in `cursors`, nur gesetzt, wenn sich das Cursor-Bild geändert hat.
        var cursor: String?
    }

    struct Click: Codable, Sendable {
        enum Button: String, Codable, Sendable { case left, right, other }
        enum Phase: String, Codable, Sendable { case down, up }
        var t: Double
        var x: Double
        var y: Double
        var button: Button
        var phase: Phase
    }

    struct CursorImage: Codable, Sendable {
        var png: Data
        /// Größe und Hotspot in Punkten.
        var width: Double
        var height: Double
        var hotSpotX: Double
        var hotSpotY: Double
    }

    /// Lage des aufgenommenen Bereichs auf dem Bildschirm, ab `t` gültig. Bei Fenstern ändert
    /// sie sich, wenn das Fenster verschoben wird.
    struct ContentFrame: Codable, Sendable {
        var t: Double
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    /// Ein Tastendruck: Kürzel wie „⌘⇧S“ oder, mit `isTyped`, ein getipptes Zeichen.
    ///
    /// Getipptes steht nur bis zur Projektanlage hier (siehe `ProjectFactory`), danach nur noch im
    /// Projekt, wo es sich endgültig maskieren lässt.
    struct Keystroke: Codable, Sendable {
        var t: Double
        var label: String
        var isTyped: Bool?
    }

    var version = 2
    /// Globale Bildschirmkoordinaten in Punkten, Ursprung oben links am Hauptbildschirm
    /// (wie bei ScreenCaptureKit und Core Graphics).
    var coordinateSpace = "global-points-top-left"
    var samples: [Sample] = []
    var clicks: [Click] = []
    var cursors: [String: CursorImage] = [:]
    var contentFrames: [ContentFrame] = []
    var keystrokes: [Keystroke] = []

    private enum CodingKeys: String, CodingKey {
        case version, coordinateSpace, samples, clicks, cursors, contentFrames, keystrokes
    }

    init() {}

    /// Version 1 hat weder `contentFrames` noch `keystrokes`.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        coordinateSpace = try container.decode(String.self, forKey: .coordinateSpace)
        samples = try container.decode([Sample].self, forKey: .samples)
        clicks = try container.decode([Click].self, forKey: .clicks)
        cursors = try container.decode([String: CursorImage].self, forKey: .cursors)
        contentFrames = try container.decodeIfPresent([ContentFrame].self, forKey: .contentFrames) ?? []
        keystrokes = try container.decodeIfPresent([Keystroke].self, forKey: .keystrokes) ?? []
    }

    static let fileName = "cursor.json"

    /// Cursor-Daten und Aufnahme-Infos eines Pakets, oder `nil`, wenn es keine gibt (z. B. importiertes Material).
    static func load(fromPackage package: URL) -> (data: CursorData, info: RecordingInfo)? {
        let media = package.appending(path: "media", directoryHint: .isDirectory)
        guard let info = try? RecordingStorage.loadInfo(in: media),
              let json = try? Data(contentsOf: media.appending(path: info.files["cursor"] ?? fileName)),
              let data = try? JSONDecoder().decode(CursorData.self, from: json)
        else { return nil }
        return (data, info)
    }

    /// Entfernt die Tastendrücke aus der Datei eines Pakets.
    static func removeKeystrokes(fromPackage package: URL) throws {
        guard var (data, info) = load(fromPackage: package), !data.keystrokes.isEmpty else { return }
        data.keystrokes = []
        let media = package.appending(path: "media", directoryHint: .isDirectory)
        try JSONEncoder().encode(data).write(to: media.appending(path: info.files["cursor"] ?? fileName), options: .atomic)
    }

    /// Bereich der Aufnahme auf dem Bildschirm zum Zeitpunkt `t`. Ohne aufgezeichnete Rahmen
    /// (Version 1) gilt der beim Start gemeldete Bereich.
    func contentFrame(at t: Double, fallback: CGRect) -> CGRect {
        guard let index = contentFrames.lastIndex(where: { $0.t <= t }) ?? (contentFrames.isEmpty ? nil : 0) else {
            return fallback
        }
        return contentFrames[index].rect
    }
}
