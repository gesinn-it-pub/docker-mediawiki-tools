#!/bin/bash
# Downloads a tarball from $2 and unpacks it into extensions/$1.
# Fails (exit != 0) on any download, unpack or empty-result error.
set -euo pipefail

EXTENSION=$1
EXTENSION_URL=${2}

echo "Getting $EXTENSION_URL ..."

TGZ_FILE=$(mktemp "/tmp/$EXTENSION.XXXXXX.tgz")
EXTENSION_FOLDER=extensions/$EXTENSION
CREATED=0
trap 'rm -f "$TGZ_FILE"; if [ "$CREATED" = 1 ] && [ "$?" != 0 ]; then rm -rf "$EXTENSION_FOLDER"; fi' EXIT

curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 3 \
    --connect-timeout 10 --max-time 120 \
    "$EXTENSION_URL" -o "$TGZ_FILE"

mkdir "$EXTENSION_FOLDER"
CREATED=1
tar -xzf "$TGZ_FILE" -C "$EXTENSION_FOLDER" --strip-components 1

if [ -z "$(ls -A "$EXTENSION_FOLDER")" ]; then
    echo "ERROR: $EXTENSION_FOLDER is empty after unpacking $EXTENSION_URL" >&2
    exit 1
fi

printf "Done.\n\n"
