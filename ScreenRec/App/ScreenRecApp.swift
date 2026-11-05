import KeyboardShortcuts
import SwiftUI

@main
struct ScreenRecApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var appState: AppState

    init() {
        AppLanguage.applySelection()
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
        // Die Menüleiste ist die erste Szene, daher öffnet SwiftUI dieses Fenster
        // nicht von selbst. Ohne Restoration erscheint es auch dann, wenn es beim
        // letzten Beenden geschlossen war.
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)

        Window("Über ScreenRec", id: AboutView.windowID) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        DocumentGroup(newDocument: { ProjectDocument() }) { file in
            EditorView(document: file.document, fileURL: file.fileURL)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            AboutCommands()
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
                .environment(appState)
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
        case .idle: String(localized: "Aufnahme starten")
        case .selectingSource: String(localized: "Quelle wählen …")
        case .countdown: String(localized: "Countdown abbrechen")
        case .recording, .paused: String(localized: "Aufnahme stoppen")
        case .finishing: String(localized: "Wird gespeichert …")
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
            Button(appState.phase == .paused ? String(localized: "Fortsetzen") : String(localized: "Pausieren")) { appState.togglePause() }
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
        Button("Über ScreenRec") {
            openWindow(id: AboutView.windowID)
            NSApplication.shared.activate()
        }
        Divider()
        Button("Beenden") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
