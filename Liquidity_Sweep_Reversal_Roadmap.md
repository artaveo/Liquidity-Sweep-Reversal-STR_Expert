# Liquidity Sweep Reversal — Extended Implementation & Research Roadmap

**Document name:** `Liquidity_Sweep_Reversal_Roadmap.md`  
**Status:** EXTENDED FINAL — implementation/research-ready  
**Baseline symbol:** XAUUSD  
**Baseline broker context:** FundedNext / MT5  
**Baseline signal timeframe:** M1  
**Research risk default:** 0.50% per trade = 1R  
**Default Daily Loss Guard:** ON, 3R  
**Default Max Concurrent Positions:** 3  
**Default Daily Profit Target:** OFF, 9R  
**Experimental range:** 2026-01-01 → 2026-09-28  
**Extended development range:** 2020-07-01 → 2024-12-31 and 2026-01-01 → 2026-09-28  
**Reserved OOS:** 2025-01-01 → 2025-12-31

---

# 0. Research Decisions Locked Before Implementation

This section records the decisions that were added/changed after the external review. They are not suggestions for the implementation phase; they are part of the specification.

## 0.1 What is supported by evidence

Academic market-microstructure research supports two relevant facts:

1. Clearly defined support/resistance levels can have measurable intraday turning-point information.
2. Once clustered levels are crossed, stop-loss order flow can also accelerate price in the breakout direction.

Therefore a liquidity sweep/reclaim is a meaningful reversal hypothesis, but a reclaim candle alone is not proof that reversal will continue. The project must keep the unconfirmed version as a control and test one strict confirmation variant separately rather than silently replacing the original hypothesis.

## 0.2 No universal claim that “M1 gold sweeps usually continue”

The repository contains no historical data or trade ledger, so such a claim cannot be established from the repository itself. The engine must determine reversal/continuation behavior empirically from the selected XAUUSD data.

## 0.3 XAUUSD “pip” is explicitly defined

Pip terminology varies by platform/broker. For the FundedNext XAUUSD convention used by this research, the official example treats a 0.10 price movement as 1 pip. Therefore:

`StrategyPipSize = 0.10`

The strategy must never infer the meaning of “pip” from `SYMBOL_POINT` or from another broker’s convention. The actual price distance used by the strategy is always stored numerically.

## 0.4 Stop trigger is separated from broker-native SL behavior

The research strategy explicitly wants a stop that cannot be triggered merely by spread expansion.

Therefore the research engine uses a deterministic **reference-price stop trigger**:

`MidPrice = (Bid + Ask) / 2`

The research stop is triggered when MidPrice crosses the stop-reference level. The actual simulated exit then uses the executable opposite quote:

- Long exit = Bid
- Short exit = Ask

This is intentionally different from a broker-native protective SL, which is quote-side based and can react to spread changes. The research engine must document this distinction in every final report.

## 0.5 Costs and target definition

The geometric distance between entry and TP is not sufficient to call a trade a true `R` result.

The engine therefore calculates:

- actual entry quote
- actual stop/exit quote
- current execution spread
- commission
- configured slippage model
- swap when it occurs

The selected TP_R is a **net target against all costs that are deterministically knowable at target construction**. A TP is not classified as a full TP unless the executed result reaches the configured net target within the defined execution model.

Unpredictable future market gaps or execution deviations cannot be mathematically guaranteed away; those are recorded as actual execution deviation rather than falsely counted as a full target.

---

# 1. Non-Negotiable Architecture Rules

These rules apply to every phase.

1. **Broker Server Time is the source of truth.** No manual UTC/DST conversion is used for strategy session logic.
2. **Signal timeframe is an Input.** Default `M1`; at minimum support `M1/M5/M15/M30/H1`.
3. **Execution is Tick based.** Signal detection may be candle based, but entry/exit execution uses the actual tick stream.
4. **Primary research tester:** `Every tick based on real ticks`.
5. **No average/bar spread for execution.** The exact Bid/Ask from the event tick is used.
6. **No look-ahead.** A swing or HTF structure element is usable only after all candles required to confirm it have closed.
7. **No hidden rules.** Entry, confirmation, liquidity lifecycle, SL, TP, BE, re-entry, risk, sessions, costs, and reporting all have deterministic definitions.
8. **2025 is permanently reserved for OOS** in the extended research design. It cannot be used to select rules, filters, parameters, or scenarios.
9. **Single market-data pass for reporting.** Monthly/yearly/full-period reports must come from the same ledger, not separate backtests.
10. **Scenario isolation.** Each TP/BE/confirmation/filter scenario has independent account/trade state while sharing the one market-data stream.
11. **No automatic “best configuration” selection.** The engine reports predefined configurations; it must not silently optimize and select the highest historical result.
12. **Every code-changing phase updates this roadmap.**
13. **Roadmap filename and relative path never change:** `Liquidity_Sweep_Reversal_Roadmap.md`.
14. **Changed files keep their original filenames and relative paths. Unchanged files are untouched.**

