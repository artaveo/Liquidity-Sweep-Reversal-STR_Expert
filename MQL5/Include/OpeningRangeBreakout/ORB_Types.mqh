//+------------------------------------------------------------------+
//| ORB_Types.mqh                                                    |
//| Opening Range Breakout — enums and frozen constants.             |
//| Every value is taken from Opening_Range_Breakout_Roadmap.md      |
//| Section 2 (owner-approved, pre-registered). Not inputs.          |
//+------------------------------------------------------------------+
#ifndef ORB_TYPES_MQH
#define ORB_TYPES_MQH

#define ORB_CONTRACT_ID            "ORB-PHASE1-CONTRACT-2026-09-29"
#define ORB_ROADMAP_FILENAME       "Opening_Range_Breakout_Roadmap.md"
#define ORB_OUTPUT_ROOT            "ORB"

//--- Session clock (roadmap 2): 16:30 broker = 09:30 New York, 23:00 broker = 16:00 New York.
#define ORB_SESSION_START_SEC      (16*3600+30*60)
#define ORB_EOD_SEC                (23*3600)

//--- Filters and daily features (roadmap 2.1, 3). Pre-registered; never tuned.
#define ORB_RV_LOOKBACK            14      // F1: previous valid sessions of the same OR length
#define ORB_NR_LOOKBACK            7       // F3: NR7
#define ORB_SMA_PERIOD             50      // F5: daily SMA50 of closes
#define ORB_ATR_D_PERIOD           14      // F4 diagnostic: Wilder ATR14 on daily bars
#define ORB_F2_MAX_SPREAD_TO_STOP  0.10    // F2: EntrySpread <= 0.10 x |Entry - SL|
#define ORB_GAP_EXIT_SECONDS       300     // GAP_* marking (LSR 3.8 item 3)
#define ORB_NEWS_STATE             "NO_CALENDAR_OBSERVE_ONLY"

//+------------------------------------------------------------------+
//| Opening-range lengths (roadmap 2). Enum order is canonical.      |
//+------------------------------------------------------------------+
enum ENUM_ORB_ORLEN
  {
   ORB_OR5  = 0,  // OR5  [16:30, 16:35) — the paper
   ORB_OR15 = 1   // OR15 [16:30, 16:45) — owner variant
  };
#define ORB_ORLEN_COUNT 2

string ORB_OrLenName(const int k)  { return k == ORB_OR5 ? "OR5" : "OR15"; }
int    ORB_OrLenMinutes(const int k) { return k == ORB_OR5 ? 5 : 15; }

//+------------------------------------------------------------------+
//| Exit variants (roadmap 2): net target in R, else end of day.     |
//+------------------------------------------------------------------+
enum ENUM_ORB_EXIT
  {
   ORB_EXIT_R10_EOD = 0,  // R10_EOD — the paper's rule
   ORB_EXIT_R2_EOD  = 1   // R2_EOD  — owner variant
  };
#define ORB_EXIT_COUNT 2

string ORB_ExitName(const int e) { return e == ORB_EXIT_R10_EOD ? "R10_EOD" : "R2_EOD"; }
double ORB_ExitTargetR(const int e) { return e == ORB_EXIT_R10_EOD ? 10.0 : 2.0; }

//+------------------------------------------------------------------+
//| Day decision codes (roadmap 3 item 5). The day ledger holds the  |
//| codes derivable from BID M1 bars; NO_TRADE_INVALID_STOP needs the|
//| entry tick and is recorded on the proxy rows (roadmap 3 item 5a).|
//+------------------------------------------------------------------+
enum ENUM_ORB_DECISION
  {
   ORB_TRADE                     = 0,
   ORB_NO_TRADE_DOJI             = 1,
   ORB_NO_TRADE_INCOMPLETE_RANGE = 2,
   ORB_NO_TRADE_QUARANTINE       = 3,
   ORB_NO_TRADE_WARMUP           = 4,
   ORB_NO_TRADE_NO_TICK          = 5,
   ORB_NO_TRADE_INVALID_STOP     = 6
  };
#define ORB_DECISION_COUNT 7

string ORB_DecisionName(const int d)
  {
   switch(d)
     {
      case ORB_TRADE:                     return "TRADE";
      case ORB_NO_TRADE_DOJI:             return "NO_TRADE_DOJI";
      case ORB_NO_TRADE_INCOMPLETE_RANGE: return "NO_TRADE_INCOMPLETE_RANGE";
      case ORB_NO_TRADE_QUARANTINE:       return "NO_TRADE_QUARANTINE";
      case ORB_NO_TRADE_WARMUP:           return "NO_TRADE_WARMUP";
      case ORB_NO_TRADE_NO_TICK:          return "NO_TRADE_NO_TICK";
      case ORB_NO_TRADE_INVALID_STOP:     return "NO_TRADE_INVALID_STOP";
     }
   return "UNKNOWN";
  }

//--- F4 diagnostic buckets of ORWidth / ATR14_D (roadmap 2.1).
string ORB_WidthBucket(const bool ok, const double ratio)
  {
   if(!ok)
      return "NA";
   if(ratio < 0.05)
      return "LT_0.05";
   if(ratio < 0.10)
      return "0.05_0.10";
   if(ratio < 0.20)
      return "0.10_0.20";
   return "GE_0.20";
  }

#endif // ORB_TYPES_MQH
//+------------------------------------------------------------------+
