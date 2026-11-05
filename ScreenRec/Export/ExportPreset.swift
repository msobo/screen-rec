import AVFoundation
import VideoToolbox

/// Zuletzt benutzte Exporteinstellungen, gespeichert im Projekt.
struct ExportSettings: Codable, Equatable, Sendable {
    enum Preset: String, Codable, CaseIterable, Sendable {
        /// MP4 nach den Upload-Empfehlungen von YouTube.
        case youTube
        /// Auflösung und Bildrate der Aufnahme, MP4.
        case original
        /// ProRes 422 in MOV mit unkomprimiertem Ton, zum Archivieren oder Weiterbearbeiten.
        case proRes
        /// Animiertes GIF ohne Ton, z. B. für Dokumentation und Chats.
        case gif

        var title: String {
            switch self {
            case .youTube: "YouTube"
            case .original: String(localized: "Original")
            case .proRes: String(localized: "ProRes (Archiv)")
            case .gif: "GIF"
            }
        }
    }

    enum Resolution: Int, Codable, CaseIterable, Sendable {
        case p1080 = 1080, p1440 = 1440, p2160 = 2160

        var title: String { self == .p2160 ? "4K" : "\(rawValue)p" }
        /// 16:9-Rahmen, in den das Bild eingepasst wird.
        var box: CGSize { CGSize(width: rawValue * 16 / 9, height: rawValue) }
    }

    enum Codec: String, Codable, CaseIterable, Sendable {
        case h264, hevc

        var title: String { self == .h264 ? "H.264" : "HEVC (H.265)" }
    }

    var preset = Preset.youTube
    var resolution = Resolution.p1080
    var frameRate = 60
    var codec = Codec.h264
    /// Zielordner; `nil` heißt „Filme“ im Benutzerordner.
    var directoryPath: String?
    /// Lange Seite des GIFs in Pixeln.
    var gifSize = 800
    var gifFrameRate = 15

    static let frameRates = [30, 60]
    static let gifSizes = [480, 640, 800, 1080]
    static let gifFrameRates = [10, 15, 20, 25]

    var directoryURL: URL {
        directoryPath.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? .moviesDirectory
    }
}

/// Die konkreten Parameter einer Ausgabedatei, abgeleitet aus Einstellungen und Quellmaterial.
struct ExportFormat: Equatable, Sendable {
    enum VideoCodec: Equatable, Sendable { case h264, hevc, proRes422, gif }

    /// `nil` bei GIF, das nicht über `AVAssetWriter` entsteht.
    var fileType: AVFileType?
    var videoCodec: VideoCodec
    var renderSize: CGSize
    var frameRate: Int
    /// Bit/s; bei ProRes nur geschätzt, der Encoder hat eine feste Qualitätsstufe.
    var videoBitRate: Int
    /// Bit/s; bei ProRes PCM mit 24 Bit.
    var audioBitRate: Int

    static let audioSampleRate = 48_000
    static let audioChannels = 2
    /// YouTube empfiehlt 384 kbit/s, Apples AAC-Encoder schafft für Stereo aber höchstens 320 kbit/s.
    static let aacBitRate = 320_000
    /// 48 kHz × 24 Bit × 2 Kanäle.
    static let pcmBitRate = audioSampleRate * 24 * audioChannels
    /// Größte Bildfläche, die H.264 (Level 5.2) noch kodiert.
    static let h264MaxSize = CGSize(width: 4096, height: 2304)

    var fileExtension: String {
        switch videoCodec {
        case .gif: "gif"
        case .proRes422: "mov"
        case .h264, .hevc: "mp4"
        }
    }

    /// Empfohlene Bitraten für SDR-Uploads laut YouTube-Hilfe, in Mbit/s.
    static func youTubeBitRate(height: Int, frameRate: Int) -> Int {
        let highFrameRate = frameRate > 30
        let mbps = switch height {
        case ..<1440: highFrameRate ? 12 : 8
        case ..<2160: highFrameRate ? 24 : 16
        default: highFrameRate ? 53 : 40
        }
        return mbps * 1_000_000
    }

