#!/bin/bash
set -euo pipefail

# shellcheck source=env.sh
. /env.sh

# Get database name(s): try read from file, else get from env
# Note: when from file, there can be one database name per line in that file
[ -z "${MYSQL_DATABASE_FILE:-}" ] || MYSQL_DATABASE=$(cat "${MYSQL_DATABASE_FILE}")
# Get level from env, else use 6
[ -z "${GZIP_LEVEL:-}" ] && GZIP_LEVEL=6

# Get PGP key: try read from file, else get from env
if [ -n "${PGP_KEY_FILE:-}" ]; then
    if [[ "${PGP_KEY_FILE}" == file:* ]]; then
        PGP_KEY=$(cat "${PGP_KEY_FILE#file:}")
    else
        PGP_KEY=$(cat "${PGP_KEY_FILE}")
    fi
fi
PGP_KEY="${PGP_KEY:-}"

DATE=$(date +%Y-%m-%d-%H-%M-%S)
echo "=> Backup started at $(date "+%Y-%m-%d %H:%M:%S")"

# Determine backup directory structure
if [ "${DATABASE_SPLIT_TO_FILE:-false}" = "true" ]; then
    BACKUP_DIR="/backup/${DATE}"
    mkdir -p "${BACKUP_DIR}"
    echo "=> Using split mode: ${BACKUP_DIR}"
else
    BACKUP_DIR="/backup"
    echo "=> Using flat mode: ${BACKUP_DIR}"
fi

if [ -n "${MYSQL_SOCKET}" ]; then
  echo "=> Using socket connection: ${MYSQL_SOCKET}"
else
  echo "=> Using TCP connection: ${MYSQL_HOST}:${MYSQL_PORT}"
fi

# Any non-zero exit (explicit or via set -e) is recorded as a failed run
trap '[ $? -eq 0 ] || date +%s > "${LAST_FAILURE_FILE}"' EXIT

# PGP: import the key and resolve its ID once, before the loop over databases.
# Without a usable key the run is aborted: writing unencrypted dumps when encryption
# was requested is worse than writing nothing (the healthcheck reports the failure)
KEY_ID=""
if [ -n "${PGP_KEY}" ]; then
  echo "=> Importing PGP key"
  GPG_IMPORT_OUTPUT=$(echo "${PGP_KEY}" | gpg --batch --yes --import 2>&1) || true
  echo "${GPG_IMPORT_OUTPUT}" | grep -E "(imported|processed|secret key)" || echo "Key import status: ${GPG_IMPORT_OUTPUT}"

  # Key ID from the pub (public) or sec (secret) line, else the fingerprint
  KEY_ID=$(echo "${PGP_KEY}" | gpg --batch --with-colons --import-options show-only --import 2>/dev/null | grep -E '^(pub|sec)' | head -1 | cut -d: -f5 || true)
  if [ -z "${KEY_ID}" ]; then
    KEY_ID=$(echo "${PGP_KEY}" | gpg --batch --with-colons --import-options show-only --import 2>/dev/null | grep '^fpr' | head -1 | cut -d: -f10 || true)
  fi
  if [ -z "${KEY_ID}" ]; then
    echo "!! Could not extract key ID from PGP key"
    echo "!! Debug: trying to list all keys in keyring..."
    gpg --list-keys 2>&1 || true
    exit 1
  fi
  echo "=> Using key ID: ${KEY_ID}"
  # Set trust level to ultimate for this key
  echo "${KEY_ID}:6:" | gpg --batch --import-ownertrust 2>/dev/null || true
fi

# Suffix added to <name>.sql by the pipeline stages below; delete.sh matches files by it
EXT=""
[ -n "${USE_PLAIN_SQL:-}" ] || EXT=".gz"
[ -z "${KEY_ID}" ] || EXT="${EXT}.gpg"

# Anything short of dumping every database is a failed run for the healthcheck
DUMPED=0
FAILED=0

