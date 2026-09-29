"""Run the Python reference on an MT5 run package and reconcile the ledgers.

Usage:
    python -m lsr_reference.run_reference <package_dir> [--out DIR] [--quarantine CSV]

<package_dir> is Common/Files/LSR/<ExperimentId>/ from an LSR_Expert run. It must
contain reference_config.json, the M1 bar export and (research runs)
data_quarantine_windows.csv. The reference recomputes every event ledger from the
M1 bars only and compares it line by line with the MQL5 ledgers.
"""

from __future__ import annotations

import argparse
import calendar
import hashlib
import json
import os
import sys
import time
from typing import List, Tuple

from .engine import Bar, EventConfig, EventEngine

LEDGERS = ("events", "levels", "pools", "touches")


def parse_iso(s: str) -> int:
    return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%S"))


def read_m1(path: str) -> List[Bar]:
    bars = []
    with open(path, "r", encoding="utf-8") as f:
        header = f.readline().strip()
        if header != "time,open,high,low,close,ticks":
            raise ValueError(f"unexpected M1 header: {header}")
        for line in f:
            line = line.strip()
            if not line:
                continue
            t, o, h, l, c, n = line.split(",")
            bars.append(Bar(parse_iso(t), 60, float(o), float(h), float(l), float(c), int(n)))
    return bars


def read_quarantine(path: str) -> List[Tuple[int, int]]:
    out = []
    if not path or not os.path.exists(path):
        return out
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(",")
            a = calendar.timegm(time.strptime(parts[0].strip(), "%Y.%m.%d %H:%M:%S"))
            b = calendar.timegm(time.strptime(parts[1].strip(), "%Y.%m.%d %H:%M:%S"))
            out.append((a, b))
    return out


def config_from_json(c: dict) -> EventConfig:
    return EventConfig(
        use_previous_day=c["use_previous_day"], use_previous_session=c["use_previous_session"],
        use_swings=c["use_swings"], use_equal=c["use_equal"],
        session_start_sec=c["session_start_sec"], session_end_sec=c["session_end_sec"],
        swing_left=c["swing_left"], swing_right=c["swing_right"],
        equal_tol_pips=float(c["equal_tol_pips"]), cluster_tol_pips=float(c["cluster_tol_pips"]),
        multi_pool_policy=c["multi_pool_policy"], entry_mode=c["entry_mode"],
        pip_size=float(c["strategy_pip_size"]), point=float(c["point"]), digits=int(c["digits"]))


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def compare(ea_lines: List[str], ref_lines: List[str], limit: int = 20) -> dict:
    mismatches = []
    header = ea_lines[0].split(",") if ea_lines else []
    for i in range(max(len(ea_lines), len(ref_lines))):
        a = ea_lines[i] if i < len(ea_lines) else None
        b = ref_lines[i] if i < len(ref_lines) else None
        if a == b:
            continue
        cols = []
        if a is not None and b is not None:
            fa, fb = a.split(","), b.split(",")
            for k in range(max(len(fa), len(fb))):
                va = fa[k] if k < len(fa) else None
                vb = fb[k] if k < len(fb) else None
                if va != vb:
                    cols.append({"column": header[k] if k < len(header) else str(k), "mql5": va, "python": vb})
        mismatches.append({"line": i + 1, "mql5_missing": a is None, "python_missing": b is None, "columns": cols[:10]})
        if len(mismatches) >= limit:
            break
    return {"mql5_rows": max(0, len(ea_lines) - 1), "python_rows": max(0, len(ref_lines) - 1),
            "identical": ea_lines == ref_lines, "first_mismatches": mismatches}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("package_dir")
    ap.add_argument("--out", default=None, help="output directory (default: <package_dir>/python_reference)")
    ap.add_argument("--quarantine", default=None, help="declared DataQuarantineFile, if the run used one")
    ap.add_argument("--mql5-dir", default=None, help="folder holding the MQL5 ledgers (default: <package_dir>; LSR_EventReplay writes to <package_dir>/replay)")
    args = ap.parse_args(argv)

    pkg = args.package_dir
    out = args.out or os.path.join(pkg, "python_reference")
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(pkg, "reference_config.json"), "r", encoding="utf-8") as f:
        rc = json.load(f)
    cfg = config_from_json(rc)

    t0 = time.time()
    bars = read_m1(os.path.join(pkg, rc["m1_bars_file"]))
    windows = []
    if rc.get("quarantine_file"):
        windows += read_quarantine(os.path.join(pkg, rc["quarantine_file"]))
    if rc.get("declared_quarantine_file"):
        if not args.quarantine:
            print(f"warning: run declared DataQuarantineFile={rc['declared_quarantine_file']}; pass --quarantine", file=sys.stderr)
        else:
            windows += read_quarantine(args.quarantine)

    def in_quarantine(a: int, b: int) -> bool:
        return any(qa < b and a < qb for qa, qb in windows)

    engines = [EventEngine(tf, cfg) for tf in rc["timeframes"]]
    for m1 in bars:
        for e in engines:
            e.on_m1(m1)
    for e in engines:
        e.flush()

    report = {"contract_id": rc.get("contract_id"), "package": os.path.abspath(pkg), "m1_bars": len(bars),
              "python_version": sys.version.split()[0], "timeframes": {}, "result": "PASS"}
    combined = ""
    for e in engines:
        ledgers = e.ledger_lines(in_quarantine)
        tf_rep = {"summary": e.summary(), "ledgers": {}}
        for name in LEDGERS:
            text = "\n".join(ledgers[name]) + "\n"
            data = text.encode("utf-8")
            fname = f"{name}_{e.tf}.csv"
            with open(os.path.join(out, fname), "wb") as f:
                f.write(data)
            ea_path = os.path.join(args.mql5_dir or pkg, fname)
            if os.path.exists(ea_path):
                with open(ea_path, "rb") as f:
                    ea_data = f.read()
                cmp = compare(ea_data.decode("utf-8").splitlines(), text.splitlines())
                cmp["mql5_sha256"] = sha256_bytes(ea_data)
            else:
                cmp = {"identical": False, "error": "MQL5 ledger missing"}
            cmp["python_sha256"] = sha256_bytes(data)
            tf_rep["ledgers"][name] = cmp
            if not cmp.get("identical"):
                report["result"] = "FAIL"
            if name == "events":
                combined += f"{e.tf}:{sha256_bytes(data)};"
        report["timeframes"][e.tf] = tf_rep
    report["python_ledger_checksum"] = hashlib.sha256(combined.encode("utf-8")).hexdigest()
    report["elapsed_seconds"] = round(time.time() - t0, 1)
    with open(os.path.join(out, "reconciliation_report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)

    for tf, r in report["timeframes"].items():
        parts = [f"{n}={'OK' if r['ledgers'][n].get('identical') else 'DIFF'}({r['ledgers'][n].get('python_rows', '?')})" for n in LEDGERS]
        print(f"{tf}: " + " ".join(parts))
    print(f"RECONCILIATION {report['result']}  ledger_checksum={report['python_ledger_checksum']}  "
          f"({report['elapsed_seconds']}s) -> {os.path.join(out, 'reconciliation_report.json')}")
    return 0 if report["result"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
