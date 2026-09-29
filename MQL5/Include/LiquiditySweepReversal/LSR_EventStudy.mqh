//+------------------------------------------------------------------+
//| LSR_EventStudy.mqh                                               |
//| Phase 3 — pre-implementation event study (roadmap 3.1–3.7 and    |
//| the binding closures in 3.8).                                    |
//|                                                                  |
//| Every SETUP event of a timeframe engine becomes two independent  |
//| proxy trades on the real tick stream:                            |
//|   A = RECLAIM_CONTROL: first executable tick after sweep close.  |
//|   B = NEXT_BAR_CONFIRM: next bar must close beyond the sweep     |
//|       extreme; entry on the first tick after that close.         |
//| Proxy = 1 lot, LIVE_NATIVE_STOP, SL = sweep extreme ± (entry     |
//| spread + SweepSLExtraPips), net TP = SingleTP_R × PlannedRisk1R, |
//| no BE, no re-entry, no portfolio/risk admission. EventStudyNetR  |
//| = RealizedNetPnL / PlannedRisk1R.                                |
//+------------------------------------------------------------------+
#ifndef LSR_EVENTSTUDY_MQH
#define LSR_EVENTSTUDY_MQH

#include "LSR_Types.mqh"
#include "LSR_Json.mqh"
#include "LSR_Quote.mqh"
#include "LSR_SymbolSpec.mqh"
#include "LSR_Costs.mqh"
#include "LSR_Sizing.mqh"
#include "LSR_Sessions.mqh"
#include "LSR_Liquidity.mqh"

#define LSR_PHASE3_CONTRACT_ID "LSR-PHASE3-EVENTSTUDY-2026-09-29"
#define LSR_GAP_EXIT_SECONDS   300

enum ENUM_LSR_HYPOTHESIS
  {
   LSR_HYP_A_RECLAIM_CONTROL   = 0,
   LSR_HYP_B_NEXT_BAR_CONFIRM  = 1
  };

string LSR_HypothesisName(const int h) { return h == LSR_HYP_A_RECLAIM_CONTROL ? "A_RECLAIM_CONTROL" : "B_NEXT_BAR_CONFIRM"; }

int LSR_FORWARD_HORIZONS[5] = {1, 3, 5, 10, 20};

struct LSR_StudyConfig
  {
   double            sl_extra_pips;
   double            tp_r;
   double            pip_size;
   double            point;
   double            tick_size;
   double            contract_size;
   int               digits;
   long              swap_mode;
   double            swap_long;
   double            swap_short;
   int               swap_rollover3days;
  };

struct LSR_ProxyTrade
  {
   int               ev;             // engine event index
   int               hyp;
   int               dir;            // +1 long, -1 short
   string            state;          // PENDING_CONFIRM, PENDING_ENTRY, OPEN, CLOSED, EXPIRED
   string            reason;
   long              confirm_index;
   datetime          signal_close;
   long              due_msc;
   long              entry_msc;
   double            entry_bid;
   double            entry_ask;
   double            entry_price;
   bool              in_window;
   double            sl;
   double            tp;
   double            r_per_lot;
   double            commission;
   double            profit_per_price;
   double            mfe;
   double            mae;
   long              last_msc;
   datetime          last_day;
   int               swap_nights;
   double            swap_cost;
   long              exit_msc;
   double            exit_bid;
   double            exit_ask;
   double            exit_price;
   bool              gap_exit;
   bool              ambiguous;
  };

