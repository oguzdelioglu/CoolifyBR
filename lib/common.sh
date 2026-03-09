#!/bin/bash
# CoolifyBR - Common Utilities
# Shared functions for logging, validation, and system checks

set -euo pipefail

# ============================================================
# Colors & Formatting
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ============================================================
# Logging Functions
# ============================================================
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_step() {
    echo -e "\n${CYAN}${BOLD}>> $*${NC}"
}

log_substep() {
    echo -e "   ${DIM}→${NC} $*"
}

log_header() {
    local text="$1"
    local width=60
    echo ""
    echo -e "${MAGENTA}${BOLD}$(printf '═%.0s' $(seq 1 $width))${NC}"
    echo -e "${MAGENTA}${BOLD}  $text${NC}"
    echo -e "${MAGENTA}${BOLD}$(printf '═%.0s' $(seq 1 $width))${NC}"
    echo ""
}

# ============================================================
# Error Handling
# ============================================================
die() {
    log_error "$@"
    exit 1
}

trap_cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script terminated with exit code $exit_code"
        if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" ]]; then
            log_warn "Cleaning up temporary directory: $TEMP_DIR"
            rm -rf "$TEMP_DIR"
        fi
    fi
}

# ============================================================
# Validation Functions
# ============================================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (sudo)"
    fi
}

check_docker() {
    if ! command -v docker &>/dev/null; then
        die "Docker is not installed"
    fi
    if ! docker info &>/dev/null; then
        die "Docker daemon is not running"
    fi
    log_success "Docker is available"
}

check_coolify_installed() {
    if [[ ! -d "/data/coolify" ]]; then
        die "Coolify installation not found at /data/coolify"
    fi
    log_success "Coolify installation found"
}

check_coolify_containers() {
    local required_containers=("coolify" "coolify-db")
    local missing=()

    for container in "${required_containers[@]}"; do
        if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            missing+=("$container")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing running containers: ${missing[*]}"
        return 1
    fi

    log_success "Coolify containers are running"
    return 0
}

check_dependencies() {
    local deps=("tar" "gzip" "jq" "curl")
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing dependencies: ${missing[*]}. Install them first."
    fi
    log_success "All dependencies available"
}

# ============================================================
# Coolify Environment
# ============================================================
COOLIFY_BASE="/data/coolify"
COOLIFY_SOURCE="$COOLIFY_BASE/source"
COOLIFY_ENV="$COOLIFY_SOURCE/.env"
COOLIFY_SSH_DIR="$COOLIFY_BASE/ssh/keys"
COOLIFY_BACKUPS_DIR="$COOLIFY_BASE/backups"
COOLIFY_DB_CONTAINER="coolify-db"
COOLIFY_DB_USER="coolify"
COOLIFY_DB_NAME="coolify"
COOLIFY_CONTAINERS=("coolify" "coolify-db" "coolify-redis" "coolify-realtime")

get_app_key() {
    if [[ -f "$COOLIFY_ENV" ]]; then
        grep "^APP_KEY=" "$COOLIFY_ENV" | cut -d'=' -f2- || true
    else
        log_error "Coolify .env file not found at $COOLIFY_ENV"
        return 1
    fi
}

get_coolify_version() {
    if docker ps --format '{{.Image}}' | grep -q "coolify"; then
        docker inspect --format '{{.Config.Image}}' coolify 2>/dev/null | cut -d: -f2 || echo "unknown"
    else
        echo "unknown"
    fi
}

# ============================================================
# Backup Naming & Paths
# ============================================================
generate_backup_name() {
    local mode="${1:-full}"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    echo "coolify-backup-${mode}-${timestamp}"
}

create_temp_dir() {
    local prefix="${1:-coolify-br}"
    TEMP_DIR=$(mktemp -d "/tmp/${prefix}-XXXXXX")
    echo "$TEMP_DIR"
}

# ============================================================
# Manifest Management
# ============================================================
create_manifest() {
    local output_file="$1"
    local mode="$2"
    local version
    version=$(get_coolify_version)

    cat > "$output_file" <<EOF
{
    "tool": "CoolifyBR",
    "version": "1.0.0",
    "backup_mode": "$mode",
    "coolify_version": "$version",
    "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "hostname": "$(hostname)",
    "components": {}
}
EOF
}

update_manifest() {
    local manifest_file="$1"
    local key="$2"
    local value="$3"

    if command -v jq &>/dev/null; then
        local tmp
        tmp=$(mktemp)
        jq ".components.${key} = ${value}" "$manifest_file" > "$tmp" && mv "$tmp" "$manifest_file"
    fi
}

# ============================================================
# Interactive Menu Helpers
# ============================================================
print_menu_header() {
    local title="$1"
    echo ""
    echo -e "${CYAN}${BOLD}┌─────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}${BOLD}│  $title$(printf '%*s' $((46 - ${#title})) '')│${NC}"
    echo -e "${CYAN}${BOLD}└─────────────────────────────────────────────────┘${NC}"
}

print_menu_item() {
    local num="$1"
    local label="$2"
    local desc="${3:-}"
    if [[ -n "$desc" ]]; then
        echo -e "  ${BOLD}${num})${NC} ${label} ${DIM}— ${desc}${NC}"
    else
        echo -e "  ${BOLD}${num})${NC} ${label}"
    fi
}

prompt_yes_no() {
    local question="$1"
    local default="${2:-y}"
    local hint="[Y/n]"
    [[ "$default" == "n" ]] && hint="[y/N]"

    echo -ne "${YELLOW}${question} ${hint}: ${NC}" >&2
    read -r answer
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy] ]]
}

prompt_selection() {
    local prompt_text="$1"
    local max="$2"
    local selection

    while true; do
        echo -ne "\n${YELLOW}${prompt_text} (1-${max}): ${NC}" >&2
        read -r selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ "$selection" -ge 1 ]] && [[ "$selection" -le "$max" ]]; then
            echo "$selection"
            return 0
        fi
        log_error "Invalid selection. Please enter a number between 1 and $max." >&2
    done
}

prompt_multi_selection() {
    local prompt_text="$1"
    local max="$2"

    echo -ne "\n${YELLOW}${prompt_text} (comma-separated, e.g. 1,3,5 or 'all'): ${NC}" >&2
    read -r input

    if [[ "$input" == "all" ]]; then
        seq 1 "$max" | tr '\n' ',' | sed 's/,$//'
        return 0
    fi

    echo "$input"
}

# ============================================================
# Size Formatting
# ============================================================
format_size() {
    local bytes=$1
    if [[ $bytes -ge 1073741824 ]]; then
        awk "BEGIN {printf \"%.2f GB\", $bytes / 1073741824}"
    elif [[ $bytes -ge 1048576 ]]; then
        awk "BEGIN {printf \"%.2f MB\", $bytes / 1048576}"
    elif [[ $bytes -ge 1024 ]]; then
        awk "BEGIN {printf \"%.2f KB\", $bytes / 1024}"
    else
        echo "$bytes B"
    fi
}

# ============================================================
# Progress Indicator
# ============================================================
spinner() {
    local pid=$1
    local msg="${2:-Processing...}"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${CYAN}${spin:$i:1}${NC} %s" "$msg"
        i=$(( (i + 1) % ${#spin} ))
        sleep 0.1
    done
    printf "\r"
}
