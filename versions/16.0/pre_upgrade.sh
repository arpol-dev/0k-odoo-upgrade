#!/bin/bash
set -euo pipefail

echo "Prepare migration to 16.0..."

# Copy database
copy_database ou15 ou16 ou16 || exit 1

# Execute SQL pre-migration commands
PRE_MIGRATE_SQL=$(cat <<'EOF'
/* Odoo 16.0 ships the Swiss cantons in base (base.state_ch_<code>, 71 rows,
   e.g. state_ch_zh / state_ch_zh_it); 15.0 did not. A database that already
   holds CH states (manual import, l10n/OCA module...) makes the base data load
   INSERT a duplicate and violate res_country_state_name_code_uniq
   (country_id, code).
   Deleting the existing rows is not an option: res.partner.state_id is
   ondelete='restrict'. Instead, attach the base xml-id to each existing state
   whose code matches a 16.0 base canton, so the data load UPDATEs it in place
   and partner references are preserved. Idempotent. */
INSERT INTO ir_model_data (module, name, model, res_id, noupdate, create_date, write_date)
SELECT 'base', 'state_ch_' || lower(replace(s.code, '-', '_')), 'res.country.state', s.id, false,
       now() AT TIME ZONE 'UTC', now() AT TIME ZONE 'UTC'
FROM res_country_state s
JOIN res_country c ON c.id = s.country_id AND c.code = 'CH'
WHERE s.code IN ('ZH','ZH-IT','ZH-FR','BE','BE-IT','BE-FR','LU','LU-IT','LU-FR','UR','SZ','SZ-IT','OW','OW-IT','OW-FR','NW','NW-IT','NW-FR','GL','GL-IT','GL-FR','ZG','ZG-IT','ZG-FR','FR','FR-IT','FR-FR','SO','SO-IT','SO-FR','BS','BS-IT','BS-FR','BL','BL-IT','BL-FR','SH','SH-IT','SH-FR','AR','AR-IT','AR-FR','AI','AI-IT','AI-FR','SG','SG-IT','SG-FR','GR','GR-IT','GR-FR','AG','AG-IT','AG-FR','TG','TG-IT','TG-FR','TI','TI-IT','VD','VD-FR','VS','VS-IT','VS-FR','NE','NE-FR','GE','GE-IT','GE-FR','JU','JU-IT')
AND NOT EXISTS (
    SELECT 1 FROM ir_model_data d
    WHERE d.module = 'base' AND d.name = 'state_ch_' || lower(replace(s.code, '-', '_'))
);
EOF
)
echo "SQL command = $PRE_MIGRATE_SQL"
query_postgres_container "$PRE_MIGRATE_SQL" ou16 || exit 1

# Copy filestores
copy_filestore ou15 ou15 ou16 ou16 || exit 1

echo "Ready for migration to 16.0!"
