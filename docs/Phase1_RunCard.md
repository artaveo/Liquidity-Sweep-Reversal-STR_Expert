# Phase 1 Run Card — Data, Time, Symbol & Execution Contract

This Run Card covers the Phase 1 smoke run that the Phase 1 Gate asks for. It uses the **Rapid Iteration Sample** only. Keep every other roadmap default unchanged. No strategy input is tuned in this phase.

## 1. Install

Copy the repository's `MQL5` folder over the terminal data folder (MetaEditor → *File → Open Data Folder*). This adds:

| Path | Purpose |
|---|---|
| `MQL5/Experts/LiquiditySweepReversal/LSR_Expert.mq5` | Phase 1 EA (validates the contract, audits data, writes the run package; **does not trade**) |
| `MQL5/Scripts/LiquiditySweepReversal/LSR_Tests.mq5` | Blocking deterministic tests (pure fixtures; runs on any chart) |
| `MQL5/Scripts/LiquiditySweepReversal/LSR_RawTickAudit.mq5` | Raw real-tick audit outside the Strategy Tester |
| `MQL5/Include/LiquiditySweepReversal/*.mqh` | Phase 1 contract library |

Compile all three programs in MetaEditor. Each one must report `0 errors, 0 warnings`.

## 2. Blocking tests (run first)

1. Drag `LSR_Tests` onto any chart.
2. The Experts log must end with `LSR Phase 1 tests RESULT: PASS passed=N failed=0`.
3. Evidence file: `Common\Files\LSR\tests\lsr_tests.txt`.

If any test fails, stop. Phase 1 is not complete.

## 3. Strategy Tester settings (copy exactly)

| Setting | Value |
|---|---|
| Expert | `LiquiditySweepReversal\LSR_Expert` |
| Symbol | `XAUUSD` (FundedNext MT5 server) |
| Period (chart) | any. Signal timeframes come from `TimeframeSet`, not from the chart |
| Modelling | **Every tick based on real ticks** |
| Date | Custom period **2026.01.01 → 2026.07.01**. The MT5 tester excludes its end date, so 07.01 is needed to include 30 June |
| Deposit / currency | 100000 USD (the first smoke run used 10000 by mistake). It must match `AccountCurrency`, otherwise init fails |
| Optimization | Disabled |

The EA cannot read the tester's date fields, so `AuditRequestedStartDate` and `AuditRequestedEndDate` must be copied from this table by hand (roadmap 1.4).

## 4. Exact Inputs

Everything stays at the roadmap default. Only these identity fields change for each run:

| Input | Value for this run |
|---|---|
| `ExperimentId` | `LSR-P1-SMOKE` (or a new unique id) |
| `CodeCommitSHA` | output of `git rev-parse HEAD` |
| `RoadmapSHA256` | output of `sha256sum Liquidity_Sweep_Reversal_Roadmap.md` (PowerShell: `Get-FileHash -Algorithm SHA256`) |

The table below lists every input with its default. The EA writes the same list, with the actual values and an `is_default` flag, to `run_card_inputs.txt` and `manifest.json`.

| Group | Input | Default |
|---|---|---|
| 1.1 | TimeframeSet | `M5,M15,H1` |
| 1.1 | LiveTimeframe | `M5` |
| 1.3 | TradingSessionMode | `FULL_DAY_EXCEPT_LATE_SPREAD_WINDOW` (Mode 1) |
| 1.3 | TradeStartTime / TradeEndTime | `00:00` / `24:00` (Mode 3 only; always validated) |
| 1.4 | AuditRequestedStartDate / EndDate | `2026-01-01` / `2026-06-30` (end date inclusive) |
| 1.4 | ClosedMarketCalendarFile | *(empty)* |
| 1.12 | DataQuarantineFile | *(empty)* (Phase 4+ trading runs load the raw-audit quarantine CSV) |
| 1.5 | StrategyPipSize | `0.10` |
| 0B.16 | SignalBarPriceSource | `BID` |
| 0.4 | StopExecutionProfile | `LIVE_NATIVE_STOP` |
| 1.7 | CommissionMode | `FUNDEDNEXT_OFFICIAL_METALS` |
| 1.7 | CommissionRatePercent | `0.0016` |
| 1.7 | CommissionContractSizeSource | `SYMBOL_TRADE_CONTRACT_SIZE` |
| 1.7 | CommissionScheduleContractSize | `0` (only for `BROKER_SCHEDULE`) |
| 1.7 | CommissionPricingBasis | `OPEN_PRICE` |
| 1.7 | CostScheduleLabel / CostScheduleDate | `CURRENT_OFFICIAL_SCHEDULE` / `2026-09-28` |
| 1.7 | SlippageMode / Entry / Exit points | `NONE` / `0` / `0` |
| 1.7 | LatencyMode / FixedExecutionDelayMs | `ZERO` / `0` |
| 1.7 | MaxEntrySpreadEnabled | `true` |
| 1.7 | MaxEntrySpreadStrategyPips | `3.0` |
| 1.7 | MaxEntryKnownNonSpreadCostR | `0.10` |
| 1.8 | RiskPerTradePercent | `0.50` |
| 1.9 | DailyLossGuardEnabled / MaxDailyLossR | `true` / `3.0` |
| 1.9 | MaxConcurrentPositions | `3` |
| 0B.9 | MaxAggregateOpenWorstCaseRiskR | `3.0` |
| 0B.9 | MaxDirectionalOpenWorstCaseRiskR | `2.0` |
| 1.10 | DirectionalPositionCapEnabled / MaxDirectionalPositions | `false` / `3` |
| 1.10 | MaxTotalDrawdownEnabled / MaxTotalDrawdownR | `false` / `0` (enabling = SPEC-INCOMPLETE until Phase 5) |
| 1.10 | MaxConsecutiveLossGuardEnabled / MaxConsecutiveLosses | `false` / `0` (enabling = SPEC-INCOMPLETE until Phase 5) |
| 1.11 | DailyProfitTargetEnabled / DailyProfitTargetR / Basis | `false` / `9.0` / `NET_EQUITY` |
| 0B.10 | AccountRuleProfile / AccountRuleEngine | `FUNDEDNEXT_STELLAR_2STEP` / `APPLY_OFFICIAL_ACCOUNT_RULES` |
| 0B.10 | AccountInitialBalance / AccountCurrency | `100000` / `USD` |
| 0B.10 | AccountRuleSafetyBufferR | `0.10` |

