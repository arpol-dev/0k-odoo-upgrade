#!/bin/bash
set -euo pipefail

compose -f ../compose.yml run -p 8014:8069 ou14 --config=/opt/odoo/auto/odoo.conf --stop-after-init -u all --workers 0 --log-level=debug --max-cron-threads=0 --limit-time-real=10000 --database=ou14 --load=base,web,openupgrade_framework
