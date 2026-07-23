#!/usr/bin/env python3
"""
Reconcile res.config.settings-managed security groups after migration.

Background: several res.config.settings boolean fields are backed by
`implied_group=...` and computed from the current state of res.groups /
res_groups_implied_rel, not simply "does at least one user already have the
group". If a group ended up granted to users through a path other than the
settings framework's own implied-group chain (e.g. surviving unchanged
across an OpenUpgrade version hop while the *chain itself* was rebuilt),
the settings form can compute a boolean as unset even though the
underlying feature's data (e.g. active pricelists) is clearly in use --
triggering a same @api.onchange warning the field's module defines for a
genuine user-initiated deactivation (e.g. product.group_product_pricelist /
"You are deactivating the pricelist feature").

Concretely found and confirmed on the Perdelle 14->18 migration
(2026-07-23): group "Multi Currencies" implies group "Basic Pricelists" (a
stock Odoo relationship, not custom), and 3 active users already had the
pricelist group directly -- yet every Settings screen (they all render the
same combined res.config.settings form, regardless of which app's
Settings menu was clicked) opened with the pricelist onchange firing. A
plain "open Settings, click Save without changing anything" via the UI
fixed it permanently for every Settings entry point at once, because
res.config.settings.execute() re-applies every implied-group relationship
through Odoo's own official mechanism rather than relying on whatever
happened to survive the migration's raw data.

This is generic Odoo/OpenUpgrade behaviour, not specific to any one client
or feature -- running it once after any 0k-odoo-upgrade migration costs
nothing (idempotent: with no unsaved changes it just re-applies the
already-computed values) and closes this whole class of "phantom settings
warning" before manual/Playwright testing (migration-odoo skill 5.7.2)
ever sees it.
"""

print("\n" + "=" * 80)
print("RECONCILE SETTINGS-MANAGED SECURITY GROUPS (res.config.settings.execute())")
print("=" * 80 + "\n")

settings = env["res.config.settings"].create({})
settings.execute()

print("Settings reconciled (equivalent of opening Settings and clicking Save).")
