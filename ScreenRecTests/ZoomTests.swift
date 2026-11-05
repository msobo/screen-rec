import CoreGraphics
import Foundation
import Testing
@testable import ScreenRec

struct ZoomCommandsTests {
    private func seconds(_ value: Double) -> RationalTime { RationalTime(seconds: value) }

    /// 20 s Bildschirm, ein Clip ab 0.
    private func timeline(zooms: [ZoomRegion] = []) -> Timeline {
        let clip = Clip(assetID: screenID, sourceRange: RationalTimeRange(start: .zero, duration: seconds(20)),
                        timelineStart: .zero)
        return Timeline(tracks: [Track(kind: .video, name: "Bildschirm", clips: [clip])], zooms: zooms)
    }

    private let screenID = UUID()

    @Test func addFitsIntoGap() throws {
        var timeline = timeline(zooms: [ZoomRegion(start: seconds(5), duration: seconds(2))])
        let id = try #require(ZoomCommands.add(&timeline, at: seconds(3)))
        let added = try #require(timeline.zooms.first { $0.id == id })
        // Drei Sekunden passen nicht vor den vorhandenen Zoom: Er endet an dessen Anfang.
        #expect(added.start == seconds(3))
        #expect(added.end == seconds(5))
        #expect(timeline.hasValidZooms)
        // In einem bestehenden Zoom wird keiner gesetzt.
        #expect(ZoomCommands.add(&timeline, at: seconds(6)) == nil)
    }

    @Test func moveAndTrimStopAtNeighbours() throws {
        let first = ZoomRegion(start: seconds(1), duration: seconds(2))
        let second = ZoomRegion(start: seconds(6), duration: seconds(2))
        var timeline = timeline(zooms: [first, second])

        ZoomCommands.move(&timeline, first.id, by: seconds(10))
        #expect(timeline.zooms[0].end == second.start)
        ZoomCommands.move(&timeline, first.id, by: seconds(-100))
        #expect(timeline.zooms[0].start == .zero)

        ZoomCommands.trim(&timeline, second.id, edge: .start, by: seconds(-10))
        #expect(timeline.zooms[1].start == timeline.zooms[0].end)
        ZoomCommands.trim(&timeline, second.id, edge: .end, by: seconds(-100))
        #expect(timeline.zooms[1].duration == ZoomRegion.minimumDuration)
        #expect(timeline.hasValidZooms)
        #expect(timeline.zooms.allSatisfy { !$0.isAutomatic })
    }

    @Test func autoZoomGroupsClicks() {
        let zooms = ZoomCommands.automaticZooms(for: timeline(), clickTimes: [2, 3, 4, 12], screenAssetIDs: [screenID])
        #expect(zooms.count == 2)
        // 2–4 s: 0,6 s Vorlauf, 1,8 s Nachlauf.
        #expect(abs(zooms[0].start.seconds - 1.4) < 0.02)
        #expect(abs(zooms[0].end.seconds - 5.8) < 0.02)
        // Ein einzelner Klick bekommt die Mindestlänge.
        #expect(zooms[1].duration.seconds >= ZoomCommands.minimumAutoDuration - 0.02)
        #expect(zooms.allSatisfy { $0.isAutomatic })
    }

    @Test func autoZoomFollowsCutsAndSpeed() {
        // Quelle 0–10 s auf doppelter Geschwindigkeit, also 5 s Timeline; danach Quelle 15–20 s.
        var timeline = timeline()
        timeline.tracks[0].clips = [
            Clip(assetID: screenID, sourceRange: RationalTimeRange(start: .zero, duration: seconds(10)),
                 timelineStart: .zero, speed: 2),
            Clip(assetID: screenID, sourceRange: RationalTimeRange(start: seconds(15), duration: seconds(5)),
                 timelineStart: seconds(5)),
        ]
        // Klick bei 8 s → Timeline 4 s; Klick bei 12 s ist herausgeschnitten; 16 s → Timeline 6 s.
        let zooms = ZoomCommands.automaticZooms(for: timeline, clickTimes: [8, 12, 16], screenAssetIDs: [screenID])
        #expect(zooms.count == 1)
        #expect(abs(zooms[0].start.seconds - 3.4) < 0.02)
        #expect(abs(zooms[0].end.seconds - 7.8) < 0.02)
    }

    @Test func replacingAutoZoomsKeepsManualOnes() {
        let manual = ZoomRegion(start: seconds(1), duration: seconds(3))
        var timeline = timeline(zooms: [manual, ZoomRegion(start: seconds(10), duration: seconds(2), isAutomatic: true)])
        let generated = [ZoomRegion(start: seconds(2), duration: seconds(3), isAutomatic: true),
                         ZoomRegion(start: seconds(14), duration: seconds(2), isAutomatic: true)]
        ZoomCommands.replaceAutomaticZooms(&timeline, with: generated)
        #expect(timeline.zooms.map(\.start) == [seconds(1), seconds(14)])
        #expect(timeline.zooms[0].id == manual.id)
    }
}

struct ZoomPathTests {
    private func seconds(_ value: Double) -> RationalTime { RationalTime(seconds: value) }

    @Test func easesInAndOut() {
        let region = ZoomRegion(start: seconds(1), duration: seconds(4), scale: 3)
        #expect(ZoomPath.scale(of: region, at: 0.5) == 1)
        #expect(ZoomPath.scale(of: region, at: 1) == 1)
        #expect(abs(ZoomPath.scale(of: region, at: 3) - 3) < 1e-9)
        let halfway = ZoomPath.scale(of: region, at: 1 + ZoomPath.maximumEase / 2)
        #expect(halfway > 1.9 && halfway < 2.1)
        #expect(ZoomPath.scale(of: region, at: 5) == 1)
    }

    @Test func followsCursorWithoutJumping() {
        let region = ZoomRegion(start: seconds(1), duration: seconds(4))
        // Der Cursor springt bei 2 s von links nach rechts.
        let path = ZoomPath(zooms: [region], duration: 6) { t in CGPoint(x: t < 2 ? 0.2 : 0.8, y: 0.5) }
        #expect(path.state(at: 0.5).scale == 1)
        // Beim Einzoomen sitzt die Kamera schon auf dem Cursor.
        #expect(abs(path.state(at: 1.05).focus.x - 0.2) < 0.01)
        // Kurz nach dem Sprung ist sie unterwegs, eine Sekunde später angekommen.
        let moving = path.state(at: 2.2).focus.x
        #expect(moving > 0.25 && moving < 0.75)
        #expect(abs(path.state(at: 3.5).focus.x - 0.8) < 0.02)
    }

    @Test func fixedPointIgnoresCursor() {
        let region = ZoomRegion(start: .zero, duration: seconds(3), focus: .point, pointX: 0.9, pointY: 0.1)
        let path = ZoomPath(zooms: [region], duration: 3) { _ in CGPoint(x: 0.1, y: 0.9) }
        #expect(abs(path.state(at: 1.5).focus.x - 0.9) < 1e-6)
        #expect(abs(path.state(at: 1.5).focus.y - 0.1) < 1e-6)
    }
}
