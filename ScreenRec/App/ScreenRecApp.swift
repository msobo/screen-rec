import KeyboardShortcuts
import SwiftUI

@main
struct ScreenRecApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var appState: AppState

    init() {
        TapeFont.register()
        let appState = AppState()
        _appState = State(initialValue: appState)
        HotkeyManager.register(for: appState)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(appState)
        } label: {
            MenuBarLabel()
                .environment(appState)
        }

        Window("ScreenRec", id: "main") {
            RecorderHUD()
                .environment(appState)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)

        DocumentGroup(newDocument: { ProjectDocument() }) { file in
            EditorView(document: file.document, fileURL: file.fileURL)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            PlaybackCommands()
            TimelineCommands()
            ExportCommands()
            // Projekte entstehen nur aus Aufnahmen, nicht leer über „Neu“.
            CommandGroup(replacing: .newItem) {
                Button("Neue Aufnahme") { appState.toggleRecording() }
                    .disabled(appState.phase != .idle)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Beim Start kein leeres Dokument öffnen; das Hauptfenster ist der Einstieg.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
}

extension AppState {
    var formattedElapsed: String {
        Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond))
    }

    var primaryActionTitle: String {
        switch phase {
        case .idle: "Aufnahme starten"
        case .selectingSource: "Quelle wählen …"
        case .countdown: "Countdown abbrechen"
        case .recording, .paused: "Aufnahme stoppen"
        case .finishing: "Wird gespeichert …"
        }
    }
}

private struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.phase {
        case .recording:
            Image(systemName: "record.circle.fill")
            Text(appState.formattedElapsed)
        case .paused:
            Image(systemName: "pause.circle.fill")
            Text(appState.formattedElapsed)
        case .countdown(let remaining):
            Image(systemName: "record.circle")
            Text("\(remaining)")
        default:
            Image(systemName: "record.circle")
        }
    }
}

private struct MenuBarContent: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(appState.primaryActionTitle) { appState.toggleRecording() }
            .globalKeyboardShortcut(.toggleRecording)
            .disabled(appState.phase == .selectingSource || appState.phase == .finishing)

        if appState.isRecording {
            Button(appState.phase == .paused ? "Fortsetzen" : "Pausieren") { appState.togglePause() }
                .globalKeyboardShortcut(.togglePause)
        }

        if appState.lastRecording != nil {
            Button("Letzte Aufnahme im Finder zeigen") { appState.revealLastRecording() }
        }

        Divider()
        Button("ScreenRec öffnen") {
            openWindow(id: "main")
            NSApplication.shared.activate()
        }
        SettingsLink { Text("Einstellungen …") }
            .keyboardShortcut(",")
        Divider()
        Button("Beenden") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
