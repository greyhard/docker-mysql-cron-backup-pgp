# mysql-cron-backup-pgp

Run mysqldump to backup your databases periodically using the cron task manager in the container. Your backups are saved in `/backup`. You can mount any directory of your host or a docker volumes in /backup. Othwerwise, a docker volume is created in the default location.

Also you can add PGP encryption to your backups. (Optional)

## Origin

This project is derived from [fradelg/docker-mysql-cron-backup](https://github.com/fradelg/docker-mysql-cron-backup)
(Apache License 2.0, see `LICENSE` and `NOTICE`); the original history is preserved in this repository.
Differences from the original:

- PGP encryption of dumps (`PGP_KEY`, `PGP_KEY_FILE`);
- split mode: a directory per backup run (`DATABASE_SPLIT_TO_FILE`);
- connection through a MySQL socket (`MYSQL_SOCKET`, `MYSQL_SOCKET_FILE`);
- a healthcheck that verifies the database connection and the age of the last successful backup;
- the dump is streamed through gzip and gpg: the raw SQL never touches the disk.

## Usage:

```bash
docker container run -d \
       --env MYSQL_USER=root \
       --env MYSQL_PASS=my_password \
       --link mysql
       --volume /path/to/my/backup/folder:/backup
       greyhard/docker-mysql-cron-backup-pgp
```

### Disk usage

`backup.sh` pipes `mysqldump` straight into `gzip` and (when a PGP key is set) into `gpg`:

```
mysqldump ... | gzip -$GZIP_LEVEL -n | gpg --encrypt --recipient <key> --output <db>.sql.gz.gpg
```

The raw `.sql` is never written, so the extra space a run needs is the size of the compressed
(and encrypted) file being written — not the size of the uncompressed dump. A database that packs
into 1.5 GB of gzip needs 1.5 GB of free space in `/backup`, not the 13 GB of its plain SQL plus
the archive. Images up to `1.0` wrote the plain dump first and compressed it afterwards; the disk had
to hold the plain dump and the archive at the same time.

If `mysqldump`, `gzip` or `gpg` fails, the incomplete file is removed and the run is reported as
failed (see [Healthcheck](#healthcheck)). With `USE_PLAIN_SQL` set the dump is written as `.sql`
(or piped into `gpg` as `.sql.gpg`) without compression.

### Healthcheck

The image has a built-in Docker `HEALTHCHECK` (`/healthcheck.sh`). It answers one question: *are backups actually being made?* — not just "is the container running".

#### What is checked

Checks run in this order; the first one that fails makes the container **unhealthy** and its message becomes the check output:

| # | Check | Fails when | Output on failure |
|---|-------|------------|-------------------|
| 1 | Init phase finished | `run.sh` is still waiting for the database or running `INIT_BACKUP` | `init phase not finished` |
| 2 | Database connection | `SELECT 1` fails with the **same** host/socket, user, password and `MYSQL_SSL_OPTS` that `backup.sh` uses (`*_FILE` variables included). `mysqladmin ping` is deliberately not used: it succeeds even on `Access denied` | `database connection failed: ERROR 1045 (28000): Access denied ...` |
| 3 | Last backup run | the most recent run of `backup.sh` failed: a database could not be dumped or PGP-encrypted, no database was dumped at all, or the script aborted | `last backup run failed at 2026-10-21 03:00:01` |
| 4 | Backup age | the last successful backup is older than `HEALTHCHECK_MAX_AGE_HOURS` (default `48`). Before the first backup the age counts from the container start, so a fresh container gets the same window | `last successful backup at ..., older than 48h` |

When everything passes the output is `ok: last successful backup at ...` (or `ok: no backup yet, started at ...`).

A failed run keeps the container unhealthy until the next **successful** run (cron or a manual `docker exec <container> /backup.sh`). A dead `crond` is caught by check 4: no new backups — the age grows past the limit.

#### Timing

```
HEALTHCHECK --interval=60s --timeout=10s --start-period=30m --start-interval=5s --retries=3
```

- every minute in normal operation; **unhealthy** after 3 failed checks in a row (about 3 minutes);
- during the first 30 minutes failures are not counted, so a long `INIT_BACKUP` of a large database does not flip the container to unhealthy; checks run every 5 seconds there, so it turns **healthy** right after the init;
- after `docker restart` the status is **starting** again until the init phase of the new start is finished.

#### Where the state lives

`backup.sh` writes epoch seconds to `/backup/.last_success` or `/backup/.last_failure` at the end of every run. Both files live in the `/backup` volume, so the backup history survives `docker compose down/up` and image upgrades. They are not touched by `MAX_BACKUPS` rotation. Deleting them resets the history (the age counts from the container start again).

#### Reading the status

```bash
docker ps --filter name=backup                      # STATUS column: (healthy) / (unhealthy) / (health: starting)
docker inspect --format '{{json .State.Health}}' <container> | jq   # last 5 checks with their output
docker exec <container> /healthcheck.sh             # run the check by hand
```

#### Tuning

```yaml
  backup:
    image: greyhard/docker-mysql-cron-backup-pgp
    environment:
      - CRON_TIME=0 3 * * *
      - HEALTHCHECK_MAX_AGE_HOURS=48     # allowed age of the last successful backup
    healthcheck:                         # optional: override the timing
      interval: 5m
      start_period: 2h                   # e.g. for a very large INIT_BACKUP
```

**Note**: the default `CRON_TIME` (`0 3 * * sun`, weekly) does not fit the default 48 hours: with weekly backups set `HEALTHCHECK_MAX_AGE_HOURS` above a week (e.g. `192`) or back up daily.

Images before `1.0` only checked that the init phase was over (`/HEALTHY.status`); failed backups did not affect the status.

## Variables


- `MYSQL_HOST`: The host/ip of your mysql database.
- `MYSQL_HOST_FILE`: The file in container where to find the host of your mysql database (cf. docker secrets). You should use either MYSQL_HOST_FILE or MYSQL_HOST (see examples below).
- `MYSQL_PORT`: The port number of your mysql database.
- `MYSQL_SOCKET`: Path to MySQL socket file for local connections. When set, `MYSQL_HOST` and `MYSQL_PORT` are ignored.
- `MYSQL_SOCKET_FILE`: The file in container where to find the socket path (cf. docker secrets). You should use either MYSQL_SOCKET_FILE or MYSQL_SOCKET.
- `MYSQL_USER`: The username of your mysql database.
- `MYSQL_USER_FILE`: The file in container where to find the user of your mysql database (cf. docker secrets). You should use either MYSQL_USER_FILE or MYSQL_USER (see examples below).
- `MYSQL_PASS`: The password of your mysql database.
- `MYSQL_PASS_FILE`: The file in container where to find the password of your mysql database (cf. docker secrets). You should use either MYSQL_PASS_FILE or MYSQL_PASS (see examples below).
- `MYSQL_DATABASE`: The database name to dump. Default: `--all-databases`.
- `MYSQL_DATABASE_FILE`: The file in container where to find the database name(s) in your mysql database (cf. docker secrets). In that file, there can be several database names: one per line. You should use either MYSQL_DATABASE or MYSQL_DATABASE_FILE (see examples below).
- `MYSQLDUMP_OPTS`: Command line arguments to pass to mysqldump (see [mysqldump documentation](https://dev.mysql.com/doc/refman/8.0/en/mysqldump.html)).
- `MYSQL_SSL_OPTS`: Command line arguments to use [SSL](https://dev.mysql.com/doc/refman/5.6/en/using-encrypted-connections.html).
- `CRON_TIME`: The interval of cron job to run mysqldump. `0 3 * * sun` by default, which is every Sunday at 03:00. It uses UTC timezone.
- `MAX_BACKUPS`: The number of backups to keep. When reaching the limit, the old backup will be discarded. No limit by default.
- `INIT_BACKUP`: If set, create a backup when the container starts.
- `EXIT_BACKUP`: If set, create a backup when the container stops.
- `TIMEOUT`: Wait a given number of seconds for the database to be ready and make the first backup, `10s` by default. After that time, the initial attempt for backup gives up and only the Cron job will try to make a backup.
- `GZIP_LEVEL`: Specify the level of gzip compression from 1 (quickest, least compressed) to 9 (slowest, most compressed), default is 6.
- `USE_PLAIN_SQL`: If set, skip gzip and keep the dumps as plain `.sql` (or `.sql.gpg` with a PGP key).
- `HEALTHCHECK_MAX_AGE_HOURS`: Max age in hours of the last successful backup before the container turns **unhealthy**, default is 48 (see [Healthcheck](#healthcheck)).
- `TZ`: Specify TIMEZONE in Container. E.g. "Europe/Berlin". Default is UTC.
- `REMOVE_DUPLICATES`: Use [fdupes](https://github.com/adrianlopezroche/fdupes) to remove duplicate database dumps
- `DATABASE_SPLIT_TO_FILE`: If set to `true`, creates a separate directory for each backup session with individual files per database. Default is `false` (flat structure).
- `PGP_KEY`: PGP public key for encrypting backups (as string).
- `PGP_KEY_FILE`: Path to file containing PGP public key. Supports `file:./path/to/key` format or direct path.

## New Features

### Database Split Mode

When `DATABASE_SPLIT_TO_FILE=true`, backups are organized in timestamped directories:

```
/backup/
├── 2025-11-17-15-00-00/
│   ├── database1.sql.gz.gpg
│   ├── database2.sql.gz.gpg
│   └── database3.sql.gz.gpg
├── 2025-11-17-16-00-00/
│   ├── database1.sql.gz.gpg
│   └── database2.sql.gz.gpg
└── latest -> 2025-11-17-16-00-00/
```

### PGP Encryption

Backups can be encrypted using PGP. Encrypted files have `.gpg` extension. The key is imported once
per run and the dump is encrypted on the fly (see [Disk usage](#disk-usage)); if the key cannot be
used, the run is aborted before any dump is written, so no unencrypted file is left behind.

```bash
# Using PGP key from environment variable
docker run -e PGP_KEY="-----BEGIN PGP PUBLIC KEY BLOCK-----..." ...

# Using PGP key from file
docker run -e PGP_KEY_FILE="file:./secrets/pgp_public_key" ...

# Or mount the key file
docker run -v ./secrets:/secrets -e PGP_KEY_FILE="/secrets/pgp_public_key" ...
```

If you want to make this image the perfect companion of your MySQL container, use [docker-compose](https://docs.docker.com/compose/). You can add more services that will be able to connect to the MySQL image using the name `my_mariadb`, note that you only expose the port `3306` internally to the servers and not to the host:

### Docker-compose with MYSQL_PASS env var:

```yaml
version: "2"
services:
  mariadb:
    image: mariadb
    container_name: my_mariadb
    expose:
      - 3306
    volumes:
      - data:/var/lib/mysql
      # If there is not scheme, restore the last created backup (if exists)
      - ${VOLUME_PATH}/backup/latest.${DATABASE_NAME}.sql.gz:/docker-entrypoint-initdb.d/database.sql.gz
    environment:
      - MYSQL_ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD}
      - MYSQL_DATABASE=${DATABASE_NAME}
    restart: unless-stopped

  mysql-cron-backup:
    image: greyhard/docker-mysql-cron-backup-pgp
    depends_on:
      - mariadb
    volumes:
      - ${VOLUME_PATH}/backup:/backup
    environment:
      - MYSQL_HOST=my_mariadb
      - MYSQL_USER=root
      - MYSQL_PASS=${MARIADB_ROOT_PASSWORD}
      - MAX_BACKUPS=15
      - INIT_BACKUP=0
      # Every day at 03:00
      - CRON_TIME=0 3 * * *
      # Make it small
      - GZIP_LEVEL=9
      # As of MySQL 8.0.21 this is needed
      - MYSQLDUMP_OPTS=--no-tablespaces
    restart: unless-stopped

volumes:
  data:
```

### Docker-compose using docker secrets:

The database root password passed to docker container by using [docker secrets](https://docs.docker.com/engine/swarm/).

In example below, docker is in classic 'docker engine mode' (iow. not swarm mode) and secret sources are local files on host filesystem.

Alternatively, secrets can be stored in docker secrets engine (iow. not in host filesystem).

```yaml
version: "3.7"

secrets:
  # Place your secret file somewhere on your host filesystem, with your password inside
  mysql_root_password:
    file: ./secrets/mysql_root_password
  mysql_user:
    file: ./secrets/mysql_user
  mysql_password:
    file: ./secrets/mysql_password
  mysql_database:
    file: ./secrets/mysql_database

services:
  mariadb:
    image: mariadb:10
    container_name: my_mariadb
    expose:
      - 3306
    volumes:
      - data:/var/lib/mysql
      - ${VOLUME_PATH}/backup:/backup
    environment:
      - MYSQL_ROOT_PASSWORD_FILE=/run/secrets/mysql_root_password
      - MYSQL_USER_FILE=/run/secrets/mysql_user
      - MYSQL_PASSWORD_FILE=/run/secrets/mysql_password
      - MYSQL_DATABASE_FILE=/run/secrets/mysql_database
    secrets:
      - mysql_root_password
      - mysql_user
      - mysql_password
      - mysql_database
    restart: unless-stopped

  backup:
    build: .
    image: greyhard/docker-mysql-cron-backup-pgp
    depends_on:
      - mariadb
    volumes:
      - ${VOLUME_PATH}/backup:/backup
    environment:
      - MYSQL_HOST=my_mariadb
      # Alternatively to MYSQL_USER_FILE, we can use MYSQL_USER=root to use root user instead
      - MYSQL_USER_FILE=/run/secrets/mysql_user
      # Alternatively, we can use /run/secrets/mysql_root_password when using root user
      - MYSQL_PASS_FILE=/run/secrets/mysql_password
      - MYSQL_DATABASE_FILE=/run/secrets/mysql_database
      - MAX_BACKUPS=10
      - INIT_BACKUP=1
      - CRON_TIME=0 0 * * *
    secrets:
      - mysql_user
      - mysql_password
      - mysql_database
    restart: unless-stopped

volumes:
  data:

```

### Docker-compose with local MySQL using socket:

```yaml
version: "3.7"

services:
  backup:
    image: greyhard/docker-mysql-cron-backup-pgp
    volumes:
      - ./backup:/backup
      # Mount MySQL socket from host
      - /var/run/mysqld/mysqld.sock:/var/run/mysqld/mysqld.sock
    environment:
      # Use socket instead of TCP connection
      - MYSQL_SOCKET=/var/run/mysqld/mysqld.sock
      - MYSQL_USER=root
      - MYSQL_PASS=my_password
      - MAX_BACKUPS=7
      - INIT_BACKUP=1
      - CRON_TIME=0 3 * * *
      - GZIP_LEVEL=9
    restart: unless-stopped
```

**Note**: Make sure the socket file has appropriate permissions and the MySQL user has access from the Docker container's network namespace.

### Docker-compose with PGP encryption and split mode:

```yaml
version: "3.7"

secrets:
  mysql_root_password:
    file: ./secrets/mysql_root_password
  pgp_public_key:
    file: ./secrets/pgp_public_key
  pgp_private_key:
    file: ./secrets/pgp_private_key

services:
  mariadb:
    image: mariadb:10
    container_name: my_mariadb
    expose:
      - 3306
    volumes:
      - data:/var/lib/mysql
    environment:
      - MYSQL_ROOT_PASSWORD_FILE=/run/secrets/mysql_root_password
      - MYSQL_DATABASE=myapp
    secrets:
      - mysql_root_password
    restart: unless-stopped

  backup:
    image: greyhard/docker-mysql-cron-backup-pgp
    depends_on:
      - mariadb
    volumes:
      - ${VOLUME_PATH}/backup:/backup
    environment:
      - MYSQL_HOST=my_mariadb
      - MYSQL_USER=root
      - MYSQL_PASS_FILE=/run/secrets/mysql_root_password
      - MAX_BACKUPS=7
      - INIT_BACKUP=1
      - CRON_TIME=0 3 * * *
      - GZIP_LEVEL=9
      # Enable split mode - each backup in separate directory
      - DATABASE_SPLIT_TO_FILE=true
      # Enable PGP encryption
      - PGP_KEY_FILE=/run/secrets/pgp_public_key
      - PGP_PRIVATE_KEY_FILE=/run/secrets/pgp_private_key
    secrets:
      - mysql_root_password
      - pgp_public_key
      - pgp_private_key
    restart: unless-stopped

volumes:
  data:
```

## List available backups

See the list of backups in your running docker container:

```bash
docker container exec <your_mysql_backup_container_name> ls -lh /backup
```