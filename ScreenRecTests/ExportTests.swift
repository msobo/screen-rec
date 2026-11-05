import AVFoundation
import Testing
@testable import ScreenRec

struct ExportFormatTests {
    private let retina = CGSize(width: 3024, height: 1964)

    @Test func youTubeBitRatesFollowTable() {
        #expect(ExportFormat.youTubeBitRate(height: 1080, frameRate: 30) == 8_000_000)
        #expect(ExportFormat.youTubeBitRate(height: 1080, frameRate: 60) == 12_000_000)
        #expect(ExportFormat.youTubeBitRate(height: 1440, frameRate: 60) == 24_000_000)
        #expect(ExportFormat.youTubeBitRate(height: 2160, frameRate: 60) == 53_000_000)
    }

    @Test func youTube1080p60() {
        let format = ExportFormat(settings: ExportSettings(), sourceSize: CGSize(width: 3840, height: 2160),
                                  sourceFrameRate: 60)
        #expect(format.fileType == .mp4)
        #expect(format.videoCodec == .h264)
        #expect(format.renderSize == CGSize(width: 1920, height: 1080))
        #expect(format.frameRate == 60)
        #expect(format.videoBitRate == 12_000_000)
        #expect(format.audioBitRate == 320_000)
    }

    @Test func youTubeKeepsAspectRatioWithEvenSize() {
        var settings = ExportSettings()
        settings.resolution = .p1440
        let format = ExportFormat(settings: settings, sourceSize: retina, sourceFrameRate: 60)
        #expect(format.renderSize.height == 1440)
        #expect(Int(format.renderSize.width) % 2 == 0)
        #expect(abs(format.renderSize.width / format.renderSize.height - retina.width / retina.height) < 0.01)
    }

    @Test func originalKeepsSourceUnlessH264CannotEncodeIt() {
        var settings = ExportSettings()
        settings.preset = .original
        settings.codec = .hevc
        let fiveK = CGSize(width: 5120, height: 2880)
        #expect(ExportFormat(settings: settings, sourceSize: fiveK, sourceFrameRate: 30).renderSize == fiveK)
        #expect(ExportFormat(settings: settings, sourceSize: fiveK, sourceFrameRate: 30).frameRate == 30)
        settings.codec = .h264
        #expect(ExportFormat(settings: settings, sourceSize: fiveK, sourceFrameRate: 30).renderSize
            == CGSize(width: 4096, height: 2304))
        #expect(ExportFormat(settings: settings, sourceSize: retina, sourceFrameRate: 30).renderSize == retina)
    }

    @Test func proResUsesMovAndPCM() {
        var settings = ExportSettings()
        settings.preset = .proRes
        let format = ExportFormat(settings: settings, sourceSize: retina, sourceFrameRate: 60)
        #expect(format.fileType == .mov)
        #expect(format.videoCodec == .proRes422)
        #expect(format.audioSettings[AVFormatIDKey] as? AudioFormatID == kAudioFormatLinearPCM)
    }

    @Test func estimatesFileSizeFromBitRates() {
        let format = ExportFormat(settings: ExportSettings(), sourceSize: retina, sourceFrameRate: 60)
        // 10 s × (12 Mbit/s + 320 kbit/s) / 8
        #expect(format.estimatedFileSize(duration: RationalTime(value: 10, timescale: 1)) == 15_400_000)
    }

    @Test func availableURLAvoidsOverwriting() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ExportController.availableURL(in: directory, name: "Demo", extension: "mp4")
        #expect(first.lastPathComponent == "Demo.mp4")
        try Data().write(to: first)
        #expect(ExportController.availableURL(in: directory, name: "Demo", extension: "mp4").lastPathComponent
            == "Demo 2.mp4")
    }
}

/// Echter Export einer synthetischen Aufnahme (2 s Video 320 × 240 @ 30 fps, Systemton, Mikrofon).
@MainActor
struct ExporterTests {
    private func export(_ settings: ExportSettings, edit: (inout Project) -> Void = { _ in }) async throws
        -> (url: URL, format: ExportFormat, expectedDuration: Double) {
        let package = try await TestMedia.makeRecordingPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        var project = try await ProjectFactory.makeProject(forRecordingAt: package)
        edit(&project)
        let built = try await CompositionBuilder(packageURL: package).build(project)
        let format = ExportController.format(for: settings, built: built)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).\(format.fileExtension)")
        try await Exporter(built, format: format, to: url).run { _ in }
        return (url, format, built.composition.duration.seconds)
    }

    @Test func exportsYouTubeMP4() async throws {
        var settings = ExportSettings()
        settings.frameRate = 30
        let (url, format, expectedDuration) = try await export(settings) { project in
            // Ein beschleunigter Abschnitt, damit Zeitskalierung und Tonmix mit exportiert werden.
            project.timeline.tracks[0].clips[0].speed = 2
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == format.renderSize)
        #expect(format.renderSize == CGSize(width: 1440, height: 1080))
        let videoFormat = try #require(try await video.load(.formatDescriptions).first)
        #expect(videoFormat.mediaSubType == .h264)
        #expect(abs(try await video.load(.nominalFrameRate) - 30) < 0.5)

        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let audioFormat = try #require(try await audio.load(.formatDescriptions).first)
        #expect(audioFormat.mediaSubType == .mpeg4AAC)
        #expect(audioFormat.audioStreamBasicDescription?.mSampleRate == 48_000)
        #expect(audioFormat.audioStreamBasicDescription?.mChannelsPerFrame == 2)

        #expect(abs(try await asset.load(.duration).seconds - expectedDuration) < 0.1)
        #expect(try Self.moovPrecedesMdat(url))
    }

    @Test func exportsProResMov() async throws {
        var settings = ExportSettings()
        settings.preset = .proRes
        let (url, format, _) = try await export(settings)
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 320, height: 240))
        #expect(format.frameRate == 30)
        #expect(try await video.load(.formatDescriptions).first?.mediaSubType == .proRes422)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        #expect(try await audio.load(.formatDescriptions).first?.mediaSubType == .linearPCM)
    }

    @Test func cancellingRemovesPartialFile() async throws {
        let package = try await TestMedia.makeRecordingPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let project = try await ProjectFactory.makeProject(forRecordingAt: package)
        let built = try await CompositionBuilder(packageURL: package).build(project)
        var settings = ExportSettings()
        settings.resolution = .p2160
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        let exporter = try Exporter(built, format: ExportController.format(for: settings, built: built), to: url)

        let task = Task { try await exporter.run { _ in } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    /// „faststart“: Das `moov`-Atom liegt auf oberster Ebene vor `mdat`.
    private static func moovPrecedesMdat(_ url: URL) throws -> Bool {
        let data = try Data(contentsOf: url)
        var offset = 0
        var atoms: [String] = []
        while offset + 8 <= data.count {
            let size = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            atoms.append(String(decoding: data[offset + 4..<offset + 8], as: UTF8.self))
            guard size >= 8 else { break }
            offset += size
        }
        guard let moov = atoms.firstIndex(of: "moov"), let mdat = atoms.firstIndex(of: "mdat") else { return false }
        return moov < mdat
    }
}
