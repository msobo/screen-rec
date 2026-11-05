import AppKit
import Foundation
import Testing
@testable import ScreenRec

private func seconds(_ value: Double) -> RationalTime { RationalTime(seconds: value) }

private func keystroke(_ t: Double, _ label: String, typed: Bool = true) -> CursorData.Keystroke {
    CursorData.Keystroke(t: t, label: label, isTyped: typed ? true : nil)
}

/// Zwei Clips einer Bildschirmaufnahme: 0–4 s und 6–10 s der Quelle, hintereinander; 4–6 s ist herausgeschnitten.
private func cutTimeline(screen: UUID, secondClipSpeed: Double = 1) -> Timeline {
    let first = Clip(assetID: screen, sourceRange: RationalTimeRange(start: .zero, duration: seconds(4)), timelineStart: .zero)
    let second = Clip(assetID: screen, sourceRange: RationalTimeRange(start: seconds(6), duration: seconds(4)),
                      timelineStart: seconds(4), speed: secondClipSpeed)
    return Timeline(tracks: [Track(kind: .video, name: "Bildschirm", clips: [first, second])])
}

private func note(at anchor: Double, duration: Double = 2) -> Annotation {
    Annotation(anchor: seconds(anchor), duration: seconds(duration), content: .text(TextNote(text: "Hinweis")))
}

struct AnnotationPlacementTests {
    private let screen = UUID()

    @Test func followsTheMaterialAfterACut() {
        var timeline = cutTimeline(screen: screen)
        timeline.annotations = [note(at: 7)]
        let placement = AnnotationPlacement.resolve(timeline, screenAssetIDs: [screen]).first
        #expect(placement?.start == seconds(5))
        #expect(placement?.duration == seconds(2))
    }

    @Test func keepsDurationButFollowsPositionAtHigherSpeed() {
        var timeline = cutTimeline(screen: screen, secondClipSpeed: 2)
        timeline.annotations = [note(at: 8, duration: 0.5)]
        let placement = AnnotationPlacement.resolve(timeline, screenAssetIDs: [screen]).first
        #expect(placement?.start == seconds(5))
        #expect(placement?.duration == seconds(0.5))
        #expect(placement?.speed == 2)
    }

    @Test func dropsAnnotationsWhoseMaterialIsCutOut() {
        var timeline = cutTimeline(screen: screen)
        timeline.annotations = [note(at: 5)]
        #expect(AnnotationPlacement.resolve(timeline, screenAssetIDs: [screen]).isEmpty)
    }

    @Test func endsWithTheTimeline() {
        var timeline = cutTimeline(screen: screen)
        timeline.annotations = [note(at: 9, duration: 5)]
        #expect(AnnotationPlacement.resolve(timeline, screenAssetIDs: [screen]).first?.duration == seconds(1))
    }

    @Test func anchorSnapsToTheNearestClipInGaps() {
        var timeline = cutTimeline(screen: screen)
        timeline.tracks[0].clips[1].timelineStart = seconds(10)
        let early = AnnotationPlacement.anchor(forTimelineTime: seconds(9), in: timeline, screenAssetIDs: [screen])
        #expect(early == seconds(6))
        let late = AnnotationPlacement.anchor(forTimelineTime: seconds(5), in: timeline, screenAssetIDs: [screen])
        #expect(late.map { $0 < seconds(4) } == true)
    }
}

struct KeystrokeGrouperTests {
    @Test func groupsTypingAndSplitsAtPauses() {
        let annotations = KeystrokeGrouper.annotations(from: [
            keystroke(1, "H"), keystroke(1.3, "i"), keystroke(5, "x"),
        ])
        #expect(annotations.count == 2)
        #expect(annotations[0].keys?.displayText == "Hi")
        #expect(annotations[0].anchor == seconds(1))
        #expect(abs((annotations[0].keys?.keys[1].offset ?? 0) - 0.3) < 0.001)
    }

    @Test func tabAndReturnSeparatePasswordFromTheRest() {
        let annotations = KeystrokeGrouper.annotations(from: [
            keystroke(1, "m"), keystroke(1.1, "e"), keystroke(1.2, "⇥", typed: false),
            keystroke(1.3, "g"), keystroke(1.4, "e"), keystroke(1.5, "↩", typed: false),
        ])
        #expect(annotations.map { $0.keys?.displayText } == ["me", "⇥", "ge", "↩"])
    }

    @Test func shortcutsStandAloneAndSplitIntoCaps() {
        let annotations = KeystrokeGrouper.annotations(from: [
            keystroke(1, "a"), keystroke(1.1, "⇧⌘S", typed: false), keystroke(1.2, "b"),
        ])
        #expect(annotations.count == 3)
        #expect(annotations[1].keys?.keys.first?.caps == ["⇧", "⌘", "S"])
    }

