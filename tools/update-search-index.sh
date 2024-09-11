#!/bin/bash

set -euo pipefail
echo "Rebuilding search index"

cd /var/www/html

php extensions/Cirrussearch/maintenance/UpdateSearchIndexConfig.php --startOver
php extensions/Cirrussearch/maintenance/ForceSearchIndex.php
