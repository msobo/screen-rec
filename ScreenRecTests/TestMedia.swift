import AVFoundation
import ImageIO
import Testing
@testable import ScreenRec

/// Synthetische Samples und Aufnahmen für Tests, ohne echten Bildschirm.
enum TestMedia {
    /// Host-Zeitpunkt, wie ScreenCaptureKit ihn liefern würde.
    static func host(_ seconds: Double) -> CMTime {
        CMTime(seconds: 1_000 + seconds, preferredTimescale: 48_000)
    }

    static func videoSample(at time: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &pixelBuffer)
        let buffer = try #require(pixelBuffer)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: try #require(format),
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return try #require(sample)
    }

    static func audioSample(at time: CMTime, frames: Int) throws -> CMSampleBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: time,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                             formatDescription: format.formatDescription, sampleCount: frames,
                             sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                             sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        let buffer = try #require(sample)
        CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                       flags: 0, bufferList: pcm.audioBufferList)
        return buffer
    }

    /// Legt ein `.screenrec`-Paket an wie eine echte Aufnahme: 2 s Video und Systemton,
    /// das Mikrofon setzt erst nach `microphoneDelay` Sekunden ein.
    static func makeRecordingPackage(microphoneDelay: Double = 0.5) async throws -> URL {
        let package = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).screenrec")
        let media = package.appending(path: "media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)

        let clock = RecordingClock()
        let writer = CaptureWriter(directory: media, clock: clock, videoSize: CGSize(width: 320, height: 240),
                                   frameRate: 30, realTime: false)
        for frame in 0..<60 {
            let sample = try videoSample(at: host(Double(frame) / 30))
            writer.queue.sync { writer.write(sample, to: .screen) }
        }
        for chunk in 0..<20 {
            let time = Double(chunk) * 0.1
            let sample = try audioSample(at: host(time), frames: 4_800)
            writer.queue.sync {
                writer.write(sample, to: .systemAudio)
                if time >= microphoneDelay { writer.write(sample, to: .microphone) }
            }
        }
        let output = try await writer.finish(at: host(2))

        let info = RecordingInfo(
            createdAt: .now, duration: output.duration.seconds,
            source: .init(kind: .display, contentRect: CGRect(x: 0, y: 0, width: 160, height: 120), pointPixelScale: 2),
            videoWidth: 320, videoHeight: 240, frameRate: 30,
            files: Dictionary(uniqueKeysWithValues: output.files.map { ($0.key.rawValue, $0.value.lastPathComponent) }),
            startOffsets: Dictionary(uniqueKeysWithValues: output.startOffsets.map { ($0.key.rawValue, $0.value.seconds) }),
            droppedFrames: output.droppedFrames)
        try RecordingStorage.save(info, in: media)
        return package
    }
}

extension TestMedia {
    /// Legt `cursor.json` in ein Testpaket, wie der `CursorTracker` es nach einer Aufnahme tut.
    /// Der aufgenommene Bereich ist 160 × 120 Punkte groß (siehe `makeRecordingPackage`).
    static func addCursorData(_ data: CursorData, to package: URL) throws {
        let media = package.appending(path: "media")
        try JSONEncoder().encode(data).write(to: media.appending(path: CursorData.fileName))
        var info = try RecordingStorage.loadInfo(in: media)
        info.files["cursor"] = CursorData.fileName
        try RecordingStorage.save(info, in: media)
    }

    /// Weißes, quadratisches Cursor-Bild, Hotspot oben links.
    static func squareCursor(points: Double = 16) throws -> CursorData.CursorImage {
        let pixels = Int(points * 2)
        let context = try #require(CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return CursorData.CursorImage(png: data as Data, width: points, height: points, hotSpotX: 0, hotSpotY: 0)
    }

    /// Farbe eines Pixels (Ursprung oben links) als RGB 0 … 1.
    static func pixel(_ image: CGImage, x: Int, y: Int) throws -> (red: Double, green: Double, blue: Double) {
        let cropped = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
    }
}
