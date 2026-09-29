//+------------------------------------------------------------------+
//| ORB_Expert.mq5                                                   |
//| Opening Range Breakout (NDX100) — Phase ORB-1 research EA.       |
//|                                                                  |
//| This EA does NOT trade. In one tick pass it validates the LSR    |
//| Phase 1 contract (symbol, sessions, costs), audits the real      |
//| ticks, builds the ORB day ledger for OR5 and OR15 and runs the   |
//| R10_EOD / R2_EOD proxy trades. The run package is written to     |
//| Common\Files\ORB\<ExperimentId>\ (Opening_Range_Breakout_Roadmap |
//| Sections 3, 4 and 10).                                           |
//+------------------------------------------------------------------+
#property copyright   "Opening Range Breakout"
#property version     "1.00"
#property description "ORB-1 — day ledger and proxy trades for OR5/OR15 (no trading)"

#include "../../Include/OpeningRangeBreakout/ORB_Phase1.mqh"

//--- Run identity (DataManifest)
input group "Run identity (DataManifest)"
input string                        InpExperimentId               = "ORB-1-SMOKE";    // ExperimentId
input string                        InpCodeCommitSHA              = "";               // CodeCommitSHA (git rev-parse HEAD)
input string                        InpRoadmapSHA256              = "";               // RoadmapSHA256 (sha256 of Opening_Range_Breakout_Roadmap.md)

//--- Audit (LSR 1.4)
input group "Tick/data-quality audit"
input datetime                      InpAuditRequestedStartDate    = D'2026.01.01';    // AuditRequestedStartDate (copy from tester)
input datetime                      InpAuditRequestedEndDate      = D'2026.06.30';    // AuditRequestedEndDate (inclusive date, copy from tester)
input string                        InpClosedMarketCalendarFile   = "";               // ClosedMarketCalendarFile (Common\Files CSV, optional)
input string                        InpDataQuarantineFile         = "";               // DataQuarantineFile (raw-audit quarantine CSV, optional)

//--- Symbol and quotes (LSR 1.5 / 1.6)
input group "Symbol price units and quote model"
input double                        InpStrategyPipSize            = 1.0;              // StrategyPipSize (1 index point)
input ENUM_LSR_PRICE_SOURCE         InpSignalBarPriceSource       = LSR_PRICE_BID;    // SignalBarPriceSource
input ENUM_LSR_STOP_PROFILE         InpStopExecutionProfile       = LSR_STOP_LIVE_NATIVE; // StopExecutionProfile

//--- Costs (LSR 1.7, ORB 1.3)
input group "Cost and execution model"
input ENUM_LSR_COMMISSION_MODE      InpCommissionMode             = LSR_COMMISSION_FUNDEDNEXT_OFFICIAL_INDICES; // CommissionMode
input double                        InpCommissionRatePercent      = 0.0;              // CommissionRatePercent (%; 0 for indices)
input ENUM_LSR_CONTRACT_SIZE_SOURCE InpCommissionContractSizeSource = LSR_CONTRACT_SIZE_SYMBOL; // CommissionContractSizeSource
input double                        InpCommissionScheduleContractSize = 0.0;          // CommissionScheduleContractSize (BROKER_SCHEDULE only)
input ENUM_LSR_COMMISSION_BASIS     InpCommissionPricingBasis     = LSR_COMMISSION_BASIS_OPEN_PRICE; // CommissionPricingBasis
input ENUM_LSR_COST_SCHEDULE_LABEL  InpCostScheduleLabel          = LSR_COST_SCHEDULE_CURRENT_OFFICIAL; // CostScheduleLabel
input string                        InpCostScheduleDate           = "2026-09-29";     // CostScheduleDate (YYYY-MM-DD)
input ENUM_LSR_SLIPPAGE_MODE        InpSlippageMode               = LSR_SLIPPAGE_NONE; // SlippageMode
input int                           InpEntrySlippagePoints        = 0;                // EntrySlippagePoints (0/1/2/5)
input int                           InpExitSlippagePoints         = 0;                // ExitSlippagePoints (0/1/2/5)
input ENUM_LSR_LATENCY_MODE         InpLatencyMode                = LSR_LATENCY_ZERO; // LatencyMode
input int                           InpFixedExecutionDelayMs      = 0;                // FixedExecutionDelayMs (100/250/500)
input bool                          InpMaxEntrySpreadEnabled      = false;            // MaxEntrySpreadEnabled (ORB: false, F2 replaces it)