//+------------------------------------------------------------------+
class CLSR_EventStudy
  {
private:
   CLSR_EventEngine *m_eng;
   CLSR_SymbolEconomics *m_econ;
   CLSR_StrategyWindow *m_window;
   LSR_StudyConfig   m_cfg;
   LSR_CostModel     m_costs;
   LSR_ProxyTrade    m_tr[];
   int               m_n;
   int               m_live[];       // indices of trades not yet CLOSED/EXPIRED
   int               m_seenEvents;
   int               m_seenBars;
   bool              m_haveLast;
   LSR_Quote         m_last;
   bool              m_swapModeled;

   int               AddTrade(const int ev, const int hyp, const int dir, const string state)
     {
      if(m_n >= ArraySize(m_tr))
         ArrayResize(m_tr, m_n + 1, 1024);
      int i = m_n++;
      m_tr[i].ev = ev;
      m_tr[i].signal_close = 0;
      m_tr[i].due_msc = 0;
      m_tr[i].entry_msc = 0;
      m_tr[i].entry_bid = 0.0;
      m_tr[i].entry_ask = 0.0;
      m_tr[i].entry_price = 0.0;
      m_tr[i].in_window = false;
      m_tr[i].sl = 0.0;
      m_tr[i].tp = 0.0;
      m_tr[i].r_per_lot = 0.0;
      m_tr[i].commission = 0.0;
      m_tr[i].profit_per_price = 0.0;
      m_tr[i].mfe = 0.0;
      m_tr[i].mae = 0.0;
      m_tr[i].last_msc = 0;
      m_tr[i].last_day = 0;
      m_tr[i].swap_nights = 0;
      m_tr[i].swap_cost = 0.0;
      m_tr[i].exit_msc = 0;
      m_tr[i].exit_bid = 0.0;
      m_tr[i].exit_ask = 0.0;
      m_tr[i].exit_price = 0.0;
      m_tr[i].gap_exit = false;
      m_tr[i].ambiguous = false;
      m_tr[i].hyp = hyp;
      m_tr[i].dir = dir;
      m_tr[i].state = state;
      m_tr[i].reason = "";
      m_tr[i].confirm_index = -1;
      int k = ArraySize(m_live);
      ArrayResize(m_live, k + 1, 256);
      m_live[k] = i;
      return i;
     }

   void              Retire(const int i)
     {
      int n = ArraySize(m_live);
      for(int k = 0; k < n; k++)
         if(m_live[k] == i)
           {
            for(int j = k; j < n - 1; j++)
               m_live[j] = m_live[j + 1];
            ArrayResize(m_live, n - 1, 256);
            return;
           }
     }

   double            SwapPerNight(const int dir) const
     {
      double v = (dir > 0 ? m_cfg.swap_long : m_cfg.swap_short);
      if(m_cfg.swap_mode == SYMBOL_SWAP_MODE_POINTS)
         return v * m_cfg.point * m_cfg.contract_size;
      if(m_cfg.swap_mode == SYMBOL_SWAP_MODE_CURRENCY_DEPOSIT || m_cfg.swap_mode == SYMBOL_SWAP_MODE_CURRENCY_SYMBOL)
         return v;
      return 0.0;
     }

   void              Enter(const int i, const LSR_Quote &q)
     {
      int dir = m_tr[i].dir;
      double slip = (m_costs.slippage_mode == LSR_SLIPPAGE_FIXED_ADVERSE_POINTS ? m_costs.entry_slippage_points * m_cfg.point : 0.0);
      LSR_Bar sw;
      m_eng.EventBar(m_tr[i].ev, sw);
      double spread = q.ask - q.bid;
      double buffer = spread + m_cfg.sl_extra_pips * m_cfg.pip_size;
      double entry = (dir > 0 ? q.ask + slip : q.bid - slip);
      double sl = (dir > 0 ? sw.low - buffer : sw.high + buffer);
      //--- stop aligned to the tick grid, never closer than computed (4.4)
      sl = (dir > 0 ? MathFloor(sl / m_cfg.tick_size + 1e-9) : MathCeil(sl / m_cfg.tick_size - 1e-9)) * m_cfg.tick_size;
      sl = NormalizeDouble(sl, m_cfg.digits);

      m_tr[i].entry_msc = q.time_msc;
      m_tr[i].entry_bid = q.bid;
      m_tr[i].entry_ask = q.ask;
      m_tr[i].entry_price = entry;
      m_tr[i].in_window = (m_window != NULL ? m_window.IsEntryAllowed(q.time) : true);
      m_tr[i].last_msc = q.time_msc;
      m_tr[i].last_day = LSR_BrokerDayStart(q.time);

      bool invalid = (dir > 0 ? !(sl < entry) : !(sl > entry));
      double pnlStop = 0.0, pp = 0.0;
      bool ok = !invalid && m_econ.ProfitPerLot((ENUM_LSR_DIRECTION)dir, entry, sl, pnlStop) &&
                m_econ.ProfitPerLot((ENUM_LSR_DIRECTION)dir, entry, entry + dir * 1.0, pp) && pnlStop < 0.0 && pp > 0.0;
      if(!ok)
        {
         m_tr[i].state = "EXPIRED";
         m_tr[i].reason = "INVALID_STOP_GEOMETRY";
         Retire(i);
         return;
        }
      m_tr[i].sl = sl;
      m_tr[i].commission = LSR_CommissionCurrency(m_costs, 1.0, m_cfg.contract_size, entry);
      m_tr[i].r_per_lot = -pnlStop + m_tr[i].commission;
      m_tr[i].profit_per_price = pp;
      //--- net target (4.7): profit(entry -> TP) - known costs = TP_R x PlannedRisk1R
      double gross = m_cfg.tp_r * m_tr[i].r_per_lot + m_tr[i].commission;
      double tp = entry + dir * gross / pp;
      tp = (dir > 0 ? MathCeil(tp / m_cfg.tick_size - 1e-9) : MathFloor(tp / m_cfg.tick_size + 1e-9)) * m_cfg.tick_size;
      m_tr[i].tp = NormalizeDouble(tp, m_cfg.digits);
      m_tr[i].state = "OPEN";
      //--- excursions are measured from the entry tick itself (0C.14)
      double px0 = (dir > 0 ? q.bid : q.ask);
      double fav0 = dir * (px0 - entry);
      m_tr[i].mfe = fav0;
      m_tr[i].mae = MathMax(0.0, -fav0);
     }

   void              Close(const int i, const LSR_Quote &q, const string reason, const bool gap, const bool ambiguous)
     {
      int dir = m_tr[i].dir;
      double slip = (m_costs.slippage_mode == LSR_SLIPPAGE_FIXED_ADVERSE_POINTS ? m_costs.exit_slippage_points * m_cfg.point : 0.0);
      m_tr[i].exit_msc = q.time_msc;
      m_tr[i].exit_bid = q.bid;
      m_tr[i].exit_ask = q.ask;
      m_tr[i].exit_price = (dir > 0 ? q.bid - slip : q.ask + slip);
      m_tr[i].gap_exit = gap;
      m_tr[i].ambiguous = ambiguous;
      m_tr[i].state = "CLOSED";
      m_tr[i].reason = reason;
      Retire(i);
     }

   void              UpdateOpen(const int i, const LSR_Quote &q)
     {
      int dir = m_tr[i].dir;
      //--- swap at each broker-day rollover while held
      datetime d = LSR_BrokerDayStart(q.time);
      if(d > m_tr[i].last_day)
        {
         int nights = (LSR_DayOfWeek(m_tr[i].last_day) == m_cfg.swap_rollover3days ? 3 : 1);
         m_tr[i].swap_nights += nights;
         m_tr[i].swap_cost += -SwapPerNight(dir) * nights;
         m_tr[i].last_day = d;
        }
      double px = (dir > 0 ? q.bid : q.ask);
      double fav = dir * (px - m_tr[i].entry_price);
      if(fav > m_tr[i].mfe)
         m_tr[i].mfe = fav;
      if(-fav > m_tr[i].mae)
         m_tr[i].mae = -fav;
      bool stopHit = (dir > 0 ? q.bid <= m_tr[i].sl : q.ask >= m_tr[i].sl);
      bool tpHit = (dir > 0 ? q.bid >= m_tr[i].tp : q.ask <= m_tr[i].tp);
      bool gap = (q.time_msc - m_tr[i].last_msc) > (long)LSR_GAP_EXIT_SECONDS * 1000;
      m_tr[i].last_msc = q.time_msc;
      if(stopHit && tpHit)
         Close(i, q, gap ? "GAP_CROSSED_BOTH_BARRIERS" : "STOP_AMBIGUOUS_BOTH_BARRIERS", gap, true);
      else
         if(stopHit)
            Close(i, q, gap ? "GAP_STOP" : "STOP", gap, false);
         else
            if(tpHit)
               Close(i, q, gap ? "GAP_TP" : "TP", gap, false);
     }

   //--- another valid sweep in the opposite direction on the confirmation bar (0C.7)
   bool              OppositeSweepOnBar(const long barIndex, const int dir) const
     {
      for(int e = m_eng.EventCount() - 1; e >= 0; e--)
        {
         long bi = m_eng.EventBarIndex(e);
         if(bi < barIndex)
            break;
         if(bi != barIndex)
            continue;
         string st = m_eng.EventStatus(e);
         bool validSweep = (st == "SETUP" || st == "MULTI_POOL_NOT_SELECTED" || st == "CONFLICTING_SWEEP_SAME_BAR");
         int evDir = (m_eng.EventSide(e) > 0 ? -1 : 1);
         if(validSweep && evDir == -dir)
            return true;
        }
      return false;
     }

   string            N(const bool ok, const double v, const int d) const { return ok ? DoubleToString(v, d) : "NA"; }
   string            P(const double v) const { return DoubleToString(v, m_cfg.digits); }
   string            T(const long msc) const { return msc > 0 ? LSR_IsoTimeMsc(msc) : ""; }

public:
                     CLSR_EventStudy(void) { m_eng = NULL; m_econ = NULL; m_window = NULL; m_n = 0; }

   void              Init(CLSR_EventEngine *eng, CLSR_SymbolEconomics *econ, CLSR_StrategyWindow *window,
                          const LSR_StudyConfig &cfg, const LSR_CostModel &costs)
     {
      m_eng = eng;
      m_econ = econ;
      m_window = window;
      m_cfg = cfg;
      m_costs = costs;
      m_n = 0;
      ArrayResize(m_tr, 0);
      ArrayResize(m_live, 0);
      m_seenEvents = 0;
      m_seenBars = 0;
      m_haveLast = false;
      m_swapModeled = (cfg.swap_mode == SYMBOL_SWAP_MODE_DISABLED || cfg.swap_mode == SYMBOL_SWAP_MODE_POINTS ||
                       cfg.swap_mode == SYMBOL_SWAP_MODE_CURRENCY_DEPOSIT || cfg.swap_mode == SYMBOL_SWAP_MODE_CURRENCY_SYMBOL);
     }

   //--- Call after the engine has consumed the current tick (OnM1/OnTime).
   void              OnEngineUpdate(void)
     {
      long latency = (m_costs.latency_mode == LSR_LATENCY_FIXED_MS ? m_costs.fixed_execution_delay_ms : 0);
      //--- new SETUP events -> hypothesis A and B proxies
      int ne = m_eng.EventCount();
      for(int e = m_seenEvents; e < ne; e++)
        {
         if(m_eng.EventStatus(e) != "SETUP")
            continue;
         int dir = (m_eng.EventSide(e) > 0 ? -1 : 1);
         datetime closeT = m_eng.EventBarTime(e) + m_eng.Period();
         int a = AddTrade(e, LSR_HYP_A_RECLAIM_CONTROL, dir, "PENDING_ENTRY");
         m_tr[a].signal_close = closeT;
         m_tr[a].due_msc = (long)closeT * 1000 + latency;
         int b = AddTrade(e, LSR_HYP_B_NEXT_BAR_CONFIRM, dir, "PENDING_CONFIRM");
         m_tr[b].confirm_index = m_eng.EventBarIndex(e) + 1;
        }
      m_seenEvents = ne;
      //--- confirmation bars (B)
      int nb = m_eng.BarCount();
      if(nb != m_seenBars)
        {
         for(int k = ArraySize(m_live) - 1; k >= 0; k--)
           {
            int i = m_live[k];
            if(m_tr[i].state != "PENDING_CONFIRM" || m_tr[i].confirm_index >= nb)
               continue;
            LSR_Bar cb, sw;
            m_eng.GetBar((int)m_tr[i].confirm_index, cb);
            m_eng.EventBar(m_tr[i].ev, sw);
            if(OppositeSweepOnBar(m_tr[i].confirm_index, m_tr[i].dir))
              {
               m_tr[i].state = "EXPIRED";
               m_tr[i].reason = "CONFIRMATION_CONFLICT";
               Retire(i);
               continue;
              }
            bool confirmed = (m_tr[i].dir < 0 ? cb.close < sw.low : cb.close > sw.high);
            if(!confirmed)
              {
               m_tr[i].state = "EXPIRED";
               m_tr[i].reason = "CONFIRMATION_FAILED";
               Retire(i);
               continue;
              }
            m_tr[i].state = "PENDING_ENTRY";
            m_tr[i].signal_close = cb.time + cb.period;
            m_tr[i].due_msc = (long)m_tr[i].signal_close * 1000 + latency;
           }
         m_seenBars = nb;
        }
     }

   //--- Call for every usable quote (after OnEngineUpdate for that quote).
   void              OnQuote(const LSR_Quote &q)
     {
      m_last = q;
      m_haveLast = true;
      for(int k = ArraySize(m_live) - 1; k >= 0; k--)
        {
         if(k >= ArraySize(m_live))
            continue;
         int i = m_live[k];
         if(m_tr[i].state == "PENDING_ENTRY" && q.time_msc >= m_tr[i].due_msc)
            Enter(i, q);
         else
            if(m_tr[i].state == "OPEN")
               UpdateOpen(i, q);
        }
     }

   void              Finish(void)
     {
      for(int k = ArraySize(m_live) - 1; k >= 0; k--)
        {
         int i = m_live[k];
         if(m_tr[i].state == "OPEN" && m_haveLast)
            Close(i, m_last, "END_OF_DATA", false, false);
         else
           {
            m_tr[i].reason = (m_tr[i].state == "PENDING_CONFIRM" ? "NOT_CONFIRMED_END_OF_DATA" : "NOT_FILLED_END_OF_DATA");
            m_tr[i].state = "EXPIRED";
            Retire(i);
           }
        }
     }

   int               TradeCount(void) const { return m_n; }
   string            TradeState(const int i) const  { return m_tr[i].state; }
   string            TradeReason(const int i) const { return m_tr[i].reason; }
   int               TradeHyp(const int i) const    { return m_tr[i].hyp; }
   int               TradeDir(const int i) const    { return m_tr[i].dir; }
   double            TradeEntry(const int i) const  { return m_tr[i].entry_price; }
   double            TradeSL(const int i) const     { return m_tr[i].sl; }
   double            TradeTP(const int i) const     { return m_tr[i].tp; }
   double            TradeR(const int i) const      { return m_tr[i].r_per_lot; }
   double            TradeMfe(const int i) const    { return m_tr[i].mfe; }
   double            TradeMae(const int i) const    { return m_tr[i].mae; }
   long              TradeEntryMsc(const int i) const { return m_tr[i].entry_msc; }
   double            TradeNetPnl(const int i) const
     {
      double pnl = 0.0;
      m_econ.ProfitPerLot((ENUM_LSR_DIRECTION)m_tr[i].dir, m_tr[i].entry_price, m_tr[i].exit_price, pnl);
      return pnl - m_tr[i].commission - m_tr[i].swap_cost;
     }
   double            TradeNetR(const int i) const { return m_tr[i].r_per_lot > 0.0 ? TradeNetPnl(i) / m_tr[i].r_per_lot : 0.0; }
   int               CountState(const string st, const int hyp) const
     {
      int c = 0;
      for(int i = 0; i < m_n; i++)
         if(m_tr[i].state == st && m_tr[i].hyp == hyp)
            c++;
      return c;
     }

   //+---------------------------------------------------------------+
   bool              WriteCsv(const string path, CLSR_QuarantineCheck &q) const
     {
      int h = FileOpen(path, FILE_WRITE | FILE_BIN | FILE_COMMON);
      if(h == INVALID_HANDLE)
         return false;
      string hdr = "tf,event_id,hypothesis,direction,state,reason,source_tags,member_level_ids,touch_count,touch_bucket,swing_prominence_atr,"
                   "sweep_bar_time,sweep_close_time,sweep_open,sweep_high,sweep_low,sweep_close,pool_lower,pool_upper,sweep_extreme,"
                   "penetration,reclaim,penetration_pips,reclaim_pips,signal_close_time,entry_time,signal_to_entry_ms,entry_bid,entry_ask,"
                   "entry_price,entry_spread,entry_spread_pips,in_entry_window,stop_price,take_profit,planned_stop_distance,"
                   "planned_risk_1r_per_lot,commission_per_lot,exit_time,exit_bid,exit_ask,exit_price,exit_reason,gap_exit,"
                   "ambiguous_execution,holding_seconds,swap_nights,swap_per_lot,swap_modeled,gross_pnl_per_lot,net_pnl_per_lot,"
                   "gross_r,costs_r,net_r,mfe_price,mae_price,mfe_r,mae_r";
      for(int hz = 0; hz < 5; hz++)
         hdr += ",fwd_" + IntegerToString(LSR_FORWARD_HORIZONS[hz]);
      for(int hz = 0; hz < 5; hz++)
         hdr += ",class_" + IntegerToString(LSR_FORWARD_HORIZONS[hz]);
      hdr += ",sweep_hour,weekday,time_bucket,spread_bucket,news_state,in_quarantine";
      CLSR_EventEngine::WriteLine(h, hdr);

      string tf = LSR_TimeframeName(m_eng.Timeframe());
      for(int i = 0; i < m_n; i++)
        {
         int e = m_tr[i].ev;
         int dir = m_tr[i].dir;
         LSR_Bar sw;
         m_eng.EventBar(e, sw);
         double pl = m_eng.EventPoolLower(e), pu = m_eng.EventPoolUpper(e);
         double pen = m_eng.EventPenetration(e), rec = m_eng.EventReclaim(e);
         double prom = 0.0;
         bool hasProm = m_eng.EventSwingProminence(e, prom);
         bool entered = (m_tr[i].entry_msc > 0 && m_tr[i].r_per_lot > 0.0);
         bool closed = (m_tr[i].state == "CLOSED");
         double gross = 0.0;
         if(closed)
            m_econ.ProfitPerLot((ENUM_LSR_DIRECTION)dir, m_tr[i].entry_price, m_tr[i].exit_price, gross);
         double net = gross - m_tr[i].commission - m_tr[i].swap_cost;
         double R = m_tr[i].r_per_lot;
         double spread = m_tr[i].entry_ask - m_tr[i].entry_bid;
         double spreadPips = spread / m_cfg.pip_size;
         string sb = !entered ? "NA" : (spreadPips < 1.0 ? "LT1" : spreadPips < 2.0 ? "1_2" : spreadPips < 3.0 ? "2_3" : spreadPips < 5.0 ? "3_5" : "GE5");
         datetime closeT = sw.time + sw.period;
         int hour = (int)((closeT % LSR_SECONDS_PER_DAY) / 3600);
         string bucket = hour < 8 ? "H00_08" : hour < 13 ? "H08_13" : hour < 17 ? "H13_17" : "H17_24";
         long quarEnd = closed ? m_tr[i].exit_msc / 1000 + 1 : closeT;
         bool quar = q.Overlaps(sw.time, (datetime)quarEnd);

         string row = tf + "," + m_eng.EventId(e) + "," + LSR_HypothesisName(m_tr[i].hyp) + "," + (dir > 0 ? "LONG" : "SHORT") + "," +
                      m_tr[i].state + "," + m_tr[i].reason + "," + m_eng.EventTags(e) + "," + m_eng.EventMemberIds(e) + "," +
                      IntegerToString(m_eng.EventTouches(e)) + "," + LSR_TouchBucket(m_eng.EventTouches(e)) + "," + N(hasProm, prom, 6) + "," +
                      LSR_IsoTime(sw.time) + "," + LSR_IsoTime(closeT) + "," + P(sw.open) + "," + P(sw.high) + "," + P(sw.low) + "," + P(sw.close) + "," +
                      P(pl) + "," + P(pu) + "," + P(dir < 0 ? sw.high : sw.low) + "," + P(pen) + "," + P(rec) + "," +
                      DoubleToString(pen / m_cfg.pip_size, 4) + "," + DoubleToString(rec / m_cfg.pip_size, 4) + "," +
                      (m_tr[i].signal_close > 0 ? LSR_IsoTime(m_tr[i].signal_close) : "") + "," + T(m_tr[i].entry_msc) + "," +
                      (entered ? IntegerToString(m_tr[i].entry_msc - (long)m_tr[i].signal_close * 1000) : "NA") + "," +
                      N(entered, m_tr[i].entry_bid, m_cfg.digits) + "," + N(entered, m_tr[i].entry_ask, m_cfg.digits) + "," +
                      N(entered, m_tr[i].entry_price, m_cfg.digits) + "," + N(entered, spread, m_cfg.digits) + "," + N(entered, spreadPips, 4) + "," +
                      (entered ? (m_tr[i].in_window ? "1" : "0") : "NA") + "," +
                      N(entered, m_tr[i].sl, m_cfg.digits) + "," + N(entered, m_tr[i].tp, m_cfg.digits) + "," +
                      N(entered, MathAbs(m_tr[i].entry_price - m_tr[i].sl), m_cfg.digits) + "," +
                      N(entered, R, 4) + "," + N(entered, m_tr[i].commission, 4) + "," +
                      T(m_tr[i].exit_msc) + "," + N(closed, m_tr[i].exit_bid, m_cfg.digits) + "," + N(closed, m_tr[i].exit_ask, m_cfg.digits) + "," +
                      N(closed, m_tr[i].exit_price, m_cfg.digits) + "," + (closed ? m_tr[i].reason : "") + "," +
                      (closed ? (m_tr[i].gap_exit ? "1" : "0") : "NA") + "," + (closed ? (m_tr[i].ambiguous ? "1" : "0") : "NA") + "," +
                      (closed ? IntegerToString((m_tr[i].exit_msc - m_tr[i].entry_msc) / 1000) : "NA") + "," +
                      IntegerToString(m_tr[i].swap_nights) + "," + N(entered, m_tr[i].swap_cost, 4) + "," + (m_swapModeled ? "1" : "0") + "," +
                      N(closed, gross, 4) + "," + N(closed, net, 4) + "," +
                      N(closed, gross / R, 6) + "," + N(closed, (m_tr[i].commission + m_tr[i].swap_cost) / R, 6) + "," + N(closed, net / R, 6) + "," +
                      N(entered, m_tr[i].mfe, m_cfg.digits) + "," + N(entered, m_tr[i].mae, m_cfg.digits) + "," +
                      N(entered, m_tr[i].mfe * m_tr[i].profit_per_price / R, 6) + "," + N(entered, m_tr[i].mae * m_tr[i].profit_per_price / R, 6);
         long bi = m_eng.EventBarIndex(e);
         string cls = "";
         for(int hz = 0; hz < 5; hz++)
           {
            LSR_Bar fb;
            bool ok = m_eng.GetBar((int)(bi + LSR_FORWARD_HORIZONS[hz]), fb);
            double fr = ok ? (dir > 0 ? fb.close - sw.close : sw.close - fb.close) : 0.0;
            row += "," + N(ok, fr, m_cfg.digits);
            cls += "," + (!ok ? "NA" : fr > 0.0 ? "REVERSAL" : fr < 0.0 ? "CONTINUATION" : "UNRESOLVED");
           }
         row += cls + "," + IntegerToString(hour) + "," + LSR_WeekdayName(LSR_DayOfWeek(closeT)) + "," + bucket + "," + sb + ",NO_CALENDAR_OBSERVE_ONLY," +
                (quar ? "1" : "0");
         CLSR_EventEngine::WriteLine(h, row);
        }
      FileClose(h);
      return true;
     }
  };

#endif // LSR_EVENTSTUDY_MQH
//+------------------------------------------------------------------+
