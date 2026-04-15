#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bootstrap.sh"

JOB_NAME=""
REMOTE_HOST="203.0.113.10"
REMOTE_USER="root"
REMOTE_PORT="22"
REMOTE_KEY_PATH="/root/.ssh/id_ed25519_remote_coolify"
LOCAL_BACKUP_ROOT=""
SCHEDULE_HOUR="2"
SCHEDULE_MINUTE="30"
CONFIG_DIR="$(coolifybr_config_home)/jobs"

usage() {
    cat <<EOF
CoolifyBR init-job

Usage:
  $(basename "$0") --name NAME [options]

Options:
  --name NAME         Job name, also used as default alias and file name
  --host HOST         Remote host placeholder or real host
  --user USER         Remote SSH user (default: root)
  --port PORT         Remote SSH port (default: 22)
  --key PATH          Remote SSH private key path
  --backup-root PATH  Local backup root
  --hour HOUR         Default schedule hour (default: 2)
  --minute MINUTE     Default schedule minute (default: 30)
  --config-dir DIR    Directory where the job config will be written
  -h, --help          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) JOB_NAME="$2"; shift 2 ;;
        --host) REMOTE_HOST="$2"; shift 2 ;;
        --user) REMOTE_USER="$2"; shift 2 ;;
        --port) REMOTE_PORT="$2"; shift 2 ;;
        --key) REMOTE_KEY_PATH="$2"; shift 2 ;;
        --backup-root) LOCAL_BACKUP_ROOT="$2"; shift 2 ;;
        --hour) SCHEDULE_HOUR="$2"; shift 2 ;;
        --minute) SCHEDULE_MINUTE="$2"; shift 2 ;;
        --config-dir) CONFIG_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[[ -n "$JOB_NAME" ]] || { echo "--name is required" >&2; exit 1; }
[[ -n "$LOCAL_BACKUP_ROOT" ]] || LOCAL_BACKUP_ROOT="/srv/backups/$JOB_NAME"

mkdir -p "$CONFIG_DIR"
OUTPUT_FILE="$CONFIG_DIR/$JOB_NAME.env"
if [[ -e "$OUTPUT_FILE" ]]; then
    echo "Config already exists: $OUTPUT_FILE" >&2
    exit 1
fi

render_job_config \
    "$JOB_NAME" \
    "$REMOTE_HOST" \
    "$REMOTE_USER" \
    "$REMOTE_PORT" \
    "$REMOTE_KEY_PATH" \
    "$LOCAL_BACKUP_ROOT" \
    "$SCHEDULE_HOUR" \
    "$SCHEDULE_MINUTE" > "$OUTPUT_FILE"

python_notice=""
if [[ -d "$REPO_DIR" ]]; then
    python_notice="Set REPO_DIR in $OUTPUT_FILE to: $REPO_DIR"
fi

cat <<EOF
Created job config: $OUTPUT_FILE
$python_notice
Next steps:
  1. Fill REMOTE_HOST / credentials / REPO_DIR
  2. Run: CONFIG_FILE=$OUTPUT_FILE $REPO_DIR/ops/remote-pull-backup.sh
  3. Install cron after validation
EOF
