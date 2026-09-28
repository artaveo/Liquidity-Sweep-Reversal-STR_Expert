# Liquidity Sweep Reversal — Extended Implementation & Research Roadmap

**Document name:** `Liquidity_Sweep_Reversal_Roadmap.md`  
**Status:** V3 STRATEGY-LOGIC HARDENED SPEC — research + production-architecture ready  
**Research audit date:** 2026-09-28  
**V3 design score:** 8.9/10 for methodology/architecture and deterministic strategy specification when implemented exactly; profitability remains unvalidated  
**Baseline symbol:** XAUUSD  
**Baseline broker context:** FundedNext / MT5  
**Baseline signal timeframe:** M1  
**Research risk default:** 0.50% per trade = 1R  
**Default Daily Loss Guard:** ON, 3R  
**Default Max Concurrent Positions:** 3  
**Default Daily Profit Target:** OFF, 9R  
**Experimental range:** 2026-01-01 → 2026-09-28  
**Extended development range:** 2020-07-01 → 2024-12-31 and 2026-01-01 → 2026-09-28  
**Historical blind holdout:** 2025-01-01 → 2025-12-31  
**True forward OOS:** 2026-09-29 → onward

---

# 0. Research Decisions Locked Before Implementation

## 0A. V2 HARDENING — BINDING OVERRIDES

Where this section conflicts with an earlier sentence, this section wins.

### 0A.1 Acceptance / rejection framework

A positive backtest is not sufficient for acceptance. The project has three separate gates:

1. implementation correctness;
2. research validity;
3. deployment readiness.

A configuration is blocked by unresolved look-ahead, timestamp ambiguity, material data contamination, illegal broker execution semantics, unrecoverable risk-state divergence, or any use of OOS observations for selection.

Pre-register before untouched OOS:

- PrimaryConfidenceLevel = 95%
- MinTradesForInferentialStats = 200
- MaxSinglePeriodNetRContribution = 50%
- MaxStressExpectancyDegradation = 50%
- MaxDeclaredPropBreachProbability = 5%

Below the inferential sample minimum, classification is **INCONCLUSIVE**.

Primary evidence is mean NetR per closed trade with a one-sided 95% block-bootstrap lower confidence bound. Positive point estimate alone is never an acceptance criterion.

### 0A.2 Deterministic configuration selection

Never select by “highest historical NetR”.

The selection rule must be frozen before OOS:

1. eliminate configurations failing hard/OOS gates;
2. among survivors prefer lower rule complexity;
3. if tied, prefer lower tail risk/drawdown under the declared stress set;
4. use untouched OOS NetR only as the final tie-breaker.

A new material candidate after results are seen creates a new research version and restarts the holdout process.

### 0A.3 Research / live separation

Architecture is explicitly:

- Strategy Core — deterministic, side-effect-free signal and lifecycle logic.
- Research Simulator — synthetic multi-scenario execution over one tick stream.
- Live Execution Adapter — one frozen deployment configuration only.
- Ledger / Reporting — immutable candidate, event and trade records.

The Full Matrix is research simulation, not fifteen live strategies.

### 0A.4 Liquidity terminology boundary

PDH/PDL, session extremes, swings and equal highs/lows are **price-level proxies**, not direct observations of institutional liquidity or a centralized order book. DOM, if later available, is a separate data source and hypothesis.

### 0A.5 Validation chronology

- 2026-01-01 → 2026-09-28 = discovery / experiment
- 2020-07-01 → 2024-12-31 = development / robustness
- 2025-01-01 → 2025-12-31 = untouched historical OOS
- 2026-09-29 → onward = true forward validation

A material rule change after discovery/development starts a new research version and invalidates the prior OOS selection process.

### 0A.6 Reproducibility

Every run produces a DataManifest containing code SHA, roadmap hash, MT5 build, broker/server, account-rule profile, symbol specification, requested/actual range, tick source and fallback coverage, server-time basis, cost/slippage/latency model, scenario IDs, declared trial count, random seeds and ledger checksum.


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

## 0B. V3 STRATEGY-LOGIC HARDENING — BINDING OVERRIDES

This section closes the remaining strategy-definition loopholes. Where it conflicts with earlier strategy wording, this section wins.

