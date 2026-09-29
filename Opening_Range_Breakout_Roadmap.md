# Opening Range Breakout (XAUUSD) — Implementation & Research Roadmap

**Document name:** `Opening_Range_Breakout_Roadmap.md` (permanent: never renamed, never version-numbered)
**Status:** APPROVED BY OWNER, 2026-09-29. Implementation starts at Phase ORB-1.
**Symbol / broker:** XAUUSD, FundedNext MT5 (`FundedNext-Server 2`), Broker Server Time
**Predecessor:** `Liquidity_Sweep_Reversal_Roadmap.md` (LSR). LSR Phases 1–3 are complete; the owner closed the LSR strategy after its Phase 3 event study. ORB reuses the LSR engine. Read Section 1 before touching code.

---

## 0. How a new chat must start (read first)

1. Clone the repository and read this file completely. Read `Liquidity_Sweep_Reversal_Roadmap.md` **only** for the sections referenced here: 0A, 0B.9–0B.11, 0C.9–0C.22, Phase 1 (1.1–1.12) and 2.12 items 1, 2, 6 and 13.
2. Work on branch `main`. There is one logical work package per chat (ORB-1, ORB-2, …). Update this roadmap at the end of every code-changing phase, following Section 9.
3. **Do not change any file listed as REUSE-UNCHANGED in Section 1.1** unless a failing test proves a defect. If a defect is proved, the fix goes into that file *and* is logged in this roadmap's update log.
4. The owner's machine (Section 10) already has MetaTrader 5, MetaEditor, Python 3.12, and cached XAUUSD ticks for 2026-01 to 2026-09.

### 0.1 Why LSR was closed (evidence carried forward)

LSR Phase 3 ran on XAUUSD 2026-01-01 → 2026-06-30 with real ticks, a 1-lot proxy and a net 2R target. The sweep/reclaim reversal showed no edge:

- M5 was STOP_EARLY_REDESIGN.
- M15 and H1 had negative or near-zero mean NetR, a win rate of 28–33%, and a reversal share of 50–56%, which is close to a coin flip.
- The mean entry spread was about **5.7 strategy pips**, so spread is a first-order cost at short horizons.
- External evidence agrees. A pre-registered sweep-reversal study found no edge on EURUSD, XAUUSD or BTCUSD, and a mechanical ICT bot reached PF 0.81 with a 29.6% win rate.
- Osler (FRBNY) found that stop-loss clusters beyond levels produce **continuation cascades**. This motivates a breakout hypothesis.

### 0.2 Why ORB (hypothesis evidence, not proof)

- **Zarattini, Barbon & Aziz (2024), US stocks.** A 5-minute ORB traded in the direction of the first candle, with the stop at 10% of the 14-day ATR and an exit at end of day:
  - unfiltered: Sharpe 0.48;
  - trading only instruments with abnormally high **opening relative volume**: Sharpe 2.81.

  The volume filter carried almost all of the edge.
- **Zarattini & Aziz (2025), QQQ.** Entry in the direction of the first 5-minute candle, stop at the candle's opposite extreme, exit at 10R or end of day: win rate 24%, positive expectancy from large winners.
- **Crabel (1990).** ORB performs best after narrow-range days (NR7), i.e. volatility contraction before expansion.
- **Moskowitz, Ooi & Pedersen (2012).** Time-series momentum is significant in gold futures. This motivates a trend filter.
- No peer-reviewed ORB study on XAUUSD CFDs was found. **Every result here must be established on our own data.** A positive in-sample result is never sufficient (LSR 0A.1).

---

## 1. Engine reuse map (what stays, what changes)

All paths are repository-relative. "LSR" include files live in `MQL5/Include/LiquiditySweepReversal/`.

### 1.1 REUSE-UNCHANGED (do not edit)

