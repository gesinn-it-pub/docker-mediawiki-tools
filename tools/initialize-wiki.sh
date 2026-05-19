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

    # Disable search index updates during initial MW setup.
    #
    # Background: CirrusSearch registers its own LinksUpdate hooks (e.g.
    # onLinksUpdateCompleted in Hooks.php) that queue Job\LinksUpdate jobs
    # independently of MW core's SearchUpdate mechanism. These hooks fire during
    # update.php for any page that gets a links-table entry, and lazyPush() the
    # jobs to the job queue — WITHOUT checking $wgDisableSearchUpdate.
    #
    # If those jobs are later processed (e.g. by Ofelia's run-jobs.sh) AFTER
    # initialize_cirrus() has filled the ES index via ForceSearchIndex, they
    # will overwrite/delete the freshly indexed documents, leaving ES empty.
    #
    # The fix requires two things:
    # 1. Set $wgCirrusSearchDisableUpdate=true in addition to $wgDisableSearchUpdate.
    #    CirrusSearch's Job\JobTraits::run() checks this flag and skips the job
    #    entirely (see JobTraits.php: "Skipping job: search updates disabled").
    # 2. Keep TMP active until run-jobs.sh has drained the queue (see call below),
    #    so all CirrusSearch jobs queued by update.php are processed as no-ops.
    #    Only after the queue is empty is TMP removed and initialize_cirrus called,
    #    guaranteeing ForceSearchIndex is the final step that writes to ES.
    if [ "$ELASTICSEARCH_HOST" != "" ]; then
        # shellcheck disable=SC2016
        echo '<?php $wgDisableSearchUpdate = true; $wgCirrusSearchDisableUpdate = true;' > LocalSettings.TMP.php
    fi

    sudo -u www-data php maintenance/update.php --skip-external-dependencies --quick

    # TMP is intentionally NOT deleted here — run-jobs.sh (called next in the
    # main script) must drain the queue while both disable flags are active.

    echo "=== Setting up LocalSettings.php ==="
}

initialize_cirrus() {
    if [ "$ELASTICSEARCH_HOST" != "" ]; then
        echo "--- Initializing Cirrus Search ---"
        echo "Waiting for elasticsearch server to be ready..."
        wait-for-it.sh -h "$ELASTICSEARCH_HOST" -p 9200 -t 120
        # shellcheck disable=SC2016
        echo '<?php $wgDisableSearchUpdate = true; $wgCirrusSearchDisableUpdate = true;' > LocalSettings.TMP.php
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
        # Drain the job queue while LocalSettings.TMP.php is still active (both
        # $wgDisableSearchUpdate and $wgCirrusSearchDisableUpdate are set), so
        # CirrusSearch jobs queued by update.php are processed as no-ops.
        # Only then remove TMP and run initialize_cirrus, ensuring ForceSearchIndex
        # is the last operation that writes to Elasticsearch.
        run-jobs.sh
        rm -f LocalSettings.TMP.php
        initialize_cirrus
        save_settings
    fi
fi