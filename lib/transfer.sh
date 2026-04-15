#!/bin/bash
# CoolifyBR - Server Transfer Module
# Handles transferring backup archives between servers via SCP/rsync

# ============================================================
# SSH Connection Testing
# ============================================================

transfer_test_ssh() {
    local host="$1"
    local user="${2:-root}"
    local key="${3:-}"
    local port="${4:-22}"

    log_substep "Testing SSH connection to ${user}@${host}:${port}..."

    local ssh_args=(-o "StrictHostKeyChecking=no" -o "ConnectTimeout=10" -o "BatchMode=yes" -p "$port")

    if [[ -n "$key" && -f "$key" ]]; then
        ssh_args+=(-i "$key")
    fi

    if ssh "${ssh_args[@]}" "${user}@${host}" "echo ok" &>/dev/null; then
        log_success "SSH connection to ${user}@${host} successful"
        return 0
    else
        log_error "SSH connection to ${user}@${host} failed"
        return 1
    fi
}

# ============================================================
# Transfer via SCP
# ============================================================

transfer_scp() {
    local local_file="$1"
    local remote_host="$2"
    local remote_path="${3:-/tmp/}"
    local remote_user="${4:-root}"
    local ssh_key="${5:-}"
    local ssh_port="${6:-22}"

    log_step "Transferring backup to ${remote_user}@${remote_host}:${remote_path}"

    if [[ ! -f "$local_file" ]]; then
        die "Local file not found: $local_file"
    fi

    local file_size
    file_size=$(stat -f%z "$local_file" 2>/dev/null || stat -c%s "$local_file" 2>/dev/null || echo "0")
    log_info "File size: $(format_size "$file_size")"

    local scp_args=(-P "$ssh_port" -o "StrictHostKeyChecking=no" -o "ConnectTimeout=30")

    if [[ -n "$ssh_key" && -f "$ssh_key" ]]; then
        scp_args+=(-i "$ssh_key")
    fi

    # Ensure remote directory exists
    local ssh_args_base=(-o "StrictHostKeyChecking=no" -o "ConnectTimeout=10" -p "$ssh_port")
    if [[ -n "$ssh_key" && -f "$ssh_key" ]]; then
        ssh_args_base+=(-i "$ssh_key")
    fi
    local remote_cmd
    printf -v remote_cmd 'mkdir -p %q' "$remote_path"
    # shellcheck disable=SC2029
    ssh "${ssh_args_base[@]}" "${remote_user}@${remote_host}" "$remote_cmd" 2>/dev/null

    log_substep "Starting transfer..."
    if scp "${scp_args[@]}" "$local_file" "${remote_user}@${remote_host}:${remote_path}" 2>/dev/null; then
        log_success "Transfer completed successfully"
        return 0
    else
        log_error "Transfer failed"
        return 1
    fi
}

# ============================================================
# Transfer via rsync (preferred for large files)
# ============================================================

transfer_rsync() {
    local local_file="$1"
    local remote_host="$2"
    local remote_path="${3:-/tmp/}"
    local remote_user="${4:-root}"
    local ssh_key="${5:-}"
    local ssh_port="${6:-22}"

    log_step "Transferring backup via rsync to ${remote_user}@${remote_host}:${remote_path}"

    if ! command -v rsync &>/dev/null; then
        log_warn "rsync not available, falling back to SCP"
        transfer_scp "$local_file" "$remote_host" "$remote_path" "$remote_user" "$ssh_key" "$ssh_port"
        return $?
    fi

    if [[ ! -f "$local_file" ]]; then
        die "Local file not found: $local_file"
    fi

    local file_size
    file_size=$(stat -f%z "$local_file" 2>/dev/null || stat -c%s "$local_file" 2>/dev/null || echo "0")
    log_info "File size: $(format_size "$file_size")"

    local ssh_cmd="ssh -p $ssh_port -o StrictHostKeyChecking=no -o ConnectTimeout=30"
    if [[ -n "$ssh_key" && -f "$ssh_key" ]]; then
        ssh_cmd="$ssh_cmd -i $ssh_key"
    fi

    # Ensure remote directory exists
    local ssh_args_base=(-o "StrictHostKeyChecking=no" -o "ConnectTimeout=10" -p "$ssh_port")
    if [[ -n "$ssh_key" && -f "$ssh_key" ]]; then
        ssh_args_base+=(-i "$ssh_key")
    fi
    local remote_cmd
    printf -v remote_cmd 'mkdir -p %q' "$remote_path"
    # shellcheck disable=SC2029
    ssh "${ssh_args_base[@]}" "${remote_user}@${remote_host}" "$remote_cmd" 2>/dev/null

    log_substep "Starting rsync transfer..."
    if rsync -avz --progress -e "$ssh_cmd" \
        "$local_file" "${remote_user}@${remote_host}:${remote_path}"; then
        log_success "Transfer completed successfully"
        return 0
    else
        log_error "Transfer failed"
        return 1
    fi
}

