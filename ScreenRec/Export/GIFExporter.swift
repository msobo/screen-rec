import AVFoundation
import ImageIO
import os
import UniformTypeIdentifiers
import VideoToolbox

/// Rendert eine `BuiltComposition` als animiertes GIF (ohne Ton).
///
/// Wie beim `Exporter` liest ein `AVAssetReader` die Composition samt Video-Composition, also genau
/// das Bild der Vorschau, nur gleich in GIF-Größe und -Bildrate. ImageIO übernimmt Farbpalette und Kodierung.
///
/// `@unchecked Sendable`: Reader und Ausgabe werden nach `init` nur noch auf `queue` benutzt;
/// der Abbruch läuft über einen Lock.
final class GIFExporter: @unchecked Sendable {
    let outputURL: URL
    let format: ExportFormat
    let duration: CMTime

    private let reader: AVAssetReader
    private let output: AVAssetReaderVideoCompositionOutput
    private let frameCount: Int
    private let queue = DispatchQueue(label: "ScreenRec.GIFExporter", qos: .userInitiated)
    private let isCancelled = OSAllocatedUnfairLock(initialState: false)

    @MainActor
    init(_ built: BuiltComposition, format: ExportFormat, to outputURL: URL) throws {
        guard let sourceVideoComposition = built.videoComposition,
              !built.composition.tracks(withMediaType: .video).isEmpty
        else { throw Exporter.ExportError.noVideo }

        self.outputURL = outputURL
        self.format = format
        let composition = built.composition.copy() as! AVComposition
        duration = composition.duration
        frameCount = max(Int((duration.seconds * Double(format.frameRate)).rounded(.up)), 1)

        do {
            reader = try AVAssetReader(asset: composition)
        } catch {
            throw Exporter.ExportError.cannotRead(error)
        }
        let videoComposition = sourceVideoComposition.mutableCopy() as! AVMutableVideoComposition
        videoComposition.renderSize = format.renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(format.frameRate))

        output = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Exporter.ExportError.cannotRead(nil) }
        reader.add(output)
    }

    /// Exportiert und meldet den Fortschritt (0…1) auf dem Main Thread.
    /// Bei Abbruch des Tasks wird die halbfertige Datei gelöscht und `CancellationError` geworfen.
    func run(progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        let completed = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
                queue.async { continuation.resume(with: Result { try self.encode(progress: progress) }) }
            }
        } onCancel: {
            isCancelled.withLock { $0 = true }
        }
        guard completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        }
    }

    /// Verzögerung von Bild `index` in Hundertstelsekunden, so verteilt, dass die Gesamtdauer stimmt
    /// (GIF kennt nur ganze Hundertstel, 15 fps wären sonst 7 statt 6,67).
    static func delay(ofFrame index: Int, frameRate: Int) -> Double {
        let start = (Double(index) * 100 / Double(frameRate)).rounded()
        let end = (Double(index + 1) * 100 / Double(frameRate)).rounded()
        return (end - start) / 100
    }

    // MARK: Auf `queue`

    /// Liefert `true`, wenn die Datei fertig ist, `false` nach einem Abbruch.
    private func encode(progress: @escaping @MainActor @Sendable (Double) -> Void) throws -> Bool {
        try? FileManager.default.removeItem(at: outputURL)
        guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.gif.identifier as CFString,
                                                                frameCount, nil)
        else { throw Exporter.ExportError.cannotWrite(nil) }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        guard reader.startReading() else { throw Exporter.ExportError.cannotRead(reader.error) }

        var written = 0
        var lastImage: CGImage?
        var lastReported = -1.0
        func add(_ image: CGImage) {
            let delay = Self.delay(ofFrame: written, frameRate: format.frameRate)
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ] as CFDictionary)
            written += 1
            let fraction = Double(written) / Double(frameCount)
            if fraction - lastReported >= 0.01 {
                lastReported = fraction
                Task { @MainActor in progress(min(fraction, 0.99)) }
            }
        }

        while written < frameCount {
            if isCancelled.withLock({ $0 }) {
                reader.cancelReading()
                return false
            }
            guard let sample = output.copyNextSampleBuffer() else { break }
            guard let pixelBuffer = sample.imageBuffer else { continue }
            var image: CGImage?
            VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
            guard let image else { continue }
            add(image)
            lastImage = image
        }
        if reader.status == .failed { throw Exporter.ExportError.cannotRead(reader.error) }
        // Die Anzahl der Bilder steht vorab fest; fehlen am Ende welche, das letzte wiederholen.
        while written < frameCount, let lastImage { add(lastImage) }
        reader.cancelReading()

        guard written > 0, CGImageDestinationFinalize(destination) else { throw Exporter.ExportError.cannotWrite(nil) }
        Task { @MainActor in progress(1) }
        return true
    }
}
