#!/bin/bash
###############################################################################
# SCANOSS Automated Update
#
# Non-interactive wrapper meant to be scheduled (e.g. from cron). It keeps an
# on-premise installation up to date by calling the scripts next to it:
#
#   1. install-scanoss.sh -y -a all   install/update binaries (and, with -s,
#                                     decoration services); unchanged ones
#                                     are skipped by the installer
#   2. full KB (optional, -k or -K)   downloaded with kb-download.sh -y, or
#                                     copied from a local folder, into
#                                     /var/lib/ldb/oss (overwrite in place);
#                                     skipped when that version is deployed
#
# Run with -? for the list of flags.
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

INSTALLER="$SCRIPT_DIR/install-scanoss.sh"
KB_DOWNLOAD="$SCRIPT_DIR/kb-download.sh"
KB_DIR="$LDB_LOCATION/oss"
REMOTE_PATH_FULL="kb/full"
LOCK_FILE="/var/lock/scanoss-update.lock"
# Exists while a KB deployment is running or after one was interrupted. The KB
# is overwritten in place, so version.json may already show the new version
# before every file is in place: while this file exists the KB is never
# considered deployed.
KB_MARKER="$APP_DIR/.installed/kb.in-progress"

SERVICES=""        # -s, passed to the installer
KB_VERSION=""      # -k: "latest" or a version
KB_PATH=""         # -K: local full KB folder (holds oss/)
STOP_SERVICES=""   # -S
CLI_SFTP_HOST=""
CLI_SFTP_PORT=""
CLI_SFTP_USER=""
CLI_SFTP_PASSWORD=""

# scanoss* services stopped by -S, started again on exit.
STOPPED_SERVICES=()

usage() {
    echo "Usage: $0 [-s services] [-k version | -K path] [-S] [-h host] [-P port] [-u user] [-p password]"
    echo
    echo "Non-interactive update of SCANOSS binaries and, optionally, the full KB."
    echo
    echo "  -s    Also update decoration services: 'all' or a comma-separated list"
    echo "        (passed to install-scanoss.sh)"
    echo "  -k    Deploy the full KB from SFTP: 'latest' or a version (e.g. 26.09)"
    echo "  -K    Deploy the full KB from a local folder holding oss/ (e.g. /data/26.09)"
    echo "  -S    Stop the active scanoss* services while the KB is deployed and"
    echo "        start them again afterwards (requires -k or -K)"
    echo "  -h    SFTP host (default: ${SFTP_HOST})"
    echo "  -P    SFTP port (default: ${SFTP_PORT})"
    echo "  -u    SFTP username"
    echo "  -p    SFTP password"
    echo "        Without -u/-p the credentials saved in ~/.scanoss_sftp are used."
    echo "  -?    Show this help"
    exit 0
}

die() {
    echo "Error: $*" >&2
    exit 1
}

