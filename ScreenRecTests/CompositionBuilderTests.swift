import AVFoundation
import Foundation
import Testing
@testable import ScreenRec

/// Plan-Logik ohne Mediendateien.
struct CompositionPlanTests {
    private func seconds(_ value: Double) -> RationalTime { RationalTime(seconds: value) }

    /// Ein 10-s-Video, aufgeteilt in zwei aneinanderliegende Clips mit Lücke im Quellmaterial,
    /// damit für Überblendungen Material vorhanden ist.
    private func splitProject(transition kind: Transition.Kind?, duration: Double = 1) -> Project {
        let asset = MediaAsset(id: UUID(), kind: .video, role: .screen, path: "media/screen.mov",
                               duration: seconds(10), pixelWidth: 320, pixelHeight: 240)
        let first = Clip(assetID: asset.id, sourceRange: RationalTimeRange(start: seconds(1), duration: seconds(3)),
                         timelineStart: .zero)
        let second = Clip(assetID: asset.id, sourceRange: RationalTimeRange(start: seconds(5), duration: seconds(4)),
                          timelineStart: seconds(3))
        var timeline = Timeline(tracks: [Track(kind: .video, name: "Bildschirm", clips: [first, second])])
        if let kind {
            timeline.transitions = [Transition(fromClipID: first.id, toClipID: second.id, kind: kind,
                                               duration: seconds(duration))]
        }
        return Project(assets: [asset], timeline: timeline)
    }

    @Test func hardCutStaysOnOneSlot() {
        let plan = CompositionPlan(project: splitProject(transition: nil))
        #expect(plan.segments.map(\.slot) == [0, 0])
        #expect(plan.transitions.isEmpty)
        #expect(plan.segments.allSatisfy { $0.envelope.isConstant })
    }

    @Test func crossfadeOverlapsOnTwoSlots() throws {
        let plan = CompositionPlan(project: splitProject(transition: .crossfade, duration: 1))
        let transition = try #require(plan.transitions.first)
        #expect(transition.cut == seconds(3))
        #expect(transition.duration == seconds(1))

        let first = plan.segments[0], second = plan.segments[1]
        #expect(first.slot != second.slot)
        // Der erste Clip läuft 0,5 s länger, der zweite beginnt 0,5 s früher.
        #expect(first.timelineRange == RationalTimeRange(start: .zero, duration: seconds(3.5)))
        #expect(first.sourceRange == RationalTimeRange(start: seconds(1), duration: seconds(3.5)))
        #expect(second.timelineRange == RationalTimeRange(start: seconds(2.5), duration: seconds(4.5)))
        #expect(second.sourceRange == RationalTimeRange(start: seconds(4.5), duration: seconds(4.5)))
        // Der obere (zweite) Clip wird eingeblendet, der untere bleibt voll sichtbar.
        #expect(first.envelope.isConstant)
        #expect(second.envelope.value(at: seconds(3)) == 0.5)
        // Die Gesamtdauer ändert sich durch die Überblendung nicht.
        #expect(plan.duration == seconds(7))
    }

    @Test func crossfadeIsLimitedByAvailableMaterial() throws {
        // Gewünscht 3 s, aber hinter dem ersten Clip (Quelle 1–4 s) liegen nur noch 0,4 s Material.
        var project = splitProject(transition: .crossfade, duration: 3)
        project.assets[0].duration = seconds(4.4)
        let plan = CompositionPlan(project: project)
        let transition = try #require(plan.transitions.first)
        #expect(transition.halfDuration == seconds(0.4))
    }

    @Test func crossfadeWithoutMaterialIsDropped() {
        var project = splitProject(transition: .crossfade)
        project.assets[0].duration = seconds(4)
        let plan = CompositionPlan(project: project)
        #expect(plan.transitions.isEmpty)
        #expect(plan.segments.map(\.slot) == [0, 0])
    }

    @Test func fadeThroughBlackNeedsNoExtraMaterial() throws {
        var project = splitProject(transition: .fadeThroughBlack, duration: 1)
        project.assets[0].duration = seconds(4)
        let plan = CompositionPlan(project: project)
        #expect(plan.transitions.count == 1)
        let first = plan.segments[0], second = plan.segments[1]
        #expect(first.timelineRange.end == seconds(3))
        #expect(second.timelineRange.start == seconds(3))
        #expect(first.envelope.value(at: seconds(2.75)) == 0.5)
        #expect(first.envelope.value(at: seconds(3)) == 0)
        #expect(second.envelope.value(at: seconds(3.25)) == 0.5)
    }

