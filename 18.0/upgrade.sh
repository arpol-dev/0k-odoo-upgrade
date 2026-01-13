#!/bin/bash

compose -f ../compose.yml run -p 8018:8069 ou18 --config=/opt/odoo/auto/odoo.conf --stop-after-init -u all --workers 0 --log-level=debug --max-cron-threads=0 --limit-time-real=10000 --database=ou18 --load=base,web,openupgrade_framework
