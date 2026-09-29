"""Independent Python reference for the ORB day ledger (roadmap Section 3).

Rebuilds orb_days_<ORLEN>.csv from the M1 BID bars, the weekly trading-session
schedule in reference_config.json, the data-quarantine windows and the detected
market closures. It does not translate MQL5 code; it implements Section 3 of
Opening_Range_Breakout_Roadmap.md directly. Reuses the LSR reference's Bar,
WilderAtr and number conventions (LSR 2.12 items 6 and 13).
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Sequence, Tuple

from lsr_reference.engine import Bar, WilderAtr, day_start, iso_date, iso_time, mql_round

SECONDS_PER_DAY = 86400
SESSION_START_SEC = 16 * 3600 + 30 * 60
EOD_SEC = 23 * 3600
RV_LOOKBACK = 14
NR_LOOKBACK = 7
SMA_PERIOD = 50
ATR_PERIOD = 14
NEWS_STATE = "NO_CALENDAR_OBSERVE_ONLY"
OR_LENGTHS: Tuple[Tuple[str, int], ...] = (("OR5", 5), ("OR15", 15))
WEEKDAYS = ("SUNDAY", "MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY")

HEADER = ("date,or_length,weekday,or_start,or_end,or_bars,or_open,or_high,or_low,or_close,or_ticks,or_width,direction,"
          "decision,in_quarantine,prior_valid_sessions,rv,f1,prev_date,prev_range,nr7,prev_close,sma50,f5,atr14_d,"
          "width_atr,width_bucket,news_state")


def weekday(t: int) -> int:
    """0 = Sunday ... 6 = Saturday (MQL5 ENUM_DAY_OF_WEEK)."""
    return (time.gmtime(t).tm_wday + 1) % 7


def width_bucket(ok: bool, ratio: float) -> str:
    if not ok:
        return "NA"
    if ratio < 0.05:
        return "LT_0.05"
    if ratio < 0.10:
        return "0.05_0.10"
    if ratio < 0.20:
        return "0.10_0.20"
    return "GE_0.20"


class Schedule:
    """Weekly broker trade sessions: weekday -> list of [from_sec, to_sec)."""

    def __init__(self, intervals: Dict[int, List[Tuple[int, int]]]):
        self.iv = {d: list(intervals.get(d, [])) for d in range(7)}

    @staticmethod
    def hhmm(s: str) -> int:
        h, m = s.split(":")
        return int(h) * 3600 + int(m) * 60

    @classmethod
    def from_json(cls, sched: dict) -> "Schedule":
        out: Dict[int, List[Tuple[int, int]]] = {}
        for wd in sched["weekdays"]:
            d = WEEKDAYS.index(wd["weekday"])
            out[d] = [(cls.hhmm(i["from"]), cls.hhmm(i["to_exclusive"])) for i in wd["normalized_intervals"]]
        return cls(out)

    def in_session(self, t: int) -> bool:
        sod = t % SECONDS_PER_DAY
        return any(a <= sod < b for a, b in self.iv[weekday(t)])


@dataclass
class DayRec:
    day: int
    first: bool
    open: float = 0.0
    high: float = 0.0
    low: float = 0.0
    close: float = 0.0
    or_bars: List[int] = field(default_factory=lambda: [0, 0])
    or_open: List[float] = field(default_factory=lambda: [0.0, 0.0])
    or_high: List[float] = field(default_factory=lambda: [0.0, 0.0])
    or_low: List[float] = field(default_factory=lambda: [0.0, 0.0])
    or_close: List[float] = field(default_factory=lambda: [0.0, 0.0])
    or_ticks: List[int] = field(default_factory=lambda: [0, 0])
    has_after: List[bool] = field(default_factory=lambda: [False, False])


@dataclass
class DayRow:
    day: int
    orlen: int
    or_bars: int
    or_open: float
    or_high: float
    or_low: float
    or_close: float
    or_ticks: int
    complete: bool
    dir: int
    decision: str
    in_quarantine: bool
    prior_valid: int
    rv_ok: bool
    rv: float
    f1: bool
    prev_ok: bool
    prev_day: int
    prev_range: float
    prev_close: float
    nr7_ok: bool
    nr7: bool
    sma_ok: bool
    sma50: float
    f5_ok: bool
    f5: bool
    atr_ok: bool
    atr: float
    width_ok: bool
    width_atr: float


class DayLedger:
    def __init__(self, digits: int, point: float):
        self.digits = digits
        self.point = point
        self.days: List[DayRec] = []
        self.rows: List[DayRow] = []

    def pts(self, price: float) -> int:
        return mql_round(price / self.point)

    def on_m1(self, b: Bar) -> None:
        d = day_start(b.time)
        if not self.days or d > self.days[-1].day:
            self.days.append(DayRec(day=d, first=not self.days, open=b.open, high=b.high, low=b.low))
        r = self.days[-1]
        if b.high > r.high:
            r.high = b.high
        if b.low < r.low:
            r.low = b.low
        r.close = b.close
        sod = b.time % SECONDS_PER_DAY
        for k, (_, minutes) in enumerate(OR_LENGTHS):
            or_end = SESSION_START_SEC + minutes * 60
            if SESSION_START_SEC <= sod < or_end:
                if r.or_bars[k] == 0:
                    r.or_open[k], r.or_high[k], r.or_low[k] = b.open, b.high, b.low
                if b.high > r.or_high[k]:
                    r.or_high[k] = b.high
                if b.low < r.or_low[k]:
                    r.or_low[k] = b.low
                r.or_close[k] = b.close
                r.or_ticks[k] += b.ticks
                r.or_bars[k] += 1
            elif or_end <= sod < EOD_SEC:
                r.has_after[k] = True

    def build(self, sched: Schedule, overlaps: Callable[[int, int], bool]) -> List[DayRow]:
        self.rows = []
        if not self.days:
            return self.rows
        prior: List[DayRec] = []
        tick_hist: List[List[int]] = [[] for _ in OR_LENGTHS]
        atr = WilderAtr(ATR_PERIOD)
        by_day = {r.day: r for r in self.days}
        d = self.days[0].day
        while d <= self.days[-1].day:
            rec: Optional[DayRec] = by_day.get(d)
            if sched.in_session(d + SESSION_START_SEC):
                np_ = len(prior)
                for k, (_, minutes) in enumerate(OR_LENGTHS):
                    or_start = d + SESSION_START_SEC
                    or_end = or_start + minutes * 60
                    bars = rec.or_bars[k] if rec else 0
                    o = rec.or_open[k] if rec else 0.0
                    h = rec.or_high[k] if rec else 0.0
                    lo = rec.or_low[k] if rec else 0.0
                    c = rec.or_close[k] if rec else 0.0
                    ticks = rec.or_ticks[k] if rec else 0
                    complete = bars == minutes
                    dp = self.pts(c) - self.pts(o)
                    dir_ = 0 if not complete else (1 if dp > 0 else -1 if dp < 0 else 0)
                    quar = overlaps(or_start, or_end)
                    valid = complete and not quar
                    hist = tick_hist[k]
                    nvalid = len(hist)
                    s = sum(hist[-RV_LOOKBACK:]) if nvalid >= RV_LOOKBACK else 0
                    rv_ok = valid and nvalid >= RV_LOOKBACK and s > 0
                    rv = ticks / (s / RV_LOOKBACK) if rv_ok else 0.0
                    f1 = rv_ok and ticks * RV_LOOKBACK >= s
                    prev = prior[-1] if prior else None
                    nr7_ok = np_ >= NR_LOOKBACK
                    nr7 = False
                    if nr7_ok:
                        pr = self.pts(prev.high) - self.pts(prev.low)
                        nr7 = all(pr <= self.pts(q.high) - self.pts(q.low) for q in prior[-NR_LOOKBACK:-1])
                    sma_ok = np_ >= SMA_PERIOD
                    close_sum = sum(self.pts(q.close) for q in prior[-SMA_PERIOD:]) if sma_ok else 0
                    sma50 = close_sum / SMA_PERIOD * self.point if sma_ok else 0.0
                    f5_ok = sma_ok and complete and dir_ != 0
                    pc50 = self.pts(prev.close) * SMA_PERIOD if prev else 0
                    f5 = f5_ok and (pc50 > close_sum if dir_ > 0 else pc50 < close_sum)
                    atr_ok = atr.ready
                    atr_v = atr.atr if atr_ok else 0.0
                    width_ok = complete and atr_ok and atr_v > 0.0
                    width_atr = (h - lo) / atr_v if width_ok else 0.0
                    has_after = bool(rec and rec.has_after[k])
                    if not complete:
                        decision = "NO_TRADE_INCOMPLETE_RANGE"
                    elif quar:
                        decision = "NO_TRADE_QUARANTINE"
                    elif nvalid < RV_LOOKBACK:
                        decision = "NO_TRADE_WARMUP"
                    elif dir_ == 0:
                        decision = "NO_TRADE_DOJI"
                    elif not has_after:
                        decision = "NO_TRADE_NO_TICK"
                    else:
                        decision = "TRADE"
                    self.rows.append(DayRow(
                        day=d, orlen=k, or_bars=bars, or_open=o, or_high=h, or_low=lo, or_close=c, or_ticks=ticks,
                        complete=complete, dir=dir_, decision=decision, in_quarantine=quar, prior_valid=nvalid,
                        rv_ok=rv_ok, rv=rv, f1=f1, prev_ok=prev is not None, prev_day=prev.day if prev else 0,
                        prev_range=(prev.high - prev.low) if prev else 0.0, prev_close=prev.close if prev else 0.0,
                        nr7_ok=nr7_ok, nr7=nr7, sma_ok=sma_ok, sma50=sma50, f5_ok=f5_ok, f5=f5,
                        atr_ok=atr_ok, atr=atr_v, width_ok=width_ok, width_atr=width_atr))
                    if valid:
                        hist.append(ticks)
            if rec is not None and not rec.first:
                prior.append(rec)
                atr.update(Bar(d, SECONDS_PER_DAY, rec.open, rec.high, rec.low, rec.close, 0))
            d += SECONDS_PER_DAY
        return self.rows

    # ---- formatting (LSR 2.12 items 13/14: prices with digits, ratios 6 decimals, NA) ----
    def row_text(self, r: DayRow) -> str:
        dg = self.digits

        def n(ok: bool, v: float, d: int) -> str:
            return f"{v:.{d}f}" if ok else "NA"

        def fl(ok: bool, v: bool) -> str:
            return ("1" if v else "0") if ok else "NA"

        name, minutes = OR_LENGTHS[r.orlen]
        or_start = r.day + SESSION_START_SEC
        any_ = r.or_bars > 0
        direction = "NA" if not r.complete else ("LONG" if r.dir > 0 else "SHORT" if r.dir < 0 else "NONE")
        return ",".join([
            iso_date(r.day), name, WEEKDAYS[weekday(r.day)], iso_time(or_start), iso_time(or_start + minutes * 60),
            str(r.or_bars), n(any_, r.or_open, dg), n(any_, r.or_high, dg), n(any_, r.or_low, dg), n(any_, r.or_close, dg),
            str(r.or_ticks), n(r.complete, r.or_high - r.or_low, dg), direction, r.decision,
            "1" if r.in_quarantine else "0", str(r.prior_valid), n(r.rv_ok, r.rv, 6), fl(r.rv_ok, r.f1),
            iso_date(r.prev_day) if r.prev_ok else "NA", n(r.prev_ok, r.prev_range, dg), fl(r.nr7_ok, r.nr7),
            n(r.prev_ok, r.prev_close, dg), n(r.sma_ok, r.sma50, 6), fl(r.f5_ok, r.f5), n(r.atr_ok, r.atr, 6),
            n(r.width_ok, r.width_atr, 6), width_bucket(r.width_ok, r.width_atr), NEWS_STATE])

    def lines(self, k: int) -> List[str]:
        return [HEADER] + [self.row_text(r) for r in self.rows if r.orlen == k]


def build_ledger(bars: Sequence[Bar], sched: Schedule, windows: Sequence[Tuple[int, int]],
                 digits: int, point: float) -> DayLedger:
    led = DayLedger(digits, point)
    for b in bars:
        led.on_m1(b)
    led.build(sched, lambda a, b: any(qa < b and a < qb for qa, qb in windows))
    return led
