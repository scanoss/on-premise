#!/bin/bash

set -e

###############################################################################
# SCANOSS Knowledge Base Download Script
#
# Downloads the full KB, a KB update, or the test KB from the SCANOSS SFTP
# server. Supports both lftp (parallel, resumable) and sftp fallback.
#
# Usage:
#   kb-download.sh [-m mode] [-h host] [-P port] [-u user] [-p password]
#                  [-t threads] [-d tool]
#
# All options are optional. Any not provided will be prompted interactively.
###############################################################################

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

LOG_FILE="${HOME}/scanoss_kb_download.log"

SFTP_HOST=""
SFTP_PORT=""
REMOTE_PATH_FULL="kb/full"
REMOTE_PATH_UPDATE="kb/update"
REMOTE_PATH_TEST="kb/test/oss"

MODE=""            # "full", "update", or "test"
DOWNLOAD_TOOL=""   # set during init: "lftp" or "sftp"
SFTP_USER=""
SFTP_PASS=""
LFTP_THREADS="25"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
    echo "$(date +'%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

die() {
    echo "ERROR: $*" >&2
    log "ERROR: $*"
    exit 1
}

usage() {
    echo "Usage: $0 [-m mode] [-h host] [-P port] [-u user] [-p password] [-t threads] [-d tool]"
    echo
    echo "Options:"
    echo "  -m    Download mode: full, update, or test"
    echo "  -h    SFTP host"
    echo "  -P    SFTP port"
    echo "  -u    SFTP username"
    echo "  -p    SFTP password"
    echo "  -t    lftp parallel threads (default: ${LFTP_THREADS})"
    echo "  -d    Download tool: lftp or sftp"
    echo "  -?    Show this help"
    exit 0
}

# lftp options applied to every invocation. sftp:auto-confirm makes lftp
# accept unknown host keys instead of failing with a cryptic error — matches
# the -oStrictHostKeyChecking=no used on the sftp fallback.
LFTP_SETTINGS="set sftp:auto-confirm yes;"

# Run an SFTP batch command and return stdout.
sftp_cmd() {
    local cmd="$1"
    sshpass -p "$SFTP_PASS" \
        sftp -P "$SFTP_PORT" -oBatchMode=no -oStrictHostKeyChecking=no \
        "$SFTP_USER@$SFTP_HOST" <<< "$cmd" 2>/dev/null
}

# Run an lftp command and return stdout.
lftp_cmd() {
    local cmd="$1"
    lftp -u "$SFTP_USER","$SFTP_PASS" \
        -e "${LFTP_SETTINGS} $cmd; exit" \
        "sftp://${SFTP_HOST}:${SFTP_PORT}" 2>/dev/null
}

# List directories under a remote path, returning just the names.
list_remote_dirs() {
    local remote_path="$1"
    if [[ "$DOWNLOAD_TOOL" == "lftp" ]]; then
        lftp_cmd "ls $remote_path" | awk '/^d/ {print $NF}' | grep -v '^\.\.*$' | sort
    else
        sftp_cmd "ls -l $remote_path" | awk '/^d/ {print $NF}' | grep -v '^\.\.*$' | sort
    fi
}

# Read a remote file's content (e.g. LATEST.txt).
read_remote_file() {
    local remote_path="$1"
    local tmpfile
    tmpfile=$(mktemp)
    rm -f "$tmpfile"
    if [[ "$DOWNLOAD_TOOL" == "lftp" ]]; then
        lftp -u "$SFTP_USER","$SFTP_PASS" \
            -e "${LFTP_SETTINGS} get $remote_path -o $tmpfile; exit" \
            "sftp://${SFTP_HOST}:${SFTP_PORT}" &>/dev/null
    else
        sftp_cmd "get $remote_path $tmpfile" >/dev/null 2>&1
    fi
    cat "$tmpfile"
    rm -f "$tmpfile"
}

# List all top-level items (files and dirs) under a remote path.
list_remote_items() {
    local remote_path="$1"
    if [[ "$DOWNLOAD_TOOL" == "lftp" ]]; then
        lftp_cmd "ls $remote_path" | awk '/^[-dl]/ {print $NF}' | grep -v '^\.\.*$' | sort
    else
        sftp_cmd "ls -l $remote_path" | awk '/^[-dl]/ {print $NF}' | grep -v '^\.\.*$' | sort
    fi
}