| File | What ORB uses it for |
|---|---|
| `LSR_Types.mqh` | Shared enums and constants (price source, stop profile, costs, account rules, data gates) |
| `LSR_Json.mqh` | JSON writer, UTF-8 file output, SHA-256 |
| `LSR_BrokerTime.mqh` | Broker-day helpers and day clock |
| `LSR_Sessions.mqh` | Broker session schedule (`SymbolInfoSessionTrade`), `LSR_ParseHHMM`, closure calendar, tradeable segments |
| `LSR_SymbolSpec.mqh` | Symbol snapshot, price units (StrategyPipSize 0.10), tick alignment |
| `LSR_Quote.mqh` | Bid/Ask quote model, stop triggers |
| `LSR_Costs.mqh` | Commission (FundedNext metals), slippage, latency, entry cost gate |
| `LSR_Sizing.mqh` | Symbol economics (`OrderCalcProfit`), stress-aware sizing (used from ORB-3) |
| `LSR_AccountRules.mqh` | FundedNext Stellar 2-Step engine (used from ORB-3) |
| `LSR_RiskAdmission.mqh` | Daily-risk admission and ceilings (used from ORB-3) |
| `LSR_DataAudit.mqh` | Raw-tick audit, closures, quarantine, M1 reconciliation, `CLSR_DataQuarantine` |
| `LSR_Manifest.mqh` | Input recorder, run output package, `RegisterFile` |
| `LSR_Bars.mqh` | `CLSR_M1Builder` (M1 bars from ticks, normalized to digits), `CLSR_WilderAtr` |
| `LSR_Phase1.mqh` | Umbrella include of the Phase 1 contract |
| `Scripts/.../LSR_RawTickAudit.mq5` | Raw audit outside the tester |
| `python/lsr_reference/event_study.py` | Reuse `day_block_bootstrap_upper` and `analysis_filter` by import; do not copy them |

LSR-specific files are kept for history and are **not used** by ORB: `LSR_Liquidity.mqh`, `LSR_EventStudy.mqh`, `LSR_Phase2.mqh`, `LSR_Phase3.mqh`, `LSR_Expert.mq5`, `LSR_EventReplay.mq5`, and `python/lsr_reference/engine.py` and `run_reference.py`. Do not delete them.

### 1.2 NEW files

| File | Content |
|---|---|
| `MQL5/Include/OpeningRangeBreakout/ORB_Types.mqh` | ORB enums: session ID, exit variant, filter set, day decision codes |
| `MQL5/Include/OpeningRangeBreakout/ORB_Days.mqh` | Daily bars from M1, daily features (range, NR7, SMA50, daily ATR), opening-range builder per session, relative tick volume, day decision and filter flags (Section 3) |
| `MQL5/Include/OpeningRangeBreakout/ORB_Proxy.mqh` | Tick-level proxy-trade simulator with a time exit (Section 4). It is a generalized copy of the LSR `LSR_EventStudy` trade mechanics (entry, SL/TP geometry, LIVE_NATIVE_STOP, swap, MAE/MFE, gap/ambiguity), extended with `TIME_EXIT` |
| `MQL5/Include/OpeningRangeBreakout/ORB_Phase1.mqh` | ORB umbrella: includes `../LiquiditySweepReversal/LSR_Phase1.mqh`, `LSR_Bars.mqh` and the ORB files |
| `MQL5/Experts/OpeningRangeBreakout/ORB_Expert.mq5` | Non-trading research EA: Phase 1 contract, data audit, ORB day ledger and proxy ledger in **one tick pass** for both sessions |
| `MQL5/Scripts/OpeningRangeBreakout/ORB_DayReplay.mq5` | Rebuilds `orb_days_<SESSION>.csv` from an exported M1 file (like `LSR_EventReplay`) |
| `python/orb_reference/__init__.py`, `days.py`, `study.py`, `run_reference.py` | Independent Python reference for the day ledger (byte-identical reconciliation), plus trial statistics and the report |
| `python/tests/test_orb_days.py`, `python/tests/test_orb_study.py` | Python blocking fixtures |
| `docs/ORB_RunCard.md` | Exact tester settings, inputs and commands |

