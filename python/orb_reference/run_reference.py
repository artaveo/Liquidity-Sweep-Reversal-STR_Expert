"""Rebuild the ORB day ledgers from an ORB_Expert run package and reconcile them.

Usage:
    python -m orb_reference.run_reference <package_dir> [--quarantine CSV] [--calendar CSV] [--mql5-dir DIR]

<package_dir> is Common/Files/ORB/<ExperimentId>/. It must contain
reference_config.json, bars_M1_BID.csv, data_quarantine_windows.csv and
detected_market_closures.csv. Every orb_days_<ORLEN>.csv is recomputed from the
M1 bars alone and must be byte-identical to the MQL5 file (roadmap 3 item 8).
The proxy ledgers are checked for completeness: every TRADE day has one row per
exit variant, and every row is closed or explained (roadmap ORB-1 gate).
"""

from __future__ import annotations

import argparse
import calendar
import csv
import hashlib
import json
import os
import sys
import time
from collections import Counter
from typing import List, Tuple

from lsr_reference.run_reference import compare, read_m1, read_quarantine, sha256_bytes

from .days import OR_LENGTHS, Schedule, build_ledger

EXIT_VARIANTS = ("R10_EOD", "R2_EOD")
EXPLAINED_NOT_CLOSED = {"NO_TRADE_INVALID_STOP", "NO_EXECUTABLE_TICK"}


def parse_time(s: str) -> int:
    s = s.strip()
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y.%m.%d %H:%M:%S", "%Y.%m.%d %H:%M", "%Y-%m-%d %H:%M:%S"):
        try:
            return calendar.timegm(time.strptime(s, fmt))
        except ValueError:
            continue
    raise ValueError(f"unparseable time '{s}'")


def read_intervals(path: str) -> List[Tuple[int, int]]:
    """Any 'from,to[,...]' CSV; lines not starting with a digit (headers, comments) are skipped."""
    out: List[Tuple[int, int]] = []
    if not path or not os.path.exists(path):
        return out
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or not line[0].isdigit():
                continue
            parts = line.split(",")
            a, b = parse_time(parts[0]), parse_time(parts[1])
            if b > a:
                out.append((a, b))
    return out


