#!/bin/bash

# To be run after restoring DB

set -euo pipefail

service cron stop

update-wiki-db-schema.sh
run-jobs.sh
update-search-index.sh
run-jobs.sh

service cron start