---

# Phase 1 — Data Contract, Quality Audit, Event Study & Research Foundation

## Goal

Test whether the core sweep hypothesis has measurable behavior before building a large execution/scenario engine, while simultaneously establishing the exact market-data, time, cost, risk, and symbol contract required by later phases.

## 1.1 Signal timeframe

Input:

`SignalTimeframe`

Default:

`M1`

Required selectable values include:

`M1 / M5 / M15 / M30 / H1`

All candle calculations use the selected SignalTimeframe.

Tick execution remains independent of the selected timeframe.

## 1.2 Broker/server time

All sessions, day boundaries, month/year assignments, and daily-risk resets use:

`Broker Server Time`

No hard-coded UTC offset.

No hand-built DST table.

The engine must record the broker timestamp of every setup and trade.

## 1.3 Trading sessions

Input:

`TradingSessionMode`

### Mode 1 — Full Day Except Late Spread Window (default)

New entries allowed:

`Market Open → 21:30`

New entries blocked:

`21:30 → Market Close`

New entries resume after the next tradable market open.

### Mode 2 — NY Window

New entries allowed only:

`16:30 → 21:30 Broker Server Time`

### Mode 3 — Custom

Inputs:

`TradeStartTime`

`TradeEndTime`

Session filtering controls **new entries only**.

Existing positions are not closed merely because the session ends.

## 1.4 Tick/data-quality audit

The engine must verify and report:

- requested date range
- actual first/last available tick
- tick timestamp monotonicity
- duplicate timestamps
- missing intervals
- impossible/non-positive spreads
- negative or corrupted price values
- M1 OHLC vs tick reconciliation
- real-tick coverage
- minutes where MT5 falls back to generated ticks
- number and duration of fallback intervals
- symbol specification snapshot at test start
- trading-session specification
- tick size
- point size
- volume minimum/maximum/step
- stops level
- freeze level
- contract size
- tick value

MT5 documentation states that “real ticks” are the most accurate tester source when available, but if real tick history is unavailable or inconsistent with minute bars, the tester can use generated ticks for the affected interval. The final report must expose this rather than silently presenting the run as 100% real-tick data.

## 1.5 Symbol price units

Inputs:

`StrategyPipSize = 0.10`

for the baseline XAUUSD/FundedNext convention.

All price-distance calculations are stored in raw price units.

MT5 symbol properties such as `SYMBOL_POINT` and `SYMBOL_TRADE_TICK_SIZE` are also stored, but they must not redefine the strategy’s pip convention.

Every report includes:

- raw price distance
- strategy pips
- symbol points
- tick count where applicable.

## 1.6 Execution quote model

For every event tick, record:

- Timestamp
- Bid
- Ask
- Spread = Ask - Bid
- Last if available
- tick flags if available

Opening:

- Long = Ask
- Short = Bid

Closing:

- Long = Bid
- Short = Ask

No midpoint execution for actual P/L.

## 1.7 Cost model

The research engine supports:

`Commission`

`Swap`

`Configured slippage`

`Spread`

Commission must be configurable by dated schedule or current-condition preset.

For the FundedNext preset, the current official XAUUSD metals commission schedule is represented as a configurable formula rather than permanently hard-coded business logic.

Historical backtests must report whether they use:

- current-condition costs applied uniformly, or
- a dated historical commission schedule.

The research report must never present current costs applied retrospectively as if they were historical broker costs.

## 1.8 Position sizing and symbol constraints

Risk input:

`RiskPerTradePercent = 0.50`

The engine calculates dynamic 1R from the start-of-broker-day equity basis.

Position sizing must respect:

- minimum lot
- maximum lot
- volume step
- tick size
- contract size
- available margin

Use the MT5 calculation facilities where applicable:

- `OrderCalcProfit`
- `OrderCalcMargin`
- `OrderCheck` for execution-validity checks

The final volume is rounded **down to the legal volume step** so the requested risk is not exceeded by rounding.

## 1.9 Daily risk admission

Inputs:

`DailyLossGuardEnabled = true`

`MaxDailyLossR = 3.0`

`MaxConcurrentPositions = 3`

The daily guard is a **new-risk admission guard**, not a floating-loss forced exit.

Before any new position:

`RemainingDailyRiskR = MaxDailyLossR + RealizedNetDailyR - ReservedWorstCaseOpenRiskR`

A trade is admitted only when:

`NewTradeWorstCaseRiskR <= RemainingDailyRiskR`

and:

`OpenPositions < MaxConcurrentPositions`

Examples:

0R realized loss → up to three 1R positions may be open.

-1R realized loss → at most 2R new worst-case daily risk may be admitted.

-2R realized loss → at most 1R remains.

-3R realized loss → no new entry.

Floating P/L alone does not close an existing position.

The three currently open positions are allowed to finish through their normal exit rules.

