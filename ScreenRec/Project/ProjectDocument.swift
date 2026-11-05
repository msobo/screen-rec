import os
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Paket-Ordner `*.screenrec` (siehe `UTExportedTypeDeclarations` in `project.yml`).
    static let screenRecProject = UTType(exportedAs: "de.sobolewski.screenrec.project")
}

/// Ein geöffnetes `.screenrec`-Paket.
///
/// Gespeichert wird nur `project.json`; die Mediendateien bleiben unangetastet im
/// bestehenden Paket. Jede Änderung läuft über `update`, damit Undo/Redo und der
/// „ungesichert“-Status von macOS stimmen.
///
/// `@unchecked Sendable`: `project` wird nur auf dem Main Thread geändert (alle Änderungs-
/// methoden sind `@MainActor`); SwiftUI ruft `snapshot` ebenfalls auf dem Main Thread auf.
final class ProjectDocument: ReferenceFileDocument, @unchecked Sendable {
    static let projectFileName = "project.json"
    static let readableContentTypes: [UTType] = [.screenRecProject]

    @Published private(set) var project: Project
    /// Stand vor einer laufenden `liveUpdate`-Geste.
    private var liveUpdateBase: Project?
    /// Dateien, die der Editor nachträglich ins Paket legt (z. B. Hintergrundbilder), Pfad → Inhalt.
    /// Sie liegen schon im Paket auf der Platte, müssen aber auch in den `FileWrapper`, sonst
    /// verwirft macOS sie beim nächsten sicheren Speichern.
    private let addedFiles = OSAllocatedUnfairLock<[String: Data]>(initialState: [:])

    enum DocumentError: LocalizedError {
        case missingProjectFile

        var errorDescription: String? {
            "Im Paket fehlt die Datei \(ProjectDocument.projectFileName). Aufnahmen aus der ersten Testversion lassen sich nicht öffnen."
        }
    }

    init(project: Project = Project(assets: [], timeline: Timeline())) {
        self.project = project
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.fileWrappers?[Self.projectFileName]?.regularFileContents else {
            throw DocumentError.missingProjectFile
        }
        project = try SchemaMigration.decodeProject(from: data)
        // Vor Schema 5 lagen die Tastenkürzel nur in `cursor.json`. Getipptes gab es damals nicht.
        if SchemaMigration.storedVersion(of: data) ?? 0 < 5,
           let json = configuration.file.fileWrappers?["media"]?.fileWrappers?[CursorData.fileName]?.regularFileContents,
           let cursor = try? JSONDecoder().decode(CursorData.self, from: json) {
            project.timeline.annotations = KeystrokeGrouper.annotations(from: cursor.keystrokes)
        }
    }

    func snapshot(contentType: UTType) throws -> Project {
        project
    }

    func fileWrapper(snapshot: Project, configuration: WriteConfiguration) throws -> FileWrapper {
        let package = configuration.existingFile ?? FileWrapper(directoryWithFileWrappers: [:])
        if let old = package.fileWrappers?[Self.projectFileName] {
            package.removeFileWrapper(old)
        }
        let json = FileWrapper(regularFileWithContents: try SchemaMigration.encode(snapshot))
        json.preferredFilename = Self.projectFileName
        package.addFileWrapper(json)

        for (path, data) in addedFiles.withLock({ $0 }) {
            let components = path.split(separator: "/").map(String.init)
            guard let name = components.last else { continue }
            var directory = package
            for component in components.dropLast() {
                if let existing = directory.fileWrappers?[component], existing.isDirectory {
                    directory = existing
                } else {
                    let created = FileWrapper(directoryWithFileWrappers: [:])
                    created.preferredFilename = component
                    directory.addFileWrapper(created)
                    directory = created
                }
            }
            guard directory.fileWrappers?[name] == nil else { continue }
            let file = FileWrapper(regularFileWithContents: data)
            file.preferredFilename = name
            directory.addFileWrapper(file)
        }
        return package
    }

    /// Legt eine Datei ins Paket, z. B. ein Hintergrundbild. Liefert den Pfad relativ zum Paket.
    func addFile(_ data: Data, named name: String, toPackageAt packageURL: URL) throws -> String {
        let path = "media/\(name)"
        try data.write(to: packageURL.appending(path: path), options: .atomic)
        addedFiles.withLock { $0[path] = data }
        return path
    }

    // MARK: Ändern

    /// Führt eine Änderung als ein Undo-Schritt aus.
    @MainActor
    func update(_ actionName: String, undoManager: UndoManager?, _ change: (inout Project) -> Void) {
        endLiveUpdate(actionName, undoManager: undoManager)
        let previous = project
        change(&project)
        guard project != previous else { return }
        registerUndo(restoring: previous, actionName: actionName, undoManager: undoManager)
    }

    /// Fortlaufende Änderung, z. B. während ein Regler gezogen wird: sofort sichtbar, aber erst
    /// `endLiveUpdate` legt einen einzigen Undo-Schritt für die ganze Geste an.
    @MainActor
    func liveUpdate(_ change: (inout Project) -> Void) {
        if liveUpdateBase == nil { liveUpdateBase = project }
        change(&project)
    }

    @MainActor
    func endLiveUpdate(_ actionName: String, undoManager: UndoManager?) {
        guard let base = liveUpdateBase else { return }
        liveUpdateBase = nil
        guard project != base else { return }
        registerUndo(restoring: base, actionName: actionName, undoManager: undoManager)
    }

    /// Editor-Zustand (Playhead, Zoom) ändert sich ständig und ist deshalb kein Undo-Schritt.
    @MainActor
    func updateEditorState(_ change: (inout EditorState) -> Void) {
        change(&project.editorState)
    }

    @MainActor
    private func restore(_ snapshot: Project, actionName: String, undoManager: UndoManager?) {
        let current = project
        project = snapshot
        registerUndo(restoring: current, actionName: actionName, undoManager: undoManager)
    }

    @MainActor
    private func registerUndo(restoring snapshot: Project, actionName: String, undoManager: UndoManager?) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                document.restore(snapshot, actionName: actionName, undoManager: undoManager)
            }
        }
        undoManager.setActionName(actionName)
    }
}
