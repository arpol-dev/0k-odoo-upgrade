#!/bin/bash
set -euo pipefail

echo "Prepare migration to 18.0..."

# Copy database
copy_database ou17 ou18 ou18 || exit 1

# ============================================================================
# FIX: Remove orphaned auto-created 'balance' expressions for French tax
# report lines before l10n_fr_account's own data files load.
#
# Background: account.report.line supports a shortcut syntax where writing
# a field like 'aggregation_formula' directly on the line auto-creates the
# underlying account.report.expression via a plain ORM create() (see
# _create_report_expression() in addons/account/models/account_report.py).
# This auto-created expression NEVER gets an ir_model_data (xmlid) entry,
# unlike an explicit <record id="..."> tag processed by the XML data loader.
#
# The l10n_fr module (as installed here, an older point release) still uses
# this shortcut style for these specific report lines. l10n_fr_account (18.0)
# rewrites the same lines using the modern explicit <record> syntax with a
# proper xmlid (e.g. tax_report_16_formula). Since our installed l10n_fr never
# created that xmlid in the first place, OpenUpgrade's rename step
# (l10n_fr/18.0.2.1/pre-migration.py, module='l10n_fr' -> 'l10n_fr_account')
# has nothing to rename for these expressions, and l10n_fr_account's own data
# file then tries to INSERT a fresh expression for the same (report_line_id,
# label) pair, hitting the "account_report_expression_line_label_uniq"
# unique constraint against the untracked orphan.
#
# OpenUpgrade already recognizes this exact pattern for the 16->17 hop (see
# _remove_autocreated_expression() in
# openupgrade_scripts/scripts/l10n_fr/17.0.2.1/pre-migration.py), cleaning up
# the very same list of report lines. No equivalent exists for 17->18, so we
# replicate it here, scoped to module='l10n_fr' (the rename to
# 'l10n_fr_account' only happens later, inside Odoo's own migration
# framework during the -u all run).
# ============================================================================
ORPHAN_EXPRESSION_FIX_SQL=$(cat <<'EOF'
DELETE FROM account_report_expression
WHERE label = 'balance'
AND report_line_id IN (
    SELECT res_id FROM ir_model_data
    WHERE module = 'l10n_fr'
    AND model = 'account.report.line'
    AND name IN ('tax_report_16', 'tax_report_23', 'tax_report_TIC_total',
                 'tax_report_X4', 'tax_report_Y1', 'tax_report_Y2',
                 'tax_report_Y3', 'tax_report_Z4', 'tax_report_32')
)
AND id NOT IN (
    SELECT res_id FROM ir_model_data
    WHERE module = 'l10n_fr' AND model = 'account.report.expression'
);
EOF
)
echo "Removing orphaned auto-created 'balance' expressions for French tax report lines..."
query_postgres_container "$ORPHAN_EXPRESSION_FIX_SQL" ou18 || exit 1

# ============================================================================
# FIX: Remove legacy web_tour.tour rows with no user_id before OpenUpgrade's
# web_tour end-migration step runs.
#
# Background: in 17.0, web_tour.tour had one row per (user, tour) completion,
# with a required-in-practice user_id many2one. In 18.0 this became one row
# per tour (unique by name), with completions tracked via a user_consumed_ids
# many2many (relation table res_users_web_tour_tour_rel).
#
# Some legacy rows have user_id IS NULL: these are tour-registration markers
# (e.g. a tour existing without ever being completed by a specific user) with
# no equivalent in the new schema. OpenUpgrade's own
# web_tour/18.0.1.0/end-migration.py does:
#   INSERT INTO res_users_web_tour_tour_rel (res_users_id, web_tour_tour_id)
#   SELECT legacy_table.user_id, web_tour_tour.id FROM legacy_table, ...
# with no NULL filtering, so it fails with "null value in column
# res_users_id violates not-null constraint" as soon as one of these rows
# is present.
#
# Fix pushed upstream to OpenUpgrade would solve this properly, but since
# ou18 runs from a pre-built Docker image, code changes to OpenUpgrade
# scripts don't take effect without an image rebuild. So, as with the
# l10n_fr orphan-expression fix above, we clean up the data directly here,
# before Odoo's own pre-migration.py renames this table aside.
# ============================================================================
WEB_TOUR_NULL_USER_FIX_SQL=$(cat <<'EOF'
DELETE FROM web_tour_tour WHERE user_id IS NULL;
EOF
)
echo "Removing legacy web_tour.tour rows with no user_id..."
query_postgres_container "$WEB_TOUR_NULL_USER_FIX_SQL" ou18 || exit 1

# ============================================================================
# FIX: Correct the noupdate ir.rule 'analytic.analytic_plan_comp_rule'
# (model account.analytic.plan) before OpenUpgrade/the -u all run touches it.
#
# Background: this rule's domain_force is "[('company_id', 'in',
# company_ids + [False])]", but account.analytic.plan has no company_id field
# in 18.0 (only account.analytic.account, the accounts *within* a plan, is
# company-scoped -- plans themselves are shared across companies). Since
# ir.rule records are noupdate="1" by default, a plain module update never
# refreshes this domain even though the model's fields changed at some point
# in the migration path -- it silently carries over whatever domain was
# valid on the origin version.
#
# Symptom: any view that renders analytic plan filters (e.g. Reporting >
# Analytic Report, found via the Playwright menu sweep documented in the
# migration-odoo skill) crashes with "KeyError: 'company_id'" inside
# Model.filtered_domain(), raised from analytic/models/analytic_line.py's
# _patch_view() walking account.analytic.plan.children_ids.
#
# Fix: neutralize the domain (always-true) rather than removing the rule --
# preserves the rule's row/xmlid (so a future core update can still manage
# it) without the invalid field reference.
# ============================================================================
ANALYTIC_PLAN_RULE_FIX_SQL=$(cat <<'EOF'
UPDATE ir_rule SET domain_force = '[(1,"=",1)]'
WHERE id IN (
    SELECT res_id FROM ir_model_data
    WHERE module = 'analytic' AND name = 'analytic_plan_comp_rule' AND model = 'ir.rule'
);
EOF
)
echo "Fixing invalid company_id domain on analytic.analytic_plan_comp_rule..."
query_postgres_container "$ANALYTIC_PLAN_RULE_FIX_SQL" ou18 || exit 1

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

# Copy filestores
copy_filestore ou17 ou17 ou18 ou18 || exit 1

echo "Ready for migration to 18.0!"
