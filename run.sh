#!/bin/bash

# Wait for database to be ready
wait_for_db() {
    echo "=> Waiting for database $MYSQL_HOST:$MYSQL_PORT to be ready..."
    local timeout=${TIMEOUT:-10}
    local elapsed=0
    
    until nc -z "$MYSQL_HOST" "$MYSQL_PORT" 2>/dev/null; do
        if [ $elapsed -ge $timeout ]; then
            echo "=> Timeout waiting for database after ${timeout}s"
            return 1
        fi
        echo "=> Waiting for database container... (${elapsed}s/${timeout}s)"
        sleep 1
        elapsed=$((elapsed + 1))
    done
    
    echo "=> Database is ready!"
    return 0
}

# Wait for database before starting
wait_for_db || echo "=> Warning: Database not ready, continuing anyway..."

tail -F /mysql_backup.log &

if [ "${INIT_BACKUP:-0}" -gt "0" ]; then
  echo "=> Create a backup on the startup"
  /backup.sh
fi

function final_backup {
    echo "=> Captured trap for final backup"
    echo "=> Requested last backup at $(date "+%Y-%m-%d %H:%M:%S")"
    exec /backup.sh
    exit 0
}

if [ -n "${EXIT_BACKUP}" ]; then
  echo "=> Listening on container shutdown gracefully to make last backup before close"
  trap final_backup SIGHUP SIGINT SIGTERM
fi

touch /HEALTHY.status

echo "${CRON_TIME} /backup.sh >> /mysql_backup.log 2>&1" > /tmp/crontab.conf
crontab /tmp/crontab.conf
echo "=> Running cron task manager in foreground"
crond -f -l 8 -L /mysql_backup.log &

echo "Listening on crond, and wait..."

tail -f /dev/null & wait $!

echo "Script is shutted down."