### 1.3 CHANGED files

| File | Change |
|---|---|
| `MQL5/Scripts/LiquiditySweepReversal/LSR_Tests.mq5` | Stays the **single** blocking-test script for the repository (owner decision). Add ORB suites (`TestOrbDays`, `TestOrbProxy`) and include `../../Include/OpeningRangeBreakout/ORB_Phase1.mqh`. Do not remove the existing suites. |
| `docs/DataManifest.schema.json` | Allow `phase` values `ORB-*` (already a free string), and add optional `orb` summary object. |
| `Liquidity_Sweep_Reversal_Roadmap.md` | Only the update-log entry that records the project closure (already added). |

---

## 2. Frozen research decisions (owner-approved, pre-registered)

| Item | Value |
|---|---|
| Sessions | `NY` and `LONDON`, as separate trials, both computed in the **same tick pass** |
| NY opening range | `[16:30, 16:45)` broker time (= 09:30–09:45 New York; the FundedNext server follows US DST) |
| LONDON opening range | `[10:00, 10:15)` broker time (= 08:00–08:15 London when UK and US DST are aligned) |
| Opening-range length | 15 minutes, built from M1 BID bars (LSR 2.12 item 1) |
| Entry method | **Direction of the opening-range candle** (Zarattini & Aziz 2025): Long if OR close > OR open, Short if OR close < OR open, no trade if equal (`NO_TRADE_DOJI`) |
| Entry time | First executable tick at or after the OR end (+ `FixedExecutionDelayMs`; LSR 0C.11). Long at Ask, Short at Bid |
| Initial stop | Opposite extreme of the opening range, widened by the entry spread: Long `SL = OR_Low − EntrySpread`, Short `SL = OR_High + EntrySpread`, aligned outward to the tick grid. LIVE_NATIVE_STOP triggers (LSR 0.4) |
| Exit variant `EOD` | No target. Time exit on the first tick at or after `SessionExitTime`; the stop remains active |
| Exit variant `R2` | Net target `TP_R = 2.0` (LSR 4.7, solved against known costs), plus the same stop and the same time exit as backstop |
| Session exit times | NY `23:00` broker (= 16:00 New York); LONDON `18:30` broker (= 16:30 London) |
| Trades per session | Maximum **1** per session per broker day, no re-entry (F7) |
| PlannedRisk1R | Loss entry → SL at 1 lot via `OrderCalcProfit` + known opening commission (LSR 4.5) |
| Costs | FundedNext metals commission, real Bid/Ask, slippage/latency NONE/ZERO at baseline (LSR 1.7). Swap is charged if a proxy crosses a rollover (EOD exits make this rare) |
| `MaxEntrySpreadEnabled` | **false** for ORB. The fixed 3-pip gate is replaced by the relative cost filter F2 |

### 2.1 Filters (pre-registered values; do not tune)

| ID | Filter | Exact rule | Role |
|---|---|---|---|
| **F1** | Opening relative tick volume | `RV = ORTicks / mean(ORTicks of the same session over the previous 14 valid sessions)`. Pass if `RV ≥ 1.0`. Fewer than 14 prior valid sessions → `NO_TRADE_WARMUP` | Base |
| **F2** | Relative cost | Pass if `EntrySpread ≤ 0.10 × |Entry − SL|`, i.e. spread ≤ 10% of the stop distance | Base |
| **F7** | One trade per session per day | Structural | Base |
| **F3** | NR7 | Previous complete broker day's range (high − low) ≤ the range of each of the 6 broker days before it. Needs 7 prior days, otherwise `NO_TRADE_WARMUP` | Separate trial |
| **F5** | Daily trend | `SMA50` = mean of the previous 50 broker-day closes. Long allowed only if the previous day's close is above SMA50; Short only if below; equal → blocked. Needs 50 prior days | Separate trial |
| F4 | OR width / daily ATR(14) | Recorded and stratified in buckets `<0.15`, `0.15–0.30`, `0.30–0.60`, `≥0.60`. **Not a filter** | Diagnostic |
| F6 | High-impact news | `NO_CALENDAR_OBSERVE_ONLY` unless a validated calendar is supplied (LSR 3.3). **Not a filter** | Diagnostic |

