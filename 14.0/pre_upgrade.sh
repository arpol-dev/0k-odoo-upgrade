#!/bin/bash
set -euo pipefail

echo "Prepare migration to 14.0..."

# Copy database
copy_database ou13 ou14 ou14 || exit 1

# Execute SQL pre-migration commands
PRE_MIGRATE_SQL=""
query_postgres_container "$PRE_MIGRATE_SQL" ou14 || exit 1

# Copy filestores
copy_filestore ou13 ou13 ou14 ou14 || exit 1

echo "Ready for migration to 14.0!"
