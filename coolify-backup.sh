#!/bin/bash
# ============================================================
# CoolifyBR - Coolify Backup Tool
# Full / Project / Selective backup for Coolify instances
# https://github.com/coolify-br
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
MODE=""
OUTPUT_DIR=""
PROJECT_UUID=""
TRANSFER_HOST=""
TRANSFER_USER="root"
TRANSFER_KEY=""
TRANSFER_PORT="22"
NON_INTERACTIVE=false
SKIP_VOLUMES=false
SKIP_DB=false

usage() {
    cat <<EOF
${BOLD}CoolifyBR - Coolify Backup Tool${NC}

${BOLD}Usage:${NC}
  $(basename "$0") [OPTIONS]

${BOLD}Modes:${NC}
  --mode full          Full Coolify instance backup (DB + volumes + SSH + proxy)
  --mode project       Backup specific project(s)
  --mode selective     Interactive selection of resources

${BOLD}Options:${NC}
  --output DIR         Output directory (default: ./backups)
  --project-uuid UUID  Project UUID for project mode (skip interactive selection)
  --transfer HOST      Transfer backup to remote host after creation
  --transfer-user USER Remote SSH user (default: root)
  --transfer-key PATH  SSH key for remote transfer
  --transfer-port PORT SSH port for remote transfer (default: 22)
  --skip-volumes       Skip Docker volume backups
  --skip-db            Skip database backup
  --non-interactive    Run without prompts (use defaults)
  -h, --help           Show this help message

${BOLD}Examples:${NC}
  $(basename "$0") --mode full
  $(basename "$0") --mode project --project-uuid abc123
  $(basename "$0") --mode full --transfer 192.168.1.100
  $(basename "$0") --mode selective
EOF
    exit 0
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                MODE="$2"; shift 2 ;;
            --output)
                OUTPUT_DIR="$2"; shift 2 ;;
            --project-uuid)
                PROJECT_UUID="$2"; shift 2 ;;
            --transfer)
                TRANSFER_HOST="$2"; shift 2 ;;
            --transfer-user)
                TRANSFER_USER="$2"; shift 2 ;;
            --transfer-key)
                TRANSFER_KEY="$2"; shift 2 ;;
            --transfer-port)
                TRANSFER_PORT="$2"; shift 2 ;;
            --skip-volumes)
                SKIP_VOLUMES=true; shift ;;
            --skip-db)
                SKIP_DB=true; shift ;;
            --non-interactive)
                NON_INTERACTIVE=true; shift ;;
            -h|--help)
                usage ;;
            *)
                die "Unknown option: $1. Use --help for usage." ;;
        esac
    done
}

# ============================================================
# Mode Selection (Interactive)
# ============================================================
select_mode() {
    if [[ -n "$MODE" ]]; then
        return
    fi

    print_menu_header "CoolifyBR - Backup Mode"
    print_menu_item "1" "Full Backup" "Complete Coolify instance (DB + volumes + SSH + proxy)"
    print_menu_item "2" "Project Backup" "Backup specific project(s) with their resources"
    print_menu_item "3" "Selective Backup" "Choose individual applications, databases, services"
    echo ""

    local choice
    choice=$(prompt_selection "Select backup mode" 3)

    case "$choice" in
        1) MODE="full" ;;
        2) MODE="project" ;;
        3) MODE="selective" ;;
    esac
}

