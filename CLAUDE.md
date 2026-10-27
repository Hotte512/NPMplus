# Hinweise für Claude

Eigene NPMplus-Variante „Hotte“. Dieser Branch (`claude/hotte-features`) enthält Upstream `develop` plus die
eigenen Feature-Commits. Build, Doku und Changelog liegen auf `claude/hotte-ci`
(`README.md`, `docs/`, `CHANGELOG.md`, `CLAUDE.md` dort lesen).

- Ein Commit pro Funktion, Upstream-Dateien nur minimal ändern (neue Dateien bevorzugen).
- Nach jeder Änderung `CHANGELOG.md` und `docs/features.md` auf `claude/hotte-ci` pflegen.
- Öffentliches Repository: keine echten Domains, Hostnamen, internen IPs, Keys/Tokens, IDs, E-Mail-Adressen oder
  lokalen Pfade in Code, Doku, Commits, Issues oder Kommentare; Beispiele nur mit `example.com` / `192.168.1.x`.
