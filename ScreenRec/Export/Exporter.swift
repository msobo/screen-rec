import AVFoundation

/// Rendert eine `BuiltComposition` in eine Datei.
///
/// `AVAssetExportSession` lässt die Bitrate nicht einstellen, deshalb liest ein `AVAssetReader`
/// die Composition samt Video-Composition und Audio-Mix (also genau das, was die Vorschau zeigt)
/// und ein `AVAssetWriter` kodiert sie über VideoToolbox neu.
///
/// `@unchecked Sendable`: Reader und Writer werden nach `init` nur noch auf `queue` benutzt;
/// `cancel()` ruft nur die dafür vorgesehenen, threadsicheren Abbruchmethoden auf.
final class Exporter: @unchecked Sendable {
    enum ExportError: LocalizedError {
        case noVideo
        case cannotRead((any Error)?)
        case cannotWrite((any Error)?)

        var errorDescription: String? {
            switch self {
            case .noVideo: String(localized: "Die Timeline enthält kein Bild.")
            case .cannotRead(let error): String(localized: "Die Timeline konnte nicht gelesen werden: \(Self.describe(error))")
            case .cannotWrite(let error): String(localized: "Die Datei konnte nicht geschrieben werden: \(Self.describe(error))")
            }
        }

        private static func describe(_ error: (any Error)?) -> String {
            error?.localizedDescription ?? String(localized: "unbekannter Fehler")
        }
    }

    let outputURL: URL
    let format: ExportFormat
    let duration: CMTime

    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderVideoCompositionOutput
    private let videoInput: AVAssetWriterInput
    private let audio: (output: AVAssetReaderAudioMixOutput, input: AVAssetWriterInput)?
    private let queue = DispatchQueue(label: "ScreenRec.Exporter", qos: .userInitiated)

    @MainActor
    init(_ built: BuiltComposition, format: ExportFormat, to outputURL: URL) throws {
        guard let fileType = format.fileType else { throw ExportError.cannotWrite(nil) }
        guard let sourceVideoComposition = built.videoComposition,
              !built.composition.tracks(withMediaType: .video).isEmpty
        else { throw ExportError.noVideo }

        self.outputURL = outputURL
        self.format = format
        // Eigene Kopie: Die Vorschau spielt das Original weiter und baut es bei Änderungen neu.
        let composition = built.composition.copy() as! AVComposition
        duration = composition.duration

        do {
            reader = try AVAssetReader(asset: composition)
        } catch {
            throw ExportError.cannotRead(error)
        }
        try? FileManager.default.removeItem(at: outputURL)
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        } catch {
            throw ExportError.cannotWrite(error)
        }
        // Moov-Atom an den Dateianfang („faststart“), damit YouTube und Browser sofort lesen können.
        writer.shouldOptimizeForNetworkUse = fileType == .mp4

