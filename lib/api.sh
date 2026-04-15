#!/bin/bash
# CoolifyBR - Coolify API Integration
# Communicates with Coolify REST API for project/resource discovery

# ============================================================
# API Configuration
# ============================================================
COOLIFY_API_BASE="${COOLIFY_API_BASE:-}"
COOLIFY_API_TOKEN="${COOLIFY_API_TOKEN:-}"

api_init() {
    if [[ -z "$COOLIFY_API_BASE" ]]; then
        COOLIFY_API_BASE="http://localhost:8000"
    fi

    if [[ -z "$COOLIFY_API_TOKEN" ]]; then
        if [[ -f "${SCRIPT_DIR:-}/config.env" ]]; then
            # shellcheck source=/dev/null
            source "${SCRIPT_DIR}/config.env"
        fi
    fi

    if [[ -z "$COOLIFY_API_TOKEN" ]]; then
        log_warn "No API token configured. Selective backup will use database-level discovery."
        return 1
    fi

    log_success "API configured: $COOLIFY_API_BASE"
    return 0
}

# ============================================================
# HTTP Helpers
# ============================================================
api_request() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local url="${COOLIFY_API_BASE}/api/v1${endpoint}"
    local curl_args=(
        -s -S
        -X "$method"
        -H "Authorization: Bearer ${COOLIFY_API_TOKEN}"
        -H "Accept: application/json"
        -H "Content-Type: application/json"
        --connect-timeout 10
        --max-time 30
    )

    if [[ -n "$data" ]]; then
        curl_args+=(-d "$data")
    fi

    local response
    local http_code

    response=$(curl "${curl_args[@]}" -w "\n%{http_code}" "$url" 2>/dev/null)
    http_code=$(echo "$response" | tail -1)
    response=$(echo "$response" | sed '$d')

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        echo "$response"
        return 0
    else
        log_error "API request failed: $method $endpoint (HTTP $http_code)"
        return 1
    fi
}

api_get() {
    api_request "GET" "$1"
}

# ============================================================
# Project Discovery
# ============================================================
api_list_projects() {
    local response
    response=$(api_get "/projects") || return 1
    echo "$response"
}

api_get_project() {
    local uuid="$1"
    local response
    response=$(api_get "/projects/${uuid}") || return 1
    echo "$response"
}

api_get_project_environments() {
    local project_uuid="$1"
    local response
    response=$(api_get "/projects/${project_uuid}/environments") || return 1
    echo "$response"
}

api_get_environment_resources() {
    local project_uuid="$1"
    local env_name="$2"
    local response
    response=$(api_get "/projects/${project_uuid}/${env_name}") || return 1
    echo "$response"
}

# ============================================================
# Application Discovery
# ============================================================
api_list_applications() {
    local response
    response=$(api_get "/applications") || return 1
    echo "$response"
}

api_get_application() {
    local uuid="$1"
    local response
    response=$(api_get "/applications/${uuid}") || return 1
    echo "$response"
}

# ============================================================
# Database Discovery
# ============================================================
api_list_databases() {
    local response
    response=$(api_get "/databases") || return 1
    echo "$response"
}

api_get_database() {
    local uuid="$1"
    local response
    response=$(api_get "/databases/${uuid}") || return 1
    echo "$response"
}

# ============================================================
# Service Discovery
# ============================================================
api_list_services() {
    local response
    response=$(api_get "/services") || return 1
    echo "$response"
}

api_get_service() {
    local uuid="$1"
    local response
    response=$(api_get "/services/${uuid}") || return 1
    echo "$response"
}

# ============================================================
# Server Discovery
# ============================================================
api_list_servers() {
    local response
    response=$(api_get "/servers") || return 1
    echo "$response"
}

api_get_server_resources() {
    local uuid="$1"
    local response
    response=$(api_get "/servers/${uuid}/resources") || return 1
    echo "$response"
}

# ============================================================
# High-Level Discovery Functions
# ============================================================

# Get a formatted list of projects with their resources
discover_projects() {
    local projects_json
    projects_json=$(api_list_projects) || return 1

    local count
    count=$(echo "$projects_json" | jq 'length')

    if [[ "$count" -eq 0 ]]; then
        log_warn "No projects found"
        return 1
    fi

    echo "$projects_json" | jq -r '.[] | "\(.uuid)\t\(.name)\t\(.description // "N/A")"'
}

# Get all resources for a specific project
discover_project_resources() {
    local project_uuid="$1"
    local environments_json
    local all_resources='{"applications":[],"databases":[],"services":[]}'

    environments_json=$(api_get_project_environments "$project_uuid") || return 1

    local env_count
    env_count=$(echo "$environments_json" | jq 'length')

    for ((i = 0; i < env_count; i++)); do
        local env_name
        env_name=$(echo "$environments_json" | jq -r ".[$i].name")

        local resources
        resources=$(api_get_environment_resources "$project_uuid" "$env_name") || continue

        local apps dbs svcs
        apps=$(echo "$resources" | jq '.applications // []')
        dbs=$(echo "$resources" | jq '.databases // []')
        svcs=$(echo "$resources" | jq '.services // []')

        all_resources=$(echo "$all_resources" | jq \
            --argjson apps "$apps" \
            --argjson dbs "$dbs" \
            --argjson svcs "$svcs" \
            '.applications += $apps | .databases += $dbs | .services += $svcs')
    done

    echo "$all_resources"
}

