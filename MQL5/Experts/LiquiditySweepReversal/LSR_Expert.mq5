//+------------------------------------------------------------------+
//| LSR_Expert.mq5                                                   |
//| Liquidity Sweep Reversal — Phase 1:                              |
//| Data, Time, Symbol & Execution Contract.                         |
//|                                                                  |
//| This phase does NOT trade. It validates every Phase-1 input,     |
//| snapshots the symbol/session/account-rule contract, audits the   |
//| tick data and writes the DataManifest run package to             |
//| Common\Files\LSR\<ExperimentId>\.                                |
//+------------------------------------------------------------------+
#property copyright   "Liquidity Sweep Reversal"
#property version     "1.00"
#property description "Phase 1 — Data, Time, Symbol & Execution Contract (no trading)"

#include "../../Include/LiquiditySweepReversal/LSR_Phase1.mqh"

//--- Run identity (DataManifest, roadmap 0A.6)
input group "Run identity (DataManifest)"
input string                        InpExperimentId               = "LSR-P1-SMOKE";   // ExperimentId
input string                        InpCodeCommitSHA              = "";               // CodeCommitSHA (git rev-parse HEAD)
input string                        InpRoadmapSHA256              = "";               // RoadmapSHA256 (sha256 of the roadmap file)

//--- 1.1 Timeframes
input group "1.1 TimeframeSet and live timeframe"
input string                        InpTimeframeSet               = "M5,M15,H1";      // TimeframeSet (M1/M5/M15/M30/H1)
input ENUM_LSR_TIMEFRAME            InpLiveTimeframe              = LSR_TF_M5;        // LiveTimeframe

//--- 1.3 Sessions
input group "1.3 Trading sessions (Broker Server Time)"
input ENUM_LSR_SESSION_MODE         InpTradingSessionMode         = LSR_SESSION_FULL_DAY_EXCEPT_LATE_SPREAD; // TradingSessionMode
input string                        InpTradeStartTime             = "00:00";          // TradeStartTime (Mode 3)
input string                        InpTradeEndTime               = "24:00";          // TradeEndTime (Mode 3)

//--- 1.4 Audit
input group "1.4 Tick/data-quality audit"
input datetime                      InpAuditRequestedStartDate    = D'2026.01.01';    // AuditRequestedStartDate (copy from tester)
input datetime                      InpAuditRequestedEndDate      = D'2026.06.30';    // AuditRequestedEndDate (inclusive date, copy from tester)
input string                        InpClosedMarketCalendarFile   = "";               // ClosedMarketCalendarFile (Common\Files CSV, optional)
input string                        InpDataQuarantineFile         = "";               // DataQuarantineFile (raw-audit quarantine CSV, optional)

//--- 1.5 / 1.6 Symbol and quotes
input group "1.5/1.6 Symbol price units and quote model"
input double                        InpStrategyPipSize            = 0.10;             // StrategyPipSize
input ENUM_LSR_PRICE_SOURCE         InpSignalBarPriceSource       = LSR_PRICE_BID;    // SignalBarPriceSource
input ENUM_LSR_STOP_PROFILE         InpStopExecutionProfile       = LSR_STOP_LIVE_NATIVE; // StopExecutionProfile

//--- 1.7 Costs
input group "1.7 Cost and execution model"
input ENUM_LSR_COMMISSION_MODE      InpCommissionMode             = LSR_COMMISSION_FUNDEDNEXT_OFFICIAL_METALS; // CommissionMode
input double                        InpCommissionRatePercent      = 0.0016;           // CommissionRatePercent (%)
input ENUM_LSR_CONTRACT_SIZE_SOURCE InpCommissionContractSizeSource = LSR_CONTRACT_SIZE_SYMBOL; // CommissionContractSizeSource
input double                        InpCommissionScheduleContractSize = 0.0;          // CommissionScheduleContractSize (BROKER_SCHEDULE only)
input ENUM_LSR_COMMISSION_BASIS     InpCommissionPricingBasis     = LSR_COMMISSION_BASIS_OPEN_PRICE; // CommissionPricingBasis
input ENUM_LSR_COST_SCHEDULE_LABEL  InpCostScheduleLabel          = LSR_COST_SCHEDULE_CURRENT_OFFICIAL; // CostScheduleLabel
input string                        InpCostScheduleDate           = "2026-09-28";     // CostScheduleDate (YYYY-MM-DD)
input ENUM_LSR_SLIPPAGE_MODE        InpSlippageMode               = LSR_SLIPPAGE_NONE; // SlippageMode
input int                           InpEntrySlippagePoints        = 0;                // EntrySlippagePoints (0/1/2/5)
input int                           InpExitSlippagePoints         = 0;                // ExitSlippagePoints (0/1/2/5)
input ENUM_LSR_LATENCY_MODE         InpLatencyMode                = LSR_LATENCY_ZERO; // LatencyMode
input int                           InpFixedExecutionDelayMs      = 0;                // FixedExecutionDelayMs (100/250/500)
input bool                          InpMaxEntrySpreadEnabled      = true;             // MaxEntrySpreadEnabled
input double                        InpMaxEntrySpreadStrategyPips = 3.0;              // MaxEntrySpreadStrategyPips
input double                        InpMaxEntryKnownNonSpreadCostR = 0.10;            // MaxEntryKnownNonSpreadCostR

