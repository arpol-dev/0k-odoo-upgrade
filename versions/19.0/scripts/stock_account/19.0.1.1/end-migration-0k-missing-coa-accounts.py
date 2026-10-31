# Copyright ArPol
# License AGPL-3.0 or later (https://www.gnu.org/licenses/agpl).
#
# Custom migration script, injected through the 0k --upgrade-path (see
# versions/19.0/upgrade.sh). Odoo runs the scripts of a module/version/stage
# sorted by file name, so this one runs right BEFORE the native OpenUpgrade
# stock_account/19.0.1.1/end-migration.py.
#
# The native script (update_from_coa) sets the new stock fields
# (account.account account_stock_expense_id / account_stock_variation_id,
# res.company account_stock_valuation_id / account_stock_journal_id) from the
# chart template. For a template account that does not exist in the company
# (charts loaded with an older localization, e.g. a French chart from 14.0
# without the generic 310000 / 601000 accounts), AccountChartTemplate.ref()
# returns an empty recordset, the script keeps the record and _load_data()
# creates an account with the stock fields only:
#   null value in column "name" of relation "account_account"
# Create these missing template accounts beforehand (or link the template
# xml-id to an existing account with the same code).
import logging

from openupgradelib import openupgrade

_logger = logging.getLogger(__name__)

ACCOUNT_FIELDS = ("account_stock_expense_id", "account_stock_variation_id")
COMPANY_FIELDS = ("account_stock_valuation_id",)


def _needed_account_xmlids(company, template_data):
    needed = set()
    for xmlid, vals in template_data.get("account.account", {}).items():
        refs = [vals.get(f) for f in ACCOUNT_FIELDS if vals.get(f)]
        if refs:
            needed.add(xmlid)
            needed.update(refs)
    company_vals = template_data.get("res.company", {}).get(company.id, {})
    needed.update(company_vals[f] for f in COMPANY_FIELDS if company_vals.get(f))
    return {x for x in needed if isinstance(x, str)}


@openupgrade.migrate()
def migrate(env, version):
    Account = env["account.account"]
    for company in env["res.company"].search([]):
        chart = env["account.chart.template"].with_context(
            default_company_id=company.id,
            allowed_company_ids=company.ids,
            tracking_disable=True,
            delay_account_group_sync=True,
            lang="en_US",
            chart_template_load=True,
        )
        if company.chart_template not in chart._template_register:
            continue
        template_data = chart._get_chart_template_data(company.chart_template)
        accounts_data = template_data.get("account.account", {})
        to_create = {}
        for xmlid in sorted(_needed_account_xmlids(company, template_data)):
            if chart.ref(xmlid, False) or xmlid not in accounts_data:
                continue
            vals = {
                k: v for k, v in accounts_data[xmlid].items() if k not in ACCOUNT_FIELDS
            }
            existing = Account.with_company(company).search(
                [("code", "=", vals.get("code")), ("company_ids", "in", company.ids)],
                limit=1,
            )
            if existing:
                module, name = chart.company_xmlid(xmlid).split(".", 1)
                env["ir.model.data"].create(
                    {
                        "module": module,
                        "name": name,
                        "model": "account.account",
                        "res_id": existing.id,
                        "noupdate": True,
                    }
                )
                _logger.info(
                    "company %s: template account %s linked to existing account %s",
                    company.id,
                    xmlid,
                    existing.code,
                )
            else:
                to_create[xmlid] = vals
        if to_create:
            chart._load_data({"account.account": to_create})
            _logger.info(
                "company %s: created missing template accounts %s",
                company.id,
                ", ".join(sorted(to_create)),
            )
