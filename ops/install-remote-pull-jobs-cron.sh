#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIG_DIR="${CONFIG_DIR:-/root/.config/coolifybr/jobs}"
CRON_FILE="${CRON_FILE:-/etc/crontabs/root}"

if [[ ! -d "$CONFIG_DIR" ]]; then
    echo "Missing config directory: $CONFIG_DIR" >&2
    exit 1
fi

mapfile -t configs < <(find "$CONFIG_DIR" -maxdepth 1 -type f -name '*.env' | sort)
if (( ${#configs[@]} == 0 )); then
    echo "No job configs found in $CONFIG_DIR" >&2
    exit 1
fi

mkdir -p "$(dirname "$CRON_FILE")"
touch "$CRON_FILE"

grep -Fv "${REPO_DIR}/ops/remote-pull-backup.sh" "$CRON_FILE" | grep -Fv "${REPO_DIR}/ops/run-remote-pull-jobs.sh" > "${CRON_FILE}.tmp" || true

for config in "${configs[@]}"; do
    # shellcheck source=/dev/null
    source "$config"
    BACKUP_JOB_NAME="${BACKUP_JOB_NAME:-remote-coolify}"
    LOCAL_BACKUP_ROOT="${LOCAL_BACKUP_ROOT:-/srv/backups/$BACKUP_JOB_NAME}"
    SCHEDULE_MINUTE="${SCHEDULE_MINUTE:-30}"
    SCHEDULE_HOUR="${SCHEDULE_HOUR:-2}"

    mkdir -p "${LOCAL_BACKUP_ROOT}/logs"
    printf '%s %s * * * cd %s && CONFIG_FILE=%s %s/ops/remote-pull-backup.sh >> %s/logs/cron.log 2>&1\n' \
        "$SCHEDULE_MINUTE" \
        "$SCHEDULE_HOUR" \
        "$REPO_DIR" \
        "$config" \
        "$REPO_DIR" \
        "$LOCAL_BACKUP_ROOT" >> "${CRON_FILE}.tmp"
done

mv "${CRON_FILE}.tmp" "$CRON_FILE"

if pidof crond >/dev/null 2>&1; then
    kill -HUP "$(pidof crond | awk '{print $1}')"
fi

echo "Installed cron entries from $CONFIG_DIR"
