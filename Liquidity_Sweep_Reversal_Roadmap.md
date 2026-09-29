# Liquidity Sweep Reversal — Implementation & Research Roadmap

**Document name:** `Liquidity_Sweep_Reversal_Roadmap.md`  
**Status:** FINAL ROADMAP — implementation-ready research and production specification  
**Research audit date:** 2026-09-28  
**Baseline symbol:** XAUUSD  
**Baseline broker context:** FundedNext / MT5  
**Research TimeframeSet default:** M5, M15, H1  
**Live signal timeframe:** exactly one fixed member of the declared TimeframeSet  
**Research risk default:** 0.50% per trade = 1R  
**Default Daily Loss Guard:** ON, 3R  
**Default Max Concurrent Positions:** 3  
**Default Daily Profit Target:** OFF, 9R  
**Rapid iteration sample:** 2026-01-01 → 2026-06-30  
**Full discovery/experimental range:** 2026-01-01 → 2026-09-28  
**Extended development range:** 2020-07-01 → 2024-12-31 and 2026-01-01 → 2026-09-28  
**Historical blind holdout:** 2025-01-01 → 2025-12-31  
**True forward OOS:** 2026-09-29 → onward

---

# 0. Research Decisions Locked Before Implementation

## 0A. Research & Governance — Binding Rules

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

1. eliminate configurations failing hard/development gates;
2. among survivors prefer lower rule complexity;
3. if tied, prefer lower tail risk/drawdown under the declared stress set;
4. freeze the pre-registered Primary Configuration before the untouched holdout;
5. use the untouched holdout only for pass/fail confirmation and distributional reporting — never for ranking, tie-breaking, pruning or parameter changes;
6. when multiple timeframes are preregistered, each timeframe is a separate research trial; do not choose a “best timeframe” by historical performance, and do not use cross-timeframe ranking for deployment selection.

A material candidate introduced after results are seen reopens the holdout process. The single roadmap file is preserved; research state is identified by Git commit, DataManifest and experiment identifiers.

### 0A.3 Research / live separation

Architecture is explicitly:

- Strategy Core — deterministic, side-effect-free signal and lifecycle logic.
- Research Simulator — synthetic multi-scenario execution over one tick stream, including separate preregistered timeframe contexts.
- Live Execution Adapter — one frozen deployment configuration and one fixed signal timeframe only.
- Ledger / Reporting — immutable candidate, event and trade records.

The Full Matrix is research simulation, not fifteen live strategies.

### 0A.4 Liquidity terminology boundary

PDH/PDL, session extremes, swings and equal highs/lows are **price-level proxies**, not direct observations of institutional liquidity or a centralized order book. DOM, if later available, is a separate data source and hypothesis.

### 0A.5 Validation chronology

- 2026-01-01 → 2026-06-30 = rapid iteration / small-sample development
- 2020-07-01 → 2024-12-31 = extended development / robustness
- 2026-07-01 → 2026-09-28 = late-2026 development extension after rapid-iteration gates
- 2025-01-01 → 2025-12-31 = untouched historical OOS
- 2026-09-29 → onward = true forward validation

A material rule change after discovery/development reopens the holdout process and invalidates the prior OOS selection process. The roadmap remains this same file.

### 0A.6 Reproducibility

Every run produces a DataManifest containing code SHA, roadmap hash, MT5 build, broker/server, account-rule profile, symbol specification, requested/actual range, tick source and fallback coverage, server-time basis, cost/slippage/latency model, scenario IDs, declared trial count, random seeds and ledger checksum.


This section records the binding governance decisions established by the audit. They are part of the specification, not suggestions for implementation.

## 0.1 What is supported by evidence

Academic market-microstructure research supports two relevant facts:

1. Clearly defined support/resistance levels can have measurable intraday turning-point information.
2. Once clustered levels are crossed, stop-loss order flow can also accelerate price in the breakout direction.

Therefore a liquidity sweep/reclaim is a meaningful reversal hypothesis, but a reclaim candle alone is not proof that reversal will continue. The project must keep the unconfirmed reclaim control as a control hypothesis and test one strict confirmation variant separately rather than silently replacing the original hypothesis.

## 0.2 No universal claim that “M1 gold sweeps usually continue”

The repository contains no historical data or trade ledger, so such a claim cannot be established from the repository itself. The engine must determine reversal/continuation behavior empirically from the selected XAUUSD data.

## 0.3 XAUUSD “pip” is explicitly defined

Pip terminology varies by platform/broker. For the FundedNext XAUUSD convention used by this research, the official example treats a 0.10 price movement as 1 pip. Therefore:

`StrategyPipSize = 0.10`

The strategy must never infer the meaning of “pip” from `SYMBOL_POINT` or from another broker’s convention. The actual price distance used by the strategy is always stored numerically.

## 0.4 Stop execution profile

Primary execution/risk model: `LIVE_NATIVE_STOP`.

- Long stop trigger = Bid <= broker-native SL
- Short stop trigger = Ask >= broker-native SL
- Long exit = Bid
- Short exit = Ask

`RESEARCH_MID_STOP` with `MidPrice = (Bid + Ask) / 2` is sensitivity only and is not used for primary acceptance or deployment.

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

## 0B. Strategy Logic — Binding Rules

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

Inputs:

`AccountRuleProfile = FUNDEDNEXT_STELLAR_2STEP`

`AccountInitialBalance = 100000` (research default; exact enrolled balance must be set before live deployment)

`AccountCurrency = USD`

`AccountRuleSafetyBufferR = 0.10R`

The EA must implement AccountRuleEngine with:
- InitialBalance
- DailyLossRate
- DailyLossFloorAmount
- MaximumLossRate
- MaximumLossFloorAmount
- current balance
- current equity
- realized P/L
- floating P/L
- commissions/fees
- reset timestamp
- safety-buffer amount
- near-breach state
- breach state

### Default official FundedNext Stellar 2-Step profile

Current official documentation states a 5% daily loss limit and 10% maximum loss limit for Stellar 2-Step, with the daily rule resetting at 00:00 broker/server time and including closed/running trade results plus commissions, swap and fees. Therefore the frozen research profile is:

`DailyLossRate = 5%`

`DailyLossFloor = -InitialBalance × 0.05`

`MaximumLossRate = 10%`

`MaximumLossFloorEquity = InitialBalance × 0.90`

`DailyNetResult = ClosedTradeResult + CurrentFloatingResult + AccountAppliedCommission + AccountAppliedSwap + AccountAppliedFees`, with no component counted twice when already included by the broker/account record.

Daily reset timestamp = first broker-server timestamp at or after `00:00:00` on the new broker day.

Account breach occurs when either:

`DailyNetResult < DailyLossFloor`

or

`Equity < MaximumLossFloorEquity`.

The AccountRuleSafetyBuffer is:

`AccountRuleSafetyBufferCurrency = AccountRuleSafetyBufferR × DayRiskUnitCurrency`.

Near-breach is entered when the projected distance to either external-rule floor is less than or equal to this buffer; breach state is entered at the actual floor crossing.

Other FundedNext profiles may be supported only as separately declared AccountRuleProfile values with their official rules frozen before the run. No universal FundedNext rule may be assumed.

### 0B.11 News/account-rule treatment

News proximity is always recorded and is not a strategy feature in the core A/B/C matrix.

As of 2026-09-28, current FundedNext documentation permits news trading. For current Stellar funded accounts, trades executed within 5 minutes before or after listed high-impact news are subject to the current News Reward Share Rule: 40% of affected profit is counted while losses remain fully applied. Challenge treatment differs. The selected account model must therefore be frozen in AccountRuleEngine before performance interpretation.

Reports must expose MarketStrategyResult separately from AccountRuleAdjustedResult.

Missing or unvalidated news data = OBSERVE_ONLY, never silently treated as “no news”.

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

All bar-derived structure uses BID consistently. Choosing LAST in a future research study state creates a distinct research study state. Execution remains Bid/Ask-specific.

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

Pre-registered: `MinEconomicEdgeR = 0.05R`.

Final economic acceptance requires the one-sided 95% lower confidence bound of mean NetR to be at or above +0.05R after declared costs and stress, together with all other hard gates.

### 0B.21 Stable event identity

Every candidate receives a stable EventID independent of scenario. Scenario reports may reuse the same EventID, but the underlying market event is immutable.

### 0B.22 Cost attribution

Cost burden is decomposed into entry spread, exit spread, commission, swap, slippage and gap deviation. A single aggregate cost field must not replace these components.

## 0C. Final Strategy / Execution / Risk Closures

These rules close the remaining material loopholes found during the final audit. Where they conflict with any earlier wording, these rules win.

### 0C.1 Frozen Primary Research Configuration

The project must have one explicit baseline configuration before any untouched holdout interpretation. It is a reference hypothesis, not a claim that it is the most profitable configuration.

- Symbol = XAUUSD
- TimeframeSet = M5,M15,H1
- LiveTimeframe = one fixed selected member only
- Each selected research timeframe is a separate preregistered trial with isolated state and reporting.
- SignalBarPriceSource = BID
- LiquiditySourceProfile = ALL_FOUR (PDH/PDL, Previous Session H/L, Confirmed Swings, Equal Highs/Lows)
- EntryMode = RECLAIM_CLOSE
- SingleTP = 2R
- BreakEven = OFF
- Filters A/B/C = OFF
- NewsPolicy = OBSERVE_ONLY
- AccountRuleEngine = APPLY_OFFICIAL_ACCOUNT_RULES
- Spread/Cost Gate = ON
- StopExecutionProfile = LIVE_NATIVE_STOP
- MaxEntrySpreadStrategyPips = 3.0
- MaxEntryKnownNonSpreadCostR = 0.10R
- ReEntryAttempts = 1
- MaxOpenPositionsPerLiquidityPool = 1
- MaxConcurrentPositions = 3
- MaxAggregateOpenWorstCaseRiskR = 3.0R
- MaxDirectionalOpenWorstCaseRiskR = 2.0R
- DailyLossGuard = ON at 3.0R
- DailyProfitTarget = OFF
- TimeExit = OFF
- ScenarioInvalidationExit = OFF
- SameBarOppositeSweepPolicy = NO_TRADE_ON_CONFLICT
- MultiPoolSweepPolicy = FIRST_CROSSED_LEVEL

