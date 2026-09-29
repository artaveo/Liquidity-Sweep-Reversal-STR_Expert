//+------------------------------------------------------------------+
//| LSR_Phase1_Tests.mq5                                             |
//| Blocking deterministic tests for the Phase 1 contract.           |
//| Pure fixtures only: no broker data, no trading, any chart works. |
//| Result: Experts log + Common\Files\LSR\tests\phase1_tests.txt    |
//+------------------------------------------------------------------+
#property copyright   "Liquidity Sweep Reversal"
#property version     "1.00"
#property description "Phase 1 blocking tests (no trading)"
#property script_show_inputs

#include "../../Include/LiquiditySweepReversal/LSR_Phase2.mqh"

input bool InpCloseTerminalWhenDone = false; // Close terminal after the run (CI use)

int    g_pass = 0;
int    g_fail = 0;
string g_report = "";
string g_suite = "";

void Suite(const string name)
  {
   g_suite = name;
   g_report += "\n[" + name + "]\n";
  }

void Check(const bool cond, const string name)
  {
   if(cond)
     {
      g_pass++;
      g_report += "  PASS " + name + "\n";
     }
   else
     {
      g_fail++;
      g_report += "  FAIL " + name + "\n";
      PrintFormat("FAIL [%s] %s", g_suite, name);
     }
  }

void CheckNear(const double actual, const double expected, const double tol, const string name)
  {
   bool ok = MathAbs(actual - expected) <= tol;
   Check(ok, name + (ok ? "" : StringFormat(" (actual %.10f expected %.10f)", actual, expected)));
  }

void CheckStr(const string actual, const string expected, const string name)
  {
   bool ok = (actual == expected);
   Check(ok, name + (ok ? "" : " (actual '" + actual + "' expected '" + expected + "')"));
  }

void MkTick(MqlTick &k, const datetime t, const int ms, const double bid, const double ask)
  {
   ZeroMemory(k);
   k.time = t;
   k.time_msc = (long)t * 1000 + ms;
   k.bid = bid;
   k.ask = ask;
   k.flags = TICK_FLAG_BID | TICK_FLAG_ASK;
  }

void MkQuote(LSR_Quote &q, const double bid, const double ask)
  {
   q.seq = 1;
   q.time = D'2026.01.05 10:00';
   q.time_msc = (long)q.time * 1000;
   q.bid = bid;
   q.ask = ask;
   q.last = 0.0;
   q.volume = 0;
   q.flags = 0;
  }

//--- Mon–Fri [01:00, 23:57), weekend closed — an XAUUSD-like broker schedule.
void BuildGoldSchedule(CLSR_SessionSchedule &s)
  {
   string e;
   s.Clear();
   for(int d = 1; d <= 5; d++)
      s.AddBrokerInterval(d, 3600, 23 * 3600 + 57 * 60, e);
  }

