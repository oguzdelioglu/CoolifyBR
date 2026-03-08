#!/bin/bash
# CoolifyBR - SSH Key Management
# Handles backup and restore of Coolify SSH keys and APP_KEY

# ============================================================
# SSH Key Backup
# ============================================================

ssh_backup_keys() {
    local output_dir="$1"
    local keys_dir="${output_dir}/keys"

    log_step "Backing up SSH keys"
    mkdir -p "$keys_dir"

    # Backup Coolify SSH keys
    if [[ -d "$COOLIFY_SSH_DIR" ]]; then
        local key_count=0
        for key_file in "$COOLIFY_SSH_DIR"/*; do
            if [[ -f "$key_file" ]]; then
                cp -p "$key_file" "$keys_dir/"
                ((key_count++))
            fi
        done
        if [[ $key_count -gt 0 ]]; then
            log_success "Backed up $key_count SSH key(s) from $COOLIFY_SSH_DIR"
        else
            log_warn "No SSH key files found in $COOLIFY_SSH_DIR"
        fi
    else
        log_warn "Coolify SSH keys directory not found: $COOLIFY_SSH_DIR"
    fi

    # Backup authorized_keys
    if [[ -f "$HOME/.ssh/authorized_keys" ]]; then
        cp -p "$HOME/.ssh/authorized_keys" "$keys_dir/authorized_keys.backup"
        log_success "Backed up authorized_keys"
    fi

    echo "$keys_dir"
}

# ============================================================
# APP_KEY Backup
# ============================================================

env_backup() {
    local output_dir="$1"
    local env_dir="${output_dir}"

    log_step "Backing up Coolify environment (.env)"
    mkdir -p "$env_dir"

    if [[ -f "$COOLIFY_ENV" ]]; then
        cp -p "$COOLIFY_ENV" "$env_dir/.env"
        log_success "Environment file backed up"

        # Extract and display APP_KEY (masked)
        local app_key
        app_key=$(grep "^APP_KEY=" "$COOLIFY_ENV" | cut -d'=' -f2-)
        if [[ -n "$app_key" ]]; then
            local masked="${app_key:0:10}...${app_key: -4}"
            log_info "APP_KEY captured: $masked"
        else
            log_warn "APP_KEY not found in .env file"
        fi
    else
        log_warn "Coolify .env file not found at $COOLIFY_ENV"
        return 1
    fi

    echo "$env_dir"
}

# ============================================================
# Proxy Config Backup
# ============================================================

proxy_backup() {
    local output_dir="$1"

    log_step "Backing up proxy configuration"
    mkdir -p "$output_dir"

    local proxy_dirs=(
        "/data/coolify/proxy"
    )

    local backed_up=false
    for dir in "${proxy_dirs[@]}"; do
        if [[ -d "$dir" ]]; then
            tar czf "${output_dir}/proxy-config.tar.gz" -C "$(dirname "$dir")" "$(basename "$dir")" 2>/dev/null
            log_success "Proxy configuration backed up from $dir"
            backed_up=true
            break
        fi
    done

    if [[ "$backed_up" == false ]]; then
        log_warn "No proxy configuration directory found"
    fi
}

# ============================================================
# SSH Key Restore
# ============================================================

ssh_restore_keys() {
    local backup_dir="$1"
    local keys_dir="${backup_dir}"

    # Find keys directory
    if [[ -d "${backup_dir}/keys" ]]; then
        keys_dir="${backup_dir}/keys"
    fi

    log_step "Restoring SSH keys"

    if [[ ! -d "$keys_dir" ]]; then
        log_warn "SSH keys backup directory not found"
        return 1
    fi

    # Ensure target directory exists
    mkdir -p "$COOLIFY_SSH_DIR"

    # Remove existing auto-generated keys
    if [[ -d "$COOLIFY_SSH_DIR" ]]; then
        local existing_count
        existing_count=$(find "$COOLIFY_SSH_DIR" -type f | wc -l)
        if [[ $existing_count -gt 0 ]]; then
            log_warn "Removing $existing_count existing SSH key(s) from $COOLIFY_SSH_DIR"
            rm -f "$COOLIFY_SSH_DIR"/*
        fi
    fi

    # Copy backed-up keys
    local restored=0
    for key_file in "$keys_dir"/ssh_key@*; do
        if [[ -f "$key_file" ]]; then
            cp -p "$key_file" "$COOLIFY_SSH_DIR/"
            chmod 600 "$COOLIFY_SSH_DIR/$(basename "$key_file")"
            ((restored++))
        fi
    done

    if [[ $restored -gt 0 ]]; then
        log_success "Restored $restored SSH key(s)"
    else
        log_warn "No SSH key files found in backup"
    fi

    # Merge authorized_keys
    if [[ -f "${keys_dir}/authorized_keys.backup" ]]; then
        log_substep "Merging authorized_keys..."
        mkdir -p "$HOME/.ssh"
        touch "$HOME/.ssh/authorized_keys"

        # Merge and deduplicate
        cat "$HOME/.ssh/authorized_keys" "${keys_dir}/authorized_keys.backup" | sort | uniq > "$HOME/.ssh/authorized_keys.tmp"
        mv "$HOME/.ssh/authorized_keys.tmp" "$HOME/.ssh/authorized_keys"
        chmod 600 "$HOME/.ssh/authorized_keys"
        log_success "authorized_keys merged"
    fi
}

# ============================================================
# APP_KEY / Environment Restore
# ============================================================

env_restore() {
    local backup_dir="$1"
    local env_file="${backup_dir}/.env"

    log_step "Restoring Coolify environment"

    if [[ ! -f "$env_file" ]]; then
        # Try alternate location
        env_file="${backup_dir}/env/.env"
    fi

    if [[ ! -f "$env_file" ]]; then
        log_warn "No .env backup found"
        return 1
    fi

    # Extract old APP_KEY from backup
    local old_app_key
    old_app_key=$(grep "^APP_KEY=" "$env_file" | cut -d'=' -f2-)

    if [[ -z "$old_app_key" ]]; then
        log_warn "No APP_KEY found in backup .env"
        return 1
    fi

    local masked="${old_app_key:0:10}...${old_app_key: -4}"
    log_info "Old APP_KEY from backup: $masked"

    # Update the current .env file
    if [[ -f "$COOLIFY_ENV" ]]; then
        # Get current APP_PREVIOUS_KEYS if exists
        local current_previous
        current_previous=$(grep "^APP_PREVIOUS_KEYS=" "$COOLIFY_ENV" | cut -d'=' -f2- || echo "")

        if [[ -n "$current_previous" ]]; then
            # Append old key if not already present
            if [[ "$current_previous" != *"$old_app_key"* ]]; then
                local new_previous="${current_previous},${old_app_key}"
                sed -i.bak "s|^APP_PREVIOUS_KEYS=.*|APP_PREVIOUS_KEYS=${new_previous}|" "$COOLIFY_ENV"
                log_success "APP_KEY appended to existing APP_PREVIOUS_KEYS"
            else
                log_info "APP_KEY already present in APP_PREVIOUS_KEYS"
            fi
        else
            # Add APP_PREVIOUS_KEYS line
            echo "APP_PREVIOUS_KEYS=${old_app_key}" >> "$COOLIFY_ENV"
            log_success "APP_PREVIOUS_KEYS added to .env"
        fi
    else
        log_warn "Current Coolify .env not found at $COOLIFY_ENV"
        log_info "You may need to manually set APP_PREVIOUS_KEYS=$old_app_key"
    fi
}

# ============================================================
# Proxy Config Restore
# ============================================================

proxy_restore() {
    local backup_dir="$1"
    local proxy_archive="${backup_dir}/proxy-config.tar.gz"

    if [[ ! -f "$proxy_archive" ]]; then
        # Try in proxy/ subdirectory
        proxy_archive="${backup_dir}/proxy/proxy-config.tar.gz"
    fi

    if [[ ! -f "$proxy_archive" ]]; then
        log_info "No proxy configuration backup found, skipping"
        return 0
    fi

    log_step "Restoring proxy configuration"

    if tar xzf "$proxy_archive" -C "/data/coolify/" 2>/dev/null; then
        log_success "Proxy configuration restored"
    else
        log_warn "Failed to restore proxy configuration"
    fi
}
