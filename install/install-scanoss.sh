#!/bin/bash
# Don't use set -e: we handle errors per function to avoid killing the whole
# interactive menu when a single component fails.

# Import configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Non-interactive mode (-y): never read from stdin. Only valid with -a all,
# which runs the "Install everything" sequence and exits. Meant for scheduled
# jobs (e.g. cron) that keep an installation up to date automatically.
NON_INTERACTIVE=""
ACTION=""
CLI_SFTP_HOST=""
CLI_SFTP_PORT=""
# Decoration services to update with -a all (-s). Empty = none.
DECORATION_SELECTED=()

# Set by install_everything(): install functions skip a component whose package
# is identical to the one recorded at its last successful install.
SKIP_UNCHANGED=""
# One file per component holding the sha256 of the last installed package.
# Kept outside the download folders, which `mirror -e` keeps in sync with SFTP.
INSTALLED_DIR="$APP_DIR/.installed"

usage() {
    echo "Usage: $0 [-y] [-a all] [-s services] [-h host] [-P port] [-u user] [-p password]"
    echo
    echo "Without options the interactive menu is shown."
    echo
    echo "  -a    Action to run without the menu. Only 'all' is supported:"
    echo "        dependencies + SFTP check + download + install core components."
    echo "        Components whose package did not change since their last"
    echo "        install are skipped."
    echo "  -s    With -a all, also download/install decoration services: 'all' or a"
    echo "        comma-separated list of: ${DECORATION_SERVICES[*]}"
    echo "        (default: none)"
    echo "  -h    SFTP host (default: ${SFTP_HOST})"
    echo "  -P    SFTP port (default: ${SFTP_PORT})"
    echo "  -u    SFTP username"
    echo "  -p    SFTP password"
    echo "  -y    Don't prompt (requires -a all). Credentials are taken from -u/-p,"
    echo "        or from ~/.scanoss_sftp saved by a previous run."
    echo "  -?    Show this help"
    echo
    echo "Versions are taken from config.sh."
    exit 0
}

parse_args() {
    local services=""
    while getopts "a:s:h:P:u:p:y?" opt; do
        case $opt in
            a) ACTION="$OPTARG" ;;
            s) services="$OPTARG" ;;
            h) CLI_SFTP_HOST="$OPTARG" ;;
            P) CLI_SFTP_PORT="$OPTARG" ;;
            u) SFTP_USER="$OPTARG" ;;
            p) SFTP_PASSWORD="$OPTARG" ;;
            y) NON_INTERACTIVE=1 ;;
            ?) usage ;;
        esac
    done

    if [[ -n "$ACTION" && "$ACTION" != "all" ]]; then
        echo "Error: invalid action '$ACTION'. Only '-a all' is supported."
        exit 1
    fi
    if [[ -n "$NON_INTERACTIVE" && -z "$ACTION" ]]; then
        echo "Error: -y requires -a all."
        exit 1
    fi
    if [[ -n "$services" ]]; then
        if [[ -z "$ACTION" ]]; then
            echo "Error: -s requires -a all."
            exit 1
        fi
        if [[ "$services" == "all" ]]; then
            DECORATION_SELECTED=("${DECORATION_SERVICES[@]}")
        else
            local svc
            IFS=',' read -ra DECORATION_SELECTED <<< "$services"
            for svc in "${DECORATION_SELECTED[@]}"; do
                if [[ " ${DECORATION_SERVICES[*]} " != *" $svc "* ]]; then
                    echo "Error: unknown decoration service '$svc'. Valid: all, ${DECORATION_SERVICES[*]}"
                    exit 1
                fi
            done
        fi
    fi
    [[ -n "$CLI_SFTP_HOST" ]] && SFTP_HOST="$CLI_SFTP_HOST"
    [[ -n "$CLI_SFTP_PORT" ]] && SFTP_PORT="$CLI_SFTP_PORT"
    if [[ -n "$NON_INTERACTIVE" ]]; then
        export DEBIAN_FRONTEND=noninteractive
    fi
}

# ─── OS Detection ───────────────────────────────────────────────────────────