//+------------------------------------------------------------------+
void TestJson(void)
  {
   Suite("JSON / hashing");
   CheckStr(LSR_NumStr(1.50), "1.5", "NumStr strips trailing zeros");
   CheckStr(LSR_NumStr(2.0), "2", "NumStr integer value");
   CheckStr(LSR_NumStr(-0.0), "0", "NumStr negative zero");
   CheckStr(LSR_NumStr(7.145952, 8), "7.145952", "NumStr 8 digits");
   CheckStr(CLSR_Json::Escape("a\"b\\c\nd"), "a\\\"b\\\\c\\nd", "Escape quote, backslash, newline");
   CLSR_Json j;
   j.BeginObject();
   j.KInt("a", 1);
   j.KArr("b");
   j.Bool(true);
   j.Null();
   j.Str("x");
   j.EndArray();
   j.KObj("c");
   j.EndObject();
   j.EndObject();
   CheckStr(j.Text(), "{\"a\":1,\"b\":[true,null,\"x\"],\"c\":{}}", "builder commas and nesting");
   CheckStr(LSR_Sha256Hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256('abc')");
   CheckStr(LSR_IsoTimeMsc((long)D'2026.01.05 01:02:03' * 1000 + 45), "2026-01-05T01:02:03.045", "ISO time with ms");
  }

//+------------------------------------------------------------------+
void TestTimeframes(void)
  {
   Suite("1.1 TimeframeSet");
   LSR_TimeframeSet s;
   string e;
   Check(LSR_ParseTimeframeSet("M5,M15,H1", s, e) && s.count == 3, "default parses");
   CheckStr(LSR_TimeframeSetToString(s), "M5,M15,H1", "default canonical");
   Check(LSR_ParseTimeframeSet(" h1 , m5 ", s, e), "case-insensitive, whitespace-tolerant");
   CheckStr(LSR_TimeframeSetToString(s), "M5,H1", "canonical order after reorder");
   Check(LSR_ParseTimeframeSet("H1,M1,M30,M15,M5", s, e), "all five allowed");
   CheckStr(LSR_TimeframeSetToString(s), "M1,M5,M15,M30,H1", "canonical enum order");
   Check(!LSR_ParseTimeframeSet("M5,,H1", s, e), "empty middle entry fails");
   Check(!LSR_ParseTimeframeSet("M5,", s, e), "trailing empty entry fails");
   Check(!LSR_ParseTimeframeSet("M5,m5", s, e), "duplicate fails (not silently removed)");
   Check(!LSR_ParseTimeframeSet("M2", s, e), "unsupported value fails");
   Check(!LSR_ParseTimeframeSet("H4", s, e), "H4 not allowed");
   Check(!LSR_ParseTimeframeSet("", s, e), "empty string fails");
   Check(!LSR_ParseTimeframeSet("   ", s, e), "whitespace-only fails");
   Check(!LSR_ParseTimeframeSet("M 5", s, e), "internal whitespace fails");

   LSR_ParseTimeframeSet("M5,M15,H1", s, e);
   Check(LSR_ValidateLiveTimeframe(s, LSR_TF_M5, e), "LiveTimeframe M5 member");
   Check(!LSR_ValidateLiveTimeframe(s, LSR_TF_M1, e), "LiveTimeframe M1 not member fails");
   LSR_TimeframeSet a;
   LSR_ResolveActiveTimeframes(s, LSR_TF_M15, LSR_CONTEXT_RESEARCH, a);
   Check(a.count == 3, "research runs every selected timeframe");
   LSR_ResolveActiveTimeframes(s, LSR_TF_M15, LSR_CONTEXT_LIVE, a);
   Check(a.count == 1 && a.items[0] == LSR_TF_M15, "live runs exactly the one LiveTimeframe");
   Check(LSR_TimeframeSeconds(LSR_TF_M15) == 900 && LSR_TimeframeSeconds(LSR_TF_H1) == 3600, "timeframe seconds");
  }

//+------------------------------------------------------------------+
void TestBrokerTime(void)
  {
   Suite("1.2 Broker time");
   datetime t = D'2026.01.05 13:45:10';
   Check(LSR_BrokerDayStart(t) == D'2026.01.05', "broker day start");
   Check(LSR_SecondsOfDay(t) == 13 * 3600 + 45 * 60 + 10, "seconds of day");
   Check(LSR_DayOfWeek(D'2026.01.05') == 1, "2026-01-05 is Monday");
   Check(LSR_BrokerMonthKey(t) == 202601, "month key");
   CLSR_BrokerDayClock c;
   Check(c.Observe(D'2026.01.05 00:00:07'), "first observation opens a day");
   Check(!c.Observe(D'2026.01.05 23:59:59'), "same day does not reset");
   Check(c.Observe(D'2026.01.06 00:00:00'), "00:00:00 resets");
   Check(c.ResetTimestamp() == D'2026.01.06 00:00:00', "reset timestamp is first tick at/after 00:00");
   Check(c.Observe(D'2026.01.08 03:00:00') && c.ResetTimestamp() == D'2026.01.08 03:00:00', "gap day: reset at first observed tick");
  }

//+------------------------------------------------------------------+
void TestSessions(void)
  {
   Suite("1.3 Sessions");
   string e;
   int sec;
   Check(LSR_ParseHHMM("16:30", false, sec, e) && sec == 16 * 3600 + 30 * 60, "HH:MM parses");
   Check(LSR_ParseHHMM("24:00", true, sec, e) && sec == 86400, "24:00 allowed for end");
   Check(!LSR_ParseHHMM("24:00", false, sec, e), "24:00 rejected for start");
   Check(!LSR_ParseHHMM("9:00", false, sec, e), "H:MM rejected");
   Check(!LSR_ParseHHMM("25:00", true, sec, e), "25:00 rejected");
   Check(!LSR_ParseHHMM("10:60", true, sec, e), "minute 60 rejected");

   CLSR_SessionSchedule gold;
   BuildGoldSchedule(gold);
   Check(gold.IsInSession(D'2026.01.05 01:00'), "session start inclusive");
   Check(!gold.IsInSession(D'2026.01.05 23:57'), "session end exclusive");
   Check(!gold.IsInSession(D'2026.01.10 12:00'), "Saturday closed");
   datetime ns;
   Check(gold.NextSessionStartAfter(D'2026.01.05 21:30', ns) && ns == D'2026.01.06 01:00', "next start after Mon 21:30 is Tue 01:00");
   Check(gold.NextSessionStartAfter(D'2026.01.09 21:30', ns) && ns == D'2026.01.12 01:00', "next start after Fri 21:30 is Mon 01:00");
   Check(gold.NextSessionStartAfter(D'2026.01.06 01:00', ns) && ns == D'2026.01.07 01:00', "strictly after: equal start excluded");
   Check(!gold.AddBrokerInterval(2, 3600, 3600, e), "zero-length broker interval rejected");

   //--- Mode 1
   CLSR_StrategyWindow w1;
   Check(w1.Init(LSR_SESSION_FULL_DAY_EXCEPT_LATE_SPREAD, "00:00", "24:00", GetPointer(gold), e), "Mode 1 init");
   Check(w1.IsEntryAllowed(D'2026.01.05 21:29:59'), "Mode 1: 21:29:59 allowed");
   Check(!w1.IsEntryAllowed(D'2026.01.05 21:30:00'), "Mode 1: 21:30 blocked");
   Check(!w1.IsEntryAllowed(D'2026.01.05 23:00'), "Mode 1: 23:00 blocked");
   Check(w1.IsInLateSpreadBlock(D'2026.01.06 00:30'), "Mode 1: block continues past midnight");
   Check(w1.IsEntryAllowed(D'2026.01.06 01:00'), "Mode 1: next session start allowed");
   Check(w1.IsInLateSpreadBlock(D'2026.01.10 12:00'), "Mode 1: Friday block spans weekend");
   Check(w1.IsEntryAllowed(D'2026.01.12 01:00'), "Mode 1: Monday open allowed");
   datetime bs, be;
   Check(w1.LateBlockOfDay(D'2026.01.09', bs, be) && bs == D'2026.01.09 21:30' && be == D'2026.01.12 01:00', "Mode 1: Friday block [21:30, Mon 01:00)");

   CLSR_SessionSchedule split;
   split.AddBrokerInterval(1, 3600, 21 * 3600, e);
   split.AddBrokerInterval(1, 22 * 3600, 86400, e);
   split.AddBrokerInterval(2, 3600, 21 * 3600, e);
   CLSR_StrategyWindow w1b;
   w1b.Init(LSR_SESSION_FULL_DAY_EXCEPT_LATE_SPREAD, "00:00", "24:00", GetPointer(split), e);
   Check(w1b.IsInLateSpreadBlock(D'2026.01.05 21:45'), "Mode 1: same-day later session — 21:45 in block");
   Check(!w1b.IsInLateSpreadBlock(D'2026.01.05 22:00') && w1b.IsEntryAllowed(D'2026.01.05 23:00'), "Mode 1: block ends at same-day 22:00 session");

   CLSR_SessionSchedule wrap;
   wrap.AddBrokerInterval(1, 22 * 3600, 2 * 3600, e);
   wrap.AddBrokerInterval(2, 22 * 3600, 2 * 3600, e);
   Check(wrap.IsInSession(D'2026.01.06 01:00'), "wrapped interval continues after midnight");
   Check(wrap.NextSessionStartAfter(D'2026.01.05 23:00', ns) && ns == D'2026.01.06 22:00', "midnight continuation is not a session start");

   //--- Mode 2
   CLSR_StrategyWindow w2;
   Check(w2.Init(LSR_SESSION_NY_WINDOW, "00:00", "24:00", GetPointer(gold), e), "Mode 2 init");
   Check(!w2.IsEntryAllowed(D'2026.01.05 16:29:59'), "Mode 2: 16:29:59 outside");
   Check(w2.IsEntryAllowed(D'2026.01.05 16:30'), "Mode 2: 16:30 inside");
   Check(w2.IsEntryAllowed(D'2026.01.05 21:29:59'), "Mode 2: 21:29:59 inside");
   Check(!w2.IsEntryAllowed(D'2026.01.05 21:30'), "Mode 2: 21:30 exclusive end");
   Check(!w2.IsEntryAllowed(D'2026.01.10 17:00'), "Mode 2: Saturday — no actual session");

   //--- Mode 3
   CLSR_StrategyWindow w3;
   Check(w3.Init(LSR_SESSION_CUSTOM, "00:00", "24:00", GetPointer(gold), e), "Mode 3 00:00->24:00 valid");
   Check(w3.IsEntryAllowed(D'2026.01.05 23:56') && !w3.IsEntryAllowed(D'2026.01.05 00:30'), "Mode 3 full day intersects actual session");
   Check(!w3.Init(LSR_SESSION_CUSTOM, "10:00", "10:00", GetPointer(gold), e), "Mode 3 Start=End invalid");
   Check(!w3.Init(LSR_SESSION_CUSTOM, "00:00", "00:00", GetPointer(gold), e), "Mode 3 00:00->00:00 invalid");
   Check(!w3.Init(LSR_SESSION_CUSTOM, "24:00", "10:00", GetPointer(gold), e), "Mode 3 start 24:00 invalid");
   Check(w3.Init(LSR_SESSION_CUSTOM, "22:00", "02:00", GetPointer(gold), e), "Mode 3 wrap-midnight valid");
   Check(w3.IsEntryAllowed(D'2026.01.05 22:00') && w3.IsEntryAllowed(D'2026.01.06 01:30'), "Mode 3 wrap: both sides inside");
   Check(!w3.IsEntryAllowed(D'2026.01.06 02:00') && !w3.IsEntryAllowed(D'2026.01.05 21:59'), "Mode 3 wrap: boundaries");
   Check(!w3.IsEntryAllowed(D'2026.01.06 00:30'), "Mode 3 wrap: inside window but outside actual session");
   Check(w3.Init(LSR_SESSION_CUSTOM, "08:00", "12:00", GetPointer(gold), e) && w3.IsEntryAllowed(D'2026.01.05 11:59') && !w3.IsEntryAllowed(D'2026.01.05 12:00'), "Mode 3 same-day window");
  }

//+------------------------------------------------------------------+
void TestUnitsAndQuotes(void)
  {
   Suite("1.5/1.6 Units and quotes");
   CLSR_PriceUnits u;
   string e;
   Check(u.Init(0.10, 0.01, 0.01, e), "units init");
   CheckNear(u.ToPips(0.35), 3.5, 1e-12, "0.35 = 3.5 strategy pips");
   CheckNear(u.ToPoints(0.35), 35.0, 1e-9, "0.35 = 35 points");
   CheckNear(u.PipsToPrice(3.0), 0.30, 1e-12, "3 pips = 0.30");
   Check(!u.Init(0.0, 0.01, 0.01, e), "zero pip size rejected");
   Check(LSR_IsTickAligned(2000.01, 0.01) && !LSR_IsTickAligned(2000.015, 0.01), "tick alignment");

   LSR_Quote q;
   MkQuote(q, 1999.90, 2000.10);
   CheckNear(LSR_Spread(q), 0.20, 1e-9, "spread = ask - bid");
   Check(LSR_OpenQuote(LSR_DIR_LONG, q) == 2000.10 && LSR_OpenQuote(LSR_DIR_SHORT, q) == 1999.90, "open long Ask / short Bid");
   Check(LSR_CloseQuote(LSR_DIR_LONG, q) == 1999.90 && LSR_CloseQuote(LSR_DIR_SHORT, q) == 2000.10, "close long Bid / short Ask");
   Check(LSR_SignalBarPrice(q, LSR_PRICE_BID) == 1999.90, "signal bar source BID");
   Check(LSR_QuoteIsUsable(q), "usable quote");
   LSR_Quote z;
   MkQuote(z, 2000.0, 2000.0);
   Check(!LSR_QuoteIsUsable(z), "zero spread not usable");

   // Native stop fires on Bid; spread widening alone can trigger native but not mid.
   Check(LSR_StopTriggered(LSR_STOP_LIVE_NATIVE, LSR_DIR_LONG, q, 1999.95), "native long: Bid <= SL");
   Check(!LSR_StopTriggered(LSR_STOP_RESEARCH_MID, LSR_DIR_LONG, q, 1999.95), "mid long: Mid above SL");
   Check(!LSR_StopTriggered(LSR_STOP_LIVE_NATIVE, LSR_DIR_LONG, q, 1999.89), "native long: Bid above SL");
   Check(LSR_StopTriggered(LSR_STOP_LIVE_NATIVE, LSR_DIR_SHORT, q, 2000.10), "native short: Ask >= SL (equal)");
   Check(!LSR_StopTriggered(LSR_STOP_LIVE_NATIVE, LSR_DIR_SHORT, q, 2000.11), "native short: Ask below SL");
   Check(LSR_StopTriggered(LSR_STOP_RESEARCH_MID, LSR_DIR_SHORT, q, 1999.99), "mid short: Mid >= SL");
  }

//+------------------------------------------------------------------+
void TestCosts(void)
  {
   Suite("1.7 Costs");
   LSR_CostModel m;
   LSR_CostModelDefaults(m);
   string e;
   Check(LSR_ValidateCostModel(m, e), "defaults valid");
   CheckNear(LSR_CommissionCurrency(m, 1.0, 100.0, 4466.22), 7.145952, 1e-9, "published XAUUSD example formula (1 lot @ 4466.22)");
   CheckNear(LSR_CommissionCurrency(m, 0.5, 100.0, 2000.0), 1.6, 1e-12, "0.5 lot @ 2000");
   Check(LSR_DeclaredRiskExecutionBufferPoints(m) == 0, "buffer 0 at baseline");
   Check(LSR_EarliestExecutionMsc(m, 1000) == 1000, "latency ZERO");

   LSR_Quote q;
   MkQuote(q, 2000.00, 2000.20);
   Check(LSR_AdverseEntryPrice(m, LSR_DIR_LONG, q, 0.01) == 2000.20, "no slippage: long entry = Ask");

   LSR_CostModel s = m;
   s.slippage_mode = LSR_SLIPPAGE_FIXED_ADVERSE_POINTS;
   s.entry_slippage_points = 2;
   s.exit_slippage_points = 5;
   Check(LSR_ValidateCostModel(s, e), "FIXED 2/5 valid");
   CheckNear(LSR_AdverseEntryPrice(s, LSR_DIR_LONG, q, 0.01), 2000.22, 1e-9, "long entry Ask+2pt");
   CheckNear(LSR_AdverseEntryPrice(s, LSR_DIR_SHORT, q, 0.01), 1999.98, 1e-9, "short entry Bid-2pt");
   CheckNear(LSR_AdverseExitPrice(s, LSR_DIR_LONG, q, 0.01), 1999.95, 1e-9, "long exit Bid-5pt");
   CheckNear(LSR_AdverseExitPrice(s, LSR_DIR_SHORT, q, 0.01), 2000.25, 1e-9, "short exit Ask+5pt");
   Check(LSR_DeclaredRiskExecutionBufferPoints(s) == 5, "buffer = max(entry, exit)");

   LSR_CostModel bad = m;
   bad.entry_slippage_points = 1;
   Check(!LSR_ValidateCostModel(bad, e), "NONE with non-zero points rejected");
   bad = s;
   bad.entry_slippage_points = 3;
   Check(!LSR_ValidateCostModel(bad, e), "non-registered slippage 3 rejected");
   bad = s;
   bad.entry_slippage_points = 0;
   bad.exit_slippage_points = 0;
   Check(!LSR_ValidateCostModel(bad, e), "FIXED with 0/0 rejected");
   bad = m;
   bad.fixed_execution_delay_ms = 100;
   Check(!LSR_ValidateCostModel(bad, e), "latency ZERO with delay rejected");
   LSR_CostModel lat = m;
   lat.latency_mode = LSR_LATENCY_FIXED_MS;
   lat.fixed_execution_delay_ms = 250;
   Check(LSR_ValidateCostModel(lat, e), "latency 250ms valid");
   Check(LSR_EarliestExecutionMsc(lat, 1000) == 1250, "latency adds delay");
   lat.fixed_execution_delay_ms = 300;
   Check(!LSR_ValidateCostModel(lat, e), "latency 300ms rejected");
   bad = m;
   bad.contract_size_source = LSR_CONTRACT_SIZE_BROKER_SCHEDULE;
   Check(!LSR_ValidateCostModel(bad, e), "broker-schedule contract size requires a value");

   LSR_CostGateResult g;
   LSR_EvaluateEntryCostGate(m, 0.30, 0.10, 50.0, 500.0, g);
   Check(g.passed, "spread exactly 3.0 pips and cost exactly 0.10R pass");
   LSR_EvaluateEntryCostGate(m, 0.31, 0.10, 0.0, 500.0, g);
   Check(!g.passed && g.reason == LSR_COST_GATE_SPREAD_TOO_WIDE, "3.1 pips rejected");
   LSR_EvaluateEntryCostGate(m, 0.20, 0.10, 50.01, 500.0, g);
   Check(!g.passed && g.reason == LSR_COST_GATE_NONSPREAD_COST_TOO_HIGH, "0.10002R cost rejected");
   LSR_CostModel off = m;
   off.max_entry_spread_enabled = false;
   LSR_EvaluateEntryCostGate(off, 0.50, 0.10, 0.0, 500.0, g);
   Check(g.passed, "spread gate disabled");
   LSR_EvaluateEntryCostGate(m, 0.20, 0.10, 0.0, 0.0, g);
   Check(!g.passed && g.reason == LSR_COST_GATE_INVALID_INPUT, "zero 1R is invalid input");
  }

//+------------------------------------------------------------------+
void TestSizing(void)
  {
   Suite("1.8 Position sizing");
   LSR_SymbolSpec spec;
   spec.point = 0.01;
   spec.tick_size = 0.01;
   spec.contract_size = 100.0;
   spec.volume_min = 0.01;
   spec.volume_max = 100.0;
   spec.volume_step = 0.01;
   spec.stops_level = 0;
   LSR_CostModel m;
   LSR_CostModelDefaults(m);
   CLSR_LinearEconomics econ(100.0, 100.0);

   CheckNear(LSR_FloorToVolumeStep(0.999999, 0.01), 0.99, 1e-12, "floor 0.999999 -> 0.99");
   CheckNear(LSR_FloorToVolumeStep(1.0, 0.01), 1.0, 1e-12, "exact step kept");
   CheckNear(LSR_FloorToVolumeStep(0.3, 0.1), 0.3, 1e-12, "0.3/0.1 float edge kept");

   LSR_SizingRequest r;
   r.dir = LSR_DIR_LONG;
   r.entry_quote = 2000.00;
   r.stop_price = 1995.00;
   r.risk_budget_currency = 500.0;
   r.free_margin = 1e9;
   LSR_SizingResult res;
   Check(LSR_SizePosition(r, spec, m, LSR_STOP_LIVE_NATIVE, econ, res), "long sizing ok");
   CheckNear(res.worst_loss_per_lot, 503.2, 1e-9, "worst loss per lot = 500 path + 3.2 commission");
   CheckNear(res.volume, 0.99, 1e-12, "volume rounded down (0.9936 -> 0.99)");
   Check(res.worst_loss_currency <= 500.0 + 1e-9, "worst-case loss never exceeds 1R");

   r.dir = LSR_DIR_SHORT;
   r.stop_price = 2005.00;
   Check(LSR_SizePosition(r, spec, m, LSR_STOP_LIVE_NATIVE, econ, res) && MathAbs(res.volume - 0.99) < 1e-12, "short sizing symmetric");

   LSR_CostModel s = m;
   s.slippage_mode = LSR_SLIPPAGE_FIXED_ADVERSE_POINTS;
   s.entry_slippage_points = 2;
   s.exit_slippage_points = 5;
   r.dir = LSR_DIR_LONG;
   r.stop_price = 1995.00;
   Check(LSR_SizePosition(r, spec, s, LSR_STOP_LIVE_NATIVE, econ, res), "stressed sizing ok");
   CheckNear(res.exec_entry_price, 2000.02, 1e-9, "exec entry includes entry slippage");
   CheckNear(res.worst_exit_price, 1994.95, 1e-9, "worst exit includes buffer");
   CheckNear(res.volume, 0.98, 1e-12, "stressed volume 0.98");
   Check(res.worst_loss_currency <= 500.0 + 1e-9, "stressed worst-case within 1R");

   r.stop_price = 2001.0;
   Check(!LSR_SizePosition(r, spec, m, LSR_STOP_LIVE_NATIVE, econ, res) && res.reason == LSR_SIZING_INVALID_STOP_SIDE, "stop on wrong side rejected");
   r.stop_price = 1995.0;
   r.risk_budget_currency = 5.0;
   Check(!LSR_SizePosition(r, spec, m, LSR_STOP_LIVE_NATIVE, econ, res) && res.reason == LSR_SIZING_VOLUME_BELOW_MIN, "below minimum volume rejected (never rounded up)");
   r.risk_budget_currency = 500.0;
   LSR_SymbolSpec capped = spec;
   capped.volume_max = 0.5;
   Check(LSR_SizePosition(r, capped, m, LSR_STOP_LIVE_NATIVE, econ, res) && MathAbs(res.volume - 0.5) < 1e-12, "capped at volume max");
   r.free_margin = 1000.0;   // margin/lot = 2000
   Check(LSR_SizePosition(r, spec, m, LSR_STOP_LIVE_NATIVE, econ, res) && MathAbs(res.volume - 0.5) < 1e-12, "reduced to available margin");
   r.free_margin = 10.0;
   Check(!LSR_SizePosition(r, spec, m, LSR_STOP_LIVE_NATIVE, econ, res) && res.reason == LSR_SIZING_INSUFFICIENT_MARGIN, "insufficient margin rejected");
   r.free_margin = 1e9;
   Check(!LSR_SizePosition(r, spec, m, LSR_STOP_RESEARCH_MID, econ, res) && res.reason == LSR_SIZING_SPEC_INCOMPLETE_MID_STOP, "MID-stop sizing is SPEC-INCOMPLETE");

   spec.stops_level = 50;
   Check(LSR_IsStopDistanceLegal(spec, 2000.0, 1999.5) && !LSR_IsStopDistanceLegal(spec, 2000.0, 1999.6), "stops level distance");
  }

//+------------------------------------------------------------------+
void MkAcctIn(LSR_AccountRuleInputs &in, const double closed, const double floating, const double comm,
              const double swap, const double equity)
  {
   in.closed_result = closed;
   in.floating_result = floating;
   in.commission = comm;
   in.swap = swap;
   in.fees = 0.0;
   in.balance = equity;
   in.equity = equity;
   in.day_risk_unit_currency = 500.0;
  }

void TestAccountRules(void)
  {
   Suite("0B.10 AccountRuleEngine");
   LSR_AccountRuleProfile p;
   string e;
   Check(LSR_LoadAccountRuleProfile(LSR_ACCOUNT_FUNDEDNEXT_STELLAR_2STEP, LSR_ACCOUNT_RULES_APPLY_OFFICIAL, 100000.0, "USD", 0.10, p, e), "profile loads");
   Check(!LSR_LoadAccountRuleProfile(LSR_ACCOUNT_FUNDEDNEXT_STELLAR_2STEP, LSR_ACCOUNT_RULES_APPLY_OFFICIAL, 0.0, "USD", 0.10, p, e), "zero balance rejected");
   LSR_LoadAccountRuleProfile(LSR_ACCOUNT_FUNDEDNEXT_STELLAR_2STEP, LSR_ACCOUNT_RULES_APPLY_OFFICIAL, 100000.0, "USD", 0.10, p, e);
   CLSR_AccountRuleEngine a;
   a.Init(p);
   CheckNear(a.DailyLossFloor(), -5000.0, 1e-9, "daily floor = -5% of initial balance");
   CheckNear(a.MaxLossFloorEquity(), 90000.0, 1e-9, "max-loss floor equity = 90%");

   LSR_AccountRuleInputs in;
   LSR_AccountRuleEval ev;
   MkAcctIn(in, -3000.0, -1000.0, -50.0, -10.0, 95940.0);
   CheckNear(CLSR_AccountRuleEngine::DailyNetResult(in), -4060.0, 1e-9, "DailyNetResult sums components once");
   a.Evaluate(in, 0.0, ev);
   Check(ev.state == LSR_ACCOUNT_OK, "940 above floor with 50 buffer: OK");
   CheckNear(ev.safety_buffer_currency, 50.0, 1e-9, "buffer = 0.10R x 500");
   a.Evaluate(in, 900.0, ev);
   Check(ev.state == LSR_ACCOUNT_NEAR_BREACH && ev.daily_near, "projected distance 40 <= 50: NEAR_BREACH");
   a.Evaluate(in, 940.0, ev);
   Check(ev.state == LSR_ACCOUNT_NEAR_BREACH && !ev.daily_breach, "exactly on the floor is near-breach, not breach");
   a.Evaluate(in, 950.0, ev);
   Check(ev.state == LSR_ACCOUNT_BREACH && ev.daily_breach, "below daily floor: BREACH");

   MkAcctIn(in, 0.0, 0.0, 0.0, 0.0, 90040.0);
   a.Evaluate(in, 0.0, ev);
   Check(ev.state == LSR_ACCOUNT_NEAR_BREACH && ev.max_near, "equity 40 above max-loss floor: NEAR_BREACH");
   MkAcctIn(in, 0.0, 0.0, 0.0, 0.0, 89999.0);
   Check(a.Update(D'2026.01.05 10:00', in, ev) == LSR_ACCOUNT_BREACH && ev.max_breach, "equity below max-loss floor: BREACH");
   MkAcctIn(in, 0.0, 0.0, 0.0, 0.0, 100000.0);
   Check(a.Update(D'2026.01.05 10:01', in, ev) == LSR_ACCOUNT_BREACH && a.BreachLatched(), "breach is latched for the run");

   CLSR_AccountRuleEngine b;
   b.Init(p);
   Check(b.OnTimestamp(D'2026.01.05 00:00:05'), "first reset");
   Check(!b.OnTimestamp(D'2026.01.05 12:00'), "no intraday reset");
   Check(b.OnTimestamp(D'2026.01.06 00:00:00') && b.ResetTimestamp() == D'2026.01.06 00:00:00', "reset at 00:00 broker time");
  }

//+------------------------------------------------------------------+
void AddOpen(LSR_OpenRiskItem &arr[], const ENUM_LSR_DIRECTION dir, const double loss)
  {
   int n = ArraySize(arr);
   ArrayResize(arr, n + 1);
   arr[n].dir = dir;
   arr[n].incremental_worst_case_loss = loss;
  }

void TestRiskAdmission(void)
  {
   Suite("0C.9/1.9 Risk admission");
   LSR_RiskConfig c;
   LSR_RiskConfigDefaults(c);
   string e;
   Check(LSR_ValidateRiskConfig(c, e), "defaults valid");
   LSR_RiskConfig bad = c;
   bad.max_total_drawdown_enabled = true;
   Check(!LSR_ValidateRiskConfig(bad, e), "MaxTotalDrawdown enabled = SPEC-INCOMPLETE");
   bad = c;
   bad.max_consecutive_loss_guard_enabled = true;
   Check(!LSR_ValidateRiskConfig(bad, e), "MaxConsecutiveLossGuard enabled = SPEC-INCOMPLETE");

   CLSR_DailyRiskState d;
   Check(d.Observe(D'2026.01.05 00:00:01', 100000.0, 0.5), "day opens");
   CheckNear(d.DayRiskUnit(), 500.0, 1e-9, "1R = 0.5% of start-of-day equity");
   CheckNear(d.DailyLossFloor(3.0), 98500.0, 1e-9, "daily floor = start - 3R");
   Check(!d.Observe(D'2026.01.05 15:00', 99000.0, 0.5) && d.StartOfDayEquity() == 100000.0, "intraday equity does not rebase");
   Check(d.Observe(D'2026.01.06 00:00:00', 99000.0, 0.5) && MathAbs(d.DayRiskUnit() - 495.0) < 1e-9, "new day rebases 1R");

   LSR_AccountRuleProfile p;
   LSR_LoadAccountRuleProfile(LSR_ACCOUNT_FUNDEDNEXT_STELLAR_2STEP, LSR_ACCOUNT_RULES_APPLY_OFFICIAL, 100000.0, "USD", 0.10, p, e);
   CLSR_AccountRuleEngine acct;
   acct.Init(p);
   LSR_AccountRuleInputs ai;
   MkAcctIn(ai, 0.0, 0.0, 0.0, 0.0, 100000.0);

   LSR_OpenRiskItem none[];
   LSR_AdmissionProposal prop;
   prop.dir = LSR_DIR_LONG;
   prop.new_trade_worst_case_loss = 500.0;
   LSR_AdmissionTrace tr;
   Check(LSR_EvaluateAdmission(c, 100000.0, 500.0, 100000.0, none, prop, acct, ai, tr), "clean book admits 1R");
   CheckNear(tr.aggregate_r_after, 1.0, 1e-12, "aggregate 1R");

   LSR_OpenRiskItem three[];
   AddOpen(three, LSR_DIR_LONG, 100);
   AddOpen(three, LSR_DIR_SHORT, 100);
   AddOpen(three, LSR_DIR_SHORT, 100);
   prop.new_trade_worst_case_loss = 100.0;
   LSR_EvaluateAdmission(c, 100000.0, 500.0, 100000.0, three, prop, acct, ai, tr);
   Check(!tr.admitted && tr.final_reason == LSR_REJECT_MAX_CONCURRENT_POSITIONS, "4th position rejected");

   LSR_OpenRiskItem dir[];
   AddOpen(dir, LSR_DIR_LONG, 500);
   prop.new_trade_worst_case_loss = 600.0;
   LSR_EvaluateAdmission(c, 100000.0, 500.0, 100000.0, dir, prop, acct, ai, tr);
   Check(!tr.admitted && tr.final_reason == LSR_REJECT_DIRECTIONAL_RISK_CEILING, "same-direction 2.2R > 2.0R rejected");
   prop.dir = LSR_DIR_SHORT;
   Check(LSR_EvaluateAdmission(c, 100000.0, 500.0, 100000.0, dir, prop, acct, ai, tr), "opposite direction 1.2R admitted");

   LSR_OpenRiskItem agg[];
   AddOpen(agg, LSR_DIR_LONG, 700);
   AddOpen(agg, LSR_DIR_SHORT, 700);
   prop.dir = LSR_DIR_LONG;
   prop.new_trade_worst_case_loss = 700.0;
   MkAcctIn(ai, 1000.0, 0.0, 0.0, 0.0, 101000.0);
   LSR_EvaluateAdmission(c, 100000.0, 500.0, 101000.0, agg, prop, acct, ai, tr);
   Check(!tr.admitted && tr.final_reason == LSR_REJECT_AGGREGATE_RISK_CEILING, "aggregate 4.2R > 3.0R rejected");

   MkAcctIn(ai, -1000.0, 0.0, 0.0, 0.0, 99000.0);
   prop.new_trade_worst_case_loss = 600.0;
   LSR_EvaluateAdmission(c, 100000.0, 500.0, 99000.0, none, prop, acct, ai, tr);
   Check(!tr.admitted && tr.final_reason == LSR_REJECT_DAILY_LOSS_FLOOR, "projected 98400 < 98500 rejected");
   prop.new_trade_worst_case_loss = 500.0;
   Check(LSR_EvaluateAdmission(c, 100000.0, 500.0, 99000.0, none, prop, acct, ai, tr), "projected exactly at floor admitted");
   LSR_RiskConfig noGuard = c;
   noGuard.daily_loss_guard_enabled = false;
   prop.new_trade_worst_case_loss = 600.0;
   Check(LSR_EvaluateAdmission(noGuard, 100000.0, 500.0, 99000.0, none, prop, acct, ai, tr), "guard OFF skips daily floor");

   LSR_OpenRiskItem open1[];
   AddOpen(open1, LSR_DIR_LONG, 400);
   prop.new_trade_worst_case_loss = 200.0;
   MkAcctIn(ai, -1500.0, 0.0, 0.0, 0.0, 98500.0);
   LSR_EvaluateAdmission(c, 100000.0, 500.0, 98500.0, open1, prop, acct, ai, tr);
   Check(!tr.admitted && tr.final_reason == LSR_REJECT_DAILY_LOSS_FLOOR, "open-trade incremental loss counts toward floor");

   LSR_RiskConfig pt = c;
   pt.daily_profit_target_enabled = true;
   MkAcctIn(ai, 4500.0, 0.0, 0.0, 0.0, 104500.0);
   prop.new_trade_worst_case_loss = 500.0;
   LSR_EvaluateAdmission(pt, 100000.0, 500.0, 104500.0, none, prop, acct, ai, tr);
   Check(!tr.admitted && tr.final_reason == LSR_REJECT_DAILY_PROFIT_TARGET_REACHED, "+9R reached blocks new entries");
   MkAcctIn(ai, 4499.0, 0.0, 0.0, 0.0, 104499.0);
   Check(LSR_EvaluateAdmission(pt, 100000.0, 500.0, 104499.0, none, prop, acct, ai, tr), "below +9R admits");

   LSR_RiskConfig cap = c;
   cap.directional_position_cap_enabled = true;
   cap.max_directional_positions = 1;
   LSR_OpenRiskItem oneLong[];
   AddOpen(oneLong, LSR_DIR_LONG, 100);
   MkAcctIn(ai, 0.0, 0.0, 0.0, 0.0, 100000.0);
   prop.dir = LSR_DIR_LONG;
   LSR_EvaluateAdmission(cap, 100000.0, 500.0, 100000.0, oneLong, prop, acct, ai, tr);
   Check(!tr.admitted && tr.final_reason == LSR_REJECT_DIRECTIONAL_POSITION_CAP, "directional position cap");
   prop.dir = LSR_DIR_SHORT;
   Check(LSR_EvaluateAdmission(cap, 100000.0, 500.0, 100000.0, oneLong, prop, acct, ai, tr), "cap counts directions separately");

   MkAcctIn(ai, -4460.0, 0.0, 0.0, 0.0, 95540.0);
   prop.new_trade_worst_case_loss = 500.0;
   LSR_EvaluateAdmission(c, 95540.0, 500.0, 95540.0, none, prop, acct, ai, tr);
   Check(!tr.admitted && tr.final_reason == LSR_REJECT_ACCOUNT_RULE_NEAR_BREACH && tr.daily_floor_ok, "external account rule rejects even when internal budget passes");

   prop.new_trade_worst_case_loss = 0.0;
   MkAcctIn(ai, 0.0, 0.0, 0.0, 0.0, 100000.0);
   LSR_EvaluateAdmission(c, 100000.0, 500.0, 100000.0, none, prop, acct, ai, tr);
   Check(!tr.admitted && tr.final_reason == LSR_REJECT_INVALID_PROPOSAL, "zero-risk proposal invalid");
  }

//+------------------------------------------------------------------+
//| Raw-tick audit fixtures: Mon 2026-01-05 01:00–02:00, 6 ticks per |
//| minute, M1 bars derived from the same Bid values.                |
//+------------------------------------------------------------------+
void BuildAuditFixture(MqlTick &ticks[], MqlRates &rates[], const bool degrade)
  {
   ArrayResize(ticks, 0);
   ArrayResize(rates, 0);
   datetime base = D'2026.01.05 01:00';
   for(int m = 0; m < 60; m++)
     {
      datetime mt = base + m * 60;
      bool dropTicks = degrade && ((m >= 10 && m <= 16) || (m >= 40 && m <= 49));
      bool dropBar = degrade && ((m >= 13 && m <= 16) || (m >= 40 && m <= 49));
      double first = 2000.0 + m * 0.1;
      if(!dropTicks)
         for(int s = 0; s < 6; s++)
           {
            int n = ArraySize(ticks);
            ArrayResize(ticks, n + 1);
            double bid = first + s * 0.01;
            MkTick(ticks[n], mt + s * 10, 0, bid, bid + 0.20);
           }
      if(!dropBar)
        {
         int r = ArraySize(rates);
         ArrayResize(rates, r + 1);
         ZeroMemory(rates[r]);
         rates[r].time = mt;
         rates[r].open = first;
         rates[r].high = first + 0.05;
         rates[r].low = first;
         rates[r].close = first + 0.05;
         rates[r].tick_volume = 6;
         if(degrade && m == 30)
            rates[r].high += 0.50;   // contradicts raw ticks
        }
     }
  }

//+------------------------------------------------------------------+
//| Day fixture: `minutes` minutes from `base`, 6 ticks per minute.  |
//| drops[k] = {fromMinute, toMinute, dropBar}; ticks always dropped.|
//+------------------------------------------------------------------+
void BuildDayFixture(MqlTick &ticks[], MqlRates &rates[], const datetime base, const int minutes,
                     const int &drops[][3], const int nDrops)
  {
   ArrayResize(ticks, 0, minutes * 6);
   ArrayResize(rates, 0, minutes);
   for(int m = 0; m < minutes; m++)
     {
      bool dropTicks = false, dropBar = false;
      for(int k = 0; k < nDrops; k++)
         if(m >= drops[k][0] && m <= drops[k][1])
           {
            dropTicks = true;
            dropBar = (drops[k][2] != 0);
           }
      datetime mt = base + m * 60;
      double first = 2000.0 + (m % 100) * 0.1;
      if(!dropTicks)
         for(int s = 0; s < 6; s++)
           {
            int n = ArraySize(ticks);
            ArrayResize(ticks, n + 1, minutes * 6);
            double bid = first + s * 0.01;
            MkTick(ticks[n], mt + s * 10, 0, bid, bid + 0.20);
           }
      if(!dropBar)
        {
         int r = ArraySize(rates);
         ArrayResize(rates, r + 1, minutes);
         ZeroMemory(rates[r]);
         rates[r].time = mt;
         rates[r].open = first;
         rates[r].high = first + 0.05;
         rates[r].low = first;
         rates[r].close = first + 0.05;
        }
     }
  }

//--- Feeds fixtures to the audit in hourly chunks, as CLSR_RawAuditDriver does.
void FeedHourly(CLSR_RawTickAudit &audit, const MqlTick &ticks[], const MqlRates &rates[],
                const datetime from, const datetime to)
  {
   for(datetime c = from; c < to; c += 3600)
     {
      MqlTick ct[];
      MqlRates cr[];
      for(int i = 0; i < ArraySize(ticks); i++)
         if(ticks[i].time >= c && ticks[i].time < c + 3600)
           {
            int n = ArraySize(ct);
            ArrayResize(ct, n + 1);
            ct[n] = ticks[i];
           }
      for(int i = 0; i < ArraySize(rates); i++)
         if(rates[i].time >= c && rates[i].time < c + 3600)
           {
            int n = ArraySize(cr);
            ArrayResize(cr, n + 1);
            cr[n] = rates[i];
           }
      audit.ProcessChunk(ct, ArraySize(ct), cr, ArraySize(cr), c, c + 3600);
     }
  }

CLSR_SessionSchedule g_auditSched;
CLSR_ClosureCalendar g_auditCal;
CLSR_ClosureCalendar g_noCal;

void TestDataAudit(void)
  {
   Suite("1.4 Data-quality audit");
   string e;
   BuildGoldSchedule(g_auditSched);
   MqlTick ticks[];
   MqlRates rates[];

   //--- Clean hour
   BuildAuditFixture(ticks, rates, false);
   CLSR_RawTickAudit clean;
   clean.Init(GetPointer(g_auditSched), GetPointer(g_noCal), LSR_PRICE_BID, 0.01, D'2026.01.05', D'2026.01.06', "TEST");
   clean.ProcessChunk(ticks, ArraySize(ticks), rates, ArraySize(rates), D'2026.01.05 01:00', D'2026.01.05 02:00');
   Check(clean.Gate() == LSR_DATA_AUDIT_INCOMPLETE, "gate is AUDIT-INCOMPLETE before Finalize");
   clean.Finalize();
   Check(clean.EligibleMinutes() == 60 && clean.FallbackMinutes() == 0, "clean hour: 60 eligible, 0 fallback");
   Check(clean.CriticalGapCount() == 0 && clean.ClosureCount() == 0, "clean hour: session start after range start is not a gap");
   Check(clean.QuarantinedMinutes() == 0 && clean.Gate() == LSR_DATA_PASSED, "clean gate DATA-PASSED, nothing quarantined");

   //--- Degraded hour with a declared closure 01:40–01:50
   g_auditCal.Clear();
   Check(g_auditCal.Add(D'2026.01.05 01:40', D'2026.01.05 01:50', "fixture closure", e), "closure declared");
   BuildAuditFixture(ticks, rates, true);
   CLSR_RawTickAudit a;
   a.Init(GetPointer(g_auditSched), GetPointer(g_auditCal), LSR_PRICE_BID, 0.01, D'2026.01.05', D'2026.01.06', "TEST");
   a.ProcessChunk(ticks, ArraySize(ticks), rates, ArraySize(rates), D'2026.01.05 01:00', D'2026.01.05 02:00');
   a.Finalize();
   Check(a.EligibleMinutes() == 50, "declared closure minutes are not eligible (60 - 10)");
   Check(a.FallbackMinutes() == 8, "fallback = 3 no-tick+bar, 4 no-tick-no-bar, 1 reconciliation failure");
   CheckNear(a.FallbackShare(), 8.0 / 50.0, 1e-12, "fallback share");
   Check(a.CriticalGapCount() == 1 && a.ClosureCount() == 0, "mid-session 7-minute gap is a critical gap, not a closure");
   Check(a.QuarantinedMinutes() == 9, "quarantine = 8 PFM minutes + partial gap minute 01:09");
   Check(a.IsQuarantined(D'2026.01.05 01:12') && a.IsQuarantined(D'2026.01.05 01:30:30') && !a.IsQuarantined(D'2026.01.05 01:20'), "quarantine lookup");
   Check(a.Gate() == LSR_DATA_FAILED, "quarantine share 18% -> DATA-FAILED");
   Check(StringFind(a.GapsCsv(), "2026-01-05T01:09:50,2026-01-05T01:17:00,430,QUARANTINED") >= 0, "gap interval recorded as quarantined");
   Check(StringFind(a.FallbackCsv(), "2026-01-05T01:30:00,PFM_RECONCILIATION_FAILED") >= 0, "reconciliation failure listed");

   //--- Boundary helpers
   Check(g_auditSched.IsSessionStartAt(D'2026.01.05 01:00') && !g_auditSched.IsSessionStartAt(D'2026.01.05 01:01'), "session start boundary");
   Check(g_auditSched.IsSessionEndAt(D'2026.01.05 23:57') && !g_auditSched.IsSessionEndAt(D'2026.01.05 23:56'), "session end boundary");
   CLSR_SessionSchedule full;
   full.AddBrokerInterval(1, 4500, 86400, e);
   Check(full.IsSessionEndAt(D'2026.01.06 00:00'), "24:00 end boundary seen at next midnight");

   //--- Full-day fixture, Mon [01:00, 23:00): a holiday-style early close,
   //--- a Feb-20-style no-bar hole and a bar-without-ticks (fallback) hole.
   CLSR_SessionSchedule day;
   day.AddBrokerInterval(1, 3600, 23 * 3600, e);
   int drops[3][3] = {{600, 607, 1}, {700, 701, 0}, {1280, 1319, 1}};   // fromMinute, toMinute, dropBar
   BuildDayFixture(ticks, rates, D'2026.01.05 01:00', 1320, drops, 3);
   CLSR_RawTickAudit d;
   d.Init(GetPointer(day), GetPointer(g_noCal), LSR_PRICE_BID, 0.01, D'2026.01.05', D'2026.01.06', "TEST");
   FeedHourly(d, ticks, rates, D'2026.01.05', D'2026.01.06');
   d.Finalize();
   Check(d.ClosureCount() == 1, "early close (no ticks, no bars, reaches session end) auto-detected as closure");
   Check(d.EligibleMinutes() == 1280, "closure minutes excluded from eligible (1320 - 40)");
   Check(d.CriticalGapCount() == 1, "mid-session no-bar hole stays a critical gap");
   Check(d.FallbackMinutes() == 10, "PFM = 8 no-bar + 2 bar-without-ticks");
   Check(d.QuarantinedMinutes() == 11, "quarantine = 10 PFM + partial gap minute");
   Check(d.IsQuarantined(D'2026.01.05 11:03') && d.IsQuarantined(D'2026.01.05 12:41') && !d.IsQuarantined(D'2026.01.05 12:00'), "both holes quarantined");
   Check(!d.IsQuarantined(D'2026.01.05 22:30'), "closure is not quarantine");
   Check(d.Gate() == LSR_DATA_PASSED, "quarantine share 0.86% <= 1% -> DATA-PASSED");
   Check(StringFind(d.ClosuresCsv(), "2026-01-05T22:19:50,2026-01-05T23:00:00") >= 0, "closure interval recorded");

   //--- Same day, but bars still exist after the last tick: never a closure.
   int drops2[1][3] = {{1280, 1319, 0}};
   BuildDayFixture(ticks, rates, D'2026.01.05 01:00', 1320, drops2, 1);
   CLSR_RawTickAudit d2;
   d2.Init(GetPointer(day), GetPointer(g_noCal), LSR_PRICE_BID, 0.01, D'2026.01.05', D'2026.01.06', "TEST");
   FeedHourly(d2, ticks, rates, D'2026.01.05', D'2026.01.06');
   d2.Finalize();
   Check(d2.ClosureCount() == 0 && d2.CriticalGapCount() == 1, "bars without ticks at session end is a gap, not a closure");
   Check(d2.Gate() == LSR_DATA_FAILED, "40 fallback minutes -> DATA-FAILED");

   //--- Quarantine CSV round-trip
   string qpath = "LSR\\tests\\quarantine_fixture.csv";
   LSR_WriteUtf8File(qpath, d.QuarantineCsv(), true);
   CLSR_DataQuarantine q;
   Check(q.LoadCsv(qpath, e) && q.Count() == 2, "quarantine CSV loads (2 windows)");
   Check(q.IsQuarantined(D'2026.01.05 11:05') && !q.IsQuarantined(D'2026.01.05 11:30'), "loaded quarantine lookup");

   //--- Tradeable segments across a session break and a weekend
   datetime sf[], st[];
   int n = LSR_TradeableSegments(g_auditSched, g_noCal, D'2026.01.05 23:56', D'2026.01.06 01:03', sf, st);
   Check(n == 2 && st[0] - sf[0] == 60 && st[1] - sf[1] == 180, "daily break excluded (60s + 180s)");
   n = LSR_TradeableSegments(g_auditSched, g_noCal, D'2026.01.09 23:56:50', D'2026.01.12 01:00:05', sf, st);
   Check(n == 2 && st[0] - sf[0] == 10 && st[1] - sf[1] == 5, "weekend excluded");
   n = LSR_TradeableSegments(g_auditSched, g_noCal, D'2026.01.05 10:00', D'2026.01.05 10:06:01', sf, st);
   Check(n == 1 && st[0] - sf[0] == 361, "continuous in-session interval");

   //--- Tick anomalies
   LSR_TickAnomalies an;
   LSR_TickAnomaliesReset(an);
   MqlTick t1, t2, t3, t4, t5, prev;
   MkTick(t1, D'2026.01.05 10:00', 500, 2000.0, 2000.2);
   MkTick(t2, D'2026.01.05 10:00', 500, 2000.0, 2000.2);
   MkTick(t3, D'2026.01.05 10:00', 100, 2000.0, 2000.2);
   MkTick(t4, D'2026.01.05 10:00', 600, 0.0, 2000.2);
   MkTick(t5, D'2026.01.05 10:00', 700, 2000.0, 2000.0);
   ZeroMemory(prev);
   LSR_TickAnomaliesObserve(an, t1, false, prev);
   LSR_TickAnomaliesObserve(an, t2, true, t1);
   LSR_TickAnomaliesObserve(an, t3, true, t2);
   LSR_TickAnomaliesObserve(an, t4, true, t3);
   LSR_TickAnomaliesObserve(an, t5, true, t4);
   Check(an.records == 5 && an.usable == 3, "5 records, 3 usable");
   Check(an.duplicate_timestamp == 1 && an.exact_duplicate == 1, "duplicate timestamp + exact duplicate");
   Check(an.non_monotonic == 1, "non-monotonic timestamp");
   Check(an.invalid_price == 1 && an.nonpositive_spread == 1, "invalid price and zero spread");

   //--- Closure calendar file round-trip
   string path = "LSR\\tests\\closure_fixture.csv";
   int h = FileOpen(path, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h != INVALID_HANDLE)
     {
      FileWriteString(h, "# start,end,reason\n2026.01.01 00:00,2026.01.02 01:00,New Year\n");
      FileClose(h);
     }
   CLSR_ClosureCalendar cal;
   Check(cal.LoadCsv(path, e) && cal.Count() == 1, "closure CSV loads");
   Check(cal.Contains(D'2026.01.01 12:00') && !cal.Contains(D'2026.01.02 01:00'), "closure end exclusive");
  }

//+------------------------------------------------------------------+
void TestManifest(void)
  {
   Suite("0A.6 Manifest helpers");
   string e;
   Check(LSR_ValidateExperimentId("LSR-P1-SMOKE_2026.01", e), "experiment id valid");
   Check(!LSR_ValidateExperimentId("bad id", e) && !LSR_ValidateExperimentId("", e) && !LSR_ValidateExperimentId("..\\x", e), "unsafe experiment ids rejected");
   CLSR_InputRecorder r;
   r.Add("TimeframeSet", "M5,M15,H1", "M5,M15,H1");
   r.AddNum("RiskPerTradePercent", 0.25, 0.50);
   Check(r.NonDefaultCount() == 1, "non-default input detected");
   Check(StringFind(r.RunCardText(), "* RiskPerTradePercent = 0.25") >= 0, "run card marks non-default");
   string sha = LSR_WriteUtf8File("LSR\\tests\\sha_fixture.txt", "abc", true);
   CheckStr(sha, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "written file hash matches content hash");
  }

//+------------------------------------------------------------------+
//| Phase 2 event fixtures — identical to python/tests/test_engine.py|
//+------------------------------------------------------------------+
datetime P2_BASE = D'2026.01.05 10:00';

void P2Bar(LSR_Bar &b, const datetime t, const double o, const double h, const double l, const double c)
  {
   b.time = t;
   b.period = 60;
   b.open = o;
   b.high = h;
   b.low = l;
   b.close = c;
   b.ticks = 1;
  }

void P2Feed(CLSR_EventEngine &e, const int i, const double o, const double h, const double l, const double c)
  {
   LSR_Bar b;
   P2Bar(b, P2_BASE + i * 60, o, h, l, c);
   e.OnM1(b);
  }

void P2FeedAt(CLSR_EventEngine &e, const datetime t, const double o, const double h, const double l, const double c)
  {
   LSR_Bar b;
   P2Bar(b, t, o, h, l, c);
   e.OnM1(b);
  }

void P2Cfg(LSR_EventConfig &c, const bool pd, const bool ps, const bool sw, const bool eq)
  {
   LSR_EventConfigDefaults(c);
   c.use_previous_day = pd;
   c.use_previous_session = ps;
   c.use_swings = sw;
   c.use_equal = eq;
  }

double P2_SWING[7][4] =
  {
     {2000.00, 2000.50, 1999.80, 2000.20},
     {2000.20, 2001.00, 2000.10, 2000.80},
     {2000.80, 2002.00, 2000.60, 2001.50},
     {2001.50, 2001.70, 2000.90, 2001.00},
     {2001.00, 2001.20, 2000.40, 2000.60},
     {2000.60, 2001.40, 2000.30, 2001.20},
     {2001.20, 2001.95, 2001.10, 2001.80}
  };

void P2SwingEngine(CLSR_EventEngine &e, const int nSwingBars, const double &extra[][4], const int nExtra)
  {
   LSR_EventConfig c;
   P2Cfg(c, false, false, true, false);
   string err;
   e.Init(LSR_TF_M1, c, err);
   for(int i = 0; i < nSwingBars; i++)
      P2Feed(e, i, P2_SWING[i][0], P2_SWING[i][1], P2_SWING[i][2], P2_SWING[i][3]);
   for(int i = 0; i < nExtra; i++)
      P2Feed(e, nSwingBars + i, extra[i][0], extra[i][1], extra[i][2], extra[i][3]);
   e.Flush();
  }

string P2Statuses(const CLSR_EventEngine &e)
  {
   string s = "";
   for(int i = 0; i < e.EventCount(); i++)
      s += (i > 0 ? "," : "") + e.EventStatus(i);
   return s;
  }

void TestPhase2Bars(void)
  {
   Suite("2.10A Bars / ATR");
   CLSR_TfAggregator agg;
   agg.Init(300);
   LSR_Bar out[];
   for(int i = 0; i < 10; i++)
     {
      LSR_Bar m, d;
      P2Bar(m, P2_BASE + i * 60, 2000 + i, 2000.5 + i, 1999.5 + i, 2000.2 + i);
      if(agg.OnM1(m, d))
        {
         int n = ArraySize(out);
         ArrayResize(out, n + 1);
         out[n] = d;
        }
     }
   LSR_Bar last;
   if(agg.Flush(last))
     {
      int n = ArraySize(out);
      ArrayResize(out, n + 1);
      out[n] = last;
     }
   Check(ArraySize(out) == 2, "10 M1 bars -> 2 M5 bars");
   Check(out[0].time == P2_BASE && out[0].open == 2000 && out[0].high == 2004.5 && out[0].low == 1999.5 && out[0].close == 2004.2, "M5 OHLC aggregation");
   Check(out[1].time == P2_BASE + 300, "second M5 bar time");

   CLSR_WilderAtr atr;
   atr.Init(3);
   double bars[4][4] = {{10, 12, 9, 11}, {11, 13, 10, 12}, {12, 15, 11, 14}, {14, 14.5, 12, 13}};
   for(int i = 0; i < 4; i++)
     {
      LSR_Bar b;
      P2Bar(b, i * 60, bars[i][0], bars[i][1], bars[i][2], bars[i][3]);
      atr.Update(b);
      if(i == 1)
         Check(!atr.Ready(), "ATR not ready before n bars");
     }
   CheckNear(atr.Value(), ((10.0 / 3) * 2 + 2.5) / 3, 1e-12, "Wilder ATR recursion");
   CheckStr(LSR_StableId("abc"), "ba7816bf8f01cfea", "stable id = sha256 prefix");
  }

void TestPhase2Sweeps(void)
  {
   Suite("2 Events: sweeps");
   //--- fixture A: valid sweep of a confirmed swing high
   CLSR_EventEngine a;
   double ex[3][4] = {{2001.80, 2002.00, 2001.60, 2001.70}, {2001.70, 2002.60, 2001.50, 2001.60}, {2001.60, 2002.70, 2001.40, 2002.65}};
   P2SwingEngine(a, 7, ex, 3);
   Check(a.EventCount() == 1 && a.EventStatus(0) == "SETUP", "one SETUP row");
   int pa = a.EventPoolIndex(0);
   Check(a.EventSide(0) == 1 && a.EventTouches(0) == 1, "high side, one pre-sweep touch");
   CheckNear(a.EventPenetration(0), 0.60, 1e-9, "penetration = High - PoolUpper");
   CheckNear(a.EventReclaim(0), 0.40, 1e-9, "reclaim = PoolLower - Close");
   CheckStr(a.PoolEndReason(pa), "SWEPT", "pool consumed as SWEPT");
   Check(a.PoolArm(pa) == P2_BASE + 5 * 60, "swing effective at open of the bar after confirmation");
   CheckStr(a.EventId(0), "fe6198d644d45855", "EventID equals the Python reference");
   CheckStr(a.LevelId(0), "64a5fad6d55b0573", "LevelID equals the Python reference");

   //--- rejections
   string names[3] = {"OPEN_ON_LIQUIDITY", "NO_RECLAIM", "OPENED_BEYOND_POOL"};
   double rej[3][4] = {{2002.00, 2002.50, 2001.80, 2001.90}, {2001.80, 2002.50, 2001.70, 2002.10}, {2002.30, 2002.50, 2002.10, 2002.20}};
   for(int r = 0; r < 3; r++)
     {
      CLSR_EventEngine e;
      double x[2][4];
      for(int k = 0; k < 4; k++)
         x[0][k] = rej[r][k];
      x[1][0] = 2001.0;
      x[1][1] = 2001.1;
      x[1][2] = 2000.9;
      x[1][3] = 2001.0;
      P2SwingEngine(e, 7, x, 2);
      CheckStr(P2Statuses(e), names[r], "rejection " + names[r]);
      Check(StringFind(e.PoolEndReason(e.EventPoolIndex(0)), "BREACHED_") == 0, "breach consumes pool: " + names[r]);
     }
   CLSR_EventEngine pc;
   double pcx[2][4] = {{2001.20, 2002.00, 2001.10, 2002.00}, {2001.90, 2002.40, 2001.80, 2001.90}};
   P2SwingEngine(pc, 6, pcx, 2);
   CheckStr(P2Statuses(pc), "PREV_CLOSE_NOT_OUTSIDE", "previous close on the level is rejected");

   //--- multi-pool policies
   for(int pol = 0; pol < 2; pol++)
     {
      LSR_EventConfig c;
      P2Cfg(c, true, false, false, false);
      c.multi_pool_policy = (pol == 0 ? LSR_MULTIPOOL_FIRST_CROSSED_LEVEL : LSR_MULTIPOOL_DEEPEST_PENETRATION_LEVEL);
      CLSR_EventEngine e;
      string err;
      e.Init(LSR_TF_M1, c, err);
      e.InjectLevel(LSR_LV_SWING_HIGH, 2001.00, 2001.00, "fx-a");
      e.InjectLevel(LSR_LV_SWING_HIGH, 2001.50, 2001.50, "fx-b");
      P2Feed(e, 0, 2000.00, 2000.20, 1999.90, 2000.10);
      P2Feed(e, 1, 2000.10, 2001.80, 2000.00, 2000.50);
      e.Flush();
      CheckStr(P2Statuses(e), pol == 0 ? "SETUP,MULTI_POOL_NOT_SELECTED" : "MULTI_POOL_NOT_SELECTED,SETUP",
               pol == 0 ? "FIRST_CROSSED_LEVEL selects the nearest pool" : "DEEPEST_PENETRATION_LEVEL selects the farthest pool");
      Check(e.ActiveHighCount() == 0, "every crossed pool is consumed");
     }
   //--- opposite-direction conflict
     {
      LSR_EventConfig c;
      P2Cfg(c, true, false, false, false);
      CLSR_EventEngine e;
      string err;
      e.Init(LSR_TF_M1, c, err);
      e.InjectLevel(LSR_LV_SWING_HIGH, 2001.00, 2001.00, "fx-a");
      e.InjectLevel(LSR_LV_SWING_HIGH, 2001.50, 2001.50, "fx-b");
      e.InjectLevel(LSR_LV_PDL, 1999.00, 1999.00, "fx-c");
      P2Feed(e, 0, 2000.00, 2000.20, 1999.90, 2000.10);
      P2Feed(e, 1, 2000.10, 2001.20, 1998.50, 2000.00);
      e.Flush();
      CheckStr(P2Statuses(e), "CONFLICTING_SWEEP_SAME_BAR,CONFLICTING_SWEEP_SAME_BAR", "same-bar opposite sweeps: no trade");
      Check(e.ActiveHighCount() == 1, "unreached pool stays armed");
     }
   //--- partial pool penetration, then sweep
     {
      LSR_EventConfig c;
      P2Cfg(c, true, false, false, false);
      CLSR_EventEngine e;
      string err;
      e.Init(LSR_TF_M1, c, err);
      e.InjectLevel(LSR_LV_EQUAL_HIGHS, 2001.00, 2001.20, "fx-band");
      P2Feed(e, 0, 2000.00, 2000.20, 1999.90, 2000.10);
      P2Feed(e, 1, 2000.10, 2001.10, 2000.00, 2000.50);
      P2Feed(e, 2, 2000.50, 2001.40, 2000.40, 2000.60);
      e.Flush();
      CheckStr(P2Statuses(e), "PARTIAL_POOL_SWEEP,SETUP", "partial penetration recorded, not traded");
      Check(e.EventTouches(1) == 1, "partial bar counts as a pre-sweep touch");
     }
   //--- clustering, supersession, inherited touches
     {
      LSR_EventConfig c;
      P2Cfg(c, true, false, false, false);
      CLSR_EventEngine e;
      string err;
      e.Init(LSR_TF_M1, c, err);
      e.InjectLevel(LSR_LV_PDH, 2001.00, 2001.00, "fx-pdh");
      P2Feed(e, 0, 2000.00, 2000.20, 1999.90, 2000.10);
      P2Feed(e, 1, 2000.50, 2001.00, 2000.40, 2000.60);
      e.InjectLevel(LSR_LV_SWING_HIGH, 2001.20, 2001.20, "fx-sw1");
      P2Feed(e, 2, 2000.60, 2000.80, 2000.50, 2000.60);
      e.InjectLevel(LSR_LV_SWING_HIGH, 2001.40, 2001.40, "fx-sw2");
      P2Feed(e, 3, 2000.60, 2001.30, 2000.50, 2000.70);
      P2Feed(e, 4, 2000.70, 2000.90, 2000.60, 2000.80);
      e.Flush();
      Check(e.PoolCount() == 3, "3 pool instances");
      CheckStr(e.PoolEndReason(0), "SUPERSEDED", "armed pool is superseded, never rewritten");
      Check(e.PoolTags(1) == "PDH;SWING_HIGH" && e.PoolLower(1) == 2001.00 && e.PoolUpper(1) == 2001.20 && e.PoolInherited(1) == 1,
            "clustered pool keeps all source tags and inherits touches");
      CheckNear(e.PoolAnchor(1), 2001.10, 1e-9, "anchor = median member level");
      CheckStr(P2Statuses(e), "SETUP", "PDH + swing produce one setup");
      Check(e.EventTouches(0) == 1 && e.PoolActive(2), "touch count carried; wider level forms its own pool");
     }
   //--- touch rule
     {
      LSR_EventConfig c;
      P2Cfg(c, true, false, false, false);
      CLSR_EventEngine e;
      string err;
      e.Init(LSR_TF_M1, c, err);
      e.InjectLevel(LSR_LV_SWING_HIGH, 2001.00, 2001.00, "fx");
      P2Feed(e, 0, 2000.00, 2000.20, 1999.90, 2000.10);
      P2Feed(e, 1, 2000.10, 2001.00, 2000.00, 2000.50);
      P2Feed(e, 2, 2000.50, 2000.90, 2000.40, 2000.60);
      P2Feed(e, 3, 2000.60, 2001.00, 2000.50, 2001.00);
      P2Feed(e, 4, 2001.00, 2001.00, 2000.70, 2000.80);
      P2Feed(e, 5, 2000.80, 2001.50, 2000.70, 2000.90);
      e.Flush();
      Check(e.TouchCount() == 2, "re-entry without exit is the same touch");
      Check(P2Statuses(e) == "SETUP" && e.EventTouches(0) == 2, "setup carries 2 pre-sweep touches");
     }
  }

void TestPhase2Sources(void)
  {
   Suite("2 Events: sources");
     {
      LSR_EventConfig c;
      P2Cfg(c, true, true, false, false);
      CLSR_EventEngine e;
      string err;
      e.Init(LSR_TF_M1, c, err);
      datetime d0 = D'2026.01.05', d1 = D'2026.01.06', d2 = D'2026.01.07';
      P2FeedAt(e, d0 + 10 * 3600, 2000.0, 2005.0, 1995.0, 2000.0);
      P2FeedAt(e, d1 + 10 * 3600, 2000.0, 2010.0, 1990.0, 2000.0);
      P2FeedAt(e, d1 + 17 * 3600, 2000.0, 2012.0, 1991.0, 2000.0);
      P2FeedAt(e, d1 + 18 * 3600, 2000.0, 2008.0, 1993.0, 2000.0);
      P2FeedAt(e, d2 + 1 * 3600, 2000.0, 2001.0, 1999.0, 2000.0);
      P2FeedAt(e, d2 + 1 * 3600 + 60, 2000.0, 2013.0, 1999.5, 2005.0);
      e.Flush();
      bool ok = (e.LevelCount() == 4);
      for(int i = 0; i < e.LevelCount() && ok; i++)
        {
         string k = e.LevelKind(i);
         double p = e.LevelLo(i);
         ok = ((k == "PDH" && p == 2012.0) || (k == "PDL" && p == 1990.0) || (k == "PSH" && p == 2012.0) || (k == "PSL" && p == 1991.0)) &&
              e.LevelArm(i) == d2 + 3600;
        }
      Check(ok, "PDH/PDL/PSH/PSL from the previous complete day/session; first observed day skipped");
      Check(e.PoolCount() == 4, "PDH and PSH at one price share a pool");
      Check(P2Statuses(e) == "SETUP" && e.EventTags(0) == "PDH;PSH", "sweep of the clustered PDH+PSH pool");
     }
     {
      LSR_EventConfig c;
      P2Cfg(c, false, false, true, true);
      CLSR_EventEngine e;
      string err;
      e.Init(LSR_TF_M1, c, err);
      double b[10][4] = {{2000.00, 2000.50, 1999.80, 2000.20}, {2000.20, 2001.00, 2000.10, 2000.80},
         {2000.80, 2002.00, 2000.60, 2001.50}, {2001.50, 2001.50, 2000.90, 2001.00},
         {2001.00, 2001.20, 2000.40, 2000.60}, {2000.60, 2001.60, 2000.50, 2001.40},
         {2001.40, 2001.90, 2001.20, 2001.30}, {2001.30, 2001.50, 2000.95, 2001.00},
         {2001.00, 2001.40, 2000.85, 2001.10}, {2001.10, 2002.30, 2001.00, 2001.70}};
      for(int i = 0; i < 10; i++)
         P2Feed(e, i, b[i][0], b[i][1], b[i][2], b[i][3]);
      e.Flush();
      int eq = 0, eqi = -1;
      for(int i = 0; i < e.LevelCount(); i++)
         if(e.LevelKind(i) == "EQUAL_HIGHS")
           {
            eq++;
            eqi = i;
           }
      Check(eq == 1 && e.LevelLo(eqi) == 2001.90 && e.LevelHi(eqi) == 2002.00, "equal highs from two confirmed swings within 3 pips");
      int s = -1;
      for(int i = 0; i < e.EventCount(); i++)
         if(e.EventStatus(i) == "SETUP")
            s = i;
      Check(s >= 0 && e.CountStatus("SETUP") == 1, "one setup");
      if(s >= 0)
        {
         CheckStr(e.EventTags(s), "SWING_HIGH;EQUAL_HIGHS", "setup pool tags");
         CheckNear(e.PoolAnchor(e.EventPoolIndex(s)), 2001.95, 1e-9, "median of member prices");
         CheckNear(e.EventPenetration(s), 0.30, 1e-9, "penetration beyond the pool upper band");
        }
     }
   //--- deterministic rerun
   CLSR_EventEngine r1, r2;
   double ex[2][4] = {{2001.80, 2002.00, 2001.60, 2001.70}, {2001.70, 2002.60, 2001.50, 2001.60}};
   P2SwingEngine(r1, 7, ex, 2);
   P2SwingEngine(r2, 7, ex, 2);
   Check(r1.EventCount() == r2.EventCount() && r1.EventCount() > 0 && r1.EventId(0) == r2.EventId(0), "identical input -> identical EventIDs");
   LSR_EventConfig bad;
   P2Cfg(bad, false, false, false, false);
   string err;
   Check(!LSR_ValidateEventConfig(bad, err), "all sources off is rejected");
   P2Cfg(bad, true, true, true, true);
   bad.equal_tol_mode = LSR_EQTOL_ATR_NORMALIZED;
   Check(!LSR_ValidateEventConfig(bad, err), "ATR_NORMALIZED tolerance is SPEC-INCOMPLETE");
  }

//+------------------------------------------------------------------+
void OnStart(void)
  {
   g_pass = 0;
   g_fail = 0;
   g_report = "LSR Phase 1+2 blocking tests — contracts " + LSR_PHASE1_CONTRACT_ID + ", " + LSR_PHASE2_CONTRACT_ID + "\n";

   TestJson();
   TestTimeframes();
   TestBrokerTime();
   TestSessions();
   TestUnitsAndQuotes();
   TestCosts();
   TestSizing();
   TestAccountRules();
   TestRiskAdmission();
   TestDataAudit();
   TestManifest();
   TestPhase2Bars();
   TestPhase2Sweeps();
   TestPhase2Sources();

   string summary = StringFormat("RESULT: %s  passed=%d failed=%d  build=%d",
                                 g_fail == 0 ? "PASS" : "FAIL", g_pass, g_fail, (int)TerminalInfoInteger(TERMINAL_BUILD));
   g_report += "\n" + summary + "\n";
   LSR_WriteUtf8File("LSR\\tests\\phase1_tests.txt", g_report, true);
   Print("LSR Phase 1 tests ", summary);

   if(InpCloseTerminalWhenDone)
      TerminalClose(g_fail == 0 ? 0 : 1);
  }
//+------------------------------------------------------------------+
