import Testing
@testable import ScreenRec

@MainActor
struct SmokeTests {
    @Test func appStateStartsIdle() {
        #expect(AppState().isRecording == false)
    }
}
