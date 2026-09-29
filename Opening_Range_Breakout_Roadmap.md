# Opening Range Breakout (Nasdaq-100 / NDX100) — Implementation & Research Roadmap

**Document name:** `Opening_Range_Breakout_Roadmap.md` (permanent: never renamed, never version-numbered)
**Status:** APPROVED BY OWNER, 2026-09-29. Implementation starts at Phase ORB-1.
**Instrument:** `NDX100` on FundedNext MT5 (`FundedNext-Server 2`), a CFD on the Nasdaq-100 index. This is the market in which the reference paper (Zarattini & Aziz 2025, QQQ) reported its result. **XAUUSD is not tested** (owner decision 2026-09-29; see 0.3).
**Time basis:** Broker Server Time (FundedNext follows US DST, so 16:30 broker = 09:30 New York all year).
**Predecessor:** `Liquidity_Sweep_Reversal_Roadmap.md` (LSR). LSR Phases 1–3 are complete; the owner closed the LSR strategy after its Phase 3 event study. ORB reuses the LSR engine. Read Section 1 before touching code.

---

## 0. How a new chat must start (read first)

1. Clone the repository and read this file completely. Read `Liquidity_Sweep_Reversal_Roadmap.md` **only** for the sections referenced here: 0A, 0B.9–0B.11, 0C.9–0C.22, Phase 1 (1.1–1.12) and 2.12 items 1, 2, 6 and 13.
2. Work on branch `main`. There is one logical work package per chat (ORB-1, ORB-1S, ORB-2, …). Update this roadmap at the end of every code-changing phase, following Section 9.
3. **Do not change any file listed as REUSE-UNCHANGED in Section 1.1** unless a failing test proves a defect, or Section 1.3 explicitly lists the change. Every change is logged in this roadmap's update log.
4. The owner's machine (Section 10) already has MetaTrader 5, MetaEditor, Python 3.12, and a FundedNext-Server 2 login. **NDX100 ticks for 2026-01 → 2026-08 are not cached yet.** The first NDX100 tester run downloads them automatically; this is slow, and the watchdog pattern in Section 10 applies.

### 0.1 Why LSR was closed (evidence carried forward)

LSR Phase 3 ran on XAUUSD 2026-01-01 → 2026-06-30 with real ticks, a 1-lot proxy and a net 2R target. The sweep/reclaim reversal showed no edge:

- M5 was STOP_EARLY_REDESIGN.
- M15 and H1 had negative or near-zero mean NetR, a win rate of 28–33%, and a reversal share of 50–56%.
- The mean XAUUSD entry spread was about 5.7 strategy pips.
- External evidence agrees. A pre-registered sweep-reversal study found no edge on EURUSD, XAUUSD or BTCUSD, and a mechanical ICT bot reached PF 0.81.
- Osler (FRBNY) found that stop clusters beyond levels produce **continuation**. This motivates a breakout hypothesis.

### 0.2 Why ORB (hypothesis evidence, not proof)

- **Zarattini & Aziz (2025), QQQ / TQQQ, the paper being replicated here.** Rules:
  - The opening range is the first 5-minute candle of the US cash session (09:30–09:35 ET).
  - At 09:35 enter in the **direction of that candle**, with the stop at the candle's **opposite extreme**.
  - Exit at **10R or end of day**.
  - Risk is at most 1% per trade.

  Reported result: QQQ 33% annualized, Sharpe 1.13, win rate 24%. The authors note sensitivity to slippage.
- **Zarattini, Barbon & Aziz (2024), US stocks.** The same ORB made almost nothing unfiltered (Sharpe 0.48). Trading only stocks with abnormally high **opening relative volume** ("stocks in play") raised it to Sharpe 2.81.
- **Crabel (1990).** ORB performs best after narrow-range days (NR7).
- **Moskowitz, Ooi & Pedersen (2012).** Time-series momentum motivates a trend filter.

### 0.3 Why NDX100 and not XAUUSD, and what cannot be replicated

- The owner requires the test to run on the market where the paper found its result. QQQ tracks the Nasdaq-100; the closest instrument available at FundedNext is the `NDX100` CFD. Same underlying index, same US cash-session open.
- The stock-universe paper (2024) needs a cross-section of about 7,000 US stocks ranked by relative volume each day. FundedNext offers only a handful of single stocks (for example AMD, INTC, MSFT, NVDA), so **that universe cannot be replicated**. Its relative-volume idea is kept only as filter F1 on NDX100.
- A CFD differs from QQQ: it has a broker spread instead of an exchange spread, trades nearly 24 hours instead of only the cash session, and its tick volume counts quote updates, not traded shares. The replication is therefore approximate. Results must be judged on our own data and costs.