    @Test func backspaceStaysInTheGroup() {
        let annotations = KeystrokeGrouper.annotations(from: [
            keystroke(1, "a"), keystroke(1.1, "⌫", typed: false), keystroke(1.2, "b"),
        ])
        #expect(annotations.map { $0.keys?.displayText } == ["a⌫b"])
    }

    @Test func nextGroupReplacesThePreviousOne() {
        let annotations = KeystrokeGrouper.annotations(from: [
            keystroke(1, "⌘C", typed: false), keystroke(1.5, "⌘V", typed: false),
        ])
        #expect(abs(annotations[0].duration.seconds - 0.5) < 0.001)
        #expect(abs(annotations[1].duration.seconds - KeystrokeGrouper.holdDuration) < 0.001)
    }
}

struct TypedCharacterTests {
    @Test func usesTheCharacterOfTheLayout() {
        #expect(KeystrokeLabel.typedCharacter(keyCode: 0, characters: "a", modifiers: []) == "a")
        #expect(KeystrokeLabel.typedCharacter(keyCode: 0, characters: "A", modifiers: .shift) == "A")
        #expect(KeystrokeLabel.typedCharacter(keyCode: 37, characters: "@", modifiers: .option) == "@")
        #expect(KeystrokeLabel.typedCharacter(keyCode: 49, characters: " ", modifiers: []) == KeystrokeLabel.spaceCap)
    }

    @Test func leavesShortcutsAndSpecialKeysToTheLabel() {
        #expect(KeystrokeLabel.typedCharacter(keyCode: 1, characters: "s", modifiers: .command) == nil)
        #expect(KeystrokeLabel.typedCharacter(keyCode: 36, characters: "\r", modifiers: []) == nil)
        #expect(KeystrokeLabel.typedCharacter(keyCode: 123, characters: "\u{F702}", modifiers: []) == nil)
        // Tote Taste: Das Zeichen entsteht erst mit dem nächsten Anschlag.
        #expect(KeystrokeLabel.typedCharacter(keyCode: 24, characters: "", modifiers: []) == nil)
    }
}

struct AnnotationCommandsTests {
    private let screen = UUID()
    private let secret = "geheim-7421"

    private func timelineWithSecret() -> (Timeline, Annotation.ID) {
        var timeline = cutTimeline(screen: screen)
        timeline.annotations = KeystrokeGrouper.annotations(from: secret.enumerated().map {
            keystroke(1 + Double($0.offset) * 0.1, String($0.element))
        })
        return (timeline, timeline.annotations[0].id)
    }

    private func encoded(_ timeline: Timeline) throws -> String {
        // Jede Kappe steht einzeln im JSON, deshalb auch ein Stück des Geheimnisses prüfen.
        let project = Project(assets: [], timeline: timeline)
        let json = try #require(String(data: SchemaMigration.encode(project), encoding: .utf8))
        return json.filter { !$0.isWhitespace && !"\",[]{}:".contains($0) }
    }

    @Test func maskOverwritesTheOriginal() throws {
        var (timeline, id) = timelineWithSecret()
        #expect(try encoded(timeline).contains("7"))
        AnnotationCommands.mask(&timeline, id, with: "***")
        #expect(timeline.annotations[0].keys?.displayText == "***")
        let caps = try #require(timeline.annotations[0].keys).keys.flatMap(\.caps)
        #expect(caps == ["*", "*", "*"])
        #expect(try !encoded(timeline).contains("7421"))
    }

    @Test func hideRemovesContentAndTiming() throws {
        var (timeline, id) = timelineWithSecret()
        AnnotationCommands.hide(&timeline, id)
        let group = try #require(timeline.annotations[0].keys)
        #expect(group.isHidden)
        #expect(group.keys == [KeyGroup.Key(offset: 0, caps: [KeyGroup.hiddenSymbol])])
    }

    @Test func editingShowsAHiddenGroupAgain() throws {
        var (timeline, id) = timelineWithSecret()
        AnnotationCommands.hide(&timeline, id)
        AnnotationCommands.setKeys(&timeline, id, text: "a b")
        let group = try #require(timeline.annotations[0].keys)
        #expect(!group.isHidden)
        #expect(group.keys.flatMap(\.caps) == ["a", KeystrokeLabel.spaceCap, "b"])
    }

