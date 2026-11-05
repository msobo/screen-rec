# ScreenRec

Bildschirm aufnehmen, im Editor schneiden und fertig exportieren. Eine native Mac-App.

## Installation

Voraussetzung ist macOS 15 oder neuer.

1. Lade die aktuelle `ScreenRec-x.y.z.dmg` von der [Release-Seite](https://github.com/msobo/ScreenRec/releases/latest).
2. Öffne die DMG und ziehe **ScreenRec** in den Ordner **Programme**.
3. Starte ScreenRec. macOS blockiert den ersten Start, weil die App nicht von Apple notarisiert ist.
4. Öffne *Systemeinstellungen → Datenschutz & Sicherheit*, scrolle nach unten und klicke bei ScreenRec auf **Trotzdem öffnen**.
5. Erlaube beim ersten Aufnehmen die **Bildschirmaufnahme**. Mikrofon und Kamera fragt die App nur ab, wenn du sie einschaltest.

Nach einem Update musst du die Erlaubnis für die Bildschirmaufnahme eventuell neu erteilen. Falls die Aufnahme nicht startet, entferne ScreenRec unter *Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme* und erlaube die App erneut.

### Aus dem Quellcode bauen

Du brauchst Xcode und [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
open ScreenRec.xcodeproj
```

## Kurzanleitung

**Aufnehmen**

1. Beim Start öffnet sich das Aufnahmefenster. Hast du es geschlossen, holst du es über das Symbol in der Menüleiste und **ScreenRec öffnen** zurück.
2. Wähle im Fenster aus, ob Systemton, Mikrofon oder Kamera mitlaufen sollen.
3. Starte die Aufnahme mit **REC** oder mit **⌘⇧2**. Das Tastenkürzel funktioniert auch, wenn die App im Hintergrund läuft.
4. Wähle den Bildschirm oder das Fenster aus. Nach dem Countdown läuft die Aufnahme.
5. Beende die Aufnahme wieder mit **⌘⇧2** oder über das Symbol in der Menüleiste. Der Editor öffnet sich automatisch.

**Bearbeiten**

- **Abspielen:** Leertaste, oder J, K und L für rückwärts, Pause und vorwärts
- **Schneiden:** Playhead setzen und **⌘B** drücken
- **Löschen:** Clip auswählen und **⌫** drücken, mit **⇧⌫** rückt der Rest nach
- **Beschleunigen:** Bereich mit **I** und **O** markieren, dann **⌘R** drücken und das Tempo wählen

**Exportieren**

Drücke **⌘E**, wähle das Preset **YouTube** und die Auflösung und klicke auf **Exportieren**.

Aufnahmen landen als Projekte unter `~/Movies/ScreenRec`. Änderungen sicherst du mit **⌘S**, die Originalaufnahme bleibt dabei unverändert.

## Lizenz

GPL-3.0, siehe [LICENSE](LICENSE). Hinweise zu verwendeten Komponenten stehen in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
