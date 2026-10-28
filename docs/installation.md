# Installation

Zwei Skripte im Ordner [`install/`](../install):

| Skript | Läuft auf | Macht |
| --- | --- | --- |
| `proxmox.sh` | Proxmox-VE-Host (root) | legt einen Alpine-LXC (Standard) oder Debian-12-LXC an und ruft darin `install.sh` auf |
| `install.sh` | Alpine 3.20+, Debian 12/13, Ubuntu 22.04/24.04 (LXC oder VM, root) | installiert Docker und startet NPMplus · Hotte, optional mit UniFi API Guard und CrowdSec; übernimmt auf Wunsch eine vorhandene Installation |

Die erzeugte `compose.yaml` entspricht [`deploy/compose.yaml`](../deploy/compose.yaml) – wer lieber von Hand
installiert, nimmt diese Datei und aktiviert die gewünschten optionalen Blöcke.

## Proxmox: neuer LXC in einem Schritt

Auf dem Proxmox-Host als root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install/proxmox.sh)"
```

Gefragt wird nach Container-ID (nächste freie), Hostname (`npmplus-hotte`), Betriebssystem (`CT_OS`: `alpine` oder
`debian`), Storages, Größe, Bridge (`vmbr0`), IPv4 (`dhcp` oder z. B. `192.168.1.20/24` mit Gateway) und den
NPMplus-Optionen (siehe unten). Danach läuft alles ohne Rückfragen: neueste Vorlage laden (Alpine 3.x „default“
ohne edge bzw. Debian 12 „standard“), unprivilegierten Container mit `nesting=1,keyctl=1` (nötig für Docker)
anlegen, starten, auf Netzwerk warten, bei Alpine `bash` und `curl` nachinstallieren, `install.sh` hineinkopieren
und ausführen.

| `CT_OS` | Vorgaben | Hinweis |
| --- | --- | --- |
| `alpine` (Standard) | 4 GB, 2 Kerne, 1024 MB RAM | klein, schnell, Docker aus den Alpine-Paketen |
| `debian` | 8 GB, 2 Kerne, 2048 MB RAM | Docker aus dem offiziellen Docker-Repository |

Mit CrowdSec eher 2048 MB RAM geben; alle Werte lassen sich im Dialog oder per Umgebungsvariable ändern.

Der Container hat kein root-Passwort; Zugang über `pct enter <CTID>` (oder `CT_PASSWORD=…` beim Aufruf setzen).

## Vorhandener LXC oder VM

Im Container bzw. in der VM als root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install/install.sh)"
```

**Alpine** bringt weder `bash` noch `curl` mit, dort vorher:

```bash
apk add bash curl
```

Das Skript installiert danach selbst, was es braucht: unter Alpine `docker` und `docker-cli-compose` aus dem
Repository „community“ (wird bei Bedarf in `/etc/apk/repositories` aktiviert), `jq`, `tzdata`, `newt` (für die
Dialoge) und richtet die Dienste per OpenRC ein; unter Debian/Ubuntu Docker aus dem offiziellen Docker-Repository.

Fragen (Dialog per `whiptail`, Vorgabe in Klammern):

| Variable | Bedeutung |
| --- | --- |
| `TZ` | Zeitzone der Container (Systemzeitzone) |
| `ACME_EMAIL` | E-Mail für Let's Encrypt/ZeroSSL (leer) |
| `UNIFI_GUARD` | UniFi API Guard mitinstallieren (`no`) |
| `CROWDSEC` | CrowdSec mitinstallieren, Bouncer in NPMplus automatisch einrichten (`no`) |
| `AUTO_UPDATE` | täglich um 04:47 Uhr Images aktualisieren und alte löschen (`yes`) |
| `AUTO_OS_UPDATE` | zusätzlich täglich das Betriebssystem aktualisieren, `apk -U upgrade` bzw. `apt-get upgrade` (`no`) |
| `INSTALL_DIR` | Ort der `compose.yaml` (`/opt/npmplus-hotte`) |
| `TAKEOVER` | nur wenn eine andere Installation gefunden wird: übernehmen (`no` = Abbruch ohne Änderung) |
| `OLD_COMPOSE` | optional: Pfad einer fremden `compose.yaml`, die übernommen werden soll (sonst automatische Suche) |
| `IMPORT_FROM` | optional: weitere Dienste aus einer anderen compose-Datei in die vorhandene Installation holen (siehe unten) |

