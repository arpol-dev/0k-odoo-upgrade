#!/bin/bash
set -euo pipefail

DB_NAME="$1"
ODOO_SERVICE="$2"

echo "Running SQL cleanup..."
CLEANUP_SQL=$(cat <<'EOF'
-- Drop sequences that prevent Odoo from starting.
-- These sequences are recreated by Odoo on startup but stale values
-- from the old version can cause conflicts.
DROP SEQUENCE IF EXISTS base_registry_signaling;
DROP SEQUENCE IF EXISTS base_cache_signaling;

-- Reset website templates to their original state.
-- Views with arch_fs (file source) that have been customized (arch_db not null)
-- are reset to use the file version, EXCEPT for actual website pages which
-- contain user content that must be preserved.
UPDATE ir_ui_view
SET arch_db = NULL
WHERE arch_fs IS NOT NULL
  AND arch_fs LIKE 'website/%'
  AND arch_db IS NOT NULL
  AND id NOT IN (SELECT view_id FROM website_page);

-- Purge compiled frontend assets (CSS/JS bundles).
-- These cached files reference old asset versions and must be regenerated
-- by Odoo after migration to avoid broken stylesheets and scripts.
DELETE FROM ir_attachment
WHERE name LIKE '/web/assets/%'
   OR name LIKE '%.assets_%'
   OR (res_model = 'ir.ui.view' AND mimetype = 'text/css');
EOF
)
query_postgres_container "$CLEANUP_SQL" "$DB_NAME"

PYTHON_SCRIPT=post_migration_fix_duplicated_views.py
echo "Remove duplicated views with script $PYTHON_SCRIPT ..."
exec_python_script_in_odoo_shell "$DB_NAME" "$DB_NAME" "$PYTHON_SCRIPT"

# Uninstall obsolete add-ons
PYTHON_SCRIPT=post_migration_cleanup_obsolete_modules.py
echo "Uninstall obsolete add-ons with script $PYTHON_SCRIPT ..."
exec_python_script_in_odoo_shell "$DB_NAME" "$DB_NAME" "$PYTHON_SCRIPT" || exit 1

# Give back the right to user to access to the tables
# docker exec -u 70 "$DB_CONTAINER_NAME" pgm chown "$FINALE_SERVICE_NAME" "$DB_NAME"


# Launch Odoo with database in finale version to run all updates
compose --debug run "$ODOO_SERVICE" -u all --log-level=debug --stop-after-init --no-http
