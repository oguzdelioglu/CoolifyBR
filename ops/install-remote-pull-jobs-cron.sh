#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIG_DIR="${CONFIG_DIR:-/root/.config/coolifybr/jobs}"
# shellcheck source=/dev/null
source "$REPO_DIR/scripts/lib/bootstrap.sh"
CRON_FILE="${CRON_FILE:-$(detect_cron_file)}"

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
    # Clear the four values read below before each source. They are all resolved
    # with :- defaults, so a config that omits one would otherwise silently
    # inherit the previous job's value and write that job's backup root or
    # schedule into this job's cron line.
    unset BACKUP_JOB_NAME LOCAL_BACKUP_ROOT SCHEDULE_MINUTE SCHEDULE_HOUR
    # shellcheck source=/dev/null
    source "$config"
    BACKUP_JOB_NAME="${BACKUP_JOB_NAME:-remote-coolify}"
    LOCAL_BACKUP_ROOT="${LOCAL_BACKUP_ROOT:-/srv/backups/$BACKUP_JOB_NAME}"
    SCHEDULE_MINUTE="${SCHEDULE_MINUTE:-30}"
    SCHEDULE_HOUR="${SCHEDULE_HOUR:-2}"

    mkdir -p "${LOCAL_BACKUP_ROOT}/logs"
    cron_line_for_job "$REPO_DIR" "$config" "$LOCAL_BACKUP_ROOT" "$SCHEDULE_HOUR" "$SCHEDULE_MINUTE" >> "${CRON_FILE}.tmp"
done

mv "${CRON_FILE}.tmp" "$CRON_FILE"

warn_if_no_cron_daemon

echo "Installed cron entries from $CONFIG_DIR into $CRON_FILE"
