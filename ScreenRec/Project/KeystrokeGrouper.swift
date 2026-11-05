import Foundation

/// Fasst die Tastendrücke einer Aufnahme zu Einblendungen zusammen.
enum KeystrokeGrouper {
    /// Längere Pausen beginnen eine neue Gruppe.
    static let maximumGap = 1.2
    /// So lange bleibt die Gruppe nach der letzten Taste stehen.
    static let holdDuration = 1.6

    /// Diese Tasten beenden eine Eingabe. Sie stehen für sich, damit ein Passwort zwischen
    /// ⇥ und ↩ meist eine eigene Gruppe wird, die sich als Ganzes maskieren lässt.
    private static let separators: Set<String> = ["↩", "⇥"]
    private static let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]

    static func annotations(from keystrokes: [CursorData.Keystroke]) -> [Annotation] {
        var groups: [(start: Double, keys: [KeyGroup.Key])] = []
        var isOpen = false
        var last = 0.0
        for keystroke in keystrokes.sorted(by: { $0.t < $1.t }) {
            let caps = caps(for: keystroke)
            // Tippen, ⌫ und Pfeiltasten gehören zusammen, Kürzel und Trenner nicht.
            let joins = caps.count == 1 && !separators.contains(keystroke.label)
            if joins, isOpen, keystroke.t - last <= maximumGap {
                groups[groups.count - 1].keys.append(.init(offset: keystroke.t - groups[groups.count - 1].start, caps: caps))
            } else {
                groups.append((keystroke.t, [.init(offset: 0, caps: caps)]))
            }
            isOpen = joins
            last = keystroke.t
        }
        return groups.enumerated().map { index, group in
            var duration = (group.keys.last?.offset ?? 0) + holdDuration
            // Die nächste Gruppe löst die vorige ab, in der Spur wie im Bild.
            if index + 1 < groups.count { duration = min(duration, groups[index + 1].start - group.start) }
            return Annotation(anchor: RationalTime(seconds: group.start), duration: RationalTime(seconds: duration),
                              content: .keys(KeyGroup(keys: group.keys)))
        }
    }

    /// Einzelne Kappen: „⇧⌘S“ wird zu `["⇧", "⌘", "S"]`, Getipptes bleibt eine Kappe.
    static func caps(for keystroke: CursorData.Keystroke) -> [String] {
        if keystroke.isTyped == true { return [keystroke.label] }
        let symbols = keystroke.label.prefix { modifiers.contains($0) }
        let key = keystroke.label.dropFirst(symbols.count)
        return symbols.map { String($0) } + (key.isEmpty ? [] : [String(key)])
    }
}
