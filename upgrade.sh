#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

readonly LOG_FILE="${SCRIPT_DIR}/migration.log"
if [[ -z "${_MIGRATION_LOGGING:-}" ]]; then
    rm -f "$LOG_FILE"
    export _MIGRATION_LOGGING=1
    exec script -q -c "$(printf '%q ' "$0" "$@")" "$LOG_FILE"
fi

####################
# USAGE & ARGUMENTS
####################

usage() {
    cat <<EOF >&2
Usage: $0 <origin_version> <final_version> <db_name> <service_name> [--resume-from|-r <version>]

Arguments:
    origin_version   Origin Odoo version number (e.g., 12 for version 12.0)
    final_version    Target Odoo version number (e.g., 16 for version 16.0)
    db_name          Name of the database to migrate
    service_name     Name of the origin Odoo service (docker compose service)

Options:
    --resume-from, -r <version>
                     Resume migration from an already-migrated intermediate
                     database (e.g., ou15). Skips the initial DB copy and
                     prepare_db.sh phases. The intermediate DB must exist.

Examples:
    $0 14 18 elabore_20241208 odoo14
    $0 14 18 elabore_20241208 odoo14 --resume-from 15
    $0 14 18 elabore_20241208 odoo14 -r 15
EOF
    exit 1
}

