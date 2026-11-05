import SwiftUI

/// Eigenschaften der Auswahl als Gehäusemodul: Clips (Geschwindigkeit, Lautstärke, Blenden, Spur),
/// Übergang, Zoom oder Einblendung. Ohne Auswahl stehen hier die wichtigsten Tasten. Die zweite Seite enthält
/// die Gestaltung des ganzen Bilds.
struct InspectorView: View {
    enum Page: Hashable { case selection, look }

    @ObservedObject var document: ProjectDocument
    let editor: TimelineEditor
    @State private var page = Page.selection

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.tapeDisplay(17))
                    .foregroundStyle(Tape.ink)
                    .tracking(1)
                    .lineLimit(1)
                Spacer()
                ModuleTag(text: tag)
            }
            KeyPicker(selection: $page, options: [(.selection, String(localized: "Auswahl")), (.look, String(localized: "Gestaltung"))])
            ScrollView {
                Group {
                    if page == .look {
                        LookInspector(document: document, editor: editor)
                    } else if let transition = editor.selectedTransition {
                        TransitionInspector(document: document, editor: editor, transition: transition)
                    } else if let zoom = editor.selectedZoom {
                        ZoomInspector(editor: editor, zoom: zoom)
                    } else if let annotation = editor.selectedAnnotation {
                        AnnotationInspector(editor: editor, annotation: annotation)
                            .id(annotation.id)
                    } else if !editor.selectedClips.isEmpty {
                        ClipInspector(editor: editor, clips: editor.selectedClips)
                    } else {
                        EmptyInspector()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        // Wer etwas in der Timeline anklickt, will dessen Eigenschaften sehen.
        .onChange(of: editor.selection) { if !editor.selection.isEmpty { page = .selection } }
        .onChange(of: editor.selectedTransitionID) { if editor.selectedTransitionID != nil { page = .selection } }
        .onChange(of: editor.selectedZoomID) { if editor.selectedZoomID != nil { page = .selection } }
        .onChange(of: editor.selectedAnnotationID) { if editor.selectedAnnotationID != nil { page = .selection } }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxHeight: .infinity, alignment: .top)
        .modulePanel()
    }

    private var title: String {
        if page == .look { return String(localized: "Gestaltung") }
        if editor.selectedTransition != nil { return String(localized: "Übergang") }
        if editor.selectedZoom != nil { return String(localized: "Zoom") }
        if let annotation = editor.selectedAnnotation { return annotation.kindTitle }
        let count = editor.selectedClips.count
        return switch count {
        case 0: String(localized: "Inspektor")
        case 1: String(localized: "Clip")
        default: String(localized: "\(count) Clips")
        }
    }

    private var tag: String {
        if page == .look { return String(localized: "MODUL 04") }
        if editor.selectedTransition != nil { return String(localized: "MODUL 02") }
        if editor.selectedZoom != nil { return String(localized: "MODUL 03") }
        if editor.selectedAnnotation != nil { return String(localized: "MODUL 05") }
        return editor.selectedClips.isEmpty ? String(localized: "BEREIT") : String(localized: "MODUL 01")
    }
}

/// Abschnitt im Modul: eingelassene Platte mit Beschriftung.
private struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).caseLabel(11)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .trayPanel(cornerRadius: 12, color: Tape.bezel)
    }
}