//--- Account currency contract (LSR 0B.13)
input group "Account"
input double                        InpAccountInitialBalance      = 100000.0;         // AccountInitialBalance
input string                        InpAccountCurrency            = "USD";            // AccountCurrency (= NDX100 profit currency)

//--- Outputs
input group "ORB-1 outputs"
input bool                          InpExportReferenceBars        = true;             // ExportReferenceBars (M1 CSV for the Python reference)

//+------------------------------------------------------------------+
//| Quarantine + closure lookup for the ledgers (roadmap 3 item 2).  |
//+------------------------------------------------------------------+
class CORB_EAQuarantine : public CORB_IntervalCheck
  {
public:
   CLSR_RawTickAudit *raw;
   CLSR_DataQuarantine *file;
   CLSR_ClosureCalendar *calendar;
   CORB_IntervalList closures;       // auto-detected closures of the raw audit

   virtual bool      Overlaps(const datetime from, const datetime toExclusive)
     {
      if(raw != NULL && raw.Overlaps(from, toExclusive))
         return true;
      if(file != NULL && file.Overlaps(from, toExclusive))
         return true;
      if(closures.Overlaps(from, toExclusive))
         return true;
      if(calendar != NULL && calendar.Count() > 0)
        {
         datetime f[], t[];
         calendar.Subtract(from, toExclusive, f, t);
         long open = 0;
         for(int i = 0; i < ArraySize(f); i++)
            open += (long)(t[i] - f[i]);
         if(open < (long)(toExclusive - from))
            return true;
        }
      return false;
     }
  };

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
ENUM_LSR_RUN_CONTEXT   g_runContext = LSR_CONTEXT_RESEARCH;
LSR_SymbolSpec         g_spec;
CLSR_PriceUnits        g_units;
CLSR_SessionSchedule   g_sched;
CLSR_ClosureCalendar   g_calendar;
CLSR_DataQuarantine    g_quarantine;
LSR_CostModel          g_costs;
LSR_AccountRuleProfile g_acctProfile;
CLSR_InputRecorder     g_inputs;
CORB_RunOutput         g_out;
CLSR_RawTickAudit      g_rawAudit;
CLSR_RawAuditDriver    g_rawDriver;
CLSR_BarReconciler     g_barRecon;
CLSR_M1Builder         g_m1;
CORB_DayLedger         g_days;
CORB_ProxySim          g_proxies;
CLSR_MT5Economics     *g_econ = NULL;
CLSR_BrokerDayClock    g_dayClock;
int                    g_m1File = INVALID_HANDLE;
long                   g_m1Count = 0;
datetime               g_firstM1 = 0;

LSR_TickAnomalies      g_stream;
bool                   g_havePrev = false;
MqlTick                g_prevTick;
ulong                  g_seq = 0;
long                   g_ticks = 0;
long                   g_ticksInSession = 0;
long                   g_ticksBeforeRange = 0;
long                   g_ticksAfterRange = 0;
datetime               g_rangeStart = 0;
datetime               g_rangeEndExclusive = 0;
bool                   g_initialized = false;
string                 g_initTime = "";

string                 g_daysSha[ORB_ORLEN_COUNT];
string                 g_tradesSha[ORB_ORLEN_COUNT];

