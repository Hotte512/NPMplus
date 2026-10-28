#!/usr/bin/env bash
# NPMplus · Hotte – Installer für Alpine 3.20+, Debian 12/13 und Ubuntu 22.04/24.04 (LXC oder VM), als root ausführen.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install/install.sh)"
#
# Alpine bringt weder bash noch curl mit, dort vorher: apk add bash curl
#
# Alle Fragen lassen sich per Umgebungsvariable beantworten (NONINTERACTIVE=1 fragt gar nicht):
#   TZ=Europe/Berlin ACME_EMAIL= UNIFI_GUARD=yes|no CROWDSEC=yes|no AUTO_UPDATE=yes|no AUTO_OS_UPDATE=yes|no
#   INSTALL_DIR=/opt/npmplus-hotte TAKEOVER=yes|no OLD_COMPOSE=/pfad/zur/alten/compose.yaml
# DRY_RUN=1 zeigt nur die erzeugte compose.yaml und die geplanten Schritte, ohne etwas zu verändern.
#
# Erneutes Ausführen ist gefahrlos: vorhandene Daten bleiben, eine geänderte compose.yaml wird vorher gesichert.
# Eine vorhandene Installation mit eigener compose.yaml (z. B. von community-scripts) wird erkannt und auf Wunsch
# übernommen (TAKEOVER=yes), siehe docs/installation.md.
#
# Update von Betriebssystem und Containern: install.sh --update (oder MODE=update)
#
# Nur für Tests: OS_RELEASE_FILE=<Datei> ersetzt /etc/os-release, NPMPLUS_HOTTE_LIB=1 lädt nur die Funktionen.

# Deutsche Anführungszeichen („…“) in Texten sind gewollt:
# shellcheck disable=SC1111

set -Eeuo pipefail

# LXC-Templates setzen oft LANG=en_US.UTF-8 ohne erzeugte Locale, apt/perl warnen dann bei jedem Aufruf.
# C.UTF-8 ist immer vorhanden (unter Alpine/musl ohne Wirkung, aber harmlos).
export LANG=C.UTF-8 LC_ALL=C.UTF-8
unset LANGUAGE

# ---------------------------------------------------------------------------------------------------------------
# Feste Werte
# ---------------------------------------------------------------------------------------------------------------
readonly NPMPLUS_IMAGE="ghcr.io/hotte512/npmplus:hotte-main"
readonly GUARD_IMAGE="ghcr.io/hotte512/unifi-api-guard:latest"
readonly CROWDSEC_IMAGE="docker.io/crowdsecurity/crowdsec:latest"
readonly NPMPLUS_DATA="/opt/npmplus"
readonly CROWDSEC_DATA="/opt/crowdsec"
readonly GUARD_UID=65532
readonly GUARD_PROXY_PORT=8090
readonly GUARD_ADMIN_PORT=8091
readonly CRON_FILE="/etc/cron.d/npmplus-hotte" # Debian/Ubuntu
readonly CRONTAB_ALPINE="/etc/crontabs/root"  # Alpine: busybox crond liest /etc/cron.d nicht
readonly CRON_MARK_BEGIN="# >>> npmplus-hotte"
readonly CRON_MARK_END="# <<< npmplus-hotte"
readonly CRON_TIME="47 4" # Minute Stunde: täglich 04:47 Uhr (Systemzeit des Containers)
readonly CRON_TIME_TEXT="04:47"
readonly CRON_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
readonly OURS_MARKER="erzeugt von install/install.sh"
readonly TITLE="NPMplus · Hotte"

GUARD_DATA="/opt/unifi-api-guard" # bei einer Übernahme ggf. der bisherige Pfad
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
DRY_RUN="${DRY_RUN:-0}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"
MODE="${MODE:-install}"

# Übernahme einer vorhandenen Installation (siehe detect_existing)
OLD_COMPOSE="${OLD_COMPOSE:-}"
OLD_JSON=""
TAKEOVER_ACTIVE=0
OLD_DISABLED=""
ROLLBACK_HINT=""
EXTRA_ENV=() EXTRA_ENV_NAMES=() EXTRA_VOLUMES=() EXTRA_DNS=() EXTRA_CAPS=() NOT_CARRIED=() REMOVED_CRON=()

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
    if [[ -n "$ROLLBACK_HINT" ]]; then
        printf '\n%s\n' "$ROLLBACK_HINT" >&2
    fi
    exit 1
}
trap 'die "Abbruch in Zeile $LINENO (Befehl: $BASH_COMMAND)"' ERR

have() { command -v "$1" > /dev/null 2>&1; }

# Führt einen Befehl aus oder zeigt ihn bei DRY_RUN=1 nur an.
run() {
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '   [dry-run] %s\n' "$*"
    else
        "$@"
    fi
}

# Wie run, aber ohne Ausgabe des Befehls selbst.
run_quiet() {
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '   [dry-run] %s\n' "$*"
    else
        "$@" > /dev/null
    fi
}

# ---------------------------------------------------------------------------------------------------------------
# Fragen (whiptail, sonst read, bei NONINTERACTIVE=1 gar nicht)
# ---------------------------------------------------------------------------------------------------------------
UI=none
if [[ "$NONINTERACTIVE" != 1 ]] && [[ -r /dev/tty ]] && { : < /dev/tty; } 2> /dev/null; then
    if have whiptail; then
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
            local flag=() height
            [[ "$default" == no ]] && flag=(--defaultno)
            height=$(($(printf '%s\n' "$question" | wc -l) + 7))
            ((height < 14)) && height=14
            ((height > 24)) && height=24
            if whiptail --title "$TITLE" --scrolltext "${flag[@]}" --yesno "$question" "$height" 78 < /dev/tty; then
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
    # Eine TZ der Shell im POSIX-Format (z. B. „CET-1CEST,M3.5.0,M10.5.0/3“, unter Alpine üblich) ist kein Bezeichner.
    if [[ -n "${TZ:-}" && ! "$TZ" =~ ^[A-Za-z0-9_+/-]+$ ]]; then
        warn "TZ='$TZ' aus der Umgebung ist kein TZ-Bezeichner und wird ignoriert."
        unset TZ
    fi
    ask_text TZ "Zeitzone für die Container (TZ-Bezeichner, z. B. Europe/Berlin):" "${OLD_TZ:-$(system_tz)}"
    ask_text ACME_EMAIL "E-Mail-Adresse für ACME/Let's Encrypt (optional, leer lassen möglich):" "${OLD_ACME_EMAIL:-}"
    ask_yesno UNIFI_GUARD "UniFi API Guard mitinstallieren?

Rechte-Proxy für die UniFi-API: NPMplus bekommt einen eigenen Key, der nur DNS-Einträge ändern darf. Der Proxy lauscht nur lokal (127.0.0.1:${GUARD_PROXY_PORT}), die Admin-Oberfläche auf Port ${GUARD_ADMIN_PORT}." \
        "$([[ -n "${OLD_GUARD_SVC:-}" ]] && echo yes || echo no)"
    ask_yesno CROWDSEC "CrowdSec mitinstallieren?

Erkennt Angriffe in den NPMplus-Logs und sperrt IPs (Bouncer in NPMplus wird automatisch eingerichtet). Aktiviert LOGROTATE." \
        "$([[ -n "${OLD_CROWDSEC_SVC:-}" ]] && echo yes || echo no)"
    ask_yesno AUTO_UPDATE "Automatische Updates der Container einrichten?

