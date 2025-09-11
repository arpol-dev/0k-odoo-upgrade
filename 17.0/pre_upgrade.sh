#!/bin/bash

echo "Prepare migration to 17.0..."

# Copy database
copy_database ou16 ou17 ou17 || exit 1

# Execute SQL pre-migration commands
PRE_MIGRATE_SQL=""
echo "SQL command = $PRE_MIGRATE_SQL"
query_postgres_container "$PRE_MIGRATE_SQL" ou17 || exit 1

# Copy filestores
copy_filestore ou16 ou16 ou17 ou17 || exit 1

echo "Ready for migration to 17.0!"
