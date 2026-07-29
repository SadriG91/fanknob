#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fanknob-preinstall.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

VOLUME="$SCRATCH/volume"
STUBS="$SCRATCH/bin"
DAEMON="$VOLUME/usr/local/bin/fanknobd"
PLIST="$VOLUME/Library/LaunchDaemons/com.fanknob.daemon.plist"

mkdir -p "$STUBS" "$(dirname "$DAEMON")" "$(dirname "$PLIST")"

cat > "$STUBS/pkgutil" <<'EOF'
#!/bin/sh
[ "${FANKNOB_TEST_RECEIPT:-0}" = "1" ]
EOF
chmod +x "$STUBS/pkgutil"

run_guard() {
    FANKNOB_TEST_RECEIPT="$1"
    export FANKNOB_TEST_RECEIPT
    PATH="$STUBS:$PATH" "$ROOT/packaging/scripts/preinstall" ignored ignored "$VOLUME"
}

expect_success() {
    label="$1"
    receipt="$2"
    if ! run_guard "$receipt" >/dev/null 2>&1; then
        echo "preinstall test failed: $label should succeed" >&2
        exit 1
    fi
}

expect_failure() {
    label="$1"
    receipt="$2"
    if run_guard "$receipt" >"$SCRATCH/output" 2>&1; then
        echo "preinstall test failed: $label should fail" >&2
        exit 1
    fi
    grep -q "source-built copy is already installed" "$SCRATCH/output" || {
        echo "preinstall test failed: $label returned the wrong message" >&2
        cat "$SCRATCH/output" >&2
        exit 1
    }
}

expect_success "clean volume" 0

touch "$DAEMON"
expect_failure "source daemon" 0
expect_success "package upgrade" 1
rm "$DAEMON"

touch "$PLIST"
expect_failure "source launch daemon" 0

echo "preinstall tests passed"
