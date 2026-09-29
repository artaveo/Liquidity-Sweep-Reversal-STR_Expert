"""Blocking ORB-1 fixtures for the Python reference (day ledger, proxies, commission).

The same fixtures, with the same expected values, are implemented in
MQL5/Scripts/LiquiditySweepReversal/LSR_Tests.mq5 (suites TestOrbDays, TestOrbProxy,
TestIndexCommission).
Run:  python -m unittest discover -s tests -v   (from python/)
"""

import calendar
import os
import sys
import unittest

sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")))

from lsr_reference.engine import Bar  # noqa: E402
from orb_reference.days import Schedule, build_ledger  # noqa: E402
from orb_reference.proxy import Harness, commission  # noqa: E402


def ts(y, mo, d, h=0, mi=0, s=0):
    return calendar.timegm((y, mo, d, h, mi, s, 0, 0, 0))


# Mon-Fri [01:00, 23:57), weekend closed (same as BuildGoldSchedule in LSR_Tests.mq5)
SCHED = Schedule({d: [(3600, 23 * 3600 + 57 * 60)] for d in range(1, 6)})
MON = ts(2026, 1, 5)


def weekdays(n, start=MON):
    out, d = [], start
    while len(out) < n:
        if SCHED.in_session(d + 16 * 3600 + 30 * 60):
            out.append(d)
        d += 86400
    return out


def bar(day, hh, mm, o, h, l, c, ticks=1):
    return Bar(day + hh * 3600 + mm * 60, 60, o, h, l, c, ticks)


def rows_by(led, k):
    """date -> dict of column values for OR length k."""
    lines = led.lines(k)
    hdr = lines[0].split(",")
    return {ln.split(",")[0]: dict(zip(hdr, ln.split(","))) for ln in lines[1:]}


def or15_day(day, skip=()):
    """The OR build fixture: 15 opening-range bars plus a 16:45 bar."""
    first5 = [(100.00, 101.00, 99.50, 100.50, 10), (100.50, 102.00, 100.00, 101.50, 11), (101.50, 101.80, 98.00, 99.00, 12),
              (99.00, 100.20, 98.50, 100.00, 13), (100.00, 100.90, 99.80, 100.80, 14)]
    bars = []
    for j in range(15):
        if 30 + j in skip:
            continue
        if j < 5:
            o, h, l, c, t = first5[j]
        else:
            o, h, l, c, t = 100.80, (103.00 if j == 10 else 100.90), 100.70, 100.80, 5
        bars.append(bar(day, 16, 30 + j, o, h, l, c, t))
    bars.append(bar(day, 16, 45, 100.80, 100.90, 100.70, 100.80, 5))
    return bars


def or5_day(day, ticks, doji=False, after=True):
    """Five rising OR5 bars (or a doji) with the given per-bar ticks, plus an optional 16:35 bar."""
    bars = []
    for j in range(5):
        o = 100.00 + 0.10 * j
        c = o + 0.10
        if doji:
            o, c = (100.00, 100.20) if j == 0 else (100.20, 100.00) if j == 4 else (100.20, 100.20)
        bars.append(bar(day, 16, 30 + j, o, max(o, c) + 0.05, min(o, c) - 0.05, c, ticks[j]))
    if after:
        bars.append(bar(day, 16, 35, 100.50, 100.60, 100.40, 100.50, 3))
    return bars


