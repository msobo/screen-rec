import AppKit
import Observation

/// Steuert den Export eines Editorfensters. Der Export läuft im Hintergrund weiter, während man
/// schneidet; er arbeitet mit dem Projektstand zum Zeitpunkt des Starts.
@MainActor
@Observable
final class ExportController {
    enum State: Equatable {
        case idle
        case running(progress: Double, url: URL)
        case finished(URL)
        case failed(String)
    }

    private(set) var state = State.idle
    var isSheetPresented = false

    var isRunning: Bool {
        if case .running = state { true } else { false }
    }

    @ObservationIgnored private let packageURL: URL
    @ObservationIgnored private var task: Task<Void, Never>?

    init(packageURL: URL) {
        self.packageURL = packageURL
    }

    func start(_ project: Project, fileName: String) {
        guard !isRunning else { return }
        let settings = project.exportSettings
        let directory = settings.directoryURL
        task = Task {
            do {
                let built = try await CompositionBuilder(packageURL: packageURL).build(project)
                let format = Self.format(for: settings, built: built)
                let url = Self.availableURL(in: directory, name: fileName, extension: format.fileExtension)
                state = .running(progress: 0, url: url)
                let progress: @MainActor @Sendable (Double) -> Void = { [weak self] fraction in
                    guard let self, case .running(_, let url) = state else { return }
                    state = .running(progress: fraction, url: url)
                }
                if format.videoCodec == .gif {
                    try await GIFExporter(built, format: format, to: url).run(progress: progress)
                } else {
                    try await Exporter(built, format: format, to: url).run(progress: progress)
                }
                state = .finished(url)
                if !NSApplication.shared.isActive { NSApplication.shared.requestUserAttention(.informationalRequest) }
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func dismissResult() {
        if !isRunning { state = .idle }
    }

    // MARK: Hilfen

    static func format(for settings: ExportSettings, built: BuiltComposition?) -> ExportFormat {
        let videoComposition = built?.videoComposition
        let frameDuration = videoComposition?.frameDuration.seconds ?? 0
        return ExportFormat(
            settings: settings,
            sourceSize: videoComposition?.renderSize ?? CompositionBuilder.fallbackRenderSize,
            sourceFrameRate: frameDuration > 0 ? Int((1 / frameDuration).rounded()) : CompositionBuilder.fallbackFrameRate)
    }

    /// `Name.mp4`, oder `Name 2.mp4` usw., falls es die Datei schon gibt.
    nonisolated static func availableURL(in directory: URL, name: String, extension fileExtension: String) -> URL {
        let base = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        let name = base.isEmpty ? "Export" : base
        var url = directory.appending(path: "\(name).\(fileExtension)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            url = directory.appending(path: "\(name) \(counter).\(fileExtension)")
            counter += 1
        }
        return url
    }
}
