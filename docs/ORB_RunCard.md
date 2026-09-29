# ORB Run Card — Opening Range Breakout (NDX100), phases ORB-1 and ORB-1S

This card lists the exact settings for the ORB-1 smoke run and the ORB-1S screen. `ORB_Expert` never trades. The rules come from `Opening_Range_Breakout_Roadmap.md` Sections 2–4 and ORB-1S. Paths below are relative to the repository root; the owner's machine paths are in roadmap Section 10.

## 0. Install and compile

Copy `MQL5\Include\OpeningRangeBreakout`, `MQL5\Include\LiquiditySweepReversal`, `MQL5\Experts\OpeningRangeBreakout`, `MQL5\Scripts\OpeningRangeBreakout` and `MQL5\Scripts\LiquiditySweepReversal` into the MT5 data folder, then compile each file. All must report **0 errors, 0 warnings**:

```
MetaEditor64.exe /compile:"<data>\MQL5\Experts\OpeningRangeBreakout\ORB_Expert.mq5"        /log:"orb_expert.log" /inc:"<data>\MQL5"
MetaEditor64.exe /compile:"<data>\MQL5\Scripts\OpeningRangeBreakout\ORB_DayReplay.mq5"      /log:"orb_replay.log" /inc:"<data>\MQL5"
MetaEditor64.exe /compile:"<data>\MQL5\Scripts\LiquiditySweepReversal\LSR_Tests.mq5"        /log:"lsr_tests.log"  /inc:"<data>\MQL5"
MetaEditor64.exe /compile:"<data>\MQL5\Experts\LiquiditySweepReversal\LSR_Expert.mq5"       /log:"lsr_expert.log" /inc:"<data>\MQL5"
MetaEditor64.exe /compile:"<data>\MQL5\Scripts\LiquiditySweepReversal\LSR_RawTickAudit.mq5" /log:"lsr_audit.log"  /inc:"<data>\MQL5"
MetaEditor64.exe /compile:"<data>\MQL5\Scripts\LiquiditySweepReversal\LSR_EventReplay.mq5"  /log:"lsr_replay.log" /inc:"<data>\MQL5"
```

The LSR files are recompiled because `LSR_Types.mqh` and `LSR_Costs.mqh` gained the index-commission mode (roadmap 1.3).

## 1. Blocking tests

- **MQL5:** run `Scripts\LiquiditySweepReversal\LSR_Tests` on any chart. `Common\Files\LSR\tests\lsr_tests.txt` must end with `RESULT: PASS ... failed=0`. The ORB suites are `ORB-1 Day ledger`, `ORB-1 Proxy trades` and `ORB 1.3 Index commission`; every existing LSR suite must still pass unchanged.
- **Python** (from `python/`):

  ```
  python -m unittest discover -s tests -v
  ```

  `tests/test_orb_days.py` has the same fixtures and expected values as the MQL5 ORB suites. `tests/test_orb_study.py` covers the trial grid, filters, bootstrap p-value, Holm, the ORB-1S classification and the ORB-2 decision.

## 2. Index commission (roadmap 1.3)

- **Source:** FundedNext Help Center, *"What are the commission charges for Stellar Challenges and FundedNext Accounts?"* (`https://help.fundednext.com/en/articles/10701368`) and *Symbols & Conditions* (`https://fundednext.com/general-rules/cfds/symbols-and-conditions`), consulted 2026-09-29. Stellar 1-Step/2-Step commissions are listed for Forex, Oil, Metals (0.0016%), Crypto and Stocks; **indices carry no commission**.
- **Implementation:** `CommissionMode = FUNDEDNEXT_OFFICIAL_INDICES`, `CommissionRatePercent = 0`. The formula returns 0, and a non-zero rate fails initialization.
- **Cross-check (owner, once):** open and close a 0.01- or 1-lot NDX100 position on the FundedNext demo, or read any NDX100 tester deal. In Toolbox → History, the **Commission** column (`DEAL_COMMISSION`) must be 0. Record the result in the ORB-1 completion record. If it is not 0, stop and report it; the mode must then be re-specified.

## 3. Strategy Tester — ORB-1 smoke run (also the ORB-1S data)

| Setting | Value |
|---|---|
| Expert | `OpeningRangeBreakout\ORB_Expert` |
| Symbol / period | `NDX100`, `M1` |
| Model | **Every tick based on real ticks** |
| Dates | `2026.01.01` → `2026.07.01` (tester end date is exclusive) |
| Deposit / currency / leverage | `100000` / `USD` / `1:100` |
| Inputs | all at their defaults (the `.set` file is not needed) |

The first run downloads NDX100 ticks for 2026-01 → 2026-06 and is slow; the watchdog from roadmap Section 10 applies. Headless example (`config\orb1.ini`):

```
[Tester]
Expert=OpeningRangeBreakout\ORB_Expert
Symbol=NDX100
Period=M1
Model=4
FromDate=2026.01.01
ToDate=2026.07.01
Deposit=100000
Currency=USD
Leverage=100
ShutdownTerminal=0
```

