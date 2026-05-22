#!/bin/bash
# Don't use set -e: we handle errors per function to avoid killing the whole
# interactive menu when a single component fails.

# Import configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

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

    read -rp "SFTP host [$SFTP_HOST]: " input_host
    SFTP_HOST="${input_host:-$SFTP_HOST}"

    read -rp "SFTP port [$SFTP_PORT]: " input_port
    SFTP_PORT="${input_port:-$SFTP_PORT}"

    read -rp "SFTP username: " SFTP_USER
    read -rsp "SFTP password: " SFTP_PASSWORD
    echo ""

    if [[ -z "$SFTP_USER" || -z "$SFTP_PASSWORD" ]]; then
        echo "Error: username and password are required."
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

    # Save credentials for later use
    echo "SFTP_USER=$SFTP_USER" > ~/.scanoss_sftp
    echo "SFTP_PASSWORD=$SFTP_PASSWORD" >> ~/.scanoss_sftp
    echo "SFTP_HOST=$SFTP_HOST" >> ~/.scanoss_sftp
    echo "SFTP_PORT=$SFTP_PORT" >> ~/.scanoss_sftp
    chmod 600 ~/.scanoss_sftp

    log "SFTP credentials saved to ~/.scanoss_sftp"
}

load_sftp_creds() {
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

    lftp -u "$SFTP_USER","$SFTP_PASSWORD" -p "$SFTP_PORT" "sftp://$SFTP_HOST" -e \
        "set sftp:auto-confirm yes; mirror -c -P 5 $remote_path $local_path; exit" 2>/dev/null

    if [[ -d "$local_path" ]] && ls "$local_path"/* &>/dev/null; then
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

    download_component "engine" "$ENGINE_VERSION"
    download_component "ldb" "$LDB_VERSION"
    download_component "api" "$API_VERSION"
    download_component "scanoss-encoder" "$ENCODER_VERSION"
}

# ─── Install ────────────────────────────────────────────────────────────────

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
            log "Installing engine from $deb"
            dpkg -i "$deb"
            ;;
        CentOS)
            local rpm
            rpm=$(find "$pkg_dir" -name "scanoss*.rpm" | head -1)
            if [[ -z "$rpm" ]]; then
                echo "Error: No engine .rpm package found in $pkg_dir"
                return 1
            fi
            log "Installing engine from $rpm"
            dnf -y install "$rpm"
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
            log "Installing ldb from $deb"
            dpkg -i "$deb"
            ;;
        CentOS)
            local rpm
            rpm=$(find "$pkg_dir" -name "ldb*.rpm" | head -1)
            if [[ -z "$rpm" ]]; then
                echo "Error: No ldb .rpm package found in $pkg_dir"
                return 1
            fi
            log "Installing ldb from $rpm"
            dnf -y install "$rpm"
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

    log "Installing API from $tgz"
    local tmpdir
    tmpdir=$(mktemp -d)
    tar -xzf "$tgz" -C "$tmpdir"

    if [[ -x "$tmpdir/scripts/env-setup.sh" ]]; then
        (cd "$tmpdir/scripts" && ./env-setup.sh)
    else
        echo "Error: env-setup.sh not found in the API package."
        rm -rf "$tmpdir"
        return 1
    fi
    rm -rf "$tmpdir"
}

install_encoder() {
    local version="${ENCODER_VERSION}"
    local pkg_dir="$APP_DIR/scanoss-encoder/$version"

    local tgz
    tgz=$(find "$pkg_dir" -maxdepth 1 -name "*.tar.gz" | head -1)
    if [[ -n "$tgz" ]]; then
        log "Extracting encoder from $tgz"
        tar -xzf "$tgz" -C "$pkg_dir"
    fi

    if [[ -f "$pkg_dir/libscanoss_encoder.so" ]]; then
        cp "$pkg_dir/libscanoss_encoder.so" /usr/lib/libscanoss_encoder.so
        ldconfig
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

install_all() {
    echo ""
    echo "Installing all SCANOSS components"
    echo "──────────────────────────────────"
    create_scanoss_user
    create_directories
    install_engine
    install_ldb
    install_api
    install_encoder
    fix_ownership
    echo ""
    echo "All components installed. Run the test script to verify:"
    echo "  ./test.sh"
}

install_select() {
    echo ""
    echo "Select component to install:"
    select app in "All components" "engine" "ldb" "API" "encoder" "Back"; do
        case "$app" in
            "All components") install_all; break ;;
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

while true; do
    echo ""
    echo "Installation Menu"
    echo "─────────────────"
    echo "1) Install everything (dependencies + download + install)"
    echo "2) Install system dependencies only"
    echo "3) Setup SFTP credentials"
    echo "4) Download components from SFTP"
    echo "5) Install components (from already downloaded files)"
    echo "6) Select versions (current: engine=$ENGINE_VERSION, ldb=$LDB_VERSION, api=$API_VERSION)"
    echo "7) Quit"
    echo ""
    read -rp "Enter your choice [1-7]: " choice

    case "$choice" in
        1)
            create_scanoss_user
            create_directories
            install_dependencies
            setup_sftp
            download_all
            install_all
            ;;
        2) install_dependencies ;;
        3) setup_sftp ;;
        4) download_all ;;
        5) install_select ;;
        6) select_versions ;;
        7) echo "Exiting."; exit 0 ;;
        *) echo "Invalid option." ;;
    esac
done
