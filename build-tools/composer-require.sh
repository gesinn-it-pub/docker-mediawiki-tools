#!/bin/bash

PACKAGE=$1
VERSION=$2

COMPOSER=composer.local.json composer require --no-update "$PACKAGE" "$VERSION"
