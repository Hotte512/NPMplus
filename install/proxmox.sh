#!/usr/bin/env bash
# NPMplus · Hotte – legt auf einem Proxmox-VE-Host einen Debian-12-LXC an und installiert darin NPMplus · Hotte
# (Docker, optional UniFi API Guard und CrowdSec). Als root auf dem Proxmox-Host ausführen:
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install/proxmox.sh)"
#
# Alle Fragen lassen sich per Umgebungsvariable beantworten (NONINTERACTIVE=1 fragt gar nicht):
#   CTID CT_HOSTNAME TEMPLATE_STORAGE ROOTFS_STORAGE DISK_GB CORES RAM_MB SWAP_MB BRIDGE IP (dhcp oder CIDR) GATEWAY
#   VLAN UNPRIVILEGED ONBOOT CT_PASSWORD
# sowie die Optionen von install.sh: TZ ACME_EMAIL UNIFI_GUARD CROWDSEC AUTO_UPDATE INSTALL_DIR

# Deutsche Anführungszeichen („…“) in Texten sind gewollt:
# shellcheck disable=SC1111

set -Eeuo pipefail

readonly RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/Hotte512/NPMplus/claude/hotte-ci/install}"
readonly TITLE="NPMplus · Hotte – Proxmox-LXC"
readonly CT_SCRIPT="/root/npmplus-hotte-install.sh"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

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

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------------------------------------------------------------------------------------------------------------
# Fragen
# ---------------------------------------------------------------------------------------------------------------
UI=none
if [[ "$NONINTERACTIVE" != 1 ]] && [[ -r /dev/tty ]] && { : < /dev/tty; } 2> /dev/null; then
    if command -v whiptail > /dev/null 2>&1; then UI="whiptail"; else UI="read"; fi
fi

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

