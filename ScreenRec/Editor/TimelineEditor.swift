import SwiftUI
import Observation

/// Zustand und Aktionen des Timeline-Editors eines Dokumentfensters.
///
/// Timeline-Ansicht, Inspector, Kontextmenüs und das Menü „Schnitt“ rufen alle dieselben
/// Methoden auf; jede Bearbeitung läuft über `EditCommands` und wird ein Undo-Schritt.
@MainActor
@Observable
final class TimelineEditor {
    static let zoomRange = 1.0...3_000.0
    private static let zoomStep = 1.5

    let document: ProjectDocument
    @ObservationIgnored var undoManager: UndoManager?
    @ObservationIgnored weak var playback: PlaybackController?
    let thumbnails: ThumbnailCache?
    let waveforms: WaveformCache?

    var selection: Set<Clip.ID> = [] {
        didSet { if !selection.isEmpty { selectedTransitionID = nil; selectedZoomID = nil; selectedAnnotationID = nil } }
    }
    var selectedTransitionID: Transition.ID? {
        didSet { if selectedTransitionID != nil { selection = []; selectedZoomID = nil; selectedAnnotationID = nil } }
    }
    var selectedZoomID: ZoomRegion.ID? {
        didSet { if selectedZoomID != nil { selection = []; selectedTransitionID = nil; selectedAnnotationID = nil } }
    }
    var selectedAnnotationID: Annotation.ID? {
        didSet { if selectedAnnotationID != nil { selection = []; selectedTransitionID = nil; selectedZoomID = nil } }
    }
    /// Markierter Zeitbereich (z. B. zum Beschleunigen), unabhängig von der Clip-Auswahl.
    var rangeSelection: RationalTimeRange?
    var isSpeedSheetPresented = false
    /// Im Inspektor wird gerade getippt; Menübefehle auf einfachen Tasten ruhen dann.
    var isEditingText = false
    var isSnappingEnabled = true
    /// Punkte pro Sekunde; wird mit dem Projekt gesichert.
    var pixelsPerSecond: Double {
        didSet { document.updateEditorState { $0.pixelsPerSecond = pixelsPerSecond } }
    }
    /// Sichtbare Breite der Timeline, von der Ansicht gemeldet (für „Ganze Timeline zeigen“).
    @ObservationIgnored var visibleWidth: Double = 800

    @ObservationIgnored let packageURL: URL?

    init(document: ProjectDocument, packageURL: URL?) {
        self.document = document
        self.packageURL = packageURL
        pixelsPerSecond = document.project.editorState.pixelsPerSecond
        thumbnails = packageURL.map(ThumbnailCache.init(packageURL:))
        waveforms = packageURL.map(WaveformCache.init(packageURL:))
    }

    var project: Project { document.project }
    var timeline: Timeline { document.project.timeline }
    var playhead: RationalTime { playback?.currentTime ?? project.editorState.playhead }

    /// Gewählte Clips, die es (nach Undo usw.) noch gibt.
    var selectedClips: [Clip] {
        timeline.tracks.flatMap(\.clips).filter { selection.contains($0.id) }
    }

    var selectedTransition: Transition? {
        selectedTransitionID.flatMap { id in timeline.transitions.first { $0.id == id } }
    }

    var selectedZoom: ZoomRegion? {
        selectedZoomID.flatMap { id in timeline.zooms.first { $0.id == id } }
    }

    var selectedAnnotation: Annotation? {
        selectedAnnotationID.flatMap { id in timeline.annotations.first { $0.id == id } }
    }

    // MARK: Bearbeiten

    func perform(_ actionName: String, _ change: (inout Timeline) -> Void) {
        document.update(actionName, undoManager: undoManager) { change(&$0.timeline) }
    }

    /// Für Regler: sofort anwenden, Undo-Schritt erst mit `endLiveChange`.
    func liveChange(_ change: (inout Timeline) -> Void) {
        document.liveUpdate { change(&$0.timeline) }
    }

    func endLiveChange(_ actionName: String) {
        document.endLiveUpdate(actionName, undoManager: undoManager)
    }

    /// Änderung der Gestaltung als ein Undo-Schritt.
    func performLook(_ actionName: String, _ change: (inout Look) -> Void) {
        document.update(actionName, undoManager: undoManager) { change(&$0.look) }
    }

    func liveLookChange(_ change: (inout Look) -> Void) {
        document.liveUpdate { change(&$0.look) }
    }

    func commit(_ timeline: Timeline, actionName: String) {
        perform(actionName) { $0 = timeline }
    }

    func seek(to time: RationalTime) {
        playback?.seek(to: time)
    }

    /// Teilt am Playhead die gewählten Clips oder, ohne Auswahl, alle Clips unter dem Playhead.
    func splitAtPlayhead() {
        let time = playhead
        let clips = selection.isEmpty ? nil : selection
        var didSplit = false
        perform(String(localized: "Teilen")) { didSplit = EditCommands.split(&$0, at: time, clips: clips) }
        if !didSplit { NSSound.beep() }
    }

