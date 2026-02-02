#!/bin/bash
#
# Common functions for Odoo migration scripts
# Source this file from other scripts: source "$(dirname "$0")/lib/common.sh"
#

set -euo pipefail

readonly DATASTORE_PATH="/srv/datastore/data"
readonly FILESTORE_SUBPATH="var/lib/odoo/filestore"

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

    sudo mkdir -p "$dst_path"
    sudo rm -rf "$dst_path"
    sudo cp -a "$src_path" "$dst_path"
    echo "Filestore ${from_service}/${from_db} copied to ${to_service}/${to_db}."
}

exec_python_script_in_odoo_shell() {
    local service_name="$1"
    local db_name="$2"
    local python_script="$3"

    compose --debug run "$service_name" shell -d "$db_name" --no-http --stop-after-init < "$python_script"
}

export DATASTORE_PATH FILESTORE_SUBPATH
export -f query_postgres_container copy_database copy_filestore exec_python_script_in_odoo_shell
