#!/bin/bash

compose -f ../compose.yml run -p 8016:8069 ou16 --config=/opt/odoo/auto/odoo.conf --stop-after-init -u all --workers 0 --log-level=warn --max-cron-threads=0 --limit-time-real=10000 --database=ou16 --load=base,web,openupgrade_framework
