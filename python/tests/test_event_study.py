"""Blocking tests for the Phase 3 event-study statistics."""

import os
import sys
import unittest

sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")))

from lsr_reference.event_study import (analysis_filter, classify_timeframe, day_block_bootstrap_upper,  # noqa: E402
                                       reversal_table)


def row(day, net, state="CLOSED", exit_reason="TP", window="1", quar="0"):
    return {"state": state, "reason": "", "exit_reason": exit_reason, "in_entry_window": window, "in_quarantine": quar,
            "entry_time": f"2026-01-{day:02d}T10:00:00.000", "net_r": str(net)}


class TestEventStudy(unittest.TestCase):
    def test_analysis_filter(self):
        self.assertEqual(analysis_filter(row(5, 1.0)), "")
        self.assertEqual(analysis_filter(row(5, 1.0, state="EXPIRED")), "NOT_TRADED_EXPIRED")
        self.assertEqual(analysis_filter(row(5, 1.0, exit_reason="END_OF_DATA")), "OPEN_AT_END_OF_DATA")
        self.assertEqual(analysis_filter(row(5, 1.0, quar="1")), "DATA_QUARANTINE")
        self.assertEqual(analysis_filter(row(5, 1.0, window="0")), "OUTSIDE_STRATEGY_ENTRY_WINDOW")

    def test_bootstrap_deterministic_and_ordered(self):
        rows = [row(d, (-1.02 if d % 3 else 2.0)) for d in range(1, 29)]
        a = day_block_bootstrap_upper(rows, 2000, 7)
        b = day_block_bootstrap_upper(rows, 2000, 7)
        self.assertEqual(a, b)
        mean = sum(float(r["net_r"]) for r in rows) / len(rows)
        self.assertLess(a["lower"], mean)
        self.assertGreater(a["upper"], mean)

    def test_constant_sample(self):
        rows = [row(d, -1.0) for d in range(1, 25)]
        self.assertAlmostEqual(day_block_bootstrap_upper(rows, 500, 1)["upper"], -1.0)

    def test_classification(self):
        ok = {"events": 150, "independent_days": 40}
        neg = dict(ok, upper95_mean_net_r=-0.05)
        pos = dict(ok, upper95_mean_net_r=0.02)
        self.assertEqual(classify_timeframe({"A": neg, "B": neg})["classification"], "STOP_EARLY_REDESIGN")
        self.assertEqual(classify_timeframe({"A": neg, "B": pos})["classification"], "CONTINUE")
        small = dict(neg, events=99)
        self.assertEqual(classify_timeframe({"A": small, "B": neg})["classification"], "INCONCLUSIVE")
        few_days = dict(neg, independent_days=19)
        self.assertEqual(classify_timeframe({"A": neg, "B": few_days})["classification"], "INCONCLUSIVE")

    def test_reversal_table(self):
        rows = [{f"class_{h}": c for h in (1, 3, 5, 10, 20)} for c in ("REVERSAL", "REVERSAL", "CONTINUATION", "NA", "UNRESOLVED")]
        t = reversal_table(rows)
        self.assertEqual((t["1"]["REVERSAL"], t["1"]["CONTINUATION"], t["1"]["UNRESOLVED"], t["1"]["NA"]), (2, 1, 1, 1))
        self.assertAlmostEqual(t["20"]["reversal_share"], 0.5)


if __name__ == "__main__":
    unittest.main()