# ============================================================
# Project Selection (Interactive)
# ============================================================
select_projects() {
    if [[ -n "$PROJECT_UUID" ]]; then
        return
    fi

    log_step "Discovering projects..."

    # Try API first, fall back to database
    local projects=""
    local api_available=false

    if api_init 2>/dev/null; then
        projects=$(discover_projects 2>/dev/null || true)
        if [[ -n "$projects" ]]; then
            api_available=true
        fi
    fi

    if [[ -z "$projects" ]]; then
        log_info "Using database discovery (API not available)"
        projects=$(db_discover_projects 2>/dev/null || true)
    fi

    if [[ -z "$projects" ]]; then
        die "No projects found. Is Coolify running?"
    fi

    # Display project list
    print_menu_header "Available Projects"

    local project_list=()
    local i=1
    while IFS=$'\t' read -r id uuid name desc env_count; do
        if [[ "$api_available" == true ]]; then
            # API format: uuid, name, description
            print_menu_item "$i" "$uuid" "$name"
            project_list+=("$uuid|$uuid|$name")
        else
            # DB format: id, uuid, name, description, env_count
            local display_info=""
            if [[ -n "$desc" ]]; then
                local display_desc="$desc"
                [[ ${#display_desc} -gt 40 ]] && display_desc="${display_desc:0:40}..."
                display_info="$display_desc (${env_count:-0} env(s))"
            else
                display_info="${env_count:-0} env(s)"
            fi
            print_menu_item "$i" "$name" "$display_info"
            project_list+=("$id|$uuid|$name")
        fi
        ((i++))
    done <<< "$projects"

    echo "" >&2
    local max=$((i - 1))

    if [[ "$MODE" == "project" ]]; then
        local selections
        selections=$(prompt_multi_selection "Select project(s) to backup" "$max")

        PROJECT_UUID=""
        IFS=',' read -ra selected_indices <<< "$selections"
        for idx in "${selected_indices[@]}"; do
            idx=$(echo "$idx" | tr -d ' ')
            [[ "$idx" =~ ^[0-9]+$ ]] || continue
            if [[ $idx -ge 1 && $idx -le $max ]]; then
                local entry="${project_list[$((idx - 1))]}"
                local proj_id proj_uuid proj_name
                IFS='|' read -r proj_id proj_uuid proj_name <<< "$entry"
                if [[ -n "$PROJECT_UUID" ]]; then
                    PROJECT_UUID+=",${proj_id}:${proj_uuid}:${proj_name}"
                else
                    PROJECT_UUID="${proj_id}:${proj_uuid}:${proj_name}"
                fi
            fi
        done
    fi
}

# ============================================================
# Selective Resource Selection
# ============================================================
select_resources() {
    local temp_dir="$1"

    log_step "Discovering all resources..."

    # Discover containers
    local containers
    containers=$(discover_containers_docker 2>/dev/null || true)

    if [[ -z "$containers" ]]; then
        log_warn "No application containers found"
        return
    fi

    print_menu_header "Running Application Containers"

    local container_list=()
    local i=1
    while IFS=$'\t' read -r name id image; do
        print_menu_item "$i" "$name" "$image"
        container_list+=("$name")
        ((i++))
    done <<< "$containers"

    echo "" >&2
    local max=$((i - 1))
    local selections
    selections=$(prompt_multi_selection "Select containers to backup volumes for" "$max")

    SELECTED_CONTAINERS=()
    IFS=',' read -ra selected_indices <<< "$selections"
    for idx in "${selected_indices[@]}"; do
        idx=$(echo "$idx" | tr -d ' ')
        [[ "$idx" =~ ^[0-9]+$ ]] || continue
        if [[ $idx -ge 1 && $idx -le $max ]]; then
            SELECTED_CONTAINERS+=("${container_list[$((idx - 1))]}")
        fi
    done

    log_info "Selected ${#SELECTED_CONTAINERS[@]} container(s)"
}

# ============================================================
# Full Backup
# ============================================================
backup_full() {
    local backup_name
    backup_name=$(generate_backup_name "full")
    local backup_dir="${OUTPUT_DIR}/${backup_name}"

    mkdir -p "$backup_dir"/{database,volumes,ssh,env,proxy}

    log_header "FULL COOLIFY BACKUP"
    log_info "Backup directory: $backup_dir"

    # Create manifest
    create_manifest "$backup_dir/manifest.json" "full"

    # 1. Database backup
    if [[ "$SKIP_DB" != true ]]; then
        local db_size
        db_size=$(db_get_size 2>/dev/null || echo "unknown")
        log_info "Database size: $db_size"

        db_backup_full "$backup_dir/database"
        update_manifest "$backup_dir/manifest.json" "database" '{"type":"full","format":"custom"}'
    fi

    # 2. Docker volumes
    if [[ "$SKIP_VOLUMES" != true ]]; then
        volume_backup_all "$backup_dir/volumes"

        local vol_count
        vol_count=$(find "$backup_dir/volumes" -name "*.tar.gz" 2>/dev/null | wc -l | tr -d ' ')
        update_manifest "$backup_dir/manifest.json" "volumes" "{\"count\":$vol_count}"
    fi

    # 3. SSH keys
    ssh_backup_keys "$backup_dir/ssh"
    update_manifest "$backup_dir/manifest.json" "ssh_keys" '{"backed_up":true}'

    # 4. Environment (.env + APP_KEY)
    env_backup "$backup_dir/env"
    update_manifest "$backup_dir/manifest.json" "environment" '{"backed_up":true}'

    # 5. Proxy config
    proxy_backup "$backup_dir/proxy"
    update_manifest "$backup_dir/manifest.json" "proxy" '{"backed_up":true}'

    # Package everything
    package_backup "$backup_dir" "$backup_name"
}

# ============================================================
# Project Backup
# ============================================================
backup_project() {
    select_projects

    if [[ -z "$PROJECT_UUID" ]]; then
        die "No projects selected"
    fi

    local backup_name
    backup_name=$(generate_backup_name "project")
    local backup_dir="${OUTPUT_DIR}/${backup_name}"

    mkdir -p "$backup_dir"/{database,volumes,ssh,env}

    log_header "PROJECT BACKUP"

    # Create manifest
    create_manifest "$backup_dir/manifest.json" "project"

    local project_entries=()
    IFS=',' read -ra project_entries <<< "$PROJECT_UUID"

    local project_names=()

    for entry in "${project_entries[@]}"; do
        IFS=':' read -r proj_id proj_uuid proj_name <<< "$entry"
        log_step "Backing up project: $proj_name (ID: $proj_id, UUID: $proj_uuid)"
        project_names+=("$proj_name")

        # Export project data from database
        db_export_project_data "$proj_id" "$backup_dir/database"

        # Backup volumes for project
        if [[ "$SKIP_VOLUMES" != true ]]; then
            volume_backup_for_project "$proj_id" "$backup_dir/volumes"
        fi
    done

    # Always include SSH keys and env for project restore
    ssh_backup_keys "$backup_dir/ssh"
    env_backup "$backup_dir/env"

    # Update manifest with project info
    local projects_json
    projects_json=$(printf '%s\n' "${project_names[@]}" | jq -R . | jq -s .)
    update_manifest "$backup_dir/manifest.json" "projects" "$projects_json"

    # Package
    package_backup "$backup_dir" "$backup_name"
}

# ============================================================
# Selective Backup
# ============================================================
backup_selective() {
    local backup_name
    backup_name=$(generate_backup_name "selective")
    local backup_dir="${OUTPUT_DIR}/${backup_name}"

    mkdir -p "$backup_dir"/{database,volumes,ssh,env}

    log_header "SELECTIVE BACKUP"

    # Create manifest
    create_manifest "$backup_dir/manifest.json" "selective"

    # Ask what to include
    print_menu_header "What to Include"
    echo ""

    local include_db=false
    local include_volumes=false
    local include_ssh=false
    local include_env=false

    if prompt_yes_no "Include Coolify database (full dump)?"; then
        include_db=true
    fi

    if prompt_yes_no "Include Docker volumes?"; then
        include_volumes=true
    fi

    if prompt_yes_no "Include SSH keys?"; then
        include_ssh=true
    fi

    if prompt_yes_no "Include environment (.env + APP_KEY)?"; then
        include_env=true
    fi

    # Database
    if [[ "$include_db" == true ]]; then
        db_backup_full "$backup_dir/database"
    fi

    # Volumes (selective by container)
    if [[ "$include_volumes" == true ]]; then
        SELECTED_CONTAINERS=()
        select_resources "$backup_dir"

        for container in "${SELECTED_CONTAINERS[@]}"; do
            volume_backup_for_container "$container" "$backup_dir/volumes"
        done
    fi

    # SSH
    if [[ "$include_ssh" == true ]]; then
        ssh_backup_keys "$backup_dir/ssh"
    fi

    # Environment
    if [[ "$include_env" == true ]]; then
        env_backup "$backup_dir/env"
    fi

    # Package
    package_backup "$backup_dir" "$backup_name"
}

# ============================================================
# Package & Compress
# ============================================================
package_backup() {
    local backup_dir="$1"
    local backup_name="$2"
    local archive_file="${OUTPUT_DIR}/${backup_name}.tar.gz"

    log_step "Packaging backup archive"

    # Update manifest with final info
    if [[ -f "$backup_dir/manifest.json" ]]; then
        local tmp
        tmp=$(mktemp)
        jq ".completed_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$backup_dir/manifest.json" > "$tmp" && mv "$tmp" "$backup_dir/manifest.json"
    fi

    # Get uncompressed size for progress display
    local raw_size
    raw_size=$(du -sb "$backup_dir" 2>/dev/null | cut -f1 || echo "0")

    # Create tar.gz in background with spinner
    tar czf "$archive_file" -C "$OUTPUT_DIR" "$backup_name" 2>/dev/null &
    local tar_pid=$!

    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local si=0
    while kill -0 "$tar_pid" 2>/dev/null; do
        printf "\r  ${CYAN}${spin:$si:1}${NC} Compressing archive (%s)..." "$(format_size "${raw_size:-0}")"
        si=$(( (si + 1) % ${#spin} ))
        sleep 0.1
    done
    printf "\r%-80s\r" ""

    wait "$tar_pid"

    # Get archive size
    local archive_size
    archive_size=$(stat -c%s "$archive_file" 2>/dev/null || stat -f%z "$archive_file" 2>/dev/null || echo "0")

    # Cleanup uncompressed directory
    rm -rf "$backup_dir"

    log_success "Backup archive created: $archive_file"
    log_info "Archive size: $(format_size "$archive_size")"

    # Transfer if requested
    if [[ -n "$TRANSFER_HOST" ]]; then
        transfer_auto "$archive_file" "$TRANSFER_HOST" "/tmp/" "$TRANSFER_USER" "$TRANSFER_KEY" "$TRANSFER_PORT"

        if prompt_yes_no "Execute restore on remote server?"; then
            local remote_archive="/tmp/$(basename "$archive_file")"
            transfer_remote_restore "$TRANSFER_HOST" "$remote_archive" "$TRANSFER_USER" "$TRANSFER_KEY" "$TRANSFER_PORT"
        fi
    fi

    # Final summary
    echo ""
    log_header "BACKUP COMPLETE"
    echo -e "  ${BOLD}Archive:${NC}  $archive_file"
    echo -e "  ${BOLD}Size:${NC}     $(format_size "$archive_size")"
    echo -e "  ${BOLD}Mode:${NC}     $MODE"
    echo -e "  ${BOLD}Time:${NC}     $(date)"
    echo ""
    echo -e "  ${DIM}To restore on another server:${NC}"
    echo -e "  ${CYAN}  scp $archive_file root@NEW_SERVER:/tmp/${NC}"
    echo -e "  ${CYAN}  ssh root@NEW_SERVER${NC}"
    echo -e "  ${CYAN}  ./coolify-restore.sh --file /tmp/$(basename "$archive_file")${NC}"
    echo ""
}

# ============================================================
# Main
# ============================================================
main() {
    parse_args "$@"

    log_header "CoolifyBR - Coolify Backup Tool v1.0"

    # Load config if exists
    if [[ -f "$SCRIPT_DIR/config.env" ]]; then
        source "$SCRIPT_DIR/config.env"
    fi

    # Validations
    check_root
    check_docker
    check_coolify_installed
    check_dependencies
    db_verify_connection

    # Set default output directory
    OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/backups}"
    mkdir -p "$OUTPUT_DIR"

    # Select mode
    select_mode

    case "$MODE" in
        full)
            backup_full
            ;;
        project)
            backup_project
            ;;
        selective)
            backup_selective
            ;;
        *)
            die "Invalid mode: $MODE"
            ;;
    esac
}

main "$@"
