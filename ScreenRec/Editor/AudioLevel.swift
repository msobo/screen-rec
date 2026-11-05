import Foundation

extension TimelineEditor {
    /// Pegel der hörbaren Tonspuren zum Zeitpunkt, 0…1 auf einer Skala von −48 bis 0 dB.
    /// Gelesen aus den Spitzenwerten der Wellenform; Blenden bleiben unberücksichtigt.
    func audioLevel(at time: RationalTime) -> Double {
        guard let waveforms else { return 0 }
        let rate = Double(WaveformCache.peaksPerSecond)
        var peak: Float = 0
        for track in timeline.tracks where track.kind == .audio && !track.isMuted {
            guard let clip = track.clips.first(where: { $0.timelineRange.contains(time) }), !clip.isMuted,
                  let asset = project.assets.first(where: { $0.id == clip.assetID }),
                  let peaks = waveforms.peaks(for: asset), !peaks.isEmpty else { continue }
            let source = clip.sourceRange.start.seconds + (time - clip.timelineStart).seconds * clip.speed
            // Kurzes Fenster um den Zeitpunkt, damit die Anzeige nicht flackert.
            let center = Int(source * rate)
            let lower = max(center - 3, 0), upper = min(center + 3, peaks.count)
            guard lower < upper else { continue }
            peak = max(peak, (peaks[lower..<upper].max() ?? 0) * clip.volume * track.volume)
        }
        guard peak > 0 else { return 0 }
        return min(max((20 * log10(Double(peak)) + 48) / 48, 0), 1)
    }
}
