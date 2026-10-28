#!/usr/bin/env bash
# NPMplus · Hotte – Installer für Debian 12/13 und Ubuntu 22.04/24.04 (LXC oder VM), als root ausführen.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install/install.sh)"
#
# Alle Fragen lassen sich per Umgebungsvariable beantworten (NONINTERACTIVE=1 fragt gar nicht):
#   TZ=Europe/Berlin ACME_EMAIL= UNIFI_GUARD=yes|no CROWDSEC=yes|no AUTO_UPDATE=yes|no INSTALL_DIR=/opt/npmplus-hotte
# DRY_RUN=1 zeigt nur die erzeugte compose.yaml und die geplanten Schritte, ohne etwas zu verändern.
#
# Erneutes Ausführen ist gefahrlos: vorhandene Daten bleiben, eine geänderte compose.yaml wird vorher gesichert.

# Deutsche Anführungszeichen („…“) in Texten sind gewollt:
# shellcheck disable=SC1111

set -Eeuo pipefail

# LXC-Templates setzen oft LANG=en_US.UTF-8 ohne erzeugte Locale, apt/perl warnen dann bei jedem Aufruf.
# C.UTF-8 ist immer vorhanden.
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset LANGUAGE

# ---------------------------------------------------------------------------------------------------------------
# Feste Werte
# ---------------------------------------------------------------------------------------------------------------
readonly NPMPLUS_IMAGE="ghcr.io/hotte512/npmplus:hotte-main"
readonly GUARD_IMAGE="ghcr.io/hotte512/unifi-api-guard:latest"
readonly CROWDSEC_IMAGE="docker.io/crowdsecurity/crowdsec:latest"
readonly NPMPLUS_DATA="/opt/npmplus"
readonly GUARD_DATA="/opt/unifi-api-guard"
readonly CROWDSEC_DATA="/opt/crowdsec"
readonly GUARD_UID=65532
readonly GUARD_PROXY_PORT=8090
readonly GUARD_ADMIN_PORT=8091
readonly CRON_FILE="/etc/cron.d/npmplus-hotte"
readonly CRON_TIME="47 4" # Minute Stunde: täglich 04:47 Uhr (Systemzeit des Containers)
readonly CRON_TIME_TEXT="04:47"
readonly TITLE="NPMplus · Hotte"

DRY_RUN="${DRY_RUN:-0}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

# ---------------------------------------------------------------------------------------------------------------
# Ausgabe
# ---------------------------------------------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_OK=$'\e[32m' C_WARN=$'\e[33m' C_ERR=$'\e[31m' C_BOLD=$'\e[1m' C_OFF=$'\e[0m'
else
    C_OK="" C_WARN="" C_ERR="" C_BOLD="" C_OFF=""
fi
info() { printf '%s==>%s %s\n' "$C_BOLD" "$C_OFF" "$*"; }
ok() { printf '%s ✓%s  %s\n' "$C_OK" "$C_OFF" "$*"; }
warn() { printf '%s !%s  %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die() {
    printf '%sFehler:%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2
    exit 1
}
trap 'die "Abbruch in Zeile $LINENO (Befehl: $BASH_COMMAND)"' ERR