# Download a remote directory or file to a local path.
download_path() {
    local remote_path="$1"
    local local_path="$2"

    mkdir -p "$local_path"

    if [[ "$DOWNLOAD_TOOL" == "lftp" ]]; then
        echo "Downloading ${remote_path} with lftp (${LFTP_THREADS} parallel threads, resumable)..."
        lftp -u "$SFTP_USER","$SFTP_PASS" \
            -e "${LFTP_SETTINGS} mirror -c -P ${LFTP_THREADS} $remote_path $local_path; exit" \
            "sftp://${SFTP_HOST}:${SFTP_PORT}"
    else
        echo "Downloading ${remote_path} with sftp..."
        local parent_dir
        parent_dir=$(dirname "$local_path")
        sshpass -p "$SFTP_PASS" \
            sftp -P "$SFTP_PORT" -oBatchMode=no -oStrictHostKeyChecking=no \
            -r "$SFTP_USER@$SFTP_HOST:$remote_path" "$parent_dir"
    fi
}

# Download a remote directory to a local path (whole directory, single transfer).
download_dir() {
    download_path "$1" "$2"
}

# Download the full KB with split destinations:
#   - the "oss" subfolder goes to oss_dest
#   - everything else goes to rest_dest
download_full_kb() {
    local remote_version_path="$1"   # e.g., kb/full/26.03
    local oss_dest="$2"               # e.g., /var/lib/ldb/oss
    local rest_dest="$3"              # e.g., /tmp/scanoss_kb_full_26.03

    # 1) Download oss folder
    echo
    echo "Downloading 'oss' folder to ${oss_dest} ..."
    download_path "${remote_version_path}/oss" "$oss_dest"

    # 2) Download all other top-level items
    echo
    echo "Downloading remaining items to ${rest_dest} ..."
    mkdir -p "$rest_dest"

    local items
    items=$(list_remote_items "$remote_version_path")

    while IFS= read -r item; do
        item=$(echo "$item" | tr -d '[:space:]')
        [[ -z "$item" || "$item" == "oss" ]] && continue
        download_path "${remote_version_path}/${item}" "${rest_dest}/${item}"
    done <<< "$items"
}

# ---------------------------------------------------------------------------
# Initialization
# ---------------------------------------------------------------------------

parse_args() {
    while getopts "m:h:P:u:p:t:d:?" opt; do
        case $opt in
            m) MODE="$OPTARG" ;;
            h) SFTP_HOST="$OPTARG" ;;
            P) SFTP_PORT="$OPTARG" ;;
            u) SFTP_USER="$OPTARG" ;;
            p) SFTP_PASS="$OPTARG" ;;
            t) LFTP_THREADS="$OPTARG" ;;
            d) DOWNLOAD_TOOL="$OPTARG" ;;
            ?) usage ;;
            *) usage ;;
        esac
    done
}

check_sshpass() {
    if ! command -v sshpass &>/dev/null; then
        die "sshpass is required but not installed. Install it with: apt install sshpass"
    fi
}

init_download_tool() {
    # If already set via -d flag, validate and return
    if [[ -n "$DOWNLOAD_TOOL" ]]; then
        case "$DOWNLOAD_TOOL" in
            lftp) command -v lftp &>/dev/null || die "lftp was requested but is not installed." ;;
            sftp) ;; # always available
            *)    die "Unknown download tool: ${DOWNLOAD_TOOL}. Use lftp or sftp." ;;
        esac
        echo "Using ${DOWNLOAD_TOOL} for downloads."
        return
    fi

    # Auto-detect: prefer lftp, fall back to sftp
    if command -v lftp &>/dev/null; then
        DOWNLOAD_TOOL="lftp"
        echo "Using lftp for downloads (parallel, resumable)."
    else
        echo
        echo "lftp is not installed. lftp provides faster parallel downloads."
        echo "You can install it with: apt install lftp"
        echo
        while true; do
            read -p "Continue with sftp instead? (y/n) " yn
            case $yn in
                [Yy]*)
                    DOWNLOAD_TOOL="sftp"
                    echo "Using sftp for downloads."
                    break
                    ;;
                [Nn]*)
                    echo "Install lftp and re-run this script."
                    exit 0
                    ;;
                *)
                    echo "Please answer yes (y) or no (n)."
                    ;;
            esac
        done
    fi
}

