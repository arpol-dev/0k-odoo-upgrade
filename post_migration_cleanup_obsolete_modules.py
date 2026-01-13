#!/usr/bin/env python3
"""
Post-Migration Obsolete Module Cleanup
Run this AFTER migration to detect and remove modules that exist in the database
but no longer exist in the filesystem (addons paths).
"""

print("\n" + "="*80)
print("POST-MIGRATION OBSOLETE MODULE CLEANUP")
print("="*80 + "\n")

import odoo.modules.module as module_lib

# Get all modules from database
all_modules = env['ir.module.module'].search([])

print(f"Analyzing {len(all_modules)} modules in database...\n")

# Detect obsolete modules (in database but not in filesystem)
obsolete_modules = []
for mod in all_modules:
    mod_path = module_lib.get_module_path(mod.name, display_warning=False)
    if not mod_path:
        obsolete_modules.append(mod)

if not obsolete_modules:
    print("✓ No obsolete modules found! Database is clean.")
    print("=" * 80 + "\n")
    exit()

# Separate modules by state
safe_to_delete = [m for m in obsolete_modules if m.state != 'installed']
installed_obsolete = [m for m in obsolete_modules if m.state == 'installed']

# Display obsolete modules
print(f"Obsolete modules found: {len(obsolete_modules)}\n")

if installed_obsolete:
    print("-" * 80)
    print("⚠️  OBSOLETE INSTALLED MODULES (require attention)")
    print("-" * 80)
    for mod in sorted(installed_obsolete, key=lambda m: m.name):
        print(f"  • {mod.name:40} | ID: {mod.id}")
    print()

if safe_to_delete:
    print("-" * 80)
    print("OBSOLETE UNINSTALLED MODULES (safe to delete)")
    print("-" * 80)
    for mod in sorted(safe_to_delete, key=lambda m: m.name):
        print(f"  • {mod.name:40} | State: {mod.state:15} | ID: {mod.id}")
    print()

# Summary
print("=" * 80)
print("SUMMARY")
print("=" * 80 + "\n")
print(f"  • Obsolete uninstalled modules (safe to delete): {len(safe_to_delete)}")
print(f"  • Obsolete INSTALLED modules (caution!):         {len(installed_obsolete)}")

# Delete uninstalled modules
if safe_to_delete:
    print("\n" + "=" * 80)
    print("DELETING OBSOLETE UNINSTALLED MODULES")
    print("=" * 80 + "\n")

    deleted_count = 0
    failed_deletes = []

    for mod in safe_to_delete:
        try:
            mod_name = mod.name
            mod_id = mod.id
            mod.unlink()
            print(f"✓ Deleted: {mod_name} (ID: {mod_id})")
            deleted_count += 1
        except Exception as e:
            print(f"✗ Failed: {mod.name} - {e}")
            failed_deletes.append({'name': mod.name, 'id': mod.id, 'reason': str(e)})

    # Commit changes
    print("\n" + "=" * 80)
    print("COMMITTING CHANGES")
    print("=" * 80 + "\n")

    try:
        env.cr.commit()
        print("✓ All changes committed successfully!")
    except Exception as e:
        print(f"✗ Commit failed: {e}")
        print("Changes were NOT saved!")
        exit(1)

    # Final result
    print("\n" + "=" * 80)
    print("RESULT")
    print("=" * 80 + "\n")
    print(f"  • Successfully deleted modules: {deleted_count}")
    print(f"  • Failed deletions:             {len(failed_deletes)}")

    if failed_deletes:
        print("\n⚠️  Modules not deleted:")
        for item in failed_deletes:
            print(f"  • {item['name']} (ID: {item['id']}): {item['reason']}")

if installed_obsolete:
    print("\n" + "=" * 80)
    print("⚠️  WARNING: OBSOLETE INSTALLED MODULES")
    print("=" * 80 + "\n")
    print("The following modules are marked 'installed' but no longer exist")
    print("in the filesystem. They may cause problems.\n")
    print("Options:")
    print("  1. Check if these modules were renamed/merged in the new version")
    print("  2. Manually uninstall them if possible")
    print("  3. Force delete them (risky, may break dependencies)\n")

    for mod in sorted(installed_obsolete, key=lambda m: m.name):
        # Find modules that depend on this module
        dependents = env['ir.module.module'].search([
            ('state', '=', 'installed'),
            ('dependencies_id.name', '=', mod.name)
        ])
        dep_info = f" <- Dependents: {dependents.mapped('name')}" if dependents else ""
        print(f"  • {mod.name}{dep_info}")

print("\n" + "=" * 80)
print("CLEANUP COMPLETED!")
print("=" * 80 + "\n")
