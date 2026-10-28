# Changelog

Alle Änderungen an NPMplus · Hotte. Format angelehnt an [Keep a Changelog](https://keepachangelog.com/de/1.1.0/),
Einträge nach Datum. Upstream-Änderungen stehen im [NPMplus-Repository](https://github.com/ZoeyVid/NPMplus).

## 2026-10-28

### Neu
- **UniFi Local DNS:** erkennt einen UniFi API Guard hinter der Gateway-URL, zeigt dessen Version und verlinkt
  direkt zur Guard-Verwaltung.
- **CrowdSec-Seite:** eigener Menüpunkt mit aktiven Bans (manuell bannen und entbannen), Alerts (angegriffene Hosts
  und Pfade) und den Bouncer-Einstellungen, ohne Neustart ([Doku](docs/features.md#crowdsec-seite)).
- **Proxy-Hosts:** CrowdSec-Bouncer pro Host abschaltbar.
- **Installer:** legt mit CrowdSec auch den Machine-Login für die CrowdSec-Seite an.
- **Installer für Alpine:** `install.sh` läuft jetzt auch auf Alpine 3.20+; `proxmox.sh` legt standardmäßig einen
  Alpine-LXC an (kleiner, schneller Start), Debian bleibt wählbar (`CT_OS`).
- **Übernahme einer vorhandenen Installation** (z. B. per community-scripts): Umgebungsvariablen, Zusatz-Volumes,
  DNS und Guard werden übernommen, die Daten in `/opt/npmplus` bleiben, alter Update-Job wird ersetzt, Rückweg wird
  angezeigt.
- **`install.sh --update`:** System- und Container-Update in einem Befehl; optional tägliches System-Update
  (`AUTO_OS_UPDATE`).
- **Installer:** ein Befehl für Proxmox VE (legt einen Debian-LXC an) oder für vorhandene Debian/Ubuntu-Systeme.
  Fragt nach UniFi API Guard, CrowdSec und automatischen Updates, installiert Docker und richtet alles ein
  ([Anleitung](docs/installation.md)).
- **Referenz-Konfiguration** `deploy/compose.yaml` mit optionalen Blöcken für UniFi API Guard und CrowdSec.
- **UniFi API Guard:** neues Begleitprojekt, ein Rechte-Proxy für die UniFi-API. NPMplus bekommt damit einen Key,
  der nur die DNS-Einträge der eigenen Domains ändern darf ([Projekt](https://github.com/Hotte512/unifi-api-guard)).
- **Zugriffslisten:** Spalte „Proxy-Hosts“ zeigt, welche Hosts und Locations die Liste verwenden; ein Klick öffnet
  den Host. Die Suche findet auch diese Domains.
- **Zugriffslisten:** Feld „Beschreibung“, angezeigt unter dem Namen und durchsuchbar.

### Geändert
- Installer: ein erneuter Lauf übernimmt die bisherigen Antworten und zusätzliche Einträge der `compose.yaml`.
- README: Haftungsausschluss und Hinweis auf die Entwicklung mit KI-Unterstützung (deutsch und englisch).
- Doku UniFi Local DNS: richtige Gateway-URL mit Guard auf demselben Host (`http://127.0.0.1:8090`).
- Installationsanleitung: Abschnitt Fehlersuche (u. a. versehentlicher Lauf auf dem Proxmox-Host), Hinweise
  zu den CrowdSec-Kennzahlen.
- README überarbeitet: Installation, Hinweis auf den UniFi API Guard, Build-Stand (derzeit Upstream `develop`,
  später Release), kurze englische Zusammenfassung.
- Doku UniFi API Guard v1.1.0: Regeln lassen sich im Formular auf der Key-Seite ändern (JSON bleibt als
  Expertenmodus); Installations- und Funktionsdoku ergänzt. Das Guard-Image `latest` ist jetzt v1.1.0.
- README: Sprachwahl oben (Deutsch/Englisch), englische Fassung als `README.en.md`.

### Behoben
- **Sicherheit, UniFi Local DNS:** Nur Admins können den lokalen DNS-Eintrag eines Proxy-Hosts einschalten oder
  ändern; bei Hosts mit aktivem Eintrag auch Domainnamen und Ziel-Host. Vorher konnte jeder Nutzer mit dem Recht
  „Proxy-Hosts verwalten“ für beliebige freie Domains LAN-weite DNS-Einträge anlegen.
- **Sicherheit, UniFi Local DNS:** Das Zertifikat des Gateways lässt sich per SHA-256-Fingerprint festlegen
  (selbstsignierte Zertifikate). Ohne Prüfung warnt die Einstellungsseite und bietet den zuletzt gesehenen
  Fingerprint zum Übernehmen an. Gilt auch für die Erkennung des UniFi API Guard.
- Installer: Zusatzdienste der alten Installation (z. B. `geoipupdate` für GeoIP) werden bei der Übernahme
  mitgenommen und bei jedem weiteren Lauf behalten; mit `IMPORT_FROM` lassen sie sich nachträglich holen.
- Installer: Der Probelauf (`DRY_RUN`) bricht nicht mehr ab, wenn `jq` fehlt, und zeigt übernommene Werte nur als `***`.
- Installer: Ein vorübergehender Fehler beim Laden der Images lässt eine Übernahme nicht mehr halb fertig zurück.
- Installer: liest das Einrichtungs-Token des Guards aus der neuen Datei `setup-token`; bei fehlendem Token
  nennt er den `chown`-Befehl für das Datenverzeichnis.
- Installer: `install.sh` bricht auf einem Proxmox-VE-Host ab und verweist auf `proxmox.sh` (Docker auf dem Host
  würde die Netze der VMs und LXCs stören).
- Installer: zeigt beim Warten auf Netzwerk, NPMplus und CrowdSec den Fortschritt an statt stumm zu wirken; keine
  Locale-Warnungen mehr in frischen LXC-Containern.
- **Sicherheit:** Der UniFi-API-Key konnte im Log (Konsole und Log-Viewer) erscheinen, wenn das Speichern der
  Einstellung an einem Datenbankfehler scheiterte. API-Keys werden jetzt in allen Logzeilen maskiert. Wer den Key
  im Log gesehen hat, sollte ihn im UniFi-Gateway neu erzeugen.

## 2026-10-27

### Neu
- **UniFi Local DNS:** lokale DNS-Einträge für Proxy-Hosts auf einem UniFi-Gateway (Ziel: NPMplus-Adresse,
  Ziel-Host oder eigenes Ziel), Einstellungsseite mit Übersicht aller Einträge und „Jetzt synchronisieren“,
  DNS-Badge in der Host-Liste, Statuszeile im Proxy-Host-Dialog.
- **UniFi Local DNS:** einstellbare TTL, Standard „Auto“ wie in der UniFi-Oberfläche.
- **UniFi Local DNS:** vorhandene identische Einträge werden übernommen statt als Konflikt gemeldet.
- **http.net** als DNS-Anbieter für Let's-Encrypt-DNS-Challenges, beschränkt auf erlaubte Zonen.
- **ACME-Weiterleitung:** eigener Port für Challenges am Ziel-Host.
- **Hotte-Logo** im Header und im Seitentitel.
- **Proxy-Host-Tabelle:** kompakte zweizeilige Darstellung, Spalten ein-/ausblendbar.

### Geändert
- Hotte-Logo neu gestaltet: petrolfarbenes „H“-Monogramm.
- ACME-Weiterleitung an das neue Upstream-Verfahren angepasst: erst das Ziel fragen, bei Fehler antwortet NPMplus.
- Build: baut den Feature-Branch unverändert, Upstream wird gezielt übernommen; wöchentlicher Neubau am Sonntag.

### Behoben
- UniFi Local DNS: Einträge wurden abgelehnt, weil die TTL fehlte.
- Log-Viewer: die eigenen Abfragen des Log-Viewers tauchten im Textfilter auf.

### Upstream
- Basis auf `develop` `50adf2a8` aktualisiert (u. a. zustandslose ACME-Challenges, Dateien unter `/data/nginx`).

## 2026-10-26

### Neu
- **Proxy-Hosts:** Beschreibung, Tags, Sortierung nach Basis-Domain, Gruppierung (Gruppe, Basis-Domain, Ziel, Tag).
- **ACME-Weiterleitung:** http-01-Challenges optional an das Ziel weiterleiten.
- **Log-Viewer** für nginx-, Certbot- und NPMplus-Logs.
- Nächtlicher Build des eigenen Images `ghcr.io/hotte512/npmplus:hotte-main`.