def check_trades(path: str, day_lines: List[str]) -> dict:
    """Every TRADE day -> one row per exit; every row CLOSED or explained."""
    if not os.path.exists(path):
        return {"ok": False, "error": "MQL5 trade ledger missing"}
    trade_days = [ln.split(",")[0] for ln in day_lines[1:] if ln.split(",")[13] == "TRADE"]
    with open(path, "r", encoding="utf-8", newline="") as f:
        rows = list(csv.DictReader(f))
    keys = Counter((r["date"], r["exit_variant"]) for r in rows)
    missing = [(d, e) for d in trade_days for e in EXIT_VARIANTS if keys[(d, e)] != 1]
    extra = [k for k in keys if k[0] not in set(trade_days)]
    unexplained = [r["date"] + "/" + r["exit_variant"] for r in rows
                   if not (r["state"] == "CLOSED" or r["reason"] in EXPLAINED_NOT_CLOSED)]
    reasons = Counter((r["exit_reason"] if r["state"] == "CLOSED" else r["reason"]) for r in rows)
    ok = not missing and not extra and not unexplained
    return {"ok": ok, "rows": len(rows), "trade_days": len(trade_days), "missing": missing[:20], "extra": extra[:20],
            "unexplained": unexplained[:20], "by_reason": dict(sorted(reasons.items())),
            "end_of_data": reasons.get("END_OF_DATA", 0)}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("package_dir")
    ap.add_argument("--out", default=None, help="output directory (default: <package_dir>/python_reference)")
    ap.add_argument("--quarantine", default=None, help="declared DataQuarantineFile, if the run used one")
    ap.add_argument("--calendar", default=None, help="declared ClosedMarketCalendarFile, if the run used one")
    ap.add_argument("--mql5-dir", default=None, help="folder holding the MQL5 day ledgers (default: <package_dir>; ORB_DayReplay writes to <package_dir>/replay)")
    args = ap.parse_args(argv)

    pkg = args.package_dir
    out = args.out or os.path.join(pkg, "python_reference")
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(pkg, "reference_config.json"), "r", encoding="utf-8") as f:
        rc = json.load(f)

    t0 = time.time()
    bars = read_m1(os.path.join(pkg, rc["m1_bars_file"]))
    windows = read_quarantine(os.path.join(pkg, rc["quarantine_file"])) if rc.get("quarantine_file") else []
    windows += read_intervals(os.path.join(pkg, rc["closures_file"])) if rc.get("closures_file") else []
    for key, arg in (("declared_quarantine_file", args.quarantine), ("declared_calendar_file", args.calendar)):
        if rc.get(key):
            if not arg:
                print(f"warning: run declared {key}={rc[key]}; pass it with --{'quarantine' if 'quarantine' in key else 'calendar'}",
                      file=sys.stderr)
            else:
                windows += read_intervals(arg)
    sched = Schedule.from_json(rc["trading_session_schedule"])
    if rc.get("latency_ms", 0):
        print("note: FixedExecutionDelayMs > 0; NO_TRADE_NO_TICK is bar-derived and may differ from the proxy fill",
              file=sys.stderr)
    led = build_ledger(bars, sched, windows, int(rc["digits"]), float(rc["point"]))

    report = {"contract_id": rc.get("contract_id"), "package": os.path.abspath(pkg), "m1_bars": len(bars),
              "quarantine_and_closure_windows": len(windows), "python_version": sys.version.split()[0],
              "or_lengths": {}, "result": "PASS"}
    combined = ""
    for k, (name, _) in enumerate(OR_LENGTHS):
        lines = led.lines(k)
        text = "\n".join(lines) + "\n"
        data = text.encode("utf-8")
        fname = f"orb_days_{name}.csv"
        with open(os.path.join(out, fname), "wb") as f:
            f.write(data)
        ea_path = os.path.join(args.mql5_dir or pkg, fname)
        if os.path.exists(ea_path):
            with open(ea_path, "rb") as f:
                ea_data = f.read()
            cmp = compare(ea_data.decode("utf-8").splitlines(), text.splitlines())
            cmp["mql5_sha256"] = sha256_bytes(ea_data)
        else:
            cmp = {"identical": False, "error": "MQL5 day ledger missing"}
        cmp["python_sha256"] = sha256_bytes(data)
        decisions = Counter(ln.split(",")[13] for ln in lines[1:])
        trades = check_trades(os.path.join(pkg, f"orb_trades_{name}.csv"), lines)
        report["or_lengths"][name] = {"days": cmp, "decisions": dict(sorted(decisions.items())), "proxies": trades}
        if not cmp.get("identical") or not trades.get("ok"):
            report["result"] = "FAIL"
        combined += f"{name}:{sha256_bytes(data)};"
    report["python_ledger_checksum"] = hashlib.sha256(combined.encode("utf-8")).hexdigest()
    report["elapsed_seconds"] = round(time.time() - t0, 1)
    with open(os.path.join(out, "orb_reconciliation_report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)

    for name, r in report["or_lengths"].items():
        print(f"{name}: days={'OK' if r['days'].get('identical') else 'DIFF'}({r['days'].get('python_rows', '?')}) "
              f"TRADE={r['decisions'].get('TRADE', 0)} proxies={'OK' if r['proxies'].get('ok') else 'CHECK'}"
              f"({r['proxies'].get('rows', '?')} rows, END_OF_DATA={r['proxies'].get('end_of_data', '?')})")
    print(f"RECONCILIATION {report['result']}  ledger_checksum={report['python_ledger_checksum']}  "
          f"({report['elapsed_seconds']}s) -> {os.path.join(out, 'orb_reconciliation_report.json')}")
    return 0 if report["result"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
