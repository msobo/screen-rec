import AppKit
import SwiftUI

/// Großer Countdown in der Bildschirmmitte vor Aufnahmebeginn.
/// Das Fenster ist geschlossen, bevor die Aufnahme startet, und taucht daher nicht im Video auf.
@MainActor
enum CountdownOverlay {
    /// Läuft `seconds` Sekunden; wirft `CancellationError`, wenn der Task abgebrochen wird.
    static func run(seconds: Int, onTick: (Int) -> Void = { _ in }) async throws {
        guard seconds > 0 else { return }
        let model = Model(remaining: seconds)
        let panel = makePanel(model: model)
        defer { panel.close() }
        panel.orderFrontRegardless()

        for remaining in stride(from: seconds, through: 1, by: -1) {
            model.remaining = remaining
            onTick(remaining)
            try await Task.sleep(for: .seconds(1))
        }
    }

    @Observable
    fileprivate final class Model {
        var remaining: Int
        init(remaining: Int) { self.remaining = remaining }
    }

    fileprivate struct CountdownView: View {
        let model: Model

        var body: some View {
            VStack(spacing: 10) {
                Text("\(model.remaining)")
                    .font(.tapeLCD(150))
                    .monospacedDigit()
                    .foregroundStyle(Tape.phosphor)
                    .phosphorGlow()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.snappy, value: model.remaining)
                    .frame(width: 156, height: 136)
                    .lcdScreen(cornerRadius: 14, border: 4)
                Text("GLEICH GEHT'S LOS").font(.tapeDisplay(11)).foregroundStyle(Tape.line).tracking(1)
            }
            .frame(width: 200, height: 200)
            .background(Tape.casing, in: .rect(cornerRadius: 30))
            .overlay { RoundedRectangle(cornerRadius: 30).strokeBorder(Tape.line, lineWidth: 2) }
            .frame(width: 220, height: 220)
        }
    }

    private static func makePanel(model: Model) -> NSPanel {
        let size = NSSize(width: 220, height: 220)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: CountdownView(model: model))
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2))
        }
        return panel
    }
}
