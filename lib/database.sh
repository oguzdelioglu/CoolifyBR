#!/bin/bash
# CoolifyBR - PostgreSQL Database Backup/Restore
# Handles Coolify's internal PostgreSQL database operations

# ============================================================
# Full Database Backup
# ============================================================
db_backup_full() {
    local output_dir="$1"
    local dump_file="${output_dir}/coolify-db.dump"

    log_step "Backing up Coolify PostgreSQL database (full)"

    # Verify container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${COOLIFY_DB_CONTAINER}$"; then
        die "Database container '${COOLIFY_DB_CONTAINER}' is not running"
    fi

    # Create dump using pg_dump custom format
    log_substep "Creating database dump..."
    if docker exec "$COOLIFY_DB_CONTAINER" \
        pg_dump --format=custom --no-acl --no-owner \
        -U "$COOLIFY_DB_USER" "$COOLIFY_DB_NAME" > "$dump_file" 2>/dev/null; then

        local size
        size=$(stat -f%z "$dump_file" 2>/dev/null || stat -c%s "$dump_file" 2>/dev/null || echo "0")
        log_success "Database dump created: $(format_size "$size")"
        echo "$dump_file"
        return 0
    else
        log_error "Database dump failed"
        rm -f "$dump_file"
        return 1
    fi
}

# ============================================================
# Full Database Backup (SQL plain text - for selective use)
# ============================================================
db_backup_full_sql() {
    local output_dir="$1"
    local dump_file="${output_dir}/coolify-db.sql"

    log_substep "Creating SQL dump for selective operations..."
    if docker exec "$COOLIFY_DB_CONTAINER" \
        pg_dump --format=plain --no-acl --no-owner --inserts \
        -U "$COOLIFY_DB_USER" "$COOLIFY_DB_NAME" > "$dump_file" 2>/dev/null; then
        echo "$dump_file"
        return 0
    else
        rm -f "$dump_file"
        return 1
    fi
}

# ============================================================
# Selective Database Export (Project-based)
# ============================================================
db_export_project_data() {
    local project_id="$1"
    local output_dir="$2"
    local export_file="${output_dir}/project-${project_id}-data.json"

    log_step "Exporting project data (ID: $project_id)"

    # Helper: run psql and return result or empty string
    _psql_query() {
        docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A \
            -c "$1" 2>/dev/null || true
    }

    # Helper: ensure value is valid JSON or return "null"
    _ensure_json() {
        local val="$1"
        if [[ -z "$val" || "$val" == "null" ]]; then
            echo "null"
        elif echo "$val" | jq empty 2>/dev/null; then
            echo "$val"
        else
            echo "null"
        fi
    }

    # Export project record
    local project_data
    project_data=$(_psql_query "SELECT row_to_json(p) FROM projects p WHERE p.id = $project_id;")
    project_data=$(_ensure_json "$project_data")

    # Export environments
    local environments_data
    environments_data=$(_psql_query "SELECT json_agg(row_to_json(e)) FROM environments e WHERE e.project_id = $project_id;")
    environments_data=$(_ensure_json "$environments_data")

    # Get environment IDs for this project
    local env_ids
    env_ids=$(_psql_query "SELECT string_agg(id::text, ',') FROM environments WHERE project_id = $project_id;")

    if [[ -z "$env_ids" || "$env_ids" == "null" ]]; then
        log_warn "No environments found for project $project_id"
        env_ids="0"
    fi

    # Export applications
    local applications_data
    applications_data=$(_psql_query "SELECT json_agg(row_to_json(a)) FROM applications a WHERE a.environment_id IN ($env_ids);")
    applications_data=$(_ensure_json "$applications_data")

    # Export application settings
    local app_ids
    app_ids=$(_psql_query "SELECT string_agg(id::text, ',') FROM applications WHERE environment_id IN ($env_ids);")

    local app_settings_data="null"
    local env_vars_data="null"
    if [[ -n "$app_ids" && "$app_ids" != "null" ]]; then
        app_settings_data=$(_psql_query "SELECT json_agg(row_to_json(s)) FROM application_settings s WHERE s.application_id IN ($app_ids);")
        app_settings_data=$(_ensure_json "$app_settings_data")

        env_vars_data=$(_psql_query "SELECT json_agg(row_to_json(ev)) FROM environment_variables ev WHERE ev.application_id IN ($app_ids);")
        env_vars_data=$(_ensure_json "$env_vars_data")
    fi

    # Export standalone databases (all types)
    local db_tables=("standalone_postgresqls" "standalone_mysqls" "standalone_mariadbs" "standalone_mongodbs" "standalone_redis" "standalone_clickhouses" "standalone_dragonflies" "standalone_keydbs")
    local databases_data="{}"

    for table in "${db_tables[@]}"; do
        local table_data
        table_data=$(_psql_query "SELECT json_agg(row_to_json(d)) FROM $table d WHERE d.environment_id IN ($env_ids);")
        table_data=$(_ensure_json "$table_data")
        if [[ "$table_data" != "null" ]]; then
            databases_data=$(echo "$databases_data" | jq --arg key "$table" --argjson val "$table_data" '. + {($key): $val}' 2>/dev/null || echo "$databases_data")
        fi
    done

    # Export services
    local services_data
    services_data=$(_psql_query "SELECT json_agg(row_to_json(s)) FROM services s WHERE s.environment_id IN ($env_ids);")
    services_data=$(_ensure_json "$services_data")

    # Export service applications and databases
    local svc_ids
    svc_ids=$(_psql_query "SELECT string_agg(id::text, ',') FROM services WHERE environment_id IN ($env_ids);")

    local service_apps_data="null"
    local service_dbs_data="null"
    if [[ -n "$svc_ids" && "$svc_ids" != "null" ]]; then
        service_apps_data=$(_psql_query "SELECT json_agg(row_to_json(sa)) FROM service_applications sa WHERE sa.service_id IN ($svc_ids);")
        service_apps_data=$(_ensure_json "$service_apps_data")

        service_dbs_data=$(_psql_query "SELECT json_agg(row_to_json(sd)) FROM service_databases sd WHERE sd.service_id IN ($svc_ids);")
        service_dbs_data=$(_ensure_json "$service_dbs_data")
    fi

    # Compile full export
    jq -n \
        --argjson project "$project_data" \
        --argjson environments "$environments_data" \
        --argjson applications "$applications_data" \
        --argjson app_settings "$app_settings_data" \
        --argjson env_vars "$env_vars_data" \
        --argjson databases "$databases_data" \
        --argjson services "$services_data" \
        --argjson service_apps "$service_apps_data" \
        --argjson service_dbs "$service_dbs_data" \
        '{
            project: $project,
            environments: $environments,
            applications: $applications,
            application_settings: $app_settings,
            environment_variables: $env_vars,
            databases: $databases,
            services: $services,
            service_applications: $service_apps,
            service_databases: $service_dbs
        }' > "$export_file"

    log_success "Project data exported to: $export_file"
}

