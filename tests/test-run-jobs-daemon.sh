#!/bin/bash
## Test for tools/run-jobs-daemon.sh with stubbed sudo/php (no MediaWiki needed):
## a second instance with the same arguments exits at once, SIGTERM stops the
## daemon and the runner, a failing runner is restarted after a pause.
##
## Usage: bash tests/test-run-jobs-daemon.sh

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DAEMON="$ROOT/tools/run-jobs-daemon.sh"
tmp="$(mktemp -d)"
args="--test=$$"
fail=0
trap 'rm -rf "$tmp" /tmp/run-jobs-daemon.*"test=$$"*.flock' EXIT

check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: expected '$2', got '$3'"; fail=1; fi; }

printf '#!/bin/sh\nshift 2; exec "$@"\n' > "$tmp/sudo"
printf '#!/bin/sh\necho start >> "%s/log"\nexec sleep 30\n' "$tmp" > "$tmp/php"
chmod +x "$tmp/sudo" "$tmp/php"
export RUN_JOBS_PHP_OPTS=""

PATH="$tmp:$PATH" bash "$DAEMON" "$args" & daemon=$!
sleep 1
PATH="$tmp:$PATH" bash "$DAEMON" "$args"
check "second instance exits 0" 0 $?
kill -TERM "$daemon"
wait "$daemon"
check "TERM ends the daemon with 0" 0 $?
check "runner started exactly once" 1 "$(wc -l < "$tmp/log")"

# A failing runner is restarted after a pause (not spun on).
printf '#!/bin/sh\necho start >> "%s/log2"\nexit 1\n' "$tmp" > "$tmp/php"
PATH="$tmp:$PATH" bash "$DAEMON" "$args" & daemon=$!
sleep 2.5
kill -TERM "$daemon"
wait "$daemon"
n=$(wc -l < "$tmp/log2")
check "failing runner restarted 2-4 times in 2.5 s" yes "$([ "$n" -ge 2 ] && [ "$n" -le 4 ] && echo yes || echo "no ($n)")"
exit $fail
