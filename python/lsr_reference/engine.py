"""Independent Python reference for the Phase 2 event layer.

Implements roadmap 2.1-2.10A, 0B.1-0B.6, 0B.21, 0C.2-0C.6, 0C.19 and the
binding closures in roadmap 2.12 directly from the specification. It does not
import or translate MQL5 signal code; it consumes the normalized M1 bars and
reference configuration written by the Phase 1/2 run package.
"""

from __future__ import annotations

import hashlib
import math
import time
from dataclasses import dataclass, field
from typing import Callable, List, Optional

SECONDS_PER_DAY = 86400
ATR_PERIOD = 14
ID_HEX_CHARS = 16

TF_SECONDS = {"M1": 60, "M5": 300, "M15": 900, "M30": 1800, "H1": 3600}

LEVEL_KINDS = ["PDH", "PDL", "PSH", "PSL", "SWING_HIGH", "SWING_LOW", "EQUAL_HIGHS", "EQUAL_LOWS"]
PDH, PDL, PSH, PSL, SWING_HIGH, SWING_LOW, EQUAL_HIGHS, EQUAL_LOWS = range(8)

STATUS_KEYS = ["SETUP", "PARTIAL_POOL_SWEEP", "OPEN_ON_LIQUIDITY", "OPEN_INSIDE_POOL", "OPENED_BEYOND_POOL",
               "PREV_CLOSE_NOT_OUTSIDE", "NO_RECLAIM", "NO_PREVIOUS_BAR", "MULTI_POOL_NOT_SELECTED",
               "CONFLICTING_SWEEP_SAME_BAR"]


def kind_side(kind: int) -> int:
    return 1 if kind % 2 == 0 else -1


def side_name(side: int) -> str:
    return "HIGH" if side > 0 else "LOW"


def iso_time(t: int) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t))


def iso_date(t: int) -> str:
    return time.strftime("%Y-%m-%d", time.gmtime(t))


def day_start(t: int) -> int:
    return t - (t % SECONDS_PER_DAY)


def stable_id(canonical: str) -> str:
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:ID_HEX_CHARS]


def mql_round(x: float) -> int:
    """MathRound: half away from zero."""
    return int(math.floor(x + 0.5)) if x >= 0 else -int(math.floor(-x + 0.5))


def touch_bucket(n: int) -> str:
    return "3+" if n >= 3 else str(n)


@dataclass
class Bar:
    time: int
    period: int
    open: float
    high: float
    low: float
    close: float
    ticks: int

    @property
    def close_time(self) -> int:
        return self.time + self.period


@dataclass
class EventConfig:
    use_previous_day: bool = True
    use_previous_session: bool = True
    use_swings: bool = True
    use_equal: bool = True
    session_start_sec: int = 16 * 3600 + 30 * 60
    session_end_sec: int = 21 * 3600 + 30 * 60
    swing_left: int = 2
    swing_right: int = 2
    equal_tol_pips: float = 3.0
    cluster_tol_pips: float = 3.0
    multi_pool_policy: str = "FIRST_CROSSED_LEVEL"
    entry_mode: str = "RECLAIM_CLOSE"
    pip_size: float = 0.10
    point: float = 0.01
    digits: int = 2


class WilderAtr:
    def __init__(self, n: int):
        self.n = n
        self.count = 0
        self.sum = 0.0
        self.atr = 0.0
        self.have_prev = False
        self.prev_close = 0.0

    def update(self, b: Bar) -> None:
        tr = b.high - b.low
        if self.have_prev:
            a = abs(b.high - self.prev_close)
            c = abs(b.low - self.prev_close)
            if a > tr:
                tr = a
            if c > tr:
                tr = c
        self.prev_close = b.close
        self.have_prev = True
        self.count += 1
        if self.count < self.n:
            self.sum += tr
        elif self.count == self.n:
            self.sum += tr
            self.atr = self.sum / self.n
        else:
            self.atr = (self.atr * (self.n - 1) + tr) / self.n

    @property
    def ready(self) -> bool:
        return self.count >= self.n


