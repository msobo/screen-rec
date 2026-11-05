import CoreMedia
import Foundation
import Testing
@testable import ScreenRec

struct TimeMappingTests {
    private func seconds(_ value: Double) -> RationalTime { RationalTime(seconds: value) }

    private func clip(source: (Double, Double), at start: Double, speed: Double) -> Clip {
        Clip(assetID: UUID(), sourceRange: RationalTimeRange(start: seconds(source.0), duration: seconds(source.1)),
             timelineStart: seconds(start), speed: speed)
    }

    @Test(arguments: [0.25, 0.5, 1, 1.5, 2, 4, 8, 16])
    func durationsRoundTrip(speed: Double) {
        let source = seconds(12)
        let timeline = TimeMapping.timelineDuration(forSourceDuration: source, speed: speed)
        #expect(timeline == seconds(12 / speed))
        #expect(TimeMapping.sourceDuration(forTimelineDuration: timeline, speed: speed) == source)
    }

    @Test func mapsTimelineToSource() throws {
        // Quelle 10–18 s, ab Timeline 2 s mit doppelter Geschwindigkeit → Timeline 2–6 s.
        let clip = clip(source: (10, 8), at: 2, speed: 2)
        #expect(clip.timelineEnd == seconds(6))
        #expect(TimeMapping.sourceTime(forTimelineTime: seconds(2), in: clip) == seconds(10))
        #expect(TimeMapping.sourceTime(forTimelineTime: seconds(3.5), in: clip) == seconds(13))
        #expect(TimeMapping.sourceTime(forTimelineTime: seconds(1.9), in: clip) == nil)
        #expect(TimeMapping.sourceTime(forTimelineTime: seconds(6), in: clip) == nil)
    }

    @Test func mapsSourceToTimeline() {
        let clip = clip(source: (10, 8), at: 2, speed: 2)
        #expect(TimeMapping.timelineTime(forSourceTime: seconds(13), in: clip) == seconds(3.5))
        #expect(TimeMapping.timelineTime(forSourceTime: seconds(9), in: clip) == nil)
        #expect(TimeMapping.timelineTime(forSourceTime: seconds(18), in: clip) == nil)
    }

    @Test(arguments: [0.5, 1.5, 4])
    func roundTripInsideClip(speed: Double) throws {
        let clip = clip(source: (1, 6), at: 3, speed: speed)
        for step in 0..<20 {
            let time = clip.timelineStart + RationalTime(value: Int64(step), timescale: 20)
            guard clip.timelineRange.contains(time) else { continue }
            let source = try #require(TimeMapping.sourceTime(forTimelineTime: time, in: clip))
            #expect(TimeMapping.timelineTime(forSourceTime: source, in: clip) == time)
        }
    }

    @Test func clipsAtTimeAcrossTracks() {
        let first = clip(source: (0, 2), at: 0, speed: 1)
        let second = clip(source: (0, 2), at: 2, speed: 1)
        let audio = clip(source: (0, 4), at: 0.5, speed: 1)
        let timeline = Timeline(tracks: [Track(kind: .video, name: "V", clips: [first, second]),
                                         Track(kind: .audio, name: "A", clips: [audio])])
        #expect(timeline.clips(at: seconds(0.25)).map(\.clip.id) == [first.id])
        #expect(timeline.clips(at: seconds(2)).map(\.clip.id) == [second.id, audio.id])
        #expect(timeline.clips(at: seconds(5)).isEmpty)
    }
}

struct GainEnvelopeTests {
    @Test func interpolatesAndHoldsEdges() {
        let envelope = GainEnvelope(points: [.init(time: RationalTime(seconds: 1), gain: 0),
                                             .init(time: RationalTime(seconds: 3), gain: 1)])
        #expect(envelope.value(at: .zero) == 0)
        #expect(envelope.value(at: RationalTime(seconds: 2)) == 0.5)
        #expect(envelope.value(at: RationalTime(seconds: 10)) == 1)
    }

    @Test func productOfRamps() {
        let range = RationalTimeRange(start: .zero, duration: RationalTime(seconds: 10))
        let envelope = GainEnvelope.product(base: 0.5, ramps: [
            .init(start: .zero, end: RationalTime(seconds: 2), from: 0, to: 1),
            .init(start: RationalTime(seconds: 8), end: RationalTime(seconds: 10), from: 1, to: 0),
        ], over: range)
        #expect(envelope.points.map(\.gain) == [0, 0.5, 0.5, 0])
        #expect(envelope.value(at: RationalTime(seconds: 1)) == 0.25)
    }
}
