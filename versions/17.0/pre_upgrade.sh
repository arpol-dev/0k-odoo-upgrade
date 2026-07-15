#!/bin/bash
set -euo pipefail

echo "Prepare migration to 17.0..."

# Copy database
copy_database ou16 ou17 ou17 || exit 1

# Execute SQL pre-migration commands
PRE_MIGRATE_SQL=$(cat <<'EOF'
DO $$
DECLARE
    plan_id INTEGER;
BEGIN
    -- Check if the 'Projects' analytic plan exists
    SELECT id INTO plan_id FROM account_analytic_plan WHERE name = 'Projects' LIMIT 1;

    -- If it doesn't exist, create it
    IF plan_id IS NULL THEN
        INSERT INTO account_analytic_plan (name, complete_name, default_applicability, create_date, write_date)
        VALUES ('Projects', 'migration_PROJECTS', 'optional', now(), now())
        RETURNING id INTO plan_id;
    END IF;

    -- Delete existing system parameter (if any)
    DELETE FROM ir_config_parameter WHERE key = 'analytic.project_plan';

    -- Insert the system parameter with the correct plan ID
    INSERT INTO ir_config_parameter (key, value, create_date, write_date)
    VALUES ('analytic.project_plan', plan_id::text, now(), now());
END $$;
EOF
)
echo "SQL command = $PRE_MIGRATE_SQL"
query_postgres_container "$PRE_MIGRATE_SQL" ou17 || exit 1

PRE_MIGRATE_SQL_2=$(cat <<'EOF'
DELETE FROM ir_model_fields WHERE name = 'kanban_state_label';
EOF
)
echo "SQL command = $PRE_MIGRATE_SQL_2"
query_postgres_container "$PRE_MIGRATE_SQL_2" ou17 || exit 1

PRE_MIGRATE_SQL_3=$(cat <<'EOF'
DELETE FROM ir_model_fields WHERE name = 'phone' AND model='hr.employee';
DELETE FROM ir_model_fields WHERE name = 'hr_responsible_id' AND model='hr.job';
DELETE FROM ir_model_fields WHERE name = 'address_home_id' AND model='hr.employee';
DELETE FROM ir_model_fields WHERE name = 'manager_id' AND model='project.task';
EOF
)
echo "SQL command = $PRE_MIGRATE_SQL_3"
query_postgres_container "$PRE_MIGRATE_SQL_3" ou17 || exit 1

# ────────────────────────────────────────────────────────────
# Remove project_list's ir.actions.act_window.view records
#
# `project_list` (OCA) is not ported to 17.0 and is classified as
# merged_in_core: in 17.0 the core `project` module natively adds the
# kanban/tree views to the "Projects" actions (act_window_id 149 & 760).
# 17.0 also introduces the unique constraint
# `act_window_view_unique_mode_per_action = unique(act_window_id, view_mode)`.
#
# When core reloads project_project_views.xml, it INSERTs its own
# (act_window_id, view_mode='kanban') rows, which collide with the rows still
# owned by project_list -> UniqueViolation, aborting the registry load:
#
#   ERROR: duplicate key value violates unique constraint
#   "act_window_view_unique_mode_per_action"
#   DETAIL: Key (act_window_id, view_mode)=(760, kanban) already exists.
#
# We delete project_list's act_window_view rows (and their ir_model_data) so
# core can recreate its canonical rows. Verified against the 17.0 OpenUpgrade
# scripts: none reference project_list xmlids nor remap these records, so this
# is safe. Scoped to ir.actions.act_window.view only. Idempotent.
# ────────────────────────────────────────────────────────────
PRE_MIGRATE_SQL_4=$(cat <<'EOF'
DO $$
DECLARE
    deleted_count INTEGER;
BEGIN
    WITH targets AS (
        SELECT d.id AS imd_id, d.res_id AS awv_id
        FROM ir_model_data d
        WHERE d.module = 'project_list'
          AND d.model = 'ir.actions.act_window.view'
    ),
    del_views AS (
        DELETE FROM ir_act_window_view
        WHERE id IN (SELECT awv_id FROM targets)
        RETURNING id
    ),
    del_imd AS (
        DELETE FROM ir_model_data
        WHERE id IN (SELECT imd_id FROM targets)
        RETURNING id
    )
    SELECT count(*) INTO deleted_count FROM del_views;

    RAISE NOTICE 'Removed % project_list act_window_view record(s) to avoid act_window_view_unique_mode_per_action collision', deleted_count;
END $$;
EOF
)
echo "SQL command = $PRE_MIGRATE_SQL_4"
query_postgres_container "$PRE_MIGRATE_SQL_4" ou17 || exit 1

# Copy filestores
copy_filestore ou16 ou16 ou17 ou17 || exit 1

echo "Ready for migration to 17.0!"
