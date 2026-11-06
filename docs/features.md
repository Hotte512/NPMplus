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
- Ablauf: Eigene Challenges beantwortet NPMplus selbst, alle anderen Tokens gehen an das Ziel. So funktionieren
  die Zertifikate von NPMplus und vom Ziel.
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

Erkennt NPMplus hinter der Gateway-URL einen UniFi API Guard (ab Guard v1.2.0), zeigt die Einstellungsseite dessen Version und den
Button **„Guard-Verwaltung öffnen“**. Die Adresse ergibt sich automatisch (bei `127.0.0.1` der Rechner, über den
NPMplus gerade aufgerufen wird, plus Admin-Port); hinter einem Reverse-Proxy setzt man im Guard `GUARD_ADMIN_URL`.

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
| TLS-Fingerprint | Nur bei „TLS prüfen“ aus: SHA-256-Fingerprint des selbstsignierten Gateway-Zertifikats. NPMplus verbindet sich nur, wenn er passt. Ohne Fingerprint warnt die Seite und zeigt den zuletzt gesehenen zum Übernehmen an (vorher vergleichen, z. B. `openssl s_client -connect 192.168.1.1:443 </dev/null \| openssl x509 -noout -fingerprint -sha256`). |

Darunter stehen alle von NPMplus verwalteten Einträge, Fehler und der Button **„Jetzt synchronisieren“**.

**Pro Proxy-Host** („Lokaler DNS-Eintrag (UniFi)“): aus, NPMplus-Adresse, Ziel-Host oder eigenes Ziel (IP oder
Hostname). IPs werden A/AAAA-Einträge, Hostnamen CNAME-Einträge. Wildcard-Domains werden übersprungen.
Die Einträge gelten im ganzen LAN, deshalb können nur Admins diese Einstellung ändern. Ist ein Eintrag aktiv,
können andere Nutzer auch Domainnamen und Ziel-Host des Hosts nicht ändern.

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
Local API erreichbar ist, Bouncer-Key und Machine-Login funktionieren und ob der
[CrowdSec-Helfer](#crowdsec-helfer) läuft („Helfer aktiv“, „Helfer nicht gefunden“, „Helfer antwortet nicht“,
„Helfer: Fehler“ mit der Meldung als Tooltip).

- **Bans:** aktive Sperren mit IP/Bereich, Scenario, Herkunft, Typ und Restlaufzeit, filterbar. Die
  Community-Blockliste wird nicht angezeigt (zehntausende Einträge). IP oder Bereich (CIDR) manuell bannen mit
  Dauer, Typ (ban/captcha) und Grund, Sperren einzeln entfernen.
- **Alerts:** die letzten Alerts mit Zeit, Quelle (Land, Provider), Scenario, angegriffenen Hosts und Pfaden (z. B.
  `/.env`) und Anzahl Events. Filter nach IP/Bereich oder Scenario; Entbannen direkt aus dem Alert.
- **Ausnahmen:** IP-Adressen und Bereiche (IPv4/IPv6, CIDR), für die Bouncer **und** AppSec nicht greifen: keine
  Sperren, kein Captcha, keine WAF-Prüfung. Gilt wahlweise **global** (alle Hosts, auch Weiterleitungs- und 404-Hosts)
  oder nur für **bestimmte Proxy-Hosts**. Typischer Fall: AppSec lehnt Request-Bodies über 10 MB ab, große
  Uploads (z. B. Pushes auf eine Git-Forge) landen dann auf der Sperrseite. Mit der eigenen festen IP als Ausnahme
  für diesen Host gehen sie durch, für alle anderen bleibt AppSec aktiv.
  - Oben steht die Adresse, mit der NPMplus dich gerade sieht, mit Knopf **„Meine IP hinzufügen“**. Läuft der
    Zugriff über das LAN oder einen weiteren Proxy, ist das nicht die öffentliche IP.
  - Eingaben werden geprüft und vereinheitlicht (`192.0.2.7/24` wird `192.0.2.0/24`). Bereiche größer als `/16`
    (IPv4) bzw. `/32` (IPv6) sind nicht erlaubt; früher gespeicherte größere Bereiche (bis `/8` bzw. `/16`) bleiben
    in der Liste, wirken aber nicht mehr und sind als „Bereich zu groß, unwirksam“ markiert. Maßgeblich ist die Client-Adresse nach Auswertung von Real-IP-Headern,
    also dieselbe, die der Bouncer prüft.
  - Technisch: NPMplus schreibt `conf.d/crowdsec-exceptions.conf` (nginx-`geo`-Blöcke) und prüft sie mit `nginx -t`;
    wird sie abgelehnt, bleiben alte Datei und alter Stand erhalten. Die Datei wird beim Start neu erzeugt. Gelöschte
    Proxy-Hosts fallen aus den Ausnahmen heraus.
  - Ausnahmen wirken direkt in nginx, auch pro Host und ohne laufendes CrowdSec. Eine CrowdSec-Allowlist (siehe
    unten) gilt dagegen in CrowdSec selbst für alle Hosts: keine Decisions, und AppSec überspringt die Adresse
    (geprüft mit CrowdSec 1.8.2; ältere Versionen prüften Requests von Allowlist-Adressen noch).
