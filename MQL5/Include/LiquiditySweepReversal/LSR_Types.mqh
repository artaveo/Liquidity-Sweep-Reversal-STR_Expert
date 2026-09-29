//+------------------------------------------------------------------+
//| LSR_Types.mqh                                                    |
//| Liquidity Sweep Reversal — Phase 1 shared enums and constants.   |
//| Every value here is taken from Liquidity_Sweep_Reversal_Roadmap. |
//+------------------------------------------------------------------+
#ifndef LSR_TYPES_MQH
#define LSR_TYPES_MQH

#define LSR_ENGINE_NAME            "LiquiditySweepReversal"
#define LSR_PHASE1_CONTRACT_ID     "LSR-PHASE1-CONTRACT-2026-09-28"
#define LSR_ROADMAP_FILENAME       "Liquidity_Sweep_Reversal_Roadmap.md"
#define LSR_SECONDS_PER_DAY        86400
#define LSR_EPS                    1e-9
#define LSR_MONEY_EPS              1e-8

//--- Frozen session constants (roadmap 1.3). Not inputs.
#define LSR_LATE_BLOCK_START_SEC   (21*3600+30*60)   // 21:30
#define LSR_NY_WINDOW_START_SEC    (16*3600+30*60)   // 16:30
#define LSR_NY_WINDOW_END_SEC      (21*3600+30*60)   // 21:30 (exclusive)

//--- Pre-registered data gates (roadmap 1.4). Not inputs.
#define LSR_MAX_FALLBACK_MINUTE_SHARE        0.01
#define LSR_CRITICAL_DATA_GAP_THRESHOLD_MIN  5
#define LSR_MAX_CRITICAL_DATA_GAP_COUNT      0

//--- Pre-registered stress values (roadmap 1.7). Not optimized.
#define LSR_SLIPPAGE_STRESS_POINTS_LIST      "1,2,5"
#define LSR_LATENCY_STRESS_MS_LIST           "100,250,500"

//--- Roadmap baseline commission rate (roadmap 1.7).
#define LSR_BASELINE_COMMISSION_RATE_PERCENT 0.0016

//+------------------------------------------------------------------+
//| Timeframes (roadmap 1.1). Enum order is the canonical order.     |
//+------------------------------------------------------------------+
enum ENUM_LSR_TIMEFRAME
  {
   LSR_TF_M1  = 0,
   LSR_TF_M5  = 1,
   LSR_TF_M15 = 2,
   LSR_TF_M30 = 3,
   LSR_TF_H1  = 4
  };
#define LSR_TF_COUNT 5

enum ENUM_LSR_RUN_CONTEXT
  {
   LSR_CONTEXT_RESEARCH = 0,   // Strategy Tester: every TimeframeSet member, isolated state
   LSR_CONTEXT_LIVE     = 1    // Live chart: exactly one fixed LiveTimeframe
  };

//+------------------------------------------------------------------+
//| Sessions (roadmap 1.3)                                           |
//+------------------------------------------------------------------+
enum ENUM_LSR_SESSION_MODE
  {
   LSR_SESSION_FULL_DAY_EXCEPT_LATE_SPREAD = 1, // Mode 1 — Full Day Except Late Spread Window
   LSR_SESSION_NY_WINDOW                   = 2, // Mode 2 — NY Window [16:30,21:30)
   LSR_SESSION_CUSTOM                      = 3  // Mode 3 — Custom [TradeStartTime,TradeEndTime)
  };

//+------------------------------------------------------------------+
//| Price source / execution profile (roadmap 0B.16, 0.4)            |
//+------------------------------------------------------------------+
enum ENUM_LSR_PRICE_SOURCE
  {
   LSR_PRICE_BID  = 0,  // BID (baseline)
   LSR_PRICE_LAST = 1   // LAST (distinct research study state)
  };

enum ENUM_LSR_STOP_PROFILE
  {
   LSR_STOP_LIVE_NATIVE  = 0, // LIVE_NATIVE_STOP (primary)
   LSR_STOP_RESEARCH_MID = 1  // RESEARCH_MID_STOP (sensitivity only)
  };

enum ENUM_LSR_DIRECTION
  {
   LSR_DIR_LONG  = 1,
   LSR_DIR_SHORT = -1
  };