### 0B.1 Single event stream, scenario-neutral market structure

Liquidity detection, sweep detection, touch counting, swing confirmation, equal-level formation and event timestamps are generated once by the Strategy Core.

Research scenarios consume that same event stream.

A scenario must never create or destroy a liquidity event merely because a filter, TP, BE or risk rule differs. This prevents scenario-dependent opportunity sets.

### 0B.2 Exact liquidity-pool geometry

For every pooled set of high-side levels define:
- PoolLower = minimum member level
- PoolUpper = maximum member level
- PoolAnchor = median member level

For low-side pools use the analogous band.

Clustering is only for deduplication and common event identity; it does not erase the member prices.

A pool may be formed only when max(member levels) - min(member levels) <= LiquidityClusteringTolerancePrice.

Baseline:

LiquidityClusteringTolerancePips = 3.0

This prevents transitive chain clustering from silently producing an over-wide pool.

A high-side sweep is valid only when all are true:
- PreviousBarClose < PoolLower
- SweepOpen <= PoolLower
- SweepHigh > PoolUpper
- SweepClose < PoolLower

A low-side sweep is valid only when all are true:
- PreviousBarClose > PoolUpper
- SweepOpen >= PoolUpper
- SweepLow < PoolLower
- SweepClose > PoolUpper

This rejects already-crossed-at-open and gap-like classifications and requires traversal of the pooled band before reclaim.

### 0B.3 Exact penetration and reclaim metrics

For a high-side sweep:
- Penetration = SweepHigh - PoolUpper
- ReclaimDistance = PoolLower - SweepClose

For a low-side sweep:
- Penetration = PoolLower - SweepLow
- ReclaimDistance = SweepClose - PoolUpper

Store raw-price and ATR-normalized values. Non-positive penetration or reclaim invalidates the candidate.

### 0B.4 Event-consumption rule

A valid sweep is a market event whether or not a later filter rejects the trade.

VALID_SWEEP_EVENT -> RECORD_EVENT -> CONSUME_LEVEL_INSTANCE

Filter rejection never resurrects the level. The same physical sweep cannot become multiple opportunities by changing filter/scenario state.

### 0B.5 Touch-count definition

A pre-sweep touch occurs when the declared SignalBarPriceSource enters or crosses the pool band before the sweep candle opens.

Rules:
- timestamp strictly earlier than sweep-candle open;
- multiple ticks inside one bar count as one touch;
- the band must be exited before a later re-entry can count as another touch;
- the sweep candle itself is not a pre-sweep touch.

Touch timestamps and the band touched are stored.

### 0B.6 Level eligibility and freshness

A level is eligible only if its defining information became available before the sweep candle opened.

- PDH/PDL = previous fully completed broker-time day;
- previous-session high/low = previous fully completed configured session;
- swing = usable only after right-side confirmation closes;
- equal-high/low cluster = formed only from already confirmed swings.

No level created or modified using information from the sweep candle or later bars may participate in that sweep.

### 0B.7 Target-room look-ahead prohibition

Target-room analysis may use only opposing liquidity that is known and eligible at the exact entry timestamp.

Future swings, future equal-high/low clusters and future session levels cannot define or invalidate the trade.

If no eligible opposing liquidity exists at entry, report NO_KNOWN_OPPOSING_LIQUIDITY rather than substituting a future level.

### 0B.8 Same-timestamp execution ambiguity

Preserve source tick sequence when available. If deterministic sequence is unavailable, mark AMBIGUOUS_EXECUTION and do not invent intra-tick ordering.

### 0B.9 Account-level risk aggregation

MaxConcurrentPositions = 3 is not sufficient by itself.

Also enforce:
- MaxAggregateOpenWorstCaseRiskR
- MaxDirectionalOpenWorstCaseRiskR

Default safety ceilings:

MaxAggregateOpenWorstCaseRiskR = 3.0R
MaxDirectionalOpenWorstCaseRiskR = 2.0R

These are safety ceilings, not optimality claims, and may be tightened before deployment.

Aggregate worst-case exposure includes all open trades plus declared execution buffers. No new trade is admitted when it would breach an aggregate ceiling.

