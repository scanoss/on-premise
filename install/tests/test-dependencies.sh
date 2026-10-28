#!/bin/bash
# test-dependencies.sh — Runs install-scanoss.sh option 2 (install system
# dependencies) inside clean Docker containers and checks that every tool and
# library the SCANOSS components and scripts need ends up installed.
#
# Usage: ./test-dependencies.sh [image ...]
#   Default images cover both installer variants: Debian (apt) and the
#   Fedora/RHEL family (dnf). Logs are written to $LOG_DIR (default: a temp dir).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="${LOG_DIR:-$(mktemp -d)}"

DEFAULT_IMAGES=(debian:12 debian:13 rockylinux:8 rockylinux:9)
IMAGES=("${@:-${DEFAULT_IMAGES[@]}}")

# Commands used by install-scanoss.sh, kb-download.sh, test.sh and the
# services' env-setup.sh / startup scripts
REQUIRED_COMMANDS=(gzip tar curl lftp sshpass ssh sftp)
# Shared libraries linked by engine, ldb and scanoss-encoder
REQUIRED_LIBS=(libsodium.so.23 libgcrypt.so.20 libz.so.1)

# Executed inside the container
read -r -d '' CONTAINER_SCRIPT <<'EOF'
printf "2\n9\n" | bash /src/install/install-scanoss.sh
fail=0
if grep -q "Error:" /var/log/scanoss-install.log; then
    echo "FAIL installer reported errors"; fail=1
fi
for c in $REQUIRED_COMMANDS; do
    if command -v "$c" &>/dev/null; then echo "OK   cmd $c"; else echo "FAIL cmd $c"; fail=1; fi
done
for l in $REQUIRED_LIBS; do
    if ldconfig -p | grep -q "$l"; then echo "OK   lib $l"; else echo "FAIL lib $l"; fail=1; fi
done
exit $fail
EOF

if ! command -v docker &>/dev/null; then
    echo "Error: docker is required to run these tests."
    exit 1
fi

run_image() {
    local image="$1"
    local log="$LOG_DIR/$(echo "$image" | tr ':/' '--').log"
    docker run --rm \
        -e REQUIRED_COMMANDS="${REQUIRED_COMMANDS[*]}" \
        -e REQUIRED_LIBS="${REQUIRED_LIBS[*]}" \
        -v "$REPO_DIR:/src:ro" \
        "$image" bash -c "$CONTAINER_SCRIPT" > "$log" 2>&1
}

echo "Testing dependency installation on: ${IMAGES[*]}"
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
        grep -E "^FAIL" "$log" | sed 's/^/    /'
        failed=1
    fi
done

exit $failed
