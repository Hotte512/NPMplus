# Installation

Zwei Skripte im Ordner [`install/`](../install):

| Skript | Läuft auf | Macht |
| --- | --- | --- |
| `proxmox.sh` | Proxmox-VE-Host (root) | legt einen Debian-12-LXC an und ruft darin `install.sh` auf |
| `install.sh` | Debian 12/13, Ubuntu 22.04/24.04 (LXC oder VM, root) | installiert Docker und startet NPMplus · Hotte, optional mit UniFi API Guard und CrowdSec |

Die erzeugte `compose.yaml` entspricht [`deploy/compose.yaml`](../deploy/compose.yaml) – wer lieber von Hand
installiert, nimmt diese Datei und aktiviert die gewünschten optionalen Blöcke.

## Proxmox: neuer LXC in einem Schritt

Auf dem Proxmox-Host als root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install/proxmox.sh)"
```

Gefragt wird nach Container-ID (nächste freie), Hostname (`npmplus-hotte`), Storages, Größe (8 GB, 2 Kerne,
2048 MB RAM), Bridge (`vmbr0`), IPv4 (`dhcp` oder z. B. `192.168.1.20/24` mit Gateway) und den NPMplus-Optionen
(siehe unten). Danach läuft alles ohne Rückfragen: aktuelle Debian-12-Vorlage laden, unprivilegierten Container mit
`nesting=1,keyctl=1` (nötig für Docker) anlegen, starten, `install.sh` hineinkopieren und ausführen.

Der Container hat kein root-Passwort; Zugang über `pct enter <CTID>` (oder `CT_PASSWORD=…` beim Aufruf setzen).

## Vorhandener LXC oder VM

Im Container bzw. in der VM als root:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install/install.sh)"
```

Fragen (Dialog per `whiptail`, Vorgabe in Klammern):

| Variable | Bedeutung |
| --- | --- |
| `TZ` | Zeitzone der Container (Systemzeitzone) |
| `ACME_EMAIL` | E-Mail für Let's Encrypt/ZeroSSL (leer) |
| `UNIFI_GUARD` | UniFi API Guard mitinstallieren (`no`) |
| `CROWDSEC` | CrowdSec mitinstallieren, Bouncer in NPMplus automatisch einrichten (`no`) |
| `AUTO_UPDATE` | täglich um 04:47 Uhr Images aktualisieren und alte löschen (`yes`) |
| `INSTALL_DIR` | Ort der `compose.yaml` (`/opt/npmplus-hotte`) |

### Ohne Rückfragen

Jede Antwort lässt sich als Umgebungsvariable vorgeben, `NONINTERACTIVE=1` nimmt für den Rest die Vorgaben:

```bash
curl -fsSL https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install/install.sh -o install.sh
NONINTERACTIVE=1 TZ=Europe/Berlin ACME_EMAIL=admin@example.com UNIFI_GUARD=yes CROWDSEC=yes AUTO_UPDATE=yes \
  bash install.sh
```

Für `proxmox.sh` gilt dasselbe, zusätzlich `CTID`, `CT_HOSTNAME`, `TEMPLATE_STORAGE`, `ROOTFS_STORAGE`, `DISK_GB`,
`CORES`, `RAM_MB`, `SWAP_MB`, `BRIDGE`, `VLAN`, `IP`, `GATEWAY`, `UNPRIVILEGED`, `ONBOOT`.

`DRY_RUN=1 bash install.sh` zeigt nur die erzeugte `compose.yaml` und die geplanten Schritte, ohne etwas zu ändern.

## Was wo landet

| Pfad | Inhalt |
| --- | --- |
| `/opt/npmplus-hotte/compose.yaml` | Compose-Datei (Projektname `npmplus`) |
| `/opt/npmplus` | NPMplus-Daten (Datenbank, Zertifikate, Logs, `crowdsec/crowdsec.conf`) |
| `/opt/unifi-api-guard` | Guard-Konfiguration (gehört UID 65532, Rechte 0700) |
| `/opt/crowdsec/conf`, `/opt/crowdsec/data` | CrowdSec-Konfiguration (inkl. `acquis.d/npmplus.yaml`) und -Datenbank |
| `/etc/cron.d/npmplus-hotte` | tägliches Update (nur mit `AUTO_UPDATE=yes`) |

Docker kommt aus dem offiziellen Docker-Repository und wird nur installiert, wenn es fehlt.

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

## Erneut ausführen, Updates, Deinstallation

- **Erneut ausführen** ist gefahrlos, z. B. um CrowdSec oder den Guard nachträglich zu aktivieren. Eine geänderte
  `compose.yaml` wird vorher als `compose.yaml.bak-<Datum>` gesichert, Daten bleiben. Abgewählte Dienste werden
  gestoppt und entfernt, ihre Daten unter `/opt/…` bleiben.
- **Update von Hand:**
  `docker compose -f /opt/npmplus-hotte/compose.yaml pull && docker compose -f /opt/npmplus-hotte/compose.yaml up -d && docker image prune -f`
- **Deinstallation:** `docker compose -f /opt/npmplus-hotte/compose.yaml down`, `rm -f /etc/cron.d/npmplus-hotte`;
  wer auch die Daten löschen will: `rm -rf /opt/npmplus /opt/unifi-api-guard /opt/crowdsec /opt/npmplus-hotte`.
  Beim Proxmox-LXC reicht `pct stop <CTID> && pct destroy <CTID>`.

## Fehlersuche

| Problem | Ursache und Lösung |
| --- | --- |
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
