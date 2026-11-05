import Foundation

/// Metadaten einer Rohaufnahme, gespeichert als `media/recording.json`.
/// `ProjectFactory` erzeugt daraus das bearbeitbare Projekt.
struct RecordingInfo: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case version, createdAt, duration, source, videoWidth, videoHeight, frameRate, files, startOffsets, droppedFrames
        case showsCursor
    }

    struct Source: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case display, window, application, unknown }
        var kind: Kind
        /// Aufgenommener Bereich in Punkten, wie von ScreenCaptureKit gemeldet.
        var contentRect: CGRect
        var pointPixelScale: Double
    }

    var version = 1
    var createdAt: Date
    var duration: Double
    var source: Source
    var videoWidth: Int
    var videoHeight: Int
    var frameRate: Int
    /// Spur → Dateiname relativ zum `media`-Ordner.
    var files: [String: String]
    /// Spur → Startzeitpunkt der Datei in der Aufnahme, in Sekunden.
    var startOffsets: [String: Double] = [:]
    var droppedFrames: Int
    /// Cursor ins Video eingebrannt; dann wird er im Editor nicht noch einmal gezeichnet.
    var showsCursor = false
}

extension RecordingInfo {
    /// `startOffsets` und `showsCursor` fehlen in den ersten Aufnahmen und bekommen dann Standardwerte.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        duration = try container.decode(Double.self, forKey: .duration)
        source = try container.decode(Source.self, forKey: .source)
        videoWidth = try container.decode(Int.self, forKey: .videoWidth)
        videoHeight = try container.decode(Int.self, forKey: .videoHeight)
        frameRate = try container.decode(Int.self, forKey: .frameRate)
        files = try container.decode([String: String].self, forKey: .files)
        startOffsets = try container.decodeIfPresent([String: Double].self, forKey: .startOffsets) ?? [:]
        droppedFrames = try container.decode(Int.self, forKey: .droppedFrames)
        showsCursor = try container.decodeIfPresent(Bool.self, forKey: .showsCursor) ?? false
    }
}

enum RecordingStorage {
    static let packageExtension = "screenrec"

    static var baseDirectory: URL {
        URL.moviesDirectory.appending(path: "ScreenRec", directoryHint: .isDirectory)
    }

    /// Legt `~/Movies/ScreenRec/Aufnahme <Datum>.screenrec/media/` an.
    static func makeRecordingPackage(date: Date = .now) throws -> (package: URL, media: URL) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "yyyy-MM-dd 'um' HH.mm.ss"
        let package = baseDirectory.appending(path: "Aufnahme \(formatter.string(from: date)).\(packageExtension)",
                                              directoryHint: .isDirectory)
        let media = package.appending(path: "media", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        return (package, media)
    }

    static func loadInfo(in media: URL) throws -> RecordingInfo {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingInfo.self, from: Data(contentsOf: media.appending(path: "recording.json")))
    }

    static func save(_ info: RecordingInfo, in media: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(info).write(to: media.appending(path: "recording.json"), options: .atomic)
    }
}
