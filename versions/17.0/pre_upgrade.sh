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

# ────────────────────────────────────────────────────────────
# Remove orphan theme.ir.ui.view templates pointing to deleted ir.ui.view
#
# In Odoo 17, the asset bundle system was reworked: `web._assets_utils`,
# `website.assets_editor`, and `website._assets_frontend_helpers` were
# replaced by the new `ir.asset` model. The theme_common/theme_clean 17.0
# modules no longer define those templates, but the migrated database still
# holds the old `theme_ir_ui_view` records (kept by ir_model_data noupdate).
#
# Their `inherit_id` Reference field points to ir.ui.view ids that no longer
# exist. When website's `_theme_load(website)` runs (ir_module_module.py:95)
# during the registry load, `ThemeView._convert_to_base_model`
# (theme_models.py:85) accesses `inherit.website_id` on the ghost record and
# raises MissingError, aborting the whole registry:
#
#   odoo.exceptions.MissingError: Record does not exist or has been deleted.
#   (Record: ir.ui.view(174,), User: 1)
#
# This deletes the ir_model_data + theme_ir_ui_view rows whose inherit_id
# targets a missing ir.ui.view. Generic (covers any theme, idempotent).
# Scoped to theme_ir_ui_view only. Verified: no ir.ui.view copies exist for
# the affected templates, so no side effects.
# ────────────────────────────────────────────────────────────
PRE_MIGRATE_SQL_5=$(cat <<'EOF'
DO $$
DECLARE
    deleted_imd INTEGER;
    deleted_tpl INTEGER;
BEGIN
    IF to_regclass('theme_ir_ui_view') IS NULL THEN
        RAISE NOTICE 'Table theme_ir_ui_view does not exist, skipping stale view cleanup.';
        RETURN;
    END IF;

    WITH targets AS (
        SELECT id FROM theme_ir_ui_view
        WHERE inherit_id LIKE 'ir.ui.view,%'
          AND NOT EXISTS (
              SELECT 1 FROM ir_ui_view v
              WHERE v.id = split_part(theme_ir_ui_view.inherit_id, ',', 2)::int
          )
    ),
    del AS (
        DELETE FROM ir_model_data
        WHERE model = 'theme.ir.ui.view'
          AND res_id IN (SELECT id FROM targets)
        RETURNING id
    )
    SELECT count(*) INTO deleted_imd FROM del;

    WITH del AS (
        DELETE FROM theme_ir_ui_view
        WHERE inherit_id LIKE 'ir.ui.view,%'
          AND NOT EXISTS (
              SELECT 1 FROM ir_ui_view v
              WHERE v.id = split_part(theme_ir_ui_view.inherit_id, ',', 2)::int
          )
        RETURNING id
    )
    SELECT count(*) INTO deleted_tpl FROM del;

    RAISE NOTICE 'Cleaned % stale theme_ir_ui_view record(s) and % ir_model_data entry(ies)', deleted_tpl, deleted_imd;
END $$;
EOF
)
echo "SQL command = $PRE_MIGRATE_SQL_5"
query_postgres_container "$PRE_MIGRATE_SQL_5" ou17 || exit 1