### 0B.10 External account-rule compliance

The internal strategy 3R guard is a research risk budget, not a substitute for the target account's actual rule engine.

The EA must implement AccountRuleEngine with:
- DailyLossLimitAmount
- MaximumLossLimitAmount
- current balance
- current equity
- realized P/L
- floating P/L
- commissions/fees
- reset timestamp
- safety buffer
- near-breach state
- breach state

For FundedNext, the selected account model must be configured because current official documentation distinguishes account models and includes open-position results in daily-loss calculations. The implementation must reproduce the selected model exactly rather than assuming a universal 3R rule.

### 0B.11 News is a robustness dimension

News proximity is first recorded, then tested as a separate robustness scenario. It is not presumed to improve the edge.

Published high-frequency gold research reports swift and significant responses to major U.S. macroeconomic announcements and continued short-term volatility adjustment after FOMC shocks.

### 0B.12 Filter-combination explosion control

Core strategy Filter Matrix remains only:
- A = HTF structure
- B = Sweep quality
- C = Target room

The existing 8 combinations of A/B/C remain the core matrix.

News and Spread/Execution Quality are separate robustness/gating dimensions and are not multiplied into the 8-way matrix by default.

### 0B.13 No implementation discretion for missing formulas

Before coding, the specification must contain exact formulas for pool geometry, penetration, reclaim, touch, freshness, target-room eligibility, TP/BE trigger basis, re-entry lifecycle, aggregate risk and account-rule compliance.

A missing formula is SPEC-INCOMPLETE, not developer discretion.

### 0B.14 Evidence boundary

Evidence from FX and COMEX gold futures can support hypotheses about price-level reactions, stop-order clustering, volatility and announcement effects. It does not prove the same edge for XAUUSD CFD on the target broker.

Osler's work supports intraday support/resistance turning-point hypotheses in FX; gold-futures studies support explicit treatment of intraday seasonality and announcement effects. These are hypothesis evidence, not validation of this EA.

### 0B.15 Strategy decision trace

Every candidate stores a reason-coded decision trace:
- LEVEL_ELIGIBLE
- POOL_MATCH
- SWEEP_VALID
- TOUCH_COUNT
- ENTRY_MODE
- FILTER_A
- FILTER_B
- FILTER_C
- NEWS_STATE
- SPREAD_STATE
- RISK_STATE
- ACCOUNT_RULE_STATE
- FINAL_ADMISSION

This makes every accepted/rejected candidate auditable without reconstructing logic from charts.

### 0B.16 Price-source contract is frozen

Baseline:
SignalBarPriceSource = BID

All bar-derived structure uses BID consistently. Choosing LAST in a future research version creates a new research version. Execution remains Bid/Ask-specific.

### 0B.17 Confirmation lifecycle is atomic

For NEXT_BAR_EXTREME_CONFIRM, the confirmation candle is the single candle immediately following the sweep candle.

If confirmation fails, the setup expires permanently. A later candle may not reinterpret the setup as confirmed.

### 0B.18 Gap-through handling

If an executable quote jumps over both TP and stop/reference barriers between observed ticks, the simulator must not invent the intratick path.

Classify as GAP_CROSSED_BARRIER and apply the declared conservative execution rule. Keep the raw event visible for sensitivity analysis.

### 0B.19 Target-room geometry

For a Long, a valid opposing high-side pool blocks the target when the selected TP is inside or beyond that pool. Require TP < OpposingPoolLower.

For a Short, require TP > OpposingPoolUpper.

Only opposing pools known and eligible at the exact entry timestamp may be used.

### 0B.20 Economic-edge threshold

An OOS lower confidence bound above zero is a statistical gate, not proof of economic significance.

MinEconomicEdgeR must be pre-registered before final selection. It is a research policy parameter and may not be chosen after OOS results are seen.

### 0B.21 Stable event identity

Every candidate receives a stable EventID independent of scenario. Scenario reports may reuse the same EventID, but the underlying market event is immutable.

### 0B.22 Cost attribution