/// Beschriftung links, Wert als kleine LCD-Anzeige rechts.
private struct ValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title).caseLabel(10, color: Tape.ink)
            Spacer(minLength: 8)
            Text(value)
                .font(.tapeLCD(20))
                .foregroundStyle(Tape.phosphor)
                .phosphorGlow()
                .monospacedDigit()
                .padding(.horizontal, 8)
                .frame(minWidth: 44, alignment: .trailing)
                .lcdScreen(cornerRadius: 4, border: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyInspector: View {
    private static let shortcuts = [
        ("S", String(localized: "Am Playhead teilen")),
        ("⌫", String(localized: "Löschen")),
        ("⇧⌫", String(localized: "Löschen, Lücke schließen")),
        ("I  O", String(localized: "Bereich markieren")),
        ("⌘R", String(localized: "Geschwindigkeit")),
        ("⌘T", String(localized: "Überblenden")),
        ("Z", String(localized: "Zoom setzen")),
        ("J K L", String(localized: "Spulen")),
        ("⌘E", String(localized: "Exportieren")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("KEINE AUSWAHL")
                .font(.tapeLCD(26))
                .foregroundStyle(Tape.phosphor)
                .phosphorGlow()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .lcdScreen(cornerRadius: 8)
            Text("Clip, Übergang, Zoom oder Einblendung in der Timeline anklicken. Mehrere Clips mit ⇧ oder per Rahmen auswählen. Hintergrund, Cursor und Kamera unter „Gestaltung“.")
                .font(.tapeMono(11))
                .foregroundStyle(Tape.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            InspectorSection(title: String(localized: "Tasten")) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    ForEach(Self.shortcuts, id: \.0) { key, action in
                        GridRow {
                            Text(key)
                                .font(.tapeMono(11, weight: .semibold))
                                .foregroundStyle(Tape.ink)
                                .padding(.horizontal, 6)
                                .frame(minWidth: 40, minHeight: 20)
                                .background(LinearGradient(colors: [Tape.keyTop, Tape.keyBottom], startPoint: .top,
                                                           endPoint: .bottom), in: RoundedRectangle(cornerRadius: 4))
                                .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Tape.keyEdge, lineWidth: 1) }
                                .background { RoundedRectangle(cornerRadius: 4).fill(Tape.keyEdge).offset(y: 2) }
                            Text(action)
                                .font(.tapeMono(11))
                                .foregroundStyle(Tape.ink)
                        }
                    }
                }
            }
        }
    }
}

private struct ClipInspector: View {
    let editor: TimelineEditor
    let clips: [Clip]

    static let speedPresets = [0.25, 0.5, 1, 1.5, 2, 4, 8, 16]

    private var audioClips: [Clip] {
        clips.filter { editor.timeline.track(containing: $0.id)?.kind == .audio }
    }

    private var tracks: [Track] {
        let ids = Set(clips.compactMap { editor.timeline.track(containing: $0.id)?.id })
        return editor.timeline.tracks.filter { ids.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSection(title: String(localized: "Band")) {
                // Spanne vom frühesten Anfang bis zum spätesten Ende: Parallele Spuren zählen nur einmal.
                ValueRow(title: String(localized: "Dauer"), value: TimeFormatting.timecode(
                    (clips.map(\.timelineEnd).max() ?? .zero) - (clips.map(\.timelineStart).min() ?? .zero)))
                ValueRow(title: String(localized: "Geschwindigkeit"), value: TimelineCanvas.formatSpeed(speed))
                KeyPicker(selection: Binding(get: { speed }, set: { editor.setSpeed($0) }),
                          options: Self.speedPresets.map { ($0, TimelineCanvas.formatSpeed($0)) }, columns: 4)
                Button { editor.showSpeedSheet() } label: {
                    Label("Abschnitt beschleunigen …", systemImage: "gauge.with.dots.needle.67percent")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                if clips.contains(where: { $0.linkGroupID != nil }) {
                    Button { editor.unlinkSelection() } label: {
                        Label("Verknüpfung aufheben", systemImage: "personalhotspot.slash").frame(maxWidth: .infinity)
                    }
                } else if clips.count >= 2 {
                    Button { editor.linkSelection() } label: {
                        Label("Verknüpfen", systemImage: "link").frame(maxWidth: .infinity)
                    }
                }
            }

            if !audioClips.isEmpty {
                InspectorSection(title: String(localized: "Ton")) {
                    Toggle("Stumm", isOn: Binding(get: { audioClips.allSatisfy(\.isMuted) }, set: { muted in
                        editor.perform(muted ? String(localized: "Clip stummschalten") : String(localized: "Clip-Stummschaltung aufheben")) { timeline in
                            timeline.updateClips(Set(audioClips.map(\.id))) { $0.isMuted = muted }
                        }
                    }))
                    LiveSlider(title: String(localized: "Lautstärke"), value: Double(audioClips[0].volume), range: 0...2,
                               format: { $0.formatted(.percent.precision(.fractionLength(0))) },
                               editor: editor, actionName: String(localized: "Lautstärke ändern")) { timeline, value in
                        timeline.updateClips(Set(audioClips.map(\.id))) { $0.volume = Float(value) }
                    }
                }
            }

            InspectorSection(title: String(localized: "Blenden")) {
                fadeSlider(String(localized: "Blende: Einblenden"), value: clips[0].fadeIn.seconds) { $0.fadeIn = $1 }
                fadeSlider(String(localized: "Blende: Ausblenden"), value: clips[0].fadeOut.seconds) { $0.fadeOut = $1 }
            }

            InspectorSection(title: String(localized: "Spur")) {
                ForEach(tracks) { track in
                    Toggle(track.kind == .video ? String(localized: "\(track.title) ausblenden") : String(localized: "\(track.title) stumm"),
                           isOn: Binding(get: { track.isMuted }, set: { muted in
                        editor.perform(muted ? String(localized: "Stummschalten") : String(localized: "Stummschaltung aufheben")) { timeline in
                            timeline.updateTrack(track.id) { $0.isMuted = muted }
                        }
                    }))
                    if track.kind == .audio {
                        LiveSlider(title: String(localized: "Pegel \(track.title)"), value: Double(track.volume), range: 0...2,
                                   format: { $0.formatted(.percent.precision(.fractionLength(0))) },
                                   editor: editor, actionName: String(localized: "Spurlautstärke ändern")) { timeline, value in
                            timeline.updateTrack(track.id) { $0.volume = Float(value) }
                        }
                    }
                }
            }
        }
        .toggleStyle(.tapeSwitch)
        .buttonStyle(.key)
        .foregroundStyle(Tape.ink)
    }

    /// Gemeinsamer Wert der Auswahl; bei unterschiedlichen Werten der des ersten Clips.
    private var speed: Double { clips[0].speed }

    private func fadeSlider(_ title: String, value: Double, apply: @escaping (inout Clip, RationalTime) -> Void) -> some View {
        let ids = Set(clips.map(\.id))
        return LiveSlider(title: title, value: value, range: 0...3, format: TimeFormatting.seconds,
                          editor: editor, actionName: String(localized: "\(title) ändern")) { timeline, value in
            // Auf 1/100 s gerundet, damit die gespeicherten Werte glatt bleiben.
            let time = RationalTime(value: Int64((value * 100).rounded()), timescale: 100)
            timeline.updateClips(ids) { apply(&$0, min(time, $0.timelineDuration)) }
        }
    }
}

private struct TransitionInspector: View {
    @ObservedObject var document: ProjectDocument
    let editor: TimelineEditor
    let transition: Transition

