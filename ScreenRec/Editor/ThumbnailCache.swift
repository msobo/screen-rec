import AVFoundation

/// Vorschaubilder für Videoclips in der Timeline. Werden im Hintergrund erzeugt, die zuletzt
/// angefragten zuerst, und im Speicher gehalten. Bis ein Bild fertig ist, gibt es das zeitlich
/// nächste vorhandene als Platzhalter.
@MainActor
final class ThumbnailCache {
    private struct Key: Hashable {
        var assetID: MediaAsset.ID
        /// Quellzeit in Schritten von `1 / resolution` Sekunden.
        var step: Int
    }

    static let resolution = 10.0
    static let maximumSize = CGSize(width: 320, height: 180)
    private static let capacity = 1_500
    private static let maximumPending = 120

    /// Wird aufgerufen, sobald neue Bilder vorliegen.
    var onChange: (() -> Void)?

    private let packageURL: URL
    private var images: [Key: CGImage] = [:]
    private var insertionOrder: [Key] = []
    private var pending: [Key] = []
    private var requested: Set<Key> = []
    private var generators: [MediaAsset.ID: AVAssetImageGenerator] = [:]
    private var isWorking = false

    init(packageURL: URL) {
        self.packageURL = packageURL
    }

    func image(for asset: MediaAsset, at sourceTime: RationalTime) -> CGImage? {
        let key = Key(assetID: asset.id, step: Int((sourceTime.seconds * Self.resolution).rounded()))
        if let image = images[key] { return image }
        if generators[asset.id] == nil { generators[asset.id] = makeGenerator(for: asset) }
        if requested.insert(key).inserted {
            pending.append(key)
            if pending.count > Self.maximumPending {
                requested.remove(pending.removeFirst())
            }
            generateNext()
        }
        return nearestImage(to: key)
    }

    private func nearestImage(to key: Key) -> CGImage? {
        images.filter { $0.key.assetID == key.assetID }
            .min { abs($0.key.step - key.step) < abs($1.key.step - key.step) }?.value
    }

    private func makeGenerator(for asset: MediaAsset) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: packageURL.appending(path: asset.path)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = Self.maximumSize
        // Etwas Toleranz erlaubt Keyframes und ist deutlich schneller als bildgenaues Dekodieren.
        let tolerance = CMTime(value: 1, timescale: 2 * Int32(Self.resolution))
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        return generator
    }

    private func generateNext() {
        guard !isWorking, let key = pending.popLast(), let generator = generators[key.assetID] else { return }
        isWorking = true
        let time = CMTime(value: Int64(key.step), timescale: Int32(Self.resolution))
        generator.generateCGImageAsynchronously(for: time) { [weak self] image, _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isWorking = false
                if let image { self.store(image, for: key) }
                self.generateNext()
            }
        }
    }

    private func store(_ image: CGImage, for key: Key) {
        images[key] = image
        insertionOrder.append(key)
        if insertionOrder.count > Self.capacity {
            let evicted = insertionOrder.prefix(Self.capacity / 5)
            insertionOrder.removeFirst(evicted.count)
            for key in evicted {
                images[key] = nil
                requested.remove(key)
            }
        }
        onChange?()
    }
}
