import AVFoundation
import SwiftUI

/// Dokumentfenster im Tapedeck-Look: oben Kopfleiste, darunter Monitor und Inspector,
/// dann Transportleiste und Timeline.
struct EditorView: View {
    @ObservedObject var document: ProjectDocument
    let fileURL: URL?
    @Environment(\.undoManager) private var undoManager
    @State private var playback: PlaybackController?
    @State private var editor: TimelineEditor?
    @State private var exporter: ExportController?

    var body: some View {
        VStack(spacing: 12) {
            EditorHeader(title: fileURL?.deletingPathExtension().lastPathComponent ?? String(localized: "Unbenannt"),
                         duration: document.project.timeline.duration, playback: playback, exporter: exporter,
                         fileURL: fileURL, undoManager: undoManager)
            HStack(alignment: .top, spacing: 14) {
                MonitorView(playback: playback, editor: editor, aspectRatio: videoAspectRatio)
                if let editor {
                    InspectorView(document: document, editor: editor)
                        .frame(width: 300)
                }
            }
            .frame(maxHeight: .infinity)
            if let playback {
                TransportDeck(playback: playback, editor: editor)
            }
            if let editor {
                TimelinePanel(document: document, editor: editor, playback: playback)
                    .frame(height: TimelineMetrics.totalHeight(of: document.project.timeline) + TimelinePanel.chromeHeight)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, 8)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 1000, minHeight: 720)
        .background(Tape.casing)
        .preferredColorScheme(.light)
        .sheet(isPresented: Binding(get: { editor?.isSpeedSheetPresented ?? false },
                                    set: { editor?.isSpeedSheetPresented = $0 })) {
            if let editor, let range = editor.speedTargetRange {
                SpeedSheet(editor: editor, range: range)
            }
        }
        .focusedSceneValue(\.playback, playback)
        .sheet(isPresented: Binding(get: { exporter?.isSheetPresented ?? false },
                                    set: { exporter?.isSheetPresented = $0 })) {
            if let exporter {
                ExportSheet(document: document, exporter: exporter, built: playback?.current,
                            defaultFileName: fileURL?.deletingPathExtension().lastPathComponent ?? "Export")
            }
        }
        .focusedSceneValue(\.timelineEditor, editor)
        .focusedSceneValue(\.exportController, exporter)
        .task(id: fileURL) {
            playback?.invalidate()
            let playback = fileURL.map(PlaybackController.init(packageURL:))
            playback?.update(with: document.project)
            self.playback = playback

            let editor = TimelineEditor(document: document, packageURL: fileURL)
            editor.playback = playback
            editor.undoManager = undoManager
            self.editor = editor

            exporter?.cancel()
            exporter = fileURL.map(ExportController.init(packageURL:))
        }
        .onChange(of: undoManager) { editor?.undoManager = undoManager }
        .onChange(of: document.project.timeline) { playback?.update(with: document.project) }
        .onChange(of: document.project.assets) { playback?.update(with: document.project) }
        .onChange(of: document.project.look) { playback?.update(with: document.project) }
        .onChange(of: playback?.isPlaying) { _, isPlaying in
            // Beim Anhalten den Playhead merken, damit er mit dem Projekt gesichert wird.
            if isPlaying == false, let playback { savePlayhead(playback) }
        }
        .onDisappear {
            if let playback { savePlayhead(playback) }
            playback?.invalidate()
            exporter?.cancel()
        }
    }

    /// Seitenverhältnis der Ausgabe, damit der Monitor das Bild ohne schwarze Ränder umschließt.
    private var videoAspectRatio: CGFloat {
        let size = SceneLayout.renderSize(source: CompositionBuilder.sourceSize(for: document.project),
                                          aspect: document.project.look.aspect)
        guard size.width > 0, size.height > 0 else { return 16 / 9 }
        return size.width / size.height
    }

    private func savePlayhead(_ playback: PlaybackController) {
        document.updateEditorState { $0.playhead = playback.currentTime }
    }
}

/// Kopfleiste: Finder, Info, LCD mit Projektname, Rückgängig/Wiederholen und Export.
private struct EditorHeader: View {
    let title: String
    let duration: RationalTime
    let playback: PlaybackController?
    let exporter: ExportController?
    let fileURL: URL?
    let undoManager: UndoManager?