    func deleteSelection(ripple: Bool) {
        if let annotation = selectedAnnotationID {
            perform(String(localized: "Einblendung löschen")) { AnnotationCommands.delete(&$0, annotation) }
            selectedAnnotationID = nil
            return
        }
        if let zoom = selectedZoomID {
            perform(String(localized: "Zoom löschen")) { ZoomCommands.delete(&$0, zoom) }
            selectedZoomID = nil
            return
        }
        if let transition = selectedTransitionID {
            perform(String(localized: "Übergang löschen")) { EditCommands.deleteTransition(&$0, transition) }
            selectedTransitionID = nil
            return
        }
        guard !selection.isEmpty else { return }
        let clips = selection
        perform(ripple ? String(localized: "Löschen und Lücke schließen") : String(localized: "Löschen")) {
            EditCommands.delete(&$0, clips: clips, ripple: ripple)
        }
        selection = []
    }

    func linkSelection() {
        let clips = selection
        perform(String(localized: "Verknüpfen")) { EditCommands.link(&$0, clips: clips) }
    }

    func unlinkSelection() {
        let clips = selection
        perform(String(localized: "Verknüpfung aufheben")) { EditCommands.unlink(&$0, clips: clips) }
    }

    func setSpeed(_ speed: Double) {
        let clips = selection
        var didChange = false
        perform(String(localized: "Geschwindigkeit ändern")) { didChange = EditCommands.setSpeed(&$0, clips: clips, to: speed) }
        if !didChange { NSSound.beep() }
    }

    // MARK: Abschnitt beschleunigen

    /// Bereich für „Geschwindigkeit …“: der markierte Bereich, sonst die Spanne der gewählten Clips.
    var speedTargetRange: RationalTimeRange? {
        if let rangeSelection { return rangeSelection }
        let clips = selectedClips
        guard let start = clips.map(\.timelineStart).min(), let end = clips.map(\.timelineEnd).max() else { return nil }
        return RationalTimeRange(start: start, duration: end - start)
    }

    func showSpeedSheet() {
        if speedTargetRange == nil {
            NSSound.beep()
        } else {
            isSpeedSheetPresented = true
        }
    }

    func setSpeed(_ speed: Double, in range: RationalTimeRange, muteAudio: Bool) {
        var newRange: RationalTimeRange?
        perform(String(localized: "Abschnitt beschleunigen")) {
            newRange = EditCommands.setSpeed(&$0, in: range, to: speed, muteAudio: muteAudio)
        }
        guard let newRange else { return NSSound.beep() }
        selection = []
        rangeSelection = newRange
    }

    func markRangeStart() {
        let end = rangeSelection.map(\.end).flatMap { $0 > playhead ? $0 : nil } ?? max(timeline.duration, playhead)
        setRange(from: playhead, to: end)
    }

    func markRangeEnd() {
        let start = rangeSelection.map(\.start).flatMap { $0 < playhead ? $0 : nil } ?? .zero
        setRange(from: start, to: playhead)
    }

    /// Bereich zwischen zwei Zeitpunkten in beliebiger Reihenfolge; leer heißt keiner.
    func setRange(from a: RationalTime, to b: RationalTime) {
        let start = max(min(a, b), .zero), end = max(a, b)
        rangeSelection = end > start ? RationalTimeRange(start: start, duration: end - start) : nil
    }

    func clearRange() { rangeSelection = nil }

    // MARK: Übergänge

    /// Fügt den Übergang am nächstgelegenen Schnitt ein, höchstens eine Sekunde vom Playhead
    /// entfernt; bei gleichem Abstand gewinnt die Bildspur.
    func addTransitionAtPlayhead(_ kind: Transition.Kind) {
        let time = playhead, limit = RationalTime(value: 1, timescale: 1)
        let nearest = timeline.cuts
            .map { (cut: $0, distance: max($0.time - time, time - $0.time)) }
            .filter { $0.distance <= limit }
            .min { a, b in
                a.distance != b.distance ? a.distance < b.distance
                    : timeline.tracks[a.cut.trackIndex].kind == .video && timeline.tracks[b.cut.trackIndex].kind != .video
            }
        guard let nearest else { return NSSound.beep() }
        addTransition(kind, after: nearest.cut.fromClipID)
    }

    func addTransition(_ kind: Transition.Kind, after fromClipID: Clip.ID) {
        var added: Transition.ID?
        perform(String(localized: "Übergang hinzufügen")) { added = EditCommands.addTransition(&$0, after: fromClipID, kind: kind) }
        if let added { selectedTransitionID = added } else { NSSound.beep() }
    }

    var canLink: Bool { selection.count >= 2 }
    var canUnlink: Bool { selectedClips.contains { $0.linkGroupID != nil } }
    var canDelete: Bool {
        !selection.isEmpty || selectedTransitionID != nil || selectedZoomID != nil || selectedAnnotationID != nil
    }

    // MARK: Zoom-Spur

