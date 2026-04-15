#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bootstrap.sh"

PROFILE="auto"
CONFIG_HOME="$(coolifybr_config_home)"
CONFIG_FILE=""

usage() {
    cat <<EOF
CoolifyBR doctor

Usage:
  $(basename "$0") [options]

Options:
  --profile NAME    auto, source-server, backup-host (default: auto)
  --config-home DIR Override config home
  --config-file FILE Override remote pull config file
  -h, --help        Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile) PROFILE="$2"; shift 2 ;;
        --config-home) CONFIG_HOME="$2"; shift 2 ;;
        --config-file) CONFIG_FILE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ "$PROFILE" == "auto" ]]; then
    if [[ -d /data/coolify ]]; then
        PROFILE="source-server"
    else
        PROFILE="backup-host"
    fi
fi

printf 'profile=%s\n' "$PROFILE"
case "$PROFILE" in
    source-server)
        doctor_check_source_server "/data/coolify"
        ;;
    backup-host)
        doctor_check_backup_host "$CONFIG_HOME" "${CONFIG_FILE:-$CONFIG_HOME/remote-pull-backup.env}"
        ;;
    *)
        echo "Unsupported profile: $PROFILE" >&2
        exit 1
        ;;
esac
