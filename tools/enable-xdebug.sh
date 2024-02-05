#!/bin/bash

# copy needed files
cp -r ./files/.vscode /var/www/html/
cp -r ./files/php/conf.d/99-xdebug.ini /usr/local/etc/php/conf.d/99-xdebug.ini

# install and activate xdebug
pecl install xdebug-3.1.6
php-enable.sh /usr/local/etc/php/conf.d/99-xdebug.ini
