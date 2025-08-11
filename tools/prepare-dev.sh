#!/bin/bash

# copy needed vscode files
cp -r /tools/files/.vscode /var/www/html/

# Uninstall Xdebug if it is installed
installed_version=$(php -r 'echo phpversion("xdebug");' 2>/dev/null || echo "not_installed")

if [ "$installed_version" != "not_installed" ]; then
    echo "Xdebug is installed. Uninstalling it first..."
    pecl uninstall xdebug
else
    echo "Xdebug is not installed, proceeding with installation."
fi

# Install and activate Xdebug
required_version="3.4.5"
installed_version=$(php -r 'echo phpversion("xdebug");' 2>/dev/null || echo "not_installed")

if [ "$installed_version" = "not_installed" ]; then
    echo "Xdebug not installed. Installing version $required_version."
    pecl install xdebug-$required_version
elif [ "$(printf '%s\n' "$required_version" "$installed_version" | sort -V | head -n1)" != "$required_version" ]; then
    echo "Xdebug version is older than $required_version. Updating."
    pecl install xdebug-$required_version
else
    echo "Xdebug is already installed and meets the required version ($installed_version)."
fi

enable-xdebug.sh
