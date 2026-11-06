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