//--- 1.8 / 1.9 Risk
input group "1.8/1.9 Position sizing and daily risk admission"
input double                        InpRiskPerTradePercent        = 0.50;             // RiskPerTradePercent
input bool                          InpDailyLossGuardEnabled      = true;             // DailyLossGuardEnabled
input double                        InpMaxDailyLossR              = 3.0;              // MaxDailyLossR
input int                           InpMaxConcurrentPositions     = 3;                // MaxConcurrentPositions
input double                        InpMaxAggregateOpenWorstCaseRiskR   = 3.0;        // MaxAggregateOpenWorstCaseRiskR
input double                        InpMaxDirectionalOpenWorstCaseRiskR = 2.0;        // MaxDirectionalOpenWorstCaseRiskR

//--- 1.10 Optional
input group "1.10 Optional additional risk controls (OFF by default)"
input bool                          InpDirectionalPositionCapEnabled = false;         // DirectionalPositionCapEnabled
input int                           InpMaxDirectionalPositions    = 3;                // MaxDirectionalPositions
input bool                          InpMaxTotalDrawdownEnabled    = false;            // MaxTotalDrawdownEnabled (SPEC-INCOMPLETE until Phase 5)
input double                        InpMaxTotalDrawdownR          = 0.0;              // MaxTotalDrawdownR
input bool                          InpMaxConsecutiveLossGuardEnabled = false;        // MaxConsecutiveLossGuardEnabled (SPEC-INCOMPLETE until Phase 5)
input int                           InpMaxConsecutiveLosses       = 0;                // MaxConsecutiveLosses

//--- 1.11 Daily profit target
input group "1.11 Daily profit target"
input bool                          InpDailyProfitTargetEnabled   = false;            // DailyProfitTargetEnabled
input double                        InpDailyProfitTargetR         = 9.0;              // DailyProfitTargetR
input ENUM_LSR_PROFIT_TARGET_BASIS  InpProfitTargetBasis          = LSR_PROFIT_TARGET_NET_EQUITY; // ProfitTargetBasis

//--- 0B.10 Account rules
input group "0B.10 External account-rule compliance"
input ENUM_LSR_ACCOUNT_RULE_PROFILE InpAccountRuleProfile         = LSR_ACCOUNT_FUNDEDNEXT_STELLAR_2STEP; // AccountRuleProfile
input ENUM_LSR_ACCOUNT_RULE_MODE    InpAccountRuleEngine          = LSR_ACCOUNT_RULES_APPLY_OFFICIAL; // AccountRuleEngine
input double                        InpAccountInitialBalance      = 100000.0;         // AccountInitialBalance
input string                        InpAccountCurrency            = "USD";            // AccountCurrency
input double                        InpAccountRuleSafetyBufferR   = 0.10;             // AccountRuleSafetyBufferR