//+------------------------------------------------------------------+
//| Costs (roadmap 1.7)                                              |
//+------------------------------------------------------------------+
enum ENUM_LSR_COMMISSION_MODE
  {
   LSR_COMMISSION_FUNDEDNEXT_OFFICIAL_METALS  = 0, // FUNDEDNEXT_OFFICIAL_METALS
   LSR_COMMISSION_FUNDEDNEXT_OFFICIAL_INDICES = 1  // FUNDEDNEXT_OFFICIAL_INDICES (ORB roadmap 1.3)
  };

enum ENUM_LSR_CONTRACT_SIZE_SOURCE
  {
   LSR_CONTRACT_SIZE_SYMBOL          = 0, // SYMBOL_TRADE_CONTRACT_SIZE
   LSR_CONTRACT_SIZE_BROKER_SCHEDULE = 1  // Frozen broker schedule value
  };

enum ENUM_LSR_COMMISSION_BASIS
  {
   LSR_COMMISSION_BASIS_OPEN_PRICE = 0 // OPEN_PRICE
  };

enum ENUM_LSR_COST_SCHEDULE_LABEL
  {
   LSR_COST_SCHEDULE_CURRENT_OFFICIAL = 0, // Current official schedule (not historical)
   LSR_COST_SCHEDULE_DATED_HISTORICAL = 1  // Dated historical schedule
  };

enum ENUM_LSR_SLIPPAGE_MODE
  {
   LSR_SLIPPAGE_NONE                 = 0, // NONE
   LSR_SLIPPAGE_FIXED_ADVERSE_POINTS = 1  // FIXED_ADVERSE_POINTS
  };

enum ENUM_LSR_LATENCY_MODE
  {
   LSR_LATENCY_ZERO     = 0, // ZERO
   LSR_LATENCY_FIXED_MS = 1  // FIXED_MS
  };

enum ENUM_LSR_COST_GATE_REASON
  {
   LSR_COST_GATE_PASS                 = 0,
   LSR_COST_GATE_SPREAD_TOO_WIDE      = 1,
   LSR_COST_GATE_NONSPREAD_COST_TOO_HIGH = 2,
   LSR_COST_GATE_INVALID_INPUT        = 3
  };

//+------------------------------------------------------------------+
//| Account rules (roadmap 0B.10)                                    |
//+------------------------------------------------------------------+
enum ENUM_LSR_ACCOUNT_RULE_PROFILE
  {
   LSR_ACCOUNT_FUNDEDNEXT_STELLAR_2STEP = 0 // FUNDEDNEXT_STELLAR_2STEP
  };

enum ENUM_LSR_ACCOUNT_RULE_MODE
  {
   LSR_ACCOUNT_RULES_APPLY_OFFICIAL = 0 // APPLY_OFFICIAL_ACCOUNT_RULES
  };

enum ENUM_LSR_ACCOUNT_RULE_STATE
  {
   LSR_ACCOUNT_OK          = 0,
   LSR_ACCOUNT_NEAR_BREACH = 1,
   LSR_ACCOUNT_BREACH      = 2
  };

//+------------------------------------------------------------------+
//| Risk admission (roadmap 0B.9, 0C.9, 1.8–1.11)                    |
//+------------------------------------------------------------------+
enum ENUM_LSR_PROFIT_TARGET_BASIS
  {
   LSR_PROFIT_TARGET_NET_EQUITY = 0 // NET_EQUITY
  };

enum ENUM_LSR_ADMISSION_REASON
  {
   LSR_ADMIT_OK                            = 0,
   LSR_REJECT_INVALID_PROPOSAL             = 1,
   LSR_REJECT_ACCOUNT_RULE_BREACH          = 2,
   LSR_REJECT_ACCOUNT_RULE_NEAR_BREACH     = 3,
   LSR_REJECT_DAILY_PROFIT_TARGET_REACHED  = 4,
   LSR_REJECT_MAX_CONCURRENT_POSITIONS     = 5,
   LSR_REJECT_DIRECTIONAL_POSITION_CAP     = 6,
   LSR_REJECT_DAILY_LOSS_FLOOR             = 7,
   LSR_REJECT_AGGREGATE_RISK_CEILING       = 8,
   LSR_REJECT_DIRECTIONAL_RISK_CEILING     = 9
  };

enum ENUM_LSR_SIZING_REASON
  {
   LSR_SIZING_OK                        = 0,
   LSR_SIZING_INVALID_INPUT             = 1,
   LSR_SIZING_INVALID_STOP_SIDE         = 2,
   LSR_SIZING_ECONOMICS_UNAVAILABLE     = 3,
   LSR_SIZING_VOLUME_BELOW_MIN          = 4,
   LSR_SIZING_INSUFFICIENT_MARGIN       = 5,
   LSR_SIZING_SPEC_INCOMPLETE_MID_STOP  = 6
  };