detect_os() {
    if [ -f /etc/debian_version ]; then
        echo "Debian"
    elif [ -f /etc/redhat-release ] || [ -f /etc/centos-release ]; then
        echo "CentOS"
    else
        echo "Unsupported OS. Supported: Debian 11/12/13, CentOS/RHEL."
        exit 1
    fi
}

# ─── User & Directory Setup ─────────────────────────────────────────────────

create_scanoss_user() {
    if getent passwd "$RUNTIME_USER" > /dev/null 2>&1; then
        log "User $RUNTIME_USER already exists."
    else
        log "Creating system user: $RUNTIME_USER"
        useradd --system --shell /bin/false "$RUNTIME_USER"
    fi
}

create_directories() {
    log "Creating directories..."
    mkdir -p "$APP_DIR" "$LDB_LOCATION" "/var/log/$APP_NAME" "/usr/local/etc/$APP_NAME"
    chown -R "$RUNTIME_USER:$RUNTIME_USER" "/var/log/$APP_NAME" "/usr/local/etc/$APP_NAME"
}

# ─── Dependencies ───────────────────────────────────────────────────────────

install_dependencies() {
    log "Installing system dependencies..."

    local common_packages=(gzip tar unzip curl lftp jq wget)

    case "$OS" in
        Debian)
            # Detect libsodium package name from available packages
            local libsodium_pkg
            libsodium_pkg=$(apt-cache search '^libsodium[0-9]' 2>/dev/null | awk '{print $1}' | head -1)
            if [[ -z "$libsodium_pkg" ]]; then
                libsodium_pkg="libsodium23"
                log "Warning: could not detect libsodium package, falling back to $libsodium_pkg"
            fi

            local deb_packages=(coreutils unrar-free xz-utils p7zip-full "$libsodium_pkg" libgcrypt20-dev)

            apt-get update -qq
            apt-get install -y -qq "${common_packages[@]}" "${deb_packages[@]}"
            ;;
        CentOS)
            local rpm_packages=(coreutils-common xz openssh-clients openssl)

            dnf install -y "${common_packages[@]}" "${rpm_packages[@]}"

            # Build libsodium from source if not installed
            if ! ldconfig -p | grep -q libsodium; then
                log "Building libsodium from source..."
                dnf groupinstall -y 'Development Tools'
                local tmpdir
                tmpdir=$(mktemp -d)
                curl -sL -o "$tmpdir/libsodium.tar.gz" \
                    https://download.libsodium.org/libsodium/releases/libsodium-1.0.20-stable.tar.gz
                tar -xzf "$tmpdir/libsodium.tar.gz" -C "$tmpdir"
                (cd "$tmpdir/libsodium-stable" && ./configure && make -j"$(nproc)" && make install)
                ldconfig
                rm -rf "$tmpdir"
            fi
            ;;
    esac

    log "Dependencies installed."
}

# ─── SFTP Setup ─────────────────────────────────────────────────────────────

setup_sftp() {
    # Check lftp is installed
    if ! command -v lftp &>/dev/null; then
        echo "Error: lftp is not installed. Run option 2 (Install dependencies) first."
        return 1
    fi

    echo ""
    echo "SFTP Credentials"
    echo "──────────────────"

    # Credentials are written to ~/.scanoss_sftp unless they were read from it.
    local save_creds=1

    if [[ -n "$NON_INTERACTIVE" ]]; then
        if [[ -z "$SFTP_USER" && -z "$SFTP_PASSWORD" && -f ~/.scanoss_sftp ]]; then
            source ~/.scanoss_sftp
            # -h/-P still override the saved host/port.
            [[ -n "$CLI_SFTP_HOST" ]] && SFTP_HOST="$CLI_SFTP_HOST"
            [[ -n "$CLI_SFTP_PORT" ]] && SFTP_PORT="$CLI_SFTP_PORT"
            save_creds=""
            echo "Using saved credentials from ~/.scanoss_sftp"
        fi
    else
        read -rp "SFTP host [$SFTP_HOST]: " input_host
        SFTP_HOST="${input_host:-$SFTP_HOST}"

        read -rp "SFTP port [$SFTP_PORT]: " input_port
        SFTP_PORT="${input_port:-$SFTP_PORT}"

        read -rp "SFTP username: " SFTP_USER
        read -rsp "SFTP password: " SFTP_PASSWORD
        echo ""
    fi

    if [[ -z "$SFTP_USER" || -z "$SFTP_PASSWORD" ]]; then
        if [[ -n "$NON_INTERACTIVE" ]]; then
            echo "Error: username and password are required (-u/-p, or ~/.scanoss_sftp)."
        else
            echo "Error: username and password are required."
        fi
        exit 1
    fi

    # Test connection
    echo "Testing connection..."
    if lftp -u "$SFTP_USER","$SFTP_PASSWORD" -p "$SFTP_PORT" "sftp://$SFTP_HOST" -e "set sftp:auto-confirm yes; ls; exit" &>/dev/null; then
        echo "Connection successful."
    else
        echo "Error: Could not connect to SFTP server."
        exit 1
    fi

    [[ -z "$save_creds" ]] && return 0

    # Save credentials for later use
    echo "SFTP_USER=$SFTP_USER" > ~/.scanoss_sftp
    echo "SFTP_PASSWORD=$SFTP_PASSWORD" >> ~/.scanoss_sftp
    echo "SFTP_HOST=$SFTP_HOST" >> ~/.scanoss_sftp
    echo "SFTP_PORT=$SFTP_PORT" >> ~/.scanoss_sftp
    chmod 600 ~/.scanoss_sftp

    log "SFTP credentials saved to ~/.scanoss_sftp"
}

