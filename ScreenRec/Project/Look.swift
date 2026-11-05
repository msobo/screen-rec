import CoreGraphics
import Foundation

/// Gestaltung des Ausgabebilds: Hintergrund, Abstand, Ecken, Schatten,
/// neu gezeichneter Cursor, Kamera-Einblendung und Tastenkürzel.
///
/// Alle Maße sind relativ zur Ausgabegröße, damit Vorschau und Export (andere Auflösung)
/// gleich aussehen.
struct Look: Codable, Equatable, Sendable {
    enum Aspect: String, Codable, CaseIterable, Sendable {
        case source, landscape, square, portrait

        var title: String {
            switch self {
            case .source: "Original"
            case .landscape: "16:9"
            case .square: "1:1"
            case .portrait: "9:16"
            }
        }

        /// Breite durch Höhe, `nil` = wie die Aufnahme.
        var ratio: Double? {
            switch self {
            case .source: nil
            case .landscape: 16.0 / 9
            case .square: 1
            case .portrait: 9.0 / 16
            }
        }
    }

    var background = Background()
    /// Abstand um das Bild, Anteil der kürzeren Ausgabeseite (0 … 0,25).
    var padding = 0.0
    /// Eckenradius, Anteil der kürzeren Seite des Bildes (0 … 0,1).
    var cornerRadius = 0.0
    /// Stärke des Schattens unter dem Bild (0 … 1).
    var shadow = 0.0
    var aspect = Aspect.source
    var cursor = CursorStyle()
    var camera = CameraStyle()
    /// Aufgezeichnete Tastenkürzel unten im Bild einblenden.
    var showsKeystrokes = false

    static let paddingRange = 0.0...0.25
    static let cornerRadiusRange = 0.0...0.1

    /// Unverändertes Bild: ohne Rahmen, ohne Cursor.
    static let neutral = Look()

    /// Voreinstellung für neue Aufnahmen.
    static let standard = Look(background: Background(kind: .gradient, gradient: .dusk), padding: 0.06,
                               cornerRadius: 0.015, shadow: 0.6, cursor: CursorStyle(isVisible: true),
                               showsKeystrokes: true)

    /// Bild ohne Rahmen: Hintergrund, Abstand, Ecken und Schatten wirken sich nicht aus.
    var hasFrame: Bool {
        background.kind != .none || padding > 0 || cornerRadius > 0 || shadow > 0 || aspect != .source
    }
}

/// Farbe als sRGB-Komponenten 0 … 1.
struct RGBColor: Codable, Hashable, Sendable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    static let black = RGBColor(red: 0, green: 0, blue: 0)
}

struct Background: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case none, color, gradient, image

        var title: String {
            switch self {
            case .none: "Kein"
            case .color: "Farbe"
            case .gradient: "Verlauf"
            case .image: "Bild"
            }
        }
    }

    /// Farbverlauf von oben links nach unten rechts.
    struct Gradient: Codable, Hashable, Sendable {
        var from: RGBColor
        var to: RGBColor

        static let dusk = Gradient(from: RGBColor(hex: 0xF2902A), to: RGBColor(hex: 0x8F63F5))
        static let ocean = Gradient(from: RGBColor(hex: 0x2EC4B6), to: RGBColor(hex: 0x1A2A6C))
        static let candy = Gradient(from: RGBColor(hex: 0xF0599C), to: RGBColor(hex: 0xF6C844))
        static let forest = Gradient(from: RGBColor(hex: 0x3CC46F), to: RGBColor(hex: 0x07140D))
        static let slate = Gradient(from: RGBColor(hex: 0x5A5446), to: RGBColor(hex: 0x1B1814))
        static let paper = Gradient(from: RGBColor(hex: 0xF8F4EA), to: RGBColor(hex: 0xBDB39A))

        static let presets: [Gradient] = [.dusk, .ocean, .candy, .forest, .slate, .paper]
    }

    var kind = Kind.none
    var color = RGBColor(hex: 0x1B1814)
    var gradient = Gradient.dusk
    /// Pfad relativ zum Paket, z. B. `media/background.jpg`.
    var imagePath: String?
}

struct CursorStyle: Codable, Equatable, Sendable {
    /// Den aufgezeichneten Cursor neu ins Bild zeichnen.
    var isVisible = false
    /// Vergrößerung gegenüber der Originalgröße.
    var scale = 1.5
    /// 0 = Bewegung wie aufgenommen, 1 = stark geglättet.
    var smoothing = 0.6
    /// Kurzer Ring um jeden Klick.
    var highlightsClicks = true

    static let scaleRange = 0.5...4.0
}

struct CameraStyle: Codable, Equatable, Sendable {
    enum Corner: String, Codable, CaseIterable, Sendable {
        case topLeft, topRight, bottomLeft, bottomRight

        var title: String {
            switch self {
            case .topLeft: "Oben links"
            case .topRight: "Oben rechts"
            case .bottomLeft: "Unten links"
            case .bottomRight: "Unten rechts"
            }
        }
    }

    enum Shape: String, Codable, CaseIterable, Sendable {
        case circle, roundedRectangle

        var title: String { self == .circle ? "Kreis" : "Abgerundet" }
    }

    var corner = Corner.bottomRight
    var shape = Shape.circle
    /// Kantenlänge als Anteil der kürzeren Ausgabeseite.
    var size = 0.24

    static let sizeRange = 0.1...0.5
}