//+------------------------------------------------------------------+
//| One isolated research state per selected timeframe (rule 11).    |
//+------------------------------------------------------------------+
class CLSR_TimeframeContext
  {
public:
   ENUM_LSR_TIMEFRAME tf;
   CLSR_BarReconciler bars;
   CLSR_DailyRiskState daily;
   CLSR_AccountRuleEngine acct;
   double            equity;
   double            balance;
   long              ticks;
   long              ticks_in_entry_window;
   ENUM_LSR_ACCOUNT_RULE_STATE last_account_state;

   void              Init(const ENUM_LSR_TIMEFRAME t, const string symbol, const ENUM_LSR_PRICE_SOURCE src,
                          const double point, const LSR_AccountRuleProfile &profile, const double startEquity)
     {
      tf = t;
      bars.Init(symbol, t, src, point);
      acct.Init(profile);
      equity = startEquity;
      balance = startEquity;
      ticks = 0;
      ticks_in_entry_window = 0;
      last_account_state = LSR_ACCOUNT_OK;
     }
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
ENUM_LSR_RUN_CONTEXT   g_runContext = LSR_CONTEXT_RESEARCH;
LSR_TimeframeSet       g_tfSet;
LSR_TimeframeSet       g_active;
LSR_SymbolSpec         g_spec;
CLSR_PriceUnits        g_units;
CLSR_SessionSchedule   g_sched;
CLSR_ClosureCalendar   g_calendar;
CLSR_DataQuarantine    g_quarantine;
CLSR_StrategyWindow    g_window;
LSR_CostModel          g_costs;
LSR_RiskConfig         g_risk;
LSR_AccountRuleProfile g_acctProfile;
CLSR_InputRecorder     g_inputs;
CLSR_RunOutput         g_out;
CLSR_RawTickAudit      g_rawAudit;
CLSR_RawAuditDriver    g_rawDriver;
CLSR_TimeframeContext *g_ctx[LSR_TF_COUNT];
int                    g_ctxCount = 0;

LSR_TickAnomalies      g_stream;
bool                   g_havePrev = false;
MqlTick                g_prevTick;
ulong                  g_seq = 0;
long                   g_ticksInSession = 0;
long                   g_ticksInEntryWindow = 0;
long                   g_ticksBeforeRange = 0;
long                   g_ticksAfterRange = 0;
datetime               g_rangeStart = 0;
datetime               g_rangeEndExclusive = 0;
bool                   g_initialized = false;
string                 g_initTime = "";

//+------------------------------------------------------------------+
void RecordInputs(void)
  {
   g_inputs.Add("ExperimentId", InpExperimentId, "LSR-P1-SMOKE");
   g_inputs.Add("CodeCommitSHA", InpCodeCommitSHA, "");
   g_inputs.Add("RoadmapSHA256", InpRoadmapSHA256, "");
   g_inputs.Add("TimeframeSet", InpTimeframeSet, LSR_DEFAULT_TIMEFRAME_SET);
   g_inputs.Add("LiveTimeframe", LSR_TimeframeName(InpLiveTimeframe), "M5");
   g_inputs.Add("TradingSessionMode", LSR_SessionModeName(InpTradingSessionMode), LSR_SessionModeName(LSR_SESSION_FULL_DAY_EXCEPT_LATE_SPREAD));
   g_inputs.Add("TradeStartTime", InpTradeStartTime, "00:00");
   g_inputs.Add("TradeEndTime", InpTradeEndTime, "24:00");
   g_inputs.Add("AuditRequestedStartDate", LSR_IsoDate(InpAuditRequestedStartDate), "2026-01-01");
   g_inputs.Add("AuditRequestedEndDate", LSR_IsoDate(InpAuditRequestedEndDate), "2026-06-30");
   g_inputs.Add("ClosedMarketCalendarFile", InpClosedMarketCalendarFile, "");
   g_inputs.Add("DataQuarantineFile", InpDataQuarantineFile, "");
   g_inputs.AddNum("StrategyPipSize", InpStrategyPipSize, LSR_BASELINE_STRATEGY_PIP_SIZE);
   g_inputs.Add("SignalBarPriceSource", LSR_PriceSourceName(InpSignalBarPriceSource), "BID");
   g_inputs.Add("StopExecutionProfile", LSR_StopProfileName(InpStopExecutionProfile), "LIVE_NATIVE_STOP");
   g_inputs.Add("CommissionMode", LSR_CommissionModeName(InpCommissionMode), "FUNDEDNEXT_OFFICIAL_METALS");
   g_inputs.AddNum("CommissionRatePercent", InpCommissionRatePercent, LSR_BASELINE_COMMISSION_RATE_PERCENT);
   g_inputs.Add("CommissionContractSizeSource", LSR_ContractSizeSourceName(InpCommissionContractSizeSource), "SYMBOL_TRADE_CONTRACT_SIZE");
   g_inputs.AddNum("CommissionScheduleContractSize", InpCommissionScheduleContractSize, 0.0);
   g_inputs.Add("CommissionPricingBasis", LSR_CommissionBasisName(InpCommissionPricingBasis), "OPEN_PRICE");
   g_inputs.Add("CostScheduleLabel", LSR_CostScheduleLabelName(InpCostScheduleLabel), "CURRENT_OFFICIAL_SCHEDULE");
   g_inputs.Add("CostScheduleDate", InpCostScheduleDate, "2026-09-28");
   g_inputs.Add("SlippageMode", LSR_SlippageModeName(InpSlippageMode), "NONE");
   g_inputs.AddInt("EntrySlippagePoints", InpEntrySlippagePoints, 0);
   g_inputs.AddInt("ExitSlippagePoints", InpExitSlippagePoints, 0);
   g_inputs.Add("LatencyMode", LSR_LatencyModeName(InpLatencyMode), "ZERO");
   g_inputs.AddInt("FixedExecutionDelayMs", InpFixedExecutionDelayMs, 0);
   g_inputs.AddBool("MaxEntrySpreadEnabled", InpMaxEntrySpreadEnabled, true);
   g_inputs.AddNum("MaxEntrySpreadStrategyPips", InpMaxEntrySpreadStrategyPips, 3.0);
   g_inputs.AddNum("MaxEntryKnownNonSpreadCostR", InpMaxEntryKnownNonSpreadCostR, 0.10);
   g_inputs.AddNum("RiskPerTradePercent", InpRiskPerTradePercent, 0.50);
   g_inputs.AddBool("DailyLossGuardEnabled", InpDailyLossGuardEnabled, true);
   g_inputs.AddNum("MaxDailyLossR", InpMaxDailyLossR, 3.0);
   g_inputs.AddInt("MaxConcurrentPositions", InpMaxConcurrentPositions, 3);
   g_inputs.AddNum("MaxAggregateOpenWorstCaseRiskR", InpMaxAggregateOpenWorstCaseRiskR, 3.0);
   g_inputs.AddNum("MaxDirectionalOpenWorstCaseRiskR", InpMaxDirectionalOpenWorstCaseRiskR, 2.0);
   g_inputs.AddBool("DirectionalPositionCapEnabled", InpDirectionalPositionCapEnabled, false);
   g_inputs.AddInt("MaxDirectionalPositions", InpMaxDirectionalPositions, 3);
   g_inputs.AddBool("MaxTotalDrawdownEnabled", InpMaxTotalDrawdownEnabled, false);
   g_inputs.AddNum("MaxTotalDrawdownR", InpMaxTotalDrawdownR, 0.0);
   g_inputs.AddBool("MaxConsecutiveLossGuardEnabled", InpMaxConsecutiveLossGuardEnabled, false);
   g_inputs.AddInt("MaxConsecutiveLosses", InpMaxConsecutiveLosses, 0);
   g_inputs.AddBool("DailyProfitTargetEnabled", InpDailyProfitTargetEnabled, false);
   g_inputs.AddNum("DailyProfitTargetR", InpDailyProfitTargetR, 9.0);
   g_inputs.Add("ProfitTargetBasis", LSR_ProfitTargetBasisName(InpProfitTargetBasis), "NET_EQUITY");
   g_inputs.Add("AccountRuleProfile", LSR_AccountRuleProfileName(InpAccountRuleProfile), "FUNDEDNEXT_STELLAR_2STEP");
   g_inputs.Add("AccountRuleEngine", LSR_AccountRuleModeName(InpAccountRuleEngine), "APPLY_OFFICIAL_ACCOUNT_RULES");
   g_inputs.AddNum("AccountInitialBalance", InpAccountInitialBalance, 100000.0);
   g_inputs.Add("AccountCurrency", InpAccountCurrency, "USD");
   g_inputs.AddNum("AccountRuleSafetyBufferR", InpAccountRuleSafetyBufferR, 0.10);
  }

//+------------------------------------------------------------------+
int Fail(const string what)
  {
   PrintFormat("LSR PHASE-1 INIT FAILED: %s", what);
   return INIT_PARAMETERS_INCORRECT;
  }

//+------------------------------------------------------------------+
int OnInit(void)
  {
   string err;
   g_initialized = false;
   g_inputs.Clear();
   RecordInputs();

   if(!LSR_ValidateExperimentId(InpExperimentId, err))
      return Fail(err);
   g_out.Init(InpExperimentId);

   //--- 1.1 TimeframeSet / LiveTimeframe
   if(!LSR_ParseTimeframeSet(InpTimeframeSet, g_tfSet, err))
      return Fail(err);
   if(!LSR_ValidateLiveTimeframe(g_tfSet, InpLiveTimeframe, err))
      return Fail(err);
   g_runContext = (MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION)) ? LSR_CONTEXT_RESEARCH : LSR_CONTEXT_LIVE;
   LSR_ResolveActiveTimeframes(g_tfSet, InpLiveTimeframe, g_runContext, g_active);

   //--- 1.5 Symbol specification and price units
   if(!LSR_CaptureSymbolSpec(_Symbol, TimeCurrent(), g_spec, err))
      return Fail(err);
   if(!LSR_ValidateSymbolSpec(g_spec, err))
      return Fail(err);
   if(!g_units.Init(InpStrategyPipSize, g_spec.point, g_spec.tick_size, err))
      return Fail(err);
   if(InpSignalBarPriceSource == LSR_PRICE_LAST && g_spec.chart_mode != SYMBOL_CHART_MODE_LAST)
      return Fail("SignalBarPriceSource LAST requested but the symbol's bars are not built from LAST");

   //--- Currency contract: no conversion rule is specified (0B.13)
   string accCcy = AccountInfoString(ACCOUNT_CURRENCY);
   if(accCcy != InpAccountCurrency)
      return Fail(StringFormat("account/tester deposit currency %s differs from AccountCurrency %s", accCcy, InpAccountCurrency));
   if(g_spec.currency_profit != InpAccountCurrency)
      return Fail(StringFormat("symbol profit currency %s differs from AccountCurrency %s; commission conversion is not specified (SPEC-INCOMPLETE)",
                               g_spec.currency_profit, InpAccountCurrency));

   //--- 1.3 Sessions
   if(!g_sched.LoadFromSymbol(_Symbol, err))
      return Fail(err);
   if(!g_window.Init(InpTradingSessionMode, InpTradeStartTime, InpTradeEndTime, GetPointer(g_sched), err))
      return Fail(err);

   //--- 1.7 Costs
   g_costs.commission_mode                  = InpCommissionMode;
   g_costs.commission_rate_percent          = InpCommissionRatePercent;
   g_costs.contract_size_source             = InpCommissionContractSizeSource;
   g_costs.schedule_contract_size           = InpCommissionScheduleContractSize;
   g_costs.commission_basis                 = InpCommissionPricingBasis;
   g_costs.schedule_label                   = InpCostScheduleLabel;
   g_costs.schedule_date                    = InpCostScheduleDate;
   g_costs.slippage_mode                    = InpSlippageMode;
   g_costs.entry_slippage_points            = InpEntrySlippagePoints;
   g_costs.exit_slippage_points             = InpExitSlippagePoints;
   g_costs.latency_mode                     = InpLatencyMode;
   g_costs.fixed_execution_delay_ms         = InpFixedExecutionDelayMs;
   g_costs.max_entry_spread_enabled         = InpMaxEntrySpreadEnabled;
   g_costs.max_entry_spread_strategy_pips   = InpMaxEntrySpreadStrategyPips;
   g_costs.max_entry_known_nonspread_cost_r = InpMaxEntryKnownNonSpreadCostR;
   if(!LSR_ValidateCostModel(g_costs, err))
      return Fail(err);

   //--- 1.8–1.11 Risk
   g_risk.risk_per_trade_percent                 = InpRiskPerTradePercent;
   g_risk.daily_loss_guard_enabled               = InpDailyLossGuardEnabled;
   g_risk.max_daily_loss_r                       = InpMaxDailyLossR;
   g_risk.max_concurrent_positions               = InpMaxConcurrentPositions;
   g_risk.max_aggregate_open_worst_case_risk_r   = InpMaxAggregateOpenWorstCaseRiskR;
   g_risk.max_directional_open_worst_case_risk_r = InpMaxDirectionalOpenWorstCaseRiskR;
   g_risk.directional_position_cap_enabled       = InpDirectionalPositionCapEnabled;
   g_risk.max_directional_positions              = InpMaxDirectionalPositions;
   g_risk.max_total_drawdown_enabled             = InpMaxTotalDrawdownEnabled;
   g_risk.max_total_drawdown_r                   = InpMaxTotalDrawdownR;
   g_risk.max_consecutive_loss_guard_enabled     = InpMaxConsecutiveLossGuardEnabled;
   g_risk.max_consecutive_losses                 = InpMaxConsecutiveLosses;
   g_risk.daily_profit_target_enabled            = InpDailyProfitTargetEnabled;
   g_risk.daily_profit_target_r                  = InpDailyProfitTargetR;
   g_risk.profit_target_basis                    = InpProfitTargetBasis;
   if(!LSR_ValidateRiskConfig(g_risk, err))
      return Fail(err);

   //--- 0B.10 Account rules
   if(!LSR_LoadAccountRuleProfile(InpAccountRuleProfile, InpAccountRuleEngine, InpAccountInitialBalance,
                                  InpAccountCurrency, InpAccountRuleSafetyBufferR, g_acctProfile, err))
      return Fail(err);

   //--- 1.4 Audit declaration (end date inclusive → exclusive broker-day boundary)
   g_rangeStart = LSR_BrokerDayStart(InpAuditRequestedStartDate);
   g_rangeEndExclusive = LSR_BrokerDayStart(InpAuditRequestedEndDate) + LSR_SECONDS_PER_DAY;
   if(g_rangeEndExclusive <= g_rangeStart)
      return Fail("AuditRequestedEndDate must not be before AuditRequestedStartDate");
   if(!g_calendar.LoadCsv(InpClosedMarketCalendarFile, err))
      return Fail(err);
   if(!g_quarantine.LoadCsv(InpDataQuarantineFile, err))
      return Fail(err);
   g_rawAudit.Init(GetPointer(g_sched), GetPointer(g_calendar), InpSignalBarPriceSource, g_spec.point,
                   g_rangeStart, g_rangeEndExclusive, "TESTER_CopyTicksRange_COPY_TICKS_ALL");
   g_rawDriver.Init(_Symbol, GetPointer(g_rawAudit));

   //--- Isolated contexts
   double startEquity = (g_runContext == LSR_CONTEXT_RESEARCH ? InpAccountInitialBalance : AccountInfoDouble(ACCOUNT_EQUITY));
   g_ctxCount = 0;
   for(int i = 0; i < g_active.count; i++)
     {
      g_ctx[i] = new CLSR_TimeframeContext;
      g_ctx[i].Init(g_active.items[i], _Symbol, InpSignalBarPriceSource, g_spec.point, g_acctProfile, startEquity);
      g_ctxCount++;
     }

   LSR_TickAnomaliesReset(g_stream);
   g_havePrev = false;
   g_seq = 0;
   g_initTime = LSR_IsoTime(TimeCurrent());
   g_initialized = true;

   WriteContractSnapshots();
   PrintFormat("LSR Phase 1 initialised: context=%s TimeframeSet=%s active=%s session=%s output=Common\\Files\\%s",
               LSR_RunContextName(g_runContext), LSR_TimeframeSetToString(g_tfSet), LSR_TimeframeSetToString(g_active),
               LSR_SessionModeName(InpTradingSessionMode), g_out.Dir());
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnTick(void)
  {
   if(!g_initialized)
      return;
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t))
      return;

   g_seq++;
   bool usable = LSR_TickAnomaliesObserve(g_stream, t, g_havePrev, g_prevTick);
   g_prevTick = t;
   g_havePrev = true;

   LSR_Quote q;
   LSR_QuoteFromTick(t, g_seq, q);

   if(q.time < g_rangeStart)
      g_ticksBeforeRange++;
   else
      if(q.time >= g_rangeEndExclusive)
         g_ticksAfterRange++;

   bool inSession = g_sched.IsInSession(q.time);
   bool entryAllowed = inSession && g_window.InConfiguredWindow(q.time);
   if(inSession)
      g_ticksInSession++;
   if(entryAllowed)
      g_ticksInEntryWindow++;

   for(int i = 0; i < g_ctxCount; i++)
     {
      CLSR_TimeframeContext *c = g_ctx[i];
      c.ticks++;
      if(entryAllowed)
         c.ticks_in_entry_window++;
      if(usable)
         c.bars.OnQuote(q);
      if(g_runContext == LSR_CONTEXT_LIVE)
        {
         c.equity = AccountInfoDouble(ACCOUNT_EQUITY);
         c.balance = AccountInfoDouble(ACCOUNT_BALANCE);
        }
      c.daily.Observe(q.time, c.equity, g_risk.risk_per_trade_percent);
      c.acct.OnTimestamp(q.time);

      LSR_AccountRuleInputs in;
      if(g_runContext == LSR_CONTEXT_LIVE)
         LSR_CollectLiveAccountRuleInputs(c.acct.ResetTimestamp(), c.daily.DayRiskUnit(), in);
      else
        {
         // Phase 1 research contexts hold no positions: every P/L component is zero.
         in.closed_result = 0.0;
         in.floating_result = 0.0;
         in.commission = 0.0;
         in.swap = 0.0;
         in.fees = 0.0;
         in.balance = c.balance;
         in.equity = c.equity;
         in.day_risk_unit_currency = c.daily.DayRiskUnit();
        }
      LSR_AccountRuleEval e;
      c.last_account_state = c.acct.Update(q.time, in, e);
     }

   if(g_runContext == LSR_CONTEXT_RESEARCH)
      g_rawDriver.Advance(q.time);
  }

