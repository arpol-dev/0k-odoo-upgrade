#!/bin/bash
set -euo pipefail

echo "Prepare migration to 20.0..."

# Copy database
copy_database ou19 ou20 ou20 || exit 1


# Execute SQL pre-migration commands
PRE_MIGRATE_SQL=$(cat <<'EOF'
EOF
)
echo "SQL command = $PRE_MIGRATE_SQL"
query_postgres_container "$PRE_MIGRATE_SQL" ou20 || exit 1

# Copy filestores
copy_filestore ou19 ou19 ou20 ou20 || exit 1

echo "Ready for migration to 20.0!"
