# Copyright 0k / Élabore
# License AGPL-3.0 or later (https://www.gnu.org/licenses/agpl).
#
# Custom OpenUpgrade migration script, injected through a dedicated
# --upgrade-path (see versions/18.0/upgrade.sh). It runs IN ADDITION to the
# native openupgrade_scripts post-migration.py of l10n_fr_account/18.0.2.2.
#
# Loads the 0k customization of the French VAT report (box 25 "adjustment")
# the OpenUpgrade way, without shadowing the core l10n_fr_account module.
from openupgradelib import openupgrade


@openupgrade.migrate()
def migrate(env, version):
    # mode="init" (re)creates records marked noupdate that the normal upgrade
    # mechanism would skip; it updates existing ones (tax_report_25_formula)
    # and creates new ones (tax_report_25_adjustment).
    openupgrade.load_data(
        env, "l10n_fr_account", "18.0.2.2/noupdate_changes.xml"
    )
