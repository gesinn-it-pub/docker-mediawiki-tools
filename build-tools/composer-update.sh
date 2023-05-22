#!/bin/bash

sudo -u www-data COMPOSER_AUTH="{\"github-oauth\": {\"github.com\": \"$(cat /run/secrets/GH_API_TOKEN 2>/dev/null || echo no_token)\"}}" composer update --prefer-source
