# Funktionen

Installation: [installation.md](installation.md).

Alle Beispiele verwenden Platzhalter (`example.com`, `192.168.1.x`).

## Proxy-Hosts: Beschreibung, Tags und Gruppierung

- Im Proxy-Host-Dialog gibt es die Felder **Beschreibung** (max. 255 Zeichen) und **Tags** (max. 20, Vorschläge aus
  den vorhandenen Tags).
- Die Suche findet auch Beschreibung und Tags. Ein Klick auf einen Tag filtert die Liste danach.
- **Gruppieren nach:** Gruppe (Verzeichnis), Basis-Domain, Ziel, Tag oder keine. Die Auswahl merkt sich der Browser.
- Die Spalte „Quelle“ sortiert nach umgekehrten Domain-Labels, Subdomains einer Domain stehen also beieinander.

## Proxy-Hosts: kompakte Tabelle und Spalten

- Jeder Host belegt zwei Zeilen: Domains, DNS-Badge und Tags in Zeile 1, Beschreibung und Erstelldatum in Zeile 2
  (volle Uhrzeit als Tooltip über dem Datum).
- Über **Spalten** lassen sich Besitzer, Ziel, TLS, Zugriff, Status und ID ausblenden (im Browser gespeichert).

## Proxy-Hosts: ACME-Challenges an das Ziel weiterleiten

Für Dienste, die selbst ein Zertifikat per http-01 anfordern (z. B. Home Assistant, Router-Oberflächen):

- Schalter **„ACME-http-01-Challenges an Upstream weiterleiten“** im Proxy-Host-Dialog (nur bei Schema http/https).
- **Port für ACME-Challenges** (Standard 80): Challenges gehen immer per http an den Ziel-Host auf diesem Port.
- Ablauf: Die Challenge wird zuerst an das Ziel weitergeleitet. Antwortet es mit 403/404/5xx oder ist es nicht
  erreichbar, beantwortet NPMplus die Challenge selbst. So funktionieren die Zertifikate von NPMplus und vom Ziel.
- Zugriffslisten und Authentifizierung gelten für diesen Pfad nicht.

## Proxy-Hosts: lokaler DNS-Eintrag auf einem UniFi-Gateway

Legt für die Domains eines Proxy-Hosts einen lokalen DNS-Eintrag auf einem UniFi-Gateway an (z. B. UDM Pro), damit
Clients im LAN das Ziel direkt bzw. über die LAN-IP von NPMplus erreichen.