//+------------------------------------------------------------------+
void RecordInputs(void)
  {
   g_inputs.Add("ExperimentId", InpExperimentId, "ORB-1-SMOKE");
   g_inputs.Add("CodeCommitSHA", InpCodeCommitSHA, "");
   g_inputs.Add("RoadmapSHA256", InpRoadmapSHA256, "");
   g_inputs.Add("AuditRequestedStartDate", LSR_IsoDate(InpAuditRequestedStartDate), "2026-01-01");
   g_inputs.Add("AuditRequestedEndDate", LSR_IsoDate(InpAuditRequestedEndDate), "2026-06-30");
   g_inputs.Add("ClosedMarketCalendarFile", InpClosedMarketCalendarFile, "");
   g_inputs.Add("DataQuarantineFile", InpDataQuarantineFile, "");
   g_inputs.AddNum("StrategyPipSize", InpStrategyPipSize, 1.0);
   g_inputs.Add("SignalBarPriceSource", LSR_PriceSourceName(InpSignalBarPriceSource), "BID");
   g_inputs.Add("StopExecutionProfile", LSR_StopProfileName(InpStopExecutionProfile), "LIVE_NATIVE_STOP");
   g_inputs.Add("CommissionMode", LSR_CommissionModeName(InpCommissionMode), "FUNDEDNEXT_OFFICIAL_INDICES");
   g_inputs.AddNum("CommissionRatePercent", InpCommissionRatePercent, 0.0);
   g_inputs.Add("CommissionContractSizeSource", LSR_ContractSizeSourceName(InpCommissionContractSizeSource), "SYMBOL_TRADE_CONTRACT_SIZE");
   g_inputs.AddNum("CommissionScheduleContractSize", InpCommissionScheduleContractSize, 0.0);
   g_inputs.Add("CommissionPricingBasis", LSR_CommissionBasisName(InpCommissionPricingBasis), "OPEN_PRICE");
   g_inputs.Add("CostScheduleLabel", LSR_CostScheduleLabelName(InpCostScheduleLabel), "CURRENT_OFFICIAL_SCHEDULE");
   g_inputs.Add("CostScheduleDate", InpCostScheduleDate, "2026-09-29");
   g_inputs.Add("SlippageMode", LSR_SlippageModeName(InpSlippageMode), "NONE");
   g_inputs.AddInt("EntrySlippagePoints", InpEntrySlippagePoints, 0);
   g_inputs.AddInt("ExitSlippagePoints", InpExitSlippagePoints, 0);
   g_inputs.Add("LatencyMode", LSR_LatencyModeName(InpLatencyMode), "ZERO");
   g_inputs.AddInt("FixedExecutionDelayMs", InpFixedExecutionDelayMs, 0);
   g_inputs.AddBool("MaxEntrySpreadEnabled", InpMaxEntrySpreadEnabled, false);
   g_inputs.AddNum("AccountInitialBalance", InpAccountInitialBalance, 100000.0);
   g_inputs.Add("AccountCurrency", InpAccountCurrency, "USD");
   g_inputs.AddBool("ExportReferenceBars", InpExportReferenceBars, true);
   //--- frozen research decisions (roadmap 2), recorded for the Run Card
   g_inputs.Add("SessionStart", LSR_SecToHHMM(ORB_SESSION_START_SEC), "16:30");
   g_inputs.Add("EndOfDay", LSR_SecToHHMM(ORB_EOD_SEC), "23:00");
   g_inputs.Add("OpeningRangeLengths", "OR5,OR15", "OR5,OR15");
   g_inputs.Add("ExitVariants", "R10_EOD,R2_EOD", "R10_EOD,R2_EOD");
   g_inputs.Add("EntryMethod", "DIRECTION_OF_OR_CANDLE", "DIRECTION_OF_OR_CANDLE");
   g_inputs.Add("NewsMode", "OBSERVE_ONLY", "OBSERVE_ONLY");
  }

