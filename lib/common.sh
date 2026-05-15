#!/bin/bash
#
# Common functions for Odoo migration scripts
# Source this file from other scripts: source "$(dirname "$0")/lib/common.sh"
#

set -euo pipefail

# Get the absolute path of the project root (parent of lib/)
readonly PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

readonly DATASTORE_PATH="/srv/datastore/data"
readonly FILESTORE_SUBPATH="var/lib/odoo/filestore"

check_required_commands() {
    local missing=()
    for cmd in docker compose sudo rsync yq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Required commands not found: ${missing[*]}"
        log_error "Please install them before running this script."
        exit 1
    fi
}

log_info()  { printf "[INFO]  %s\n" "$*"; }
log_warn()  { printf "[WARN]  %s\n" "$*" >&2; }
log_error() { printf "[ERROR] %s\n" "$*" >&2; }
log_step()  { printf "\n===== %s =====\n" "$*"; }

confirm_or_exit() {
    local message="$1"
    local choice
    echo ""
    echo "$message"
    echo "Y - Yes, continue"
    echo "N - No, cancel"
    read -r -n 1 -p "Your choice: " choice
    echo ""
    case "$choice" in
        [Yy]) return 0 ;;
        *) log_error "Cancelled by user."; exit 1 ;;
    esac
}

query_postgres_container() {
    local query="$1"
    local db_name="$2"

    if [[ -z "$query" ]]; then
        return 0
    fi

    local result
    if ! result=$(docker exec -u 70 "$POSTGRES_SERVICE_NAME" psql -d "$db_name" -t -A -c "$query"); then
        printf "Failed to execute SQL query: %s\n" "$query" >&2
        printf "Error: %s\n" "$result" >&2
        return 1
    fi
    echo "$result"
}

copy_database() {
    local from_db="$1"
    local to_service="$2"
    local to_db="$3"

    docker exec -u 70 "$POSTGRES_SERVICE_NAME" pgm cp -f "$from_db" "${to_db}@${to_service}"
}

copy_filestore() {
    local from_service="$1"
    local from_db="$2"
    local to_service="$3"
    local to_db="$4"

    local src_path="${DATASTORE_PATH}/${from_service}/${FILESTORE_SUBPATH}/${from_db}"
    local dst_path="${DATASTORE_PATH}/${to_service}/${FILESTORE_SUBPATH}/${to_db}"

    sudo mkdir -p "$(dirname "$dst_path")"
    sudo rsync -a --delete "${src_path}/" "${dst_path}/"
    echo "Filestore ${from_service}/${from_db} copied to ${to_service}/${to_db}."
}

# Workaround: 0k dev-pack's compose script doesn't handle absolute paths correctly.
# It passes HOST_COMPOSE_YML_FILE to the container, which tries to open it directly
# instead of using the mounted path. Using a relative path from PROJECT_ROOT avoids this.
run_compose() {
    (cd "$PROJECT_ROOT" && compose -f ./config/compose.yml "$@")
}

exec_python_script_in_odoo_shell() {
    local service_name="$1"
    local db_name="$2"
    local python_script="$3"

    run_compose --debug run "$service_name" shell -d "$db_name" --no-http --stop-after-init < "$python_script"
}

# Classifies missing modules into 4 categories based on the known_changes.yaml
# files from each traversed version (from ORIGIN_VERSION+1 to FINAL_VERSION).
# The following global arrays are populated:
#   addons_obsolete      : modules that became obsolete
#   addons_core          : modules merged into Odoo Core
#   addons_renamed       : renamed modules (format "old_name -> new_name")
#   addons_truly_missing : modules that are genuinely missing
#
# Prerequisites: ORIGIN_VERSION and FINAL_VERSION must be exported.
classify_missing_addons() {
    local missing_addons_raw="$1"

    addons_obsolete=()
    addons_core=()
    addons_renamed=()
    addons_truly_missing=()

    # Convert the string into an array (one entry per line)
    local -a missing=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && missing+=("$line")
    done <<< "$missing_addons_raw"

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    # Build lookup tables from all known_changes.yaml files in traversed versions
    local -A known_obsolete=()
    local -A known_core=()
    local -A known_renamed=()

    local versions_path="${PROJECT_ROOT}/versions"
    local v
    for v in $(seq $((ORIGIN_VERSION + 1)) "$FINAL_VERSION"); do
        local yaml_file="${versions_path}/${v}.0/known_changes.yaml"
        [[ -f "$yaml_file" ]] || continue

        local mod
        while IFS= read -r mod; do
            [[ -n "$mod" && "$mod" != "null" ]] && known_obsolete["$mod"]=1
        done < <(yq '.obsolete[]?' "$yaml_file" 2>/dev/null)

        while IFS= read -r mod; do
            [[ -n "$mod" && "$mod" != "null" ]] && known_core["$mod"]=1
        done < <(yq '.merged_in_core[]?' "$yaml_file" 2>/dev/null)

        local count
        count=$(yq '.renamed | length' "$yaml_file" 2>/dev/null)
        if [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]; then
            local i
            for ((i = 0; i < count; i++)); do
                local old new
                old=$(yq ".renamed[$i].old" "$yaml_file" 2>/dev/null)
                new=$(yq ".renamed[$i].new" "$yaml_file" 2>/dev/null)
                [[ -n "$old" && "$old" != "null" ]] && known_renamed["$old"]="$new"
            done
        fi
    done

    # Classify each missing module
    local mod
    for mod in "${missing[@]}"; do
        if [[ -n "${known_obsolete[$mod]:-}" ]]; then
            addons_obsolete+=("$mod")
        elif [[ -n "${known_core[$mod]:-}" ]]; then
            addons_core+=("$mod")
        elif [[ -n "${known_renamed[$mod]:-}" ]]; then
            addons_renamed+=("${mod} -> ${known_renamed[$mod]}")
        else
            addons_truly_missing+=("$mod")
        fi
    done
}

export PROJECT_ROOT DATASTORE_PATH FILESTORE_SUBPATH
export -f log_info log_warn log_error log_step confirm_or_exit
export -f check_required_commands
export -f query_postgres_container copy_database copy_filestore run_compose exec_python_script_in_odoo_shell
export -f classify_missing_addons
