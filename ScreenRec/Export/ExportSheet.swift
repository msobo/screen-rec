import SwiftUI

/// „Exportieren …“: Preset, Auflösung, Bildrate, Zielordner und geschätzte Dateigröße.
struct ExportSheet: View {
    @ObservedObject var document: ProjectDocument
    let exporter: ExportController
    /// Aktuelle Composition der Vorschau, für Ausgangsgröße und -bildrate.
    let built: BuiltComposition?
    let defaultFileName: String
    @Environment(\.undoManager) private var undoManager
    @Environment(\.dismiss) private var dismiss
    @State private var settings: ExportSettings
    @State private var fileName: String

    init(document: ProjectDocument, exporter: ExportController, built: BuiltComposition?, defaultFileName: String) {
        self.document = document
        self.exporter = exporter
        self.built = built
        self.defaultFileName = defaultFileName
        _settings = State(initialValue: document.project.exportSettings)
        _fileName = State(initialValue: defaultFileName)
    }

    private var format: ExportFormat { ExportController.format(for: settings, built: built) }
    private var duration: RationalTime { document.project.timeline.duration }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Export").font(.tapeDisplay(18)).foregroundStyle(Tape.ink)
                Spacer()
                ModuleTag(text: String(localized: "AUSGANG"))
            }

            row(String(localized: "Voreinstellung")) {
                KeyPicker(selection: $settings.preset, options: ExportSettings.Preset.allCases.map { ($0, $0.title) })
            }
            if settings.preset == .youTube {
                row(String(localized: "Auflösung")) {
                    KeyPicker(selection: $settings.resolution,
                              options: ExportSettings.Resolution.allCases.map { ($0, $0.title) })
                }
                row(String(localized: "Bildrate")) {
                    KeyPicker(selection: $settings.frameRate, options: ExportSettings.frameRates.map { ($0, "\($0) fps") })
                }
            }
            if settings.preset == .gif {
                row(String(localized: "Größe")) {
                    KeyPicker(selection: $settings.gifSize, options: ExportSettings.gifSizes.map { ($0, "\($0) px") })
                }
                row(String(localized: "Bildrate")) {
                    KeyPicker(selection: $settings.gifFrameRate,
                              options: ExportSettings.gifFrameRates.map { ($0, "\($0) fps") })
                }
            }
            if settings.preset == .youTube || settings.preset == .original {
                row(String(localized: "Codec")) {
                    KeyPicker(selection: $settings.codec, options: ExportSettings.Codec.allCases.map { ($0, $0.title) })
                }
            }
            row(String(localized: "Ziel")) {
                HStack {
                    Text(settings.directoryURL.path(percentEncoded: false))
                        .font(.tapeMono(11))
                        .foregroundStyle(Tape.inkSoft)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 8)
                    Button("Ändern …", action: chooseDirectory)
                        .buttonStyle(.key)
                }
            }
            row(String(localized: "Dateiname")) {
                HStack(spacing: 6) {
                    TextField("Dateiname", text: $fileName)
                        .textFieldStyle(PaperFieldStyle())
                    Text(".\(format.fileExtension)")
                        .font(.tapeMono(12))
                        .foregroundStyle(Tape.inkSoft)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                summaryRow(String(localized: "Ausgabe"), format.summary)
                summaryRow(String(localized: "Dauer"), TimeFormatting.timecode(duration))
                summaryRow(String(localized: "Größe"), "≈ " + ByteCountFormatter.string(fromByteCount: format.estimatedFileSize(duration: duration),
                                                                      countStyle: .file))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lcdScreen(cornerRadius: 8)

            if let note {
                Text(note)
                    .font(.tapeMono(11))
                    .foregroundStyle(Tape.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if exporter.isRunning {
                    Text("Es läuft bereits ein Export.")
                        .font(.tapeMono(11))
                        .foregroundStyle(Tape.orangeInk)
                }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .buttonStyle(.key)
                    .keyboardShortcut(.cancelAction)
                Button("Exportieren") { export() }
                    .buttonStyle(.orangeKey)
                    .keyboardShortcut(.defaultAction)
                    .disabled(exporter.isRunning || duration <= .zero)
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(Tape.casing)
        .presentationBackground(Tape.casing)
        .preferredColorScheme(.light)
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).caseLabel(10, color: Tape.ink).frame(width: 110, alignment: .leading)
            content()
        }
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title.uppercased()).foregroundStyle(Tape.phosphorDim)
            Text(value).foregroundStyle(Tape.phosphor).phosphorGlow()
        }
        .font(.tapeLCD(21))
    }

    private var note: String? {
        switch settings.preset {
        case .youTube: String(localized: "MP4 mit Moov-Atom am Anfang, Bitrate nach YouTube-Empfehlung, Ton AAC 48 kHz Stereo.")
        case .original:
            settings.codec == .h264 && format.renderSize != ExportFormat.even(built?.videoComposition?.renderSize ?? .zero)
                ? String(localized: "H.264 kann diese Auflösung nicht kodieren; das Bild wird auf 4096 × 2304 verkleinert.")
                : nil
        case .proRes: String(localized: "Sehr große Dateien, verlustarm, gut zum Archivieren oder Weiterbearbeiten.")
        case .gif:
            duration.seconds > 60
                ? String(localized: "GIFs werden bei langen Aufnahmen sehr groß. Für mehr als eine Minute besser einen Abschnitt exportieren oder MP4 wählen.")
                : String(localized: "Ohne Ton, endlos wiederholt. Die Größe ist grob geschätzt und hängt stark vom Bildinhalt ab.")
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.directoryURL
        panel.prompt = String(localized: "Auswählen")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.directoryPath = url.path(percentEncoded: false)
    }

    private func export() {
        if settings != document.project.exportSettings {
            document.update(String(localized: "Exporteinstellungen ändern"), undoManager: undoManager) { $0.exportSettings = settings }
        }
        exporter.start(document.project, fileName: fileName)
        dismiss()
    }
}