### 2.2 Trials (declared before any result is seen)

Each session has 4 filter sets and 2 exits, which gives **16 trials** in total:

- Filter sets:
  - `UNFILTERED`: F7 only
  - `BASE`: F1 + F2 + F7
  - `BASE_NR7`: BASE + F3
  - `BASE_TREND`: BASE + F5
- Exits: `EOD`, `R2`.

**Primary hypothesis (the only one that decides go/no-go): `NY / BASE / EOD`.** The other 15 trials are secondary. They are reported with their trial count, and none of them may replace the primary after results are known (LSR 0A.2).

### 2.3 Data ranges

| Range | Use |
|---|---|
| 2026-01-01 → 2026-06-30 | ORB-1 smoke test: correctness and reconciliation only. Also the ORB-1S screen (Section 6); **no profitability inference**. About 125 trading days, so fewer than the inferential minimum |
| 2020-07-01 → 2024-12-31 | ORB-2 development inference: the primary decision |
| 2026-07-01 → 2026-09-28 | Development extension (ORB-2, reported separately) |
| 2025-01-01 → 2025-12-31 | Untouched historical holdout, ORB-4 only, used once |
| 2026-09-29 → onward | True forward (ORB-5) |

---

## 3. Day ledger — exact definitions (ORB-1)

The engine consumes the single-pass M1 stream from `CLSR_M1Builder`. It advances time on every usable tick; see `CLSR_EventEngine::OnTime` in LSR for the pattern.

1. **Broker day** = `LSR_BrokerDayStart`. A day is complete when a later timestamp belongs to a new day. Daily OHLC is built from the M1 bars of that day. The day containing the first processed bar is incomplete and never counts as a "previous day".
2. **Opening range (per session, per day).**
   - `OR_Open` = open of the first M1 bar in the window; `OR_High`/`OR_Low` = max/min; `OR_Close` = close of the last M1 bar in the window; `ORTicks` = sum of the M1 tick counts.
   - The OR is **valid** only if all 15 M1 bars exist. Otherwise → `NO_TRADE_INCOMPLETE_RANGE`.
   - It is also invalid (`NO_TRADE_QUARANTINE`) if the window overlaps a data-quarantine window or a detected/declared closure (LSR 1.12 item 16).
   - The OR is complete on the first tick at or after the window end.
3. **Valid sessions for F1** = sessions with a valid OR. The 14-session mean excludes the current day.
4. **Direction** = sign(`OR_Close − OR_Open`).
5. **Decision codes**, one per session per broker day on which the session window lies inside a scheduled trading session:
   - `TRADE`
   - `NO_TRADE_DOJI`
   - `NO_TRADE_INCOMPLETE_RANGE`
   - `NO_TRADE_QUARANTINE`
   - `NO_TRADE_WARMUP`
   - `NO_TRADE_NO_TICK` (no executable tick before the session exit time)
   - `NO_TRADE_INVALID_STOP` (stop on the wrong side after alignment)

   Filter results are **flags**, not decisions. The day row stores F1, F2, F3 and F5 pass/fail, so every filter set is evaluated from the same rows.

   Note: F2 depends on the entry tick. The day ledger stores `EntrySpread` and the stop distance from the proxy entry, so F2 is computed identically for both exits.
6. **Daily features** (all use previous complete days only):
   - `PrevRange`
   - `NR7` flag
   - `SMA50` and `PrevClose`
   - Wilder `ATR14_D` on daily bars (LSR 2.12 item 6 formula)
   - `ORWidth/ATR14_D` bucket
   - weekday
   - `DST_MISMATCH` flag, true when UK and US daylight-saving states differ. Computed by rule: UK = last Sunday of March to last Sunday of October; US = second Sunday of March to first Sunday of November. **Diagnostic only**; the London window stays at 10:00 broker (LSR architecture rule 1: no DST table drives trading logic).