### Ohne Rückfragen

Jede Antwort lässt sich als Umgebungsvariable vorgeben, `NONINTERACTIVE=1` nimmt für den Rest die Vorgaben:

```bash
curl -fsSL https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install/install.sh -o install.sh
NONINTERACTIVE=1 TZ=Europe/Berlin ACME_EMAIL=admin@example.com UNIFI_GUARD=yes CROWDSEC=yes AUTO_UPDATE=yes \
  bash install.sh
```

Für `proxmox.sh` gilt dasselbe, zusätzlich `CT_OS`, `CTID`, `CT_HOSTNAME`, `TEMPLATE_STORAGE`, `ROOTFS_STORAGE`,
`DISK_GB`, `CORES`, `RAM_MB`, `SWAP_MB`, `BRIDGE`, `VLAN`, `IP`, `GATEWAY`, `UNPRIVILEGED`, `ONBOOT`.

`DRY_RUN=1 bash install.sh` zeigt nur die erzeugte `compose.yaml` und die geplanten Schritte, ohne etwas zu ändern
(auch die einer Übernahme). Werte übernommener Variablen erscheinen dabei als `***` (`SHOW_VALUES=1` zeigt sie).
Einzige Ausnahme vom „nichts ändern“: Wird eine vorhandene `compose.yaml` gelesen und fehlt `jq`, installiert auch
der Probelauf `jq` (nur zum Lesen).

## Vorhandene Installation übernehmen (z. B. community-scripts)

Wurde NPMplus mit dem Proxmox-Skript von community-scripts installiert (Alpine-LXC, `/opt/compose.yaml`, Daten in
`/opt/npmplus`), lässt sich der Container direkt umstellen – Proxy-Hosts, Zertifikate und Benutzer bleiben, weil
dieselben Daten weiterverwendet werden.

1. **Snapshot anlegen**, auf dem Proxmox-Host: `pct snapshot <CTID> vor-hotte`. Die community-scripts-LXC sind
   klein (3 GB, 512 MB RAM); das neue Image kommt zunächst zum alten dazu. Bei weniger als 1,5 GB frei warnt der
   Installer – dann vorher `pct resize <CTID> rootfs +2G` (mit CrowdSec auch mehr RAM, `pct set <CTID> --memory 2048`).
2. Im Container: `apk add bash curl`, dann den Installer wie oben starten. Ältere Container mit Alpine vor 3.20
   vorher aktualisieren (Version in `/etc/apk/repositories` anheben, `apk update && apk upgrade --available`).
3. Der Installer erkennt die alte Installation (Container `npmplus` aus einer anderen `compose.yaml`, sonst
   `/opt/compose.yaml` oder `/opt/npmplus/compose.yaml`) und zeigt, was er übernimmt:
   - alle Umgebungsvariablen des NPMplus-Dienstes (z. B. `TRUST_IP`, `NPM_PORT`) – angezeigt werden nur die
     Namen, nicht die Werte. `TZ` und `ACME_EMAIL` werden als Vorgabe für die Fragen genommen, `LOGROTATE`
     bleibt erhalten;
   - zusätzliche Bind-Mounts (z. B. `/var/www`), `dns:` und zusätzliche Capabilities;
   - einen vorhandenen Dienst `unifi-api-guard` (Vorgabe „Guard installieren“ = ja, Datenpfad bleibt) bzw.
     `crowdsec` (Vorgabe ja);
   - **alle weiteren Dienste** der alten Datei unverändert, z. B. `geoipupdate` (für `GOA=true`), samt der von
     ihnen benutzten benannten Volumes und Netze. Angezeigt werden nur die Dienstnamen. Ein Dienst, dessen Name
     oder `container_name` mit einem Dienst des Installers kollidiert, wird mit Warnung ausgelassen.
   - **nicht** übernommen: `INITIAL_ADMIN_EMAIL`/`INITIAL_ADMIN_PASSWORD` (nur für den ersten Start, bei
     community-scripts mit einem öffentlich bekannten Standardpasswort – falls das Admin-Konto noch dieses
     Passwort hat, in NPMplus ändern).

   Vor jeder Änderung prüft der Installer die neue `compose.yaml` mit `docker compose config` und lädt die neuen
   Images; schlägt das fehl, bleibt die alte Installation unverändert.
