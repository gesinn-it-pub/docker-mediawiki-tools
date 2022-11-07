#!/bin/bash

set -euo pipefail

cp /data/LocalSettings.php /var/www/html
if [ -e /data/.smw.json ]; then
    cp /data/.smw.json /var/www/html/extensions/SemanticMediaWiki
fi