---

## 1. Engine reuse map (what stays, what changes)

All paths are repository-relative. "LSR" include files live in `MQL5/Include/LiquiditySweepReversal/`.

### 1.1 REUSE-UNCHANGED (do not edit)

| File | What ORB uses it for |
|---|---|
| `LSR_Types.mqh` | Shared enums and constants. The only exception is Section 1.3 item 1 |
| `LSR_Json.mqh` | JSON writer, UTF-8 file output, SHA-256 |
| `LSR_BrokerTime.mqh` | Broker-day helpers and day clock |
| `LSR_Sessions.mqh` | Broker session schedule (`SymbolInfoSessionTrade`), `LSR_ParseHHMM`, closure calendar, tradeable segments. It works for any symbol |
| `LSR_SymbolSpec.mqh` | Symbol snapshot, price units. `StrategyPipSize` is an **input**; for NDX100 it is 1.0 index point (Section 2) |
| `LSR_Quote.mqh` | Bid/Ask quote model, stop triggers |
| `LSR_Sizing.mqh` | Symbol economics (`OrderCalcProfit`), stress-aware sizing (from ORB-3) |
| `LSR_AccountRules.mqh` | FundedNext Stellar 2-Step engine (from ORB-3) |
| `LSR_RiskAdmission.mqh` | Daily-risk admission and ceilings (from ORB-3) |
| `LSR_DataAudit.mqh` | Raw-tick audit, auto closures (US holidays and early closes), quarantine, M1 reconciliation |
| `LSR_Manifest.mqh` | Input recorder, run output package, `RegisterFile` |
| `LSR_Bars.mqh` | `CLSR_M1Builder` (M1 bars from ticks, normalized to digits), `CLSR_WilderAtr` |
| `LSR_Phase1.mqh` | Umbrella include of the Phase 1 contract |
| `Scripts/.../LSR_RawTickAudit.mq5` | Raw audit outside the tester (any chart symbol) |
| `python/lsr_reference/event_study.py` | Reuse `day_block_bootstrap_upper` by import; do not copy it |

LSR-specific files are kept for history and are **not used** by ORB: `LSR_Liquidity.mqh`, `LSR_EventStudy.mqh`, `LSR_Phase2.mqh`, `LSR_Phase3.mqh`, `LSR_Expert.mq5`, `LSR_EventReplay.mq5`, and `python/lsr_reference/engine.py` and `run_reference.py`. Do not delete them.

### 1.2 NEW files

| File | Content |
|---|---|
| `MQL5/Include/OpeningRangeBreakout/ORB_Types.mqh` | ORB enums: OR length, exit variant, filter set, day decision codes |
| `MQL5/Include/OpeningRangeBreakout/ORB_Days.mqh` | Daily bars from M1, daily features (range, NR7, SMA50, daily ATR), opening-range builder, relative tick volume, day decision and filter flags (Section 3) |
| `MQL5/Include/OpeningRangeBreakout/ORB_Proxy.mqh` | Tick-level proxy-trade simulator with a time exit (Section 4). It is a generalized copy of the LSR `LSR_EventStudy` trade mechanics (entry, SL/TP geometry, LIVE_NATIVE_STOP, swap, MAE/MFE, gap/ambiguity), extended with `TIME_EXIT` |
| `MQL5/Include/OpeningRangeBreakout/ORB_Phase1.mqh` | ORB umbrella: includes `../LiquiditySweepReversal/LSR_Phase1.mqh`, `LSR_Bars.mqh` and the ORB files |
| `MQL5/Experts/OpeningRangeBreakout/ORB_Expert.mq5` | Non-trading research EA: Phase 1 contract, data audit, ORB day ledger and proxy ledger for both OR lengths in **one tick pass** |
| `MQL5/Scripts/OpeningRangeBreakout/ORB_DayReplay.mq5` | Rebuilds `orb_days_<ORLEN>.csv` from an exported M1 file (like `LSR_EventReplay`) |
| `python/orb_reference/__init__.py`, `days.py`, `study.py`, `run_reference.py` | Independent Python reference for the day ledger (byte-identical reconciliation), plus trial statistics and the report |
| `python/tests/test_orb_days.py`, `python/tests/test_orb_study.py` | Python blocking fixtures |
| `docs/ORB_RunCard.md` | Exact tester settings, inputs and commands |

### 1.3 CHANGED files (only these)

