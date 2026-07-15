# Copyright 0k / Élabore
# License AGPL-3.0 or later (https://www.gnu.org/licenses/agpl).
#
# Custom OpenUpgrade migration script, injected through a dedicated
# --upgrade-path (see versions/18.0/upgrade.sh). Runs at stage "post" of
# l10n_fr_account/18.0.2.2, i.e. BEFORE the global "end" stage where the native
# l10n_fr_account/migrations/2.1/end-migrate_update_taxes.py runs.
#
# Problem
# -------
# end-migrate_update_taxes.py calls account.chart.template.try_loading('fr', ...).
# During _post_load_data(), Odoo 18 resolves the French template's default
# accounts via self.ref() WITHOUT raise_if_not_found=False, at three places:
#   - property_account_income_categ_id  (pcg_707_account) -> chart_template.py:711
#   - property_account_expense_categ_id (pcg_607_account) -> chart_template.py:714
#   - every _get_property_accounts()/additional_properties account -> :746
# If any expected account xml-id "account.<company>_<key>" is missing, it raises:
#   ValueError: External ID not found in the system: account.1_pcg_607_account
# which aborts the whole registry load.
#
# This happens when a database customized its chart of accounts: the generic PCG
# account was deleted (e.g. 607000) or recreated without its xml-id (e.g. 707000).
#
# Fix (generic, not hardcoded to 607/707)
# ---------------------------------------
# For every company with a chart_template, we read the list of account xml-ids
# the template expects (dynamically, from the template ORM API), and for each one
# that is missing in the DB we recreate the "account.<company>_<key>" ir.model.data
# pointing to the best matching real account:
#   1. the account whose code matches exactly the template account code,
#   2. otherwise the company account whose code shares the longest common prefix
#      with the template code (e.g. 607000 -> 607100),
#   3. otherwise nothing (logged as a warning; never blocks).
# No account is modified; only missing xml-ids are (re)created. Idempotent.
import logging

from openupgradelib import openupgrade

_logger = logging.getLogger(__name__)


def _collect_property_account_xmlids(template, code, accounts_csv):
    """Return the set of template account xml-ids referenced as property accounts.

    Sources:
      - template._get_property_accounts({})  (receivable, payable, expense, income, ...)
      - the template_data dict (property_account_*_id keys)
      - additional_properties declared on res.company template data
    Only keep values that are real account xml-ids of this template, i.e. present
    in accounts_csv (this filters out journals and dotted external ids).
    """
    xmlids = set()

    # 1. Base property accounts (model-level defaults)
    try:
        prop_fields = template._get_property_accounts({})
    except Exception as exc:  # noqa: BLE001
        _logger.warning("Could not read _get_property_accounts: %s", exc)
        prop_fields = {}

    # 2. Full template data: template_data holds property_account_*_id values,
    #    res.company holds additional_properties (currency exchange, deferral...).
    try:
        tdata = template._get_chart_template_data(code)
    except Exception as exc:  # noqa: BLE001
        _logger.warning("Could not read _get_chart_template_data(%s): %s", code, exc)
        tdata = {}

    candidate_values = []

    template_data = tdata.get("template_data", {}) if tdata else {}
    for key, value in template_data.items():
        if key in prop_fields or key.startswith("property_"):
            candidate_values.append(value)

    # additional_properties live inside the res.company template values
    res_company = tdata.get("res.company", {}) if tdata else {}
    for _company_key, company_vals in res_company.items():
        if not isinstance(company_vals, dict):
            continue
        add_props = company_vals.get("additional_properties")
        if isinstance(add_props, dict):
            candidate_values.extend(add_props.values())

    # Keep only plain (non-dotted) xml-ids that are actual accounts of the template
    for value in candidate_values:
        if isinstance(value, str) and value and "." not in value and value in accounts_csv:
            xmlids.add(value)

    return xmlids


def _find_best_account(env, company, target_code):
    """Return the best account record for a template account code, or None.

    1. exact code match for the company;
    2. otherwise the company account whose code shares the longest common prefix
       with target_code; ties are broken by smallest code (deterministic).
    3. otherwise None.

    The exact fallback account matters little functionally: it is only used as a
    journal's default_account_id / an ir.default, which stays user-overridable.
    The goal is to provide a valid account of the right family so that
    try_loading() no longer crashes on a missing external id.
    """
    if not target_code:
        return None

    Account = env["account.account"]
    company_domain = [("company_ids", "in", company.id)]

    exact = Account.search(company_domain + [("code", "=", target_code)], limit=1)
    if exact:
        return exact

    # Longest common prefix fallback; ties broken by smallest code.
    candidates = Account.search(company_domain)
    best = None
    best_key = None  # (prefix_len, negated-code-for-min) -> maximize
    for acc in candidates:
        code = acc.code or ""
        common = 0
        for a, b in zip(code, target_code):
            if a != b:
                break
            common += 1
        if common == 0:
            continue
        key = (common, tuple(-ord(c) for c in code))  # longer prefix, then smallest code
        if best_key is None or key > best_key:
            best = acc
            best_key = key
    return best


@openupgrade.migrate()
def migrate(env, version):
    template = env["account.chart.template"]
    companies = env["res.company"].search([("chart_template", "!=", False)])

    created = 0
    for company in companies:
        code = company.chart_template
        tmpl = template.with_company(company)

        try:
            accounts_csv = tmpl._get_account_account(code)
        except Exception as exc:  # noqa: BLE001
            _logger.warning(
                "Company %s (%s): cannot read template accounts: %s",
                company.id, code, exc,
            )
            continue

        expected = _collect_property_account_xmlids(tmpl, code, accounts_csv)

        for tmpl_xmlid in sorted(expected):
            full = f"account.{company.id}_{tmpl_xmlid}"
            if env.ref(full, raise_if_not_found=False):
                continue
            if company.parent_ids:
                parent_full = (
                    f"account.{company.parent_ids[0].id}_{tmpl_xmlid}"
                )
                if env.ref(parent_full, raise_if_not_found=False):
                    continue

            target_code = accounts_csv.get(tmpl_xmlid, {}).get("code")
            account = _find_best_account(env, company, target_code)
            if not account:
                _logger.warning(
                    "Company %s: no account found for template xml-id %s "
                    "(code %s); skipping",
                    company.id, tmpl_xmlid, target_code,
                )
                continue

            env["ir.model.data"].create({
                "module": "account",
                "name": f"{company.id}_{tmpl_xmlid}",
                "model": "account.account",
                "res_id": account.id,
                "noupdate": True,
            })
            created += 1
            _logger.info(
                "Company %s: created xml-id %s -> account %s (%s) for "
                "template code %s",
                company.id, full, account.id, account.code, target_code,
            )

    _logger.info(
        "[l10n_fr_account] property-account xml-id fix: %s xml-id(s) created",
        created,
    )
