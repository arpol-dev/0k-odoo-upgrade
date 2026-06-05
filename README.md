# 0k-odoo-upgrade

A tool for migrating Odoo databases between major versions, using [OpenUpgrade](https://github.com/OCA/OpenUpgrade) in a production-like Docker environment.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Project Structure](#project-structure)
- [How It Works](#how-it-works)
- [Usage](#usage)
- [Resuming a Failed Migration](#resuming-a-failed-migration)
- [Customization](#customization)
- [Troubleshooting](#troubleshooting)

## Prerequisites

- [0k dev-pack](https://git.myceliandre.fr/Lokavaluto/dev-pack) installed (provides the `compose` command)
- Docker and Docker Compose
- `rsync` for filestore copying
- `sudo` access for filestore operations

## Installation

```bash
git clone <repository-url>
cd 0k-odoo-upgrade
```

## Project Structure

```
.
├── upgrade.sh                 # Main entry point
│
├── config/
│   └── compose.yml            # Docker Compose configuration
│
├── lib/
│   ├── common.sh              # Shared bash functions
│   └── python/                # Python utility scripts
│       ├── check_views.py           # View analysis (pre-migration)
│       ├── validate_views.py        # View validation (post-migration)
│       ├── fix_duplicated_views.py  # Fix duplicated views
│       └── cleanup_modules.py       # Obsolete module cleanup
│
├── scripts/
│   ├── prepare_db.sh          # Database preparation before migration
│   ├── finalize_db.sh         # Post-migration finalization
│   └── validate_migration.sh  # Manual post-migration validation
│
└── versions/                  # Version-specific scripts
    ├── 13.0/
    │   ├── pre_upgrade.sh     # SQL fixes before migration
    │   ├── upgrade.sh         # OpenUpgrade execution
    │   └── post_upgrade.sh    # Fixes after migration
    ├── 14.0/
    ├── ...
    └── 18.0/
```

## How It Works

### Overview

The script performs a **step-by-step migration** between each major version. For example, to migrate from 14.0 to 17.0, it executes:

```
14.0 → 15.0 → 16.0 → 17.0
```

### Process Steps

1. **Initial Checks**
   - Argument validation
   - Required command verification (`docker`, `compose`, `sudo`, `rsync`)
   - Source database and filestore existence check

2. **Environment Preparation**
   - Creation of a fresh Odoo database in the target version (for module comparison)
   - Copy of the source database to a working database
   - Filestore copy

3. **Database Preparation** (`scripts/prepare_db.sh`)
   - Neutralization: disable mail servers and cron jobs
   - Detection of installed modules missing in the target version
   - View state verification
   - User confirmation prompt

4. **Migration Loop** (for each intermediate version)
   - `pre_upgrade.sh`: version-specific SQL fixes before migration
   - `upgrade.sh`: OpenUpgrade execution via Docker
   - `post_upgrade.sh`: fixes after migration

5. **Finalization** (`scripts/finalize_db.sh`)
   - Obsolete sequence removal
   - Modified website template reset
   - Compiled asset cache purge
   - Duplicated view fixes
   - Obsolete module cleanup
   - Final update with `-u all`

### Flow Diagram

```
┌─────────────────┐
│   upgrade.sh    │
└────────┬────────┘
         │
         ▼
┌─────────────────┐     ┌─────────────────┐
│ Initial         │────▶│ Copy DB +       │
│ checks          │     │ filestore       │
└─────────────────┘     └────────┬────────┘
                                 │
                                 ▼
                        ┌─────────────────┐
                        │ prepare_db.sh   │
                        │ (neutralization)│
                        └────────┬────────┘
                                 │
         ┌───────────────────────┼───────────────────────┐
         │                       │                       │
         ▼                       ▼                       ▼
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ versions/13.0/  │────▶│ versions/14.0/  │────▶│ versions/N.0/   │
│ pre/upgrade/post│     │ pre/upgrade/post│     │ pre/upgrade/post│
└─────────────────┘     └─────────────────┘     └────────┬────────┘
                                                         │
                                                         ▼
                                                ┌─────────────────┐
                                                │ finalize_db.sh  │
                                                │ (cleanup)       │
                                                └─────────────────┘
```

## Usage

### Before Migration

1. **Import the source database** to your local machine

2. **Clean up the source database** (recommended)
   - Uninstall unnecessary modules
   - Do NOT uninstall modules handled by OpenUpgrade

3. **Check module availability**
   - Ensure all custom modules are ported to the target version

4. **Start the Docker environment**
   ```bash
   # Start the PostgreSQL container
   compose up -d postgres

   # Verify only one postgres container is running
   docker ps | grep postgres
   ```

### Running the Migration

```bash
./upgrade.sh <source_version> <target_version> <database_name> <source_service> [--resume-from|-r <version>]
```

**Parameters:**
| Parameter | Description | Example |
|-----------|-------------|---------|
| `source_version` | Source Odoo version (without .0) | `14` |
| `target_version` | Target Odoo version (without .0) | `17` |
| `database_name` | Database name | `my_prod_db` |
| `source_service` | Source Docker Compose service | `odoo14` |

**Options:**
| Option | Description |
|--------|-------------|
| `--resume-from <version>`, `-r <version>` | Resume from an intermediate checkpoint (see [Resuming a Failed Migration](#resuming-a-failed-migration)) |

**Example:**
```bash
./upgrade.sh 14 17 elabore_20241208 odoo14
```

### During Migration

The script will prompt for confirmation at two points:

1. **Missing modules list**: installed modules that don't exist in the target version
   - `Y`: continue (modules will be marked for removal)
   - `N`: abort to manually uninstall certain modules

2. **View state**: verification of potentially problematic views
   - `Y`: continue
   - `N`: abort to manually fix issues

### After Migration

1. **Review logs** to detect any non-blocking errors

2. **Validate the migration** (see [Post-Migration Validation](#post-migration-validation))

3. **Test the migrated database** locally

4. **Deploy to production**
   ```bash
   # Export the migrated database
   vps odoo dump db_migrated.zip

   # On the production server
   vps odoo restore db_migrated.zip
   ```

## Post-Migration Validation

After migration, use the validation script to check for broken views and XPath errors.

### Quick Start

```bash
./scripts/validate_migration.sh ou17 odoo17
```

### What Gets Validated

Runs in Odoo shell, no HTTP server needed:

| Check | Description |
|-------|-------------|
| **Inherited views** | Verifies all inherited views can combine with their parent |
| **XPath targets** | Ensures XPath expressions find their targets in parent views |
| **QWeb templates** | Validates QWeb templates are syntactically correct |
| **Field references** | Checks that field references point to existing model fields |
| **Odoo native** | Runs Odoo's built-in `_validate_custom_views()` |

### Running Directly

You can also run the Python script directly in Odoo shell:

```bash
compose run odoo17 shell -d ou17 --no-http --stop-after-init < lib/python/validate_views.py
```

### Output

- **Colored terminal output** with `[OK]`, `[ERROR]`, `[WARN]` indicators
- **JSON report** written to `/tmp/validation_views_<db>_<timestamp>.json`
- **Exit code**: `0` = success, `1` = errors found

## Resuming a Failed Migration

Each version hop copies the database before modifying it (`ou14` → `ou15` → `ou16` → …). If a migration crashes mid-way, the intermediate databases from completed hops are still intact and can be used as a restart point.

### How It Works

Use `--resume-from <version>` (or `-r <version>`) to restart from an intermediate checkpoint:

```bash
./upgrade.sh <source_version> <target_version> <database_name> <source_service> --resume-from <checkpoint_version>
```

When a checkpoint is specified, the script:
- **Skips** the initial database and filestore copy
- **Skips** `prepare_db.sh` (already done before the crash)
- **Starts the migration loop** from `checkpoint_version + 1`

### Example

A migration from 14 to 18 crashes during the 16→17 hop. The database `ou15` was successfully created. Resume from there:

```bash
./upgrade.sh 14 18 my_database odoo14 --resume-from 15
```

This runs: `16.0 → 17.0 → 18.0`, starting from `ou15`.

### Constraints

- The checkpoint version must be strictly between the source and target versions.
- The intermediate database (`ou<version>`) and its filestore must exist before resuming.

### Restarting From Scratch

To restart a full migration from the beginning (ignoring all intermediate databases):

```bash
./upgrade.sh 14 18 my_database odoo14
```

The script automatically drops and recreates the final target database (`ou18`) if it already exists.

## Customization

### Version Scripts

Each `versions/X.0/` directory contains three scripts you can customize:

#### `pre_upgrade.sh`
Executed **before** OpenUpgrade. Use it to:
- Add missing columns expected by OpenUpgrade
- Fix incompatible data
- Remove problematic records

```bash
#!/bin/bash
set -euo pipefail

echo "Prepare migration to 15.0..."

copy_database ou14 ou15 ou15

PRE_MIGRATE_SQL=$(cat <<'EOF'
-- Example: remove a problematic module
DELETE FROM ir_module_module WHERE name = 'obsolete_module';
EOF
)
query_postgres_container "$PRE_MIGRATE_SQL" ou15

copy_filestore ou14 ou14 ou15 ou15

echo "Ready for migration to 15.0!"
```

#### `upgrade.sh`
Runs OpenUpgrade migration scripts.

#### `post_upgrade.sh`
Executed **after** OpenUpgrade. Use it to:
- Fix incorrectly migrated data
- Remove orphan records
- Update system parameters

```bash
#!/bin/bash
set -euo pipefail

echo "Post migration to 15.0..."

POST_MIGRATE_SQL=$(cat <<'EOF'
-- Example: fix a configuration value
UPDATE ir_config_parameter
SET value = 'new_value'
WHERE key = 'my_key';
EOF
)
query_postgres_container "$POST_MIGRATE_SQL" ou15
```

### Available Functions

Version scripts have access to functions defined in `lib/common.sh`:

| Function | Description |
|----------|-------------|
| `query_postgres_container "$SQL" "$DB"` | Execute an SQL query |
| `copy_database $from $to_service $to_db` | Copy a PostgreSQL database |
| `copy_filestore $from_svc $from_db $to_svc $to_db` | Copy a filestore |
| `log_info`, `log_warn`, `log_error` | Logging functions |
| `log_step "title"` | Display a section header |

### Adding a New Version

To add support for a new version (e.g., 19.0):

```bash
mkdir versions/19.0
cp versions/18.0/*.sh versions/19.0/

# Edit the scripts to:
# - Change references from ou18 → ou19
# - Change the port from -p 8018:8069 → -p 8019:8069
# - Add SQL fixes specific to this migration
```

## Troubleshooting

### Common Issues

#### "No running PostgreSQL container found"
```bash
# Check active containers
docker ps | grep postgres

# Start the container if needed
compose up -d postgres
```

#### "Multiple PostgreSQL containers found"
Stop the extra PostgreSQL containers:
```bash
docker stop <container_name_to_stop>
```

#### "Database not found"
The source database must exist in PostgreSQL:
```bash
# List databases
docker exec -u 70 <postgres_container> psql -l

# Import a database if needed
docker exec -u 70 <postgres_container> pgm restore <file.zip>
```

#### "Filestore not found"
The filestore must be present at `/srv/datastore/data/<service>/var/lib/odoo/filestore/<database>/`

### Restarting After an Error

The script works on a **copy** of the original database. You can restart as many times as needed:

```bash
# Simply restart - the copy will be recreated
./upgrade.sh 14 17 my_database odoo14
```

### Viewing Detailed Logs

Odoo/OpenUpgrade logs are displayed in real-time. For a problematic migration:

1. Note the version where the error occurs
2. Check the logs to identify the problematic module/table
3. Add a fix in the `pre_upgrade.sh` for that version
4. Restart the migration

## License

See the [LICENSE](LICENSE) file.
