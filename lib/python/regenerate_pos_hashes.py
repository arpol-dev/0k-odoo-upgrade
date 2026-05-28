#!/usr/bin/env python3
"""Regenerate all POS order inalterability hashes and sequence numbers.

This script should only be called when the SQL pre-check in finalize_db.sh
has confirmed that some pos_orders are missing l10n_fr_hash or
l10n_fr_secure_sequence_number.

It resets ALL sequence numbers and hashes from scratch, in chronological order
(date_order ASC, id ASC), and re-establishes the full hash chain.

Usage (via Odoo shell):
    odoo-shell -d <db_name> < regenerate_pos_hashes.py
"""
import logging
from hashlib import sha256

_logger = logging.getLogger(__name__)


def regenerate_all():
    PosOrder = env['pos.order']
    Company = env['res.company']

    for company in Company.search([]):
        if not company._is_accounting_unalterable():
            continue

        print(f"\n{'='*60}")
        print(f" Company: {company.name}")
        print(f"{'='*60}")

        orders = PosOrder.search([
            ('state', 'in', ['paid', 'done', 'invoiced']),
            ('company_id', '=', company.id),
        ], order='date_order ASC, id ASC')

        if not orders:
            print(" No orders to process.")
            continue

        n = len(orders)

        # ── Step 1: Reset all fields ─────────────────────────────
        print("\n--- Resetting fields ---")
        env.cr.execute("""
            UPDATE pos_order
            SET l10n_fr_hash = NULL,
                l10n_fr_secure_sequence_number = NULL,
                previous_order_id = NULL
            WHERE id IN %s
        """, (tuple(orders.ids),))
        env.invalidate_all()
        env.cr.commit()
        print(f" ✓ {n} orders reset")

        # ── Step 2: Assign sequence numbers ──────────────────────
        print("\n--- Assigning sequence numbers ---")
        for i, order in enumerate(orders, start=1):
            env.cr.execute("""
                UPDATE pos_order
                SET l10n_fr_secure_sequence_number = %s
                WHERE id = %s
            """, (i, order.id))
        env.invalidate_all()
        env.cr.commit()
        print(f" ✓ Sequence numbers 1 → {n} assigned")

        # ── Step 3: Compute previous_order_id ────────────────────
        print("\n--- Computing previous_order_id ---")
        orders = PosOrder.search([
            ('state', 'in', ['paid', 'done', 'invoiced']),
            ('company_id', '=', company.id),
        ], order='l10n_fr_secure_sequence_number ASC')
        orders._compute_previous_order()
        env.cr.commit()
        print(" ✓ OK")

        # ── Step 4: Compute hashes (with cache invalidation after each write) ─
        print("\n--- Computing hashes ---")
        success = errors = 0

        for idx in range(n):
            order = PosOrder.search([
                ('company_id', '=', company.id),
                ('l10n_fr_secure_sequence_number', '=', idx + 1),
            ], limit=1)

            if not order:
                continue

            try:
                order._compute_string_to_hash()

                prev = order.previous_order_id
                prev_hash = prev.l10n_fr_hash if prev else ''
                if not prev_hash:
                    prev_hash = ''

                computed_hash = sha256(
                    (prev_hash + order.l10n_fr_string_to_hash).encode('utf-8')
                ).hexdigest()

                env.cr.execute(
                    "UPDATE pos_order SET l10n_fr_hash = %s WHERE id = %s",
                    (computed_hash, order.id)
                )

                env.invalidate_all()
                print(f"  ✓ {order.name} (seq {idx+1})")
                success += 1

            except Exception as e:
                print(f"  ✗ {order.name} (seq {idx+1}) : {e}")
                errors += 1
                import traceback
                traceback.print_exc()

        env.cr.commit()

        remaining = PosOrder.search_count([
            ('state', 'in', ['paid', 'done', 'invoiced']),
            ('company_id', '=', company.id),
            '|', ('l10n_fr_hash', '=', False),
                 ('l10n_fr_hash', '=', None),
        ])
        print(f"\n Final result: {success} hashes written, {errors} errors, "
              f"{remaining} remaining")

        # Reset sequence for future orders
        seq = company.l10n_fr_pos_cert_sequence_id
        if seq:
            env.cr.execute(
                "UPDATE ir_sequence SET number_next = %s WHERE id = %s",
                (n + 1, seq.id)
            )
            print(f" ✓ ir_sequence number_next set to {n + 1}")

    print("\n✓ Done.")


regenerate_all()
