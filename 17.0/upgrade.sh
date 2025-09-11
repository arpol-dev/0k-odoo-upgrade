#!/bin/bash

compose -f ../compose.yml run -p 8017:8069 ou17 --config=/opt/odoo/auto/odoo.conf --stop-after-init -u all --workers 0 --log-level=warn --max-cron-threads=0 --limit-time-real=10000 --database=ou17 --load=web,openupgrade_framework
