#!/bin/bash
# ============================================================
# CoolifyBR - Coolify Restore Tool
# Restores Coolify backups created by coolify-backup.sh
# Supports full, project, and selective restore
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load libraries
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/api.sh"
source "$SCRIPT_DIR/lib/database.sh"
source "$SCRIPT_DIR/lib/volumes.sh"
source "$SCRIPT_DIR/lib/ssh_keys.sh"
source "$SCRIPT_DIR/lib/transfer.sh"

# Set cleanup trap
trap trap_cleanup EXIT

# ============================================================
# CLI Arguments
# ============================================================
BACKUP_FILE=""
RESTORE_MODE=""
NON_INTERACTIVE=false
SKIP_VOLUMES=false
SKIP_DB=false
SKIP_SSH=false
SKIP_ENV=false
SKIP_PROXY=false
SKIP_RESTART=false

usage() {
    cat <<EOF
${BOLD}CoolifyBR - Coolify Restore Tool${NC}

${BOLD}Usage:${NC}
  $(basename "$0") [OPTIONS]

${BOLD}Options:${NC}
  --file PATH          Path to backup archive (.tar.gz)
  --mode MODE          Restore mode: full, selective (default: auto-detect from manifest)
  --skip-volumes       Skip Docker volume restore
  --skip-db            Skip database restore
  --skip-ssh           Skip SSH key restore
  --skip-env           Skip environment (.env) restore
  --skip-proxy         Skip proxy configuration restore
  --skip-restart       Skip Coolify container restart after restore
  --non-interactive    Run without prompts (restore everything)
  -h, --help           Show this help message

${BOLD}Examples:${NC}
  $(basename "$0") --file coolify-backup-full-20260308-143000.tar.gz
  $(basename "$0") --file backup.tar.gz --skip-volumes
  $(basename "$0") --file backup.tar.gz --mode selective
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --file)
                BACKUP_FILE="$2"; shift 2 ;;
            --mode)
                RESTORE_MODE="$2"; shift 2 ;;
            --skip-volumes)
                SKIP_VOLUMES=true; shift ;;
            --skip-db)
                SKIP_DB=true; shift ;;
            --skip-ssh)
                SKIP_SSH=true; shift ;;
            --skip-env)
                SKIP_ENV=true; shift ;;
            --skip-proxy)
                SKIP_PROXY=true; shift ;;
            --skip-restart)
                SKIP_RESTART=true; shift ;;
            --non-interactive)
                NON_INTERACTIVE=true; shift ;;
            -h|--help)
                usage ;;
            *)
                die "Unknown option: $1. Use --help for usage." ;;
        esac
    done

    if [[ -z "$BACKUP_FILE" ]]; then
        die "No backup file specified. Use --file PATH"
    fi

    if [[ ! -f "$BACKUP_FILE" ]]; then
        die "Backup file not found: $BACKUP_FILE"
    fi
}

# ============================================================
# Extract Backup
# ============================================================
extract_backup() {
    local archive="$1"

    log_step "Extracting backup archive"

    TEMP_DIR=$(create_temp_dir "coolify-restore")
    log_substep "Temp directory: $TEMP_DIR"

    local tar_err
    tar_err=$(mktemp)
    if tar xzf "$archive" -C "$TEMP_DIR" 2>"$tar_err"; then
        log_success "Archive extracted"
    else
        local err_msg
        err_msg=$(cat "$tar_err" 2>/dev/null)
        rm -f "$tar_err"
        die "Failed to extract backup archive${err_msg:+: $err_msg}"
    fi
    rm -f "$tar_err"

    # Find the backup root (could be nested in a directory)
    local manifest
    manifest=$(find "$TEMP_DIR" -maxdepth 2 -name "manifest.json" 2>/dev/null | head -1 || true)

    if [[ -z "$manifest" ]]; then
        die "No manifest.json found in archive. Is this a valid CoolifyBR backup?"
    fi

    BACKUP_ROOT=$(dirname "$manifest")
    log_info "Backup root: $BACKUP_ROOT"

    echo "$BACKUP_ROOT"
}