    /// Tatsächlich gespielte Dauer; kürzer als gewünscht, wenn nicht genug Material da ist.
    private var playedDuration: RationalTime? {
        CompositionPlan.playableDuration(of: transition, in: document.project.timeline,
                                         assetDurations: document.project.assetDurations)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSection(title: String(localized: "Art")) {
                KeyPicker(selection: Binding(get: { transition.kind }, set: { kind in
                    editor.perform(String(localized: "Übergang ändern")) { EditCommands.updateTransition(&$0, transition.id) { $0.kind = kind } }
                }), options: Transition.Kind.allCases.map { ($0, $0.title) })
            }
            InspectorSection(title: String(localized: "Dauer")) {
                LiveSlider(title: String(localized: "Länge"), value: transition.duration.seconds, range: 0.1...3, format: TimeFormatting.seconds,
                           editor: editor, actionName: String(localized: "Übergangsdauer ändern")) { timeline, value in
                    let time = RationalTime(value: Int64((value * 100).rounded()), timescale: 100)
                    EditCommands.setTransitionDuration(&timeline, transition.id, to: time)
                }
                if editor.timeline.companionTransitionIDs(of: transition.id).count > 1 {
                    Text("Gilt auch für die verknüpften Spuren.")
                        .font(.tapeMono(11))
                        .foregroundStyle(Tape.inkSoft)
                }
                if let playedDuration, playedDuration < transition.duration {
                    warning(String(localized: "Material nur für \(playedDuration.seconds.formatted(.number.precision(.fractionLength(2)))) s"))
                } else if playedDuration == nil {
                    warning(String(localized: "Kein Material für den Übergang vorhanden"))
                }
            }
            Button(role: .destructive) { editor.deleteSelection(ripple: false) } label: {
                Label("Übergang löschen", systemImage: "trash")
                    .foregroundStyle(Color(hex: 0x9E2614))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.key)
        }
    }

    private func warning(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.tapeMono(11, weight: .semibold))
            .foregroundStyle(Tape.orangeInk)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Fader, der beim Ziehen sofort wirkt und erst beim Loslassen einen Undo-Schritt anlegt.
private struct LiveSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let editor: TimelineEditor
    let actionName: String
    let apply: (inout Project, Double) -> Void

