#!/bin/bash
#
# Post-Migration Validation Script for Odoo
# Validates views, XPath expressions, and QWeb templates.
#
# View validation runs automatically at the end of the upgrade process.
# This script can also be run manually for the full report with JSON output.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "${PROJECT_ROOT}/lib/common.sh"

####################
# CONFIGURATION
####################

REPORT_DIR="/tmp"
REPORT_TIMESTAMP=$(date +%Y%m%d_%H%M%S)
VIEWS_REPORT=""
VIEWS_REPORT_MARKER="___VALIDATE_VIEWS_JSON___"

####################
# USAGE
####################

usage() {
    cat <<EOF
Usage: $0 <db_name> <service_name>

Post-migration view validation for Odoo databases.

Validates:
    - Inherited view combination (parent + child)
    - XPath expressions find their targets
    - QWeb template syntax
    - Field references point to existing fields
    - Odoo native view validation

Arguments:
    db_name         Name of the database to validate
    service_name    Docker compose service name (e.g., odoo17, ou17)

Examples:
    $0 ou17 odoo17
    $0 elabore_migrated odoo18

Notes:
    - Runs via Odoo shell (no HTTP server needed)
    - Report is written to /tmp/validation_views_<db>_<timestamp>.json
EOF
    exit 1
}

####################
# ARGUMENT PARSING
####################

DB_NAME=""
SERVICE_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            ;;
        *)
            if [[ -z "$DB_NAME" ]]; then
                DB_NAME="$1"
                shift
            elif [[ -z "$SERVICE_NAME" ]]; then
                SERVICE_NAME="$1"
                shift
            else
                log_error "Unexpected argument: $1"
                usage
            fi
            ;;
    esac
done

if [[ -z "$DB_NAME" ]]; then
    log_error "Missing database name"
    usage
fi

if [[ -z "$SERVICE_NAME" ]]; then
    log_error "Missing service name"
    usage
fi

####################
# MAIN
####################

log_step "POST-MIGRATION VIEW VALIDATION"
log_info "Database: $DB_NAME"
log_info "Service: $SERVICE_NAME"

PYTHON_SCRIPT="${PROJECT_ROOT}/lib/python/validate_views.py"

if [[ ! -f "$PYTHON_SCRIPT" ]]; then
    log_error "Validation script not found: $PYTHON_SCRIPT"
    exit 1
fi

VIEWS_REPORT="${REPORT_DIR}/validation_views_${DB_NAME}_${REPORT_TIMESTAMP}.json"

log_info "Running view validation in Odoo shell..."
echo ""

RESULT=0
RAW_OUTPUT=$(run_compose run --rm -e VALIDATE_VIEWS_REPORT=1 "$SERVICE_NAME" shell -d "$DB_NAME" --no-http --stop-after-init < "$PYTHON_SCRIPT") || RESULT=$?

echo "$RAW_OUTPUT" | sed "/${VIEWS_REPORT_MARKER}/,/${VIEWS_REPORT_MARKER}/d"

echo "$RAW_OUTPUT" | sed -n "/${VIEWS_REPORT_MARKER}/,/${VIEWS_REPORT_MARKER}/p" | grep -v "$VIEWS_REPORT_MARKER" > "$VIEWS_REPORT"

echo ""
log_step "VALIDATION COMPLETE"

if [[ -s "$VIEWS_REPORT" ]]; then
    log_info "Report: $VIEWS_REPORT"
else
    log_warn "Could not extract validation report from output"
    VIEWS_REPORT=""
fi

if [[ $RESULT -eq 0 ]]; then
    log_info "All validations passed!"
else
    log_error "Some validations failed. Check the output above for details."
fi

exit $RESULT