4. Nach dem „Ja“ (ohne Rückfragen: `TAKEOVER=yes`): neue Images laden, alte Datei in
   `compose.yaml.disabled-by-npmplus-hotte-<Zeit>` umbenennen, `docker compose … down` für das alte Projekt
   (ohne `-v`, die Daten liegen ohnehin in `/opt/…`), alte Update-Cronjobs entfernen, die die alte Datei aufrufen
   (Sicherung der Crontab unter `/root/npmplus-hotte-backup-<Zeit>/`), dann NPMplus · Hotte mit
   `/opt/npmplus-hotte/compose.yaml` starten. Projekt- und Containernamen bleiben `npmplus`.
5. Kontrolle: `https://<IP>:81`, Login wie bisher; `docker ps` zeigt `ghcr.io/hotte512/npmplus:hotte-main`.
   Das alte NPMplus-Image wird danach gelöscht (der Rückweg lädt es bei Bedarf neu).

Speichert die alte Installation ihre Daten nicht unter `/opt/npmplus`, bricht der Installer ab, ohne etwas zu
ändern. Ohne Terminal und ohne `TAKEOVER=yes` ebenfalls.

**Zurück zur alten Installation:**

```bash
docker compose -f /opt/npmplus-hotte/compose.yaml down
mv /opt/compose.yaml.disabled-by-npmplus-hotte-<Zeit> /opt/compose.yaml
docker compose -f /opt/compose.yaml up -d
```

Entfernte Cronjobs aus `/root/npmplus-hotte-backup-<Zeit>/` zurückkopieren – oder einfach auf dem Proxmox-Host
`pct rollback <CTID> vor-hotte`. Die genauen Befehle zeigt auch die Zusammenfassung am Ende.

## Was wo landet

| Pfad | Inhalt |
| --- | --- |
| `/opt/npmplus-hotte/compose.yaml` | Compose-Datei (Projektname `npmplus`) |
| `/opt/npmplus` | NPMplus-Daten (Datenbank, Zertifikate, Logs, `crowdsec/crowdsec.conf`) |
| `/opt/unifi-api-guard` | Guard-Konfiguration (gehört UID 65532, Rechte 0700) |
| `/opt/crowdsec/conf`, `/opt/crowdsec/data` | CrowdSec-Konfiguration (inkl. `acquis.d/npmplus.yaml`) und -Datenbank |
| `/etc/cron.d/npmplus-hotte` | Debian/Ubuntu: tägliches Update (nur mit `AUTO_UPDATE=yes`) |
| `/etc/crontabs/root` | Alpine: tägliches Update als Block zwischen `# >>> npmplus-hotte` und `# <<< npmplus-hotte` (busybox `crond` liest `/etc/cron.d` nicht) |

Docker kommt unter Debian/Ubuntu aus dem offiziellen Docker-Repository, unter Alpine aus den Alpine-Paketen, und
wird nur installiert, wenn es fehlt.

## Nach der Installation

- **NPMplus:** `https://<IP>:81` (selbstsigniertes Zertifikat). Beim ersten Aufruf legt ein Assistent das
  Admin-Konto an; ein Startpasswort gibt es nicht. Startmeldungen: `docker logs npmplus`.