class TestOrbDays(unittest.TestCase):
    def test_or_build_and_missing_bar(self):
        d0, d1, d2 = weekdays(3)
        bars = or15_day(d0) + or15_day(d1, skip=(32,)) + or15_day(d2, skip=(40,))
        led = build_ledger(bars, SCHED, [], 2, 0.01)
        r5, r15 = rows_by(led, 0), rows_by(led, 1)
        a = r5["2026-01-05"]
        self.assertEqual((a["or_bars"], a["or_open"], a["or_high"], a["or_low"], a["or_close"], a["or_ticks"]),
                         ("5", "100.00", "102.00", "98.00", "100.80", "60"))
        self.assertEqual((a["or_width"], a["direction"], a["decision"], a["rv"], a["prior_valid_sessions"]),
                         ("4.00", "LONG", "NO_TRADE_WARMUP", "NA", "0"))
        b = r15["2026-01-05"]
        self.assertEqual((b["or_bars"], b["or_high"], b["or_close"], b["or_ticks"], b["or_end"]),
                         ("15", "103.00", "100.80", "110", "2026-01-05T16:45:00"))
        c = r5["2026-01-06"]
        self.assertEqual((c["or_bars"], c["direction"], c["or_width"], c["decision"]), ("4", "NA", "NA", "NO_TRADE_INCOMPLETE_RANGE"))
        self.assertEqual(r15["2026-01-06"]["decision"], "NO_TRADE_INCOMPLETE_RANGE")
        self.assertEqual(r5["2026-01-07"]["decision"], "NO_TRADE_WARMUP")
        self.assertEqual((r15["2026-01-07"]["or_bars"], r15["2026-01-07"]["decision"]), ("14", "NO_TRADE_INCOMPLETE_RANGE"))
        self.assertEqual(r5["2026-01-07"]["prior_valid_sessions"], "1")   # the incomplete day is not a valid session

    def test_rv_warmup_value_doji_no_tick(self):
        days = weekdays(17)
        bars = []
        for i, d in enumerate(days):
            if i == 14:
                bars += or5_day(d, [14] * 5)
            elif i == 15:
                bars += or5_day(d, [10, 10, 10, 10, 9], after=False)
            elif i == 16:
                bars += or5_day(d, [10] * 5, doji=True)
            else:
                bars += or5_day(d, [10] * 5)
        r = rows_by(build_ledger(bars, SCHED, [], 2, 0.01), 0)
        w = r["2026-01-22"]
        self.assertEqual((w["decision"], w["prior_valid_sessions"], w["rv"], w["f1"]), ("NO_TRADE_WARMUP", "13", "NA", "NA"))
        t = r["2026-01-23"]
        self.assertEqual((t["decision"], t["prior_valid_sessions"], t["rv"], t["f1"], t["or_ticks"]), ("TRADE", "14", "1.400000", "1", "70"))
        n = r["2026-01-26"]
        self.assertEqual((n["decision"], n["rv"], n["f1"]), ("NO_TRADE_NO_TICK", "0.952778", "0"))
        j = r["2026-01-27"]
        self.assertEqual((j["decision"], j["direction"], j["prior_valid_sessions"]), ("NO_TRADE_DOJI", "NONE", "16"))
        self.assertNotIn("2026-01-10", r)   # Saturday: 16:30 is not in a scheduled session

    def test_nr7_with_ties(self):
        days = weekdays(10)
        ranges = [5, 10, 8, 9, 12, 7, 11, 7, 20, 6]
        bars = [bar(d, 10, 0, 100.00, 100.00 + rg, 100.00, 100.00) for d, rg in zip(days, ranges)]
        r = rows_by(build_ledger(bars, SCHED, [], 2, 0.01), 0)
        self.assertEqual(r["2026-01-14"]["nr7"], "NA")                   # six prior complete days only
        x = r["2026-01-15"]
        self.assertEqual((x["nr7"], x["prev_date"], x["prev_range"]), ("1", "2026-01-14", "7.00"))  # tie counts
        self.assertEqual(r["2026-01-16"]["nr7"], "0")
        self.assertEqual(r["2026-01-05"]["prev_date"], "NA")

    def test_sma50_boundary(self):
        def run(last_close):
            days = weekdays(52)
            bars = []
            for i, d in enumerate(days):
                if i == 51:
                    bars += or5_day(d, [10] * 5)
                else:
                    c = 90.00 if i == 0 else (last_close if i == 50 else 100.00)
                    bars.append(bar(d, 10, 0, c, c, c, c))
            return rows_by(build_ledger(bars, SCHED, [], 2, 0.01), 0)
        r = run(100.50)
        self.assertEqual(r["2026-03-16"]["sma50"], "NA")                  # 49 prior complete days
        x = r["2026-03-17"]
        self.assertEqual((x["sma50"], x["prev_close"], x["direction"], x["f5"]), ("100.010000", "100.50", "LONG", "1"))
        y = run(100.00)["2026-03-17"]
        self.assertEqual((y["sma50"], y["f5"]), ("100.000000", "0"))       # close equal to SMA50 fails

    def test_quarantine_overlap(self):
        d = weekdays(1)[0]
        q1 = [(d + 16 * 3600 + 34 * 60, d + 16 * 3600 + 35 * 60)]
        r5, r15 = (rows_by(build_ledger(or15_day(d), SCHED, q1, 2, 0.01), k) for k in (0, 1))
        self.assertEqual((r5["2026-01-05"]["decision"], r5["2026-01-05"]["in_quarantine"]), ("NO_TRADE_QUARANTINE", "1"))
        self.assertEqual(r15["2026-01-05"]["decision"], "NO_TRADE_QUARANTINE")
        q2 = [(d + 16 * 3600 + 40 * 60, d + 16 * 3600 + 41 * 60)]
        r5, r15 = (rows_by(build_ledger(or15_day(d), SCHED, q2, 2, 0.01), k) for k in (0, 1))
        self.assertEqual((r5["2026-01-05"]["decision"], r5["2026-01-05"]["in_quarantine"]), ("NO_TRADE_WARMUP", "0"))
        self.assertEqual(r15["2026-01-05"]["decision"], "NO_TRADE_QUARANTINE")


