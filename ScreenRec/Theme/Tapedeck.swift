import AppKit
import CoreText
import SwiftUI

/// „Tapedeck“: verspielter Retro-Look eines Videorekorders – beiges Gehäuse, Tasten zum Drücken,
/// grün leuchtende LCD-Anzeigen und ein dunkles Bandlaufwerk für die Timeline.
/// Die Farben sind bewusst fest und folgen nicht dem Hell/Dunkel-Modus des Systems.
enum Tape {
    // Gehäuse
    static let casing = Color(hex: 0xD8CFB8)
    static let tray = Color(hex: 0xC9BFA5)
    static let module = Color(hex: 0xCDC3A8)
    static let bezel = Color(hex: 0xBDB39A)
    static let recess = Color(hex: 0xA99F85)
    static let rim = Color(hex: 0xB4AA90)
    static let edge = Color(hex: 0x8C8270)
    static let line = Color(hex: 0x6B624F)
    static let highlight = Color(hex: 0xF6EFDC)
    static let paper = Color(hex: 0xF8F4EA)

    // Schrift
    static let ink = Color(hex: 0x2A2620)
    static let inkSoft = Color(hex: 0x5A5446)
    static let label = Color(hex: 0x4A4438)
    static let cream = Color(hex: 0xE8E0C9)

    // Tasten
    static let keyTop = Color(hex: 0xF3ECDA)
    static let keyBottom = Color(hex: 0xD9D0B8)
    static let keyEdge = Color(hex: 0x7D735F)
    static let orange = Color(hex: 0xF2902A)
    static let orangeLight = Color(hex: 0xFFB056)
    static let orangeEdge = Color(hex: 0x9A4F0A)
    static let orangeInk = Color(hex: 0xB85F0E)

    // Anzeigen und Akzente
    static let lcd = Color(hex: 0x07140D)
    static let phosphor = Color(hex: 0x7DFFB0)
    static let phosphorDim = Color(hex: 0x3F9A68)
    static let red = Color(hex: 0xFF5A4A)
    static let recRed = Color(hex: 0xE5482F)
    static let pink = Color(hex: 0xF0599C)
    static let yellow = Color(hex: 0xF6C844)
    static let purple = Color(hex: 0x8F63F5)
    static let teal = Color(hex: 0x2EC4B6)
    static let green = Color(hex: 0x3CC46F)

    // Bandlaufwerk (Timeline)
    static let deck = Color(hex: 0x1B1814)
    static let deckLine = Color(hex: 0x4A4438)
}

/// Dieselben Farben für die AppKit-Zeichenfläche der Timeline.
extension NSColor {
    static let tapeDeck = NSColor(hex: 0x1B1814)
    static let tapeDeckRowA = NSColor(hex: 0x201C17)
    static let tapeDeckRowB = NSColor(hex: 0x24201B)
    static let tapeDeckLane = NSColor(hex: 0x15120F)
    static let tapeDeckLine = NSColor(hex: 0x4A4438)
    static let tapeDeckTick = NSColor(hex: 0x3A352C)
    static let tapeRim = NSColor(hex: 0xB4AA90)
    static let tapeEdge = NSColor(hex: 0x8C8270)
    static let tapeCream = NSColor(hex: 0xE8E0C9)
    static let tapePaper = NSColor(hex: 0xFFFAF0)
    static let tapeInk = NSColor(hex: 0x2A2620)
    static let tapeOrange = NSColor(hex: 0xF2902A)
    static let tapeOrangeLight = NSColor(hex: 0xFFC27A)
    static let tapeOrangeDark = NSColor(hex: 0xB85F0E)
    static let tapeOrangeChip = NSColor(hex: 0xFFD9A8)
    static let tapeLCD = NSColor(hex: 0x07140D)
    static let tapeLCDChip = NSColor(hex: 0x0B2A1A)
    static let tapePhosphor = NSColor(hex: 0x7DFFB0)
    static let tapePhosphorDim = NSColor(hex: 0x2F7A52)
    static let tapePink = NSColor(hex: 0xF0599C)
    static let tapeYellow = NSColor(hex: 0xF6C844)
    static let tapePurple = NSColor(hex: 0x8F63F5)
    static let tapePurpleLight = NSColor(hex: 0xC3AAFF)
    static let tapeRed = NSColor(hex: 0xFF5A4A)
    static let tapeTeal = NSColor(hex: 0x2EC4B6)

    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: Schriften

/// Bungee für Beschriftungen auf dem Gehäuse, VT323 für die LCD-Anzeigen (beide SIL OFL, siehe
/// `Resources/Fonts`). Fließtext ist Monospace vom System.
enum TapeFont {
    static let display = "Bungee-Regular"
    static let lcd = "VT323-Regular"

