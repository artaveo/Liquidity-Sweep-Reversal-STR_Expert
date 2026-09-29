"""ORB trial statistics, the ORB-1S screen and the ORB-2 decision (roadmap 2.2, 5, ORB-1S).

Usage:
    python -m orb_reference.study <package_dir> [--mode screen|dev] [--reps 10000] [--seed 20260929]

Reads orb_trades_OR5.csv and orb_trades_OR15.csv from an ORB_Expert run package and
writes python_reference/orb_<mode>_report.json and .md.

--mode screen (ORB-1S, 2026 H1): only the primary trial OR5/UNFILTERED/R10_EOD decides:
  SCREEN_STOP when n >= 30 and Upper95 < 0; SCREEN_INCONCLUSIVE_LOW_N when n < 30;
  SCREEN_CONTINUE otherwise. The other 15 trials are information only.
--mode dev (ORB-2): Section 5.4 decision for the primary trial; refuses 2026 H1 and the
  2025 holdout.

The grid is fixed before any result is seen: 2 OR lengths x 4 filter sets x 2 exits.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import random
import statistics
import sys
from collections import Counter, defaultdict
from typing import Dict, List, Optional, Tuple

from lsr_reference.event_study import day_block_bootstrap_upper

OR_LENGTHS = ("OR5", "OR15")
FILTER_SETS = ("UNFILTERED", "BASE", "BASE_NR7", "BASE_TREND")
EXITS = ("R10_EOD", "R2_EOD")
PRIMARY = ("OR5", "UNFILTERED", "R10_EOD")
CO_REPORTED = ("OR5", "BASE", "R10_EOD")
DEFAULT_REPS = 10000
DEFAULT_SEED = 20260929
CONFIDENCE = 0.95
SCREEN_MIN_N = 30                 # ORB-1S
DEV_MIN_N = 200                   # 5.4 / LSR 0C.15
DEV_MIN_DAYS = 60
MIN_ECONOMIC_EDGE_R = 0.05        # LSR 0B.20
RV_BUCKETS = ((0.75, "LT_0.75"), (1.0, "0.75_1"), (1.5, "1_1.5"), (2.0, "1.5_2"))


def trial_id(t: Tuple[str, str, str]) -> str:
    return "/".join(t)


def all_trials() -> List[Tuple[str, str, str]]:
    return [(o, f, e) for o in OR_LENGTHS for f in FILTER_SETS for e in EXITS]


def read_rows(path: str) -> List[dict]:
    with open(path, "r", encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def passes_filters(row: dict, filter_set: str) -> bool:
    """Filter flags are pre-registered (roadmap 2.1); NA never passes. F7 is structural."""
    if filter_set == "UNFILTERED":
        return True
    base = row["f1"] == "1" and row["f2"] == "1"
    if filter_set == "BASE":
        return base
    if filter_set == "BASE_NR7":
        return base and row["nr7"] == "1"
    if filter_set == "BASE_TREND":
        return base and row["f5"] == "1"
    raise ValueError(filter_set)


def exclusion(row: dict) -> str:
    """'' when the proxy belongs to the Section 5.1 analysis set, else the reason."""
    if row["state"] != "CLOSED":
        return "NOT_TRADED_" + (row["reason"] or row["state"])
    if row["exit_reason"] == "END_OF_DATA":
        return "OPEN_AT_END_OF_DATA"
    if row["in_quarantine"] == "1":
        return "DATA_QUARANTINE"
    return ""


def analysis_set(rows: List[dict], trial: Tuple[str, str, str]) -> List[dict]:
    o, fs, e = trial
    return [r for r in rows if r["or_length"] == o and r["exit_variant"] == e and exclusion(r) == "" and passes_filters(r, fs)]


def bootstrap_p_value(rows: List[dict], reps: int, seed: int) -> Optional[float]:
    """Share of day-block bootstrap means <= 0 (roadmap 5.5). Same resampling scheme and
    random stream as lsr_reference.event_study.day_block_bootstrap_upper, so the p-value
    and the bounds come from the same bootstrap distribution."""
    by_day: Dict[str, List[float]] = defaultdict(list)
    for r in rows:
        by_day[r["entry_time"][:10]].append(float(r["net_r"]))
    days = sorted(by_day)
    if not days:
        return None
    sums = [sum(by_day[d]) for d in days]
    counts = [len(by_day[d]) for d in days]
    rng = random.Random(seed)
    k = len(days)
    le0 = 0
    for _ in range(reps):
        s = c = 0
        for _ in range(k):
            j = rng.randrange(k)
            s += sums[j]
            c += counts[j]
        if s / c <= 0:
            le0 += 1
    return le0 / reps


def holm(pvalues: Dict[str, Optional[float]]) -> Dict[str, Optional[float]]:
    """Holm-Bonferroni step-down adjusted p-values over every declared test (missing p = 1)."""
    items = sorted(((1.0 if p is None else p), t) for t, p in pvalues.items())
    m = len(items)
    adj: Dict[str, Optional[float]] = {}
    running = 0.0
    for i, (p, t) in enumerate(items):
        running = max(running, min(1.0, (m - i) * p))
        adj[t] = running
    return adj


def rv_bucket(v: str) -> str:
    if v in ("", "NA"):
        return "NA"
    x = float(v)
    for lim, name in RV_BUCKETS:
        if x < lim:
            return name
    return "GE_2"


def stratify(rows: List[dict], key) -> dict:
    groups: Dict[str, List[float]] = defaultdict(list)
    for r in rows:
        groups[key(r)].append(float(r["net_r"]))
    return {g: {"n": len(v), "mean_net_r": statistics.fmean(v)} for g, v in sorted(groups.items())}


def summarize(rows: List[dict], reps: int, seed: int) -> dict:
    net = [float(r["net_r"]) for r in rows]
    out = {"n": len(rows), "independent_days": len({r["entry_time"][:10] for r in rows})}
    if not rows:
        out.update({"mean_net_r": None, "upper95_mean_net_r": None, "lower95_mean_net_r": None, "p_value_mean_le_0": None})
        return out
    boot = day_block_bootstrap_upper(rows, reps, seed, CONFIDENCE)
    wins = sum(x for x in net if x > 0)
    losses = -sum(x for x in net if x < 0)
    f = lambda key: statistics.fmean(float(r[key]) for r in rows)  # noqa: E731
    out.update({
        "mean_net_r": statistics.fmean(net),
        "median_net_r": statistics.median(net),
        "win_rate": sum(1 for x in net if x > 0) / len(net),
        "profit_factor": (wins / losses) if losses > 0 else None,
        "upper95_mean_net_r": boot["upper"],
        "lower95_mean_net_r": boot["lower"],
        "p_value_mean_le_0": bootstrap_p_value(rows, reps, seed),
        "bootstrap": {"method": "day-block", "reps": reps, "seed": seed, "confidence": CONFIDENCE},
        "mean_costs_r": f("costs_r"),
        "mean_entry_spread_r": f("entry_spread_r"),
        "mean_mfe_r": f("mfe_r"),
        "mean_mae_r": f("mae_r"),
        "exit_reasons": dict(sorted(Counter(r["exit_reason"] for r in rows).items())),
        "by_direction": stratify(rows, lambda r: r["direction"]),
        "by_weekday": stratify(rows, lambda r: r["weekday"]),
        "by_width_bucket": stratify(rows, lambda r: r["width_bucket"]),
        "by_rv_bucket": stratify(rows, lambda r: rv_bucket(r["rv"])),
        "by_year": stratify(rows, lambda r: r["date"][:4]),
    })
    return out


def screen_classification(s: dict) -> dict:
    """ORB-1S item 2 (primary trial only)."""
    n = s["n"]
    if n < SCREEN_MIN_N:
        return {"classification": "SCREEN_INCONCLUSIVE_LOW_N", "reason": f"n = {n} < {SCREEN_MIN_N}; ask the owner"}
    if s["upper95_mean_net_r"] is not None and s["upper95_mean_net_r"] < 0:
        return {"classification": "SCREEN_STOP", "reason": "n >= 30 and Upper95(mean NetR) < 0; ORB stops, ask the owner"}
    return {"classification": "SCREEN_CONTINUE", "reason": "not clearly negative; proceed to ORB-2"}


def dev_decision(s: dict) -> dict:
    """Section 5.4 (primary trial, ORB-2 development range)."""
    if s["n"] < DEV_MIN_N or s["independent_days"] < DEV_MIN_DAYS:
        return {"classification": "INCONCLUSIVE", "reason": f"n < {DEV_MIN_N} or independent days < {DEV_MIN_DAYS}"}
    if s["upper95_mean_net_r"] < 0:
        return {"classification": "STOP", "reason": "Upper95 < 0"}
    if s["lower95_mean_net_r"] >= MIN_ECONOMIC_EDGE_R:
        return {"classification": "PROCEED_TO_ORB3", "reason": f"Lower95 >= +{MIN_ECONOMIC_EDGE_R}R"}
    return {"classification": "NO_EDGE_DEMONSTRATED", "reason": f"Upper95 >= 0 and Lower95 < +{MIN_ECONOMIC_EDGE_R}R"}


def check_range(rows: List[dict], mode: str) -> None:
    dates = [r["date"] for r in rows]
    if mode == "dev":
        bad = [d for d in dates if d.startswith("2025") or "2026-01-01" <= d <= "2026-06-30"]
        if bad:
            raise SystemExit(f"refused: ORB-2 statistics may not use 2026 H1 (ORB-1S) or the 2025 holdout; first bad date {bad[0]}")
    elif any(d.startswith("2025") for d in dates):
        raise SystemExit("refused: 2025 is the untouched holdout (ORB-4 only)")


def analyse(pkg: str, mode: str = "screen", reps: int = DEFAULT_REPS, seed: int = DEFAULT_SEED) -> dict:
    rows: List[dict] = []
    for o in OR_LENGTHS:
        rows += read_rows(os.path.join(pkg, f"orb_trades_{o}.csv"))
    check_range(rows, mode)
    rep = {"contract_id": "ORB-PHASE1-CONTRACT-2026-09-29", "package": os.path.abspath(pkg), "mode": mode,
           "rules": {"primary": trial_id(PRIMARY), "co_reported": trial_id(CO_REPORTED),
                     "analysis_set": "closed proxies, not END_OF_DATA, not in data quarantine, passing the trial's filter set",
                     "net_r": "RealizedNetPnL / PlannedRisk1R, 1 lot, LIVE_NATIVE_STOP",
                     "bootstrap": f"day-block, {reps} reps, seed {seed}, one-sided {CONFIDENCE:.0%} bounds",
                     "multiple_testing": "Holm-Bonferroni over all 16 one-sided tests (null: mean <= 0); never decisive"},
           "trials": {}}
    for name in ("data_quality_report.json", "manifest.json"):
        p = os.path.join(pkg, name)
        if os.path.exists(p):
            with open(p, "r", encoding="utf-8") as f:
                m = json.load(f)
            if name == "manifest.json":
                rep["experiment_id"] = m.get("experiment_id")
                rep["non_default_inputs"] = m.get("inputs", {}).get("non_default_inputs")
            else:
                rep["data_gate"] = m.get("raw_real_tick_audit", {}).get("gates", {}).get("result")
    for o in OR_LENGTHS:
        for e in EXITS:
            sub = [r for r in rows if r["or_length"] == o and r["exit_variant"] == e]
            rep.setdefault("exclusions", {})[f"{o}/{e}"] = dict(sorted(Counter(exclusion(r) or "IN_ANALYSIS_SET" for r in sub).items()))
    pvals = {}
    for t in all_trials():
        s = summarize(analysis_set(rows, t), reps, seed)
        rep["trials"][trial_id(t)] = s
        pvals[trial_id(t)] = s["p_value_mean_le_0"]
    for t, p in holm(pvals).items():
        rep["trials"][t]["holm_adjusted_p"] = p
        rep["trials"][t]["declared_trial_count"] = len(pvals)
    prim = rep["trials"][trial_id(PRIMARY)]
    rep["primary_decision"] = screen_classification(prim) if mode == "screen" else dev_decision(prim)
    rep["note"] = ("ORB-1S: no profitability claim is possible; only the primary trial decides. No input, filter, time or "
                   "exit may change because of these results." if mode == "screen" else
                   "ORB-2: only the primary trial decides; secondary trials carry the Holm adjustment.")
    return rep


def fmt(x, d=3):
    return "NA" if x is None else f"{x:.{d}f}"


def markdown(rep: dict) -> str:
    title = "ORB-1S Screening Report (2026 H1)" if rep["mode"] == "screen" else "ORB-2 Development Report"
    lines = [f"# {title}", "",
             f"Experiment `{rep.get('experiment_id')}` · data gate **{rep.get('data_gate')}** · non-default inputs: {rep.get('non_default_inputs')}", "",
             f"**Primary `{rep['rules']['primary']}`: {rep['primary_decision']['classification']}** — {rep['primary_decision']['reason']}", "",
             "NetR = RealizedNetPnL / PlannedRisk1R (1 lot). One-sided 95% bounds from a day-block bootstrap. "
             "Holm-adjusted p-values over all 16 trials are information only.", "",
             "| Trial | Role | n | Days | Mean NetR | Lower95 | Upper95 | Win rate | PF | Holm p | TP / STOP / TIME |",
             "|---|---|---|---|---|---|---|---|---|---|---|"]
    for t in all_trials():
        tid = trial_id(t)
        s = rep["trials"][tid]
        role = "PRIMARY" if t == PRIMARY else "CO-REPORTED" if t == CO_REPORTED else "secondary"
        ex = s.get("exit_reasons", {})
        tp = sum(v for k, v in ex.items() if k.endswith("TP"))
        st = sum(v for k, v in ex.items() if "STOP" in k or "BOTH" in k)
        tm = sum(v for k, v in ex.items() if "TIME_EXIT" in k)
        lines.append(f"| {tid} | {role} | {s['n']} | {s['independent_days']} | {fmt(s.get('mean_net_r'))} | "
                     f"{fmt(s.get('lower95_mean_net_r'))} | {fmt(s.get('upper95_mean_net_r'))} | {fmt(s.get('win_rate'))} | "
                     f"{fmt(s.get('profit_factor'))} | {fmt(s.get('holm_adjusted_p'))} | {tp} / {st} / {tm} |")
    lines += ["", rep["note"], ""]
    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("package_dir")
    ap.add_argument("--mode", choices=("screen", "dev"), default="screen")
    ap.add_argument("--reps", type=int, default=DEFAULT_REPS)
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED)
    args = ap.parse_args(argv)
    rep = analyse(args.package_dir, args.mode, args.reps, args.seed)
    out = os.path.join(args.package_dir, "python_reference")
    os.makedirs(out, exist_ok=True)
    base = os.path.join(out, f"orb_{args.mode}_report")
    with open(base + ".json", "w", encoding="utf-8") as f:
        json.dump(rep, f, indent=2)
    with open(base + ".md", "w", encoding="utf-8") as f:
        f.write(markdown(rep))
    for t in (PRIMARY, CO_REPORTED):
        s = rep["trials"][trial_id(t)]
        print(f"{trial_id(t)}: n={s['n']} days={s['independent_days']} meanNetR={fmt(s.get('mean_net_r'))} "
              f"lower95={fmt(s.get('lower95_mean_net_r'))} upper95={fmt(s.get('upper95_mean_net_r'))}")
    print(f"PRIMARY: {rep['primary_decision']['classification']} -> {base}.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
