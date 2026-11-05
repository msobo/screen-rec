import AVFoundation
import CoreImage

/// Alles, was Vorschau und Export zum Abspielen brauchen. Beide verwenden genau diese Objekte,
/// damit der Export so aussieht wie die Vorschau.
struct BuiltComposition {
    let composition: AVComposition
    let videoComposition: AVVideoComposition?
    let audioMix: AVAudioMix?
    let plan: CompositionPlan
    let scene: RenderScene

    /// Beschleunigter Ton soll nicht nach Micky Maus klingen.
    static let audioTimePitchAlgorithm = AVAudioTimePitchAlgorithm.spectral

    @MainActor
    func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        item.audioTimePitchAlgorithm = Self.audioTimePitchAlgorithm
        return item
    }
}

/// Baut aus der Timeline eine `AVComposition` samt Video-Composition und Audio-Mix.
///
/// Pro Timeline-Spur entstehen bis zu zwei Composition-Spuren (A/B), damit sich Clips bei
/// Überblendungen überlappen können. Geschwindigkeit wird per `scaleTimeRange` umgesetzt.
@MainActor
final class CompositionBuilder {
    enum BuildError: LocalizedError {
        case missingAsset(MediaAsset.ID)
        case missingTrack(String)

        var errorDescription: String? {
            switch self {
            case .missingAsset: String(localized: "Ein Clip verweist auf eine Mediendatei, die nicht im Projekt steht.")
            case .missingTrack(let path): String(localized: "In \(path) fehlt die erwartete Bild- oder Tonspur.")
            }
        }
    }

    let packageURL: URL
    static let fallbackRenderSize = CGSize(width: 1920, height: 1080)
    static let fallbackFrameRate = 60

    private var assets: [String: AVURLAsset] = [:]
    /// Einmal gelesen; `nil` im inneren Optional heißt: Das Paket hat keine Cursor-Daten.
    private var cursorRecording: (data: CursorData, info: RecordingInfo)??
    private var cursorPathCache: (smoothing: Double, path: CursorPath)?
    private var cursorImagesCache: [String: RenderScene.CursorImage]?
    private var backgroundCache: (path: String, image: CIImage?)?

    init(packageURL: URL) {
        self.packageURL = packageURL
    }

    func build(_ project: Project) async throws -> BuiltComposition {
        let plan = CompositionPlan(project: project)
        let composition = AVMutableComposition()

        var tracks: [CompositionPlan.CompositionTrackKey: AVMutableCompositionTrack] = [:]
        var cursors: [CompositionPlan.CompositionTrackKey: CMTime] = [:]
        var placed: [(segment: CompositionPlan.Segment, track: AVMutableCompositionTrack)] = []
        var frameRate: Float = 0

        let ordered = plan.segments.sorted { $0.timelineRange.start < $1.timelineRange.start }
        for segment in ordered {
            guard let asset = project.asset(withID: segment.assetID) else { throw BuildError.missingAsset(segment.assetID) }
            let mediaType: AVMediaType = segment.kind == .video ? .video : .audio
            guard let sourceTrack = try await avAsset(for: asset).loadTracks(withMediaType: mediaType).first else {
                throw BuildError.missingTrack(asset.path)
            }
            if segment.kind == .video { frameRate = max(frameRate, try await sourceTrack.load(.nominalFrameRate)) }

            // Ist die Spur in der Datei etwas kürzer als gedacht, nur den vorhandenen Teil einfügen,
            // an derselben Timeline-Position wie geplant.
            let available = segment.sourceRange.cmTimeRange.intersection(try await sourceTrack.load(.timeRange))
            guard available.duration > .zero else { continue }
            let offset = TimeMapping.timelineDuration(
                forSourceDuration: RationalTime(available.start) - segment.sourceRange.start, speed: segment.speed)

            let key = segment.compositionTrackKey
            let track: AVMutableCompositionTrack
            if let existing = tracks[key] {
                track = existing
            } else if let created = composition.addMutableTrack(withMediaType: mediaType,
                                                                preferredTrackID: kCMPersistentTrackID_Invalid) {
                track = created
                tracks[key] = created
            } else {
                continue
            }

            let cursor = cursors[key] ?? .zero
            let start = max((segment.timelineRange.start + offset).cmTime, cursor)
            if start > cursor {
                track.insertEmptyTimeRange(CMTimeRange(start: cursor, end: start))
            }
            try track.insertTimeRange(available, of: sourceTrack, at: start)
            let duration = TimeMapping.timelineDuration(forSourceDuration: RationalTime(available.duration),
                                                        speed: segment.speed).cmTime
            if duration != available.duration {
                track.scaleTimeRange(CMTimeRange(start: start, duration: available.duration), toDuration: duration)
            }
            cursors[key] = start + duration
            placed.append((segment, track))
        }

        let audio = placed.filter { $0.segment.kind == .audio }.map { ($0.segment, $0.track as AVCompositionTrack) }
        let video = placed.filter { $0.segment.kind == .video }
        let scene = makeScene(for: project, plan: plan)
        return BuiltComposition(
            composition: composition,
            videoComposition: video.isEmpty ? nil : makeVideoComposition(
                plan: plan, project: project, duration: composition.duration,
                trackIDs: Dictionary(video.map { ($0.segment.clipID, $0.track.trackID) }, uniquingKeysWith: { a, _ in a }),
                frameRate: frameRate, scene: scene),
            audioMix: AudioMixBuilder.makeAudioMix(for: audio),
            plan: plan,
            scene: scene)
    }

