import AppKit
import CoreImage
import Testing
@testable import ScreenRec

@MainActor
struct SmokeTests {
    @Test func appStateStartsIdle() {
        #expect(AppState().isRecording == false)
    }

    @Test func supportQrCodeMatchesLink() throws {
        let image = try #require(NSImage(named: "SupportQr")?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                               options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let codes = detector.features(in: CIImage(cgImage: image)).compactMap { $0 as? CIQRCodeFeature }
        #expect(codes.first?.messageString == AboutView.supportURL.absoluteString)
    }
}
