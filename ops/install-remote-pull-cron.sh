#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CONFIG_FILE="${CONFIG_FILE:-/root/.config/coolifybr/remote-pull-backup.env}"
# Which file the running cron daemon actually reads varies by distro: Debian and
# ASUSTOR ADM use /var/spool/cron/crontabs/root, Alpine/busybox images use
# /etc/crontabs/root, RHEL uses /var/spool/cron/root. Writing a correct entry
# into a file nothing reads is silent — the job simply never runs — so prefer a
# crontab that already exists over creating a new one.
detect_cron_file() {
    local candidate
    for candidate in /var/spool/cron/crontabs/root /etc/crontabs/root /var/spool/cron/root; do
        [[ -f "$candidate" ]] && { printf '%s' "$candidate"; return; }
    done
    printf '/etc/crontabs/root'
}
CRON_FILE="${CRON_FILE:-$(detect_cron_file)}"
# shellcheck source=/dev/null
source "$REPO_DIR/scripts/lib/bootstrap.sh"

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
CRON_LINE="$(cron_line_for_job "$REPO_DIR" "$CONFIG_FILE" "$LOCAL_BACKUP_ROOT" "$SCHEDULE_HOUR" "$SCHEDULE_MINUTE")"

mkdir -p "$(dirname "$CRON_FILE")" "${LOCAL_BACKUP_ROOT}/logs"
touch "$CRON_FILE"

grep -Fv "${REPO_DIR}/ops/remote-pull-backup.sh" "$CRON_FILE" > "${CRON_FILE}.tmp" || true
printf '%s\n' "$CRON_LINE" >> "${CRON_FILE}.tmp"
mv "${CRON_FILE}.tmp" "$CRON_FILE"

# Deliberately no `kill -HUP`. busybox crond — what appliance NASes run — treats
# SIGHUP as terminate, not reload: sending it here killed the daemon outright and
# took the system's own cron jobs down with it. Both busybox crond and cronie
# poll the crontab's mtime and pick up an edit within a minute, so no signal is
# needed. Warn instead if nothing is running to read the entry.
if ! pidof crond >/dev/null 2>&1 && ! pidof cron >/dev/null 2>&1; then
    echo "Warning: no cron daemon is running, so this entry will not fire." >&2
fi

printf 'Installed cron entry in %s:\n%s\n' "$CRON_FILE" "$CRON_LINE"