## 1.10 Optional additional risk controls

Inputs exist but are OFF by default unless explicitly enabled:

`DirectionalPositionCapEnabled`

`MaxDirectionalPositions`

`MaxTotalDrawdownEnabled`

`MaxTotalDrawdownR`

`MaxConsecutiveLossGuardEnabled`

`MaxConsecutiveLosses`

These controls do not modify the baseline unless enabled.

## 1.11 Daily profit target

Inputs:

`DailyProfitTargetEnabled = false`

`DailyProfitTargetR = 9.0`

When enabled:

`NetDailyEquity/PnL >= +9R`

blocks new entries for the remainder of that broker day.

It does not force-close existing positions.

## 1.12 Pre-implementation event study

Before the full strategy execution engine is considered complete, run a lightweight event study over the experimental range:

`2026-01-01 → 2026-09-28`

The event study must evaluate the core sweep definition with no optimization.

For each candidate event record:

- liquidity source
- liquidity level
- sweep time
- sweep extreme
- penetration
- reclaim distance
- spread at event
- entry-side quote
- planned stop distance
- MAE
- MFE
- forward return at fixed R horizons
- reversal vs continuation classification
- pre-sweep touch count
- swing prominence where applicable
- session/time bucket
- weekday
- news-event proximity if a valid imported event calendar is explicitly supplied

The objective is diagnostic:

**Does the raw Sweep/Reclaim event contain measurable directional behavior after realistic transaction costs?**

This is not used to optimize dozens of parameters.

## 1.13 Event-study control vs confirmation

The event study must compare exactly two pre-registered entry hypotheses:

### Hypothesis A — Reclaim Control

Immediate entry on the first valid tick after the Sweep Candle closes back inside the level.

### Hypothesis B — Strict Next-Bar Confirmation

For a Short:

- Sweep Candle closes below LiquidityLevel.
- The immediately next SignalTimeframe candle must close below the Sweep Candle Low.
- If it does, entry occurs on the first valid tick after that confirmation candle closes.
- If it does not, the setup expires.

For a Long:

- Sweep Candle closes above LiquidityLevel.
- The immediately next SignalTimeframe candle must close above the Sweep Candle High.
- If it does, entry occurs on the first valid tick after that confirmation candle closes.
- Otherwise the setup expires.

No third confirmation pattern is introduced in the base research.

## 1.14 Completion gate for Phase 1

The event study does not declare the strategy profitable.

It produces a factual research gate:

- event count
- event quality distribution
- post-sweep direction distribution
- cost burden
- MAE/MFE
- control vs confirmation comparison

The next phase is allowed to proceed regardless of whether the event study looks attractive; its purpose is to prevent later code from hiding a weak raw signal.

### Required output

- Compile-clean diagnostic/research components
- Data-quality report
- Event-study report
- Sample raw event ledger
- Updated roadmap
- Changed-file list
- Test logs
- Patch package containing only new/changed files plus the updated roadmap

---

# Phase 2 — Liquidity Model, Level Lifecycle & Sweep Definition

## Goal

Build all four requested liquidity source types and remove ambiguity around what constitutes a valid sweep.

## 2.1 Liquidity source types

All four exist as independent Inputs:

1. `PreviousDayHighLow`
2. `PreviousSessionHighLow`
3. `ConfirmedSwingHighLow`
4. `EqualHighsLows`

Each source can be enabled or disabled independently.

Baseline does not add Asia/London/weekly/monthly/round-number sources to the core strategy.

The Liquidity Source architecture must remain extensible so those sources can be added later without rewriting the detector.

## 2.2 Previous Day High/Low

The level comes from the previous fully completed broker-time day.

Once the day closes:

`PDH` and `PDL` are fixed.

They do not move during the next trading day.

## 2.3 Previous Session High/Low

Default liquidity session:

`16:30 → 21:30 Broker Server Time`

The previous fully completed session supplies:

`PreviousSessionHigh`

`PreviousSessionLow`

Session definition is independently configurable.

## 2.4 Confirmed Swing High/Low

Defaults:

`SwingLeftBars = 2`

`SwingRightBars = 2`

Swing High:

its High is greater than the High of the two left bars and two right bars.

Swing Low:

its Low is lower than the Low of the two left bars and two right bars.

The swing becomes usable only after the two right-side candles have closed.

No future information may affect the earlier signal.

The engine must also store `SwingProminence` for every swing so later research can evaluate whether trivial swings behave differently from larger structural swings.

## 2.5 Equal Highs/Lows

Default:

`EqualLevelTolerancePips = 3`

With `StrategyPipSize = 0.10`, the default tolerance is:

`0.30 price units`

At least two confirmed swing points inside the tolerance form an Equal High/Low cluster.

The source points are retained in the ledger.

## 2.6 Liquidity clustering

If multiple liquidity sources occur within the clustering tolerance, they are one Liquidity Pool.

Example:

