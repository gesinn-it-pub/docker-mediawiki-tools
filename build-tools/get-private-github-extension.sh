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
CREATED=0
trap 'rm -f "$TGZ_FILE"; if [ "$CREATED" = 1 ] && [ "$?" != 0 ]; then rm -rf "$EXTENSION_FOLDER"; fi' EXIT

TOKEN=$(cat "${GH_API_TOKEN_FILE:-/run/secrets/GH_API_TOKEN}")

# Header passed via stdin config so the token does not show up in the process list.
curl --fail --silent --show-error --location \
    --retry 5 --retry-all-errors --retry-delay 3 \
    --connect-timeout 10 --max-time 120 \
    --config <(printf 'header = "Authorization: token %s"\n' "$TOKEN") \
    "$EXTENSION_URL" -o "$TGZ_FILE"

mkdir "$EXTENSION_FOLDER"
CREATED=1
tar -xzf "$TGZ_FILE" -C "$EXTENSION_FOLDER" --strip-components 1

if [ -z "$(ls -A "$EXTENSION_FOLDER")" ]; then
    echo "ERROR: $EXTENSION_FOLDER is empty after unpacking $EXTENSION_URL" >&2
    exit 1
fi

printf "Done.\n\n"
