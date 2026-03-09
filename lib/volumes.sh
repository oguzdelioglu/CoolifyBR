#!/bin/bash
# CoolifyBR - Docker Volume Backup/Restore
# Handles Docker volume and bind mount operations

# ============================================================
# Volume Discovery
# ============================================================

# List all volumes for a given container
volume_list_for_container() {
    local container_name="$1"
    docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}|{{.Destination}}{{printf "\n"}}{{end}}{{end}}' \
        "$container_name" 2>/dev/null | grep -v '^$' || true
}

# List all bind mounts for a given container
binds_list_for_container() {
    local container_name="$1"
    docker inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}|{{.Destination}}{{printf "\n"}}{{end}}{{end}}' \
        "$container_name" 2>/dev/null | grep -v '^$' || true
}

# Get volume size
volume_get_size() {
    local volume_name="$1"
    local vol_path
    vol_path=$(docker volume inspect --format '{{.Mountpoint}}' "$volume_name" 2>/dev/null)
    if [[ -n "$vol_path" && -d "$vol_path" ]]; then
        du -sb "$vol_path" 2>/dev/null | cut -f1
    else
        echo "0"
    fi
}

# Check if volume exists
volume_exists() {
    docker volume inspect "$1" &>/dev/null
}

# ============================================================
# Volume Backup
# ============================================================

# Backup a single Docker volume to a tar.gz file
volume_backup() {
    local volume_name="$1"
    local output_dir="$2"
    local backup_file="${output_dir}/${volume_name}-backup.tar.gz"

    if ! volume_exists "$volume_name"; then
        log_warn "Volume '$volume_name' does not exist, skipping"
        return 1
    fi

    log_substep "Backing up volume: $volume_name"

    local vol_path
    vol_path=$(docker volume inspect --format '{{.Mountpoint}}' "$volume_name" 2>/dev/null)

    if [[ -z "$vol_path" || ! -d "$vol_path" ]]; then
        log_error "  Cannot find mount point for volume '$volume_name'"
        return 1
    fi

    local tar_err
    if tar_err=$(tar czf "$backup_file" -C "$vol_path" . 2>&1); then
        local size
        size=$(stat -c%s "$backup_file" 2>/dev/null || stat -f%z "$backup_file" 2>/dev/null || echo "0")
        log_success "  Volume '$volume_name' backed up ($(format_size "$size"))"
        return 0
    else
        log_error "  Failed to backup volume '$volume_name'"
        [[ -n "$tar_err" ]] && log_error "  tar: $tar_err"
        rm -f "$backup_file"
        return 1
    fi
}

# Backup multiple volumes
volume_backup_multiple() {
    local output_dir="$1"
    shift
    local volume_names=("$@")

    local backed_up=0
    local failed=0

    mkdir -p "$output_dir"

    for vol in "${volume_names[@]}"; do
        if volume_backup "$vol" "$output_dir"; then
            backed_up=$((backed_up + 1))
        else
            failed=$((failed + 1))
        fi
    done

    log_info "Volumes backed up: $backed_up, Failed: $failed"
}

# Backup all volumes for a specific container
volume_backup_for_container() {
    local container_name="$1"
    local output_dir="$2"

    local volumes
    volumes=$(volume_list_for_container "$container_name")

    if [[ -z "$volumes" ]]; then
        log_info "No volumes found for container '$container_name'"
        return 0
    fi

    local volume_names=()
    while IFS='|' read -r name dest; do
        volume_names+=("$name")
    done <<< "$volumes"

    volume_backup_multiple "$output_dir" "${volume_names[@]}"
}