**Voraussetzungen:** UniFi Network 9.4 oder neuer, API-Key unter *UniFi Network › Einstellungen › Integrationen*.
UniFi-API-Keys haben keine Berechtigungsstufen. Den Key daher mit einem eigenen lokalen Admin erzeugen, der nur die
Network-Rolle „Site Admin“ hat. Wer die Rechte enger fassen will (z. B. nur DNS-Einträge bestimmter Domains),
setzt einen Rechte-Proxy wie [UniFi API Guard](https://github.com/Hotte512/unifi-api-guard) dazwischen und trägt
dessen URL und Key hier ein. Den Key legt man mit der Guard-Vorlage „Lokale DNS-Einträge“ an, die Regeln setzt sie
automatisch; ab Guard v1.1.0 lassen sie sich im Formular auf der Key-Seite anpassen, ohne JSON.
Läuft der Guard auf demselben Host (Installer bzw. Block aus `deploy/compose.yaml`), lautet die Gateway-URL `http://127.0.0.1:8090` – nicht 8080, das ist der Port des allgemeinen Guard-Beispiels bzw.
der CrowdSec-LAPI. „TLS prüfen“ bleibt dann aus.

Der Key wird in Logs (Konsole, Log-Viewer) maskiert.

**Einstellungen › UniFi Local DNS:**

| Feld | Bedeutung |
| --- | --- |
| Aktiviert | Ein/Aus. Beim Ausschalten werden alle von NPMplus angelegten Einträge entfernt. |
| Gateway-URL | z. B. `https://192.168.1.1` |
| API-Key | Wird nur geschrieben, nie angezeigt. Leer lassen behält den gespeicherten Key. |
| Site-ID | Leer = Standard-Site |
| NPMplus-Adresse | LAN-IP von NPMplus, Ziel für Hosts mit „NPMplus-Adresse“ |
| TTL | Leer oder 0 = Auto (wie in der UniFi-Oberfläche) |
| TLS prüfen | Zertifikat des Gateways prüfen (aus bei selbstsigniertem Zertifikat) |

Darunter stehen alle von NPMplus verwalteten Einträge, Fehler und der Button **„Jetzt synchronisieren“**.

**Pro Proxy-Host** („Lokaler DNS-Eintrag (UniFi)“): aus, NPMplus-Adresse, Ziel-Host oder eigenes Ziel (IP oder
Hostname). IPs werden A/AAAA-Einträge, Hostnamen CNAME-Einträge. Wildcard-Domains werden übersprungen.

**Verhalten:**

- Geändert oder gelöscht werden nur Einträge, die NPMplus angelegt hat.
- Gibt es für eine Domain schon einen identischen Eintrag (gleicher Typ und gleiches Ziel), wird er übernommen und
  ab dann von NPMplus verwaltet. Ein abweichender Eintrag bleibt unangetastet und wird als Fehler angezeigt.
- Der Abgleich läuft nach jedem Speichern, Aktivieren, Deaktivieren und Löschen eines Hosts im Hintergrund,
  beim Speichern der Einstellungen und beim Start von NPMplus.
- Status: grünes/rotes **DNS**-Badge in der Host-Liste, Statuszeile im Proxy-Host-Dialog, Details im Log-Viewer
  unter „NPMplus-Log“.

## Zugriffslisten: Beschreibung und Verwendung

- Im Zugriffslisten-Dialog gibt es das Feld **Beschreibung** (max. 255 Zeichen). Es steht in der Tabelle unter dem
  Namen.
- Die Spalte **Proxy-Hosts** listet die ersten drei Hosts, die die Liste verwenden, z. B. `example.com` oder
  `example.com /admin` bei einer Location. Weitere stehen als „+N weitere“ da, alle im Tooltip. Ein Klick auf eine
  Domain öffnet den Proxy-Host-Dialog.
- Ohne die Berechtigung, alle Einträge zu sehen, erscheinen nur die eigenen Proxy-Hosts.
- Die Suche findet Name, Beschreibung und die Domains der verwendenden Hosts.

## Zertifikate: DNS-Challenge über http.net

- DNS-Anbieter **„http.net“** beim Anlegen eines Let's-Encrypt-Zertifikats mit DNS-Challenge.
- Zugangsdaten:

  ```ini
  dns_httpnet_api_token = DEIN_API_KEY
  # Pflicht: nur diese Zonen (und ihre Subdomains) dürfen geändert werden
  dns_httpnet_allowed_zones = example.com, example.org
  ```

- Jede Domain wird vor dem API-Aufruf gegen `dns_httpnet_allowed_zones` geprüft, andere Domains werden abgelehnt.
- Empfehlung: eigener API-Key bei http.net nur mit den Rechten `zoneConfigsFind`, `recordsFind`, `recordsUpdate`
  und, wenn möglich, IP-Beschränkung.

## CrowdSec-Seite

Menü **CrowdSec** (nur Admins) für den in NPMplus eingebauten CrowdSec-Bouncer. CrowdSec selbst läuft als eigener
Container (Installer bzw. Block in `deploy/compose.yaml`). Oben zeigen Badges, ob der Bouncer aktiv ist, die
Local API erreichbar ist und Bouncer-Key und Machine-Login funktionieren.

- **Bans:** aktive Sperren mit IP/Bereich, Scenario, Herkunft, Typ und Restlaufzeit, filterbar. Die
  Community-Blockliste wird nicht angezeigt (zehntausende Einträge). IP oder Bereich (CIDR) manuell bannen mit
  Dauer, Typ (ban/captcha) und Grund, Sperren einzeln entfernen.
- **Alerts:** die letzten Alerts mit Zeit, Quelle (Land, Provider), Scenario, angegriffenen Hosts und Pfaden (z. B.
  `/.env`) und Anzahl Events. Filter nach IP/Bereich oder Scenario; Entbannen direkt aus dem Alert.
- **Einstellungen:** bearbeitet `/data/crowdsec/crowdsec.conf` (Bouncer an/aus, Local-API-URL, Bouncer-Key, Modus,
  Antwort für gesperrte Clients, Captcha, AppSec). Unbekannte Zeilen und Kommentare bleiben erhalten. Speichern lädt
  nginx neu, ein Neustart ist nicht nötig; lehnt nginx die Konfiguration ab, bleibt der alte Stand.
- Bouncer-Key, Captcha-Secret und Machine-Passwort werden nur geschrieben, nie angezeigt, und in Logs maskiert.
- **Machine-Login:** Bannen, Entbannen und Alerts brauchen ihn, nur Anzeigen der Bans geht mit dem Bouncer-Key. Der
  Installer legt ihn an (`/opt/npmplus/crowdsec/lapi-credentials.yaml`), von Hand:
  `docker exec crowdsec cscli machines add npmplus-gui --auto -f -` und Login/Passwort in den Einstellungen
  eintragen.
- **Pro Proxy-Host:** Schalter **„CrowdSec-Bouncer deaktivieren“**. Sperren und AppSec gelten dann für diesen Host
  nicht (z. B. für reine LAN-Dienste).
- Alle Änderungen stehen im Audit-Log.

## Log-Viewer

- Menü **Logs** (nur Admins): Quellen Zugriffslog, Fehlerlog, Stream-Log, Certbot-Log und NPMplus-Log.
- Filter nach Proxy-Host (Zugriffs- und Fehlerlog) und nach Text, Live-Aktualisierung.
- Aus der Host-Liste führt der Menüpunkt **Logs** direkt zum Zugriffslog des Hosts.

## Hotte-Logo

Petrol-farbenes „H“-Monogramm mit Schriftzug „Hotte“ hinter dem NPMplus-Logo im Header, Seitentitel
„NPMplus · Hotte“.
