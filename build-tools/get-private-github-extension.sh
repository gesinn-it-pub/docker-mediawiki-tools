#!/bin/bash
# Downloads a tarball from a private GitHub repo (token from /run/secrets/GH_API_TOKEN)
# and unpacks it into extensions/$1. Fails (exit != 0) on any error.
set -euo pipefail

EXTENSION=$1
VERSION=$2
USER_AND_EXTENSION=${3:-gesinn-it/$EXTENSION}

EXTENSION_URL=https://api.github.com/repos/$USER_AND_EXTENSION/tarball/$VERSION
echo "Getting $EXTENSION_URL ..."

TGZ_FILE=$(mktemp "/tmp/$EXTENSION-$VERSION.XXXXXX.tgz")
EXTENSION_FOLDER=extensions/$EXTENSION
mkdir -p extensions
TMP_FOLDER=$(mktemp -d "extensions/.$EXTENSION.XXXXXX")
trap 'rm -rf "$TGZ_FILE" "$TMP_FOLDER"' EXIT

TOKEN=$(cat "${GH_API_TOKEN_FILE:-/run/secrets/GH_API_TOKEN}")

# Header passed via stdin config so the token does not show up in the process list.
curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 3 \
    --connect-timeout 10 --max-time 120 \
    --config <(printf 'header = "Authorization: token %s"\n' "$TOKEN") \
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
