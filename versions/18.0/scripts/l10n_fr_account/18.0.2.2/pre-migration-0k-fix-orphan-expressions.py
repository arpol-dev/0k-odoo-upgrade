# Copyright 0k / Élabore
# License AGPL-3.0 or later (https://www.gnu.org/licenses/agpl).
#
# Custom OpenUpgrade migration script, injected through a dedicated
# --upgrade-path (see versions/18.0/upgrade.sh). It runs IN ADDITION to the
# native openupgrade_scripts pre-migration.py of l10n_fr_account/18.0.2.2:
# the framework appends every upgrade path, so this script does not override
# nor duplicate the native one.
from openupgradelib import openupgrade


@openupgrade.migrate()
def migrate(env, version):
    """Fix orphan account.report.expression records before XML data loading.

    During migration from V17, some account.report.expression records lose
    their ir_model_data entries. When l10n_fr_account loads tax_report_data.xml
    in V18, it tries to INSERT these records again, violating the unique
    constraint account_report_expression_line_label_uniq (report_line_id, label).

    Fix 1: Re-insert missing ir_model_data entries so Odoo performs UPDATE
    instead of INSERT when loading the XML data.

    Fix 2: Delete orphan expressions that no longer exist in V18 XML
    (box_X5, box_Y4, box_Y5, box_Z5 now use aggregation_formula field).
    """
    cr = env.cr
    # (expr_xmlid, line_xmlid, label)
    # Generated from l10n_fr_account/data/tax_report_data.xml (18.0)
    expressions = [
        ("tax_report_A1_tag", "tax_report_A1", "balance"),
        ("tax_report_A1_tag_rounded", "tax_report_A1", "balance_rounded"),
        ("tax_report_A1_balance_from_tags", "tax_report_A1", "balance_from_tags"),
        ("tax_report_A1_adjustment", "tax_report_A1", "adjustment"),
        ("tax_report_A2_tag", "tax_report_A2", "balance"),
        ("tax_report_A2_tag_rounded", "tax_report_A2", "balance_rounded"),
        ("tax_report_A2_balance_from_tags", "tax_report_A2", "balance_from_tags"),
        ("tax_report_A2_adjustment", "tax_report_A2", "adjustment"),
        ("tax_report_A3_tag", "tax_report_A3", "balance"),
        ("tax_report_A3_tag_rounded", "tax_report_A3", "balance_rounded"),
        ("tax_report_A3_balance_from_tags", "tax_report_A3", "balance_from_tags"),
        ("tax_report_A3_adjustment", "tax_report_A3", "adjustment"),
        ("tax_report_A4_tag", "tax_report_A4", "balance"),
        ("tax_report_A4_tag_rounded", "tax_report_A4", "balance_rounded"),
        ("tax_report_A4_balance_from_tags", "tax_report_A4", "balance_from_tags"),
        ("tax_report_A4_adjustment", "tax_report_A4", "adjustment"),
        ("tax_report_A5_tag", "tax_report_A5", "balance"),
        ("tax_report_A5_tag_rounded", "tax_report_A5", "balance_rounded"),
        ("tax_report_A5_balance_from_tags", "tax_report_A5", "balance_from_tags"),
        ("tax_report_A5_adjustment", "tax_report_A5", "adjustment"),
        ("tax_report_B1_tag", "tax_report_B1", "balance"),
        ("tax_report_B1_tag_rounded", "tax_report_B1", "balance_rounded"),
        ("tax_report_B1_balance_from_tags", "tax_report_B1", "balance_from_tags"),
        ("tax_report_B1_adjustment", "tax_report_B1", "adjustment"),
        ("tax_report_B2_tag", "tax_report_B2", "balance"),
        ("tax_report_B2_tag_rounded", "tax_report_B2", "balance_rounded"),
        ("tax_report_B2_balance_from_tags", "tax_report_B2", "balance_from_tags"),
        ("tax_report_B2_adjustment", "tax_report_B2", "adjustment"),
        ("tax_report_B3_tag", "tax_report_B3", "balance"),
        ("tax_report_B3_tag_rounded", "tax_report_B3", "balance_rounded"),
        ("tax_report_B3_balance_from_tags", "tax_report_B3", "balance_from_tags"),
        ("tax_report_B3_adjustment", "tax_report_B3", "adjustment"),
        ("tax_report_B4_tag", "tax_report_B4", "balance"),
        ("tax_report_B4_tag_rounded", "tax_report_B4", "balance_rounded"),
        ("tax_report_B4_balance_from_tags", "tax_report_B4", "balance_from_tags"),
        ("tax_report_B4_adjustment", "tax_report_B4", "adjustment"),
        ("tax_report_B5_tag", "tax_report_B5", "balance"),
        ("tax_report_B5_tag_rounded", "tax_report_B5", "balance_rounded"),
        ("tax_report_B5_balance_from_tags", "tax_report_B5", "balance_from_tags"),
        ("tax_report_B5_adjustment", "tax_report_B5", "adjustment"),
        ("tax_report_E1_tag", "tax_report_E1", "balance"),
        ("tax_report_E1_tag_rounded", "tax_report_E1", "balance_rounded"),
        ("tax_report_E1_balance_from_tags", "tax_report_E1", "balance_from_tags"),
        ("tax_report_E1_adjustment", "tax_report_E1", "adjustment"),
        ("tax_report_E2_tag", "tax_report_E2", "balance"),
        ("tax_report_E2_tag_rounded", "tax_report_E2", "balance_rounded"),
        ("tax_report_E2_balance_from_tags", "tax_report_E2", "balance_from_tags"),
        ("tax_report_E2_adjustment", "tax_report_E2", "adjustment"),
        ("tax_report_E3_tag", "tax_report_E3", "balance"),
        ("tax_report_E3_tag_rounded", "tax_report_E3", "balance_rounded"),
        ("tax_report_E3_balance_from_tags", "tax_report_E3", "balance_from_tags"),
        ("tax_report_E3_adjustment", "tax_report_E3", "adjustment"),
        ("tax_report_E4_tag", "tax_report_E4", "balance"),
        ("tax_report_E4_tag_rounded", "tax_report_E4", "balance_rounded"),
        ("tax_report_E4_balance_from_tags", "tax_report_E4", "balance_from_tags"),
        ("tax_report_E4_adjustment", "tax_report_E4", "adjustment"),
        ("tax_report_E5_tag", "tax_report_E5", "balance"),
        ("tax_report_E5_tag_rounded", "tax_report_E5", "balance_rounded"),
        ("tax_report_E5_balance_from_tags", "tax_report_E5", "balance_from_tags"),
        ("tax_report_E5_adjustment", "tax_report_E5", "adjustment"),
        ("tax_report_E6_tag", "tax_report_E6", "balance"),
        ("tax_report_E6_tag_rounded", "tax_report_E6", "balance_rounded"),
        ("tax_report_E6_balance_from_tags", "tax_report_E6", "balance_from_tags"),
        ("tax_report_E6_adjustment", "tax_report_E6", "adjustment"),
        ("tax_report_F1_tag", "tax_report_F1", "balance"),
        ("tax_report_F1_tag_rounded", "tax_report_F1", "balance_rounded"),
        ("tax_report_F1_balance_from_tags", "tax_report_F1", "balance_from_tags"),
        ("tax_report_F1_adjustment", "tax_report_F1", "adjustment"),
        ("tax_report_F2_tag", "tax_report_F2", "balance"),
        ("tax_report_F2_tag_rounded", "tax_report_F2", "balance_rounded"),
        ("tax_report_F2_balance_from_tags", "tax_report_F2", "balance_from_tags"),
        ("tax_report_F2_adjustment", "tax_report_F2", "adjustment"),
        ("tax_report_F3_tag", "tax_report_F3", "balance"),
        ("tax_report_F3_tag_rounded", "tax_report_F3", "balance_rounded"),
        ("tax_report_F3_balance_from_tags", "tax_report_F3", "balance_from_tags"),
        ("tax_report_F3_adjustment", "tax_report_F3", "adjustment"),
        ("tax_report_F4_tag", "tax_report_F4", "balance"),
        ("tax_report_F4_tag_rounded", "tax_report_F4", "balance_rounded"),
        ("tax_report_F4_balance_from_tags", "tax_report_F4", "balance_from_tags"),
        ("tax_report_F4_adjustment", "tax_report_F4", "adjustment"),
        ("tax_report_F5_tag", "tax_report_F5", "balance"),
        ("tax_report_F5_tag_rounded", "tax_report_F5", "balance_rounded"),
        ("tax_report_F5_balance_from_tags", "tax_report_F5", "balance_from_tags"),
        ("tax_report_F5_adjustment", "tax_report_F5", "adjustment"),
        ("tax_report_F6_tag", "tax_report_F6", "balance"),
        ("tax_report_F6_tag_rounded", "tax_report_F6", "balance_rounded"),
        ("tax_report_F6_balance_from_tags", "tax_report_F6", "balance_from_tags"),
        ("tax_report_F6_adjustment", "tax_report_F6", "adjustment"),
        ("tax_report_F7_tag", "tax_report_F7", "balance"),
        ("tax_report_F7_tag_rounded", "tax_report_F7", "balance_rounded"),
        ("tax_report_F7_balance_from_tags", "tax_report_F7", "balance_from_tags"),
        ("tax_report_F7_adjustment", "tax_report_F7", "adjustment"),
        ("tax_report_F8_tag", "tax_report_F8", "balance"),
        ("tax_report_F8_tag_rounded", "tax_report_F8", "balance_rounded"),
        ("tax_report_F8_balance_from_tags", "tax_report_F8", "balance_from_tags"),
        ("tax_report_F8_adjustment", "tax_report_F8", "adjustment"),
        ("tax_report_F9_tag", "tax_report_F9", "balance"),
        ("tax_report_F9_tag_rounded", "tax_report_F9", "balance_rounded"),
        ("tax_report_F9_balance_from_tags", "tax_report_F9", "balance_from_tags"),
        ("tax_report_F9_adjustment", "tax_report_F9", "adjustment"),
        ("tax_report_08_base_tag", "tax_report_08_base", "balance"),
        ("tax_report_08_base_tag_rounded", "tax_report_08_base", "balance_rounded"),
        ("tax_report_08_base_balance_from_tags", "tax_report_08_base", "balance_from_tags"),
        ("tax_report_08_base_adjustment", "tax_report_08_base", "adjustment"),
        ("tax_report_08_taxe_tag", "tax_report_08_taxe", "balance"),
        ("tax_report_08_taxe_tag_rounded", "tax_report_08_taxe", "balance_rounded"),
        ("tax_report_08_taxe_tag_no_rounding", "tax_report_08_taxe", "balance_from_tags"),
        ("tax_report_09_base_tag", "tax_report_09_base", "balance"),
        ("tax_report_09_base_tag_rounded", "tax_report_09_base", "balance_rounded"),
        ("tax_report_09_base_balance_from_tags", "tax_report_09_base", "balance_from_tags"),
        ("tax_report_09_base_adjustment", "tax_report_09_base", "adjustment"),
        ("tax_report_09_taxe_tag", "tax_report_09_taxe", "balance"),
        ("tax_report_09_taxe_tag_rounded", "tax_report_09_taxe", "balance_rounded"),
        ("tax_report_09_taxe_tag_no_rounding", "tax_report_09_taxe", "balance_from_tags"),
        ("tax_report_9B_base_tag", "tax_report_9B_base", "balance"),
        ("tax_report_9B_base_tag_rounded", "tax_report_9B_base", "balance_rounded"),
        ("tax_report_9B_base_balance_from_tags", "tax_report_9B_base", "balance_from_tags"),
        ("tax_report_9B_base_adjustment", "tax_report_9B_base", "adjustment"),
        ("tax_report_9B_taxe_tag", "tax_report_9B_taxe", "balance"),
        ("tax_report_9B_taxe_tag_rounded", "tax_report_9B_taxe", "balance_rounded"),
        ("tax_report_9B_taxe_tag_no_rounding", "tax_report_9B_taxe", "balance_from_tags"),
        ("tax_report_10_base_tag", "tax_report_10_base", "balance"),
        ("tax_report_10_base_tag_rounded", "tax_report_10_base", "balance_rounded"),
        ("tax_report_10_base_balance_from_tags", "tax_report_10_base", "balance_from_tags"),
        ("tax_report_10_base_adjustment", "tax_report_10_base", "adjustment"),
        ("tax_report_10_taxe_tag", "tax_report_10_taxe", "balance"),
        ("tax_report_10_taxe_tag_balance", "tax_report_10_taxe", "balance_rounded"),
        ("tax_report_10_taxe_tag_no_rounding", "tax_report_10_taxe", "balance_from_tags"),
        ("tax_report_11_base_tag", "tax_report_11_base", "balance"),
        ("tax_report_11_base_tag_rounded", "tax_report_11_base", "balance_rounded"),
        ("tax_report_11_base_balance_from_tags", "tax_report_11_base", "balance_from_tags"),
        ("tax_report_11_base_adjustment", "tax_report_11_base", "adjustment"),
        ("tax_report_11_taxe_tag", "tax_report_11_taxe", "balance"),
        ("tax_report_11_taxe_tag_rounded", "tax_report_11_taxe", "balance_rounded"),
        ("tax_report_11_taxe_tag_no_rounding", "tax_report_11_taxe", "balance_from_tags"),
        ("tax_report_T1_base_tag", "tax_report_T1_base", "balance"),
        ("tax_report_T1_base_tag_rounded", "tax_report_T1_base", "balance_rounded"),
        ("tax_report_T1_base_balance_from_tags", "tax_report_T1_base", "balance_from_tags"),
        ("tax_report_T1_base_adjustment", "tax_report_T1_base", "adjustment"),
        ("tax_report_T1_taxe_tag", "tax_report_T1_taxe", "balance"),
        ("tax_report_T1_taxe_tag_rounded", "tax_report_T1_taxe", "balance_rounded"),
        ("tax_report_T1_taxe_tag_no_rounding", "tax_report_T1_taxe", "balance_from_tags"),
        ("tax_report_T2_base_tag", "tax_report_T2_base", "balance"),
        ("tax_report_T2_base_tag_rounded", "tax_report_T2_base", "balance_rounded"),
        ("tax_report_T2_base_balance_from_tags", "tax_report_T2_base", "balance_from_tags"),
        ("tax_report_T2_base_adjustment", "tax_report_T2_base", "adjustment"),
        ("tax_report_T2_taxe_tag", "tax_report_T2_taxe", "balance"),
        ("tax_report_T2_taxe_tag_rounded", "tax_report_T2_taxe", "balance_rounded"),
        ("tax_report_T2_taxe_tag_no_rounding", "tax_report_T2_taxe", "balance_from_tags"),
        ("tax_report_T3_base_tag", "tax_report_T3_base", "balance"),
        ("tax_report_T3_base_tag_rounded", "tax_report_T3_base", "balance_rounded"),
        ("tax_report_T3_base_balance_from_tags", "tax_report_T3_base", "balance_from_tags"),
        ("tax_report_T3_base_adjustment", "tax_report_T3_base", "adjustment"),
        ("tax_report_T3_taxe_tag", "tax_report_T3_taxe", "balance"),
        ("tax_report_T3_taxe_tag_rounded", "tax_report_T3_taxe", "balance_rounded"),
        ("tax_report_T3_taxe_tag_no_rounding", "tax_report_T3_taxe", "balance_from_tags"),
        ("tax_report_T4_base_tag", "tax_report_T4_base", "balance"),
        ("tax_report_T4_base_tag_rounded", "tax_report_T4_base", "balance_rounded"),
        ("tax_report_T4_base_balance_from_tags", "tax_report_T4_base", "balance_from_tags"),
        ("tax_report_T4_base_adjustment", "tax_report_T4_base", "adjustment"),
        ("tax_report_T4_taxe_tag", "tax_report_T4_taxe", "balance"),
        ("tax_report_T4_taxe_tag_balance", "tax_report_T4_taxe", "balance_rounded"),
        ("tax_report_T4_taxe_tag_no_rounding", "tax_report_T4_taxe", "balance_from_tags"),
        ("tax_report_T5_base_tag", "tax_report_T5_base", "balance"),
        ("tax_report_T5_base_tag_rounded", "tax_report_T5_base", "balance_rounded"),
        ("tax_report_T5_base_balance_from_tags", "tax_report_T5_base", "balance_from_tags"),
        ("tax_report_T5_base_adjustment", "tax_report_T5_base", "adjustment"),
        ("tax_report_T5_taxe_tag", "tax_report_T5_taxe", "balance"),
        ("tax_report_T5_taxe_tag_rounded", "tax_report_T5_taxe", "balance_rounded"),
        ("tax_report_T5_taxe_tag_no_rounding", "tax_report_T5_taxe", "balance_from_tags"),
        ("tax_report_T6_base_tag", "tax_report_T6_base", "balance"),
        ("tax_report_T6_base_tag_balance", "tax_report_T6_base", "balance_rounded"),
        ("tax_report_T6_base_balance_from_tags", "tax_report_T6_base", "balance_from_tags"),
        ("tax_report_T6_base_adjustment", "tax_report_T6_base", "adjustment"),
        ("tax_report_T6_taxe_tag", "tax_report_T6_taxe", "balance"),
        ("tax_report_T6_taxe_tag_balance", "tax_report_T6_taxe", "balance_rounded"),
        ("tax_report_T6_taxe_tag_no_rounding", "tax_report_T6_taxe", "balance_from_tags"),
        ("tax_report_T7_base_tag", "tax_report_T7_base", "balance"),
        ("tax_report_T7_base_tag_rounded", "tax_report_T7_base", "balance_rounded"),
        ("tax_report_T7_base_balance_from_tags", "tax_report_T7_base", "balance_from_tags"),
        ("tax_report_T7_base_adjustment", "tax_report_T7_base", "adjustment"),
        ("tax_report_T7_taxe_tag", "tax_report_T7_taxe", "balance"),
        ("tax_report_T7_taxe_balance_rounded", "tax_report_T7_taxe", "balance_rounded"),
        ("tax_report_T7_taxe_balance_from_tags", "tax_report_T7_taxe", "balance_from_tags"),
        ("tax_report_13_base_tag", "tax_report_13_base", "balance"),
        ("tax_report_13_base_tag_rounded", "tax_report_13_base", "balance_rounded"),
        ("tax_report_13_base_balance_from_tags", "tax_report_13_base", "balance_from_tags"),
        ("tax_report_13_base_adjustment", "tax_report_13_base", "adjustment"),
        ("tax_report_13_taxe_tag", "tax_report_13_taxe", "balance"),
        ("tax_report_13_taxe_balance_rounded", "tax_report_13_taxe", "balance_rounded"),
        ("tax_report_13_taxe_balance_from_tags", "tax_report_13_taxe", "balance_from_tags"),
        ("tax_report_14_base_tag", "tax_report_14_base", "balance"),
        ("tax_report_14_base_tag_rounded", "tax_report_14_base", "balance_rounded"),
        ("tax_report_14_base_balance_from_tags", "tax_report_14_base", "balance_from_tags"),
        ("tax_report_14_base_adjustment", "tax_report_14_base", "adjustment"),
        ("tax_report_14_taxe_tag", "tax_report_14_taxe", "balance"),
        ("tax_report_14_taxe_balance_rounded", "tax_report_14_taxe", "balance_rounded"),
        ("tax_report_14_taxe_balance_from_tags", "tax_report_14_taxe", "balance_from_tags"),
        ("tax_report_P1_base_tag", "tax_report_P1_base", "balance"),
        ("tax_report_P1_base_tag_rounded", "tax_report_P1_base", "balance_rounded"),
        ("tax_report_P1_base_balance_from_tags", "tax_report_P1_base", "balance_from_tags"),
        ("tax_report_P1_base_adjustment", "tax_report_P1_base", "adjustment"),
        ("tax_report_P1_taxe_tag", "tax_report_P1_taxe", "balance"),
        ("tax_report_P1_taxe_tag_rounded", "tax_report_P1_taxe", "balance_rounded"),
        ("tax_report_P1_taxe_tag_no_rounding", "tax_report_P1_taxe", "balance_from_tags"),
        ("tax_report_P2_base_tag", "tax_report_P2_base", "balance"),
        ("tax_report_P2_base_tag_rounded", "tax_report_P2_base", "balance_rounded"),
        ("tax_report_P2_base_balance_from_tags", "tax_report_P2_base", "balance_from_tags"),
        ("tax_report_P2_base_adjustment", "tax_report_P2_base", "adjustment"),
        ("tax_report_P2_taxe_tag", "tax_report_P2_taxe", "balance"),
        ("tax_report_P2_taxe_tag_rounded", "tax_report_P2_taxe", "balance_rounded"),
        ("tax_report_P2_taxe_tag_no_rounding", "tax_report_P2_taxe", "balance_from_tags"),
        ("tax_report_I1_base_tag", "tax_report_I1_base", "balance"),
        ("tax_report_I1_base_tag_rounded", "tax_report_I1_base", "balance_rounded"),
        ("tax_report_I1_base_balance_from_tags", "tax_report_I1_base", "balance_from_tags"),
        ("tax_report_I1_base_adjustment", "tax_report_I1_base", "adjustment"),
        ("tax_report_I1_taxe_tag", "tax_report_I1_taxe", "balance"),
        ("tax_report_I1_taxe_tag_rounded", "tax_report_I1_taxe", "balance_rounded"),
        ("tax_report_I1_taxe_tag_no_rounding", "tax_report_I1_taxe", "balance_from_tags"),
        ("tax_report_I2_base_tag", "tax_report_I2_base", "balance"),
        ("tax_report_I2_base_tag_rounded", "tax_report_I2_base", "balance_rounded"),
        ("tax_report_I2_base_balance_from_tags", "tax_report_I2_base", "balance_from_tags"),
        ("tax_report_I2_base_adjustment", "tax_report_I2_base", "adjustment"),
        ("tax_report_I2_taxe_tag", "tax_report_I2_taxe", "balance"),
        ("tax_report_I2_taxe_tag_rounded", "tax_report_I2_taxe", "balance_rounded"),
        ("tax_report_I2_taxe_tag_no_rounding", "tax_report_I2_taxe", "balance_from_tags"),
        ("tax_report_I3_base_tag", "tax_report_I3_base", "balance"),
        ("tax_report_I3_base_tag_rounded", "tax_report_I3_base", "balance_rounded"),
        ("tax_report_I3_base_balance_from_tags", "tax_report_I3_base", "balance_from_tags"),
        ("tax_report_I3_base_adjustment", "tax_report_I3_base", "adjustment"),
        ("tax_report_I3_taxe_tag", "tax_report_I3_taxe", "balance"),
        ("tax_report_I3_taxe_tag_rounded", "tax_report_I3_taxe", "balance_rounded"),
        ("tax_report_I3_taxe_tag_no_rounding", "tax_report_I3_taxe", "balance_from_tags"),
        ("tax_report_I4_base_tag", "tax_report_I4_base", "balance"),
        ("tax_report_I4_base_tag_rounded", "tax_report_I4_base", "balance_rounded"),
        ("tax_report_I4_base_balance_from_tags", "tax_report_I4_base", "balance_from_tags"),
        ("tax_report_I4_base_adjustment", "tax_report_I4_base", "adjustment"),
        ("tax_report_I4_taxe_tag", "tax_report_I4_taxe", "balance"),
        ("tax_report_I4_taxe_tag_rounded", "tax_report_I4_taxe", "balance_rounded"),
        ("tax_report_I4_taxe_tag_no_rounding", "tax_report_I4_taxe", "balance_from_tags"),
        ("tax_report_I5_base_tag", "tax_report_I5_base", "balance"),
        ("tax_report_I5_base_tag_rounded", "tax_report_I5_base", "balance_rounded"),
        ("tax_report_I5_base_balance_from_tags", "tax_report_I5_base", "balance_from_tags"),
        ("tax_report_I5_base_adjustment", "tax_report_I5_base", "adjustment"),
        ("tax_report_I5_taxe_tag", "tax_report_I5_taxe", "balance"),
        ("tax_report_I5_taxe_tag_rounded", "tax_report_I5_taxe", "balance_rounded"),
        ("tax_report_I5_taxe_tag_no_rounding", "tax_report_I5_taxe", "balance_from_tags"),
        ("tax_report_I6_base_tag", "tax_report_I6_base", "balance"),
        ("tax_report_I6_base_tag_rounded", "tax_report_I6_base", "balance_rounded"),
        ("tax_report_I6_base_balance_from_tags", "tax_report_I6_base", "balance_from_tags"),
        ("tax_report_I6_base_adjustment", "tax_report_I6_base", "adjustment"),
        ("tax_report_I6_taxe_tag", "tax_report_I6_taxe", "balance"),
        ("tax_report_I6_taxe_tag_rounded", "tax_report_I6_taxe", "balance_rounded"),
        ("tax_report_I6_taxe_tag_no_rounding", "tax_report_I6_taxe", "balance_from_tags"),
        ("tax_report_15_tag", "tax_report_15", "balance"),
        ("tax_report_15_balance_rounded", "tax_report_15", "balance_rounded"),
        ("tax_report_15_balance_from_tags", "tax_report_15", "balance_from_tags"),
        ("tax_report_15_1_tag", "tax_report_15_1", "balance"),
        ("tax_report_15_1_balance_rounded", "tax_report_15_1", "balance_rounded"),
        ("tax_report_15_1_balance_from_tags", "tax_report_15_1", "balance_from_tags"),
        ("tax_report_15_2_tag", "tax_report_15_2", "balance"),
        ("tax_report_15_2_balance_rounded", "tax_report_15_2", "balance_rounded"),
        ("tax_report_15_2_balance_from_tags", "tax_report_15_2", "balance_from_tags"),
        ("tax_report_5B_tag", "tax_report_5B", "balance"),
        ("tax_report_5B_balance_rounded", "tax_report_5B", "balance_rounded"),
        ("tax_report_5B_balance_from_tags", "tax_report_5B", "balance_from_tags"),
        ("tax_report_16_formula", "tax_report_16", "balance"),
        ("tax_report_17_tag", "tax_report_17", "balance"),
        ("tax_report_17_balance_rounded", "tax_report_17", "balance_rounded"),
        ("tax_report_17_balance_from_tags", "tax_report_17", "balance_from_tags"),
        ("tax_report_18_tag", "tax_report_18", "balance"),
        ("tax_report_18_balance_rounded", "tax_report_18", "balance_rounded"),
        ("tax_report_18_balance_from_tags", "tax_report_18", "balance_from_tags"),
        ("tax_report_19_tag", "tax_report_19", "balance"),
        ("tax_report_19_balance_rounded", "tax_report_19", "balance_rounded"),
        ("tax_report_19_balance_from_tags", "tax_report_19", "balance_from_tags"),
        ("tax_report_20_tag", "tax_report_20", "balance"),
        ("tax_report_20_balance_rounded", "tax_report_20", "balance_rounded"),
        ("tax_report_20_balance_from_tags", "tax_report_20", "balance_from_tags"),
        ("tax_report_21_tag", "tax_report_21", "balance"),
        ("tax_report_21_balance_from_tags", "tax_report_21", "balance_from_tags"),
        ("tax_report_22_applied_carryover", "tax_report_22", "_applied_carryover_balance"),
        ("tax_report_22_tag", "tax_report_22", "tag"),
        ("tax_report_22_balance_rounded", "tax_report_22", "balance_rounded"),
        ("tax_report_22_balance", "tax_report_22", "balance"),
        ("tax_report_2C_tag", "tax_report_2C", "balance"),
        ("tax_report_2C_balance_rounded", "tax_report_2C", "balance_rounded"),
        ("tax_report_2C_balance_from_tags", "tax_report_2C", "balance_from_tags"),
        ("tax_report_22A_tag", "tax_report_22A", "balance"),
        ("tax_report_22A_balance_rounded", "tax_report_22A", "balance_rounded"),
        ("tax_report_22A_balance_from_tags", "tax_report_22A", "balance_from_tags"),
        ("tax_report_23_formula", "tax_report_23", "balance"),
        ("tax_report_24_tag", "tax_report_24", "balance"),
        ("tax_report_24_balance_rounded", "tax_report_24", "balance_rounded"),
        ("tax_report_24_balance_from_tags", "tax_report_24", "balance_from_tags"),
        ("tax_report_2E_tag", "tax_report_2E", "balance"),
        ("tax_report_2E_balance_rounded", "tax_report_2E", "balance_rounded"),
        ("tax_report_2E_balance_from_tags", "tax_report_2E", "balance_from_tags"),
        ("tax_report_25_formula", "tax_report_25", "balance"),
        ("tax_report_25_adjustment", "tax_report_25", "adjustment"),
        ("tax_report_td_formula", "tax_report_TD", "balance"),
        ("tax_report_TICFE_tag", "tax_report_TICFE", "balance"),
        ("tax_report_TICGN_tag", "tax_report_TICGN", "balance"),
        ("tax_report_TICC_tag", "tax_report_TICC", "balance"),
        ("tax_report_TIC_total_formula", "tax_report_TIC_total", "balance"),
        ("tax_report_X1_tag", "tax_report_X1", "balance"),
        ("tax_report_X1_balance_rounded", "tax_report_X1", "balance_rounded"),
        ("tax_report_X1_balance_from_tags", "tax_report_X1", "balance_from_tags"),
        ("tax_report_X2_tag", "tax_report_X2", "balance"),
        ("tax_report_X2_balance_rounded", "tax_report_X2", "balance_rounded"),
        ("tax_report_X2_balance_from_tags", "tax_report_X2", "balance_from_tags"),
        ("tax_report_X3_tag", "tax_report_X3", "balance"),
        ("tax_report_X3_balance_rounded", "tax_report_X3", "balance_rounded"),
        ("tax_report_X3_balance_from_tags", "tax_report_X3", "balance_from_tags"),
        ("tax_report_X4_formula", "tax_report_X4", "balance"),
        ("tax_report_Y1_formula", "tax_report_Y1", "balance"),
        ("tax_report_Y2_formula", "tax_report_Y2", "balance"),
        ("tax_report_Y3_formula", "tax_report_Y3", "balance"),
        ("tax_report_Z1_tag", "tax_report_Z1", "balance"),
        ("tax_report_Z1_balance_rounded", "tax_report_Z1", "balance_rounded"),
        ("tax_report_Z1_balance_from_tags", "tax_report_Z1", "balance_from_tags"),
        ("tax_report_Z2_tag", "tax_report_Z2", "balance"),
        ("tax_report_Z2_balance_rounded", "tax_report_Z2", "balance_rounded"),
        ("tax_report_Z2_balance_from_tags", "tax_report_Z2", "balance_from_tags"),
        ("tax_report_Z3_tag", "tax_report_Z3", "balance"),
        ("tax_report_Z3_balance_rounded", "tax_report_Z3", "balance_rounded"),
        ("tax_report_Z3_balance_from_tags", "tax_report_Z3", "balance_from_tags"),
        ("tax_report_Z4_formula", "tax_report_Z4", "balance"),
        ("tax_report_26_external_tag", "tax_report_26_external", "balance"),
        ("tax_report_AA_tag", "tax_report_AA", "balance"),
        ("tax_report_AA_balance_rounded", "tax_report_AA", "balance_rounded"),
        ("tax_report_AA_balance_from_tags", "tax_report_AA", "balance_from_tags"),
        ("tax_report_27_formula", "tax_report_27", "balance"),
        ("tax_report_27_formula_temp", "tax_report_27", "_balance_temp"),
        ("tax_report_27_carryover", "tax_report_27", "_carryover_balance"),
        ("tax_report_28_formula", "tax_report_28", "balance"),
        ("tax_report_29_tag", "tax_report_29", "balance"),
        ("tax_report_29_balance_rounded", "tax_report_29", "balance_rounded"),
        ("tax_report_29_balance_from_tags", "tax_report_29", "balance_from_tags"),
        ("tax_report_32_formula", "tax_report_32", "balance"),
    ]

    # Fix 1: insert missing ir_model_data entries for orphan expressions
    cr.execute(
        """
        SELECT imd.name, imd.res_id
        FROM ir_model_data imd
        WHERE imd.module = 'l10n_fr_account'
          AND imd.model = 'account.report.line'
        """
    )
    line_xmlid_to_id = {row[0]: row[1] for row in cr.fetchall()}

    cr.execute(
        """
        SELECT res_id FROM ir_model_data
        WHERE model = 'account.report.expression'
        """
    )
    known_expr_ids = {row[0] for row in cr.fetchall()}

    inserted = 0
    for expr_xmlid, line_xmlid, label in expressions:
        line_id = line_xmlid_to_id.get(line_xmlid)
        if not line_id:
            continue

        cr.execute(
            """
            SELECT id FROM account_report_expression
            WHERE report_line_id = %s AND label = %s
            """,
            (line_id, label),
        )
        row = cr.fetchone()
        if not row:
            continue
        expr_id = row[0]

        if expr_id in known_expr_ids:
            continue

        cr.execute(
            """
            INSERT INTO ir_model_data (name, module, model, res_id, noupdate, write_date, create_date)
            VALUES (%s, 'l10n_fr_account', 'account.report.expression', %s, false, NOW(), NOW())
            ON CONFLICT DO NOTHING
            """,
            (expr_xmlid, expr_id),
        )
        known_expr_ids.add(expr_id)
        inserted += 1

    if inserted:
        print(
            f"  [l10n_fr_account] Inserted {inserted} missing ir_model_data entries"
            " for orphan expressions"
        )

    # Fix 2: delete orphan expressions obsolete in V18
    # box_X5, box_Y4, box_Y5, box_Z5 now use aggregation_formula field
    # instead of expression_ids, so their V17 expressions are obsolete.
    obsolete_line_xmlids = [
        "tax_report_X5",
        "tax_report_Y4",
        "tax_report_Y5",
        "tax_report_Z5",
    ]
    cr.execute(
        """
        DELETE FROM account_report_expression
        WHERE report_line_id IN (
            SELECT res_id FROM ir_model_data
            WHERE module = 'l10n_fr_account'
              AND model = 'account.report.line'
              AND name = ANY(%s)
        )
        AND id NOT IN (
            SELECT res_id FROM ir_model_data
            WHERE model = 'account.report.expression'
        )
        """,
        (obsolete_line_xmlids,),
    )
    deleted = cr.rowcount
    if deleted:
        print(
            f"  [l10n_fr_account] Deleted {deleted} obsolete orphan expressions"
            " (X5/Y4/Y5/Z5)"
        )
