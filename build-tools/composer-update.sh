#!/bin/bash

sudo -u www-data COMPOSER_AUTH="{\"github-oauth\": {\"github.com\": \"$(cat /run/secrets/GH_API_TOKEN)\"}}" composer update --prefer-source
