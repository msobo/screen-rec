import Foundation

/// Liest `project.json` jeder bisherigen Schema-Version und hebt es auf die aktuelle an.
///
/// Neue Version einführen: `Project.currentSchemaVersion` erhöhen und hier einen Schritt
/// `migrations[alteVersion]` ergänzen, der das JSON-Objekt der alten Version umbaut.
enum SchemaMigration {
    enum MigrationError: LocalizedError {
        case notAProject
        case newerVersion(Int)
        case missingStep(Int)

        var errorDescription: String? {
            switch self {
            case .notAProject: "Die Datei ist kein ScreenRec-Projekt."
            case .newerVersion(let version):
                "Das Projekt wurde mit einer neueren ScreenRec-Version erstellt (Schema \(version))."
            case .missingStep(let version): "Für Schema-Version \(version) fehlt eine Migration."
            }
        }
    }

    typealias JSONObject = [String: Any]

    /// Schritt von Version n auf n + 1.
    static let migrations: [Int: @Sendable (JSONObject) throws -> JSONObject] = [
        // 1 → 2: Clips haben ein eigenes `isMuted`.
        1: { project in
            var project = project
            guard var timeline = project["timeline"] as? JSONObject,
                  let tracks = timeline["tracks"] as? [JSONObject]
            else { return project }
            timeline["tracks"] = tracks.map { track in
                var track = track
                track["clips"] = (track["clips"] as? [JSONObject] ?? []).map { clip in
                    var clip = clip
                    clip["isMuted"] = clip["isMuted"] ?? false
                    return clip
                }
                return track
            }
            project["timeline"] = timeline
            return project
        },
        // 2 → 3: Exporteinstellungen im Projekt.
        2: { project in
            var project = project
            if project["exportSettings"] == nil {
                project["exportSettings"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ExportSettings()))
            }
            return project
        },
        // 3 → 4: Gestaltung, Zoom-Spur und GIF-Export. Alte Projekte behalten ihr Aussehen.
        3: { project in
            var project = project
            if project["look"] == nil {
                project["look"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Look.neutral))
            }
            if var timeline = project["timeline"] as? JSONObject {
                timeline["zooms"] = timeline["zooms"] ?? [JSONObject]()
                project["timeline"] = timeline
            }
            // Neue Exportfelder mit Standardwerten ergänzen, vorhandene behalten.
            let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ExportSettings())) as? JSONObject ?? [:]
            let existing = project["exportSettings"] as? JSONObject ?? [:]
            project["exportSettings"] = defaults.merging(existing) { _, old in old }
            return project
        },
        // 4 → 5: Einblendungen. Die Tastenkürzel aus `cursor.json` übernimmt `ProjectDocument`.
        4: { project in
            var project = project
            if var timeline = project["timeline"] as? JSONObject {
                timeline["annotations"] = timeline["annotations"] ?? [JSONObject]()
                project["timeline"] = timeline
            }
            return project
        },
    ]

    /// Schema-Version, in der `data` gespeichert ist.
    static func storedVersion(of data: Data) -> Int? {
        (try? JSONSerialization.jsonObject(with: data) as? JSONObject)?["schemaVersion"] as? Int
    }

    static func decodeProject(from data: Data) throws -> Project {
        guard var object = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
            throw MigrationError.notAProject
        }
        var version = object["schemaVersion"] as? Int ?? 0
        if version > Project.currentSchemaVersion { throw MigrationError.newerVersion(version) }

        while version < Project.currentSchemaVersion {
            guard let step = migrations[version] else { throw MigrationError.missingStep(version) }
            object = try step(object)
            version += 1
            object["schemaVersion"] = version
        }
        return try JSONDecoder().decode(Project.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func encode(_ project: Project) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(project)
    }
}