//+------------------------------------------------------------------+
//| Data audit (roadmap 1.4)                                         |
//+------------------------------------------------------------------+
enum ENUM_LSR_MINUTE_CLASS
  {
   LSR_MINUTE_OK                        = 0,
   LSR_MINUTE_PFM_NO_TICKS_NO_BAR       = 1, // no-tick/sparse data
   LSR_MINUTE_PFM_NO_TICKS_WITH_BAR     = 2, // potential tester fallback
   LSR_MINUTE_PFM_RECONCILIATION_FAILED = 3  // raw ticks contradict the M1 bar
  };

enum ENUM_LSR_DATA_GATE
  {
   LSR_DATA_PASSED           = 0,
   LSR_DATA_FAILED           = 1,
   LSR_DATA_AUDIT_INCOMPLETE = 2
  };

//+------------------------------------------------------------------+
//| Enum → roadmap string                                            |
//+------------------------------------------------------------------+
string LSR_SessionModeName(const ENUM_LSR_SESSION_MODE m)
  {
   switch(m)
     {
      case LSR_SESSION_FULL_DAY_EXCEPT_LATE_SPREAD: return "FULL_DAY_EXCEPT_LATE_SPREAD_WINDOW";
      case LSR_SESSION_NY_WINDOW:                   return "NY_WINDOW";
      case LSR_SESSION_CUSTOM:                      return "CUSTOM";
     }
   return "UNKNOWN";
  }

string LSR_PriceSourceName(const ENUM_LSR_PRICE_SOURCE s)
  { return s == LSR_PRICE_BID ? "BID" : "LAST"; }

string LSR_StopProfileName(const ENUM_LSR_STOP_PROFILE p)
  { return p == LSR_STOP_LIVE_NATIVE ? "LIVE_NATIVE_STOP" : "RESEARCH_MID_STOP"; }

string LSR_DirectionName(const ENUM_LSR_DIRECTION d)
  { return d == LSR_DIR_LONG ? "LONG" : "SHORT"; }

string LSR_CommissionModeName(const ENUM_LSR_COMMISSION_MODE m)
  { return m == LSR_COMMISSION_FUNDEDNEXT_OFFICIAL_INDICES ? "FUNDEDNEXT_OFFICIAL_INDICES" : "FUNDEDNEXT_OFFICIAL_METALS"; }

string LSR_ContractSizeSourceName(const ENUM_LSR_CONTRACT_SIZE_SOURCE s)
  { return s == LSR_CONTRACT_SIZE_SYMBOL ? "SYMBOL_TRADE_CONTRACT_SIZE" : "BROKER_SCHEDULE"; }

string LSR_CommissionBasisName(const ENUM_LSR_COMMISSION_BASIS b)
  { return "OPEN_PRICE"; }

string LSR_CostScheduleLabelName(const ENUM_LSR_COST_SCHEDULE_LABEL l)
  { return l == LSR_COST_SCHEDULE_CURRENT_OFFICIAL ? "CURRENT_OFFICIAL_SCHEDULE" : "DATED_HISTORICAL_SCHEDULE"; }

string LSR_SlippageModeName(const ENUM_LSR_SLIPPAGE_MODE m)
  { return m == LSR_SLIPPAGE_NONE ? "NONE" : "FIXED_ADVERSE_POINTS"; }

string LSR_LatencyModeName(const ENUM_LSR_LATENCY_MODE m)
  { return m == LSR_LATENCY_ZERO ? "ZERO" : "FIXED_MS"; }

string LSR_AccountRuleProfileName(const ENUM_LSR_ACCOUNT_RULE_PROFILE p)
  { return "FUNDEDNEXT_STELLAR_2STEP"; }

string LSR_AccountRuleModeName(const ENUM_LSR_ACCOUNT_RULE_MODE m)
  { return "APPLY_OFFICIAL_ACCOUNT_RULES"; }

string LSR_AccountRuleStateName(const ENUM_LSR_ACCOUNT_RULE_STATE s)
  {
   switch(s)
     {
      case LSR_ACCOUNT_OK:          return "OK";
      case LSR_ACCOUNT_NEAR_BREACH: return "NEAR_BREACH";
      case LSR_ACCOUNT_BREACH:      return "BREACH";
     }
   return "UNKNOWN";
  }