    var body: some View {
        HStack(spacing: 8) {
            // Platz für die Fensterknöpfe des Systems
            Color.clear.frame(width: 62, height: 1)
            Button {
                if let fileURL { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
            } label: {
                Image(systemName: "folder")
            }
            .help("Im Finder zeigen")
            .disabled(fileURL == nil)
            AboutButton()

            Spacer(minLength: 12)
            nameplate
            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Button { undoManager?.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help(undoManager?.undoMenuItemTitle ?? String(localized: "Rückgängig"))
                    .disabled(undoManager?.canUndo != true)
                Button { undoManager?.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .help(undoManager?.redoMenuItemTitle ?? String(localized: "Wiederholen"))
                    .disabled(undoManager?.canRedo != true)
            }
            if let exporter {
                ExportStatusView(exporter: exporter)
                Button {
                    exporter.isSheetPresented = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .padding(.horizontal, 6)
                        .frame(height: 34)
                }
                .buttonStyle(.orangeKey)
                .help("Exportieren (⌘E)")
            }
        }
        .buttonStyle(.key)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Tape.rim).frame(height: 2).padding(.horizontal, -16)
        }
    }

    /// LCD wie das Bandetikett: Name, Länge und Bildrate.
    private var nameplate: some View {
        HStack(spacing: 12) {
            if exporter?.isRunning == true { BlinkingDot() }
            Text(title.uppercased())
                .font(.tapeLCD(24))
                .foregroundStyle(Tape.phosphor)
                .phosphorGlow()
                .tracking(1)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(details)
                .font(.tapeLCD(18))
                .foregroundStyle(Tape.phosphorDim)
                .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 3)
        .frame(minWidth: 280, maxWidth: 560)
        .lcdScreen(cornerRadius: 8)
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts = [Duration.seconds(duration.seconds).formatted(.time(pattern: .minuteSecond))]
        if let frameDuration = playback?.current?.videoComposition?.frameDuration, frameDuration.seconds > 0 {
            parts.append("\(Int((1 / frameDuration.seconds).rounded()))FPS")
        }
        return "· " + parts.joined(separator: " · ")
    }
}

/// Vorschau in einem schmalen Gehäuse. Ein Klick ins Bild startet oder stoppt die Wiedergabe.
private struct MonitorView: View {
    let playback: PlaybackController?
    let editor: TimelineEditor?
    let aspectRatio: CGFloat
    @State private var osd: (symbol: String, text: String)?
    @State private var lastRate: Float?