`PDH + SwingHigh + EqualHigh`

must not produce three independent setups at essentially the same price.

The ledger retains all source tags.

## 2.7 Level lifecycle

Each liquidity level/pool has a lifecycle state:

`ARMED`

`TOUCHED`

`SWEPT`

`CONSUMED`

A successful sweep consumes that specific level instance so the same physical pool cannot generate duplicate entries from the same sweep event.

A new day/session/newly confirmed swing creates a new level instance.

## 2.8 Pre-sweep touches

A first-touch requirement is **not hard-coded into the baseline**, because existing evidence does not justify a universal claim that first touch is always superior.

Instead the engine must record:

`PreSweepTouchCount`

and report performance stratified by:

`0`

`1`

`2`

`3+`

An optional research input may later cap the permitted touch count, but the baseline engine must not silently reject repeated tests.

## 2.9 Exact Sweep Definition

### Buy-side Sweep → Short

The sweep candle must satisfy all:

`Open < LiquidityLevel`

`High > LiquidityLevel`

`Close < LiquidityLevel`

This ensures the candle approached the level from below, penetrated it, and closed back below it.

A candle that opens already above the level is not a valid buy-side sweep of that level.

### Sell-side Sweep → Long

The sweep candle must satisfy:

`Open > LiquidityLevel`

`Low < LiquidityLevel`

`Close > LiquidityLevel`

A candle that opens already below the level is not a valid sell-side sweep.

## 2.10 Same-bar duplicate handling

A single SignalTimeframe candle may generate at most one sweep setup for one Liquidity Pool.

Multiple source labels inside the same pool do not multiply the trade.

### Required output

Every setup stores:

- source type(s)
- level ID
- liquidity price
- sweep candle OHLC
- sweep timestamp
- sweep extreme
- penetration
- reclaim distance
- pre-sweep touch count
- level age
- confirmation mode
- setup status

---

# Phase 3 — Entry, Spread-Insulated SL, Net-R TP/BE, Re-entry & Trade Lifecycle

## Goal

Define the exact entry, stop, target, BE, re-entry and optional time-exit behavior.

## 3.1 Entry modes

Input:

`EntryConfirmationMode`

Default:

`RECLAIM_CLOSE`

Available:

`RECLAIM_CLOSE`

`NEXT_BAR_EXTREME_CONFIRM`

### RECLAIM_CLOSE

The first valid real tick after the Sweep Candle closes is the entry event.

Long:

`Entry = Ask`

Short:

`Entry = Bid`

### NEXT_BAR_EXTREME_CONFIRM

The Sweep Candle itself does not create immediate entry.

The immediately following SignalTimeframe candle must confirm as specified in Phase 1.

Entry is the first valid tick after that confirmation candle closes.

If confirmation fails, the setup expires.

## 3.2 Exact initial SL reference

Input:

`SweepSLExtraPips = 3.0`

At the actual entry tick:

`EntrySpread = Ask - Bid`

`SLBufferPrice = EntrySpread + (3.0 × StrategyPipSize)`

Therefore, using the FundedNext XAUUSD pip convention:

`SLBufferPrice = EntrySpread + 0.30`

### Long

`StopReference = SweepLow - SLBufferPrice`

### Short

`StopReference = SweepHigh + SLBufferPrice`

## 3.3 Spread-insulated research stop trigger

The stop trigger uses:

`MidPrice = (Bid + Ask) / 2`

Long Stop Event:

`MidPrice <= StopReference`

Short Stop Event:

`MidPrice >= StopReference`

This means widening the spread alone cannot move the research reference price through the stop.

After the trigger:

- Long exits at Bid on the trigger tick.
- Short exits at Ask on the trigger tick.

The ledger records both the reference trigger and executable exit quote.

## 3.4 Minimum execution validity

Before a stop/TP/BE price is accepted, the engine checks:

- price is aligned to `SYMBOL_TRADE_TICK_SIZE`
- legal volume step
- minimum stop/freeze distance where applicable
- margin sufficiency
- no invalid order relation

The research engine must not fabricate an executable price that would be illegal under the symbol specification.

## 3.5 1R definition

At entry:

`RiskAmount1R = absolute planned net loss if initial stop is triggered`

under the configured execution/cost model.

The R amount is dynamic.

Example:

`RiskPerTradePercent = 0.50%`

and start-of-day equity is `$100,000`:

`1R target risk basis = $500`

Position size is solved from the actual stop distance and symbol value.

## 3.6 TP definition

Input:

`TPMode`

Default:

`SINGLE`

### Single TP

`TP_R = 2.0`

The value is configurable.

### Full Matrix

Only when selected, all 15 scenarios are tested:

1. R1 / BE OFF
2. R2 / BE OFF
3. R2 / BE R1
4. R3 / BE OFF
5. R3 / BE R1
6. R3 / BE R2
7. R4 / BE OFF
8. R4 / BE R1
9. R4 / BE R2
10. R4 / BE R3
11. R5 / BE OFF
12. R5 / BE R1
13. R5 / BE R2
14. R5 / BE R3
15. R5 / BE R4