# ============================================================
# Database Restore - Full
# ============================================================
db_restore_full() {
    local dump_file="$1"

    log_step "Restoring Coolify PostgreSQL database (full)"

    if [[ ! -f "$dump_file" ]]; then
        die "Dump file not found: $dump_file"
    fi

    # Verify container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${COOLIFY_DB_CONTAINER}$"; then
        die "Database container '${COOLIFY_DB_CONTAINER}' is not running"
    fi

    # Terminate existing connections
    log_substep "Terminating existing database connections..."
    docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d postgres \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$COOLIFY_DB_NAME' AND pid <> pg_backend_pid();" \
        &>/dev/null || true

    # Drop and recreate database
    log_substep "Dropping and recreating database..."
    docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d postgres \
        -c "DROP DATABASE IF EXISTS $COOLIFY_DB_NAME;" &>/dev/null
    docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d postgres \
        -c "CREATE DATABASE $COOLIFY_DB_NAME;" &>/dev/null

    # Restore from dump
    log_substep "Restoring database from dump..."
    if cat "$dump_file" | docker exec -i "$COOLIFY_DB_CONTAINER" \
        pg_restore --verbose --clean --no-acl --no-owner \
        -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" 2>/dev/null; then
        log_success "Database restored successfully"
    else
        # pg_restore often returns non-zero due to warnings, verify table count
        local table_count
        table_count=$(docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A \
            -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null)

        if [[ "$table_count" -gt 0 ]]; then
            log_success "Database restored (${table_count} tables, some warnings were expected)"
        else
            die "Database restore failed - no tables found"
        fi
    fi
}