# ============================================================
# Read & Display Manifest
# ============================================================
read_manifest() {
    local manifest_file="$1"

    if [[ ! -f "$manifest_file" ]]; then
        die "Manifest file not found"
    fi

    log_step "Reading backup manifest"

    local tool version mode coolify_ver timestamp hostname
    tool=$(jq -r '.tool // "unknown"' "$manifest_file")
    version=$(jq -r '.version // "unknown"' "$manifest_file")
    mode=$(jq -r '.backup_mode // "unknown"' "$manifest_file")
    coolify_ver=$(jq -r '.coolify_version // "unknown"' "$manifest_file")
    timestamp=$(jq -r '.timestamp // "unknown"' "$manifest_file")
    hostname=$(jq -r '.hostname // "unknown"' "$manifest_file")

    echo "" >&2
    echo -e "  ${BOLD}Tool:${NC}            $tool v$version" >&2
    echo -e "  ${BOLD}Backup Mode:${NC}     $mode" >&2
    echo -e "  ${BOLD}Coolify Version:${NC} $coolify_ver" >&2
    echo -e "  ${BOLD}Created:${NC}         $timestamp" >&2
    echo -e "  ${BOLD}Source Host:${NC}     $hostname" >&2
    echo "" >&2

    # Show components
    local components
    components=$(jq -r '.components | keys[]' "$manifest_file" 2>/dev/null || echo "")
    if [[ -n "$components" ]]; then
        echo -e "  ${BOLD}Components:${NC}" >&2
        while IFS= read -r comp; do
            local comp_info
            comp_info=$(jq -r ".components.${comp}" "$manifest_file" 2>/dev/null)
            echo -e "    ${GREEN}+${NC} $comp: $comp_info" >&2
        done <<< "$components"
        echo "" >&2
    fi

    # Return backup mode
    echo "$mode"
}

# ============================================================
# Stop Coolify Containers
# ============================================================
stop_coolify() {
    log_step "Stopping Coolify containers"

    local containers_to_stop=("coolify" "coolify-redis" "coolify-realtime")

    for container in "${containers_to_stop[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            docker stop "$container" &>/dev/null && log_substep "Stopped: $container"
        fi
    done

    # Keep coolify-db running for restore
    if docker ps --format '{{.Names}}' | grep -q "^coolify-db$"; then
        log_info "Keeping coolify-db running for restore"
    else
        log_warn "coolify-db is not running - attempting to start it"
        docker start coolify-db &>/dev/null || true
        sleep 3
    fi
}

# ============================================================
# Restart Coolify
# ============================================================
restart_coolify() {
    if [[ "$SKIP_RESTART" == true ]]; then
        log_info "Skipping Coolify restart (--skip-restart)"
        return 0
    fi

    log_step "Restarting Coolify"

    # Flush Redis cache so Coolify picks up database changes
    log_substep "Flushing Redis cache..."
    docker exec coolify-redis redis-cli FLUSHALL &>/dev/null || true

    # Force-restart Coolify containers (not just 'up -d' which skips running ones)
    if [[ -f "/data/coolify/source/docker-compose.yml" ]]; then
        log_substep "Restarting via docker compose..."
        (cd /data/coolify/source && docker compose restart) &>/dev/null || true
    else
        # Fallback: restart individual containers
        for container in "${COOLIFY_CONTAINERS[@]}"; do
            docker restart "$container" &>/dev/null || true
        done
        # Also restart proxy
        docker restart coolify-proxy &>/dev/null || true
    fi

    log_substep "Waiting for containers to start..."
    sleep 10

    # Verify
    local running=0
    for container in "${COOLIFY_CONTAINERS[@]}"; do
        if docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            running=$((running + 1))
        fi
    done

    log_success "Coolify restarted ($running/${#COOLIFY_CONTAINERS[@]} containers running)"

    echo ""
    echo -e "  ${BOLD}Container Status:${NC}"
    docker ps --filter "name=coolify" --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>/dev/null
    echo ""
}