/// Fortschritt bzw. Ergebnis des laufenden Exports, in der Kopfleiste des Editors.
struct ExportStatusView: View {
    let exporter: ExportController

    var body: some View {
        switch exporter.state {
        case .idle:
            EmptyView()
        case .running(let progress, let url):
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("EXPORT \(Int(progress * 100))%")
                        .font(.tapeLCD(20))
                        .foregroundStyle(Tape.phosphor)
                        .monospacedDigit()
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Tape.phosphor.opacity(0.15))
                            Rectangle().fill(Tape.phosphor).frame(width: proxy.size.width * progress)
                        }
                    }
                    .frame(width: 60, height: 8)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .lcdScreen(cornerRadius: 5, border: 2)
                Button { exporter.cancel() } label: { Image(systemName: "xmark") }
                    .help("Export abbrechen")
            }
            .help("Exportiert \(url.lastPathComponent)")
        case .finished(let url):
            HStack(spacing: 6) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Fertig", systemImage: "checkmark.circle.fill")
                }
                .help("\(url.lastPathComponent) im Finder zeigen")
                closeButton
            }
        case .failed(let message):
            HStack(spacing: 6) {
                Label("Export fehlgeschlagen", systemImage: "exclamationmark.triangle.fill")
                    .font(.tapeMono(11, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x9E2614))
                    .help(message)
                closeButton
            }
        }
    }

    private var closeButton: some View {
        Button { exporter.dismissResult() } label: { Image(systemName: "xmark") }
            .help("Ausblenden")
    }
}

extension FocusedValues {
    @Entry var exportController: ExportController?
}

/// „Ablage > Exportieren …“ (⌘E).
struct ExportCommands: Commands {
    @FocusedValue(\.exportController) private var exporter

    var body: some Commands {
        CommandGroup(replacing: .importExport) {
            Button("Exportieren …") { exporter?.isSheetPresented = true }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(exporter == nil)
        }
    }
}
