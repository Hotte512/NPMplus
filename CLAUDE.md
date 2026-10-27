# Hinweise für Claude

Projekt: eigene NPMplus-Variante „Hotte“. Details: `README.md`, `docs/development.md`, `docs/features.md`.

## Pflicht bei jeder Änderung

- `CHANGELOG.md` (dieser Branch, `claude/hotte-ci`) ergänzen: Abschnitt mit dem heutigen Datum, Kategorien
  Neu / Geändert / Behoben / Upstream. Kurz und aus Nutzersicht formulieren.
- `docs/features.md` aktualisieren, wenn sich Funktionen oder Bedienung ändern; `docs/development.md` bei Änderungen
  am Build oder Ablauf.
- Feature-Code liegt auf `claude/hotte-features`, ein Commit pro Funktion; Upstream-Dateien nur minimal ändern.

## Öffentliches Repository: keine internen Informationen

Nie in Code, Doku, Commit-Nachrichten, Issues, PRs oder Kommentare übernehmen, auch nicht aus Logs, Screenshots oder
Fehlermeldungen des Nutzers: echte Domains, Hostnamen, interne IPs, API-Keys/Tokens, Site-/Geräte-IDs,
E-Mail-Adressen, Namen, lokale Pfade. Beispiele nur mit `example.com` und `192.168.1.x`.
Vor jedem Push prüfen, z. B. `git diff` / `git log -p` gegen bekannte interne Werte durchsuchen.