    /// Einmal beim Start aufrufen; registriert die mitgelieferten Schriften nur für diese App.
    static func register() {
        for name in [display, lcd] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "woff2") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    static func nsLCD(_ size: CGFloat) -> NSFont {
        NSFont(name: lcd, size: size) ?? .monospacedDigitSystemFont(ofSize: size, weight: .regular)
    }

    static func nsMono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: weight)
    }
}

extension Font {
    static func tapeDisplay(_ size: CGFloat) -> Font { .custom(TapeFont.display, fixedSize: size) }
    static func tapeLCD(_ size: CGFloat) -> Font { .custom(TapeFont.lcd, fixedSize: size) }
    static func tapeMono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: Tasten

/// Eine Gehäusetaste, die beim Drücken nach unten wandert. `isOn` hält sie gedrückt (z. B. für
/// die gewählte Option einer Tastengruppe).
struct KeyButtonStyle: ButtonStyle {
    enum Kind { case cream, orange }

    var kind = Kind.cream
    var isOn = false
    var cornerRadius: CGFloat = 8

    func makeBody(configuration: Configuration) -> some View {
        KeyBody(configuration: configuration, kind: kind, isOn: isOn, cornerRadius: cornerRadius)
    }

    private struct KeyBody: View {
        let configuration: Configuration
        let kind: Kind
        let isOn: Bool
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let pressed = configuration.isPressed || isOn
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            configuration.label
                .font(kind == .orange ? .tapeDisplay(14) : .tapeMono(12, weight: .semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 8)
                .frame(minWidth: 34, minHeight: 30)
                .background {
                    shape.fill(LinearGradient(colors: faceColors(pressed: pressed), startPoint: .top, endPoint: .bottom))
                        .overlay(alignment: .top) {
                            // Lichtkante oben
                            Capsule().fill(highlight.opacity(pressed ? 0 : 0.9))
                                .frame(height: 1)
                                .padding(.horizontal, cornerRadius / 2)
                                .padding(.top, 1)
                        }
                        .overlay { shape.strokeBorder(edgeColor, lineWidth: 1) }
                }
                .contentShape(shape)
                .offset(y: pressed ? 3 : 0)
                .background { shape.fill(edgeColor).offset(y: 4) }
                .padding(.bottom, 4)
                .shadow(color: .black.opacity(pressed ? 0.12 : 0.25), radius: pressed ? 1 : 3, y: pressed ? 2 : 4)
                .opacity(isEnabled ? 1 : 0.5)
                .animation(.easeOut(duration: 0.06), value: pressed)
        }

        private var foreground: Color {
            switch kind {
            case .cream: isOn ? Tape.orangeInk : Tape.ink
            case .orange: Color(hex: 0x2A1400)
            }
        }

        private var edgeColor: Color { kind == .orange ? Tape.orangeEdge : Tape.keyEdge }
        private var highlight: Color { kind == .orange ? Color(hex: 0xFFD9A8) : Color(hex: 0xFFFAF0) }

        private func faceColors(pressed: Bool) -> [Color] {
            switch kind {
            case .cream: pressed ? [Color(hex: 0xE4DBC4), Color(hex: 0xCFC5AA)] : [Tape.keyTop, Tape.keyBottom]
            case .orange: pressed ? [Tape.orange, Color(hex: 0xE07F1C)] : [Tape.orangeLight, Tape.orange]
            }
        }
    }
}

extension ButtonStyle where Self == KeyButtonStyle {
    static var key: KeyButtonStyle { KeyButtonStyle() }
    static var orangeKey: KeyButtonStyle { KeyButtonStyle(kind: .orange) }
    static func key(isOn: Bool) -> KeyButtonStyle { KeyButtonStyle(isOn: isOn) }
}

/// Tastengruppe in einer Mulde, eine Taste ist gedrückt: Ersatz für segmentierte Picker.
struct KeyPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var columns = 0

