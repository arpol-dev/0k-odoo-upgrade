#!/bin/bash
set -euo pipefail

echo "Prepare migration to 16.0..."

# Copy database
copy_database ou15 ou16 ou16 || exit 1

# Execute SQL pre-migration commands
PRE_MIGRATE_SQL=""
echo "SQL command = $PRE_MIGRATE_SQL"
query_postgres_container "$PRE_MIGRATE_SQL" ou16 || exit 1

# Copy filestores
copy_filestore ou15 ou15 ou16 ou16 || exit 1

echo "Ready for migration to 16.0!"
