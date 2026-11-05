import AVFoundation
import SwiftUI

/// Zeigt das Bild des Players ohne eigene Bedienelemente; gesteuert wird über `PlaybackController`.
struct PreviewView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerLayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.black.cgColor
            layer = playerLayer
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) wird nicht unterstützt")
        }
    }
}
