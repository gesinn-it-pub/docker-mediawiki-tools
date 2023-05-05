#!/bin/bash

MAX_TIME=240
MEMORY_LIMIT=2G

set -euo pipefail
echo "Running jobs"

cd /var/www/html

n=1
j=`php maintenance/showJobs.php --list | wc -l`
while [ $j -gt 0 ]; do
    echo "Loop $n: $j jobs"
    sudo -u www-data php maintenance/runJobs.php -q --maxtime $MAX_TIME --memory-limit $MEMORY_LIMIT
    ((n++))
    j=`php maintenance/showJobs.php --list | wc -l`
done