Cost burden is decomposed into entry spread, exit spread, commission, swap, slippage and gap deviation. A single aggregate cost field must not replace these components.

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
15. **Research matrices are synthetic simulations; live trading uses one frozen configuration.**
16. **Broker-native protective SL is mandatory for live deployment where supported.**
17. **All OHLC-derived logic uses one declared bar price source; executable P/L uses Bid/Ask.**
18. **Every research run is reproducible from its DataManifest.**

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

New entries are allowed only while the symbol is actually tradeable according to the broker symbol-session schedule.

StrategyEntryWindow = ActualTradeSession ∩ ConfiguredStrategyWindow

The default late-spread block remains `21:30 → next tradable session`.

Do not hard-code a universal market open/close; obtain the tradable schedule from MT5 symbol session data.

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

MT5 documentation states that real ticks are the preferred high-fidelity tester source when available, but affected intervals can fall back to generated ticks. The final report must expose actual coverage rather than claiming 100% real-tick history.

Pre-registered data gates:

MaxFallbackMinuteShare = 1%
MaxCriticalDataGapMinutes = 0

A run exceeding these gates is DATA-FAILED unless an exception was documented before interpreting results.

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
- declared SignalBarPriceSource

All OHLC-derived logic (sweep, swing, equal levels, ATR, HTF structure) must use the same declared bar price source. MidPrice is reserved for the explicitly named research-stop variant only.

Opening:

- Long = Ask
- Short = Bid

Closing:

- Long = Bid
- Short = Ask

No midpoint execution for actual P/L.

## 1.7 Cost and execution model

The research engine supports:

`Commission`

`Swap`

`Spread`

`Slippage`

`Latency`

Explicit Inputs:

`SlippageMode = NONE` (default baseline)

`EntrySlippagePoints = 0`

`ExitSlippagePoints = 0`

`LatencyMode = ZERO` (default baseline)

`FixedExecutionDelayMs` exists for controlled research stress tests.

The baseline does not invent historical slippage values. Any non-zero slippage/latency assumption must be explicitly shown in the run configuration and report.

Commission must be configurable by dated schedule or current-condition preset.

For the FundedNext preset, the current official XAUUSD metals commission schedule is represented as a configurable formula rather than permanently hard-coded business logic.

Historical backtests must report whether they use:

- current-condition costs applied uniformly, or
- a dated historical commission schedule.

The research report must never present current costs applied retrospectively as if they were historical broker costs.

### Entry spread / cost admission gate

Inputs:

MaxEntrySpreadEnabled = true
MaxEntrySpreadStrategyPips = 3.0
MaxEntrySpreadToInitialRiskPct = 25%
MaxEntryCostR = 0.10R

These are pre-registered research defaults, not optimality claims. They may not be tuned from OOS.

A candidate is rejected before admission when the observed entry spread or ex-ante measurable cost violates the frozen gate. Rejected candidates remain in the ledger with a rejection reason. Numeric thresholds are frozen before OOS.

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

It is an internal strategy budget and does not replace the external AccountRuleEngine. For compliance, the external account-rule engine takes precedence.

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

If enabled, `ProfitTargetBasis = NET_EQUITY` and floating P/L is valued on executable quotes. This is a policy control, not a strategy-quality metric.

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

## 1.14 Macro-event and spread observability

News is first a stratification variable, not an assumed predictive edge.

Inputs:

NewsMode = OBSERVE_ONLY
NewsBlockMinutesBefore = 15
NewsBlockMinutesAfter = 15
NewsImportance = HIGH

A blocking mode is allowed only when the event-calendar source, timestamp basis, importance mapping and missing-data behavior are validated and frozen. Without a validated calendar, remain in OBSERVE_ONLY.

Spread is separately reported by bucket even when the spread filter is OFF.

## 1.15 Development event-study replication

Repeat the lightweight event study over 2020-07-01 → 2024-12-31 with 2025 excluded. This tests whether the raw sweep/reclaim behavior is unique to the 2026 discovery sample.

No optimization is allowed.

The event study also reports fixed forward horizons such as 1, 3, 5, 10 and 20 completed bars, plus first-barrier outcomes when valid stop/target references exist. Horizon definitions are frozen before analysis.

## 1.16 Phase-1 foundation gate

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

All four exist as independent Inputs. They are price-level proxies, not direct order-book observations:

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

