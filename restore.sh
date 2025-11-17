#!/bin/bash
set -euo pipefail

# Get hostname: try read from file, else get from env
[ -z "${MYSQL_HOST_FILE:-}" ] || MYSQL_HOST=$(head -1 "${MYSQL_HOST_FILE}")
[ -z "${MYSQL_HOST:-}" ] && { echo "=> MYSQL_HOST cannot be empty"; exit 1; }
# Get username: try read from file, else get from env
[ -z "${MYSQL_USER_FILE:-}" ] || MYSQL_USER=$(head -1 "${MYSQL_USER_FILE}")
[ -z "${MYSQL_USER:-}" ] && { echo "=> MYSQL_USER cannot be empty"; exit 1; }
# Get password: try read from file, else get from env, else get from MYSQL_PASSWORD env
[ -z "${MYSQL_PASS_FILE:-}" ] || MYSQL_PASS=$(head -1 "${MYSQL_PASS_FILE}")
MYSQL_PASS="${MYSQL_PASS:-${MYSQL_PASSWORD:-}}"
[ -z "${MYSQL_PASS}" ] && { echo "=> MYSQL_PASS cannot be empty"; exit 1; }

# Get PGP private key for decryption
if [ -n "${PGP_PRIVATE_KEY_FILE:-}" ]; then
    if [[ "${PGP_PRIVATE_KEY_FILE}" == file:* ]]; then
        PGP_PRIVATE_KEY=$(cat "${PGP_PRIVATE_KEY_FILE#file:}")
    else
        PGP_PRIVATE_KEY=$(cat "${PGP_PRIVATE_KEY_FILE}")
    fi
fi
PGP_PRIVATE_KEY="${PGP_PRIVATE_KEY:-}"

if [ "$#" -ne 1 ]
then
    echo "You must pass the path of the backup file to restore"
    exit 1
fi

set -o pipefail

# Determine file type and extract SQL
FILE="$1"

# Check if file is PGP encrypted
if [[ "${FILE}" == *.gpg ]]; then
    echo "=> Decrypting PGP encrypted file"
    if [ -n "${PGP_PRIVATE_KEY:-}" ]; then
        echo "${PGP_PRIVATE_KEY}" | gpg --batch --yes --import 2>/dev/null || true
    fi
    
    # Decrypt - check if original was gzipped by filename
    if [[ "${FILE}" == *.gz.gpg ]]; then
        # File was gzipped before encryption, decrypt and decompress
        SQL=$(gpg --batch --yes --decrypt "${FILE}" 2>/dev/null | gunzip -c)
    else
        # File was not gzipped, just decrypt
        SQL=$(gpg --batch --yes --decrypt "${FILE}" 2>/dev/null)
    fi
elif [ -z "${USE_PLAIN_SQL:-}" ]; then
    SQL=$(gunzip -c "${FILE}")
else
    SQL=$(cat "${FILE}")
fi

DB_NAME=${MYSQL_DATABASE:-${MYSQL_DB}}
if [ -z "${DB_NAME}" ]
then
    echo "=> Searching database name in $1"
    DB_NAME=$(echo "$SQL" | grep -oE '(Database: (.+))' | cut -d ' ' -f 2)
fi
[ -z "${DB_NAME}" ] && { echo "=> Database name not found" && exit 1; }

echo "=> Restore database $DB_NAME from $1"

if echo "$SQL" | mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" $MYSQL_SSL_OPTS "$DB_NAME"
then
    echo "=> Restore succeeded"
else
    echo "=> Restore failed"
fi
