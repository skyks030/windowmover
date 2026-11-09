# WindowMover

Kleine macOS-Menüleisten-App (ab macOS 14), mit der man Fenster über die Bildschirmkante auf einen anderen Monitor ziehen kann – auch dann, wenn man per **Remote Desktop** nur einen der Bildschirme sieht.

## So funktioniert's

1. Menüleisten-Symbol (Mauspfeil) → **Move a Window**
   In der Mitte des Bildschirms erscheint ein großer Mauszeiger.
2. Den großen Zeiger mit der Maus auf die **Titelleiste** des Fensters ziehen
   (Feinjustierung: Pfeiltasten, mit ⇧ in 10er-Schritten; Esc blendet ihn aus).
3. Menüleiste → **Let's go** → Richtung wählen (rechts / links / oben / unten)
   – alternativ Rechtsklick oder ⏎ auf den großen Zeiger.

WindowMover drückt dann an der Spitze des Zeigers die Maustaste, zieht das Fenster auf den benachbarten Bildschirm (an die entsprechende Position), lässt los und setzt den Mauszeiger wieder auf den sichtbaren Bildschirm zurück. Richtungen ohne Bildschirm sind ausgegraut.

Beim ersten Start fragt macOS nach dem **Bedienungshilfen-Zugriff** (Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen) – ohne ihn kann die App die Maus nicht steuern.

## Installation

Aktuelle Version unter [Releases](https://github.com/skyks030/windowmover/releases/latest) (`.dmg` oder `.zip`) herunterladen und nach *Programme* ziehen.
Da die App nicht notarisiert ist: beim ersten Start Rechtsklick → *Öffnen*.

## Updates & Versionen

- **Jeder Push auf `main` erzeugt automatisch eine neue Version** (GitHub Actions, `.github/workflows/release.yml`):
  die letzte Stelle zählt hoch (`1.0.0`, `1.0.1`, …). Für einen größeren Sprung die Datei `VERSION` ändern (z. B. `1.1`) – die Zählung beginnt dann bei `1.1.0`.
- Die App prüft **bei jedem Start** (und danach alle 6 Stunden) auf eine neue Version und installiert sie automatisch.
- Manuell: Menü → *Nach Updates suchen …*. Die aktuelle Version steht oben im Menü.
- Releases werden mit einem festen, selbst erzeugten Zertifikat signiert (GitHub-Secrets `SIGNING_P12_BASE64` / `SIGNING_P12_PASSWORD`), damit macOS die Bedienungshilfen-Berechtigung über Updates hinweg behält.

## Entwicklung

```sh
./build.sh                 # baut build/WindowMover.app (lokal ad-hoc signiert)
scripts/version.sh         # zeigt die Version, die der nächste Push bekäme
open build/WindowMover.app
```
