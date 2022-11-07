#!/bin/bash

set -euo pipefail

php /var/www/html/maintenance/update.php

# Possibly need to save updated .smw.json
save-wiki-settings.php