7. **Output `orb_days_<SESSION>.csv`** (one row per session per broker day):
   - date, session, OR open/high/low/close, ORTicks, RV (or NA), direction, decision code;
   - the F1/F3/F5 flags and their inputs (PrevRange, NR7, SMA50, PrevClose, ATR14_D, width bucket);
   - DST_MISMATCH, weekday, news state.

   Numeric formatting follows LSR 2.12 item 13/14 conventions (prices with symbol digits, ratios 6 decimals, NA for missing).
8. **Python reference** `python/orb_reference/days.py` rebuilds `orb_days_*.csv` from `bars_M1_BID.csv`, `reference_config.json` and `data_quarantine_windows.csv`. Reconciliation must be **byte-identical**; reuse the `run_reference.py` compare pattern.

## 4. Proxy trades — exact definitions (ORB-1)

1. For each `TRADE` day, create **two** proxies, `EOD` and `R2`, with an identical entry. Each is 1 lot and independent (no portfolio). This follows the LSR `LSR_EventStudy` mechanics.
2. Entry, SL and 1R are as in Section 2. The `R2` target is solved as in LSR 3.8 item 3 and aligned outward.
3. Exit precedence on each tick after entry:
   1. stop (Bid ≤ SL long / Ask ≥ SL short)
   2. target (`R2` only)
   3. time exit (tick time ≥ SessionExitTime)

   If both stop and target trigger on one tick, the stop wins (LSR 0C.21). A tick more than 300 s after the previous one marks `GAP_*`. A time exit fills at the executable quote (Bid long / Ask short) plus exit slippage.
4. MAE/MFE are measured from the entry tick (LSR 0C.14). Swap follows LSR 3.8 item 4.
5. **Output `orb_trades_<SESSION>.csv`**, one row per day and exit:
   - day keys, exit variant;
   - entry tick, Bid/Ask, spread, SL, TP, PlannedRisk1R;
   - exit time, quote and reason (`STOP`, `TP`, `TIME_EXIT`, `GAP_*`, `STOP_AMBIGUOUS_BOTH_BARRIERS`, `END_OF_DATA`);
   - gross/net P/L and R, costs R, MAE/MFE R;
   - F2 flag, quarantine flag.

## 5. Statistics and decision rules (ORB-2)

1. **Analysis set per trial.** Closed proxies (not `END_OF_DATA`), not quarantined, that pass the trial's filter set.
2. **Per trial:** n, independent days, mean NetR, median, win rate, profit factor, mean costs R, exit-reason counts, MAE/MFE, and stratifications by direction, weekday, width bucket, RV bucket (`<0.75`, `0.75–1`, `1–1.5`, `1.5–2`, `≥2`), DST_MISMATCH and year.
3. **Confidence bounds.** One-sided 95% lower and upper bounds of mean NetR from the day-block bootstrap: `python/lsr_reference/event_study.day_block_bootstrap_upper`, 10,000 repetitions, seed 20260929.
4. **Primary decision** (NY / BASE / EOD on 2020-07-01 → 2024-12-31):
   - `INCONCLUSIVE` if n < 200 or independent days < 60 (LSR 0A.1 / 0C.15);
   - `STOP` if Upper95 < 0;
   - `PROCEED_TO_ORB3` only if Lower95 ≥ +0.05R, i.e. `MinEconomicEdgeR` (LSR 0B.20);
   - otherwise `NO_EDGE_DEMONSTRATED`, which means stop, or redesign with the owner's approval.
5. **Secondary trials** are reported with a Holm–Bonferroni adjustment over all 16 one-sided tests (null hypothesis: mean ≤ 0). The p-value comes from the bootstrap: the share of bootstrap means ≤ 0. They never override the primary decision.
6. **Robustness in ORB-2.** The primary trial is re-reported with the pre-registered slippage stress of 2 points on both legs and latency 250 ms (LSR 1.7). Degradation above 50% (LSR 0A.1) is flagged.

