#!/bin/bash
set -euo pipefail

echo "Prepare migration to 13.0..."

# Copy database
copy_database ou12 ou13 ou13 || exit 1

# Execute SQL pre-migration commands
PRE_MIGRATE_SQL=$(cat <<'EOF'
/* Add analytic_policy column as openupgrade script is waiting for it whereas it doesn't existe since v12.  */
ALTER TABLE public.account_account_type ADD analytic_policy varchar NULL;

/* The model in missing on some website_sale data */
UPDATE ir_model_data SET model = 'ir.ui.view' WHERE module = 'website_sale' AND name = 'recommended_products';
UPDATE ir_model_data SET model = 'ir.ui.view' WHERE module = 'website_sale' AND name = 'product_comment';
EOF
)
query_postgres_container "$PRE_MIGRATE_SQL" ou13 || exit 1

# Copy filestores
copy_filestore ou12 ou12 ou13 ou13 || exit 1

echo "Ready for migration to 13.0!"