//+------------------------------------------------------------------+
void WriteSessionSample(CLSR_Json &j)
  {
   // Mode-1 late-spread block for the first 14 broker dates of the declared range.
   j.BeginArray();
   for(int k = 0; k < 14; k++)
     {
      datetime day = g_rangeStart + k * LSR_SECONDS_PER_DAY;
      datetime bs, be;
      j.BeginObject();
      j.KStr("broker_date", LSR_IsoDate(day));
      j.KStr("weekday", LSR_WeekdayName(LSR_DayOfWeek(day)));
      if(g_window.LateBlockOfDay(day, bs, be))
        {
         j.KTime("late_block_start", bs);
         j.KTime("late_block_end_exclusive", be);
        }
      else
         j.KNull("late_block_start");
      j.EndObject();
     }
   j.EndArray();
  }

void WriteContractSnapshots(void)
  {
   CLSR_Json j;

   //--- symbol/session snapshot
   j.BeginObject();
   j.KStr("contract_id", LSR_PHASE1_CONTRACT_ID);
   j.KStr("server_time_basis", LSR_SERVER_TIME_BASIS);
   j.Key("symbol_specification");
   LSR_WriteSymbolSpecJson(j, g_spec);
   j.KObj("price_units");
   j.KNum("strategy_pip_size", g_units.PipSize(), 8);
   j.KStr("strategy_pip_source", "explicit input (never inferred from SYMBOL_POINT)");
   j.KNum("symbol_point", g_units.Point(), 12);
   j.KNum("tick_size", g_units.TickSize(), 12);
   j.Key("one_strategy_pip");
   g_units.WriteDistanceJson(j, g_units.PipSize());
   j.EndObject();
   j.Key("trading_session_schedule");
   g_sched.WriteJson(j);
   j.Key("strategy_entry_window");
   g_window.WriteJson(j);
   j.Key("mode1_late_block_sample");
   WriteSessionSample(j);
   j.Key("declared_closed_market_calendar");
   g_calendar.WriteJson(j);
   j.EndObject();
   g_out.Write("symbol_session_snapshot.json", j.Text());

   //--- account-rule profile snapshot
   j.Reset();
   if(g_ctxCount > 0)
      g_ctx[0].acct.WriteProfileJson(j);
   else
      j.Null();
   g_out.Write("account_rule_profile.json", j.Text());

   //--- cost / execution contract
   j.Reset();
   j.BeginObject();
   j.Key("cost_model");
   LSR_WriteCostModelJson(j, g_costs, LSR_CommissionContractSize(g_costs, g_spec), InpStopExecutionProfile,
                          InpSignalBarPriceSource, InpStrategyPipSize);
   j.KObj("position_sizing");
   j.KStr("risk_unit", "DayRiskUnitCurrency = StartOfBrokerDayEquity * RiskPerTradePercent / 100");
   j.KStr("worst_case_loss_per_lot", "loss(ExecEntry -> SL -/+ DeclaredRiskExecutionBufferPoints) + opening commission per lot");
   j.KStr("exec_entry", "Ask + EntrySlippage (long) / Bid - EntrySlippage (short)");
   j.KStr("economics", "OrderCalcProfit / OrderCalcMargin; OrderCheck for live execution validity");
   j.KStr("volume_rounding", "down to SYMBOL_VOLUME_STEP; capped at SYMBOL_VOLUME_MAX; below SYMBOL_VOLUME_MIN = reject");
   j.KStr("margin", "volume reduced (rounded down) to available margin; below minimum = reject");
   j.KStr("research_mid_stop", "sizing SPEC-INCOMPLETE until the stop-execution spread buffer is declared (roadmap 4.5)");
   j.EndObject();
   j.Key("risk_admission");
   LSR_WriteRiskConfigJson(j, g_risk);
   j.EndObject();
   g_out.Write("execution_contract.json", j.Text());
  }