    /// Zoom am Playhead, oder im markierten Bereich, falls einer markiert ist.
    func addZoomAtPlayhead() {
        var added: ZoomRegion.ID?
        let range = rangeSelection, time = playhead
        perform(String(localized: "Zoom hinzufügen")) { timeline in
            added = range.flatMap { ZoomCommands.add(&timeline, range: $0) } ?? ZoomCommands.add(&timeline, at: time)
        }
        if let added { selectedZoomID = added } else { NSSound.beep() }
    }

    func addZoom(in range: RationalTimeRange) {
        var added: ZoomRegion.ID?
        perform(String(localized: "Zoom hinzufügen")) { added = ZoomCommands.add(&$0, range: range) }
        if let added { selectedZoomID = added } else { NSSound.beep() }
    }

    // MARK: Einblendungen

    var canAddAnnotation: Bool {
        !AnnotationPlacement.screenClips(in: timeline, screenAssetIDs: project.screenAssetIDs).isEmpty
    }

    /// Fügt am Playhead ein, wenn `time` fehlt.
    func addText(at time: RationalTime? = nil) {
        addAnnotation(.text(TextNote(text: String(localized: "Text"))), at: time, actionName: String(localized: "Text einfügen"))
    }

    func addShape(_ kind: ShapeMark.Kind, at time: RationalTime? = nil) {
        addAnnotation(AnnotationCommands.newShape(kind, in: timeline), at: time, actionName: String(localized: "\(kind.title) einfügen"))
    }

    private func addAnnotation(_ content: Annotation.Content, at time: RationalTime?, actionName: String) {
        var added: Annotation.ID?
        let target = time ?? playhead, screens = project.screenAssetIDs
        perform(actionName) { added = AnnotationCommands.add(&$0, content, at: target, screenAssetIDs: screens) }
        guard let added else { NSSound.beep(); return }
        selectedAnnotationID = added
        // Die Griffe erscheinen nur, solange der Playhead in der Einblendung steht.
        if time != nil { seek(to: target) }
    }

    /// Lage der gewählten Einblendung, falls sie gerade im Schnitt liegt.
    var selectedPlacement: AnnotationPlacement? {
        selectedAnnotationID.flatMap { id in project.annotationPlacements.first { $0.annotation.id == id } }
    }

    /// Teilt die gewählte Tastengruppe am Playhead.
    func splitSelectedKeys() {
        guard let placement = selectedPlacement else { return }
        let offset = (playhead - placement.start).seconds * placement.speed
        var added: Annotation.ID?
        perform(String(localized: "Tasten teilen")) { added = AnnotationCommands.split(&$0, placement.annotation.id, atOffset: offset) }
        if added == nil { NSSound.beep() }
    }

    /// Was die Aufnahme an Cursor-Daten mitbringt; einmal beim Öffnen gelesen.
    private struct CursorSummary {
        /// Klicks in Aufnahmezeit.
        var clickTimes: [Double] = []
        var hasSamples = false
    }

    @ObservationIgnored private lazy var cursorSummary: CursorSummary = {
        guard let data = packageURL.flatMap(CursorData.load(fromPackage:))?.data else { return CursorSummary() }
        return CursorSummary(clickTimes: data.clicks.filter { $0.phase == .down }.map(\.t),
                             hasSamples: !data.samples.isEmpty)
    }()

    private var clickTimes: [Double] { cursorSummary.clickTimes }
    var canGenerateAutoZoom: Bool { !clickTimes.isEmpty }
    var hasCursorData: Bool { cursorSummary.hasSamples }
    var hasKeystrokes: Bool { timeline.annotations.contains { $0.keys != nil } }

    /// Erzeugt die automatischen Zooms aus den Klicks neu; von Hand gesetzte bleiben.
    func generateAutoZoom() {
        let screens = Set(project.assets.filter { $0.role == .screen }.map(\.id))
        let regions = ZoomCommands.automaticZooms(for: timeline, clickTimes: clickTimes, screenAssetIDs: screens)
        guard !regions.isEmpty else { return NSSound.beep() }
        selectedZoomID = nil
        perform(String(localized: "Auto-Zoom")) { ZoomCommands.replaceAutomaticZooms(&$0, with: regions) }
    }

    func updateZoom(_ actionName: String, _ id: ZoomRegion.ID, _ change: @escaping (inout ZoomRegion) -> Void) {
        perform(actionName) { ZoomCommands.update(&$0, id, change) }
    }

    // MARK: Auswahl

    func selectAll() {
        selection = Set(timeline.tracks.flatMap(\.clips).map(\.id))
    }

    func deselectAll() {
        selection = []
        selectedTransitionID = nil
        selectedZoomID = nil
        selectedAnnotationID = nil
        rangeSelection = nil
    }

    // MARK: Zoom

    func zoomIn() { setZoom(pixelsPerSecond * Self.zoomStep) }
    func zoomOut() { setZoom(pixelsPerSecond / Self.zoomStep) }

    func zoomToFit() {
        let duration = max(timeline.duration.seconds, 1)
        setZoom((visibleWidth - TimelineMetrics.leadingInset * 2) / duration)
    }

    func setZoom(_ value: Double) {
        pixelsPerSecond = min(max(value, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }
}

extension FocusedValues {
    @Entry var timelineEditor: TimelineEditor?
}
