#!/bin/bash

## run-jobs.sh
##
## Options added:
##   -q, --quiet      Suppress informational output. Errors continue to be
##                    written to stderr so failures remain visible.
##   -s, --silent     Suppress all output (redirects both stdout and stderr
##                    to /dev/null). This implies --quiet.
##   -t, --type=TYPE  Only process (and only count, for the empty-queue
##                    check) jobs of this one type. Without this option,
##                    every registered job type is processed, same as
##                    before this option existed.
##   -h, --help       Print a short usage message and exit.
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
##   Run a fast, dedicated poll cycle for one latency-sensitive job type
##   only (e.g. on a shorter Ofelia/cron interval than the general one):
##     tools/run-jobs.sh --type=smw.update
##
## Notes:
##   - Informational messages in the script use the helper `info()` which
##     checks the quiet flag. Error messages intentionally still write to
##     stderr so that they appear unless `--silent` is used.
##   - If the lockfile at LOCK_FILE exists, the script exits immediately
##     (exit 0) without processing the job queue. This lets external
##     callers (e.g. backup/restore scripts) pause job execution by
##     creating the lockfile and resume it by removing it, without
##     needing to stop any long-running daemon/service.
##   - The lockfile is also re-checked between batches, not just on
##     startup. Without this, a run already looping through a large
##     backlog (bounded by --maxjobs/--maxtime per batch, but the loop
##     itself is unbounded) would ignore a lockfile created after it
##     started, forcing callers to wait for the entire backlog to drain
##     before it's safe to proceed with a backup/restore.
##   - --type is a single job type, not a list: MediaWiki's own
##     runJobs.php/showJobs.php --type option only accepts one type each,
##     so passing a comma-separated list here would silently pass an
##     invalid value straight through. Run this script once per type
##     (e.g. from separate cron/Ofelia entries with different intervals)
##     if more than one type needs its own dedicated poll cycle.
##   - Deliberately no type allowlist/config file to maintain: omitting
##     --type keeps covering every job type MediaWiki knows about,
##     including ones added later by an extension - this option only
##     narrows an individual invocation, it never needs updating when a
##     new job type appears elsewhere in the wiki.
##

MAX_TIME=240
MEMORY_LIMIT=2G
MAX_JOBS=200
MW_PATH="/var/www/html"
LOCK_FILE="${RUN_JOBS_LOCK_FILE:-/tmp/run-jobs.lock}"

set -euo pipefail

QUIET=0
SILENT=0
JOB_TYPE=""

# Parse simple long/short options. -q/--quiet: suppress informational output.
# -s/--silent: suppress all output (redirect stdout+stderr to /dev/null).
# -t/--type=TYPE (or --type TYPE): restrict processing to one job type - see
# this file's own top-of-file docs for why this takes exactly one type, not
# a list, and why there is no allowlist to maintain when it's omitted.
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
    -t|--type)
      if [[ "$#" -lt 2 ]]; then
        echo "Error: $1 requires a job type argument" >&2
        exit 2
      fi
      JOB_TYPE="$2"
      shift 2
      ;;
    --type=*)
      JOB_TYPE="${1#--type=}"
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [-q|--quiet] [-s|--silent] [-t|--type=TYPE]"
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

info() { if [ "${QUIET:-0}" -eq 0 ]; then echo "$@"; fi }

if [ -f "$LOCK_FILE" ]; then
  info "Lockfile $LOCK_FILE present, skipping job run."
  exit 0
fi

cd "$MW_PATH"

if [ -n "$JOB_TYPE" ]; then
  info "Running jobs (type=$JOB_TYPE)"
else
  info "Running jobs"
fi

get_queued_jobs() {
    # --type is passed through to showJobs.php itself (not just filtered
    # from its output here) so the empty-queue check only ever counts the
    # ONE type this invocation cares about - a run-jobs.sh --type=X
    # instance must not keep looping just because some OTHER type's queue
    # (handled by a separate, differently-scheduled invocation) still has
    # work.
    local -a type_args=()
    if [ -n "$JOB_TYPE" ]; then
      type_args=( --type "$JOB_TYPE" )
    fi

    php maintenance/showJobs.php --group "${type_args[@]}" \
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
    if [ -f "$LOCK_FILE" ]; then
      info "Lockfile $LOCK_FILE present, stopping before next batch."
      exit 0
    fi

    info "Loop $n: $j jobs queued"
    run_jobs_args=( -q --maxtime "$MAX_TIME" --memory-limit "$MEMORY_LIMIT" --maxjobs "$MAX_JOBS" )
    if [ -n "$JOB_TYPE" ]; then
      run_jobs_args+=( --type "$JOB_TYPE" )
    fi
    sudo -u www-data php maintenance/runJobs.php "${run_jobs_args[@]}" \
    || {
        echo "runJobs.php failed with exit code $?" >&2
        break
    }
    # └─ If runJobs.php errors, report and break out of the loop.
    ((n++))
    j=$(get_queued_jobs)
done

info "No queued jobs left."