@dataclass
class Level:
    id: str
    kind: int
    lo: float
    hi: float
    prices: List[float]
    instance: str
    avail: int
    arm: int
    arm_index: int
    swing_time: int
    prominence: Optional[float]
    members: str
    end_time: int = 0
    end_reason: str = ""
    active: bool = True
    pool: int = -1


@dataclass
class Pool:
    id: str
    side: int
    lower: float
    upper: float
    anchor: float
    members: List[int]
    member_ids: str
    tags: str
    arm: int
    arm_index: int
    level_arm: int
    level_arm_index: int
    predecessor: str
    inherited: int
    touches: int
    end_time: int = 0
    end_reason: str = ""
    active: bool = True


@dataclass
class Event:
    id: str
    pool: int
    status: str
    bar_index: int
    bar: Bar
    have_prev: bool
    prev_close: float
    atr_ready: bool
    atr: float
    touches: int


@dataclass
class Swing:
    side: int
    price: float
    bar_time: int
    conf_time: int
    live: bool = True


@dataclass
class Pending:
    kind: int
    lo: float
    hi: float
    prices: List[float]
    instance: str
    avail: int
    swing_time: int
    prominence: Optional[float]
    members: str


class TfAggregator:
    def __init__(self, period: int):
        self.period = period
        self.cur: Optional[Bar] = None

    def on_m1(self, m1: Bar) -> Optional[Bar]:
        bt = m1.time - (m1.time % self.period)
        done = None
        if self.cur is not None and bt != self.cur.time:
            done = self.cur
            self.cur = None
        if self.cur is None:
            self.cur = Bar(bt, self.period, m1.open, m1.high, m1.low, m1.close, m1.ticks)
        else:
            if m1.high > self.cur.high:
                self.cur.high = m1.high
            if m1.low < self.cur.low:
                self.cur.low = m1.low
            self.cur.close = m1.close
            self.cur.ticks += m1.ticks
        return done

    def flush(self) -> Optional[Bar]:
        done, self.cur = self.cur, None
        return done


