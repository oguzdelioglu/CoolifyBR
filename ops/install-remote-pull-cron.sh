#!/opt/bin/bash

set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIG_FILE="${CONFIG_FILE:-/root/.config/coolifybr/remote-pull-backup.env}"
CRON_FILE="${CRON_FILE:-/etc/crontabs/root}"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Missing config file: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

BACKUP_JOB_NAME="${BACKUP_JOB_NAME:-remote-coolify}"
LOCAL_BACKUP_ROOT="${LOCAL_BACKUP_ROOT:-/srv/backups/$BACKUP_JOB_NAME}"
SCHEDULE_MINUTE="${SCHEDULE_MINUTE:-30}"
SCHEDULE_HOUR="${SCHEDULE_HOUR:-2}"
CRON_LINE="${SCHEDULE_MINUTE} ${SCHEDULE_HOUR} * * * cd ${REPO_DIR} && CONFIG_FILE=${CONFIG_FILE} ${REPO_DIR}/ops/remote-pull-backup.sh >> ${LOCAL_BACKUP_ROOT}/logs/cron.log 2>&1"

mkdir -p "$(dirname "$CRON_FILE")" "${LOCAL_BACKUP_ROOT}/logs"
touch "$CRON_FILE"

grep -Fv "${REPO_DIR}/ops/remote-pull-backup.sh" "$CRON_FILE" > "${CRON_FILE}.tmp" || true
printf '%s\n' "$CRON_LINE" >> "${CRON_FILE}.tmp"
mv "${CRON_FILE}.tmp" "$CRON_FILE"

if pidof crond >/dev/null 2>&1; then
    kill -HUP "$(pidof crond | awk '{print $1}')"
fi

printf 'Installed cron entry:\n%s\n' "$CRON_LINE"
