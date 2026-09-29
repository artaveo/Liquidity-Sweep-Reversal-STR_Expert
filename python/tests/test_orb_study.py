"""Blocking tests for the ORB trial statistics, the ORB-1S screen and the ORB-2 decision."""

import os
import sys
import unittest

sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")))

from lsr_reference.event_study import day_block_bootstrap_upper  # noqa: E402
from orb_reference.study import (all_trials, analysis_set, bootstrap_p_value, check_range, dev_decision,  # noqa: E402
                                 exclusion, holm, passes_filters, rv_bucket, screen_classification)


def row(day, net, orlen="OR5", exit_variant="R10_EOD", state="CLOSED", exit_reason="TIME_EXIT", quar="0",
        f1="1", f2="1", nr7="0", f5="1", month=1):
    return {"date": f"2026-{month:02d}-{day:02d}", "or_length": orlen, "exit_variant": exit_variant, "state": state,
            "reason": exit_reason if state == "CLOSED" else "NO_TRADE_INVALID_STOP", "exit_reason": exit_reason,
            "in_quarantine": quar, "f1": f1, "f2": f2, "nr7": nr7, "f5": f5,
            "entry_time": f"2026-{month:02d}-{day:02d}T16:35:00.500", "net_r": str(net)}


class TestOrbStudy(unittest.TestCase):
    def test_grid_is_sixteen_trials(self):
        t = all_trials()
        self.assertEqual(len(t), 16)
        self.assertIn(("OR5", "UNFILTERED", "R10_EOD"), t)

    def test_filter_sets(self):
        r = row(5, 1.0)
        self.assertTrue(passes_filters(r, "UNFILTERED"))
        self.assertTrue(passes_filters(r, "BASE"))
        self.assertFalse(passes_filters(r, "BASE_NR7"))
        self.assertTrue(passes_filters(r, "BASE_TREND"))
        self.assertFalse(passes_filters(row(5, 1.0, f2="0"), "BASE"))       # F2 fail
        self.assertFalse(passes_filters(row(5, 1.0, f1="NA"), "BASE"))      # NA never passes
        self.assertTrue(passes_filters(row(5, 1.0, f1="NA", f2="0"), "UNFILTERED"))

    def test_analysis_set(self):
        self.assertEqual(exclusion(row(5, 1.0)), "")
        self.assertEqual(exclusion(row(5, 1.0, state="NO_TRADE")), "NOT_TRADED_NO_TRADE_INVALID_STOP")
        self.assertEqual(exclusion(row(5, 1.0, exit_reason="END_OF_DATA")), "OPEN_AT_END_OF_DATA")
        self.assertEqual(exclusion(row(5, 1.0, quar="1")), "DATA_QUARANTINE")
        rows = [row(5, 1.0), row(6, 1.0, exit_variant="R2_EOD"), row(7, 1.0, orlen="OR15"), row(8, 1.0, f1="0")]
        self.assertEqual(len(analysis_set(rows, ("OR5", "UNFILTERED", "R10_EOD"))), 2)
        self.assertEqual(len(analysis_set(rows, ("OR5", "BASE", "R10_EOD"))), 1)

    def test_p_value_matches_bootstrap_bounds(self):
        rows = [row(d, (-1.0 if d % 4 else 3.5)) for d in range(1, 29)]
        p = bootstrap_p_value(rows, 2000, 20260929)
        b = day_block_bootstrap_upper(rows, 2000, 20260929)
        self.assertGreater(p, 0.0)
        self.assertLess(p, 1.0)
        # same distribution: the 5% lower bound is <= 0 exactly when at least 5% of the means are <= 0
        self.assertEqual(b["lower"] <= 0, p >= 0.05)
        self.assertEqual(bootstrap_p_value([row(d, -1.0) for d in range(1, 10)], 500, 1), 1.0)
        self.assertEqual(bootstrap_p_value([row(d, 0.5) for d in range(1, 10)], 500, 1), 0.0)

    def test_holm(self):
        adj = holm({"a": 0.01, "b": 0.04, "c": 0.03, "d": None})
        self.assertAlmostEqual(adj["a"], 0.04)
        self.assertAlmostEqual(adj["c"], 0.09)
        self.assertAlmostEqual(adj["b"], 0.09)       # monotone step-down
        self.assertAlmostEqual(adj["d"], 1.0)

    def test_screen_classification(self):
        self.assertEqual(screen_classification({"n": 29, "upper95_mean_net_r": -0.5})["classification"], "SCREEN_INCONCLUSIVE_LOW_N")
        self.assertEqual(screen_classification({"n": 30, "upper95_mean_net_r": -0.01})["classification"], "SCREEN_STOP")
        self.assertEqual(screen_classification({"n": 30, "upper95_mean_net_r": 0.0})["classification"], "SCREEN_CONTINUE")
        self.assertEqual(screen_classification({"n": 110, "upper95_mean_net_r": 0.4})["classification"], "SCREEN_CONTINUE")

    def test_dev_decision(self):
        base = {"n": 250, "independent_days": 200, "upper95_mean_net_r": 0.3, "lower95_mean_net_r": 0.05}
        self.assertEqual(dev_decision(base)["classification"], "PROCEED_TO_ORB3")
        self.assertEqual(dev_decision(dict(base, lower95_mean_net_r=0.049))["classification"], "NO_EDGE_DEMONSTRATED")
        self.assertEqual(dev_decision(dict(base, upper95_mean_net_r=-0.01))["classification"], "STOP")
        self.assertEqual(dev_decision(dict(base, n=199))["classification"], "INCONCLUSIVE")
        self.assertEqual(dev_decision(dict(base, independent_days=59))["classification"], "INCONCLUSIVE")

    def test_range_guards(self):
        check_range([row(5, 1.0)], "screen")
        with self.assertRaises(SystemExit):
            check_range([row(5, 1.0)], "dev")                     # 2026 H1 never enters ORB-2
        with self.assertRaises(SystemExit):
            check_range([dict(row(5, 1.0), date="2025-03-03")], "screen")

    def test_rv_bucket(self):
        self.assertEqual([rv_bucket(v) for v in ("NA", "0.5", "0.75", "1.0", "1.499999", "1.5", "2.0")],
                         ["NA", "LT_0.75", "0.75_1", "1_1.5", "1_1.5", "1.5_2", "GE_2"])


if __name__ == "__main__":
    unittest.main()
