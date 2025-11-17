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
    TIMEOUT="10" \
    MYSQLDUMP_OPTS="--quick"

COPY ["run.sh", "backup.sh", "/delete.sh", "/"]
RUN mkdir /backup && \
    chmod 777 /backup && \ 
    chmod 755 /run.sh /backup.sh /delete.sh && \
    touch /mysql_backup.log && \
    chmod 666 /mysql_backup.log

VOLUME ["/backup"]

HEALTHCHECK --interval=2s --retries=1800 \
    CMD stat /HEALTHY.status || exit 1

CMD ["/run.sh"]