Pre-registered stress scenarios are separate declared runs. Only these values are accepted, and any other value fails init:

- Slippage (`FIXED_ADVERSE_POINTS`): each leg ∈ {0, 1, 2, 5} symbol points, and at least one leg must be non-zero.
- Latency (`FIXED_MS`): 100, 250 or 500 ms.

## 5. Market closures and data quarantine (roadmap 1.12 item 16)

Holidays and early closes are detected automatically. A tick-free stretch with no M1 bars that touches a session start or end is a closure, and no calendar is needed. Other bad data is quarantined minute by minute, and later phases open no new trades inside a quarantine window. The run fails only when quarantined minutes exceed 1% of eligible minutes.

Optional declared calendar (a supplement, frozen before the run):

`SymbolInfoSessionTrade` holds only the weekly schedule, so holiday closures must be declared. If they are not, they count as data gaps. The calendar is a file in `Common\Files`:

```
# start,end_exclusive,reason   (Broker Server Time)
2026.01.01 00:00,2026.01.02 01:00,New Year
```

Declared minutes are excluded from `AuditEligibleMinute` and from `CriticalDataGap`. The calendar is copied into `symbol_session_snapshot.json`. Changing it after results are seen reopens the run.

## 6. Raw real-tick audit outside the tester (recommended)

Run `LSR_RawTickAudit` on an `XAUUSD` chart with the same ExperimentId, dates and calendar. It reads the terminal's own tick history directly, with no tester path involved, and writes the files `raw_tick_audit_report.json`, `raw_tick_audit_fallback_minutes.csv` and `raw_tick_audit_critical_gaps.csv`.

## 7. Run package — `Common\Files\LSR\<ExperimentId>\`

| File | Phase 1 required output |
|---|---|
| `manifest.json` | DataManifest (schema: `docs/DataManifest.schema.json`), with the SHA-256 of every other file |
| `data_quality_report.json` | Data-quality report: coverage, stream anomalies, raw-tick audit, PFM/gap gates, signal-timeframe OHLC reconciliation |
| `symbol_session_snapshot.json` | Symbol/session snapshot, including the Mode 1 late-block sample and the declared calendar |
| `execution_contract.json` | Cost/execution contract, including sizing and risk-admission formulas |
| `account_rule_profile.json` | AccountRule profile snapshot |
| `run_card_inputs.txt` | Exact Inputs (non-default values marked `*`) |
| `potential_fallback_minutes.csv`, `critical_data_gaps.csv`, `timeframe_bar_reconciliation.csv` | Row-level audit evidence |
| `detected_market_closures.csv`, `data_quarantine_windows.csv` | Auto-detected closures; quarantine windows (loadable as `DataQuarantineFile`) |

## 8. Gate checklist (submit with the package)

- [ ] Blocking tests: `RESULT: PASS`, `failed=0`
- [ ] All programs compile: 0 errors, 0 warnings
- [ ] `manifest.json` → `inputs.non_default_inputs` lists only identity fields
- [ ] `data_quality_report.json` → `raw_real_tick_audit.gates.result` is `DATA-PASSED` (fallback share ≤ 1% and quarantine share ≤ 1%)
- [ ] `coverage.declared_vs_observed` is reviewed
- [ ] `signal_timeframe_ohlc_reconciliation` shows `bars_mismatched = 0` for every active timeframe
- [ ] No strategy-selection decision has been made
