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
#   IMPORT_FROM=/pfad/zu/anderer/compose.yaml (weitere Dienste daraus in die vorhandene Installation holen)
# DRY_RUN=1 zeigt nur die erzeugte compose.yaml und die geplanten Schritte, ohne etwas zu verändern (übernommene Werte
# als ***, SHOW_VALUES=1 zeigt sie; fehlt jq zum Lesen einer vorhandenen compose.yaml, wird es trotzdem installiert).
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
# CrowdSec-Helfer (deploy/crowdsec-helper.sh): Skript und Spool-Verzeichnis, das NPMplus als /data/crowdsec/helper sieht
readonly CROWDSEC_HELPER_DIR="$CROWDSEC_DATA/helper"
# in: schreibt nur NPMplus (beim Helfer schreibgeschützt), out: schreibt nur der Helfer (bei NPMplus schreibgeschützt)
readonly CROWDSEC_SPOOL_IN="$CROWDSEC_HELPER_DIR/in"
readonly CROWDSEC_SPOOL_OUT="$CROWDSEC_HELPER_DIR/out"
readonly CROWDSEC_SPOOL_LEGACY="$CROWDSEC_HELPER_DIR/spool" # erste Fassung, ein gemeinsames Verzeichnis
readonly CROWDSEC_HELPER_BIN="$CROWDSEC_HELPER_DIR/bin"
readonly CROWDSEC_HELPER_SCRIPT="$CROWDSEC_HELPER_BIN/crowdsec-helper.sh"
readonly NPMPLUS_SPOOL_TARGET="/data/crowdsec/helper"
readonly NPMPLUS_SPOOL_IN="$NPMPLUS_SPOOL_TARGET/in"
readonly NPMPLUS_SPOOL_OUT="$NPMPLUS_SPOOL_TARGET/out"
# AppSec-Body-Limit (appsec-config npmplus/body-limit), Vorgabe für neue und aktualisierte Installationen: 64 MiB, partial
readonly CROWDSEC_BODY_FILE="$CROWDSEC_DATA/conf/appsec-configs/npmplus-body-limit.yaml"
readonly CROWDSEC_BODY_DEFAULT_SIZE=67108864
readonly CROWDSEC_BODY_DEFAULT_ACTION=partial
readonly CROWDSEC_BODY_MARK="npmplus/body-limit: Body-Limit aus NPMplus"
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
# weitere Dienste (z. B. geoipupdate) samt benutzter Volumes/Netze als JSON {services, volumes, networks, …}
EXTRA_JSON="" EXTRA_SVC_NAMES=() IMPORTED_SVCS=()
IMPORT_FROM="${IMPORT_FROM:-}"
SHOW_VALUES="${SHOW_VALUES:-0}"
COMPOSE_MASK=0 # 1 = Werte übernommener Variablen als *** anzeigen (Probelauf)
# Bisherige Einstellungen der eigenen compose.yaml (erneuter Lauf, --update), siehe CARRY_JQ
CARRY_JSON=""

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
    if [[ "$CROWDSEC" == yes ]]; then
        printf '      - "%s:%s" # CrowdSec-Helfer: Soll-Zustand (schreibt NPMplus)\n' "$CROWDSEC_SPOOL_IN" "$NPMPLUS_SPOOL_IN"
        printf '      - "%s:%s:ro" # CrowdSec-Helfer: Status (schreibt der Helfer)\n' "$CROWDSEC_SPOOL_OUT" "$NPMPLUS_SPOOL_OUT"
    fi
    print_list "      " "${EXTRA_VOLUMES[@]}"
    # übernommene Volumes, die keine Bind-Mounts sind (z. B. benannte Volumes)
    [[ -n "$CARRY_JSON" ]] && jq -r '(.services.npmplus.volumes // [])[] | select(.type != "bind") | "      - " + tojson' <<< "$CARRY_JSON"
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
        if [[ "$COMPOSE_MASK" == 1 ]]; then
            local n
            for n in "${EXTRA_ENV_NAMES[@]}"; do printf '      - "%s=***"\n' "$n"; done
        else
            print_list "      " "${EXTRA_ENV[@]}"
        fi
    fi
    print_keys npmplus container_name restart image pull_policy network_mode cap_drop cap_add security_opt dns

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
EOF
        print_volumes unifi-api-guard '[]' "$GUARD_DATA:/data"
        print_env unifi-api-guard "TZ=$TZ" "GUARD_PROXY_ADDR=127.0.0.1:$GUARD_PROXY_PORT" "GUARD_ADMIN_ADDR=:$GUARD_ADMIN_PORT" \
            "GUARD_ADMIN_ALLOW=127.0.0.0/8,::1/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,fc00::/7"
        print_keys unifi-api-guard container_name restart image pull_policy network_mode read_only cap_drop security_opt
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
EOF
        print_ports crowdsec '"127.0.0.1:7422:7422"' '"127.0.0.1:8080:8080"'
        print_env crowdsec "TZ=$TZ" "USE_WAL=true" "COLLECTIONS=ZoeyVid/npmplus"
        print_volumes crowdsec '[]' "$CROWDSEC_DATA/conf:/etc/crowdsec" "$CROWDSEC_DATA/data:/var/lib/crowdsec/data" \
            "$NPMPLUS_DATA/nginx/logs:$NPMPLUS_DATA/nginx/logs:ro"
        print_keys crowdsec container_name restart image pull_policy network_mode security_opt
        cat << EOF

  # CrowdSec-Helfer: setzt NPMplus-Allowlist und AppSec-Body-Limit um (cscli, SIGHUP an crowdsec), ohne Docker-Socket
  crowdsec-helper:
    container_name: crowdsec-helper
    restart: unless-stopped
    image: $CROWDSEC_IMAGE
    pull_policy: always
    network_mode: "service:crowdsec" # LAPI unter 127.0.0.1:8080 für cscli allowlists list/inspect
    pid: "service:crowdsec" # SIGHUP an den crowdsec-Prozess nach einer AppSec-Änderung
    depends_on:
      crowdsec:
        condition: service_started
        restart: true # „docker compose restart crowdsec“ startet den Helfer mit (nötig wegen pid/network)
    entrypoint: ["/bin/sh", "/helper/crowdsec-helper.sh"]
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp:size=64m
    pids_limit: 64
    mem_limit: 256m
    # Schreibrechte nur wo nötig: appsec-configs (npmplus-body-limit.yaml), data (cscli allowlists schreibt in die
    # SQLite-Datenbank), spool/out (Status). Den Soll-Zustand in spool/in liest der Helfer nur.
EOF
        print_volumes crowdsec-helper '["/spool"]' "$CROWDSEC_DATA/conf:/etc/crowdsec:ro" \
            "$CROWDSEC_DATA/conf/appsec-configs:/etc/crowdsec/appsec-configs" "$CROWDSEC_DATA/data:/var/lib/crowdsec/data" \
            "$CROWDSEC_SPOOL_IN:/spool/in:ro" "$CROWDSEC_SPOOL_OUT:/spool/out" "$CROWDSEC_HELPER_BIN:/helper:ro"
        print_env crowdsec-helper "TZ=$TZ"
        print_keys crowdsec-helper container_name restart image pull_policy network_mode pid depends_on entrypoint \
            cap_drop security_opt read_only tmpfs pids_limit mem_limit
    fi
    print_extra_services
    print_top_level
}

carry_or_empty() { if [[ -n "$CARRY_JSON" ]]; then printf '%s' "$CARRY_JSON"; else printf '{}'; fi; }