## 2.6A Multi-pool sweep policy

A single large candle can cross multiple non-clustered price-level proxies. The engine must not silently create multiple trades from one candle.

Input:

MultiPoolSweepPolicy = FIRST_CROSSED_LEVEL

Alternative research-only variant:

DEEPEST_PENETRATION_LEVEL

Only one policy is active per scenario and the policy ID is stored in the ledger.

## 2.6B Equal-level tolerance modes

Baseline:

EqualLevelToleranceMode = FIXED_PIPS

ATR_NORMALIZED may exist only as a separately declared research variant and may not be chosen after observing results.

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

If confirmation fails, the setup expires. If the confirmation entry timestamp falls outside StrategyEntryWindow or the symbol is not tradeable, the pending setup expires without entry.

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

This MidPrice trigger is RESEARCH ONLY.

### Live execution

LiveStopMode = BROKER_NATIVE_QUOTE_SL

The live adapter must place a broker-native protective SL where the venue permits it. A virtual-only stop is not an acceptable sole production safety mechanism.

The ledger stores StopModel = MID_RESEARCH or NATIVE_QUOTE so the two performance series cannot be mixed silently.

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

`PlannedRisk1R` = modeled loss between executable entry and initial stop under the selected execution profile, plus only costs deterministically known at admission.

For `RESEARCH_MID_STOP`, position sizing includes the declared stop-execution spread buffer so the R unit is not based on a midpoint trigger while ignoring the executable opposite quote.

For `LIVE_NATIVE_STOP`, sizing uses the broker-native quote-side stop plus declared slippage/gap stress.

Store separately:

`PlannedRisk1R`
`RealizedStopLossR`
`ExecutionDeviationR`

A MidPrice stop trigger followed by a worse executable Bid/Ask exit must never be reported as exactly -1R merely because the reference level was crossed.

Use OrderCalcProfit / equivalent symbol-specific economics rather than a hard-coded pip-value shortcut. Future spread, slippage and swap are not treated as knowable at entry.

The R amount is dynamic. RiskBasis = START_OF_BROKER_DAY_EQUITY.

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

TargetGrossProfit = TP_R × RiskAmount1R

The TP price is solved in the executable exit-quote domain using the exact entry quote and known admission-time costs.

Long TP is triggered from Bid.

Short TP is triggered from Ask.

Future exit spread, slippage and swap are not treated as knowable when constructing a static TP price; they are applied at execution and reported in NetR.

The report distinguishes TP_PRICE_HIT from NET_TARGET_REACHED.

The report separately retains:

`GrossPriceR`

`GrossR`

`CostsR`

`NetR`

so the effect of costs is visible rather than hidden.

## 3.8 Break-even definition

The matrix labels BE R1/BE R2/BE R3/BE R4 mean activation at the specified positive price-R threshold under executable quote semantics.

BETriggerBasis = PRICE_R

BE trigger condition:

`CurrentExecutableProfit / PlannedRisk1R >= BETriggerR`

where CurrentExecutableProfit uses Bid for Long and Ask for Short.

After activation, move to a cost-neutral break-even reference only when legal under symbol stop/freeze constraints. Otherwise record BE_BLOCKED_BY_SYMBOL_RULE.

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

ReEntryCooldownBars = 1
MaxReEntriesPerPoolPerDay = 3

These are anti-churn guardrails and are frozen before OOS.

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

## 4.3A Filter D — Macro News

Inputs:

UseNewsFilter = false
NewsBlockMinutesBefore = 15
NewsBlockMinutesAfter = 15
NewsImportance = HIGH

Default is OFF / OBSERVE_ONLY. Blocking is permitted only with a validated event calendar and frozen mapping of USD-sensitive high-impact events.

## 4.3B Filter E — Spread / Execution Quality

Inputs:

UseSpreadFilter = true
MaxEntrySpreadToInitialRiskPct

This is a transaction-cost gate, not a predictive feature. Rejected opportunities remain in the candidate ledger.

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

