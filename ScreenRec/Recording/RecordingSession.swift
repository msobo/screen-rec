import ScreenCaptureKit

/// Eine laufende Aufnahme: `SCStream` → `CaptureWriter` plus `CursorTracker` und optional `CameraCapture`.
@MainActor
final class RecordingSession: NSObject, SCStreamDelegate {
    struct Result: Sendable {
        var package: URL
        var info: RecordingInfo
    }

    let clock = RecordingClock()
    let package: URL
    private let media: URL
    private let filter: SCContentFilter
    private let options: RecordingOptions
    private let videoSize: CGSize
    private let writer: CaptureWriter
    private let cursorTracker: CursorTracker
    private let camera: CameraCapture?
    private let createdAt = Date.now
    private var stream: SCStream?

    /// Wird aufgerufen, wenn der Stream von außen beendet wird
    /// (z. B. aufgenommenes Fenster geschlossen oder Freigabe über das System gestoppt).
    var onUnexpectedStop: ((any Error) -> Void)?

    init(filter: SCContentFilter, options: RecordingOptions) throws {
        self.filter = filter
        self.options = options
        (package, media) = try RecordingStorage.makeRecordingPackage()

        let scale = CGFloat(filter.pointPixelScale)
        // HEVC verlangt gerade Abmessungen.
        videoSize = CGSize(width: Self.even(filter.contentRect.width * scale),
                           height: Self.even(filter.contentRect.height * scale))
        writer = CaptureWriter(directory: media, clock: clock, videoSize: videoSize, frameRate: options.frameRate)
        cursorTracker = CursorTracker(clock: clock, keystrokeMode: options.keystrokeMode,
                                      contentFrame: Self.contentFrameProvider(for: filter))
        camera = options.captureCamera ? try CameraCapture(deviceID: options.cameraID, writer: writer) : nil
    }

    func start() async throws {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(videoSize.width)
        configuration.height = Int(videoSize.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.frameRate))
        configuration.queueDepth = 6
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.showsCursor = options.showsCursor
        configuration.capturesAudio = options.captureSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureMicrophone = options.captureMicrophone
        if let microphoneID = options.microphoneID {
            configuration.microphoneCaptureDeviceID = microphoneID
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue)
        if options.captureSystemAudio {
            try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue)
        }
        if options.captureMicrophone {
            try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue)
        }
        try await stream.startCapture()
        self.stream = stream
        cursorTracker.start()
        camera?.start()
    }

    func pause() { clock.pause() }
    func resume() { clock.resume() }

    func stop() async throws -> Result {
        let stopTime = RecordingClock.hostNow()
        cursorTracker.stop()
        camera?.stop()
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        return try await finish(at: stopTime)
    }

    private func finish(at stopTime: CMTime) async throws -> Result {
        let output = try await writer.finish(at: stopTime)
        try cursorTracker.save(to: media.appending(path: CursorData.fileName))

        var files = Dictionary(uniqueKeysWithValues: output.files.map { ($0.key.rawValue, $0.value.lastPathComponent) })
        files["cursor"] = CursorData.fileName
        let info = RecordingInfo(
            createdAt: createdAt,
            duration: output.duration.seconds,
            source: .init(kind: Self.kind(of: filter), contentRect: filter.contentRect,
                          pointPixelScale: Double(filter.pointPixelScale)),
            videoWidth: Int(videoSize.width),
            videoHeight: Int(videoSize.height),
            frameRate: options.frameRate,
            files: files,
            startOffsets: Dictionary(uniqueKeysWithValues: output.startOffsets.map { ($0.key.rawValue, $0.value.seconds) }),
            droppedFrames: output.droppedFrames,
            showsCursor: options.showsCursor
        )
        try RecordingStorage.save(info, in: media)
        return Result(package: package, info: info)
    }

    // MARK: SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            guard self.stream != nil else { return }
            self.onUnexpectedStop?(error)
        }
    }

    // MARK: Hilfen

    private static func even(_ value: CGFloat) -> CGFloat {
        CGFloat(max(2, Int(value.rounded()) & ~1))
    }

    /// Lage des aufgenommenen Bereichs in globalen Punkten (oben links), für die Zuordnung der
    /// Mausposition zum Bild. Fenster werden laufend abgefragt, weil man sie verschieben kann.
    private static func contentFrameProvider(for filter: SCContentFilter) -> () -> CGRect? {
        if #available(macOS 15.2, *) {
            if filter.style == .window, let windowID = filter.includedWindows.first?.windowID {
                return { windowBounds(windowID) }
            }
            if let displayID = filter.includedDisplays.first?.displayID {
                let bounds = CGDisplayBounds(displayID)
                return { bounds }
            }
        }
        let rect = filter.contentRect
        return { rect }
    }

    private static func windowBounds(_ windowID: CGWindowID) -> CGRect? {
        guard let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let bounds = info.first?[kCGWindowBounds as String] as? [String: Any]
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    private static func kind(of filter: SCContentFilter) -> RecordingInfo.Source.Kind {
        switch filter.style {
        case .display: .display
        case .window: .window
        case .application: .application
        default: .unknown
        }
    }
}
