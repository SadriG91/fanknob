#!/bin/sh

set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
SCRATCH=$(mktemp -d "/tmp/fanknob-postinstall.XXXXXX")
trap '/bin/rm -rf "$SCRATCH"' EXIT INT TERM

VOLUME="$SCRATCH/volume"
STUBS="$SCRATCH/bin"
LOG="$SCRATCH/commands.log"
SOCKET="$SCRATCH/fanknobd.sock"
APP="$VOLUME/Applications/Fanknob.app"

mkdir -p "$STUBS" "$APP"
: >"$LOG"

# No colon in the expansion: ${VAR-alice} keeps a set-but-EMPTY value, so the
# no-console case (empty user) is actually reachable through the stub.
cat >"$STUBS/stat" <<'EOF'
#!/bin/sh
echo "${FANKNOB_TEST_CONSOLE_USER-alice}"
EOF

cat >"$STUBS/id" <<'EOF'
#!/bin/sh
[ "$1" = "-u" ] || exit 2
echo 502
EOF

cat >"$STUBS/launchctl" <<'EOF'
#!/bin/sh
echo "launchctl $*" >>"$FANKNOB_TEST_LOG"
if [ "$1" = "bootstrap" ]; then
    /usr/bin/python3 - "$FANKNOB_TEST_SOCKET" <<'PY'
import socket
import sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.close()
PY
fi
exit 0
EOF

cat >"$STUBS/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF

chmod +x "$STUBS/stat" "$STUBS/id" "$STUBS/launchctl" "$STUBS/sleep"

run_postinstall() {
    /bin/rm -f "$SOCKET"
    FANKNOB_TEST_SOCKET="$SOCKET" \
    FANKNOB_TEST_LOG="$LOG" \
    FANKNOB_TEST_CONSOLE_USER="$1" \
    PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
        "$ROOT/packaging/scripts/postinstall" ignored ignored "$VOLUME"
}

run_postinstall alice
grep -Fqx "launchctl asuser 502 pkill -U 502 -x FanknobApp" "$LOG" || {
    echo "postinstall test failed: process restart was not scoped to console UID" >&2
    exit 1
}
grep -Fqx "launchctl asuser 502 sudo -u alice open $APP" "$LOG" || {
    echo "postinstall test failed: app was not launched in the console session" >&2
    exit 1
}

: >"$LOG"
run_postinstall root
if grep -q "asuser" "$LOG"; then
    echo "postinstall test failed: app launch attempted without a console user" >&2
    exit 1
fi

# No console session at all (stat reports an empty user): launch_app must bail
# before running `launchctl asuser "" pkill -U ""` as root.
: >"$LOG"
run_postinstall ""
if grep -q "asuser" "$LOG"; then
    echo "postinstall test failed: app launch attempted with no console session" >&2
    exit 1
fi

echo "postinstall tests passed"
