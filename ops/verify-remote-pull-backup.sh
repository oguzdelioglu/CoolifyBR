#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $(basename "$0") <backup-root> [snapshot-id]" >&2
    exit 1
fi

BACKUP_ROOT="$1"
SNAPSHOT_ID="${2:-}"

FILES_DIR="$BACKUP_ROOT/files"
DB_DIR="$BACKUP_ROOT/db"
DOCKER_DIR="$BACKUP_ROOT/docker"

if [[ -z "$SNAPSHOT_ID" ]]; then
    SNAPSHOT_ID="$(find "$FILES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | head -n 1)"
fi

[[ -n "$SNAPSHOT_ID" ]] || { echo "No snapshot found" >&2; exit 1; }

MANIFEST="$FILES_DIR/$SNAPSHOT_ID/manifest.json"
METADATA="$FILES_DIR/$SNAPSHOT_ID/pull-metadata.txt"
INVENTORY="$DOCKER_DIR/$SNAPSHOT_ID/remote-inventory.txt"

[[ -f "$MANIFEST" ]] || { echo "Missing manifest: $MANIFEST" >&2; exit 1; }
[[ -s "$INVENTORY" ]] || { echo "Missing or empty inventory: $INVENTORY" >&2; exit 1; }

if [[ -f "$METADATA" ]]; then
    ARCHIVE_PATH="$(awk -F= '/^local_archive=/{print $2}' "$METADATA" | tail -n 1)"
    if [[ -n "$ARCHIVE_PATH" && -f "$ARCHIVE_PATH" ]]; then
        tar tzf "$ARCHIVE_PATH" >/dev/null
    fi
else
    echo "Metadata file not found, continuing with legacy snapshot checks: $METADATA"
fi

if [[ -d "$DB_DIR/$SNAPSHOT_ID/database" ]]; then
    find "$DB_DIR/$SNAPSHOT_ID/database" -type f -size +0c | grep -q . || { echo "Database dump directory is empty" >&2; exit 1; }
fi

if [[ -d "$DOCKER_DIR/$SNAPSHOT_ID/volumes" ]]; then
    while IFS= read -r archive; do
        gzip -t "$archive"
    done < <(find "$DOCKER_DIR/$SNAPSHOT_ID/volumes" -type f -name '*.tar.gz' | sort)
fi

echo "Verification passed for snapshot $SNAPSHOT_ID"