    var body: some View {
        screen
            .frame(minWidth: 320, minHeight: 180)
            .padding(8)
            .background {
                let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
                shape.fill(Tape.bezel)
                    .overlay { shape.inset(by: 2).stroke(Color(hex: 0xE8E0C9), lineWidth: 3)
                        .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)) }
                    .overlay { shape.inset(by: 3).stroke(Color(hex: 0xA39980), lineWidth: 6)
                        .mask(LinearGradient(colors: [.clear, .white], startPoint: .center, endPoint: .bottom)) }
                    .overlay { shape.strokeBorder(Tape.line, lineWidth: 2) }
                    .background { shape.fill(Tape.edge).offset(y: 5) }
            }
            .padding(.bottom, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: playback?.rate) { await showOSD(for: playback?.rate) }
    }

    private var screen: some View {
        ZStack {
            Color.black
            if let playback {
                PreviewView(player: playback.player)
            } else {
                noSignal
            }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { playback?.togglePlayback() }
                .accessibilityHidden(true)
            if let editor, let playback {
                AnnotationOverlayView(editor: editor, playback: playback)
            }
            onScreenDisplay
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tape.edge))
    }

    private var noSignal: some View {
        VStack(spacing: 8) {
            Text("KEIN SIGNAL").font(.tapeLCD(40)).foregroundStyle(Tape.phosphor).phosphorGlow()
            Text("Das Projekt muss zuerst gesichert werden.").font(.tapeMono(12)).foregroundStyle(Tape.cream)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x1A2A6C))
    }

    /// Einblendungen wie bei einem Videorekorder: Laufwerkszustand kurz nach jeder Änderung,
    /// das Tempo eines beschleunigten Abschnitts, solange der Playhead darin steht.
    private var onScreenDisplay: some View {
        ZStack(alignment: .topLeading) {
            if let osd {
                Label(osd.text, systemImage: osd.symbol)
                    .labelStyle(OSDLabelStyle())
                    .padding(18)
                    .transition(.opacity)
            }
            if let speed = speedAtPlayhead {
                Text("TEMPO \(TimelineCanvas.formatSpeed(speed))")
                    .font(.tapeLCD(22))
                    .foregroundStyle(Tape.phosphor)
                    .phosphorGlow()
                    .padding(.horizontal, 8)
                    .background(Tape.lcd.opacity(0.8), in: RoundedRectangle(cornerRadius: 4))
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .topTrailing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: osd?.text)
    }

    private var speedAtPlayhead: Double? {
        guard let editor, let playback else { return nil }
        return editor.timeline.speedSegments.first { $0.range.contains(playback.currentTime) }?.speed
    }

    private func showOSD(for rate: Float?) async {
        // Beim Öffnen nichts einblenden, erst bei einer Änderung.
        defer { lastRate = rate }
        guard let rate, let lastRate, lastRate != rate else { return }
        osd = switch rate {
        case 0: ("pause.fill", String(localized: "PAUSE"))
        case 1: ("play.fill", "PLAY")
        case let rate where rate > 1: ("forward.fill", "\(Int(rate))×")
        default: ("backward.fill", "\(Int(-rate))×")
        }
        try? await Task.sleep(for: .seconds(2.5))
        if !Task.isCancelled { osd = nil }
    }
}

private struct OSDLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            configuration.icon.font(.system(size: 22, weight: .black))
            configuration.title.font(.tapeLCD(34))
        }
        .foregroundStyle(Tape.phosphor)
        .phosphorGlow()
        .shadow(color: .black, radius: 0, x: 2, y: 2)
    }
}

/// Transportleiste: Schere, Zählwerk, Laufwerkstasten, Pegel und Spulen.
private struct TransportDeck: View {
    let playback: PlaybackController
    let editor: TimelineEditor?

    var body: some View {
        HStack(spacing: 16) {
            Button { editor?.splitAtPlayhead() } label: {
                Image(systemName: "scissors").frame(width: 24, height: 32)
            }
            .help("Am Playhead teilen (S oder ⌘B)")
            .disabled(editor == nil)

            Spacer(minLength: 0)
            counter(TimeFormatting.timecode(playback.currentTime), color: Tape.phosphor)
                .phosphorGlow()
            HStack(spacing: 0) {
                transportKey("backward.end.fill", help: String(localized: "Zum Anfang (Pos1)"), width: 48) { playback.seek(to: .zero) }
                transportKey(playback.isPlaying ? "pause.fill" : "play.fill",
                             help: playback.isPlaying ? String(localized: "Pause (Leertaste)") : String(localized: "Wiedergabe (Leertaste)"), width: 62,
                             isOn: playback.isPlaying) { playback.togglePlayback() }
                transportKey("forward.end.fill", help: String(localized: "Zum Ende (Ende)"), width: 48) { playback.seek(to: playback.duration) }
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .background(Tape.ink, in: RoundedRectangle(cornerRadius: 10))
            counter(TimeFormatting.timecode(playback.duration), color: Tape.phosphorDim)
            Spacer(minLength: 0)

            if let errorMessage = playback.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tape.orangeInk)
                    .help(errorMessage)
            }
            if let editor {
                LevelMeter(level: editor.audioLevel(at: playback.currentTime))
            }
            Button { playback.shuttleForward() } label: {
                Text(rateText).font(.tapeLCD(24)).frame(minWidth: 30, minHeight: 32)
            }
            .accessibilityLabel("Schneller vorwärts")
            .help("Schneller vorwärts (L), anhalten mit K")
        }
        .buttonStyle(.key)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .trayPanel()
    }

    private var rateText: String {
        let rate = abs(playback.rate)
        return rate > 1 ? "\(Int(rate))×" : "1×"
    }

    private func counter(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.tapeLCD(30))
            .foregroundStyle(color)
            .tracking(2)
            .monospacedDigit()
            .padding(.horizontal, 14)
            .lcdScreen(cornerRadius: 8)
    }

    private func transportKey(_ symbol: String, help: String, width: CGFloat, isOn: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: width - 20, height: 34)
        }
        .buttonStyle(KeyButtonStyle(isOn: isOn, cornerRadius: 6))
        .help(help)
        .accessibilityLabel(String(help.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces))
    }
}

