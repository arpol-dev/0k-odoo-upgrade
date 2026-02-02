#!/bin/bash
set -euo pipefail

compose -f ../compose.yml run -p 8013:8069 ou13 --config=/opt/odoo/auto/odoo.conf --stop-after-init -u all --workers 0 --log-level=debug --max-cron-threads=0 --limit-time-real=10000 --database=ou13