# ============================================================
# Auto-Transfer (picks best method)
# ============================================================

transfer_auto() {
    local local_file="$1"
    local remote_host="$2"
    local remote_path="${3:-/tmp/}"
    local remote_user="${4:-root}"
    local ssh_key="${5:-}"
    local ssh_port="${6:-22}"

    # Test connection first
    if ! transfer_test_ssh "$remote_host" "$remote_user" "$ssh_key" "$ssh_port"; then
        die "Cannot connect to remote server. Check SSH settings."
    fi

    # Use rsync if available (better for large files), else SCP
    if command -v rsync &>/dev/null; then
        transfer_rsync "$local_file" "$remote_host" "$remote_path" "$remote_user" "$ssh_key" "$ssh_port"
    else
        transfer_scp "$local_file" "$remote_host" "$remote_path" "$remote_user" "$ssh_key" "$ssh_port"
    fi
}

# ============================================================
# Remote Restore Execution
# ============================================================

transfer_remote_restore() {
    local remote_host="$1"
    local remote_backup_path="$2"
    local remote_user="${3:-root}"
    local ssh_key="${4:-}"
    local ssh_port="${5:-22}"

    log_step "Executing remote restore on ${remote_user}@${remote_host}"

    local ssh_args=(-o "StrictHostKeyChecking=no" -o "ConnectTimeout=30" -p "$ssh_port" -t)

    if [[ -n "$ssh_key" && -f "$ssh_key" ]]; then
        ssh_args+=(-i "$ssh_key")
    fi

    # Check if CoolifyBR restore script exists on remote
    local remote_script_check
    remote_script_check=$(ssh "${ssh_args[@]}" "${remote_user}@${remote_host}" \
        "test -f /tmp/coolify-restore.sh && echo 'exists' || echo 'missing'" 2>/dev/null)

    if [[ "$remote_script_check" == "missing" ]]; then
        log_info "Uploading restore script to remote server..."

        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

        # Transfer the restore script and lib directory
        local scp_args=(-P "$ssh_port" -o "StrictHostKeyChecking=no" -r)
        if [[ -n "$ssh_key" && -f "$ssh_key" ]]; then
            scp_args+=(-i "$ssh_key")
        fi

        scp "${scp_args[@]}" "$script_dir/coolify-restore.sh" "${remote_user}@${remote_host}:/tmp/" 2>/dev/null
        scp "${scp_args[@]}" "$script_dir/lib" "${remote_user}@${remote_host}:/tmp/coolify-restore-lib/" 2>/dev/null

        ssh "${ssh_args[@]}" "${remote_user}@${remote_host}" "chmod +x /tmp/coolify-restore.sh" 2>/dev/null
    fi

    # Execute restore
    log_substep "Running restore on remote server..."
    local restore_cmd
    printf -v restore_cmd 'cd /tmp && ./coolify-restore.sh --file %q --non-interactive' "$remote_backup_path"
    # shellcheck disable=SC2029
    ssh "${ssh_args[@]}" "${remote_user}@${remote_host}" \
        "$restore_cmd" 2>&1

    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        log_success "Remote restore completed successfully"
    else
        log_error "Remote restore failed (exit code: $exit_code)"
    fi
    return $exit_code
}

# ============================================================
# Interactive Transfer Setup
# ============================================================

transfer_interactive_setup() {
    print_menu_header "Transfer Configuration"

    echo -ne "  ${BOLD}Remote host${NC} (IP or hostname): "
    read -r remote_host

    echo -ne "  ${BOLD}Remote user${NC} [root]: "
    read -r remote_user
    remote_user="${remote_user:-root}"

    echo -ne "  ${BOLD}SSH port${NC} [22]: "
    read -r ssh_port
    ssh_port="${ssh_port:-22}"

    echo -ne "  ${BOLD}SSH key path${NC} (leave empty for default): "
    read -r ssh_key

    echo -ne "  ${BOLD}Remote backup path${NC} [/tmp/]: "
    read -r remote_path
    remote_path="${remote_path:-/tmp/}"

    # Return values as a tab-separated string
    echo "${remote_host}	${remote_user}	${ssh_port}	${ssh_key}	${remote_path}"
}