    init(title: String, value: Double, range: ClosedRange<Double>, format: @escaping (Double) -> String,
         editor: TimelineEditor, actionName: String, apply: @escaping (inout Timeline, Double) -> Void) {
        self.init(title: title, value: value, range: range, format: format, editor: editor, actionName: actionName,
                  project: { apply(&$0.timeline, $1) })
    }

    init(title: String, value: Double, range: ClosedRange<Double>, format: @escaping (Double) -> String,
         editor: TimelineEditor, actionName: String, look apply: @escaping (inout Look, Double) -> Void) {
        self.init(title: title, value: value, range: range, format: format, editor: editor, actionName: actionName,
                  project: { apply(&$0.look, $1) })
    }

    private init(title: String, value: Double, range: ClosedRange<Double>, format: @escaping (Double) -> String,
                 editor: TimelineEditor, actionName: String, project apply: @escaping (inout Project, Double) -> Void) {
        self.title = title
        self.value = value
        self.range = range
        self.format = format
        self.editor = editor
        self.actionName = actionName
        self.apply = apply
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ValueRow(title: title, value: format(value))
            Fader(value: Binding(get: { value }, set: { newValue in editor.document.liveUpdate { apply(&$0, newValue) } }),
                  range: range) { isEditing in
                if !isEditing { editor.endLiveChange(actionName) }
            }
            .accessibilityLabel(title)
        }
    }
}

extension Timeline {
    mutating func updateTrack(_ id: Track.ID, _ change: (inout Track) -> Void) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        change(&tracks[index])
    }
}

