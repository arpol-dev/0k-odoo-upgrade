#!/bin/bash
#
# Common functions for Odoo migration scripts
# Source this file from other scripts: source "$(dirname "$0")/lib/common.sh"
#

set -euo pipefail

readonly DATASTORE_PATH="/srv/datastore/data"
readonly FILESTORE_SUBPATH="var/lib/odoo/filestore"

check_required_commands() {
    local missing=()
    for cmd in docker compose sudo rsync; do
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

exec_python_script_in_odoo_shell() {
    local service_name="$1"
    local db_name="$2"
    local python_script="$3"

    compose --debug run "$service_name" shell -d "$db_name" --no-http --stop-after-init < "$python_script"
}

export DATASTORE_PATH FILESTORE_SUBPATH
export -f log_info log_warn log_error log_step confirm_or_exit
export -f check_required_commands
export -f query_postgres_container copy_database copy_filestore exec_python_script_in_odoo_shell
