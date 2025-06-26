#!/bin/sh
set -e

# Создаём директории для данных, приложений и логов
install -o root -g root -m 755 -d /var/lib/arangodb3
install -o root -g root -m 755 -d /var/lib/arangodb3-apps
install -o root -g root -m 777 -d /var/log/arangodb3
mkdir -p /docker-entrypoint-initdb.d/

# Настраиваем конфигурацию arangod.conf
# Привязываемся ко всем интерфейсам
sed -i -e 's~^endpoint.*8529$~endpoint = tcp://0.0.0.0:8529~' /etc/arangodb3/arangod.conf
# Удаляем настройку uid для поддержки произвольных пользователей
sed -i \
    -e 's!^\(file\s*=\s*\).*!\1 -!' \
    -e 's~^uid = .*$~~' \
    /etc/arangodb3/arangod.conf