---

## 6. Phases

Each phase is one work package, handled in one chat.

### ORB-1 — Day layer, proxy simulator, EA and Python reference

- Implement the Section 1.2 files and the Section 1.3 test additions.
- **Blocking fixtures**, in both MQL5 and Python with the same expected values:
  - OR build (15 bars, a missing bar → incomplete);
  - direction and doji;
  - RV warm-up and value;
  - NR7 with ties;
  - SMA50 boundary;
  - quarantine overlap;
  - `EOD` time exit;
  - `R2` target;
  - stop-wins;
  - F2 pass/fail;
  - one trade per session.
- Smoke run: 2026-01-01 → 2026-07-01, both sessions, one pass. Required: data gate PASSED, `orb_days` reconciliation byte-identical, all proxies closed or explained.
- **Gate:** tests PASS, compile 0/0, reconciliation PASS.

### ORB-1S — Screening on the cached 6 months (owner-approved, pre-registered 2026-09-29)

The owner wants to avoid downloading 2020–2024 unless ORB is at least not clearly negative. The screen runs on the ORB-1 smoke run (2026-01-01 → 2026-06-30, ticks already cached) and applies **only** this rule:

1. **Evaluate only the primary trial, `NY / BASE / EOD`.** Use the Section 5 analysis set and the day-block bootstrap (10,000 repetitions, seed 20260929).
2. **Classification:**
   - `SCREEN_STOP`: n ≥ 30 and Upper95(mean NetR) < 0, i.e. clearly negative. ORB stops; ask the owner whether to redesign.
   - `SCREEN_INCONCLUSIVE_LOW_N`: n < 30. Report it and ask the owner whether to download the development data anyway.
   - `SCREEN_CONTINUE`: anything else. Proceed to ORB-2 (download 2020-07 → 2024-12).
3. **The other 15 trials are reported for information only.** They cannot trigger `SCREEN_CONTINUE` for ORB if the primary trial is `SCREEN_STOP`.
4. **The screen can never support a profitability claim.** Its sample is below the inferential minimum (LSR 0A.1). No input, filter value, session time or exit may be changed because of screening results. A change reopens the pre-registration and needs the owner's approval, logged here.
5. The screening period (2026 H1) is kept separate from the ORB-2 inference period (2020-07 → 2024-12). ORB-2 statistics never include 2026 H1.

### ORB-2 — Development inference

- Tick data check for 2020-07-01 → 2024-12-31 on FundedNext-Server 2:
  - run `LSR_RawTickAudit` year by year;
  - if real ticks are missing (PotentialFallbackMinuteShare > 1% per year), **stop and ask the owner** about the data source (LSR 8.3). Do not silently switch to generated ticks.
- Run the EA on the full development range, then the Python study. Apply the Section 5 decision to the primary hypothesis.
- **Gate:** the primary classification is recorded along with all 16 trials, the adjustment, and the stress re-run.

### ORB-3 — Trade engine (only if the primary result is `PROCEED_TO_ORB3`)

- Real sizing (`LSR_Sizing`), daily risk admission (`LSR_RiskAdmission`, 0.5% = 1R, 3R daily guard) and FundedNext rules (`LSR_AccountRules`).
- A portfolio of both sessions is allowed only for trials that passed individually.
- Ledger with monthly/annual reports and max drawdown, reusing the definitions in LSR Phase 6.

### ORB-4 — Historical holdout 2025 (once)

- Frozen configuration only. The result is pass/fail against the Section 5 thresholds. Nothing may be tuned afterwards (LSR 0A.2).

### ORB-5 — Live hardening and forward

- Follows LSR Phase 9: live adapter for one session only, broker-native SL, fault injection and demo forward.

---