## 3.7 Net-R target construction

For the selected TP scenario:

`TargetNetProfit = TP_R × RiskAmount1R`

The TP price is solved in the executable exit-quote domain.

Long TP is triggered from Bid.

Short TP is triggered from Ask.

The engine uses the exact entry quote, stop-derived R amount, configured commission model, and configured slippage/cost assumptions when constructing the target.

A result is classified as a full TP only when the realized modeled net profit reaches the configured target.

The report separately retains:

`GrossPriceR`

`GrossR`

`CostsR`

`NetR`

so the effect of costs is visible rather than hidden.

## 3.8 Break-even definition

The matrix labels:

`BE R1`

`BE R2`

`BE R3`

`BE R4`

mean the BE transition activates when the trade reaches the specified positive R threshold under the configured executable/net-R model.

After the trigger, the stop is moved to a **cost-neutral break-even reference**, not blindly to the raw entry price.

This avoids calling a trade “risk free” while known commissions would still guarantee a small loss.

The ledger records:

- BE trigger time
- trigger price/quote
- pre-BE net R
- new stop reference
- final exit result

## 3.9 Re-entry

Input:

`MaxAttemptsPerSetup = 1`

Allowed:

`1 / 2 / 3 / 4`

Meaning:

1 = initial only

2 = initial + one retry

3 = initial + two retries

4 = initial + three retries

A retry requires:

`same Liquidity Pool`

+

`new Sweep Event`

+

`new valid reclaim/confirmation`

A retry on the same candle/event is prohibited.

TP or BE permanently ends that setup lifecycle.

## 3.10 Time exit — optional research mode

Inputs:

`TimeExitEnabled = false`

`MaxHoldingBars`

When enabled:

after N completed SignalTimeframe bars from entry, on the first valid tick after the Nth bar closes, the position is closed at the executable market quote.

This feature is OFF by default and must not alter the baseline results unless explicitly enabled.

## 3.11 Session behavior

Session end never forcibly closes an existing trade in the baseline.

Existing positions continue until:

- TP
- SL
- BE
- optional time exit
- optional risk-control exit explicitly enabled

## 3.12 Completion output

Same mandatory roadmap-update and patch-package protocol.

---

# Phase 4 — Strategy-Specific Filters & Optional Risk Extensions

## Goal

Add the three approved strategy-specific filters without making them mandatory in the baseline.

All three are:

`OFF` by default.

## 4.1 Filter A — HTF Structure

Inputs:

`UseHTFStructureFilter = false`

Default:

`HTF = M15`

Using confirmed 2/2 swings:

Bullish:

valid `HH + HL`

Bearish:

valid `LH + LL`

When enabled:

Long requires Bullish HTF structure.

Short requires Bearish HTF structure.

Neutral/ambiguous structure = no trade.

No future data.

## 4.2 Filter B — Sweep Quality

Inputs:

`UseSweepQualityFilter = false`

`ATRPeriod = 14`

Requirements:

`SweepPenetration >= 0.10 × ATR`

`SweepPenetration <= 0.50 × ATR`

`ReclaimDistance >= 0.10 × ATR`

ATR uses completed pre-sweep candles only.

## 4.3 Filter C — Opposing Liquidity / Target Room

Input:

`UseTargetRoomFilter = false`

For Long:

the selected TP must be before the nearest relevant opposing liquidity in the move direction.

For Short:

the selected TP must be before the nearest relevant opposing liquidity in the move direction.

If no valid opposing liquidity exists, the trade is not rejected solely for absence of a target reference.

## 4.4 Filter combinations

For research, the engine can run:

- all OFF
- A
- B
- C
- A+B
- A+C
- B+C
- A+B+C

These are **predefined scenarios**, not an optimizer.

The engine must not search arbitrary threshold combinations.

## 4.5 Optional directional-risk cap

Input:

`DirectionalPositionCapEnabled = false`

`MaxDirectionalPositions = 3`

When disabled, baseline behavior is unchanged.

When enabled, Long and Short open positions are counted separately.

## 4.6 Optional total drawdown and streak guards

Supported but OFF by default:

`MaxTotalDrawdownEnabled`

`MaxTotalDrawdownR`

`MaxConsecutiveLossGuardEnabled`

`MaxConsecutiveLosses`

These controls are reported separately from the default daily 3R guard.

### Completion output

Same mandatory roadmap-update and patch-package protocol.

---

# Phase 5 — Single-Pass Backtest, Scenario State Engine & Hierarchical Reporting

## Goal

Process historical market data once per run while producing independent scenario results and all required reports without rerunning the backtest for each month/year.

## 5.1 Single market pass

The engine reads the selected tick stream once.

During that pass it constructs:

`Event Ledger`

`Trade Ledger`

`Scenario States`

