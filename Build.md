# Build Instructions

## Release (CI)

Pushing a version tag (no `v` prefix) publishes the image to Docker Hub as `:<tag>` and `:latest`
for linux/amd64, linux/arm/v7 and linux/arm64 (`.github/workflows/build.yml`):

```bash
git tag 1.1
git push origin 1.1
```

The workflow needs the repository secret `DOCKER_PASSWORD` — a Docker Hub access token of `greyhard`
with Read & Write scope: `gh secret set DOCKER_PASSWORD`.

The manual build below is only for releases outside CI.

## Setup buildx for multi-platform builds

First time only - create a builder:

```bash
docker buildx use multiplatform
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