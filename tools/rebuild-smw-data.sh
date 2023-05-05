#!/bin/bash

set -euo pipefail
echo "Rebuilding SMW data"

cd /var/www/html

n=1
while [ true ]; do
    echo "Loop $n"
    php extensions/SemanticMediaWiki/maintenance/rebuildData.php -v --auto-recovery \
        && break
    ((n++))
done