`Daily State`

`Equity Curves`

Reports are generated afterward by grouping the resulting ledger.

January must never trigger a second backtest merely to create the January report.

## 5.2 Matrix scenario architecture

In Full Matrix mode, all 15 TP/BE scenarios run against the same single market-data traversal.

If confirmation/filter scenarios are being compared, each scenario has independent:

- open positions
- daily realized R
- reserved risk
- equity
- drawdown
- TP
- BE
- re-entry state
- guard state

Market ticks are not reread 15 times.

## 5.3 Exact tested ranges

### Experimental

`2026-01-01 → 2026-09-28`

### Extended Development

`2020-07-01 → 2024-12-31`

plus:

`2026-01-01 → 2026-09-28`

### OOS

`2025-01-01 → 2025-12-31`

The OOS year is not read by optimization or selection logic before the final OOS run.

## 5.4 Trade ledger fields

Minimum:

- Trade ID
- Scenario ID
- Year
- Month
- Day
- Direction
- SignalTimeframe
- Liquidity source
- Liquidity pool ID
- Liquidity level
- Pre-sweep touch count
- Level age
- Sweep candle time
- Sweep extreme
- Sweep penetration
- Reclaim distance
- Entry confirmation mode
- Entry Bid
- Entry Ask
- Entry price
- Entry spread
- Planned stop reference
- Stop trigger reference price
- Stop exit quote
- Exit spread
- TP price
- BE trigger
- BE stop reference
- Exit time
- Exit reason
- Attempt number
- Gross P/L
- Commission
- Swap
- Slippage
- Net P/L
- Gross R
- Costs R
- Net R
- MAE
- MFE
- Holding duration
- Holding bars

## 5.5 Monthly report

For every month:

- Year
- Month
- Total trades
- Long trades
- Short trades
- TP
- SL
- BE
- Guard events
- Gross R
- Net R
- Costs R
- Max DD R
- Max DD Touch Count
- Starting underwater DD R
- Maximum consecutive losses
- Maximum consecutive wins
- Average win R
- Average loss R
- Expectancy R
- Profit Factor
- MAE summary
- MFE summary
- Average holding duration
- Spread/cost summary

## 5.6 Annual report

For every year:

the same metric family as the monthly report, aggregated over the full year.

At minimum:

- Total trades
- Long
- Short
- TP
- SL
- BE
- Guard
- Gross R
- Net R
- Costs R
- Max DD
- Max DD Touch Count
- Max losing streak
- Max winning streak
- Expectancy
- Profit Factor
- MAE/MFE
- Holding time

## 5.7 Grand total

For a multi-year test:

same metric family over the complete requested range.

The final report also clearly identifies which calendar periods were Development and which were OOS.

## 5.8 Drawdown definition

For each report period:

`MaxDD_R` = deepest peak-to-trough drawdown visible in that period’s equity curve.

To avoid ambiguity at period boundaries, also report:

`StartingUnderwaterDD_R`

which shows whether the period began already below a previous peak.

This prevents a monthly report from hiding the fact that the account entered the month already underwater.

## 5.9 Max DD Touch Count

The user-requested metric is retained.

For each period:

`MaxDD_TouchCount`

is the number of distinct returns of the equity curve into the tolerance zone surrounding that period’s maximum drawdown.

Default:

`DDTouchToleranceR = 0.05R`

A new touch is counted only after the equity curve first exits the tolerance band and later re-enters it.

This metric is calculated independently for:

- every month
- every year
- the full requested period

Example:

`2026 Max DD = 8.4R`

`Max DD Touches = 5`

means the 2026 equity curve revisited its 8.4R drawdown zone five distinct times.

The example values are illustrative only.

## 5.10 Research stratification reports

Without rerunning the backtest, the same ledger must support additional tables by:

- liquidity source
- Long vs Short
- entry confirmation mode
- pre-sweep touch-count bucket
- swing prominence bucket
- trading-session mode
- hour
- weekday
- spread bucket
- cost/R bucket
- filter combination

These are descriptive slices, not independent backtests.

## 5.11 Execution-cost analysis

The report must show:

- average entry spread
- median entry spread
- maximum entry spread
- average exit spread
- total commission
- total swap
- total modeled slippage
- total costs in R
- cost/R distribution
- number of trades rejected because execution/cost constraints made the setup invalid

This allows the user to see whether the strategy edge survives costs.

## 5.12 Scenario-comparison output

The engine outputs all requested TP/BE scenarios side by side.

It must not automatically select the scenario with the highest Net R.

Scenario comparison includes:

- trade count
- win rate
- expectancy
- PF
- Net R
- max DD
- max DD touches
- max loss streak
- cost/R
- MAE/MFE

### Completion output

Same mandatory roadmap-update and patch-package protocol.

---

# Phase 6 — Statistical Validation, Reference Implementation, Freeze, Extended Test & OOS

## Goal

