# Slipstream: Anleitung

Slipstream wandelt ProRes-Dateien, die du ins Funkhaus ziehst, auf deinem Mac um, bevor
sie hochladen. Auf einem gekoppelten Mac hilft es außerdem dem Encoder bei seinen Aufträgen.
Installieren: [README, „Installieren“](../README.md#installieren).

## ProRes hochladen

- In Final Cut wie gewohnt als ProRes exportieren und die Datei ins Funkhaus ziehen, wie
  jede andere.
- Die Seite übergibt die Datei an Slipstream, Slipstream wandelt sie um (bei 10 Minuten 4K
  etwa vier Minuten), dann lädt die Seite das Ergebnis hoch. Den Fortschritt zeigen die Seite
  und das Symbol in der Menüleiste.
- Den Tab offen lassen, bis der Upload durch ist. Wird er doch geschlossen: Upload wieder
  öffnen, die Seite macht dort weiter, wo Slipstream steht.
- Die ProRes-Datei behalten: sie ist die einzige Quelle, falls das Video je neu kodiert wird.
  Slipstream löscht seine eigene Kopie, sobald der Upload fertig ist, und alles, was älter als
  7 Tage ist.

## Das Menü

- **Das Symbol** zeigt den Zustand: Wind (bereit), Wind mit Prozent (wandelt um), Pause-Kreis
  (pausiert).
- **Was gerade läuft:** Titel, Stufe oder „Whisper“, Prozent, Bilder pro Sekunde, Tempo,
  Restzeit. Eine ProRes-Umwandlung steht hier auch.
- **Die letzten Ergebnisse** und wie viele heute fertig wurden.
- **Pause:** 30 Minuten, 2 Stunden oder 24 Stunden; „Fortsetzen“ beendet sie. Die Pause gilt
  nur für Aufträge des Encoders, nie für ProRes.
- **CPU für den Encoder:** Alle, ¾, ½ oder ¼ der Kerne, sofort für den laufenden Auftrag und
  auch nach einem Neustart. Die genaue Zahl steht in den Einstellungen.
- **Protokoll anzeigen …**, wenn etwas komisch aussieht.
- **Verbindung:** Tunnel verbunden oder getrennt. „Nicht gekoppelt (nur ProRes)“ ist normal auf
  einem Mac, der nur ProRes umwandelt.
- **Safari-Extension:** „verbunden“, sobald das Funkhaus in Safari Slipstream erreicht hat.
  Steht dort „noch nicht verbunden“, obwohl das Funkhaus offen ist: in Safari →
  Einstellungen → Erweiterungen → Slipstream die Website `funkhaus.iphoneblog.de` erlauben (nach
  einem Update von Slipstream fragt Safari das neu).
- **Einstellungen …:** CPU-Threads, ob Whisper die GPU nutzen darf, Aufträge gleichzeitig, der
  Stand der Kopplung.
- **Beenden** während einer Umwandlung fragt nach und gibt den Auftrag zurück.

Slipstream rechnet mit niedriger Priorität: was du am Mac tust, geht vor. Der Mac schläft nicht
ein, solange Slipstream einen Auftrag hat.

## Wenn etwas schiefgeht

- **Das Funkhaus zeigt „Slipstream starten“:** Die Extension ist an, die App läuft nicht.
  Ein Klick darauf startet sie im Hintergrund.
- **Die Seite sagt, ProRes werde hier nicht unterstützt:** Slipstream ist nicht installiert, die
  Extension ist aus, oder sie darf auf `funkhaus.iphoneblog.de` nicht laufen (Safari →
  Einstellungen → Erweiterungen → Slipstream; das Menü zeigt dann „Safari-Extension: noch nicht
  verbunden“). Danach die Seite neu laden.
- **„Das ist keine Videodatei.“** oder **„Dieses Videoformat (…) kann der Mac nicht lesen.“**:
  Neu aus Final Cut exportieren.
- **„Auf dem Mac ist kein Platz mehr frei.“**: Platz schaffen; 10 Minuten 4K brauchen etwa
  50 GB für die Kopie und 4 GB für das Ergebnis.
- Alles andere: ein [Issue](../../../issues) öffnen, mit einem Bildschirmfoto und den Zeilen aus
  „Protokoll anzeigen“.