The Full Matrix and robustness scenarios are research experiments around this frozen baseline. They are never treated as simultaneous live configurations.

### 0C.2 Level-instance identity and immutable pool membership

Every level instance has a stable identity built from its source type, source-instance timestamp/date, polarity and price.

A liquidity pool is immutable after it becomes armed for trade evaluation. Later-confirmed levels may form a new pool instance; they may not retroactively widen, narrow or rewrite an already-armed pool.

### 0C.3 Same-polarity equal-level rule

Equal Highs may cluster only confirmed highs; Equal Lows may cluster only confirmed lows.

A cluster requires:
- at least two distinct confirmed swing instances;
- different confirmation timestamps;
- the declared within-band tolerance;
- no use of a single swing instance twice.

No same-candle dual-pivot shortcut is permitted.

### 0C.4 Exact opening-boundary policy

High-side sweep: PreviousBarClose < PoolLower and SweepOpen < PoolLower.
Low-side sweep: PreviousBarClose > PoolUpper and SweepOpen > PoolUpper.

A sweep candle opening exactly on the liquidity boundary is classified OPEN_ON_LIQUIDITY and rejected.

This overrides the earlier <= / >= boundary wording.

### 0C.5 Partial-pool penetration is observed but not traded

A candle that penetrates only part of a pooled band is recorded as PARTIAL_POOL_SWEEP.

It is not a valid baseline trade event. This keeps near-valid opportunities visible for later hypothesis testing without silently changing the core definition.

### 0C.6 Opposite-direction conflict policy

If the same SignalTimeframe candle creates valid high-side and low-side sweep events that would produce opposite-direction setups, the baseline takes no trade from that candle and records CONFLICTING_SWEEP_SAME_BAR.

A later implementation with a reliable tick-sequence basis may report the sequence, but it may not silently replace the frozen baseline rule.

### 0C.7 Confirmation and pending-setup conflict

For NEXT_BAR_EXTREME_CONFIRM, only the single immediately following candle can confirm.

If the confirmation candle independently creates an opposite-direction sweep, the pending setup expires with CONFIRMATION_CONFLICT. A failed confirmation never reopens.

### 0C.8 Per-pool concurrency and re-entry lifecycle

Only one live position may be open against one liquidity-pool instance at a time.

A stop-loss exit may unlock one new attempt only after a new valid sweep event of the same pool instance.

TP, BE stop, time exit or invalidation exit terminates that setup lifecycle. A fresh setup requires a new valid sweep event.

### 0C.9 Canonical daily-risk admission

DayRiskUnitCurrency = StartOfBrokerDayEquity × RiskPerTradePercent.

DailyLossFloor = StartOfBrokerDayEquity − (MaxDailyLossR × DayRiskUnitCurrency).

`DeclaredRiskExecutionBufferPoints = max(EntrySlippagePoints, ExitSlippagePoints)` when a non-zero fixed-adverse slippage stress is active; otherwise = 0.

For an already-open trade, calculate only the incremental loss from the current executable quote to its currently valid stop plus the loss represented by DeclaredRiskExecutionBufferPoints. Use the selected native executable quote side and symbol economics; do not subtract the full original risk a second time from current equity.

For a proposed trade:

`NewTradeWorstCaseLoss = loss from the admission-time executable entry to the valid stop + declared execution/slippage buffer + known admission-time costs`.

`ProjectedWorstCaseEquity = CurrentEquity − Σ IncrementalWorstCaseOpenLoss − NewTradeWorstCaseLoss`.

Admission requires `ProjectedWorstCaseEquity >= DailyLossFloor`, plus MaxAggregateOpenWorstCaseRiskR, MaxDirectionalOpenWorstCaseRiskR and all external AccountRuleEngine gates.

The internal strategy risk budget and the external account-rule budget are never merged into one number; both must independently pass.

### 0C.10 Stress-aware position sizing

Position size is solved against the declared worst-case loss budget, including:

- native executable stop path;
- `DeclaredRiskExecutionBufferPoints`;
- configured adverse slippage;
- known admission-time commission/fees;
- symbol-specific economics from `OrderCalcProfit` or equivalent.

Baseline buffer = 0 points and baseline slippage = 0. Stress runs use only the pre-registered values in Phase 1. No undocumented “pressure”, “safety” or execution buffer may be introduced in code.

### 0C.11 Exact signal-close to executable-tick rule

When an entry is defined at bar close, execution uses the first executable tick at or after the completed bar-close timestamp.

Record SignalCloseTimestamp, FirstExecutableTickTimestamp and SignalToEntryDelaySeconds.

A later tick caused by a market closure is not treated as an immediate bar-close fill; normal session/risk gates still apply.

### 0C.12 Exact time-exit indexing

When MaxHoldingBars = N, and entry occurs on the first executable tick after bar B closes, the time exit is evaluated on the first executable tick after bar B+N closes.

N = 1 means one full completed signal bar after entry.

### 0C.13 Scenario invalidation exit

Baseline: ScenarioInvalidationExit = OFF.

Research-only variant: Long invalidates when a completed SignalTimeframe bar closes at or below PoolUpper; Short invalidates when a completed SignalTimeframe bar closes at or above PoolLower.

Execution occurs on the first executable tick after that bar close. The variant is tested separately.

### 0C.14 Exact MAE/MFE definitions

Long: MFE = max(Bid_t − EntryAsk); MAE = max(EntryAsk − Bid_t, 0).
Short: MFE = max(EntryBid − Ask_t); MAE = max(Ask_t − EntryBid, 0).

Evaluate only from entry to final exit. Also report MFE_R and MAE_R against PlannedRisk1R.

### 0C.15 Minimum independent sample

Inferential acceptance requires both MinTradesForInferentialStats >= 200 and MinIndependentTradingDays >= 60.

Block bootstrap/resampling is performed at day/session level where practical so clustered intraday trades are not treated as independent observations.

### 0C.16 Level-age policy

No hidden age cutoff may be added to improve apparent performance.

Baseline eligibility is determined by source-specific lifecycle and freshness. An implementation memory cap is permitted only if it is proven not to alter the eligible event set.

### 0C.17 Closed-session, holiday and Monday-gap behavior

Existing positions may remain open across a non-trading interval unless the selected account/risk policy forbids it.

Pre-registered `GapExecutionRule = FIRST_EXECUTABLE_QUOTE_NO_INTERPOLATION`.

- If a gap crosses one barrier, exit at the first executable Bid/Ask after the gap, not at the barrier price.
- If a gap crosses both TP and SL and the path is unknowable, classify `GAP_CROSSED_BOTH_BARRIERS`, assign the conservative STOP outcome, and execute at the first executable quote.
- Monday/holiday/reopen gaps are reported separately.
- A closed-market gap touching a level does not create a new trade.

### 0C.18 Deterministic HTF structure filter

Bullish HTF structure requires LatestHigh > PriorHigh and LatestLow > PriorLow using the latest two confirmed highs/lows. Bearish requires LatestHigh < PriorHigh and LatestLow < PriorLow. Otherwise = NEUTRAL.

No unconfirmed HTF swing participates.

### 0C.19 Prominence is diagnostic unless separately pre-registered

SwingProminence is not an implicit filter.

A prior-known diagnostic may use PriorOppositeSwingDistanceATR = abs(CurrentSwingPrice − NearestPriorConfirmedOppositeSwingPrice) / ATR_at_confirmation. If none exists, store NA. Future swings may not be used for live eligibility.

### 0C.20 Cost-neutral BE reference

Break-even uses a declared executable-price basis and solves the stop price that offsets known deterministic entry costs and commission under the selected accounting model. Future unknown swap and future execution deviation are excluded and recorded separately.

If the computed BE stop violates broker stop/freeze constraints, the BE transition is rejected and logged rather than silently rounded.

### 0C.21 Barrier-ordering rule

If the tick sequence determines which barrier was crossed first, the first crossed barrier wins.

If both are crossed by the same observed tick and order cannot be determined, classify `AMBIGUOUS_EXECUTION`, apply `BarrierAmbiguityRule = STOP_WINS`, and execute at the first executable quote.

OHLC-only assumptions may not manufacture intra-bar order.

### 0C.22 One permanent roadmap file

The permanent roadmap filename is Liquidity_Sweep_Reversal_Roadmap.md.

Future updates append to the Roadmap Update Log. The roadmap is never renamed or version-numbered. Reproducibility uses Git commit SHA, file hash, DataManifest and experiment IDs.

## Phase Map — One Logical Work Package Per Chat

The roadmap is split into 9 medium-sized phases. Each is a coherent, testable work package suitable for one dedicated chat without turning the program into dozens of tiny tasks.

