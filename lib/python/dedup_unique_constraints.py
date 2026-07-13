#!/usr/bin/env python3
"""
Pre-Migration Unique Constraint Deduplication Script for Odoo

Some Odoo versions introduce new UNIQUE constraints on fields that previously
allowed duplicates (e.g. utm.source.name in 16.0). When the migration rebuilds
the model, the unique index creation raises
`psycopg2.errors.UniqueViolation: could not create unique index ...`
and aborts the whole registry load.

This script runs BEFORE the migration loop, on the SOURCE database, and renames
duplicate records so the target-version unique index can be built successfully.

For each declared constraint (model + fields), it:
  - resolves the table, column type and translatable flag from the ORM;
  - detects duplicate groups (for translatable/jsonb fields the comparison is
    done on the value actually indexed by Odoo, i.e. the `en_US` key);
  - keeps the record with the smallest id untouched and renames every other
    duplicate by appending ` [<id>]` to ALL language keys (jsonb) or to the
    plain value (varchar), preserving all foreign keys.

Constraints to check are passed as JSON via the DEDUP_UNIQUE_CONSTRAINTS
environment variable, e.g.:
    [{"model": "utm.source", "fields": ["name"]}, ...]

A machine-readable report of every rename is written to
/tmp/dedup_unique_constraints_<db>_<timestamp>.json when DEDUP_REPORT is set.

Usage:
    compose run <service> shell -d <db> --no-http --stop-after-init \
        < dedup_unique_constraints.py

Exit codes:
    0 - Completed (duplicates, if any, were deduplicated)
    2 - Technical failure (see traceback)
"""

import os
import sys
import json
from datetime import datetime
from collections import defaultdict


class Colors:
    RED = '\033[91m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    BOLD = '\033[1m'
    END = '\033[0m'


def _c(color, text):
    return f"{color}{text}{Colors.END}"


def load_constraints():
    """Load the constraints catalog from the environment."""
    raw = os.environ.get('DEDUP_UNIQUE_CONSTRAINTS', '').strip()
    if not raw:
        return []
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"DEDUP_UNIQUE_CONSTRAINTS is not valid JSON: {exc}")
    if not isinstance(data, list):
        raise ValueError("DEDUP_UNIQUE_CONSTRAINTS must be a JSON list")
    return data


def resolve_constraint(env, spec):
    """Resolve a {model, fields} spec into concrete DB metadata.

    Returns a dict with table, list of (field_name, column, is_jsonb) or
    None if the model/fields are not present in this database (e.g. module
    not installed in the source version).
    """
    model_name = spec.get('model')
    field_names = spec.get('fields') or []
    if not model_name or not field_names:
        return None
    if model_name not in env:
        return None

    model = env[model_name]
    table = model._table

    # The physical table must exist in the source DB.
    env.cr.execute("SELECT to_regclass(%s)", (table,))
    if not env.cr.fetchone()[0]:
        return None

    columns = []
    for fname in field_names:
        field = model._fields.get(fname)
        if field is None:
            return None
        column = field.name
        # Column must physically exist (skip non-stored/computed fields).
        # We rely on the ACTUAL PostgreSQL column type, not the ORM `translate`
        # attribute: in the source version a translatable field may still be a
        # plain `character varying` column (it only becomes `jsonb` during the
        # migration to the version that introduces translation storage).
        env.cr.execute(
            """
            SELECT data_type FROM information_schema.columns
            WHERE table_name = %s AND column_name = %s
            """,
            (table, column),
        )
        row = env.cr.fetchone()
        if not row:
            return None
        data_type = row[0]
        columns.append({
            'field': fname,
            'column': column,
            'is_jsonb': data_type == 'jsonb',
        })

    return {'model': model_name, 'table': table, 'columns': columns}


def key_sql(column, is_jsonb):
    """SQL expression yielding the value Odoo compares for the unique index.

    For jsonb (translated) columns Odoo indexes the value; the semantically
    relevant duplicate is on the `en_US` key. For plain columns, the value.
    """
    if is_jsonb:
        return f"({column} ->> 'en_US')"
    return column


def find_duplicate_groups(env, meta):
    """Return duplicate groups as list of dicts: {value, ids (sorted)}."""
    table = meta['table']
    key_exprs = [key_sql(c['column'], c['is_jsonb']) for c in meta['columns']]
    key_concat = " || '\x1f' || ".join(f"COALESCE({e}, '')" for e in key_exprs)

    query = f"""
        SELECT {key_concat} AS dup_key, array_agg(id ORDER BY id) AS ids
        FROM {table}
        GROUP BY {key_concat}
        HAVING COUNT(*) > 1
    """
    env.cr.execute(query)
    groups = []
    for dup_key, ids in env.cr.fetchall():
        groups.append({'value': dup_key, 'ids': list(ids)})
    return groups