prompt_missing_mode() {
    if [[ -n "$MODE" ]]; then
        case "$MODE" in
            full|update|test) ;;
            *) die "Invalid mode: ${MODE}. Use 'full', 'update', or 'test'." ;;
        esac
        return
    fi

    echo
    echo "What do you want to download?"
    echo "  1) Full KB"
    echo "  2) KB update"
    echo "  3) Test KB"
    echo
    while true; do
        read -p "Select [1-3]: " choice
        case $choice in
            1) MODE="full"; break ;;
            2) MODE="update"; break ;;
            3) MODE="test"; break ;;
            *) echo "Please enter 1, 2, or 3." ;;
        esac
    done
}

prompt_missing_connection() {
    echo
    if [[ -z "$SFTP_HOST" ]]; then
        read -p "SFTP host: " SFTP_HOST
    fi
    if [[ -z "$SFTP_PORT" ]]; then
        read -p "SFTP port: " SFTP_PORT
    fi
    if [[ -z "$SFTP_USER" ]]; then
        read -p "SFTP username: " SFTP_USER
    fi
    if [[ -z "$SFTP_PASS" ]]; then
        read -sp "SFTP password: " SFTP_PASS
        echo
    fi
    [[ -n "$SFTP_HOST" ]] || die "SFTP host is required."
    [[ -n "$SFTP_PORT" ]] || die "SFTP port is required."
    [[ -n "$SFTP_USER" && -n "$SFTP_PASS" ]] || die "Username and password are required."
}

# ---------------------------------------------------------------------------
# Download workflow
# ---------------------------------------------------------------------------

kb_download_test() {
    local remote_path="$REMOTE_PATH_TEST"
    local default_dest="/var/lib/ldb/oss"

    # Destination
    echo
    read -p "Destination for test KB [${default_dest}]: " dest_input
    local test_dest="${dest_input:-$default_dest}"
    mkdir -p "$(dirname "$test_dest")"

    # Fetch metadata and check disk space. The test KB is not guaranteed to
    # ship a metadata.json, so treat its absence as expected rather than a
    # warning condition.
    echo
    echo "Fetching test KB metadata..."
    local metadata_content
    metadata_content=$(read_remote_file "${remote_path}/metadata.json" 2>/dev/null || true)

    if [[ -n "$metadata_content" ]]; then
        local remote_size
        remote_size=$(echo "$metadata_content" | grep -o '"total_size_bytes":[[:space:]]*[0-9]*' | grep -o '[0-9]*$')

        if [[ -n "$remote_size" && "$remote_size" -gt 0 ]]; then
            local local_free
            local_free=$(df -B1 "$(dirname "$test_dest")" | awk 'NR==2 {print $4}')
            local remote_hr
            remote_hr=$(numfmt --to=iec "$remote_size")
            local local_hr
            local_hr=$(numfmt --to=iec "$local_free")

            echo "Test KB size: ${remote_hr}"
            echo "Free space:   ${local_hr} (on $(df "$(dirname "$test_dest")" | awk 'NR==2 {print $1}'))"

            if (( local_free < remote_size )); then
                echo
                echo "WARNING: Not enough disk space. Need ${remote_hr} but only ${local_hr} available."
                log "Insufficient disk space for test KB: need ${remote_hr}, have ${local_hr} (user confirm)"
                while true; do
                    read -p "Continue download anyway? [y/N] " yn
                    yn="${yn:-n}"
                    case $yn in
                        [Yy]*) echo "Continuing despite low disk space."; break ;;
                        [Nn]*) echo "Aborting download."; return ;;
                        *)     echo "Please answer yes (y) or no (n)." ;;
                    esac
                done
            else
                echo "Disk space OK."
            fi
        fi
    else
        echo "Note: test KB does not include metadata.json; skipping disk space check."
    fi

    # Prompt for thread count if using lftp
    if [[ "$DOWNLOAD_TOOL" == "lftp" ]]; then
        read -p "lftp parallel threads [${LFTP_THREADS}]: " threads_input
        LFTP_THREADS="${threads_input:-$LFTP_THREADS}"
    fi

    # Download
    echo
    while true; do
        read -p "Download test KB to ${test_dest}? [Y/n] " yn
        yn="${yn:-y}"
        case $yn in
            [Yy]*)
                log "Starting download of test KB to ${test_dest}"
                download_path "$remote_path" "$test_dest"
                echo
                echo "Test KB downloaded to ${test_dest}"
                log "Test KB downloaded to ${test_dest}"
                echo
                echo "Finished downloading test KB."
                break
                ;;
            [Nn]*)
                echo "Skipping download."
                return
                ;;
            *)
                echo "Please answer yes (y) or no (n)."
                ;;
        esac
    done
}