    /// Werte aus einem echten Projekt: Das Ende des letzten Clips und die Dauer der Composition
    /// unterscheiden sich um Bruchteile einer Nanosekunde. Früher entstand daraus ein Abschnitt
    /// der Länge null, und Vorschau und Export blieben ohne Bild.
    @Test func videoIntervalsHaveNoEmptyRangeAfterSpeedChanges() throws {
        let asset = MediaAsset(id: UUID(), kind: .video, role: .screen, path: "media/screen.mov",
                               duration: seconds(170), pixelWidth: 320, pixelHeight: 240)
        let cut = RationalTime(value: 4_446_789, timescale: 60_000)
        let first = Clip(assetID: asset.id, sourceRange: RationalTimeRange(start: .zero, duration: cut), timelineStart: .zero)
        var second = Clip(assetID: asset.id, sourceRange: RationalTimeRange(
            start: RationalTime(value: 293_180_151_230, timescale: 2_000_000_000),
            duration: RationalTime(value: 42_536_515_436, timescale: 2_000_000_000)), timelineStart: cut)
        second.speed = 1.5
        let timeline = Timeline(tracks: [Track(kind: .video, name: "Bildschirm", clips: [first, second])])
        let plan = CompositionPlan(project: Project(assets: [asset], timeline: timeline))

        let end = RationalTime(value: 88_291_988_479, timescale: 1_000_000_000)
        let intervals = plan.videoIntervals(upTo: end)
        #expect(intervals.count == 2)
        #expect(intervals.allSatisfy { $0.range.duration > .zero && !$0.layers.isEmpty })
        #expect(intervals.first?.range.start == .zero)
        #expect(intervals.last?.range.end == end)
        for (lhs, rhs) in zip(intervals, intervals.dropFirst()) {
            #expect(lhs.range.end == rhs.range.start)
        }
    }

    @Test func videoIntervalsCoverWithoutGaps() {
        let plan = CompositionPlan(project: splitProject(transition: .crossfade))
        let intervals = plan.videoIntervals(upTo: plan.duration)
        #expect(intervals.first?.range.start == .zero)
        #expect(intervals.last?.range.end == plan.duration)
        for (a, b) in zip(intervals, intervals.dropFirst()) {
            #expect(a.range.end == b.range.start)
        }
        // Während der Überblendung liegen beide Clips übereinander, der zweite oben.
        let overlap = intervals.first { $0.layers.count == 2 }
        #expect(overlap?.range == RationalTimeRange(start: seconds(2.5), duration: seconds(1)))
        #expect(overlap?.layers == [0, 1])
    }

    @Test func audioEnvelopeCombinesVolumeFadesAndMute() {
        let asset = MediaAsset(id: UUID(), kind: .audio, role: .microphone, path: "media/mic.m4a", duration: seconds(10))
        var clip = Clip(assetID: asset.id, sourceRange: RationalTimeRange(start: .zero, duration: seconds(10)),
                        timelineStart: .zero)
        clip.volume = 0.5
        clip.fadeIn = seconds(2)
        var track = Track(kind: .audio, name: "Mikrofon", clips: [clip])
        track.volume = 0.8
        var project = Project(assets: [asset], timeline: Timeline(tracks: [track]))

        let envelope = CompositionPlan(project: project).segments[0].envelope
        #expect(envelope.value(at: .zero) == 0)
        #expect(abs(envelope.value(at: seconds(1)) - 0.2) < 1e-6)
        #expect(abs(envelope.value(at: seconds(5)) - 0.4) < 1e-6)

        project.timeline.tracks[0].isMuted = true
        #expect(CompositionPlan(project: project).segments.isEmpty)
    }
}

/// Echte Compositions aus synthetischen Aufnahmen (2 s Video, Systemton, Mikrofon ab 0,5 s).
@MainActor
struct CompositionBuilderTests {
    private func seconds(_ value: Double) -> RationalTime { RationalTime(seconds: value) }

