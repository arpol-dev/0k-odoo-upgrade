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

# ============================================================================
# FIX: stock_picking name='/' and missing POS picking type sequences
#
# Two issues can occur after migration:
#
# 1. stock_picking records with name='/' violate the new V18 unique constraint
#    stock_picking_name_uniq (name, company_id). In previous versions this
#    constraint did not exist, so multiple pickings could share name='/'.
#
# 2. POS picking types (pos_type_id on stock_warehouse) may lack a sequence_id.
#    In V18, stock.picking.create() assigns the name from picking_type.sequence_id,
#    but if sequence_id is NULL the name stays '/' and the unique constraint is
#    violated on every new POS payment.
#
#    The standard _create_missing_pos_picking_types() only fixes warehouses where
#    pos_type_id is NULL — it does NOT fix existing pos_type_id records that are
#    missing their sequence_id.
#
# Only executed if stock module tables exist.
# ============================================================================

STOCK_PICKING_TABLE_EXISTS=$(query_postgres_container "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'stock_picking';" ou18 2>/dev/null | grep -E '^\s*[0-9]+' | tr -d ' ' || echo "0")

if [ "$STOCK_PICKING_TABLE_EXISTS" -gt 0 ]; then
    echo "stock_picking table exists, proceeding with POS picking fixes..."

    # --- Step 1: Rename stock_picking records with name='/' ---
    FIX_SLASH_PICKING_NAMES_SQL=$(cat <<'EOF'
DO $$
DECLARE
    slash_count INTEGER;
BEGIN
    IF NOT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'stock_picking') THEN
        RAISE NOTICE 'stock_picking table not found, skipping slash name fix';
        RETURN;
    END IF;

    SELECT COUNT(*) INTO slash_count FROM stock_picking WHERE name = '/';

    IF slash_count > 0 THEN
        UPDATE stock_picking SET name = 'MIGRATED-' || id WHERE name = '/';
        RAISE NOTICE 'Renamed % stock_picking record(s) with name=/ to MIGRATED-<id>', slash_count;
    ELSE
        RAISE NOTICE 'No stock_picking with name=/ found, nothing to rename';
    END IF;
END $$;
EOF
)
    echo "Fixing stock_picking names with '/'..."
    query_postgres_container "$FIX_SLASH_PICKING_NAMES_SQL" ou18 || exit 1

    # --- Step 2: Create missing ir.sequence for POS picking types without sequence ---
    FIX_POS_PICKING_TYPE_SEQUENCES_SQL=$(cat <<'EOF'
DO $$
DECLARE
    pt_rec RECORD;
    seq_id INTEGER;
    seq_name TEXT;
    seq_prefix TEXT;
BEGIN
    IF NOT EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'stock_picking_type') THEN
        RAISE NOTICE 'stock_picking_type table not found, skipping POS sequence fix';
        RETURN;
    END IF;

    IF NOT EXISTS (SELECT FROM information_schema.columns
                   WHERE table_name = 'stock_warehouse' AND column_name = 'pos_type_id') THEN
        RAISE NOTICE 'stock_warehouse.pos_type_id column not found (point_of_sale not installed), skipping POS sequence fix';
        RETURN;
    END IF;

    FOR pt_rec IN
        SELECT spt.id AS picking_type_id,
               spt.name AS picking_type_name,
               COALESCE(spt.sequence_code, 'POS') AS sequence_code,
               sw.code AS warehouse_code,
               sw.name AS warehouse_name,
               sw.company_id
        FROM stock_picking_type spt
        JOIN stock_warehouse sw ON sw.pos_type_id = spt.id
        WHERE spt.sequence_id IS NULL OR spt.sequence_id = 0
    LOOP
        seq_prefix := pt_rec.warehouse_code || '/' || pt_rec.sequence_code || '/';
        seq_name := pt_rec.warehouse_name || ' Picking POS';

        INSERT INTO ir_sequence (
            name, prefix, padding, company_id, implementation,
            number_increment, number_next, active
        ) VALUES (
            seq_name, seq_prefix, 5, pt_rec.company_id, 'standard',
            1, 1, true
        ) RETURNING id INTO seq_id;

        UPDATE stock_picking_type
        SET sequence_id = seq_id
        WHERE id = pt_rec.picking_type_id;

        RAISE NOTICE 'Created ir.sequence % (%) for POS picking type % (ID:%) on warehouse %',
            seq_name, seq_id, pt_rec.picking_type_name, pt_rec.picking_type_id, pt_rec.warehouse_name;
    END LOOP;
