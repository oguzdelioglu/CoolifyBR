#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

PROFILE="source-server"
INSTALL_DIR="/usr/local/bin"
CONFIG_HOME="${XDG_CONFIG_HOME:-/root/.config}/coolifybr"
LINK_NAME="coolifybr"

usage() {
    cat <<EOF
CoolifyBR installer

Usage:
  $(basename "$0") [options]

Options:
  --profile NAME     Install profile: source-server, backup-host, full (default: ${PROFILE})
  --install-dir DIR  Directory for the coolifybr symlink (default: ${INSTALL_DIR})
  --config-home DIR  Config home for example files (default: ${CONFIG_HOME})
  -h, --help         Show this help

Profiles:
  source-server  Prepare a Coolify server for local backup/restore usage
  backup-host    Prepare a NAS/backup host for remote pull backup jobs
  full           Install both source-server and backup-host assets
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            PROFILE="$2"
            shift 2
            ;;
        --install-dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        --config-home)
            CONFIG_HOME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing command: $1" >&2
        exit 1
    }
}

install_file_mode() {
    local mode="$1"
    local path="$2"
    chmod "$mode" "$path"
}

copy_if_missing() {
    local src="$1"
    local dst="$2"
    if [[ ! -f "$dst" ]]; then
        cp "$src" "$dst"
        echo "Created example config: $dst"
    else
        echo "Keeping existing file: $dst"
    fi
}

print_summary() {
    cat <<EOF

Install complete

Profile:      $PROFILE
Repo:         $REPO_DIR
CLI symlink:  $INSTALL_DIR/$LINK_NAME
Config home:  $CONFIG_HOME

Next steps:
  1. Review README.md
  2. Fill any copied example config files
  3. Run 'coolifybr help'
EOF
}

require_cmd bash
require_cmd chmod
require_cmd mkdir
require_cmd ln

mkdir -p "$INSTALL_DIR" "$CONFIG_HOME"

ln -sfn "$REPO_DIR/coolifybr" "$INSTALL_DIR/$LINK_NAME"
install_file_mode 755 "$REPO_DIR/coolifybr"
install_file_mode 755 "$REPO_DIR/coolify-backup.sh"
install_file_mode 755 "$REPO_DIR/coolify-restore.sh"
install_file_mode 755 "$REPO_DIR/ops/remote-pull-backup.sh"
install_file_mode 755 "$REPO_DIR/ops/run-remote-pull-jobs.sh"
install_file_mode 755 "$REPO_DIR/ops/install-remote-pull-cron.sh"
install_file_mode 755 "$REPO_DIR/ops/install-remote-pull-jobs-cron.sh"
install_file_mode 755 "$REPO_DIR/ops/verify-remote-pull-backup.sh"
install_file_mode 755 "$REPO_DIR/scripts/install.sh"

case "$PROFILE" in
    source-server)
        copy_if_missing "$REPO_DIR/config.env" "$CONFIG_HOME/config.env"
        ;;
    backup-host)
        mkdir -p "$CONFIG_HOME/jobs"
        copy_if_missing "$REPO_DIR/ops/remote-pull-backup.env.example" "$CONFIG_HOME/remote-pull-backup.env"
        copy_if_missing "$REPO_DIR/ops/remote-pull-backup.env.example" "$CONFIG_HOME/jobs/example.env"
        ;;
    full)
        copy_if_missing "$REPO_DIR/config.env" "$CONFIG_HOME/config.env"
        mkdir -p "$CONFIG_HOME/jobs"
        copy_if_missing "$REPO_DIR/ops/remote-pull-backup.env.example" "$CONFIG_HOME/remote-pull-backup.env"
        copy_if_missing "$REPO_DIR/ops/remote-pull-backup.env.example" "$CONFIG_HOME/jobs/example.env"
        ;;
    *)
        echo "Unsupported profile: $PROFILE" >&2
        exit 1
        ;;
esac

print_summary