/// Pegelanzeige aus zwölf Segmenten.
private struct LevelMeter: View {
    let level: Double

    var body: some View {
        HStack(spacing: 10) {
            Text("Pegel").caseLabel(10, color: Tape.ink)
            HStack(spacing: 3) {
                ForEach(0..<12, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(color(for: index))
                        .opacity(Double(index) < level * 12 ? 1 : 0.2)
                        .frame(width: 6, height: 18)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Tape.lcd, in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Tape.line, lineWidth: 2) }
        }
        .padding(.bottom, 4)
        .accessibilityElement()
        .accessibilityLabel("Pegel")
        .accessibilityValue(level.formatted(.percent.precision(.fractionLength(0))))
    }

    private func color(for index: Int) -> Color {
        index < 7 ? Tape.phosphor : index < 10 ? Tape.yellow : Tape.red
    }
}

/// Das Bandlaufwerk: Werkzeugleiste, Spurköpfe und Timeline auf dunklem Grund.
private struct TimelinePanel: View {
    @ObservedObject var document: ProjectDocument
    let editor: TimelineEditor
    let playback: PlaybackController?

    /// Höhe von Werkzeugleiste, Trennlinie, Rand und Rollbalken über der Spurenhöhe.
    static let chromeHeight: CGFloat = 70

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 0) {
            TimelineToolbar(editor: editor, duration: document.project.timeline.duration)
            Rectangle().fill(Tape.deckLine).frame(height: 1)
            HStack(spacing: 0) {
                TrackHeaders(editor: editor, tracks: document.project.timeline.tracks)
                Rectangle().fill(Tape.deckLine).frame(width: 1)
                TimelineView(editor: editor, timeline: document.project.timeline, assets: document.project.assets,
                             selection: editor.selection, selectedTransitionID: editor.selectedTransitionID,
                             selectedZoomID: editor.selectedZoomID, selectedAnnotationID: editor.selectedAnnotationID,
                             rangeSelection: editor.rangeSelection,
                             playhead: playback?.currentTime ?? document.project.editorState.playhead,
                             isPlaying: playback?.isPlaying ?? false, pixelsPerSecond: editor.pixelsPerSecond,
                             isSnappingEnabled: editor.isSnappingEnabled)
            }
        }
        .padding(.vertical, 3)
        .background(Tape.deck)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Tape.line, lineWidth: 3) }
    }
}

private struct TimelineToolbar: View {
    @Bindable var editor: TimelineEditor
    let duration: RationalTime

