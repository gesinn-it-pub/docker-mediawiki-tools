#!/bin/bash

# copy needed files
cp -r /tools/files/.vscode /var/www/html/
cp -r /tools/files/php/conf.d/99-xdebug.ini /usr/local/etc/php/conf.d/99-xdebug.ini.DISABLED

# install and activate xdebug
pecl install xdebug-3.1.6
php-enable.sh /usr/local/etc/php/conf.d/99-xdebug.ini