# print_env DIENST "K=V"... – Vorgaben des Installers; bisherige Werte und weitere Variablen der eigenen
# compose.yaml gehen vor (z. B. COLLECTIONS, BOUNCER_KEY_*, GUARD_ADMIN_ALLOW)
print_env() {
    local svc=$1
    shift
    printf '    environment:\n'
    jq -rn --argjson c "$(carry_or_empty)" --arg s "$svc" --arg mask "$COMPOSE_MASK" '
        ($ARGS.positional | map(capture("^(?<key>[^=]+)=(?<value>.*)$"))) as $def
        | ($def | from_entries) as $d
        | ($c.services[$s].environment // {}) as $old
        | (($def | map(.key)) + ($old | keys_unsorted | map(select(. as $k | $d | has($k) | not))))[] as $k
        | (if $old | has($k) then $old[$k] else $d[$k] end) as $v
        | (if $mask == "1" and ($old | has($k)) and $v != $d[$k] then "***" else $v end) as $shown
        | "      - " + (if $v == null then $k else "\($k)=\($shown)" end | tojson)' --args "$@"
}

# print_ports DIENST "IP:Port:Port"... – bisherige, abweichende Ports der eigenen compose.yaml gehen vor
print_ports() {
    local svc=$1
    shift
    # shellcheck disable=SC2016 # jq-Variablen
    if jq -en --argjson c "$(carry_or_empty)" --arg s "$svc" '
        ($c.services[$s].ports // []) as $old
        | ($old | map("\(.host_ip // ""):\(.published // ""):\(.target)/\(.protocol // "tcp")") | sort) as $o
        | ($ARGS.positional | map(gsub("\""; "") + "/tcp") | sort) as $t
        | ($old | length) > 0 and $o != $t' --args "$@" > /dev/null; then
        printf '    ports: # bisherige Einstellung\n'
        jq -r --arg s "$svc" '.services[$s].ports[] | "      - " + tojson' <<< "$CARRY_JSON"
    else
        printf '    ports:\n'
        print_list "      " "$@"
    fi
}

# print_volumes DIENST ALTE_ZIELE(JSON) "Quelle:Ziel[:ro]"... – Vorgaben, dazu bisherige Volumes mit anderem Ziel
# (ALTE_ZIELE: Ziele früherer Fassungen, die wegfallen)
print_volumes() {
    local svc=$1 legacy=$2 v
    shift 2
    printf '    volumes:\n'
    for v in "$@"; do printf '      - "%s"\n' "$v"; done
    jq -rn --argjson c "$(carry_or_empty)" --arg s "$svc" --argjson legacy "$legacy" '
        ($ARGS.positional | map(split(":")[1])) as $t
        | ($c.services[$s].volumes // [])[] | select(.target as $x | ($t + $legacy) | index($x) | not)
        | "      - " + tojson' --args "$@"
}

# print_keys DIENST SCHLÜSSEL... – weitere Einstellungen der eigenen compose.yaml, die die Vorlage nicht setzt
# (z. B. labels, logging, mem_limit), bleiben erhalten; die genannten Schlüssel setzt die Vorlage
print_keys() {
    local svc=$1
    shift
    jq -rn --argjson c "$(carry_or_empty)" --arg s "$svc" '
        ($c.services[$s] // {}) | to_entries[]
        | select(.value != null and (.key as $k | ["environment", "ports", "volumes"] + $ARGS.positional | index($k) | not))
        | "    \(.key | tojson): \(.value | tojson)"' --args "$@"
}

# Oberste Ebene: Volumes/Netze/Secrets/Configs weiterer Dienste und alle übrigen Schlüssel der eigenen compose.yaml
print_top_level() {
    local e=${EXTRA_JSON:-}
    [[ -n "$e" ]] || e='{}'
    jq -rn --argjson c "$(carry_or_empty)" --argjson e "$e" '
        def sections: ["volumes", "networks", "secrets", "configs"];
        (reduce sections[] as $k (($c.top // {});
            if ($e[$k] // {}) | length > 0 then .[$k] = ((.[$k] // {}) + $e[$k]) else . end)) as $all
        | $all | to_entries[] | select(.value != null and .value != {})
        | if (.key as $k | sections | index($k)) and (.value | type) == "object"
          then "\n\(.key):", (.value | to_entries[] | "  \(.key | tojson): \(.value | tojson)")
          else "\n\(.key): \(.value | tojson)" end'
}

# Weitere Dienste als JSON-Flow-Mappings (gültiges YAML); Werte unverändert aus „docker compose config“ ($ als $$).
# Im Probelauf (COMPOSE_MASK=1) werden ihre Umgebungsvariablen als *** angezeigt.
print_extra_services() {
    [[ -n "$EXTRA_JSON" ]] || return 0
    printf '\n  # Weitere Dienste (übernommen bzw. ergänzt, bleiben bei erneutem Lauf erhalten)\n'
    jq -r --arg mask "$COMPOSE_MASK" '
        def mask: if (.environment | type) == "object" then .environment |= map_values(if . == null then null else "***" end)
            elif (.environment | type) == "array" then .environment |= map(sub("=.*"; "=***")) else . end;
        .services | to_entries[] | "  \(.key | tojson): \(.value | if $mask == "1" then mask else . end | tojson)"' <<< "$EXTRA_JSON"
}

# Zeigt vor dem Überschreiben der eigenen compose.yaml die Änderungen (Werte von Umgebungsvariablen als ***).
# Gingen dabei Einstellungen verloren, wird gefragt; ohne Terminal bleibt die Datei, und das Skript bricht ab
# (bestätigen mit ACCEPT_COMPOSE_CHANGES=yes).
review_compose_changes() {
    [[ -n "$CARRY_JSON" && -n "$OLD_JSON" && -f "$COMPOSE_FILE" ]] || return 0
    local tmp new losses allowed
    tmp=$(mktemp)
    COMPOSE_MASK=0 generate_compose > "$tmp"
    if cmp -s "$tmp" "$COMPOSE_FILE"; then
        rm -f "$tmp"
        return 0
    fi
    info "Änderungen an $COMPOSE_FILE (Werte von Variablen als ***):"
    diff -u "$COMPOSE_FILE" "$tmp" | tail -n +3 |
        sed -E 's/^([-+ ][[:space:]]*- )"([A-Za-z_][A-Za-z0-9_]*)=[^"]*"/\1"\2=***"/; s/^([-+ ]  "[^"]+"): \{.*/\1: {…}/' |
        sed 's/^/    /' || true
    new=$(docker compose -f "$tmp" --project-directory "$INSTALL_DIR" config --format json 2> /dev/null) || new='{}'
    rm -f "$tmp"
    # vom Installer gewollte Änderungen: altes Spool-Verzeichnis des Helfers, LOGROTATE beim Abwählen von CrowdSec
    allowed='[["services","crowdsec-helper","volumes","/spool"],["services","npmplus","volumes","'"$NPMPLUS_SPOOL_TARGET"'"]'
    [[ "$CROWDSEC" == yes ]] || allowed+=',["services","npmplus","environment","LOGROTATE"]'
    allowed+=']'
    losses=$(jq -rn --argjson old "$OLD_JSON" --argjson new "$new" --argjson allowed "$allowed" "$LOSS_JQ")
    [[ -n "$losses" ]] || return 0
    warn "Diese Einstellungen der bisherigen compose.yaml würden geändert oder gingen verloren:"
    printf '%s\n' "$losses" | sed 's/^/      /' >&2
    [[ "$DRY_RUN" == 1 ]] && return 0
    ask_yesno ACCEPT_COMPOSE_CHANGES "Die bisherige compose.yaml enthält Einstellungen, die der Installer ändern würde (Liste
im Terminal). Die alte Fassung wird als .bak gesichert.

Trotzdem übernehmen?" no
    [[ "$ACCEPT_COMPOSE_CHANGES" == yes ]] ||
        die "$COMPOSE_FILE bleibt unverändert. Die Einstellungen oben von Hand übertragen bzw. bestätigen mit
    ACCEPT_COMPOSE_CHANGES=yes (oder interaktiv ausführen)."
}

# Prüft die erzeugte compose.yaml mit „docker compose config“, bevor irgendetwas geändert wird.
validate_compose() {
    if ! have docker || ! docker compose version > /dev/null 2>&1; then
        return 0
    fi
    local tmp err
    tmp=$(mktemp) err=$(mktemp)
    COMPOSE_MASK=0 generate_compose > "$tmp"
    if docker compose -f "$tmp" --project-directory "$INSTALL_DIR" config -q 2> "$err"; then
        ok "Erzeugte compose.yaml ist gültig (docker compose config)."
        rm -f "$tmp" "$err"
    else
        sed 's/^/    /' "$err" >&2
        rm -f "$tmp" "$err"
        die "Die erzeugte compose.yaml ist ungültig (Meldung oben) – nichts verändert."
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

# Inhalt von deploy/crowdsec-helper.sh, unverändert eingebettet (Abgleich: siehe docs/development.md)
crowdsec_helper_script() {
    cat << 'CROWDSEC_HELPER_EOF'
#!/bin/sh
# NPMplus · Hotte – CrowdSec-Helfer (crowdsec-helper.sh)
#
# Läuft als Dienst „crowdsec-helper“ im selben Image wie „crowdsec“ (bringt cscli mit), pid und network von crowdsec
# geteilt. Setzt den Soll-Zustand um, den NPMplus nach /spool/in schreibt (für den Helfer schreibgeschützt):
#
#   allowlist.desired  Einträge der CrowdSec-Allowlist „npmplus“ (cscli allowlists). Fehlende werden ergänzt; entfernt
#                      werden nur Einträge, die der Helfer selbst angelegt hat. Andere Allowlists bleiben unberührt.
#   appsec.desired     Body-Limit von AppSec: prüft die appsec-config „npmplus/body-limit“ zuerst unter anderem Namen mit
#                      „crowdsec -t“, stellt sie dann bereit und lädt crowdsec per SIGHUP neu.
#
# Ergebnis und Lebenszeichen: /spool/out/status.json (für NPMplus schreibgeschützt), NPMplus zeigt es an.
#
# /spool/in gilt als nicht vertrauenswürdig: jeder Wert wird hier erneut streng geprüft, Werte gehen nur als einzelne
# Argumente an cscli (kein eval, kein sh -c), Symlinks und andere Nicht-Dateien werden nicht gelesen, Lesen bricht nach
# 5 Sekunden ab, ungültige Zeilen erscheinen nur mit ihrer Zeilennummer im Status. Beschreibungen werden nie geloggt.
# Geschrieben wird nur in Verzeichnisse, auf die NPMplus keinen Schreibzugriff hat.
#
# Quelle: deploy/crowdsec-helper.sh (Branch claude/hotte-ci); install/install.sh schreibt dieselbe Fassung nach
# /opt/crowdsec/helper/bin/crowdsec-helper.sh. Änderungen dort werden beim nächsten Lauf des Installers überschrieben.
#
# Aufruf: crowdsec-helper.sh            Dienst (Schleife)
#         crowdsec-helper.sh probe BYTES AKTION   nur prüfen, ob crowdsec dieses Body-Limit annimmt (für install.sh)
#
# Nur für Tests: HELPER_IN, HELPER_OUT, HELPER_CONF_DIR, HELPER_STATE_DIR, HELPER_TMP ersetzen die Pfade, HELPER_ONCE=1
# macht nur einen Durchlauf, HELPER_INTERVAL, HELPER_MIN_GAP und HELPER_HEARTBEAT setzen Pause, Mindestabstand und
# Abstand der Lebenszeichen (Sekunden).

set -u
umask 077

HELPER_VERSION=2
IN_DIR=${HELPER_IN:-/spool/in}
OUT_DIR=${HELPER_OUT:-/spool/out}
CONF_DIR=${HELPER_CONF_DIR:-/etc/crowdsec}
STATE_DIR=${HELPER_STATE_DIR:-/var/lib/crowdsec/data/npmplus-helper}
TMP_BASE=${HELPER_TMP:-/tmp}
INTERVAL=${HELPER_INTERVAL:-5}
MIN_GAP=${HELPER_MIN_GAP:-60} # Mindestabstand zwischen zwei Abgleichen bzw. zwei Neuladungen von crowdsec
RECHECK=300                   # Abgleich auch ohne Änderung (abgelaufene Einträge, Änderungen per cscli)
HEARTBEAT=${HELPER_HEARTBEAT:-30} # status.json spätestens nach so vielen Sekunden neu schreiben
READ_TIMEOUT=5
LIST=npmplus
LIST_DESCRIPTION="managed by NPMplus"
BODY_NAME=npmplus/body-limit
BODY_FILE=$CONF_DIR/appsec-configs/npmplus-body-limit.yaml
PROBE_NAME=npmplus/body-limit-probe
PROBE_FILE=$CONF_DIR/appsec-configs/npmplus-body-limit-probe.yaml
MAX_FILE_BYTES=262144
MAX_LINE=1100
MAX_ITEMS=500
MAX_LINES=$((MAX_ITEMS + 3)) # Kopf, revision, end
MAX_INVALID=20               # mehr ungültige Zeilen: Datei als Ganzes ablehnen
MIN_BODY=1048576             # 1 MiB
MAX_BODY=1073741824          # 1 GiB
MAX_EPOCH=4102444800         # 01.01.2100
TAB=$(printf '\t')

case $INTERVAL in '' | *[!0-9]* | 0) INTERVAL=5 ;; esac
case $MIN_GAP in '' | *[!0-9]*) MIN_GAP=60 ;; esac
case $HEARTBEAT in '' | *[!0-9]* | 0) HEARTBEAT=30 ;; esac

# Ausgabe auf stderr (docker logs crowdsec-helper), stdout ist in Schleifen oft umgeleitet
log() { printf '%s crowdsec-helper: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >&2; }

# Nur unkritische Zeichen, keine Anführungszeichen oder Backslashes: Ergebnis passt ohne Escaping in einen JSON-String.
sanitize() { printf '%s' "$1" | tr -cd 'A-Za-z0-9 ._,:;/()=+@#-' | cut -c1-200; }

is_uint() {
    case $1 in '' | *[!0-9]* | 0?*) return 1 ;; esac
    [ ${#1} -le 10 ]
}

valid_ipv4() {
    _ip=$1
    case $_ip in '' | *[!0-9.]* | .* | *. | *..*) return 1 ;; esac
    [ ${#_ip} -le 15 ] || return 1
    _n=0
    _rest=$_ip
    while :; do
        _o=${_rest%%.*}
        case $_o in '' | 0?*) return 1 ;; esac
        [ ${#_o} -le 3 ] && [ "$_o" -le 255 ] || return 1
        _n=$((_n + 1))
        [ "$_rest" = "$_o" ] && break
        _rest=${_rest#*.}
    done
    [ "$_n" -eq 4 ]
}

# Nur hexadezimale Schreibweise in Kleinbuchstaben (so normalisiert NPMplus), höchstens ein „::“.
valid_ipv6() {
    _ip=$1
    case $_ip in '' | *[!0-9a-f:]* | *:::*) return 1 ;; esac
    [ ${#_ip} -le 39 ] || return 1
    _dbl=0
    case $_ip in
        *::*)
            _dbl=1
            case ${_ip#*::} in *::*) return 1 ;; esac
            ;;
    esac
    case $_ip in :[!:]* | *[!:]:) return 1 ;; esac
    _n=0
    _rest=$_ip
    while :; do
        _g=${_rest%%:*}
        if [ -n "$_g" ]; then
            [ ${#_g} -le 4 ] || return 1
            _n=$((_n + 1))
        fi
        [ "$_rest" = "$_g" ] && break
        _rest=${_rest#*:}
    done
    if [ "$_dbl" -eq 1 ]; then [ "$_n" -le 7 ]; else [ "$_n" -eq 8 ]; fi
}

# valid_value WERT [strict] – IPv4/IPv6-Adresse oder CIDR-Bereich; strict: Bereiche höchstens /16 (IPv4) bzw. /32 (IPv6)
valid_value() {
    _v=$1
    [ ${#_v} -le 43 ] || return 1
    case $_v in
        */*)
            _addr=${_v%%/*}
            _pfx=${_v#*/}
            case $_pfx in '' | *[!0-9]* | 0?*) return 1 ;; esac
            [ ${#_pfx} -le 3 ] || return 1
            ;;
        *)
            _addr=$_v
            _pfx=
            ;;
    esac
    if valid_ipv4 "$_addr"; then
        _max=32 _min=16
    elif valid_ipv6 "$_addr"; then
        _max=128 _min=32
    else
        return 1
    fi
    [ -n "$_pfx" ] || return 0
    [ "$_pfx" -le "$_max" ] || return 1
    [ "${2:-}" = strict ] || return 0
    [ "$_pfx" -ge "$_min" ]
}

# Beschreibung: eine Zeile ohne Steuerzeichen, höchstens 1024 Byte (NPMplus erlaubt 255 Zeichen)
valid_description() {
    [ ${#1} -le 1024 ] || return 1
    case $1 in *[[:cntrl:]]*) return 1 ;; esac
    return 0
}

valid_revision() {
    case $1 in '' | *[!0-9a-f]*) return 1 ;; esac
    [ ${#1} -eq 16 ]
}

valid_body() {
    is_uint "$1" && [ "$1" -ge "$MIN_BODY" ] && [ "$1" -le "$MAX_BODY" ] || return 1
    case $2 in drop | partial | allow) return 0 ;; esac
    return 1
}

# safe_copy NAME ZIEL – 0 kopiert, 1 fehlt, 2 abgelehnt (Symlink, keine normale Datei, zu groß, Lesen hängt)
# head öffnet die Datei selbst, so bricht timeout auch ein Öffnen ab, das nie zurückkehrt (z. B. FIFO).
safe_copy() {
    _src=$IN_DIR/$1
    [ -L "$_src" ] && return 2
    [ -e "$_src" ] || return 1
    [ -f "$_src" ] || return 2
    timeout "$READ_TIMEOUT" head -c $((MAX_FILE_BYTES + 1)) "$_src" > "$2" 2> /dev/null < /dev/null || return 2
    [ -L "$_src" ] && return 2
    [ "$(wc -c < "$2")" -le "$MAX_FILE_BYTES" ] || return 2
    return 0
}

# write_file DATEI – stdin über eine neue Datei im selben Verzeichnis an ihren Platz (nur in eigenen Verzeichnissen)
write_file() {
    _wf_dir=$(dirname "$1")
    _wf_tmp=$(mktemp "$_wf_dir/.npmplus-helper.XXXXXX") || return 1
    if cat > "$_wf_tmp" && chmod 0644 "$_wf_tmp" && mv -fT "$_wf_tmp" "$1"; then
        return 0
    fi
    rm -f "$_wf_tmp"
    return 1
}

# cs ARG... – cscli ohne stdin, Ausgabe in $WORK/out und $WORK/err
cs() { cscli "$@" < /dev/null > "$WORK/out" 2> "$WORK/err"; }

cs_error() {
    _m=$(grep -v 'level=warning' "$WORK/err" | grep -v '^[[:space:]]*$' | tail -n 1)
    [ -n "$_m" ] || _m=$(tail -n 1 "$WORK/out")
    sanitize "${_m:-cscli failed}"
}

# ---------------------------------------------------------------------------------------------------------------
# Allowlist „npmplus“
# ---------------------------------------------------------------------------------------------------------------
AL_STATE=idle AL_MESSAGE="" AL_REVISION="" AL_LAST=0 AL_FAILED=0

# item_json value state [message] (message aus cscli, wird bereinigt); line_json zeile message (feste Texte)
item_json() { printf '{"value":"%s","state":"%s","message":"%s"}\n' "$1" "$2" "$(sanitize "${3:-}")" >> "$WORK/items"; }
line_json() {
    printf '{"line":%s,"state":"invalid","message":"%s"}\n' "$1" "$2" >> "$WORK/items"
    _invalid=$((_invalid + 1))
}

# Liest $WORK/allowlist.cur, schreibt gültige Einträge nach $WORK/want (Wert TAB Ablauf TAB Beschreibung).
# Rückgabe 1: Datei als Ganzes ungültig (Kopf, Ende, zu viele Zeilen oder zu viele ungültige Zeilen)
parse_allowlist() {
    : > "$WORK/want"
    : > "$WORK/want.values"
    AL_REVISION=""
    _ln=0 _count=0 _ended=0 _invalid=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        _ln=$((_ln + 1))
        [ "$_ln" -le "$MAX_LINES" ] && [ "$_invalid" -le "$MAX_INVALID" ] || return 1
        if [ "$_ln" -eq 1 ]; then
            [ "$_line" = "npmplus-crowdsec-desired 1 allowlist" ] || return 1
            continue
        fi
        [ "$_ended" -eq 0 ] || return 1
        if [ ${#_line} -gt "$MAX_LINE" ]; then
            line_json "$_ln" "line too long"
            continue
        fi
        case $_line in
            "revision "*)
                _rev=${_line#revision }
                valid_revision "$_rev" || return 1
                AL_REVISION=$_rev
                ;;
            end) _ended=1 ;;
            item"$TAB"*"$TAB"*"$TAB"*)
                _rest=${_line#item"$TAB"}
                _value=${_rest%%"$TAB"*}
                _rest=${_rest#*"$TAB"}
                _exp=${_rest%%"$TAB"*}
                _desc=${_rest#*"$TAB"}
                if ! valid_value "$_value" strict; then
                    line_json "$_ln" "invalid value or range too large"
                elif ! is_uint "$_exp"; then
                    line_json "$_ln" "invalid expiration"
                elif [ "$_exp" != 0 ] && { [ "$_exp" -lt 1000000000 ] || [ "$_exp" -gt "$MAX_EPOCH" ]; }; then
                    line_json "$_ln" "invalid expiration"
                elif ! valid_description "$_desc"; then
                    line_json "$_ln" "invalid description"
                elif grep -q -x -F -e "$_value" "$WORK/want.values"; then
                    line_json "$_ln" "duplicate value"
                elif [ "$_count" -ge "$MAX_ITEMS" ]; then
                    line_json "$_ln" "too many entries"
                else
                    printf '%s\t%s\t%s\n' "$_value" "$_exp" "$_desc" >> "$WORK/want"
                    printf '%s\n' "$_value" >> "$WORK/want.values"
                    _count=$((_count + 1))
                fi
                ;;
            *) line_json "$_ln" "unknown line" ;;
        esac
    done < "$WORK/allowlist.cur"
    [ "$_invalid" -le "$MAX_INVALID" ] && [ "$_ended" -eq 1 ] && [ -n "$AL_REVISION" ]
}

# Werte der Allowlist laut LAPI nach $WORK/actual; Rückgabe 2 = Allowlist gibt es nicht
read_actual() {
    : > "$WORK/actual"
    if ! cs allowlists list -o json; then
        AL_MESSAGE="cannot list allowlists: $(cs_error)"
        return 1
    fi
    if ! yq -p json '.[] | .name' < "$WORK/out" > "$WORK/names" 2> /dev/null; then
        AL_MESSAGE="cannot parse the allowlists (yq)"
        return 1
    fi
    grep -q -x -F -e "$LIST" "$WORK/names" || return 2
    if ! cs allowlists inspect "$LIST" -o json; then
        AL_MESSAGE="cannot read allowlist $LIST: $(cs_error)"
        return 1
    fi
    if ! yq -p json '.items // [] | .[] | .value' < "$WORK/out" > "$WORK/actual.raw" 2> /dev/null; then
        AL_MESSAGE="cannot parse allowlist $LIST (yq)"
        return 1
    fi
    # Werte aus der LAPI nur mit unkritischen Zeichen weiterverwenden
    while IFS= read -r _v; do
        case $_v in '' | *[!0-9A-Fa-f.:/]*) ;; *) [ ${#_v} -le 64 ] && printf '%s\n' "$_v" ;; esac
    done < "$WORK/actual.raw" > "$WORK/actual"
    return 0
}

fingerprint() { printf '%s\t%s' "$1" "$2" | cksum | cut -d' ' -f1-2 | tr ' ' '-'; }

# Hat der Helfer den Wert selbst angelegt? ($STATE_DIR/applied: Wert TAB Fingerabdruck)
is_ours() { cut -f1 "$STATE_DIR/applied" 2> /dev/null | grep -q -x -F -e "$1"; }

reconcile_allowlist() {
    : > "$WORK/items"
    AL_LAST=$NOW
    AL_MESSAGE=""
    if ! parse_allowlist; then
        AL_STATE=error AL_MESSAGE="desired state file is invalid, incomplete or has too many invalid lines" AL_REVISION=""
        : > "$WORK/items"
        return 0
    fi

    read_actual
    _rc=$?
    if [ "$_rc" -eq 1 ]; then
        AL_STATE=error
        return 1
    fi
    if [ "$_rc" -eq 2 ]; then
        if [ ! -s "$WORK/want" ]; then
            AL_STATE=ok
            return 0
        fi
        if ! cs allowlists create "$LIST" --description="$LIST_DESCRIPTION"; then
            AL_STATE=error AL_MESSAGE="cannot create allowlist $LIST: $(cs_error)"
            return 1
        fi
        log "allowlist: created $LIST"
    fi

    _errors=0
    : > "$WORK/applied.new"
    : > "$WORK/keep"
    while IFS="$TAB" read -r _value _exp _desc; do
        if [ "$_exp" != 0 ] && [ "$_exp" -le "$NOW" ]; then
            item_json "$_value" expired
            continue
        fi
        printf '%s\n' "$_value" >> "$WORK/keep"
        _fp=$(fingerprint "$_exp" "$_desc")
        if grep -q -x -F -e "$_value" "$WORK/actual" &&
            grep -q -x -F -e "$_value$TAB$_fp" "$STATE_DIR/applied" 2> /dev/null; then
            printf '%s\t%s\n' "$_value" "$_fp" >> "$WORK/applied.new"
            item_json "$_value" ok
            continue
        fi
        # vorher entfernen: abgelaufene oder geänderte Einträge ignoriert „add“ sonst („already in allowlist“)
        if ! cs allowlists remove "$LIST" -- "$_value"; then
            item_json "$_value" error "$(cs_error)"
            _errors=$((_errors + 1))
            continue
        fi
        if [ "$_exp" = 0 ]; then
            set -- --comment="$_desc"
        else
            set -- --comment="$_desc" --expiration="$((_exp - NOW))s"
        fi
        if ! cs allowlists add "$LIST" "$@" -- "$_value"; then
            item_json "$_value" error "$(cs_error)"
            _errors=$((_errors + 1))
            continue
        fi
        printf '%s\t%s\n' "$_value" "$_fp" >> "$WORK/applied.new"
        item_json "$_value" ok
        log "allowlist: added $_value"
    done < "$WORK/want"

    # nicht mehr gewünschte und abgelaufene Einträge entfernen, aber nur die eigenen: von Hand mit cscli ergänzte bleiben
    while IFS= read -r _value; do
        grep -q -x -F -e "$_value" "$WORK/keep" && continue
        is_ours "$_value" || continue
        if cs allowlists remove "$LIST" -- "$_value"; then
            log "allowlist: removed $_value"
        else
            AL_MESSAGE="could not remove $_value: $(cs_error)"
            log "allowlist: $AL_MESSAGE"
            # bleibt als eigener Eintrag vermerkt, damit es beim nächsten Lauf erneut versucht wird
            printf '%s\t-\n' "$_value" >> "$WORK/applied.new"
            _errors=$((_errors + 1))
        fi
    done < "$WORK/actual"

    if ! write_file "$STATE_DIR/applied" < "$WORK/applied.new"; then
        AL_STATE=error AL_MESSAGE="cannot write $STATE_DIR/applied"
        return 1
    fi
    if [ "$_errors" -gt 0 ]; then
        AL_STATE=error
        [ -n "$AL_MESSAGE" ] || AL_MESSAGE="some entries could not be applied"
        return 1
    fi
    if grep -q '"state":"invalid"' "$WORK/items"; then
        AL_STATE=error AL_MESSAGE="some lines of the desired state were rejected"
    else
        AL_STATE=ok
    fi
    return 0
}

# ---------------------------------------------------------------------------------------------------------------
# AppSec-Body-Limit (appsec-config npmplus/body-limit)
# ---------------------------------------------------------------------------------------------------------------
AS_STATE=idle AS_MESSAGE="" AS_REVISION="" AS_LAST=0 AS_FAILED=0 AS_RELOADED=0 AS_RELOAD_PENDING=0 AS_SHOWN=0
AS_SIZE="" AS_ACTION="" AS_REFERENCED=false

# body_config BYTES AKTION [NAME]
body_config() {
    cat << EOF
# Erzeugt vom CrowdSec-Helfer von NPMplus · Hotte (crowdsec-helper.sh), Änderungen werden überschrieben.
# Einstellen in NPMplus › CrowdSec › Einstellungen › AppSec-Body-Limit, gilt für alle Hosts.
# Steht in der AppSec-Acquisition (acquis.d/npmplus.yaml) als erster Eintrag von appsec_configs.
name: ${3:-$BODY_NAME}
on_load:
  - apply:
      - SetMaxBodySize($1)
      - SetBodySizeExceededAction("$2")
EOF
}

# Werte der vorhandenen Datei, nur wenn sie dem eigenen Aufbau entspricht
read_body_file() {
    AS_SIZE="" AS_ACTION=""
    [ -f "$BODY_FILE" ] && [ ! -L "$BODY_FILE" ] || return 0
    _s=$(sed -n 's/^ *- SetMaxBodySize(\([0-9]*\))$/\1/p' "$BODY_FILE" | head -n 1)
    _a=$(sed -n 's/^ *- SetBodySizeExceededAction("\([a-z]*\)")$/\1/p' "$BODY_FILE" | head -n 1)
    is_uint "$_s" && AS_SIZE=$_s
    case $_a in drop | partial | allow) AS_ACTION=$_a ;; esac
}

check_referenced() {
    AS_REFERENCED=false
    for _f in "$CONF_DIR/acquis.yaml" "$CONF_DIR"/acquis.d/*.yaml "$CONF_DIR"/acquis.d/*.yml; do
        [ -f "$_f" ] || continue
        if grep -q -E "^[[:space:]]*-[[:space:]]*[\"']?${BODY_NAME}[\"']?[[:space:]]*(#.*)?$" "$_f"; then
            AS_REFERENCED=true
            return 0
        fi
    done
}

# test_body_config BYTES AKTION – prüft die Werte mit „crowdsec -t“, ohne die bereitgestellte Datei anzufassen:
# als eigene appsec-config (npmplus/body-limit-probe) in einer eigenen Acquisition und einer Kopie der config.yaml.
# Eine nicht referenzierte appsec-config stört crowdsec nicht. Fehlermeldung in TEST_MESSAGE.
test_body_config() {
    TEST_MESSAGE=""
    _td=$(mktemp -d "$TMP_BASE/npmplus-probe.XXXXXX") || {
        TEST_MESSAGE="cannot create a temporary directory"
        return 1
    }
    mkdir "$_td/acquis.d"
    printf 'source: appsec\nname: npmplus-probe\nlisten_addr: 127.0.0.1:7499\nappsec_configs:\n  - %s\nlabels:\n  type: appsec\n' \
        "$PROBE_NAME" > "$_td/acquis.yaml"
    _rc=0
    if ! PROBE_DIR=$_td yq '.crowdsec_service.acquisition_path = strenv(PROBE_DIR) + "/acquis.yaml"
        | .crowdsec_service.acquisition_dir = strenv(PROBE_DIR) + "/acquis.d"' "$CONF_DIR/config.yaml" \
        > "$_td/config.yaml" 2> /dev/null; then
        TEST_MESSAGE="cannot prepare the config test (yq)"
        _rc=1
    elif ! body_config "$1" "$2" "$PROBE_NAME" | write_file "$PROBE_FILE"; then
        TEST_MESSAGE="cannot write $PROBE_FILE"
        _rc=1
    elif ! timeout 180 crowdsec -c "$_td/config.yaml" -t < /dev/null > "$_td/test.log" 2>&1; then
        TEST_MESSAGE="crowdsec rejected the config: $(sanitize "$(grep -E 'level=(fatal|error)' "$_td/test.log" | tail -n 1)")"
        _rc=1
    fi
    rm -f "$PROBE_FILE"
    rm -rf "$_td"
    return "$_rc"
}

crowdsec_pid() {
    _pids=$(pidof crowdsec 2> /dev/null) || return 1
    # shellcheck disable=SC2086 # Aufteilen in einzelne PIDs ist gewollt
    set -- $_pids
    [ "$#" -eq 1 ] || return 1
    case $1 in '' | *[!0-9]*) return 1 ;; esac
    printf '%s' "$1"
}

reload_crowdsec() {
    if ! _pid=$(crowdsec_pid); then
        AS_STATE=error AS_MESSAGE="crowdsec process not found (helper needs pid: service:crowdsec), reload pending"
        AS_RELOAD_PENDING=1
        return 1
    fi
    if ! kill -HUP "$_pid" 2> /dev/null; then
        AS_STATE=error AS_MESSAGE="could not send SIGHUP to crowdsec, reload pending"
        AS_RELOAD_PENDING=1
        return 1
    fi
    AS_RELOAD_PENDING=0
    AS_RELOADED=$NOW
    log "appsec: crowdsec reloaded (SIGHUP)"
    return 0
}

parse_appsec() {
    AS_REVISION="" _size="" _action="" _ln=0 _ended=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        _ln=$((_ln + 1))
        [ "$_ln" -le 6 ] || return 1
        if [ "$_ln" -eq 1 ]; then
            [ "$_line" = "npmplus-crowdsec-desired 1 appsec" ] || return 1
            continue
        fi
        [ "$_ended" -eq 0 ] || return 1
        case $_line in
            "revision "*)
                AS_REVISION=${_line#revision }
                valid_revision "$AS_REVISION" || return 1
                ;;
            "max_body_size "*) _size=${_line#max_body_size } ;;
            "body_size_exceeded_action "*) _action=${_line#body_size_exceeded_action } ;;
            end) _ended=1 ;;
            *) return 1 ;;
        esac
    done < "$WORK/appsec.cur"
    [ "$_ended" -eq 1 ] && [ -n "$AS_REVISION" ] && valid_body "$_size" "$_action" || return 1
    WANT_SIZE=$_size WANT_ACTION=$_action
}

# Rückgabe 1 nur bei vorübergehenden Fehlern (erneuter Versuch), sonst gilt das Ergebnis bis zur nächsten Änderung
reconcile_appsec() {
    AS_LAST=$NOW
    AS_MESSAGE=""
    check_referenced
    if ! parse_appsec; then
        AS_STATE=error AS_MESSAGE="desired state file is invalid" AS_REVISION=""
        read_body_file
        return 0
    fi
    body_config "$WANT_SIZE" "$WANT_ACTION" > "$WORK/body.new"
    if [ -f "$BODY_FILE" ] && [ ! -L "$BODY_FILE" ] && cmp -s "$WORK/body.new" "$BODY_FILE"; then
        read_body_file
        AS_STATE=ok
        if [ "$AS_RELOAD_PENDING" -eq 1 ]; then reload_crowdsec || return 1; fi
        return 0
    fi
    # erst prüfen, dann bereitstellen: eine abgelehnte Konfiguration würde crowdsec beim Neuladen beenden
    if ! test_body_config "$WANT_SIZE" "$WANT_ACTION"; then
        read_body_file
        AS_STATE=error AS_MESSAGE="$TEST_MESSAGE (old config kept)"
        log "appsec: config test failed, old config kept"
        return 0
    fi
    if ! write_file "$BODY_FILE" < "$WORK/body.new"; then
        read_body_file
        AS_STATE=error AS_MESSAGE="cannot write $BODY_FILE"
        return 1
    fi
    read_body_file
    log "appsec: body limit $WANT_SIZE bytes, action $WANT_ACTION"
    AS_STATE=ok
    if [ "$AS_REFERENCED" != true ]; then
        AS_STATE=error
        AS_MESSAGE="$BODY_NAME is not listed in appsec_configs of the AppSec acquisition, run install.sh --update"
        return 0
    fi
    reload_crowdsec
}

# ---------------------------------------------------------------------------------------------------------------
# Status und Ablauf
# ---------------------------------------------------------------------------------------------------------------
write_status() {
    {
        printf '{"format":1,"helper_version":"%s","started_at":%s,"heartbeat":%s,' "$HELPER_VERSION" "$STARTED" "$NOW"
        printf '"allowlist":{"name":"%s","state":"%s","message":"%s","revision":"%s","last_run":%s,"items":[' \
            "$LIST" "$AL_STATE" "$(sanitize "$AL_MESSAGE")" "$AL_REVISION" "$AL_LAST"
        [ -s "$STATE_DIR/items.json" ] && sed '$!s/$/,/' "$STATE_DIR/items.json" | tr -d '\n'
        printf ']},"appsec":{"state":"%s","message":"%s","revision":"%s","last_run":%s,' \
            "$AS_STATE" "$(sanitize "$AS_MESSAGE")" "$AS_REVISION" "$AS_LAST"
        printf '"max_body_size":%s,"action":%s,"referenced":%s,"reloaded_at":%s}}\n' \
            "${AS_SIZE:-null}" "$([ -n "$AS_ACTION" ] && printf '"%s"' "$AS_ACTION" || printf null)" \
            "$AS_REFERENCED" "$AS_RELOADED"
    } > "$WORK/status.json"
    # out/ beschreibt nur der Helfer; NPMplus hat es schreibgeschützt eingebunden
    if write_file "$OUT_DIR/status.json" < "$WORK/status.json"; then
        LAST_STATUS=$NOW
    else
        log "cannot write the status file in $OUT_DIR"
    fi
}

# step_due NAME FEHLGESCHLAGEN LETZTER_LAUF – muss der Soll-Zustand (neu) umgesetzt werden? 0 = ja
# Änderungen werden höchstens alle MIN_GAP Sekunden umgesetzt (dazwischen gesammelt), Fehler ebenso oft wiederholt.
step_due() {
    _name=$1 _failed=$2 _last=$3
    safe_copy "$_name.desired" "$WORK/$_name.cur"
    _rc=$?
    if [ "$_rc" -eq 1 ]; then
        rm -f "$STATE_DIR/$_name.done"
        return 1
    fi
    [ "$_rc" -eq 2 ] && printf 'rejected\n' > "$WORK/$_name.cur"
    [ $((NOW - _last)) -ge "$MIN_GAP" ] || return 1
    [ "$_failed" -eq 1 ] && return 0
    [ $((NOW - _last)) -ge "$RECHECK" ] && return 0
    ! cmp -s "$WORK/$_name.cur" "$STATE_DIR/$_name.done"
}

run_once() {
    NOW=$(date +%s)
    rm -rf "$WORK"
    mkdir -p "$WORK"
    _changed=0

    if step_due allowlist "$AL_FAILED" "$AL_LAST"; then
        if reconcile_allowlist; then AL_FAILED=0; else AL_FAILED=1; fi
        cp "$WORK/items" "$STATE_DIR/items.json"
        cp "$WORK/allowlist.cur" "$STATE_DIR/allowlist.done"
        _changed=1
    elif [ ! -f "$STATE_DIR/allowlist.done" ] && [ "$AL_STATE" != idle ]; then
        AL_STATE=idle AL_MESSAGE="" AL_REVISION=""
        : > "$STATE_DIR/items.json"
        _changed=1
    fi

    if step_due appsec "$AS_FAILED" "$AS_LAST"; then
        if reconcile_appsec; then AS_FAILED=0; else AS_FAILED=1; fi
        cp "$WORK/appsec.cur" "$STATE_DIR/appsec.done"
        _changed=1
    elif [ ! -f "$STATE_DIR/appsec.done" ] && [ $((NOW - AS_SHOWN)) -ge "$HEARTBEAT" ]; then
        # ohne Vorgabe aus NPMplus: nur anzeigen, was gerade gilt (AS_LAST bleibt, sonst würde der Mindestabstand nie
        # erreicht)
        AS_STATE=idle AS_MESSAGE="" AS_REVISION="" AS_SHOWN=$NOW
        check_referenced
        read_body_file
        _changed=1
    fi

    if [ "$_changed" -eq 1 ] || [ $((NOW - LAST_STATUS)) -ge "$HEARTBEAT" ]; then
        write_status
    fi
}

probe() {
    if ! valid_body "${1:-}" "${2:-}"; then
        log "probe: invalid values"
        exit 2
    fi
    if test_body_config "$1" "$2"; then
        exit 0
    fi
    log "probe: $TEST_MESSAGE"
    exit 1
}

main() {
    for _d in "$IN_DIR" "$OUT_DIR"; do
        if [ ! -d "$_d" ] || [ -L "$_d" ]; then
            log "directory $_d is missing"
            exit 1
        fi
    done
    mkdir -p "$STATE_DIR" || exit 1
    chmod 0700 "$STATE_DIR"
    WORK=$TMP_BASE/npmplus-helper-work
    # Zustand der letzten Läufe gilt nicht über einen Neustart hinweg (nur „applied“ bleibt)
    rm -f "$STATE_DIR/allowlist.done" "$STATE_DIR/appsec.done" "$STATE_DIR/items.json" "$PROBE_FILE"
    : > "$STATE_DIR/items.json"
    STARTED=$(date +%s)
    LAST_STATUS=0
    for _tool in cscli yq crowdsec pidof timeout; do
        command -v "$_tool" > /dev/null 2>&1 || log "warning: $_tool not found"
    done
    log "version $HELPER_VERSION started"
    trap 'log "stopped"; exit 0' TERM INT
    while :; do
        run_once
        [ "${HELPER_ONCE:-0}" = 1 ] && break
        sleep "$INTERVAL" &
        wait $!
    done
}

if [ "${1:-}" = probe ]; then
    probe "${2:-}" "${3:-}"
fi
main "$@"
CROWDSEC_HELPER_EOF
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
    for opt in UNIFI_GUARD:unifi-api-guard CROWDSEC:crowdsec CROWDSEC:crowdsec-helper; do
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

# jq wird zum Lesen vorhandener compose-Dateien gebraucht – auch im Probelauf wirklich installieren (ändert sonst nichts).
ensure_jq() {
    have jq && return 0
    if [[ "$DRY_RUN" == 1 ]]; then
        [[ $EUID -eq 0 ]] || die "jq fehlt; für den Probelauf mit vorhandener Installation jq installieren oder als root ausführen."
        info "Installiere jq auch im Probelauf (nur zum Lesen der vorhandenen compose.yaml)" >&2
        local DRY_RUN=0 # gilt nur für diesen Aufruf (dynamischer Gültigkeitsbereich)
        pkg_install jq >&2
    else
        pkg_install jq >&2
    fi
    have jq || die "jq fehlt (wird zum Auslesen der vorhandenen compose.yaml gebraucht)."
}

# compose_json Datei – normalisierte Konfiguration (docker compose config, ohne Docker-Dienst möglich) als JSON
compose_json() {
    local file=$1 err
    if ! have docker || ! docker compose version > /dev/null 2>&1; then
        die "$file kann ohne „docker compose“ nicht ausgelesen werden."
    fi
    ensure_jq
    err=$(mktemp)
    if ! docker compose -f "$file" --project-directory "$(dirname "$file")" config --format json 2> "$err"; then
        cat "$err" >&2
        rm -f "$err"
        die "docker compose config für $file ist fehlgeschlagen (Meldung oben)."
    fi
    rm -f "$err"
}

# Liest eine vorhandene compose-Datei nach OLD_JSON.
load_old_json() {
    ensure_jq
    OLD_JSON=$(compose_json "$1")
    jq -e 'type == "object"' <<< "$OLD_JSON" > /dev/null 2>&1 || die "docker compose config für $1 lieferte kein JSON."
}

# Weitere Dienste einer compose-Konfiguration (alles außer NPMplus, Guard, CrowdSec) unverändert, dazu die von ihnen
# benutzten Volumes/Netze/Secrets/Configs. „default“-Netz nur, wenn es mehr als Name/leere Felder festlegt (sonst
# entsteht es ohnehin, als npmplus_default). Ergebnis: {services, volumes, networks, secrets, configs}, leere Teile weggelassen.
# shellcheck disable=SC2016 # jq-Variablen
readonly EXTRAS_JQ='
def pick($m; $names): ($m // {}) | with_entries(select(.key as $k | $names | index($k)));
. as $root
| ([.services | to_entries[] | select(.value.container_name == "npmplus") | .key][0]
    // (if .services.npmplus then "npmplus" else null end)) as $s
| ([.services | to_entries[] | select(.value.container_name == "unifi-api-guard" or .key == "unifi-api-guard") | .key][0]) as $g
| ([.services | to_entries[] | select(.key != "crowdsec-helper" and .value.container_name != "crowdsec-helper")
    | select(.value.container_name == "crowdsec" or .key == "crowdsec"
    or ((.value.image // "") | test("crowdsecurity/crowdsec"))) | .key][0]) as $c
| (.services | with_entries(select(.key != $s and .key != $g and .key != $c and .key != "crowdsec-helper"
    and .value.container_name != "crowdsec-helper"))
    | map_values(with_entries(select(.value != null)))) as $svcs
| ([$svcs[] | (.volumes // [])[] | select(.type == "volume" and .source != null) | .source] | unique) as $vols
| ([$svcs[] | (.networks // {}) | keys[]] | unique) as $nets
| ([$svcs[] | (.secrets // [])[] | .source] | unique) as $secs
| ([$svcs[] | (.configs // [])[] | .source] | unique) as $cfgs
| {services: $svcs,
   volumes: pick($root.volumes; $vols),
   networks: (pick($root.networks; $nets) | with_entries(select(.key != "default"
       or (.value | del(.name) | with_entries(select(.value != null and .value != {} and .value != [])) | length > 0)))),
   secrets: pick($root.secrets; $secs),
   configs: pick($root.configs; $cfgs)}
| with_entries(select(.value | length > 0))'

# Einstellungen der eigenen compose.yaml, die ein erneuter Lauf übernimmt: die Dienste dieses Installers (Umgebung,
# Ports, Volumes, weitere Schlüssel; die Vorlage setzt nur ihre eigenen Schlüssel) und die oberste Ebene.
# shellcheck disable=SC2016 # jq-Variablen
readonly CARRY_JQ='
{services: (.services // {} | with_entries(select(.key as $k
    | ["npmplus", "unifi-api-guard", "crowdsec", "crowdsec-helper"] | index($k)))),
 top: (del(.name, .services)
    | if .networks then .networks |= with_entries(select(.key != "default"
        or (.value | del(.name) | with_entries(select(.value != null and .value != {} and .value != [])) | length > 0)))
      else . end
    | with_entries(select(.value != {})))}'

# Was aus der bisherigen eigenen compose.yaml verloren ginge oder geändert würde (Pfade ohne Werte, wegen Secrets).
# Listen werden zu Maps (Volumes nach Ziel, Ports nach Adresse), damit eine andere Reihenfolge nicht zählt.
# shellcheck disable=SC2016 # jq-Variablen
readonly LOSS_JQ='
def norm: (.services // {}) |= with_entries(.value |= (
      (if .volumes then .volumes |= (map({key: .target, value: (del(.bind.create_host_path))}) | from_entries) else . end)
    | (if .ports then .ports |= (map({key: "\(.host_ip // "*"):\(.published // "")>\(.target)/\(.protocol // "tcp")", value: .})
        | from_entries) else . end)
    | reduce ("cap_add", "cap_drop", "security_opt", "dns", "tmpfs") as $k (.;
        if (.[$k] | type) == "array" then .[$k] |= (map({key: tostring, value: true}) | from_entries) else . end)))
    | del(.name);
($old | norm) as $o | ($new | norm) as $n
| [$o | paths(scalars)][]
| select(.[0] != "services" or ($n.services[.[1]] != null))
| select(. as $p | ($n | getpath($p)) != ($o | getpath($p)))
| select(. as $p | $allowed | any(. as $a | $p[0:($a | length)] == $a) | not)
| map(tostring) | join(" › ")'

# extras_from_json JSON – gibt EXTRAS_JQ-Ergebnis kompakt aus (leer, wenn keine weiteren Dienste)
extras_from_json() {
    jq -c "$EXTRAS_JQ"' | select(.services)' <<< "$1"
}

# merge_extras A B – B ergänzt A; bei gleichem Namen bleibt der Eintrag aus A
merge_extras() {
    local a=${1:-} b=${2:-}
    [[ -n "$a" ]] || a='{}'
    [[ -n "$b" ]] || b='{}'
    jq -cn --argjson a "$a" --argjson b "$b" '
        reduce ("services", "volumes", "networks", "secrets", "configs") as $k ({};
            .[$k] = (($b[$k] // {}) + ($a[$k] // {})))
        | with_entries(select(.value | length > 0))'
}

set_extra_names() {
    local out=""
    [[ -n "$EXTRA_JSON" ]] && out=$(jq -r '.services // {} | keys[]' <<< "$EXTRA_JSON")
    if [[ -n "$out" ]]; then mapfile -t EXTRA_SVC_NAMES <<< "$out"; else EXTRA_SVC_NAMES=(); fi
}

# Entfernt weitere Dienste, deren Name oder container_name mit einem erzeugten Dienst kollidiert (nach den Fragen).
filter_extra_services() {
    [[ -n "$EXTRA_JSON" ]] || return 0
    local ours='["npmplus"' clash n
    [[ "$UNIFI_GUARD" == yes ]] && ours+=', "unifi-api-guard"'
    [[ "$CROWDSEC" == yes ]] && ours+=', "crowdsec", "crowdsec-helper"'
    ours+=']'
    clash=$(jq -r --argjson o "$ours" '.services | to_entries[]
        | select((.key as $k | $o | index($k)) or ((.value.container_name // "") as $c | $o | index($c))) | .key' <<< "$EXTRA_JSON")
    for n in $clash; do
        warn "Dienst „$n“ kollidiert mit einem Dienst dieses Installers und wird nicht übernommen."
    done
    if [[ -n "$clash" ]]; then
        EXTRA_JSON=$(jq -c --argjson o "$ours" '.services |= with_entries(select((.key as $k | $o | index($k) | not)
            and ((.value.container_name // "") as $c | $o | index($c) | not)))' <<< "$EXTRA_JSON")
        [[ "$(jq -r '.services | length' <<< "$EXTRA_JSON")" != 0 ]] || EXTRA_JSON=""
    fi
    set_extra_names
}

# IMPORT_FROM=<Datei>: weitere Dienste aus einer anderen compose-Datei in die vorhandene Installation holen
import_services() {
    local file=$1 json imp names n
    [[ -f "$file" ]] || die "IMPORT_FROM=$file: Datei nicht gefunden."
    ensure_jq
    json=$(compose_json "$file")
    jq -e 'type == "object"' <<< "$json" > /dev/null 2>&1 || die "docker compose config für $file lieferte kein JSON."
    imp=$(extras_from_json "$json")
    [[ -n "$imp" ]] || die "IMPORT_FROM=$file enthält keine weiteren Dienste (außer NPMplus, Guard, CrowdSec)."
    names=$(jq -r '.services | keys[]' <<< "$imp")
    for n in $names; do
        if [[ -n "$EXTRA_JSON" ]] && jq -e --arg n "$n" '.services | has($n)' <<< "$EXTRA_JSON" > /dev/null; then
            warn "Dienst „$n“ ist schon vorhanden, bleibt wie er ist."
        else
            IMPORTED_SVCS+=("$n")
        fi
    done
    EXTRA_JSON=$(merge_extras "$EXTRA_JSON" "$imp")
    set_extra_names
    info "Importiere Dienste aus $file: ${IMPORTED_SVCS[*]:-keine neuen}"
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
    jq_array EXTRA_VOLUMES '.services[$s].volumes // [] | .[] | select(.type == "bind" and .target != "/data" and (.target | startswith("'"$NPMPLUS_SPOOL_TARGET"'") | not))
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
    OLD_CROWDSEC_SVC=$(jq_old '[.services | to_entries[] | select(.key != "crowdsec-helper" and .value.container_name != "crowdsec-helper")
        | select(.value.container_name == "crowdsec" or .key == "crowdsec"
        or ((.value.image // "") | test("crowdsecurity/crowdsec"))) | .key][0] // empty')
    OLD_CROWDSEC_PATHS=""
    if [[ -n "$OLD_CROWDSEC_SVC" ]]; then
        OLD_CROWDSEC_PATHS=$(jq_old '[.services[$c].volumes // [] | .[] | select(.target == "/etc/crowdsec" or .target == "/var/lib/crowdsec/data") | "\(.source):\(.target)"] | join(" ")' --arg c "$OLD_CROWDSEC_SVC")
    fi
    EXTRA_JSON=$(extras_from_json "$OLD_JSON")
    set_extra_names
    return 0
}

# Liest die eigene, bereits vorhandene compose.yaml (erneuter Lauf): bisherige Antworten als Vorgabe und alle
# übernommenen bzw. von Hand ergänzten Einträge (Variablen, Bind-Mounts, dns, cap_add) bleiben erhalten.
load_previous() {
    local file=$1 n
    if ! have docker || ! docker compose version > /dev/null 2>&1; then
        warn "Bisherige $file kann nicht ausgelesen werden (docker compose fehlt) – zusätzliche Einträge gehen verloren."
        return 0
    fi
    load_old_json "$file"
    if ! analyze_old_json; then
        OLD_JSON=""
        return 0
    fi
    # LOGROTATE stammte von CrowdSec, wenn CrowdSec aktiv war – dann nicht festschreiben
    [[ -n "$OLD_CROWDSEC_SVC" ]] && OLD_LOGROTATE=""
    # eigene Datei: alle übrigen Einstellungen der Dienste und der obersten Ebene werden übernommen (CARRY_JQ),
    # was trotzdem wegfiele, zeigt review_compose_changes vor dem Schreiben
    CARRY_JSON=$(jq -c "$CARRY_JQ" <<< "$OLD_JSON")
    NOT_CARRIED=()
    if [[ -n "$OLD_GUARD_DATA" && "$OLD_GUARD_DATA" != "$GUARD_DATA" ]]; then
        GUARD_DATA=$OLD_GUARD_DATA
    fi
    if ((${#EXTRA_ENV_NAMES[@]} + ${#EXTRA_VOLUMES[@]} + ${#EXTRA_DNS[@]} + ${#EXTRA_CAPS[@]})); then
        info "Bisherige zusätzliche Einträge bleiben: ${EXTRA_ENV_NAMES[*]:-} (${#EXTRA_VOLUMES[@]} Volume(s), ${#EXTRA_DNS[@]} DNS, ${#EXTRA_CAPS[@]} Capability(s))"
    fi
    for n in "${NOT_CARRIED[@]}"; do
        warn "Nicht übernommen aus $file: $n"
    done
    ((${#EXTRA_SVC_NAMES[@]})) && info "Weitere Dienste bleiben: ${EXTRA_SVC_NAMES[*]}"
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
        if [[ -n "$IMPORT_FROM" ]]; then
            [[ -n "$own" ]] || die "IMPORT_FROM braucht eine vorhandene Installation von NPMplus · Hotte (compose.yaml nicht gefunden)."
            import_services "$IMPORT_FROM"
        fi
        return 0
    fi
    [[ -z "$IMPORT_FROM" ]] || die "IMPORT_FROM geht nicht zusammen mit einer Übernahme – erst übernehmen, dann importieren."

    load_old_json "${cands[0]}"
    OLD_COMPOSE=${cands[0]}
    if ! analyze_old_json; then
        if [[ -n "$cfg" && "$cfg" == "$OLD_COMPOSE" ]]; then
            die "$OLD_COMPOSE enthält keinen Dienst mit container_name „npmplus“."
        fi
        warn "$OLD_COMPOSE enthält keinen NPMplus-Dienst, wird ignoriert."
        OLD_COMPOSE="" OLD_JSON=""
        EXTRA_ENV=() EXTRA_ENV_NAMES=() EXTRA_VOLUMES=() EXTRA_DNS=() EXTRA_CAPS=() NOT_CARRIED=()
        OLD_TZ="" OLD_ACME_EMAIL="" OLD_LOGROTATE="" OLD_GUARD_SVC="" OLD_CROWDSEC_SVC="" EXTRA_JSON="" EXTRA_SVC_NAMES=()
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
    ((${#EXTRA_SVC_NAMES[@]})) && msg+="
  Weitere Dienste (unverändert übernommen): ${EXTRA_SVC_NAMES[*]}"
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
    if [[ -n "$EXTRA_JSON" ]]; then
        local extra
        extra=$(jq -r '.services[].image // empty' <<< "$EXTRA_JSON")
        for img in $extra; do imgs+=("$img"); done
    fi
    info "Lade die neuen Images (alte Installation läuft solange weiter)"
    for img in "${imgs[@]}"; do
        if [[ "$img" == "$NPMPLUS_IMAGE" || "$img" == "$GUARD_IMAGE" || "$img" == "$CROWDSEC_IMAGE" ]]; then
            run_quiet docker pull -q "$img" # Fehler hier: Abbruch, bevor etwas verändert wurde
        elif [[ "$DRY_RUN" == 1 ]]; then
            printf '   [dry-run] docker pull -q %s\n' "$img"
        elif ! docker pull -q "$img" > /dev/null; then
            warn "Image $img ließ sich nicht laden – vorhandenes wird verwendet bzw. beim Start erneut versucht."
        fi
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
    prepare_crowdsec_helper
}

# CrowdSec-Helfer: Skript (immer die Fassung dieses Installers) und Spool-Verzeichnis, vor „compose up“
prepare_crowdsec_helper() {
    HELPER_CHANGED=0
    local owner
    run mkdir -p "$CROWDSEC_HELPER_BIN" "$CROWDSEC_SPOOL_IN" "$CROWDSEC_SPOOL_OUT" "$CROWDSEC_DATA/conf/appsec-configs"
    run chmod 0755 "$CROWDSEC_HELPER_DIR" "$CROWDSEC_HELPER_BIN" "$CROWDSEC_SPOOL_IN" "$CROWDSEC_SPOOL_OUT"
    # in/ gehört demselben Benutzer wie die NPMplus-Daten (mit PUID/PGID nicht root), out/ bleibt root
    if [[ -d "$NPMPLUS_DATA/crowdsec" ]]; then
        owner=$(stat -c '%u:%g' "$NPMPLUS_DATA/crowdsec")
        run chown "$owner" "$CROWDSEC_SPOOL_IN"
    fi
    migrate_helper_spool
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '   [dry-run] %s schreiben (Quelle: deploy/crowdsec-helper.sh)\n' "$CROWDSEC_HELPER_SCRIPT"
        return 0
    fi
    local tmp
    tmp=$(mktemp "$CROWDSEC_HELPER_BIN/.crowdsec-helper.XXXXXX")
    crowdsec_helper_script > "$tmp"
    if [[ -f "$CROWDSEC_HELPER_SCRIPT" ]] && cmp -s "$tmp" "$CROWDSEC_HELPER_SCRIPT"; then
        rm -f "$tmp"
        ok "CrowdSec-Helfer aktuell: $CROWDSEC_HELPER_SCRIPT"
        return 0
    fi
    chmod 0644 "$tmp"
    # neue Datei statt Überschreiben: eine laufende Shell liest ihr Skript stückweise
    mv -f "$tmp" "$CROWDSEC_HELPER_SCRIPT"
    HELPER_CHANGED=1
    ok "CrowdSec-Helfer geschrieben: $CROWDSEC_HELPER_SCRIPT (Soll-Zustand: $CROWDSEC_SPOOL_IN, Status: $CROWDSEC_SPOOL_OUT)"
}

# Erste Fassung des Helfers: ein gemeinsames Spool-Verzeichnis. Den Soll-Zustand schreibt NPMplus beim Start neu, der
# Inhalt wird nur entfernt (Dateien und Symlinks, keine Verzeichnisse), danach das Verzeichnis selbst.
migrate_helper_spool() {
    [[ -d "$CROWDSEC_SPOOL_LEGACY" && ! -L "$CROWDSEC_SPOOL_LEGACY" ]] || return 0
    if [[ "$DRY_RUN" == 1 ]]; then
        printf '   [dry-run] altes Spool-Verzeichnis %s leeren und entfernen\n' "$CROWDSEC_SPOOL_LEGACY"
        return 0
    fi
    find "$CROWDSEC_SPOOL_LEGACY" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -exec rm -f {} +
    if rmdir "$CROWDSEC_SPOOL_LEGACY" 2> /dev/null; then
        ok "Altes Spool-Verzeichnis entfernt: $CROWDSEC_SPOOL_LEGACY (jetzt in/ und out/)"
    else
        warn "$CROWDSEC_SPOOL_LEGACY ist nicht leer und bleibt, wird aber nicht mehr verwendet."
    fi
}

# appsec-config für das Body-Limit, gleicher Aufbau wie body_config in deploy/crowdsec-helper.sh
crowdsec_body_config() {
    cat << EOF
# Erzeugt vom CrowdSec-Helfer von NPMplus · Hotte (crowdsec-helper.sh), Änderungen werden überschrieben.
# Einstellen in NPMplus › CrowdSec › Einstellungen › AppSec-Body-Limit, gilt für alle Hosts.
# Steht in der AppSec-Acquisition (acquis.d/npmplus.yaml) als erster Eintrag von appsec_configs.
name: npmplus/body-limit
on_load:
  - apply:
      - SetMaxBodySize($1)
      - SetBodySizeExceededAction("$2")
EOF
}

# Nach dem Start: neue Fassung des Helfers laden, Body-Limit einrichten (CrowdSec muss laufen)
finish_crowdsec_helper() {
    # „docker restart crowdsec“ beendet auch den Helfer (gemeinsamer PID-Namensraum)
    docker start crowdsec-helper > /dev/null 2>&1 || true
    if [[ "${HELPER_CHANGED:-0}" == 1 ]] &&
        [[ "$(docker inspect -f '{{.State.Running}}' crowdsec-helper 2> /dev/null)" == true ]]; then
        docker restart crowdsec-helper > /dev/null && ok "CrowdSec-Helfer mit der neuen Fassung gestartet."
    fi
    if ! cs_lapi_ready > /dev/null 2>&1; then
        warn "CrowdSec läuft nicht, AppSec-Body-Limit nicht eingerichtet (erneut: install.sh --update)."
        return 0
    fi
    setup_crowdsec_body_limit
}

# acquis_add_body_limit Datei Ausgabe – setzt npmplus/body-limit als ersten Eintrag unter appsec_configs.
# Nur dort steht er richtig: Optionen wie default_remediation übernimmt CrowdSec von der zuletzt geladenen Konfiguration.
acquis_add_body_limit() {
    MARK="$CROWDSEC_BODY_MARK" awk '
        BEGIN { mark = ENVIRON["MARK"]; state = 0 }
        state == 0 && /^appsec_configs:[ \t]*$/ { print; state = 1; next }
        state == 1 && /^[ \t]*#/ { print; next }
        state == 1 && /^[ \t]*- / {
            indent = $0
            sub(/-.*$/, "", indent)
            print indent "# " mark " (install.sh), muss der erste Eintrag sein"
            print indent "- npmplus/body-limit"
            print
            state = 2
            next
        }
        state == 1 { exit 3 }
        { print }
        END { if (state != 2) exit 3 }
    ' "$1" > "$2"
}

# Body-Limit von AppSec: Standard 64 MiB, partial (CrowdSec selbst: 10 MiB, drop – große Uploads bekämen die Sperrseite).
# Vorhandene Einstellungen (aus NPMplus oder von Hand) bleiben, ein bewusst entfernter Eintrag wird nicht wieder ergänzt.
# Reihenfolge: erst prüft der Helfer die Werte unter anderem Namen (crowdsec -t), dann Datei und Acquisition, dann die
# ganze Konfiguration; abgelehnt wird nur die Acquisition zurückgenommen, die Datei bleibt (nicht referenziert harmlos).
setup_crowdsec_body_limit() {
    local acquis="$CROWDSEC_DATA/conf/acquis.d/npmplus.yaml" need_file=0 need_acquis=0 backup="" tmp log msg
    [[ -e "$CROWDSEC_BODY_FILE" || -L "$CROWDSEC_BODY_FILE" ]] || need_file=1
    if [[ ! -f "$acquis" ]]; then
        warn "$acquis fehlt – AppSec-Body-Limit nicht eingerichtet."
        return 0
    elif grep -Eq '^[[:space:]]*-[[:space:]]*["'"'"']?npmplus/body-limit' "$acquis"; then
        :
    elif grep -qF "$CROWDSEC_BODY_MARK" "$acquis"; then
        warn "npmplus/body-limit wurde aus $acquis entfernt und bleibt draußen (AppSec-Body-Limit aus NPMplus wirkt nicht)."
        return 0
    else
        need_acquis=1
    fi
    if [[ "$need_file" == 0 && "$need_acquis" == 0 ]]; then
        ok "AppSec-Body-Limit bereits eingerichtet ($CROWDSEC_BODY_FILE)."
        return 0
    fi
    log=$(mktemp)
    if ! docker exec crowdsec-helper /bin/sh /helper/crowdsec-helper.sh probe \
        "$CROWDSEC_BODY_DEFAULT_SIZE" "$CROWDSEC_BODY_DEFAULT_ACTION" > "$log" 2>&1; then
        msg=$(tail -n 1 "$log")
        rm -f "$log"
        warn "AppSec-Body-Limit nicht eingerichtet: CrowdSec lehnt es ab (zu alte Version?) oder der Helfer läuft nicht.${msg:+
    $msg}"
        return 0
    fi
    rm -f "$log"
    if [[ "$need_file" == 1 ]]; then
        tmp=$(mktemp "$(dirname "$CROWDSEC_BODY_FILE")/.npmplus-body-limit.XXXXXX")
        if ! crowdsec_body_config "$CROWDSEC_BODY_DEFAULT_SIZE" "$CROWDSEC_BODY_DEFAULT_ACTION" > "$tmp" ||
            ! chmod 0644 "$tmp" || ! mv -f "$tmp" "$CROWDSEC_BODY_FILE"; then
            rm -f "$tmp"
            warn "$CROWDSEC_BODY_FILE konnte nicht geschrieben werden – AppSec-Body-Limit nicht eingerichtet."
            return 0
        fi
    fi
    if [[ "$need_acquis" == 1 ]]; then
        tmp=$(mktemp)
        if acquis_add_body_limit "$acquis" "$tmp"; then
            backup="$acquis.bak-$(date +%Y%m%d-%H%M%S)"
            cp -a "$acquis" "$backup"
            cat "$tmp" > "$acquis"
        else
            warn "Kein appsec_configs-Eintrag in $acquis gefunden – AppSec-Body-Limit bitte von Hand ergänzen:
    erster Eintrag unter appsec_configs: - npmplus/body-limit"
        fi
        rm -f "$tmp"
        # ohne Eintrag in der Acquisition wirkt die Datei nicht, crowdsec muss nicht neu laden
        [[ -n "$backup" ]] || return 0
    fi
    # die ganze Konfiguration prüfen, dann neu laden: eine abgelehnte würde crowdsec beim Neuladen beenden
    log=$(mktemp)
    if docker exec crowdsec crowdsec -c /etc/crowdsec/config.yaml -t > "$log" 2>&1; then
        rm -f "$log"
        docker kill -s HUP crowdsec > /dev/null
        sleep 3
        wait_for 120 "CrowdSec LAPI nach dem Neuladen" cs_lapi_ready ||
            warn "CrowdSec meldet sich nach dem Neuladen nicht – prüfen mit: docker logs crowdsec"
        ok "AppSec-Body-Limit: $((CROWDSEC_BODY_DEFAULT_SIZE / 1048576)) MB, $CROWDSEC_BODY_DEFAULT_ACTION (änderbar in NPMplus › CrowdSec › Einstellungen)."
        [[ -n "$backup" ]] && ok "Acquis-Datei ergänzt (vorher: $backup)."
        return 0
    fi
    msg=$(grep -E 'level=(fatal|error)' "$log" | tail -n 1 || true)
    rm -f "$log"
    [[ -n "$backup" ]] && cp -a "$backup" "$acquis"
    warn "CrowdSec lehnt die Konfiguration mit dem AppSec-Body-Limit ab, Acquis-Datei zurückgenommen.${msg:+
    $msg}"
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

# Falsch nur, wenn die LAPI das Passwort aus der Datei ausdrücklich ablehnt (401), z. B. nach einem erneuten
# „cscli machines add --force“. Ist die LAPI vom Host nicht erreichbar, gilt der Login als in Ordnung. Das Passwort
# geht über stdin an curl und steht so in keiner Befehlszeile.
cs_machine_login_ok() {
    local pw
    pw=$(sed -n 's/^password: *//p' "$1" | head -n 1)
    [[ "$pw" == \"* ]] || pw="\"$pw\""
    [[ $(printf '{"machine_id":"npmplus-gui","password":%s,"scenarios":[]}' "$pw" |
        curl -s -o /dev/null -w '%{http_code}' -m 10 -H 'Content-Type: application/json' --data-binary @- \
            http://127.0.0.1:8080/v1/watchers/login) != 401 ]]
}

# Machine-Login für die CrowdSec-Seite in NPMplus (Bannen, Entbannen, Alerts). Das Passwort geht direkt in die
# Datei, im Format von „cscli machines add -f“, und taucht in keiner Ausgabe auf.
setup_crowdsec_machine() {
    local conf=$1 creds="$NPMPLUS_DATA/crowdsec/lapi-credentials.yaml" tmp
    if [[ -s "$creds" ]] && cs_machine_exists; then
        if cs_machine_login_ok "$creds"; then
            ok "Machine-Login für die CrowdSec-Seite bereits eingerichtet."
            return
        fi
        warn "Machine-Login „npmplus-gui“ wird abgelehnt (Passwort passt nicht mehr), lege ihn neu an."
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

# --update: compose.yaml mit den bisherigen Antworten neu erzeugen, damit neue Dienste (z. B. crowdsec-helper) und
# Einstellungen dazukommen. Übernommene bzw. von Hand ergänzte Einträge bleiben wie bei einem erneuten Lauf erhalten.
update_compose() {
    CROWDSEC=no
    if ! have docker || ! docker compose version > /dev/null 2>&1; then
        warn "docker compose fehlt – compose.yaml bleibt unverändert."
        return 0
    fi
    load_previous "$COMPOSE_FILE"
    if [[ -z "$OLD_JSON" ]]; then
        warn "$COMPOSE_FILE enthält keinen NPMplus-Dienst – bleibt unverändert."
        return 0
    fi
    TZ=${OLD_TZ:-$(system_tz)}
    ACME_EMAIL=${OLD_ACME_EMAIL:-}
    UNIFI_GUARD=$([[ -n "$OLD_GUARD_SVC" ]] && echo yes || echo no)
    CROWDSEC=$([[ -n "$OLD_CROWDSEC_SVC" ]] && echo yes || echo no)
    [[ "$TZ" =~ ^[A-Za-z0-9_+/-]+$ ]] || die "TZ '$TZ' aus $COMPOSE_FILE ist ungültig."
    filter_extra_services
    validate_compose
    review_compose_changes
    [[ "$CROWDSEC" == yes ]] && prepare_crowdsec
    if [[ "$DRY_RUN" == 1 ]]; then
        info "Erzeugte $COMPOSE_FILE (übernommene Werte als ***)"
        COMPOSE_MASK=1 generate_compose
        return 0
    fi
    if generate_compose | write_file_with_backup "$COMPOSE_FILE"; then
        ok "compose.yaml aktualisiert: $COMPOSE_FILE"
    else
        ok "compose.yaml unverändert: $COMPOSE_FILE"
    fi
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
    update_compose
    info "Aktualisiere die Container ($COMPOSE_FILE)"
    run docker compose -f "$COMPOSE_FILE" --project-directory "$INSTALL_DIR" pull -q
    run docker compose -f "$COMPOSE_FILE" --project-directory "$INSTALL_DIR" up -d
    if [[ "${CROWDSEC:-no}" == yes && "$DRY_RUN" != 1 ]]; then
        wait_for 180 "CrowdSec LAPI" cs_lapi_ready || true
        finish_crowdsec_helper
    fi
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
    if ((${#EXTRA_SVC_NAMES[@]})); then
        printf '   Weitere Dienste:       %s\n' "${EXTRA_SVC_NAMES[*]}"
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
    if ((${#IMPORTED_SVCS[@]})); then
        printf '  Importiert:   %s (aus %s)\n' "${IMPORTED_SVCS[*]}" "$IMPORT_FROM"
    fi
    if [[ "$TAKEOVER_ACTIVE" != 1 ]] && ((${#EXTRA_SVC_NAMES[@]})); then
        printf '  Weitere Dienste: %s\n' "${EXTRA_SVC_NAMES[*]}"
    fi
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
        ((${#EXTRA_SVC_NAMES[@]})) && printf '  Weitere Dienste: %s (unverändert übernommen)\n' "${EXTRA_SVC_NAMES[*]}"
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
    filter_extra_services
    print_plan

    if [[ "$DRY_RUN" == 1 ]]; then
        if [[ "$SHOW_VALUES" == 1 ]]; then
            info "Erzeugte $COMPOSE_FILE"
        else
            info "Erzeugte $COMPOSE_FILE (übernommene Werte als *** – anzeigen mit SHOW_VALUES=1)"
        fi
        COMPOSE_MASK=$([[ "$SHOW_VALUES" == 1 ]] && echo 0 || echo 1) generate_compose
        if [[ "$CROWDSEC" == yes ]]; then
            info "Erzeugte $CROWDSEC_DATA/conf/acquis.d/npmplus.yaml"
            crowdsec_acquis
        fi
        info "Geplante Schritte"
    fi

    install_docker
    validate_compose
    review_compose_changes
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
                "$NPMPLUS_DATA/crowdsec/crowdsec.conf" &&
            printf '   [dry-run] AppSec-Body-Limit: %s anlegen (64 MB, partial), npmplus/body-limit in acquis.d/npmplus.yaml, crowdsec -t, SIGHUP\n' \
                "$CROWDSEC_BODY_FILE"
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
    compose pull -q || warn "Nicht alle Images ließen sich laden – vorhandene werden verwendet, „up“ versucht es erneut."
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
    if [[ "$CROWDSEC" == yes ]]; then
        setup_crowdsec
        finish_crowdsec_helper
    fi
    [[ "$UNIFI_GUARD" == yes ]] && setup_guard
    setup_cron
    print_summary
}

# NPMPLUS_HOTTE_LIB=1 nur für Tests: Funktionen laden, nichts ausführen
if [[ "${NPMPLUS_HOTTE_LIB:-0}" != 1 ]]; then
    main "$@"
fi