def rename_record(env, meta, record_id):
    """Suffix ` [<id>]` on every language key (jsonb) / plain value (varchar).

    Returns a list of {field, old_value, new_value} describing the change.
    """
    table = meta['table']
    changes = []
    suffix = f" [{record_id}]"

    for col in meta['columns']:
        column = col['column']
        env.cr.execute(
            f"SELECT {column} FROM {table} WHERE id = %s", (record_id,)
        )
        row = env.cr.fetchone()
        if not row:
            continue
        old_value = row[0]

        if col['is_jsonb']:
            # jsonb: append suffix to each language value
            if not isinstance(old_value, dict):
                # psycopg may already decode jsonb to dict; if not, load it.
                try:
                    old_value = json.loads(old_value) if old_value else {}
                except (TypeError, ValueError):
                    old_value = {}
            new_value = {
                lang: (val or '') + suffix for lang, val in old_value.items()
            }
            env.cr.execute(
                f"UPDATE {table} SET {column} = %s::jsonb WHERE id = %s",
                (json.dumps(new_value), record_id),
            )
        else:
            new_value = (old_value or '') + suffix
            env.cr.execute(
                f"UPDATE {table} SET {column} = %s WHERE id = %s",
                (new_value, record_id),
            )

        changes.append({
            'field': col['field'],
            'old_value': old_value,
            'new_value': new_value,
        })

    return changes


def main():
    print("\n" + "=" * 80)
    print(_c(Colors.BOLD, "PRE-MIGRATION - UNIQUE CONSTRAINT DEDUPLICATION"))
    print("=" * 80 + "\n")

    try:
        specs = load_constraints()
    except ValueError as exc:
        print(_c(Colors.RED, f"[ERROR] {exc}"))
        sys.exit(2)

    if not specs:
        print(_c(Colors.YELLOW, "No unique constraints declared. Nothing to do."))
        return

    renamed_records = []  # flat report entries
    checked = 0
    skipped = []

    for spec in specs:
        meta = resolve_constraint(env, spec)
        label = f"{spec.get('model')}({', '.join(spec.get('fields', []))})"
        if meta is None:
            skipped.append(label)
            print(_c(Colors.YELLOW, f"[SKIP]  {label} - not present in this database"))
            continue

        checked += 1
        groups = find_duplicate_groups(env, meta)
        if not groups:
            print(_c(Colors.GREEN, f"[OK]    {label} - no duplicates"))
            continue

        total_dups = sum(len(g['ids']) - 1 for g in groups)
        print(_c(Colors.BOLD,
                 f"[FIX]   {label} - {len(groups)} duplicate group(s), "
                 f"{total_dups} record(s) to rename"))

        for group in groups:
            ids = group['ids']
            keep_id, dup_ids = ids[0], ids[1:]
            print(f"        value={group['value']!r} keep id={keep_id} "
                  f"rename ids={dup_ids}")
            for dup_id in dup_ids:
                changes = rename_record(env, meta, dup_id)
                for ch in changes:
                    renamed_records.append({
                        'model': meta['model'],
                        'table': meta['table'],
                        'id': dup_id,
                        'field': ch['field'],
                        'old_value': ch['old_value'],
                        'new_value': ch['new_value'],
                    })

    if renamed_records:
        env.cr.commit()

    # ---- Summary ---------------------------------------------------------
    print("\n" + "=" * 80)
    print(_c(Colors.BOLD, "DEDUPLICATION SUMMARY"))
    print("=" * 80)
    print(f"  Constraints checked ... {checked}")
    print(f"  Constraints skipped ... {len(skipped)}")
    print(f"  Records renamed ....... {len(renamed_records)}")
    if renamed_records:
        print("")
        for r in renamed_records:
            old_display = r['old_value']
            new_display = r['new_value']
            print(f"  - {r['model']} #{r['id']} [{r['field']}]: "
                  f"{old_display!r} -> {new_display!r}")
    print("=" * 80 + "\n")

    # ---- JSON report -----------------------------------------------------
    if os.environ.get('DEDUP_REPORT') and renamed_records:
        ts = datetime.now().strftime('%Y%m%d_%H%M%S')
        db = env.cr.dbname
        path = f"/tmp/dedup_unique_constraints_{db}_{ts}.json"
        report = {
            'type': 'dedup_unique_constraints',
            'timestamp': datetime.now().isoformat(),
            'database': db,
            'constraints_checked': checked,
            'constraints_skipped': skipped,
            'renamed_count': len(renamed_records),
            'renamed': renamed_records,
        }
        with open(path, 'w') as fh:
            json.dump(report, fh, indent=2, default=str)
        print(_c(Colors.BLUE, f"[REPORT] JSON written to {path}"))


try:
    main()
except Exception as exc:  # noqa: BLE001
    print(_c(Colors.RED, f"[ERROR] Deduplication script failed: {exc}"))
    import traceback
    traceback.print_exc()
    sys.exit(2)
