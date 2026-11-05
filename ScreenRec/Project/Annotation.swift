import Foundation

/// Einblendung für Tutorials: aufgezeichnete Tasten, Erklärungstext oder Symbol.
///
/// Sie hängt an einer Stelle der Bildschirmaufnahme und nicht an der Timeline, damit sie bei
/// Schnitten und Tempowechseln beim selben Bildinhalt bleibt. Wo sie auf der Timeline liegt,
/// ermittelt `AnnotationPlacement`.
struct Annotation: Codable, Equatable, Identifiable, Sendable {
    enum Content: Codable, Equatable, Sendable {
        case keys(KeyGroup)
        case text(TextNote)
        case shape(ShapeMark)
    }

    var id = UUID()
    /// Quellzeit in der Bildschirmaufnahme.
    var anchor: RationalTime
    /// Anzeigedauer in Timeline-Zeit, damit Einblendungen auch bei 4× lesbar bleiben.
    var duration: RationalTime
    var content: Content

    /// Kürzeste Dauer beim Bearbeiten. Aufgezeichnete Tasten dürfen kürzer sein.
    static let minimumDuration = RationalTime(value: 3, timescale: 10)

    var keys: KeyGroup? {
        if case .keys(let group) = content { group } else { nil }
    }

    /// Bleibt mit dem Bildinhalt verbunden und zoomt mit.
    var followsZoom: Bool {
        switch content {
        case .keys: false
        case .text(let note): note.followsZoom
        case .shape(let mark): mark.followsZoom
        }
    }

    /// Überschrift im Inspektor.
    var kindTitle: String {
        switch content {
        case .keys: "Tasten"
        case .text: "Text"
        case .shape: "Symbol"
        }
    }

    /// Kurztext für die Timeline.
    var title: String {
        switch content {
        case .keys(let group): group.displayText
        case .text(let note): note.text
        case .shape(let mark): mark.kind == .badge ? "\(mark.kind.title) \(mark.number)" : mark.kind.title
        }
    }
}

/// Punkt relativ zum Bild (0 … 1, Ursprung oben links).
struct AnnotationPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    func clamped() -> AnnotationPoint {
        AnnotationPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}

enum AnnotationColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, blue, white

    var title: String {
        switch self {
        case .red: "Rot"
        case .orange: "Orange"
        case .yellow: "Gelb"
        case .green: "Grün"
        case .blue: "Blau"
        case .white: "Weiß"
        }
    }

    var rgb: RGBColor {
        switch self {
        case .red: RGBColor(red: 0.91, green: 0.2, blue: 0.16)
        case .orange: RGBColor(red: 0.96, green: 0.52, blue: 0.1)
        case .yellow: RGBColor(red: 0.98, green: 0.82, blue: 0.16)
        case .green: RGBColor(red: 0.2, green: 0.72, blue: 0.36)
        case .blue: RGBColor(red: 0.16, green: 0.5, blue: 0.93)
        case .white: RGBColor(red: 1, green: 1, blue: 1)
        }
    }
}

/// Aufeinanderfolgende Tastendrücke, die als Reihe von Tastenkappen erscheinen.
struct KeyGroup: Codable, Equatable, Sendable {
    struct Key: Codable, Equatable, Sendable {
        /// Sekunden Quellzeit nach dem Anker; so erscheinen die Tasten im Takt des Tippens.
        var offset: Double
        /// Eine Kappe je Eintrag, z. B. `["⇧", "⌘", "S"]`.
        var caps: [String]
    }

    /// Steht für ausgeblendete Eingaben in der Timeline.
    static let hiddenSymbol = "•"

    var keys: [Key]
    /// Wird nicht ins Video gezeichnet. Der Inhalt ist dann bereits entfernt.
    var isHidden = false

    var displayText: String { keys.flatMap(\.caps).joined() }
}

/// Frei platzierter Erklärungstext.
struct TextNote: Codable, Equatable, Sendable {
    enum Size: String, Codable, CaseIterable, Sendable {
        case small, medium, large

        var title: String {
            switch self {
            case .small: "S"
            case .medium: "M"
            case .large: "L"
            }
        }

        /// Schriftgröße relativ zur kurzen Bildseite.
        var scale: Double {
            switch self {
            case .small: 0.032
            case .medium: 0.045
            case .large: 0.065
            }
        }
    }

    var text: String
    /// Mittelpunkt der Textplatte.
    var position = AnnotationPoint(x: 0.5, y: 0.2)
    var size = Size.medium
    var color = AnnotationColor.white
    var followsZoom = false
}

/// Symbol, das auf etwas zeigt oder etwas hervorhebt.
struct ShapeMark: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case arrow, ellipse, rectangle, badge

        var title: String {
            switch self {
            case .arrow: "Pfeil"
            case .ellipse: "Kreis"
            case .rectangle: "Rechteck"
            case .badge: "Nummer"
            }
        }
    }

    var kind: Kind
    /// Pfeil: Anfang. Kreis und Rechteck: eine Ecke. Nummer: Mittelpunkt.
    var start = AnnotationPoint(x: 0.35, y: 0.35)
    /// Pfeil: Spitze. Kreis und Rechteck: gegenüberliegende Ecke. Bei der Nummer unbenutzt.
    var end = AnnotationPoint(x: 0.6, y: 0.6)
    var color = AnnotationColor.red
    /// Zahl im Nummern-Symbol.
    var number = 1
    var followsZoom = true
}
