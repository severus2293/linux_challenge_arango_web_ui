#!/bin/bash
set -e

ARANGO_INIT_PORT="${ARANGO_INIT_PORT:-8999}"
AUTHENTICATION="true"
ARANGO_CACHE="${ARANGO_CACHE:-1GB}"

# NUMA
NUMACTL=""
if [ -d /sys/devices/system/node/node1 -a -f /proc/self/numa_maps ]; then
    if [ -z "$NUMA" ]; then
        NUMACTL="numactl --interleave=all"
    elif [ "$NUMA" != "disable" ]; then
        NUMACTL="numactl --interleave=$NUMA"
    fi

    if [ -n "$NUMACTL" ] && ! $NUMACTL echo > /dev/null 2>&1; then
        echo "NUMA init failed; continuing without NUMA"
        NUMACTL=""
    fi
fi

cp /etc/arangodb3/arangod.conf /tmp/arangod.conf

if [ -n "$ARANGO_ENCRYPTION_KEYFILE" ]; then
    echo "Using encrypted database"
    sed -i /tmp/arangod.conf -e "s;^.*encryption-keyfile.*;encryption-keyfile=$ARANGO_ENCRYPTION_KEYFILE;"
fi

ln -sf /usr/local/share/arangodb3/js /usr/local/js

if [ ! -f /var/lib/arangodb3/SERVER ] && [ "$SKIP_DATABASE_INIT" != "1" ]; then
    if [ -n "$ARANGO_RANDOM_ROOT_PASSWORD" ]; then
        ARANGO_ROOT_PASSWORD="$(pwgen -s -1 16)"
        echo "Generated random root password: $ARANGO_ROOT_PASSWORD"
    elif [ -n "$ARANGO_ROOT_PASSWORD_FILE" ] && [ -f "$ARANGO_ROOT_PASSWORD_FILE" ]; then
        ARANGO_ROOT_PASSWORD="$(cat "$ARANGO_ROOT_PASSWORD_FILE")"
    fi

    if [ -z "$ARANGO_ROOT_PASSWORD" ] && [ -z "$ARANGO_NO_AUTH" ]; then
        echo >&2 "ERROR: You must specify ARANGO_ROOT_PASSWORD or disable auth."
        exit 1
    fi

    echo "Initializing ArangoDB..."
    $NUMACTL arangod \
        --config /tmp/arangod.conf \
        --database.directory=/var/lib/arangodb3 \
        --javascript.app-path $ARANGO_APPS_DIR \
        --server.authentication=false \
        --server.endpoint=tcp://127.0.0.1:$ARANGO_INIT_PORT \
        --cache.size="$ARANGO_CACHE" \
        --rocksdb.block-cache-size="$ARANGO_CACHE" \
        --rocksdb.total-write-buffer-size="$ARANGO_CACHE" \
        --rocksdb.enforce-block-cache-size-limit=true \
        --log.output - \
        --log.foreground-tty true \
        &

    pid="$!"

    for i in {1..60}; do
        sleep 1
        if arangosh \
            --server.endpoint=tcp://127.0.0.1:$ARANGO_INIT_PORT \
            --server.authentication=false \
            --javascript.execute-string "db._version()" &>/dev/null; then
            break
        fi

        if ! kill -0 "$pid" 2>/dev/null; then
            echo "ArangoDB failed to start during init"
            exit 1
        fi
    done

echo "=== INSTALL FOXX ==="

arangosh \
  --server.endpoint tcp://127.0.0.1:$ARANGO_INIT_PORT \
  --server.authentication false \
  --javascript.execute-string "
    const foxxManager = require('@arangodb/foxx/manager');

    const mount = '/temp-db';
    const source = '/foxx-temp-db';

    try { foxxManager.uninstall(mount); } catch (e) {}

    foxxManager.install(source, mount, { force: true });
  "

    if [ -n "$ARANGO_ROOT_PASSWORD" ]; then
        echo "Creating root user..."
        arangosh \
            --server.endpoint=tcp://127.0.0.1:$ARANGO_INIT_PORT \
            --server.authentication=false \
            --javascript.execute-string "require('@arangodb/users').replace('root', '$ARANGO_ROOT_PASSWORD');"
    fi

    for f in /docker-entrypoint-initdb.d/*; do
        case "$f" in
            *.sh)
                echo "Running $f"
                . "$f"
                ;;
            *.js)
                echo "Running $f"
                arangosh \
                    --server.endpoint=tcp://127.0.0.1:$ARANGO_INIT_PORT \
                    --server.authentication=false \
                    --javascript.execute "$f"
                ;;
        esac
    done

    kill -TERM "$pid"
    wait "$pid"

    echo "Initialization complete"
fi

# Запуск основной ArangoDB
if [ -n "$ARANGO_NO_AUTH" ]; then
    AUTHENTICATION="false"
fi

exec $NUMACTL arangod \
    --config /tmp/arangod.conf \
    --database.directory=/var/lib/arangodb3 \
    --javascript.app-path $ARANGO_APPS_DIR \
    --server.authentication="$AUTHENTICATION" \
    --cache.size="$ARANGO_CACHE" \
    --rocksdb.block-cache-size="$ARANGO_CACHE" \
    --rocksdb.total-write-buffer-size="$ARANGO_CACHE" \
    --rocksdb.enforce-block-cache-size-limit=true \
    --log.output - \
    --log.foreground-tty true \
    --query.slow-threshold 5 \
    --query.tracking true \
    "$@"
