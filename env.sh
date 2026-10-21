#!/bin/bash
# shellcheck disable=SC2034  # variables are used by the scripts sourcing this file
# Connection settings shared by backup.sh and healthcheck.sh (sourced, not executed)
# so the healthcheck verifies exactly the credentials the backup uses.

# Get socket path: try read from file, else get from env
[ -z "${MYSQL_SOCKET_FILE:-}" ] || MYSQL_SOCKET=$(head -1 "${MYSQL_SOCKET_FILE}")
MYSQL_SOCKET="${MYSQL_SOCKET:-}"

# Get hostname: try read from file, else get from env (only if socket not set)
if [ -z "${MYSQL_SOCKET}" ]; then
  [ -z "${MYSQL_HOST_FILE:-}" ] || MYSQL_HOST=$(head -1 "${MYSQL_HOST_FILE}")
  [ -z "${MYSQL_HOST:-}" ] && { echo "=> MYSQL_HOST or MYSQL_SOCKET must be set"; exit 1; }
fi
# Get username: try read from file, else get from env
[ -z "${MYSQL_USER_FILE:-}" ] || MYSQL_USER=$(head -1 "${MYSQL_USER_FILE}")
[ -z "${MYSQL_USER:-}" ] && { echo "=> MYSQL_USER cannot be empty"; exit 1; }
# Get password: try read from file, else get from env, else get from MYSQL_PASSWORD env
[ -z "${MYSQL_PASS_FILE:-}" ] || MYSQL_PASS=$(head -1 "${MYSQL_PASS_FILE}")
MYSQL_PASS="${MYSQL_PASS:-${MYSQL_PASSWORD:-}}"
[ -z "${MYSQL_PASS}" ] && { echo "=> MYSQL_PASS cannot be empty"; exit 1; }

# Build connection options
if [ -n "${MYSQL_SOCKET}" ]; then
  MYSQL_CONN_OPTS="--protocol=SOCKET --socket=${MYSQL_SOCKET} -h localhost"
else
  MYSQL_CONN_OPTS="-h ${MYSQL_HOST} -P ${MYSQL_PORT}"
fi

# Backup status markers, kept in the /backup volume so they survive container re-creation
LAST_SUCCESS_FILE="/backup/.last_success"
LAST_FAILURE_FILE="/backup/.last_failure"