//+------------------------------------------------------------------+
int Fail(const string what)
  {
   PrintFormat("ORB-1 INIT FAILED: %s", what);
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
   g_runContext = (MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION)) ? LSR_CONTEXT_RESEARCH : LSR_CONTEXT_LIVE;
   if(g_runContext != LSR_CONTEXT_RESEARCH)
      return Fail("ORB-1 is a research EA: run it in the Strategy Tester (live execution is ORB-5)");

   //--- Symbol specification and price units
   if(!LSR_CaptureSymbolSpec(_Symbol, TimeCurrent(), g_spec, err))
      return Fail(err);
   if(!LSR_ValidateSymbolSpec(g_spec, err))
      return Fail(err);
   if(!g_units.Init(InpStrategyPipSize, g_spec.point, g_spec.tick_size, err))
      return Fail(err);
   if(InpSignalBarPriceSource == LSR_PRICE_LAST && g_spec.chart_mode != SYMBOL_CHART_MODE_LAST)
      return Fail("SignalBarPriceSource LAST requested but the symbol's bars are not built from LAST");
   if(InpStopExecutionProfile != LSR_STOP_LIVE_NATIVE)
      return Fail("ORB proxies implement LIVE_NATIVE_STOP only (roadmap 2)");

   //--- Currency contract: no conversion rule is specified (LSR 0B.13)
   string accCcy = AccountInfoString(ACCOUNT_CURRENCY);
   if(accCcy != InpAccountCurrency)
      return Fail(StringFormat("account/tester deposit currency %s differs from AccountCurrency %s", accCcy, InpAccountCurrency));
   if(g_spec.currency_profit != InpAccountCurrency)
      return Fail(StringFormat("symbol profit currency %s differs from AccountCurrency %s; conversion is not specified (SPEC-INCOMPLETE)",
                               g_spec.currency_profit, InpAccountCurrency));

   //--- Sessions
   if(!g_sched.LoadFromSymbol(_Symbol, err))
      return Fail(err);

   //--- Costs
   LSR_CostModelDefaults(g_costs);
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
   if(!LSR_ValidateCostModel(g_costs, err))
      return Fail(err);

   //--- Account-rule profile: recorded only; applied from ORB-3
   if(!LSR_LoadAccountRuleProfile(LSR_ACCOUNT_FUNDEDNEXT_STELLAR_2STEP, LSR_ACCOUNT_RULES_APPLY_OFFICIAL, InpAccountInitialBalance,
                                  InpAccountCurrency, 0.10, g_acctProfile, err))
      return Fail(err);

   //--- Audit declaration (end date inclusive -> exclusive broker-day boundary)
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
   g_barRecon.Init(_Symbol, LSR_TF_M1, InpSignalBarPriceSource, g_spec.point);

   //--- Day ledger and proxies
   g_days.Init(g_spec.digits, g_spec.point);
   g_econ = new CLSR_MT5Economics(_Symbol);
   ORB_ProxyConfig pc;
   pc.point = g_spec.point;
   pc.tick_size = g_spec.tick_size;
   pc.contract_size = LSR_CommissionContractSize(g_costs, g_spec);
   pc.digits = g_spec.digits;
   pc.range_end_exclusive = g_rangeEndExclusive;
   g_proxies.Init(GetPointer(g_days), g_econ, GetPointer(g_sched), pc, g_costs);

   g_m1.Init(InpSignalBarPriceSource, g_spec.digits);
   g_m1Count = 0;
   g_firstM1 = 0;
   g_m1File = INVALID_HANDLE;
   if(InpExportReferenceBars)
     {
      g_m1File = FileOpen(g_out.Dir() + M1FileName(), FILE_WRITE | FILE_BIN | FILE_COMMON);
      if(g_m1File == INVALID_HANDLE)
         return Fail("cannot open the M1 reference-bar export file");
      ORB_WriteLine(g_m1File, "time,open,high,low,close,ticks");
     }

   LSR_TickAnomaliesReset(g_stream);
   g_dayClock.Reset();
   g_havePrev = false;
   g_seq = 0;
   g_ticks = 0;
   g_initTime = LSR_IsoTime(TimeCurrent());
   g_initialized = true;

   WriteContractSnapshots();
   PrintFormat("ORB-1 initialised: symbol=%s digits=%d point=%s commission=%s output=Common\\Files\\%s",
               _Symbol, g_spec.digits, LSR_NumStr(g_spec.point), LSR_CommissionModeName(g_costs.commission_mode), g_out.Dir());
   return INIT_SUCCEEDED;
  }

string M1FileName(void) { return "bars_M1_" + LSR_PriceSourceName(InpSignalBarPriceSource) + ".csv"; }

//+------------------------------------------------------------------+
void OnCompletedM1(const LSR_Bar &m1)
  {
   if(g_m1Count == 0)
      g_firstM1 = m1.time;
   g_m1Count++;
   if(g_m1File != INVALID_HANDLE)
      ORB_WriteLine(g_m1File, LSR_IsoTime(m1.time) + "," + DoubleToString(m1.open, g_spec.digits) + "," +
                    DoubleToString(m1.high, g_spec.digits) + "," + DoubleToString(m1.low, g_spec.digits) + "," +
                    DoubleToString(m1.close, g_spec.digits) + "," + IntegerToString(m1.ticks));
   g_days.OnM1(m1);
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
   g_ticks++;
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
   if(g_sched.IsInSession(q.time))
      g_ticksInSession++;
   g_dayClock.Observe(q.time);

   //--- one M1 stream feeds the day ledger; proxies see the completed bar first
   if(usable)
     {
      LSR_Bar m1;
      if(g_m1.OnQuote(q, m1))
         OnCompletedM1(m1);
      g_proxies.OnQuote(q);
      g_barRecon.OnQuote(q);
     }
   g_rawDriver.Advance(q.time);
  }

