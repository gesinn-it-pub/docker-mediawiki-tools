#!/bin/bash

PACKAGE=$1
VERSION=$2

# Only use COMPOSER_AUTH environment variable, if a token secret is available.
# Setting the environment variable inline with the command avoids to persist beyond that command.
if [ -f /run/secrets/GH_API_TOKEN ]; then
    COMPOSER_AUTH="{\"github-oauth\": {\"github.com\": \"$(cat /run/secrets/GH_API_TOKEN 2>/dev/null || echo no_token)\"}}" COMPOSER=composer.local.json composer require --no-update "$PACKAGE" "$VERSION"
else
    COMPOSER=composer.local.json composer require --no-update "$PACKAGE" "$VERSION"
fi