parse_args() {
    while getopts "s:k:K:Sh:P:u:p:?" opt; do
        case $opt in
            s) SERVICES="$OPTARG" ;;
            k) KB_VERSION="$OPTARG" ;;
            K) KB_PATH="$OPTARG" ;;
            S) STOP_SERVICES=1 ;;
            h) CLI_SFTP_HOST="$OPTARG" ;;
            P) CLI_SFTP_PORT="$OPTARG" ;;
            u) CLI_SFTP_USER="$OPTARG" ;;
            p) CLI_SFTP_PASSWORD="$OPTARG" ;;
            ?) usage ;;
        esac
    done

    [[ -n "$KB_VERSION" && -n "$KB_PATH" ]] && die "-k and -K cannot be used together."
    [[ -n "$STOP_SERVICES" && -z "$KB_VERSION" && -z "$KB_PATH" ]] && die "-S requires -k or -K."
    if [[ -n "$KB_VERSION" && ! "$KB_VERSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
        die "invalid KB version '$KB_VERSION'."
    fi
}

# Value of "monthly" in a version.json, empty if missing.
kb_version_of() {
    sed -nE 's/.*"monthly"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$1" 2>/dev/null | head -n1
}

# Credentials for the KB step: flags first, then ~/.scanoss_sftp (saved by the
# installer). -h/-P override the saved host/port.
load_kb_creds() {
    if [[ -n "$CLI_SFTP_USER" && -n "$CLI_SFTP_PASSWORD" ]]; then
        SFTP_USER="$CLI_SFTP_USER"
        SFTP_PASSWORD="$CLI_SFTP_PASSWORD"
    elif [[ -f ~/.scanoss_sftp ]]; then
        source ~/.scanoss_sftp
    fi
    [[ -n "$CLI_SFTP_HOST" ]] && SFTP_HOST="$CLI_SFTP_HOST"
    [[ -n "$CLI_SFTP_PORT" ]] && SFTP_PORT="$CLI_SFTP_PORT"
    [[ -n "$SFTP_USER" && -n "$SFTP_PASSWORD" ]] || { echo "Error: no SFTP credentials (-u/-p or ~/.scanoss_sftp)."; return 1; }
}

# Prints a file from the SFTP server. Same password-only auth and timeouts as
# kb-download.sh, so a wrong host/port fails instead of hanging.
sftp_cat() {
    lftp -u "$SFTP_USER","$SFTP_PASSWORD" \
        -e "set sftp:connect-program \"ssh -a -x -oPubkeyAuthentication=no -oPreferredAuthentications=password,keyboard-interactive\"; set sftp:auto-confirm yes; set net:timeout 15; set net:max-retries 3; cat $1; exit" \
        "sftp://${SFTP_HOST}:${SFTP_PORT}" 2>/dev/null
}

# Size in bytes of a full KB on the server: total_size_bytes from its
# metadata.json (written by the server when the KB is published), empty if it
# cannot be read.
read_remote_kb_size() {
    sftp_cat "${REMOTE_PATH_FULL}/$1/metadata.json" \
        | grep -oE '"total_size_bytes"[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+$'
}

# Refuses the deployment unless the new KB fits: its size plus KB_MIN_FREE_GB
# must not exceed the free space plus the space of the KB it overwrites in
# place. Sizes are apparent sizes (du -sb), like total_size_bytes. The KB
# folder is resolved first, so a symlinked /var/lib/ldb or oss is measured on
# the filesystem it points to.
check_kb_space() {
    local new_size="$1" kb_real current free buffer
    [[ "$KB_MIN_FREE_GB" =~ ^[0-9]+$ ]] || { echo "Error: invalid KB_MIN_FREE_GB '$KB_MIN_FREE_GB' in config.sh."; return 1; }
    buffer=$(( KB_MIN_FREE_GB * 1024 * 1024 * 1024 ))
    kb_real=$(readlink -f "$KB_DIR")
    current=$(du -sb "$kb_real" | cut -f1)
    free=$(df -B1 --output=avail "$kb_real" | tail -n1 | tr -d ' ')
    [[ -n "$current" && -n "$free" ]] || { echo "Error: could not measure the disk space of $kb_real."; return 1; }

    log "Disk space on $kb_real: new KB $(numfmt --to=iec "$new_size"), installed KB $(numfmt --to=iec "$current"), free $(numfmt --to=iec "$free"), buffer ${KB_MIN_FREE_GB}G"
    if (( new_size + buffer > current + free )); then
        echo "Error: not enough disk space for the new KB: it needs $(numfmt --to=iec "$new_size") + ${KB_MIN_FREE_GB}G buffer (KB_MIN_FREE_GB), but only $(numfmt --to=iec $(( current + free ))) is available (free space + the installed KB it replaces)."
        return 1
    fi
}

stop_services() {
    mapfile -t STOPPED_SERVICES < <(systemctl list-units --type=service --state=active --no-legend --plain 'scanoss*' | awk '{print $1}')
    local svc
    for svc in "${STOPPED_SERVICES[@]}"; do
        log "Stopping $svc"
        systemctl stop "$svc"
    done
}

start_services() {
    local svc
    for svc in "${STOPPED_SERVICES[@]}"; do
        log "Starting $svc"
        systemctl start "$svc" || echo "Warning: could not start $svc"
    done
    STOPPED_SERVICES=()
}

deploy_kb() {
    local target
    if [[ -n "$KB_PATH" ]]; then
        [[ -f "$KB_PATH/oss/version.json" ]] || { echo "Error: $KB_PATH/oss/version.json not found: not a full KB folder."; return 1; }
        target=$(kb_version_of "$KB_PATH/oss/version.json")
        [[ -n "$target" ]] || { echo "Error: no \"monthly\" version in $KB_PATH/oss/version.json."; return 1; }
    else
        load_kb_creds || return 1
        if [[ "$KB_VERSION" == "latest" ]]; then
            target=$(sftp_cat "${REMOTE_PATH_FULL}/LATEST.txt" | tr -d '[:space:]')
            [[ -n "$target" ]] || { echo "Error: could not read ${REMOTE_PATH_FULL}/LATEST.txt from ${SFTP_HOST}:${SFTP_PORT}."; return 1; }
        else
            target="$KB_VERSION"
        fi
    fi

    local installed
    installed=$(kb_version_of "$KB_DIR/version.json")
    if [[ "$installed" == "$target" && ! -f "$KB_MARKER" ]]; then
        log "KB $target already deployed, skipping."
        KB_RESULT="already at $target"
        return 0
    fi

    # Checked before anything is stopped, downloaded or copied.
    local new_size
    if [[ -n "$KB_PATH" ]]; then
        new_size=$(du -sb "$(readlink -f "$KB_PATH/oss")" | cut -f1)
    else
        new_size=$(read_remote_kb_size "$target")
        [[ -n "$new_size" ]] || { echo "Error: could not read ${REMOTE_PATH_FULL}/${target}/metadata.json from ${SFTP_HOST}:${SFTP_PORT}."; return 1; }
    fi
    mkdir -p "$KB_DIR"
    check_kb_space "$new_size" || return 1

    log "Deploying full KB $target to $KB_DIR (installed: ${installed:-none})"
    mkdir -p "$(dirname "$KB_MARKER")"
    echo "$target" > "$KB_MARKER"

    [[ -n "$STOP_SERVICES" ]] && stop_services

    local rc=0
    if [[ -n "$KB_PATH" ]]; then
        cp -a "$KB_PATH/oss/." "$KB_DIR/" || rc=1
    else
        # -f: check_kb_space replaces kb-download.sh's own disk space check,
        # which ignores the space of the KB being overwritten and has no buffer.
        "$KB_DOWNLOAD" -y -f -m full -V "$target" -o "$KB_DIR" \
            -h "$SFTP_HOST" -P "$SFTP_PORT" -u "$SFTP_USER" -p "$SFTP_PASSWORD" || rc=1
    fi

    if [[ $rc -eq 0 ]]; then
        installed=$(kb_version_of "$KB_DIR/version.json")
        if [[ "$installed" != "$target" ]]; then
            echo "Error: deployed KB reports version '${installed:-none}', expected '$target'."
            rc=1
        fi
    fi

    [[ -n "$STOP_SERVICES" ]] && start_services

    if [[ $rc -ne 0 ]]; then
        log "KB $target deployment failed; it will be retried on the next run."
        return 1
    fi
    # Resolved: chown -R does not descend into a symlinked oss folder.
    chown -R "$RUNTIME_USER:$RUNTIME_USER" "$(readlink -f "$KB_DIR")"
    rm -f "$KB_MARKER"
    log "KB $target deployed."
    KB_RESULT="deployed $target"
}

# ─── Main ───────────────────────────────────────────────────────────────────

parse_args "$@"

[[ "$(id -u)" == "0" ]] || die "This script must be run as root."

# The installer of a release before the non-interactive mode only has the menu,
# which would wait for input forever.
grep -q -- '\[-a all\]' "$INSTALLER" 2>/dev/null \
    || die "$INSTALLER does not support non-interactive mode (-a all). Update the on-premise scripts."

exec 9>"$LOCK_FILE"
flock -n 9 || die "another scanoss-update.sh run is in progress ($LOCK_FILE)."

# Services stopped by -S are started again however the script ends.
trap start_services EXIT
trap 'exit 130' INT TERM

log "scanoss-update.sh started"

BINARIES_RESULT="OK"
KB_RESULT="not requested"
RC=0

installer_args=(-y -a all)
[[ -n "$SERVICES" ]] && installer_args+=(-s "$SERVICES")
[[ -n "$CLI_SFTP_HOST" ]] && installer_args+=(-h "$CLI_SFTP_HOST")
[[ -n "$CLI_SFTP_PORT" ]] && installer_args+=(-P "$CLI_SFTP_PORT")
[[ -n "$CLI_SFTP_USER" ]] && installer_args+=(-u "$CLI_SFTP_USER")
[[ -n "$CLI_SFTP_PASSWORD" ]] && installer_args+=(-p "$CLI_SFTP_PASSWORD")

if ! "$INSTALLER" "${installer_args[@]}" </dev/null; then
    BINARIES_RESULT="FAILED"
    RC=1
fi

if [[ -n "$KB_VERSION" || -n "$KB_PATH" ]]; then
    if [[ $RC -ne 0 ]]; then
        KB_RESULT="skipped (binaries failed)"
    elif ! deploy_kb; then
        KB_RESULT="FAILED"
        RC=1
    fi
fi

echo ""
log "Summary: binaries: $BINARIES_RESULT; KB: $KB_RESULT"
exit $RC
