import SwiftUI

/// Fenster „Über ScreenRec“: Name, Version, Autor, Lizenz und ein Link samt QR-Code für alle, die
/// die Entwicklung unterstützen möchten.
struct AboutView: View {
    static let windowID = "about"
    static let supportURL = URL(string: "https://buymeacoffee.com/msobo")!

    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 4) {
                Text("ScreenRec")
                    .font(.tapeDisplay(30))
                    .foregroundStyle(Tape.ink)
                Text("Version \(version)")
                    .font(.tapeLCD(20))
                    .foregroundStyle(Tape.phosphor)
                    .phosphorGlow()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 2)
                    .lcdScreen()
                    .padding(.top, 4)
            }

            Text("Von Marek Sobolewski")
                .font(.tapeMono(13, weight: .semibold))
                .foregroundStyle(Tape.ink)

            VStack(spacing: 4) {
                Text("Gefällt dir ScreenRec? Unterstütze mich mit einem Kaffee!")
                    .font(.tapeMono(11))
                    .foregroundStyle(Tape.inkSoft)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Link("buymeacoffee.com/msobo", destination: Self.supportURL)
                    .font(.tapeMono(12, weight: .semibold))
                    .foregroundStyle(Tape.orangeInk)
                    .help("Öffnet buymeacoffee.com/msobo im Browser")
            }

            Image("SupportQr")
                .resizable()
                .interpolation(.high)
                .frame(width: 200, height: 200)
                .padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Tape.line, lineWidth: 2) }
                .accessibilityLabel("QR-Code für buymeacoffee.com/msobo")

            Button("Schließen") { dismiss() }
                .buttonStyle(.key)
                .keyboardShortcut(.cancelAction)

            Text("Freie Software unter der GNU GPL v3\nCopyright 2026 Marek Sobolewski")
                .font(.tapeMono(10))
                .foregroundStyle(Tape.inkSoft)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 18)
        .frame(width: 380)
        .background(alignment: .top) {
            HStack {
                Screw()
                Spacer()
                Screw()
            }
            .padding(10)
        }
        .background(Tape.casing)
        .preferredColorScheme(.light)
    }
}

/// Kleine Info-Taste, die das Fenster „Über ScreenRec“ öffnet. Den Tastenstil gibt die Umgebung vor.
struct AboutButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(id: AboutView.windowID)
        } label: {
            Image(systemName: "info.circle")
        }
        .help("Über ScreenRec")
        .accessibilityLabel("Über ScreenRec")
    }
}

/// Ersetzt den Standardeintrag im App-Menü, der sonst nur die Systemtafel zeigt.
struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("Über ScreenRec") { openWindow(id: AboutView.windowID) }
        }
    }
}
