#!/bin/bash
# Healthy = init finished, the database accepts the backup credentials,
# the last backup run did not fail and a backup succeeded within HEALTHCHECK_MAX_AGE_HOURS.
set -eu

# shellcheck source=env.sh
. /env.sh

[ -f /HEALTHY.status ] || { echo "init phase not finished"; exit 1; }

# SELECT 1, not mysqladmin ping: ping reports success even on "Access denied"
# shellcheck disable=SC2086
if ! OUT=$(MYSQL_PWD="$MYSQL_PASS" mysql ${MYSQL_CONN_OPTS} -u "$MYSQL_USER" ${MYSQL_SSL_OPTS:-} \
    --connect-timeout=5 -N -e "SELECT 1" 2>&1); then
  echo "database connection failed: ${OUT}"
  exit 1
fi

fmt() { date -d "@$1" "+%Y-%m-%d %H:%M:%S"; }

NOW=$(date +%s)
LAST_SUCCESS=$(cat "${LAST_SUCCESS_FILE}" 2>/dev/null || true)
LAST_FAILURE=$(cat "${LAST_FAILURE_FILE}" 2>/dev/null || true)

if [ -n "${LAST_FAILURE}" ] && [ "${LAST_FAILURE}" -gt "${LAST_SUCCESS:-0}" ]; then
  echo "last backup run failed at $(fmt "${LAST_FAILURE}")"
  exit 1
fi

# No backup yet: count from the container start, giving it the same window for the first one
SINCE=${LAST_SUCCESS:-$(cat /started_at)}
MAX_AGE=$(( ${HEALTHCHECK_MAX_AGE_HOURS:-48} * 3600 ))
if [ $(( NOW - SINCE )) -gt "${MAX_AGE}" ]; then
  if [ -n "${LAST_SUCCESS}" ]; then
    echo "last successful backup at $(fmt "${LAST_SUCCESS}"), older than ${HEALTHCHECK_MAX_AGE_HOURS:-48}h"
  else
    echo "no successful backup since start at $(fmt "${SINCE}"), older than ${HEALTHCHECK_MAX_AGE_HOURS:-48}h"
  fi
  exit 1
fi

if [ -n "${LAST_SUCCESS}" ]; then
  echo "ok: last successful backup at $(fmt "${LAST_SUCCESS}")"
else
  echo "ok: no backup yet, started at $(fmt "${SINCE}")"
fi