# ============================================================
# Database Restore - Selective (Project-based)
# ============================================================
db_restore_project_data() {
    local export_file="$1"

    log_step "Restoring project data from export"

    if [[ ! -f "$export_file" ]]; then
        die "Export file not found: $export_file"
    fi

    # Read project info
    local project_name project_uuid
    project_name=$(jq -r '.project.name' "$export_file")
    project_uuid=$(jq -r '.project.uuid' "$export_file")
    log_info "Restoring project: $project_name (UUID: $project_uuid)"

    # Get target server's team_id (Root Team)
    local target_team_id
    target_team_id=$(docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A \
        -c "SELECT id FROM teams ORDER BY id LIMIT 1;" 2>/dev/null || echo "0")
    target_team_id=$(echo "$target_team_id" | tr -d '[:space:]')
    [[ -z "$target_team_id" ]] && target_team_id="0"
    log_substep "Target team_id: $target_team_id"

    # Remap team_id in the export data to target server's team
    local modified_export
    modified_export=$(mktemp /tmp/coolify-export-XXXXXX.json)
    jq --argjson tid "$target_team_id" '
        .project.team_id = $tid |
        if .environments then .environments |= map(.team_id = $tid // .team_id) else . end |
        if .applications then .applications |= map(.team_id = $tid // .team_id) else . end |
        if .services then .services |= map(.team_id = $tid // .team_id) else . end
    ' "$export_file" > "$modified_export" 2>/dev/null || cp "$export_file" "$modified_export"

    # Check if project already exists (by uuid)
    local existing_project
    existing_project=$(docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A \
        -c "SELECT id FROM projects WHERE uuid = '$project_uuid';" 2>/dev/null || true)
    existing_project=$(echo "$existing_project" | tr -d '[:space:]')

    if [[ -n "$existing_project" ]]; then
        log_warn "Project '$project_name' already exists (ID: $existing_project)"
        if ! prompt_yes_no "Overwrite existing project data?" "n"; then
            log_info "Skipping project restore"
            rm -f "$modified_export"
            return 0
        fi
        # Delete existing project data (cascade will remove environments, apps, etc.)
        docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" \
            -c "DELETE FROM projects WHERE id = $existing_project;" &>/dev/null || true
        log_substep "Deleted existing project data"
    fi

    # Also check for id conflict (different project using same numeric id)
    local source_id
    source_id=$(jq -r '.project.id' "$modified_export")
    local id_conflict
    id_conflict=$(docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A \
        -c "SELECT uuid FROM projects WHERE id = $source_id;" 2>/dev/null || true)
    id_conflict=$(echo "$id_conflict" | tr -d '[:space:]')

    if [[ -n "$id_conflict" && "$id_conflict" != "$project_uuid" ]]; then
        log_warn "ID $source_id is used by another project, will let PostgreSQL assign new ID"
        # Remove id from project and all related records to let PG auto-assign
        # We need to use a different approach: insert without id, get new id, remap
        local new_id
        new_id=$(docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A \
            -c "SELECT COALESCE(MAX(id), 0) + 1 FROM projects;" 2>/dev/null || true)
        new_id=$(echo "$new_id" | tr -d '[:space:]')
        [[ -z "$new_id" ]] && new_id="1000"
        log_substep "Remapping project ID: $source_id -> $new_id"

        # Remap IDs in the modified export
        jq --argjson old_id "$source_id" --argjson new_id "$new_id" '
            .project.id = $new_id |
            if .environments then .environments |= map(if .project_id == $old_id then .project_id = $new_id else . end) else . end
        ' "$modified_export" > "${modified_export}.tmp" && mv "${modified_export}.tmp" "$modified_export"
    fi

    # Build SQL insert statements
    local sql_file
    sql_file=$(mktemp /tmp/coolify-restore-XXXXXX.sql)

    echo "BEGIN;" > "$sql_file"

    # Insert project
    local project_json
    project_json=$(jq -c '.project' "$modified_export")
    _generate_insert_sql "projects" "$project_json" >> "$sql_file"

    # Insert environments
    local env_count
    env_count=$(jq '.environments | length // 0' "$modified_export")
    for ((i = 0; i < env_count; i++)); do
        local env_json
        env_json=$(jq -c ".environments[$i]" "$modified_export")
        _generate_insert_sql "environments" "$env_json" >> "$sql_file"
    done

    # Insert applications
    local app_count
    app_count=$(jq '.applications | length // 0' "$modified_export")
    for ((i = 0; i < app_count; i++)); do
        local app_json
        app_json=$(jq -c ".applications[$i]" "$modified_export")
        _generate_insert_sql "applications" "$app_json" >> "$sql_file"
    done

    # Insert application settings
    local settings_count
    settings_count=$(jq '.application_settings | length // 0' "$modified_export")
    for ((i = 0; i < settings_count; i++)); do
        local settings_json
        settings_json=$(jq -c ".application_settings[$i]" "$modified_export")
        _generate_insert_sql "application_settings" "$settings_json" >> "$sql_file"
    done

    # Insert environment variables
    local ev_count
    ev_count=$(jq '.environment_variables | length // 0' "$modified_export")
    for ((i = 0; i < ev_count; i++)); do
        local ev_json
        ev_json=$(jq -c ".environment_variables[$i]" "$modified_export")
        _generate_insert_sql "environment_variables" "$ev_json" >> "$sql_file"
    done

    # Insert databases (all types)
    for table in $(jq -r '.databases | keys[]' "$modified_export" 2>/dev/null || true); do
        local db_count
        db_count=$(jq ".databases.\"$table\" | length // 0" "$modified_export")
        for ((i = 0; i < db_count; i++)); do
            local db_json
            db_json=$(jq -c ".databases.\"$table\"[$i]" "$modified_export")
            _generate_insert_sql "$table" "$db_json" >> "$sql_file"
        done
    done

    # Insert services
    local svc_count
    svc_count=$(jq '.services | length // 0' "$modified_export")
    for ((i = 0; i < svc_count; i++)); do
        local svc_json
        svc_json=$(jq -c ".services[$i]" "$modified_export")
        _generate_insert_sql "services" "$svc_json" >> "$sql_file"
    done

    # Insert service applications
    local sa_count
    sa_count=$(jq '.service_applications | length // 0' "$modified_export")
    for ((i = 0; i < sa_count; i++)); do
        local sa_json
        sa_json=$(jq -c ".service_applications[$i]" "$modified_export")
        _generate_insert_sql "service_applications" "$sa_json" >> "$sql_file"
    done

    # Insert service databases
    local sd_count
    sd_count=$(jq '.service_databases | length // 0' "$modified_export")
    for ((i = 0; i < sd_count; i++)); do
        local sd_json
        sd_json=$(jq -c ".service_databases[$i]" "$modified_export")
        _generate_insert_sql "service_databases" "$sd_json" >> "$sql_file"
    done

    # Update sequences after inserts
    echo "SELECT setval(pg_get_serial_sequence('projects', 'id'), COALESCE(MAX(id), 1)) FROM projects;" >> "$sql_file"
    echo "SELECT setval(pg_get_serial_sequence('environments', 'id'), COALESCE(MAX(id), 1)) FROM environments;" >> "$sql_file"
    echo "SELECT setval(pg_get_serial_sequence('applications', 'id'), COALESCE(MAX(id), 1)) FROM applications;" >> "$sql_file"

    echo "COMMIT;" >> "$sql_file"

    # Execute SQL (capture errors)
    log_substep "Executing restore SQL..."
    local sql_output
    sql_output=$(cat "$sql_file" | docker exec -i "$COOLIFY_DB_CONTAINER" \
        psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" 2>&1 || true)

    # Check for errors in output
    if echo "$sql_output" | grep -qi "error" 2>/dev/null; then
        log_warn "SQL errors detected during restore:"
        echo "$sql_output" | grep -i "error" | head -5 | while IFS= read -r line; do
            log_warn "  $line"
        done
    fi

    # Verify the project was actually inserted
    local verify
    verify=$(docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A \
        -c "SELECT id FROM projects WHERE uuid = '$project_uuid';" 2>/dev/null || true)
    verify=$(echo "$verify" | tr -d '[:space:]')

    if [[ -n "$verify" ]]; then
        log_success "Project '$project_name' restored to database (ID: $verify)"
    else
        log_error "Project '$project_name' was NOT inserted into database"
        log_error "Run with SQL debug: cat $sql_file"
        # Don't delete sql_file for debugging
        rm -f "$modified_export"
        return 1
    fi

    rm -f "$sql_file" "$modified_export"
}

# ============================================================
# SQL Generation Helper
# ============================================================
_generate_insert_sql() {
    local table="$1"
    local json="$2"

    if [[ "$json" == "null" || -z "$json" ]]; then
        return
    fi

    # Extract columns and values from JSON using to_entries to keep them paired
    local columns values
    columns=$(echo "$json" | jq -r '[to_entries[].key] | join(",")')
    values=$(echo "$json" | jq -r '[to_entries[].value | if type == "null" then "NULL" elif type == "string" then ("'"'"'" + (gsub("'"'"'"; "'"'"''"'"'") ) + "'"'"'") elif type == "object" or type == "array" then ("'"'"'" + (tostring | gsub("'"'"'"; "'"'"''"'"'")) + "'"'"'") else tostring end] | join(",")')

    echo "INSERT INTO $table ($columns) VALUES ($values) ON CONFLICT DO NOTHING;"
}

# ============================================================
# Database Info
# ============================================================
db_get_size() {
    docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A \
        -c "SELECT pg_size_pretty(pg_database_size('$COOLIFY_DB_NAME'));" 2>/dev/null
}

db_get_table_count() {
    docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A \
        -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null
}

db_verify_connection() {
    if docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" \
        -c "SELECT 1;" &>/dev/null; then
        log_success "Database connection verified"
        return 0
    else
        log_error "Cannot connect to Coolify database"
        return 1
    fi
}
