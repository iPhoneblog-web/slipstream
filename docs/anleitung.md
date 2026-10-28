# Slipstream: Anleitung

Slipstream wandelt ProRes-Dateien, die du ins Funkhaus ziehst, auf deinem Mac um, bevor
sie hochladen. Auf einem gekoppelten Mac hilft es außerdem dem Encoder bei seinen Aufträgen.
Installieren und das Funkhaus einrichten: [README, „Install“](../README.md#install).

## Mit dem Funkhaus verbinden

- Bietet das Funkhaus **In Slipstream verbinden** an: anklicken. Slipstream öffnet sich, prüft
  das Funkhaus und fragt „Mit … verbinden?“. Nur **Verbinden** speichert es; ein Link allein
  richtet nichts ein, denn jede Website kann ihn schicken. Verbinde nur mit einem Funkhaus, dem
  du vertraust.
- Sonst: beim ersten Start den Hostnamen eintippen, etwa `funkhaus.example.org`, und **Prüfen
  und speichern**.
- Ein anderes Funkhaus geht genauso, per Link oder in Einstellungen → Funkhaus. Danach Safari
  mit ⌘Q beenden und neu öffnen. Die Kopplung bleibt.

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
- **Was gerade läuft:** eine Zeile je Auftrag, etwa „Wandelt um: one_144_Hey_Siri · 12 %“. Ihr
  Untermenü nennt Datei, Stufe oder „Untertitel (Whisper)“, Bilder pro Sekunde, Tempo, Restzeit
  und den Platz („Normal“ oder „Sofort und Stufe 1“). Eine ProRes-Umwandlung steht hier auch.
  Läuft nichts, steht hier „Bereit“.
- **Letzte Ereignisse:** ein Untermenü mit den letzten zehn Ergebnissen, das neueste oben.
  Darunter, wie viele heute fertig wurden.
- **Punkte**, zum Beispiel „1.240 Punkte heute · Platz 1 von 3“: was die heute angenommenen
  Aufträge dieses Macs wert sind, und sein Platz unter allen gekoppelten Encodern. Ein Punkt ist
  eine Minute Arbeit des Mac Studio; derselbe Auftrag bringt auf jedem Rechner gleich viele
  Punkte. Das Funkhaus rechnet sie aus; sie entscheiden nicht, wer welchen Auftrag bekommt.
- **Pause:** 30 Minuten, 2 Stunden oder 24 Stunden; „Fortsetzen“ beendet sie, ihr Ende auch.
  Ab dann nimmt der Mac keinen neuen Auftrag. Läuft gerade einer, gibt es zwei Wege:
  „Sofort pausieren“ hält ihn an. Ein Archiv- oder Stufe-2-Auftrag bleibt dann beim Mac und läuft
  nach der Pause dort weiter, wo er stand; ein Sofort- oder Stufe-1-Auftrag, auf den jemand
  wartet, geht nach einer Minute an einen anderen Rechner. „Nach diesem Auftrag“ lässt ihn zu
  Ende laufen. Das Menü zeigt „Pausiert bis 20:00“ (oder „Pause nach diesem Auftrag, bis 20:00“),
  ein angehaltener Auftrag heißt „Angehalten: …“. Die Pause gilt nur für Aufträge des Encoders,
  nie für ProRes.
- **CPU für den Encoder:** Alle, ¾, ½ oder ¼ der Kerne; die genaue Zahl steht in den
  Einstellungen. Die Zeile zeigt, was gerade gilt, etwa „3 von 12 Kernen“. Neue Aufträge starten
  mit der neuen Zahl. Ein laufender Auftrag, der mit mehr Kernen begann, läuft gedrosselt weiter:
  er hält in jeder Zehntelsekunde so lange an, dass er im Mittel nur noch so viele Kerne braucht,
  und verliert dabei nichts. Dann steht dort „(laufender Auftrag gedrosselt)“. Mehr Kerne heben
  die Drossel sofort auf. Die Zahl gilt auch nach einem Neustart. **Nur Effizienzkerne** lässt
  alle Aufträge nur auf den Effizienzkernen laufen, **Archiv-Aufträge nur auf Effizienzkernen**
  nur die Archiv-Aufträge: die Leistungskerne bleiben frei für die Arbeit am Mac, auch für einen
  laufenden Auftrag sofort. Das ist etwa 11-mal langsamer (gemessen am Mac Studio), und ein
  solcher Auftrag läuft fast nur, wenn der Mac nichts anderes tut: macOS gibt ihm, was übrig
  bleibt. Bei viel Arbeit am Mac bekam er in einer Minute kaum etwas (0,07 Kerne). Menü und
  Einstellungen sagen beides dazu.
- **Protokoll anzeigen …**, wenn etwas komisch aussieht. Das Fenster zeigt die neuesten Zeilen
  und folgt neuen Zeilen, solange **Folgen** an ist; wer hochscrollt, schaltet es aus, am Ende
  geht es wieder an. Oben wählt man **Fehler**, **Warnungen**, **Info** oder **Debug** und sucht
  nach einem Wort. **Debug aufzeichnen** schreibt auch jedes Ereignis des Workers mit (aus, bis
  man es einschaltet). **Kopieren** kopiert die sichtbaren Zeilen, **In Console öffnen** öffnet
  die Datei `~/Library/Logs/Slipstream/slipstream.log` in der Konsole (dort auch unter
  „Protokollberichte“).
- **Verbindung: Encoder gestoppt** heißt: der Encoder-Teil von Slipstream läuft gerade nicht.
  Das Untermenü sagt, wann Slipstream ihn wieder startet (erst nach 10 Sekunden, bei
  wiederholtem Stopp seltener, höchstens alle 10 Minuten), und darunter, warum. ProRes für das
  Funkhaus geht trotzdem.
- **Verbindung: verbunden** oder getrennt. Das Untermenü zeigt den Tunnel mit der letzten Antwort
  des Funkhauses, die Safari-Extension und Auftragsarten, die das Funkhaus diesem Mac nicht gibt.
  „Nicht gekoppelt (nur ProRes)“ ist normal auf einem Mac, der nur ProRes umwandelt.
- **Safari-Extension** (im Untermenü „Verbindung“): „verbunden“, sobald das Funkhaus in Safari Slipstream erreicht hat.
  Steht dort „noch nicht verbunden“, obwohl das Funkhaus offen ist: in Safari →
  Einstellungen → Erweiterungen → Slipstream das eingerichtete Funkhaus erlauben (nach
  einem Update von Slipstream fragt Safari das neu).
- **Einstellungen …:** ein Fenster mit vier Tabs, in der Größe veränderbar: **Allgemein**
  (Bei der Anmeldung starten, Version, Lizenzen), **Leistung** (CPU-Threads, nur Effizienzkerne, Archiv-Aufträge nur auf Effizienzkernen, ob Whisper die GPU
  nutzen darf, Aufträge gleichzeitig, die Plätze dazu für Sofort und Stufe 1, und die
  Whisper-Modelle: welche das Funkhaus will (auf jedem Mac small und large-v3-turbo, das eine
  Untertitel-Modell, rund 2,1 GB), ob sie laden oder bereit sind, wie schnell, wie viel Platz
  sie belegen), **Funkhaus** (welches, und ein anderes einrichten),
  **Kopplung** (Name, öffentlicher Schlüssel, Tunnel).
- **Lange Zeilen** kürzt das Menü mit „…“, damit es nicht breiter als etwa 420 Punkt wird; ein Pfad
  verliert seine Mitte, eine Auftragszeile nur den Titel, die Prozent bleiben. Den ganzen Text
  zeigt der Tooltip, und „Protokoll anzeigen …“ hat ihn auch.
- **Beenden** während einer Umwandlung fragt nach und gibt den Auftrag zurück.
- **Bei der Anmeldung starten** (beim ersten Start fragt Slipstream einmal, „Ja“ ist
  vorgewählt; in den Einstellungen umschaltbar): Slipstream startet mit jeder Anmeldung. macOS zeigt es unter Systemeinstellungen → Allgemein →
  Anmeldeobjekte; dort ausgeschaltet, zeigen es die Einstellungen auch aus.
- **Nach Updates suchen …:** Slipstream sucht ohnehin einmal am Tag und fragt, bevor es eine neue
  Version installiert; abschalten in Einstellungen → Allgemein. Danach Safari mit ⌘Q beenden und
  neu öffnen.
- **Lizenzen …** zeigt die Lizenzen von Slipstream und von allem, was es mitbringt.

Slipstream rechnet mit niedriger Priorität: was du am Mac tust, geht vor. Der Mac schläft nicht
ein, solange Slipstream einen Auftrag hat.

## Wenn etwas schiefgeht

- **Das Funkhaus findet Slipstream nicht, obwohl App und Extension laufen:** Safari mit ⌘Q
  beenden und neu öffnen. Ein Safari, das schon vor dem Installieren oder Update lief, kennt die
  neue Extension nicht.
- **Das Funkhaus zeigt „Slipstream starten“:** Die Extension ist an, die App läuft nicht.
  Ein Klick darauf startet sie im Hintergrund.
- **Die Seite sagt, ProRes werde hier nicht unterstützt:** Slipstream ist nicht installiert, die
  Extension ist aus, oder sie darf beim Funkhaus nicht laufen (Safari →
  Einstellungen → Erweiterungen → Slipstream; das Menü zeigt dann unter „Verbindung“
  „Safari-Extension: noch nicht verbunden“). Danach die Seite neu laden.
- **„Das ist keine Videodatei.“** oder **„Dieses Videoformat (…) kann der Mac nicht lesen.“**:
  Neu aus Final Cut exportieren.
- **„Auf dem Mac ist kein Platz mehr frei.“**: Platz schaffen; 10 Minuten 4K brauchen etwa
  50 GB für die Kopie und 4 GB für das Ergebnis.
- Alles andere: ein [Issue](../../../issues) öffnen, mit einem Bildschirmfoto und der Datei
  `~/Library/Logs/Slipstream/slipstream.log` (Protokoll anzeigen → Im Finder zeigen).
