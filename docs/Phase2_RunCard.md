# Phase 2 Run Card — Liquidity Model, Sweep Events & Python Reference

Phase 2 adds the deterministic event layer to `LSR_Expert`. The EA still never trades. The Phase 1 contract, data audit and gates stay active and unchanged, so the Phase 1 Run Card (`docs/Phase1_RunCard.md`) still applies. This card adds only what is new.

## 1. Blocking tests

- **MQL5:** drag `Scripts\LiquiditySweepReversal\LSR_Phase1_Tests` onto any chart. The result must be `RESULT: PASS ... failed=0`. This single script covers Phase 1 and Phase 2.
- **Python** (3.12, standard library only), from the repository root:

  ```
  python -m unittest discover -s python/tests -v
  ```

The two suites share the same fixtures. They must produce identical EventIDs and LevelIDs (`fe6198d644d45855`, `64a5fad6d55b0573`).

## 2. Strategy Tester (rapid-iteration smoke run)

Use the same tester settings as Phase 1: XAUUSD, **Every tick based on real ticks**, **2026.01.01 → 2026.07.01** (the tester excludes its end date), deposit 100000 USD.

Inputs: keep every input at its roadmap default. Change only `ExperimentId` (default `LSR-P2-SMOKE`), `CodeCommitSHA` and `RoadmapSHA256`.

Phase 2 inputs (defaults):

| Input | Default |
|---|---|
| PreviousDayHighLow / PreviousSessionHighLow / ConfirmedSwingHighLow / EqualHighsLows | `true` / `true` / `true` / `true` |
| LiquiditySessionStart / LiquiditySessionEnd | `16:30` / `21:30` |
| SwingLeftBars / SwingRightBars | `2` / `2` |
| EqualLevelTolerancePips / EqualLevelToleranceMode | `3.0` / `FIXED_PIPS` |
| LiquidityClusteringTolerancePips | `3.0` |
| MultiPoolSweepPolicy | `FIRST_CROSSED_LEVEL` |
| EntryMode | `RECLAIM_CLOSE` (recorded as the confirmation mode) |
| ExportReferenceBars | `true` |

A single tick pass processes every timeframe in `TimeframeSet` (M5, M15, H1). Each timeframe has its own isolated engine.

## 3. Python reconciliation

```
python -m lsr_reference.run_reference "<Common>\Files\LSR\LSR-P2-SMOKE"
```

Run this from `python/`. It rebuilds every ledger from `bars_M1_BID.csv` and `reference_config.json`, writes them to `python_reference/`, and prints `RECONCILIATION PASS` only if every ledger of every timeframe is byte-identical to the MQL5 ledger. It also writes `python_reference/reconciliation_report.json`.

## 4. Run package additions — `Common\Files\LSR\<ExperimentId>\`

| File | Content |
|---|---|
| `events_<TF>.csv` | Every sweep classification: setups, rejections, partial, multi-pool and conflict rows. Each row has its EventID, geometry, penetration/reclaim (raw, pips, ATR), touch count and bucket, level age and 0B.15 decision trace |
| `levels_<TF>.csv` | Every level instance (PDH/PDL/PSH/PSL/swing/equal) with availability, arm, end and prominence |
| `pools_<TF>.csv` | Every immutable pool instance: band, anchor, tags, members, predecessor, touches, end reason |
| `touches_<TF>.csv` | Every pre-sweep touch, with its bar and band |
| `bars_M1_BID.csv`, `reference_config.json` | Inputs for the independent Python reference |
| `event_summary.json` | Per-timeframe counts and `events_<TF>.csv` hashes |
| `manifest.json` | `ledger_checksum` and `event_ledgers_sha256` per timeframe |

## 5. Phase 2 Gate checklist

- [ ] MQL5 tests PASS and Python tests OK, with identical fixture IDs
- [ ] Every program compiles with 0 errors and 0 warnings
- [ ] Smoke run: Phase 1 data gate is `DATA-PASSED`
- [ ] `events_M5.csv`, `events_M15.csv` and `events_H1.csv` exist, and their checksums are recorded in `manifest.json`
- [ ] `RECONCILIATION PASS` for all three timeframes
- [ ] No input other than the identity fields is non-default
