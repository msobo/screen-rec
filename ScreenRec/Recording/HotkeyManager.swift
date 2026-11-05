import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRecording = Self("toggleRecording", default: .init(.two, modifiers: [.command, .shift]))
    static let togglePause = Self("togglePause")
}

@MainActor
enum HotkeyManager {
    /// Einmal beim App-Start aufrufen.
    static func register(for appState: AppState) {
        KeyboardShortcuts.onKeyUp(for: .toggleRecording) { [weak appState] in
            Task { @MainActor in appState?.toggleRecording() }
        }
        KeyboardShortcuts.onKeyUp(for: .togglePause) { [weak appState] in
            Task { @MainActor in appState?.togglePause() }
        }
    }
}
