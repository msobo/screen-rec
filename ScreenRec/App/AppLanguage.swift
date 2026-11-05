import AppKit

/// Sprache der Oberfläche. Unabhängig von der Systemsprache ist Englisch der Standard.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case german = "de"

    static let key = "app.language"

    /// Die Sprache, mit der dieser Prozess gestartet ist. Ein Wechsel greift erst nach einem Neustart.
    static let active = selected

    static var selected: AppLanguage {
        UserDefaults.standard.string(forKey: key).flatMap(AppLanguage.init) ?? .english
    }

    var id: String { rawValue }

    /// Jede Sprache steht in ihrer eigenen Schreibweise in der Auswahl.
    var title: String {
        switch self {
        case .english: "English"
        case .german: "Deutsch"
        }
    }

    /// Muss vor dem ersten Zugriff auf lokalisierte Texte laufen, weil `Bundle` die Sprache
    /// beim ersten Zugriff festhält.
    static func applySelection() {
        _ = active
        UserDefaults.standard.set([selected.rawValue], forKey: "AppleLanguages")
    }

    /// Beendet die App und startet sie danach neu. Bricht jemand das Beenden ab, bleibt es dabei.
    @MainActor
    static func relaunch() {
        applySelection()
        let script = """
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
            kill -0 "$1" 2>/dev/null || exec /usr/bin/open "$2"
            sleep 0.25
        done
        """
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, "sh", "\(ProcessInfo.processInfo.processIdentifier)", Bundle.main.bundlePath]
        try? process.run()
        NSApplication.shared.terminate(nil)
    }
}
