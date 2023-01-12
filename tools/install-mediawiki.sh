#!/bin/bash

set -euo pipefail

MYSQL_HOST=${MYSQL_HOST:-}
WIKI_PROTOCOL=${WIKI_PROTOCOL:-http}
WIKI_DOMAIN=${WIKI_DOMAIN:-wiki.local}
WIKI_PORT=${WIKI_PORT:-80}
WIKI_LANGUAGE=${WIKI_LANGUAGE:-en}
WIKI_NAME=${WIKI_NAME:-wiki}
WIKI_ADMIN=${WIKI_ADMIN:-WikiSysop}
WIKI_ADMIN_PASS=${WIKI_ADMIN_PASS:-wiki4everyone}

INSTALLDBUSER=${INSTALLDBUSER:-root}
INSTALLDBPASS=${INSTALLDBPASS:-database}
DBNAME=${DBNAME:-wiki}
DBUSER=${DBUSER:-wiki}
DBPASS=${DBPASS:-wiki}

if [ "$MYSQL_HOST" != "" ]; then
    echo "Using mysql db at $MYSQL_HOST."
    DB_CONFIG="--dbtype=mysql --dbserver=$MYSQL_HOST --installdbuser=$INSTALLDBUSER --installdbpass=$INSTALLDBPASS"

    echo "Waiting for mysql server to be ready..."
    wait-for-it.sh -h $MYSQL_HOST -p 3306 -t 60
else
    echo "Using sqlite db"
    SQLITE_DB_PATH=/data/sqlite
    DB_CONFIG="--dbtype=sqlite --dbpath=$SQLITE_DB_PATH"
    mkdir -p $SQLITE_DB_PATH
    chown -R www-data $SQLITE_DB_PATH
fi

echo "Installing MediaWiki"
SERVER="$WIKI_PROTOCOL://$WIKI_DOMAIN:$WIKI_PORT"
SKINS=MonoBook,Timeless,Vector # [1]
sudo -u www-data php maintenance/install.php \
    --scriptpath="" \
    --skins=$SKINS \
    --pass=$WIKI_ADMIN_PASS \
    --server=$SERVER \
    --dbname=$DBNAME \
    --dbuser=$DBUSER \
    --dbpass=$DBPASS \
    --lang=$WIKI_LANGUAGE \
    $DB_CONFIG $WIKI_NAME $WIKI_ADMIN

chown -R www-data:www-data images

run-jobs.sh

# [1] Explicitly pass skins to load here; otherwise MediaWiki will load *all* skins inside the skins directory.
#     This leads to an error if there is a skin depending on an extension (e.g. the chameleon skin depends on the 
#     Bootstrap extension) which has not been loaded yet.