- **UniFi API Guard:** Das Skript zeigt am Ende das einmalige Einrichtungs-Token (später: `cat /opt/unifi-api-guard/setup-token`, bis die Einrichtung abgeschlossen ist).
  1. `http://<IP>:8091` öffnen, Token eingeben, Admin-Passwort festlegen.
  2. UniFi-Gateway eintragen (z. B. `https://192.168.1.1` und UniFi-API-Key), Fingerprint prüfen, Verbindung testen.
  3. Key anlegen: Vorlage **„Lokale DNS-Einträge“**, Domains z. B. `*.example.com`, erlaubte IP **`127.0.0.1`**.
  4. In NPMplus › *Einstellungen › UniFi Local DNS*: Gateway-URL `http://127.0.0.1:8090`, API-Key = Guard-Key.
- **CrowdSec:** Acquis-Datei, `LOGROTATE=true` und Bouncer (`cscli bouncers add npmplus`, Key landet ohne Ausgabe in
  `/opt/npmplus/crowdsec/crowdsec.conf`) richtet das Skript ein. Kontrolle: `docker exec crowdsec cscli metrics`.
  Tipp: Zugriffe aus dem eigenen LAN stehen dort unter „Lines whitelisted“ – CrowdSec ignoriert private Adressen
  standardmäßig, gewertet werden nur Zugriffe von außen. `cscli bouncers list` zeigt den Bouncer `npmplus` mit der
  Docker-Bridge-IP (z. B. `172.17.0.1`), das ist richtig.
  Weitere Collections, AppSec-CRS und Bot-Erkennung: NPMplus-README, Abschnitt „Crowdsec“.

### Weitere Dienste nachträglich holen (`IMPORT_FROM`)

Ältere Versionen des Installers haben bei der Übernahme weitere Dienste der alten Datei (z. B. `geoipupdate`)
gestoppt, aber nicht übernommen. Die alte Datei liegt noch als `*.disabled-by-npmplus-hotte-<Zeit>` daneben; daraus
lassen sich die Dienste in die vorhandene Installation holen (NPMplus, Guard und CrowdSec der alten Datei werden
dabei ignoriert, schon vorhandene Dienste bleiben, wie sie sind):

```bash
ls /opt/compose.yaml.disabled-by-npmplus-hotte-*
# erst ansehen (Werte als ***), dann ausführen:
DRY_RUN=1 IMPORT_FROM=/opt/compose.yaml.disabled-by-npmplus-hotte-<Zeit> \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install/install.sh)"
IMPORT_FROM=/opt/compose.yaml.disabled-by-npmplus-hotte-<Zeit> \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install/install.sh)"
```

Danach läuft der normale Ablauf: Fragen mit den bisherigen Antworten als Vorgabe, `compose.yaml` neu schreiben
(alte Fassung als `.bak-<Zeit>`), Container starten. Die Zusammenfassung nennt die importierten Dienste.

## Erneut ausführen, Updates, Deinstallation

- **Erneut ausführen** ist gefahrlos, z. B. um CrowdSec oder den Guard nachträglich zu aktivieren. Die bisherige
  `compose.yaml` liefert die Vorgaben (Zeitzone, ACME-E-Mail, Guard, CrowdSec); zusätzliche Einträge des
  NPMplus-Dienstes – übernommen oder von Hand ergänzt: Umgebungsvariablen, Bind-Mounts, `dns:`, `cap_add` – bleiben
  erhalten, ebenso weitere Dienste (z. B. `geoipupdate`) samt ihrer Volumes und Netze. Eine geänderte
  `compose.yaml` wird vorher als `compose.yaml.bak-<Datum>` gesichert, Daten bleiben. Abgewählte Dienste werden gestoppt und entfernt, ihre
  Daten unter `/opt/…` bleiben.
- **Automatische Updates** (`AUTO_UPDATE=yes`) aktualisieren nur die **Container** (neue Images, Neustart, alte
  Images löschen). Das Betriebssystem bleibt unverändert, außer mit `AUTO_OS_UPDATE=yes`: dann läuft vorher
  `apk -U upgrade` bzw. `apt-get upgrade` (ohne Neustart; ein neuer Kernel bzw. Docker-Dienst wirkt erst nach
  einem Neustart des Containers).
