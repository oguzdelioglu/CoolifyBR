#!/opt/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR_DEFAULT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_HOME_DEFAULT="${XDG_CONFIG_HOME:-/root/.config}/coolifybr"
CONFIG_FILE_DEFAULT="$CONFIG_HOME_DEFAULT/remote-pull-backup.env"
CONFIG_FILE="${CONFIG_FILE:-$CONFIG_FILE_DEFAULT}"

export PATH="/opt/bin:/opt/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

timestamp_utc() {
    date -u +"%Y%m%dT%H%M%SZ"
}

log() {
    local level="$1"
    shift
    printf '[%s] [%s] %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$level" "$*"
}

fail() {
    log ERROR "$*"
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

ensure_dir() {
    mkdir -p "$1"
}

cleanup() {
    local exit_code=$?
    if [[ -n "${ASKPASS_SCRIPT:-}" && -f "${ASKPASS_SCRIPT:-}" ]]; then
        rm -f "$ASKPASS_SCRIPT"
    fi
    if [[ -n "${LOCK_DIR:-}" && -d "${LOCK_DIR:-}" ]]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    exit "$exit_code"
}

trap cleanup EXIT

if [[ ! -f "$CONFIG_FILE" ]]; then
    fail "Missing config file: $CONFIG_FILE. Copy $SCRIPT_DIR/remote-pull-backup.env.example to $CONFIG_FILE and fill secrets there."
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

REPO_DIR="${REPO_DIR:-$REPO_DIR_DEFAULT}"
BACKUP_JOB_NAME="${BACKUP_JOB_NAME:-remote-coolify}"
REMOTE_ALIAS="${REMOTE_ALIAS:-coolify-source}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-root}"
REMOTE_PORT="${REMOTE_PORT:-22}"
REMOTE_KEY_PATH="${REMOTE_KEY_PATH:-/root/.ssh/id_ed25519_remote_coolify}"
REMOTE_REPO_DIR="${REMOTE_REPO_DIR:-/root/CoolifyBR}"
REMOTE_OUTPUT_DIR="${REMOTE_OUTPUT_DIR:-/root/CoolifyBR/backups}"
LOCAL_BACKUP_ROOT="${LOCAL_BACKUP_ROOT:-/srv/backups/$BACKUP_JOB_NAME}"
BACKUP_MODE="${BACKUP_MODE:-full}"
REMOTE_BACKUP_EXTRA_ARGS="${REMOTE_BACKUP_EXTRA_ARGS:-}"
VERIFY_AFTER_PULL="${VERIFY_AFTER_PULL:-true}"
VERIFY_VOLUME_ARCHIVES="${VERIFY_VOLUME_ARCHIVES:-true}"
DELETE_REMOTE_ARCHIVE_AFTER_PULL="${DELETE_REMOTE_ARCHIVE_AFTER_PULL:-false}"
DELETE_LOCAL_ARCHIVE_AFTER_EXTRACT="${DELETE_LOCAL_ARCHIVE_AFTER_EXTRACT:-false}"
RETENTION_DAILY="${RETENTION_DAILY:-7}"
RETENTION_WEEKLY="${RETENTION_WEEKLY:-4}"
RETENTION_MONTHLY="${RETENTION_MONTHLY:-6}"

[[ -n "$REMOTE_HOST" ]] || fail "REMOTE_HOST must be set"

FILES_DIR="$LOCAL_BACKUP_ROOT/files"
DB_DIR="$LOCAL_BACKUP_ROOT/db"
DOCKER_DIR="$LOCAL_BACKUP_ROOT/docker"
LOG_DIR="$LOCAL_BACKUP_ROOT/logs"
TMP_DIR="$LOCAL_BACKUP_ROOT/tmp"

RUN_ID="$(timestamp_utc)"
RUN_LOG="$LOG_DIR/backup-$RUN_ID.log"
LOCK_DIR="$TMP_DIR/.backup.lock"
LOCAL_ARCHIVE_PATH=""

ensure_dir "$FILES_DIR"
ensure_dir "$DB_DIR"
ensure_dir "$DOCKER_DIR"
ensure_dir "$LOG_DIR"
ensure_dir "$TMP_DIR"

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    fail "Another backup run is already active: $LOCK_DIR"
fi

exec > >(tee -a "$RUN_LOG") 2>&1

ssh_base() {
    ssh \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile=/root/.ssh/known_hosts \
        -o IdentitiesOnly=yes \
        -i "$REMOTE_KEY_PATH" \
        -p "$REMOTE_PORT" \
        "${REMOTE_USER}@${REMOTE_HOST}" "$@"
}

scp_from_remote() {
    scp \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile=/root/.ssh/known_hosts \
        -o IdentitiesOnly=yes \
        -i "$REMOTE_KEY_PATH" \
        -P "$REMOTE_PORT" \
        "${REMOTE_USER}@${REMOTE_HOST}:$1" "$2"
}

make_askpass() {
    ASKPASS_SCRIPT="$(mktemp "$TMP_DIR/askpass.XXXXXX")"
    chmod 700 "$ASKPASS_SCRIPT"
    cat >"$ASKPASS_SCRIPT" <<EOF
#!/bin/sh
echo '${REMOTE_PASSWORD}'
EOF
}

ensure_host_key() {
    [[ -n "${REMOTE_HOST_FINGERPRINT:-}" ]] || return 0

    local actual
    actual="$(ssh-keyscan -t ed25519 -p "$REMOTE_PORT" "$REMOTE_HOST" 2>/dev/null | ssh-keygen -lf - -E sha256 | awk '{print $2}' | head -n 1)"
    [[ -n "$actual" ]] || fail "Could not read remote ED25519 host key fingerprint"
    [[ "$actual" == "$REMOTE_HOST_FINGERPRINT" ]] || fail "Remote host fingerprint mismatch: expected $REMOTE_HOST_FINGERPRINT got $actual"
    ssh-keyscan -H -p "$REMOTE_PORT" "$REMOTE_HOST" >> /root/.ssh/known_hosts 2>/dev/null || true
    sort -u /root/.ssh/known_hosts -o /root/.ssh/known_hosts
    chmod 600 /root/.ssh/known_hosts
}

bool_is_true() {
    case "${1:-false}" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

bootstrap_remote_key() {
    if ssh_base "true" >/dev/null 2>&1; then
        log INFO "SSH key access already works for ${REMOTE_USER}@${REMOTE_HOST}"
        return
    fi

    [[ -n "${REMOTE_PASSWORD:-}" ]] || fail "REMOTE_PASSWORD is empty and key auth is not available"
    [[ -f "${REMOTE_KEY_PATH}.pub" ]] || fail "Missing public key: ${REMOTE_KEY_PATH}.pub"

    local pubkey
    pubkey="$(cat "${REMOTE_KEY_PATH}.pub")"
    make_askpass

    log INFO "Bootstrapping remote authorized_keys on ${REMOTE_HOST}"
    DISPLAY=1 SSH_ASKPASS="$ASKPASS_SCRIPT" SSH_ASKPASS_REQUIRE=force setsid \
        ssh \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile=/root/.ssh/known_hosts \
        -p "$REMOTE_PORT" \
        "${REMOTE_USER}@${REMOTE_HOST}" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF '$pubkey' ~/.ssh/authorized_keys || printf '%s\n' '$pubkey' >> ~/.ssh/authorized_keys"

    rm -f "$ASKPASS_SCRIPT"
    unset ASKPASS_SCRIPT

    ssh_base "true" >/dev/null 2>&1 || fail "Key bootstrap completed but key auth still fails"
    log INFO "SSH key access confirmed for ${REMOTE_USER}@${REMOTE_HOST}"
}

remote_preflight() {
    log INFO "Running remote preflight checks"
    ssh_base "command -v docker >/dev/null && command -v jq >/dev/null && command -v curl >/dev/null && command -v tar >/dev/null && command -v gzip >/dev/null"
}

sync_repo_to_remote() {
    local stage_dir="${REMOTE_REPO_DIR}.incoming"
    log INFO "Syncing local repo to ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_REPO_DIR}"

    ssh_base "rm -rf '$stage_dir' && mkdir -p '$stage_dir'"

    tar \
        --exclude=.git \
        --exclude=backups \
        --exclude=ops/*.env \
        --exclude=ops/*.log \
        -czf - \
        -C "$REPO_DIR" . | ssh_base "tar xzf - -C '$stage_dir'"

    ssh_base "rm -rf '${REMOTE_REPO_DIR}.prev'; if [ -d '$REMOTE_REPO_DIR' ]; then mv '$REMOTE_REPO_DIR' '${REMOTE_REPO_DIR}.prev'; fi; mv '$stage_dir' '$REMOTE_REPO_DIR'; rm -rf '${REMOTE_REPO_DIR}.prev'"
}

collect_remote_inventory() {
    local snapshot_id="$1"
    local inventory_file="$DOCKER_DIR/$snapshot_id/remote-inventory.txt"

    log INFO "Collecting remote Docker and Coolify inventory"
    mkdir -p "$DOCKER_DIR/$snapshot_id"
    ssh_base 'sh <<'"'"'EOF'"'"'
hostname
echo "=== docker ps ==="
docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"
echo "=== docker volumes ==="
docker volume ls --format "{{.Name}}"
echo "=== coolify env summary ==="
if [ -f /data/coolify/source/.env ]; then
  grep -E "^(APP_ID|APP_NAME|DB_USERNAME|REGISTRY_URL)=" /data/coolify/source/.env || true
fi
echo "=== projects count ==="
docker exec coolify-db psql -U coolify -d coolify -Atqc "select count(*) from projects;" 2>/dev/null || true
EOF' >"$inventory_file"
}

run_remote_backup() {
    log INFO "Starting remote CoolifyBR ${BACKUP_MODE} backup"
    ssh_base "mkdir -p '$REMOTE_OUTPUT_DIR' && cd '$REMOTE_REPO_DIR' && chmod +x coolify-backup.sh coolify-restore.sh && ./coolify-backup.sh --mode '$BACKUP_MODE' --output '$REMOTE_OUTPUT_DIR' --non-interactive $REMOTE_BACKUP_EXTRA_ARGS"
}

fetch_latest_archive() {
    ssh_base "ls -1t '$REMOTE_OUTPUT_DIR'/coolify-backup-${BACKUP_MODE}-*.tar.gz 2>/dev/null | head -n 1"
}

extract_snapshot() {
    local snapshot_id="$1"
    local local_archive="$2"
    local extract_root="$TMP_DIR/$snapshot_id"

    rm -rf "$extract_root"
    mkdir -p "$extract_root"
    tar xzf "$local_archive" -C "$extract_root"

    local unpacked_dir
    unpacked_dir="$(find "$extract_root" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    [[ -n "$unpacked_dir" ]] || fail "Archive extraction did not produce a snapshot directory"

    mkdir -p "$FILES_DIR/$snapshot_id" "$DB_DIR/$snapshot_id" "$DOCKER_DIR/$snapshot_id"

    [[ -f "$unpacked_dir/manifest.json" ]] && mv "$unpacked_dir/manifest.json" "$FILES_DIR/$snapshot_id/manifest.json"
    [[ -d "$unpacked_dir/ssh" ]] && mv "$unpacked_dir/ssh" "$FILES_DIR/$snapshot_id/ssh"
    [[ -d "$unpacked_dir/env" ]] && mv "$unpacked_dir/env" "$FILES_DIR/$snapshot_id/env"
    [[ -d "$unpacked_dir/database" ]] && mv "$unpacked_dir/database" "$DB_DIR/$snapshot_id/database"
    [[ -d "$unpacked_dir/volumes" ]] && mv "$unpacked_dir/volumes" "$DOCKER_DIR/$snapshot_id/volumes"
    [[ -d "$unpacked_dir/proxy" ]] && mv "$unpacked_dir/proxy" "$DOCKER_DIR/$snapshot_id/proxy"

    ln -sfn "$FILES_DIR/$snapshot_id" "$LOCAL_BACKUP_ROOT/current-files"
    ln -sfn "$DB_DIR/$snapshot_id" "$LOCAL_BACKUP_ROOT/current-db"
    ln -sfn "$DOCKER_DIR/$snapshot_id" "$LOCAL_BACKUP_ROOT/current-docker"

    rm -rf "$extract_root"
}

write_snapshot_metadata() {
    local snapshot_id="$1"
    local remote_archive="$2"
    local metadata_file="$FILES_DIR/$snapshot_id/pull-metadata.txt"

    {
        printf 'job_name=%s\n' "$BACKUP_JOB_NAME"
        printf 'run_id=%s\n' "$snapshot_id"
        printf 'remote_host=%s\n' "$REMOTE_HOST"
        printf 'remote_user=%s\n' "$REMOTE_USER"
        printf 'remote_port=%s\n' "$REMOTE_PORT"
        printf 'remote_archive=%s\n' "$remote_archive"
        printf 'backup_mode=%s\n' "$BACKUP_MODE"
        printf 'local_archive=%s\n' "${LOCAL_ARCHIVE_PATH:-}"
        printf 'completed_at=%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    } >"$metadata_file"
}

verify_local_snapshot() {
    local snapshot_id="$1"
    local archive_path="$2"
    local manifest="$FILES_DIR/$snapshot_id/manifest.json"
    local inventory="$DOCKER_DIR/$snapshot_id/remote-inventory.txt"

    log INFO "Verifying pulled snapshot"

    [[ -f "$manifest" ]] || fail "Manifest missing after extraction: $manifest"
    [[ -s "$inventory" ]] || fail "Remote inventory missing or empty: $inventory"

    if [[ -n "$archive_path" && -f "$archive_path" ]]; then
        tar tzf "$archive_path" >/dev/null
    fi

    if [[ -d "$DB_DIR/$snapshot_id/database" ]]; then
        find "$DB_DIR/$snapshot_id/database" -type f -size +0c | grep -q . || fail "Database backup directory exists but contains no non-empty files"
    fi

    if bool_is_true "$VERIFY_VOLUME_ARCHIVES" && [[ -d "$DOCKER_DIR/$snapshot_id/volumes" ]]; then
        while IFS= read -r archive; do
            gzip -t "$archive"
        done < <(find "$DOCKER_DIR/$snapshot_id/volumes" -type f -name '*.tar.gz' | sort)
    fi

    log INFO "Verification passed"
}

cleanup_transferred_archives() {
    local remote_archive="$1"
    local archive_path="$2"

    if bool_is_true "$DELETE_REMOTE_ARCHIVE_AFTER_PULL"; then
        log INFO "Deleting remote archive: $remote_archive"
        ssh_base "rm -f '$remote_archive'"
    fi

    if bool_is_true "$DELETE_LOCAL_ARCHIVE_AFTER_EXTRACT" && [[ -n "$archive_path" && -f "$archive_path" ]]; then
        log INFO "Deleting local pulled archive: $archive_path"
        rm -f "$archive_path"
    fi
}

prune_snapshots() {
    log INFO "Applying retention policy: daily=${RETENTION_DAILY}, weekly=${RETENTION_WEEKLY}, monthly=${RETENTION_MONTHLY}"

    local snapshot_ids=()
    mapfile -t snapshot_ids < <(find "$FILES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | grep -E '^[0-9]{8}T[0-9]{6}Z$' | sort -r)
    (( ${#snapshot_ids[@]} == 0 )) && return

    declare -A keep_map=()
    declare -A day_seen=()
    declare -A week_seen=()
    declare -A month_seen=()

    keep_map["${snapshot_ids[0]}"]=1

    local id day_key week_key month_key
    for id in "${snapshot_ids[@]}"; do
        [[ -n "${keep_map[$id]:-}" ]] && continue

        day_key="${id:0:8}"
        if (( ${#day_seen[@]} < RETENTION_DAILY )) && [[ -z "${day_seen[$day_key]:-}" ]]; then
            day_seen["$day_key"]=1
            keep_map["$id"]=1
            continue
        fi

        week_key="$(date -u -d "${id:0:4}-${id:4:2}-${id:6:2}" +%G-W%V)"
        if (( ${#week_seen[@]} < RETENTION_WEEKLY )) && [[ -z "${week_seen[$week_key]:-}" ]]; then
            week_seen["$week_key"]=1
            keep_map["$id"]=1
            continue
        fi

        month_key="${id:0:6}"
        if (( ${#month_seen[@]} < RETENTION_MONTHLY )) && [[ -z "${month_seen[$month_key]:-}" ]]; then
            month_seen["$month_key"]=1
            keep_map["$id"]=1
        fi
    done

    for id in "${snapshot_ids[@]}"; do
        [[ -n "${keep_map[$id]:-}" ]] && continue
        log INFO "Pruning snapshot $id"
        rm -rf "$FILES_DIR/$id" "$DB_DIR/$id" "$DOCKER_DIR/$id"
    done
}

main() {
    require_cmd ssh
    require_cmd scp
    require_cmd ssh-keyscan
    require_cmd ssh-keygen
    require_cmd tar
    require_cmd tee
    require_cmd find
    require_cmd gzip

    [[ -d "$REPO_DIR" ]] || fail "Repo directory not found: $REPO_DIR"
    [[ -f "$REMOTE_KEY_PATH" ]] || fail "Missing private key: $REMOTE_KEY_PATH"

    ensure_host_key

    log INFO "Job: $BACKUP_JOB_NAME"
    log INFO "Run id: $RUN_ID"
    bootstrap_remote_key
    remote_preflight
    sync_repo_to_remote
    run_remote_backup

    local remote_archive
    remote_archive="$(fetch_latest_archive)"
    [[ -n "$remote_archive" ]] || fail "Could not find remote backup archive under $REMOTE_OUTPUT_DIR"
    log INFO "Latest remote archive: $remote_archive"

    local local_snapshot_dir="$FILES_DIR/$RUN_ID"
    mkdir -p "$local_snapshot_dir"
    local local_archive="$local_snapshot_dir/$(basename "$remote_archive")"
    LOCAL_ARCHIVE_PATH="$local_archive"

    scp_from_remote "$remote_archive" "$local_archive"
    collect_remote_inventory "$RUN_ID"
    extract_snapshot "$RUN_ID" "$local_archive"
    write_snapshot_metadata "$RUN_ID" "$remote_archive"
    if bool_is_true "$VERIFY_AFTER_PULL"; then
        verify_local_snapshot "$RUN_ID" "$local_archive"
    fi
    cleanup_transferred_archives "$remote_archive" "$local_archive"
    prune_snapshots

    log INFO "Backup completed successfully"
    log INFO "Files snapshot: $FILES_DIR/$RUN_ID"
    log INFO "DB snapshot: $DB_DIR/$RUN_ID"
    log INFO "Docker snapshot: $DOCKER_DIR/$RUN_ID"
}

main "$@"
