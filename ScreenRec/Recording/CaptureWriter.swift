import AVFoundation
import ScreenCaptureKit

/// Schreibt die Samples eines `SCStream` in getrennte Dateien:
/// `screen.mov` (HEVC), `system.m4a` und `mic.m4a` (AAC), dazu optional `camera.mov` von der Kamera.
///
/// Alle Methoden laufen auf `queue`; dieselbe Queue wird dem `SCStream` als
/// Sample-Handler-Queue übergeben, deshalb ist keine weitere Synchronisation nötig.
final class CaptureWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    enum Track: String, CaseIterable, Sendable {
        case screen, systemAudio, microphone, camera

        var fileName: String {
            switch self {
            case .screen: "screen.mov"
            case .systemAudio: "system.m4a"
            case .microphone: "mic.m4a"
            case .camera: "camera.mov"
            }
        }
    }

    struct Output: Sendable {
        var files: [Track: URL]
        /// Aufnahmezeit des ersten Samples je Spur. Die Dateien selbst beginnen immer bei 0,
        /// das Mikrofon liefert aber oft erst einige hundert Millisekunden nach dem Video.
        var startOffsets: [Track: CMTime]
        var duration: CMTime
        var droppedFrames: Int
    }

    enum WriterError: LocalizedError {
        case cannotAddInput(Track)
        case noVideoFrames
        case writerFailed(Track, (any Error)?)

        var errorDescription: String? {
            switch self {
            case .cannotAddInput(let track): String(localized: "Spur \(track.rawValue) konnte nicht angelegt werden.")
            case .noVideoFrames: String(localized: "Es wurde kein einziges Videobild aufgenommen.")
            case .writerFailed(let track, let error):
                String(localized: "Schreiben von \(track.fileName) fehlgeschlagen: \(error?.localizedDescription ?? String(localized: "unbekannter Fehler"))")
            }
        }
    }

    let queue = DispatchQueue(label: "ScreenRec.CaptureWriter", qos: .userInteractive)

    private let directory: URL
    private let clock: RecordingClock
    private let videoSize: CGSize
    private let frameRate: Int
    private let realTime: Bool

    private var writers: [Track: TrackWriter] = [:]
    private var startOffsets: [Track: CMTime] = [:]
    private var failure: (any Error)?
    private var droppedFrames = 0

    /// - Parameter realTime: `false` nur für Tests, dann wartet der Writer auf freie Kapazität statt Samples zu verwerfen.
    init(directory: URL, clock: RecordingClock, videoSize: CGSize, frameRate: Int, realTime: Bool = true) {
        self.directory = directory
        self.clock = clock
        self.videoSize = videoSize
        self.frameRate = frameRate
        self.realTime = realTime
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer) else { return }
            write(sampleBuffer, to: .screen)
        case .audio:
            write(sampleBuffer, to: .systemAudio)
        case .microphone:
            write(sampleBuffer, to: .microphone)
        @unknown default:
            return
        }
    }

    /// ScreenCaptureKit liefert auch „idle“-Frames ohne Bild, wenn sich nichts geändert hat.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }

    // MARK: Schreiben

    /// Muss auf `queue` aufgerufen werden.
    func write(_ sampleBuffer: CMSampleBuffer, to track: Track) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard failure == nil else { return }

        let hostTime = sampleBuffer.presentationTimeStamp
        // Der erste vollständige Videoframe definiert den Nullpunkt aller Spuren.
        if track == .screen { clock.startIfNeeded(at: hostTime) }
        guard let time = clock.recordingTime(forHostTime: hostTime),
              let retimed = Self.retime(sampleBuffer, to: time)
        else { return }

        do {
            let writer = try writers[track] ?? makeWriter(for: track, sourceFormat: sampleBuffer.formatDescription)
            if writers[track] == nil { startOffsets[track] = time }
            writers[track] = writer
            if !writer.append(retimed, waitIfBusy: !realTime), track == .screen {
                droppedFrames += 1
            }
        } catch {
            failure = error
        }
    }

    func finish(at hostTime: CMTime = RecordingClock.hostNow()) async throws -> Output {
        let duration = clock.stop(at: hostTime)
        let (writers, startOffsets, failure, droppedFrames) = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: (self.writers, self.startOffsets, self.failure, self.droppedFrames))
            }
        }
        if let failure { throw failure }
        guard writers[.screen] != nil else { throw WriterError.noVideoFrames }

        var files: [Track: URL] = [:]
        for (track, writer) in writers {
            try await writer.finish(at: duration, track: track)
            files[track] = writer.url
        }
        return Output(files: files, startOffsets: startOffsets, duration: duration, droppedFrames: droppedFrames)
    }

    private func makeWriter(for track: Track, sourceFormat: CMFormatDescription?) throws -> TrackWriter {
        let url = directory.appending(path: track.fileName)
        try? FileManager.default.removeItem(at: url)
        switch track {
        case .screen:
            return try TrackWriter(url: url, fileType: .mov, mediaType: .video,
                                   settings: videoSettings(), sourceFormat: sourceFormat, realTime: realTime, track: track)
        case .camera:
            return try TrackWriter(url: url, fileType: .mov, mediaType: .video,
                                   settings: Self.cameraSettings(for: sourceFormat), sourceFormat: sourceFormat,
                                   realTime: realTime, track: track)
        case .systemAudio, .microphone:
            return try TrackWriter(url: url, fileType: .m4a, mediaType: .audio,
                                   settings: Self.audioSettings(for: sourceFormat), sourceFormat: sourceFormat,
                                   realTime: realTime, track: track)
        }
    }

    private func videoSettings() -> [String: Any] {
        let width = Int(videoSize.width), height = Int(videoSize.height)
        // Großzügige Bitrate: Die Aufnahme ist Rohmaterial für den Schnitt.
        let bitrate = min(Double(width * height * frameRate) * 0.12, 120_000_000)
        return [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ]
    }

    /// Kamerabild in seiner eigenen Größe; es wird später nur klein eingeblendet.
    private static func cameraSettings(for format: CMFormatDescription?) -> [String: Any] {
        let dimensions = format.map(CMVideoFormatDescriptionGetDimensions) ?? CMVideoDimensions(width: 1280, height: 720)
        let width = Int(dimensions.width) & ~1, height = Int(dimensions.height) & ~1
        return [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: min(Double(width * height) * 30 * 0.08, 12_000_000),
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoAllowFrameReorderingKey: false,
            ] as [String: Any],
        ]
    }

    private static func audioSettings(for format: CMFormatDescription?) -> [String: Any] {
        let asbd = format.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let sampleRate = min(asbd?.mSampleRate ?? 48_000, 48_000)
        let channels = max(1, min(Int(asbd?.mChannelsPerFrame ?? 2), 2))
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels == 1 ? 128_000 : 256_000,
        ]
    }

    /// Verschiebt alle Zeitstempel eines Samples so, dass es bei `time` beginnt.
    static func retime(_ sampleBuffer: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return nil }
        var timings = [CMSampleTimingInfo](repeating: .invalid, count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)

        let offset = time - sampleBuffer.presentationTimeStamp
        for index in timings.indices {
            timings[index].presentationTimeStamp = timings[index].presentationTimeStamp + offset
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = timings[index].decodeTimeStamp + offset
            }
        }
        var result: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sampleBuffer,
                                              sampleTimingEntryCount: count, sampleTimingArray: &timings,
                                              sampleBufferOut: &result)
        return result
    }
}

