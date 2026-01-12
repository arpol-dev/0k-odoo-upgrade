#!/bin/bash

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

# Copy filestores
copy_filestore ou16 ou16 ou17 ou17 || exit 1

echo "Ready for migration to 17.0!"
