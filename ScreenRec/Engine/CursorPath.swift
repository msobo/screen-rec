import CoreGraphics

/// Geglättete Cursor-Bewegung einer Aufnahme, vorab berechnet in festen Schritten über die Aufnahmezeit.
///
/// Positionen sind relativ zum aufgenommenen Bereich (0 … 1, Ursprung oben links), damit sie
/// unabhängig von Auflösung, Fensterposition und Ausgabegröße sind. Der Compositor fragt sie
/// pro Bild ab und darf dabei keinen Zustand mitführen; deshalb wird die Feder-Glättung hier
/// einmal für die ganze Aufnahme gerechnet.
struct CursorPath: Sendable {
    static let rate = 60.0

    struct Click: Sendable {
        var t: Double
        var position: CGPoint
    }

    private var xs: [Float] = []
    private var ys: [Float] = []
    /// Index in `imageIDs` je Schritt, `-1` = kein Cursor-Bild bekannt.
    private var imageIndices: [Int32] = []
    let imageIDs: [String]
    let clicks: [Click]
    /// Breite und Höhe des aufgenommenen Bereichs in Punkten, um Cursor-Bilder relativ zu skalieren.
    let contentPointSize: CGSize

    /// - Parameters:
    ///   - fallbackFrame: Bereich der Aufnahme auf dem Bildschirm, falls `data` keine Rahmen enthält.
    ///   - smoothing: 0 = wie aufgenommen, 1 = stark geglättet.
    init(data: CursorData, fallbackFrame: CGRect, duration: Double, smoothing: Double) {
        let frameAtStart = data.contentFrame(at: 0, fallback: fallbackFrame)
        contentPointSize = frameAtStart.size
        imageIDs = data.cursors.keys.sorted()
        let imageIndex = Dictionary(uniqueKeysWithValues: imageIDs.enumerated().map { ($1, Int32($0)) })

        func normalized(_ x: Double, _ y: Double, in frame: CGRect) -> CGPoint {
            guard frame.width > 0, frame.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
            return CGPoint(x: (x - frame.minX) / frame.width, y: (y - frame.minY) / frame.height)
        }
        func normalized(_ x: Double, _ y: Double, at t: Double) -> CGPoint {
            normalized(x, y, in: data.contentFrame(at: t, fallback: fallbackFrame))
        }

        clicks = data.clicks.filter { $0.phase == .down }.map { Click(t: $0.t, position: normalized($0.x, $0.y, at: $0.t)) }

        let samples = data.samples.sorted { $0.t < $1.t }
        guard let first = samples.first else { return }
        let count = max(Int((duration * Self.rate).rounded(.up)) + 1, 1)
        xs.reserveCapacity(count)
        ys.reserveCapacity(count)
        imageIndices.reserveCapacity(count)

        // Feder ohne Überschwingen (kritisch gedämpft); weicher = kleinere Eigenfrequenz.
        let omega = 40 * pow(6.0 / 40, min(max(smoothing, 0), 1))
        let substeps = 4, dt = 1 / Self.rate / Double(substeps)
        var position = normalized(first.x, first.y, at: first.t)
        var velocity = CGVector.zero
        var sampleIndex = 0
        // Rahmen schrittweise mitführen statt bei jedem Schritt zu suchen.
        let frames = data.contentFrames.sorted { $0.t < $1.t }
        var frameIndex = 0
        var frame = frames.first?.rect ?? fallbackFrame
        var currentImage: Int32 = first.cursor.flatMap { imageIndex[$0] } ?? -1

        for step in 0..<count {
            let t = Double(step) / Self.rate
            while sampleIndex + 1 < samples.count, samples[sampleIndex + 1].t <= t {
                sampleIndex += 1
                if let id = samples[sampleIndex].cursor, let index = imageIndex[id] { currentImage = index }
            }
            while frameIndex + 1 < frames.count, frames[frameIndex + 1].t <= t {
                frameIndex += 1
                frame = frames[frameIndex].rect
            }
            let sample = samples[sampleIndex]
            let target = normalized(sample.x, sample.y, in: frame)
            if smoothing <= 0 {
                position = target
            } else {
                for _ in 0..<substeps {
                    let ax = omega * omega * (target.x - position.x) - 2 * omega * velocity.dx
                    let ay = omega * omega * (target.y - position.y) - 2 * omega * velocity.dy
                    velocity.dx += ax * dt
                    velocity.dy += ay * dt
                    position.x += velocity.dx * dt
                    position.y += velocity.dy * dt
                }
            }
            xs.append(Float(position.x))
            ys.append(Float(position.y))
            imageIndices.append(currentImage)
        }
    }

    var isEmpty: Bool { xs.isEmpty }

    /// Geglättete Position zur Aufnahmezeit `t`, zwischen den Schritten linear interpoliert.
    func position(at t: Double) -> CGPoint? {
        guard !xs.isEmpty else { return nil }
        let exact = min(max(t * Self.rate, 0), Double(xs.count - 1))
        let lower = Int(exact.rounded(.down)), upper = min(lower + 1, xs.count - 1)
        let fraction = Float(exact - Double(lower))
        return CGPoint(x: Double(xs[lower] + (xs[upper] - xs[lower]) * fraction),
                       y: Double(ys[lower] + (ys[upper] - ys[lower]) * fraction))
    }

    func imageID(at t: Double) -> String? {
        guard !imageIndices.isEmpty else { return nil }
        let index = imageIndices[min(max(Int((t * Self.rate).rounded()), 0), imageIndices.count - 1)]
        return index >= 0 ? imageIDs[Int(index)] : nil
    }

    /// Klicks, die zur Zeit `t` noch höchstens `window` Sekunden her sind, mit ihrem Alter.
    func recentClicks(at t: Double, window: Double) -> [(click: Click, age: Double)] {
        clicks.compactMap { click in
            let age = t - click.t
            return age >= 0 && age < window ? (click, age) : nil
        }
    }
}