//+------------------------------------------------------------------+
void WriteContractSnapshots(void)
  {
   CLSR_Json j;
   j.BeginObject();
   j.KStr("contract_id", LSR_PHASE1_CONTRACT_ID);
   j.KStr("orb_contract_id", ORB_CONTRACT_ID);
   j.KStr("server_time_basis", LSR_SERVER_TIME_BASIS);
   j.Key("symbol_specification");
   LSR_WriteSymbolSpecJson(j, g_spec);
   j.KObj("price_units");
   j.KNum("strategy_pip_size", g_units.PipSize(), 8);
   j.KStr("strategy_pip_source", "explicit input (never inferred from SYMBOL_POINT)");
   j.KNum("symbol_point", g_units.Point(), 12);
   j.KNum("tick_size", g_units.TickSize(), 12);
   j.EndObject();
   j.Key("trading_session_schedule");
   g_sched.WriteJson(j);
   j.Key("declared_closed_market_calendar");
   g_calendar.WriteJson(j);
   j.EndObject();
   g_out.Write("symbol_session_snapshot.json", j.Text());

   j.Reset();
   j.BeginObject();
   j.Key("cost_model");
   LSR_WriteCostModelJson(j, g_costs, LSR_CommissionContractSize(g_costs, g_spec), InpStopExecutionProfile,
                          InpSignalBarPriceSource, InpStrategyPipSize);
   j.KObj("orb_proxy");
   j.KStr("contract_id", ORB_CONTRACT_ID);
   j.KStr("entry", "first usable tick at or after OR end + FixedExecutionDelayMs; Long at Ask, Short at Bid; one attempt per OR length per broker day");
   j.KStr("direction", "sign(OR_Close - OR_Open); equal = NO_TRADE_DOJI");
   j.KStr("stop", "Long OR_Low - EntrySpread (floor to tick), Short OR_High + EntrySpread (ceil to tick); LIVE_NATIVE_STOP");
   j.KStr("planned_risk_1r", "OrderCalcProfit loss entry -> SL at 1 lot + opening commission");
   j.KStr("target", "net TargetR x PlannedRisk1R, aligned outward; R10_EOD = 10R, R2_EOD = 2R");
   j.KStr("time_exit", "first tick at or after 23:00 broker; day without such a tick closes on its last tick (TIME_EXIT_EARLY_CLOSE when 23:00 is scheduled)");
   j.KStr("exit_precedence", "stop, target, time; stop and target on one tick = stop wins (STOP_AMBIGUOUS_BOTH_BARRIERS)");
   j.KInt("gap_seconds", ORB_GAP_EXIT_SECONDS);
   j.KStr("swap", "structurally 0: every proxy closes before the broker-day rollover");
   j.EndObject();
   j.EndObject();
   g_out.Write("execution_contract.json", j.Text());
  }