| Phase | Work package | Main dependency |
|---|---|---|
| 1 | Data, time, symbol and execution contract | None |
| 2 | Liquidity model, exact sweep events and Python reference foundation | Phase 1 |
| 3 | Pre-implementation event study and early-stop decision | Phase 2 |
| 4 | Entry, SL, TP, BE, re-entry and trade lifecycle | Phases 2–3 |
| 5 | Strategy filters and optional risk extensions | Phase 4 |
| 6 | Single-pass backtest, scenario engine, ledger and reporting | Phases 4–5 |
| 7 | Deterministic validation, reference reconciliation and statistical tests | Phase 6 |
| 8 | Robustness, freeze, development and historical holdout | Phase 7 |
| 9 | Production hardening, shadow/demo and true forward validation | Phase 8 |

**Chat boundary rule:** each chat works only on its assigned phase and its declared outputs. A later phase may consume earlier outputs but must not silently rewrite earlier strategy rules.

# Non-Negotiable Architecture Rules

These rules apply to every phase.

1. **Broker Server Time is the source of truth.** No manual UTC/DST conversion is used for strategy session logic.
2. **TimeframeSet is an Input.** Default `M5,M15,H1`; allowed values are `M1/M5/M15/M30/H1`. Research may execute multiple selected timeframes in one pass; live execution uses exactly one fixed timeframe.
3. **Execution is Tick based.** Signal detection may be candle based, but entry/exit execution uses the actual tick stream.
4. **Primary research tester:** `Every tick based on real ticks`.
5. **No average/bar spread for execution.** The exact Bid/Ask from the event tick is used.
6. **No look-ahead.** A swing or HTF structure element is usable only after all candles required to confirm it have closed.
7. **No hidden rules.** Entry, confirmation, liquidity lifecycle, SL, TP, BE, re-entry, risk, sessions, costs, and reporting all have deterministic definitions.
8. **2025 is permanently reserved for OOS** in the extended research design. It cannot be used to select rules, filters, parameters, or scenarios.
9. **Single market-data pass for reporting.** Monthly/yearly/full-period reports must come from the same ledger, not separate backtests.
10. **Scenario isolation.** Each scenario has independent account/trade state while sharing the one market-data stream.
11. **Multi-timeframe research isolation.** Every selected timeframe has its own positions, daily risk, max positions, equity, drawdown, trade ledger and event ledger. No state is shared between timeframes; only the normalized tick stream is shared.
12. **Live timeframe isolation.** Live trading runs one fixed timeframe only; multi-timeframe execution is prohibited.
13. **No automatic “best configuration” selection.** The engine reports predefined configurations; it must not silently optimize and select the highest historical result.
14. **Every code-changing phase updates this roadmap.**
15. **Roadmap filename and relative path never change:** `Liquidity_Sweep_Reversal_Roadmap.md`.
16. **Changed files keep their original filenames and relative paths. Unchanged files are untouched.**
17. **Research matrices are synthetic simulations; live trading uses one frozen configuration.**
18. **Broker-native protective SL is mandatory for live deployment where supported.**
19. **All OHLC-derived logic uses one declared bar price source; executable P/L uses Bid/Ask.**
20. **Every research run is reproducible from its DataManifest.**

---

# Phase 1 — Data, Time, Symbol & Execution Contract

## Goal

Establish the exact, reproducible market-data and broker/execution contract consumed by every later phase. This phase does not build the strategy itself.

## 1.1 TimeframeSet and live timeframe

Inputs:

`TimeframeSet`

Default:

`M5,M15,H1`

Allowed selectable values:

`M1 / M5 / M15 / M30 / H1`

Parsing is comma-separated, case-insensitive and whitespace-tolerant. Empty entries, unsupported values and duplicate values are invalid and must fail initialization; duplicates are not silently removed. Canonical storage/reporting order is the fixed enum order: M1, M5, M15, M30, H1.

The research tester may process one or multiple selected timeframes from the same tick stream, but each timeframe runs in a completely isolated research state.

Input:

`LiveTimeframe`

Default:

`M5`

LiveTimeframe must be exactly one member of TimeframeSet. Live trading executes only that one fixed timeframe; simultaneous multi-timeframe live execution is prohibited.

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

All session times are interpreted in Broker Server Time and all window ends are **exclusive**.

### Mode 1 — Full Day Except Late Spread Window (default)

The base strategy window is the union of all broker-declared trading sessions for the requested timestamp range.

At each broker date, define `LateBlockStart = 21:30`. Define `NextTradableSessionStart` as the earliest broker-session start time strictly after 21:30 across the same date or the next calendar dates. The search continues until a valid session is found.

The late-spread block is:

`[21:30, NextTradableSessionStart)`.

If another trading session begins later the same date, the block ends at that later session start. Otherwise it ends at the first trading-session start on a later broker date. Thus “next tradable session” has an exact schedule-derived meaning and never assumes a universal market close.

`StrategyEntryWindow = ActualTradeSession ∩ [not in the late-spread block]`.

### Mode 2 — NY Window

Configured strategy window:

`[16:30, 21:30)` Broker Server Time.

`StrategyEntryWindow = ActualTradeSession ∩ [16:30,21:30)`.

### Mode 3 — Custom

Inputs:

`TradeStartTime`

Default: `00:00`

`TradeEndTime`

Default: `24:00`

`24:00` is a valid end-of-day sentinel and is permitted only for TradeEndTime.

Window construction:

- if Start < End: same-day window `[Start,End)`;
- if Start > End: wrap-midnight window `[Start,24:00) ∪ [00:00,End)`;
- if Start = End, the custom window is invalid except `00:00 → 24:00`, which means the full broker day.

For every mode:

`StrategyEntryWindow = ActualTradeSession ∩ ConfiguredStrategyWindow`.

ActualTradeSession is obtained from MT5 `SymbolInfoSessionTrade` for the symbol and broker weekday; no hard-coded exchange schedule is substituted. This same intersection rule applies to Modes 1, 2 and 3.

Session filtering controls **new entries only**.

Existing positions are not closed merely because the session ends.

## 1.4 Tick/data-quality audit

Required manifest inputs:

`AuditRequestedStartDate`

Default: `2026-01-01`

`AuditRequestedEndDate`

Default: `2026-06-30`

These inputs are a manual declaration of the MT5 Strategy Tester date range because the EA must not assume it can read the tester's requested start/end settings directly. The Run Card must copy the same dates from the tester UI before each historical run. The EA records actual first/last processed tick timestamps and reports any mismatch between declared and observed coverage; it never infers the requested tester range from runtime data.

The engine must verify and report:

- declared requested date range
- actual first/last available/processed tick
- tick timestamp monotonicity
- duplicate timestamps
- missing intervals
- impossible/non-positive spreads
- negative or corrupted price values
- M1 OHLC vs raw-tick reconciliation
- selected SignalTimeframe OHLC construction/reconciliation
- auditable real-tick availability
- minutes with no usable raw real-tick records
- minutes whose raw tick data fails M1 OHLC reconciliation
- symbol specification snapshot at test start
- trading-session specification
- tick size
- point size
- volume minimum/maximum/step
- stops level
- freeze level
- contract size
- tick value

MT5 documents that real-tick testing can fall back to generated ticks when a minute has no tick data or when tick data for a minute contradicts the minute bar and is discarded. The EA cannot treat an undocumented internal tester flag as proof of the exact runtime tick-generation path. Therefore the roadmap uses the auditable class **PotentialFallbackMinute**: a scheduled tradeable minute with either no usable raw real-tick record or an M1/tick reconciliation failure. Reports must never label this class as confirmed generated ticks unless the platform explicitly exposes such a flag.

Operational definitions:

`AuditEligibleMinute` = one broker-scheduled tradeable minute inside the declared requested range.

`PotentialFallbackMinute` = AuditEligibleMinute with zero usable raw real-tick records OR failed M1 OHLC reconciliation.

`PotentialFallbackMinuteShare = PotentialFallbackMinute / AuditEligibleMinute`.

`CriticalDataGap` = a gap between consecutive usable raw ticks longer than `CriticalDataGapThresholdMinutes` while the symbol is continuously tradeable; scheduled session breaks, weekends and closed-market intervals are excluded.

Pre-registered data gates:

`MaxFallbackMinuteShare = 1%`

`CriticalDataGapThresholdMinutes = 5`

`MaxCriticalDataGapCount = 0`

A run exceeding either gate is DATA-FAILED unless the exception was frozen before results are interpreted.

The audit must distinguish **no-tick/sparse data**, **potential tester fallback**, **closed-market intervals** and **session breaks** rather than counting them as one generic missing-data category.

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

### Commission — frozen baseline preset

Input:

`CommissionMode = FUNDEDNEXT_OFFICIAL_METALS`

Official published FundedNext metals formula currently used for the baseline:

`CommissionCurrency = VolumeLots × ContractSize × OpeningPrice × 0.0016%`

For the published XAU/USD example, ContractSize = 100 and the stated 1-lot commission at an opening price of 4466.22 is $7.14. The roadmap applies the published formula once to the opening transaction and never manually doubles it. Any additional commission component is applied only when explicitly present in the dated broker/account schedule or in actual tester/account deal records.

Research Inputs:

`CommissionRatePercent = 0.0016%`

`CommissionContractSizeSource = SYMBOL_TRADE_CONTRACT_SIZE` unless the frozen broker schedule explicitly specifies another contract size.

`CommissionPricingBasis = OPEN_PRICE`.

The report stores the applied commission source and currency amount per deal/trade.

Historical backtests must label whether they use the current official FundedNext schedule or a dated historical schedule. Current-condition costs must never be presented as historical broker costs without that label.

### Slippage

Allowed:

`SlippageMode = NONE | FIXED_ADVERSE_POINTS`

Default:

`NONE`

Defaults:

`EntrySlippagePoints = 0`

`ExitSlippagePoints = 0`

