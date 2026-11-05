import CoreMedia
import os

/// Gemeinsame Zeitbasis aller Spuren einer Aufnahme.
///
/// ScreenCaptureKit stempelt Video, Systemton und Mikrofon mit der Host-Clock.
/// Die Uhr rechnet diese Host-Zeiten in Aufnahmezeit um: Sie beginnt beim ersten
/// Videoframe bei null und lässt Pausen weg, damit alle Dateien lückenlos und
/// synchron sind.
final class RecordingClock: Sendable {
    private struct State {
        var start: CMTime?
        var pauses: [(begin: CMTime, end: CMTime?)] = []
        var stop: CMTime?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    static func hostNow() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    var hasStarted: Bool {
        state.withLock { $0.start != nil }
    }

    var isPaused: Bool {
        state.withLock { $0.pauses.last.map { $0.end == nil } ?? false }
    }

    /// Legt den Startzeitpunkt fest, falls das noch nicht geschehen ist.
    func startIfNeeded(at hostTime: CMTime) {
        state.withLock { state in
            if state.start == nil { state.start = hostTime }
        }
    }

    func pause(at hostTime: CMTime = RecordingClock.hostNow()) {
        state.withLock { state in
            guard state.start != nil, state.stop == nil else { return }
            if let last = state.pauses.last {
                // Keine offene Pause und keine, die vor dem Ende der vorigen beginnt.
                guard let end = last.end, hostTime >= end else { return }
            }
            state.pauses.append((hostTime, nil))
        }
    }

    func resume(at hostTime: CMTime = RecordingClock.hostNow()) {
        state.withLock { state in
            guard let last = state.pauses.indices.last, state.pauses[last].end == nil else { return }
            state.pauses[last].end = max(hostTime, state.pauses[last].begin)
        }
    }

    /// Beendet die Uhr und liefert die Gesamtdauer der Aufnahme (ohne Pausen).
    @discardableResult
    func stop(at hostTime: CMTime = RecordingClock.hostNow()) -> CMTime {
        state.withLock { state in
            if state.stop == nil { state.stop = hostTime }
            return Self.duration(of: state, at: state.stop!)
        }
    }

    /// Bisherige Aufnahmedauer ohne Pausen.
    func elapsed(at hostTime: CMTime = RecordingClock.hostNow()) -> CMTime {
        state.withLock { Self.duration(of: $0, at: $0.stop.map { min($0, hostTime) } ?? hostTime) }
    }

    /// Rechnet einen Host-Zeitpunkt in Aufnahmezeit um.
    /// Liefert `nil` vor dem Start, während einer Pause und nach dem Stopp:
    /// Samples aus diesen Zeiträumen werden verworfen.
    func recordingTime(forHostTime hostTime: CMTime) -> CMTime? {
        state.withLock { state in
            guard let start = state.start, hostTime >= start else { return nil }
            if let stop = state.stop, hostTime > stop { return nil }
            var paused = CMTime.zero
            for pause in state.pauses {
                guard hostTime >= pause.begin else { break }
                guard let end = pause.end, hostTime >= end else { return nil }
                paused = paused + (end - pause.begin)
            }
            return hostTime - start - paused
        }
    }

    private static func duration(of state: State, at hostTime: CMTime) -> CMTime {
        guard let start = state.start, hostTime > start else { return .zero }
        var paused = CMTime.zero
        for pause in state.pauses where pause.begin < hostTime {
            paused = paused + (min(pause.end ?? hostTime, hostTime) - pause.begin)
        }
        return hostTime - start - paused
    }
}