1. **`LSR_Types.mqh` + `LSR_Costs.mqh`: commission for indices.**
   - Today the only commission mode is `FUNDEDNEXT_OFFICIAL_METALS`. Add `ENUM_LSR_COMMISSION_MODE` value `LSR_COMMISSION_FUNDEDNEXT_OFFICIAL_INDICES`.
   - ORB-1 must first read the **official FundedNext commission schedule for indices** and record the source URL and date in this roadmap. If the schedule states no commission, the formula returns 0 and the Run Card says so. If it states a formula, implement exactly that formula.
   - Also cross-check the result against the `DEAL_COMMISSION` of one demo/tester deal on NDX100.
   - Existing XAUUSD tests must still pass unchanged.
   - **Recorded 2026-09-29 (ORB-1):** FundedNext Help Center, "What are the commission charges for Stellar Challenges and FundedNext Accounts?" (`https://help.fundednext.com/en/articles/10701368`), and *Symbols & Conditions* (`https://fundednext.com/general-rules/cfds/symbols-and-conditions`). Stellar 1-Step/2-Step list commission for Forex, Oil, Metals (0.0016%), Crypto and Stocks; **indices carry no commission**. `FUNDEDNEXT_OFFICIAL_INDICES` therefore returns 0, and a non-zero `CommissionRatePercent` fails initialization. The pages were read through search excerpts because the build container could not open fundednext.com directly; the `DEAL_COMMISSION` cross-check on the owner's machine is the binding confirmation (Run Card 2).
2. **`MQL5/Scripts/LiquiditySweepReversal/LSR_Tests.mq5`**: stays the **single** blocking-test script for the repository (owner decision). Add ORB suites (`TestOrbDays`, `TestOrbProxy`, `TestIndexCommission`) and include `../../Include/OpeningRangeBreakout/ORB_Phase1.mqh`. Keep the existing suites.
3. **`docs/DataManifest.schema.json`**: add an optional `orb` summary object.

The following are **not** code changes. They are EA inputs set in the ORB Run Card:
- `AccountCurrency` must equal NDX100's profit currency, USD. The existing LSR init check enforces this.
- `StrategyPipSize = 1.0`.
- `MaxEntrySpreadEnabled = false`.

---

## 2. Frozen research decisions (owner-approved, pre-registered)