# ask_choice VAR "Frage" Option... – Vorgabe ist die erste Option
ask_choice() {
    local var=$1 question=$2 answer
    shift 2
    if [[ -n "${!var+x}" ]]; then
        return
    fi
    if (($# == 1)) || [[ "$UI" == none ]]; then
        printf -v "$var" '%s' "$1"
        return
    fi
    if [[ "$UI" == whiptail ]]; then
        local items=() o
        for o in "$@"; do items+=("$o" ""); done
        answer=$(whiptail --title "$TITLE" --menu "$question" 18 74 8 "${items[@]}" 3>&1 1>&2 2>&3 < /dev/tty) ||
            die "Abgebrochen."
    else
        read -r -p "$question ($*) [$1]: " answer < /dev/tty || die "Abgebrochen."
        answer=${answer:-$1}
    fi
    printf -v "$var" '%s' "$answer"
}

host_tz() {
    local tz=""
    tz=$(timedatectl show -p Timezone --value 2> /dev/null || true)
    [[ -n "$tz" ]] || tz=$(cat /etc/timezone 2> /dev/null || true)
    printf '%s' "${tz:-Etc/UTC}"
}

# Storages mit dem gewünschten Inhalt, bevorzugte zuerst
storages() {
    local content=$1 prefer=$2
    pvesm status -content "$content" 2> /dev/null | awk 'NR > 1 && $3 == "active" {print $1}' |
        awk -v p="$prefer" '$1 == p {print; next} {rest = rest $1 "\n"} END {printf "%s", rest}'
}

collect_options() {
    local next_id
    next_id=$(pvesh get /cluster/nextid)
    ask_text CTID "Container-ID:" "$next_id"
    [[ "$CTID" =~ ^[0-9]+$ ]] || die "CTID muss eine Zahl sein."
    if pct status "$CTID" > /dev/null 2>&1 || qm status "$CTID" > /dev/null 2>&1; then
        die "ID $CTID ist bereits vergeben."
    fi
    ask_text CT_HOSTNAME "Hostname des Containers:" "npmplus-hotte"
    [[ "$CT_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || die "Ungültiger Hostname '$CT_HOSTNAME'."

    local list=()
    mapfile -t list < <(storages vztmpl local)
    ((${#list[@]})) || die "Kein Storage für Container-Vorlagen (Inhalt „vztmpl“) gefunden."
    ask_choice TEMPLATE_STORAGE "Storage für die Debian-Vorlage:" "${list[@]}"
    mapfile -t list < <(storages rootdir local-lvm)
    ((${#list[@]})) || die "Kein Storage für Container-Datenträger (Inhalt „rootdir“) gefunden."
    ask_choice ROOTFS_STORAGE "Storage für den Container-Datenträger:" "${list[@]}"

    ask_text DISK_GB "Festplattengröße in GB:" "8"
    ask_text CORES "CPU-Kerne:" "2"
    ask_text RAM_MB "Arbeitsspeicher in MB:" "2048"
    ask_text SWAP_MB "Swap in MB:" "512"
    local n
    for n in DISK_GB CORES RAM_MB SWAP_MB; do
        [[ "${!n}" =~ ^[0-9]+$ ]] || die "$n muss eine Zahl sein."
    done
    ask_text BRIDGE "Netzwerk-Bridge:" "vmbr0"
    ask_text VLAN "VLAN-Tag (leer = keins):" ""
    [[ -z "$VLAN" || "$VLAN" =~ ^[0-9]+$ ]] || die "VLAN muss eine Zahl sein."
    ask_text IP "IPv4: „dhcp“ oder feste Adresse mit Präfix (z. B. 192.168.1.20/24):" "dhcp"
    if [[ "$IP" != dhcp ]]; then
        [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "IP '$IP' ist weder dhcp noch Adresse/Präfix."
        ask_text GATEWAY "Gateway (z. B. 192.168.1.1):" ""
        [[ "$GATEWAY" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Gateway '$GATEWAY' ist ungültig."
    else
        GATEWAY=""
    fi
    ask_yesno UNPRIVILEGED "Unprivilegierten Container anlegen? (empfohlen)" yes
    ask_yesno ONBOOT "Container beim Booten des Hosts starten?" yes

    # Optionen für install.sh – werden jetzt gefragt, damit danach alles ohne Rückfragen durchläuft.
    ask_text TZ "Zeitzone für die Container (z. B. Europe/Berlin):" "$(host_tz)"
    [[ "$TZ" =~ ^[A-Za-z0-9_+/-]+$ ]] || die "TZ '$TZ' ist ungültig."
    ask_text ACME_EMAIL "E-Mail-Adresse für ACME/Let's Encrypt (optional):" ""
    ask_yesno UNIFI_GUARD "UniFi API Guard mitinstallieren?

Rechte-Proxy für die UniFi-API: NPMplus bekommt einen eigenen Key, der nur DNS-Einträge ändern darf." no
    ask_yesno CROWDSEC "CrowdSec mitinstallieren?

Erkennt Angriffe in den NPMplus-Logs und sperrt IPs; der Bouncer in NPMplus wird automatisch eingerichtet." no
    ask_yesno AUTO_UPDATE "Automatische Updates (täglich neue Images holen und alte löschen)?" yes
    ask_text INSTALL_DIR "Verzeichnis für die compose.yaml im Container:" "/opt/npmplus-hotte"
}

# ---------------------------------------------------------------------------------------------------------------
# Ablauf
# ---------------------------------------------------------------------------------------------------------------
fetch_install_script() {
    local self="${BASH_SOURCE[0]:-}" dir
    if [[ -n "$self" && -f "$self" ]]; then
        dir=$(cd "$(dirname "$self")" && pwd)
        if [[ -f "$dir/install.sh" ]]; then
            cp "$dir/install.sh" "$TMP_DIR/install.sh"
            ok "install.sh aus $dir"
            return
        fi
    fi
    info "Lade install.sh von $RAW_BASE"
    curl -fsSL "$RAW_BASE/install.sh" -o "$TMP_DIR/install.sh" || die "Download von install.sh fehlgeschlagen."
    head -n1 "$TMP_DIR/install.sh" | grep -q '^#!/usr/bin/env bash' || die "install.sh sieht nicht wie ein Skript aus."
}

latest_template() {
    pveam update > /dev/null 2>&1 || warn "pveam update fehlgeschlagen, verwende die vorhandene Liste."
    pveam available --section system | awk '$2 ~ /^debian-12-standard_.*_amd64\.tar\.zst$/ {print $2}' |
        sort -V | tail -n1
}

prepare_template() {
    TEMPLATE=$(latest_template)
    [[ -n "$TEMPLATE" ]] || die "Keine Debian-12-Vorlage in „pveam available“ gefunden."
    if pveam list "$TEMPLATE_STORAGE" | awk '{print $1}' | grep -q "/$TEMPLATE$"; then
        ok "Vorlage vorhanden: $TEMPLATE"
    else
        info "Lade Vorlage $TEMPLATE nach $TEMPLATE_STORAGE"
        pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" > /dev/null
        ok "Vorlage geladen."
    fi
}

create_ct() {
    local net="name=eth0,bridge=$BRIDGE,ip=$IP"
    [[ -n "$GATEWAY" ]] && net+=",gw=$GATEWAY"
    [[ -n "$VLAN" ]] && net+=",tag=$VLAN"
    local args=(
        "$CTID" "$TEMPLATE_STORAGE:vztmpl/$TEMPLATE"
        --hostname "$CT_HOSTNAME"
        --cores "$CORES" --memory "$RAM_MB" --swap "$SWAP_MB"
        --rootfs "$ROOTFS_STORAGE:$DISK_GB"
        --net0 "$net"
        --ostype debian
        --unprivileged "$([[ "$UNPRIVILEGED" == yes ]] && echo 1 || echo 0)"
        --features "nesting=1,keyctl=1" # nötig für Docker im LXC
        --onboot "$([[ "$ONBOOT" == yes ]] && echo 1 || echo 0)"
        --timezone host
        --tags npmplus
        --description "NPMplus · Hotte (https://github.com/Hotte512/NPMplus)"
    )
    if [[ -n "${CT_PASSWORD:-}" ]]; then
        args+=(--password "$CT_PASSWORD")
    fi
    info "Lege Container $CTID ($CT_HOSTNAME) an"
    pct create "${args[@]}" > /dev/null
    ok "Container angelegt."
    pct start "$CTID"
}

ct_ip() { pct exec "$CTID" -- sh -c "ip -4 -o addr show dev eth0 | awk '{print \$4}' | cut -d/ -f1 | head -n1"; }

wait_network() {
    info "Warte auf Netzwerk im Container (IP: $IP, DNS; bis zu 120 s)"
    local i ip
    for ((i = 0; i < 60; i++)); do
        if pct exec "$CTID" -- getent hosts deb.debian.org > /dev/null 2>&1; then
            CT_IP=$(ct_ip || true)
            ok "Netzwerk bereit (${CT_IP:-IP unbekannt})."
            return
        fi
        if ((i > 0 && i % 5 == 0)); then
            ip=$(ct_ip 2> /dev/null || true)
            printf '    … %s s, IP: %s\n' "$((i * 2))" "${ip:-noch keine}"
        fi
        sleep 2
    done
    ip=$(ct_ip 2> /dev/null || true)
    if [[ -n "$ip" ]]; then
        die "Container $CTID hat die IP $ip, aber DNS geht nicht. Prüfen: pct exec $CTID -- cat /etc/resolv.conf"
    fi
    die "Container $CTID hat nach 120 s keine IP. DHCP auf der Bridge/im VLAN prüfen oder statische IP wählen. Container bleibt bestehen."
}

run_install() {
    info "Starte install.sh im Container (das dauert einige Minuten)"
    pct push "$CTID" "$TMP_DIR/install.sh" "$CT_SCRIPT" --perms 0755
    pct exec "$CTID" -- env \
        NONINTERACTIVE=1 \
        TZ="$TZ" \
        ACME_EMAIL="$ACME_EMAIL" \
        UNIFI_GUARD="$UNIFI_GUARD" \
        CROWDSEC="$CROWDSEC" \
        AUTO_UPDATE="$AUTO_UPDATE" \
        INSTALL_DIR="$INSTALL_DIR" \
        TERM="${TERM:-xterm}" \
        bash "$CT_SCRIPT" ||
        die "install.sh im Container ist fehlgeschlagen. Erneut versuchen mit: pct exec $CTID -- bash $CT_SCRIPT"
}

main() {
    [[ $EUID -eq 0 ]] || die "Bitte als root auf dem Proxmox-Host ausführen."
    local cmd
    for cmd in pct pveam pvesh pvesm; do
        command -v "$cmd" > /dev/null 2>&1 || die "$cmd fehlt – dieses Skript läuft nur auf einem Proxmox-VE-Host."
    done
    if [[ "$UI" == whiptail ]]; then
        whiptail --title "$TITLE" --yesno "Neuen LXC-Container mit NPMplus · Hotte anlegen?" 8 74 < /dev/tty ||
            die "Abgebrochen."
    fi
    collect_options
    fetch_install_script

    info "Zusammenfassung"
    cat << EOF
   Container:  $CTID ($CT_HOSTNAME), $([[ "$UNPRIVILEGED" == yes ]] && echo unprivilegiert || echo privilegiert), Start beim Booten: $ONBOOT
   Ressourcen: ${CORES} Kerne, ${RAM_MB} MB RAM, ${SWAP_MB} MB Swap, ${DISK_GB} GB auf $ROOTFS_STORAGE
   Netzwerk:   $BRIDGE${VLAN:+ (VLAN $VLAN)}, IPv4 $IP${GATEWAY:+ über $GATEWAY}
   NPMplus:    TZ=$TZ, UniFi API Guard=$UNIFI_GUARD, CrowdSec=$CROWDSEC, Auto-Update=$AUTO_UPDATE
EOF
    if [[ "$UI" == whiptail ]]; then
        whiptail --title "$TITLE" --yesno "Container $CTID ($CT_HOSTNAME) jetzt anlegen und NPMplus · Hotte installieren?" \
            8 74 < /dev/tty || die "Abgebrochen."
    fi

    prepare_template
    create_ct
    wait_network
    run_install

    CT_IP=$(ct_ip || true)
    printf '\n%sProxmox-Container fertig%s\n' "$C_BOLD" "$C_OFF"
    cat << EOF
  Container:  $CTID ($CT_HOSTNAME), IP ${CT_IP:-unbekannt}
  Konsole:    pct enter $CTID
  NPMplus:    https://${CT_IP:-<IP>}:81
EOF
    if [[ "$UNIFI_GUARD" == yes ]]; then
        printf '  Guard:      http://%s:8091 (Einrichtungs-Token steht oben in der Ausgabe von install.sh)\n' "${CT_IP:-<IP>}"
    fi
    if [[ "$IP" == dhcp ]]; then
        warn "Die IP kommt per DHCP – für einen Reverse-Proxy besser eine feste Reservierung im Router anlegen."
    fi
}

main "$@"
