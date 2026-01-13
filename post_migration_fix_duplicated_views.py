#!/usr/bin/env python3
"""
Post-Migration Duplicate View Fixer
Run this AFTER migration to fix duplicate views automatically.
"""

print("\n" + "="*80)
print("POST-MIGRATION DUPLICATE VIEW FIXER")
print("="*80 + "\n")

from collections import defaultdict

# Find all duplicate views
all_views = env['ir.ui.view'].search(['|', ('active', '=', True), ('active', '=', False)])
keys = defaultdict(list)

for view in all_views:
    if view.key:
        keys[view.key].append(view)

duplicates = {k: v for k, v in keys.items() if len(v) > 1}

print(f"Found {len(duplicates)} keys with duplicate views\n")

if not duplicates:
    print("✓ No duplicate views found! Database is clean.")
    print("=" * 80 + "\n")
    exit()

# Process duplicates
views_to_delete = []
redirect_log = []

for key, views in sorted(duplicates.items()):
    print(f"\nProcessing key: {key}")
    print("-" * 80)

    # Sort views: module views first, then by ID (older first)
    sorted_views = sorted(views, key=lambda v: (
        0 if v.model_data_id else 1,  # Module views first
        v.id  # Older views first (lower ID = older)
    ))

    # Keep the first view (should be module view or oldest)
    keep = sorted_views[0]
    to_delete = sorted_views[1:]

    module_keep = keep.model_data_id.module if keep.model_data_id else "Custom/DB"
    print(f"KEEP:   ID {keep.id:>6} | Module: {module_keep:<20} | {keep.name}")

    for view in to_delete:
        module = view.model_data_id.module if view.model_data_id else "Custom/DB"
        print(f"DELETE: ID {view.id:>6} | Module: {module:<20} | {view.name}")

        # Find and redirect children
        children = env['ir.ui.view'].search([('inherit_id', '=', view.id)])
        if children:
            print(f"        → Redirecting {len(children)} children {children.ids} to view {keep.id}")
            for child in children:
                child_module = child.model_data_id.module if child.model_data_id else "Custom/DB"
                redirect_log.append({
                    'child_id': child.id,
                    'child_name': child.name,
                    'child_module': child_module,
                    'from': view.id,
                    'to': keep.id
                })
            try:
                children.write({'inherit_id': keep.id})
                print(f"        ✓ Redirected successfully")
            except Exception as e:
                print(f"        ✗ Redirect failed: {e}")
                continue

        views_to_delete.append(view)

# Summary before deletion
print("\n" + "="*80)
print("SUMMARY")
print("="*80 + "\n")

print(f"Views to delete: {len(views_to_delete)}")
print(f"Child views to redirect: {len(redirect_log)}\n")

if redirect_log:
    print("Redirections that will be performed:")
    for item in redirect_log[:10]:  # Show first 10
        print(f"  • View {item['child_id']} ({item['child_module']})")
        print(f"    '{item['child_name']}'")
        print(f"    Parent: {item['from']} → {item['to']}")

    if len(redirect_log) > 10:
        print(f"  ... and {len(redirect_log) - 10} more redirections")

# Delete duplicate views
print("\n" + "="*80)
print("DELETING DUPLICATE VIEWS")
print("="*80 + "\n")

deleted_count = 0
failed_deletes = []

# Sort views by ID descending (delete newer/child views first)
views_to_delete_sorted = sorted(views_to_delete, key=lambda v: v.id, reverse=True)

for view in views_to_delete_sorted:
    try:
        # Create savepoint to isolate each deletion
        env.cr.execute('SAVEPOINT delete_view')

        view_id = view.id
        view_name = view.name
        view_key = view.key

        # Double-check it has no children
        remaining_children = env['ir.ui.view'].search([('inherit_id', '=', view_id)])
        if remaining_children:
            print(f"⚠️  Skipping view {view_id}: Still has {len(remaining_children)} children")
            failed_deletes.append({
                'id': view_id,
                'reason': f'Still has {len(remaining_children)} children'
            })
            env.cr.execute('ROLLBACK TO SAVEPOINT delete_view')
            continue

        view.unlink()
        env.cr.execute('RELEASE SAVEPOINT delete_view')
        print(f"✓ Deleted view {view_id}: {view_key}")
        deleted_count += 1

    except Exception as e:
        env.cr.execute('ROLLBACK TO SAVEPOINT delete_view')
        print(f"✗ Failed to delete view {view.id}: {e}")
        failed_deletes.append({
            'id': view.id,
            'name': view.name,
            'reason': str(e)
        })

# Commit changes
print("\n" + "="*80)
print("COMMITTING CHANGES")
print("="*80 + "\n")

try:
    env.cr.commit()
    print("✓ All changes committed successfully!")
except Exception as e:
    print(f"✗ Commit failed: {e}")
    print("Changes were NOT saved!")
    exit(1)

# Final verification
print("\n" + "="*80)
print("FINAL VERIFICATION")
print("="*80 + "\n")

# Re-check for duplicates
all_views_after = env['ir.ui.view'].search([('active', '=', True)])
keys_after = defaultdict(list)

for view in all_views_after:
    if view.key:
        keys_after[view.key].append(view)

duplicates_after = {k: v for k, v in keys_after.items() if len(v) > 1}

print(f"Results:")
print(f"  • Successfully deleted: {deleted_count} views")
print(f"  • Failed deletions: {len(failed_deletes)}")
print(f"  • Child views redirected: {len(redirect_log)}")
print(f"  • Remaining duplicates: {len(duplicates_after)}")

if failed_deletes:
    print(f"\n⚠️  Failed deletions:")
    for item in failed_deletes:
        print(f"  • View {item['id']}: {item['reason']}")

if duplicates_after:
    print(f"\n⚠️  Still have {len(duplicates_after)} duplicate keys:")
    for key, views in sorted(duplicates_after.items())[:5]:
        print(f"  • {key}: {len(views)} views")
        for view in views:
            module = view.model_data_id.module if view.model_data_id else "Custom/DB"
            print(f"    - ID {view.id} ({module})")
    print(f"\n  Run this script again to attempt another cleanup.")
else:
    print(f"\n✓ All duplicates resolved!")

print("\n" + "="*80)
print("FIX COMPLETED!")
print("="*80)