if [[ $# -lt 4 ]]; then
    log_error "Missing arguments. Expected at least 4, got $#."
    usage
fi

check_required_commands

export ORIGIN_VERSION="$1"
readonly ORIGIN_VERSION
export FINAL_VERSION="$2"
readonly FINAL_VERSION
readonly ORIGIN_DB_NAME="$3"
readonly ORIGIN_SERVICE_NAME="$4"

# Parse optional --resume-from / -r flag
RESUME_FROM_VERSION=""
shift 4
while [[ $# -gt 0 ]]; do
    case "$1" in
        --resume-from|-r)
            if [[ $# -lt 2 ]]; then
                log_error "Option '$1' requires a version number argument."
                usage
            fi
            RESUME_FROM_VERSION="$2"
            shift 2
            ;;
        *)
            log_error "Unknown option: '$1'"
            usage
            ;;
    esac
done
readonly RESUME_FROM_VERSION

readonly COPY_DB_NAME="ou${ORIGIN_VERSION}"
export FINALE_DB_NAME="ou${FINAL_VERSION}"
readonly FINALE_DB_NAME
readonly FINALE_SERVICE_NAME="${FINALE_DB_NAME}"

# Validate --resume-from value if provided
if [[ -n "$RESUME_FROM_VERSION" ]]; then
    if ! [[ "$RESUME_FROM_VERSION" =~ ^[0-9]+$ ]]; then
        log_error "--resume-from value must be a numeric version number (got: '$RESUME_FROM_VERSION')."
        exit 1
    fi
    if [[ "$RESUME_FROM_VERSION" -le "$ORIGIN_VERSION" ]]; then
        log_error "--resume-from ($RESUME_FROM_VERSION) must be strictly greater than origin version ($ORIGIN_VERSION)."
        log_error "To start a fresh migration, run without --resume-from."
        exit 1
    fi
    if [[ "$RESUME_FROM_VERSION" -ge "$FINAL_VERSION" ]]; then
        log_error "--resume-from ($RESUME_FROM_VERSION) must be strictly less than final version ($FINAL_VERSION)."
        log_error "Nothing to migrate: checkpoint is at or beyond the target version."
        exit 1
    fi
fi

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
log_info "Origin DB name .......... $ORIGIN_DB_NAME"
log_info "Origin service name ..... $ORIGIN_SERVICE_NAME"
if [[ -n "$RESUME_FROM_VERSION" ]]; then
    log_info "Resume from version ..... $RESUME_FROM_VERSION (ou${RESUME_FROM_VERSION})"
else
    log_info "Resume from version ..... none (full migration)"
fi

log_step "COMPUTED GLOBAL VARIABLES"
log_info "Copy DB name ............. $COPY_DB_NAME"
log_info "Finale DB name ........... $FINALE_DB_NAME"
log_info "Finale service name ...... $FINALE_SERVICE_NAME"
log_info "Postgres service name .... $POSTGRES_SERVICE_NAME"



log_step "CHECKS ALL NEEDED COMPONENTS ARE AVAILABLE"

if [[ -n "$RESUME_FROM_VERSION" ]]; then
    readonly RESUME_DB_NAME="ou${RESUME_FROM_VERSION}"

    resume_db_exists=$(docker exec -u 70 "$POSTGRES_SERVICE_NAME" psql -tc "SELECT 1 FROM pg_database WHERE datname = '${RESUME_DB_NAME}'" | tr -d '[:space:]')
    if [[ "$resume_db_exists" ]]; then
        log_info "Checkpoint database '${RESUME_DB_NAME}' found."
    else
        log_error "Checkpoint database '${RESUME_DB_NAME}' not found in the local postgres service."
        log_error "Ensure the migration up to version ${RESUME_FROM_VERSION} completed successfully before resuming."
        exit 1
    fi

    resume_filestore_path="${DATASTORE_PATH}/${RESUME_DB_NAME}/${FILESTORE_SUBPATH}/${RESUME_DB_NAME}"
    if [[ -d "$resume_filestore_path" ]]; then
        log_info "Checkpoint filestore '${resume_filestore_path}' found."
    else
        log_error "Checkpoint filestore '${resume_filestore_path}' not found."
        log_error "Ensure the filestore for '${RESUME_DB_NAME}' is intact before resuming."
        exit 1
    fi
else
    db_exists=$(docker exec -u 70 "$POSTGRES_SERVICE_NAME" psql -tc "SELECT 1 FROM pg_database WHERE datname = '$ORIGIN_DB_NAME'" | tr -d '[:space:]')
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
fi

log_step "LAUNCH VIRGIN ODOO IN FINAL VERSION"

if docker exec -u 70 "$POSTGRES_SERVICE_NAME" pgm ls | grep "$FINALE_SERVICE_NAME"; then
    log_info "Removing existing finale database and filestore..."
    docker exec -u 70 "$POSTGRES_SERVICE_NAME" pgm rm -f "$FINALE_SERVICE_NAME"
    sudo rm -rf "${DATASTORE_PATH}/${FINALE_SERVICE_NAME}/${FILESTORE_SUBPATH}/${FINALE_SERVICE_NAME}"
fi

run_compose --debug run "$FINALE_SERVICE_NAME" -i base --stop-after-init --no-http

log_info "Model database in final Odoo version created."

if [[ -z "$RESUME_FROM_VERSION" ]]; then
    log_step "COPY ORIGINAL COMPONENTS"

    copy_database "$ORIGIN_DB_NAME" "$COPY_DB_NAME" "$COPY_DB_NAME"
    log_info "Original database copied to ${COPY_DB_NAME}@${COPY_DB_NAME}."

    copy_filestore "$ORIGIN_SERVICE_NAME" "$ORIGIN_DB_NAME" "$COPY_DB_NAME" "$COPY_DB_NAME"
    log_info "Original filestore copied."
else
    log_step "COPY ORIGINAL COMPONENTS — SKIPPED (resuming from checkpoint ou${RESUME_FROM_VERSION})"
fi


log_step "PATH OF MIGRATION"

if [[ -n "$RESUME_FROM_VERSION" ]]; then
    readarray -t versions < <(seq $((RESUME_FROM_VERSION + 1)) "$FINAL_VERSION")
    log_info "Resuming migration from ou${RESUME_FROM_VERSION} — path is ${versions[*]}"
else
    readarray -t versions < <(seq $((ORIGIN_VERSION + 1)) "$FINAL_VERSION")
    log_info "Migration path is ${versions[*]}"
fi


if [[ -z "$RESUME_FROM_VERSION" ]]; then
    log_step "DATABASE PREPARATION"
    "${SCRIPT_DIR}/scripts/prepare_db.sh" "$COPY_DB_NAME" "$COPY_DB_NAME" "$FINALE_DB_NAME" "$FINALE_SERVICE_NAME"
else
    log_step "DATABASE PREPARATION — SKIPPED (resuming from checkpoint ou${RESUME_FROM_VERSION})"
fi


log_step "UPGRADE PROCESS"

for version in "${versions[@]}"; do
    log_info "START UPGRADE TO ${version}.0"

    "${SCRIPT_DIR}/versions/${version}.0/pre_upgrade.sh"
    "${SCRIPT_DIR}/versions/${version}.0/upgrade.sh"
    "${SCRIPT_DIR}/versions/${version}.0/post_upgrade.sh"

    log_info "END UPGRADE TO ${version}.0"
done

log_step "POST-UPGRADE PROCESSES"

"${SCRIPT_DIR}/scripts/finalize_db.sh" "$FINALE_DB_NAME" "$FINALE_SERVICE_NAME"

log_step "UPGRADE PROCESS ENDED WITH SUCCESS"
log_info "Full logs available at: ${LOG_FILE}"
