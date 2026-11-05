import AVFoundation

/// Hüllkurven (Spitzenwerte) der Tonspuren für die Timeline.
///
/// Einmal im Hintergrund mit `AVAssetReader` gelesen und in `~/Library/Caches` abgelegt, nicht im
/// Projektpaket: Das Paket schreibt beim Sichern nur, was beim Öffnen schon darin lag.
@MainActor
final class WaveformCache {
    /// Spitzenwerte pro Sekunde Quellzeit.
    nonisolated static let peaksPerSecond = 100
    private nonisolated static let sampleRate = 8_000

    /// Wird aufgerufen, sobald eine Hüllkurve fertig gelesen ist.
    var onChange: (() -> Void)?

    private let packageURL: URL
    private var peaks: [MediaAsset.ID: [Float]] = [:]
    private var loading: [MediaAsset.ID: Task<Void, Never>] = [:]

    init(packageURL: URL) {
        self.packageURL = packageURL
    }

    deinit {
        for task in loading.values { task.cancel() }
    }

    /// Spitzenwerte (0…1) der Datei oder `nil`, solange sie noch gelesen wird.
    func peaks(for asset: MediaAsset) -> [Float]? {
        if let peaks = peaks[asset.id] { return peaks }
        if loading[asset.id] == nil {
            let url = packageURL.appending(path: asset.path)
            let cacheURL = Self.cacheURL(for: asset)
            loading[asset.id] = Task { [weak self] in
                let peaks = await Task.detached(priority: .utility) {
                    (try? await Self.loadOrRead(url: url, cacheURL: cacheURL)) ?? []
                }.value
                guard let self, !Task.isCancelled else { return }
                self.peaks[asset.id] = peaks
                self.onChange?()
            }
        }
        return nil
    }

    // MARK: Lesen

    private nonisolated static func cacheURL(for asset: MediaAsset) -> URL {
        URL.cachesDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "ScreenRec")
            .appending(path: "Waveforms")
            .appending(path: "\(asset.id.uuidString)-\(peaksPerSecond).peaks")
    }

    private nonisolated static func loadOrRead(url: URL, cacheURL: URL) async throws -> [Float] {
        if let data = try? Data(contentsOf: cacheURL) {
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        let peaks = try await readPeaks(from: url)
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? peaks.withUnsafeBytes { Data($0) }.write(to: cacheURL, options: .atomic)
        return peaks
    }

    /// Liest die Datei als Mono mit niedriger Abtastrate und behält je Abschnitt den lautesten Wert.
    nonisolated static func readPeaks(from url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }

        let samplesPerPeak = sampleRate / peaksPerSecond
        var peaks: [Float] = []
        var current: Float = 0
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled { reader.cancelReading(); return [] }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var samples = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size)
            samples.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            for sample in samples {
                current = max(current, abs(sample))
                count += 1
                if count == samplesPerPeak {
                    peaks.append(min(current, 1))
                    current = 0
                    count = 0
                }
            }
        }
        if count > 0 { peaks.append(min(current, 1)) }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
        return peaks
    }
}
