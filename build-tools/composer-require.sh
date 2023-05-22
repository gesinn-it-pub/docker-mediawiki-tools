#!/bin/bash

PACKAGE=$1
VERSION=$2

COMPOSER_AUTH="{\"github-oauth\": {\"github.com\": \"$(cat /run/secrets/GH_API_TOKEN 2>/dev/null || true)\"}}" COMPOSER=composer.local.json composer require --no-update "$PACKAGE" "$VERSION"
