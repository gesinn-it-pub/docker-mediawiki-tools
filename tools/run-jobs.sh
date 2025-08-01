#!/bin/bash

MAX_TIME=240
MEMORY_LIMIT=2G
MAX_JOBS=200
MW_PATH="/var/www/html"

set -euo pipefail
cd "$MW_PATH"

echo "Running jobs"

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
    echo "Loop $n: $j jobs queued"
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

echo "No queued jobs left."