//+------------------------------------------------------------------+
//| Day ledger, proxy ledger, reference config and summary.          |
//| Returns the combined day-ledger checksum.                        |
//+------------------------------------------------------------------+
string FinalizeOrb(void)
  {
   LSR_Bar m1;
   if(g_m1.Flush(m1))
      OnCompletedM1(m1);
   g_proxies.Finish();
   if(g_m1File != INVALID_HANDLE)
     {
      FileClose(g_m1File);
      g_m1File = INVALID_HANDLE;
      g_out.RegisterFile(M1FileName());
     }

   CORB_EAQuarantine q;
   q.raw = GetPointer(g_rawAudit);
   q.file = GetPointer(g_quarantine);
   q.calendar = GetPointer(g_calendar);
   q.closures.AddCsvText(g_rawAudit.ClosuresCsv());
   g_days.Build(g_sched, q);

   string combined = "";
   for(int k = 0; k < ORB_ORLEN_COUNT; k++)
     {
      string name = ORB_OrLenName(k);
      if(!g_days.WriteCsv(g_out.Dir() + "orb_days_" + name + ".csv", k))
         PrintFormat("ORB: cannot write orb_days_%s.csv", name);
      g_daysSha[k] = g_out.RegisterFile("orb_days_" + name + ".csv");
      if(!g_proxies.WriteCsv(g_out.Dir() + "orb_trades_" + name + ".csv", k, q))
         PrintFormat("ORB: cannot write orb_trades_%s.csv", name);
      g_tradesSha[k] = g_out.RegisterFile("orb_trades_" + name + ".csv");
      combined += name + ":" + g_daysSha[k] + ";";
     }

   //--- configuration consumed by the independent Python reference
   CLSR_Json j;
   j.BeginObject();
   j.KStr("contract_id", ORB_CONTRACT_ID);
   j.KStr("symbol", _Symbol);
   j.KInt("digits", g_spec.digits);
   j.KNum("point", g_spec.point, 12);
   j.KNum("tick_size", g_spec.tick_size, 12);
   j.KNum("strategy_pip_size", InpStrategyPipSize, 8);
   j.KStr("signal_bar_price_source", LSR_PriceSourceName(InpSignalBarPriceSource));
   j.KStr("m1_bars_file", M1FileName());
   j.KInt("session_start_sec", ORB_SESSION_START_SEC);
   j.KInt("eod_sec", ORB_EOD_SEC);
   j.KArr("or_lengths");
   for(int k = 0; k < ORB_ORLEN_COUNT; k++)
     {
      j.BeginObject();
      j.KStr("name", ORB_OrLenName(k));
      j.KInt("minutes", ORB_OrLenMinutes(k));
      j.EndObject();
     }
   j.EndArray();
   j.KArr("exit_variants");
   for(int e = 0; e < ORB_EXIT_COUNT; e++)
      j.Str(ORB_ExitName(e));
   j.EndArray();
   j.KInt("rv_lookback", ORB_RV_LOOKBACK);
   j.KInt("nr_lookback", ORB_NR_LOOKBACK);
   j.KInt("sma_period", ORB_SMA_PERIOD);
   j.KInt("atr_period", ORB_ATR_D_PERIOD);
   j.KNum("f2_max_spread_to_stop", ORB_F2_MAX_SPREAD_TO_STOP, 6);
   j.KInt("latency_ms", g_costs.latency_mode == LSR_LATENCY_FIXED_MS ? g_costs.fixed_execution_delay_ms : 0);
   j.Key("trading_session_schedule");
   g_sched.WriteJson(j);
   j.KStr("quarantine_file", "data_quarantine_windows.csv");
   j.KStr("closures_file", "detected_market_closures.csv");
   j.KStr("declared_quarantine_file", InpDataQuarantineFile);
   j.KStr("declared_calendar_file", InpClosedMarketCalendarFile);
   j.EndObject();
   g_out.Write("reference_config.json", j.Text());

   //--- summary (counts only; roadmap ORB-1 gate)
   j.Reset();
   j.BeginObject();
   j.KStr("contract_id", ORB_CONTRACT_ID);
   j.KInt("m1_bars", g_m1Count);
   j.KStr("first_m1_bar", g_m1Count > 0 ? LSR_IsoTime(g_firstM1) : "");
   j.KInt("broker_days_with_bars", g_days.DayCount());
   j.KArr("or_lengths");
   for(int k = 0; k < ORB_ORLEN_COUNT; k++)
     {
      j.BeginObject();
      j.KStr("or_length", ORB_OrLenName(k));
      j.KInt("day_rows", g_days.CountRows(k));
      j.KObj("decisions");
      for(int d = 0; d < ORB_DECISION_COUNT; d++)
         if(d != ORB_NO_TRADE_INVALID_STOP)
            j.KInt(ORB_DecisionName(d), g_days.CountDecision(k, d));
      j.EndObject();
      j.KObj("proxy_rows_by_reason");
      string reasons[] = {"TP", "STOP", "STOP_AMBIGUOUS_BOTH_BARRIERS", "TIME_EXIT", "TIME_EXIT_EARLY_CLOSE", "GAP_TP", "GAP_STOP",
                          "GAP_CROSSED_BOTH_BARRIERS", "GAP_TIME_EXIT", "END_OF_DATA", "NO_TRADE_INVALID_STOP", "NO_EXECUTABLE_TICK"};
      for(int r = 0; r < ArraySize(reasons); r++)
         j.KInt(reasons[r], g_proxies.CountReason(k, reasons[r]));
      j.EndObject();
      j.KStr("orb_days_sha256", g_daysSha[k]);
      j.KStr("orb_trades_sha256", g_tradesSha[k]);
      j.EndObject();
     }
   j.EndArray();
   j.EndObject();
   g_out.Write("orb_summary.json", j.Text());
   return LSR_Sha256Hex(combined);
  }

