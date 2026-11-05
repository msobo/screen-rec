import Foundation
import Testing
@testable import ScreenRec

struct EditCommandsTests {
    private func seconds(_ value: Double) -> RationalTime { RationalTime(seconds: value) }

    /// Wie eine frische Aufnahme: 10 s Bild und Systemton ab 0, Mikrofon ab 0,5 s, alles verknüpft.
    private func recording() -> (timeline: Timeline, durations: [MediaAsset.ID: RationalTime]) {
        let group = UUID()
        let screen = UUID(), system = UUID(), mic = UUID()
        func clip(_ asset: UUID, start: Double, length: Double) -> Clip {
            Clip(assetID: asset, sourceRange: RationalTimeRange(start: .zero, duration: seconds(length)),
                 timelineStart: seconds(start), linkGroupID: group)
        }
        let timeline = Timeline(tracks: [
            Track(kind: .video, name: "Bildschirm", clips: [clip(screen, start: 0, length: 10)]),
            Track(kind: .audio, name: "Systemton", clips: [clip(system, start: 0, length: 10)]),
            Track(kind: .audio, name: "Mikrofon", clips: [clip(mic, start: 0.5, length: 9.5)]),
        ])
        return (timeline, [screen: seconds(10), system: seconds(10), mic: seconds(9.5)])
    }

    private func ends(_ timeline: Timeline) -> [RationalTime] {
        timeline.tracks.map { $0.clips.last!.timelineEnd }
    }

    // MARK: Split

    @Test func splitCutsAllLinkedClipsAndRegroupsRightHalves() throws {
        var (timeline, _) = recording()
        let before = timeline.duration
        #expect(EditCommands.split(&timeline, at: seconds(4)))

        #expect(timeline.tracks.allSatisfy { $0.clips.count == 2 })
        #expect(timeline.hasValidLayout)
        #expect(timeline.duration == before)
        let left = timeline.tracks.map { $0.clips[0] }, right = timeline.tracks.map { $0.clips[1] }
        #expect(Set(left.compactMap(\.linkGroupID)).count == 1)
        #expect(Set(right.compactMap(\.linkGroupID)).count == 1)
        #expect(left[0].linkGroupID != right[0].linkGroupID)
        // Das Mikrofon beginnt 0,5 s später, also liegt sein Schnitt bei 3,5 s Quellzeit.
        #expect(right[2].sourceRange.start == seconds(3.5))
        #expect(right.allSatisfy { $0.timelineStart == seconds(4) })
    }

    @Test func splitRespectsSpeedAndMovesTransition() throws {
        let asset = UUID()
        let first = Clip(assetID: asset, sourceRange: RationalTimeRange(start: .zero, duration: seconds(6)),
                         timelineStart: .zero, speed: 1.5)
        let second = Clip(assetID: asset, sourceRange: RationalTimeRange(start: seconds(7), duration: seconds(2)),
                          timelineStart: first.timelineEnd)
        var timeline = Timeline(tracks: [Track(kind: .video, name: "V", clips: [first, second])])
        timeline.transitions = [Transition(fromClipID: first.id, toClipID: second.id, kind: .crossfade, duration: seconds(1))]

        #expect(EditCommands.split(&timeline, at: seconds(2), clips: [first.id]))
        let clips = timeline.tracks[0].clips
        #expect(clips.count == 3)
        #expect(clips[0].sourceRange.duration == seconds(3))
        #expect(clips[1].timelineEnd == second.timelineStart)
        #expect(timeline.transitions.first?.fromClipID == clips[1].id)
    }

    @Test func splitIgnoresEdges() {
        var (timeline, _) = recording()
        #expect(!EditCommands.split(&timeline, at: .zero))
        #expect(!EditCommands.split(&timeline, at: seconds(10)))
    }

    // MARK: Trim

    @Test func trimStartCutsIntoLaterStartingLinkedClip() {
        var (timeline, durations) = recording()
        let video = timeline.tracks[0].clips[0]
        let applied = EditCommands.trim(&timeline, clip: video.id, edge: .start, by: seconds(1), assetDurations: durations)

        #expect(applied == seconds(1))
        #expect(timeline.tracks.allSatisfy { $0.clips[0].timelineStart == seconds(1) })
        // Mikrofon: 0,5 s seines Materials fallen weg, Ende bleibt synchron.
        #expect(timeline.tracks[2].clips[0].sourceRange.start == seconds(0.5))
        #expect(Set(ends(timeline)) == [seconds(10)])
    }

