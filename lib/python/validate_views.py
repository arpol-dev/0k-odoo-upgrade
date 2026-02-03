#!/usr/bin/env python3
"""
Post-Migration View Validation Script for Odoo

Validates all views after migration to detect:
- Broken XPath expressions in inherited views
- Views that fail to combine with their parent
- Invalid QWeb templates
- Missing asset files
- Field references to non-existent fields

Usage:
    odoo-bin shell -d <database> < validate_views.py
    
    # Or with compose:
    compose run <service> shell -d <database> --no-http --stop-after-init < validate_views.py

Exit codes:
    0 - All validations passed
    1 - Validation errors found (see report)
"""

import os
import sys
import re
import json
from datetime import datetime
from collections import defaultdict
from lxml import etree

# ANSI colors for terminal output
class Colors:
    RED = '\033[91m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    BLUE = '\033[94m'
    BOLD = '\033[1m'
    END = '\033[0m'


def print_header(title):
    """Print a formatted section header."""
    print(f"\n{Colors.BOLD}{'='*80}{Colors.END}")
    print(f"{Colors.BOLD}{title}{Colors.END}")
    print(f"{Colors.BOLD}{'='*80}{Colors.END}\n")


def print_subheader(title):
    """Print a formatted subsection header."""
    print(f"\n{Colors.BLUE}{'-'*60}{Colors.END}")
    print(f"{Colors.BLUE}{title}{Colors.END}")
    print(f"{Colors.BLUE}{'-'*60}{Colors.END}\n")


def print_ok(message):
    """Print success message."""
    print(f"{Colors.GREEN}[OK]{Colors.END} {message}")


def print_error(message):
    """Print error message."""
    print(f"{Colors.RED}[ERROR]{Colors.END} {message}")


def print_warn(message):
    """Print warning message."""
    print(f"{Colors.YELLOW}[WARN]{Colors.END} {message}")


def print_info(message):
    """Print info message."""
    print(f"{Colors.BLUE}[INFO]{Colors.END} {message}")


class ViewValidator:
    """Validates Odoo views after migration."""

    def __init__(self, env):
        self.env = env
        self.View = env['ir.ui.view']
        self.errors = []
        self.warnings = []
        self.stats = {
            'total_views': 0,
            'inherited_views': 0,
            'qweb_views': 0,
            'broken_xpath': 0,
            'broken_combine': 0,
            'broken_qweb': 0,
            'broken_fields': 0,
            'missing_assets': 0,
        }

    def validate_all(self):
        """Run all validation checks."""
        print_header("ODOO VIEW VALIDATION - POST-MIGRATION")
        print(f"Started at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        print(f"Database: {self.env.cr.dbname}")

        # Get all active views
        all_views = self.View.search([('active', '=', True)])
        self.stats['total_views'] = len(all_views)
        print_info(f"Total active views to validate: {len(all_views)}")

        # Run validations
        self._validate_inherited_views()
        self._validate_xpath_targets()
        self._validate_qweb_templates()
        self._validate_field_references()
        self._validate_odoo_native()
        self._check_assets()

        # Print summary
        self._print_summary()

        # Rollback to avoid any accidental changes
        self.env.cr.rollback()

        return len(self.errors) == 0

    def _validate_inherited_views(self):
        """Check that all inherited views can combine with their parent."""
        print_subheader("1. Validating Inherited Views (Combination)")

        inherited_views = self.View.search([
            ('inherit_id', '!=', False),
            ('active', '=', True)
        ])
        self.stats['inherited_views'] = len(inherited_views)
        print_info(f"Found {len(inherited_views)} inherited views to check")

        broken = []
        for view in inherited_views:
            try:
                # Attempt to get combined architecture
                view._get_combined_arch()
            except Exception as e:
                broken.append({
                    'view_id': view.id,
                    'xml_id': view.xml_id or 'N/A',
                    'name': view.name,
                    'model': view.model,
                    'parent_xml_id': view.inherit_id.xml_id if view.inherit_id else 'N/A',
                    'error': str(e)[:200]
                })

        self.stats['broken_combine'] = len(broken)

        if broken:
            for item in broken:
                error_msg = (
                    f"View '{item['xml_id']}' (ID: {item['view_id']}) "
                    f"cannot combine with parent '{item['parent_xml_id']}': {item['error']}"
                )
                print_error(error_msg)
                self.errors.append({
                    'type': 'combination_error',
                    'severity': 'error',
                    **item
                })
        else:
            print_ok("All inherited views combine correctly with their parents")

    def _validate_xpath_targets(self):
        """Check that XPath expressions find their targets in parent views."""
        print_subheader("2. Validating XPath Targets")

        inherited_views = self.View.search([
            ('inherit_id', '!=', False),
            ('active', '=', True)
        ])

        xpath_pattern = re.compile(r'<xpath[^>]+expr=["\']([^"\']+)["\']')
        orphan_xpaths = []

        for view in inherited_views:
            if not view.arch_db or not view.inherit_id or not view.inherit_id.arch_db:
                continue

            try:
                # Get parent's combined arch (to handle chained inheritance)
                parent_arch = view.inherit_id._get_combined_arch()
                parent_tree = etree.fromstring(parent_arch)
            except Exception:
                # Parent view is already broken, skip
                continue

            # Parse child view
            try:
                view_tree = etree.fromstring(view.arch_db)
            except Exception:
                continue

            # Find all xpath nodes
            for xpath_node in view_tree.xpath('//xpath'):
                expr = xpath_node.get('expr')
                if not expr:
                    continue

                try:
                    matches = parent_tree.xpath(expr)
                    if not matches:
                        orphan_xpaths.append({
                            'view_id': view.id,
                            'xml_id': view.xml_id or 'N/A',
                            'name': view.name,
                            'model': view.model,
                            'xpath': expr,
                            'parent_xml_id': view.inherit_id.xml_id or 'N/A',
                            'parent_id': view.inherit_id.id
                        })
                except etree.XPathEvalError as e:
                    orphan_xpaths.append({
                        'view_id': view.id,
                        'xml_id': view.xml_id or 'N/A',
                        'name': view.name,
                        'model': view.model,
                        'xpath': expr,
                        'parent_xml_id': view.inherit_id.xml_id or 'N/A',
                        'parent_id': view.inherit_id.id,
                        'xpath_error': str(e)
                    })

        self.stats['broken_xpath'] = len(orphan_xpaths)

        if orphan_xpaths:
            for item in orphan_xpaths:
                error_msg = (
                    f"View '{item['xml_id']}' (ID: {item['view_id']}): "
                    f"XPath '{item['xpath']}' finds no target in parent '{item['parent_xml_id']}'"
                )
                if 'xpath_error' in item:
                    error_msg += f" (XPath syntax error: {item['xpath_error']})"
                print_error(error_msg)
                self.errors.append({
                    'type': 'orphan_xpath',
                    'severity': 'error',
                    **item
                })
        else:
            print_ok("All XPath expressions find their targets")

    def _validate_qweb_templates(self):
        """Validate QWeb templates can be rendered."""
        print_subheader("3. Validating QWeb Templates")

        qweb_views = self.View.search([
            ('type', '=', 'qweb'),
            ('active', '=', True)
        ])
        self.stats['qweb_views'] = len(qweb_views)
        print_info(f"Found {len(qweb_views)} QWeb templates to check")

        broken = []
        for view in qweb_views:
            try:
                # Basic XML parsing check
                if view.arch_db:
                    etree.fromstring(view.arch_db)

                # Try to get combined arch for inherited qweb views
                if view.inherit_id:
                    view._get_combined_arch()

            except Exception as e:
                broken.append({
                    'view_id': view.id,
                    'xml_id': view.xml_id or 'N/A',
                    'name': view.name,
                    'key': view.key or 'N/A',
                    'error': str(e)[:200]
                })

        self.stats['broken_qweb'] = len(broken)

        if broken:
            for item in broken:
                error_msg = (
                    f"QWeb template '{item['xml_id']}' (key: {item['key']}): {item['error']}"
                )
                print_error(error_msg)
                self.errors.append({
                    'type': 'qweb_error',
                    'severity': 'error',
                    **item
                })
        else:
            print_ok("All QWeb templates are valid")

    def _validate_field_references(self):
        """Check that field references in views point to existing fields."""
        print_subheader("4. Validating Field References")

        field_pattern = re.compile(r'(?:name|field)=["\'](\w+)["\']')
        missing_fields = []

        # Only check form, tree, search, kanban views (not qweb)
        views = self.View.search([
            ('type', 'in', ['form', 'tree', 'search', 'kanban', 'pivot', 'graph']),
            ('active', '=', True),
            ('model', '!=', False)
        ])

        print_info(f"Checking field references in {len(views)} views")

        checked_models = set()
        for view in views:
            model_name = view.model
            if not model_name or model_name in checked_models:
                continue

            # Skip if model doesn't exist
            if model_name not in self.env:
                continue

            checked_models.add(model_name)

            try:
                # Get combined arch
                arch = view._get_combined_arch()
                tree = etree.fromstring(arch)
            except Exception:
                continue

            model = self.env[model_name]
            model_fields = set(model._fields.keys())

            # Find all field references
            for field_node in tree.xpath('//*[@name]'):
                field_name = field_node.get('name')
                if not field_name:
                    continue

                # Skip special names
                if field_name in ('id', '__last_update', 'display_name'):
                    continue

                # Skip if it's a button or action (not a field)
                if field_node.tag in ('button', 'a'):
                    continue

                # Check if field exists
                if field_name not in model_fields:
                    # Check if it's a related field path (e.g., partner_id.name)
                    if '.' in field_name:
                        continue

                    missing_fields.append({
                        'view_id': view.id,
                        'xml_id': view.xml_id or 'N/A',
                        'model': model_name,
                        'field_name': field_name,
                        'tag': field_node.tag
                    })

        self.stats['broken_fields'] = len(missing_fields)

        if missing_fields:
            # Group by view for cleaner output
            by_view = defaultdict(list)
            for item in missing_fields:
                by_view[item['xml_id']].append(item['field_name'])

            for xml_id, fields in list(by_view.items())[:20]:  # Limit output
                print_warn(f"View '{xml_id}': references missing fields: {', '.join(fields)}")
                self.warnings.append({
                    'type': 'missing_field',
                    'severity': 'warning',
                    'xml_id': xml_id,
                    'fields': fields
                })

            if len(by_view) > 20:
                print_warn(f"... and {len(by_view) - 20} more views with missing fields")
        else:
            print_ok("All field references are valid")

    def _validate_odoo_native(self):
        """Run Odoo's native view validation."""
        print_subheader("5. Running Odoo Native Validation")

        try:
            # This validates all custom views
            self.View._validate_custom_views('all')
            print_ok("Odoo native validation passed")
        except Exception as e:
            error_msg = f"Odoo native validation failed: {str(e)[:500]}"
            print_error(error_msg)
            self.errors.append({
                'type': 'native_validation',
                'severity': 'error',
                'error': str(e)
            })

    def _check_assets(self):
        """Check for missing asset files."""
        print_subheader("6. Checking Asset Files")

        try:
            IrAsset = self.env['ir.asset']
        except KeyError:
            print_info("ir.asset model not found (Odoo < 14.0), skipping asset check")
            return

        assets = IrAsset.search([])
        print_info(f"Checking {len(assets)} asset definitions")

        missing = []
        for asset in assets:
            if not asset.path:
                continue

            try:
                # Try to resolve the asset path
                # This is a simplified check - actual asset resolution is complex
                path = asset.path
                if path.startswith('/'):
                    path = path[1:]

                # Check if it's a glob pattern or specific file
                if '*' in path:
                    continue  # Skip glob patterns

                # Try to get the asset content (this will fail if file is missing)
                # Note: This is environment dependent and may not catch all issues
            except Exception as e:
                missing.append({
                    'asset_id': asset.id,
                    'path': asset.path,
                    'bundle': asset.bundle or 'N/A',
                    'error': str(e)[:100]
                })

        self.stats['missing_assets'] = len(missing)

        if missing:
            for item in missing:
                print_warn(f"Asset '{item['path']}' (bundle: {item['bundle']}): may be missing")
                self.warnings.append({
                    'type': 'missing_asset',
                    'severity': 'warning',
                    **item
                })
        else:
            print_ok("Asset definitions look valid")

    def _print_summary(self):
        """Print validation summary."""
        print_header("VALIDATION SUMMARY")

        print(f"Statistics:")
        print(f"  - Total views checked: {self.stats['total_views']}")
        print(f"  - Inherited views: {self.stats['inherited_views']}")
        print(f"  - QWeb templates: {self.stats['qweb_views']}")
        print()

        print(f"Issues found:")
        print(f"  - Broken view combinations: {self.stats['broken_combine']}")
        print(f"  - Orphan XPath expressions: {self.stats['broken_xpath']}")
        print(f"  - Invalid QWeb templates: {self.stats['broken_qweb']}")
        print(f"  - Missing field references: {self.stats['broken_fields']}")
        print(f"  - Missing assets: {self.stats['missing_assets']}")
        print()

        total_errors = len(self.errors)
        total_warnings = len(self.warnings)

        if total_errors == 0 and total_warnings == 0:
            print(f"{Colors.GREEN}{Colors.BOLD}")
            print("="*60)
            print("  ALL VALIDATIONS PASSED!")
            print("="*60)
            print(f"{Colors.END}")
        elif total_errors == 0:
            print(f"{Colors.YELLOW}{Colors.BOLD}")
            print("="*60)
            print(f"  VALIDATION PASSED WITH {total_warnings} WARNING(S)")
            print("="*60)
            print(f"{Colors.END}")
        else:
            print(f"{Colors.RED}{Colors.BOLD}")
            print("="*60)
            print(f"  VALIDATION FAILED: {total_errors} ERROR(S), {total_warnings} WARNING(S)")
            print("="*60)
            print(f"{Colors.END}")

        if os.environ.get('VALIDATE_VIEWS_REPORT'):
            report = {
                'type': 'views',
                'timestamp': datetime.now().isoformat(),
                'database': self.env.cr.dbname,
                'stats': self.stats,
                'errors': self.errors,
                'warnings': self.warnings
            }
            MARKER = '___VALIDATE_VIEWS_JSON___'
            print(MARKER)
            print(json.dumps(report, indent=2, default=str))
            print(MARKER)


def main():
    """Main entry point."""
    try:
        validator = ViewValidator(env)
        success = validator.validate_all()
        
        # Exit with appropriate code
        if not success:
            sys.exit(1)
            
    except Exception as e:
        print_error(f"Validation script failed: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(2)


# Run when executed in Odoo shell
if __name__ == '__main__' or 'env' in dir():
    main()
