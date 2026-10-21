FROM alpine:3.20.3
LABEL maintainer="Ilynikh Denis <greyhard@gmail.com>"

RUN apk add --update \
    tzdata \
    bash \
    gzip \
    openssl \
    mysql-client=~10.11 \
    mariadb-connector-c \
    netcat-openbsd \
    gnupg \
    fdupes && \
    rm -rf /var/cache/apk/*

ENV CRON_TIME="0 3 * * sun" \
    MYSQL_HOST="mysql" \
    MYSQL_PORT="3306" \
    MYSQL_SOCKET="" \
    TIMEOUT="10" \
    MYSQLDUMP_OPTS="--quick" \
    HEALTHCHECK_MAX_AGE_HOURS="48"

COPY ["run.sh", "backup.sh", "delete.sh", "env.sh", "healthcheck.sh", "/"]
RUN mkdir /backup && \
    chmod 777 /backup && \ 
    chmod 755 /run.sh /backup.sh /delete.sh /env.sh /healthcheck.sh && \
    touch /mysql_backup.log && \
    chmod 666 /mysql_backup.log

VOLUME ["/backup"]

# start-period covers INIT_BACKUP of a large database; start-interval reports healthy soon after it
HEALTHCHECK --interval=60s --timeout=10s --start-period=30m --start-interval=5s --retries=3 \
    CMD ["/healthcheck.sh"]

CMD ["/run.sh"]