string LSR_ProfitTargetBasisName(const ENUM_LSR_PROFIT_TARGET_BASIS b)
  { return "NET_EQUITY"; }

string LSR_RunContextName(const ENUM_LSR_RUN_CONTEXT c)
  { return c == LSR_CONTEXT_RESEARCH ? "RESEARCH_TESTER" : "LIVE"; }

string LSR_AdmissionReasonName(const ENUM_LSR_ADMISSION_REASON r)
  {
   switch(r)
     {
      case LSR_ADMIT_OK:                           return "ADMITTED";
      case LSR_REJECT_INVALID_PROPOSAL:            return "INVALID_PROPOSAL";
      case LSR_REJECT_ACCOUNT_RULE_BREACH:         return "ACCOUNT_RULE_BREACH";
      case LSR_REJECT_ACCOUNT_RULE_NEAR_BREACH:    return "ACCOUNT_RULE_NEAR_BREACH";
      case LSR_REJECT_DAILY_PROFIT_TARGET_REACHED: return "DAILY_PROFIT_TARGET_REACHED";
      case LSR_REJECT_MAX_CONCURRENT_POSITIONS:    return "MAX_CONCURRENT_POSITIONS";
      case LSR_REJECT_DIRECTIONAL_POSITION_CAP:    return "DIRECTIONAL_POSITION_CAP";
      case LSR_REJECT_DAILY_LOSS_FLOOR:            return "DAILY_LOSS_FLOOR";
      case LSR_REJECT_AGGREGATE_RISK_CEILING:      return "AGGREGATE_RISK_CEILING";
      case LSR_REJECT_DIRECTIONAL_RISK_CEILING:    return "DIRECTIONAL_RISK_CEILING";
     }
   return "UNKNOWN";
  }

string LSR_SizingReasonName(const ENUM_LSR_SIZING_REASON r)
  {
   switch(r)
     {
      case LSR_SIZING_OK:                       return "OK";
      case LSR_SIZING_INVALID_INPUT:            return "INVALID_INPUT";
      case LSR_SIZING_INVALID_STOP_SIDE:        return "INVALID_STOP_SIDE";
      case LSR_SIZING_ECONOMICS_UNAVAILABLE:    return "ECONOMICS_UNAVAILABLE";
      case LSR_SIZING_VOLUME_BELOW_MIN:         return "VOLUME_BELOW_MIN";
      case LSR_SIZING_INSUFFICIENT_MARGIN:      return "INSUFFICIENT_MARGIN";
      case LSR_SIZING_SPEC_INCOMPLETE_MID_STOP: return "SPEC_INCOMPLETE_RESEARCH_MID_STOP_BUFFER";
     }
   return "UNKNOWN";
  }

string LSR_CostGateReasonName(const ENUM_LSR_COST_GATE_REASON r)
  {
   switch(r)
     {
      case LSR_COST_GATE_PASS:                    return "PASS";
      case LSR_COST_GATE_SPREAD_TOO_WIDE:         return "ENTRY_SPREAD_TOO_WIDE";
      case LSR_COST_GATE_NONSPREAD_COST_TOO_HIGH: return "KNOWN_NONSPREAD_COST_TOO_HIGH";
      case LSR_COST_GATE_INVALID_INPUT:           return "INVALID_INPUT";
     }
   return "UNKNOWN";
  }

string LSR_MinuteClassName(const ENUM_LSR_MINUTE_CLASS c)
  {
   switch(c)
     {
      case LSR_MINUTE_OK:                        return "OK";
      case LSR_MINUTE_PFM_NO_TICKS_NO_BAR:       return "PFM_NO_TICKS_NO_BAR";
      case LSR_MINUTE_PFM_NO_TICKS_WITH_BAR:     return "PFM_NO_TICKS_WITH_BAR";
      case LSR_MINUTE_PFM_RECONCILIATION_FAILED: return "PFM_RECONCILIATION_FAILED";
     }
   return "UNKNOWN";
  }

string LSR_DataGateName(const ENUM_LSR_DATA_GATE g)
  {
   switch(g)
     {
      case LSR_DATA_PASSED:           return "DATA-PASSED";
      case LSR_DATA_FAILED:           return "DATA-FAILED";
      case LSR_DATA_AUDIT_INCOMPLETE: return "AUDIT-INCOMPLETE";
     }
   return "UNKNOWN";
  }

#endif // LSR_TYPES_MQH
//+------------------------------------------------------------------+
