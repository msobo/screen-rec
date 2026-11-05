import AVFoundation
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    private typealias Key = RecordingOptions.Key

    @AppStorage(Key.captureSystemAudio) private var captureSystemAudio = true
    @AppStorage(Key.captureMicrophone) private var captureMicrophone = true
    @AppStorage(Key.microphoneID) private var microphoneID = ""
    @AppStorage(Key.showsCursor) private var showsCursor = false
    @AppStorage(Key.frameRate) private var frameRate = 60
    @AppStorage(Key.countdownSeconds) private var countdownSeconds = 3
    @AppStorage(Key.captureCamera) private var captureCamera = false
    @AppStorage(Key.cameraID) private var cameraID = ""
    @AppStorage(Key.keystrokeMode) private var keystrokeMode = RecordingOptions.KeystrokeMode.shortcuts
    @AppStorage(AppLanguage.key) private var language = AppLanguage.english
    @Environment(AppState.self) private var appState

    @State private var microphones: [AVCaptureDevice] = []
    @State private var cameras: [AVCaptureDevice] = []
    @State private var hasKeystrokePermission = KeystrokePermission.isGranted(prompt: false)

    private var keystrokeHint: String {
        if keystrokeMode != .off, !hasKeystrokePermission {
            return String(localized: "ScreenRec braucht dafür die Freigabe unter Systemeinstellungen > Datenschutz & Sicherheit > Bedienungshilfen.")
        }
        return switch keystrokeMode {
        case .off: String(localized: "Es werden keine Tastenanschläge aufgezeichnet.")
        case .shortcuts: String(localized: "Nur Kürzel mit ⌘, ⌃ oder ⌥ und einige Sondertasten, nie getippter Text.")
        case .all: String(localized: "Auch getippter Text, also womöglich Passwörter. Im Editor lassen sich Eingaben maskieren oder ausblenden.")
        }
    }

    var body: some View {
        Form {
            Section("Sprache") {
                Picker("Sprache", selection: $language) {
                    ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
                }
                if language != AppLanguage.active {
                    Text("Die neue Sprache gilt nach einem Neustart von ScreenRec.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Jetzt neu starten") { AppLanguage.relaunch() }
                        .disabled(appState.phase != .idle)
                }
            }

            Section("Ton") {
                Toggle("Systemton aufnehmen", isOn: $captureSystemAudio)
                Toggle("Mikrofon aufnehmen", isOn: $captureMicrophone)
                Picker("Mikrofon", selection: $microphoneID) {
                    Text("Systemstandard").tag("")
                    ForEach(microphones, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .disabled(!captureMicrophone)
            }

            Section("Bild") {
                Picker("Bildrate", selection: $frameRate) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                Toggle("Cursor ins Video einbrennen", isOn: $showsCursor)
                Text("Aus empfohlen: Der Cursor wird separat aufgezeichnet und kann später geglättet dargestellt werden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Countdown", selection: $countdownSeconds) {
                    Text("Aus").tag(0)
                    Text("3 Sekunden").tag(3)
                    Text("5 Sekunden").tag(5)
                }
            }

            Section("Kamera") {
                Toggle("Kamera aufnehmen", isOn: $captureCamera)
                Picker("Kamera", selection: $cameraID) {
                    Text("Systemstandard").tag("")
                    ForEach(cameras, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .disabled(!captureCamera)
                Text("Das Kamerabild landet als eigene Spur im Projekt und wird als Einblendung über die Aufnahme gelegt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Einblendungen") {
                Picker("Tastenanschläge aufzeichnen", selection: $keystrokeMode) {
                    ForEach(RecordingOptions.KeystrokeMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .onChange(of: keystrokeMode) { _, mode in
                    if mode != .off { hasKeystrokePermission = KeystrokePermission.isGranted(prompt: true) }
                }
                Text(keystrokeHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Tastenkürzel") {
                KeyboardShortcuts.Recorder("Aufnahme starten/stoppen", name: .toggleRecording)
                KeyboardShortcuts.Recorder("Pause/Fortsetzen", name: .togglePause)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            microphones = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                           mediaType: .audio, position: .unspecified).devices
            cameras = CameraCapture.defaultDevices()
            hasKeystrokePermission = KeystrokePermission.isGranted(prompt: false)
        }
    }
}