# ============================================================
# Full Restore
# ============================================================
restore_full() {
    local backup_root="$1"

    log_header "FULL COOLIFY RESTORE"

    if [[ "$NON_INTERACTIVE" != true ]]; then
        echo -e "  ${RED}${BOLD}WARNING:${NC} Full restore will:"
        echo -e "    - Replace the Coolify database with the backup"
        echo -e "    - Restore all Docker volumes (overwriting existing)"
        echo -e "    - Replace SSH keys"
        echo -e "    - Update APP_KEY configuration"
        echo ""
        if ! prompt_yes_no "Continue with full restore?" "n"; then
            log_info "Restore cancelled"
            exit 0
        fi
    fi

    # Stop Coolify (except DB)
    stop_coolify

    # 1. Database restore
    if [[ "$SKIP_DB" != true ]]; then
        local dump_file
        dump_file=$(find "$backup_root/database" -name "coolify-db.dump" 2>/dev/null | head -1)
        if [[ -n "$dump_file" ]]; then
            db_restore_full "$dump_file"
        else
            log_warn "No database dump found in backup"
        fi
    fi

    # 2. Docker volumes
    if [[ "$SKIP_VOLUMES" != true ]]; then
        if [[ -d "$backup_root/volumes" ]]; then
            volume_restore_all "$backup_root/volumes"
            bindmount_restore_all "$backup_root/volumes"
        else
            log_info "No volume backups found"
        fi
    fi

    # 3. SSH keys
    if [[ "$SKIP_SSH" != true ]]; then
        if [[ -d "$backup_root/ssh" ]]; then
            ssh_restore_keys "$backup_root/ssh"
        else
            log_info "No SSH key backup found"
        fi
    fi

    # 4. Environment
    if [[ "$SKIP_ENV" != true ]]; then
        if [[ -d "$backup_root/env" ]]; then
            env_restore "$backup_root/env"
        else
            log_info "No environment backup found"
        fi
    fi

    # 5. Proxy config
    if [[ "$SKIP_PROXY" != true ]]; then
        if [[ -d "$backup_root/proxy" ]]; then
            proxy_restore "$backup_root/proxy"
        fi
    fi

    # Restart
    restart_coolify
}

# ============================================================
# Project Restore
# ============================================================
restore_project() {
    local backup_root="$1"

    log_header "PROJECT RESTORE"

    # Find project data files
    local project_files
    project_files=$(find "$backup_root/database" -name "project-*-data.json" 2>/dev/null)

    if [[ -z "$project_files" ]]; then
        log_warn "No project data files found. Attempting full database restore instead."
        restore_full "$backup_root"
        return
    fi

    # List available projects from backup
    print_menu_header "Projects in Backup"

    local project_list=()
    local i=1
    while IFS= read -r pfile; do
        local pname
        pname=$(jq -r '.project.name // "Unknown"' "$pfile")
        local puuid
        puuid=$(jq -r '.project.uuid // "N/A"' "$pfile")
        local app_count
        app_count=$(jq '.applications | length // 0' "$pfile")

        print_menu_item "$i" "$pname" "UUID: $puuid, Apps: $app_count"
        project_list+=("$pfile")
        ((i++))
    done <<< "$project_files"

    echo "" >&2
    local max=$((i - 1))

    if [[ "$NON_INTERACTIVE" == true ]]; then
        # Restore all projects
        for pfile in "${project_list[@]}"; do
            db_restore_project_data "$pfile"
        done
    else
        local selections
        selections=$(prompt_multi_selection "Select project(s) to restore" "$max")

        IFS=',' read -ra selected_indices <<< "$selections"
        for idx in "${selected_indices[@]}"; do
            idx=$(echo "$idx" | tr -d ' ')
            [[ "$idx" =~ ^[0-9]+$ ]] || continue
            if [[ $idx -ge 1 && $idx -le $max ]]; then
                db_restore_project_data "${project_list[$((idx - 1))]}"
            fi
        done
    fi

    # Restore volumes
    if [[ "$SKIP_VOLUMES" != true && -d "$backup_root/volumes" ]]; then
        volume_restore_all "$backup_root/volumes"
    fi

    # SSH keys and env
    if [[ "$SKIP_SSH" != true && -d "$backup_root/ssh" ]]; then
        ssh_restore_keys "$backup_root/ssh"
    fi
    if [[ "$SKIP_ENV" != true && -d "$backup_root/env" ]]; then
        env_restore "$backup_root/env"
    fi

    # Restart
    restart_coolify
}

