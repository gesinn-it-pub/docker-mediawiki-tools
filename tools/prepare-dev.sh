#!/bin/bash

# copy needed vscode files
cp -r /tools/files/.vscode /var/www/html/

# install and activate xdebug
pecl install xdebug-3.1.6

enable-xdebug.sh