# Backup all Coolify-managed volumes
volume_backup_all() {
    local output_dir="$1"

    log_step "Backing up all Docker volumes"

    mkdir -p "$output_dir"

    # Get all running containers (excluding Coolify system containers)
    local containers
    containers=$(docker ps --format '{{.Names}}' | \
        grep -v "^coolify$" | \
        grep -v "^coolify-db$" | \
        grep -v "^coolify-redis$" | \
        grep -v "^coolify-realtime$" | \
        grep -v "^coolify-proxy$" || true)

    if [[ -z "$containers" ]]; then
        log_info "No application containers found"
        return 0
    fi

    # Collect all unique volumes
    local all_volumes=()
    local seen_volumes=()

    while IFS= read -r container; do
        local vols
        vols=$(volume_list_for_container "$container")
        while IFS='|' read -r name dest; do
            if [[ -n "$name" ]] && [[ ! " ${seen_volumes[*]+${seen_volumes[*]}} " =~ " $name " ]]; then
                all_volumes+=("$name")
                seen_volumes+=("$name")
            fi
        done <<< "$vols"
    done <<< "$containers"

    if [[ ${#all_volumes[@]} -eq 0 ]]; then
        log_info "No volumes found to backup"
        return 0
    fi

    log_info "Found ${#all_volumes[@]} unique volumes to backup"
    volume_backup_multiple "$output_dir" "${all_volumes[@]}"
}

# Backup volumes for specific project containers
volume_backup_for_project() {
    local project_id="$1"
    local output_dir="$2"

    log_step "Backing up volumes for project (ID: $project_id)"
    mkdir -p "$output_dir"

    # Get application container names from the database
    local app_containers
    app_containers=$(docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A \
        -c "SELECT a.uuid FROM applications a
            JOIN environments e ON a.environment_id = e.id
            WHERE e.project_id = $project_id;" 2>/dev/null)

    # Get service container names
    local svc_containers
    svc_containers=$(docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A \
        -c "SELECT s.uuid FROM services s
            JOIN environments e ON s.environment_id = e.id
            WHERE e.project_id = $project_id;" 2>/dev/null)

    # Get database container names (all types)
    local db_tables=("standalone_postgresqls" "standalone_mysqls" "standalone_mariadbs" "standalone_mongodbs" "standalone_redis" "standalone_clickhouses" "standalone_dragonflies" "standalone_keydbs")
    local db_containers=""

    for table in "${db_tables[@]}"; do
        local uuids
        uuids=$(docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A \
            -c "SELECT d.uuid FROM $table d
                JOIN environments e ON d.environment_id = e.id
                WHERE e.project_id = $project_id;" 2>/dev/null || true)
        if [[ -n "$uuids" ]]; then
            db_containers+="$uuids"$'\n'
        fi
    done

    # Combine all UUIDs
    local all_uuids=""
    [[ -n "$app_containers" ]] && all_uuids+="$app_containers"$'\n'
    [[ -n "$svc_containers" ]] && all_uuids+="$svc_containers"$'\n'
    [[ -n "$db_containers" ]] && all_uuids+="$db_containers"

    all_uuids=$(echo "$all_uuids" | grep -v '^$' | sort -u || true)

    if [[ -z "$all_uuids" ]]; then
        log_info "No resource UUIDs found for project"
        return 0
    fi

    # Find running Docker containers matching these UUIDs
    local all_volumes=()
    local seen_volumes=()
    local running_containers
    running_containers=$(docker ps --format '{{.Names}}')

    while IFS= read -r uuid; do
        # Match containers whose name contains the UUID
        local matched
        matched=$(echo "$running_containers" | grep "$uuid" || true)
        if [[ -n "$matched" ]]; then
            while IFS= read -r container; do
                local vols
                vols=$(volume_list_for_container "$container")
                while IFS='|' read -r name dest; do
                    if [[ -n "$name" ]] && [[ ! " ${seen_volumes[*]+${seen_volumes[*]}} " =~ " $name " ]]; then
                        all_volumes+=("$name")
                        seen_volumes+=("$name")
                    fi
                done <<< "$vols"
            done <<< "$matched"
        fi
    done <<< "$all_uuids"

    if [[ ${#all_volumes[@]} -eq 0 ]]; then
        log_info "No volumes found for project containers"
        return 0
    fi

    log_info "Found ${#all_volumes[@]} volumes for project"
    volume_backup_multiple "$output_dir" "${all_volumes[@]}"
}

# ============================================================
# Bind Mount Backup
# ============================================================
bindmount_backup() {
    local source_path="$1"
    local output_dir="$2"
    local safe_name
    safe_name=$(echo "$source_path" | sed 's/\//_/g' | sed 's/^_//')
    local backup_file="${output_dir}/bind-${safe_name}.tar.gz"

    if [[ ! -e "$source_path" ]]; then
        log_warn "Bind mount source '$source_path' does not exist, skipping"
        return 1
    fi

    log_substep "Backing up bind mount: $source_path"

    if tar czf "$backup_file" -C "$(dirname "$source_path")" "$(basename "$source_path")" 2>/dev/null; then
        local size
        size=$(stat -f%z "$backup_file" 2>/dev/null || stat -c%s "$backup_file" 2>/dev/null || echo "0")
        log_success "  Bind mount backed up ($(format_size "$size"))"
        echo "$backup_file"
        return 0
    else
        log_error "  Failed to backup bind mount '$source_path'"
        rm -f "$backup_file"
        return 1
    fi
}

# ============================================================
# Volume Restore
# ============================================================

# Restore a single volume from backup
volume_restore() {
    local backup_file="$1"
    local volume_name="${2:-}"

    # Derive volume name from filename if not provided
    if [[ -z "$volume_name" ]]; then
        volume_name=$(basename "$backup_file" | sed 's/-backup\.tar\.gz$//')
    fi

    log_substep "Restoring volume: $volume_name"

    # Create volume if it doesn't exist
    if ! volume_exists "$volume_name"; then
        docker volume create "$volume_name" &>/dev/null
        log_info "  Created new volume: $volume_name"
    else
        log_warn "  Volume '$volume_name' already exists, will overwrite contents"
    fi

    # Restore from backup
    local vol_path
    vol_path=$(docker volume inspect --format '{{.Mountpoint}}' "$volume_name" 2>/dev/null)

    if [[ -z "$vol_path" || ! -d "$vol_path" ]]; then
        log_error "  Cannot find mount point for volume '$volume_name'"
        return 1
    fi

    # Clear existing contents and extract backup
    rm -rf "${vol_path:?}"/* "${vol_path}"/.??* 2>/dev/null || true
    if tar xzf "$backup_file" -C "$vol_path" 2>/dev/null; then
        log_success "  Volume '$volume_name' restored"
        return 0
    else
        log_error "  Failed to restore volume '$volume_name'"
        return 1
    fi
}

# Restore all volumes from a backup directory
volume_restore_all() {
    local backup_dir="$1"

    log_step "Restoring Docker volumes"

    local backup_files
    backup_files=$(find "$backup_dir" -name "*-backup.tar.gz" -type f 2>/dev/null)

    if [[ -z "$backup_files" ]]; then
        log_info "No volume backups found in $backup_dir"
        return 0
    fi

    local restored=0
    local failed=0

    while IFS= read -r backup_file; do
        if volume_restore "$backup_file"; then
            restored=$((restored + 1))
        else
            failed=$((failed + 1))
        fi
    done <<< "$backup_files"

    log_info "Volumes restored: $restored, Failed: $failed"
}

# ============================================================
# Bind Mount Restore
# ============================================================
bindmount_restore() {
    local backup_file="$1"
    local target_base="${2:-/}"

    local original_path
    original_path=$(basename "$backup_file" | sed 's/^bind-//' | sed 's/\.tar\.gz$//' | sed 's/_/\//g')

    log_substep "Restoring bind mount: /$original_path"

    local target_dir
    target_dir=$(dirname "/${original_path}")
    mkdir -p "$target_dir"

    if tar xzf "$backup_file" -C "$target_dir" 2>/dev/null; then
        log_success "  Bind mount restored to: /${original_path}"
        return 0
    else
        log_error "  Failed to restore bind mount"
        return 1
    fi
}

# Restore all bind mounts from a backup directory
bindmount_restore_all() {
    local backup_dir="$1"

    local bind_backups
    bind_backups=$(find "$backup_dir" -name "bind-*.tar.gz" -type f 2>/dev/null)

    if [[ -z "$bind_backups" ]]; then
        return 0
    fi

    log_step "Restoring bind mounts"
    while IFS= read -r backup_file; do
        bindmount_restore "$backup_file"
    done <<< "$bind_backups"
}