    @Test func trimIsLimitedByMaterialAndMinimumLength() {
        var (timeline, durations) = recording()
        let video = timeline.tracks[0].clips[0]
        // Hinter dem Ende gibt es kein Material mehr.
        #expect(EditCommands.trim(&timeline, clip: video.id, edge: .end, by: seconds(2), assetDurations: durations) == .zero)
        // Weiter als bis zur Mindestlänge geht es nicht.
        let applied = EditCommands.trim(&timeline, clip: video.id, edge: .end, by: seconds(-20), assetDurations: durations)
        #expect(applied == seconds(0.5) + EditCommands.minimumClipDuration - seconds(10))
        #expect(timeline.hasValidLayout)
        #expect(timeline.tracks.allSatisfy { $0.clips[0].timelineDuration >= EditCommands.minimumClipDuration })
    }

    @Test func trimIsLimitedByNeighbour() throws {
        var (timeline, durations) = recording()
        EditCommands.split(&timeline, at: seconds(4))
        let left = timeline.tracks[0].clips[0]
        EditCommands.trim(&timeline, clip: left.id, edge: .end, by: seconds(-1), assetDurations: durations)
        // Zurück nach rechts nur bis an den Nachbarn.
        let applied = EditCommands.trim(&timeline, clip: left.id, edge: .end, by: seconds(3), assetDurations: durations)
        #expect(applied == seconds(1))
        #expect(timeline.hasValidLayout)
    }

    // MARK: Move

    @Test func moveTakesLinkedClipsAlong() throws {
        let (timeline, _) = recording()
        let moved = try #require(EditCommands.move(timeline, clips: [timeline.tracks[1].clips[0].id], by: seconds(2)))
        #expect(moved.tracks[0].clips[0].timelineStart == seconds(2))
        #expect(moved.tracks[2].clips[0].timelineStart == seconds(2.5))
        #expect(EditCommands.move(timeline, clips: [timeline.tracks[0].clips[0].id], by: seconds(-1)) == nil)
    }

