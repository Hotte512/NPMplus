# NPMplus · Hotte

Eigene Variante von [NPMplus](https://github.com/ZoeyVid/NPMplus) mit zusätzlichen Funktionen, gebaut als
Docker-Image `ghcr.io/hotte512/npmplus:hotte-main`.

- **Funktionen und Bedienung:** [docs/features.md](docs/features.md)
- **Build, Branches, Upstream-Updates:** [docs/development.md](docs/development.md)
- **Änderungen:** [CHANGELOG.md](CHANGELOG.md)

## Überblick der Erweiterungen

| Bereich | Funktion |
| --- | --- |
| Proxy-Hosts | Beschreibung, Tags, Gruppierung, kompakte Tabelle mit ein-/ausblendbaren Spalten |
| Proxy-Hosts | ACME-http-01-Challenges an das Ziel weiterleiten (eigener Port) |
| Proxy-Hosts | Lokaler DNS-Eintrag auf einem UniFi-Gateway (UniFi Network 9.4+) |
| Zertifikate | DNS-Challenge über http.net, beschränkt auf erlaubte Zonen |
| Logs | Log-Viewer für nginx-, Certbot- und NPMplus-Logs |
| Oberfläche | Hotte-Logo im Header, damit die Variante sofort erkennbar ist |

## Installation

`compose.yaml` (Beispiel, Rest wie bei NPMplus):

```yaml
services:
  npmplus:
    image: ghcr.io/hotte512/npmplus:hotte-main
    pull_policy: always
```

Automatisches Update per Cron (Beispiel für Alpine, `/etc/crontabs/root`):

```
30 4 * * * docker compose -f /pfad/zu/compose.yaml pull -q npmplus && docker compose -f /pfad/zu/compose.yaml up -d && docker image prune -f > /dev/null
```

`docker image prune -f` entfernt die alten, nicht mehr getaggten Images.

## Hinweis

Dieses Repository ist ein privates Projekt ohne Support. Lizenz wie NPMplus (AGPL-3.0, Teile MIT).