def proxy_fixture():
    """Five weekdays of ticks, fed in the EA's order (see LSR_Tests.mq5 TestOrbProxy)."""
    h = Harness(SCHED.in_session, ts(2026, 1, 10))

    def tk(d, hh, mm, ss, ms, bid, ask=None):
        h.tick(ts(2026, 1, d, hh, mm, ss), ms, bid, bid + 1.0 if ask is None else ask)

    # A Mon: long, R2 target then R10 time exit
    for mm, b in ((30, 20000.00), (31, 20002.00), (32, 19990.00), (33, 20004.00), (34, 20003.00)):
        tk(5, 16, mm, 5, 0, b)
    tk(5, 16, 35, 0, 500, 20003.00)
    tk(5, 16, 37, 0, 0, 20040.00)
    tk(5, 22, 57, 0, 0, 20060.00)
    tk(5, 23, 0, 0, 0, 20100.00)
    # B Tue: short, stop wins over the time exit on the same tick
    for mm, b in ((30, 20010.00), (31, 20012.00), (32, 20005.00), (33, 20001.00), (34, 20002.00)):
        tk(6, 16, mm, 5, 0, b)
    tk(6, 16, 35, 0, 250, 20001.00)
    tk(6, 22, 58, 0, 0, 20005.00)
    tk(6, 23, 0, 30, 0, 20012.50)
    # C Wed: doji -> no proxy
    for mm, b in ((30, 20000.00), (31, 20003.00), (32, 19998.00), (33, 20001.00), (34, 20000.00)):
        tk(7, 16, mm, 5, 0, b)
    tk(7, 16, 35, 1, 0, 20000.00)
    # D Thu: long, the day ends at 19:59 -> early close on the last tick
    for mm, b in ((30, 20000.00), (31, 20001.00), (32, 19996.00), (33, 20002.00), (34, 20003.00)):
        tk(8, 16, mm, 5, 0, b)
    tk(8, 16, 35, 0, 0, 20003.00)
    tk(8, 19, 59, 0, 0, 20010.00)
    tk(9, 1, 0, 0, 0, 20020.00)
    # E Fri: long OR, entry tick far below the OR low -> invalid stop
    for mm, b in ((30, 19995.00), (31, 20000.00), (32, 19990.00), (33, 19998.00), (34, 19996.00)):
        tk(9, 16, mm, 5, 0, b)
    tk(9, 16, 35, 0, 0, 19985.00)
    h.sim.finish()
    return h


class TestOrbProxy(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.h = proxy_fixture()

    def p(self, d, e, k=0):
        return self.h.find(ts(2026, 1, d), k, e)

    def test_one_trade_per_or_length(self):
        self.assertEqual(len(self.h.sim.trades), 8)     # A2 + B2 + C0 + D2 + E2; OR15 never complete
        self.assertIsNone(self.p(5, 0, k=1))

    def test_r10_time_exit_and_r2_target(self):
        r10, r2 = self.p(5, 0), self.p(5, 1)
        self.assertEqual((r10.dir, r10.entry_msc), (1, ts(2026, 1, 5, 16, 35) * 1000 + 500))
        self.assertAlmostEqual(r10.entry, 20004.00)
        self.assertAlmostEqual(r10.sl, 19989.00)          # OR low - entry spread
        self.assertAlmostEqual(r10.r, 15.0)
        self.assertAlmostEqual(r10.tp, 20154.00)
        self.assertAlmostEqual(r2.tp, 20034.00)
        self.assertTrue(r10.f2)                           # spread 1.00 <= 0.10 x 15.00
        self.assertEqual((r2.state, r2.reason), ("CLOSED", "TP"))
        self.assertAlmostEqual(r2.net_r, 2.4)
        self.assertEqual((r10.reason, r10.exit_msc), ("TIME_EXIT", ts(2026, 1, 5, 23) * 1000))
        self.assertAlmostEqual(r10.net_r, 6.4)
        self.assertAlmostEqual(r10.mae, 1.0)
        self.assertAlmostEqual(r10.mfe, 96.0)

    def test_stop_wins_over_time(self):
        for e in (0, 1):
            p = self.p(6, e)
            self.assertEqual((p.dir, p.reason), (-1, "STOP"))
            self.assertAlmostEqual(p.sl, 20013.00)
            self.assertAlmostEqual(p.net_r, -12.5 / 12.0)
        self.assertAlmostEqual(self.p(6, 1).tp, 19977.00)

    def test_f2_pass_fail_doji_early_close_invalid_stop(self):
        self.assertIsNone(self.p(7, 0))                   # doji
        d = self.p(8, 0)
        self.assertAlmostEqual(d.r, 9.0)
        self.assertFalse(d.f2)                            # spread 1.00 > 0.10 x 9.00
        self.assertEqual((d.reason, d.exit_msc), ("TIME_EXIT_EARLY_CLOSE", ts(2026, 1, 8, 19, 59) * 1000))
        self.assertAlmostEqual(d.net_r, 6.0 / 9.0)
        e = self.p(9, 0)
        self.assertEqual((e.state, e.reason), ("NO_TRADE", "NO_TRADE_INVALID_STOP"))


class TestIndexCommission(unittest.TestCase):
    def test_index_commission_is_zero(self):
        self.assertEqual(commission("FUNDEDNEXT_OFFICIAL_INDICES", 1.0, 1.0, 20000.0, 0.0), 0.0)

    def test_metals_commission_unchanged(self):
        self.assertAlmostEqual(commission("FUNDEDNEXT_OFFICIAL_METALS", 1.0, 100.0, 4466.22, 0.0016), 7.145952, places=9)


if __name__ == "__main__":
    unittest.main()