private struct ZoomInspector: View {
    let editor: TimelineEditor
    let zoom: ZoomRegion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSection(title: String(localized: "Zoom")) {
                ValueRow(title: String(localized: "Dauer"), value: TimeFormatting.timecode(zoom.duration))
                LiveSlider(title: String(localized: "Vergrößerung"), value: zoom.scale, range: ZoomRegion.scaleRange,
                           format: TimelineCanvas.formatSpeed, editor: editor, actionName: String(localized: "Zoom ändern")) { timeline, value in
                    ZoomCommands.update(&timeline, zoom.id) { $0.scale = (value * 20).rounded() / 20 }
                }
                if zoom.isAutomatic {
                    Text("Automatisch erzeugt. Nach einer Änderung bleibt er auch beim nächsten Auto-Zoom erhalten.")
                        .font(.tapeMono(11))
                        .foregroundStyle(Tape.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            InspectorSection(title: String(localized: "Blickpunkt")) {
                KeyPicker(selection: Binding(get: { zoom.focus }, set: { focus in
                    editor.updateZoom(String(localized: "Zoom ändern"), zoom.id) { $0.focus = focus }
                }), options: ZoomRegion.Focus.allCases.map { ($0, $0.title) })
                if zoom.focus == .point {
                    FocusPad(point: CGPoint(x: zoom.pointX, y: zoom.pointY)) { point in
                        editor.liveChange { ZoomCommands.update(&$0, zoom.id) { $0.pointX = point.x; $0.pointY = point.y } }
                    } onEnd: {
                        editor.endLiveChange(String(localized: "Blickpunkt ändern"))
                    }
                    Text("Ins Feld klicken oder ziehen, um festzulegen, wohin gezoomt wird.")
                        .font(.tapeMono(11))
                        .foregroundStyle(Tape.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Die Kamera folgt dem Cursor weich und bleibt dabei immer im Bild.")
                        .font(.tapeMono(11))
                        .foregroundStyle(Tape.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(role: .destructive) { editor.deleteSelection(ripple: false) } label: {
                Label("Zoom löschen", systemImage: "trash")
                    .foregroundStyle(Color(hex: 0x9E2614))
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.key)
        .foregroundStyle(Tape.ink)
    }
}

/// Inhalt und Dauer einer Einblendung. Getippte Eingaben lassen sich hier endgültig maskieren.
private struct AnnotationInspector: View {
    let editor: TimelineEditor
    let annotation: Annotation
    @State private var draft = ""
    @State private var mask = AnnotationCommands.defaultMask
    @FocusState private var focus: Field?

    private enum Field { case content, mask }

    private static let durationRange = Annotation.minimumDuration.seconds...30

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch annotation.content {
            case .keys(let group): keysSection(group)
            case .text(let note): textSection(note)
            case .shape(let mark): shapeSection(mark)
            }
            InspectorSection(title: String(localized: "Anzeige")) {
                LiveSlider(title: String(localized: "Dauer"), value: annotation.duration.seconds, range: Self.durationRange,
                           format: { String(format: "%.1f s", $0) }, editor: editor,
                           actionName: String(localized: "Einblendungsdauer ändern")) { timeline, value in
                    AnnotationCommands.update(&timeline, annotation.id) { $0.duration = RationalTime(seconds: value) }
                }
                if editor.selectedPlacement == nil {
                    hint(String(localized: "Die Stelle dieser Einblendung ist herausgeschnitten, deshalb erscheint sie nicht im Video."))
                }
            }
            Button(role: .destructive) { editor.deleteSelection(ripple: false) } label: {
                Label("Einblendung löschen", systemImage: "trash")
                    .foregroundStyle(Color(hex: 0x9E2614))
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.key)
        .foregroundStyle(Tape.ink)
        .onAppear { draft = initialDraft }
        .onChange(of: focus) { old, new in
            editor.isEditingText = new != nil
            if old == .content { commitDraft() }
        }
        // Undo ändert den Inhalt, ohne dass das Feld davon erfährt.
        .onChange(of: initialDraft) { draft = initialDraft }
        .onDisappear {
            editor.isEditingText = false
            commitDraft()
        }
    }

    // MARK: Tasten

    private func keysSection(_ group: KeyGroup) -> some View {
        Group {
            InspectorSection(title: String(localized: "Eingabe")) {
                TextField("Tasten", text: $draft)
                    .textFieldStyle(PaperFieldStyle())
                    .focused($focus, equals: .content)
                    .onSubmit { commitDraft() }
                if group.isHidden {
                    hint(String(localized: "Ausgeblendet: Diese Eingabe erscheint nicht im Video. Ein neuer Text zeigt sie wieder."))
                }
                Button { editor.splitSelectedKeys() } label: {
                    Label("Am Playhead teilen", systemImage: "scissors").frame(maxWidth: .infinity)
                }
                .help("Trennt die Gruppe, damit sich nur ein Teil maskieren lässt")
            }
            InspectorSection(title: String(localized: "Passwort schützen")) {
                TextField("Maske", text: $mask)
                    .textFieldStyle(PaperFieldStyle())
                    .focused($focus, equals: .mask)
                HStack(spacing: 8) {
                    Button {
                        let mask = mask
                        editor.perform(String(localized: "Eingabe maskieren")) { AnnotationCommands.mask(&$0, annotation.id, with: mask) }
                        draft = mask
                    } label: {
                        Text("Maskieren").frame(maxWidth: .infinity)
                    }
                    .disabled(mask.isEmpty)
                    Button {
                        editor.perform(String(localized: "Eingabe ausblenden")) { AnnotationCommands.hide(&$0, annotation.id) }
                        draft = KeyGroup.hiddenSymbol
                    } label: {
                        Text("Ausblenden").frame(maxWidth: .infinity)
                    }
                    .disabled(group.isHidden)
                }
                hint(String(localized: "Das Original wird überschrieben. Nach dem Speichern und Schließen lässt es sich nicht zurückholen."))
            }
        }
    }

    // MARK: Text

    private func textSection(_ note: TextNote) -> some View {
        InspectorSection(title: String(localized: "Text")) {
            TextEditor(text: $draft)
                .font(.tapeMono(12))
                .foregroundStyle(Tape.ink)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 84)
                .background(Tape.paper, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Tape.line, lineWidth: 1) }
                .focused($focus, equals: .content)
            KeyPicker(selection: Binding(get: { note.size }, set: { size in
                updateText { $0.size = size }
            }), options: TextNote.Size.allCases.map { ($0, $0.title) })
            colorPicker(note.color) { color in updateText { $0.color = color } }
            Toggle("Mitzoomen", isOn: Binding(get: { note.followsZoom }, set: { isOn in
                updateText { note in
                    note.position = Self.converted(note.position, followsZoom: isOn, editor: editor)
                    note.followsZoom = isOn
                }
            }))
            .toggleStyle(.tapeSwitch)
            hint(String(localized: "In der Vorschau am Griff verschieben."))
        }
    }

    private func updateText(_ change: (inout TextNote) -> Void) {
        editor.perform(String(localized: "Text ändern")) { timeline in
            AnnotationCommands.update(&timeline, annotation.id) { annotation in
                guard case .text(var note) = annotation.content else { return }
                change(&note)
                annotation.content = .text(note)
            }
        }
    }

    // MARK: Symbol

    private func shapeSection(_ mark: ShapeMark) -> some View {
        InspectorSection(title: String(localized: "Symbol")) {
            KeyPicker(selection: Binding(get: { mark.kind }, set: { kind in
                updateShape { $0.kind = kind }
            }), options: ShapeMark.Kind.allCases.map { ($0, $0.title) }, columns: 2)
            colorPicker(mark.color) { color in updateShape { $0.color = color } }
            if mark.kind == .badge {
                Stepper(value: Binding(get: { mark.number }, set: { number in
                    updateShape { $0.number = number }
                }), in: 1...99) {
                    ValueRow(title: String(localized: "Zahl"), value: "\(mark.number)")
                }
            }
            Toggle("Mitzoomen", isOn: Binding(get: { mark.followsZoom }, set: { isOn in
                updateShape { mark in
                    mark.start = Self.converted(mark.start, followsZoom: isOn, editor: editor)
                    mark.end = Self.converted(mark.end, followsZoom: isOn, editor: editor)
                    mark.followsZoom = isOn
                }
            }))
            .toggleStyle(.tapeSwitch)
            hint(String(localized: "In der Vorschau an den Griffen setzen. Mit „Mitzoomen“ bleibt das Symbol beim Zoomen auf derselben Bildstelle."))
        }
    }

    private func updateShape(_ change: (inout ShapeMark) -> Void) {
        editor.perform(String(localized: "Symbol ändern")) { timeline in
            AnnotationCommands.update(&timeline, annotation.id) { annotation in
                guard case .shape(var mark) = annotation.content else { return }
                change(&mark)
                annotation.content = .shape(mark)
            }
        }
    }

    /// Mitzoomende Punkte beziehen sich auf die Aufnahme, feste auf die Ausgabe. So bleibt die
    /// Einblendung beim Umschalten an ihrem Platz.
    private static func converted(_ point: AnnotationPoint, followsZoom: Bool, editor: TimelineEditor) -> AnnotationPoint {
        guard let scene = editor.playback?.current?.scene,
              let size = editor.playback?.current?.videoComposition?.renderSize
        else { return point }
        let layout = SceneLayout(output: size, sourceSize: scene.sourceSize, look: scene.look)
        return layout.annotationPoint(for: layout.point(for: point, followsZoom: !followsZoom), followsZoom: followsZoom).clamped()
    }

    // MARK: Hilfen

    private func colorPicker(_ color: AnnotationColor, onChange: @escaping (AnnotationColor) -> Void) -> some View {
        KeyPicker(selection: Binding(get: { color }, set: onChange),
                  options: AnnotationColor.allCases.map { ($0, $0.title) }, columns: 3)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.tapeMono(11))
            .foregroundStyle(Tape.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var initialDraft: String {
        switch annotation.content {
        case .keys(let group): group.displayText
        case .text(let note): note.text
        case .shape: ""
        }
    }

    /// Jede Änderung baut die Composition neu auf, deshalb erst beim Verlassen des Felds übernehmen.
    private func commitDraft() {
        let text = draft
        guard text != initialDraft else { return }
        switch annotation.content {
        case .keys:
            editor.perform(String(localized: "Tasten ändern")) { AnnotationCommands.setKeys(&$0, annotation.id, text: text) }
        case .text:
            updateText { $0.text = text }
        case .shape:
            break
        }
    }
}

/// Kleines LCD-Feld, in dem man den festen Blickpunkt eines Zooms setzt.
private struct FocusPad: View {
    let point: CGPoint
    let onChange: (CGPoint) -> Void
    let onEnd: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Path { path in
                    for fraction in [0.25, 0.5, 0.75] {
                        path.move(to: CGPoint(x: size.width * fraction, y: 0))
                        path.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                        path.move(to: CGPoint(x: 0, y: size.height * fraction))
                        path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                    }
                }
                .stroke(Tape.phosphorDim.opacity(0.4), lineWidth: 1)
                Circle()
                    .strokeBorder(Tape.phosphor, lineWidth: 2)
                    .frame(width: 16, height: 16)
                    .phosphorGlow()
                    .offset(x: point.x * size.width - 8, y: point.y * size.height - 8)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                onChange(CGPoint(x: min(max(drag.location.x / size.width, 0), 1),
                                 y: min(max(drag.location.y / size.height, 0), 1)))
            }.onEnded { _ in onEnd() })
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .lcdScreen(cornerRadius: 6, border: 2)
        .accessibilityLabel("Blickpunkt")
    }
}

/// Hintergrund, Rahmen, Cursor, Kamera und Einblendungen für das ganze Bild.
private struct LookInspector: View {
    @ObservedObject var document: ProjectDocument
    let editor: TimelineEditor
    @State private var colorCommit: Task<Void, Never>?
    @State private var importError: String?