# ============================================================
# Selective Restore
# ============================================================
restore_selective() {
    local backup_root="$1"

    log_header "SELECTIVE RESTORE"

    # Stop Coolify
    stop_coolify

    # Database
    if [[ "$SKIP_DB" != true ]]; then
        local dump_file
        dump_file=$(find "$backup_root/database" -name "coolify-db.dump" 2>/dev/null | head -1)
        local project_files
        project_files=$(find "$backup_root/database" -name "project-*-data.json" 2>/dev/null)

        if [[ -n "$dump_file" || -n "$project_files" ]]; then
            if prompt_yes_no "Restore database?"; then
                if [[ -n "$dump_file" ]] && prompt_yes_no "  Full database restore (recommended)?"; then
                    db_restore_full "$dump_file"
                elif [[ -n "$project_files" ]]; then
                    log_info "Restoring individual project data..."
                    while IFS= read -r pfile; do
                        local pname
                        pname=$(jq -r '.project.name // "Unknown"' "$pfile")
                        if prompt_yes_no "  Restore project '$pname'?"; then
                            db_restore_project_data "$pfile"
                        fi
                    done <<< "$project_files"
                fi
            fi
        fi
    fi

    # Volumes
    if [[ "$SKIP_VOLUMES" != true && -d "$backup_root/volumes" ]]; then
        local vol_backups
        vol_backups=$(find "$backup_root/volumes" -name "*-backup.tar.gz" 2>/dev/null)
        if [[ -n "$vol_backups" ]]; then
            if prompt_yes_no "Restore Docker volumes?"; then
                while IFS= read -r vfile; do
                    local vname
                    vname=$(basename "$vfile" | sed 's/-backup\.tar\.gz$//')
                    if prompt_yes_no "  Restore volume '$vname'?"; then
                        volume_restore "$vfile"
                    fi
                done <<< "$vol_backups"
            fi
        fi
    fi

    # SSH
    if [[ "$SKIP_SSH" != true && -d "$backup_root/ssh" ]]; then
        if prompt_yes_no "Restore SSH keys?"; then
            ssh_restore_keys "$backup_root/ssh"
        fi
    fi

    # Environment
    if [[ "$SKIP_ENV" != true && -d "$backup_root/env" ]]; then
        if prompt_yes_no "Restore environment (.env + APP_KEY)?"; then
            env_restore "$backup_root/env"
        fi
    fi

    # Proxy
    if [[ "$SKIP_PROXY" != true && -d "$backup_root/proxy" ]]; then
        if prompt_yes_no "Restore proxy configuration?"; then
            proxy_restore "$backup_root/proxy"
        fi
    fi

    # Restart
    if prompt_yes_no "Restart Coolify now?"; then
        restart_coolify
    else
        log_info "Remember to restart Coolify manually when ready"
    fi
}

# ============================================================
# Main
# ============================================================
main() {
    parse_args "$@"

    log_header "CoolifyBR - Coolify Restore Tool v1.0"

    # Validations
    check_root
    check_docker
    check_coolify_installed
    check_dependencies

    # Extract backup
    local backup_root
    backup_root=$(extract_backup "$BACKUP_FILE")

    # Read manifest
    local manifest_file="${backup_root}/manifest.json"
    local backup_mode
    backup_mode=$(read_manifest "$manifest_file" | tail -1)

    # Determine restore mode
    if [[ -z "$RESTORE_MODE" ]]; then
        RESTORE_MODE="$backup_mode"
    fi

    # Verify DB connection
    db_verify_connection || die "Cannot connect to Coolify database. Is coolify-db running?"

    # Execute restore based on mode
    case "$RESTORE_MODE" in
        full)
            restore_full "$backup_root"
            ;;
        project)
            restore_project "$backup_root"
            ;;
        selective)
            restore_selective "$backup_root"
            ;;
        *)
            log_warn "Unknown backup mode: $RESTORE_MODE, defaulting to selective"
            restore_selective "$backup_root"
            ;;
    esac

    # Cleanup
    if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" ]]; then
        rm -rf "$TEMP_DIR"
    fi

    # Final summary
    log_header "RESTORE COMPLETE"
    echo -e "  ${BOLD}Backup File:${NC}  $BACKUP_FILE"
    echo -e "  ${BOLD}Mode:${NC}         $RESTORE_MODE"
    echo -e "  ${BOLD}Time:${NC}         $(date)"
    echo ""
    echo -e "  ${DIM}Next steps:${NC}"
    echo -e "    1. Verify your Coolify dashboard is accessible"
    echo -e "    2. Check that projects and deployments are visible"
    echo -e "    3. Test SSH connections to managed servers"
    echo -e "    4. Re-deploy applications if needed"
    echo ""
}

main "$@"
