# Jemrix – nur für Remlingers

Das Block-Puzzle der Familie Remlinger als Web-App fürs iPhone (ab iPhone 15, Hochformat).
Nach dem Intro wählt man **Jemrix** (Block-Puzzle) oder **jenMah** (Mahjong mit dem Original-Satz von 144 Steinen).

## Spielen
1. Link in **Safari** öffnen: `https://jremlinger-sv.github.io/rix/`
2. Teilen-Symbol → **Zum Home-Bildschirm** → Hinzufügen
3. Jemrix startet ab jetzt wie eine App: Vollbild, eigenes Icon, funktioniert auch offline.

## Gemeinsame Highscore-Liste (Supabase, einmalig einrichten)
1. Auf <https://supabase.com> kostenlos registrieren → **New project**, Region **Frankfurt (eu-central-1)**.
2. Im Projekt: **SQL Editor → New query**, den Inhalt von `supabase-setup.sql` einfügen → **Run**.
3. **Project Settings → API**: „Project URL“ und den **anon public** Key kopieren.
4. Beides in `config.js` eintragen (`supabaseUrl`, `supabaseKey`) und speichern/committen.

Ohne diese Angaben läuft das Spiel trotzdem – dann führt jedes iPhone seine eigene Liste.

**jenMah-Liste:** einmalig `supabase-jenmah.sql` im SQL Editor ausführen (eigene Liste, gleicher Familien-Code). Zurücksetzen mit `select reset_scores_mah();`.

**Liste zurücksetzen:** Im Supabase SQL Editor `select reset_scores();` ausführen. Die Geräte leeren ihre lokalen Listen beim nächsten Start automatisch mit.

## Dateien
| Datei | Zweck |
|---|---|
| `index.html` | Jemrix mit Intro und Spielauswahl (wird aus `jemrix-source.html` erzeugt) |
| `jenmah.html` | jenMah – Mahjong (wird aus `jenmah-source.html` erzeugt) |
| `config.js` | Supabase-Zugang und Familien-Code |
| `sw.js` | Offline-Speicher |
| `manifest.webmanifest`, `icons/` | App-Name, Icon, Startbild |
| `fonts/` | Schriften lokal (keine Google-Fonts-Abfrage, DSGVO-freundlich) |
| `supabase-setup.sql` | Datenbank für die Highscores |
| `supabase-jenmah.sql` | eigene Highscore-Liste für jenMah |
| `build.py`, `sw.template.js` | Werkzeuge zum Neu-Erzeugen von `index.html` und `sw.js` |

## Vorschau-Links
Looks und Geburtstage lassen sich mit einem Zusatz am Link ansehen, z. B. `…/rix/#weihnachten`, `#halloween`, `#ostern`, `#fruehling`, `#sommer`, `#herbst`, `#winter`, `#geburtstag-emma`, `#geburtstag-jenny`, `#geburtstag-jens`.

jenMah: `…/rix/jenmah.html#stufe-5` springt zum Ansehen direkt in eine Stufe (nur nach dem Intro).