END $$;
EOF
)
    echo "Creating missing POS picking type sequences..."
    query_postgres_container "$FIX_POS_PICKING_TYPE_SEQUENCES_SQL" ou18 || exit 1

    # --- Step 3: Create missing PostgreSQL sequences for ir.sequence records ---
    # When ir.sequence records are created via SQL INSERT (not ORM), the underlying
    # PostgreSQL sequence (ir_sequence_NNN) is NOT created. This causes errors when
    # Odoo tries to read or use the sequence.
    FIX_MISSING_PG_SEQUENCES_SQL=$(cat <<'EOF'
DO $$
DECLARE
    seq_rec RECORD;
    seq_pg_name TEXT;
    seq_count INTEGER;
BEGIN
    seq_count := 0;

    FOR seq_rec IN
        SELECT id, number_increment, number_next
        FROM ir_sequence
        WHERE implementation = 'standard'
    LOOP
        seq_pg_name := 'ir_sequence_' || lpad(seq_rec.id::text, 3, '0');

        IF NOT EXISTS (
            SELECT 1 FROM pg_class
            WHERE relkind = 'S' AND relname = seq_pg_name
        ) THEN
            EXECUTE format('CREATE SEQUENCE %I INCREMENT BY %s START WITH %s',
                seq_pg_name, seq_rec.number_increment, seq_rec.number_next);
            seq_count := seq_count + 1;
            RAISE NOTICE 'Created PostgreSQL sequence %', seq_pg_name;
        END IF;
    END LOOP;

    IF seq_count > 0 THEN
        RAISE NOTICE 'Created % missing PostgreSQL sequence(s)', seq_count;
    ELSE
        RAISE NOTICE 'All PostgreSQL sequences already exist, nothing to create';
    END IF;
END $$;
EOF
)
    echo "Creating missing PostgreSQL sequences for ir.sequence records..."
    query_postgres_container "$FIX_MISSING_PG_SEQUENCES_SQL" ou18 || exit 1

    # --- Step 4: Grant permissions on newly created PostgreSQL sequences ---
    # Sequences created above are owned by the current DB user, but we ensure
    # the Odoo DB user has proper access (needed when created by a different superuser).
    GRANT_PG_SEQUENCES_SQL=$(cat <<'EOF'
DO $$
DECLARE
    seq_rec RECORD;
    seq_pg_name TEXT;
    db_user TEXT;
    grant_count INTEGER;
BEGIN
    -- Determine the Odoo database user from the current connection
    SELECT current_user INTO db_user;
    grant_count := 0;

    FOR seq_rec IN
        SELECT id
        FROM ir_sequence
        WHERE implementation = 'standard'
    LOOP
        seq_pg_name := 'ir_sequence_' || lpad(seq_rec.id::text, 3, '0');

        IF EXISTS (
            SELECT 1 FROM pg_class
            WHERE relkind = 'S' AND relname = seq_pg_name
        ) THEN
            BEGIN
                EXECUTE format('GRANT ALL ON SEQUENCE %I TO %I', seq_pg_name, db_user);
                grant_count := grant_count + 1;
            EXCEPTION WHEN insufficient_privilege THEN
                RAISE NOTICE 'Cannot GRANT on % (not owner), skipping', seq_pg_name;
            END;
        END IF;
    END LOOP;

    RAISE NOTICE 'Granted permissions on % PostgreSQL sequence(s) to %', grant_count, db_user;
END $$;
EOF
)
    echo "Granting permissions on PostgreSQL sequences..."
    query_postgres_container "$GRANT_PG_SEQUENCES_SQL" ou18 || exit 1

    # --- Step 5: Verification ---
    VERIFY_POS_FIXES_SQL=$(cat <<'EOF'
DO $$
DECLARE
    slash_count INTEGER;
    missing_seq_count INTEGER;
BEGIN
    -- Check remaining pickings with name='/'
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'stock_picking') THEN
        SELECT COUNT(*) INTO slash_count FROM stock_picking WHERE name = '/';
        IF slash_count > 0 THEN
            RAISE WARNING 'Still % stock_picking record(s) with name=/', slash_count;
        ELSE
            RAISE NOTICE 'OK: No stock_picking with name=/ remaining';
        END IF;
    END IF;

    -- Check POS picking types without sequence
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'stock_picking_type')
       AND EXISTS (SELECT FROM information_schema.columns
                   WHERE table_name = 'stock_warehouse' AND column_name = 'pos_type_id') THEN
        SELECT COUNT(*) INTO missing_seq_count
        FROM stock_picking_type spt
        JOIN stock_warehouse sw ON sw.pos_type_id = spt.id
        WHERE spt.sequence_id IS NULL OR spt.sequence_id = 0;

        IF missing_seq_count > 0 THEN
            RAISE WARNING 'Still % POS picking type(s) without sequence_id', missing_seq_count;
        ELSE
            RAISE NOTICE 'OK: All POS picking types have a sequence_id';
        END IF;
    END IF;
END $$;
EOF
)
    echo "Verifying POS picking fixes..."
    query_postgres_container "$VERIFY_POS_FIXES_SQL" ou18 || exit 1

else
    echo "stock_picking table not found, skipping POS picking fixes."
fi

# Same reasoning as in pre_upgrade.sh: bump cache-signaling sequences so any
# already-running Odoo process for this database sees the fixes above
# instead of a stale in-memory cache. See invalidate_odoo_caches() in
# lib/common.sh.
invalidate_odoo_caches ou18

echo "Post migration to 18.0 completed!"