# ────────────────────────────────────────────────────────────
# Drop mail.tracking.value rows referencing event.registration.mobile
#
# In Odoo 17 the field event.registration.mobile is removed (OpenUpgrade:
# "event / event.registration / mobile (char) : DEL"). During _process_end,
# Odoo unlinks the now-orphan ir.model.fields row. mail's ir_model_fields
# unlink() override iterates the mail.tracking.value rows pointing to it and
# calls event.registration._mail_track_get_field_sequence('mobile'), which
# does self._fields['mobile'] -> KeyError: 'mobile', aborting the registry:
#
#   KeyError: 'mobile'  (mail/models/models.py, _mail_track_get_field_sequence)
#
# The OpenUpgrade event script deletes the field but leaves its tracking
# values, so any DB that tracked this field crashes. We delete those tracking
# values beforehand so the field unlinks cleanly.
# Scoped strictly to event.registration.mobile. Idempotent.
# NOTE: this runs before -u all, so the FK column is still named 'field'
# (mail renames it to 'field_id' during the 16->17 upgrade).
# ────────────────────────────────────────────────────────────
PRE_MIGRATE_SQL_6=$(cat <<'EOF'
DO $$
DECLARE
    deleted_count INTEGER;
BEGIN
    WITH del AS (
        DELETE FROM mail_tracking_value
         WHERE field IN (
             SELECT id FROM ir_model_fields
              WHERE model = 'event.registration' AND name = 'mobile'
         )
        RETURNING id
    )
    SELECT count(*) INTO deleted_count FROM del;
    RAISE NOTICE 'Removed % mail_tracking_value row(s) for event.registration.mobile', deleted_count;
END $$;
EOF
)
echo "SQL command = $PRE_MIGRATE_SQL_6"
query_postgres_container "$PRE_MIGRATE_SQL_6" ou17 || exit 1

PRE_MIGRATE_SQL_7=$(cat <<'EOF'
/* OpenUpgrade 16→17 hr post-migration tries to delete hr.res_partner_admin_private_address
   which resolves to the Administrator's own res.partner (protected by _unlink_except_user).
   Remove the XML ID so delete_records_safely_by_xml_id skips it. */
DELETE FROM ir_model_data WHERE module = 'hr' AND name = 'res_partner_admin_private_address';
EOF
)
echo "SQL command = $PRE_MIGRATE_SQL_7"
query_postgres_container "$PRE_MIGRATE_SQL_7" ou17 || exit 1

PRE_MIGRATE_SQL_8=$(cat <<'EOF'
/* project/17.0.1.3/post-migration.py::_convert_project_task_repeat_type_after
   converts repeat_type='after' recurrences (month/year unit) to repeat_type='until'
   by computing repeat_until = MAX(task.date_deadline) + recurrence_left*repeat_interval
   months/years. It anchors on the date_deadline of the OLDEST task carrying a non-null
   value (usually the very first occurrence ever generated), ignoring how much time has
   elapsed since. If real time has passed since that first occurrence, the computed
   repeat_until lands in the past and violates project.task.recurrence's own
   _check_repeat_until_date constraint (repeat_until must be >= today), crashing the
   whole 16→17 upgrade.

   Fix: recompute date_deadline right before the OpenUpgrade script runs, using
   next_recurrence_date as the anchor instead (always current/future by construction) so
   the script's own math lands safely ahead of today. For a recurrence that has already
   completed (next_recurrence_date IS NULL, no next occurrence scheduled), there's no
   sensible replacement date left to compute — delete the recurrence outright, leaving
   its historical tasks orphaned (recurrence_id -> NULL via ON DELETE SET NULL) rather
   than fabricate one; this also removes it from the OpenUpgrade script's query entirely,
   avoiding an invalid repeat_type='after' leftover (removed from the Selection in 17.0).
*/
DELETE FROM project_task_recurrence
WHERE repeat_type = 'after' AND repeat_unit IN ('month','year')
  AND next_recurrence_date IS NULL;

UPDATE project_task
SET date_deadline = ptr.next_recurrence_date - (ptr.repeat_interval || ' ' || ptr.repeat_unit)::interval
FROM project_task_recurrence ptr
WHERE project_task.recurrence_id = ptr.id
  AND ptr.repeat_type = 'after'
  AND ptr.repeat_unit IN ('month', 'year')
  AND project_task.date_deadline IS NOT NULL;
EOF
)
echo "SQL command = $PRE_MIGRATE_SQL_8"
query_postgres_container "$PRE_MIGRATE_SQL_8" ou17 || exit 1

# Copy filestores
copy_filestore ou16 ou16 ou17 ou17 || exit 1

echo "Ready for migration to 17.0!"
