#!/bin/bash
set -euo pipefail

# --upgrade-path lists BOTH our custom migration scripts and OpenUpgrade's
# native ones. Passing --upgrade-path overrides config['upgrade_path'], and
# openupgrade_framework only sets that default when it is empty; so we must
# include the native openupgrade_scripts/scripts path explicitly, otherwise the
# native migration scripts would no longer run. Odoo appends every listed path
# to odoo.upgrade.__path__ and concatenates (does not override) the scripts
# found per module/version, so our script runs IN ADDITION to the native ones.
run_compose run -p 8019:8069 ou19 --config=/opt/odoo/auto/odoo.conf --stop-after-init --update=all --workers 0 --log-level=debug --max-cron-threads=0 --limit-time-real=10000 --database=ou19 --load=base,web,openupgrade_framework --addons-path=/opt/odoo/auto/mig,/opt/odoo/auto/addons --upgrade-path=/opt/odoo/auto/upgrade,/opt/odoo/auto/addons/openupgrade_scripts/scripts
