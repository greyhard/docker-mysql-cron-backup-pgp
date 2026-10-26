#!/bin/bash
# End-to-end test of the image with docker-compose.yaml (run by the `test` workflow, works locally too):
# a throwaway PGP key pair is generated, a backup is made with it, the .sql.gz.gpg is decrypted,
# decompressed and restored into a second database, and the container must report healthy.
# Everything lives in TEST_DIR (a temp dir by default), so the repository's own backup/ and secrets/
# are not touched; docker-compose.test.yaml points the compose volumes there.
set -euo pipefail
cd "$(dirname "$0")"

export DATABASE_NAME=${DATABASE_NAME:-foo}
export MARIADB_ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD:-abcd}
export TEST_DIR=${TEST_DIR:-$(mktemp -d)}
export GNUPGHOME="${TEST_DIR}/gnupg"
mkdir -p "${TEST_DIR}/backup" "${TEST_DIR}/secrets" "${GNUPGHOME}"
chmod 700 "${GNUPGHOME}"
echo "=> Test directory: ${TEST_DIR}"

COMPOSE=(docker compose -f docker-compose.yaml -f docker-compose.test.yaml)
cleanup() {
  echo "=> Cleaning up"
  "${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

sql() { "${COMPOSE[@]}" exec -T mariadb mariadb -uroot -p"${MARIADB_ROOT_PASSWORD}" "$@"; }

echo "=> Generating a throwaway PGP key pair"
gpg --batch --quiet --gen-key <<EOF
Key-Type: RSA
Key-Length: 2048
Name-Real: Image Test
Name-Email: test@localhost
Expire-Date: 0
%no-protection
%commit
EOF
gpg --armor --export test@localhost > "${TEST_DIR}/secrets/pgp_public_key"

echo "=> Building the image and starting MariaDB"
"${COMPOSE[@]}" build backup
"${COMPOSE[@]}" up -d --wait --wait-timeout 180 mariadb

echo "=> Seeding ${DATABASE_NAME}"
sql "${DATABASE_NAME}" -e "CREATE TABLE t (id INT PRIMARY KEY, v VARCHAR(20)); INSERT INTO t VALUES (1,'one'),(2,'two'),(3,'three');"

echo "=> Running a backup"
"${COMPOSE[@]}" run --rm backup /backup.sh

echo "=> Checking the backup files"
ls -la "${TEST_DIR}/backup"
DUMP="${TEST_DIR}/backup/latest.${DATABASE_NAME}.sql.gz.gpg"
[ -L "${DUMP}" ] || { echo "!! ${DUMP} is not a symlink"; exit 1; }
[ -s "${DUMP}" ] || { echo "!! ${DUMP} is missing or empty"; exit 1; }
if find "${TEST_DIR}/backup" \( -name '*.sql' -o -name '*.sql.gz' \) | grep .; then
  echo "!! unencrypted dump found in /backup"; exit 1
fi
[ -f "${TEST_DIR}/backup/.last_success" ] || { echo "!! .last_success was not written"; exit 1; }

echo "=> Decrypting and decompressing"
gpg --batch --quiet --decrypt "${DUMP}" | gunzip > "${TEST_DIR}/restored.sql"
grep -q "INSERT INTO \`t\` VALUES" "${TEST_DIR}/restored.sql" || { echo "!! no INSERT in the dump"; exit 1; }
grep -q "^-- Dump completed" "${TEST_DIR}/restored.sql" || { echo "!! dump is truncated"; exit 1; }

echo "=> Restoring into ${DATABASE_NAME}_restored"
sql -e "CREATE DATABASE ${DATABASE_NAME}_restored"
sql "${DATABASE_NAME}_restored" < "${TEST_DIR}/restored.sql"
ROWS=$(sql -N -e "SELECT COUNT(*) FROM ${DATABASE_NAME}_restored.t" | tr -d '[:space:]')
[ "${ROWS}" = "3" ] || { echo "!! expected 3 rows, got ${ROWS}"; exit 1; }

echo "=> Starting the backup service and waiting for it to become healthy"
"${COMPOSE[@]}" up -d --wait --wait-timeout 180 backup
"${COMPOSE[@]}" exec -T backup /healthcheck.sh | tee "${TEST_DIR}/healthcheck.out"
grep -q '^ok:' "${TEST_DIR}/healthcheck.out" || { echo "!! healthcheck did not report ok"; exit 1; }

echo "=> Image test passed"
