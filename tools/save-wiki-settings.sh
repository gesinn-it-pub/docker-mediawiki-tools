#!/bin/bash

set -euo pipefail

cp /var/www/html/LocalSettings.php /data
if [ -e extensions/SemanticMediaWiki/.smw.json ]; then
    cp /var/www/html/extensions/SemanticMediaWiki/.smw.json /data 
fi
