#!/bin/bash

## run-jobs.sh
##
## Options added:
##   -q, --quiet    Suppress informational output. Errors continue to be
##                  written to stderr so failures remain visible.
##   -s, --silent   Suppress all output (redirects both stdout and stderr
##                  to /dev/null). This implies --quiet.
##   -h, --help     Print a short usage message and exit.
##
## Examples:
##   Run normally:
##     tools/run-jobs.sh
##
##   Suppress informational output but still see errors:
##     tools/run-jobs.sh --quiet
##
##   Run completely silently (no output at all):
##     tools/run-jobs.sh --silent
##
## Notes:
##   - Informational messages in the script use the helper `info()` which
##     checks the quiet flag. Error messages intentionally still write to
##     stderr so that they appear unless `--silent` is used.
##

MAX_TIME=240
MEMORY_LIMIT=2G
MAX_JOBS=200
MW_PATH="/var/www/html"

set -euo pipefail

QUIET=0
SILENT=0

# Parse simple long/short options. -q/--quiet: suppress informational output.
# -s/--silent: suppress all output (redirect stdout+stderr to /dev/null).
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -q|--quiet)
      QUIET=1
      shift
      ;;
    -s|--silent)
      QUIET=1
      SILENT=1
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [-q|--quiet] [-s|--silent]" 
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
  esac
done

if [ "$SILENT" -eq 1 ]; then
  exec >/dev/null 2>&1
fi

cd "$MW_PATH"

info() { if [ "${QUIET:-0}" -eq 0 ]; then echo "$@"; fi }

info "Running jobs"

get_queued_jobs() {
    php maintenance/showJobs.php --group \
      | { grep -o '[0-9]\+ queued;' || echo '0 queued;'; } \
      | sed 's/ queued;//' \
      | awk '{ sum += $1 } END { print sum }'
}
# └─ If grep finds nothing, it would normally exit non-zero.
#    We catch that and emit “0 queued;” so the pipeline returns 0.

n=1
j=$(get_queued_jobs)
if ! [[ "$j" =~ ^[0-9]+$ ]]; then
  echo "Error: get_queued_jobs returned unexpected output: '$j'" >&2
  exit 1
fi

while [ "$j" -gt 0 ]; do
    info "Loop $n: $j jobs queued"
    sudo -u www-data php maintenance/runJobs.php \
    -q --maxtime "$MAX_TIME" --memory-limit "$MEMORY_LIMIT" --maxjobs "$MAX_JOBS" \
    || {
        echo "runJobs.php failed with exit code $?" >&2
        break
    }
    # └─ If runJobs.php errors, report and break out of the loop.
    ((n++))
    j=$(get_queued_jobs)
done

info "No queued jobs left."