# ============================================================
# Docker-Level Discovery (Fallback when API is unavailable)
# ============================================================

# Discover Coolify-managed containers from Docker labels
discover_containers_docker() {
    log_info "Discovering resources via Docker labels (API fallback)..."

    local containers
    containers=$(docker ps --format '{{.Names}}\t{{.ID}}\t{{.Image}}\t{{.Labels}}' 2>/dev/null)

    if [[ -z "$containers" ]]; then
        log_warn "No running containers found"
        return 1
    fi

    # Filter Coolify-managed containers (they have coolify.* labels)
    local coolify_containers
    coolify_containers=$(docker ps --filter "label=coolify.managed" --format '{{.Names}}\t{{.ID}}\t{{.Image}}' 2>/dev/null || true)

    if [[ -z "$coolify_containers" ]]; then
        # Try broader search - exclude Coolify system containers
        coolify_containers=$(docker ps --format '{{.Names}}\t{{.ID}}\t{{.Image}}' 2>/dev/null | \
            grep -v "^coolify\b" | \
            grep -v "^coolify-db" | \
            grep -v "^coolify-redis" | \
            grep -v "^coolify-realtime" | \
            grep -v "^coolify-proxy" || true)
    fi

    echo "$coolify_containers"
}

# Get container volumes by container name
get_container_volumes() {
    local container_name="$1"
    docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{printf "\n"}}{{end}}{{end}}' "$container_name" 2>/dev/null | grep -v '^$' || true
}

# Get container bind mounts by container name
get_container_binds() {
    local container_name="$1"
    docker inspect --format '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}:{{.Destination}}{{printf "\n"}}{{end}}{{end}}' "$container_name" 2>/dev/null | grep -v '^$' || true
}

# Get all Docker volumes for Coolify-managed containers
discover_all_volumes() {
    local containers
    containers=$(discover_containers_docker)

    if [[ -z "$containers" ]]; then
        return 1
    fi

    local all_volumes=()
    while IFS=$'\t' read -r name _id _image; do
        local volumes
        volumes=$(get_container_volumes "$name" 2>/dev/null)
        if [[ -n "$volumes" ]]; then
            while IFS= read -r vol; do
                all_volumes+=("$vol")
            done <<< "$volumes"
        fi
    done <<< "$containers"

    # Deduplicate
    printf '%s\n' "${all_volumes[@]}" | sort -u
}

# ============================================================
# Database-Level Discovery
# ============================================================

# Query Coolify's PostgreSQL for project/resource info
db_discover_projects() {
    docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A -F $'\t' \
        -c "SELECT p.id, p.uuid, p.name, COALESCE(p.description, ''), COUNT(DISTINCT e.id) as env_count
            FROM projects p
            LEFT JOIN environments e ON e.project_id = p.id
            GROUP BY p.id, p.uuid, p.name, p.description
            ORDER BY p.name;" 2>/dev/null
}

db_discover_project_applications() {
    local project_id="$1"
    docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A -F $'\t' \
        -c "SELECT a.id, a.uuid, a.name, a.fqdn, a.status
            FROM applications a
            JOIN environments e ON a.environment_id = e.id
            WHERE e.project_id = $project_id
            ORDER BY a.name;" 2>/dev/null
}

db_discover_project_databases() {
    local project_id="$1"
    local db_tables=("standalone_postgresqls" "standalone_mysqls" "standalone_mariadbs" "standalone_mongodbs" "standalone_redis" "standalone_clickhouses" "standalone_dragonflies" "standalone_keydbs")
    local results=""

    for table in "${db_tables[@]}"; do
        local type
        type=$(echo "$table" | sed 's/standalone_//' | sed 's/s$//')
        local rows
        rows=$(docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A -F $'\t' \
            -c "SELECT d.id, d.uuid, d.name, '$type' as type, d.status
                FROM $table d
                JOIN environments e ON d.environment_id = e.id
                WHERE e.project_id = $project_id
                ORDER BY d.name;" 2>/dev/null || true)
        if [[ -n "$rows" ]]; then
            results+="$rows"$'\n'
        fi
    done

    echo "$results" | grep -v '^$' || true
}

db_discover_project_services() {
    local project_id="$1"
    docker exec "$COOLIFY_DB_CONTAINER" psql -U "$COOLIFY_DB_USER" -d "$COOLIFY_DB_NAME" -t -A -F $'\t' \
        -c "SELECT s.id, s.uuid, s.name, s.status
            FROM services s
            JOIN environments e ON s.environment_id = e.id
            WHERE e.project_id = $project_id
            ORDER BY s.name;" 2>/dev/null
}
