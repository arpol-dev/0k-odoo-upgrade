#!/usr/bin/env python3
"""
Pre-Migration Cleanup Script for Odoo
Run this BEFORE migrating to identify and clean up custom views.

Usage: odoo shell -d dbname < pre_migration_cleanup.py
"""

print("\n" + "="*80)
print("PRE-MIGRATION CLEANUP - VIEW ANALYSIS")
print("="*80 + "\n")

# 1. Find all custom (COW) views
print("STEP 1: Identifying Custom/COW Views")
print("-"*80)

all_views = env['ir.ui.view'].search(['|', ('active', '=', True), ('active', '=', False)])
cow_views = all_views.filtered(lambda v: not v.model_data_id)

print(f"Total views in database: {len(all_views)}")
print(f"Custom views (no module): {len(cow_views)}")
print(f"Module views: {len(all_views) - len(cow_views)}\n")

if cow_views:
    print("Custom views found:\n")
    print(f"{'ID':<8} {'Active':<8} {'Key':<50} {'Name':<40}")
    print("-"*120)

    for view in cow_views[:50]:  # Show first 50
        active_str = "✓" if view.active else "✗"
        key_str = view.key[:48] if view.key else "N/A"
        name_str = view.name[:38] if view.name else "N/A"
        print(f"{view.id:<8} {active_str:<8} {key_str:<50} {name_str:<40}")

    if len(cow_views) > 50:
        print(f"\n... and {len(cow_views) - 50} more custom views")

# 2. Find duplicate views
print("\n" + "="*80)
print("STEP 2: Finding Duplicate Views (Same Key)")
print("-"*80 + "\n")

from collections import defaultdict

keys = defaultdict(list)
for view in all_views.filtered(lambda v: v.key and v.active):
    keys[view.key].append(view)

duplicates = {k: v for k, v in keys.items() if len(v) > 1}

print(f"Found {len(duplicates)} keys with duplicate views:\n")

if duplicates:
    for key, views in sorted(duplicates.items()):
        print(f"\nKey: {key} ({len(views)} duplicates)")
        for view in views:
            module = view.model_data_id.module if view.model_data_id else "⚠️  Custom/DB"
            print(f"  ID {view.id:>6}: {module:<25} | {view.name}")

# 3. Find views that might have xpath issues
print("\n" + "="*80)
print("STEP 3: Finding Views with XPath Expressions")
print("-"*80 + "\n")

import re

views_with_xpath = []
xpath_pattern = r'<xpath[^>]+expr="([^"]+)"'

for view in all_views.filtered(lambda v: v.active and v.inherit_id):
    xpaths = re.findall(xpath_pattern, view.arch_db)
    if xpaths:
        views_with_xpath.append({
            'view': view,
            'xpaths': xpaths,
            'is_custom': not bool(view.model_data_id)
        })

print(f"Found {len(views_with_xpath)} views with xpath expressions")

custom_xpath_views = [v for v in views_with_xpath if v['is_custom']]
print(f"  - {len(custom_xpath_views)} are custom views (potential issue!)")
print(f"  - {len(views_with_xpath) - len(custom_xpath_views)} are module views\n")

if custom_xpath_views:
    print("Custom views with xpaths (risk for migration issues):\n")
    for item in custom_xpath_views:
        view = item['view']
        print(f"ID {view.id}: {view.name}")
        print(f"  Key: {view.key}")
        print(f"  Inherits from: {view.inherit_id.key}")
        print(f"  XPath count: {len(item['xpaths'])}")
        print(f"  Sample xpaths: {item['xpaths'][:2]}")
        print()

# 4. Summary and recommendations
print("=" * 80)
print("SUMMARY AND RECOMMENDATIONS")
print("=" * 80 + "\n")

print(f"📊 Statistics:")
print(f"  • Total views: {len(all_views)}")
print(f"  • Custom views: {len(cow_views)}")
print(f"  • Duplicate view keys: {len(duplicates)}")
print(f"  • Custom views with xpaths: {len(custom_xpath_views)}\n")

print(f"\n📋 RECOMMENDED ACTIONS BEFORE MIGRATION:\n")

if custom_xpath_views:
    print(f"1. Archive or delete {len(custom_xpath_views)} custom views with xpaths:")
    print(f"   • Review each one and determine if still needed")
    print(f"   • Archive unnecessary ones: env['ir.ui.view'].browse([ids]).write({{'active': False}})")
    print(f"   • Plan to recreate important ones as proper module views after migration\n")

if duplicates:
    print(f"2. Fix {len(duplicates)} duplicate view keys:")
    print(f"   • Manually review and delete obsolete duplicates, keeping the most appropriate one")
    print(f"   • Document the remaining appropriate ones as script post_migration_fix_duplicated_views.py will run AFTER the migration and delete all duplicates.\n")

if cow_views:
    print(f"3. Review {len(cow_views)} custom views:")
    print(f"   • Document which ones are important")
    print(f"   • Export their XML for reference")
    print(f"   • Consider converting to module views\n")

print("=" * 80 + "\n")
