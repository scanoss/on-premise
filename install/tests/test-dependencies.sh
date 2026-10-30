#!/bin/bash
# test-dependencies.sh — Runs install-scanoss.sh inside clean Docker containers
# and checks that:
#   1. Option 2 (install system dependencies) installs every tool and library
#      the SCANOSS components and scripts need.
#   2. The real engine and ldb packages (downloaded from their GitHub releases)
#      install and run: first an older release, then an upgrade to a newer one.
#      Older .deb packages declare Depends: libgcrypt20-dev, which option 2
#      does not install, so this checks the installer resolves declared
#      package dependencies.
#   3. On Debian, a system left with half-configured packages by a previous
#      failed install (dpkg -i) is repaired by option 2.
#
# Usage: ./test-dependencies.sh [image ...]
#   Default images cover both installer variants: Debian (apt) and the
#   Fedora/RHEL family (dnf). Logs are written to $LOG_DIR (default: a temp dir).
#   Package versions can be changed with OLD_ENGINE, OLD_LDB, NEW_ENGINE and
#   NEW_LDB.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="${LOG_DIR:-$(mktemp -d)}"
PKG_DIR="$LOG_DIR/packages"

DEFAULT_IMAGES=(debian:12 debian:13 rockylinux:8 rockylinux:9)
IMAGES=("${@:-${DEFAULT_IMAGES[@]}}")

OLD_ENGINE="${OLD_ENGINE:-5.4.25}"
OLD_LDB="${OLD_LDB:-4.1.11}"
NEW_ENGINE="${NEW_ENGINE:-5.4.28}"
NEW_LDB="${NEW_LDB:-4.1.13}"

# Commands used by install-scanoss.sh, kb-download.sh, test.sh and the
# services' env-setup.sh / startup scripts
REQUIRED_COMMANDS=(gzip tar curl lftp sshpass ssh sftp)
# Shared libraries linked by engine, ldb and scanoss-encoder
REQUIRED_LIBS=(libsodium.so.23 libgcrypt.so.20 libz.so.1)

# Executed inside the container
read -r -d '' CONTAINER_SCRIPT <<'EOF'
installer() { bash /src/install/install-scanoss.sh 2>&1 | tee /tmp/installer.out; }
fail=0
check() { if eval "$2" &>/dev/null; then echo "OK   $1"; else echo "FAIL $1"; fail=1; fi; }
# Errors are reported both in the log file and only on screen (echo)
no_errors() {
    if grep -qE "Error:|command not found" /var/log/scanoss-install.log /tmp/installer.out 2>/dev/null; then
        echo "FAIL $1: installer reported errors"
        grep -hE "Error:|command not found" /var/log/scanoss-install.log /tmp/installer.out | sort -u | sed 's/^/     /'
        fail=1
    else
        echo "OK   $1: no installer errors"
    fi
    rm -f /var/log/scanoss-install.log /tmp/installer.out
}
if [ -f /etc/debian_version ]; then
    pkg_ok() { [ "$(dpkg-query -W -f='${Status} ${Version}' "$1")" = "install ok installed $2" ]; }
else
    pkg_ok() { [ "$(rpm -q --qf '%{VERSION}' "$1")" = "$2" ]; }
