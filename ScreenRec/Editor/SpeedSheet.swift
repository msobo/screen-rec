import SwiftUI

/// „Geschwindigkeit …“: Faktor für einen Zeitbereich wählen, optional mit stummem Ton.
struct SpeedSheet: View {
    let editor: TimelineEditor
    let range: RationalTimeRange
    @Environment(\.dismiss) private var dismiss
    @AppStorage("muteAudioWhenSpedUp") private var muteAudio = false
    @State private var speed: Double

    static let presets = [0.5, 1, 1.5, 2, 4, 8]

    init(editor: TimelineEditor, range: RationalTimeRange) {
        self.editor = editor
        self.range = range
        // Vorbelegt mit der Geschwindigkeit, die im Bereich schon gilt, sonst 2×.
        let current = editor.timeline.tracks.flatMap(\.clips)
            .first { $0.timelineRange.contains(range.start) && $0.speed != 1 }?.speed
        _speed = State(initialValue: current ?? 2)
    }

    private var resultingDuration: RationalTime {
        // Bereich bei 1× gemessen: bereits beschleunigte Clips zählen mit ihrer Quelldauer.
        let source = editor.timeline.speedSourceDuration(in: range)
        return TimeMapping.timelineDuration(forSourceDuration: source, speed: speed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Geschwindigkeit").font(.tapeDisplay(18)).foregroundStyle(Tape.ink)
                Spacer()
                ModuleTag(text: String(localized: "TEMPO"))
            }
            HStack {
                Text("\(TimeFormatting.timecode(range.start)) – \(TimeFormatting.timecode(range.end))")
                Spacer()
                Text("\(TimeFormatting.seconds(range.duration.seconds)) → \(TimeFormatting.seconds(resultingDuration.seconds))")
            }
            .font(.tapeLCD(22))
            .foregroundStyle(Tape.phosphor)
            .phosphorGlow()
            .monospacedDigit()
            .padding(.horizontal, 12)
            .padding(.vertical, 2)
            .lcdScreen(cornerRadius: 8)

            KeyPicker(selection: $speed, options: Self.presets.map { ($0, TimelineCanvas.formatSpeed($0)) })

            HStack(spacing: 8) {
                Text("Eigener Wert").caseLabel(10, color: Tape.ink)
                TextField("Faktor", value: $speed, format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(PaperFieldStyle())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text("× (\(Clip.speedRange.lowerBound.formatted()) bis \(Clip.speedRange.upperBound.formatted()))")
                    .font(.tapeMono(11))
                    .foregroundStyle(Tape.inkSoft)
            }
            Toggle("Ton in beschleunigten Abschnitten stummschalten", isOn: $muteAudio)
                .toggleStyle(.tapeSwitch)
                .foregroundStyle(Tape.ink)

            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .buttonStyle(.key)
                    .keyboardShortcut(.cancelAction)
                Button("Anwenden") {
                    editor.setSpeed(min(max(speed, Clip.speedRange.lowerBound), Clip.speedRange.upperBound),
                                    in: range, muteAudio: muteAudio && speed > 1)
                    dismiss()
                }
                .buttonStyle(.orangeKey)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Tape.casing)
        .presentationBackground(Tape.casing)
        .preferredColorScheme(.light)
    }
}

extension Timeline {
    /// Länge des Bereichs bei normaler Geschwindigkeit, gemessen an der längsten Spur.
    func speedSourceDuration(in range: RationalTimeRange) -> RationalTime {
        tracks.map { track in
            track.clips.reduce(RationalTime.zero) { total, clip in
                let start = max(clip.timelineStart, range.start), end = min(clip.timelineEnd, range.end)
                guard end > start else { return total }
                return total + TimeMapping.sourceDuration(forTimelineDuration: end - start, speed: clip.speed)
            }
        }.max() ?? .zero
    }
}