load_sftp_creds() {
    # Already set by setup_sftp in this run.
    [[ -n "$SFTP_USER" && -n "$SFTP_PASSWORD" ]] && return 0

    if [[ -f ~/.scanoss_sftp ]]; then
        source ~/.scanoss_sftp
    else
        echo "No saved SFTP credentials found. Run 'Setup SFTP Credentials' first."
        return 1
    fi
}

# ─── Download ───────────────────────────────────────────────────────────────

download_component() {
    local component="$1"
    local version="$2"

    if ! command -v lftp &>/dev/null; then
        echo "Error: lftp is not installed. Run option 2 (Install dependencies) first."
        return 1
    fi

    load_sftp_creds || return 1

    local remote_path="/binaries/$component/$version"
    local local_path="$APP_DIR/$component/$version"

    echo "Downloading $component ($version) from SFTP..."
    mkdir -p "$local_path"

    # Check lftp's exit status too: on a failed mirror the previous version's
    # files are still in $local_path, so a non-empty directory proves nothing.
    if lftp -u "$SFTP_USER","$SFTP_PASSWORD" -p "$SFTP_PORT" "sftp://$SFTP_HOST" -e \
        "set sftp:auto-confirm yes; mirror -c -e -P 5 $remote_path $local_path; exit" 2>/dev/null \
        && [[ -d "$local_path" ]] && ls "$local_path"/* &>/dev/null; then
        log "Downloaded $component $version to $local_path"
        echo "$component $version downloaded successfully."
    else
        echo "Error: Download of $component $version failed or directory is empty."
        return 1
    fi
}

download_all() {
    echo ""
    echo "Downloading SCANOSS components"
    echo "──────────────────────────────"
    echo "Versions: engine=$ENGINE_VERSION, ldb=$LDB_VERSION, api=$API_VERSION, encoder=$ENCODER_VERSION"
    echo ""

    local rc=0
    download_component "engine" "$ENGINE_VERSION" || rc=1
    download_component "ldb" "$LDB_VERSION" || rc=1
    download_component "api" "$API_VERSION" || rc=1
    download_component "scanoss-encoder" "$ENCODER_VERSION" || rc=1
    return $rc
}

# ─── Install ────────────────────────────────────────────────────────────────

# Returns 0 (skip) when SKIP_UNCHANGED is set and $pkg is the same file that
# was recorded at the last successful install of $component.
skip_if_unchanged() {
    local component="$1" pkg="$2"
    [[ -n "$SKIP_UNCHANGED" && -f "$INSTALLED_DIR/$component" ]] || return 1
    if [[ "$(cat "$INSTALLED_DIR/$component")" == "$(sha256sum "$pkg" | cut -d' ' -f1)" ]]; then
        log "$component: $(basename "$pkg") already installed, skipping."
        return 0
    fi
    return 1
}

mark_installed() {
    local component="$1" pkg="$2"
    mkdir -p "$INSTALLED_DIR"
    sha256sum "$pkg" | cut -d' ' -f1 > "$INSTALLED_DIR/$component"
}

install_engine() {
    local version="${ENGINE_VERSION}"
    local pkg_dir="$APP_DIR/engine/$version"

    case "$OS" in
        Debian)
            local deb
            deb=$(find "$pkg_dir" -name "scanoss_*_amd64.deb" | head -1)
            if [[ -z "$deb" ]]; then
                echo "Error: No engine .deb package found in $pkg_dir"
                return 1
            fi
            skip_if_unchanged engine "$deb" && return 0
            log "Installing engine from $deb"
            dpkg -i "$deb" || return 1
            mark_installed engine "$deb"
            ;;
        CentOS)
            local rpm
            rpm=$(find "$pkg_dir" -name "scanoss*.rpm" | head -1)
            if [[ -z "$rpm" ]]; then
                echo "Error: No engine .rpm package found in $pkg_dir"
                return 1
            fi
            skip_if_unchanged engine "$rpm" && return 0
            log "Installing engine from $rpm"
            dnf -y install "$rpm" || return 1
            mark_installed engine "$rpm"
            ;;
    esac
}

install_ldb() {
    local version="${LDB_VERSION}"
    local pkg_dir="$APP_DIR/ldb/$version"

    case "$OS" in
        Debian)
            local deb
            deb=$(find "$pkg_dir" -name "ldb_*_amd64.deb" | head -1)
            if [[ -z "$deb" ]]; then
                echo "Error: No ldb .deb package found in $pkg_dir"
                return 1
            fi
            skip_if_unchanged ldb "$deb" && return 0
            log "Installing ldb from $deb"
            dpkg -i "$deb" || return 1
            mark_installed ldb "$deb"
            ;;
        CentOS)
            local rpm
            rpm=$(find "$pkg_dir" -name "ldb*.rpm" | head -1)
            if [[ -z "$rpm" ]]; then
                echo "Error: No ldb .rpm package found in $pkg_dir"
                return 1
            fi
            skip_if_unchanged ldb "$rpm" && return 0
            log "Installing ldb from $rpm"
            dnf -y install "$rpm" || return 1
            mark_installed ldb "$rpm"
            ;;
    esac
}

install_api() {
    local version="${API_VERSION}"
    local pkg_dir="$APP_DIR/api/$version"

    local tgz
    tgz=$(find "$pkg_dir" -name "scanoss-go_linux-amd64_*.tgz" -o -name "scanoss-go-api_*.tgz" | head -1)
    if [[ -z "$tgz" ]]; then
        echo "Error: No API .tgz package found in $pkg_dir"
        return 1
    fi

    skip_if_unchanged api "$tgz" && return 0
    log "Installing API from $tgz"
    local tmpdir
    tmpdir=$(mktemp -d)
    tar -xzf "$tgz" -C "$tmpdir"

    if [[ -f "$tmpdir/scripts/env-setup.sh" ]]; then
        chmod +x "$tmpdir/scripts/env-setup.sh"
        if ! (cd "$tmpdir/scripts" && ./env-setup.sh); then
            echo "Error: API env-setup.sh failed."
            rm -rf "$tmpdir"
            return 1
        fi
    else
        echo "Error: env-setup.sh not found in the API package."
        rm -rf "$tmpdir"
        return 1
    fi
    rm -rf "$tmpdir"
    mark_installed api "$tgz"
}

install_encoder() {
    local version="${ENCODER_VERSION}"
    local pkg_dir="$APP_DIR/scanoss-encoder/$version"

    local tgz
    tgz=$(find "$pkg_dir" -maxdepth 1 -name "*.tar.gz" | head -1)
    if [[ -n "$tgz" ]]; then
        skip_if_unchanged encoder "$tgz" && return 0
        log "Extracting encoder from $tgz"
        tar -xzf "$tgz" -C "$pkg_dir"
    fi

    if [[ -f "$pkg_dir/libscanoss_encoder.so" ]]; then
        cp "$pkg_dir/libscanoss_encoder.so" /usr/lib/libscanoss_encoder.so || return 1
        ldconfig
        mark_installed encoder "${tgz:-$pkg_dir/libscanoss_encoder.so}"
        log "scanoss-encoder installed."
    else
        echo "Warning: libscanoss_encoder.so not found in $pkg_dir"
        return 1
    fi
}

fix_ownership() {
    log "Setting ownership for SCANOSS directories..."
    chown -R "$RUNTIME_USER:$RUNTIME_USER" "/var/log/$APP_NAME" 2>/dev/null || true
    chown -R "$RUNTIME_USER:$RUNTIME_USER" "/usr/local/etc/$APP_NAME" 2>/dev/null || true
    [[ -d /bin/scanoss ]] && chown -R "$RUNTIME_USER:$RUNTIME_USER" /bin/scanoss
    [[ -d /bin/ldb ]] && chown -R "$RUNTIME_USER:$RUNTIME_USER" /bin/ldb
    [[ -f /usr/lib/libscanoss_encoder.so ]] && chown "$RUNTIME_USER:$RUNTIME_USER" /usr/lib/libscanoss_encoder.so
}

# ─── Decoration Services ────────────────────────────────────────────────────

DECORATION_SERVICES=(dependencies components vulnerabilities cryptography geoprovenance licenses folder-hashing-api)

install_decoration_service() {
    local service="$1"
    local version="latest"
    local pkg_dir="$APP_DIR/$service/$version"

    local tgz
    tgz=$(find "$pkg_dir" -name "scanoss-${service}-api_linux-amd64_*.tgz" -o -name "scanoss-${service}_linux-amd64_*.tgz" 2>/dev/null | head -1)
    if [[ -z "$tgz" ]]; then
        echo "Error: No .tgz package found for $service in $pkg_dir"
        echo "  Run 'Download components from SFTP' first."
        return 1
    fi

    skip_if_unchanged "$service" "$tgz" && return 0
    log "Installing $service from $tgz"
    local tmpdir
    tmpdir=$(mktemp -d)
    tar -xzf "$tgz" -C "$tmpdir"

    if [[ -f "$tmpdir/scripts/env-setup.sh" ]]; then
        chmod +x "$tmpdir/scripts/env-setup.sh"
        if ! (cd "$tmpdir/scripts" && ./env-setup.sh); then
            echo "Error: $service env-setup.sh failed."
            rm -rf "$tmpdir"
            return 1
        fi
    else
        echo "Error: env-setup.sh not found in the $service package."
        rm -rf "$tmpdir"
        return 1
    fi
    rm -rf "$tmpdir"
    mark_installed "$service" "$tgz"
}

# Downloads the given services, or all of them when called without arguments.
download_decoration_services() {
    local services=("$@")
    [[ ${#services[@]} -eq 0 ]] && services=("${DECORATION_SERVICES[@]}")

    if ! command -v lftp &>/dev/null; then
        echo "Error: lftp is not installed. Run option 2 (Install dependencies) first."
        return 1
    fi
    load_sftp_creds || return 1

    echo ""
    echo "Downloading decoration services"
    echo "────────────────────────────────"
    local rc=0
    for svc in "${services[@]}"; do
        download_component "$svc" "latest" || rc=1
    done
    return $rc
}

install_decoration_select() {
    echo ""
    echo "Select decoration service to install:"
    select svc in "All decoration services" "${DECORATION_SERVICES[@]}" "Back"; do
        case "$svc" in
            "All decoration services")
                for s in "${DECORATION_SERVICES[@]}"; do
                    install_decoration_service "$s"
                done
                break
                ;;
            "Back") break ;;
            *)
                if [[ -n "$svc" ]]; then
                    install_decoration_service "$svc"
                    break
                else
                    echo "Invalid option."
                fi
                ;;
        esac
    done
}

install_all() {
    echo ""
    echo "Installing all SCANOSS components"
    echo "──────────────────────────────────"
    local rc=0
    create_scanoss_user
    create_directories
    install_engine || rc=1
    install_ldb || rc=1
    install_api || rc=1
    install_encoder || rc=1
    fix_ownership
    echo ""
    if [[ $rc -ne 0 ]]; then
        echo "Error: one or more core components failed to install. See $LOG_FILE"
        return 1
    fi
    echo "All core components installed. Run the test script to verify:"
    echo "  ./test.sh"
    echo ""
    echo "To install decoration services, use menu option 8."
}

# Menu option 1 / -a all (plus the -s decoration services). Stops before
# installing if the dependencies, SFTP check or any download fail, and returns
# non-zero so scheduled jobs see it.
install_everything() {
    SKIP_UNCHANGED=1
    create_scanoss_user
    create_directories
    install_dependencies || { echo "Error: dependency installation failed."; return 1; }
    setup_sftp || return 1
    local rc=0
    download_all || rc=1
    if [[ ${#DECORATION_SELECTED[@]} -gt 0 ]]; then
        download_decoration_services "${DECORATION_SELECTED[@]}" || rc=1
    fi
    [[ $rc -eq 0 ]] || { echo "Error: download failed, nothing was installed."; return 1; }

    install_all || rc=1
    local svc
    for svc in "${DECORATION_SELECTED[@]}"; do
        install_decoration_service "$svc" || rc=1
    done
    if [[ ${#DECORATION_SELECTED[@]} -gt 0 && $rc -ne 0 ]]; then
        echo "Error: one or more components failed to install. See $LOG_FILE"
    fi
    return $rc
}

install_select() {
    echo ""
    echo "Select component to install:"
    select app in "All core components" "engine" "ldb" "API" "encoder" "Back"; do
        case "$app" in
            "All core components") install_all; break ;;
            "engine") install_engine; break ;;
            "ldb") install_ldb; break ;;
            "API") install_api; break ;;
            "encoder") install_encoder; break ;;
            "Back") break ;;
            *) echo "Invalid option." ;;
        esac
    done
}

# ─── Version Selection ──────────────────────────────────────────────────────

select_versions() {
    echo ""
    echo "Current versions: engine=$ENGINE_VERSION, ldb=$LDB_VERSION, api=$API_VERSION, encoder=$ENCODER_VERSION"
    echo "(\"latest\" uses the most recent release on SFTP)"
    echo ""
    read -rp "Engine version [$ENGINE_VERSION]: " v
    ENGINE_VERSION="${v:-$ENGINE_VERSION}"
    read -rp "LDB version [$LDB_VERSION]: " v
    LDB_VERSION="${v:-$LDB_VERSION}"
    read -rp "API version [$API_VERSION]: " v
    API_VERSION="${v:-$API_VERSION}"
    read -rp "Encoder version [$ENCODER_VERSION]: " v
    ENCODER_VERSION="${v:-$ENCODER_VERSION}"
    echo "Versions set: engine=$ENGINE_VERSION, ldb=$LDB_VERSION, api=$API_VERSION, encoder=$ENCODER_VERSION"
}

# ─── Main ───────────────────────────────────────────────────────────────────

parse_args "$@"

echo ""
echo "SCANOSS On-Premise Installer"
echo "════════════════════════════"
echo ""

if [[ "$(id -u)" != "0" ]]; then
    echo "This script must be run as root."
    exit 1
fi

OS=$(detect_os)
log "Detected OS: $OS"

mkdir -p "$APP_DIR"

if [[ "$ACTION" == "all" ]]; then
    install_everything
    exit $?
fi

while true; do
    echo ""
    echo "Installation Menu"
    echo "─────────────────"
    echo "1) Install everything (dependencies + download + install core)"
    echo "2) Install system dependencies only"
    echo "3) Setup SFTP credentials"
    echo "4) Download core components from SFTP"
    echo "5) Install core components (from already downloaded files)"
    echo "6) Select versions (current: engine=$ENGINE_VERSION, ldb=$LDB_VERSION, api=$API_VERSION)"
    echo "7) Download decoration services from SFTP"
    echo "8) Install decoration services"
    echo "9) Quit"
    echo ""
    read -rp "Enter your choice [1-9]: " choice

    case "$choice" in
        1) install_everything ;;
        2) install_dependencies ;;
        3) setup_sftp ;;
        4) download_all ;;
        5) install_select ;;
        6) select_versions ;;
        7) download_decoration_services ;;
        8) install_decoration_select ;;
        9) echo "Exiting."; exit 0 ;;
        *) echo "Invalid option." ;;
    esac
done
