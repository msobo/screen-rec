import AppKit
import AVFoundation
import Observation

/// Steuert den Ablauf: Quelle wählen → Countdown → Aufnahme (mit Pause) → Stopp.
@MainActor
@Observable
final class AppState {
    enum Phase: Equatable {
        case idle
        case selectingSource
        case countdown(Int)
        case recording
        case paused
        case finishing
    }

    private(set) var phase: Phase = .idle
    /// Aufnahmedauer ohne Pausen, in Sekunden.
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastRecording: URL?
    var errorMessage: String?

    var isRecording: Bool { phase == .recording || phase == .paused }

    @ObservationIgnored private let picker = SourcePicker()
    @ObservationIgnored private var session: RecordingSession?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var elapsedTask: Task<Void, Never>?

    func toggleRecording() {
        switch phase {
        case .idle: startRecording()
        case .countdown: startTask?.cancel()
        case .recording, .paused: stopRecording()
        case .selectingSource, .finishing: break
        }
    }

    func togglePause() {
        guard let session else { return }
        switch phase {
        case .recording:
            session.pause()
            phase = .paused
        case .paused:
            session.resume()
            phase = .recording
        default:
            break
        }
    }

    func revealLastRecording() {
        guard let lastRecording else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastRecording])
    }

    func openProject(at url: URL) async throws {
        _ = try await NSDocumentController.shared.openDocument(withContentsOf: url, display: true)
        NSApplication.shared.activate()
    }

    // MARK: Ablauf

    private func startRecording() {
        errorMessage = nil
        startTask = Task {
            do {
                phase = .selectingSource
                var options = RecordingOptions.load()
                guard let filter = try await picker.pick(options.sourceKind) else {
                    picker.deactivate()
                    phase = .idle
                    return
                }

                if options.captureMicrophone, await !Self.requestAccess(for: .audio) {
                    options.captureMicrophone = false
                    errorMessage = String(localized: "Kein Mikrofonzugriff – es wird ohne Mikrofon aufgenommen.")
                }
                if options.captureCamera, await !Self.requestAccess(for: .video) {
                    options.captureCamera = false
                    errorMessage = String(localized: "Kein Kamerazugriff – es wird ohne Kamera aufgenommen.")
                }
                if options.keystrokeMode != .off, !KeystrokePermission.isGranted(prompt: true) {
                    options.keystrokeMode = .off
                    errorMessage = String(localized: "Tastenanschläge brauchen die Freigabe unter Bedienungshilfen und werden diesmal nicht aufgezeichnet.")
                }

                try await CountdownOverlay.run(seconds: options.countdownSeconds) { self.phase = .countdown($0) }

                let session = try RecordingSession(filter: filter, options: options)
                session.onUnexpectedStop = { error in
                    self.errorMessage = String(localized: "Aufnahme wurde beendet: \(error.localizedDescription)")
                    self.stopRecording()
                }
                try await session.start()
                self.session = session
                phase = .recording
                startElapsedUpdates(clock: session.clock)
            } catch is CancellationError {
                picker.deactivate()
                phase = .idle
            } catch {
                picker.deactivate()
                errorMessage = String(localized: "Aufnahme konnte nicht gestartet werden: \(error.localizedDescription)")
                phase = .idle
            }
        }
    }

    private func stopRecording() {
        guard let session, phase != .finishing else { return }
        phase = .finishing
        elapsedTask?.cancel()
        Task {
            do {
                let result = try await session.stop()
                lastRecording = result.package
                try await ProjectFactory.createProjectFile(forRecordingAt: result.package)
                try await openProject(at: result.package)
            } catch {
                errorMessage = String(localized: "Aufnahme konnte nicht gespeichert werden: \(error.localizedDescription)")
            }
            self.session = nil
            picker.deactivate()
            elapsed = 0
            phase = .idle
        }
    }

    private func startElapsedUpdates(clock: RecordingClock) {
        elapsedTask = Task {
            while !Task.isCancelled {
                elapsed = clock.elapsed().seconds
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private static func requestAccess(for mediaType: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: mediaType)
        default: false
        }
    }
}

/// Globale Tastendrücke kommen nur an, wenn die App unter „Bedienungshilfen“ freigegeben ist.
enum KeystrokePermission {
    static func isGranted(prompt: Bool) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
