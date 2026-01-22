#!/bin/bash

# To be run after restoring DB

set -euo pipefail

update-wiki-db-schema.sh
run-jobs.sh
update-search-index.sh
run-jobs.sh