- **Allowlists:**
  - **NPMplus-Allowlist:** eine echte CrowdSec-Allowlist namens `npmplus`, gepflegt auf dieser Seite: IP oder Bereich
    (IPv4/IPv6, CIDR) mit optionaler Beschreibung und Gültigkeit (1 Stunde bis 1 Jahr oder unbegrenzt) hinzufügen,
    Einträge entfernen, die eigene Adresse mit **„Meine IP hinzufügen“** übernehmen. Adressen darauf bekommen keine
    Decisions (bestehende löscht CrowdSec beim Hinzufügen) und AppSec prüft ihre Requests nicht, auch nicht das
    Body-Limit. Eingaben werden geprüft und vereinheitlicht wie bei den Ausnahmen (höchstens `/16` bzw. `/32`,
    höchstens 500 Einträge). Übertragen werden sie vom [CrowdSec-Helfer](#crowdsec-helfer); die Spalte **Status**
    zeigt pro Eintrag „übernommen“, „ausstehend“ (Helfer läuft nicht oder hat die Änderung noch nicht verarbeitet),
    „Fehler“ (mit Meldung) oder „abgelaufen“. Ohne Helfer wird trotzdem gespeichert und später übernommen. Die
    Der Helfer entfernt aus der Allowlist `npmplus` nur Einträge, die er selbst angelegt hat; mit `cscli` von Hand
    ergänzte bleiben (auch wenn NPMplus noch keine Einträge hat). Steht eine Adresse schon von Hand darauf und wird
    sie in NPMplus hinzugefügt, übernimmt der Helfer sie.
  - **Alle Allowlists der Local API** mit Einträgen (IP/Bereich, Beschreibung, Ablauf), dazu **„IP prüfen“**, ob eine
    Adresse oder ein Bereich auf einer davon steht. Nur lesen, braucht den Machine-Login und eine CrowdSec-Version mit
    Allowlists. Weitere Allowlists anlegen und pflegen mit `cscli`, z. B.:

  ```bash
  docker exec crowdsec cscli allowlists create my_allowlist -d "my allowlist"
  docker exec crowdsec cscli allowlists add my_allowlist 192.0.2.10 -d "office"
  ```

- **Einstellungen:** bearbeitet `/data/crowdsec/crowdsec.conf` (Bouncer an/aus, Local-API-URL, Bouncer-Key, Modus,
  Antwort für gesperrte Clients, Captcha, AppSec). Unbekannte Zeilen und Kommentare bleiben erhalten. Speichern lädt
  nginx neu, ein Neustart ist nicht nötig; lehnt nginx die Konfiguration ab, bleibt der alte Stand.
  - **Ausgenommene Pfade** (`EXCLUDE_LOCATION`): kommagetrennt, jeder Pfad beginnt mit `/`, ohne Leerzeichen,
    Anführungszeichen oder Backslash; gilt für den Pfad und alles darunter, für Bouncer und AppSec.
  - **AppSec-Timeouts** für Verbindung, Senden und Verarbeitung in ms (1–60000, leer = Standard 100/100/500). Bei
    Zeitüberschreitung gilt „Wenn AppSec nicht erreichbar ist“.
  - **Requests mit nicht lesbarem Body ablehnen** (`APPSEC_DROP_UNREADABLE_BODY`): betrifft HTTP/2- und
    HTTP/3-Requests ohne Content-Length sowie gRPC. Aus (Standard) gehen sie ohne Body an AppSec.
  - **AppSec-Body-Limit** (eigener Abschnitt mit eigenem Speichern-Knopf, gilt für alle Hosts): bis zu welcher Größe
    (1–1024 MB) AppSec Request-Bodies (Uploads, Formulare) prüft und was mit größeren passiert:
    `partial` prüft nur den Anfang und behandelt den Request sonst normal, `drop` lehnt ihn ab, `allow` lässt ihn
    ohne Prüfung des Bodys durch (Header und URL werden weiter geprüft). CrowdSec selbst prüft nur 10 MB mit `drop`;
    zusammen mit „Wenn AppSec nicht erreichbar ist: deny“ landen größere Uploads dann auf der Sperrseite. Der
    Installer setzt **64 MB mit `partial`**. Angezeigt wird, was CrowdSec gerade verwendet und wann es neu geladen
    wurde. Hohe Limits brauchen RAM im crowdsec-Container (AppSec hält den Body bis zum Limit im Speicher).
- Bouncer-Key, Captcha-Secret und Machine-Passwort werden nur geschrieben, nie angezeigt, und in Logs maskiert.
- **Machine-Login:** Bannen, Entbannen und Alerts brauchen ihn, nur Anzeigen der Bans geht mit dem Bouncer-Key.
  NPMplus liest ihn aus `/opt/npmplus/crowdsec/lapi-credentials.yaml` (im Container `/data/crowdsec/`). Der
  Installer legt ihn an und legt ihn bei `install.sh --update` neu an, wenn CrowdSec das Passwort ablehnt. Von Hand
  (z. B. nach Installation per community-scripts) auf dem Host, das Passwort landet nur in der Datei:

  ```bash
  docker exec crowdsec cscli machines add npmplus-gui --auto --force -f - > /opt/npmplus/crowdsec/lapi-credentials.yaml
  chmod 600 /opt/npmplus/crowdsec/lapi-credentials.yaml
  ```

  Danach nichts in den Einstellungen eintragen, die Datei genügt. Das Passwortfeld dort überschreibt die Datei und ist
  nur nötig, wenn der Login woanders angelegt wurde. Jedes `machines add --force` erzeugt ein neues Passwort; die
  Datei muss danach neu geschrieben werden, sonst meldet die Seite „401 incorrect Username or Password“.
- **Pro Proxy-Host:** Schalter **„CrowdSec-Bouncer deaktivieren“**. Sperren und AppSec gelten dann für diesen Host
  nicht (z. B. für reine LAN-Dienste).
- Alle Änderungen stehen im Audit-Log.

### CrowdSec-Helfer

NPMplus kann CrowdSec nicht selbst ändern: die Local API kennt keine Schreibzugriffe auf Allowlists, und NPMplus
bekommt bewusst keinen Docker-Socket. Das übernimmt der Container **`crowdsec-helper`** (richtet der Installer mit
CrowdSec ein, `install.sh --update` ergänzt ihn bei vorhandenen Installationen):

- gleiches Image wie `crowdsec` (bringt `cscli` mit), `network_mode`/`pid` von `crowdsec` geteilt (Local API unter
  `127.0.0.1:8080`, Neuladen per SIGHUP), ohne Capabilities, ohne eigene Ports, Dateisystem schreibgeschützt
  (`/tmp` im Speicher), höchstens 64 Prozesse und 256 MB RAM. Die CrowdSec-Konfiguration ist schreibgeschützt
  eingebunden bis auf `appsec-configs` (dort liegt `npmplus-body-limit.yaml`); das Datenverzeichnis bleibt
  beschreibbar, weil `cscli allowlists` direkt in die SQLite-Datenbank schreibt.
- NPMplus speichert die Einstellungen in seiner Datenbank und schreibt daraus bei jeder Änderung und beim Start den
  Soll-Zustand nach `/data/crowdsec/helper/in` (`allowlist.desired`, `appsec.desired`; auf dem Host
  `/opt/crowdsec/helper/in`). Der Helfer bindet dieses Verzeichnis nur lesend ein; sein Ergebnis schreibt er nach
  `/opt/crowdsec/helper/out`, das NPMplus nur lesend sieht. So schreibt keine Seite in ein Verzeichnis, das die andere
  verändern kann.
- Der Helfer schaut alle 5 Sekunden nach, prüft jeden Wert erneut (Dateien mit mehr als 20 ungültigen Zeilen oder
  mehr als 503 Zeilen lehnt er ganz ab), gleicht die Allowlist `npmplus` mit `cscli allowlists` ab (fehlende
  hinzufügen, eigene nicht mehr gewünschte entfernen; andere Allowlists bleiben unberührt) und schreibt beim
  Body-Limit die appsec-config `npmplus/body-limit`. Die prüft er vorher unter anderem Namen mit `crowdsec -t`; erst
  wenn CrowdSec sie annimmt, stellt er sie bereit und lädt CrowdSec neu, sonst bleibt die alte. Änderungen setzt er
  höchstens einmal pro Minute um (schnelle Änderungen hintereinander werden gesammelt), zusätzlich gleicht er alle 5
  Minuten ab.
- Ergebnis und Lebenszeichen schreibt er nach `out/status.json`; meldet er sich 90 Sekunden nicht, zeigt die Seite
  „Helfer antwortet nicht“. Log: `docker logs crowdsec-helper`. Wird `crowdsec` mit `docker restart crowdsec` neu
  gestartet, endet auch der Helfer (gemeinsamer PID-Namensraum): danach `docker start crowdsec-helper`, oder gleich
  `docker compose -f /opt/npmplus-hotte/compose.yaml restart crowdsec` verwenden, das startet ihn mit.

## Log-Viewer

- Menü **Logs** (nur Admins): Quellen Zugriffslog, Fehlerlog, Stream-Log, Certbot-Log und NPMplus-Log.
- Filter nach Proxy-Host (Zugriffs- und Fehlerlog) und nach Text, Live-Aktualisierung.
- Aus der Host-Liste führt der Menüpunkt **Logs** direkt zum Zugriffslog des Hosts.

## Hotte-Logo

Petrol-farbenes „H“-Monogramm mit Schriftzug „Hotte“ hinter dem NPMplus-Logo im Header, Seitentitel
„NPMplus · Hotte“.