    private var look: Look { document.project.look }
    private var hasCamera: Bool { document.project.assets.contains { $0.role == .camera } }
    private var hasCursorData: Bool { editor.hasCursorData }

    private static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            InspectorSection(title: String(localized: "Format")) {
                KeyPicker(selection: lookBinding(\.aspect, String(localized: "Format ändern")),
                          options: Look.Aspect.allCases.map { ($0, $0.title) })
            }

            InspectorSection(title: String(localized: "Hintergrund")) {
                KeyPicker(selection: lookBinding(\.background.kind, String(localized: "Hintergrund ändern")),
                          options: Background.Kind.allCases.map { ($0, $0.title) })
                switch look.background.kind {
                case .none:
                    EmptyView()
                case .color:
                    ColorPicker("Farbe", selection: colorBinding)
                        .font(.tapeMono(11, weight: .semibold))
                case .gradient:
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                        ForEach(Background.Gradient.presets, id: \.self) { gradient in
                            Button {
                                editor.performLook(String(localized: "Verlauf ändern")) { $0.background.gradient = gradient }
                            } label: {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(LinearGradient(colors: [Color(gradient.from), Color(gradient.to)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(height: 26)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 5)
                                            .strokeBorder(gradient == look.background.gradient ? Tape.pink : Tape.line,
                                                          lineWidth: gradient == look.background.gradient ? 3 : 1)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                case .image:
                    HStack {
                        Text(look.background.imagePath.map { ($0 as NSString).lastPathComponent } ?? String(localized: "Kein Bild"))
                            .font(.tapeMono(11))
                            .foregroundStyle(Tape.inkSoft)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 6)
                        Button("Wählen …", action: chooseImage)
                            .disabled(editor.packageURL == nil)
                    }
                    if let importError {
                        Text(importError).font(.tapeMono(11)).foregroundStyle(Tape.orangeInk)
                    }
                }
                LiveSlider(title: String(localized: "Abstand"), value: look.padding, range: Look.paddingRange, format: Self.percent,
                           editor: editor, actionName: String(localized: "Abstand ändern"), look: { $0.padding = ($1 * 200).rounded() / 200 })
                LiveSlider(title: String(localized: "Ecken"), value: look.cornerRadius, range: Look.cornerRadiusRange,
                           format: { ($0 * 1000).formatted(.number.precision(.fractionLength(0))) },
                           editor: editor, actionName: String(localized: "Ecken ändern"), look: { $0.cornerRadius = ($1 * 1000).rounded() / 1000 })
                LiveSlider(title: String(localized: "Schatten"), value: look.shadow, range: 0...1, format: Self.percent,
                           editor: editor, actionName: String(localized: "Schatten ändern"), look: { $0.shadow = ($1 * 100).rounded() / 100 })
            }

            InspectorSection(title: String(localized: "Cursor")) {
                Toggle("Cursor zeichnen", isOn: lookBinding(\.cursor.isVisible, String(localized: "Cursor ein- oder ausblenden")))
                    .disabled(!hasCursorData)
                if !hasCursorData {
                    note(String(localized: "Für diese Aufnahme gibt es keine Cursor-Daten."))
                } else if look.cursor.isVisible {
                    LiveSlider(title: String(localized: "Größe"), value: look.cursor.scale, range: CursorStyle.scaleRange,
                               format: TimelineCanvas.formatSpeed, editor: editor, actionName: String(localized: "Cursorgröße ändern"),
                               look: { $0.cursor.scale = ($1 * 10).rounded() / 10 })
                    LiveSlider(title: String(localized: "Glättung"), value: look.cursor.smoothing, range: 0...1, format: Self.percent,
                               editor: editor, actionName: String(localized: "Glättung ändern"),
                               look: { $0.cursor.smoothing = ($1 * 20).rounded() / 20 })
                    Toggle("Klicks zeigen", isOn: lookBinding(\.cursor.highlightsClicks, String(localized: "Klicks ein- oder ausblenden")))
                }
            }

            if hasCamera {
                InspectorSection(title: String(localized: "Kamera")) {
                    KeyPicker(selection: lookBinding(\.camera.corner, String(localized: "Kameraposition ändern")),
                              options: CameraStyle.Corner.allCases.map { ($0, $0.title) }, columns: 2)
                    KeyPicker(selection: lookBinding(\.camera.shape, String(localized: "Kameraform ändern")),
                              options: CameraStyle.Shape.allCases.map { ($0, $0.title) })
                    LiveSlider(title: String(localized: "Größe"), value: look.camera.size, range: CameraStyle.sizeRange, format: Self.percent,
                               editor: editor, actionName: String(localized: "Kameragröße ändern"),
                               look: { $0.camera.size = ($1 * 100).rounded() / 100 })
                    note(String(localized: "Ausblenden über das Auge an der Spur „Kamera“."))
                }
            }

            InspectorSection(title: String(localized: "Einblendungen")) {
                Toggle("Tasten zeigen", isOn: lookBinding(\.showsKeystrokes, String(localized: "Tasten ein- oder ausblenden")))
                if look.showsKeystrokes, !editor.hasKeystrokes {
                    note(String(localized: "In dieser Aufnahme wurden keine Tasten aufgezeichnet."))
                }
            }

            HStack(spacing: 8) {
                Button { editor.performLook(String(localized: "Standard-Gestaltung")) { $0 = Self.standardLook(keeping: $0) } } label: {
                    Text("Standard").frame(maxWidth: .infinity)
                }
                Button { editor.performLook(String(localized: "Ohne Gestaltung")) { $0 = Self.neutralLook(keeping: $0) } } label: {
                    Text("Schlicht").frame(maxWidth: .infinity)
                }
            }
        }
        .toggleStyle(.tapeSwitch)
        .buttonStyle(.key)
        .foregroundStyle(Tape.ink)
    }

    /// Standard, aber Cursor und Kamera bleiben, wie sie für diese Aufnahme eingestellt sind.
    private static func standardLook(keeping current: Look) -> Look {
        var look = Look.standard
        look.cursor.isVisible = current.cursor.isVisible
        look.camera = current.camera
        return look
    }

    private static func neutralLook(keeping current: Look) -> Look {
        var look = Look.neutral
        look.cursor = current.cursor
        look.camera = current.camera
        look.showsKeystrokes = current.showsKeystrokes
        return look
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.tapeMono(11))
            .foregroundStyle(Tape.inkSoft)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func lookBinding<Value: Equatable>(_ keyPath: WritableKeyPath<Look, Value>, _ actionName: String) -> Binding<Value> {
        Binding(get: { look[keyPath: keyPath] }, set: { value in
            editor.performLook(actionName) { $0[keyPath: keyPath] = value }
        })
    }

    /// Der Farbwähler meldet fortlaufend; ein Undo-Schritt entsteht erst, wenn er kurz ruht.
    private var colorBinding: Binding<Color> {
        Binding(get: { Color(look.background.color) }, set: { color in
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            editor.liveLookChange {
                $0.background.color = RGBColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
            }
            colorCommit?.cancel()
            colorCommit = Task {
                try? await Task.sleep(for: .milliseconds(600))
                if !Task.isCancelled { editor.endLiveChange(String(localized: "Hintergrundfarbe ändern")) }
            }
        })
    }

    private func chooseImage() {
        guard let packageURL = editor.packageURL else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = String(localized: "Verwenden")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let name = "background-\(UUID().uuidString.prefix(8)).\(url.pathExtension.isEmpty ? "png" : url.pathExtension)"
            let path = try document.addFile(data, named: name, toPackageAt: packageURL)
            importError = nil
            editor.performLook(String(localized: "Hintergrundbild wählen")) { $0.background.imagePath = path }
        } catch {
            importError = String(localized: "Das Bild konnte nicht übernommen werden: \(error.localizedDescription)")
        }
    }
}

extension Color {
    init(_ color: RGBColor) {
        self.init(.sRGB, red: color.red, green: color.green, blue: color.blue)
    }
}