Täglich um ${CRON_TIME_TEXT} Uhr neue Images holen, Container neu starten und alte Images löschen." yes
    if [[ "$AUTO_UPDATE" == yes ]]; then
        ask_yesno AUTO_OS_UPDATE "Zusätzlich das Betriebssystem automatisch aktualisieren?

Führt vor dem Container-Update täglich $(os_upgrade_cmd_text) aus. Ohne diese Option bleibt das System-Update Handarbeit (install.sh --update)." no
    else
        AUTO_OS_UPDATE=no
    fi
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
# compose.yaml erzeugen (gleicher Aufbau wie deploy/compose.yaml, bei einer Übernahme plus übernommene Einträge)
# ---------------------------------------------------------------------------------------------------------------
# print_list Einrückung Eintrag... – Einträge sind bereits YAML-taugliche Skalare (JSON-Strings)
print_list() {
    local indent=$1 item
    shift
    for item in "$@"; do
        printf '%s- %s\n' "$indent" "$item"
    done
}

generate_compose() {
    cat << EOF
# NPMplus · Hotte – $OURS_MARKER (bei erneutem Lauf überschrieben, alte Fassung als .bak-<Zeit>)
# Optionen: UNIFI_GUARD=$UNIFI_GUARD CROWDSEC=$CROWDSEC
# Vorlage mit allen Kommentaren: https://github.com/Hotte512/NPMplus/blob/claude/hotte-ci/deploy/compose.yaml
EOF
    # ohne Pfad/Zeit, damit ein erneuter Lauf dieselbe Datei erzeugt
    if ((${#EXTRA_ENV[@]} + ${#EXTRA_VOLUMES[@]} + ${#EXTRA_DNS[@]} + ${#EXTRA_CAPS[@]})); then
        printf '# Zusätzliche Einträge bei npmplus (übernommen bzw. von Hand ergänzt) bleiben bei erneutem Lauf erhalten\n'
    fi
    cat << EOF
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
EOF
    print_list "      " "${EXTRA_CAPS[@]}"
    cat << EOF
    security_opt:
      - no-new-privileges:true
EOF
    if ((${#EXTRA_DNS[@]})); then
        printf '    dns: # übernommen\n'
        print_list "      " "${EXTRA_DNS[@]}"
    fi
    cat << EOF
    volumes:
      - "$NPMPLUS_DATA:/data"
EOF
    print_list "      " "${EXTRA_VOLUMES[@]}"
    cat << EOF
    environment:
      - "TZ=$TZ"
EOF
    if [[ -n "$ACME_EMAIL" ]]; then
        printf '      - "ACME_EMAIL=%s"\n' "$ACME_EMAIL"
    fi
    if [[ "$CROWDSEC" == yes ]]; then
        printf '      - "LOGROTATE=true" # access.log für CrowdSec\n'
    elif [[ -n "${OLD_LOGROTATE:-}" ]]; then
        printf '      - %s # übernommen\n' "$OLD_LOGROTATE"
    fi
    if ((${#EXTRA_ENV[@]})); then
        printf '      # übernommen bzw. ergänzt\n'
        print_list "      " "${EXTRA_ENV[@]}"
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
# System: Erkennung, Pakete, Dienste
# ---------------------------------------------------------------------------------------------------------------
check_system() {
    # Docker auf dem Proxmox-Host verändert iptables (FORWARD DROP) und stört die Netze der VMs/LXCs
    if [[ -d /etc/pve || -x /usr/bin/pveversion ]] && [[ "${ALLOW_PVE_HOST:-0}" != 1 && "$DRY_RUN" != 1 ]]; then
        die "Das ist ein Proxmox-VE-Host. install.sh gehört in einen LXC oder eine VM.
    Auf dem Host stattdessen ausführen (legt den LXC an):
    bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install/proxmox.sh)\""
    fi
    [[ -r "$OS_RELEASE_FILE" ]] || die "$OS_RELEASE_FILE fehlt, unbekanntes System."
    local ID="" VERSION_ID="" VERSION_CODENAME="" PRETTY_NAME="" ID_LIKE=""
    # shellcheck source=/dev/null
    . "$OS_RELEASE_FILE"
    OS_ID=${ID:-unknown}
    OS_CODENAME=${VERSION_CODENAME:-}
    OS_NAME=${PRETTY_NAME:-$OS_ID}
    local supported=0 major minor
    case "$OS_ID" in
        debian | ubuntu)
            OS_FAMILY=debian
            case "$OS_ID:$VERSION_ID" in
                debian:12 | debian:13 | ubuntu:22.04 | ubuntu:24.04) supported=1 ;;
            esac
            ;;
        alpine)
            OS_FAMILY=alpine
            major=${VERSION_ID%%.*}
            minor=${VERSION_ID#*.}
            minor=${minor%%.*}
            if [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] && ((major > 3 || (major == 3 && minor >= 20))); then
                supported=1
            fi
            ;;
        *)
            if [[ " $ID_LIKE " == *" debian "* ]]; then
                OS_FAMILY=debian
            elif [[ " $ID_LIKE " == *" alpine "* ]]; then
                OS_FAMILY=alpine
            else
                OS_FAMILY=unknown
            fi
            ;;
    esac
    if ((!supported)); then
        if [[ "$OS_FAMILY" != unknown ]] && [[ "${FORCE:-0}" == 1 || "$DRY_RUN" == 1 ]]; then
            warn "Nicht getestetes System: $OS_NAME."
        else
            die "Unterstützt: Alpine 3.20+, Debian 12/13, Ubuntu 22.04/24.04 (gefunden: $OS_NAME). FORCE=1 versucht es trotzdem (nur Debian-/Alpine-Abkömmlinge)."
        fi
    fi
    if [[ "$DRY_RUN" != 1 && $EUID -ne 0 ]]; then
        die "Bitte als root ausführen."
    fi
    if [[ -d /run/systemd/system ]] && have systemctl; then
        INIT=systemd
    elif have rc-service && have rc-update; then
        INIT=openrc
    elif [[ "$DRY_RUN" == 1 ]]; then
        # nur Anzeige: typisches Init-System der Familie annehmen
        if [[ "$OS_FAMILY" == alpine ]]; then INIT=openrc; else INIT=systemd; fi
    else
        INIT=none
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

apk_install() {
    local missing=() pkg
    for pkg in "$@"; do
        apk info -e "$pkg" > /dev/null 2>&1 || missing+=("$pkg")
    done
    ((${#missing[@]})) || return 0
    info "Installiere Pakete: ${missing[*]}"
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '   [dry-run] apk add --no-cache %s\n' "${missing[*]}"
        return 0
    fi
    apk add --no-cache -q "${missing[@]}" > /dev/null
}

# pkg_install Paket... – Debian-Namen; unter Alpine werden abweichende Namen übersetzt.
pkg_install() {
    local pkgs=() p
    if [[ "$OS_FAMILY" == alpine ]]; then
        for p in "$@"; do
            case "$p" in
                whiptail) p=newt ;;
                cron) p=busybox-openrc ;; # Init-Skript für busybox crond
            esac
            pkgs+=("$p")
        done
        apk_install "${pkgs[@]}"
    else
        apt_install "$@"
    fi
}

# Alpine: docker und docker-cli-compose liegen im Repository „community“.
apk_enable_community() {
    local repos=/etc/apk/repositories tmp
    if [[ -f "$repos" ]] && grep -Eq '^[[:space:]]*[^#[:space:]].*/community/?[[:space:]]*$' "$repos"; then
        return 0
    fi
    info "Aktiviere das Alpine-Repository „community“ ($repos)"
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '   [dry-run] auskommentierte Zeile …/community in %s aktivieren, apk update\n' "$repos"
        return 0
    fi
    [[ -f "$repos" ]] || die "$repos fehlt."
    cp -a "$repos" "$repos.bak-$(date +%Y%m%d-%H%M%S)"
    tmp=$(mktemp)
    # 1. passende auskommentierte Zeile (nicht edge) aktivieren, 2. sonst aus der main-Zeile ableiten
    awk '
        !done && /^[ \t]*#[ \t]*[^ \t#]+\/community\/?[ \t]*$/ && !/edge/ { sub(/^[ \t]*#[ \t]*/, ""); done = 1 }
        { print }
        /^[ \t]*[^#[:space:]][^ \t]*\/main\/?[ \t]*$/ && !main { main = $0 }
        END { if (!done && main != "") { sub(/main\/?[ \t]*$/, "community", main); print main } }
    ' "$repos" > "$tmp"
    cat "$tmp" > "$repos"
    rm -f "$tmp"
    grep -Eq '^[[:space:]]*[^#[:space:]].*/community/?[[:space:]]*$' "$repos" ||
        die "Konnte das Repository „community“ nicht aktivieren, bitte in $repos von Hand eintragen."
    apk update -q > /dev/null
}

# Dienst dauerhaft aktivieren und starten (systemd oder OpenRC)
svc_enable_start() {
    local name=$1
    case "$INIT" in
        systemd) run_quiet systemctl enable --now "$name" ;;
        openrc)
            run_quiet rc-update add "$name" default
            if [[ "$DRY_RUN" == 1 ]] || ! rc-service "$name" status > /dev/null 2>&1; then
                run_quiet rc-service "$name" start
            fi
            ;;
        *) warn "Kein bekanntes Init-System – Dienst „$name“ bitte selbst starten und aktivieren." ;;
    esac
}

# Läuft der Dienst, wird er neu gestartet (liest dann z. B. geänderte Crontabs neu ein).
svc_restart_if_running() {
    local name=$1
    case "$INIT" in
        systemd) systemctl is-active -q "$name" 2> /dev/null && run_quiet systemctl restart "$name" ;;
        openrc) rc-service "$name" status > /dev/null 2>&1 && run_quiet rc-service "$name" restart ;;
    esac
    return 0
}

install_base_packages() {
    local pkgs=(ca-certificates curl jq tzdata)
    pkg_install "${pkgs[@]}"
}

docker_running() { docker info > /dev/null 2>&1; }

install_docker() {
    if have docker && docker compose version > /dev/null 2>&1; then
        ok "Docker und Compose-Plugin vorhanden ($(docker --version | cut -d, -f1))."
    elif [[ "$OS_FAMILY" == alpine ]]; then
        info "Installiere Docker aus den Alpine-Paketen"
        apk_enable_community
        if have docker; then
            pkg_install docker-cli-compose
        else
            pkg_install docker docker-cli-compose
        fi
    else
        info "Richte das offizielle Docker-Repository ein"
        apt_install ca-certificates curl
        local arch
        arch=$(dpkg --print-architecture 2> /dev/null || echo amd64)
        run mkdir -p /etc/apt/keyrings
        run chmod 0755 /etc/apt/keyrings
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
        if have docker; then
            # Docker ist da (z. B. aus den Distributionspaketen), es fehlt nur das Compose-Plugin.
            apt_install docker-compose-plugin
        else
            apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        fi
    fi
    svc_enable_start docker
    if [[ "$DRY_RUN" == 1 ]]; then
        ok "Docker-Einrichtung geplant."
        return
    fi
    wait_for 60 "Docker-Dienst" docker_running || die "Docker läuft nicht. Prüfen: docker info"
    docker compose version > /dev/null 2>&1 || die "docker compose funktioniert nach der Installation nicht."
    ok "Docker bereit."
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
    cp "$tmp" "$file"
    chmod 0644 "$file"
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
    # jede Quelle darf fehlen (kein iproute2, busybox-hostname ohne -I)
    ip=$(ip -4 route get 1.1.1.1 2> /dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true)
    [[ -n "$ip" ]] ||
        ip=$(ip -4 addr show scope global 2> /dev/null | awk '$1 == "inet" {sub(/\/.*/, "", $2); print $2; exit}' || true)
    [[ -n "$ip" ]] || ip=$(hostname -I 2> /dev/null | awk '{print $1}' || true)
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
# Übernahme einer vorhandenen Installation (z. B. community-scripts: /opt/compose.yaml, Projekt „npmplus“)
# ---------------------------------------------------------------------------------------------------------------
is_ours() { [[ -f "$1" ]] && head -n3 "$1" | grep -q "$OURS_MARKER"; }

# Liest die normalisierte Konfiguration (docker compose config, ohne Docker-Dienst möglich) nach OLD_JSON.
load_old_json() {
    local file=$1 err
    if ! have docker || ! docker compose version > /dev/null 2>&1; then
        die "Alte Installation $file gefunden, aber „docker compose“ fehlt – damit lässt sie sich nicht auslesen."
    fi
    have jq || die "jq fehlt (wird zum Auslesen der alten compose.yaml gebraucht)."
    err=$(mktemp)
    if ! OLD_JSON=$(docker compose -f "$file" --project-directory "$(dirname "$file")" config --format json 2> "$err"); then
        cat "$err" >&2
        rm -f "$err"
        die "docker compose config für $file ist fehlgeschlagen (Meldung oben)."
    fi
    rm -f "$err"
}

# jq_old Filter [jq-Optionen] – Filter auf OLD_JSON
jq_old() {
    local filter=$1
    shift
    jq -r "$@" "$filter" <<< "$OLD_JSON"
}

# jq_array ARRAY Filter [jq-Optionen] – Ergebniszeilen in ein Array (ohne Prozess-Substitution, braucht kein /dev/fd)
jq_array() {
    local var=$1 out
    shift
    out=$(jq_old "$@")
    if [[ -n "$out" ]]; then
        mapfile -t "$var" <<< "$out"
    else
        mapfile -t "$var" < /dev/null
    fi
}

# Wertet OLD_JSON aus: Dienstname, übernommene Variablen/Volumes/DNS/Capabilities, Guard, CrowdSec, Rest.
# shellcheck disable=SC2016 # $s, $g, $c usw. sind jq-Variablen
analyze_old_json() {
    local s
    OLD_SVC=$(jq_old '[.services | to_entries[] | select(.value.container_name == "npmplus") | .key][0]
        // (if .services.npmplus then "npmplus" else empty end)')
    [[ -n "$OLD_SVC" ]] || return 1
    s=$OLD_SVC
    OLD_PROJECT=$(jq_old '.name // empty')
    OLD_IMAGE=$(jq_old '.services[$s].image // "?"' --arg s "$s")
    OLD_DATA=$(jq_old '[.services[$s].volumes // [] | .[] | select(.target == "/data") | .source][0] // empty' --arg s "$s")

    # environment als Liste {key, value} (compose liefert eine Map, ältere Fassungen evtl. eine Liste)
    local envdef='def envlist: if type == "array" then map(. as $e | ($e | index("=")) as $i
        | if $i then {key: $e[:$i], value: $e[$i + 1:]} else {key: $e, value: null} end) else to_entries end;'
    local skip='["TZ", "ACME_EMAIL", "LOGROTATE", "INITIAL_ADMIN_EMAIL", "INITIAL_ADMIN_PASSWORD"]'
    OLD_TZ=$(jq_old "$envdef"' [.services[$s].environment // {} | envlist[] | select(.key == "TZ") | .value][0] // empty' --arg s "$s")
    OLD_ACME_EMAIL=$(jq_old "$envdef"' [.services[$s].environment // {} | envlist[] | select(.key == "ACME_EMAIL") | .value][0] // empty' --arg s "$s")
    OLD_LOGROTATE=$(jq_old "$envdef"' [.services[$s].environment // {} | envlist[] | select(.key == "LOGROTATE" and .value != null and .value != "" and .value != "false")
        | "LOGROTATE=\(.value)" | tojson][0] // empty' --arg s "$s")
    OLD_INITIAL_ADMIN=$(jq_old "$envdef"' [.services[$s].environment // {} | envlist[] | select(.key | startswith("INITIAL_ADMIN_")) | .key] | join(", ")' --arg s "$s")
    # Werte bleiben wie von „compose config“ geliefert ($ ist dort bereits als $$ maskiert); tojson ergibt gültiges YAML.
    jq_array EXTRA_ENV "$envdef"' .services[$s].environment // {} | envlist[] | select(.key as $k | '"$skip"' | index($k) | not)
        | if .value == null then .key else "\(.key)=\(.value)" end | tojson' --arg s "$s"
    jq_array EXTRA_ENV_NAMES "$envdef"' .services[$s].environment // {} | envlist[] | select(.key as $k | '"$skip"' | index($k) | not) | .key' --arg s "$s"
    jq_array EXTRA_VOLUMES '.services[$s].volumes // [] | .[] | select(.type == "bind" and .target != "/data")
        | "\(.source):\(.target)\(if .read_only then ":ro" else "" end)" | tojson' --arg s "$s"
    jq_array EXTRA_DNS '.services[$s].dns // [] | if type == "string" then [.] else . end | .[] | tojson' --arg s "$s"
    jq_array EXTRA_CAPS '(.services[$s].cap_add // []) - ["NET_BIND_SERVICE", "SETGID", "CAP_NET_BIND_SERVICE", "CAP_SETGID"] | .[] | tojson' --arg s "$s"
    jq_array NOT_CARRIED '.services[$s] as $svc
        | ($svc.volumes // [] | .[] | select(.type != "bind") | "Volume \(.source // "-") → \(.target) (Typ \(.type))"),
          ($svc | to_entries[] | select(.value != null) | .key
            | select(. as $k | ["container_name", "restart", "image", "pull_policy", "network_mode", "cap_drop", "cap_add",
                "security_opt", "volumes", "environment", "env_file", "dns", "command", "entrypoint"] | index($k) | not)
            | "Einstellung „\(.)“ des Dienstes"),
          (select(($svc.network_mode // "") != "host") | "network_mode war „\($svc.network_mode // "bridge")“, neu: host")' --arg s "$s"

    OLD_GUARD_SVC=$(jq_old '[.services | to_entries[] | select(.value.container_name == "unifi-api-guard" or .key == "unifi-api-guard") | .key][0] // empty')
    OLD_GUARD_DATA="" OLD_GUARD_ADDRS=""
    if [[ -n "$OLD_GUARD_SVC" ]]; then
        OLD_GUARD_DATA=$(jq_old '[.services[$g].volumes // [] | .[] | select(.target == "/data") | .source][0] // empty' --arg g "$OLD_GUARD_SVC")
        OLD_GUARD_ADDRS=$(jq_old "$envdef"' [.services[$g].environment // {} | envlist[] | select(.key == "GUARD_PROXY_ADDR" or .key == "GUARD_ADMIN_ADDR") | "\(.key)=\(.value)"] | join(" ")' --arg g "$OLD_GUARD_SVC")
    fi
    OLD_CROWDSEC_SVC=$(jq_old '[.services | to_entries[] | select(.value.container_name == "crowdsec" or .key == "crowdsec"
        or ((.value.image // "") | test("crowdsecurity/crowdsec"))) | .key][0] // empty')
    OLD_CROWDSEC_PATHS=""
    if [[ -n "$OLD_CROWDSEC_SVC" ]]; then
        OLD_CROWDSEC_PATHS=$(jq_old '[.services[$c].volumes // [] | .[] | select(.target == "/etc/crowdsec" or .target == "/var/lib/crowdsec/data") | "\(.source):\(.target)"] | join(" ")' --arg c "$OLD_CROWDSEC_SVC")
    fi
    jq_array OLD_OTHER_SVCS '.services | keys[] | select(. != $s and . != $g and . != $c)' \
        --arg s "$s" --arg g "$OLD_GUARD_SVC" --arg c "$OLD_CROWDSEC_SVC"
    return 0
}

# Liest die eigene, bereits vorhandene compose.yaml (erneuter Lauf): bisherige Antworten als Vorgabe und alle
# übernommenen bzw. von Hand ergänzten Einträge (Variablen, Bind-Mounts, dns, cap_add) bleiben erhalten.
load_previous() {
    local file=$1 n
    if ! have docker || ! docker compose version > /dev/null 2>&1 || ! have jq; then
        warn "Bisherige $file kann nicht ausgelesen werden (docker compose/jq fehlt) – zusätzliche Einträge gehen verloren."
        return 0
    fi
    load_old_json "$file"
    if ! analyze_old_json; then
        OLD_JSON=""
        return 0
    fi
    # LOGROTATE stammte von CrowdSec, wenn CrowdSec aktiv war – dann nicht festschreiben
    [[ -n "$OLD_CROWDSEC_SVC" ]] && OLD_LOGROTATE=""
    if [[ -n "$OLD_GUARD_DATA" && "$OLD_GUARD_DATA" != "$GUARD_DATA" ]]; then
        GUARD_DATA=$OLD_GUARD_DATA
    fi
    if ((${#EXTRA_ENV_NAMES[@]} + ${#EXTRA_VOLUMES[@]} + ${#EXTRA_DNS[@]} + ${#EXTRA_CAPS[@]})); then
        info "Bisherige zusätzliche Einträge bleiben: ${EXTRA_ENV_NAMES[*]:-} (${#EXTRA_VOLUMES[@]} Volume(s), ${#EXTRA_DNS[@]} DNS, ${#EXTRA_CAPS[@]} Capability(s))"
    fi
    for n in "${NOT_CARRIED[@]}"; do
        warn "Nicht übernommen aus $file: $n"
    done
    ((${#OLD_OTHER_SVCS[@]})) &&
        warn "Weitere Dienste in $file werden nicht übernommen (Sicherung als .bak-<Zeit>): ${OLD_OTHER_SVCS[*]}"
    return 0
}

# Sucht die eigene Installation (erneuter Lauf) und fremde Installationen: Container „npmplus“ aus einer anderen
# compose-Datei oder bekannte Pfade (community-scripts: /opt/compose.yaml).
detect_existing() {
    local cfg="" wd="" f own="" cands=()
    if [[ -n "$OLD_COMPOSE" ]]; then
        [[ -f "$OLD_COMPOSE" ]] || die "OLD_COMPOSE=$OLD_COMPOSE: Datei nicht gefunden."
        is_ours "$OLD_COMPOSE" && die "OLD_COMPOSE=$OLD_COMPOSE wurde von diesem Installer erzeugt, da gibt es nichts zu übernehmen."
        cands=("$OLD_COMPOSE")
    else
        if have docker && docker inspect npmplus > /dev/null 2>&1; then
            cfg=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' npmplus 2> /dev/null || true)
            wd=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' npmplus 2> /dev/null || true)
            cfg=${cfg%%,*}
            [[ -n "$cfg" ]] || die "Ein Container „npmplus“ existiert, wurde aber nicht mit Docker Compose angelegt.
    Einstellungen notieren (docker inspect npmplus), Container entfernen (docker rm -f npmplus; Daten unter
    /opt/npmplus bleiben) und install.sh erneut ausführen."
            [[ "$cfg" == /* ]] || cfg="$wd/$cfg"
            if is_ours "$cfg"; then
                own=$cfg
                if [[ -z "${INSTALL_DIR+x}" ]]; then
                    INSTALL_DIR=$(dirname "$cfg")
                fi
            elif [[ -f "$cfg" ]]; then
                cands+=("$cfg")
            else
                die "Container „npmplus“ gehört zu $cfg, die Datei gibt es aber nicht mehr.
    Container prüfen (docker inspect npmplus), entfernen (docker rm -f npmplus; Daten bleiben) und install.sh erneut
    ausführen, oder die Datei wiederherstellen und mit OLD_COMPOSE=<Datei> übernehmen."
            fi
        fi
        if [[ -z "$own" ]] && ! ((${#cands[@]})) && is_ours "${INSTALL_DIR:-/opt/npmplus-hotte}/compose.yaml"; then
            own="${INSTALL_DIR:-/opt/npmplus-hotte}/compose.yaml"
        fi
        for f in /opt/compose.yaml /opt/npmplus/compose.yaml; do
            if [[ ! -f "$f" ]] || is_ours "$f"; then continue; fi
            ((${#cands[@]})) && [[ "${cands[0]}" == "$f" ]] && continue
            if [[ -n "$own" ]] || ((${#cands[@]})); then
                warn "Weitere compose-Datei gefunden, nicht aktiv: $f – bitte umbenennen, damit sie nicht versehentlich startet."
                continue
            fi
            cands+=("$f")
        done
    fi
    if ! ((${#cands[@]})); then
        [[ -n "$own" ]] && load_previous "$own"
        return 0
    fi

    load_old_json "${cands[0]}"
    OLD_COMPOSE=${cands[0]}
    if ! analyze_old_json; then
        if [[ -n "$cfg" && "$cfg" == "$OLD_COMPOSE" ]]; then
            die "$OLD_COMPOSE enthält keinen Dienst mit container_name „npmplus“."
        fi
        warn "$OLD_COMPOSE enthält keinen NPMplus-Dienst, wird ignoriert."
        OLD_COMPOSE="" OLD_JSON=""
        EXTRA_ENV=() EXTRA_ENV_NAMES=() EXTRA_VOLUMES=() EXTRA_DNS=() EXTRA_CAPS=() NOT_CARRIED=()
        OLD_TZ="" OLD_ACME_EMAIL="" OLD_LOGROTATE="" OLD_GUARD_SVC="" OLD_CROWDSEC_SVC=""
        return 0
    fi
    confirm_takeover
}

confirm_takeover() {
    local msg names
    if [[ "$OLD_DATA" != "$NPMPLUS_DATA" ]]; then
        die "Die vorhandene Installation ($OLD_COMPOSE) speichert ihre Daten unter „${OLD_DATA:-(Docker-Volume)}“,
    dieser Installer erwartet $NPMPLUS_DATA. Bitte die Daten von Hand dorthin verschieben und den Pfad in der alten
    compose.yaml anpassen, dann install.sh erneut ausführen."
    fi
    names=$(printf '%s ' "${EXTRA_ENV_NAMES[@]}")
    msg="Vorhandene Installation gefunden:
  compose.yaml:  $OLD_COMPOSE (Projekt „${OLD_PROJECT:-?}“)
  NPMplus-Image: $OLD_IMAGE
  Daten:         $OLD_DATA (bleiben, werden weiterverwendet)
  Übernommen:    TZ=${OLD_TZ:-–}, ACME_EMAIL=${OLD_ACME_EMAIL:-–} (als Vorgabe)
  Variablen:     ${names:-keine weiteren}"
    if ((${#EXTRA_VOLUMES[@]} + ${#EXTRA_DNS[@]} + ${#EXTRA_CAPS[@]})); then
        msg+="
  Außerdem:      ${#EXTRA_VOLUMES[@]} Volume(s), ${#EXTRA_DNS[@]} DNS-Server, ${#EXTRA_CAPS[@]} Capability(s)"
    fi
    [[ -n "$OLD_INITIAL_ADMIN" ]] && msg+="
  Entfernt:      $OLD_INITIAL_ADMIN (nur für den ersten Start)"
    [[ -n "$OLD_GUARD_SVC" ]] && msg+="
  Guard:         Dienst „$OLD_GUARD_SVC“, Daten ${OLD_GUARD_DATA:-?}"
    [[ -n "$OLD_CROWDSEC_SVC" ]] && msg+="
  CrowdSec:      Dienst „$OLD_CROWDSEC_SVC“ (${OLD_CROWDSEC_PATHS:-keine Pfade})"
    ((${#OLD_OTHER_SVCS[@]})) && msg+="
  Wird gestoppt, NICHT übernommen: Dienst(e) ${OLD_OTHER_SVCS[*]}"
    local n free_mb
    for n in "${NOT_CARRIED[@]}"; do
        msg+="
  Nicht übernommen: $n"
    done
    # Das neue Image (~450 MB) kommt zunächst zum alten dazu; community-scripts-LXC haben nur wenige GB.
    free_mb=$({ df -Pk /var/lib/docker 2> /dev/null || df -Pk /; } | awk 'NR == 2 {print int($4 / 1024)}' || true)
    if [[ "$free_mb" =~ ^[0-9]+$ ]] && ((free_mb < 1500)); then
        msg+="
  ACHTUNG:       nur $free_mb MB frei – vorher vergrößern, auf dem Proxmox-Host: pct resize <CTID> rootfs +2G"
    fi
    msg+="

Bei der Übernahme wird die alte Installation gestoppt (docker compose down, ohne Volumes zu löschen), die Datei
in *.disabled-by-npmplus-hotte-<Zeit> umbenannt, alte Update-Cronjobs entfernt und NPMplus · Hotte mit denselben
Daten gestartet. Vorher einen Snapshot anlegen, auf dem Proxmox-Host: pct snapshot <CTID> vor-hotte

Installation jetzt übernehmen?"
    printf '\n%s\n\n' "$msg"
    if [[ -z "${TAKEOVER+x}" && "$UI" == none && "$DRY_RUN" == 1 ]]; then
        warn "DRY_RUN: Übernahme wird nur angezeigt (wie mit TAKEOVER=yes)."
        TAKEOVER=yes
    fi
    ask_yesno TAKEOVER "$msg" no
    if [[ "$TAKEOVER" == yes ]]; then
        TAKEOVER_ACTIVE=1
    else
        die "Nichts verändert. Zwei NPMplus-Installationen nebeneinander gehen nicht (Ports 80, 443, 81).
    Übernehmen: install.sh erneut ausführen und zustimmen, ohne Rückfragen mit TAKEOVER=yes."
    fi
    if [[ -n "$OLD_GUARD_DATA" && "$OLD_GUARD_DATA" != "$GUARD_DATA" ]]; then
        [[ "$OLD_GUARD_DATA" == /* && "$OLD_GUARD_DATA" != *[[:space:]]* ]] ||
            die "Datenpfad des alten Guards „$OLD_GUARD_DATA“ ist kein absoluter Pfad ohne Leerzeichen."
        warn "Guard-Daten bleiben am bisherigen Ort: $OLD_GUARD_DATA"
        GUARD_DATA=$OLD_GUARD_DATA
    fi
    if [[ -n "$OLD_GUARD_ADDRS" && "$OLD_GUARD_ADDRS" != *"GUARD_PROXY_ADDR=127.0.0.1:$GUARD_PROXY_PORT"* ]]; then
        warn "Alter Guard lief mit $OLD_GUARD_ADDRS; neu: Proxy 127.0.0.1:$GUARD_PROXY_PORT, Admin :$GUARD_ADMIN_PORT – ggf. Gateway-URL in NPMplus anpassen."
    fi
    if [[ -n "$OLD_CROWDSEC_SVC" && "$OLD_CROWDSEC_PATHS" != *"$CROWDSEC_DATA/conf:/etc/crowdsec"* ]]; then
        warn "Alte CrowdSec-Daten liegen nicht unter $CROWDSEC_DATA – CrowdSec wird dort neu eingerichtet."
    fi
}

# Images vorab laden, damit die alte Installation nur kurz steht.
takeover_pull_images() {
    local img imgs=("$NPMPLUS_IMAGE")
    [[ "$UNIFI_GUARD" == yes ]] && imgs+=("$GUARD_IMAGE")
    [[ "$CROWDSEC" == yes ]] && imgs+=("$CROWDSEC_IMAGE")
    info "Lade die neuen Images (alte Installation läuft solange weiter)"
    for img in "${imgs[@]}"; do
        run_quiet docker pull -q "$img"
    done
}

takeover_disable_old() {
    local ts old_dir
    ts=$(date +%Y%m%d-%H%M%S)
    old_dir=$(dirname "$OLD_COMPOSE")
    OLD_DISABLED="$OLD_COMPOSE.disabled-by-npmplus-hotte-$ts"
    TAKEOVER_BACKUP="/root/npmplus-hotte-backup-$ts"
    info "Deaktiviere die alte Installation ($OLD_COMPOSE)"
    run mv "$OLD_COMPOSE" "$OLD_DISABLED"
    ROLLBACK_HINT="Rückweg zur alten Installation:
  docker compose -f $COMPOSE_FILE down
  mv $OLD_DISABLED $OLD_COMPOSE
  docker compose -f $OLD_COMPOSE up -d
  Cronjobs: Sicherung unter $TAKEOVER_BACKUP (falls vorhanden) zurückkopieren
  oder auf dem Proxmox-Host: pct rollback <CTID> vor-hotte"
    run docker compose -p "${OLD_PROJECT:-npmplus}" -f "$OLD_DISABLED" --project-directory "$old_dir" down
    [[ "$DRY_RUN" == 1 ]] || ok "Alte Container gestoppt und entfernt (Daten bleiben)."
    remove_old_cron
}

# filter_cron Datei Ausgabe Entfernt – entfernt aktive Zeilen, die compose mit der alten Datei bzw. „cd <altes Verz.>“
# aufrufen. Unser eigener Block zwischen den Markern bleibt unangetastet.
filter_cron() {
    OLD_FILE="$OLD_COMPOSE" OLD_DIR="$(dirname "$OLD_COMPOSE")" awk -v removed="$3" '
        function bounded(line, pat,    rest, p, c) {
            rest = line
            while ((p = index(rest, pat)) > 0) {
                c = substr(rest, p + length(pat), 1)
                if (c == "" || c ~ /[ \t;&|)"\047]/) return 1
                rest = substr(rest, p + 1)
            }
            return 0
        }
        BEGIN { f = ENVIRON["OLD_FILE"]; d = ENVIRON["OLD_DIR"]; inblock = 0 }
        index($0, "# >>> npmplus-hotte") == 1 { inblock = 1 }
        inblock { print; if (index($0, "# <<< npmplus-hotte") == 1) inblock = 0; next }
        /^[ \t]*#/ { print; next }
        index($0, "compose") && (bounded($0, f) || bounded($0, "cd " d)) { print > removed; next }
        { print }
    ' "$1" > "$2"
}

remove_old_cron() {
    local file tmp removed line files=("$CRONTAB_ALPINE" /var/spool/cron/crontabs/root /etc/crontab)
    for file in /etc/cron.d/*; do
        [[ -f "$file" && "$file" != "$CRON_FILE" ]] && files+=("$file")
    done
    REMOVED_CRON=()
    for file in "${files[@]}"; do
        [[ -f "$file" ]] || continue
        tmp=$(mktemp) removed=$(mktemp)
        filter_cron "$file" "$tmp" "$removed"
        if [[ -s "$removed" ]]; then
            while IFS= read -r line; do
                REMOVED_CRON+=("$file: $line")
                warn "Alter Cronjob entfernt aus $file: $line"
            done < "$removed"
            if [[ "$DRY_RUN" != 1 ]]; then
                mkdir -p "$TAKEOVER_BACKUP"
                cp -a "$file" "$TAKEOVER_BACKUP/$(printf '%s' "${file#/}" | tr / _)"
                cat "$tmp" > "$file" # Besitzer und Rechte bleiben
            fi
        fi
        rm -f "$tmp" "$removed"
    done
    if ((${#REMOVED_CRON[@]})); then
        [[ "$DRY_RUN" == 1 ]] || ok "Sicherung der geänderten Crontabs: $TAKEOVER_BACKUP"
        svc_restart_if_running crond
        svc_restart_if_running cron
    fi
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

cs_machine_exists() { docker exec crowdsec cscli machines list -o json 2> /dev/null | grep -Eq '"machineId": *"npmplus-gui"'; }

# Machine-Login für die CrowdSec-Seite in NPMplus (Bannen, Entbannen, Alerts). Das Passwort geht direkt in die
# Datei, im Format von „cscli machines add -f“, und taucht in keiner Ausgabe auf.
setup_crowdsec_machine() {
    local conf=$1 creds="$NPMPLUS_DATA/crowdsec/lapi-credentials.yaml" tmp
    if [[ -s "$creds" ]] && cs_machine_exists; then
        ok "Machine-Login für die CrowdSec-Seite bereits eingerichtet."
        return
    fi
    tmp=$(mktemp "$creds.XXXXXX") # mktemp legt die Datei mit 0600 an
    if docker exec crowdsec cscli machines add npmplus-gui --auto --force -f - > "$tmp" 2> /dev/null &&
        grep -q '^password:' "$tmp"; then
        chown "$(stat -c '%u:%g' "$conf")" "$tmp"
        mv "$tmp" "$creds"
        ok "Machine-Login „npmplus-gui“ für die CrowdSec-Seite angelegt ($creds)."
    else
        rm -f "$tmp"
        warn "Machine-Login für die CrowdSec-Seite konnte nicht angelegt werden; Bans sind dort nur lesbar."
    fi
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
    setup_crowdsec_machine "$conf"
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
    # neuere Guard-Versionen legen das Token zusätzlich als Datei ab
    if [[ -s "$GUARD_DATA/setup-token" ]]; then
        tr -d '[:space:]' < "$GUARD_DATA/setup-token"
        return
    fi
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
        GUARD_STATUS="Kein Einrichtungs-Token gefunden – prüfen mit: docker logs unifi-api-guard (bei „permission denied“: chown $GUARD_UID:$GUARD_UID $GUARD_DATA)"
    fi
}

# ---------------------------------------------------------------------------------------------------------------
# Updates: täglicher Cronjob (Container, optional Betriebssystem) und Modus --update
# ---------------------------------------------------------------------------------------------------------------
os_upgrade_cmd_text() {
    if [[ "$OS_FAMILY" == alpine ]]; then
        printf 'apk -U upgrade'
    else
        printf 'apt-get update && apt-get upgrade'
    fi
}

os_upgrade_cmd() {
    if [[ "$OS_FAMILY" == alpine ]]; then
        printf 'apk -U upgrade -q'
    else
        printf 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold'
    fi
}

cron_command() {
    local cmd="docker compose -f $COMPOSE_FILE pull -q && docker compose -f $COMPOSE_FILE up -d && docker image prune -f > /dev/null"
    if [[ "${AUTO_OS_UPDATE:-no}" == yes ]]; then
        cmd="{ $(os_upgrade_cmd); } > /dev/null; $cmd"
    fi
    printf '%s' "$cmd"
}

# crontab_set_block Datei Inhalt – ersetzt den Block zwischen den Markern (leerer Inhalt entfernt ihn).
# Rückgabe 0 = geändert, 1 = unverändert.
crontab_set_block() {
    local file=$1 content=$2 tmp
    [[ -f "$file" || -n "$content" ]] || return 1
    tmp=$(mktemp)
    if [[ -f "$file" ]]; then
        awk -v b="$CRON_MARK_BEGIN" -v e="$CRON_MARK_END" '
            index($0, b) == 1 { skip = 1 }
            !skip { print }
            index($0, e) == 1 { skip = 0 }
        ' "$file" > "$tmp"
    fi
    if [[ -n "$content" ]]; then
        printf '%s\n%s\n%s\n' "$CRON_MARK_BEGIN" "$content" "$CRON_MARK_END" >> "$tmp"
    fi
    if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then
        rm -f "$tmp"
        return 1
    fi
    if [[ -f "$file" ]]; then
        cat "$tmp" > "$file" # Besitzer und Rechte bleiben
    else
        mkdir -p "$(dirname "$file")"
        cp "$tmp" "$file"
        chmod 0600 "$file"
    fi
    rm -f "$tmp"
    return 0
}

setup_cron() {
    local cmd where
    if [[ "$OS_FAMILY" == alpine ]]; then where=$CRONTAB_ALPINE; else where=$CRON_FILE; fi
    if [[ "$AUTO_UPDATE" != yes ]]; then
        if [[ "$OS_FAMILY" == alpine ]]; then
            if [[ "$DRY_RUN" == 1 ]]; then
                printf '   [dry-run] Block „%s“ aus %s entfernen (falls vorhanden)\n' "$CRON_MARK_BEGIN" "$where"
            elif crontab_set_block "$where" ""; then
                svc_restart_if_running crond
                ok "Automatische Updates entfernt ($where)."
            fi
        elif [[ -f "$CRON_FILE" ]]; then
            run rm -f "$CRON_FILE"
            ok "Automatische Updates entfernt ($CRON_FILE)."
        fi
        return
    fi
    cmd=$(cron_command)
    if [[ "$OS_FAMILY" == alpine ]]; then
        # busybox crond: kein Benutzerfeld, keine Variablenzeilen – PATH steht deshalb im Befehl
        local block
        block="# NPMplus · Hotte: tägliches Update (install/install.sh), wird bei erneutem Lauf ersetzt
$CRON_TIME * * * PATH=$CRON_PATH; $cmd"
        [[ -x /etc/init.d/crond ]] || pkg_install cron
        if [[ "$DRY_RUN" == 1 ]]; then
            printf '   [dry-run] %s (Block zwischen „%s“ und „%s“):\n%s\n' "$where" "$CRON_MARK_BEGIN" "$CRON_MARK_END" "$block"
            svc_enable_start crond
            return
        fi
        crontab_set_block "$where" "$block" || true
        svc_enable_start crond
        svc_restart_if_running crond
    else
        local line="$CRON_TIME * * * root $cmd"
        pkg_install cron
        if [[ "$DRY_RUN" == 1 ]]; then
            printf '   [dry-run] %s:\n   %s\n' "$CRON_FILE" "$line"
            return
        fi
        printf '# NPMplus · Hotte: tägliches Update (install/install.sh)\nSHELL=/bin/sh\nPATH=%s\n%s\n' \
            "$CRON_PATH" "$line" > "$CRON_FILE"
        chmod 0644 "$CRON_FILE"
        svc_enable_start cron
    fi
    ok "Automatische Updates: täglich ${CRON_TIME_TEXT} Uhr ($where)."
}

# install.sh --update: Betriebssystem und Container aktualisieren
update_mode() {
    if [[ -z "${INSTALL_DIR:-}" ]] && have docker; then
        local cfg
        cfg=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' npmplus 2> /dev/null || true)
        cfg=${cfg%%,*}
        if is_ours "$cfg"; then INSTALL_DIR=$(dirname "$cfg"); fi
    fi
    INSTALL_DIR=${INSTALL_DIR:-/opt/npmplus-hotte}
    INSTALL_DIR=${INSTALL_DIR%/}
    COMPOSE_FILE="$INSTALL_DIR/compose.yaml"
    if ! is_ours "$COMPOSE_FILE"; then
        die "Keine Installation von NPMplus · Hotte unter $COMPOSE_FILE gefunden (anderer Ort: INSTALL_DIR=… setzen).
    Eine andere Installation (z. B. community-scripts) zuerst mit install.sh ohne --update übernehmen."
    fi
    info "Aktualisiere das Betriebssystem ($OS_NAME)"
    if [[ "$OS_FAMILY" == alpine ]]; then
        run apk -U upgrade
    else
        run apt-get update -qq
        if [[ "$DRY_RUN" == 1 ]]; then
            printf '   [dry-run] apt-get upgrade -y\n'
        else
            DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -o Dpkg::Options::=--force-confdef \
                -o Dpkg::Options::=--force-confold
        fi
    fi
    info "Aktualisiere die Container ($COMPOSE_FILE)"
    run docker compose -f "$COMPOSE_FILE" --project-directory "$INSTALL_DIR" pull -q
    run docker compose -f "$COMPOSE_FILE" --project-directory "$INSTALL_DIR" up -d
    run_quiet docker image prune -f
    [[ "$DRY_RUN" == 1 ]] || ok "Update abgeschlossen. Nach einem Kernel- oder Docker-Update ggf. neu starten."
}

# ---------------------------------------------------------------------------------------------------------------
# Ablauf
# ---------------------------------------------------------------------------------------------------------------
print_plan() {
    info "Geplante Installation"
    cat << EOF
   System:                $OS_NAME ($OS_FAMILY, Init: $INIT)
   Zeitzone:              $TZ
   ACME-E-Mail:           ${ACME_EMAIL:-(keine)}
   UniFi API Guard:       $UNIFI_GUARD
   CrowdSec:              $CROWDSEC
   Automatische Updates:  $AUTO_UPDATE (Container)$([[ "$AUTO_OS_UPDATE" == yes ]] && printf ' + Betriebssystem')
   compose.yaml:          $COMPOSE_FILE
   Daten:                 $NPMPLUS_DATA$([[ "$UNIFI_GUARD" == yes ]] && printf ', %s' "$GUARD_DATA")$([[ "$CROWDSEC" == yes ]] && printf ', %s' "$CROWDSEC_DATA")
EOF
    if [[ "$TAKEOVER_ACTIVE" == 1 ]]; then
        printf '   Übernahme von:         %s (Projekt „%s“)\n' "$OLD_COMPOSE" "${OLD_PROJECT:-?}"
        printf '   Übernommene Variablen: %s\n' "${EXTRA_ENV_NAMES[*]:-keine}"
    fi
}

print_summary() {
    local ip
    ip=$(host_ip)
    printf '\n%s%s – fertig%s\n\n' "$C_BOLD" "$TITLE" "$C_OFF"
    if [[ "$TAKEOVER_ACTIVE" == 1 ]]; then
        cat << EOF
NPMplus
  Oberfläche:   https://$ip:81  (Login wie bisher, Daten wurden übernommen)
EOF
    else
        cat << EOF
NPMplus
  Oberfläche:   https://$ip:81  (selbstsigniertes Zertifikat, Warnung im Browser bestätigen)
  Erster Login: Beim ersten Aufruf legt ein Einrichtungsassistent das Admin-Konto an.
                Ein Startpasswort gibt es nicht; Meldungen beim Start zeigt: docker logs npmplus
EOF
    fi
    printf '  compose.yaml: %s   Daten: %s\n' "$COMPOSE_FILE" "$NPMPLUS_DATA"
    if [[ "$TAKEOVER_ACTIVE" == 1 ]]; then
        cat << EOF

Übernahme
  Alte Datei:   $OLD_DISABLED (deaktiviert)
  Variablen:    ${EXTRA_ENV_NAMES[*]:-keine} (dazu TZ, ACME_EMAIL aus den Antworten)
EOF
        ((${#EXTRA_VOLUMES[@]} + ${#EXTRA_DNS[@]} + ${#EXTRA_CAPS[@]})) &&
            printf '  Außerdem:     %s Volume(s), %s DNS-Server, %s Capability(s)\n' \
                "${#EXTRA_VOLUMES[@]}" "${#EXTRA_DNS[@]}" "${#EXTRA_CAPS[@]}"
        if [[ -n "$OLD_INITIAL_ADMIN" ]]; then
            cat << EOF
  Entfernt:     $OLD_INITIAL_ADMIN – nur für den ersten Start gedacht und mit einem öffentlich
                bekannten Standardpasswort. Falls das Admin-Konto noch dieses Passwort hat: in NPMplus ändern.
EOF
        fi
        local n
        for n in "${NOT_CARRIED[@]}"; do printf '  Nicht übernommen: %s\n' "$n"; done
        ((${#OLD_OTHER_SVCS[@]})) && printf '  Gestoppt, nicht übernommen: %s\n' "${OLD_OTHER_SVCS[*]}"
        for n in "${REMOVED_CRON[@]}"; do printf '  Cron entfernt: %s\n' "$n"; done
        printf '\n'
        while IFS= read -r n; do printf '  %s\n' "$n"; done <<< "$ROLLBACK_HINT"
    fi
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
        if [[ "$GUARD_STATUS" != "Admin-Passwort ist bereits gesetzt." ]]; then
            cat << EOF
  Nächste Schritte:
    1. Admin-Oberfläche öffnen, Token eingeben, Admin-Passwort festlegen.
    2. UniFi-Gateway eintragen (URL + UniFi-API-Key), Fingerprint prüfen, „Verbindung testen“.
    3. Key anlegen: Vorlage „Lokale DNS-Einträge“, Domains z. B. *.example.com, erlaubte IP 127.0.0.1.
       Der Guard-Key (uag_…) wird nur einmal angezeigt.
    4. NPMplus › Einstellungen › UniFi Local DNS: Gateway-URL http://127.0.0.1:$GUARD_PROXY_PORT, API-Key = Guard-Key.
EOF
        fi
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
    printf '\n'
    if [[ "$AUTO_UPDATE" == yes ]]; then
        printf 'Updates:        täglich %s Uhr (%s), Container%s\n' "$CRON_TIME_TEXT" \
            "$([[ "$OS_FAMILY" == alpine ]] && echo "$CRONTAB_ALPINE" || echo "$CRON_FILE")" \
            "$([[ "$AUTO_OS_UPDATE" == yes ]] && echo " und Betriebssystem" || echo " (Betriebssystem nicht)")"
    fi
    # shellcheck disable=SC2016 # Befehl zum Abschreiben, nicht auswerten
    printf 'Update manuell: install.sh --update bzw. MODE=update bash -c "$(curl …/install.sh)" (Betriebssystem und Container)\n'
}

usage() {
    cat << 'EOF'
install.sh            installieren bzw. Einstellungen ändern (erneut ausführen ist gefahrlos)
install.sh --update   Betriebssystem (apk/apt) und Container aktualisieren
Optionen per Umgebungsvariable, siehe Kopf dieser Datei und docs/installation.md.
EOF
}

main() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --update) MODE=update ;;
            -h | --help)
                usage
                return 0
                ;;
            *) die "Unbekannte Option: $arg (siehe --help)" ;;
        esac
    done
    check_system
    if [[ "$MODE" == update ]]; then
        update_mode
        return
    fi
    [[ "$MODE" == install ]] || die "MODE=$MODE unbekannt (install oder update)."
    if [[ "$UI" == none && "$NONINTERACTIVE" != 1 && "$DRY_RUN" != 1 ]]; then
        warn "Kein Terminal für Rückfragen – verwende Vorgaben bzw. Umgebungsvariablen."
    fi
    install_base_packages
    if [[ "$UI" == read && "$DRY_RUN" != 1 ]]; then
        # whiptail (Alpine: newt) nachinstallieren, damit die Fragen als Dialog erscheinen
        pkg_install whiptail && UI=whiptail
    fi
    detect_existing
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

    install_docker
    run mkdir -p "$INSTALL_DIR" "$NPMPLUS_DATA"
    [[ "$UNIFI_GUARD" == yes ]] && prepare_guard
    [[ "$CROWDSEC" == yes ]] && prepare_crowdsec
    if [[ "$TAKEOVER_ACTIVE" == 1 ]]; then
        takeover_pull_images
        takeover_disable_old
    fi

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
    if [[ "$TAKEOVER_ACTIVE" == 1 && "$OLD_IMAGE" != "$NPMPLUS_IMAGE" && "$OLD_IMAGE" != "?" ]] &&
        docker image rm "$OLD_IMAGE" > /dev/null 2>&1; then
        ok "Altes Image entfernt: $OLD_IMAGE (der Rückweg lädt es bei Bedarf neu)"
    fi

    # shellcheck disable=SC2016 # wird erst in sh -c ausgewertet
    wait_for 300 "NPMplus-Healthcheck" \
        sh -c '[ "$(docker inspect -f "{{.State.Health.Status}}" npmplus)" = healthy ]' ||
        warn "NPMplus meldet noch nicht „healthy“ (der erste Start kann dauern). Prüfen mit: docker logs npmplus"
    [[ "$CROWDSEC" == yes ]] && setup_crowdsec
    [[ "$UNIFI_GUARD" == yes ]] && setup_guard
    setup_cron
    print_summary
}

# NPMPLUS_HOTTE_LIB=1 nur für Tests: Funktionen laden, nichts ausführen
if [[ "${NPMPLUS_HOTTE_LIB:-0}" != 1 ]]; then
    main "$@"
fi
