#!/bin/bash
set -euo pipefail

echo "Post migration to 17.0..."

# Execute SQL post-migration commands
POST_MIGRATE_SQL=$(cat <<'EOF'
DO $$
DECLARE
    plan_id INTEGER;
BEGIN
    -- Check if the 'Projects' analytic plan exists
    SELECT id INTO plan_id FROM account_analytic_plan WHERE complete_name = 'migration_PROJECTS' LIMIT 1;

    -- If it does exist, delete it
    IF plan_id IS NOT NULL THEN
        DELETE FROM account_analytic_plan WHERE complete_name = 'migration_PROJECTS';
	SELECT id INTO plan_id FROM account_analytic_plan WHERE complete_name = 'Projects' LIMIT 1;
    	-- Delete existing system parameter (if any)
	DELETE FROM ir_config_parameter WHERE key = 'analytic.project_plan';
	-- Insert the system parameter with the correct plan ID
    	INSERT INTO ir_config_parameter (key, value, create_date, write_date)
    	VALUES ('analytic.project_plan', plan_id::text, now(), now());
    END IF;
END $$;
EOF
)
echo "SQL command = $POST_MIGRATE_SQL"
query_postgres_container "$POST_MIGRATE_SQL" ou17 || exit 1


#compose --debug run ou17 -u base --stop-after-init --no-http