    var body: some View {
        HStack(spacing: 8) {
            Button { editor.splitAtPlayhead() } label: { Image(systemName: "scissors") }
                .help("Am Playhead teilen (S oder ⌘B)")
            Button { editor.deleteSelection(ripple: false) } label: { Image(systemName: "trash") }
                .help("Löschen (⌫)")
                .disabled(!editor.canDelete)
            Button { editor.deleteSelection(ripple: true) } label: { Image(systemName: "arrow.left.to.line") }
                .help("Löschen und Lücke schließen (⇧⌫)")
                .disabled(editor.selection.isEmpty)
            separator
            Button { editor.linkSelection() } label: { Image(systemName: "link") }
                .help("Verknüpfen (⌘L)")
                .disabled(!editor.canLink)
            Button { editor.unlinkSelection() } label: { Image(systemName: "personalhotspot.slash") }
                .help("Verknüpfung aufheben (⇧⌘L)")
                .disabled(!editor.canUnlink)
            separator
            TransitionPalette(editor: editor)
            Button { editor.addZoomAtPlayhead() } label: { Image(systemName: "viewfinder") }
                .help("Zoom am Playhead oder im markierten Bereich (Z)")
            Button { editor.generateAutoZoom() } label: { Image(systemName: "wand.and.stars") }
                .help("Auto-Zoom aus den Klicks der Aufnahme (⌥⌘Z)")
                .disabled(!editor.canGenerateAutoZoom)
            Button { editor.showSpeedSheet() } label: { Image(systemName: "gauge.with.dots.needle.67percent") }
                .help("Geschwindigkeit des markierten Bereichs oder der Auswahl (⌘R)")
                .disabled(editor.speedTargetRange == nil)
            separator
            Button { editor.addText() } label: { Image(systemName: "text.bubble") }
                .help("Erklärungstext am Playhead einfügen (⇧⌘T)")
                .disabled(!editor.canAddAnnotation)
            Menu {
                ForEach(ShapeMark.Kind.allCases, id: \.self) { kind in
                    Button(kind.title) { editor.addShape(kind) }
                }
            } label: {
                Image(systemName: "arrow.up.right")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Symbol am Playhead einfügen")
            .disabled(!editor.canAddAnnotation)
            separator
            Toggle("Einrasten", isOn: $editor.isSnappingEnabled)
                .toggleStyle(.tapeSwitch)
                .textCase(.uppercase)
                .foregroundStyle(Tape.cream)
                .fixedSize()
                .help("An Playhead und Clipkanten einrasten (N; ctrl beim Ziehen kehrt es um)")

            Spacer(minLength: 8)
            Text(TimeFormatting.timecode(duration))
                .font(.tapeLCD(18))
                .foregroundStyle(Tape.phosphorDim)
                .monospacedDigit()
                .fixedSize()
                .padding(.horizontal, 8)
                .lcdScreen(cornerRadius: 4, border: 1)
                .help("Gesamtdauer der Timeline")
            separator
            Button { editor.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Verkleinern (⌘−)")
            Fader(value: Binding(get: { log(editor.pixelsPerSecond) }, set: { editor.setZoom(exp($0)) }),
                  range: log(TimelineEditor.zoomRange.lowerBound)...log(TimelineEditor.zoomRange.upperBound),
                  compact: true)
                .frame(minWidth: 50, maxWidth: 110)
                .accessibilityLabel("Zoom")
            Button { editor.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Vergrößern (⌘+)")
            Button { editor.zoomToFit() } label: { Image(systemName: "arrow.left.and.right.square") }
                .help("Ganze Timeline zeigen (⇧Z)")
        }
        .buttonStyle(.key)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var separator: some View {
        Rectangle().fill(Tape.deckLine).frame(width: 1, height: 22).padding(.horizontal, 2)
    }
}

/// Übergänge zum Ziehen auf einen Schnitt; ein Klick setzt sie am Schnitt beim Playhead.
private struct TransitionPalette: View {
    let editor: TimelineEditor

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Transition.Kind.allCases, id: \.self) { kind in
                // Kein Button: Der würde die Maus festhalten und das Ziehen verhindern.
                Label(kind.title, systemImage: kind == .crossfade ? "square.on.square" : "square.fill.on.square")
                    .labelStyle(.titleAndIcon)
                    .font(.tapeMono(11, weight: .bold))
                    .fixedSize()
                    .foregroundStyle(Color(hex: 0xFFFAF0))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(Tape.purple, in: RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Color(hex: 0xC3AAFF), lineWidth: 1.5) }
                    .background { RoundedRectangle(cornerRadius: 7).fill(.black).offset(y: 3) }
                    .padding(.bottom, 3)
                    .contentShape(Rectangle())
                    .onTapGesture { editor.addTransitionAtPlayhead(kind) }
                    .onDrag { NSItemProvider(object: (TimelineCanvas.transitionDragPrefix + kind.rawValue) as NSString) }
                    .help("Auf einen Schnitt in der Timeline ziehen oder klicken für den Schnitt am Playhead (\(kind == .crossfade ? "⌘T" : "⌥⌘T"))")
            }
        }
    }
}