    @Test func splitKeepsBothParts() throws {
        var (timeline, id) = timelineWithSecret()
        let rest = try #require(AnnotationCommands.split(&timeline, id, atOffset: 0.55))
        let front = try #require(timeline.annotations.first { $0.id == id })
        let back = try #require(timeline.annotations.first { $0.id == rest })
        #expect(front.keys?.displayText == "geheim")
        #expect(back.keys?.displayText == "-7421")
        #expect(back.keys?.keys.first?.offset == 0)
        #expect(abs((back.anchor - front.anchor).seconds - 0.6) < 0.001)
    }

    @Test func badgesCountUp() {
        var timeline = cutTimeline(screen: screen)
        for expected in 1...3 {
            let content = AnnotationCommands.newShape(.badge, in: timeline)
            guard case .shape(let mark) = content else { Issue.record("kein Symbol"); return }
            #expect(mark.number == expected)
            AnnotationCommands.add(&timeline, content, at: seconds(1), screenAssetIDs: [screen])
        }
    }

    @Test func moveAndTrimWorkInTimelineTime() throws {
        var timeline = cutTimeline(screen: screen)
        let id = try #require(AnnotationCommands.add(&timeline, .text(TextNote(text: "x")), at: seconds(1),
                                                     screenAssetIDs: [screen]))
        AnnotationCommands.move(&timeline, id, to: seconds(5), screenAssetIDs: [screen])
        #expect(timeline.annotations[0].anchor == seconds(7))

        let placement = try #require(AnnotationPlacement.resolve(timeline, screenAssetIDs: [screen]).first)
        AnnotationCommands.trim(&timeline, placement, edge: .start, to: seconds(6), screenAssetIDs: [screen])
        #expect(timeline.annotations[0].anchor == seconds(8))
        #expect(timeline.annotations[0].duration == seconds(2))
    }

    @Test func overlappingNotesGetTheirOwnRow() {
        var timeline = cutTimeline(screen: screen)
        timeline.annotations = [note(at: 0), note(at: 1), note(at: 2.5)]
        let placements = AnnotationPlacement.resolve(timeline, screenAssetIDs: [screen])
        let rows = AnnotationCommands.rows(for: placements, rowCount: 2)
        #expect(placements.map { rows[$0.annotation.id] } == [0, 1, 0])
    }
}

struct AnnotationPersistenceTests {
    @Test func version4GetsAnEmptyAnnotationList() throws {
        let project = Project(assets: [], timeline: Timeline())
        var object = try #require(JSONSerialization.jsonObject(with: SchemaMigration.encode(project)) as? [String: Any])
        object["schemaVersion"] = 4
        var timeline = try #require(object["timeline"] as? [String: Any])
        timeline.removeValue(forKey: "annotations")
        object["timeline"] = timeline

        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(SchemaMigration.storedVersion(of: data) == 4)
        let migrated = try SchemaMigration.decodeProject(from: data)
        #expect(migrated.schemaVersion == Project.currentSchemaVersion)
        #expect(migrated.timeline.annotations.isEmpty)
    }

    @Test func annotationsSurviveSaving() throws {
        var timeline = Timeline()
        timeline.annotations = [
            note(at: 1),
            Annotation(anchor: seconds(2), duration: seconds(3), content: .shape(ShapeMark(kind: .arrow))),
            Annotation(anchor: seconds(3), duration: seconds(1),
                       content: .keys(KeyGroup(keys: [.init(offset: 0, caps: ["⌘", "S"])]))),
        ]
        let project = Project(assets: [], timeline: timeline)
        #expect(try SchemaMigration.decodeProject(from: SchemaMigration.encode(project)) == project)
    }

    @Test func oldKeystrokeModeIsCarriedOver() throws {
        let suite = "annotation-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(RecordingOptions.load(from: defaults).keystrokeMode == .shortcuts)

        defaults.set(false, forKey: RecordingOptions.Key.recordsKeystrokes)
        #expect(RecordingOptions.load(from: defaults).keystrokeMode == .off)
        #expect(defaults.string(forKey: RecordingOptions.Key.keystrokeMode) == "off")
    }
}

@MainActor
struct KeystrokeStorageTests {
    @Test func typedTextLeavesCursorDataWhenTheProjectIsCreated() async throws {
        let package = try await TestMedia.makeRecordingPackage()
        defer { try? FileManager.default.removeItem(at: package) }
        var data = CursorData()
        data.keystrokes = [keystroke(0.5, "x"), keystroke(0.6, "y")]
        try TestMedia.addCursorData(data, to: package)

        try await ProjectFactory.createProjectFile(forRecordingAt: package)

        #expect(try #require(CursorData.load(fromPackage: package)).data.keystrokes.isEmpty)
        let json = try Data(contentsOf: package.appending(path: ProjectDocument.projectFileName))
        let project = try SchemaMigration.decodeProject(from: json)
        #expect(project.timeline.annotations.first?.keys?.displayText == "xy")
    }
}