class EventEngine:
    """One isolated engine per SignalTimeframe."""

    def __init__(self, tf: str, cfg: EventConfig):
        self.cfg = cfg
        self.tf = tf
        self.period = TF_SECONDS[tf]
        self.eq_tol_pts = mql_round(cfg.equal_tol_pips * cfg.pip_size / cfg.point)
        self.cluster_tol_pts = mql_round(cfg.cluster_tol_pips * cfg.pip_size / cfg.point)
        self.agg = TfAggregator(self.period)
        self.atr = WilderAtr(ATR_PERIOD)
        self.bars: List[Bar] = []
        self.first_m1: Optional[int] = None
        self.day_have = False
        self.day = 0
        self.day_hi = self.day_lo = 0.0
        self.ses_have = False
        self.ses_date = 0
        self.ses_hi = self.ses_lo = 0.0
        self.levels: List[Level] = []
        self.pools: List[Pool] = []
        self.touches: List[tuple] = []
        self.events: List[Event] = []
        self.swings: List[Swing] = []
        self.pending: List[Pending] = []
        self.active_high: List[int] = []
        self.active_low: List[int] = []
        self.live_sw_high: List[int] = []
        self.live_sw_low: List[int] = []
        self.active_by_kind = [-1, -1, -1, -1]

    # ------------------------------------------------------------------ helpers
    def pts(self, p: float) -> int:
        return mql_round(p / self.cfg.point)

    def fp(self, p: float) -> str:
        return f"{p:.{self.cfg.digits}f}"

    def _high_before(self, a: int, b: int) -> bool:
        pa, pb = self.pools[a], self.pools[b]
        if pa.lower != pb.lower:
            return pa.lower < pb.lower
        if pa.upper != pb.upper:
            return pa.upper < pb.upper
        return pa.id < pb.id

    def _low_before(self, a: int, b: int) -> bool:
        pa, pb = self.pools[a], self.pools[b]
        if pa.upper != pb.upper:
            return pa.upper > pb.upper
        if pa.lower != pb.lower:
            return pa.lower > pb.lower
        return pa.id < pb.id

    def _insert_active(self, pi: int) -> None:
        lst = self.active_high if self.pools[pi].side > 0 else self.active_low
        before = self._high_before if self.pools[pi].side > 0 else self._low_before
        lst.append(pi)
        pos = len(lst) - 1
        while pos > 0 and before(pi, lst[pos - 1]):
            lst[pos] = lst[pos - 1]
            pos -= 1
        lst[pos] = pi

    # -------------------------------------------------------------------- pools
    def _create_pool(self, members: List[int], arm: int, arm_index: int, predecessor: str, inherited: int) -> int:
        side = kind_side(self.levels[members[0]].kind)
        prices: List[float] = []
        ids: List[str] = []
        kinds_seen = set()
        lv_arm = 0
        lv_arm_idx = 0
        for i, li in enumerate(members):
            lv = self.levels[li]
            ids.append(lv.id)
            kinds_seen.add(lv.kind)
            prices.extend(lv.prices)
            if i == 0 or lv.arm < lv_arm:
                lv_arm = lv.arm
                lv_arm_idx = lv.arm_index
        prices.sort()
        ids.sort()
        np_ = len(prices)
        anchor = prices[np_ // 2] if np_ % 2 == 1 else (prices[np_ // 2 - 1] + prices[np_ // 2]) / 2.0
        id_list = ";".join(ids)
        tags = ";".join(LEVEL_KINDS[k] for k in range(8) if k in kinds_seen)
        pid = stable_id("P|" + self.tf + "|" + side_name(side) + "|" + iso_time(arm) + "|" + id_list.replace(";", ","))
        pool = Pool(pid, side, prices[0], prices[-1], anchor, list(members), id_list, tags, arm, arm_index,
                    lv_arm, lv_arm_idx, predecessor, inherited, inherited)
        self.pools.append(pool)
        pi = len(self.pools) - 1
        for li in members:
            self.levels[li].pool = pi
        self._insert_active(pi)
        return pi

    def _end_pool(self, pi: int, t: int, reason: str) -> None:
        p = self.pools[pi]
        p.active = False
        p.end_time = t
        p.end_reason = reason
        (self.active_high if p.side > 0 else self.active_low).remove(pi)

    def _join_pool(self, li: int, t: int, next_index: int) -> None:
        lv = self.levels[li]
        side = kind_side(lv.kind)
        llo, lhi = self.pts(lv.lo), self.pts(lv.hi)
        mid = (lv.lo + lv.hi) / 2.0
        best = -1
        best_dist = 0.0
        for pi in (self.active_high if side > 0 else self.active_low):
            p = self.pools[pi]
            width = max(self.pts(p.upper), lhi) - min(self.pts(p.lower), llo)
            if width > self.cluster_tol_pts:
                continue
            d = abs(p.anchor - mid)
            if best < 0:
                better = True
            else:
                b = self.pools[best]
                better = d < best_dist or (d == best_dist and (p.arm > b.arm or (p.arm == b.arm and p.id < b.id)))
            if better:
                best, best_dist = pi, d
        if best < 0:
            self._create_pool([li], t, next_index, "", 0)
            return
        members = list(self.pools[best].members) + [li]
        pred = self.pools[best].id
        inh = self.pools[best].touches
        self._end_pool(best, t, "SUPERSEDED")
        self._create_pool(members, t, next_index, pred, inh)

    def _expire_level(self, li: int, t: int, next_index: int) -> None:
        lv = self.levels[li]
        if not lv.active:
            return
        lv.active = False
        lv.end_time = t
        lv.end_reason = "EXPIRED"
        pi = lv.pool
        if pi < 0 or not self.pools[pi].active:
            return
        rest = [m for m in self.pools[pi].members if m != li]
        pred = self.pools[pi].id
        inh = self.pools[pi].touches
        self._end_pool(pi, t, "MEMBER_EXPIRED" if rest else "EXPIRED")
        if rest:
            self._create_pool(rest, t, next_index, pred, inh)

    # ------------------------------------------------------------------ pending
    def _queue(self, kind, lo, hi, prices, instance, avail, swing_time, prominence, members) -> None:
        self.pending.append(Pending(kind, lo, hi, list(prices), instance, avail, swing_time, prominence, members))

    def _pending_key(self, q: Pending):
        return (q.kind // 2, -kind_side(q.kind), q.lo, q.hi, q.instance)

    def _apply_pending(self, t: int, next_index: int) -> None:
        ready = [q for q in self.pending if q.avail <= t]
        if not ready:
            return
        self.pending = [q for q in self.pending if q.avail > t]
        ready.sort(key=self._pending_key)
        for q in ready:
            if q.kind <= PSL and self.active_by_kind[q.kind] >= 0:
                self._expire_level(self.active_by_kind[q.kind], t, next_index)
                self.active_by_kind[q.kind] = -1
        for q in ready:
            price_key = self.fp(q.lo) if q.lo == q.hi else self.fp(q.lo) + "-" + self.fp(q.hi)
            lid = stable_id("L|" + self.tf + "|" + LEVEL_KINDS[q.kind] + "|" + q.instance + "|" + price_key)
            lv = Level(lid, q.kind, q.lo, q.hi, q.prices, q.instance, q.avail, t, next_index, q.swing_time,
                       q.prominence, q.members)
            self.levels.append(lv)
            li = len(self.levels) - 1
            if q.kind <= PSL:
                self.active_by_kind[q.kind] = li
            self._join_pool(li, t, next_index)

    # --------------------------------------------------------- day and session
    def _track_day(self, b: Bar) -> None:
        d = day_start(b.time)
        if self.day_have and d != self.day:
            if self.cfg.use_previous_day and self.day != day_start(self.first_m1):
                avail = self.day + SECONDS_PER_DAY
                self._queue(PDH, self.day_hi, self.day_hi, [self.day_hi], iso_date(self.day), avail, 0, None, "")
                self._queue(PDL, self.day_lo, self.day_lo, [self.day_lo], iso_date(self.day), avail, 0, None, "")
            self.day_have = False
        if not self.day_have:
            self.day, self.day_hi, self.day_lo, self.day_have = d, b.high, b.low, True
        else:
            if b.high > self.day_hi:
                self.day_hi = b.high
            if b.low < self.day_lo:
                self.day_lo = b.low

    def _track_session(self, b: Bar) -> None:
        ds = day_start(b.time)
        sod = b.time - ds
        s, e = self.cfg.session_start_sec, self.cfg.session_end_sec
        if self.ses_have and (ds != self.ses_date or sod >= e):
            if self.cfg.use_previous_session and self.first_m1 <= self.ses_date + s:
                inst = iso_time(self.ses_date + s)
                avail = self.ses_date + e
                self._queue(PSH, self.ses_hi, self.ses_hi, [self.ses_hi], inst, avail, 0, None, "")
                self._queue(PSL, self.ses_lo, self.ses_lo, [self.ses_lo], inst, avail, 0, None, "")
            self.ses_have = False
        if s <= sod < e:
            if not self.ses_have:
                self.ses_date, self.ses_hi, self.ses_lo, self.ses_have = ds, b.high, b.low, True
            else:
                if b.high > self.ses_hi:
                    self.ses_hi = b.high
                if b.low < self.ses_lo:
                    self.ses_lo = b.low

    # ----------------------------------------------------------- classification
    @staticmethod
    def _classify_high(p: Pool, b: Bar, have_prev: bool, prev_close: float):
        crossing = b.high > p.upper
        if not crossing:
            if b.open < p.lower and have_prev and prev_close < p.lower:
                return "PARTIAL_POOL_SWEEP", False
            return "", False
        if b.open > p.upper:
            return "OPENED_BEYOND_POOL", True
        if b.open == p.lower:
            return "OPEN_ON_LIQUIDITY", True
        if b.open > p.lower:
            return "OPEN_INSIDE_POOL", True
        if not have_prev:
            return "NO_PREVIOUS_BAR", True
        if prev_close >= p.lower:
            return "PREV_CLOSE_NOT_OUTSIDE", True
        if b.close >= p.lower:
            return "NO_RECLAIM", True
        return "VALID", True

    @staticmethod
    def _classify_low(p: Pool, b: Bar, have_prev: bool, prev_close: float):
        crossing = b.low < p.lower
        if not crossing:
            if b.open > p.upper and have_prev and prev_close > p.upper:
                return "PARTIAL_POOL_SWEEP", False
            return "", False
        if b.open < p.lower:
            return "OPENED_BEYOND_POOL", True
        if b.open == p.upper:
            return "OPEN_ON_LIQUIDITY", True
        if b.open < p.upper:
            return "OPEN_INSIDE_POOL", True
        if not have_prev:
            return "NO_PREVIOUS_BAR", True
        if prev_close <= p.upper:
            return "PREV_CLOSE_NOT_OUTSIDE", True
        if b.close <= p.upper:
            return "NO_RECLAIM", True
        return "VALID", True

    def _select(self, cand: List[int], side: int) -> int:
        first = self.cfg.multi_pool_policy == "FIRST_CROSSED_LEVEL"
        # (side > 0 and first) or (side < 0 and not first): prefer lowest lower
        prefer_low = (side > 0) == first
        best = -1
        for pi in cand:
            if best < 0:
                best = pi
                continue
            p, b = self.pools[pi], self.pools[best]
            if prefer_low:
                better = p.lower < b.lower or (p.lower == b.lower and (p.upper < b.upper or (p.upper == b.upper and p.id < b.id)))
            else:
                better = p.upper > b.upper or (p.upper == b.upper and (p.lower > b.lower or (p.lower == b.lower and p.id < b.id)))
            if better:
                best = pi
        return best

    def _add_event(self, pi, status, k, b, have_prev, prev_close, atr_ready, atr) -> None:
        eid = stable_id("E|" + self.tf + "|" + self.pools[pi].id + "|" + iso_time(b.time))
        self.events.append(Event(eid, pi, status, k, b, have_prev, prev_close, atr_ready, atr, self.pools[pi].touches))

    def _consume_pool(self, pi: int, t: int, status: str) -> None:
        if status == "SETUP":
            reason = "SWEPT"
        elif status in ("MULTI_POOL_NOT_SELECTED", "CONFLICTING_SWEEP_SAME_BAR"):
            reason = "SWEPT_NOT_TRADED"
        else:
            reason = "BREACHED_" + status
        self._end_pool(pi, t, reason)
        for li in self.pools[pi].members:
            lv = self.levels[li]
            if not lv.active:
                continue
            lv.active = False
            lv.end_time = t
            lv.end_reason = reason
            if lv.kind <= PSL and self.active_by_kind[lv.kind] == li:
                self.active_by_kind[lv.kind] = -1

    def _evaluate(self, k, b, have_prev, prev_close, atr_ready, atr) -> None:
        high_rows, low_rows = [], []
        for pi in self.active_high:
            if not (b.high > self.pools[pi].lower):
                break
            st, crossing = self._classify_high(self.pools[pi], b, have_prev, prev_close)
            if st == "" and not crossing:
                continue
            high_rows.append([pi, st, crossing])
        for pi in self.active_low:
            if not (b.low < self.pools[pi].upper):
                break
            st, crossing = self._classify_low(self.pools[pi], b, have_prev, prev_close)
            if st == "" and not crossing:
                continue
            low_rows.append([pi, st, crossing])
        hsel = self._select([r[0] for r in high_rows if r[1] == "VALID"], 1)
        lsel = self._select([r[0] for r in low_rows if r[1] == "VALID"], -1)
        conflict = hsel >= 0 and lsel >= 0
        for rows, sel in ((high_rows, hsel), (low_rows, lsel)):
            for r in rows:
                if r[1] == "VALID":
                    r[1] = "MULTI_POOL_NOT_SELECTED" if r[0] != sel else ("CONFLICTING_SWEEP_SAME_BAR" if conflict else "SETUP")
                self._add_event(r[0], r[1], k, b, have_prev, prev_close, atr_ready, atr)
        close_t = b.close_time
        for rows in (high_rows, low_rows):
            for r in rows:
                if r[2]:
                    self._consume_pool(r[0], close_t, r[1])

    def _add_touch(self, pi: int, t: int) -> None:
        self.pools[pi].touches += 1
        self.touches.append((pi, t, self.pools[pi].touches))

    def _update_touches(self, b: Bar, have_prev: bool, prev_close: float) -> None:
        for pi in list(self.active_high):
            p = self.pools[pi]
            if p.lower > b.high:
                break
            if p.upper < b.low:
                continue
            if not have_prev or prev_close < p.lower or prev_close > p.upper:
                self._add_touch(pi, b.time)
        for pi in list(self.active_low):
            p = self.pools[pi]
            if p.upper < b.low:
                break
            if p.lower > b.high:
                continue
            if not have_prev or prev_close < p.lower or prev_close > p.upper:
                self._add_touch(pi, b.time)

    # -------------------------------------------------------------------- swings
    def _violate_swings(self, b: Bar) -> None:
        while self.live_sw_high and self.swings[self.live_sw_high[0]].price < b.high:
            self.swings[self.live_sw_high[0]].live = False
            self.live_sw_high.pop(0)
        while self.live_sw_low and self.swings[self.live_sw_low[0]].price > b.low:
            self.swings[self.live_sw_low[0]].live = False
            self.live_sw_low.pop(0)

    def _insert_live_swing(self, si: int) -> None:
        s = self.swings[si]
        lst = self.live_sw_high if s.side > 0 else self.live_sw_low
        lst.append(si)
        pos = len(lst) - 1
        if s.side > 0:
            while pos > 0 and self.swings[lst[pos - 1]].price > s.price:
                lst[pos] = lst[pos - 1]
                pos -= 1
        else:
            while pos > 0 and self.swings[lst[pos - 1]].price < s.price:
                lst[pos] = lst[pos - 1]
                pos -= 1
        lst[pos] = si

    def _register_swing(self, side: int, c: int, k: int) -> None:
        conf_t = self.bars[k].close_time
        price = self.bars[c].high if side > 0 else self.bars[c].low
        prom = None
        for s in reversed(self.swings):
            if s.side == -side and s.conf_time < conf_t:
                if self.atr.ready and self.atr.atr > 0.0:
                    prom = abs(price - s.price) / self.atr.atr
                break
        cand: List[int] = []
        if self.cfg.use_equal:
            pts = self.pts(price)
            for si in (self.live_sw_high if side > 0 else self.live_sw_low):
                sw = self.swings[si]
                if sw.conf_time >= conf_t:
                    continue
                if abs(self.pts(sw.price) - pts) > self.eq_tol_pts:
                    continue
                cand.append(si)
        self.swings.append(Swing(side, price, self.bars[c].time, conf_t))
        s_idx = len(self.swings) - 1
        self._insert_live_swing(s_idx)
        if self.cfg.use_swings:
            self._queue(SWING_HIGH if side > 0 else SWING_LOW, price, price, [price], iso_time(self.bars[c].time),
                        conf_t, self.bars[c].time, prom, "")
        if self.cfg.use_equal and cand:
            ref = self.pts(price)
            cand.sort(key=lambda si: (abs(self.pts(self.swings[si].price) - ref),
                                      -self.swings[si].conf_time, -self.swings[si].bar_time))
            mem = [s_idx]
            mn = mx = self.pts(price)
            for si in cand:
                p = self.pts(self.swings[si].price)
                nmn, nmx = min(mn, p), max(mx, p)
                if nmx - nmn > self.eq_tol_pts:
                    continue
                mn, mx = nmn, nmx
                mem.append(si)
            if len(mem) >= 2:
                prices = sorted(self.swings[m].price for m in mem)
                times = sorted(iso_time(self.swings[m].bar_time) for m in mem)
                members = ";".join(times)
                self._queue(EQUAL_HIGHS if side > 0 else EQUAL_LOWS, prices[0], prices[-1], prices, members,
                            conf_t, self.bars[c].time, None, members)

    def _detect_swings(self, k: int) -> None:
        c = k - self.cfg.swing_right
        if c - self.cfg.swing_left < 0:
            return
        is_high = is_low = True
        for j in range(c - self.cfg.swing_left, c + self.cfg.swing_right + 1):
            if j == c:
                continue
            if not (self.bars[c].high > self.bars[j].high):
                is_high = False
            if not (self.bars[c].low < self.bars[j].low):
                is_low = False
        if is_high:
            self._register_swing(1, c, k)
        if is_low:
            self._register_swing(-1, c, k)

    # ---------------------------------------------------------------- pipeline
    def _process_bar(self, b: Bar, apply_time: int) -> None:
        k = len(self.bars)
        self.bars.append(b)
        have_prev = k > 0
        prev_close = self.bars[k - 1].close if have_prev else 0.0
        atr_ready, atr = self.atr.ready, self.atr.atr
        self._evaluate(k, b, have_prev, prev_close, atr_ready, atr)
        self._update_touches(b, have_prev, prev_close)
        self._violate_swings(b)
        self.atr.update(b)
        self._detect_swings(k)
        self._apply_pending(apply_time, k + 1)

    def on_m1(self, m1: Bar) -> None:
        if self.first_m1 is None:
            self.first_m1 = m1.time
        self._track_day(m1)
        self._track_session(m1)
        done = self.agg.on_m1(m1)
        if done is not None:
            self._process_bar(done, m1.time - (m1.time % self.period))

    def flush(self) -> None:
        done = self.agg.flush()
        if done is not None:
            self._process_bar(done, done.close_time)

    def inject_level(self, kind: int, lo: float, hi: float, instance: str) -> None:
        """Test hook: queue a level that becomes effective at the next bar boundary."""
        self._queue(kind, lo, hi, [lo] if lo == hi else [lo, hi], instance, 0, 0, None, "")

    # ------------------------------------------------------------------ ledgers
    def ledger_lines(self, in_quarantine: Callable[[int, int], bool]) -> dict:
        cfg = self.cfg
        tf = self.tf
        fp = self.fp

        def na(ok: bool, v: float, d: int) -> str:
            return f"{v:.{d}f}" if ok else "NA"

        def tt(t: int) -> str:
            return iso_time(t) if t > 0 else ""

        events = ["tf,event_id,pool_id,side,direction,status,sweep_bar_time,sweep_close_time,open,high,low,close,prev_close,"
                  "pool_lower,pool_upper,pool_anchor,sweep_extreme,penetration,reclaim,penetration_pips,reclaim_pips,atr,"
                  "penetration_atr,reclaim_atr,touch_count,touch_bucket,source_tags,member_level_ids,level_age_sec,level_age_bars,"
                  "pool_age_sec,pool_age_bars,confirmation_mode,multi_pool_policy,in_quarantine,decision_trace"]
        for e in self.events:
            p = self.pools[e.pool]
            b = e.bar
            pen = b.high - p.upper if p.side > 0 else p.lower - b.low
            rec = p.lower - b.close if p.side > 0 else b.close - p.upper
            atr_ok = e.atr_ready and e.atr > 0.0
            close_t = b.time + self.period
            trace = ("LEVEL_ELIGIBLE=PASS|POOL_MATCH=" + p.id + "|SWEEP_VALID=" + e.status + "|TOUCH_COUNT=" + str(e.touches) +
                     "|ENTRY_MODE=" + cfg.entry_mode +
                     "|FILTER_A=NOT_EVALUATED|FILTER_B=NOT_EVALUATED|FILTER_C=NOT_EVALUATED|NEWS_STATE=OBSERVE_ONLY"
                     "|SPREAD_STATE=NOT_EVALUATED|RISK_STATE=NOT_EVALUATED|ACCOUNT_RULE_STATE=NOT_EVALUATED|FINAL_ADMISSION=NOT_EVALUATED")
            row = [tf, e.id, p.id, side_name(p.side), "SHORT" if p.side > 0 else "LONG", e.status,
                   tt(b.time), tt(close_t), fp(b.open), fp(b.high), fp(b.low), fp(b.close),
                   fp(e.prev_close) if e.have_prev else "NA",
                   fp(p.lower), fp(p.upper), f"{p.anchor:.{cfg.digits + 1}f}",
                   fp(b.high if p.side > 0 else b.low), fp(pen), fp(rec),
                   f"{pen / cfg.pip_size:.4f}", f"{rec / cfg.pip_size:.4f}",
                   na(atr_ok, e.atr, 8), na(atr_ok, pen / e.atr if atr_ok else 0.0, 6),
                   na(atr_ok, rec / e.atr if atr_ok else 0.0, 6),
                   str(e.touches), touch_bucket(e.touches), p.tags, p.member_ids,
                   str(b.time - p.level_arm), str(e.bar_index - p.level_arm_index),
                   str(b.time - p.arm), str(e.bar_index - p.arm_index),
                   cfg.entry_mode, cfg.multi_pool_policy, "1" if in_quarantine(b.time, close_t) else "0", trace]
            events.append(",".join(row))

        levels = ["tf,level_id,kind,side,price_low,price_high,source_instance,available_time,arm_time,end_time,end_reason,pool_id,prominence_atr,members"]
        for lv in self.levels:
            levels.append(",".join([tf, lv.id, LEVEL_KINDS[lv.kind], side_name(kind_side(lv.kind)), fp(lv.lo), fp(lv.hi),
                                    lv.instance, tt(lv.avail), tt(lv.arm), tt(lv.end_time),
                                    "ACTIVE" if lv.active else lv.end_reason,
                                    self.pools[lv.pool].id if lv.pool >= 0 else "",
                                    na(lv.prominence is not None, lv.prominence or 0.0, 6), lv.members]))

        pools = ["tf,pool_id,side,pool_lower,pool_upper,pool_anchor,source_tags,member_level_ids,arm_time,end_time,end_reason,final_state,predecessor_pool_id,inherited_touches,touches"]
        for p in self.pools:
            if p.active:
                state = "TOUCHED" if p.touches > 0 else "ARMED"
            elif p.end_reason == "SUPERSEDED":
                state = "SUPERSEDED"
            elif p.end_reason in ("EXPIRED", "MEMBER_EXPIRED"):
                state = "EXPIRED"
            else:
                state = "CONSUMED"
            pools.append(",".join([tf, p.id, side_name(p.side), fp(p.lower), fp(p.upper), f"{p.anchor:.{cfg.digits + 1}f}",
                                   p.tags, p.member_ids, tt(p.arm), tt(p.end_time),
                                   "ACTIVE" if p.active else p.end_reason, state, p.predecessor,
                                   str(p.inherited), str(p.touches)]))

        touches = ["tf,pool_id,touch_bar_time,touch_number,band_lower,band_upper"]
        for pi, t, n in self.touches:
            p = self.pools[pi]
            touches.append(",".join([tf, p.id, tt(t), str(n), fp(p.lower), fp(p.upper)]))

        return {"events": events, "levels": levels, "pools": pools, "touches": touches}

    def summary(self) -> dict:
        counts = {s: sum(1 for e in self.events if e.status == s) for s in STATUS_KEYS}
        longs = sum(1 for e in self.events if e.status == "SETUP" and self.pools[e.pool].side < 0)
        shorts = sum(1 for e in self.events if e.status == "SETUP" and self.pools[e.pool].side > 0)
        return {"timeframe": self.tf, "bars": len(self.bars), "swings": len(self.swings), "levels": len(self.levels),
                "pools": len(self.pools), "active_pools_at_end": len(self.active_high) + len(self.active_low),
                "touches": len(self.touches), "event_rows": len(self.events), "event_status_counts": counts,
                "setups_long": longs, "setups_short": shorts}
