import ScreenCaptureKit

/// Zeigt den systemeigenen Auswahldialog für Bildschirm, Fenster oder App.
///
/// `SCContentSharingPicker` braucht keine vorab erteilte Bildschirmaufnahme-Berechtigung:
/// Die Auswahl durch den Nutzer gilt selbst als Zustimmung.
@MainActor
final class SourcePicker: NSObject, SCContentSharingPickerObserver {
    private var continuation: CheckedContinuation<SCContentFilter?, any Error>?

    /// Liefert den gewählten Filter oder `nil`, wenn der Nutzer abbricht.
    func pick(_ kind: RecordingOptions.SourceKind) async throws -> SCContentFilter? {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = switch kind {
        case .display: .singleDisplay
        case .window: .singleWindow
        case .application: .singleApplication
        }
        if let bundleID = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleID]
        }
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation?.resume(returning: nil)
            self.continuation = continuation
            picker.present()
        }
    }

    /// Nach Ende der Aufnahme aufrufen, damit macOS den Picker nicht mehr als aktiv anzeigt.
    func deactivate() {
        let picker = SCContentSharingPicker.shared
        picker.remove(self)
        picker.isActive = false
    }

    private func complete(with result: sending Result<SCContentFilter?, any Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }

    // MARK: SCContentSharingPickerObserver

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter,
                                          for stream: SCStream?) {
        nonisolated(unsafe) let filter = filter
        Task { @MainActor in self.complete(with: .success(filter)) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.complete(with: .success(nil)) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in self.complete(with: .failure(error)) }
    }
}