    private func makeVideoComposition(plan: CompositionPlan, project: Project, duration: CMTime,
                                      trackIDs: [Clip.ID: CMPersistentTrackID], frameRate: Float,
                                      scene: RenderScene) -> AVVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = RenderCompositor.self
        videoComposition.renderSize = SceneLayout.renderSize(source: Self.sourceSize(for: project), aspect: project.look.aspect)
        let fps = frameRate > 0 ? Int32(frameRate.rounded()) : Int32(Self.fallbackFrameRate)
        videoComposition.frameDuration = CMTime(value: 1, timescale: fps)
        videoComposition.instructions = plan.videoIntervals(upTo: RationalTime(duration)).map { interval in
            LayerInstruction(timeRange: interval.range.cmTimeRange, layers: interval.layers.compactMap { index in
                let segment = plan.segments[index]
                return trackIDs[segment.clipID].map {
                    LayerInstruction.Layer(trackID: $0, opacity: segment.envelope, role: segment.role,
                                           sourceStart: segment.sourceRange.start.seconds,
                                           timelineStart: segment.timelineRange.start.seconds, speed: segment.speed)
                }
            }, scene: scene)
        }
        return videoComposition
    }

    // MARK: Gestaltung

    private func makeScene(for project: Project, plan: CompositionPlan) -> RenderScene {
        let look = project.look
        let recording = loadCursorRecording()
        var cursor: CursorPath?
        if let recording {
            if let cached = cursorPathCache, cached.smoothing == look.cursor.smoothing {
                cursor = cached.path
            } else {
                let path = CursorPath(data: recording.data, fallbackFrame: recording.info.source.contentRect,
                                      duration: recording.info.duration, smoothing: look.cursor.smoothing)
                cursorPathCache = (look.cursor.smoothing, path)
                cursor = path
            }
        }
        let zoom = ZoomPath(zooms: project.timeline.zooms, duration: plan.duration.seconds) { t in
            plan.screenSourceTime(at: RationalTime(seconds: t)).flatMap { cursor?.position(at: $0) }
        }
        return RenderScene(look: look, sourceSize: Self.sourceSize(for: project),
                           backgroundImage: look.background.kind == .image ? backgroundImage(look.background.imagePath) : nil,
                           cursor: cursor, cursorImages: look.cursor.isVisible ? cursorImages(recording?.data) : [:],
                           zoom: zoom, placements: project.annotationPlacements)
    }

    private func loadCursorRecording() -> (data: CursorData, info: RecordingInfo)? {
        if let cursorRecording { return cursorRecording }
        let loaded = CursorData.load(fromPackage: packageURL)
        cursorRecording = .some(loaded)
        return loaded
    }

    private func cursorImages(_ data: CursorData?) -> [String: RenderScene.CursorImage] {
        if let cursorImagesCache { return cursorImagesCache }
        let images = data.map(RenderScene.cursorImages(from:)) ?? [:]
        cursorImagesCache = images
        return images
    }

    private func backgroundImage(_ path: String?) -> CIImage? {
        guard let path else { return nil }
        if let backgroundCache, backgroundCache.path == path { return backgroundCache.image }
        let image = CIImage(contentsOf: packageURL.appending(path: path))
        backgroundCache = (path, image)
        return image
    }

    // MARK: Größe

    /// Größte Auflösung unter den verwendeten Bildschirmquellen, damit nichts unnötig verkleinert wird.
    /// Die Kamera zählt nicht mit, sie wird nur klein eingeblendet.
    static func sourceSize(for project: Project) -> CGSize {
        let usedAssetIDs = Set(project.timeline.tracks.filter { $0.kind == .video }.flatMap(\.clips).map(\.assetID))
        let sizes = project.assets.filter { usedAssetIDs.contains($0.id) && $0.role != .camera }.compactMap { asset -> CGSize? in
            guard let width = asset.pixelWidth, let height = asset.pixelHeight else { return nil }
            return CGSize(width: width, height: height)
        }
        return sizes.max { $0.width * $0.height < $1.width * $1.height } ?? Self.fallbackRenderSize
    }

    private func avAsset(for asset: MediaAsset) -> AVURLAsset {
        if let cached = assets[asset.path] { return cached }
        let avAsset = AVURLAsset(url: packageURL.appending(path: asset.path),
                                 options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        assets[asset.path] = avAsset
        return avAsset
    }
}
