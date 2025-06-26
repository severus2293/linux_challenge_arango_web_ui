#!/bin/bash
set -e

# Устанавливаем порт для инициализации, если не указан
if [ -z "$ARANGO_INIT_PORT" ]; then
    ARANGO_INIT_PORT=8999
fi

# По умолчанию включаем аутентификацию
AUTHENTICATION="true"

# Если команда начинается с опции, добавляем arangod
case "$1" in
    -*) set -- arangod "$@" ;;
    *) ;;
esac

# Проверяем поддержку NUMA
NUMACTL=""
if [ -d /sys/devices/system/node/node1 ] && [ -f /proc/self/numa_maps ]; then
    if [ -z "$NUMA" ]; then
        NUMACTL="numactl --interleave=all"
    elif [ "$NUMA" != "disable" ]; then
        NUMACTL="numactl --interleave=$NUMA"
    fi
    if [ -n "$NUMACTL" ]; then
        if $NUMACTL echo > /dev/null 2>&1; then
            echo "Using NUMA $NUMACTL"
        else
            echo "Cannot start with NUMA $NUMACTL: please ensure that docker is running with --cap-add SYS_NICE"
            NUMACTL=""
        fi
    fi
fi

if [ "$1" = "arangod" ]; then
    # Копируем конфигурацию для патчинга
    cp /etc/arangodb3/arangod.conf /tmp/arangod.conf

    # Устанавливаем RocksDB как движок хранения
    ARANGO_STORAGE_ENGINE=rocksdb

    # Поддержка шифрования, если указан ключ
    if [ -n "$ARANGO_ENCRYPTION_KEYFILE" ]; then
        echo "Using encrypted database"
        sed -i /tmp/arangod.conf -e "s;^.*encryption-keyfile.*;encryption-keyfile=$ARANGO_ENCRYPTION_KEYFILE;"
    fi

    # Инициализация базы данных, если она не существует
    if [ ! -f /var/lib/arangodb3/SERVER ] && [ "$SKIP_DATABASE_INIT" != "1" ]; then
        # Читаем пароль из файла, если указан
        if [ -n "$ARANGO_ROOT_PASSWORD_FILE" ] && [ -f "$ARANGO_ROOT_PASSWORD_FILE" ]; then
            ARANGO_ROOT_PASSWORD="$(cat $ARANGO_ROOT_PASSWORD_FILE)"
        fi

        # Проверяем, что пароль или режим указан
        if [ -z "${ARANGO_ROOT_PASSWORD+x}" ] && [ -z "$ARANGO_NO_AUTH" ] && [ -z "$ARANGO_RANDOM_ROOT_PASSWORD" ]; then
            echo >&2 "Error: database is uninitialized and password option is not specified"
            echo >&2 "You need to specify one of ARANGO_ROOT_PASSWORD, ARANGO_ROOT_PASSWORD_FILE, ARANGO_NO_AUTH, or ARANGO_RANDOM_ROOT_PASSWORD"
            exit 1
        fi

        # Генерируем случайный пароль, если указан
        if [ -n "$ARANGO_RANDOM_ROOT_PASSWORD" ]; then
            ARANGO_ROOT_PASSWORD=$(pwgen -s -1 16)
            echo "==========================================="
            echo "GENERATED ROOT PASSWORD: $ARANGO_ROOT_PASSWORD"
            echo "==========================================="
        fi

        # Инициализируем базу с паролем
        if [ -n "${ARANGO_ROOT_PASSWORD+x}" ]; then
            echo "Initializing root user..."
            ARANGODB_DEFAULT_ROOT_PASSWORD="$ARANGO_ROOT_PASSWORD" \
                /usr/sbin/arango-init-database -c /tmp/arangod.conf \
                --server.rest-server false --log.level error --database.init-database true || true
            export ARANGO_ROOT_PASSWORD
            ARANGOSH_ARGS=" --server.password ${ARANGO_ROOT_PASSWORD} "
        else
            ARANGOSH_ARGS=" --server.authentication false"
        fi

        echo "Initializing database..."

        # Запускаем arangod для инициализации
        $NUMACTL arangod --config /tmp/arangod.conf \
            --server.endpoint tcp://127.0.0.1:$ARANGO_INIT_PORT \
            --server.authentication false \
            --log.file /tmp/init-log \
            --log.foreground-tty false &
        pid="$!"

        counter=0
        ARANGO_UP=0
        while [ "$ARANGO_UP" = "0" ]; do
            if [ $counter -gt 0 ]; then
                sleep 1
            fi
            if [ "$counter" -gt 100 ]; then
                echo "ArangoDB didn't start correctly during init"
                cat /tmp/init-log
                exit 1
            fi
            let counter=counter+1
            ARANGO_UP=1
            $NUMACTL arangosh \
                --server.endpoint=tcp://127.0.0.1:$ARANGO_INIT_PORT \
                --server.authentication false \
                --javascript.execute-string "db._version()" \
                > /dev/null 2>&1 || ARANGO_UP=0
        done

        # Выполняем скрипты инициализации из /docker-entrypoint-initdb.d/
        for f in /docker-entrypoint-initdb.d/*; do
            case "$f" in
                *.sh)
                    echo "$0: running $f"
                    . "$f"
                    ;;
                *.js)
                    echo "$0: running $f"
                    $NUMACTL arangosh ${ARANGOSH_ARGS} \
                        --server.endpoint=tcp://127.0.0.1:$ARANGO_INIT_PORT \
                        --javascript.execute "$f"
                    ;;
                */dumps)
                    echo "$0: restoring databases"
                    for d in $f/*; do
                        DBName=$(echo ${d}|sed "s;$f/;;")
                        echo "restoring $d into ${DBName}"
                        $NUMACTL arangorestore \
                            ${ARANGOSH_ARGS} \
                            --server.endpoint=tcp://127.0.0.1:$ARANGO_INIT_PORT \
                            --create-database true \
                            --include-system-collections true \
                            --server.database "$DBName" \
                            --input-directory "$d"
                    done
                    ;;
            esac
        done

        if ! kill -s TERM "$pid" || ! wait "$pid"; then
            echo >&2 "ArangoDB Init failed."
            exit 1
        fi

        echo "Database initialized...Starting System..."
    fi

    # Отключаем аутентификацию, если указано
    if [ -n "$ARANGO_NO_AUTH" ]; then
        AUTHENTICATION="false"
    fi

    # Добавляем параметры аутентификации и конфигурации
    shift
    set -- arangod "$@" --server.authentication="$AUTHENTICATION" --config /tmp/arangod.conf
else
    NUMACTL=""
fi

# Запускаем команду
exec $NUMACTL "$@"