/// Ein `AVAssetWriter` mit genau einer Spur.
private final class TrackWriter {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput

    init(url: URL, fileType: AVFileType, mediaType: AVMediaType, settings: [String: Any],
         sourceFormat: CMFormatDescription?, realTime: Bool, track: CaptureWriter.Track) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        input = AVAssetWriterInput(mediaType: mediaType, outputSettings: settings, sourceFormatHint: sourceFormat)
        input.expectsMediaDataInRealTime = realTime
        guard writer.canAdd(input) else { throw CaptureWriter.WriterError.cannotAddInput(track) }
        writer.add(input)
        guard writer.startWriting() else { throw CaptureWriter.WriterError.writerFailed(track, writer.error) }
        writer.startSession(atSourceTime: .zero)
    }

    /// Liefert `false`, wenn das Sample verworfen wurde.
    func append(_ sampleBuffer: CMSampleBuffer, waitIfBusy: Bool) -> Bool {
        while waitIfBusy && !input.isReadyForMoreMediaData && writer.status == .writing {
            Thread.sleep(forTimeInterval: 0.001)
        }
        guard input.isReadyForMoreMediaData else { return false }
        return input.append(sampleBuffer)
    }

    func finish(at duration: CMTime, track: CaptureWriter.Track) async throws {
        input.markAsFinished()
        // Verlängert das letzte Bild bis zum Stopp, auch wenn sich der Bildschirm zuletzt nicht mehr geändert hat.
        writer.endSession(atSourceTime: duration)
        let writer = self.writer
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw CaptureWriter.WriterError.writerFailed(track, writer.error)
        }
    }
}