        // Gleiche Instructions und derselbe Compositor wie in der Vorschau, nur Größe und Bildrate des Exports.
        let videoComposition = sourceVideoComposition.mutableCopy() as! AVMutableVideoComposition
        videoComposition.renderSize = format.renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(format.frameRate))

        videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: composition.tracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: format.videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let audioTracks = composition.tracks(withMediaType: .audio)
        if audioTracks.isEmpty {
            audio = nil
        } else {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: ExportFormat.audioSampleRate,
                AVNumberOfChannelsKey: ExportFormat.audioChannels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            output.audioMix = built.audioMix
            output.audioTimePitchAlgorithm = BuiltComposition.audioTimePitchAlgorithm
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: format.audioSettings)
            input.expectsMediaDataInRealTime = false
            audio = (output, input)
        }

        guard reader.canAdd(videoOutput), audio.map({ reader.canAdd($0.output) }) ?? true else {
            throw ExportError.cannotRead(nil)
        }
        reader.add(videoOutput)
        if let audio { reader.add(audio.output) }
        guard writer.canAdd(videoInput), audio.map({ writer.canAdd($0.input) }) ?? true else {
            throw ExportError.cannotWrite(nil)
        }
        writer.add(videoInput)
        if let audio { writer.add(audio.input) }
    }

    /// Exportiert und meldet den Fortschritt (0…1) auf dem Main Thread.
    /// Bei Abbruch des Tasks wird die halbfertige Datei gelöscht und `CancellationError` geworfen.
    func run(progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        self.progress = progress
        let completed = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
                queue.async { self.start(continuation) }
            }
        } onCancel: {
            // Über die Queue, damit ein Abbruch vor `start` nicht `startReading` nach `cancelReading` auslöst.
            queue.async { self.cancelOnQueue() }
        }
        guard completed else {
            try? FileManager.default.removeItem(at: outputURL)
            throw CancellationError()
        }
    }

    // MARK: Auf `queue`

    private var progress: (@MainActor @Sendable (Double) -> Void)?
    private var lastReportedProgress = -1.0
    private var isCancelled = false

    private func cancelOnQueue() {
        isCancelled = true
        if reader.status == .reading { reader.cancelReading() }
    }

    /// Liefert `true`, wenn die Datei fertig ist, `false` nach einem Abbruch.
    private func start(_ continuation: CheckedContinuation<Bool, any Error>) {
        guard !isCancelled else {
            continuation.resume(returning: false)
            return
        }
        guard reader.startReading() else {
            continuation.resume(throwing: ExportError.cannotRead(reader.error))
            return
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            continuation.resume(throwing: ExportError.cannotWrite(writer.error))
            return
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        group.enter()
        pump(videoOutput, into: videoInput, reportsProgress: true, done: group.leave)
        if let audio {
            group.enter()
            pump(audio.output, into: audio.input, reportsProgress: false, done: group.leave)
        }

        group.notify(queue: queue) { [self] in
            if writer.status == .failed {
                reader.cancelReading()
                continuation.resume(throwing: ExportError.cannotWrite(writer.error))
            } else if reader.status == .failed {
                writer.cancelWriting()
                continuation.resume(throwing: ExportError.cannotRead(reader.error))
            } else if reader.status == .cancelled {
                writer.cancelWriting()
                continuation.resume(returning: false)
            } else {
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        report(1)
                        continuation.resume(returning: true)
                    } else {
                        continuation.resume(throwing: ExportError.cannotWrite(writer.error))
                    }
                }
            }
        }
    }

    /// Kopiert Samples, solange der Writer sie annimmt; ruft `done` genau einmal auf.
    private func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, reportsProgress: Bool,
                      done: @escaping @Sendable () -> Void) {
        let state = PumpState()
        input.requestMediaDataWhenReady(on: queue) { [self] in
            guard !state.isFinished else { return }
            while input.isReadyForMoreMediaData {
                // Bei Fehler oder Abbruch des Writers auch das Lesen beenden, damit die andere Spur aufhört.
                guard reader.status == .reading, let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                    state.isFinished = true
                    if writer.status == .failed { reader.cancelReading() }
                    input.markAsFinished()
                    done()
                    return
                }
                if reportsProgress { reportProgress(at: sample.presentationTimeStamp) }
            }
        }
    }

    private func reportProgress(at time: CMTime) {
        let fraction = duration.seconds > 0 ? min(max(time.seconds / duration.seconds, 0), 1) : 0
        // Nur in Prozentschritten melden, sonst flutet der Export den Main Thread.
        guard fraction - lastReportedProgress >= 0.01 else { return }
        report(fraction)
    }

    private func report(_ fraction: Double) {
        lastReportedProgress = fraction
        guard let progress else { return }
        Task { @MainActor in progress(fraction) }
    }
}

/// Merkt sich pro Spur, ob sie fertig ist. Nur auf der Queue des Exporters benutzt.
private final class PumpState: @unchecked Sendable {
    var isFinished = false
}
