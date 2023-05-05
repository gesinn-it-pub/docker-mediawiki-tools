#!/bin/bash

set -euo pipefail
echo "Rebuilding search index"

cd /var/www/html

php extensions/CirrusSearch/maintenance/UpdateSearchIndexConfig.php --startOver
php extensions/CirrusSearch/maintenance/ForceSearchIndex.php
