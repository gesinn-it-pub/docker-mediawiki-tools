#!/bin/bash

set -euo pipefail

ELASTICSEARCH_HOST=${ELASTICSEARCH_HOST:-}

setup_local_settings() {
    echo "--- Setting up LocalSettings.php ---"

    echo '$wgNetworkEnvironment = [];' >> LocalSettings.php;
    if [ "$ELASTICSEARCH_HOST" != "" ]; then
        echo "\$wgNetworkEnvironment[ 'ELASTICSEARCH_HOST' ] = '$ELASTICSEARCH_HOST';" >> LocalSettings.php;
    fi
    echo 'if (file_exists( "$IP/LocalSettings.Include.php" )) require_once( "$IP/LocalSettings.Include.php" );' >> LocalSettings.php
    echo 'if (file_exists( "$IP/LocalSettings.TMP.php" )) require_once( "$IP/LocalSettings.TMP.php" );' >> LocalSettings.php

    sudo -u www-data php maintenance/update.php --skip-external-dependencies --quick
    echo "=== Setting up LocalSettings.php ==="
}

initialize_cirrus() {
    if [ "$ELASTICSEARCH_HOST" != "" ]; then
        echo "--- Initializing Cirrus Search ---"
        echo "Waiting for elasticsearch server to be ready..."
        wait-for-it.sh -h $ELASTICSEARCH_HOST -p 9200 -t 60
        echo '<?php $wgDisableSearchUpdate = true; echo "*** Inside TMP ***\n"; ' >> LocalSettings.TMP.php
        php extensions/Cirrussearch/maintenance/UpdateSearchIndexConfig.php && \
        rm LocalSettings.TMP.php && \
        php extensions/Cirrussearch/maintenance/ForceSearchIndex.php --skipLinks --indexOnSkip && \
        php extensions/Cirrussearch/maintenance/ForceSearchIndex.php --skipParse
    fi
}

save_settings() {
    echo "--- Saving LocalSettings for later ---"
    save-wiki-settings.sh
}

restore_settings() {
    restore-wiki-settings.sh
}

setup_cron_job() {
    if [ "`type crontab 2>/dev/null`" != "" ]; then
        echo "Setting up cron job for wiki jobs"
        echo "*/1 * * * * /usr/bin/timeout -k 60 300 /usr/local/bin/php /var/www/html/maintenance/runJobs.php --maxtime 50 >> /dev/null 2>&1" | crontab -uwww-data -
    fi
}

if [ -e LocalSettings.php ]; then
    # Case 1: The container has already been started before
    echo ">>> LocalSettings.php exists. Nothing to do."
else
    # Case 2: The container is starting the first time after creation from the image
    echo ">>> LocalSettings.php is missing."

    # Ensure the log folder exists
    mkdir -p /data/log && chown www-data:www-data /data/log

    configure-container.sh

    if [ -e /data/LocalSettings.php ]; then
        # Case 2a: there has already been a running container for this environment
        echo ">>> Settings in /data exist. Taking them."
        restore_settings
    else
        # Case 2a: this is a completely fresh environment which has to be initialized first
        echo ">>> /data/LocalSettings.php missing, too. Need to create one."
        install-mediawiki.sh
        setup_local_settings
        initialize_cirrus
        save_settings
        run-jobs.sh
    fi
    setup_cron_job
fi