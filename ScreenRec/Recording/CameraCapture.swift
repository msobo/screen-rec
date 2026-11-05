import AVFoundation

/// Nimmt die Kamera parallel zum Bildschirm auf und reicht die Bilder an den `CaptureWriter`.
///
/// Die Bilder kommen direkt auf der Queue des Writers an. Ihre Zeitstempel werden von der Uhr
/// der Capture-Session in Host-Zeit umgerechnet, damit sie zur Uhr von ScreenCaptureKit passen.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum CameraError: LocalizedError {
        case noCamera
        case cannotAdd

        var errorDescription: String? {
            switch self {
            case .noCamera: String(localized: "Es wurde keine Kamera gefunden.")
            case .cannotAdd: String(localized: "Die Kamera konnte nicht verwendet werden.")
            }
        }
    }

    // `@unchecked Sendable`: `session` wird nur in `init`, `start` und `stop` angefasst,
    // die Bilder kommen ausschließlich auf `writer.queue` an.
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let writer: CaptureWriter

    /// - Parameter deviceID: `nil` = Standardkamera.
    init(deviceID: String?, writer: CaptureWriter) throws {
        self.writer = writer
        super.init()
        guard let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .video)
        else { throw CameraError.noCamera }

        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .high
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input), session.canAddOutput(output) else { throw CameraError.cannotAdd }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: writer.queue)
        session.addOutput(output)
        session.commitConfiguration()
    }

    static func defaultDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    func start() {
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Bilder vor dem ersten Bildschirmbild verwirft der Writer, weil die Uhr dann noch nicht läuft.
        let hostTime = session.synchronizationClock.map {
            CMSyncConvertTime(sampleBuffer.presentationTimeStamp, from: $0, to: CMClockGetHostTimeClock())
        } ?? sampleBuffer.presentationTimeStamp
        guard let retimed = CaptureWriter.retime(sampleBuffer, to: hostTime) else { return }
        writer.write(retimed, to: .camera)
    }
}