    var body: some View {
        let grid = Array(repeating: GridItem(.flexible(), spacing: 6), count: columns > 0 ? columns : options.count)
        LazyVGrid(columns: grid, spacing: 4) {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    Text(option.title)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.key(isOn: selection == option.value))
                .accessibilityAddTraits(selection == option.value ? .isSelected : [])
            }
        }
        .padding(6)
        .padding(.bottom, -2)
        .recessed(cornerRadius: 10)
    }
}

// MARK: Schalter und Fader

/// Schiebeschalter wie am Aufnahme-HUD: grün = an.
struct TapeSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Tape.ink.shadow(.inner(color: .black.opacity(0.6), radius: 2, y: 2)))
                    .frame(width: 40, height: 22)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(configuration.isOn ? Tape.phosphor : Tape.edge)
                            .frame(width: 16, height: 16)
                            .shadow(color: configuration.isOn ? Tape.phosphor.opacity(0.6) : .black.opacity(0.4),
                                    radius: configuration.isOn ? 4 : 0, y: configuration.isOn ? 0 : 2)
                            .padding(3)
                    }
                    .animation(.snappy(duration: 0.15), value: configuration.isOn)
                configuration.label
                    .font(.tapeMono(11, weight: .semibold))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

extension ToggleStyle where Self == TapeSwitchStyle {
    static var tapeSwitch: TapeSwitchStyle { TapeSwitchStyle() }
}

/// Schieberegler mit Kappe wie an einem Mischpult.
struct Fader: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var compact = false
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isDragging = false

    var body: some View {
        let thumb = compact ? CGSize(width: 14, height: 20) : CGSize(width: 18, height: 26)
        GeometryReader { proxy in
            let travel = max(proxy.size.width - thumb.width, 1)
            let fraction = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound)
                / max(range.upperBound - range.lowerBound, .ulpOfOne)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Tape.ink.shadow(.inner(color: .black.opacity(0.6), radius: 1.5, y: 2)))
                    .frame(height: compact ? 6 : 8)
                    .overlay(alignment: .bottom) { Capsule().stroke(Color(hex: 0xFFFAF0).opacity(0.5), lineWidth: 0.5).offset(y: 1) }
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: [Tape.keyTop, Color(hex: 0xCFC5AA)], startPoint: .top, endPoint: .bottom))
                    .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Tape.line, lineWidth: 1) }
                    .overlay { Rectangle().fill(Tape.ink.opacity(0.55)).frame(width: thumb.width - 6, height: 1.5) }
                    .frame(width: thumb.width, height: thumb.height)
                    .background { RoundedRectangle(cornerRadius: 4).fill(Tape.line).offset(y: isDragging ? 1 : 3) }
                    .offset(x: fraction * travel, y: isDragging ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                if !isDragging { isDragging = true; onEditingChanged(true) }
                let position = min(max((drag.location.x - thumb.width / 2) / travel, 0), 1)
                value = range.lowerBound + position * (range.upperBound - range.lowerBound)
            }.onEnded { _ in
                isDragging = false
                onEditingChanged(false)
            })
        }
        .frame(height: thumb.height + 4)
        .accessibilityRepresentation {
            Slider(value: $value, in: range) { editing in onEditingChanged(editing) }
        }
    }
}

// MARK: Anzeigen

/// Grüne LCD-Anzeige mit Zeilenraster und Vertiefung.
struct LCDScreen: ViewModifier {
    var cornerRadius: CGFloat = 6
    var border: CGFloat = 3

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(Tape.lcd)
            .overlay { Scanlines().opacity(0.8) }
            .overlay { shape.stroke(.black.opacity(0.7), lineWidth: 6).blur(radius: 3).clipShape(shape) }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Tape.line, lineWidth: border) }
    }
}