# Führt einen Befehl aus oder zeigt ihn bei DRY_RUN=1 nur an.
run() {
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '   [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

# ---------------------------------------------------------------------------------------------------------------
# Fragen (whiptail, sonst read, bei NONINTERACTIVE=1 gar nicht)
# ---------------------------------------------------------------------------------------------------------------
UI=none
if [[ "$NONINTERACTIVE" != 1 ]] && [[ -r /dev/tty ]] && { : < /dev/tty; } 2> /dev/null; then
    if command -v whiptail > /dev/null 2>&1; then
        UI=whiptail
    else
        UI="read"
    fi
fi

# ask_text VAR "Frage" "Vorgabe"
ask_text() {
    local var=$1 question=$2 default=$3 answer
    if [[ -n "${!var+x}" || "$UI" == none ]]; then
        printf -v "$var" '%s' "${!var-$default}"
        return
    fi
    if [[ "$UI" == whiptail ]]; then
        answer=$(whiptail --title "$TITLE" --inputbox "$question" 12 74 "$default" 3>&1 1>&2 2>&3 < /dev/tty) ||
            die "Abgebrochen."
    else
        read -r -p "$question [$default]: " answer < /dev/tty || die "Abgebrochen."
        answer=${answer:-$default}
    fi
    printf -v "$var" '%s' "$answer"
}

# ask_yesno VAR "Frage" yes|no
ask_yesno() {
    local var=$1 question=$2 default=$3 answer
    if [[ -z "${!var+x}" && "$UI" != none ]]; then
        if [[ "$UI" == whiptail ]]; then
            local flag=()
            [[ "$default" == no ]] && flag=(--defaultno)
            if whiptail --title "$TITLE" "${flag[@]}" --yesno "$question" 14 74 < /dev/tty; then
                answer=yes
            else
                answer=no
            fi
        else
            read -r -p "$question (yes/no) [$default]: " answer < /dev/tty || die "Abgebrochen."
            answer=${answer:-$default}
        fi
        printf -v "$var" '%s' "$answer"
    fi
    case "${!var:-$default}" in
        y | Y | yes | YES | Yes | j | J | ja | Ja | 1 | true) printf -v "$var" yes ;;
        n | N | no | NO | No | nein | Nein | 0 | false) printf -v "$var" no ;;
        *) die "$var: ungültiger Wert '${!var}' (yes oder no erwartet)" ;;
    esac
}

