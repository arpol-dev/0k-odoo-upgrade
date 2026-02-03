#!/bin/bash
set -euo pipefail

ODOO_SERVICE="$1"
DB_NAME="$2"
DB_FINALE_MODEL="$3"
DB_FINALE_SERVICE="$4"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Start database preparation"

# Check POSTGRES container is running
if ! docker ps | grep -q "$POSTGRES_SERVICE_NAME"; then
    printf "Docker container %s is not running.\n" "$POSTGRES_SERVICE_NAME" >&2
    exit 1
fi

EXT_EXISTS=$(query_postgres_container "SELECT 1 FROM pg_extension WHERE extname = 'dblink'" "$DB_NAME") || exit 1
if [[ "$EXT_EXISTS" != "1" ]]; then
    query_postgres_container "CREATE EXTENSION dblink;" "$DB_NAME" || exit 1
fi

# Neutralize the database
SQL_NEUTRALIZE=$(cat <<'EOF'
/* Archive all the mail servers */
UPDATE fetchmail_server SET active = false;
UPDATE ir_mail_server SET active = false;

/* Archive all the cron */
ALTER TABLE ir_cron ADD COLUMN IF NOT EXISTS active_bkp BOOLEAN;
UPDATE ir_cron SET active_bkp = active;
UPDATE ir_cron SET active = False;
EOF
	      )
echo "Neutralize base..."
query_postgres_container "$SQL_NEUTRALIZE" "$DB_NAME" || exit 1
echo "Base neutralized..."

#######################################
## List add-ons not in final version ##
#######################################

SQL_MISSING_ADDONS=$(cat <<EOF
SELECT module_origin.name
FROM ir_module_module module_origin
LEFT JOIN (
    SELECT *
    FROM dblink('dbname=${FINALE_DB_NAME}','SELECT name, shortdesc, author FROM ir_module_module')
    AS tb2(name text, shortdesc text, author text)
) AS module_dest ON module_dest.name = module_origin.name
WHERE (module_dest.name IS NULL)
  AND (module_origin.state = 'installed')
  AND (module_origin.author NOT IN ('Odoo S.A.'))
ORDER BY module_origin.name;
EOF
)
echo "Retrieve missing addons..."
missing_addons=$(query_postgres_container "$SQL_MISSING_ADDONS" "$DB_NAME")

log_step "ADD-ONS CHECK"
echo "Installed add-ons not available in final Odoo version:"
echo "$missing_addons"
confirm_or_exit "Do you accept to migrate with these add-ons still installed?"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_SCRIPT="${SCRIPT_DIR}/lib/python/check_views.py"
echo "Check views with script $PYTHON_SCRIPT ..."
exec_python_script_in_odoo_shell "$DB_NAME" "$DB_NAME" "$PYTHON_SCRIPT"

confirm_or_exit "Do you accept to migrate with the current views state?"

echo "Database successfully prepared!"
