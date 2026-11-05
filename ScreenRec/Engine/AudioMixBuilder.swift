import AVFoundation

/// Übersetzt die Lautstärkeverläufe der Ton-Segmente in einen `AVAudioMix`.
enum AudioMixBuilder {
    static func makeAudioMix(for segments: [(segment: CompositionPlan.Segment, track: AVCompositionTrack)]) -> AVAudioMix? {
        guard !segments.isEmpty else { return nil }

        var parametersByTrack: [CMPersistentTrackID: AVMutableAudioMixInputParameters] = [:]
        for (segment, track) in segments.sorted(by: { $0.segment.timelineRange.start < $1.segment.timelineRange.start }) {
            let parameters = parametersByTrack[track.trackID] ?? AVMutableAudioMixInputParameters(track: track)
            parametersByTrack[track.trackID] = parameters

            let points = segment.envelope.points
            parameters.setVolume(Float(points[0].gain), at: segment.timelineRange.start.cmTime)
            for (a, b) in zip(points, points.dropFirst()) where a.gain != b.gain {
                parameters.setVolumeRamp(fromStartVolume: Float(a.gain), toEndVolume: Float(b.gain),
                                         timeRange: CMTimeRange(start: a.time.cmTime, end: b.time.cmTime))
            }
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = parametersByTrack.keys.sorted().map { parametersByTrack[$0]! }
        return mix
    }
}