Adverse direction is deterministic:

- Long entry: Ask + EntrySlippagePoints
- Short entry: Bid - EntrySlippagePoints
- Long exit: Bid - ExitSlippagePoints
- Short exit: Ask + ExitSlippagePoints

Pre-registered stress values for controlled sensitivity are 1, 2 and 5 symbol points, tested as separate declared scenarios. These values are not optimized.

### Latency

Allowed:

`LatencyMode = ZERO | FIXED_MS`

Default:

`ZERO`

`FixedExecutionDelayMs = 0`

Pre-registered stress values are 100, 250 and 500 ms as separate declared scenarios. Any non-zero latency/slippage assumption must appear in the Run Card and report.

The baseline does not invent historical slippage or latency values.

### Entry spread / cost admission gate

Inputs:

MaxEntrySpreadEnabled = true
MaxEntrySpreadStrategyPips = 3.0
MaxEntryKnownNonSpreadCostR = 0.10R

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

DailyLossGuardEnabled = true

MaxDailyLossR = 3.0

MaxConcurrentPositions = 3

The daily guard is a new-risk admission guard, not a floating-loss forced exit. The canonical admission calculation is the incremental worst-case equity method defined in 0C.9, and the external AccountRuleEngine takes precedence.

Admission must satisfy the projected daily-loss floor and the aggregate/directional worst-case exposure ceilings. Floating P/L alone does not force-close an existing position.


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


## 1.12 Phase 1 implementation closures (binding)

Implementing Phase 1 exposed these gaps. Under 0B.13 each one is closed here, in the specification, and is not left to code discretion. Where these rules conflict with earlier Phase 1 wording, these rules win.

