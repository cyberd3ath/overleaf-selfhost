#!/bin/bash
set -Eeuo pipefail

DATA_DIR="${DATA_DIR:-/srv/overleaf}"
TOOLKIT_DIR="${TOOLKIT_DIR:-/home/overleaf/overleaf-toolkit}"
BACKUP_ROOT="${BACKUP_ROOT:-/srv/overleaf-backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"

SHARELATEX="${SHARELATEX_CONTAINER:-sharelatex}"
REDIS="${REDIS_CONTAINER:-redis}"
MONGO="${MONGO_CONTAINER:-mongo}"

DATE="$(date '+%Y-%m-%d_%H-%M-%S')"
BACKUP_DIR="${BACKUP_ROOT}/${DATE}"
TMP_DIR="${BACKUP_ROOT}/.tmp-${DATE}"

cleanup() {
    docker start "$REDIS" >/dev/null 2>&1 || true
    docker start "$SHARELATEX" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$TMP_DIR"

docker stop "$SHARELATEX"
docker exec "$MONGO" sh -c 'mongodump --archive --gzip' > "${TMP_DIR}/mongo.archive.gz"
docker stop "$REDIS"

tar --zstd -C "$DATA_DIR" -cf "${TMP_DIR}/overleaf.tar.zst" overleaf
tar --zstd -C "$DATA_DIR" -cf "${TMP_DIR}/redis.tar.zst" redis
tar --zstd -C "$TOOLKIT_DIR" -cf "${TMP_DIR}/toolkit-config.tar.zst" config

mkdir -p "$BACKUP_DIR"
mv "${TMP_DIR}"/* "$BACKUP_DIR"/

cat > "${BACKUP_DIR}/backup-info.txt" <<EOF
Backup created: $(date --iso-8601=seconds)
Hostname: $(hostname)
Data dir: ${DATA_DIR}
Toolkit config: ${TOOLKIT_DIR}/config
Mongo backup: mongodump --archive --gzip
EOF

find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' \
    -mtime "+$((RETENTION_DAYS - 1))" -exec rm -rf -- {} +
