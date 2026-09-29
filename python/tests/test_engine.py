"""Blocking Phase 2 event fixtures for the Python reference.

The same fixtures, with the same expected values, are implemented in
MQL5/Scripts/LiquiditySweepReversal/LSR_Tests.mq5 (suite "2 Events").
Run:  python -m unittest discover -s python/tests -v
"""

import calendar
import os
import sys
import unittest

sys.path.insert(0, os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")))

from lsr_reference.engine import (Bar, EventConfig, EventEngine, TfAggregator, WilderAtr, stable_id,  # noqa: E402
                                  PDH, SWING_HIGH, PDL, EQUAL_HIGHS)


def ts(y, mo, d, h=0, mi=0, s=0):
    return calendar.timegm((y, mo, d, h, mi, s, 0, 0, 0))


BASE = ts(2026, 1, 5, 10, 0)  # Monday


def m1(i, o, h, l, c, base=BASE):
    return Bar(base + 60 * i, 60, o, h, l, c, 1)


def feed(engine, bars):
    for b in bars:
        engine.on_m1(b)


def only_pd_cfg(**kw):
    # previous-day source on, but fixtures never complete a second day: no accidental levels
    cfg = EventConfig(use_previous_day=True, use_previous_session=False, use_swings=False, use_equal=False)
    for k, v in kw.items():
        setattr(cfg, k, v)
    return cfg


SWING_BARS = [
    (2000.00, 2000.50, 1999.80, 2000.20),
    (2000.20, 2001.00, 2000.10, 2000.80),
    (2000.80, 2002.00, 2000.60, 2001.50),
    (2001.50, 2001.70, 2000.90, 2001.00),
    (2001.00, 2001.20, 2000.40, 2000.60),
    (2000.60, 2001.40, 2000.30, 2001.20),
    (2001.20, 2001.95, 2001.10, 2001.80),
]


def swing_engine(extra, cfg=None):
    e = EventEngine("M1", cfg or EventConfig(use_previous_day=False, use_previous_session=False, use_swings=True, use_equal=False))
    bars = [m1(i, *b) for i, b in enumerate(SWING_BARS + extra)]
    feed(e, bars)
    e.flush()
    return e


class TestBarsAndAtr(unittest.TestCase):
    def test_tf_aggregation(self):
        agg = TfAggregator(300)
        out = []
        for i in range(10):
            done = agg.on_m1(m1(i, 2000 + i, 2000.5 + i, 1999.5 + i, 2000.2 + i))
            if done:
                out.append(done)
        out.append(agg.flush())
        self.assertEqual(len(out), 2)
        self.assertEqual((out[0].time, out[0].open, out[0].high, out[0].low, out[0].close), (BASE, 2000, 2004.5, 1999.5, 2004.2))
        self.assertEqual(out[1].time, BASE + 300)

    def test_wilder_atr(self):
        atr = WilderAtr(3)
        closes = [(10, 12, 9, 11), (11, 13, 10, 12), (12, 15, 11, 14), (14, 14.5, 12, 13)]
        for i, (o, h, l, c) in enumerate(closes):
            atr.update(Bar(i * 60, 60, o, h, l, c, 1))
            if i == 1:
                self.assertFalse(atr.ready)
        # TR: 3, 3, 4, 2.5 -> ATR3 = (3+3+4)/3 = 3.3333; ATR4 = (3.3333*2+2.5)/3
        self.assertAlmostEqual(atr.atr, ((10.0 / 3) * 2 + 2.5) / 3, places=12)


class TestSweeps(unittest.TestCase):
    def test_valid_sweep_of_confirmed_swing(self):
        e = swing_engine([(2001.80, 2002.00, 2001.60, 2001.70),   # touch #1 (high == level)
                          (2001.70, 2002.60, 2001.50, 2001.60),   # valid sweep
                          (2001.60, 2002.70, 2001.40, 2002.65)])  # pool already consumed
        setups = [ev for ev in e.events if ev.status == "SETUP"]
        self.assertEqual(len(e.events), 1)
        self.assertEqual(len(setups), 1)
        ev = setups[0]
        p = e.pools[ev.pool]
        self.assertEqual(p.side, 1)
        self.assertEqual(ev.touches, 1)
        self.assertAlmostEqual(ev.bar.high - p.upper, 0.60, places=9)
        self.assertAlmostEqual(p.lower - ev.bar.close, 0.40, places=9)
        self.assertEqual(p.end_reason, "SWEPT")
        self.assertEqual(p.arm, BASE + 5 * 60)  # confirmed at close of bar 4, effective at open of bar 5
        self.assertEqual(ev.id, EXPECTED_IDS["fixture_a_event"])
        self.assertEqual(e.levels[0].id, EXPECTED_IDS["fixture_a_swing_level"])

    def test_rejections(self):
        cases = {
            "OPEN_ON_LIQUIDITY": [(2002.00, 2002.50, 2001.80, 2001.90)],
            "NO_RECLAIM": [(2001.80, 2002.50, 2001.70, 2002.10)],
            "OPENED_BEYOND_POOL": [(2002.30, 2002.50, 2002.10, 2002.20)],
        }
        for status, extra in cases.items():
            e = swing_engine(extra + [(2001.0, 2001.1, 2000.9, 2001.0)])
            self.assertEqual([ev.status for ev in e.events], [status], status)
            self.assertTrue(e.pools[e.events[0].pool].end_reason.startswith("BREACHED_"), status)
        # previous close on the level: not outside the pool
        e = EventEngine("M1", EventConfig(use_previous_day=False, use_previous_session=False, use_swings=True, use_equal=False))
        bars = SWING_BARS[:6] + [(2001.20, 2002.00, 2001.10, 2002.00), (2001.90, 2002.40, 2001.80, 2001.90)]
        feed(e, [m1(i, *b) for i, b in enumerate(bars)])
        e.flush()
        self.assertEqual([ev.status for ev in e.events], ["PREV_CLOSE_NOT_OUTSIDE"])

    def test_multi_pool_and_conflict(self):
        for policy, expected in (("FIRST_CROSSED_LEVEL", ["SETUP", "MULTI_POOL_NOT_SELECTED"]),
                                 ("DEEPEST_PENETRATION_LEVEL", ["MULTI_POOL_NOT_SELECTED", "SETUP"])):
            e = EventEngine("M1", only_pd_cfg(multi_pool_policy=policy))
            e.inject_level(SWING_HIGH, 2001.00, 2001.00, "fx-a")
            e.inject_level(SWING_HIGH, 2001.50, 2001.50, "fx-b")
            feed(e, [m1(0, 2000.00, 2000.20, 1999.90, 2000.10), m1(1, 2000.10, 2001.80, 2000.00, 2000.50)])
            e.flush()
            self.assertEqual([ev.status for ev in e.events], expected, policy)
            self.assertEqual(len(e.active_high), 0)
        e = EventEngine("M1", only_pd_cfg())
        e.inject_level(SWING_HIGH, 2001.00, 2001.00, "fx-a")
        e.inject_level(SWING_HIGH, 2001.50, 2001.50, "fx-b")
        e.inject_level(PDL, 1999.00, 1999.00, "fx-c")
        feed(e, [m1(0, 2000.00, 2000.20, 1999.90, 2000.10), m1(1, 2000.10, 2001.20, 1998.50, 2000.00)])
        e.flush()
        self.assertEqual([ev.status for ev in e.events], ["CONFLICTING_SWEEP_SAME_BAR", "CONFLICTING_SWEEP_SAME_BAR"])
        self.assertEqual(len(e.active_high), 1)  # 2001.50 was never reached

    def test_partial_pool_then_sweep(self):
        e = EventEngine("M1", only_pd_cfg())
        e.inject_level(EQUAL_HIGHS, 2001.00, 2001.20, "fx-band")
        feed(e, [m1(0, 2000.00, 2000.20, 1999.90, 2000.10),
                 m1(1, 2000.10, 2001.10, 2000.00, 2000.50),
                 m1(2, 2000.50, 2001.40, 2000.40, 2000.60)])
        e.flush()
        self.assertEqual([ev.status for ev in e.events], ["PARTIAL_POOL_SWEEP", "SETUP"])
        self.assertEqual(e.events[1].touches, 1)

    def test_clustering_supersession_and_inherited_touches(self):
        e = EventEngine("M1", only_pd_cfg())
        e.inject_level(PDH, 2001.00, 2001.00, "fx-pdh")
        feed(e, [m1(0, 2000.00, 2000.20, 1999.90, 2000.10), m1(1, 2000.50, 2001.00, 2000.40, 2000.60)])
        e.inject_level(SWING_HIGH, 2001.20, 2001.20, "fx-sw1")
        feed(e, [m1(2, 2000.60, 2000.80, 2000.50, 2000.60)])
        e.inject_level(SWING_HIGH, 2001.40, 2001.40, "fx-sw2")
        feed(e, [m1(3, 2000.60, 2001.30, 2000.50, 2000.70), m1(4, 2000.70, 2000.90, 2000.60, 2000.80)])
        e.flush()
        self.assertEqual(len(e.pools), 3)
        self.assertEqual(e.pools[0].end_reason, "SUPERSEDED")
        p = e.pools[1]
        self.assertEqual((p.tags, p.lower, p.upper, p.inherited), ("PDH;SWING_HIGH", 2001.00, 2001.20, 1))
        self.assertAlmostEqual(p.anchor, 2001.10, places=9)
        self.assertEqual([ev.status for ev in e.events], ["SETUP"])
        self.assertEqual(e.events[0].touches, 1)
        self.assertTrue(e.pools[2].active)

    def test_touch_rule(self):
        e = EventEngine("M1", only_pd_cfg())
        e.inject_level(SWING_HIGH, 2001.00, 2001.00, "fx")
        feed(e, [m1(0, 2000.00, 2000.20, 1999.90, 2000.10),
                 m1(1, 2000.10, 2001.00, 2000.00, 2000.50),   # touch 1
                 m1(2, 2000.50, 2000.90, 2000.40, 2000.60),   # no contact
                 m1(3, 2000.60, 2001.00, 2000.50, 2001.00),   # touch 2, closes on the band
                 m1(4, 2001.00, 2001.00, 2000.70, 2000.80),   # contact, previous close inside: same touch
                 m1(5, 2000.80, 2001.50, 2000.70, 2000.90)])  # sweep
        e.flush()
        self.assertEqual(len(e.touches), 2)
        self.assertEqual([ev.status for ev in e.events], ["SETUP"])
        self.assertEqual(e.events[0].touches, 2)


class TestSources(unittest.TestCase):
    def test_previous_day_and_session(self):
        cfg = EventConfig(use_previous_day=True, use_previous_session=True, use_swings=False, use_equal=False)
        e = EventEngine("M1", cfg)
        d0, d1, d2 = ts(2026, 1, 5), ts(2026, 1, 6), ts(2026, 1, 7)
        bars = [Bar(d0 + 10 * 3600, 60, 2000.0, 2005.0, 1995.0, 2000.0, 1),       # first observed day: skipped
                Bar(d1 + 10 * 3600, 60, 2000.0, 2010.0, 1990.0, 2000.0, 1),
                Bar(d1 + 17 * 3600, 60, 2000.0, 2012.0, 1991.0, 2000.0, 1),
                Bar(d1 + 18 * 3600, 60, 2000.0, 2008.0, 1993.0, 2000.0, 1),
                Bar(d2 + 1 * 3600, 60, 2000.0, 2001.0, 1999.0, 2000.0, 1),
                Bar(d2 + 1 * 3600 + 60, 60, 2000.0, 2013.0, 1999.5, 2005.0, 1)]
        feed(e, bars)
        e.flush()
        kinds = {(["PDH", "PDL", "PSH", "PSL"][lv.kind], lv.lo) for lv in e.levels}
        self.assertEqual(kinds, {("PDH", 2012.0), ("PDL", 1990.0), ("PSH", 2012.0), ("PSL", 1991.0)})
        self.assertTrue(all(lv.arm == d2 + 3600 for lv in e.levels))
        self.assertEqual(len(e.pools), 4)
        self.assertEqual([ev.status for ev in e.events], ["SETUP"])
        self.assertEqual(e.pools[e.events[0].pool].tags, "PDH;PSH")

    def test_equal_highs(self):
        cfg = EventConfig(use_previous_day=False, use_previous_session=False, use_swings=True, use_equal=True)
        e = EventEngine("M1", cfg)
        bars = [(2000.00, 2000.50, 1999.80, 2000.20), (2000.20, 2001.00, 2000.10, 2000.80),
                (2000.80, 2002.00, 2000.60, 2001.50), (2001.50, 2001.50, 2000.90, 2001.00),
                (2001.00, 2001.20, 2000.40, 2000.60), (2000.60, 2001.60, 2000.50, 2001.40),
                (2001.40, 2001.90, 2001.20, 2001.30), (2001.30, 2001.50, 2000.95, 2001.00),
                (2001.00, 2001.40, 2000.85, 2001.10), (2001.10, 2002.30, 2001.00, 2001.70)]
        feed(e, [m1(i, *b) for i, b in enumerate(bars)])
        e.flush()
        eq = [lv for lv in e.levels if lv.kind == EQUAL_HIGHS]
        self.assertEqual(len(eq), 1)
        self.assertEqual((eq[0].lo, eq[0].hi), (2001.90, 2002.00))
        setups = [ev for ev in e.events if ev.status == "SETUP"]
        self.assertEqual(len(setups), 1)
        p = e.pools[setups[0].pool]
        self.assertEqual(p.tags, "SWING_HIGH;EQUAL_HIGHS")
        self.assertAlmostEqual(p.anchor, 2001.95, places=9)
        self.assertAlmostEqual(setups[0].bar.high - p.upper, 0.30, places=9)


class TestIdentity(unittest.TestCase):
    def test_stable_id(self):
        self.assertEqual(stable_id("abc"), "ba7816bf8f01cfea")

    def test_deterministic_rerun(self):
        a = swing_engine([(2001.80, 2002.00, 2001.60, 2001.70), (2001.70, 2002.60, 2001.50, 2001.60)])
        b = swing_engine([(2001.80, 2002.00, 2001.60, 2001.70), (2001.70, 2002.60, 2001.50, 2001.60)])
        self.assertEqual([ev.id for ev in a.events], [ev.id for ev in b.events])
        self.assertEqual(a.ledger_lines(lambda x, y: False), b.ledger_lines(lambda x, y: False))


# Filled from the reference run; the MQL5 test suite asserts the same constants.
EXPECTED_IDS = {
    "fixture_a_event": "fe6198d644d45855",
    "fixture_a_swing_level": "64a5fad6d55b0573",
}

if __name__ == "__main__":
    unittest.main()
