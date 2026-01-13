#!/bin/bash

# Global variables
ODOO_SERVICE="$1"
DB_NAME="$2"
DB_FINALE_MODEL="$3"
DB_FINALE_SERVICE="$4"

echo "Start database preparation"

# Check POSTGRES container is running
if ! docker ps | grep -q "$DB_CONTAINER_NAME"; then
    printf "Docker container %s is not running.\n" "$DB_CONTAINER_NAME" >&2
    return 1
fi

EXT_EXISTS=$(query_postgres_container "SELECT 1 FROM pg_extension WHERE extname = 'dblink'" "$DB_NAME") || exit 1
if [ "$EXT_EXISTS" != "1" ]; then
    query_postgres_container "CREATE EXTENSION dblink;" "$DB_NAME" || exit 1
fi

# Neutralize the database
SQL_NEUTRALIZE=$(cat <<'EOF'
/* Archive all the mail servers */
UPDATE fetchmail_server SET active = false;
UPDATE ir_mail_server SET active = false;

/* Archive all the cron */
ALTER TABLE ir_cron ADD COLUMN IF NOT EXISTS active_bkp BOOLEAN;
UPDATE ir_cron SET active_bkp = active;
UPDATE ir_cron SET active = False;
EOF
	      )
echo "Neutralize base..."
query_postgres_container "$SQL_NEUTRALIZE" "$DB_NAME" || exit 1
echo "Base neutralized..."

#######################################
## List add-ons not in final version ##
#######################################

# Retrieve add-ons not available on the final Odoo version
SQL_404_ADDONS_LIST="
	SELECT module_origin.name
	FROM ir_module_module module_origin
	LEFT   JOIN (
	   SELECT *
	   FROM   dblink('dbname=$FINALE_DB_NAME','SELECT name, shortdesc, author FROM ir_module_module')
	   AS     tb2(name text, shortdesc text, author text)
	) AS module_dest ON module_dest.name = module_origin.name

	WHERE (module_dest.name IS NULL) AND (module_origin.state = 'installed') AND (module_origin.author NOT IN ('Odoo S.A.', 'Lokavaluto', 'Elabore'))
	ORDER BY module_origin.name
;
"
echo "Retrieve 404 addons... "
echo "SQL REQUEST = $SQL_404_ADDONS_LIST"
query_postgres_container "$SQL_404_ADDONS_LIST" "$DB_NAME" > 404_addons || exit 1

# Keep only the installed add-ons
INSTALLED_ADDONS="SELECT name FROM ir_module_module WHERE state='installed';"
query_postgres_container "$INSTALLED_ADDONS" "$DB_NAME" > installed_addons || exit 1

grep -Fx -f 404_addons installed_addons > final_404_addons
rm -f 404_addons installed_addons

# Ask confirmation to uninstall the selected add-ons
echo "
==== ADD-ONS CHECK ====
Installed add-ons not available in final Odoo version:
"
cat final_404_addons


echo "
Do you accept to migrate the database with all these add-ons still installed? (Y/N/R)"
echo "Y - Yes, let's go on with the upgrade."
echo "N - No, stop the upgrade"
read -n 1 -p "Your choice: " choice
case "$choice" in
    [Yy] ) echo "
Let's go on!";;
    [Nn] ) echo "
Upgrade cancelled!"; exit 1;;
    * ) echo "
Please answer by Y or N.";;
esac


# Check the views
PYTHON_SCRIPT=pre_migration_view_checking.py
echo "Check views with script $PYTHON_SCRIPT ..."
exec_python_script_in_odoo_shell "$DB_NAME" "$DB_NAME" "$PYTHON_SCRIPT" || exit 1

echo "
Do you accept to migrate the database with the current views states? (Y/N/R)"
echo "Y - Yes, let's go on with the upgrade."
echo "N - No, stop the upgrade"
read -n 1 -p "Your choice: " choice
case "$choice" in
    [Yy] ) echo "
Upgrade confirmed!";;
    [Nn] ) echo "
Upgrade cancelled!"; exit 1;;
    * ) echo "
Please answer by Y or N.";;
esac

echo "Database successfully prepared!"
