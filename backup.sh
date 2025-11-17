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

# shellcheck disable=SC2086
DATABASES=${MYSQL_DATABASE:-${MYSQL_DB:-$(mysql -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" ${MYSQL_SSL_OPTS:-} -e "SHOW DATABASES;" | tr -d "| " | grep -v Database)}}
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
        FILENAME="${BACKUP_DIR}/${db}.sql"
        LATEST="/backup/latest/${db}.sql"
    else
        FILENAME="${BACKUP_DIR}/${DATE}.${db}.sql"
        LATEST="${BACKUP_DIR}/latest.${db}.sql"
    fi
    
    BASIC_OPTS=(--single-transaction --skip-lock-tables --quick)
    if [ -n "${REMOVE_DUPLICATES:-}" ]; then
      BASIC_OPTS+=(--skip-dump-date)
    fi
    
    # shellcheck disable=SC2086
    if mysqldump "${BASIC_OPTS[@]}" ${MYSQLDUMP_OPTS:-} -h "$MYSQL_HOST" -P "$MYSQL_PORT" -u "$MYSQL_USER" -p"$MYSQL_PASS" ${MYSQL_SSL_OPTS:-} "$db" > "$FILENAME"; then
      EXT=""
      
      # Compression
      if [ -z "${USE_PLAIN_SQL:-}" ]; then
        echo "==> Compressing $db with LEVEL $GZIP_LEVEL"
        gzip "-$GZIP_LEVEL" -n -f "$FILENAME"
        EXT=".gz"
        FILENAME="${FILENAME}${EXT}"
        LATEST="${LATEST}${EXT}"
      fi
      
      # PGP Encryption
      if [ -n "${PGP_KEY:-}" ]; then
        set +e  # Temporarily disable exit on error for PGP block
        echo "==> Encrypting $db with PGP"
        
        # Import key to GPG keyring
        GPG_IMPORT_OUTPUT=$(echo "${PGP_KEY}" | gpg --batch --yes --import 2>&1)
        echo "${GPG_IMPORT_OUTPUT}" | grep -E "(imported|processed|secret key)" || echo "Key import status: ${GPG_IMPORT_OUTPUT}"
        
        # Get the key fingerprint/ID from imported keys
        # Try pub first (public key), then sec (secret/private key)
        KEY_ID=$(echo "${PGP_KEY}" | gpg --batch --with-colons --import-options show-only --import 2>/dev/null | grep -E '^(pub|sec)' | head -1 | cut -d: -f5)
        
        if [ -z "${KEY_ID}" ]; then
          # Fallback: try to get from fpr (fingerprint) line
          KEY_ID=$(echo "${PGP_KEY}" | gpg --batch --with-colons --import-options show-only --import 2>/dev/null | grep '^fpr' | head -1 | cut -d: -f10)
        fi
        
        if [ -n "${KEY_ID}" ]; then
          echo "==> Using key ID: ${KEY_ID}"
          
          # Set trust level to ultimate for this key
          echo "${KEY_ID}:6:" | gpg --batch --import-ownertrust 2>/dev/null || true
          
          # Encrypt the file
          echo "==> Running: gpg --encrypt --recipient ${KEY_ID} --output ${FILENAME}.gpg ${FILENAME}"
          GPG_ENCRYPT_OUTPUT=$(gpg --batch --yes --trust-model always --encrypt --recipient "${KEY_ID}" --output "${FILENAME}.gpg" "${FILENAME}" 2>&1)
          GPG_EXIT_CODE=$?
          
          if [ $GPG_EXIT_CODE -eq 0 ]; then
            if [ -f "${FILENAME}.gpg" ]; then
              rm -f "${FILENAME}"
              FILENAME="${FILENAME}.gpg"
              LATEST="${LATEST}.gpg"
              EXT="${EXT}.gpg"
              echo "==> Encrypted successfully: ${FILENAME}"
            else
              echo "!! PGP encryption failed: .gpg file not created (exit code: $GPG_EXIT_CODE)"
              echo "!! GPG output: ${GPG_ENCRYPT_OUTPUT}"
            fi
          else
            echo "!! PGP encryption command failed for $db (exit code: $GPG_EXIT_CODE)"
            echo "!! GPG output: ${GPG_ENCRYPT_OUTPUT}"
          fi
        else
          echo "!! Could not extract key ID from PGP key"
          echo "!! Debug: trying to list all keys in keyring..."
          gpg --list-keys 2>&1 || true
        fi
        set -e  # Re-enable exit on error
      fi
      
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
    else
      echo "!! Failed to dump $db"
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