Default inputs (every one is recorded in `run_card_inputs.txt` and the manifest; a `*` marks a non-default value):

| Input | Default |
|---|---|
| ExperimentId | `ORB-1-SMOKE` |
| CodeCommitSHA / RoadmapSHA256 | fill in from `git rev-parse HEAD` / `sha256sum Opening_Range_Breakout_Roadmap.md` (optional) |
| AuditRequestedStartDate / EndDate | `2026.01.01` / `2026.06.30` (inclusive) |
| StrategyPipSize | `1.0` |
| SignalBarPriceSource / StopExecutionProfile | `BID` / `LIVE_NATIVE_STOP` |
| CommissionMode / CommissionRatePercent | `FUNDEDNEXT_OFFICIAL_INDICES` / `0` |
| SlippageMode / LatencyMode | `NONE` (0/0) / `ZERO` (0 ms) |
| MaxEntrySpreadEnabled | `false` (F2 replaces it) |
| AccountCurrency | `USD` (must equal the NDX100 profit currency; init fails otherwise) |
| ExportReferenceBars | `true` |

Frozen, not inputs: session start `16:30`, end of day `23:00`, `OR5`/`OR15`, `R10_EOD`/`R2_EOD`, RV 14, NR7, SMA50, ATR14 (daily), F2 = 0.10.

## 4. Output — `Common\Files\ORB\ORB-1-SMOKE\`

| File | Content |
|---|---|
| `orb_days_OR5.csv`, `orb_days_OR15.csv` | One row per broker day on which 16:30 is a scheduled session: OR OHLC/ticks, direction, decision code, quarantine flag, RV/F1, previous-day range/NR7, previous close/SMA50/F5, ATR14_D, width/ATR bucket, weekday, news state |
| `orb_trades_OR5.csv`, `orb_trades_OR15.csv` | One row per `TRADE` day and exit (`R10_EOD`, `R2_EOD`): entry tick, Bid/Ask, spread, SL, TP, 1R, F2, exit tick/quote/reason, gap/ambiguity, gross/net P/L and R, costs R, spread R, MAE/MFE R, the day's filter flags, quarantine flag |
| `bars_M1_BID.csv`, `reference_config.json` | Inputs to the Python reference |
| `orb_summary.json` | Counts per decision code and per proxy exit reason |
| `data_quality_report.json` + audit CSVs | Raw-tick data gate (LSR 1.4) |
| `symbol_session_snapshot.json`, `execution_contract.json`, `run_card_inputs.txt`, `manifest.json` | Contract snapshots and the DataManifest (written last) |

`NO_TRADE_INVALID_STOP` is decided on the entry tick, so it appears on the proxy rows (`state = NO_TRADE`), not in `orb_days` (roadmap 3 item 5a).

## 5. ORB-1 reconciliation (from `python/`)

```
python -m orb_reference.run_reference "<Common>\Files\ORB\ORB-1-SMOKE"
```

It must print `RECONCILIATION PASS`: both `orb_days` files are byte-identical, every `TRADE` day has one proxy row per exit, and every row is closed or explained. The report goes to `python_reference\orb_reconciliation_report.json`. Optional MQL5 replay: run `Scripts\OpeningRangeBreakout\ORB_DayReplay` on an NDX100 chart with `InpFolder = ORB\ORB-1-SMOKE`, then add `--mql5-dir "<pkg>\replay"`.

### ORB-1 gate

- [ ] All six files compile with 0 errors and 0 warnings
- [ ] `LSR_Tests` PASS (all suites) and Python unittest OK
- [ ] Index commission cross-check: NDX100 `DEAL_COMMISSION` = 0
- [ ] Data gate `DATA-PASSED`
- [ ] `RECONCILIATION PASS` (days byte-identical, proxies complete, `END_OF_DATA` = 0 or explained)
- [ ] Counts recorded in the roadmap completion record (no profitability statements)

## 6. ORB-1S screen (from `python/`, after the ORB-1 gate)

```
python -m orb_reference.study "<Common>\Files\ORB\ORB-1-SMOKE" --mode screen
```

This writes `python_reference\orb_screen_report.md` and `.json`. Only the primary trial `OR5/UNFILTERED/R10_EOD` decides:

| Classification | Rule | Next step |
|---|---|---|
| `SCREEN_STOP` | n ≥ 30 and Upper95(mean NetR) < 0 | ORB stops; ask the owner |
| `SCREEN_INCONCLUSIVE_LOW_N` | n < 30 | Ask the owner |
| `SCREEN_CONTINUE` | anything else | Go to ORB-2 |

The other 15 trials, including the co-reported `OR5/BASE/R10_EOD`, are information only. No input, filter, time or exit may change because of this screen. 2026 H1 never enters ORB-2 statistics; `--mode dev` refuses it.

### ORB-1S gate

- [ ] Report generated from the gated ORB-1 package with no non-default inputs
- [ ] Primary classification recorded in the roadmap; co-reported trial shown beside it
- [ ] Owner asked if `SCREEN_STOP` or `SCREEN_INCONCLUSIVE_LOW_N`
