#!/bin/bash

COMPOSER_AUTH="{\"github-oauth\": {\"github.com\": \"$(cat /run/secrets/GH_API_TOKEN 2>/dev/null || echo no_token)\"}}" composer update --no-cache --prefer-source

# Only use COMPOSER_AUTH environment variable, if a token secret is available.
# Setting the environment variable inline with the command avoids to persist beyond that command.
if [ -f /run/secrets/GH_API_TOKEN ]; then
    COMPOSER_AUTH="{\"github-oauth\": {\"github.com\": \"$(cat /run/secrets/GH_API_TOKEN 2>/dev/null || echo no_token)\"}}" composer update --no-cache --prefer-source
else
    composer update --no-cache --prefer-source
fi
