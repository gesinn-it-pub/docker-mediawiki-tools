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
        | grep -o '[0-9]\+ queued;' \
        | sed 's/ queued;//' \
        | awk '{sum += $1} END {print sum}'
}

n=1
j=$(get_queued_jobs)

while [ "$j" -gt 0 ]; do
    echo "Loop $n: $j jobs queued"
    sudo -u www-data php maintenance/runJobs.php -q --maxtime "$MAX_TIME" --memory-limit "$MEMORY_LIMIT" --maxjobs "$MAX_JOBS"
    ((n++))
    j=$(get_queued_jobs)
done

echo "No queued jobs left."