//+------------------------------------------------------------------+
void WriteFinalPackage(const int deinitReason)
  {
   if(g_runContext == LSR_CONTEXT_RESEARCH && g_havePrev)
      g_rawDriver.Flush((datetime)(g_stream.last_msc / 1000));

   //--- data-quality report
   CLSR_Json j;
   j.BeginObject();
   j.KStr("contract_id", LSR_PHASE1_CONTRACT_ID);
   j.KStr("run_context", LSR_RunContextName(g_runContext));
   j.KObj("coverage");
   j.KTime("declared_requested_start", g_rangeStart);
   j.KTime("declared_requested_end_exclusive", g_rangeEndExclusive);
   j.KStr("declaration_rule", "manual Run Card declaration copied from the tester UI; never inferred from runtime data");
   j.KStr("first_processed_tick", LSR_IsoTimeMsc(g_stream.first_msc));
   j.KStr("last_processed_tick", LSR_IsoTimeMsc(g_stream.last_msc));
   j.KInt("processed_ticks_before_declared_start", g_ticksBeforeRange);
   j.KInt("processed_ticks_after_declared_end", g_ticksAfterRange);
   bool mismatch = (g_ticksBeforeRange > 0 || g_ticksAfterRange > 0 || g_stream.records == 0);
   j.KStr("declared_vs_observed", mismatch ? "MISMATCH" : "OBSERVED_WITHIN_DECLARED_RANGE");
   if(g_stream.first_msc >= 0)
     {
      j.KInt("seconds_from_declared_start_to_first_tick", (long)(g_stream.first_msc / 1000) - (long)g_rangeStart);
      j.KInt("seconds_from_last_tick_to_declared_end", (long)g_rangeEndExclusive - (long)(g_stream.last_msc / 1000));
     }
   j.EndObject();
   j.Key("processed_tick_stream");
   LSR_WriteTickAnomaliesJson(j, g_stream);
   j.KObj("session_counts");
   j.KInt("ticks_in_actual_trade_session", g_ticksInSession);
   j.KInt("ticks_in_strategy_entry_window", g_ticksInEntryWindow);
   j.EndObject();
   if(g_runContext == LSR_CONTEXT_RESEARCH)
     {
      j.Key("raw_real_tick_audit");
      g_rawAudit.WriteJson(j);
     }
   else
      j.KStr("raw_real_tick_audit", "not run in LIVE context; use Scripts/LiquiditySweepReversal/LSR_RawTickAudit");
   j.KArr("signal_timeframe_ohlc_reconciliation");
   for(int i = 0; i < g_ctxCount; i++)
      g_ctx[i].bars.WriteJson(j);
   j.EndArray();
   j.EndObject();
   g_out.Write("data_quality_report.json", j.Text());

   if(g_runContext == LSR_CONTEXT_RESEARCH)
     {
      g_out.Write("potential_fallback_minutes.csv", g_rawAudit.FallbackCsv());
      g_out.Write("critical_data_gaps.csv", g_rawAudit.GapsCsv());
      g_out.Write("detected_market_closures.csv", g_rawAudit.ClosuresCsv());
      g_out.Write("data_quarantine_windows.csv", g_rawAudit.QuarantineCsv());
     }
   string csv = "timeframe,bar_time,kind,built_open,built_high,built_low,built_close,platform_open,platform_high,platform_low,platform_close\n";
   for(int i = 0; i < g_ctxCount; i++)
      csv += g_ctx[i].bars.CsvRows();
   g_out.Write("timeframe_bar_reconciliation.csv", csv);
   g_out.Write("run_card_inputs.txt", g_inputs.RunCardText());

   //--- DataManifest (written last; indexes every file above)
   j.Reset();
   j.BeginObject();
   j.KStr("schema_version", LSR_MANIFEST_SCHEMA_VERSION);
   j.KStr("engine", LSR_ENGINE_NAME);
   j.KStr("phase", "PHASE_1_DATA_TIME_SYMBOL_EXECUTION_CONTRACT");
   j.KStr("contract_id", LSR_PHASE1_CONTRACT_ID);
   j.KStr("experiment_id", InpExperimentId);
   j.KStr("run_context", LSR_RunContextName(g_runContext));
   j.KStr("init_broker_time", g_initTime);
   j.KStr("finalized_broker_time", LSR_IsoTime(TimeCurrent()));
   j.KInt("deinit_reason", deinitReason);
   j.KObj("code");
   j.KStr("code_sha", InpCodeCommitSHA);
   j.KStr("roadmap_file", LSR_ROADMAP_FILENAME);
   j.KStr("roadmap_sha256", InpRoadmapSHA256);
   j.EndObject();
   j.KObj("platform");
   j.KInt("mt5_build", TerminalInfoInteger(TERMINAL_BUILD));
   j.KStr("terminal_company", TerminalInfoString(TERMINAL_COMPANY));
   j.KBool("strategy_tester", (bool)MQLInfoInteger(MQL_TESTER));
   j.KStr("declared_tester_model", "Every tick based on real ticks (Run Card declaration)");
   j.EndObject();
   j.KObj("broker");
   j.KStr("company", AccountInfoString(ACCOUNT_COMPANY));
   j.KStr("server", AccountInfoString(ACCOUNT_SERVER));
   j.KStr("account_currency", AccountInfoString(ACCOUNT_CURRENCY));
   j.EndObject();
   j.KStr("server_time_basis", LSR_SERVER_TIME_BASIS);
   j.KStr("symbol", _Symbol);
   j.KObj("timeframes");
   j.KStr("timeframe_set", LSR_TimeframeSetToString(g_tfSet));
   j.KStr("live_timeframe", LSR_TimeframeName(InpLiveTimeframe));
   j.KStr("active_timeframes", LSR_TimeframeSetToString(g_active));
   j.KStr("isolation", "each active timeframe has independent bars, daily risk, account-rule state and equity; only the tick stream is shared");
   j.EndObject();
   j.KObj("range");
   j.KTime("requested_start", g_rangeStart);
   j.KTime("requested_end_exclusive", g_rangeEndExclusive);
   j.KStr("actual_first_tick", LSR_IsoTimeMsc(g_stream.first_msc));
   j.KStr("actual_last_tick", LSR_IsoTimeMsc(g_stream.last_msc));
   j.EndObject();
   j.KObj("tick_source");
   j.KStr("execution_stream", "OnTick SymbolInfoTick, source order preserved (sequence numbers)");
   if(g_runContext == LSR_CONTEXT_RESEARCH)
     {
      j.KStr("raw_audit_source", "CopyTicksRange COPY_TICKS_ALL + CopyRates M1");
      j.KNum("potential_fallback_minute_share", g_rawAudit.FallbackShare(), 8);
      j.KInt("critical_data_gap_count", g_rawAudit.CriticalGapCount());
      j.KInt("auto_detected_market_closures", g_rawAudit.ClosureCount());
      j.KNum("quarantine_share", g_rawAudit.QuarantineShare(), 8);
      j.KStr("data_gate", LSR_DataGateName(g_rawAudit.Gate()));
     }
   j.KStr("data_quarantine_file", InpDataQuarantineFile);
   j.KInt("data_quarantine_windows_loaded", g_quarantine.Count());
   j.EndObject();
   j.KObj("account_rules");
   j.KStr("profile", LSR_AccountRuleProfileName(g_acctProfile.profile));
   j.KNum("initial_balance", g_acctProfile.initial_balance, 2);
   j.KStr("currency", g_acctProfile.currency);
   j.EndObject();
   j.KObj("execution_model");
   j.KStr("stop_execution_profile", LSR_StopProfileName(InpStopExecutionProfile));
   j.KStr("commission", LSR_CommissionModeName(g_costs.commission_mode) + " @ " + LSR_NumStr(g_costs.commission_rate_percent) + "%, " + LSR_CostScheduleLabelName(g_costs.schedule_label) + " " + g_costs.schedule_date);
   j.KStr("slippage", LSR_SlippageModeName(g_costs.slippage_mode) + " entry=" + IntegerToString(g_costs.entry_slippage_points) + " exit=" + IntegerToString(g_costs.exit_slippage_points));
   j.KStr("latency", LSR_LatencyModeName(g_costs.latency_mode) + " " + IntegerToString(g_costs.fixed_execution_delay_ms) + "ms");
   j.EndObject();
   j.KArr("scenario_ids");
   j.Str("BASELINE");
   j.EndArray();
   j.KInt("declared_trial_count", g_active.count);
   j.KArr("random_seeds");
   j.EndArray();
   j.KNull("ledger_checksum");
   j.KStr("ledger_note", "Phase 1 produces no event/trade ledger; ledgers start in Phase 2");
   j.KArr("per_timeframe_state");
   for(int i = 0; i < g_ctxCount; i++)
     {
      j.BeginObject();
      j.KStr("timeframe", LSR_TimeframeName(g_ctx[i].tf));
      j.KInt("ticks", g_ctx[i].ticks);
      j.KInt("ticks_in_entry_window", g_ctx[i].ticks_in_entry_window);
      j.KInt("broker_day_resets", g_ctx[i].daily.ResetCount());
      j.KNum("equity", g_ctx[i].equity, 2);
      j.KStr("account_rule_state", LSR_AccountRuleStateName(g_ctx[i].last_account_state));
      j.Key("account_rule_engine");
      g_ctx[i].acct.WriteStateJson(j);
      j.EndObject();
     }
   j.EndArray();
   j.Key("inputs");
   g_inputs.WriteJson(j);
   j.Key("files");
   g_out.WriteIndexJson(j);
   j.EndObject();
   string sha = g_out.Write("manifest.json", j.Text());

   PrintFormat("LSR Phase 1 package written to Common\\Files\\%s (manifest sha256 %s, write failures %d)",
               g_out.Dir(), sha, g_out.Failures());
   if(g_runContext == LSR_CONTEXT_RESEARCH)
      PrintFormat("LSR data gate: %s  fallback share=%s  quarantine share=%s  quarantined gaps=%I64d  auto closures=%I64d",
                  LSR_DataGateName(g_rawAudit.Gate()), LSR_NumStr(g_rawAudit.FallbackShare(), 6), LSR_NumStr(g_rawAudit.QuarantineShare(), 6),
                  g_rawAudit.CriticalGapCount(), g_rawAudit.ClosureCount());
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_initialized)
      WriteFinalPackage(reason);
   for(int i = 0; i < g_ctxCount; i++)
     {
      delete g_ctx[i];
      g_ctx[i] = NULL;
     }
   g_ctxCount = 0;
   g_initialized = false;
  }
//+------------------------------------------------------------------+
