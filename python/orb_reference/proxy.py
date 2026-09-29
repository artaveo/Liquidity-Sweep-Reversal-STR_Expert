"""Python mirror of the ORB proxy mechanics (roadmap Section 4) for the blocking fixtures.

Implements Section 2/4 directly: one entry attempt per OR length and broker day at the
first tick at or after the OR end, Long at Ask / Short at Bid, SL at the opposite OR
extreme widened by the entry spread (aligned outward), net 10R / 2R targets, exit
precedence stop -> target -> time (tick >= 23:00), end-of-day close on the last tick
of a broker day that has no tick at or after 23:00. Linear CFD economics only
(profit = price change x contract size), which is what the fixtures use. The MQL5
simulator (ORB_Proxy.mqh) is the one used for the research runs.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Callable, List, Optional

from lsr_reference.engine import Bar, day_start

from .days import EOD_SEC, OR_LENGTHS, SESSION_START_SEC, DayLedger

EXITS = (("R10_EOD", 10.0), ("R2_EOD", 2.0))
F2_MAX_SPREAD_TO_STOP = 0.10
GAP_SECONDS = 300
EPS = 1e-9


def commission(mode: str, lots: float, contract_size: float, price: float, rate_percent: float) -> float:
    """FUNDEDNEXT_OFFICIAL_METALS: lots x contract x price x rate%; FUNDEDNEXT_OFFICIAL_INDICES: 0 (roadmap 1.3)."""
    if mode == "FUNDEDNEXT_OFFICIAL_INDICES":
        return 0.0
    return lots * contract_size * price * (rate_percent / 100.0)


@dataclass
class Quote:
    msc: int
    bid: float
    ask: float

    @property
    def t(self) -> int:
        return self.msc // 1000


@dataclass
class Proxy:
    day: int
    orlen: int
    exitv: int
    dir: int
    state: str = "OPEN"
    reason: str = ""
    entry_msc: int = 0
    entry: float = 0.0
    sl: float = 0.0
    tp: float = 0.0
    r: float = 0.0
    commission: float = 0.0
    f2: bool = False
    mfe: float = 0.0
    mae: float = 0.0
    last_msc: int = 0
    exit_msc: int = 0
    exit_price: float = 0.0

    @property
    def net_r(self) -> float:
        return ((self.exit_price - self.entry) * self.dir * self.contract - self.commission) / self.r

    contract: float = 1.0


class M1Builder:
    def __init__(self, digits: int):
        self.digits = digits
        self.cur: Optional[Bar] = None

    def on_quote(self, q: Quote) -> Optional[Bar]:
        px = round(q.bid, self.digits)
        bt = q.t - q.t % 60
        done = None
        if self.cur is not None and bt != self.cur.time:
            done, self.cur = self.cur, None
        if self.cur is None:
            self.cur = Bar(bt, 60, px, px, px, px, 1)
        else:
            self.cur.high = max(self.cur.high, px)
            self.cur.low = min(self.cur.low, px)
            self.cur.close = px
            self.cur.ticks += 1
        return done


class ProxySim:
    def __init__(self, days: DayLedger, tick_size: float, digits: int, contract_size: float,
                 in_session: Callable[[int], bool], range_end: int, commission_mode: str = "FUNDEDNEXT_OFFICIAL_INDICES",
                 rate_percent: float = 0.0, latency_ms: int = 0):
        self.days, self.tick, self.digits, self.contract = days, tick_size, digits, contract_size
        self.in_session, self.range_end = in_session, range_end
        self.mode, self.rate, self.latency = commission_mode, rate_percent, latency_ms
        self.trades: List[Proxy] = []
        self.attempt = [None] * len(OR_LENGTHS)
        self.last: Optional[Quote] = None

    def _open(self) -> List[Proxy]:
        return [p for p in self.trades if p.state == "OPEN"]

    def _eod_reason(self, day: int) -> str:
        return "TIME_EXIT_EARLY_CLOSE" if self.in_session(day + EOD_SEC) else "TIME_EXIT"

    def _close(self, p: Proxy, q: Quote, reason: str) -> None:
        p.exit_msc, p.state, p.reason = q.msc, "CLOSED", reason
        p.exit_price = q.bid if p.dir > 0 else q.ask

    def _complete_range(self, day: int, k: int):
        if not self.days.days or self.days.days[-1].day != day:
            return None
        r = self.days.days[-1]
        if r.or_bars[k] != OR_LENGTHS[k][1]:
            return None
        dp = self.days.pts(r.or_close[k]) - self.days.pts(r.or_open[k])
        return r.or_high[k], r.or_low[k], (1 if dp > 0 else -1 if dp < 0 else 0)

    def _enter(self, p: Proxy, q: Quote, h: float, lo: float) -> None:
        spread = q.ask - q.bid
        entry = q.ask if p.dir > 0 else q.bid
        sl = lo - spread if p.dir > 0 else h + spread
        sl = (math.floor(sl / self.tick + 1e-9) if p.dir > 0 else math.ceil(sl / self.tick - 1e-9)) * self.tick
        sl = round(sl, self.digits)
        p.entry_msc, p.entry, p.sl, p.last_msc, p.contract = q.msc, entry, sl, q.msc, self.contract
        if (p.dir > 0 and not sl < entry) or (p.dir < 0 and not sl > entry):
            p.state, p.reason = "NO_TRADE", "NO_TRADE_INVALID_STOP"
            return
        p.commission = commission(self.mode, 1.0, self.contract, entry, self.rate)
        p.r = abs(entry - sl) * self.contract + p.commission
        p.f2 = spread <= F2_MAX_SPREAD_TO_STOP * abs(entry - sl) + EPS
        gross = EXITS[p.exitv][1] * p.r + p.commission
        tp = entry + p.dir * gross / self.contract
        tp = (math.ceil(tp / self.tick - 1e-9) if p.dir > 0 else math.floor(tp / self.tick + 1e-9)) * self.tick
        p.tp = round(tp, self.digits)
        fav0 = p.dir * ((q.bid if p.dir > 0 else q.ask) - entry)
        p.mfe, p.mae = fav0, max(0.0, -fav0)

    def _update(self, p: Proxy, q: Quote) -> None:
        fav = p.dir * ((q.bid if p.dir > 0 else q.ask) - p.entry)
        p.mfe, p.mae = max(p.mfe, fav), max(p.mae, -fav)
        stop = q.bid <= p.sl if p.dir > 0 else q.ask >= p.sl
        tp = q.bid >= p.tp if p.dir > 0 else q.ask <= p.tp
        tm = q.t >= p.day + EOD_SEC
        gap = q.msc - p.last_msc > GAP_SECONDS * 1000
        p.last_msc = q.msc
        g = "GAP_" if gap else ""
        if stop and tp:
            self._close(p, q, "GAP_CROSSED_BOTH_BARRIERS" if gap else "STOP_AMBIGUOUS_BOTH_BARRIERS")
        elif stop:
            self._close(p, q, g + "STOP")
        elif tp:
            self._close(p, q, g + "TP")
        elif tm:
            self._close(p, q, g + "TIME_EXIT")

    def on_quote(self, q: Quote) -> None:
        day = day_start(q.t)
        if self.last is not None:
            for p in self._open():
                if day > p.day:
                    self._close(p, self.last, self._eod_reason(p.day))
        for p in self._open():
            self._update(p, q)
        for k, (_, minutes) in enumerate(OR_LENGTHS):
            if self.attempt[k] == day:
                continue
            or_end = day + SESSION_START_SEC + minutes * 60
            if q.msc < or_end * 1000 + self.latency:
                continue
            self.attempt[k] = day
            if q.t >= day + EOD_SEC:
                continue
            rng = self._complete_range(day, k)
            if rng is None or rng[2] == 0:
                continue
            for e in range(len(EXITS)):
                p = Proxy(day=day, orlen=k, exitv=e, dir=rng[2])
                self.trades.append(p)
                self._enter(p, q, rng[0], rng[1])
        self.last = q

    def finish(self) -> None:
        for p in self._open():
            if self.last is None:
                continue
            reason = self._eod_reason(p.day) if p.day + 86400 <= self.range_end else "END_OF_DATA"
            self._close(p, self.last, reason)


class Harness:
    """Ticks -> M1 bars -> day ledger -> proxies, in the EA's order."""

    def __init__(self, in_session: Callable[[int], bool], range_end: int, digits: int = 2, point: float = 0.01,
                 tick_size: float = 0.01, contract_size: float = 1.0):
        self.days = DayLedger(digits, point)
        self.m1 = M1Builder(digits)
        self.sim = ProxySim(self.days, tick_size, digits, contract_size, in_session, range_end)

    def tick(self, t: int, ms: int, bid: float, ask: float) -> None:
        q = Quote(t * 1000 + ms, bid, ask)
        b = self.m1.on_quote(q)
        if b is not None:
            self.days.on_m1(b)
        self.sim.on_quote(q)

    def find(self, day: int, k: int, e: int) -> Optional[Proxy]:
        for p in self.sim.trades:
            if p.day == day and p.orlen == k and p.exitv == e:
                return p
        return None