- **Update von Hand** (Betriebssystem und Container):

  ```bash
  bash install.sh --update
  # oder ohne heruntergeladene Datei:
  MODE=update bash -c "$(curl -fsSL https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install/install.sh)"
  ```

  Nur die Container:
  `docker compose -f /opt/npmplus-hotte/compose.yaml pull && docker compose -f /opt/npmplus-hotte/compose.yaml up -d && docker image prune -f`
- **Deinstallation:** `docker compose -f /opt/npmplus-hotte/compose.yaml down`, `rm -f /etc/cron.d/npmplus-hotte`
  (Alpine: den Block `# >>> npmplus-hotte` … `# <<< npmplus-hotte` aus `/etc/crontabs/root` löschen);
  wer auch die Daten löschen will: `rm -rf /opt/npmplus /opt/unifi-api-guard /opt/crowdsec /opt/npmplus-hotte`.
  Beim Proxmox-LXC reicht `pct stop <CTID> && pct destroy <CTID>`.

## Fehlersuche

| Problem | Ursache und Lösung |
| --- | --- |
| Alpine: `bash: not found` bzw. `curl: not found` | Vorher `apk add bash curl` ausführen. |
| „Vorhandene Installation gefunden“ ohne Terminal | Nach Prüfung mit `TAKEOVER=yes` erneut starten (siehe „Vorhandene Installation übernehmen“). |
| `install.sh` meldet „Das ist ein Proxmox-VE-Host“ | `install.sh` gehört in den LXC/die VM. Auf dem Host `proxmox.sh` verwenden. |
| `install.sh` versehentlich auf dem Proxmox-Host ausgeführt (ältere Version ohne Sperre) | Container mit `docker compose -f /opt/npmplus-hotte/compose.yaml down` stoppen, `/etc/cron.d/npmplus-hotte` und die Ordner unter `/opt/` löschen, Docker-Pakete entfernen (`apt-get purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`) und **den Host neu starten**. Docker hinterlässt sonst Firewall-Regeln, die das Netz neuer VMs und LXCs blockieren (z. B. bekommt ein neuer LXC per DHCP keine IP). |
| `proxmox.sh`: „hat keine IP“ | DHCP auf der Bridge bzw. im VLAN prüfen (VLAN-Tag angeben?) oder eine feste IP wählen. Siehe auch die Zeile darüber. |
| `proxmox.sh`: „IP, aber DNS geht nicht“ | Nameserver in `/etc/resolv.conf` des Containers prüfen (`pct exec <CTID> -- cat /etc/resolv.conf`). |
| Installer wartet lange | Der erste Start von NPMplus dauert etwas; das Skript zeigt alle 15 s den Fortschritt. Nach Zeitüberschreitung: `docker logs npmplus` bzw. `docker logs crowdsec`, dann das Skript erneut ausführen. |

## Sicherheit

- **Port 81** (NPMplus-Oberfläche) und **Port 8091** (Guard-Admin) nur aus dem LAN bzw. Admin-Netz erreichbar
  machen, nie per Portweiterleitung ins Internet. Ins Internet gehören nur 80 und 443.
- Der Guard-Proxy lauscht nur auf `127.0.0.1:8090`; andere Geräte im LAN erreichen ihn nicht. Soll er auch für
  andere Anwendungen (z. B. Home Assistant) da sein, `GUARD_PROXY_ADDR` anpassen und pro Key die erlaubten IPs setzen.
- CrowdSec-LAPI und -AppSec sind nur lokal (`127.0.0.1:8080`, `127.0.0.1:7422`) veröffentlicht. Werden Signale an die
  CrowdSec-Zentrale geteilt, gehört das in die Datenschutzerklärung.
- Die Skripte geben keine Schlüssel aus – einzige Ausnahme ist das Einrichtungs-Token des Guards, das nur das erste
  Admin-Passwort setzen kann.
- Docker in einem unprivilegierten LXC braucht `nesting=1,keyctl=1`. Proxmox VE aktuell halten: ältere
  LXC-/AppArmor-Stände vertragen sich nicht immer mit neuen runc-Versionen von Docker. Wer Docker strikt isolieren
  will, nimmt eine VM.
