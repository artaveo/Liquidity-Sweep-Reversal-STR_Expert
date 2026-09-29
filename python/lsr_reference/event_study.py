"""Phase 3 event-study report and early-stop classification (roadmap 3.1-3.7, 3.8).

Usage:
    python -m lsr_reference.event_study <package_dir> [--reps 10000] [--seed 20260929]

Reads event_study_<TF>.csv written by LSR_Expert for every timeframe in
reference_config.json and writes python_reference/event_study_report.json and
event_study_report.md. Every timeframe and hypothesis is evaluated separately;
nothing is pooled across timeframes (3.6).
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import random
import statistics
import sys
from collections import Counter, defaultdict
from typing import Dict, List

HYPOTHESES = ("A_RECLAIM_CONTROL", "B_NEXT_BAR_CONFIRM")
HORIZONS = (1, 3, 5, 10, 20)
MIN_EVENTS = 100          # EarlyStopMinEventsPerHypothesis
MIN_DAYS = 20             # EarlyStopMinIndependentDevelopmentDays
CONFIDENCE = 0.95         # EarlyStopConfidenceLevel
DEFAULT_REPS = 10000
DEFAULT_SEED = 20260929


def read_rows(path: str) -> List[dict]:
    with open(path, "r", encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def analysis_filter(row: dict) -> str:
    """'' when the proxy belongs to the analysis set, else the exclusion reason."""
    if row["state"] != "CLOSED":
        return "NOT_TRADED_" + (row["reason"] or row["state"])
    if row["exit_reason"] == "END_OF_DATA":
        return "OPEN_AT_END_OF_DATA"
    if row["in_quarantine"] == "1":
        return "DATA_QUARANTINE"
    if row["in_entry_window"] != "1":
        return "OUTSIDE_STRATEGY_ENTRY_WINDOW"
    return ""


def day_block_bootstrap_upper(rows: List[dict], reps: int, seed: int, confidence: float = CONFIDENCE) -> dict:
    """One-sided upper bound of mean NetR by resampling broker days with replacement (0C.15)."""
    by_day: Dict[str, List[float]] = defaultdict(list)
    for r in rows:
        by_day[r["entry_time"][:10]].append(float(r["net_r"]))
    days = sorted(by_day)
    sums = [sum(by_day[d]) for d in days]
    counts = [len(by_day[d]) for d in days]
    if not days:
        return {"upper": None, "lower": None, "reps": reps, "seed": seed}
    rng = random.Random(seed)
    k = len(days)
    means = []
    for _ in range(reps):
        s = c = 0
        for _ in range(k):
            j = rng.randrange(k)
            s += sums[j]
            c += counts[j]
        means.append(s / c)
    means.sort()
    up_idx = min(reps - 1, int(math.ceil(confidence * reps)) - 1)
    lo_idx = max(0, int(math.floor((1.0 - confidence) * reps)))
    return {"upper": means[up_idx], "lower": means[lo_idx], "reps": reps, "seed": seed}


def summarize(rows: List[dict], reps: int, seed: int) -> dict:
    net = [float(r["net_r"]) for r in rows]
    days = {r["entry_time"][:10] for r in rows}
    out = {"events": len(rows), "independent_days": len(days)}
    if not rows:
        out.update({"mean_net_r": None, "upper95_mean_net_r": None})
        return out
    boot = day_block_bootstrap_upper(rows, reps, seed)
    f = lambda key: statistics.fmean(float(r[key]) for r in rows)  # noqa: E731
    out.update({
        "mean_net_r": statistics.fmean(net),
        "median_net_r": statistics.median(net),
        "stdev_net_r": statistics.stdev(net) if len(net) > 1 else 0.0,
        "win_rate": sum(1 for x in net if x > 0) / len(net),
        "upper95_mean_net_r": boot["upper"],
        "lower05_mean_net_r": boot["lower"],
        "bootstrap": {"method": "day-block", "reps": reps, "seed": seed},
        "mean_gross_r": f("gross_r"),
        "mean_costs_r": f("costs_r"),
        "mean_entry_spread_pips": f("entry_spread_pips"),
        "mean_spread_to_stop": statistics.fmean(float(r["entry_spread"]) / float(r["planned_stop_distance"]) for r in rows),
        "mean_mfe_r": f("mfe_r"),
        "mean_mae_r": f("mae_r"),
        "mean_holding_minutes": statistics.fmean(int(r["holding_seconds"]) for r in rows) / 60.0,
        "exit_reasons": dict(Counter(r["exit_reason"] for r in rows)),
        "swap_nights_total": sum(int(r["swap_nights"]) for r in rows),
    })
    return out


def stratify(rows: List[dict], key: str) -> dict:
    groups: Dict[str, List[float]] = defaultdict(list)
    for r in rows:
        groups[r[key]].append(float(r["net_r"]))
    return {g: {"events": len(v), "mean_net_r": statistics.fmean(v)} for g, v in sorted(groups.items())}


def reversal_table(rows: List[dict]) -> dict:
    """3.7 at fixed horizons, counted once per SETUP event (hypothesis A rows)."""
    table = {}
    for h in HORIZONS:
        c = Counter(r[f"class_{h}"] for r in rows)
        known = c["REVERSAL"] + c["CONTINUATION"] + c["UNRESOLVED"]
        table[str(h)] = {"REVERSAL": c["REVERSAL"], "CONTINUATION": c["CONTINUATION"], "UNRESOLVED": c["UNRESOLVED"],
                         "NA": c["NA"], "reversal_share": (c["REVERSAL"] / known) if known else None}
    return table


def classify_timeframe(hyp_stats: Dict[str, dict]) -> dict:
    """3.6: STOP only when both minima are met for both hypotheses and both upper bounds are < 0."""
    minima = all(s["events"] >= MIN_EVENTS and s["independent_days"] >= MIN_DAYS for s in hyp_stats.values())
    if not minima:
        return {"classification": "INCONCLUSIVE", "reason": "sample minima not met for both hypotheses"}
    if all(s["upper95_mean_net_r"] is not None and s["upper95_mean_net_r"] < 0 for s in hyp_stats.values()):
        return {"classification": "STOP_EARLY_REDESIGN", "reason": "Upper95(mean EventStudyNetR) < 0 for A and B"}
    return {"classification": "CONTINUE", "reason": "at least one hypothesis has Upper95(mean EventStudyNetR) >= 0"}


def analyse(pkg: str, reps: int = DEFAULT_REPS, seed: int = DEFAULT_SEED) -> dict:
    with open(os.path.join(pkg, "reference_config.json"), "r", encoding="utf-8") as f:
        rc = json.load(f)
    report = {"contract_id": "LSR-PHASE3-EVENTSTUDY-2026-09-29", "package": os.path.abspath(pkg),
              "rules": {"min_events": MIN_EVENTS, "min_independent_days": MIN_DAYS, "confidence": CONFIDENCE,
                        "net_r": "RealizedNetPnL / PlannedRisk1R; 1 lot; LIVE_NATIVE_STOP; SingleTP 2R net; no BE, no re-entry",
                        "analysis_set": "closed proxies, entry inside StrategyEntryWindow, not in data quarantine"},
              "timeframes": {}}
    dq = os.path.join(pkg, "data_quality_report.json")
    if os.path.exists(dq):
        with open(dq, "r", encoding="utf-8") as f:
            report["data_gate"] = json.load(f).get("raw_real_tick_audit", {}).get("gates", {}).get("result")
    man = os.path.join(pkg, "manifest.json")
    if os.path.exists(man):
        with open(man, "r", encoding="utf-8") as f:
            m = json.load(f)
        report["non_default_inputs"] = m.get("inputs", {}).get("non_default_inputs")
        report["experiment_id"] = m.get("experiment_id")
    removed = []
    for tf in rc["timeframes"]:
        rows = read_rows(os.path.join(pkg, f"event_study_{tf}.csv"))
        tf_rep = {"hypotheses": {}}
        hyp_stats = {}
        for hyp in HYPOTHESES:
            hrows = [r for r in rows if r["hypothesis"] == hyp]
            excl = Counter(analysis_filter(r) for r in hrows)
            use = [r for r in hrows if analysis_filter(r) == ""]
            s = summarize(use, reps, seed)
            s["proxies"] = len(hrows)
            s["excluded"] = {k: v for k, v in excl.items() if k}
            s["by_direction"] = stratify(use, "direction")
            s["by_touch_bucket"] = stratify(use, "touch_bucket")
            s["by_source_tags"] = stratify(use, "source_tags")
            s["by_time_bucket"] = stratify(use, "time_bucket")
            s["by_weekday"] = stratify(use, "weekday")
            s["by_spread_bucket"] = stratify(use, "spread_bucket")
            hyp_stats[hyp] = s
            tf_rep["hypotheses"][hyp] = s
        tf_rep["reversal_vs_continuation"] = reversal_table([r for r in rows if r["hypothesis"] == HYPOTHESES[0]])
        tf_rep["early_stop"] = classify_timeframe(hyp_stats)
        if tf_rep["early_stop"]["classification"] == "STOP_EARLY_REDESIGN":
            removed.append(tf)
        report["timeframes"][tf] = tf_rep
    all_tfs = list(rc["timeframes"])
    report["project_classification"] = "STOP_EARLY_REDESIGN" if all_tfs and len(removed) == len(all_tfs) else "CONTINUE"
    report["removed_timeframes"] = removed
    return report


def fmt(x, d=3):
    return "NA" if x is None else f"{x:.{d}f}"


def markdown(rep: dict) -> str:
    lines = ["# Phase 3 Event Study Report", "",
             f"Experiment `{rep.get('experiment_id')}` · data gate **{rep.get('data_gate')}** · non-default inputs: {rep.get('non_default_inputs')}", "",
             "EventStudyNetR = RealizedNetPnL / PlannedRisk1R (1 lot, LIVE_NATIVE_STOP, net 2R target, no BE, no re-entry). "
             "One-sided 95% upper bound from a day-block bootstrap. Timeframes are never pooled.", "",
             "| TF | Hypothesis | Events | Days | Mean NetR | Upper95 | Win rate | Mean costs R | TP / STOP | Early stop |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for tf, t in rep["timeframes"].items():
        for hyp, s in t["hypotheses"].items():
            ex = s.get("exit_reasons", {})
            tp = sum(v for k, v in ex.items() if "TP" in k)
            st = sum(v for k, v in ex.items() if "STOP" in k or "BOTH" in k)
            lines.append(f"| {tf} | {hyp} | {s['events']} | {s['independent_days']} | {fmt(s.get('mean_net_r'))} | "
                         f"{fmt(s.get('upper95_mean_net_r'))} | {fmt(s.get('win_rate'))} | {fmt(s.get('mean_costs_r'))} | "
                         f"{tp} / {st} | {t['early_stop']['classification']} |")
    lines += ["", f"**Project classification: {rep['project_classification']}**", "", "## Reversal vs continuation (per SETUP event)", "",
              "| TF | H | Reversal | Continuation | Unresolved | Reversal share |", "|---|---|---|---|---|---|"]
    for tf, t in rep["timeframes"].items():
        for h, c in t["reversal_vs_continuation"].items():
            lines.append(f"| {tf} | {h} | {c['REVERSAL']} | {c['CONTINUATION']} | {c['UNRESOLVED']} | {fmt(c['reversal_share'])} |")
    lines.append("")
    return "\n".join(lines)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("package_dir")
    ap.add_argument("--reps", type=int, default=DEFAULT_REPS)
    ap.add_argument("--seed", type=int, default=DEFAULT_SEED)
    args = ap.parse_args(argv)
    rep = analyse(args.package_dir, args.reps, args.seed)
    out = os.path.join(args.package_dir, "python_reference")
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "event_study_report.json"), "w", encoding="utf-8") as f:
        json.dump(rep, f, indent=2)
    with open(os.path.join(out, "event_study_report.md"), "w", encoding="utf-8") as f:
        f.write(markdown(rep))
    for tf, t in rep["timeframes"].items():
        for hyp, s in t["hypotheses"].items():
            print(f"{tf} {hyp}: n={s['events']} days={s['independent_days']} meanNetR={fmt(s.get('mean_net_r'))} "
                  f"upper95={fmt(s.get('upper95_mean_net_r'))}")
        print(f"{tf}: {t['early_stop']['classification']}")
    print(f"PROJECT: {rep['project_classification']} -> {os.path.join(out, 'event_study_report.md')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
