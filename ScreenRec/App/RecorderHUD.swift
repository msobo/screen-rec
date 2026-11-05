import KeyboardShortcuts
import SwiftUI

/// Hauptfenster im Tapedeck-Look: große REC-Taste, Zählwerk und die wichtigsten Aufnahme-Schalter.
struct RecorderHUD: View {
    @Environment(AppState.self) private var appState
    @AppStorage(RecordingOptions.Key.sourceKind) private var sourceKind = RecordingOptions.SourceKind.display
    @AppStorage(RecordingOptions.Key.captureMicrophone) private var captureMicrophone = true
    @AppStorage(RecordingOptions.Key.captureSystemAudio) private var captureSystemAudio = true
    @AppStorage(RecordingOptions.Key.captureCamera) private var captureCamera = false
    @AppStorage(RecordingOptions.Key.keystrokeMode) private var keystrokeMode = RecordingOptions.KeystrokeMode.shortcuts
    @AppStorage(RecordingOptions.Key.frameRate) private var frameRate = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                RecButton(isRecording: appState.isRecording, title: appState.primaryActionTitle) {
                    appState.toggleRecording()
                }
                .disabled(appState.phase == .selectingSource || appState.phase == .finishing)

                VStack(alignment: .leading, spacing: 8) {
                    counter
                    if appState.isRecording {
                        Button {
                            appState.togglePause()
                        } label: {
                            Label(appState.phase == .paused ? String(localized: "Fortsetzen") : String(localized: "Pausieren"),
                                  systemImage: appState.phase == .paused ? "play.fill" : "pause.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.key(isOn: appState.phase == .paused))
                    } else {
                        KeyPicker(selection: $sourceKind,
                                  options: RecordingOptions.SourceKind.allCases.map { ($0, $0.title) })
                            .disabled(appState.phase != .idle)
                            .help("Was im Auswahldialog angeboten wird")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Mikro", isOn: $captureMicrophone)
                    Toggle("Systemton", isOn: $captureSystemAudio)
                    Toggle("Kamera", isOn: $captureCamera)
                }
                .toggleStyle(.tapeSwitch)
                .textCase(.uppercase)
                .foregroundStyle(Tape.ink)
                .disabled(appState.phase != .idle)
                .fixedSize()
            }

            HStack(spacing: 10) {
                Text("Tasten").caseLabel(10, color: Tape.inkSoft)
                KeyPicker(selection: $keystrokeMode,
                          options: RecordingOptions.KeystrokeMode.allCases.map { ($0, $0.title) })
                    .frame(width: 280)
                    .disabled(appState.phase != .idle)
                    .help("Welche Tastenanschläge für die Einblendung im Video aufgezeichnet werden")
                if keystrokeMode == .all {
                    Label("Auch Passwörter", systemImage: "exclamationmark.triangle.fill")
                        .font(.tapeMono(11, weight: .medium))
                        .foregroundStyle(Color(hex: 0x9E2614))
                        .help("Getippter Text wird mit aufgezeichnet. Im Editor lässt er sich maskieren oder ausblenden.")
                }
            }

            if let errorMessage = appState.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.tapeMono(11, weight: .medium))
                    .foregroundStyle(Color(hex: 0x9E2614))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    NSDocumentController.shared.openDocument(nil)
                } label: {
                    Label("Projekt öffnen …", systemImage: "folder")
                }
                if appState.lastRecording != nil, !appState.isRecording {
                    Button {
                        appState.revealLastRecording()
                    } label: {
                        Label("Letzte Aufnahme", systemImage: "magnifyingglass")
                    }
                    .help("Letzte Aufnahme im Finder zeigen")
                }
                Spacer(minLength: 8)
                if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleRecording) {
                    Text("REC/STOP \(shortcut.description)")
                        .caseLabel(10, color: Tape.inkSoft)
                }
                AboutButton()
            }
            .buttonStyle(.key)
        }
        .padding(.horizontal, 20)
        .padding(.top, 34)
        .padding(.bottom, 16)
        .frame(width: 600)
        .background(alignment: .topLeading) { casingDecoration }
        .background(Tape.casing)
        .preferredColorScheme(.light)
        .onAppear { RecordingOptions.migrateKeystrokeMode() }
    }

    private var counter: some View {
        HStack(spacing: 12) {
            if appState.phase == .recording { BlinkingDot() }
            Text(counterText)
                .font(.tapeLCD(34))
                .foregroundStyle(Tape.phosphor)
                .phosphorGlow()
                .tracking(2)
                .monospacedDigit()
                .contentTransition(.numericText())
            Spacer(minLength: 8)
            Text(statusText)
                .font(.tapeLCD(18))
                .foregroundStyle(Tape.phosphorDim)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 2)
        .lcdScreen(cornerRadius: 10)
        .accessibilityElement(children: .combine)
    }

    private var counterText: String {
        if case .countdown(let remaining) = appState.phase { return "-00:00:0\(remaining)" }
        return Duration.seconds(appState.elapsed).formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 2)))
    }

    private var statusText: String {
        switch appState.phase {
        case .idle: String(localized: "BEREIT")
        case .selectingSource: String(localized: "QUELLE WÄHLEN")
        case .countdown: String(localized: "GLEICH GEHT'S LOS")
        case .recording: "REC · \(frameRate)FPS"
        case .paused: String(localized: "PAUSE")
        case .finishing: String(localized: "SPEICHERT …")
        }
    }

    /// Schrauben und Typenschild.
    private var casingDecoration: some View {
        ZStack(alignment: .top) {
            HStack {
                Screw()
                Spacer()
                Screw()
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            HStack(spacing: 8) {
                Text("SCREENREC").font(.tapeDisplay(12)).foregroundStyle(Tape.line).tracking(2)
                Text("MODEL SR-6 · VIDEO RECORDER").caseLabel(9, color: Tape.inkSoft)
            }
            .padding(.top, 9)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Die große rote Aufnahmetaste; während der Aufnahme eingerastet und leuchtend.
private struct RecButton: View {
    let isRecording: Bool
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if isRecording {
                    RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0xFFFAF0)).frame(width: 22, height: 22)
                } else {
                    Text("REC").font(.tapeDisplay(15)).foregroundStyle(Color(hex: 0xFFFAF0)).tracking(1)
                }
            }
        }
        .buttonStyle(RecButtonStyle(isRecording: isRecording))
        .accessibilityLabel(title)
        .help(title)
    }
}

private struct RecButtonStyle: ButtonStyle {
    let isRecording: Bool

    func makeBody(configuration: Configuration) -> some View {
        let down = isRecording || configuration.isPressed
        configuration.label
            .frame(width: 76, height: 76)
            .background {
                Circle().fill(RadialGradient(colors: [Color(hex: 0xFFB3A6), Tape.recRed, Color(hex: 0x9E2614)],
                                             center: UnitPoint(x: 0.38, y: 0.32), startRadius: 0, endRadius: 50))
            }
            .overlay { Circle().strokeBorder(Tape.ink, lineWidth: 4) }
            .contentShape(Circle())
            .offset(y: down ? 5 : 0)
            .background { Circle().fill(Color(hex: 0x5A1608)).offset(y: down ? 6 : 6) }
            .shadow(color: isRecording ? Tape.red.opacity(0.8) : .black.opacity(0.35), radius: isRecording ? 12 : 5,
                    y: isRecording ? 0 : 7)
            .padding(.bottom, 6)
            .animation(.easeOut(duration: 0.08), value: down)
    }
}
