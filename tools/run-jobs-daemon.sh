#!/bin/bash
## run-jobs-daemon.sh [job-runner.php options...]
##
## Keeps the long-running job runner (job-runner.php) alive as www-data, in
## the foreground. After a planned exit (exit code 0: a batch with jobs was
## done in --isolation=exit mode, --max-runtime or memory limit reached) the
## runner is restarted at once; after an error it is restarted after a 1 s
## pause, so a persistent failure cannot spin.
##
## A lock makes a second instance with the same arguments exit immediately
## (status 0), so this can be started repeatedly, e.g. by an Ofelia job-exec
## as watchdog, without ever running two runners. SIGTERM/SIGINT are passed
## on to the runner and end the loop.
##
## Environment:
##   RUN_JOBS_PHP_OPTS  PHP options for the runner. Default: OPcache with a
##                      file cache (opcache.enable_cli is off in the image;
##                      a shared-memory cache is useless for short-lived CLI
##                      processes). Set to "" to disable.
##   RUN_JOBS_LOCK_FILE, RUN_JOBS_WAKE_SOCKET: see job-runner.php.
##
## Example:   run-jobs-daemon.sh --type=smw.update --then-all

set -u

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

key="$(printf '%s_' "$@" | tr -c 'A-Za-z0-9._=-' _)"
exec 9>"/tmp/run-jobs-daemon.${key}.flock"
flock -n 9 || exit 0

if [ "${RUN_JOBS_PHP_OPTS+set}" != "set" ]; then
  # The cache directory is private to www-data (it holds executable code).
  cache_dir=/tmp/php-opcache-cli
  if install -d -o www-data -m 700 "$cache_dir" 2>/dev/null; then
    RUN_JOBS_PHP_OPTS="-d opcache.enable_cli=1 -d opcache.file_cache=$cache_dir -d opcache.file_cache_only=1"
  else
    RUN_JOBS_PHP_OPTS=""
  fi
fi
read -r -a php_opts <<< "$RUN_JOBS_PHP_OPTS"

stop=0
pid=""
trap 'stop=1; [ -n "$pid" ] && kill -TERM "$pid" 2>/dev/null' TERM INT

while [ "$stop" = 0 ]; do
  # fd 9 is closed for the runner so that it never keeps the lock alive.
  sudo -u www-data php "${php_opts[@]}" "$TOOLS_DIR/job-runner.php" "$@" 9>&- &
  pid=$!
  wait "$pid"
  rc=$?
  # wait returns early (>128) when a trapped signal arrives; reap the runner.
  [ "$stop" = 1 ] && { wait "$pid" 2>/dev/null; break; }
  pid=""
  if [ "$rc" = 0 ]; then sleep 0.1; else sleep 1; fi
done
