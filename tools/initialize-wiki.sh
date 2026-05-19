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

    # Disable CirrusSearch deferred updates during initial MW setup.
    #
    # Background: extensions that create wiki pages during update.php (e.g. via
    # vocabulary or schema imports) queue SearchUpdate deferred jobs for those
    # pages. Because LocalSettings.TMP.php is already in the include chain (see
    # line above), setting $wgDisableSearchUpdate=true here prevents those jobs
    # from being enqueued in the first place.
    #
    # Without this guard the queued SearchUpdate jobs execute at the start of the
    # next MW maintenance script (UpdateSearchIndexConfig.php). They send bulk
    # documents to the "wiki_content" index via the ES auto-create mechanism,
    # turning it into a plain index. UpdateSearchIndexConfig.php then tries to
    # register "wiki_content" as an alias pointing to "wiki_content_first", which
    # fails with: "There is currently an index with the name of the alias."
    #
    # Important: $wgDisableSearchUpdate=true only suppresses *new* enqueue
    # operations — it has no effect on jobs already in the queue — so it must be
    # set before update.php runs. There is no downside to skipping search updates
    # here because ForceSearchIndex.php (called by initialize_cirrus below)
    # rebuilds the full ES index from scratch anyway.
    if [ "$ELASTICSEARCH_HOST" != "" ]; then
        echo '<?php $wgDisableSearchUpdate = true;' > LocalSettings.TMP.php
    fi

    sudo -u www-data php maintenance/update.php --skip-external-dependencies --quick

    # Remove TMP after update.php so initialize_cirrus() can create it cleanly.
    # (initialize_cirrus appends to TMP via >>; starting from an empty file
    # avoids a duplicate <?php opening tag which would be a PHP parse error.)
    rm -f LocalSettings.TMP.php

    echo "=== Setting up LocalSettings.php ==="
}

initialize_cirrus() {
    if [ "$ELASTICSEARCH_HOST" != "" ]; then
        echo "--- Initializing Cirrus Search ---"
        echo "Waiting for elasticsearch server to be ready..."
        wait-for-it.sh -h $ELASTICSEARCH_HOST -p 9200 -t 120
        echo '<?php $wgDisableSearchUpdate = true; echo "*** Inside TMP ***\n"; ' >> LocalSettings.TMP.php
        # Ensure LocalSettings.TMP.php is always removed, even if a command below
        # fails and set -e aborts the script (prevents stale TMP on container restart)
        trap 'rm -f LocalSettings.TMP.php' EXIT
        php extensions/Cirrussearch/maintenance/UpdateSearchIndexConfig.php
        php extensions/Cirrussearch/maintenance/ForceSearchIndex.php --skipLinks --indexOnSkip
        php extensions/Cirrussearch/maintenance/ForceSearchIndex.php --skipParse
        rm -f LocalSettings.TMP.php
        trap - EXIT
    fi
}

save_settings() {
    echo "--- Saving LocalSettings for later ---"
    save-wiki-settings.sh
}

restore_settings() {
    restore-wiki-settings.sh
}

# Remove any stale LocalSettings.TMP.php left over from a previous failed initialization
rm -f LocalSettings.TMP.php

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
fi