kb_download() {
    local mode="$1"
    local remote_path label default_download

    if [[ "$mode" == "full" ]]; then
        remote_path="$REMOTE_PATH_FULL"
        label="full KB"
        default_download="/tmp/scanoss_kb_full"
    else
        remote_path="$REMOTE_PATH_UPDATE"
        label="update"
        default_download="/tmp/scanoss_kb_update"
    fi

    # Discover available versions
    echo
    echo "Fetching available ${label} versions..."
    log "Fetching available ${label} versions from ${SFTP_HOST}:${remote_path}"

    local versions
    versions=$(list_remote_dirs "$remote_path")

    if [[ -z "$versions" ]]; then
        echo "No ${label} versions found on the server."
        log "No ${label} versions found on the server."
        return
    fi

    # Read LATEST.txt if available
    local latest=""
    latest=$(read_remote_file "${remote_path}/LATEST.txt" 2>/dev/null || true)
    latest=$(echo "$latest" | tr -d '[:space:]')

    # Display available versions
    echo
    echo "Available ${label} versions:"
    echo "-------------------"
    local i=1
    local version_list=()
    local latest_index=""
    while IFS= read -r ver; do
        ver=$(echo "$ver" | tr -d '[:space:]')
        [[ -z "$ver" ]] && continue
        version_list+=("$ver")
        if [[ "$ver" == "$latest" ]]; then
            printf "  %d) %s  (latest)\n" "$i" "$ver"
            latest_index="$i"
        else
            printf "  %d) %s\n" "$i" "$ver"
        fi
        ((i++))
    done <<< "$versions"
    echo "-------------------"

    if [[ ${#version_list[@]} -eq 0 ]]; then
        echo "No ${label} versions found."
        return
    fi

    # Let user pick a version, defaulting to latest
    echo
    local default_sel="${latest_index:-${#version_list[@]}}"
    local selection
    while true; do
        read -p "Select a ${label} version to download [1-${#version_list[@]}] (default: ${default_sel}): " selection
        selection="${selection:-$default_sel}"
        if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#version_list[@]} )); then
            break
        fi
        echo "Invalid selection. Please enter a number between 1 and ${#version_list[@]}."
    done

    local kb_version="${version_list[$((selection - 1))]}"
    echo
    echo "Selected ${label}: $kb_version"
    log "Selected ${label} version: $kb_version"

    # Download location(s)
    local oss_dest="" rest_dest="" download_dir_path="" disk_check_path=""
    if [[ "$mode" == "full" ]]; then
        local default_oss_dest="/var/lib/ldb/oss"
        local default_rest_dest="/tmp/scanoss_kb_full_${kb_version}"
        echo
        read -p "Destination for 'oss' folder [${default_oss_dest}]: " oss_input
        oss_dest="${oss_input:-$default_oss_dest}"
        read -p "Destination for remaining files/folders [${default_rest_dest}]: " rest_input
        rest_dest="${rest_input:-$default_rest_dest}"
        mkdir -p "$(dirname "$oss_dest")" "$rest_dest"
        disk_check_path="$(dirname "$oss_dest")"
    else
        echo
        read -p "Download directory [${default_download}]: " download_input
        local download_base="${download_input:-$default_download}"
        download_dir_path="${download_base}/${kb_version}"
        mkdir -p "$download_base"
        disk_check_path="$download_base"
    fi

    # Fetch metadata and check disk space
    echo
    echo "Fetching ${label} metadata..."
    local metadata_content
    metadata_content=$(read_remote_file "${remote_path}/${kb_version}/metadata.json" 2>/dev/null || true)

    if [[ -n "$metadata_content" ]]; then
        local remote_size
        remote_size=$(echo "$metadata_content" | grep -o '"total_size_bytes":[[:space:]]*[0-9]*' | grep -o '[0-9]*$')

        if [[ -n "$remote_size" && "$remote_size" -gt 0 ]]; then
            local local_free
            local_free=$(df -B1 "$disk_check_path" | awk 'NR==2 {print $4}')
            local remote_hr
            remote_hr=$(numfmt --to=iec "$remote_size")
            local local_hr
            local_hr=$(numfmt --to=iec "$local_free")

            echo "${label^} size: ${remote_hr}"
            echo "Free space:  ${local_hr} (on $(df "$disk_check_path" | awk 'NR==2 {print $1}'))"

            if (( local_free < remote_size )); then
                echo
                echo "WARNING: Not enough disk space. Need ${remote_hr} but only ${local_hr} available."
                if [[ "$mode" == "full" ]]; then
                    echo "(Note: for full KB the 'oss' folder and the remaining files may end up on different"
                    echo " filesystems. The check above is against ${disk_check_path}.)"
                fi
                log "Insufficient disk space for ${kb_version}: need ${remote_hr}, have ${local_hr} (user confirm)"
                while true; do
                    read -p "Continue download anyway? [y/N] " yn
                    yn="${yn:-n}"
                    case $yn in
                        [Yy]*) echo "Continuing despite low disk space."; break ;;
                        [Nn]*) echo "Aborting download."; return ;;
                        *)     echo "Please answer yes (y) or no (n)." ;;
                    esac
                done
            else
                echo "Disk space OK."
            fi
        fi
    else
        echo "WARN: metadata.json not found on server, skipping disk space check."
    fi

    # Prompt for thread count if using lftp
    if [[ "$DOWNLOAD_TOOL" == "lftp" ]]; then
        read -p "lftp parallel threads [${LFTP_THREADS}]: " threads_input
        LFTP_THREADS="${threads_input:-$LFTP_THREADS}"
    fi

    # Download
    echo
    local prompt_dest
    if [[ "$mode" == "full" ]]; then
        prompt_dest="${oss_dest} + ${rest_dest}"
    else
        prompt_dest="${download_dir_path}"
    fi
    while true; do
        read -p "Download ${label} ${kb_version} to ${prompt_dest}? [Y/n] " yn
        yn="${yn:-y}"
        case $yn in
            [Yy]*)
                log "Starting download of ${label} ${kb_version}"

                if [[ "$mode" == "full" ]]; then
                    download_full_kb "${remote_path}/${kb_version}" "$oss_dest" "$rest_dest"
                    echo
                    echo "Full KB downloaded:"
                    echo "  oss folder:  ${oss_dest}"
                    echo "  other files: ${rest_dest}"
                    log "Full KB ${kb_version} downloaded: oss=${oss_dest}, rest=${rest_dest}"
                    echo
                    echo "Finished downloading full KB."
                else
                    download_dir "${remote_path}/${kb_version}" "$download_dir_path"
                    echo
                    echo "${label^} downloaded to ${download_dir_path}"
                    log "${label^} downloaded to ${download_dir_path}"
                    echo
                    echo "Finished downloading update."
                    echo "Please run the ldb-import.sh script provided inside the update folder to import into the KB:"
                    echo "  ${download_dir_path}/ldb-import.sh"
                fi

                break
                ;;
            [Nn]*)
                echo "Skipping download."
                return
                ;;
            *)
                echo "Please answer yes (y) or no (n)."
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

parse_args "$@"

echo "SCANOSS Knowledge Base Download"
echo "================================"
log "Starting knowledge base download script..."

init_download_tool
[[ "$DOWNLOAD_TOOL" == "sftp" ]] && check_sshpass
prompt_missing_mode
prompt_missing_connection

if [[ "$MODE" == "test" ]]; then
    kb_download_test
else
    kb_download "$MODE"
fi