In Full Matrix mode, all 15 TP/BE scenarios run against the same single market-data traversal inside the Research Simulator. No scenario may place live orders.

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
- Median/P90/P99 NetR
- Drawdown duration
- Recovery factor
- Return concentration by day/month/year
- Time-in-market
- Margin utilization
- Prop-rule breach and near-breach counts
- Candidate rejection counts by reason

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

## 6.2 Deterministic state-machine fixtures

Before long historical runs, blocking fixtures must cover:

- valid short sweep
- valid long sweep
- wrong-side candle open
- spread expansion with unchanged MidPrice
- spread contraction with unchanged reference price
- TP/SL event ordering
- BE trigger followed by stop-out
- duplicate source tags inside one pool
- one large candle crossing two non-clustered pools
- daily risk reservation
- restart with open trade
- market-closed boundary
- tick-size and volume-step rounding

Each fixture has an expected ledger and is a blocking test.

Runtime invariants include:

ReservedWorstCaseRiskR <= RemainingDailyRiskBudget
ConsumedPool -> no duplicate same-event trade
ConfirmedSwing -> no future information
LivePositionState == BrokerReconciledPositionState

## 6.3 Multiple-testing-aware validation

When candidate selection is performed, use a suitable multiple-testing-aware method such as White's Reality Check and/or Hansen's SPA in addition to Deflated Sharpe / PBO diagnostics.

When outcome windows overlap, use purging/embargo or equivalent temporal leakage control. Random K-fold is prohibited for overlapping financial labels.

## 6.4 Python/reference reconciliation

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

## 6.5 Bootstrap and Monte Carlo

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

## 6.6 Multiple-testing control

The project deliberately contains multiple predefined scenarios.

Therefore:

- every declared scenario is counted as a research trial
- the number of trials is reported
- no hidden configurations may be added after seeing results without restarting the declared trial count
- Deflated Sharpe Ratio / Probabilistic Sharpe diagnostics may be reported where statistically appropriate
- Probability of Backtest Overfitting / CSCV diagnostics are used when a configuration-selection exercise becomes large enough to justify them

The 15 TP/BE matrix is treated as a **research matrix**, not as permission to optimize 15 results and keep only the best one.

## 6.7 Parameter sensitivity

Predeclare small, non-optimized sensitivity checks around structural parameters.

At minimum, test controlled perturbations such as:

- SL extra buffer: 2 / 3 / 4 strategy pips
- Equal-level tolerance: 2 / 3 / 4 strategy pips

Sensitivity results are reported as stability ranges.

The engine must not search arbitrary hundreds of parameter values.

## 6.8 Execution stress validation

Run controlled robustness variants for:

- zero slippage / zero latency
- small fixed adverse entry slippage
- small fixed adverse exit slippage
- combined entry/exit slippage
- fixed execution delays where the tester/model supports them

These are stress tests, not historical claims. The exact stress values must be declared before the run and included in the final report.

## 6.9 Regime robustness

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

## 6.10 Secondary-symbol robustness

After XAUUSD core rules are frozen, the same deterministic engine may be run on XAGUSD as a **robustness check**, not as a parameter-selection tool for XAUUSD.

The secondary symbol result cannot be used to alter the already-frozen XAUUSD OOS rule set.

## 6.11 Data-source robustness

Primary research remains the target broker/tester feed because execution spread and symbol rules are broker-specific.

A secondary historical source may be used only for:

- gap/data continuity audit
- broad structural event comparison
- robustness diagnostics

It must not be mixed tick-by-tick with the target broker feed.

## 6.12 Experimental freeze

After the experimental phase:

`2026-01-01 → 2026-09-28`

the strategy configuration intended for the extended run is frozen.

Any material strategy-rule change after seeing extended-development performance creates a new research version and must not be silently folded into the old version.

## 6.13 Extended development test

Run the frozen version on:

`2020-07-01 → 2024-12-31`

and:

`2026-01-01 → 2026-09-28`

Exclude all of 2025.

## 6.14 Paired execution-profile robustness

Evaluate the frozen strategy under:

1. RESEARCH_MID_STOP
2. LIVE_NATIVE_STOP

No deployment decision may rely only on the research-only MidPrice trigger.

## 6.15 Final OOS

Run the frozen configuration on:

`2025-01-01 → 2025-12-31`

No OOS observation may feed:

