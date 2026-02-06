#!/bin/bash
set -euo pipefail

echo "Post migration to 18.0..."

# ============================================================================
# BANK-PAYMENT -> BANK-PAYMENT-ALTERNATIVE DATA MIGRATION
# Source PR: https://github.com/OCA/bank-payment-alternative/pull/42
#
# Only executed if account_payment_mode table exists (module was installed).
# ============================================================================

# Check if account_payment_mode table exists (meaning the module was installed before migration)
BANK_PAYMENT_TABLE_EXISTS=$(query_postgres_container "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'account_payment_mode';" ou18 2>/dev/null | grep -E '^\s*[0-9]+' | tr -d ' ' || echo "0")

if [ "$BANK_PAYMENT_TABLE_EXISTS" -gt 0 ]; then
    echo "Table account_payment_mode exists, proceeding with bank-payment data migration..."

    BANK_PAYMENT_POST_SQL=$(cat <<'EOF'
DO $$
DECLARE
    mode_rec RECORD;
    new_line_id INTEGER;
    journal_rec RECORD;
BEGIN
    IF NOT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'account_payment_mode') THEN
        RAISE NOTICE 'No account_payment_mode table found, skipping bank-payment migration';
        RETURN;
    END IF;

    RAISE NOTICE 'Starting bank-payment to bank-payment-alternative migration...';

    ALTER TABLE account_payment_method_line
        ADD COLUMN IF NOT EXISTS old_payment_mode_id INT,
        ADD COLUMN IF NOT EXISTS old_refund_payment_mode_id INT;

    FOR mode_rec IN
        SELECT id, name, company_id, payment_method_id,
               fixed_journal_id AS journal_id, bank_account_link,
               create_date, create_uid, write_date, write_uid,
               show_bank_account, refund_payment_mode_id, active
        FROM account_payment_mode
    LOOP
        INSERT INTO account_payment_method_line (
            name, payment_method_id, bank_account_link, journal_id,
            selectable, company_id, create_uid, create_date,
            write_uid, write_date, show_bank_account,
            old_payment_mode_id, old_refund_payment_mode_id, active
        ) VALUES (
            to_jsonb(mode_rec.name),
            mode_rec.payment_method_id,
            mode_rec.bank_account_link,
            mode_rec.journal_id,
            true,
            mode_rec.company_id,
            mode_rec.create_uid,
            mode_rec.create_date,
            mode_rec.write_uid,
            mode_rec.write_date,
            mode_rec.show_bank_account,
            mode_rec.id,
            mode_rec.refund_payment_mode_id,
            mode_rec.active
        ) RETURNING id INTO new_line_id;

        IF mode_rec.bank_account_link = 'variable' THEN
            IF EXISTS (SELECT FROM information_schema.tables
                       WHERE table_name = 'account_journal_account_payment_method_line_rel') THEN
                FOR journal_rec IN
                    SELECT rel.journal_id
                    FROM account_payment_mode_variable_journal_rel rel
                    WHERE rel.payment_mode_id = mode_rec.id
                LOOP
                    INSERT INTO account_journal_account_payment_method_line_rel
                        (account_payment_method_line_id, account_journal_id)
                    VALUES (new_line_id, journal_rec.journal_id)
                    ON CONFLICT DO NOTHING;
                END LOOP;
            END IF;
        END IF;

        RAISE NOTICE 'Migrated payment mode % -> payment method line %', mode_rec.id, new_line_id;
    END LOOP;

    UPDATE account_payment_method_line apml
    SET refund_payment_method_line_id = apml2.id
    FROM account_payment_method_line apml2
    WHERE apml.old_refund_payment_mode_id IS NOT NULL
    AND apml.old_refund_payment_mode_id = apml2.old_payment_mode_id;

    UPDATE account_move am
    SET preferred_payment_method_line_id = apml.id
    FROM account_payment_mode apm, account_payment_method_line apml
    WHERE am.payment_mode_id = apm.id
    AND apm.id = apml.old_payment_mode_id
    AND am.preferred_payment_method_line_id IS NULL;

    RAISE NOTICE 'account_payment_base_oca migration completed';
END $$;
EOF
    )
    echo "Executing bank-payment base migration..."
    query_postgres_container "$BANK_PAYMENT_POST_SQL" ou18 || exit 1

    BANK_PAYMENT_BATCH_SQL=$(cat <<'EOF'
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'account_payment_mode') THEN
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'account_payment_order') THEN
        RAISE NOTICE 'No account_payment_order table, skipping batch migration';
        RETURN;
    END IF;

    RAISE NOTICE 'Starting account_payment_batch_oca migration...';

    IF EXISTS (SELECT FROM information_schema.columns 
               WHERE table_name = 'account_payment_method' AND column_name = 'payment_order_only') THEN
        UPDATE account_payment_method
        SET payment_order_ok = payment_order_only
        WHERE payment_order_only IS NOT NULL;
    END IF;

    UPDATE account_payment_method_line apml
    SET payment_order_ok = apm.payment_order_ok,
        no_debit_before_maturity = apm.no_debit_before_maturity,
        default_payment_mode = apm.default_payment_mode,
        default_invoice = apm.default_invoice,
        default_target_move = apm.default_target_move,
        default_date_type = apm.default_date_type,
        default_date_prefered = apm.default_date_prefered,
        group_lines = apm.group_lines
    FROM account_payment_mode apm
    WHERE apml.old_payment_mode_id IS NOT NULL
    AND apm.id = apml.old_payment_mode_id;

    IF EXISTS (SELECT FROM information_schema.tables 
               WHERE table_name = 'account_journal_account_payment_method_line_rel') THEN
        DELETE FROM account_journal_account_payment_method_line_rel
        WHERE account_payment_method_line_id IN (
            SELECT id FROM account_payment_method_line WHERE old_payment_mode_id IS NOT NULL
        );

        INSERT INTO account_journal_account_payment_method_line_rel
            (account_payment_method_line_id, account_journal_id)
        SELECT apml.id, rel.account_journal_id
        FROM account_journal_account_payment_mode_rel rel
        JOIN account_payment_method_line apml ON rel.account_payment_mode_id = apml.old_payment_mode_id
        ON CONFLICT DO NOTHING;
    END IF;

    UPDATE account_payment_order apo
    SET payment_method_line_id = apml.id,
        payment_method_code = apm_method.code
    FROM account_payment_method_line apml,
         account_payment_mode apm,
         account_payment_method apm_method
    WHERE apo.payment_mode_id = apm.id
    AND apml.old_payment_mode_id = apm.id
    AND apm_method.id = apml.payment_method_id;

    RAISE NOTICE 'account_payment_batch_oca migration completed';
    RAISE NOTICE 'NOTE: Payment lots for open orders must be generated manually via Odoo UI or script';
END $$;
EOF
    )
    echo "Executing bank-payment batch migration..."
    query_postgres_container "$BANK_PAYMENT_BATCH_SQL" ou18 || exit 1

else
    echo "Table account_payment_mode not found, skipping bank-payment migration."
fi

echo "Post migration to 18.0 completed!"
