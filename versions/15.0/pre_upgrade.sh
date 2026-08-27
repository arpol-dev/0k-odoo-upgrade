#!/bin/bash
set -euo pipefail

echo "Prepare migration to 15.0..."

# Copy database
copy_database ou14 ou15 ou15 || exit 1

# Execute SQL pre-migration commands
PRE_MIGRATE_SQL=$(cat <<'EOF'
/* Delete add-on 'account_usability' as its name has changed and another 'account_usability' add-on is created  */
DELETE FROM ir_module_module WHERE name = 'account_usability';
DELETE FROM ir_model_data WHERE module = 'base' AND name = 'module_account_usability';
/* auto_backup (OCA/server-tools) imports pysftp, whose paramiko DSSKey import
   fails in the 15.0 migration image, so the module cannot be loaded at all.
   Mark it 'uninstalled' (a valid ir.module.module state, unlike 'to_remove')
   so the registry skips it; its cron/config rows are left untouched. */
UPDATE ir_module_module SET state = 'uninstalled' WHERE name = 'auto_backup' AND state = 'installed';
EOF
)
echo "SQL command = $PRE_MIGRATE_SQL"
query_postgres_container "$PRE_MIGRATE_SQL" ou15 || exit 1

# Copy filestores
copy_filestore ou14 ou14 ou15 ou15 || exit 1

echo "Ready for migration to 15.0!"