/// Feine Zeilen wie auf einem Röhrenbildschirm; lässt Mausklicks durch.
struct Scanlines: View {
    var spacing: CGFloat = 3
    var darkness = 0.22

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var y: CGFloat = 0
            while y < size.height {
                path.addRect(CGRect(x: 0, y: y, width: size.width, height: 1))
                y += spacing
            }
            context.fill(path, with: .color(.black.opacity(darkness)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    func lcdScreen(cornerRadius: CGFloat = 6, border: CGFloat = 3) -> some View {
        modifier(LCDScreen(cornerRadius: cornerRadius, border: border))
    }

    /// Leuchten der LCD-Schrift.
    func phosphorGlow(_ color: Color = Tape.phosphor) -> some View {
        shadow(color: color.opacity(0.7), radius: 3).shadow(color: color.opacity(0.3), radius: 7)
    }

    /// Mulde im Gehäuse, z. B. für Tastengruppen.
    func recessed(cornerRadius: CGFloat = 12, color: Color = Tape.recess) -> some View {
        background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(color.shadow(.inner(color: .black.opacity(0.25), radius: 3, y: 3))))
    }

    /// Eingelassene Leiste mit Rand, z. B. für Transport und Werkzeuge.
    func trayPanel(cornerRadius: CGFloat = 14, color: Color = Tape.tray, border: Color = Tape.edge) -> some View {
        background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(color.shadow(.inner(color: .black.opacity(0.15), radius: 3, y: 2)))
                .overlay { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(border, lineWidth: 2) }
        }
    }

    /// Erhabenes Modul mit Lichtkante oben und Schattenkante unten.
    func modulePanel(cornerRadius: CGFloat = 18, color: Color = Tape.module) -> some View {
        background {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            shape.fill(color)
                .overlay { shape.inset(by: 2).stroke(Color(hex: 0xECE5D1), lineWidth: 2).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)) }
                .overlay { shape.inset(by: 2).stroke(Color(hex: 0xA99F85), lineWidth: 3).mask(LinearGradient(colors: [.clear, .white], startPoint: .center, endPoint: .bottom)) }
                .overlay { shape.strokeBorder(Tape.line, lineWidth: 2) }
        }
    }

    /// Beschriftung auf dem Gehäuse: Großbuchstaben mit Sperrung.
    func caseLabel(_ size: CGFloat = 11, color: Color = Tape.label) -> some View {
        font(.tapeMono(size, weight: .semibold)).tracking(1.2).textCase(.uppercase).foregroundStyle(color)
    }
}

/// Leuchtdiode.
struct LED: View {
    var color: Color = Tape.green
    var isOn = true
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(isOn ? color : color.mix(with: Tape.ink, by: 0.65))
            .overlay { Circle().stroke(.black.opacity(0.25), lineWidth: 1) }
            .shadow(color: isOn ? color : .clear, radius: 4)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Blinkender Punkt, z. B. während der Aufnahme.
struct BlinkingDot: View {
    var color: Color = Tape.red
    @State private var isVisible = true

    var body: some View {
        Circle()
            .fill(color)
            .shadow(color: color, radius: 4)
            .frame(width: 9, height: 9)
            .opacity(isVisible ? 1 : 0.15)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(isVisible ? 660 : 440))
                    isVisible.toggle()
                }
            }
            .accessibilityHidden(true)
    }
}

/// Lüftungsschlitze als Zierde.
struct Vents: View {
    var count = 14

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Tape.line.shadow(.inner(color: .black.opacity(0.4), radius: 1, y: 2)))
                    .frame(width: 4, height: 16)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Schraube in der Gehäuseecke.
struct Screw: View {
    var body: some View {
        Circle()
            .fill(Tape.rim)
            .overlay { Circle().strokeBorder(Tape.line, lineWidth: 1) }
            .overlay { Rectangle().fill(Tape.line).frame(width: 7, height: 1.5).rotationEffect(.degrees(35)) }
            .frame(width: 11, height: 11)
            .accessibilityHidden(true)
    }
}

/// Kleines Schild „MODUL 01“.
struct ModuleTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.tapeMono(10))
            .foregroundStyle(Tape.inkSoft)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Tape.line, lineWidth: 1) }
    }
}

/// Eingabefeld auf hellem Papier mit Rand.
struct PaperFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.tapeMono(12))
            .foregroundStyle(Tape.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Tape.paper.shadow(.inner(color: .black.opacity(0.2), radius: 2, y: 1)),
                        in: RoundedRectangle(cornerRadius: 6))
            .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(Tape.line, lineWidth: 1) }
    }
}
