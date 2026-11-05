import AVFoundation
import Observation

/// Spielt die aktuelle Timeline ab und baut sie nach jeder Bearbeitung neu, ohne die
/// Playhead-Position zu verlieren.
@MainActor
@Observable
final class PlaybackController {
    let player = AVPlayer()
    private(set) var currentTime: RationalTime = .zero
    private(set) var duration: RationalTime = .zero
    private(set) var rate: Float = 0
    private(set) var errorMessage: String?
    /// Die zuletzt gebaute Composition; der Export-Dialog liest daraus Größe und Bildrate.
    private(set) var current: BuiltComposition?

    var isPlaying: Bool { rate != 0 }

    @ObservationIgnored private let builder: CompositionBuilder
    @ObservationIgnored private var builtContent: (assets: [MediaAsset], timeline: Timeline, look: Look)?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var frameDuration = CMTime(value: 1, timescale: 60)

    static let rebuildDelay = Duration.milliseconds(150)
    static let shuttleRates: [Float] = [1, 2, 4, 8]

    init(packageURL: URL) {
        builder = CompositionBuilder(packageURL: packageURL)
        // Der Block läuft auch bei Sprüngen sowie beim Starten und Anhalten der Wiedergabe.
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) {
            [weak self] time in
            MainActor.assumeIsolated { self?.playerTimeChanged(time) }
        }
        // Am Ende der Timeline hält der Player von selbst an, ohne dass der Zeitbeobachter noch läuft.
        rateObservation = player.observe(\.rate) { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.rate = self?.player.rate ?? 0 } }
        }
    }

    func invalidate() {
        rebuildTask?.cancel()
        rateObservation?.invalidate()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Composition

    /// Übernimmt den Projektstand. Der erste Aufbau passiert sofort, weitere gebündelt mit
    /// kurzer Verzögerung, damit z. B. Ziehen am Lautstärkeregler nicht bei jedem Wert neu baut.
    func update(with project: Project) {
        if let builtContent, builtContent.assets == project.assets, builtContent.timeline == project.timeline,
           builtContent.look == project.look { return }
        let isFirstBuild = builtContent == nil
        builtContent = (project.assets, project.timeline, project.look)

        rebuildTask?.cancel()
        rebuildTask = Task {
            if !isFirstBuild {
                try? await Task.sleep(for: Self.rebuildDelay)
                guard !Task.isCancelled else { return }
            }
            await rebuild(project, startAt: isFirstBuild ? project.editorState.playhead : nil)
        }
    }

    private func rebuild(_ project: Project, startAt playhead: RationalTime?) async {
        do {
            let built = try await builder.build(project)
            guard !Task.isCancelled else { return }
            let time = playhead?.cmTime ?? player.currentTime()
            let rate = player.rate

            player.replaceCurrentItem(with: built.makePlayerItem())
            current = built
            duration = RationalTime(built.composition.duration)
            frameDuration = built.videoComposition?.frameDuration ?? frameDuration
            errorMessage = nil

            await player.seek(to: CMTimeMinimum(time, built.composition.duration),
                              toleranceBefore: .zero, toleranceAfter: .zero)
            if rate != 0 { player.rate = rate }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Steuerung

    func togglePlayback() {
        if isPlaying {
            player.pause()
        } else {
            if currentTime >= duration { seek(to: .zero) }
            player.rate = 1
        }
    }

    func pause() { player.pause() }

    /// L: vorwärts abspielen, jedes weitere Drücken schneller.
    func shuttleForward() {
        player.rate = Self.nextShuttleRate(after: player.rate)
    }

    /// J: rückwärts abspielen, jedes weitere Drücken schneller.
    func shuttleBackward() {
        guard player.currentItem?.canPlayReverse == true else { return }
        player.rate = -Self.nextShuttleRate(after: -player.rate)
    }

    private static func nextShuttleRate(after rate: Float) -> Float {
        guard rate > 0 else { return shuttleRates[0] }
        return shuttleRates.first { $0 > rate } ?? shuttleRates.last!
    }

    func seek(to time: RationalTime) {
        let clamped = min(max(time, .zero), duration)
        currentTime = clamped
        player.seek(to: clamped.cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Ein oder mehrere Bilder vor (positiv) oder zurück (negativ).
    func step(frames: Int) {
        player.pause()
        seek(to: currentTime + RationalTime(CMTimeMultiply(frameDuration, multiplier: Int32(frames))))
    }

    private func playerTimeChanged(_ time: CMTime) {
        if time.isNumeric { currentTime = RationalTime(time) }
        rate = player.rate
    }
}