fi
# Puts the engine/ldb packages of a release where install_engine/install_ldb look
stage() {
    rm -rf /opt/scanoss/engine/latest /opt/scanoss/ldb/latest
    mkdir -p /opt/scanoss/engine/latest /opt/scanoss/ldb/latest
    cp /packages/*scanoss[-_]"$1"[-_]* /opt/scanoss/engine/latest/
    cp /packages/ldb[-_]"$2"[-_]* /opt/scanoss/ldb/latest/
}

# 3. Debian only: leave engine/ldb half-configured, as dpkg -i does when a
#    declared dependency is missing; option 2 must repair it.
if [ -f /etc/debian_version ]; then
    echo "=== broken dpkg state"
    dpkg -i /packages/scanoss_${OLD_ENGINE}_amd64.deb /packages/ldb_${OLD_LDB}_amd64.deb &>/dev/null
    dpkg-query -W -f='${Status}\n' scanoss | grep -q "half-configured\|unpacked" \
        && echo "     (engine left half-configured, as expected)"
fi

# 1. Dependencies
echo "=== option 2: dependencies"
printf "2\n9\n" | installer
no_errors "dependencies"
for c in $REQUIRED_COMMANDS; do check "cmd $c" "command -v $c"; done
for l in $REQUIRED_LIBS; do check "lib $l" "ldconfig -p | grep -q $l"; done
if [ -f /etc/debian_version ]; then
    check "broken packages repaired" "! dpkg -l | grep -qE '^(iU|iF)'"
fi

# 2. Engine and ldb packages: older release, then upgrade
for release in "$OLD_ENGINE $OLD_LDB" "$NEW_ENGINE $NEW_LDB"; do
    set -- $release
    echo "=== option 5: install ldb $2 and engine $1"
    stage "$1" "$2"
    # Same order as install_all: ldb (5 -> 3), then engine (5 -> 2)
    printf "5\n3\n5\n2\n9\n" | installer
    no_errors "engine $1 / ldb $2"
    check "engine $1 installed" "pkg_ok scanoss $1"
    check "ldb $2 installed" "pkg_ok ldb $2"
    check "scanoss -v runs" "scanoss -v | grep -q $1"
    check "ldb -v runs" "ldb -v | grep -q $2"
done
exit $fail
EOF

if ! command -v docker &>/dev/null; then
    echo "Error: docker is required to run these tests."
    exit 1
fi

# Downloads the .deb and .rpm of a release from GitHub
fetch_release() {
    local repo="$1" version="$2" deb="$3" rpm="$4" f
    for f in "$deb" "$rpm"; do
        [[ -s "$PKG_DIR/$f" ]] && continue
        curl -fsSL -o "$PKG_DIR/$f" "https://github.com/scanoss/$repo/releases/download/v$version/$f" \
            || { echo "Error: could not download $f from scanoss/$repo v$version."; exit 1; }
    done
}

mkdir -p "$PKG_DIR"
echo "Downloading engine $OLD_ENGINE/$NEW_ENGINE and ldb $OLD_LDB/$NEW_LDB packages..."
for v in "$OLD_ENGINE" "$NEW_ENGINE"; do
    fetch_release engine "$v" "scanoss_${v}_amd64.deb" "scanoss-${v}-1.x86_64.rpm"
done
for v in "$OLD_LDB" "$NEW_LDB"; do
    fetch_release ldb "$v" "ldb_${v}_amd64.deb" "ldb-${v}-1.x86_64.rpm"
done

run_image() {
    local image="$1"
    local log="$LOG_DIR/$(echo "$image" | tr ':/' '--').log"
    docker run --rm \
        -e REQUIRED_COMMANDS="${REQUIRED_COMMANDS[*]}" \
        -e REQUIRED_LIBS="${REQUIRED_LIBS[*]}" \
        -e OLD_ENGINE="$OLD_ENGINE" -e OLD_LDB="$OLD_LDB" \
        -e NEW_ENGINE="$NEW_ENGINE" -e NEW_LDB="$NEW_LDB" \
        -v "$REPO_DIR:/src:ro" \
        -v "$PKG_DIR:/packages:ro" \
        "$image" bash -c "$CONTAINER_SCRIPT" > "$log" 2>&1
}

echo "Testing on: ${IMAGES[*]}"
echo "Logs: $LOG_DIR"
echo ""

declare -A pids
for image in "${IMAGES[@]}"; do
    run_image "$image" &
    pids[$image]=$!
done

failed=0
for image in "${IMAGES[@]}"; do
    log="$LOG_DIR/$(echo "$image" | tr ':/' '--').log"
    if wait "${pids[$image]}"; then
        printf "%-20s PASS\n" "$image"
    else
        printf "%-20s FAIL\n" "$image"
        grep -E "^FAIL|^     " "$log" | sed 's/^/    /'
        failed=1
    fi
done

exit $failed
