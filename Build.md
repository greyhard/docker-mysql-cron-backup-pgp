# Build Instructions

## Setup buildx for multi-platform builds

First time only - create a builder:

```bash
docker buildx create --name multiplatform --driver docker-container --use
docker buildx inspect --bootstrap
```

## Build and push multi-platform image

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t greyhard/docker-mysql-cron-backup-pgp:latest --push .
```

## Build locally (single platform)

```bash
docker build -t greyhard/docker-mysql-cron-backup-pgp:latest .
```

## Switch back to default builder

```bash
docker buildx use default
```