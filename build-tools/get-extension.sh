#!/bin/bash
# Downloads a tarball from $2 and unpacks it into extensions/$1.
# Fails (exit != 0) on any download, unpack or empty-result error.
set -euo pipefail

EXTENSION=$1
EXTENSION_URL=${2}

echo "Getting $EXTENSION_URL ..."

TGZ_FILE=$(mktemp "/tmp/$EXTENSION.XXXXXX.tgz")
EXTENSION_FOLDER=extensions/$EXTENSION
mkdir -p extensions
TMP_FOLDER=$(mktemp -d "extensions/.$EXTENSION.XXXXXX")
trap 'rm -rf "$TGZ_FILE" "$TMP_FOLDER"' EXIT

curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 3 \
    --connect-timeout 10 --max-time 120 \
    "$EXTENSION_URL" -o "$TGZ_FILE"

tar -xzf "$TGZ_FILE" -C "$TMP_FOLDER" --strip-components 1

if [ -z "$(ls -A "$TMP_FOLDER")" ]; then
    echo "ERROR: unpacking $EXTENSION_URL resulted in an empty folder" >&2
    exit 1
fi

# Only now touch an existing (e.g. bundled) extension; the pinned version wins.
if [ -e "$EXTENSION_FOLDER" ]; then
    echo "Replacing bundled extension $EXTENSION"
    rm -rf "$EXTENSION_FOLDER"
fi
mv "$TMP_FOLDER" "$EXTENSION_FOLDER"
chmod 755 "$EXTENSION_FOLDER"

printf "Done.\n\n"