/// Name und Stumm-/Ausblenden-Schalter je Spur, zeilengleich mit der Timeline.
private struct TrackHeaders: View {
    let editor: TimelineEditor
    let tracks: [Track]

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: TimelineMetrics.rulerHeight)
            Text("Bereich")
                .caseLabel(9, color: Tape.edge)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: TimelineMetrics.markerLaneHeight)
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Tape.teal)
                    .frame(width: 10, height: 10)
                Text("Zoom").caseLabel(11, color: Tape.cream)
                Spacer(minLength: 4)
                Button { editor.generateAutoZoom() } label: {
                    Text("AUTO")
                        .font(.tapeMono(9, weight: .bold))
                        .foregroundStyle(editor.canGenerateAutoZoom ? Tape.teal : Tape.deckLine)
                        .frame(width: 38, height: 18)
                        .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(Tape.deckLine) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!editor.canGenerateAutoZoom)
                .help("Zooms aus den Klicks der Aufnahme erzeugen; von Hand gesetzte bleiben erhalten")
            }
            .padding(.horizontal, 10)
            .frame(height: TimelineMetrics.zoomLaneHeight)
            laneHeader(String(localized: "Tasten"), color: Tape.yellow, height: TimelineMetrics.keyLaneHeight)
            laneHeader(String(localized: "Notizen"), color: Tape.purple, height: TimelineMetrics.noteLaneHeight)
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(track.kind == .video ? Tape.orange : Tape.phosphor)
                        .frame(width: 10, height: 10)
                    Text(track.title)
                        .caseLabel(11, color: Tape.cream)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(track.title)
                    Spacer(minLength: 4)
                    Button {
                        editor.perform(track.isMuted ? String(localized: "Stummschaltung aufheben") : String(localized: "Stummschalten")) { timeline in
                            timeline.updateTrack(track.id) { $0.isMuted.toggle() }
                        }
                    } label: {
                        Image(systemName: muteSymbol(for: track))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(track.isMuted ? Tape.red : Tape.rim)
                            .frame(width: 24, height: 18)
                            .overlay { RoundedRectangle(cornerRadius: 3).strokeBorder(track.isMuted ? Tape.red : Tape.deckLine) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(track.kind == .video ? String(localized: "Spur ausblenden") : String(localized: "Spur stummschalten"))
                }
                .padding(.horizontal, 10)
                .frame(height: TimelineMetrics.rowHeight(for: track.kind))
                .background(Color(nsColor: index % 2 == 0 ? .tapeDeckRowA : .tapeDeckRowB))
            }
            Spacer(minLength: 0)
        }
        .frame(width: TimelineMetrics.headerWidth)
    }

    private func laneHeader(_ title: String, color: Color, height: CGFloat) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(title).caseLabel(11, color: Tape.cream)
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .frame(height: height)
    }

    private func muteSymbol(for track: Track) -> String {
        switch (track.kind, track.isMuted) {
        case (.video, false): "eye"
        case (.video, true): "eye.slash"
        case (.audio, false): "speaker.wave.2"
        case (.audio, true): "speaker.slash"
        }
    }
}

extension FocusedValues {
    @Entry var playback: PlaybackController?
}

/// Menü „Wiedergabe“ mit den üblichen Tasten: Leertaste, J/K/L und Pfeiltasten.
struct PlaybackCommands: Commands {
    @FocusedValue(\.playback) private var playback
    @FocusedValue(\.timelineEditor) private var editor

    /// Einfache Tasten gehören dem Textfeld, solange man darin tippt.
    private var isTyping: Bool { editor?.isEditingText == true }

