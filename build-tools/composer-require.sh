#!/bin/bash

PACKAGE=$1
VERSION=$2
CONFIG_OVERRIDE=${3:-}

# If a config override is provided, pass it directly to composer config.
# For example, you might pass:
#   repositories.optional '{"type": "vcs", "url": "https://github.com/SemanticMediaWiki/SemanticResultFormats"}'
if [ -n "$CONFIG_OVERRIDE" ]; then
    composer config $CONFIG_OVERRIDE
fi

# Only use COMPOSER_AUTH environment variable if a token secret is available.
if [ -f /run/secrets/GH_API_TOKEN ]; then
    COMPOSER_AUTH="{\"github-oauth\":{\"github.com\":\"$(cat /run/secrets/GH_API_TOKEN 2>/dev/null || echo no_token)\"}}" \
    COMPOSER=composer.local.json composer require --no-cache --no-update "$PACKAGE" "$VERSION"
else
    COMPOSER=composer.local.json composer require --no-cache --no-update "$PACKAGE" "$VERSION"
fi