system_tz() {
    local tz=""
    if [[ -r /etc/timezone ]]; then
        tz=$(head -n1 /etc/timezone)
    fi
    if [[ -z "$tz" && -L /etc/localtime ]]; then
        tz=$(readlink /etc/localtime)
        tz=${tz#*zoneinfo/}
    fi
    printf '%s' "${tz:-Etc/UTC}"
}

collect_options() {
    ask_text TZ "Zeitzone für die Container (TZ-Bezeichner, z. B. Europe/Berlin):" "$(system_tz)"
    ask_text ACME_EMAIL "E-Mail-Adresse für ACME/Let's Encrypt (optional, leer lassen möglich):" ""
    ask_yesno UNIFI_GUARD "UniFi API Guard mitinstallieren?

Rechte-Proxy für die UniFi-API: NPMplus bekommt einen eigenen Key, der nur DNS-Einträge ändern darf. Der Proxy lauscht nur lokal (127.0.0.1:${GUARD_PROXY_PORT}), die Admin-Oberfläche auf Port ${GUARD_ADMIN_PORT}." no
    ask_yesno CROWDSEC "CrowdSec mitinstallieren?

Erkennt Angriffe in den NPMplus-Logs und sperrt IPs (Bouncer in NPMplus wird automatisch eingerichtet). Aktiviert LOGROTATE." no
    ask_yesno AUTO_UPDATE "Automatische Updates einrichten?

Täglich um ${CRON_TIME_TEXT} Uhr neue Images holen, Container neu starten und alte Images löschen." yes
    ask_text INSTALL_DIR "Verzeichnis für die compose.yaml (Daten bleiben unter /opt/npmplus usw.):" "/opt/npmplus-hotte"

    [[ "$TZ" =~ ^[A-Za-z0-9_+/-]+$ ]] || die "TZ '$TZ' ist ungültig."
    if [[ -d /usr/share/zoneinfo && ! -e "/usr/share/zoneinfo/$TZ" ]]; then
        die "Zeitzone '$TZ' unbekannt (siehe /usr/share/zoneinfo)."
    fi
    if [[ -n "$ACME_EMAIL" && ! "$ACME_EMAIL" =~ ^[^[:space:]@\"]+@[^[:space:]@\"]+\.[^[:space:]@\"]+$ ]]; then
        die "ACME_EMAIL '$ACME_EMAIL' ist keine gültige E-Mail-Adresse."
    fi
    [[ "$INSTALL_DIR" == /* && "$INSTALL_DIR" != *[[:space:]]* ]] ||
        die "INSTALL_DIR muss ein absoluter Pfad ohne Leerzeichen sein."
    INSTALL_DIR=${INSTALL_DIR%/}
    COMPOSE_FILE="$INSTALL_DIR/compose.yaml"
}

# ---------------------------------------------------------------------------------------------------------------
# compose.yaml erzeugen (gleicher Aufbau wie deploy/compose.yaml)
# ---------------------------------------------------------------------------------------------------------------
generate_compose() {
    cat << EOF
# NPMplus · Hotte – erzeugt von install/install.sh (bei erneutem Lauf überschrieben, alte Fassung als .bak-<Zeit>)
# Optionen: UNIFI_GUARD=$UNIFI_GUARD CROWDSEC=$CROWDSEC
# Vorlage mit allen Kommentaren: https://github.com/Hotte512/NPMplus/blob/claude/hotte-ci/deploy/compose.yaml
name: npmplus
services:
  npmplus:
    container_name: npmplus
    restart: unless-stopped
    image: $NPMPLUS_IMAGE
    pull_policy: always
    network_mode: host
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - SETGID
    security_opt:
      - no-new-privileges:true
    volumes:
      - "$NPMPLUS_DATA:/data"
    environment:
      - "TZ=$TZ"
EOF
    if [[ -n "$ACME_EMAIL" ]]; then
        printf '      - "ACME_EMAIL=%s"\n' "$ACME_EMAIL"
    fi
    if [[ "$CROWDSEC" == yes ]]; then
        printf '      - "LOGROTATE=true" # access.log für CrowdSec\n'
    fi

    if [[ "$UNIFI_GUARD" == yes ]]; then
        cat << EOF

  # UniFi API Guard: Proxy nur lokal für NPMplus, Admin-Oberfläche nur aus dem LAN
  unifi-api-guard:
    container_name: unifi-api-guard
    restart: unless-stopped
    image: $GUARD_IMAGE
    pull_policy: always
    network_mode: host
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    volumes:
      - "$GUARD_DATA:/data"
    environment:
      - "TZ=$TZ"
      - "GUARD_PROXY_ADDR=127.0.0.1:$GUARD_PROXY_PORT"
      - "GUARD_ADMIN_ADDR=:$GUARD_ADMIN_PORT"
      - "GUARD_ADMIN_ALLOW=127.0.0.0/8,::1/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,fc00::/7"
EOF
    fi

    if [[ "$CROWDSEC" == yes ]]; then
        cat << EOF

  # CrowdSec nach der NPMplus-Anleitung, LAPI/AppSec nur lokal
  crowdsec:
    container_name: crowdsec
    restart: unless-stopped
    image: $CROWDSEC_IMAGE
    pull_policy: always
    network_mode: bridge
    security_opt:
      - no-new-privileges:true
    ports:
      - "127.0.0.1:7422:7422"
      - "127.0.0.1:8080:8080"
    environment:
      - "TZ=$TZ"
      - "USE_WAL=true"
      - "COLLECTIONS=ZoeyVid/npmplus"
    volumes:
      - "$CROWDSEC_DATA/conf:/etc/crowdsec"
      - "$CROWDSEC_DATA/data:/var/lib/crowdsec/data"
      - "$NPMPLUS_DATA/nginx/logs:$NPMPLUS_DATA/nginx/logs:ro"
EOF
    fi
}

crowdsec_acquis() {
    cat << 'EOF'
# NPMplus-Logs und AppSec, siehe NPMplus README › Crowdsec
filenames:
  - /opt/npmplus/nginx/logs/access.log
labels:
  type: npmplus
---
listen_addr: 0.0.0.0:7422
appsec_configs:
  - crowdsecurity/appsec-default
#  - crowdsecurity/crs # nur mit Collection crowdsecurity/appsec-crs
name: appsec
source: appsec
labels:
  type: appsec
EOF
}

# ---------------------------------------------------------------------------------------------------------------
# System
# ---------------------------------------------------------------------------------------------------------------
check_system() {
    # Docker auf dem Proxmox-Host verändert iptables (FORWARD DROP) und stört die Netze der VMs/LXCs
    if [[ -d /etc/pve || -x /usr/bin/pveversion ]] && [[ "${ALLOW_PVE_HOST:-0}" != 1 && "$DRY_RUN" != 1 ]]; then
        die "Das ist ein Proxmox-VE-Host. install.sh gehört in einen LXC oder eine VM.
    Auf dem Host stattdessen ausführen (legt den LXC an):
    bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install/proxmox.sh)\""
    fi
    [[ -r /etc/os-release ]] || die "/etc/os-release fehlt, unbekanntes System."
    # shellcheck source=/dev/null
    . /etc/os-release
    OS_ID=${ID:-unknown}
    OS_CODENAME=${VERSION_CODENAME:-}
    case "$OS_ID:${VERSION_ID:-}" in
        debian:12 | debian:13 | ubuntu:22.04 | ubuntu:24.04) ;;
        *)
            if [[ "${FORCE:-0}" == 1 || "$DRY_RUN" == 1 ]]; then
                warn "Nicht getestetes System: ${PRETTY_NAME:-$OS_ID}."
            else
                die "Unterstützt: Debian 12/13, Ubuntu 22.04/24.04 (gefunden: ${PRETTY_NAME:-$OS_ID}). FORCE=1 versucht es trotzdem."
            fi
            ;;
    esac
    if [[ "$DRY_RUN" != 1 && $EUID -ne 0 ]]; then
        die "Bitte als root ausführen."
    fi
}

apt_install() {
    local missing=() pkg
    for pkg in "$@"; do
        dpkg-query -W -f='${Status}' "$pkg" 2> /dev/null | grep -q 'install ok installed' || missing+=("$pkg")
    done
    ((${#missing[@]})) || return 0
    info "Installiere Pakete: ${missing[*]}"
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '   [dry-run] apt-get install -y %s\n' "${missing[*]}"
        return 0
    fi
    if [[ -z "${APT_UPDATED:-}" ]]; then
        apt-get update -qq
        APT_UPDATED=1
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}" > /dev/null
}

install_docker() {
    if command -v docker > /dev/null 2>&1 && docker compose version > /dev/null 2>&1; then
        ok "Docker und Compose-Plugin vorhanden ($(docker --version | cut -d, -f1))."
        return
    fi
    info "Richte das offizielle Docker-Repository ein"
    apt_install ca-certificates curl
    local arch
    arch=$(dpkg --print-architecture)
    run install -m 0755 -d /etc/apt/keyrings
    run curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" -o /etc/apt/keyrings/docker.asc
    run chmod a+r /etc/apt/keyrings/docker.asc
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '   [dry-run] /etc/apt/sources.list.d/docker.list -> https://download.docker.com/linux/%s %s stable\n' \
            "$OS_ID" "$OS_CODENAME"
    else
        printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
            "$arch" "$OS_ID" "$OS_CODENAME" > /etc/apt/sources.list.d/docker.list
    fi
    APT_UPDATED=""
    if command -v docker > /dev/null 2>&1; then
        # Docker ist da (z. B. aus den Distributionspaketen), es fehlt nur das Compose-Plugin.
        apt_install docker-compose-plugin
    else
        apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    run systemctl enable --now docker
    if [[ "$DRY_RUN" != 1 ]]; then
        docker compose version > /dev/null 2>&1 || die "docker compose funktioniert nach der Installation nicht."
    fi
    if [[ "$DRY_RUN" == 1 ]]; then ok "Docker-Installation geplant."; else ok "Docker installiert."; fi
}

# Schreibt Inhalt (stdin) nach Datei; ist die Datei vorhanden und anders, wird sie vorher gesichert.
# Rückgabe 0 = geändert, 1 = unverändert.
write_file_with_backup() {
    local file=$1 tmp
    tmp=$(mktemp)
    cat > "$tmp"
    if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        return 1
    fi
    if [[ -f "$file" ]]; then
        local backup
        backup="$file.bak-$(date +%Y%m%d-%H%M%S)"
        cp -a "$file" "$backup"
        warn "Vorhandene $(basename "$file") gesichert: $backup"
    fi
    install -m 0644 "$tmp" "$file"
    rm -f "$tmp"
    return 0
}

compose() { docker compose -f "$COMPOSE_FILE" --project-directory "$INSTALL_DIR" "$@"; }

# Wartet bis Befehl erfolgreich ist: wait_for Sekunden "Beschreibung" befehl...
# Meldet sich alle 15 s, damit niemand einen Hänger vermutet.
wait_for() {
    local timeout=$1 what=$2 i
    shift 2
    if "$@" > /dev/null 2>&1; then
        return 0
    fi
    info "Warte auf $what (bis zu ${timeout} s) …"
    for ((i = 3; i <= timeout; i += 3)); do
        sleep 3
        if "$@" > /dev/null 2>&1; then
            ok "$what bereit nach ${i} s."
            return 0
        fi
        ((i % 15 == 0)) && printf '    … %s s\n' "$i"
    done
    warn "Zeitüberschreitung beim Warten auf: $what"
    return 1
}

host_ip() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2> /dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}')
    [[ -n "$ip" ]] || ip=$(hostname -I 2> /dev/null | awk '{print $1}')
    printf '%s' "${ip:-<IP-dieses-Hosts>}"
}

# Entfernt Container abgewählter Optionen (nur die von diesem Compose-Projekt, Daten bleiben).
# Bewusst kein --remove-orphans: das würde auch fremde Dienste im Projekt „npmplus“ löschen.
remove_disabled() {
    local opt var name
    for opt in UNIFI_GUARD:unifi-api-guard CROWDSEC:crowdsec; do
        var=${opt%%:*} name=${opt#*:}
        [[ "${!var}" == no ]] || continue
        if [[ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$name" 2> /dev/null)" == npmplus ]]; then
            docker rm -f "$name" > /dev/null
            ok "Abgewählt, Container entfernt: $name (Daten bleiben erhalten)"
        fi
    done
}

# ---------------------------------------------------------------------------------------------------------------
# CrowdSec
# ---------------------------------------------------------------------------------------------------------------
prepare_crowdsec() {
    info "Bereite CrowdSec vor ($CROWDSEC_DATA)"
    run mkdir -p "$CROWDSEC_DATA/conf/acquis.d" "$CROWDSEC_DATA/data" "$NPMPLUS_DATA/nginx/logs"
    local acquis="$CROWDSEC_DATA/conf/acquis.d/npmplus.yaml"
    ACQUIS_CHANGED=0
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '   [dry-run] %s anlegen, falls nicht vorhanden\n' "$acquis"
    elif [[ -f "$acquis" ]]; then
        ok "Acquis-Datei vorhanden, bleibt unverändert: $acquis"
    else
        crowdsec_acquis > "$acquis"
        ACQUIS_CHANGED=1
        ok "Acquis-Datei angelegt: $acquis"
    fi
}

cs_lapi_ready() { docker exec crowdsec cscli lapi status; }
cs_bouncer_exists() { docker exec crowdsec cscli bouncers list -o json 2> /dev/null | grep -Eq '"name": *"npmplus"'; }
cs_conf_done() {
    grep -Eq '^ENABLED *= *true$' "$1" && grep -Eq '^API_KEY *= *[^[:space:]]+' "$1"
}

# set_conf KEY Datei – Wert kommt aus der Umgebungsvariable CONF_VALUE (taucht so in keiner Befehlszeile auf).
set_conf() {
    local key=$1 file=$2 tmp
    tmp=$(mktemp "$file.XXXXXX")
    CONF_KEY="$key" awk '
        BEGIN { k = ENVIRON["CONF_KEY"]; v = ENVIRON["CONF_VALUE"]; done = 0 }
        $0 ~ "^" k "[ \t]*=" { if (!done) print k "=" v; done = 1; next }
        { print }
        END { if (!done) print k "=" v }
    ' "$file" > "$tmp"
    cat "$tmp" > "$file" # Besitzer und Rechte der Datei bleiben erhalten
    rm -f "$tmp"
}

setup_crowdsec() {
    local conf="$NPMPLUS_DATA/crowdsec/crowdsec.conf"
    info "Richte den CrowdSec-Bouncer in NPMplus ein"
    if [[ "${ACQUIS_CHANGED:-0}" == 1 ]]; then
        docker restart crowdsec > /dev/null
    fi
    wait_for 180 "CrowdSec LAPI" cs_lapi_ready || {
        CS_STATUS="LAPI nicht erreichbar – prüfen mit: docker logs crowdsec"
        return
    }
    wait_for 300 "$conf (wird von NPMplus beim ersten Start angelegt)" test -s "$conf" || {
        CS_STATUS="$conf fehlt – prüfen mit: docker logs npmplus"
        return
    }
    if cs_conf_done "$conf" && cs_bouncer_exists; then
        ok "Bouncer bereits eingerichtet."
        CS_STATUS="aktiv (Bouncer „npmplus“ war schon eingerichtet)"
        return
    fi
    if cs_bouncer_exists; then
        # Key des alten Bouncers ist nicht mehr abrufbar, deshalb neu anlegen.
        docker exec crowdsec cscli bouncers delete npmplus > /dev/null
    fi
    local key
    key=$(docker exec crowdsec cscli bouncers add npmplus -o raw 2> /dev/null | tr -d '[:space:]')
    [[ -n "$key" ]] || die "cscli bouncers add npmplus lieferte keinen Key."
    CONF_VALUE="$key" set_conf API_KEY "$conf"
    CONF_VALUE=true set_conf ENABLED "$conf"
    unset key
    docker restart npmplus > /dev/null
    ok "Bouncer „npmplus“ angelegt, Key in $conf eingetragen, NPMplus neu gestartet."
    CS_STATUS="aktiv (Bouncer „npmplus“ neu eingerichtet)"
}

# ---------------------------------------------------------------------------------------------------------------
# UniFi API Guard
# ---------------------------------------------------------------------------------------------------------------
prepare_guard() {
    info "Bereite UniFi API Guard vor ($GUARD_DATA)"
    run mkdir -p "$GUARD_DATA"
    run chown "$GUARD_UID:$GUARD_UID" "$GUARD_DATA"
    run chmod 0700 "$GUARD_DATA"
}

guard_token() {
    local since
    since=$(docker inspect -f '{{.State.StartedAt}}' unifi-api-guard)
    docker logs --since "$since" unifi-api-guard 2>&1 |
        grep -o 'setup_token=[^[:space:]]*' | tail -n1 | cut -d= -f2- | tr -d '"'
}

setup_guard() {
    GUARD_TOKEN=""
    if [[ -f "$GUARD_DATA/config.json" ]] && grep -Eq '"admin_password": *"[^"]' "$GUARD_DATA/config.json"; then
        GUARD_STATUS="Admin-Passwort ist bereits gesetzt."
        return
    fi
    local i
    for ((i = 0; i < 30; i++)); do
        GUARD_TOKEN=$(guard_token || true)
        [[ -n "$GUARD_TOKEN" ]] && break
        sleep 2
    done
    if [[ -n "$GUARD_TOKEN" ]]; then
        GUARD_STATUS="Einrichtungs-Token gefunden."
    else
        GUARD_STATUS="Kein Einrichtungs-Token im Log – prüfen mit: docker logs unifi-api-guard"
    fi
}

# ---------------------------------------------------------------------------------------------------------------
# Automatische Updates
# ---------------------------------------------------------------------------------------------------------------
setup_cron() {
    if [[ "$AUTO_UPDATE" != yes ]]; then
        if [[ -f "$CRON_FILE" ]]; then
            run rm -f "$CRON_FILE"
            ok "Automatische Updates entfernt ($CRON_FILE)."
        fi
        return
    fi
    apt_install cron
    local line
    line="$CRON_TIME * * * root docker compose -f $COMPOSE_FILE pull -q && docker compose -f $COMPOSE_FILE up -d && docker image prune -f > /dev/null"
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '   [dry-run] %s:\n   %s\n' "$CRON_FILE" "$line"
        return
    fi
    printf '# NPMplus · Hotte: tägliches Update (install/install.sh)\nSHELL=/bin/sh\nPATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n%s\n' \
        "$line" > "$CRON_FILE"
    chmod 0644 "$CRON_FILE"
    systemctl enable --now cron > /dev/null 2>&1 || true
    ok "Automatische Updates: täglich ${CRON_TIME_TEXT} Uhr ($CRON_FILE)."
}

# ---------------------------------------------------------------------------------------------------------------
# Ablauf
# ---------------------------------------------------------------------------------------------------------------
print_plan() {
    info "Geplante Installation"
    cat << EOF
   Zeitzone:              $TZ
   ACME-E-Mail:           ${ACME_EMAIL:-(keine)}
   UniFi API Guard:       $UNIFI_GUARD
   CrowdSec:              $CROWDSEC
   Automatische Updates:  $AUTO_UPDATE
   compose.yaml:          $COMPOSE_FILE
   Daten:                 $NPMPLUS_DATA$([[ "$UNIFI_GUARD" == yes ]] && printf ', %s' "$GUARD_DATA")$([[ "$CROWDSEC" == yes ]] && printf ', %s' "$CROWDSEC_DATA")
EOF
}

print_summary() {
    local ip
    ip=$(host_ip)
    printf '\n%s%s – fertig%s\n\n' "$C_BOLD" "$TITLE" "$C_OFF"
    cat << EOF
NPMplus
  Oberfläche:   https://$ip:81  (selbstsigniertes Zertifikat, Warnung im Browser bestätigen)
  Erster Login: Beim ersten Aufruf legt ein Einrichtungsassistent das Admin-Konto an.
                Ein Startpasswort gibt es nicht; Meldungen beim Start zeigt: docker logs npmplus
  compose.yaml: $COMPOSE_FILE   Daten: $NPMPLUS_DATA
EOF
    if [[ "$UNIFI_GUARD" == yes ]]; then
        cat << EOF

UniFi API Guard
  Admin:        http://$ip:$GUARD_ADMIN_PORT  (nur aus dem LAN erreichbar lassen)
  Status:       $GUARD_STATUS
EOF
        if [[ -n "$GUARD_TOKEN" ]]; then
            printf '  Token:        %s%s%s  (einmalig, nur zum Festlegen des Admin-Passworts)\n' \
                "$C_BOLD" "$GUARD_TOKEN" "$C_OFF"
        fi
        cat << EOF
  Nächste Schritte:
    1. Admin-Oberfläche öffnen, Token eingeben, Admin-Passwort festlegen.
    2. UniFi-Gateway eintragen (URL + UniFi-API-Key), Fingerprint prüfen, „Verbindung testen“.
    3. Key anlegen: Vorlage „Lokale DNS-Einträge“, Domains z. B. *.example.com, erlaubte IP 127.0.0.1.
       Der Guard-Key (uag_…) wird nur einmal angezeigt.
    4. NPMplus › Einstellungen › UniFi Local DNS: Gateway-URL http://127.0.0.1:$GUARD_PROXY_PORT, API-Key = Guard-Key.
EOF
    fi
    if [[ "$CROWDSEC" == yes ]]; then
        cat << EOF

CrowdSec
  Status:       ${CS_STATUS:-unbekannt}
  Prüfen:       docker exec crowdsec cscli metrics   |   docker exec crowdsec cscli decisions list
  Konfiguration: $CROWDSEC_DATA/conf (Acquis: acquis.d/npmplus.yaml), Bouncer: $NPMPLUS_DATA/crowdsec/crowdsec.conf
  Hinweis:      Signale an die CrowdSec-Zentrale ggf. in der Datenschutzerklärung erwähnen (siehe NPMplus-README).
EOF
    fi
    if [[ "$AUTO_UPDATE" == yes ]]; then
        printf '\nUpdates:        täglich %s Uhr per %s\n' "$CRON_TIME_TEXT" "$CRON_FILE"
    else
        printf '\nUpdate manuell: docker compose -f %s pull && docker compose -f %s up -d\n' "$COMPOSE_FILE" "$COMPOSE_FILE"
    fi
}

main() {
    check_system
    if [[ "$UI" == none && "$NONINTERACTIVE" != 1 && "$DRY_RUN" != 1 ]]; then
        warn "Kein Terminal für Rückfragen – verwende Vorgaben bzw. Umgebungsvariablen."
    fi
    if [[ "$UI" == read && "$DRY_RUN" != 1 ]]; then
        # whiptail nachinstallieren, damit die Fragen als Dialog erscheinen
        apt_install whiptail && UI=whiptail
    fi
    collect_options
    print_plan

    if [[ "$DRY_RUN" == 1 ]]; then
        info "Erzeugte $COMPOSE_FILE"
        generate_compose
        if [[ "$CROWDSEC" == yes ]]; then
            info "Erzeugte $CROWDSEC_DATA/conf/acquis.d/npmplus.yaml"
            crowdsec_acquis
        fi
        info "Geplante Schritte"
    fi

    apt_install ca-certificates curl
    install_docker
    run mkdir -p "$INSTALL_DIR" "$NPMPLUS_DATA"
    [[ "$UNIFI_GUARD" == yes ]] && prepare_guard
    [[ "$CROWDSEC" == yes ]] && prepare_crowdsec

    if [[ "$DRY_RUN" == 1 ]]; then
        printf '   [dry-run] %s schreiben (vorhandene, abweichende Datei wird als .bak-<Zeit> gesichert)\n' "$COMPOSE_FILE"
        printf '   [dry-run] docker compose -f %s pull && up -d\n' "$COMPOSE_FILE"
        [[ "$CROWDSEC" == yes ]] &&
            printf '   [dry-run] warten auf LAPI und %s, cscli bouncers add npmplus, ENABLED/API_KEY setzen, npmplus neu starten\n' \
                "$NPMPLUS_DATA/crowdsec/crowdsec.conf"
        [[ "$UNIFI_GUARD" == yes ]] && printf '   [dry-run] Einrichtungs-Token aus docker logs unifi-api-guard lesen\n'
        setup_cron
        ok "Dry-run beendet, nichts verändert."
        return
    fi

    if generate_compose | write_file_with_backup "$COMPOSE_FILE"; then
        ok "compose.yaml geschrieben: $COMPOSE_FILE"
    else
        ok "compose.yaml unverändert: $COMPOSE_FILE"
    fi

    info "Lade Images und starte Container"
    compose pull -q
    compose up -d
    remove_disabled

    # shellcheck disable=SC2016 # wird erst in sh -c ausgewertet
    wait_for 300 "NPMplus-Healthcheck" \
        sh -c '[ "$(docker inspect -f "{{.State.Health.Status}}" npmplus)" = healthy ]' ||
        warn "NPMplus meldet noch nicht „healthy“ (der erste Start kann dauern). Prüfen mit: docker logs npmplus"
    [[ "$CROWDSEC" == yes ]] && setup_crowdsec
    [[ "$UNIFI_GUARD" == yes ]] && setup_guard
    setup_cron
    print_summary
}

main "$@"
