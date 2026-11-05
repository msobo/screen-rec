import AppKit
import CoreMedia

/// Zeichnet Mausposition, Klicks, Cursor-Bilder, die Lage des aufgenommenen Bereichs und
/// (optional) Tastendrücke während der Aufnahme auf.
///
/// Die Daten landen in `media/cursor.json` (siehe `CursorData`) und speisen Auto-Zoom,
/// den geglätteten Cursor und die Tasten-Einblendungen.
@MainActor
final class CursorTracker {
    private let clock: RecordingClock
    /// Liefert die aktuelle Lage des aufgenommenen Bereichs (globale Punkte, oben links).
    private let contentFrame: () -> CGRect?
    private let keystrokeMode: RecordingOptions.KeystrokeMode
    private var data = CursorData()
    private var timer: Timer?
    private var monitors: [Any] = []
    private var lastPosition: CGPoint?
    private var lastCursorKey: String?
    private var lastCursorID: String?
    private var lastContentFrame: CGRect?
    private var tick = 0

    /// Fensterrahmen ändern sich selten; zehnmal pro Sekunde abfragen reicht.
    private static let contentFrameInterval = 6

    init(clock: RecordingClock, keystrokeMode: RecordingOptions.KeystrokeMode = .off, contentFrame: @escaping () -> CGRect? = { nil }) {
        self.clock = clock
        self.keystrokeMode = keystrokeMode
        self.contentFrame = contentFrame
    }

    func start(sampleRate: Double = 60) {
        let timer = Timer(timeInterval: 1 / sampleRate, repeats: true) { _ in
            MainActor.assumeIsolated { self.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        var mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                           .otherMouseDown, .otherMouseUp]
        // Tastendrücke anderer Apps kommen nur mit Bedienungshilfen-Freigabe an.
        if keystrokeMode != .off { mask.insert(.keyDown) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { self.record(event) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated { self.record(event) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    func save(to url: URL) throws {
        try JSONEncoder().encode(data).write(to: url, options: .atomic)
    }

    private var currentTime: Double? {
        clock.recordingTime(forHostTime: RecordingClock.hostNow())?.seconds
    }

    private static func globalTopLeft(_ point: NSPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    private func sample() {
        guard let t = currentTime else { return }
        if tick % Self.contentFrameInterval == 0, let frame = contentFrame(), frame != lastContentFrame {
            data.contentFrames.append(.init(t: t, x: frame.minX, y: frame.minY, width: frame.width, height: frame.height))
            lastContentFrame = frame
        }
        tick += 1

        let position = Self.globalTopLeft(NSEvent.mouseLocation)
        let cursorID = currentCursorID()
        let cursorChanged = cursorID != lastCursorID
        guard position != lastPosition || cursorChanged else { return }
        data.samples.append(.init(t: t, x: position.x, y: position.y, cursor: cursorChanged ? cursorID : nil))
        lastPosition = position
        lastCursorID = cursorID
    }

    /// Erkennt Cursor-Wechsel günstig über Hotspot und Größe; das PNG wird nur bei Änderung erzeugt.
    private func currentCursorID() -> String? {
        guard let cursor = NSCursor.currentSystem else { return lastCursorID }
        let image = cursor.image
        let key = "\(cursor.hotSpot.x),\(cursor.hotSpot.y),\(image.size.width),\(image.size.height)"
        if key == lastCursorKey { return lastCursorID }
        lastCursorKey = key

        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return lastCursorID }
        let id = String(png.hashValue, radix: 16)
        if data.cursors[id] == nil {
            data.cursors[id] = .init(png: png, width: image.size.width, height: image.size.height,
                                     hotSpotX: cursor.hotSpot.x, hotSpotY: cursor.hotSpot.y)
        }
        return id
    }

    private func record(_ event: NSEvent) {
        guard let t = currentTime else { return }
        if event.type == .keyDown {
            guard keystrokeMode != .off, !event.isARepeat else { return }
            if keystrokeMode == .all, let character = KeystrokeLabel.typedCharacter(for: event) {
                data.keystrokes.append(.init(t: t, label: character, isTyped: true))
            } else if let label = KeystrokeLabel.label(for: event) {
                data.keystrokes.append(.init(t: t, label: label))
            }
            return
        }
        let position = Self.globalTopLeft(NSEvent.mouseLocation)
        let button: CursorData.Click.Button
        let phase: CursorData.Click.Phase
        switch event.type {
        case .leftMouseDown: (button, phase) = (.left, .down)
        case .leftMouseUp: (button, phase) = (.left, .up)
        case .rightMouseDown: (button, phase) = (.right, .down)
        case .rightMouseUp: (button, phase) = (.right, .up)
        case .otherMouseDown: (button, phase) = (.other, .down)
        default: (button, phase) = (.other, .up)
        }
        data.clicks.append(.init(t: t, x: position.x, y: position.y, button: button, phase: phase))
    }
}

/// Beschriftung für Tastenkürzel wie „⌘⇧S“.
///
/// `label` erkennt nur Kürzel mit ⌘, ⌃ oder ⌥ sowie einige Sondertasten. Normaler Text kommt
/// über `typedCharacter` und nur in der Stufe „Alle Tasten“ in die Aufnahme.
enum KeystrokeLabel {
    /// Kappe für die Leertaste beim Tippen.
    static let spaceCap = "␣"

    private static let specialKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: String(localized: "Leertaste"), 51: "⌫", 53: "esc", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    /// Tasten, die auch ohne Kürzeltaste angezeigt werden.
    private static let standaloneKeys: Set<UInt16> = [36, 48, 51, 53, 117, 123, 124, 125, 126]

    static func label(for event: NSEvent) -> String? {
        label(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
              modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
    }

    static func typedCharacter(for event: NSEvent) -> String? {
        typedCharacter(keyCode: event.keyCode, characters: event.characters,
                       modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
    }

    /// Das getippte Zeichen, wie es das Tastaturlayout liefert (⌥L ergibt auf deutschem Layout
    /// „@“), oder `nil` bei Kürzeln und Sondertasten.
    static func typedCharacter(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> String? {
        guard modifiers.intersection([.command, .control]).isEmpty else { return nil }
        if keyCode == 49 { return spaceCap }
        guard specialKeys[keyCode] == nil, let first = characters?.first,
              first.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return String(first)
    }

    static func label(keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags) -> String? {
        let hasShortcutModifier = !modifiers.intersection([.command, .control, .option]).isEmpty
        guard hasShortcutModifier || standaloneKeys.contains(keyCode) else { return nil }

        let key: String
        if let special = specialKeys[keyCode] {
            key = special
        } else if let characters, let first = characters.first, !first.isWhitespace {
            key = String(first).uppercased()
        } else {
            return nil
        }
        // Reihenfolge wie in den macOS-Menüs.
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + key
    }
}
