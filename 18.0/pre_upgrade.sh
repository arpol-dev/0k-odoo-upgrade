#!/bin/bash

echo "Prepare migration to 18.0..."

# Copy database
copy_database ou17 ou18 ou18 || exit 1

# Execute SQL pre-migration commands
PRE_MIGRATE_SQL=""
echo "SQL command = $PRE_MIGRATE_SQL"
query_postgres_container "$PRE_MIGRATE_SQL" ou18 || exit 1

# Copy filestores
copy_filestore ou17 ou17 ou18 ou18 || exit 1

echo "Ready for migration to 18.0!"
