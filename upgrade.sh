#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

####################
# USAGE & ARGUMENTS
####################

usage() {
    cat <<EOF >&2
Usage: $0 <origin_version> <final_version> <db_name> <service_name>

Arguments:
    origin_version   Origin Odoo version number (e.g., 12 for version 12.0)
    final_version    Target Odoo version number (e.g., 16 for version 16.0)
    db_name          Name of the database to migrate
    service_name     Name of the origin Odoo service (docker compose service)

Example:
    $0 14 16 elabore_20241208 odoo14
EOF
    exit 1
}

if [[ $# -lt 4 ]]; then
    log_error "Missing arguments. Expected 4, got $#."
    usage
fi

check_required_commands

readonly ORIGIN_VERSION="$1"
readonly FINAL_VERSION="$2"
readonly ORIGIN_DB_NAME="$3"
readonly ORIGIN_SERVICE_NAME="$4"

readonly COPY_DB_NAME="ou${ORIGIN_VERSION}"
export FINALE_DB_NAME="ou${FINAL_VERSION}"
readonly FINALE_DB_NAME
readonly FINALE_SERVICE_NAME="${FINALE_DB_NAME}"

readarray -t postgres_containers < <(docker ps --format '{{.Names}}' | grep postgres || true)

if [[ ${#postgres_containers[@]} -eq 0 ]]; then
    log_error "No running PostgreSQL container found. Please start a PostgreSQL container and try again."
    exit 1
elif [[ ${#postgres_containers[@]} -gt 1 ]]; then
    log_error "Multiple PostgreSQL containers found:"
    printf '  %s\n' "${postgres_containers[@]}" >&2
    log_error "Please ensure only one PostgreSQL container is running."
    exit 1
fi

export POSTGRES_SERVICE_NAME="${postgres_containers[0]}"
readonly POSTGRES_SERVICE_NAME

log_step "INPUT PARAMETERS"
log_info "Origin version .......... $ORIGIN_VERSION"
log_info "Final version ........... $FINAL_VERSION"
log_info "Origin DB name ........... $ORIGIN_DB_NAME"
log_info "Origin service name ..... $ORIGIN_SERVICE_NAME"

log_step "COMPUTED GLOBAL VARIABLES"
log_info "Copy DB name ............. $COPY_DB_NAME"
log_info "Finale DB name ........... $FINALE_DB_NAME"
log_info "Finale service name ...... $FINALE_SERVICE_NAME"
log_info "Postgres service name .... $POSTGRES_SERVICE_NAME"



log_step "CHECKS ALL NEEDED COMPONENTS ARE AVAILABLE"

db_exists=$(docker exec -it -u 70 "$POSTGRES_SERVICE_NAME" psql -tc "SELECT 1 FROM pg_database WHERE datname = '$ORIGIN_DB_NAME'" | tr -d '[:space:]')
if [[ "$db_exists" ]]; then
    log_info "Database '$ORIGIN_DB_NAME' found."
else
    log_error "Database '$ORIGIN_DB_NAME' not found in the local postgres service. Please add it and restart the upgrade process."
    exit 1
fi

filestore_path="${DATASTORE_PATH}/${ORIGIN_SERVICE_NAME}/${FILESTORE_SUBPATH}/${ORIGIN_DB_NAME}"
if [[ -d "$filestore_path" ]]; then
    log_info "Filestore '$filestore_path' found."
else
    log_error "Filestore '$filestore_path' not found, please add it and restart the upgrade process."
    exit 1
fi

log_step "LAUNCH VIRGIN ODOO IN FINAL VERSION"

if docker exec -u 70 "$POSTGRES_SERVICE_NAME" pgm ls | grep -q "$FINALE_SERVICE_NAME"; then
    log_info "Removing existing finale database and filestore..."
    docker exec -u 70 "$POSTGRES_SERVICE_NAME" pgm rm -f "$FINALE_SERVICE_NAME"
    sudo rm -rf "${DATASTORE_PATH}/${FINALE_SERVICE_NAME}/${FILESTORE_SUBPATH}/${FINALE_SERVICE_NAME}"
fi

compose --debug run "$FINALE_SERVICE_NAME" -i base --stop-after-init --no-http

log_info "Model database in final Odoo version created."

log_step "COPY ORIGINAL COMPONENTS"

copy_database "$ORIGIN_DB_NAME" "$COPY_DB_NAME" "$COPY_DB_NAME"
log_info "Original database copied to ${COPY_DB_NAME}@${COPY_DB_NAME}."

copy_filestore "$ORIGIN_SERVICE_NAME" "$ORIGIN_DB_NAME" "$COPY_DB_NAME" "$COPY_DB_NAME"
log_info "Original filestore copied."


log_step "PATH OF MIGRATION"

declare -a versions
nb_migrations=$((FINAL_VERSION - ORIGIN_VERSION))

for ((i = 0; i < nb_migrations; i++)); do
    versions[i]=$((ORIGIN_VERSION + 1 + i))
done
log_info "Migration path is ${versions[*]}"


log_step "DATABASE PREPARATION"

./prepare_db.sh "$COPY_DB_NAME" "$COPY_DB_NAME" "$FINALE_DB_MODEL_NAME" "$FINALE_SERVICE_NAME"


log_step "UPGRADE PROCESS"

for version in "${versions[@]}"; do
    log_info "START UPGRADE TO ${version}.0"

    cd "${version}.0"

    ./pre_upgrade.sh
    ./upgrade.sh
    ./post_upgrade.sh

    cd ..
    log_info "END UPGRADE TO ${version}.0"
done

log_step "POST-UPGRADE PROCESSES"

./finalize_db.sh "$FINALE_DB_NAME" "$FINALE_SERVICE_NAME"

log_step "UPGRADE PROCESS ENDED WITH SUCCESS"
