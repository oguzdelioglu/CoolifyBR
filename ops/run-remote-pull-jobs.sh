#!/opt/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${CONFIG_DIR:-/root/.config/coolifybr/jobs}"
ENTRYPOINT="${ENTRYPOINT:-$SCRIPT_DIR/remote-pull-backup.sh}"

if [[ ! -d "$CONFIG_DIR" ]]; then
    echo "Missing config directory: $CONFIG_DIR" >&2
    exit 1
fi

mapfile -t configs < <(find "$CONFIG_DIR" -maxdepth 1 -type f -name '*.env' | sort)

if (( ${#configs[@]} == 0 )); then
    echo "No job configs found in $CONFIG_DIR" >&2
    exit 1
fi

exit_code=0

for config in "${configs[@]}"; do
    echo "=== Running job: $config ==="
    if ! CONFIG_FILE="$config" "$ENTRYPOINT"; then
        echo "Job failed: $config" >&2
        exit_code=1
    fi
done

exit "$exit_code"