    private func withRecording(_ body: (URL, Project) async throws -> Void) async throws {
        let package = try await TestMedia.makeRecordingPackage(microphoneDelay: 0.5)
        defer { try? FileManager.default.removeItem(at: package) }
        try await body(package, try await ProjectFactory.makeProject(forRecordingAt: package))
    }

    private func expectValid(_ built: BuiltComposition) throws {
        let duration = built.composition.duration
        let videoComposition = try #require(built.videoComposition)
        let ranges = videoComposition.instructions.map(\.timeRange)
        #expect(ranges.first?.start == .zero)
        #expect(ranges.last?.end == duration)
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            #expect(a.end == b.start)
        }
    }

    @Test func untouchedRecordingMatchesTimeline() async throws {
        try await withRecording { package, project in
            let built = try await CompositionBuilder(packageURL: package).build(project)
            #expect(RationalTime(built.composition.duration) == project.timeline.duration)
            #expect(built.composition.tracks(withMediaType: .video).count == 1)
            #expect(built.composition.tracks(withMediaType: .audio).count == 2)
            #expect(built.videoComposition?.renderSize == CGSize(width: 320, height: 240))
            #expect(built.audioMix?.inputParameters.count == 2)
            try expectValid(built)
        }
    }

    @Test func speedChangesDuration() async throws {
        try await withRecording { package, project in
            var project = project
            // Video auf doppelte Geschwindigkeit, Ton entfernen: Composition dauert 1 s.
            project.timeline.tracks = [project.timeline.tracks[0]]
            project.timeline.tracks[0].clips[0].speed = 2
            let built = try await CompositionBuilder(packageURL: package).build(project)
            #expect(RationalTime(built.composition.duration) == project.timeline.duration)
            #expect(abs(built.composition.duration.seconds - 1) < 0.001)
            try expectValid(built)
        }
    }

    @Test func crossfadeBuildsTwoVideoTracksAndRenders() async throws {
        try await withRecording { package, project in
            var project = project
            // Video in zwei Teile schneiden: Quelle 0–0,8 s und 1,2–2 s, aneinander auf der Timeline.
            var first = project.timeline.tracks[0].clips[0]
            first.sourceRange = RationalTimeRange(start: .zero, duration: seconds(0.8))
            var second = first
            second.id = UUID()
            second.sourceRange = RationalTimeRange(start: seconds(1.2), duration: seconds(0.8))
            second.timelineStart = seconds(0.8)
            project.timeline.tracks = [Track(kind: .video, name: "Bildschirm", clips: [first, second])]
            project.timeline.transitions = [Transition(fromClipID: first.id, toClipID: second.id, kind: .crossfade,
                                                       duration: seconds(0.4))]

            let built = try await CompositionBuilder(packageURL: package).build(project)
            #expect(built.composition.tracks(withMediaType: .video).count == 2)
            #expect(RationalTime(built.composition.duration) == seconds(1.6))
            try expectValid(built)

            // Ein Bild mitten in der Überblendung durch den eigenen Compositor rendern.
            // Der Generator wird nur hier benutzt; `nonisolated(unsafe)` erlaubt den asynchronen Aufruf.
            nonisolated(unsafe) let generator = AVAssetImageGenerator(asset: built.composition)
            generator.videoComposition = built.videoComposition
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let image = try await generator.image(at: seconds(0.8).cmTime).image
            #expect(image.width == 320 && image.height == 240)
        }
    }
}

struct MutedClipPlanTests {
    @Test func mutedAudioClipIsSilentButKeepsVolume() throws {
        let asset = MediaAsset(id: UUID(), kind: .audio, role: .microphone, path: "media/mic.m4a",
                               duration: RationalTime(value: 4, timescale: 1))
        var clip = Clip(assetID: asset.id, sourceRange: RationalTimeRange(start: .zero, duration: asset.duration),
                        timelineStart: .zero, volume: 0.8)
        clip.isMuted = true
        let project = Project(assets: [asset], timeline: Timeline(tracks: [Track(kind: .audio, name: "Mikrofon", clips: [clip])]))
        let segment = try #require(CompositionPlan(project: project).segments.first)
        #expect(segment.envelope.value(at: RationalTime(value: 1, timescale: 1)) == 0)
        #expect(project.timeline.tracks[0].clips[0].volume == 0.8)
    }
}