# shellcheck disable=SC2086
DATABASES=${MYSQL_DATABASE:-${MYSQL_DB:-$(mysql ${MYSQL_CONN_OPTS} -u "$MYSQL_USER" -p"$MYSQL_PASS" ${MYSQL_SSL_OPTS:-} -e "SHOW DATABASES;" | tr -d "| " | grep -v Database)}}
for db in ${DATABASES}
do
  if  [[ "$db" != "information_schema" ]] \
      && [[ "$db" != "performance_schema" ]] \
      && [[ "$db" != "mysql" ]] \
      && [[ "$db" != "sys" ]] \
      && [[ "$db" != _* ]]
  then
    echo "==> Dumping database: $db"

    # Determine filename based on mode
    if [ "${DATABASE_SPLIT_TO_FILE:-false}" = "true" ]; then
        FILENAME="${BACKUP_DIR}/${db}.sql${EXT}"
        LATEST="/backup/latest/${db}.sql${EXT}"
    else
        FILENAME="${BACKUP_DIR}/${DATE}.${db}.sql${EXT}"
        LATEST="${BACKUP_DIR}/latest.${db}.sql${EXT}"
    fi

    BASIC_OPTS=(--single-transaction --skip-lock-tables --quick)
    if [ -n "${REMOVE_DUPLICATES:-}" ]; then
      BASIC_OPTS+=(--skip-dump-date)
    fi
    # shellcheck disable=SC2206  # MYSQLDUMP_OPTS, MYSQL_CONN_OPTS and MYSQL_SSL_OPTS are word lists
    DUMP=(mysqldump "${BASIC_OPTS[@]}" ${MYSQLDUMP_OPTS:-} ${MYSQL_CONN_OPTS} -u "$MYSQL_USER" -p"$MYSQL_PASS" ${MYSQL_SSL_OPTS:-} "$db")

    # The dump is streamed through gzip and gpg straight into the final file, so the raw
    # SQL never touches the disk: the peak disk usage of a run is the size of the
    # compressed (and encrypted) file. STAGES names the pipeline stages, STATUS holds
    # their exit codes in the same order (PIPESTATUS, so a failed mysqldump is not masked
    # by a successful gzip/gpg)
    set +e
    if [ -z "${USE_PLAIN_SQL:-}" ] && [ -n "${KEY_ID}" ]; then
      echo "==> Compressing with LEVEL $GZIP_LEVEL and encrypting with PGP key ${KEY_ID}"
      STAGES=(mysqldump gzip gpg)
      "${DUMP[@]}" | gzip "-$GZIP_LEVEL" -n | gpg --batch --yes --trust-model always --encrypt --recipient "${KEY_ID}" --output "$FILENAME"
      STATUS=("${PIPESTATUS[@]}")
    elif [ -z "${USE_PLAIN_SQL:-}" ]; then
      echo "==> Compressing with LEVEL $GZIP_LEVEL"
      STAGES=(mysqldump gzip)
      "${DUMP[@]}" | gzip "-$GZIP_LEVEL" -n > "$FILENAME"
      STATUS=("${PIPESTATUS[@]}")
    elif [ -n "${KEY_ID}" ]; then
      echo "==> Encrypting with PGP key ${KEY_ID}"
      STAGES=(mysqldump gpg)
      "${DUMP[@]}" | gpg --batch --yes --trust-model always --encrypt --recipient "${KEY_ID}" --output "$FILENAME"
      STATUS=("${PIPESTATUS[@]}")
    else
      STAGES=(mysqldump)
      "${DUMP[@]}" > "$FILENAME"
      STATUS=("${PIPESTATUS[@]}")
    fi
    set -e

    DUMP_OK=1
    for i in "${!STATUS[@]}"; do
      if [ "${STATUS[$i]}" -ne 0 ]; then
        echo "!! ${STAGES[$i]} failed for $db (exit code: ${STATUS[$i]})"
        DUMP_OK=0
      fi
    done

    if [ "$DUMP_OK" -eq 1 ] && [ -s "$FILENAME" ]; then
      echo "==> Written: ${FILENAME}"
      BASENAME=$(basename "$FILENAME")

      # Create symlink for latest (only in flat mode)
      if [ "${DATABASE_SPLIT_TO_FILE:-false}" != "true" ]; then
        echo "==> Creating symlink to latest backup: $BASENAME"
        rm -f "$LATEST" 2>/dev/null
        (cd /backup && ln -sf "$BASENAME" "$(basename "$LATEST")")
      fi

      if [ -n "${REMOVE_DUPLICATES:-}" ]; then
        echo "==> Removing duplicate database dumps"
        fdupes -idN /backup/
      fi

      if [ -n "${MAX_BACKUPS:-}" ]; then
        # Execute the delete script, delete older backup or other custom delete script
        /delete.sh "$db" "$EXT"
      fi
      DUMPED=$((DUMPED + 1))
    else
      [ "$DUMP_OK" -eq 0 ] || echo "!! Dump of $db is empty"
      FAILED=$((FAILED + 1))
      echo "!! Failed to dump $db, removing incomplete file"
      rm -f "$FILENAME"
    fi
  fi
done

# Create symlink to latest backup directory (split mode)
if [ "${DATABASE_SPLIT_TO_FILE:-false}" = "true" ]; then
    LATEST_LINK="/backup/latest"
    mkdir -p "$(dirname "${LATEST_LINK}")"
    rm -f "${LATEST_LINK}" 2>/dev/null
    ln -sf "$(basename "${BACKUP_DIR}")" "${LATEST_LINK}"
    echo "==> Created symlink: latest -> ${DATE}"
fi

# Rotation of old backups (split mode)
if [ "${DATABASE_SPLIT_TO_FILE:-false}" = "true" ] && [ -n "${MAX_BACKUPS:-}" ]; then
    echo "=> Removing old backup directories (keeping last ${MAX_BACKUPS})"
    cd /backup && ls -1dt [0-9]* 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm -rf
fi

echo "=> Backup process finished at $(date "+%Y-%m-%d %H:%M:%S")"

if [ "$FAILED" -gt 0 ] || [ "$DUMPED" -eq 0 ]; then
  echo "!! Backup run failed: ${DUMPED} database(s) dumped, ${FAILED} error(s)"
  exit 1
fi
date +%s > "${LAST_SUCCESS_FILE}"
