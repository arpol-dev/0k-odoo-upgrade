#!/bin/bash
set -euo pipefail

echo "Prepare migration to 18.0..."

# Copy database
copy_database ou17 ou18 ou18 || exit 1

# ============================================================================
# BANK-PAYMENT -> BANK-PAYMENT-ALTERNATIVE MODULE RENAMING
# Migration from OCA/bank-payment to OCA/bank-payment-alternative
# Source PR: https://github.com/OCA/bank-payment-alternative/pull/42
#
# This renaming MUST be done BEFORE OpenUpgrade runs, so that the migration
# scripts in the new modules (account_payment_base_oca, account_payment_batch_oca)
# can properly migrate the data.
#
# Only executed if account_payment_mode module was installed before migration.
# ============================================================================

# Check if account_payment_mode module is installed
BANK_PAYMENT_INSTALLED=$(query_postgres_container "SELECT COUNT(*) FROM ir_module_module WHERE name = 'account_payment_mode' AND state = 'installed';" ou18 2>/dev/null | grep -E '^\s*[0-9]+' | tr -d ' ' || echo "0")

if [ "$BANK_PAYMENT_INSTALLED" -gt 0 ]; then
    echo "Module account_payment_mode is installed, proceeding with bank-payment migration..."

    BANK_PAYMENT_RENAME_SQL=$(cat <<'EOF'
DO $$
DECLARE
    renamed_modules TEXT[][] := ARRAY[
        ['account_payment_mode', 'account_payment_base_oca'],
        ['account_banking_pain_base', 'account_payment_sepa_base'],
        ['account_banking_sepa_credit_transfer', 'account_payment_sepa_credit_transfer'],
        ['account_payment_order', 'account_payment_batch_oca']
    ];
    merged_modules TEXT[][] := ARRAY[
        ['account_payment_partner', 'account_payment_base_oca']
    ];
    old_name TEXT;
    new_name TEXT;
    old_module_id INTEGER;
    deleted_count INTEGER;
BEGIN
    FOR i IN 1..array_length(renamed_modules, 1) LOOP
        old_name := renamed_modules[i][1];
        new_name := renamed_modules[i][2];

        SELECT id INTO old_module_id FROM ir_module_module WHERE name = old_name;
        IF old_module_id IS NOT NULL THEN
            RAISE NOTICE 'Renaming module: % -> %', old_name, new_name;
            UPDATE ir_module_module SET name = new_name WHERE name = old_name;
            UPDATE ir_model_data SET module = new_name WHERE module = old_name;
            UPDATE ir_module_module_dependency SET name = new_name WHERE name = old_name;
        END IF;
    END LOOP;

    FOR i IN 1..array_length(merged_modules, 1) LOOP
        old_name := merged_modules[i][1];
        new_name := merged_modules[i][2];

        SELECT id INTO old_module_id FROM ir_module_module WHERE name = old_name;
        IF old_module_id IS NOT NULL THEN
            RAISE NOTICE 'Merging module: % -> %', old_name, new_name;

            DELETE FROM ir_model_data
            WHERE module = old_name
            AND name IN (SELECT name FROM ir_model_data WHERE module = new_name);
            GET DIAGNOSTICS deleted_count = ROW_COUNT;
            IF deleted_count > 0 THEN
                RAISE NOTICE '  Deleted % duplicate ir_model_data records', deleted_count;
            END IF;

            UPDATE ir_model_data SET module = new_name WHERE module = old_name;
            UPDATE ir_module_module_dependency SET name = new_name WHERE name = old_name;
            UPDATE ir_module_module SET state = 'uninstalled' WHERE name = old_name;
            DELETE FROM ir_module_module WHERE name = old_name;
        END IF;
    END LOOP;
END $$;
EOF
    )
    echo "Executing bank-payment module renaming..."
    query_postgres_container "$BANK_PAYMENT_RENAME_SQL" ou18 || exit 1

    BANK_PAYMENT_PRE_SQL=$(cat <<'EOF'
UPDATE ir_model_data
SET noupdate = false
WHERE module = 'account_payment_base_oca'
AND name = 'view_account_invoice_report_search';
EOF
    )
    echo "Executing bank-payment pre-migration..."
    query_postgres_container "$BANK_PAYMENT_PRE_SQL" ou18 || exit 1

else
    echo "Module account_payment_mode not installed, skipping bank-payment migration."
fi

# ============================================================================
# FIX: Rename company-dependent columns before OpenUpgrade runs
# In Odoo 18, company-dependent fields are stored as JSONB columns.
# The ORM's _auto_init() tries to convert existing VARCHAR columns to JSONB,
# which fails if the data is not valid JSON.
# Solution: Rename the columns so Odoo creates new JSONB columns, then
# OpenUpgrade's convert_company_dependent() will migrate the data from ir.property.
#
# See: https://github.com/OCA/OpenUpgrade/issues/5449
# ============================================================================
COMPANY_DEPENDENT_FIX_SQL=$(cat <<'EOF'
DO $$
BEGIN
    -- res.partner.barcode (base module)
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'res_partner' AND column_name = 'barcode') THEN
        ALTER TABLE res_partner RENAME COLUMN barcode TO openupgrade_legacy_18_0_barcode;
        RAISE NOTICE 'Renamed res_partner.barcode for company-dependent conversion';
    END IF;
END $$;
EOF
)
echo "Fixing company-dependent columns for Odoo 18..."
query_postgres_container "$COMPANY_DEPENDENT_FIX_SQL" ou18 || exit 1

EOF
)

# Execute SQL pre-migration commands
PRE_MIGRATE_SQL=$(cat <<'EOF'
UPDATE account_analytic_plan SET default_applicability=NULL WHERE default_applicability='optional';
EOF
)
echo "SQL command = $PRE_MIGRATE_SQL"
query_postgres_container "$PRE_MIGRATE_SQL" ou18 || exit 1

# Copy filestores
copy_filestore ou17 ou17 ou18 ou18 || exit 1

echo "Ready for migration to 18.0!"