Prevent backtest artifacts, implementation mistakes and configuration selection bias from being mistaken for a real strategy effect.

## 6.1 Deterministic validation

Must prove:

- zero look-ahead
- correct swing confirmation timing
- exact signal-close to next-tick execution
- correct Bid/Ask opening and closing sides
- exact event-tick spread capture
- spread-insulated research stop behavior
- exact TP/BE trigger behavior
- no duplicate liquidity-pool trades
- correct level consumption
- exact re-entry limit
- correct daily risk reservation
- no forced close from floating daily DD alone
- correct three-position cap
- correct daily profit target
- correct server-time day/month/year assignment
- no month/year backtest reruns for reporting
- independent scenario state isolation

## 6.2 Python/reference reconciliation

Build a small independent reference implementation of the core event/position state machine.

It must be tested against the MT5 research engine on short deterministic intervals.

Compare:

- signal timestamps
- liquidity levels
- entry timestamps/prices
- stop/TP events
- exit timestamps/prices
- trade count
- Gross R
- Net R
- cumulative equity

Any discrepancy outside a predefined numerical tolerance becomes a blocking defect.

This is an independent cross-check, not a second production engine.

## 6.3 Bootstrap and Monte Carlo

The research package must include:

### Trade-sequence Monte Carlo

Randomly reshuffle closed-trade sequences to estimate:

- max DD distribution
- losing streak distribution
- equity-path variability

### Block bootstrap

Where practical, resample at the day/session level to preserve intraday clustering.

### Confidence intervals

Use bootstrap confidence intervals for:

- expectancy
- win rate
- mean Net R

The purpose is to show uncertainty, not to manufacture a probability of future profit.

## 6.4 Multiple-testing control

The project deliberately contains multiple predefined scenarios.

Therefore:

- every declared scenario is counted as a research trial
- the number of trials is reported
- no hidden configurations may be added after seeing results without restarting the declared trial count
- Deflated Sharpe Ratio / Probabilistic Sharpe diagnostics may be reported where statistically appropriate
- Probability of Backtest Overfitting / CSCV diagnostics are used when a configuration-selection exercise becomes large enough to justify them

The 15 TP/BE matrix is treated as a **research matrix**, not as permission to optimize 15 results and keep only the best one.

## 6.5 Parameter sensitivity

Predeclare small, non-optimized sensitivity checks around structural parameters.

At minimum, test controlled perturbations such as:

- SL extra buffer: 2 / 3 / 4 strategy pips
- Equal-level tolerance: 2 / 3 / 4 strategy pips

Sensitivity results are reported as stability ranges.

The engine must not search arbitrary hundreds of parameter values.

## 6.6 Regime robustness

Within the Development data, report performance separately across meaningful historical blocks.

The OOS year 2025 remains completely untouched.

Development diagnostics may separately show:

- 2020-07 → 2021
- 2022
- 2023
- 2024
- 2026 YTD

without using these splits as a hidden optimizer.

The objective is to determine whether the behavior exists across more than one market regime.

## 6.7 Secondary-symbol robustness

After XAUUSD core rules are frozen, the same deterministic engine may be run on XAGUSD as a **robustness check**, not as a parameter-selection tool for XAUUSD.

The secondary symbol result cannot be used to alter the already-frozen XAUUSD OOS rule set.

## 6.8 Data-source robustness

Primary research remains the target broker/tester feed because execution spread and symbol rules are broker-specific.

A secondary historical source may be used only for:

- gap/data continuity audit
- broad structural event comparison
- robustness diagnostics

It must not be mixed tick-by-tick with the target broker feed.

## 6.9 Experimental freeze

After the experimental phase:

`2026-01-01 → 2026-09-28`

the strategy configuration intended for the extended run is frozen.

Any material strategy-rule change after seeing extended-development performance creates a new research version and must not be silently folded into the old version.

## 6.10 Extended development test

Run the frozen version on:

`2020-07-01 → 2024-12-31`

and:

`2026-01-01 → 2026-09-28`

Exclude all of 2025.

## 6.11 Final OOS

Run the frozen configuration on:

`2025-01-01 → 2025-12-31`

No OOS observation may feed:

- rule selection
- filter selection
- parameter changes
- scenario pruning
- code changes intended to improve the OOS result

## 6.12 Final research package

Must contain:

- exact code version
- exact roadmap version
- exact Inputs
- symbol specification snapshot
- data-quality report
- experimental report
- extended-development report
- 2025 OOS report
- monthly reports
- annual reports
- grand total
- scenario matrix
- Monte Carlo report
- bootstrap confidence intervals
- sensitivity report
- Python reconciliation report
- compile/test logs
- known limitations

### Completion output

Same mandatory roadmap-update and patch-package protocol.

---

# Mandatory Roadmap Maintenance Protocol

This protocol applies to **every phase that changes code**.

At phase completion:

1. Update `Liquidity_Sweep_Reversal_Roadmap.md`.
2. Never rename the file.
3. Never change its relative path.
4. Mark the phase as `COMPLETE`.
5. Record completion date.
6. Add a concise 1–2 line summary of what was implemented.
7. List exact added/modified/removed files.
8. Record compile status.
9. Record test/validation status.
10. Record any blocking limitations.
11. Output the updated roadmap together with every changed/new file.
12. Preserve the original filenames and relative paths of all changed files.
13. Do not rewrite, rename or replace files that were not changed.
14. The output package must be replacement-safe: copying it over the real project replaces only matching changed/new files.
15. The next phase begins from the exact output state of the previous phase.
16. If implementation exposes a specification conflict, update the roadmap/specification first. Do not invent an undocumented code rule.

## Required completion record

Use exactly this compact structure inside the roadmap:

`Phase N — COMPLETE`

`Date: YYYY-MM-DD`

`Files changed: ...`

`Summary: ...`

`Compile/Tests: ...`

---

# Change Log From Previous Roadmap Version

## Major corrections

### 1. Entry confirmation
The original immediate-reclaim entry remains the **control/default hypothesis**, but the roadmap now contains one exact next-bar confirmation variant so continuation-after-sweep can be measured without introducing a large combinatorial search.

### 2. XAUUSD pip ambiguity
The baseline explicitly defines:

`StrategyPipSize = 0.10`

for the FundedNext XAUUSD convention.

The strategy no longer uses the undefined word “pip” as an implementation primitive.

### 3. Stop model
The stop now explicitly separates:

- stop reference
- research trigger price
- executable exit quote

The trigger is based on same-tick MidPrice so spread expansion alone does not invalidate the research setup.

### 4. Sweep validity
A Sweep Candle must approach the level from the correct side:

- Short: `Open < Level < High`, then `Close < Level`
- Long: `Open > Level > Low`, then `Close > Level`

This eliminates the ambiguous candle-opening-above/below-level case.

### 5. Liquidity lifecycle
Liquidity pools have explicit states and are consumed after a successful sweep to prevent duplicate setup generation.

### 6. First-touch handling
First-touch is not imposed as an unproven universal rule. Pre-sweep touches are measured and reported, making the effect testable.

### 7. Net-R accounting
TP construction now works from executable quote sides and deterministic costs rather than from a raw geometric price-distance multiple only.

### 8. Execution realism
Symbol volume/price restrictions, margin, stops/freeze levels, tick size, and cost models are part of the foundation rather than late additions.

### 9. Data quality
The tester’s real-tick/generation fallback behavior is audited and reported instead of assumed away.

### 10. Research ordering
A lightweight event study happens before the complete execution/scenario engine so a weak raw signal can be identified early.

### 11. Statistical validation
Bootstrap confidence intervals, trade-sequence Monte Carlo, sensitivity, independent reference reconciliation, and multiple-testing diagnostics were added.

### 12. Reporting
The requested MaxDD Touch Count remains, but the report now also exposes starting-underwater drawdown so monthly/yearly boundaries cannot create misleading standalone DD figures.

---

# Final Definition of Done

The project is complete only when:

- the four requested Liquidity sources work independently
- liquidity clustering and lifecycle are deterministic
- pre-sweep touches are measurable
- sweep detection has no ambiguous opening-above/below case
- M1 is the default and timeframe is configurable
- Broker Server Time is authoritative
- all three trading-session modes work
- real ticks are used whenever available and any fallback is reported
- actual Bid/Ask and same-tick spread are used
- XAUUSD strategy pip size is explicit
- entry/SL/TP/BE are deterministic
- initial SL cannot be triggered by spread expansion alone in the research model
- TP is cost-aware and executable-quote based
- 1R is dynamic
- position sizing respects symbol constraints and risk
- daily loss guard defaults to 3R and blocks new risk without force-closing open trades from floating DD alone
- max concurrent positions defaults to 3
- the remaining daily risk capacity prevents new trades from exceeding the 3R risk budget
- daily profit target exists at 9R but is OFF by default
- Single TP mode defaults to 2R
- Full Matrix mode runs all 15 requested TP/BE scenarios
- Re-entry defaults to one attempt and supports 1–4 attempts
- the three approved strategy filters exist and are OFF by default
- optional time/directional/total-DD/streak controls exist without altering baseline defaults
- a single market-data pass generates the full ledger and scenario outputs
- monthly, annual and grand-total reports are produced from that ledger
- Long/Short counts are explicit
- MaxDD and MaxDD Touch Count are explicit for every reporting period
- MAE/MFE/cost/execution metrics are retained
- event-study diagnostics exist
- 2025 remains a clean OOS year
- Monte Carlo/bootstrap/sensitivity diagnostics are available
- the MT5 engine reconciles against an independent reference implementation
- every code-changing phase updates this exact roadmap file
- the roadmap is never renamed
- changed/new files preserve original names and relative paths
- unchanged files are not touched