//+------------------------------------------------------------------+
void WriteFinalPackage(const int deinitReason)
  {
   if(g_havePrev)
      g_rawDriver.Flush((datetime)(g_stream.last_msc / 1000));
   string ledgerChecksum = FinalizeOrb();

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
   j.EndObject();
   j.Key("processed_tick_stream");
   LSR_WriteTickAnomaliesJson(j, g_stream);
   j.KObj("session_counts");
   j.KInt("ticks_in_actual_trade_session", g_ticksInSession);
   j.EndObject();
   j.Key("raw_real_tick_audit");
   g_rawAudit.WriteJson(j);
   j.KArr("signal_timeframe_ohlc_reconciliation");
   g_barRecon.WriteJson(j);
   j.EndArray();
   j.EndObject();
   g_out.Write("data_quality_report.json", j.Text());

   g_out.Write("potential_fallback_minutes.csv", g_rawAudit.FallbackCsv());
   g_out.Write("critical_data_gaps.csv", g_rawAudit.GapsCsv());
   g_out.Write("detected_market_closures.csv", g_rawAudit.ClosuresCsv());
   g_out.Write("data_quarantine_windows.csv", g_rawAudit.QuarantineCsv());
   g_out.Write("timeframe_bar_reconciliation.csv",
               "timeframe,bar_time,kind,built_open,built_high,built_low,built_close,platform_open,platform_high,platform_low,platform_close\n" +
               g_barRecon.CsvRows());
   g_out.Write("run_card_inputs.txt", g_inputs.RunCardText());

   //--- DataManifest (written last; indexes every file above)
   j.Reset();
   j.BeginObject();
   j.KStr("schema_version", LSR_MANIFEST_SCHEMA_VERSION);
   j.KStr("engine", LSR_ENGINE_NAME);
   j.KStr("phase", "ORB_1_DAY_LAYER_AND_PROXIES");
   j.KStr("contract_id", LSR_PHASE1_CONTRACT_ID);
   j.KStr("experiment_id", InpExperimentId);
   j.KStr("run_context", LSR_RunContextName(g_runContext));
   j.KStr("init_broker_time", g_initTime);
   j.KStr("finalized_broker_time", LSR_IsoTime(TimeCurrent()));
   j.KInt("deinit_reason", deinitReason);
   j.KObj("code");
   j.KStr("code_sha", InpCodeCommitSHA);
   j.KStr("roadmap_file", ORB_ROADMAP_FILENAME);
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
   j.KStr("timeframe_set", "M1");
   j.KStr("live_timeframe", "M1");
   j.KStr("active_timeframes", "M1");
   j.KStr("isolation", "one M1 BID stream feeds the day ledger; OR5 and OR15 proxies are independent");
   j.EndObject();
   j.KObj("range");
   j.KTime("requested_start", g_rangeStart);
   j.KTime("requested_end_exclusive", g_rangeEndExclusive);
   j.KStr("actual_first_tick", LSR_IsoTimeMsc(g_stream.first_msc));
   j.KStr("actual_last_tick", LSR_IsoTimeMsc(g_stream.last_msc));
   j.EndObject();
   j.KObj("tick_source");
   j.KStr("execution_stream", "OnTick SymbolInfoTick, source order preserved (sequence numbers)");
   j.KStr("raw_audit_source", "CopyTicksRange COPY_TICKS_ALL + CopyRates M1");
   j.KNum("potential_fallback_minute_share", g_rawAudit.FallbackShare(), 8);
   j.KInt("critical_data_gap_count", g_rawAudit.CriticalGapCount());
   j.KInt("auto_detected_market_closures", g_rawAudit.ClosureCount());
   j.KNum("quarantine_share", g_rawAudit.QuarantineShare(), 8);
   j.KStr("data_gate", LSR_DataGateName(g_rawAudit.Gate()));
   j.KStr("data_quarantine_file", InpDataQuarantineFile);
   j.KInt("data_quarantine_windows_loaded", g_quarantine.Count());
   j.EndObject();
   j.KObj("account_rules");
   j.KStr("profile", LSR_AccountRuleProfileName(g_acctProfile.profile));
   j.KNum("initial_balance", g_acctProfile.initial_balance, 2);
   j.KStr("currency", g_acctProfile.currency);
   j.KStr("note", "recorded only; account rules apply from ORB-3");
   j.EndObject();
   j.KObj("execution_model");
   j.KStr("stop_execution_profile", LSR_StopProfileName(InpStopExecutionProfile));
   j.KStr("commission", LSR_CommissionModeName(g_costs.commission_mode) + " @ " + LSR_NumStr(g_costs.commission_rate_percent) + "%, " +
          LSR_CostScheduleLabelName(g_costs.schedule_label) + " " + g_costs.schedule_date);
   j.KStr("slippage", LSR_SlippageModeName(g_costs.slippage_mode) + " entry=" + IntegerToString(g_costs.entry_slippage_points) +
          " exit=" + IntegerToString(g_costs.exit_slippage_points));
   j.KStr("latency", LSR_LatencyModeName(g_costs.latency_mode) + " " + IntegerToString(g_costs.fixed_execution_delay_ms) + "ms");
   j.EndObject();
   j.KArr("scenario_ids");
   j.Str("BASELINE");
   j.EndArray();
   j.KInt("declared_trial_count", 16);
   j.KArr("random_seeds");
   j.EndArray();
   j.KStr("ledger_checksum", ledgerChecksum);
   j.KStr("ledger_note", "sha256 over '<ORLEN>:<sha256(orb_days_<ORLEN>.csv)>;' for OR5 then OR15");
   j.KArr("per_timeframe_state");
   j.BeginObject();
   j.KStr("timeframe", "M1");
   j.KInt("ticks", g_ticks);
   j.KInt("broker_day_resets", g_dayClock.ResetCount());
   j.KNum("equity", InpAccountInitialBalance, 2);
   j.KStr("account_rule_state", "OK");
   j.EndObject();
   j.EndArray();
   j.KObj("orb");
   j.KStr("contract_id", ORB_CONTRACT_ID);
   j.KStr("roadmap_file", ORB_ROADMAP_FILENAME);
   j.KStr("primary_trial", "OR5/UNFILTERED/R10_EOD");
   j.KStr("co_reported_trial", "OR5/BASE/R10_EOD");
   j.KArr("or_lengths");
   for(int k = 0; k < ORB_ORLEN_COUNT; k++)
     {
      j.BeginObject();
      j.KStr("or_length", ORB_OrLenName(k));
      j.KInt("day_rows", g_days.CountRows(k));
      j.KInt("trade_days", g_days.CountDecision(k, ORB_TRADE));
      j.KStr("orb_days_sha256", g_daysSha[k]);
      j.KStr("orb_trades_sha256", g_tradesSha[k]);
      j.EndObject();
     }
   j.EndArray();
   j.EndObject();
   j.Key("inputs");
   g_inputs.WriteJson(j);
   j.Key("files");
   g_out.WriteIndexJson(j);
   j.EndObject();
   string sha = g_out.Write("manifest.json", j.Text());

   PrintFormat("ORB-1 package written to Common\\Files\\%s (manifest sha256 %s, write failures %d)", g_out.Dir(), sha, g_out.Failures());
   PrintFormat("ORB data gate: %s  fallback share=%s  quarantine share=%s  gaps=%I64d  auto closures=%I64d",
               LSR_DataGateName(g_rawAudit.Gate()), LSR_NumStr(g_rawAudit.FallbackShare(), 6), LSR_NumStr(g_rawAudit.QuarantineShare(), 6),
               g_rawAudit.CriticalGapCount(), g_rawAudit.ClosureCount());
   for(int k = 0; k < ORB_ORLEN_COUNT; k++)
      PrintFormat("ORB %s: day rows=%d TRADE=%d", ORB_OrLenName(k), g_days.CountRows(k), g_days.CountDecision(k, ORB_TRADE));
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_initialized)
      WriteFinalPackage(reason);
   if(g_m1File != INVALID_HANDLE)
     {
      FileClose(g_m1File);
      g_m1File = INVALID_HANDLE;
     }
   if(g_econ != NULL)
     {
      delete g_econ;
      g_econ = NULL;
     }
   g_initialized = false;
  }
//+------------------------------------------------------------------+
