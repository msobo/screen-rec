import Foundation

/// Aufnahme-Einstellungen, gespeichert in den `UserDefaults` (siehe `SettingsView`).
struct RecordingOptions: Sendable {
    enum Key {
        static let captureSystemAudio = "recording.captureSystemAudio"
        static let captureMicrophone = "recording.captureMicrophone"
        static let microphoneID = "recording.microphoneID"
        static let showsCursor = "recording.showsCursor"
        static let frameRate = "recording.frameRate"
        static let countdownSeconds = "recording.countdownSeconds"
        static let sourceKind = "recording.sourceKind"
        static let captureCamera = "recording.captureCamera"
        static let cameraID = "recording.cameraID"
        /// Bis Schema 4: Schalter für Tastenkürzel, abgelöst durch `keystrokeMode`.
        static let recordsKeystrokes = "recording.recordsKeystrokes"
        static let keystrokeMode = "recording.keystrokeMode"
    }

    /// Welche Tasten für die Einblendung aufgezeichnet werden; alles außer `off` braucht die
    /// Bedienungshilfen-Freigabe.
    enum KeystrokeMode: String, CaseIterable, Sendable {
        case off, shortcuts, all

        var title: String {
            switch self {
            case .off: "Aus"
            case .shortcuts: "Nur Kürzel"
            case .all: "Alle Tasten"
            }
        }
    }

    /// Was im Auswahldialog des Systems angeboten wird.
    enum SourceKind: String, CaseIterable, Sendable {
        case display, window, application

        var title: String {
            switch self {
            case .display: "Bildschirm"
            case .window: "Fenster"
            case .application: "App"
            }
        }
    }

    var captureSystemAudio = true
    var captureMicrophone = true
    /// `nil` = Standard-Mikrofon des Systems.
    var microphoneID: String?
    /// Cursor ins Video einbrennen. Standardmäßig aus, weil der Cursor separat
    /// aufgezeichnet und später geglättet neu gerendert wird.
    var showsCursor = false
    var frameRate = 60
    var countdownSeconds = 3
    var sourceKind = SourceKind.display
    var captureCamera = false
    /// `nil` = Standardkamera des Systems.
    var cameraID: String?
    var keystrokeMode = KeystrokeMode.shortcuts

    static func load(from defaults: UserDefaults = .standard) -> RecordingOptions {
        var options = RecordingOptions()
        if defaults.object(forKey: Key.captureSystemAudio) != nil {
            options.captureSystemAudio = defaults.bool(forKey: Key.captureSystemAudio)
        }
        if defaults.object(forKey: Key.captureMicrophone) != nil {
            options.captureMicrophone = defaults.bool(forKey: Key.captureMicrophone)
        }
        if let id = defaults.string(forKey: Key.microphoneID), !id.isEmpty {
            options.microphoneID = id
        }
        options.showsCursor = defaults.bool(forKey: Key.showsCursor)
        if defaults.object(forKey: Key.frameRate) != nil {
            options.frameRate = defaults.integer(forKey: Key.frameRate)
        }
        if defaults.object(forKey: Key.countdownSeconds) != nil {
            options.countdownSeconds = defaults.integer(forKey: Key.countdownSeconds)
        }
        if let kind = defaults.string(forKey: Key.sourceKind).flatMap(SourceKind.init(rawValue:)) {
            options.sourceKind = kind
        }
        options.captureCamera = defaults.bool(forKey: Key.captureCamera)
        if let id = defaults.string(forKey: Key.cameraID), !id.isEmpty {
            options.cameraID = id
        }
        migrateKeystrokeMode(in: defaults)
        if let mode = defaults.string(forKey: Key.keystrokeMode).flatMap(KeystrokeMode.init(rawValue:)) {
            options.keystrokeMode = mode
        }
        return options
    }

    /// Übernimmt den früheren Schalter, damit Oberfläche und Aufnahme denselben Wert sehen.
    static func migrateKeystrokeMode(in defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: Key.keystrokeMode) == nil,
              defaults.object(forKey: Key.recordsKeystrokes) != nil
        else { return }
        let mode: KeystrokeMode = defaults.bool(forKey: Key.recordsKeystrokes) ? .shortcuts : .off
        defaults.set(mode.rawValue, forKey: Key.keystrokeMode)
    }
}
