# Entwicklung und Build

## Branches

| Branch | Inhalt |
| --- | --- |
| `claude/hotte-ci` | Standard-Branch: Build-Workflow, `hotte-sync.env`, Dokumentation, Changelog |
| `claude/hotte-features` | Upstream `develop` (Commit `FEATURES_BASE`) plus die eigenen Feature-Commits |

Auf `claude/hotte-ci` liegen außerdem der Installer (`install/install.sh`, `install/proxmox.sh`) und die
Referenz-Konfiguration `deploy/compose.yaml`. Der Installer erzeugt dieselbe Datei; Änderungen an einer Stelle
daher an der anderen nachziehen. Die Skripte vor jedem Push mit `shellcheck -x install/*.sh` prüfen.
`install.sh` läuft auch unter Alpine (busybox): keine GNU-only-Optionen verwenden (`grep -P`, `sed -i` mit
GNU-Erweiterungen, `stat -c`, `date -d`, `timeout`, `hostname -I` nur als Rückfall) und keine Prozess-Substitution
`<( … )` (braucht `/dev/fd`).

Nur für Tests: `OS_RELEASE_FILE=<Datei>` ersetzt `/etc/os-release` (z. B. Alpine-Pfad mit `DRY_RUN=1` auf einem
Debian-Rechner prüfen), `NPMPLUS_HOTTE_LIB=1` lädt beim `source` nur die Funktionen, ohne den Ablauf zu starten.
`OLD_COMPOSE=<Datei> DRY_RUN=1` zeigt die Übernahme einer fremden compose.yaml (`docker compose config` braucht
keinen laufenden Docker-Dienst).

Jede Funktion ist ein eigener Commit auf `claude/hotte-features`. Neue Funktionen verändern Upstream-Dateien so
wenig wie möglich (neue Dateien bevorzugen, in Upstream-Dateien nur kurze Aufrufe), damit spätere Rebases
selten Konflikte haben.

## Build

Workflow `.github/workflows/hotte-sync.yml`, Konfiguration in `hotte-sync.env`:

- Läuft jede Nacht um 01:17 UTC, bei jedem Push auf `claude/hotte-ci` und manuell (Option `force`).
- **`BASE=pinned`** (Standard): baut `claude/hotte-features` genau so, wie er ist. Unveränderter Code wird
  übersprungen, außer sonntags (Auffrischen der Basis-Pakete).
- **`BASE=release`**: setzt die Feature-Commits auf das neueste Upstream-Release. Klappt das nicht, wird ein Issue
  angelegt und das letzte Image bleibt.
- Ergebnis: `ghcr.io/hotte512/npmplus:hotte-main` und `:hotte-<tree-hash>`. Die Version im Image lautet
  `<basis>-<commit>-hotte`.
- Geplante Workflows laufen nur auf dem Standard-Branch des Forks, deshalb muss `claude/hotte-ci` Standard bleiben.

## Upstream übernehmen

Upstream `develop` wird regelmäßig neu geschrieben (Force-Push). Deshalb wird nicht automatisch nachgezogen,
sondern bei Bedarf:

1. Feature-Commits auf das neue `upstream/develop` setzen (`git cherry-pick FEATURES_BASE..claude/hotte-features`),
   Konflikte lösen.
2. Lint (Biome), Schema-Prüfung (`node backend/validate-schema.js`), Frontend-Build, betroffene Funktionen testen.
3. `claude/hotte-features` per Force-Push (mit Lease) ersetzen.
4. `FEATURES_BASE` in `hotte-sync.env` auf den neuen Upstream-Commit setzen und pushen, das startet den Build.
5. Eintrag im [CHANGELOG](../CHANGELOG.md) unter „Upstream“.

## Warum nicht auf dem Upstream-Release?

Upstream hat `develop` am 17.10.2026 als neuen Branch ohne Vorgänger angelegt (neu geschriebene Fassung), das
Release `2026-10-22-r1` stammt noch von der alten Linie. Beide haben keinen gemeinsamen Commit, die Features passen
nur auf `develop`. Sobald ein Release aus dem neuen `develop` erscheint, kann auf `BASE=release` umgestellt werden.

## Regeln für dieses öffentliche Repository

Nichts aus dem eigenen Netz gehört in Code, Doku, Commits, Issues oder Kommentare:

- keine echten Domains, Hostnamen, internen IP-Adressen, MAC-Adressen
- keine API-Keys, Tokens, Passwörter, Site-IDs, Konto- oder Geräte-IDs
- keine E-Mail-Adressen, Namen oder Pfade aus dem eigenen System
- in Beispielen nur `example.com` / `example.org` und `192.168.1.x` (bzw. RFC-5737-Adressen)

Doku und Changelog werden mit jeder Änderung gepflegt.
