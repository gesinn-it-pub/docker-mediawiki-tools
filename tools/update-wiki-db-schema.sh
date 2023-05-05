#!/bin/bash

set -euo pipefail

php /var/www/html/maintenance/update.php --quick

# Possibly need to save updated .smw.json
save-wiki-settings.sh
