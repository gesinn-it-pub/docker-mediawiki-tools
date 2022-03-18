#!/bin/bash

set -euo pipefail

echo "Running jobs"
sudo -u www-data php maintenance/runJobs.php