    /// - Parameters:
    ///   - sourceSize: Render-Größe der Composition (größte verwendete Bildquelle).
    ///   - sourceFrameRate: Bildrate der Composition.
    init(settings: ExportSettings, sourceSize: CGSize, sourceFrameRate: Int) {
        switch settings.preset {
        case .youTube:
            fileType = .mp4
            videoCodec = settings.codec == .h264 ? .h264 : .hevc
            frameRate = settings.frameRate
            renderSize = Self.fit(sourceSize, in: settings.resolution.box)
            videoBitRate = Self.youTubeBitRate(height: settings.resolution.rawValue, frameRate: frameRate)
            audioBitRate = Self.aacBitRate
        case .original:
            fileType = .mp4
            videoCodec = settings.codec == .h264 ? .h264 : .hevc
            frameRate = sourceFrameRate
            renderSize = videoCodec == .h264 && !Self.fits(sourceSize, in: Self.h264MaxSize)
                ? Self.fit(sourceSize, in: Self.h264MaxSize) : Self.even(sourceSize)
            // So viele Bits pro Pixel wie in der YouTube-Tabelle (4K60: 53 Mbit/s ≈ 0,1).
            videoBitRate = Int(renderSize.width * renderSize.height * Double(frameRate) * 0.1)
            audioBitRate = Self.aacBitRate
        case .proRes:
            fileType = .mov
            videoCodec = .proRes422
            frameRate = sourceFrameRate
            renderSize = Self.even(sourceSize)
            // Apples Angabe für ProRes 422: 1080p30 ≈ 147 Mbit/s, also ≈ 2,4 Bit pro Pixel.
            videoBitRate = Int(renderSize.width * renderSize.height * Double(frameRate) * 2.36)
            audioBitRate = Self.pcmBitRate
        case .gif:
            fileType = nil
            videoCodec = .gif
            frameRate = settings.gifFrameRate
            renderSize = Self.fit(sourceSize, in: CGSize(width: settings.gifSize, height: settings.gifSize))
            // Erfahrungswert für Bildschirminhalte: etwa 0,6 Bit pro Pixel und Bild.
            videoBitRate = Int(renderSize.width * renderSize.height * Double(frameRate) * 0.6)
            audioBitRate = 0
        }
    }

    /// Geschätzte Dateigröße in Byte.
    func estimatedFileSize(duration: RationalTime) -> Int64 {
        Int64(Double(videoBitRate + audioBitRate) * max(duration.seconds, 0) / 8)
    }

    var summary: String {
        let codec = switch videoCodec {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .proRes422: "ProRes 422"
        case .gif: "GIF"
        }
        if videoCodec == .gif {
            return String(localized: "\(Int(renderSize.width)) × \(Int(renderSize.height)), \(frameRate) fps, \(codec) · ohne Ton")
        }
        let audio = videoCodec == .proRes422 ? String(localized: "PCM 24 Bit") : "AAC \(audioBitRate / 1000) kbit/s"
        let bitRate = videoCodec == .proRes422 ? "" : ", \(videoBitRate / 1_000_000) Mbit/s"
        return "\(Int(renderSize.width)) × \(Int(renderSize.height)), \(frameRate) fps, \(codec)\(bitRate) · \(audio)"
    }

    // MARK: Einstellungen für AVAssetWriter

    var videoSettings: [String: Any] {
        var settings: [String: Any] = [
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height),
            // Bildschirmaufnahmen sind sRGB; YouTube erwartet BT.709.
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        switch videoCodec {
        case .h264, .hevc:
            settings[AVVideoCodecKey] = videoCodec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: videoBitRate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                // YouTube empfiehlt eine geschlossene GOP von einer halben Bildrate.
                AVVideoMaxKeyFrameIntervalKey: max(frameRate / 2, 1),
                AVVideoAllowFrameReorderingKey: true,
            ]
            if videoCodec == .h264 {
                compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
                compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
            } else {
                compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
            }
            settings[AVVideoCompressionPropertiesKey] = compression
        case .proRes422:
            settings[AVVideoCodecKey] = AVVideoCodecType.proRes422
        case .gif:
            break
        }
        return settings
    }

    var audioSettings: [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        var settings: [String: Any] = [
            AVSampleRateKey: Self.audioSampleRate,
            AVNumberOfChannelsKey: Self.audioChannels,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
        if videoCodec == .proRes422 {
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 24
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        } else {
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = audioBitRate
        }
        return settings
    }

    // MARK: Größen

    /// Seitenverhältnis erhalten, in `box` einpassen; gerade Kantenlängen, wie die Encoder sie brauchen.
    static func fit(_ size: CGSize, in box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return even(box) }
        let scale = min(box.width / size.width, box.height / size.height)
        return even(CGSize(width: size.width * scale, height: size.height * scale))
    }

    private static func fits(_ size: CGSize, in box: CGSize) -> Bool {
        // Hochformat ebenso zulassen.
        let long = max(size.width, size.height), short = min(size.width, size.height)
        return long <= box.width && short <= box.height
    }

    static func even(_ size: CGSize) -> CGSize {
        CGSize(width: max(2, (size.width / 2).rounded() * 2), height: max(2, (size.height / 2).rounded() * 2))
    }
}