- rule selection
- filter selection
- parameter changes
- scenario pruning
- code changes intended to improve the OOS result

## 6.16 Final research package

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

# Phase 7 — Production Hardening, Shadow Run & True Forward Validation

## Goal

Prove the EA remains correct and safe under operational failures before live deployment.

## 7.1 Mandatory live controls

- broker-native protective SL where supported
- account/rule-profile daily-loss hard stop
- maximum concurrent positions and symbol exposure
- stale-tick detector
- spread-anomaly kill switch
- trading-session/permission check
- duplicate-order protection
- magic-number isolation
- restart/reconnect recovery
- broker-position reconciliation
- execution reconciliation through OnTradeTransaction
- emergency disable switch
- structured logs

## 7.2 Fault-injection tests

Test:

- terminal restart with open position
- network interruption around submission
- delayed or rejected order
- duplicate/partial transaction notifications
- symbol becoming non-tradeable
- spread jump
- missing ticks
- server-time/DST transition

Recovery must use broker-confirmed state, not an in-memory assumption.

## 7.3 True forward validation

Starting 2026-09-29, the frozen configuration enters:

SHADOW -> DEMO -> LIVE_AFTER_APPROVAL

Forward data records actual spread, entry/exit slippage, latency, rejects, downtime, restarts and reconciliation errors. These observations may inform a future research version but never retroactively alter the 2025 OOS.

## 7.4 Deployment gate

Deployment requires:

- hard research gates passed
- native-stop robustness documented
- operational fault tests passed
- exact account/rule profile verified
- shadow/demo behavior reconciled
- no unresolved blocking defect

## 7.5 Release artifact

Store:

- code commit SHA
- roadmap hash
- exact inputs
- symbol specification snapshot
- deployment configuration hash
- test logs
- known limitations

---

# Research & Implementation References

The roadmap is informed by:

- MQL5 Strategy Tester / real ticks: https://www.mql5.com/en/docs/runtime/testing
- MQL5 symbol properties: https://www.mql5.com/en/docs/constants/environment_state/marketinfoconstants
- MQL5 OrderCalcProfit: https://www.mql5.com/en/docs/trading/ordercalcprofit
- MQL5 OrderCalcMargin: https://www.mql5.com/en/docs/trading/ordercalcmargin
- MQL5 OrderCheck: https://www.mql5.com/en/docs/trading/ordercheck
- MQL5 OnTradeTransaction: https://www.mql5.com/en/docs/event_handlers/ontradetransaction
- MQL5 symbol trading-session schedule: https://www.mql5.com/en/docs/marketinformation/symbolinfosessiontrade
- Osler, Currency Orders and Exchange Rate Dynamics: https://onlinelibrary.wiley.com/doi/10.1111/1540-6261.00588
- Cai, Cheung & Wong, What Moves the Gold Market?: https://doi.org/10.1002/1096-9934(200103)21:3<257::AID-FUT4>3.0.CO;2-W
- Batten & Lucey, Volatility in the Gold Futures Market: https://doi.org/10.1080/13504850701719991
- Bailey & Lopez de Prado, The Deflated Sharpe Ratio: https://doi.org/10.3905/jpm.2014.40.5.094
- Bailey et al., Probability of Backtest Overfitting: https://papers.ssrn.com/sol3/papers.cfm?abstract_id=2326253
- Sullivan, Timmermann & White, Data-Snooping, Technical Trading Rule Performance, and the Bootstrap: https://doi.org/10.1111/0022-1082.00163
- Adam H. Grimes, How to Trade Support and Resistance Levels: https://adamhgrimes.com/how-to-trade-support-and-resistance-levels/
- FundedNext server time: https://help.fundednext.com/en/articles/8019672-what-is-fundednext-s-server-time
- FundedNext daily-loss calculation: https://help.fundednext.com/en/articles/8019811-how-can-i-calculate-the-daily-loss-limit
- FundedNext metals commission: https://help.fundednext.com/en/articles/10701368-what-are-the-commission-charges-for-stellar-challenges-and-fundednext-accounts

Practitioner sources are for hypothesis generation and terminology; empirical claims must be backed by research-grade evidence or platform/broker documentation.

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