1. **Run context.** In the Strategy Tester the EA runs as the Research Simulator and processes every TimeframeSet member, each with isolated state. On a live chart it runs as the Live Execution Adapter and processes only `LiveTimeframe`. The context is derived from the platform (`MQL_TESTER`) and cannot be changed by an input.
2. **Broker session intervals.** A `SymbolInfoSessionTrade` interval whose end is at or before its start wraps midnight. It becomes `[from, 24:00)` on its weekday plus `[00:00, to)` on the next weekday. That next-day part is a continuation, not a new "session start", for `NextTradableSessionStart`. A zero-length interval is ambiguous and fails initialization.
3. **Declared closed-market calendar.** Holidays and unscheduled closures are not in `SymbolInfoSessionTrade`. Input `ClosedMarketCalendarFile` (a Common-Files CSV, `start,end_exclusive,reason`, Broker Server Time, default empty) declares them before the run. Declared minutes are not `AuditEligibleMinute` and are excluded from `CriticalDataGap`. This file is the only permitted form of the "exception frozen before results are interpreted" in 1.4.
4. **Audit range.** `AuditRequestedEndDate` is an inclusive broker date, so the audited range is `[StartDate 00:00, EndDate+1 00:00)`. Coverage mismatch means that processed ticks fall outside the declared range. The distance from the declared start to the first tick, and from the last tick to the declared end, is reported but is not by itself a gate.
5. **Usable raw tick.** A raw tick is usable when Bid and Ask are finite, `Bid > 0`, `Ask > 0` and `Ask > Bid`. PotentialFallbackMinute is reported in three sub-classes: `NO_TICKS_NO_BAR` (no-tick/sparse data), `NO_TICKS_WITH_BAR` (potential tester fallback) and `RECONCILIATION_FAILED`. All three count toward `MaxFallbackMinuteShare`. M1 reconciliation compares the minute's open/high/low/close, built from the declared `SignalBarPriceSource`, with the M1 bar, using a tolerance of 0.5 × `SYMBOL_POINT`. A leading gap is measured from the declared start, and a trailing gap up to the audited end. The gate result is `AUDIT-INCOMPLETE` when a history copy fails or when no minute is eligible.
6. **Signal-timeframe OHLC reconciliation.** Bars are built from processed usable ticks with the declared price source and compared with the platform bar when the bar closes. The first bar after initialization may be partial, so it is skipped and counted. The final open bar is not compared.
7. **Worst-case sizing.** `ExecEntry` = admission quote plus the configured adverse entry slippage. `DeclaredRiskExecutionBufferPoints` is applied to the stop-exit leg (SL − buffer for a long, SL + buffer for a short). `WorstCaseLossPerLot = loss(ExecEntry → buffered SL) + opening commission per lot`. The volume is floored to the step and capped at the maximum. A volume below the minimum is rejected. The volume is reduced (floored) to the available margin, and rejected if that leaves it below the minimum. `RESEARCH_MID_STOP` sizing stays SPEC-INCOMPLETE until 4.5's stop-execution spread buffer has a declared value.
8. **Commission.** The published formula is applied unrounded. For the published example it gives 7.145952, while the page quotes $7.14; the page's rounding convention is not specified.
9. **Currency contract.** `AccountCurrency` must equal the account/tester deposit currency and the symbol's profit currency. No conversion rule is specified, so any mismatch fails initialization.
10. **Stress values.** Slippage legs accept only {0, 1, 2, 5} points, and `FIXED_ADVERSE_POINTS` needs at least one non-zero leg. Latency `FIXED_MS` accepts only {100, 250, 500} ms, and the delay adds to the decision time before the first executable tick is chosen. Any other value fails initialization.
11. **Entry cost gate.** A violation means the value is strictly greater than the frozen maximum. `KnownNonSpreadCostR` = known admission-time non-spread cost (commission plus declared slippage cost) ÷ PlannedRisk1R currency.
12. **Account rules.** `DailyNetResult` inputs are signed P/L amounts. The live adapter uses BUY/SELL deals since the reset for closed, commission, swap and fee amounts, and `POSITION_PROFIT + POSITION_SWAP` for floating P/L; each amount is counted once. An actual floor crossing latches `BREACH` for the rest of the run.
13. **Admission.** Every gate is evaluated and traced. The first failure is reported in this fixed order: account-rule breach, account-rule near-breach, daily profit target, max concurrent positions, directional position cap, daily loss floor, aggregate ceiling, directional ceiling. An open trade's incremental worst-case loss is clamped at ≥ 0. Ceilings are compared as `≤ ceiling`, the floor as `≥ floor`, and the profit target blocks new entries when the result is `≥ target`.
14. **Optional guards.** Enabling `MaxTotalDrawdownEnabled` or `MaxConsecutiveLossGuardEnabled` fails initialization as SPEC-INCOMPLETE until Phase 5 defines their peak/R/reset formulas. `DirectionalPositionCap` counts open Long and Short positions separately and rejects when the count is already ≥ `MaxDirectionalPositions`.
15. **Output package.** The EA writes to `Common\Files\LSR\<ExperimentId>\` (ExperimentId: 1–64 characters, letters, digits, `-`, `_` or `.`). Files are written as UTF-8 without a BOM, and `manifest.json` is written last with the SHA-256 of every other file. Phase 1 has no ledger, so `ledger_checksum` is `null`.

16. **Automatic market closures and data quarantine.** This rule supersedes the whole-run failure caused by a single `CriticalDataGap`; the reason was found in the first rapid-sample smoke run on 2026-09-29.
    - **Automatic market closure.** A tick-free tradeable segment longer than `CriticalDataGapThresholdMinutes` is a closure when two things hold. First, no M1 bar exists in any minute that lies fully inside it. Second, it starts exactly at a broker session start or ends exactly at a broker session end, which covers holidays and early closes. A closure is excluded from `AuditEligibleMinute` and is not a `CriticalDataGap`. When no bar exists, the tester cannot generate ticks and no trade can execute, so this exclusion never hides fabricated data. `ClosedMarketCalendarFile` stays available as an optional declared supplement.
    - **Quarantine.** Every PotentialFallbackMinute and every eligible minute that overlaps a remaining `CriticalDataGap` is quarantined. Later phases must admit **no new entry** at a timestamp inside a quarantine window. Research runs load the windows through input `DataQuarantineFile`; the raw audit writes them as `*quarantine_windows.csv`. Every critical gap is therefore quarantined, and `MaxCriticalDataGapCount = 0` applies to unquarantined gaps.
    - **Gate.** `DATA-PASSED` requires `PotentialFallbackMinuteShare ≤ MaxFallbackMinuteShare` and `QuarantineShare = quarantined eligible minutes / AuditEligibleMinute ≤ MaxFallbackMinuteShare` (1%). Otherwise the run is `DATA-FAILED`. If a history copy fails or no minute is eligible, the result is `AUDIT-INCOMPLETE`.
    - Closures, critical gaps and quarantine windows are listed row by row in the run package.


## Phase 1 Gate

**Logic:** Phase 1 is a specification-completeness gate as well as an implementation gate. No later strategy phase may begin while a Phase-1 behavior still requires developer interpretation.

Before advancing, submit the DataManifest schema, symbol/session snapshot, data-quality audit and execution contract using the Rapid Iteration Sample only where a historical smoke check is needed. Keep every roadmap default unchanged; only the requested date range may be changed to the rapid sample for speed. No strategy input is tuned in this phase.

Complete only when all of the following are frozen and reproducible:

- TimeframeSet parsing/canonicalization and LiveTimeframe rule;
- broker-session schedule intersection and exact Mode 1/2/3 window semantics;
- requested-date manifest inputs and actual tick coverage audit;
- PotentialFallbackMinute and CriticalDataGap operational definitions/gates;
- symbol specification and Bid/Ask quote model;
- commission, slippage and latency inputs and stress semantics;
- AccountRuleProfile and external daily/max-loss formulas;
- internal daily-risk formula, aggregate/directional ceilings and explicit execution-buffer semantics.

### Required output

Data-quality report, symbol/session snapshot, cost/execution contract, AccountRule profile snapshot, DataManifest schema, exact Inputs/Run Card, and blocking-test status. No strategy-selection decision is made here.

### Phase 1 completion record

`Phase 1 — IMPLEMENTED (Gate pending: blocking-test run and rapid-sample smoke packet)`

`Date: 2026-09-28`

`Files changed (2026-09-29 closure/quarantine update): modified MQL5/Include/LiquiditySweepReversal/{LSR_DataAudit,LSR_Sessions}.mqh, MQL5/Experts/LiquiditySweepReversal/LSR_Expert.mq5, MQL5/Scripts/LiquiditySweepReversal/{LSR_Phase1_Tests,LSR_RawTickAudit}.mq5, docs/Phase1_RunCard.md, this roadmap (1.12 item 16, update log).`

`Files changed: added .gitignore; MQL5/Include/LiquiditySweepReversal/{LSR_Types,LSR_Json,LSR_Timeframes,LSR_BrokerTime,LSR_Sessions,LSR_SymbolSpec,LSR_Quote,LSR_Costs,LSR_Sizing,LSR_AccountRules,LSR_RiskAdmission,LSR_DataAudit,LSR_Manifest,LSR_Phase1}.mqh; MQL5/Experts/LiquiditySweepReversal/LSR_Expert.mq5; MQL5/Scripts/LiquiditySweepReversal/{LSR_Phase1_Tests,LSR_RawTickAudit}.mq5; docs/Phase1_RunCard.md; docs/DataManifest.schema.json. Modified: Liquidity_Sweep_Reversal_Roadmap.md (1.12, this record, update log). Removed: none.`

`Summary: Adds a non-trading Phase 1 contract library and EA. They cover TimeframeSet/LiveTimeframe, broker-time sessions (Modes 1/2/3), price units, the Bid/Ask quote model, commission/slippage/latency, the spread/cost gate, stress-aware sizing, daily and aggregate/directional risk admission, and the FundedNext AccountRuleEngine. The EA also runs the raw-tick and OHLC data audit with PFM/critical-gap gates and writes the DataManifest run package.`

`Compile/Tests: MetaEditor 5.0.0.6182: LSR_Expert, LSR_Phase1_Tests and LSR_RawTickAudit each compiled with 0 errors, 0 warnings. Blocking tests executed 2026-09-29 on MT5 build 6182: RESULT PASS, passed=206, failed=0; after the 1.12 item 16 update: RESULT PASS, passed=225, failed=0. The rapid-sample smoke run (docs/Phase1_RunCard.md) has not been executed. Phase 1 becomes COMPLETE only after both pass.`

`Blocking limitations: an MT5 script and a tester run need a connected terminal. The Phase 1 Gate packet must come from the FundedNext XAUUSD real-tick run.`
# Phase 2 — Liquidity Model, Exact Sweep Events & Python Reference Foundation

## Goal

Implement the four liquidity proxy sources, immutable pool/event identity, clustering, touch lifecycle, exact sweep geometry and the independent Python reference foundation. This is the deterministic event layer required by the event study.

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

### 2.10A Multi-timeframe single-pass event processing

Input:

`TimeframeSet = M5,M15,H1` (default)

The tick stream is read exactly once. All selected timeframes are advanced from that same stream in the same pass; the tester must not run a separate market-data pass per timeframe.

Each timeframe receives an independent event state and its own EventID/timeframe identity, event ledger and lifecycle state. The normalized tick stream is shared input only; liquidity, sweep, confirmation and lifecycle state are never shared across timeframes.

Each selected timeframe is one preregistered multiple-testing trial. “Independent” here means independent trial identity/state, not statistically independent price observations.

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
- TimeframeID

---


## 2.10 Python reference foundation

Start the independent Python reference in this phase. It consumes the normalized Phase-1 inputs and DataManifest and reproduces the binding event definitions without importing MQL5 signal code.

Initial scope: liquidity instances, pool geometry, freshness, touch count, sweep classification, EventID and event ledger. Trade-management logic is extended later in Phase 7 for reconciliation.

The Python event layer is a research reference, not a second production engine.

## 2.11 Phase 2 research gate and result submission

**Logic:** Phase 2 proves deterministic event construction before historical performance work begins.

The implementation may proceed only after the blocking event fixtures pass and the first rapid-iteration smoke run is reproducible on the declared TimeframeSet. Submit the event ledger/checksum for every selected timeframe; do not advance with only one timeframe result.

For the submission, keep all roadmap defaults unchanged unless the phase explicitly names an input to vary. Record the exact changed inputs and leave every unmentioned input at its roadmap default.

### Phase 2 Gate

The event stream must produce immutable level/pool instances, exact sweep classifications, touch counts and stable EventIDs from the same market-data pass.
# Phase 3 — Pre-Implementation Event Study & Early-Stop Decision

## Goal

Measure the raw sweep/reclaim hypothesis on development/discovery data using the frozen event definition and independent Python reference, then apply the pre-registered early-stop rule before the larger trade-engine build.

## 3.1 Pre-implementation event study

Before the full strategy execution engine is considered complete, run a lightweight event study over the **Rapid Iteration Sample**:

`2026-01-01 → 2026-06-30`

This short window is intentionally used for repeated early runs so each iteration remains operationally fast. The longer development ranges are reserved for later gates and are not used for routine parameter iteration.

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

## 3.2 Event-study control vs confirmation

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

## 3.3 Macro-event and spread observability

News is first a stratification variable, not an assumed predictive edge.

Inputs:

NewsMode = OBSERVE_ONLY
NewsBlockMinutesBefore = 15
NewsBlockMinutesAfter = 15
NewsImportance = HIGH

A blocking mode is allowed only when the event-calendar source, timestamp basis, importance mapping and missing-data behavior are validated and frozen. Without a validated calendar, remain in OBSERVE_ONLY.

Spread is separately reported by bucket even when the spread filter is OFF.

## 3.4 Development event-study replication

The multi-year replication is **deferred to Phase 8**. Phase 3 must use only the Rapid Iteration Sample so repeated development runs remain short.

Phase 3 may repeat the same event-study logic across the declared TimeframeSet, but must not expand the date range beyond 2026-01-01 → 2026-06-30.

The event study also reports fixed forward horizons such as 1, 3, 5, 10 and 20 completed bars, plus first-barrier outcomes when valid stop/target references exist. Horizon definitions are frozen before analysis.

## 3.5 Event-study foundation gate

The event study does not declare the strategy profitable.

It produces a factual research gate:

- event count
- event quality distribution
- post-sweep direction distribution
- cost burden
- MAE/MFE
- control vs confirmation comparison

**Logic:** Phase 3 validates the raw event hypothesis before trade-management complexity is added.

**Required user result packet before advancing:** submit both Hypothesis A and Hypothesis B results from the Rapid Iteration Sample, including exact Inputs used, event count, mean EventStudyNetR, one-sided 95% bootstrap upper CI, reversal/continuation table, costs and data-quality status. All Inputs not explicitly named for the run remain at roadmap defaults.

Do not advance to Phase 4 until both hypothesis outputs have been received and the Phase 3 gate has been classified.

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

### 3.6 Early-stop / redesign rule

Use only development/discovery observations. Evaluate this rule **separately for each selected timeframe in `TimeframeSet`**. For each timeframe, and for both entry hypotheses A and B, calculate mean `EventStudyNetR` after declared transaction costs using that timeframe's executable entry, LIVE_NATIVE_STOP and SingleTP=2R basis. Define `EventStudyNetR = RealizedNetPnL / PlannedRisk1R` for the event-study trade proxy; no BE and no re-entry are applied.

Pre-register:
- EarlyStopMinEventsPerHypothesis = 100
- EarlyStopMinIndependentDevelopmentDays = 20
- EarlyStopConfidenceLevel = 95%

For each timeframe and hypothesis, compute the one-sided 95% bootstrap upper confidence bound for mean `EventStudyNetR`.

For an individual timeframe, when both sample minima are met and both hypotheses have `Upper95CI(mean EventStudyNetR) < 0`, classify **that timeframe only** as `STOP_EARLY_REDESIGN` and remove it from the active research set. All other selected timeframes continue under their own independent state.

A timeframe that fails to reach either minimum sample requirement is **not removed** and is classified `INCONCLUSIVE` for this gate.

The overall project is classified `STOP_EARLY_REDESIGN` only when **all selected timeframes** have been removed by their own timeframe-level `STOP_EARLY_REDESIGN` decision.

Transactions, positions, risk state, equity, drawdown, event ledger and trade ledger remain independent by timeframe. No result, sample, or state is combined across timeframes for the early-stop decision.

This is a project-efficiency gate, not proof of profitability.

### 3.7 Reversal vs continuation classification

At each fixed horizon H in `1, 3, 5, 10, 20` completed bars:

`DirectionalForwardReturn_H = Direction × (Close_H − SweepClose)`

Classification:
- > 0 = REVERSAL
- < 0 = CONTINUATION
- = 0 = UNRESOLVED

This classification is descriptive. The early-stop decision is based on NetR, not on whichever horizon looks best after results are known.


## Phase 3 Gate — Early Stop / Continue

The event-study dataset must be complete, reproducible, and split into clearly labeled control/confirmation hypotheses with no use of 2025 holdout information.

# Phase 4 — Entry, Stop, Target, Break-Even & Re-Entry Lifecycle

## Goal

Turn valid sweep events into fully specified trades with executable entries, research/live stop profiles, net-R targets, break-even behavior, re-entry and session handling.

## 4.1 Entry modes

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

## 4.2 Exact initial SL reference

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

## 4.3 Primary broker-native stop; MidPrice sensitivity

Primary execution profile:

`StopExecutionProfile = LIVE_NATIVE_STOP`

- Long stop trigger = Bid <= broker-native SL
- Short stop trigger = Ask >= broker-native SL
- Long exit = Bid
- Short exit = Ask

Sensitivity only:

`StopExecutionProfile = RESEARCH_MID_STOP`

`MidPrice = (Bid + Ask) / 2`

The MidPrice profile is not the primary acceptance or deployment model.

### Live execution

LiveStopMode = BROKER_NATIVE_QUOTE_SL

The live adapter must place a broker-native protective SL where the venue permits it. A virtual-only stop is not an acceptable sole production safety mechanism.

The ledger stores StopModel = MID_RESEARCH or NATIVE_QUOTE so the two performance series cannot be mixed silently.

## 4.4 Minimum execution validity

Before a stop/TP/BE price is accepted, the engine checks:

- price is aligned to `SYMBOL_TRADE_TICK_SIZE`
- legal volume step
- minimum stop/freeze distance where applicable
- margin sufficiency
- no invalid order relation

The research engine must not fabricate an executable price that would be illegal under the symbol specification.

## 4.5 1R definition

At entry:

`PlannedRisk1R` = modeled loss between executable entry and initial stop under the selected execution profile, plus only costs deterministically known at admission. Primary profile = LIVE_NATIVE_STOP; RESEARCH_MID_STOP is sensitivity only.

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

## 4.6 TP / Exit policy definition

Input:

`TPMode`

Default:

`FIXED_R`

Allowed:

`FIXED_R`

`TP_BE_MATRIX`

`LIQUIDITY_STRUCTURE`

### Mode 1 — FIXED_R

This is the baseline control:

`TP_R = 2.0`

`BreakEven = OFF`

The target remains configurable, but the Primary Configuration is fixed at 2R with no risk-free transition.

### Mode 2 — TP_BE_MATRIX

This is the existing fixed-R / BE research matrix. The roadmap currently defines all 15 scenarios; the implementation must expose them as predefined Scenario IDs and must not auto-select one.

No Matrix result may silently replace the fixed 2R baseline.

### Mode 3 — LIQUIDITY_STRUCTURE

The engine exits from a deterministic opposing-liquidity target rather than a discretionary “engine judgment”.

Input:

`StructureExitMode`

Allowed:

`OPPOSING_LIQUIDITY`

`LIQUIDITY_CAPPED_BY_R`

Input:

`StructureSafetyBufferTicks = 1`

Input:

`StructureMaxTP_R = 2.0` (used by LIQUIDITY_CAPPED_BY_R)

**OPPOSING_LIQUIDITY:** for Long, target is one declared safety buffer before the nearest eligible opposing high-side PoolLower; for Short, target is one safety buffer before the nearest eligible opposing low-side PoolUpper. The opposing pool must be known and eligible at the exact entry timestamp. No valid opposing target = `NO_TRADE_NO_TARGET`.

**LIQUIDITY_CAPPED_BY_R:** target is the nearer of the eligible opposing-liquidity target and `StructureMaxTP_R`. If no eligible opposing liquidity exists, use `StructureMaxTP_R`.

Mode 3 uses BreakEven = OFF in the initial research state. Adding BE to this mode is a separate preregistered hypothesis and is not implicitly combined with the mode.

### Existing Full Matrix

Only when `TPMode = TP_BE_MATRIX`, all 15 scenarios are tested:

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

## 4.7 Net-R target construction

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

## 4.8 Break-even definition

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

## 4.9 Re-entry

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

## 4.10 Time exit — optional research mode

Inputs:

`TimeExitEnabled = false`

`MaxHoldingBars`

When enabled:

after N completed SignalTimeframe bars from entry, on the first valid tick after the Nth bar closes, the position is closed at the executable market quote.

This feature is OFF by default and must not alter the baseline results unless explicitly enabled.

## 4.11 Session behavior

Session end never forcibly closes an existing trade in the baseline.

Existing positions continue until:

- TP
- SL
- BE
- optional time exit
- optional risk-control exit explicitly enabled

## 4.12 Completion output

Same mandatory roadmap-update and patch-package protocol.

---


## Phase 4 Gate & mandatory comparative run

**Logic:** Phase 4 answers the exit-engine question while holding the event definition constant. The comparison is between three top-level exit policies, not an optimizer.

Before Phase 5, run the **Rapid Iteration Sample (2026-01-01 → 2026-06-30)** with:
- Mode 1: `TPMode=FIXED_R`, `TP_R=2.0`, BreakEven OFF.
- Mode 2: `TPMode=TP_BE_MATRIX`, all predefined Matrix Scenario IDs, with only the Matrix Scenario ID varied from defaults.
- Mode 3: `TPMode=LIQUIDITY_STRUCTURE`, first `StructureExitMode=OPPOSING_LIQUIDITY`, then `StructureExitMode=LIQUIDITY_CAPPED_BY_R`; leave `StructureSafetyBufferTicks=1` and `StructureMaxTP_R=2.0` at defaults.

**Input rule:** use every roadmap default unchanged except the Inputs explicitly listed in the run prescription above. The submission must include exact Inputs, all three mode-level results, per-mode trade count, expectancy, cost/R, max DD, NetR mean with one-sided 95% CI, exit-reason distribution and data-quality status.

**Blocking rule:** Phase 5 cannot start until results for all three top-level exit modes are available. No single mode may be selected or discarded from the next phase solely by highest historical NetR; interpretation follows the frozen research gates.

### Phase 4 Gate

Entry/exit behavior must be fully deterministic, executable-quote based, and covered by lifecycle and barrier-ordering fixtures.
# Phase 5 — Strategy Filters & Optional Risk Extensions

## Goal

Implement the three approved strategy filters and keep news/spread/risk extensions isolated from the core matrix so research complexity remains controlled.

## 5.1 Filter A — HTF Structure

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

## 5.2 Filter B — Sweep Quality

Inputs:

`UseSweepQualityFilter = false`

`ATRPeriod = 14`

Requirements:

`SweepPenetration >= 0.10 × ATR`

`SweepPenetration <= 0.50 × ATR`

`ReclaimDistance >= 0.10 × ATR`

ATR uses completed pre-sweep candles only.

## 5.3 Filter C — Opposing Liquidity / Target Room

Input:

`UseTargetRoomFilter = false`

For Long:

the selected TP must be before the nearest relevant opposing liquidity in the move direction.

For Short:

the selected TP must be before the nearest relevant opposing liquidity in the move direction.

If no valid opposing liquidity exists, the trade is not rejected solely for absence of a target reference.

## 5.3 News and spread are not strategy filters

News remains OBSERVE_ONLY at the strategy layer. Official account rules are applied separately by AccountRuleEngine.

Spread remains an execution-quality gate defined in Phase 1, not a strategy filter and not part of the A/B/C matrix.

No News or Spread filter is multiplied into the core eight combinations.

## 5.4 Filter combinations

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

## 5.5 Optional directional-risk cap

Input:

`DirectionalPositionCapEnabled = false`

`MaxDirectionalPositions = 3`

When disabled, baseline behavior is unchanged.

When enabled, Long and Short open positions are counted separately.

## 5.6 Optional total drawdown and streak guards

Supported but OFF by default:

`MaxTotalDrawdownEnabled`

`MaxTotalDrawdownR`

`MaxConsecutiveLossGuardEnabled`

`MaxConsecutiveLosses`

These controls are reported separately from the default daily 3R guard.

## Phase 5 Gate

**Logic:** Phase 5 isolates whether the approved filters/risk extensions change behavior without silently changing the entry/exit contract.

Before advancing, run the declared filter scenarios on the Rapid Iteration Sample using the frozen Fixed-R control from Phase 4: `TPMode=FIXED_R`, `TP_R=2.0`, BreakEven OFF. Vary only the predefined A/B/C filter-combination state (`OFF`, A, B, C, A+B, A+C, B+C, A+B+C); all other Inputs remain at roadmap defaults. The result packet must include every combination and its exact Inputs plus the standard metrics.

**Blocking rule:** do not advance until every required filter-combination result has been submitted and the phase gate has been classified.

Filters and optional controls must be independently switchable, documented, and excluded from the frozen baseline unless explicitly declared as a research scenario.

### Completion output

Same mandatory roadmap-update and patch-package protocol.

---

# Phase 6 — Single-Pass Backtest, Scenario Engine, Ledger & Reporting

## Goal

Run the frozen event stream through isolated scenario states using one market-data pass and produce the complete event/trade ledger and hierarchical reports.

## 6.1 Single market pass

The engine reads the selected tick stream **exactly once**.

During that pass it constructs:

`Event Ledger`

`Trade Ledger`

`Scenario States`

`Daily State`

`Equity Curves`

for every selected research timeframe.

All selected timeframes are advanced from the same tick traversal. A separate execution/backtest pass per timeframe is prohibited.

Reports are generated afterward by grouping the resulting ledger.

January must never trigger a second backtest merely to create the January report.

## 6.2 Scenario and timeframe state architecture

All declared TP/BE/confirmation/filter scenarios run against the same single market-data traversal inside the Research Simulator. No scenario may place live orders.

Within that one traversal, each selected timeframe has a completely independent research state containing:

- open positions
- daily risk
- max positions
- realized R
- reserved risk
- equity
- drawdown
- TP/exit state
- BE state
- re-entry state
- guard state
- trade ledger
- event ledger

No timeframe may read another timeframe's strategy state. Only the normalized tick stream is shared.

The live adapter must not execute multiple timeframes simultaneously. Live trading selects one fixed timeframe and one frozen configuration.

## 6.3 Exact tested ranges

### Rapid Iteration Sample

`2026-01-01 → 2026-06-30`

Used for repeated short runs and early phase gates only. It is not the extended robustness test.

### Extended Development

`2020-07-01 → 2024-12-31`

plus:

`2026-01-01 → 2026-09-28`

The 2026 H2 extension is entered only after the rapid-iteration gates have passed.

### Historical Blind OOS

`2025-01-01 → 2025-12-31`

The OOS year is not read by optimization or selection logic before the final OOS run.

## 6.4 Trade ledger fields

Minimum:

- Trade ID
- Scenario ID
- TimeframeID
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

## 6.5 Monthly report

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

## 6.6 Annual report

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

## 6.7 Grand total

For a multi-year test:

same metric family over the complete requested range.

The final report also clearly identifies which calendar periods were Development and which were OOS.

## 6.8 Drawdown definition

For each report period:

`MaxDD_R` = deepest peak-to-trough drawdown visible in that period’s equity curve.

To avoid ambiguity at period boundaries, also report:

`StartingUnderwaterDD_R`

which shows whether the period began already below a previous peak.

This prevents a monthly report from hiding the fact that the account entered the month already underwater.

## 6.9 Max DD Touch Count

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

## 6.10 Research stratification reports

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

## 6.11 Execution-cost analysis

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

## 6.12 Scenario- and timeframe-comparison output

The engine outputs all requested TP/BE/exit scenarios and all selected timeframes side by side.

For each timeframe, report separately:

- event count
- trade count
- expectancy
- costs in R
- max drawdown
- mean NetR with one-sided 95% CI
- win rate
- PF
- max DD touches
- max loss streak
- MAE/MFE

A comparison table must place timeframes side by side without summing their equity curves, NetR or drawdowns.

Each selected timeframe counts as one preregistered multiple-testing experiment/trial. This is a trial-control rule, not a claim that the underlying price observations are statistically independent.

The engine must never auto-select a “best timeframe” or “best exit mode”.

The live report contains one fixed timeframe only; the multi-timeframe comparison is research-only.


## 6.13 Phase 6 gate and mandatory full-run packet

**Logic:** Phase 6 proves that all declared scenarios/timeframes can be simulated from one market-data pass and reconciled into separate ledgers and reports.

Before Phase 7, execute the complete Rapid Iteration Sample with the declared `TimeframeSet` and all required research scenarios. The run packet must include the exact Inputs used, TimeframeID for every output, scenario count/trial count, side-by-side timeframe table, separate equity curves, and the full ledger checksum.

**Blocking rule:** Phase 7 cannot start until every declared timeframe and every required scenario output has been submitted and the one-pass/state-isolation checks pass.

### Phase 6 Gate

One tick stream must generate the complete ledger and all scenario outputs without scenario-dependent or timeframe-dependent event creation/destruction.

### Completion output

Same mandatory roadmap-update and patch-package protocol.

---

# Phase 7 — Deterministic Validation, Reference Reconciliation & Statistical Tests

## Goal

Prove that the implemented engine is deterministic and reconciles to an independent reference before interpreting extended-development or holdout performance.

## 7.1 Deterministic validation

Must prove:

- zero look-ahead
- correct swing confirmation timing
- exact signal-close to next-tick execution
- correct Bid/Ask opening and closing sides
- exact event-tick spread capture
- primary broker-native stop behavior; MidPrice sensitivity is covered separately
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

## 7.2 Deterministic state-machine fixtures

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

ProjectedWorstCaseEquity >= DailyLossFloor
AggregateWorstCaseRiskR <= MaxAggregateOpenWorstCaseRiskR
DirectionalWorstCaseRiskR <= MaxDirectionalOpenWorstCaseRiskR
ConsumedPool -> no duplicate same-event trade
ConfirmedSwing -> no future information
LivePositionState == BrokerReconciledPositionState

## 7.3 Multiple-testing-aware validation

When candidate selection is performed, use a suitable multiple-testing-aware method such as White's Reality Check and/or Hansen's SPA in addition to Deflated Sharpe / PBO diagnostics.

When outcome windows overlap, use purging/embargo or equivalent temporal leakage control. Random K-fold is prohibited for overlapping financial labels.

## 7.4 Python/reference reconciliation

Continue the independent Python reference that was started in Phase 2. Extend it only for trade-management logic needed to reconcile the MQL5 engine; do not replace the independently built event layer with shared production code.

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

## 7.5 Bootstrap and Monte Carlo

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

## 7.6 Multiple-testing control

The project deliberately contains multiple predefined scenarios.

Therefore:

- every declared scenario is counted as a research trial
- the number of trials is reported
- no hidden configurations may be added after seeing results without restarting the declared trial count
- Deflated Sharpe Ratio / Probabilistic Sharpe diagnostics may be reported where statistically appropriate
- Probability of Backtest Overfitting / CSCV diagnostics are used when a configuration-selection exercise becomes large enough to justify them

These 15 TP/BE scenarios are an **exploratory sensitivity matrix** only. They cannot select the deployment configuration, alter frozen holdout rules, or determine the final verdict.

## 7.7 Parameter sensitivity

Predeclare small, non-optimized sensitivity checks around structural parameters.

At minimum, test controlled perturbations such as:

- SL extra buffer: 2 / 3 / 4 strategy pips
- Equal-level tolerance: 2 / 3 / 4 strategy pips

Sensitivity results are reported as stability ranges.

The engine must not search arbitrary hundreds of parameter values.

## 7.8 Execution stress validation

Run controlled robustness variants for:

- zero slippage / zero latency
- small fixed adverse entry slippage
- small fixed adverse exit slippage
- combined entry/exit slippage
- fixed execution delays where the tester/model supports them

These are stress tests, not historical claims. The exact stress values must be declared before the run and included in the final report.


## Phase 7 Gate & mandatory validation packet

**Logic:** Phase 7 prevents a plausible-looking backtest from passing while the execution engine and independent reference disagree.

Before Phase 8, submit the deterministic fixture results, Python/MT5 reconciliation on declared short intervals, statistical diagnostics, and the exact Inputs/Run Card used. Every declared timeframe must be checked; missing one timeframe is a blocking omission.

**Blocking rule:** no extended-development or holdout run is interpreted until the validation packet is complete and all blocking checks pass.

All blocking fixtures pass and the MQL5 engine reconciles with the independent reference within predefined tolerance before performance interpretation.
# Phase 8 — Robustness, Freeze, Development & Historical Holdout

## Goal

Stress the frozen implementation across regimes, execution profiles and data sources, then run the extended development set and the untouched 2025 historical blind holdout without feeding results back into rules.

## 8.1 Regime robustness

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

## 8.2 Secondary-symbol robustness

After XAUUSD core rules are frozen, the same deterministic engine may be run on XAGUSD as a **robustness check**, not as a parameter-selection tool for XAUUSD.

The secondary symbol result cannot be used to alter the already-frozen XAUUSD OOS rule set.

## 8.3 Data-source robustness

Primary research remains the target broker/tester feed because execution spread and symbol rules are broker-specific.

A secondary historical source may be used only for:

- gap/data continuity audit
- broad structural event comparison
- robustness diagnostics

It must not be mixed tick-by-tick with the target broker feed.

## 8.4 Experimental freeze

After the experimental phase:

`2026-01-01 → 2026-09-28`

the strategy configuration intended for the extended run is frozen.

Any material strategy-rule change after seeing extended-development performance reopens the research selection/holdout process and must not be silently folded into the prior study state.

## 8.5 Extended development test

Run the frozen configuration on:

`2020-07-01 → 2024-12-31`

and:

`2026-01-01 → 2026-09-28`

Exclude all of 2025.

## 8.6 Paired execution-profile robustness

Primary profile: `LIVE_NATIVE_STOP`.

Sensitivity profile: `RESEARCH_MID_STOP`.

The MidPrice profile is a robustness sensitivity only and cannot be the sole basis for acceptance or deployment.

## 8.7 Historical blind holdout audit

Run the frozen configuration on:

`2025-01-01 → 2025-12-31`

Because 2025 is chronologically prior to the current 2026 discovery window, this is labeled a **historical blind holdout**, not the project's only forward OOS series.

No holdout observation may feed:

- rule selection
- filter selection
- parameter changes
- scenario pruning
- code changes intended to improve the OOS result

## 8.8 Final research package

Must contain:

- exact code version
- exact roadmap commit/file hash
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

## Phase 8 Gate & final broad-run packet

**Logic:** Phase 8 is the first deliberately broad historical examination. Its purpose is robustness and freeze confirmation, not rapid parameter iteration.

Submit one complete broad-run packet covering the frozen configuration on the declared extended-development range, the separate 2025 holdout, every required timeframe/report, and the final stress/sensitivity outputs. Exact Inputs must be recorded; no unlisted input may be changed.

**Blocking rule:** if any broad-run output is missing, or if holdout data affected selection, Phase 8 is not complete.

Robustness results, freeze state, development runs and 2025 holdout are reproducible and no holdout observation feeds rule selection.

### Completion output

Same mandatory roadmap-update and patch-package protocol.

---
# Phase 9 — Production Hardening, Shadow Run & True Forward Validation

## Goal

Prove operational safety under broker/terminal/network failures, then use the frozen configuration for shadow, demo and chronological forward validation from 2026-09-29 onward.

## 9.1 Mandatory live controls

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

## 9.2 Fault-injection tests

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

## 9.3 True forward validation

Starting 2026-09-29, the frozen configuration enters:

SHADOW -> DEMO -> LIVE_AFTER_APPROVAL

Forward data records actual spread, entry/exit slippage, latency, rejects, downtime, restarts and reconciliation errors. These observations may inform a future research study state but never retroactively alter the 2025 OOS.

## 9.4 Deployment gate

Deployment requires:

- hard research gates passed
- native-stop robustness documented
- operational fault tests passed
- exact account/rule profile verified
- shadow/demo behavior reconciled
- no unresolved blocking defect

## 9.5 Release artifact

Store:

- code commit SHA
- roadmap hash
- exact inputs
- symbol specification snapshot
- deployment configuration hash
- test logs
- known limitations

---


## Phase 9 Gate & forward-run packet

**Logic:** Phase 9 is operational validation, not another optimization cycle.

Before changing deployment state, submit the fault-test results, exact frozen Inputs, account/rule profile, and shadow/demo reconciliation. Live mode must contain exactly one fixed timeframe.

Operational fault tests pass, account/rule profile is verified, and the frozen configuration enters forward validation with immutable observation logs.
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

This protocol applies to **every phase that changes code or materially changes the research implementation**.

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

# Roadmap Update Log

## Update 2026-09-29 — Automatic closure detection and data quarantine

- The first rapid-sample smoke run was DATA-FAILED: fallback share 1.93% and 12 critical gaps. Ten of the gaps and about 99% of the fallback minutes were holidays and early closes that `SymbolInfoSessionTrade` does not list (2026-01-01, 01-19, 02-16, 04-03, 05-25, 06-19). Two were real broker data holes: 2026-02-20 20:31, 8 minutes with no bars; and 2026-06-17 22:00, 20 minutes with bars but no ticks, where tester fallback ticks are possible. The same run also used a tester end date of 2026-09-25 and a 10000 deposit instead of the Run Card values.
- Added 1.12 item 16: automatic market-closure detection; per-window quarantine of fallback minutes and critical gaps, where later phases admit no new entries; and a quarantine-share gate that replaces the whole-run failure caused by a single gap. Added the `DataQuarantineFile` input and the closure and quarantine CSV outputs, plus blocking tests.

## Update 2026-09-28 — Phase 1 implementation

- Implemented the Phase 1 contract as a non-trading MQL5 library, EA, blocking-test script and raw-tick audit script. Added the Run Card (`docs/Phase1_RunCard.md`) and the DataManifest schema (`docs/DataManifest.schema.json`).
- Added 1.12 "Phase 1 implementation closures". These close the gaps found during implementation: run context, wrapped sessions, the declared closed-market calendar, audit range and tick usability, sizing buffer placement, commission rounding, the currency contract, stress-value validation, cost-gate boundaries, account-rule components/latching, admission precedence, and SPEC-INCOMPLETE optional guards.
- Phase 1 status: IMPLEMENTED; gate pending the blocking-test run and the rapid-sample smoke packet.

## Update 2026-09-28 — Phase 1 specification-completeness closure

- Closed Phase 1 gaps for broker-session windows, raw-tick/fallback auditing, cost/slippage/latency models, FundedNext account rules, execution buffers and live timeframe selection.
- Phase 1 Gate now blocks progression until these behaviors are frozen and the exact Inputs/Run Card are supplied.


## Update 2026-09-28 — Timeframe-specific early-stop gate

- Applied the Early-stop / redesign rule independently per selected timeframe; only timeframes meeting STOP_EARLY_REDESIGN are removed, while INCONCLUSIVE timeframes remain active. The whole project stops only if all selected timeframes are removed.


## Update 2026-09-28 — Timeframe, exit-policy and phase-gate expansion

- Added `TimeframeSet` with default `M5,M15,H1`; allowed values `M1/M5/M15/M30/H1`.
- One tick stream is consumed once for all selected research timeframes; each timeframe has fully isolated research state and reporting. Live trading remains one fixed timeframe only.
- Added three top-level exit policies: `FIXED_R`, `TP_BE_MATRIX`, and `LIQUIDITY_STRUCTURE`, with deterministic opposing-liquidity and liquidity-capped-by-R variants.
- Added mandatory phase-gate result packets: test-heavy phases cannot advance until every declared required output is submitted with exact Inputs; unspecified Inputs remain at roadmap defaults.
- Added Rapid Iteration Sample `2026-01-01 → 2026-06-30`; extended development remains `2020-07-01 → 2024-12-31` plus 2026, 2025 remains untouched OOS.
- Added side-by-side timeframe reporting and explicit multiple-testing treatment; no automatic best-timeframe selection.

## Update 2026-09-28 — Final audit corrections

- Removed untouched-OOS ranking/tie-breaking; OOS is confirmation/reporting only.
- Replaced legacy contradictory sweep and daily-risk wording with one canonical rule set.
- Made LIVE_NATIVE_STOP the primary model; RESEARCH_MID_STOP is sensitivity only.
- Set `MinEconomicEdgeR = 0.05R` and defined exact early-stop, gap and barrier rules.
- Reordered work: Phase 2 = liquidity/sweep event contract + Python reference foundation; Phase 3 = event study + early-stop decision.
- Removed News/Spread as strategy Filters D/E. News is observation/account-rule treatment; spread is execution-quality gating.
- Full Matrix is exploratory sensitivity only and cannot determine the final verdict.
- Fixed roadmap naming/structure errors. Future updates append here; the filename/path never changes.

# Final Definition of Done

The project is complete only when:

- the four requested liquidity proxy sources work independently
- pool geometry, clustering tolerance and event consumption are deterministic
- penetration, reclaim and pre-sweep touch formulas are explicit
- level freshness prevents sweep-time/future information leakage
- one immutable EventID represents one market event across all research scenarios
- liquidity clustering and lifecycle are deterministic
- pre-sweep touches are measurable
- sweep detection has no ambiguous opening-above/below case
- TimeframeSet defaults to M5,M15,H1 and allows M1/M5/M15/M30/H1
- research timeframes run in one tick pass with isolated state; live uses one fixed timeframe
- Broker Server Time is authoritative
- all three trading-session modes work
- real-tick availability is audited from raw tick records and M1 reconciliation; PotentialFallbackMinute is reported without falsely claiming an undocumented tester tick-source flag
- CriticalDataGapThresholdMinutes=5 and MaxCriticalDataGapCount=0 are enforced
- actual Bid/Ask and same-tick spread are used
- XAUUSD strategy pip size is explicit
- entry/SL/TP/BE are deterministic
- Fixed-R, TP/BE Matrix, and Liquidity-Structure exit modes are explicit, configurable and reason-coded
- the liquidity-structure mode never uses discretionary engine judgment
- RECLAIM_CLOSE and NEXT_BAR_EXTREME_CONFIRM have atomic lifecycle rules
- LIVE_NATIVE_STOP is the primary execution profile and RESEARCH_MID_STOP is sensitivity only
- PlannedRisk1R, RealizedStopLossR and ExecutionDeviationR are distinct
- TP_PRICE_HIT and NET_TARGET_REACHED are distinct outcomes
- gap-through and ambiguous timestamp execution are explicitly classified
- initial SL cannot be triggered by spread expansion alone in the research model
- TP is cost-aware and executable-quote based
- 1R is dynamic
- MinEconomicEdgeR is pre-registered at 0.05R
- Phase 3 has a quantitative early-stop/rethink gate
- position sizing respects symbol constraints and risk
- aggregate and directional worst-case open-risk ceilings are enforced
- the external AccountRuleEngine is separate from the internal strategy risk budget
- decision traces record every admission/rejection reason
- daily loss guard defaults to 3R and blocks new risk without force-closing open trades from floating DD alone
- max concurrent positions defaults to 3
- the remaining daily risk capacity prevents new trades from exceeding the 3R risk budget
- daily profit target exists at 9R but is OFF by default
- Fixed-R mode defaults to 2R with BE OFF
- TP/BE Matrix mode runs all 15 currently declared predefined scenarios for exploratory sensitivity only and cannot determine the final verdict
- Liquidity-Structure mode is a separate deterministic research hypothesis with opposing-liquidity and liquidity-capped-by-R variants
- Re-entry defaults to one attempt and supports 1–4 attempts
- the three approved strategy filters exist and are OFF by default; News and Spread are not strategy filters
- optional time/directional/total-DD/streak controls exist without altering baseline defaults
- a single market-data pass generates the full ledger and scenario outputs across all selected research timeframes
- each timeframe has independent event/trade/risk/equity state and its own reports
- monthly, annual and grand-total reports are produced from that ledger without summing timeframes
- side-by-side timeframe comparison reports event count, expectancy, costs/R, max DD and mean NetR with CI
- each declared timeframe is counted as a preregistered multiple-testing trial; no automatic best-timeframe selection
- Long/Short counts are explicit
- MaxDD and MaxDD Touch Count are explicit for every reporting period
- MAE/MFE/cost/execution metrics are retained
- event-study diagnostics exist
- 2025 remains untouched as the historical blind holdout and is never used for ranking or tie-breaking
- true chronological OOS begins 2026-09-29 and is kept as a forward-validation series
- Monte Carlo/bootstrap/sensitivity diagnostics are available
- multiple-testing-aware validation is available when candidate selection occurs
- deterministic fixtures and runtime invariants are blocking tests
- DataManifest makes every result reproducible
- Python reference implementation starts in Phase 2
- the MT5 engine reconciles against that independent reference implementation
- every code-changing phase updates this exact roadmap file
- the roadmap is never renamed
- changed/new files preserve original names and relative paths
- unchanged files are not touched
