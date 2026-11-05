import AVFoundation
import Testing
@testable import ScreenRec

/// Schreibt synthetische Video- und Audio-Samples und prüft die entstandenen Dateien.
struct CaptureWriterTests {
    @Test func writesSeparateFilesWithPausesRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let clock = RecordingClock()
        let writer = CaptureWriter(directory: directory, clock: clock, videoSize: CGSize(width: 320, height: 240),
                                   frameRate: 30, realTime: false)

        // Audio vor dem ersten Videoframe muss verworfen werden.
        let early = try makeAudioSample(at: host(-0.5), frames: 4_800)
        writer.queue.sync { writer.write(early, to: .microphone) }

        // 3 s Aufnahme, Pause von 1 s bis 2 s → 2 s Ergebnis.
        for frame in 0..<90 {
            let time = Double(frame) / 30
            if frame == 30 { clock.pause(at: host(1)) }
            if frame == 60 { clock.resume(at: host(2)) }
            let sample = try makeVideoSample(at: host(time))
            writer.queue.sync {
                writer.write(sample, to: .screen)
                // Die Kamera läuft mit derselben Uhr mit.
                writer.write(sample, to: .camera)
            }
        }
        for chunk in 0..<30 {
            let sample = try makeAudioSample(at: host(Double(chunk) * 0.1), frames: 4_800)
            writer.queue.sync {
                writer.write(sample, to: .systemAudio)
                // Das Mikrofon setzt wie in echt verzögert ein.
                if chunk >= 5 { writer.write(sample, to: .microphone) }
            }
        }

        let output = try await writer.finish(at: host(3))
        #expect(abs(output.duration.seconds - 2) < 0.001)
        #expect(Set(output.files.keys) == [.screen, .systemAudio, .microphone, .camera])
        #expect(output.droppedFrames == 0)
        #expect(output.startOffsets[.screen] == .zero)
        #expect(output.startOffsets[.systemAudio] == .zero)
        #expect(abs((output.startOffsets[.microphone]?.seconds ?? 0) - 0.5) < 0.001)

        for track in CaptureWriter.Track.allCases {
            let asset = AVURLAsset(url: try #require(output.files[track]))
            let duration = try await asset.load(.duration).seconds
            let expected = 2 - (output.startOffsets[track]?.seconds ?? 0)
            #expect(abs(duration - expected) < 0.05, "\(track): \(duration)")
        }
        let videoTrack = try #require(try await AVURLAsset(url: output.files[.screen]!).loadTracks(withMediaType: .video).first)
        #expect(try await videoTrack.load(.naturalSize) == CGSize(width: 320, height: 240))
    }

    @Test func failsWithoutVideo() async {
        let clock = RecordingClock()
        let writer = CaptureWriter(directory: FileManager.default.temporaryDirectory, clock: clock,
                                   videoSize: CGSize(width: 320, height: 240), frameRate: 30, realTime: false)
        await #expect(throws: CaptureWriter.WriterError.self) {
            _ = try await writer.finish()
        }
    }

    private func host(_ seconds: Double) -> CMTime { TestMedia.host(seconds) }
    private func makeVideoSample(at time: CMTime) throws -> CMSampleBuffer { try TestMedia.videoSample(at: time) }
    private func makeAudioSample(at time: CMTime, frames: Int) throws -> CMSampleBuffer {
        try TestMedia.audioSample(at: time, frames: frames)
    }
}
