#!/bin/bash

sudo -u www-data COMPOSER_AUTH="{\"github-oauth\": {\"github.com\": \"$(cat /run/secrets/GH_API_TOKEN 2>/dev/null || echo no_token)\"}}" composer update --prefer-source

# Only use COMPOSER_AUTH environment variable, if a token secret is available.
# Setting the environment variable inline with the command avoids to persist beyond that command.
if [ -f /run/secrets/GH_API_TOKEN ]; then
    sudo -u www-data COMPOSER_AUTH="{\"github-oauth\": {\"github.com\": \"$(cat /run/secrets/GH_API_TOKEN 2>/dev/null || echo no_token)\"}}" composer update --prefer-source
else
    sudo -u www-data composer update --prefer-source
fi
