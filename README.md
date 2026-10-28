# NPMplus · Hotte

Eigene Variante von [NPMplus](https://github.com/ZoeyVid/NPMplus) (Reverse-Proxy mit Weboberfläche, Fork des
Nginx Proxy Manager) mit zusätzlichen Funktionen für Homelab und UniFi-Netze. Fertiges Docker-Image:
`ghcr.io/hotte512/npmplus:hotte-main`.

> **English:** A community build of NPMplus with extra features: tags/descriptions for proxy hosts, a log viewer,
> local DNS records on UniFi gateways (optionally through the permission proxy
> [UniFi API Guard](https://github.com/Hotte512/unifi-api-guard)), ACME pass-through and an http.net DNS provider.
> One-line installer for Proxmox LXC with optional CrowdSec and UniFi API Guard, see
> [docs/installation.md](docs/installation.md). Docs are in German; issues in English are welcome.

- **Installation:** [docs/installation.md](docs/installation.md)
- **Funktionen und Bedienung:** [docs/features.md](docs/features.md)
- **Änderungen:** [CHANGELOG.md](CHANGELOG.md)
- **Build, Branches, Upstream-Updates:** [docs/development.md](docs/development.md)

## Überblick der Erweiterungen

| Bereich | Funktion |
| --- | --- |
| Proxy-Hosts | Beschreibung, Tags, Gruppierung, kompakte Tabelle mit ein-/ausblendbaren Spalten |
| Proxy-Hosts | ACME-http-01-Challenges an das Ziel weiterleiten (eigener Port) |
| Proxy-Hosts | Lokaler DNS-Eintrag auf einem UniFi-Gateway (UniFi Network 9.4+), optional über den [UniFi API Guard](https://github.com/Hotte512/unifi-api-guard) |
| Zugriffslisten | Beschreibung, Anzeige der Proxy-Hosts, die eine Liste verwenden |
| Zertifikate | DNS-Challenge über http.net, beschränkt auf erlaubte Zonen |
| Logs | Log-Viewer für nginx-, Certbot- und NPMplus-Logs, API-Keys werden im Log maskiert |
| Oberfläche | Hotte-Logo im Header, damit die Variante sofort erkennbar ist |
| Installation | Installer für Proxmox-LXC und vorhandene Debian/Ubuntu-Systeme, optional mit CrowdSec und UniFi API Guard |

Alle Funktionen von NPMplus selbst (CrowdSec, gehärtetes TLS, HTTP/3, …) bleiben erhalten.

## Installation

**Proxmox VE** – auf dem Host ausführen, legt einen Debian-LXC an und installiert alles darin:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install/proxmox.sh)"
```

**Vorhandener LXC oder VM** (Debian 12/13, Ubuntu 22.04/24.04) – als root ausführen:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install/install.sh)"
```

Der Installer fragt, ob der **UniFi API Guard** und **CrowdSec** mit eingerichtet werden sollen, installiert bei
Bedarf Docker und schreibt eine `compose.yaml`. Details, unbeaufsichtigte Installation und Deinstallation:
[docs/installation.md](docs/installation.md).

**Von Hand:** [deploy/compose.yaml](deploy/compose.yaml) ist die Referenz-Konfiguration mit auskommentierten Blöcken
für Guard und CrowdSec. Ein bestehendes NPMplus lässt sich umstellen, indem nur das Image getauscht wird:

```yaml
services:
  npmplus:
    image: ghcr.io/hotte512/npmplus:hotte-main
    pull_policy: always
```

## UniFi API Guard (optional, empfohlen mit UniFi Local DNS)

UniFi-API-Keys haben keine Berechtigungsstufen: Wer den Key aus NPMplus erbeutet, könnte die ganze Firewall
umkonfigurieren. Der [UniFi API Guard](https://github.com/Hotte512/unifi-api-guard) ist ein kleiner Rechte-Proxy
davor. NPMplus bekommt einen eigenen Key, der nur DNS-Einträge der eigenen Domains anlegen, ändern und löschen darf.
Läuft der Guard auf demselben Host, ist er nur lokal erreichbar (`http://127.0.0.1:8090`). Einrichtung:
[Anleitung des Guards](https://github.com/Hotte512/unifi-api-guard/blob/main/docs/anleitung.md).

## Build-Stand

Das Image wird derzeit aus dem Upstream-Branch **`develop`** gebaut (plus die eigenen Funktionen), weil das
aktuelle Upstream-Release noch von der alten Code-Linie stammt. Sobald ein Release auf der neuen Linie erscheint,
wird auf **Release-Basis** umgestellt. Hintergrund: [docs/development.md](docs/development.md).

## Updates

Der Installer kann ein tägliches Update einrichten. Von Hand:

```bash
docker compose -f /opt/npmplus-hotte/compose.yaml pull && docker compose -f /opt/npmplus-hotte/compose.yaml up -d && docker image prune -f
```

## Haftungsausschluss und Hinweise

- **Keine Haftung, keine Gewähr.** Privates Hobby-Projekt. Nutzung auf eigenes Risiko; vor Änderungen am
  Live-System eine Sicherung bzw. einen Proxmox-Snapshot anlegen. Für Schäden, Datenverlust oder Ausfälle wird
  keine Haftung übernommen.
- **Mit KI-Unterstützung entwickelt.** Code, Skripte und Doku entstehen mit Hilfe von KI (Claude), werden
  geprüft und getestet, können aber trotzdem Fehler enthalten. Skripte vor dem Ausführen lesen.
- **Nicht mit dem NPMplus-Upstream verbunden** – Fehler dieser Variante bitte hier melden, nicht bei NPMplus.
- Lizenz wie NPMplus (AGPL-3.0, Teile MIT).

> **English:** No warranty, no liability – use at your own risk and keep a backup/snapshot. Developed with AI
> assistance (Claude); reviewed and tested, but mistakes are possible. Not affiliated with NPMplus upstream.
