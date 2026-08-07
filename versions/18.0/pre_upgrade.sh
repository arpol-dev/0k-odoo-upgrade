#!/bin/bash
set -euo pipefail

echo "Prepare migration to 18.0..."

# Copy database
copy_database ou17 ou18 ou18 || exit 1

# ============================================================================
# REMOVE contract_payment_mode (depends on obsolete account_payment_partner)
#
# contract_payment_mode v18 still depends on account_payment_partner (deleted
# by the bank-payment renaming below) and uses the obsolete account.payment.mode
# model. No v18 replacement exists — account_payment_base_oca provides no
# contract integration. Only 2 contracts had payment_mode_id set, and the
# migration to the new payment.method.line model is not supported.
#
# MUST run BEFORE the bank-payment renaming and BEFORE OpenUpgrade's
# button_upgrade() which would otherwise crash on the missing dependency.
#
# We DELETE the module entirely (like the bank-payment merged_modules pattern)
# rather than marking it 'to remove', because Odoo's "Transient module states
# were reset" in load_modules() converts 'to remove' -> 'installed', causing
# button_upgrade() to re-parse the missing account_payment_partner dependency
# and abort the registry load. Deleting the row + ir_model_data + dependencies
# ensures OpenUpgrade's update_list() rediscovers the physical addon as a fresh
# 'uninstalled' module that button_upgrade() never touches.
# ============================================================================
contract_payment_mode_sql=$(cat <<'EOF'
DO $$
DECLARE
    mod_id INTEGER;
BEGIN
    SELECT id INTO mod_id FROM ir_module_module WHERE name = 'contract_payment_mode';
    IF mod_id IS NOT NULL THEN
        DELETE FROM ir_module_module_dependency WHERE module_id = mod_id;
        DELETE FROM ir_model_data WHERE module = 'contract_payment_mode';
        DELETE FROM ir_module_module WHERE id = mod_id;

        -- Rename the module's own external ID (base.module_contract_payment_mode)
        -- so update_list() can rediscover the physical contract_payment_mode addon
        -- (which still exists in v18 addons path) without conflicting on
        -- (base, module_contract_payment_mode). The orphaned xmlid pointed to
        -- the deleted ir.module.module row and has no other references.
        UPDATE ir_model_data
        SET name = 'module_contract_payment_mode_removed'
        WHERE module = 'base' AND name = 'module_contract_payment_mode';

        RAISE NOTICE 'Removed contract_payment_mode module (depends on obsolete account_payment_partner)';
    ELSE
        RAISE NOTICE 'contract_payment_mode not found, skipping';
    END IF;
END $$;
EOF
)
echo "Removing contract_payment_mode module..."
query_postgres_container "$contract_payment_mode_sql" ou18 || exit 1

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

# Execute SQL pre-migration commands
PRE_MIGRATE_SQL=$(cat <<'EOF'
UPDATE account_analytic_plan SET default_applicability=NULL WHERE default_applicability='optional';
DELETE FROM ir_ui_view WHERE model = 'res.config.settings';

EOF
)
echo "SQL command = $PRE_MIGRATE_SQL"
query_postgres_container "$PRE_MIGRATE_SQL" ou18 || exit 1

# NOTE: Missing generic PCG account xml-ids expected by l10n_fr_account (e.g.
# account.<company>_pcg_607_account / _pcg_707_account) are recreated generically
# by the ORM post-migration script
#   versions/18.0/scripts/l10n_fr_account/18.0.2.2/post-migration-0k-fix-property-account-xmlids.py
# which runs at stage "post" of l10n_fr_account, before the native "end" script
# end-migrate_update_taxes.py that would otherwise crash on the missing xml-id.

# Copy filestores
copy_filestore ou17 ou17 ou18 ou18 || exit 1

echo "Ready for migration to 18.0!"
