#!/bin/bash

set -euo pipefail

PASS=wiki4everyone
INSTALLDBUSER=root
INSTALLDBPASS=database
DBNAME=wiki
DBUSER=wiki
DBPASS=wiki
WIKINAME=wiki
ADMIN=WikiSysop

MYSQL_HOST=${MYSQL_HOST:-}
WIKI_PROTOCOL=${WIKI_PROTOCOL:-http}
WIKI_DOMAIN=${WIKI_DOMAIN:-wiki.local}
WIKI_PORT=${WIKI_PORT:-80}

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
sudo -u www-data php maintenance/install.php \
    --scriptpath="" \
    --pass=$PASS \
    --server=$SERVER \
    --dbname=$DBNAME \
    --dbuser=$DBUSER \
    --dbpass=$DBPASS \
    $DB_CONFIG $WIKINAME $ADMIN

run-jobs.sh
