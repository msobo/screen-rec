import CoreGraphics

/// Kamerafahrt der Zoom-Spur über die Timeline-Zeit, vorab berechnet: Vergrößerung und
/// Blickpunkt (relativ zum Bild, 0 … 1, oben links) in festen Schritten.
///
/// Folgt ein Zoom dem Cursor, läuft der Blickpunkt ihm mit einer weichen Feder hinterher,
/// damit die Kamera nicht jede kleine Mausbewegung mitmacht.
struct ZoomPath: Sendable {
    static let rate = 30.0
    /// Längste Dauer für Ein- und Auszoomen.
    static let maximumEase = 0.7
    /// Eigenfrequenz der Kamera-Feder; kleiner = träger.
    static let followOmega = 5.0

    struct State: Equatable, Sendable {
        var scale: Double
        var focus: CGPoint

        static let identity = State(scale: 1, focus: CGPoint(x: 0.5, y: 0.5))
    }

    private var scales: [Float] = []
    private var xs: [Float] = []
    private var ys: [Float] = []

    static let empty = ZoomPath()

    private init() {}

    /// - Parameter cursor: Cursor-Position (relativ zum Bild) zum Timeline-Zeitpunkt, `nil` wenn unbekannt.
    init(zooms: [ZoomRegion], duration: Double, cursor: (Double) -> CGPoint?) {
        guard !zooms.isEmpty, duration > 0 else { return }
        let regions = zooms.sorted { $0.start < $1.start }
        let count = Int((duration * Self.rate).rounded(.up)) + 1
        scales.reserveCapacity(count)
        xs.reserveCapacity(count)
        ys.reserveCapacity(count)

        let dt = 1 / Self.rate, omega = Self.followOmega
        var focus = CGPoint(x: 0.5, y: 0.5)
        var velocity = CGVector.zero
        var regionIndex = 0
        var activeRegion: ZoomRegion.ID?

        for step in 0..<count {
            let t = Double(step) / Self.rate
            while regionIndex < regions.count, regions[regionIndex].end.seconds <= t { regionIndex += 1 }
            let region = regionIndex < regions.count && regions[regionIndex].start.seconds <= t ? regions[regionIndex] : nil

            let target: CGPoint
            switch region?.focus {
            case .point: target = CGPoint(x: region!.pointX, y: region!.pointY)
            case .cursor, nil: target = cursor(t) ?? focus
            }
            if region?.id != activeRegion {
                // Beim Einzoomen sitzt die Kamera schon am Ziel, statt erst hinzuschwenken.
                activeRegion = region?.id
                focus = target
                velocity = .zero
            } else {
                let ax = omega * omega * (target.x - focus.x) - 2 * omega * velocity.dx
                let ay = omega * omega * (target.y - focus.y) - 2 * omega * velocity.dy
                velocity.dx += ax * dt
                velocity.dy += ay * dt
                focus.x += velocity.dx * dt
                focus.y += velocity.dy * dt
            }

            scales.append(Float(region.map { Self.scale(of: $0, at: t) } ?? 1))
            xs.append(Float(focus.x))
            ys.append(Float(focus.y))
        }
    }

    var isEmpty: Bool { scales.isEmpty }

    func state(at t: Double) -> State {
        guard !scales.isEmpty else { return .identity }
        let exact = min(max(t * Self.rate, 0), Double(scales.count - 1))
        let lower = Int(exact.rounded(.down)), upper = min(lower + 1, scales.count - 1)
        let f = Float(exact - Double(lower))
        func mix(_ values: [Float]) -> Double { Double(values[lower] + (values[upper] - values[lower]) * f) }
        return State(scale: mix(scales), focus: CGPoint(x: mix(xs), y: mix(ys)))
    }

    /// Vergrößerung innerhalb eines Abschnitts mit weichem Ein- und Auszoomen.
    static func scale(of region: ZoomRegion, at t: Double) -> Double {
        let start = region.start.seconds, end = region.end.seconds
        guard t >= start, t <= end else { return 1 }
        let ease = min(maximumEase, (end - start) / 2)
        guard ease > 0 else { return region.scale }
        let progress = min(smootherstep((t - start) / ease), smootherstep((end - t) / ease))
        return 1 + (region.scale - 1) * progress
    }

    static func smootherstep(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
}