| Item | Value |
|---|---|
| Instrument | `NDX100` (FundedNext), price source BID |
| Session | **US cash open only** (the paper's market). The London open is not tested, because the paper's effect concerns the US cash open |
| Session start | `16:30` broker time (= 09:30 New York) |
| Opening-range length | **`OR5` = `[16:30, 16:35)`**, as in the paper, and **`OR15` = `[16:30, 16:45)`**, the owner's variant. Both are built from M1 BID bars in the same pass |
| Entry method | **Direction of the opening-range candle**: Long if OR close > OR open, Short if OR close < OR open, no trade if equal (`NO_TRADE_DOJI`) |
| Entry time | First executable tick at or after the OR end (+ `FixedExecutionDelayMs`; LSR 0C.11). Long at Ask, Short at Bid |
| Initial stop | Opposite extreme of the opening range, widened by the entry spread so that the Bid/Ask trigger is equivalent: Long `SL = OR_Low − EntrySpread`, Short `SL = OR_High + EntrySpread`. Aligned outward to the tick grid. LIVE_NATIVE_STOP triggers (LSR 0.4) |
| Exit variant `R10_EOD` | **The paper's rule**: net target `TP = 10R`, otherwise a time exit at end of day |
| Exit variant `R2_EOD` | The owner's variant: net target `TP = 2R`, otherwise a time exit at end of day |
| End of day | First tick at or after `23:00` broker time (= 16:00 New York cash close). On US early-close days, the auto-detected closure or the last tick of the session applies; record this as `TIME_EXIT_EARLY_CLOSE` |
| Trades per day | Maximum **1** per OR length per broker day, no re-entry (F7) |
| PlannedRisk1R | Loss entry → SL at 1 lot via `OrderCalcProfit` + known opening commission (LSR 4.5). Targets are solved net of known costs (LSR 4.7) |
| Costs | Real Bid/Ask, index commission (Section 1.3), slippage/latency NONE/ZERO at baseline. Swap only if a proxy crosses a rollover (rare with an EOD exit) |
| `StrategyPipSize` | `1.0` (one index point). Pips are a reporting unit only; every rule uses raw prices or R |
| `MaxEntrySpreadEnabled` | **false**. The relative cost filter F2 replaces it |

### 2.1 Filters (pre-registered values; do not tune)

| ID | Filter | Exact rule | Role |
|---|---|---|---|
| **F1** | Opening relative tick volume | `RV = ORTicks / mean(ORTicks of the same OR length over the previous 14 valid sessions)`. Pass if `RV ≥ 1.0`. Fewer than 14 prior valid sessions → `NO_TRADE_WARMUP` | Base |
| **F2** | Relative cost | Pass if `EntrySpread ≤ 0.10 × |Entry − SL|` | Base |
| **F7** | One trade per OR length per day | Structural | Base |
| **F3** | NR7 | Previous complete broker day's range (high − low) ≤ the range of each of the 6 broker days before it. Needs 7 prior days | Separate trial |
| **F5** | Daily trend | `SMA50` = mean of the previous 50 broker-day closes. Long only if the previous close is above SMA50, Short only if below | Separate trial |
| F4 | OR width / daily ATR(14) | Stratified in buckets `<0.05`, `0.05–0.10`, `0.10–0.20`, `≥0.20`. **Not a filter** | Diagnostic |
| F6 | High-impact news (FOMC, CPI, NFP) | `NO_CALENDAR_OBSERVE_ONLY` unless a validated calendar is supplied (LSR 3.3). **Not a filter** | Diagnostic |

### 2.2 Trials (declared before any result is seen)

The grid is 2 OR lengths × 4 filter sets × 2 exits = **16 trials**:

- OR lengths: `OR5`, `OR15`.
- Filter sets:
  - `UNFILTERED`: F7 only
  - `BASE`: F1 + F2 + F7
  - `BASE_NR7`: BASE + F3
  - `BASE_TREND`: BASE + F5
- Exits: `R10_EOD`, `R2_EOD`.

**Primary hypothesis (the only one that decides go/no-go): `NDX100 / OR5 / UNFILTERED / R10_EOD`.** This is the exact paper replication. It first checks whether the published effect exists on our instrument after our costs.

**Co-reported (not decisive): `OR5 / BASE / R10_EOD`.** This is the owner's "trade only good setups" version. It is shown directly beside the primary.

All other trials are secondary, carry their trial count and a Holm adjustment, and cannot replace the primary after results are known (LSR 0A.2). The owner may swap primary and co-reported **only before** ORB-1S results exist, logged in the update log.

### 2.3 Data ranges

| Range | Use |
|---|---|
| 2026-01-01 → 2026-06-30 | ORB-1 smoke test and the ORB-1S screen. **No profitability inference.** About 125 US sessions |
| 2020-07-01 → 2024-12-31 | ORB-2 development inference: the primary decision. **Availability risk:** FundedNext keeps NDX100 bar history only from 2025 on this machine. ORB-2 must first check whether the broker serves older NDX100 ticks; see ORB-2 |
| 2026-07-01 → 2026-09-28 | Development extension (reported separately) |
| 2025-01-01 → 2025-12-31 | Untouched historical holdout, ORB-4 only, used once |
| 2026-09-29 → onward | True forward (ORB-5) |

---

## 3. Day ledger — exact definitions (ORB-1)

The engine consumes the single-pass M1 stream from `CLSR_M1Builder`. It advances time on every usable tick; see `CLSR_EventEngine::OnTime` in LSR for the pattern.

1. **Broker day** = `LSR_BrokerDayStart`. A day is complete when a later timestamp belongs to a new day. Daily OHLC is built from the M1 bars of that day. The day containing the first processed bar is incomplete and never counts as a "previous day".
2. **Opening range (per OR length, per day).**
   - `OR_Open` = open of the first M1 bar in the window; `OR_High`/`OR_Low` = max/min; `OR_Close` = close of the last M1 bar in the window; `ORTicks` = sum of the M1 tick counts.
   - The OR is **valid** only if every M1 bar of the window exists (5 or 15 bars). Otherwise → `NO_TRADE_INCOMPLETE_RANGE`.
   - It is also invalid (`NO_TRADE_QUARANTINE`) if the window overlaps a data-quarantine window or a detected/declared closure (LSR 1.12 item 16).
   - The OR is complete on the first tick at or after the window end.
3. **Valid sessions for F1** = sessions with a valid OR of the same length. The 14-session mean excludes the current day.
4. **Direction** = sign(`OR_Close − OR_Open`).
5. **Decision codes**, one per OR length per broker day on which 16:30 lies inside a scheduled trading session:
   - `TRADE`
   - `NO_TRADE_DOJI`
   - `NO_TRADE_INCOMPLETE_RANGE`
   - `NO_TRADE_QUARANTINE`
   - `NO_TRADE_WARMUP`
   - `NO_TRADE_NO_TICK` (no executable tick before 23:00)
   - `NO_TRADE_INVALID_STOP` (stop on the wrong side after alignment)

   F1, F2, F3 and F5 are **flags**, not decisions, so every filter set is evaluated from the same rows. F2 uses the proxy entry tick's spread and stop distance, so it is identical for both exits.
6. **Daily features** (previous complete days only):
   - `PrevRange`
   - `NR7` flag
   - `SMA50` and `PrevClose`
   - Wilder `ATR14_D` on daily bars (LSR 2.12 item 6 formula)
   - `ORWidth/ATR14_D` bucket
   - weekday
   - news state
7. **Output `orb_days_<ORLEN>.csv`** (one row per OR length per broker day):
   - date, OR length, OR open/high/low/close, ORTicks, RV (or NA), direction, decision code;
   - the F1/F3/F5 flags and their inputs, width bucket, weekday, news state.

   Numeric formatting follows LSR 2.12 item 13/14 conventions (prices with symbol digits, ratios 6 decimals, NA for missing).
8. **Python reference** `python/orb_reference/days.py` rebuilds `orb_days_*.csv` from `bars_M1_BID.csv`, `reference_config.json` and `data_quarantine_windows.csv`. Reconciliation must be **byte-identical**; reuse the `python/lsr_reference/run_reference.py` compare pattern.

## 4. Proxy trades — exact definitions (ORB-1)

1. For each `TRADE` day and each OR length, create **two** proxies, `R10_EOD` and `R2_EOD`, with an identical entry. Each is 1 lot and independent (no portfolio). This follows the LSR `LSR_EventStudy` mechanics.
2. Entry, SL and 1R are as in Section 2. Targets are solved net of known costs as in LSR 3.8 item 3 and aligned outward.
3. Exit precedence on each tick after entry:
   1. stop (Bid ≤ SL long / Ask ≥ SL short)
   2. target
   3. time exit (tick time ≥ 23:00 broker)

   If stop and target trigger on one tick, the stop wins (LSR 0C.21). A tick more than 300 s after the previous one marks `GAP_*`. A time exit fills at the executable quote (Bid long / Ask short) plus exit slippage.
4. MAE/MFE are measured from the entry tick (LSR 0C.14). Swap follows LSR 3.8 item 4.
5. **Output `orb_trades_<ORLEN>.csv`**, one row per day and exit:
   - day keys, exit variant;
   - entry tick, Bid/Ask, spread, SL, TP, PlannedRisk1R;
   - exit time, quote and reason (`STOP`, `TP`, `TIME_EXIT`, `TIME_EXIT_EARLY_CLOSE`, `GAP_*`, `STOP_AMBIGUOUS_BOTH_BARRIERS`, `END_OF_DATA`);
   - gross/net P/L and R, costs R, MAE/MFE R;
   - F2 flag, quarantine flag.

## 4A. ORB-1 implementation closures (binding)

Implementing ORB-1 exposed the gaps below. Each is closed here; where these rules conflict with earlier wording in Sections 3–4, they win.

1. **When the day ledger is built.** The tick pass stores only raw per-day aggregates. The ledger is built once at the end of the run, because the data quarantine and the detected closures are known only after the raw audit is finalized. Every feature of day d still uses only broker days before d, so there is no look-ahead.
2. **Rows.** One row per OR length for every broker day from the day of the first processed M1 bar to the day of the last one on which 16:30 lies inside the weekly scheduled session (`SymbolInfoSessionTrade`). A scheduled day without bars gets a row (`NO_TRADE_INCOMPLETE_RANGE`).
3. **Decision order.** The first blocking reason wins: `NO_TRADE_INCOMPLETE_RANGE` → `NO_TRADE_QUARANTINE` → `NO_TRADE_WARMUP` → `NO_TRADE_DOJI` → `NO_TRADE_NO_TICK` → `TRADE`. `WARMUP` applies to every trial (it is a decision code, not only the F1 flag).
4. **5a — `NO_TRADE_INVALID_STOP` lives on the proxy rows.** It needs the entry tick's Bid/Ask, which the BID M1 bars do not contain, so it cannot be reproduced byte for byte by the Python day reference. The day row stays `TRADE`; both proxy rows read `state = NO_TRADE`, `reason = NO_TRADE_INVALID_STOP` and are outside every analysis set.
5. **`NO_TRADE_NO_TICK`** is bar-derived: no M1 bar in `[OR end, 23:00)`. With `LatencyMode = ZERO` this equals "no executable tick". With a latency delay the proxy may find no executable tick although a bar exists; that proxy row reads `NOT_ENTERED / NO_EXECUTABLE_TICK`.
6. **Exact comparisons.** Direction, NR7 and F5 compare integer symbol points. F1 compares `ORTicks × 14 ≥ sum of the previous 14 ORTicks`. SMA50 = sum of 50 close points / 50 × point. RV, SMA50, ATR14_D and width/ATR are printed with 6 decimals, prices with symbol digits. An OR's OHLC is printed when at least one bar exists; width, direction and width/ATR only when the OR is complete.
7. **Quarantine flags.** A day is `NO_TRADE_QUARANTINE` when `[OR start, OR end)` overlaps a quarantine window, a detected closure or a declared closure. A proxy's `in_quarantine` covers `[OR start, exit + 1 s)`; Section 5.1 excludes such proxies.
8. **End of day.** A proxy exits on the first tick at or after 23:00 (`TIME_EXIT`, or `GAP_TIME_EXIT` after a gap > 300 s). If its broker day ends without such a tick, it closes on that day's last tick when the next day's first tick arrives: `TIME_EXIT_EARLY_CLOSE` when 23:00 lies inside the scheduled session, otherwise `TIME_EXIT`. At the end of the run the same rule applies when the proxy's day lies fully inside the declared range; otherwise `END_OF_DATA`. Proxies therefore never cross a broker-day rollover, and swap is structurally 0.
9. **F2** compares the entry tick's spread with `0.10 × |Entry − SL|` after tick alignment; it is identical for both exits.
10. **Output folder.** `CLSR_RunOutput` hard-codes `Common\Files\LSR\`, so `ORB_Phase1.mqh` carries `CORB_RunOutput` with the same contract and the `ORB` root (Section 10). The manifest keeps the LSR schema (`lsr.datamanifest.v1`) with the optional `orb` object.

## 5. Statistics and decision rules (ORB-2)

1. **Analysis set per trial.** Closed proxies (not `END_OF_DATA`), not quarantined, that pass the trial's filter set.
2. **Per trial:** n, independent days, mean NetR, median, win rate, profit factor, mean costs R, exit-reason counts, MAE/MFE, and stratifications by direction, weekday, width bucket, RV bucket (`<0.75`, `0.75–1`, `1–1.5`, `1.5–2`, `≥2`) and year.
3. **Confidence bounds.** One-sided 95% lower and upper bounds of mean NetR from the day-block bootstrap (`python/lsr_reference/event_study.day_block_bootstrap_upper`, 10,000 repetitions, seed 20260929).
4. **Primary decision** (`NDX100 / OR5 / UNFILTERED / R10_EOD`, 2020-07-01 → 2024-12-31):
   - `INCONCLUSIVE` if n < 200 or independent days < 60;
   - `STOP` if Upper95 < 0;
   - `PROCEED_TO_ORB3` only if Lower95 ≥ +0.05R (`MinEconomicEdgeR`, LSR 0B.20);
   - otherwise `NO_EDGE_DEMONSTRATED`.
5. **Secondary trials:** Holm–Bonferroni over all 16 one-sided tests (null: mean ≤ 0; the bootstrap p-value is the share of bootstrap means ≤ 0). Never decisive.
6. **Robustness:** the primary trial is re-reported with slippage stress of 2 points on both legs and latency 250 ms (LSR 1.7). Degradation above 50% is flagged. The paper itself warns about slippage sensitivity.

---

## 6. Phases

### ORB-1 — Day layer, proxy simulator, EA, Python reference, index commission

- Implement Sections 1.2 and 1.3.
- **Blocking fixtures**, in both MQL5 and Python with the same expected values:
  - OR5 and OR15 build (a missing bar → incomplete);
  - direction and doji;
  - RV warm-up and value;
  - NR7 with ties;
  - SMA50 boundary;
  - quarantine overlap;
  - `R10_EOD` time exit and target;
  - `R2_EOD` target;
  - stop-wins;
  - F2 pass/fail;
  - one trade per OR length;
  - index commission formula;
  - XAUUSD commission unchanged.
- Smoke run: NDX100, 2026-01-01 → 2026-07-01 (tester end date exclusive), one pass. This triggers the NDX100 tick download. Required: data gate PASSED, `orb_days` reconciliation byte-identical, all proxies closed or explained.
- **Gate:** tests PASS, compile 0/0, reconciliation PASS. Record counts only.

#### ORB-1 completion record

```
ORB-1 — CODE COMPLETE (gate pending the owner's compile, tests and smoke run)
Date: 2026-09-29
Files changed: added MQL5/Include/OpeningRangeBreakout/{ORB_Types,ORB_Days,ORB_Proxy,ORB_Phase1}.mqh,
  MQL5/Experts/OpeningRangeBreakout/ORB_Expert.mq5, MQL5/Scripts/OpeningRangeBreakout/ORB_DayReplay.mq5,
  python/orb_reference/{__init__,days,proxy,study,run_reference}.py, python/tests/{test_orb_days,test_orb_study}.py,
  docs/ORB_RunCard.md; modified MQL5/Include/LiquiditySweepReversal/{LSR_Types,LSR_Costs}.mqh (index commission, 1.3),
  MQL5/Scripts/LiquiditySweepReversal/LSR_Tests.mq5 (ORB suites), docs/DataManifest.schema.json (optional orb object,
  ORB roadmap filename), this roadmap (1.3 source, 4A, this record, update log).
Summary: Day ledger (OR5/OR15, RV/F1, NR7, SMA50/F5, ATR14_D, decision codes) built from the single M1 BID stream;
  tick-level R10_EOD/R2_EOD proxies with the end-of-day exit; non-trading research EA writing the ORB run package;
  M1 replay script; independent Python day reference with byte-identical reconciliation and proxy completeness check;
  trial statistics (16 trials, day-block bootstrap, Holm), ORB-1S screen and ORB-2 decision.
Compile/Tests: Python unittest 37/37 OK (build container, Python 3.11; standard library only). The MQL5 files could not
  be compiled in the build container (no MetaEditor): compile 0/0 and LSR_Tests PASS are the owner's first gate step.
Result: pending — smoke run NDX100 2026.01.01–2026.07.01, data gate, reconciliation and counts go here.
```

### ORB-1S — Screening on 2026 H1 (owner-approved, pre-registered 2026-09-29)

This runs before any older data is downloaded. It uses the ORB-1 smoke run and applies **only** this rule:

1. **Evaluate only the primary trial, `OR5 / UNFILTERED / R10_EOD`.** Use the Section 5 analysis set and bootstrap.
2. **Classification:**
   - `SCREEN_STOP`: n ≥ 30 and Upper95(mean NetR) < 0, i.e. clearly negative. ORB stops; ask the owner.
   - `SCREEN_INCONCLUSIVE_LOW_N`: n < 30. Ask the owner.
   - `SCREEN_CONTINUE`: anything else. Go to ORB-2.
3. **The other 15 trials, including the co-reported `OR5 / BASE / R10_EOD`, are information only.** They cannot turn `SCREEN_STOP` into `SCREEN_CONTINUE`.
4. **No profitability claim is possible here**; the sample is below the inferential minimum. No input, filter, time or exit may change because of these results. A change reopens pre-registration and needs the owner's logged approval.
5. 2026 H1 is never included in ORB-2 statistics.

Implementation: `python -m orb_reference.study <package> --mode screen` (Run Card 6). `--mode dev` refuses rows dated in 2026 H1 or 2025.

#### ORB-1S completion record

```
ORB-1S — CODE COMPLETE (classification pending the ORB-1 smoke run)
Date: 2026-09-29
Files changed: python/orb_reference/study.py, python/tests/test_orb_study.py, docs/ORB_RunCard.md (Section 6).
Summary: Screen of the primary trial OR5/UNFILTERED/R10_EOD on the ORB-1 package (Section 5.1 analysis set,
  day-block bootstrap 10,000 reps, seed 20260929): SCREEN_STOP / SCREEN_INCONCLUSIVE_LOW_N / SCREEN_CONTINUE.
  The other 15 trials are reported with Holm-adjusted p-values as information only.
Result: pending.
```

### ORB-2 — Development inference

1. **Data availability check first.** Open an NDX100 chart and run `LSR_RawTickAudit` for 2020-07-01 → 2024-12-31, year by year.
   - If FundedNext cannot serve real ticks for those years (no data, or PotentialFallbackMinuteShare > 1%), **stop and ask the owner**.
   - Options to put to the owner:
     - (a) the development period covers only what FundedNext has, e.g. 2025 H2 is **not** allowed because 2025 is the holdout, so this means 2026 only;
     - (b) an external tick source for the Nasdaq-100 CFD (a data-source change, LSR 8.3);
     - (c) the QQQ/Nasdaq futures history from another platform.

   Never switch silently to generated ticks.
2. Run the EA on the available development range, then the Python study. Apply the Section 5 decision to the primary hypothesis.
3. **Gate:** primary classification recorded, all 16 trials reported with the Holm adjustment, stress re-run done.

### ORB-3 — Trade engine (only if the primary result is `PROCEED_TO_ORB3`)

- Real sizing (`LSR_Sizing`), daily risk admission (`LSR_RiskAdmission`, 0.5% = 1R, 3R daily guard) and FundedNext rules (`LSR_AccountRules`).
- Monthly/annual reports and max drawdown (LSR Phase 6 definitions).

### ORB-4 — Historical holdout 2025 (once)

- Frozen configuration only; pass/fail against Section 5. Nothing is tuned afterwards.

### ORB-5 — Live hardening and forward

- Follows LSR Phase 9: live adapter for NDX100 only, broker-native SL, fault injection and demo forward.

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
- Every owner-approved change is logged in this file.

## 8. Known limitations (accepted)

- NDX100 is a CFD on the index, not QQQ. Its spread, financing and tick-volume semantics differ from the paper's ETF, so the replication is approximate.
- CFD tick volume counts quote updates, not shares. F1 is a proxy.
- The stock-universe ORB (2024 paper) cannot be replicated with FundedNext's symbol list.
- News is observe-only until a validated calendar exists.
- Broker NDX100 history before 2025 may be unavailable (ORB-2 item 1).

## 9. Maintenance protocol

Every code-changing phase updates this file with the completion record below and an update-log entry. Keep filenames and paths. Commit to `main`, then sync to the owner folder (Section 10); the owner pushes.

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
| Common files (run packages) | `%APPDATA%\MetaQuotes\Terminal\Common\Files\ORB\<ExperimentId>\` (LSR used `...\Files\LSR\`) |
| Run a script without the GUI | Write `config\<name>.ini` with `[StartUp] Script=...` `Symbol=NDX100` `Period=M1` (optionally `ScriptParameters=<preset in MQL5\Presets>`), close `terminal64.exe` gracefully, then start `terminal64.exe /config:"<full path>"`. The config path must be short (inside the data folder) |
| Run the tester without the GUI | `[Tester]` config with `Expert=OpeningRangeBreakout\ORB_Expert`, `ExpertParameters=<.set in MQL5\Profiles\Tester>`, `Symbol=NDX100`, `Period=M1`, `Model=4` (real ticks), `FromDate`, `ToDate` (**exclusive**), `Deposit=100000`, `Currency=USD`, `Leverage=100`, `ShutdownTerminal=0`. Datetime inputs in `.set` files are epoch seconds |
| Tick cache | `bases\FundedNext-Server 2\ticks\<SYMBOL>\YYYYMM.tkc`. NDX100 has only 2026-09 cached, and bar history starts in 2025. The first tester run downloads backwards from the current month (slow). A background watchdog that relaunches the tester config if `terminal64.exe` exits is useful; use PowerShell, because Git-Bash fork errors occurred |
| Python | `%LOCALAPPDATA%\Programs\Python\Python312-arm64\python.exe` (standard library only). In tests, insert `os.path.normpath(...)` paths; un-normalized `..` paths fail to import on this machine |
| Test entry points | MQL5 `Scripts\LiquiditySweepReversal\LSR_Tests` → `Common\Files\LSR\tests\lsr_tests.txt`; Python `python -m unittest discover -s tests` from `python/` |

---

# Roadmap Update Log

## Update 2026-09-29 — ORB-1 and ORB-1S implemented (code)

- Index commission recorded (1.3): FundedNext states no commission for indices, so `FUNDEDNEXT_OFFICIAL_INDICES` returns 0. The `DEAL_COMMISSION` cross-check is left to the owner's run.
- Added the binding implementation closures in 4A. Two of them need the owner's attention because they interpret the text: `NO_TRADE_INVALID_STOP` is recorded on the proxy rows instead of the day ledger (4A item 4), and `NO_TRADE_WARMUP` applies to every trial, including `UNFILTERED` (4A item 3).
- `docs/DataManifest.schema.json`: optional `orb` object, and `code.roadmap_file` may now name this roadmap.
- No research decision in Section 2 changed. The MQL5 code was not compiled in the build container; compile, tests, smoke run and the ORB-1S classification are the owner's next steps (Run Card).

## Update 2026-09-29 — Instrument changed to NDX100 (owner decision)

- ORB is tested on the paper's market, the Nasdaq-100 (FundedNext `NDX100`), not on XAUUSD.
- The primary hypothesis is the exact paper rule, `OR5 / UNFILTERED / R10_EOD`. The owner's filtered version `OR5 / BASE / R10_EOD` is co-reported, and `OR15` and `R2_EOD` stay as secondary trials.
- The London session is dropped because the paper concerns the US cash open.
- Section 1.3 adds the index-commission mode. ORB-2 gains a broker data-availability check.

## Update 2026-09-29 — ORB roadmap created

- The owner closed LSR after Phase 3 and approved ORB with: a 15-minute opening range, entry in the direction of the opening-range candle, two exits reported side by side, and the filters F1/F2/F7 as base with F3 and F5 as separate trials.
- Added ORB-1S: a pre-registered screen on the cached 2026 H1 data, run before downloading older data. The owner chose to keep the same repository because ORB reuses the LSR engine modules directly.