    var body: some Commands {
        CommandMenu("Wiedergabe") {
            Button(playback?.isPlaying == true ? String(localized: "Pause") : String(localized: "Wiedergabe")) { playback?.togglePlayback() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(isTyping)
            Divider()
            Button("Rückwärts abspielen") { playback?.shuttleBackward() }
                .keyboardShortcut("j", modifiers: [])
                .disabled(isTyping)
            Button("Anhalten") { playback?.pause() }
                .keyboardShortcut("k", modifiers: [])
                .disabled(isTyping)
            Button("Vorwärts abspielen") { playback?.shuttleForward() }
                .keyboardShortcut("l", modifiers: [])
                .disabled(isTyping)
            Divider()
            Button("Ein Bild zurück") { playback?.step(frames: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(isTyping)
            Button("Ein Bild vor") { playback?.step(frames: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(isTyping)
            Button("Zehn Bilder zurück") { playback?.step(frames: -10) }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("Zehn Bilder vor") { playback?.step(frames: 10) }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
            Divider()
            Button("Zum Anfang") { playback?.seek(to: .zero) }
                .keyboardShortcut(.home, modifiers: [])
                .disabled(isTyping)
            Button("Zum Ende") { playback.map { $0.seek(to: $0.duration) } }
                .keyboardShortcut(.end, modifiers: [])
                .disabled(isTyping)
        }
    }
}

/// Menü „Schnitt“ und Zoom-Befehle im Menü „Darstellung“.
struct TimelineCommands: Commands {
    @FocusedValue(\.timelineEditor) private var editor

    /// Einfache Tasten gehören dem Textfeld, solange man darin tippt.
    private var isTyping: Bool { editor?.isEditingText == true }

    var body: some Commands {
        CommandMenu("Schnitt") {
            Button("Am Playhead teilen") { editor?.splitAtPlayhead() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(editor == nil)
            Divider()
            Button("Löschen") { editor?.deleteSelection(ripple: false) }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(editor?.canDelete != true || isTyping)
            Button("Löschen und Lücke schließen") { editor?.deleteSelection(ripple: true) }
                .keyboardShortcut(.delete, modifiers: .shift)
                .disabled(editor?.selection.isEmpty != false || isTyping)
            Divider()
            Button("Überblendung hinzufügen") { editor?.addTransitionAtPlayhead(.crossfade) }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(editor == nil)
            Button("Übergang durch Schwarz hinzufügen") { editor?.addTransitionAtPlayhead(.fadeThroughBlack) }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(editor == nil)
            Divider()
            Button("Bereichsanfang am Playhead") { editor?.markRangeStart() }
                .keyboardShortcut("i", modifiers: [])
                .disabled(editor == nil || isTyping)
            Button("Bereichsende am Playhead") { editor?.markRangeEnd() }
                .keyboardShortcut("o", modifiers: [])
                .disabled(editor == nil || isTyping)
            Button("Bereich aufheben") { editor?.clearRange() }
                .keyboardShortcut("x", modifiers: .option)
                .disabled(editor?.rangeSelection == nil)
            Button("Geschwindigkeit …") { editor?.showSpeedSheet() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(editor?.speedTargetRange == nil)
            Divider()
            Button("Zoom hinzufügen") { editor?.addZoomAtPlayhead() }
                .keyboardShortcut("z", modifiers: [])
                .disabled(editor == nil || isTyping)
            Button("Auto-Zoom aus Klicks") { editor?.generateAutoZoom() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(editor?.canGenerateAutoZoom != true)
            Divider()
            Button("Text einfügen") { editor?.addText() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(editor?.canAddAnnotation != true)
            Menu("Symbol einfügen") {
                ForEach(ShapeMark.Kind.allCases, id: \.self) { kind in
                    Button(kind.title) { editor?.addShape(kind) }
                }
            }
            .disabled(editor?.canAddAnnotation != true)
            Divider()
            Button("Verknüpfen") { editor?.linkSelection() }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(editor?.canLink != true)
            Button("Verknüpfung aufheben") { editor?.unlinkSelection() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(editor?.canUnlink != true)
            Divider()
            Button("Auswahl aufheben") { editor?.deselectAll() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(editor == nil)
            Button(editor?.isSnappingEnabled == false ? String(localized: "Einrasten einschalten") : String(localized: "Einrasten ausschalten")) {
                editor?.isSnappingEnabled.toggle()
            }
            .keyboardShortcut("n", modifiers: [])
            .disabled(editor == nil || isTyping)
        }
        CommandGroup(after: .toolbar) {
            Button("Timeline vergrößern") { editor?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(editor == nil)
            Button("Timeline verkleinern") { editor?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(editor == nil)
            Button("Ganze Timeline zeigen") { editor?.zoomToFit() }
                .keyboardShortcut("z", modifiers: .shift)
                .disabled(editor == nil)
            Divider()
        }
    }
}
