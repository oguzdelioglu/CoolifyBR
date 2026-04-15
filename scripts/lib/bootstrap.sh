#!/usr/bin/env bash

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Missing command: $1" >&2
        exit 1
    }
}

bool_is_true() {
    case "${1:-false}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

coolifybr_config_home() {
    printf '%s\n' "${XDG_CONFIG_HOME:-/root/.config}/coolifybr"
}

detect_package_manager() {
    local managers=("apt-get" "dnf" "yum" "apk" "opkg")
    local manager
    for manager in "${managers[@]}"; do
        if command -v "$manager" >/dev/null 2>&1; then
            printf '%s\n' "$manager"
            return 0
        fi
    done
    return 1
}

profile_dependencies() {
    local profile="${1:-source-server}"
    case "$profile" in
        source-server)
            printf '%s\n' bash tar gzip jq curl docker
            ;;
        backup-host)
            printf '%s\n' bash tar gzip jq curl ssh scp ssh-keyscan ssh-keygen find tee
            ;;
        full)
            printf '%s\n' bash tar gzip jq curl docker ssh scp ssh-keyscan ssh-keygen find tee
            ;;
        *)
            return 1
            ;;
    esac
}

missing_dependencies() {
    local profile="${1:-source-server}"
    local dep
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        if ! command -v "$dep" >/dev/null 2>&1; then
            printf '%s\n' "$dep"
        fi
    done < <(profile_dependencies "$profile")
}

install_cmd_for_manager() {
    local manager="$1"
    shift
    case "$manager" in
        apt-get)
            printf 'apt-get update && apt-get install -y %s\n' "$*"
            ;;
        dnf)
            printf 'dnf install -y %s\n' "$*"
            ;;
        yum)
            printf 'yum install -y %s\n' "$*"
            ;;
        apk)
            printf 'apk add %s\n' "$*"
            ;;
        opkg)
            printf 'opkg update && opkg install %s\n' "$*"
            ;;
        *)
            return 1
            ;;
    esac
}

attempt_dependency_install() {
    local profile="$1"
    local missing=()
    mapfile -t missing < <(missing_dependencies "$profile")
    (( ${#missing[@]} == 0 )) && return 0

    local manager
    manager="$(detect_package_manager 2>/dev/null || true)"
    [[ -n "$manager" ]] || return 1

    local install_cmd
    install_cmd="$(install_cmd_for_manager "$manager" "${missing[@]}")" || return 1
    sh -lc "$install_cmd"
}

doctor_check_commands() {
    local missing=()
    mapfile -t missing < <(missing_dependencies "$1")
    if (( ${#missing[@]} > 0 )); then
        printf 'missing_commands=%s\n' "${missing[*]}"
        return 1
    fi
    printf 'missing_commands=\n'
}

doctor_check_source_server() {
    local coolify_base="${1:-/data/coolify}"
    doctor_check_commands source-server || true
    if [[ ! -d "$coolify_base" ]]; then
        printf 'coolify_base=missing\n'
        return 1
    fi
    printf 'coolify_base=ok\n'
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        printf 'docker=ok\n'
    else
        printf 'docker=unavailable\n'
        return 1
    fi
}

doctor_check_backup_host() {
    local config_home="${1:-$(coolifybr_config_home)}"
    local config_file="${2:-$config_home/remote-pull-backup.env}"
    doctor_check_commands backup-host || true
    if [[ -f "$config_file" ]]; then
        printf 'config_file=ok\n'
    else
        printf 'config_file=missing\n'
    fi
    if [[ -d "$config_home/jobs" ]]; then
        printf 'jobs_dir=ok\n'
    else
        printf 'jobs_dir=missing\n'
    fi
}

render_job_config() {
    local job_name="$1"
    local remote_host="$2"
    local remote_user="$3"
    local remote_port="$4"
    local remote_key_path="$5"
    local local_backup_root="$6"
    local schedule_hour="$7"
    local schedule_minute="$8"

    cat <<EOF
REPO_DIR="/path/to/CoolifyBR"

BACKUP_JOB_NAME="${job_name}"
REMOTE_ALIAS="${job_name}"
REMOTE_HOST="${remote_host}"
REMOTE_USER="${remote_user}"
REMOTE_PORT="${remote_port}"
REMOTE_PASSWORD=""
REMOTE_KEY_PATH="${remote_key_path}"
REMOTE_HOST_FINGERPRINT=""

REMOTE_REPO_DIR="/root/CoolifyBR"
REMOTE_OUTPUT_DIR="/root/CoolifyBR/backups"

LOCAL_BACKUP_ROOT="${local_backup_root}"

BACKUP_MODE="full"
REMOTE_BACKUP_EXTRA_ARGS=""
VERIFY_AFTER_PULL="true"
VERIFY_VOLUME_ARCHIVES="true"
DELETE_REMOTE_ARCHIVE_AFTER_PULL="false"
DELETE_LOCAL_ARCHIVE_AFTER_EXTRACT="false"
RETENTION_DAILY="7"
RETENTION_WEEKLY="4"
RETENTION_MONTHLY="6"
SCHEDULE_HOUR="${schedule_hour}"
SCHEDULE_MINUTE="${schedule_minute}"
EOF
}

cron_line_for_job() {
    local repo_dir="$1"
    local config_file="$2"
    local backup_root="$3"
    local hour="$4"
    local minute="$5"
    printf '%s %s * * * cd %s && CONFIG_FILE=%s %s/ops/remote-pull-backup.sh >> %s/logs/cron.log 2>&1\n' \
        "$minute" "$hour" "$repo_dir" "$config_file" "$repo_dir" "$backup_root"
}