## 7. Non-negotiables carried over from LSR

- Broker Server Time is authoritative.
- One tick pass.
- Bid/Ask execution.
- No look-ahead: every feature uses only complete prior bars and days.
- No automatic "best configuration" selection.
- 2025 is untouched until ORB-4.
- Every run writes a DataManifest.
- Python independently reproduces the day ledger.
- Owner-approved changes are logged in this file.

## 8. Known limitations (accepted)

- XAUUSD CFD tick volume is a count of quote updates, not traded volume. F1 is therefore a proxy for the volume filter in Zarattini et al.
- The London window is fixed in broker time and shifts by one hour during DST-mismatch weeks (about 3–4 weeks per year). This is diagnosed, not corrected.
- News is observe-only until a validated calendar exists.

## 9. Maintenance protocol

Every code-changing phase updates this file with the completion record below and an update-log entry. Keep filenames and paths. Commit to `main`, then sync to the owner folder (Section 10).

```
ORB-N — COMPLETE
Date: YYYY-MM-DD
Files changed: ...
Summary: ...
Compile/Tests: ...
Result: ...
```

## 10. Operator notes (owner's machine, verified 2026-09-29)

| Item | Value |
|---|---|
| Owner project folder (git clone, remote `origin` → `github.com/artaveo/Liquidity-Sweep-Reversal-STR_Expert`) | `E:\Trade\Liquidity Sweep Reversal_STR` — the owner pushes from here |
| MetaEditor (CLI compile) | `C:\Program Files\MetaTrader 5\MetaEditor64.exe /compile:"<file.mq5>" /log:"<log>" /inc:"<repo>\MQL5"` (the log is UTF-16) |
| MT5 data folder | `%APPDATA%\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075` (copy `MQL5\...` here to install) |
| Common files (all run packages) | `%APPDATA%\MetaQuotes\Terminal\Common\Files\LSR\<ExperimentId>\` (ORB uses `...\Files\ORB\<ExperimentId>\`) |
| Run a script without the GUI | Write `config\<name>.ini` with `[StartUp] Script=...` `Symbol=XAUUSD` `Period=M1` (optionally `ScriptParameters=<preset in MQL5\Presets>`), close `terminal64.exe` gracefully, then start `terminal64.exe /config:"<full path>"`. The config path must be short (inside the data folder) |
| Run the tester without the GUI | `[Tester]` config with `Expert=`, `ExpertParameters=<.set in MQL5\Profiles\Tester>`, `Symbol=XAUUSD`, `Period=M1`, `Model=4` (real ticks), `FromDate`, `ToDate` (**exclusive**), `Deposit=100000`, `Currency=USD`, `Leverage=100`, `ShutdownTerminal=0`. Datetime inputs in `.set` files are epoch seconds |
| Tick cache | `bases\FundedNext-Server 2\ticks\XAUUSD\YYYYMM.tkc`. 2026-01 → 2026-09 is cached; older years must be downloaded (slow, about 60–90 MB per month) |
| Python | `%LOCALAPPDATA%\Programs\Python\Python312-arm64\python.exe` (standard library only). In tests, insert `os.path.normpath(...)` paths; un-normalized `..` paths fail to import on this machine |
| Test entry points | MQL5 `Scripts\LiquiditySweepReversal\LSR_Tests` → `Common\Files\LSR\tests\lsr_tests.txt`; Python `python -m unittest discover -s tests` from `python/` |

---

# Roadmap Update Log

## Update 2026-09-29 — ORB roadmap created

- The owner closed LSR after Phase 3 and approved ORB with: both sessions (NY first, same pass), a 15-minute opening range, entry in the direction of the opening-range candle, `EOD` and `R2` exits reported side by side, and the filters F1/F2/F7 as base with F3 and F5 as separate trials.
- Added ORB-1S: a pre-registered screen on the cached 2026 H1 data, run before downloading 2020–2024. The owner chose to keep the same repository because ORB reuses the LSR engine modules directly.
