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

# ────────────────────────────────────────────────────────────
# Purge ir_logging (Python logger messages, no business value).
# ────────────────────────────────────────────────────────────
echo "Purging ir_logging..."
query_postgres_container "TRUNCATE ir_logging;" "$DB_NAME"

# ────────────────────────────────────────────────────────────
# Fix orphan ir_filters pointing to deleted ir_actions
#
# During OpenUpgrade migrations, ir_actions records can be deleted and
# recreated with new ids, while ir_filters.action_id (custom user filters)
# still points to the old, now-missing action. When a user opens the custom
# filters list, Odoo tries to resolve the display_name of the many2one
# action_id and raises "Record does not exist or has been deleted
# (ir.actions.actions(<id>,))". We detach such filters (set action_id = NULL),
# which keeps the filter usable and only drops the broken action link.
# ────────────────────────────────────────────────────────────
FIX_ORPHAN_FILTERS_SQL=$(cat <<'EOF'
DO $$
DECLARE
    orphan_count INTEGER;
    remaining INTEGER;
BEGIN
    SELECT COUNT(*) INTO orphan_count
    FROM ir_filters f
    LEFT JOIN ir_actions a ON a.id = f.action_id
    WHERE f.action_id IS NOT NULL AND a.id IS NULL;

    IF orphan_count > 0 THEN
        UPDATE ir_filters f
        SET action_id = NULL
        FROM (
            SELECT f2.id
            FROM ir_filters f2
            LEFT JOIN ir_actions a ON a.id = f2.action_id
            WHERE f2.action_id IS NOT NULL AND a.id IS NULL
        ) orphans
        WHERE f.id = orphans.id;
        RAISE NOTICE 'Detached % orphan ir_filters pointing to deleted ir_actions', orphan_count;
    ELSE
        RAISE NOTICE 'OK: no orphan ir_filters to fix';
    END IF;

    -- Verification
    SELECT COUNT(*) INTO remaining
    FROM ir_filters f
    LEFT JOIN ir_actions a ON a.id = f.action_id
    WHERE f.action_id IS NOT NULL AND a.id IS NULL;

    IF remaining > 0 THEN
        RAISE WARNING 'Still % orphan ir_filters remaining after fix', remaining;
    END IF;
END $$;
EOF
)
echo "Fixing orphan ir_filters pointing to deleted ir_actions..."
query_postgres_container "$FIX_ORPHAN_FILTERS_SQL" "$DB_NAME"

# Reset modules still marked as 'to upgrade' before launching the Odoo shell
# scripts below. Loading the registry in `odoo shell` re-triggers the upgrade
# of these modules, which can fail on broken views (e.g. website_sale
# TypeError). The controlled `-u all` at the end of this script performs the
# real update afterwards. We deliberately do NOT touch 'to install' modules:
# forcing them to 'installed' would skip their install scripts entirely.
#
# Uncomment the SELECT below to trace which modules were pending upgrade
# before we neutralize their state (useful if the `-u all` above is removed).
# query_postgres_container "
# SELECT name FROM ir_module_module WHERE state = 'to upgrade' ORDER BY name;
# " "$DB_NAME" || true
query_postgres_container "
UPDATE ir_module_module
SET state = 'installed'
WHERE state = 'to upgrade';
" "$DB_NAME" || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYTHON_SCRIPT="${SCRIPT_DIR}/lib/python/fix_duplicated_views.py"
echo "Remove duplicated views with script $PYTHON_SCRIPT ..."
exec_python_script_in_odoo_shell "$DB_NAME" "$DB_NAME" "$PYTHON_SCRIPT"

PYTHON_SCRIPT="${SCRIPT_DIR}/lib/python/cleanup_modules.py"
echo "Uninstall obsolete add-ons with script $PYTHON_SCRIPT ..."
exec_python_script_in_odoo_shell "$DB_NAME" "$DB_NAME" "$PYTHON_SCRIPT"

# ────────────────────────────────────────────────────────────
# Regenerate POS inalterability hashes if needed
# ────────────────────────────────────────────────────────────
HASHES_NEEDED=$(query_postgres_container "
    SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'pos_order'
" "$DB_NAME")
if [[ "$HASHES_NEEDED" =~ ^[0-9]+$ && "$HASHES_NEEDED" -gt 0 ]]; then
    HASHES_NEEDED=$(query_postgres_container "
        SELECT COUNT(*)
        FROM pos_order po
        JOIN res_company rc ON rc.id = po.company_id
        WHERE po.state IN ('paid', 'done', 'invoiced')
          AND rc.l10n_fr_pos_cert_sequence_id IS NOT NULL
          AND (po.l10n_fr_hash IS NULL OR po.l10n_fr_secure_sequence_number IS NULL)
    " "$DB_NAME")
fi

if [[ "$HASHES_NEEDED" =~ ^[0-9]+$ && "$HASHES_NEEDED" -gt 0 ]]; then
    echo ""
    echo "Found $HASHES_NEEDED pos.order(s) with missing inalterability hash or sequence number."
    echo "Regenerating all POS hashes..."
    PYTHON_SCRIPT="${SCRIPT_DIR}/lib/python/regenerate_pos_hashes.py"
    exec_python_script_in_odoo_shell "$DB_NAME" "$DB_NAME" "$PYTHON_SCRIPT"
    echo "POS hash regeneration completed."
else
    echo "No missing POS hashes detected."
fi

# Give back the right to user to access to the tables
# docker exec -u 70 "$DB_CONTAINER_NAME" pgm chown "$FINALE_SERVICE_NAME" "$DB_NAME"


# Launch Odoo with database in finale version to run all updates
run_compose --debug run "$ODOO_SERVICE" -u all --log-level=debug --stop-after-init --no-http --load=base,web,openupgrade_framework

echo ""
echo "Running post-migration view validation..."
if exec_python_script_in_odoo_shell "$DB_NAME" "$DB_NAME" "${SCRIPT_DIR}/lib/python/validate_views.py"; then
    echo "View validation passed."
else
    echo "WARNING: View validation found issues. Run scripts/validate_migration.sh for the full report."
fi
