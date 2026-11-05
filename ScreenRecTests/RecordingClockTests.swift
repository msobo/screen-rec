import CoreMedia
import Testing
@testable import ScreenRec

struct RecordingClockTests {
    private func t(_ seconds: Double) -> CMTime { CMTime(seconds: 1_000 + seconds, preferredTimescale: 600) }

    @Test func dropsSamplesBeforeStart() {
        let clock = RecordingClock()
        #expect(clock.recordingTime(forHostTime: t(0)) == nil)
        clock.startIfNeeded(at: t(1))
        #expect(clock.recordingTime(forHostTime: t(0.5)) == nil)
        #expect(clock.recordingTime(forHostTime: t(1))?.seconds == 0)
        #expect(clock.recordingTime(forHostTime: t(3))?.seconds == 2)
    }

    @Test func firstStartWins() {
        let clock = RecordingClock()
        clock.startIfNeeded(at: t(1))
        clock.startIfNeeded(at: t(5))
        #expect(clock.recordingTime(forHostTime: t(2))?.seconds == 1)
    }

    @Test func pausesAreRemoved() {
        let clock = RecordingClock()
        clock.startIfNeeded(at: t(0))
        clock.pause(at: t(2))
        #expect(clock.isPaused)
        // Ein Sample aus der Pause, das erst nach dem Fortsetzen eintrifft, wird trotzdem verworfen.
        clock.resume(at: t(5))
        #expect(!clock.isPaused)
        #expect(clock.recordingTime(forHostTime: t(3)) == nil)
        #expect(clock.recordingTime(forHostTime: t(1))?.seconds == 1)
        #expect(clock.recordingTime(forHostTime: t(6))?.seconds == 3)

        clock.pause(at: t(7))
        clock.resume(at: t(8))
        #expect(clock.recordingTime(forHostTime: t(10))?.seconds == 6)
    }

    @Test func ignoresPauseBeforePreviousResume() {
        let clock = RecordingClock()
        clock.startIfNeeded(at: t(0))
        clock.pause(at: t(2))
        clock.resume(at: t(4))
        clock.pause(at: t(3))
        #expect(!clock.isPaused)
        #expect(clock.recordingTime(forHostTime: t(5))?.seconds == 3)
    }

    @Test func elapsedAndStopExcludePauses() {
        let clock = RecordingClock()
        clock.startIfNeeded(at: t(0))
        clock.pause(at: t(4))
        #expect(clock.elapsed(at: t(6)).seconds == 4)
        clock.resume(at: t(6))
        #expect(clock.stop(at: t(10)).seconds == 8)
        #expect(clock.recordingTime(forHostTime: t(11)) == nil)
        #expect(clock.elapsed(at: t(20)).seconds == 8)
    }
}
