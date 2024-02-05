#!/bin/bash

cp -r /tools/files/php/conf.d/99-xdebug.ini /usr/local/etc/php/conf.d/99-xdebug.ini.DISABLED
php-enable.sh /usr/local/etc/php/conf.d/99-xdebug.ini