    @Test func moveToOtherTrackOfSameKindOnly() throws {
        var (timeline, _) = recording()
        EditCommands.unlink(&timeline, clips: [timeline.tracks[0].clips[0].id])
        EditCommands.delete(&timeline, clips: [timeline.tracks[2].clips[0].id], ripple: false)
        let system = timeline.tracks[1], mic = timeline.tracks[2], video = timeline.tracks[0]

        let moved = try #require(EditCommands.move(timeline, clips: [system.clips[0].id], by: .zero,
                                                   from: system.id, to: mic.id))
        #expect(moved.tracks[1].clips.isEmpty)
        #expect(moved.tracks[2].clips.count == 1)
        #expect(EditCommands.move(timeline, clips: [system.clips[0].id], by: .zero, from: system.id, to: video.id) == nil)
    }

    @Test func moveRejectsOverlap() {
        var (timeline, _) = recording()
        EditCommands.split(&timeline, at: seconds(4))
        EditCommands.unlink(&timeline, clips: Set(timeline.tracks.flatMap(\.clips).map(\.id)))
        let right = timeline.tracks[0].clips[1]
        #expect(EditCommands.move(timeline, clips: [right.id], by: seconds(-1)) == nil)
        #expect(EditCommands.move(timeline, clips: [right.id], by: seconds(1)) != nil)
    }

    // MARK: Delete

    @Test func rippleDeleteClosesGapOnAllLinkedTracks() {
        var (timeline, _) = recording()
        EditCommands.split(&timeline, at: seconds(2))
        EditCommands.split(&timeline, at: seconds(5))
        let middle = timeline.tracks[0].clips[1]

        EditCommands.delete(&timeline, clips: [middle.id], ripple: true)
        #expect(timeline.tracks.allSatisfy { $0.clips.count == 2 })
        #expect(timeline.duration == seconds(7))
        #expect(timeline.hasValidLayout)
        #expect(timeline.tracks.allSatisfy { $0.clips[1].timelineStart == seconds(2) })
        #expect(Set(ends(timeline)) == [seconds(7)])
    }

    @Test func deleteKeepsGap() {
        var (timeline, _) = recording()
        EditCommands.split(&timeline, at: seconds(2))
        EditCommands.split(&timeline, at: seconds(5))
        EditCommands.delete(&timeline, clips: [timeline.tracks[0].clips[1].id], ripple: false)
        #expect(timeline.duration == seconds(10))
        #expect(timeline.tracks[0].clips[1].timelineStart == seconds(5))
    }

    @Test func deleteRemovesTransitions() {
        var (timeline, _) = recording()
        EditCommands.split(&timeline, at: seconds(5))
        let clips = timeline.tracks[0].clips
        timeline.transitions = [Transition(fromClipID: clips[0].id, toClipID: clips[1].id, kind: .crossfade, duration: seconds(1))]
        EditCommands.delete(&timeline, clips: [clips[1].id], ripple: false)
        #expect(timeline.transitions.isEmpty)
    }

    // MARK: Link

    @Test func linkAndUnlink() {
        var (timeline, _) = recording()
        let video = timeline.tracks[0].clips[0].id, system = timeline.tracks[1].clips[0].id
        EditCommands.unlink(&timeline, clips: [video])
        #expect(timeline.tracks.flatMap(\.clips).allSatisfy { $0.linkGroupID == nil })
        #expect(timeline.linkedClipIDs([video]) == [video])

        EditCommands.link(&timeline, clips: [video, system])
        #expect(timeline.linkedClipIDs([video]) == [video, system])
    }

    // MARK: Speed

    @Test func speedKeepsLinkedClipsInSyncAndRipples() throws {
        var (timeline, _) = recording()
        EditCommands.split(&timeline, at: seconds(6))
        let first = timeline.tracks[0].clips[0]

        #expect(EditCommands.setSpeed(&timeline, clips: [first.id], to: 2))
        #expect(timeline.hasValidLayout)
        #expect(timeline.tracks[0].clips[0].timelineEnd == seconds(3))
        // Das Mikrofon startet jetzt 0,25 s nach dem Bild und endet mit ihm.
        #expect(timeline.tracks[2].clips[0].timelineStart == seconds(0.25))
        #expect(timeline.tracks.allSatisfy { $0.clips[0].timelineEnd == seconds(3) })
        // Die zweite Hälfte rückt auf allen Spuren nach.
        #expect(timeline.tracks.allSatisfy { $0.clips[1].timelineStart == seconds(3) })
        #expect(Set(ends(timeline)) == [seconds(7)])
    }

    // MARK: Abschnitt beschleunigen

    @Test func speedRangeSplitsAllTracksAndRipples() throws {
        var (timeline, _) = recording()
        let range = try #require(EditCommands.setSpeed(&timeline, in: RationalTimeRange(start: seconds(2), duration: seconds(4)),
                                                       to: 2, muteAudio: true))
        #expect(range == RationalTimeRange(start: seconds(2), duration: seconds(2)))
        #expect(timeline.hasValidLayout)
        #expect(timeline.tracks.allSatisfy { $0.clips.count == 3 })
        #expect(timeline.tracks.allSatisfy { $0.clips[1].speed == 2 && $0.clips[0].speed == 1 && $0.clips[2].speed == 1 })
        // 4 s Material laufen jetzt in 2 s; alles danach rückt auf allen Spuren um 2 s vor.
        #expect(Set(ends(timeline)) == [seconds(8)])
        #expect(timeline.tracks.allSatisfy { $0.clips[2].timelineStart == seconds(4) })
        // Nur der Ton im Bereich ist stumm.
        #expect(timeline.tracks[1].clips.map(\.isMuted) == [false, true, false])
        #expect(!timeline.tracks[0].clips[1].isMuted)
        // Die beschleunigten Stücke bleiben untereinander verknüpft, aber nicht mit dem Rest.
        let middle = timeline.tracks.map { $0.clips[1].id }
        #expect(timeline.linkedClipIDs([middle[0]]) == Set(middle))
    }

    @Test func speedRangeBackToNormalUnmutes() throws {
        var (timeline, _) = recording()
        let range = try #require(EditCommands.setSpeed(&timeline, in: RationalTimeRange(start: seconds(2), duration: seconds(4)),
                                                       to: 4, muteAudio: true))
        let restored = try #require(EditCommands.setSpeed(&timeline, in: range, to: 1, muteAudio: true))
        #expect(restored.duration == seconds(4))
        #expect(timeline.duration == seconds(10))
        #expect(timeline.tracks.flatMap(\.clips).allSatisfy { $0.speed == 1 && !$0.isMuted })
    }

    @Test func speedRangeOutsideClipsFails() {
        var (timeline, _) = recording()
        let before = timeline
        #expect(EditCommands.setSpeed(&timeline, in: RationalTimeRange(start: seconds(20), duration: seconds(2)),
                                      to: 2, muteAudio: false) == nil)
        #expect(timeline == before)
    }

    @Test func speedSegmentsMergeTracks() throws {
        var (timeline, _) = recording()
        EditCommands.setSpeed(&timeline, in: RationalTimeRange(start: seconds(1), duration: seconds(2)), to: 2, muteAudio: false)
        let segments = timeline.speedSegments
        #expect(segments.count == 1)
        #expect(segments.first?.speed == 2)
        #expect(segments.first?.range == RationalTimeRange(start: seconds(1), duration: seconds(1)))
    }

    // MARK: Übergänge

    @Test func addTransitionCoversLinkedCuts() throws {
        var (timeline, _) = recording()
        EditCommands.split(&timeline, at: seconds(5))
        #expect(timeline.cuts.count == 3)
        let video = timeline.tracks[0].clips[0]
        let id = try #require(EditCommands.addTransition(&timeline, after: video.id, kind: .crossfade))
        #expect(timeline.transitions.count == 3)
        #expect(timeline.companionTransitionIDs(of: id).count == 3)

        EditCommands.setTransitionDuration(&timeline, id, to: seconds(1))
        #expect(timeline.transitions.allSatisfy { $0.duration == seconds(1) })
        // Nie länger als der kürzere Clip.
        EditCommands.setTransitionDuration(&timeline, id, to: seconds(60))
        #expect(timeline.transitions.first { $0.id == id }?.duration == seconds(5))

        // Erneut hinzufügen ersetzt statt zu verdoppeln.
        EditCommands.addTransition(&timeline, after: video.id, kind: .fadeThroughBlack)
        #expect(timeline.transitions.count == 3)
        #expect(timeline.transitions.allSatisfy { $0.kind == .fadeThroughBlack })

        let current = try #require(timeline.transitions.first?.id)
        EditCommands.deleteTransition(&timeline, current)
        #expect(timeline.transitions.isEmpty)
    }

    @Test func addTransitionKeepsUnlinkedTracksApart() throws {
        var (timeline, _) = recording()
        EditCommands.split(&timeline, at: seconds(5))
        EditCommands.unlink(&timeline, clips: Set(timeline.tracks.flatMap(\.clips).map(\.id)))
        #expect(EditCommands.addTransition(&timeline, after: timeline.tracks[0].clips[0].id, kind: .crossfade) != nil)
        #expect(timeline.transitions.count == 1)
        // Am Ende der Spur gibt es keinen Schnitt.
        #expect(EditCommands.addTransition(&timeline, after: timeline.tracks[0].clips[1].id, kind: .crossfade) == nil)
    }

    // MARK: Snapping

    @Test func snapsToNearestTarget() throws {
        let (timeline, _) = recording()
        let targets = SnapTargets(timeline: timeline, excluding: [timeline.tracks[0].clips[0].id], playhead: seconds(3))
        let snap = try #require(targets.snap([seconds(2.9), seconds(5)], tolerance: seconds(0.2)))
        #expect(snap.target == seconds(3))
        #expect(snap.offset == seconds(3) - seconds(2.9))
        #expect(targets.snap([seconds(7)], tolerance: seconds(0.2)) == nil)
    }
}

struct WaveformTests {
    @Test func readsOnePeakPerHundredthSecond() async throws {
        let package = try await TestMedia.makeRecordingPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let peaks = try await WaveformCache.readPeaks(from: package.appending(path: "media/system.m4a"))
        // 2 s Ton, Toleranz für Encoder-Vorlauf.
        #expect(abs(peaks.count - 2 * WaveformCache.peaksPerSecond) <= 5)
        #expect(peaks.allSatisfy { (0...1).contains($0) })
    }
}
