//+------------------------------------------------------------------+
//| ORB_Proxy.mqh                                                    |
//| Tick-level proxy trades (roadmap Section 4). A generalized copy  |
//| of the LSR_EventStudy trade mechanics (entry, SL/TP geometry,    |
//| LIVE_NATIVE_STOP, MAE/MFE, gap/ambiguity) extended with the      |
//| end-of-day TIME_EXIT.                                            |
//|                                                                  |
//| Per broker day and OR length there is at most one entry attempt  |
//| (F7): the first usable tick at or after OR end + delay. If the   |
//| opening range is complete and not a doji, two independent 1-lot  |
//| proxies open on that tick, R10_EOD and R2_EOD.                   |
//|   Long : entry Ask, SL = OR_Low  - EntrySpread (floor to tick)   |
//|   Short: entry Bid, SL = OR_High + EntrySpread (ceil to tick)    |
//|   PlannedRisk1R = loss(entry -> SL) + opening commission         |
//|   net TP: profit(entry -> TP) - commission = TargetR x 1R        |
//| Exit precedence per tick: stop, target, time (tick >= 23:00).    |
//| Stop and target on one tick: stop wins (ambiguous). A proxy      |
//| whose broker day ends without a tick at or after 23:00 is closed |
//| at the last tick of that day (TIME_EXIT_EARLY_CLOSE when 23:00   |
//| lies inside the scheduled session). Proxies never cross a        |
//| broker-day rollover, so no swap accrues.                         |
//+------------------------------------------------------------------+
#ifndef ORB_PROXY_MQH
#define ORB_PROXY_MQH

#include "ORB_Types.mqh"
#include "ORB_Days.mqh"
#include "../LiquiditySweepReversal/LSR_Quote.mqh"
#include "../LiquiditySweepReversal/LSR_Costs.mqh"
#include "../LiquiditySweepReversal/LSR_Sizing.mqh"

struct ORB_ProxyConfig
  {
   double            point;
   double            tick_size;
   double            contract_size;
   int               digits;
   datetime          range_end_exclusive;   // declared end of data (broker-day boundary)
  };

struct ORB_ProxyTrade
  {
   datetime          day;
   int               orlen;
   int               exitv;
   int               dir;
   string            state;           // OPEN, CLOSED, NO_TRADE
   string            reason;
   double            or_open, or_high, or_low, or_close;
   long              entry_msc;
   double            entry_bid;
   double            entry_ask;
   double            entry_price;
   double            sl;
   double            tp;
   double            r_per_lot;
   double            commission;
   double            profit_per_price;
   bool              f2;
   double            mfe;
   double            mae;
   long              last_msc;
   long              exit_msc;
   double            exit_bid;
   double            exit_ask;
   double            exit_price;
   bool              gap_exit;
   bool              ambiguous;
  };

//+------------------------------------------------------------------+
class CORB_ProxySim
  {
private:
   CORB_DayLedger   *m_days;
   CLSR_SymbolEconomics *m_econ;
   CLSR_SessionSchedule *m_sched;
   ORB_ProxyConfig   m_cfg;
   LSR_CostModel     m_costs;
   ORB_ProxyTrade    m_tr[];
   int               m_n;
   int               m_open[];
   datetime          m_attempt[ORB_ORLEN_COUNT];
   bool              m_haveLast;
   LSR_Quote         m_last;

   int               AddTrade(const datetime day, const int k, const int e, const int dir)
     {
      if(m_n >= ArraySize(m_tr))
         ArrayResize(m_tr, m_n + 1, 512);
      int i = m_n++;
      m_tr[i].day = day;
      m_tr[i].orlen = k;
      m_tr[i].exitv = e;
      m_tr[i].dir = dir;
      m_tr[i].state = "OPEN";
      m_tr[i].reason = "";
      m_tr[i].or_open = 0.0;
      m_tr[i].or_high = 0.0;
      m_tr[i].or_low = 0.0;
      m_tr[i].or_close = 0.0;
      m_tr[i].entry_msc = 0;
      m_tr[i].entry_bid = 0.0;
      m_tr[i].entry_ask = 0.0;
      m_tr[i].entry_price = 0.0;
      m_tr[i].sl = 0.0;
      m_tr[i].tp = 0.0;
      m_tr[i].r_per_lot = 0.0;
      m_tr[i].commission = 0.0;
      m_tr[i].profit_per_price = 0.0;
      m_tr[i].f2 = false;
      m_tr[i].mfe = 0.0;
      m_tr[i].mae = 0.0;
      m_tr[i].last_msc = 0;
      m_tr[i].exit_msc = 0;
      m_tr[i].exit_bid = 0.0;
      m_tr[i].exit_ask = 0.0;
      m_tr[i].exit_price = 0.0;
      m_tr[i].gap_exit = false;
      m_tr[i].ambiguous = false;
      return i;
     }

   void              Retire(const int i)
     {
      int n = ArraySize(m_open);
      for(int k = 0; k < n; k++)
         if(m_open[k] == i)
           {
            for(int j = k; j < n - 1; j++)
               m_open[j] = m_open[j + 1];
            ArrayResize(m_open, n - 1, 64);
            return;
           }
     }

   //--- Entry geometry (roadmap 2, 4 item 2). Returns false when the stop is invalid.
   bool              Enter(const int i, const LSR_Quote &q)
     {
      int dir = m_tr[i].dir;
      double slip = (m_costs.slippage_mode == LSR_SLIPPAGE_FIXED_ADVERSE_POINTS ? m_costs.entry_slippage_points * m_cfg.point : 0.0);
      double spread = q.ask - q.bid;
      double entry = (dir > 0 ? q.ask + slip : q.bid - slip);
      double sl = (dir > 0 ? m_tr[i].or_low - spread : m_tr[i].or_high + spread);
      //--- aligned outward to the tick grid, never closer than computed
      sl = (dir > 0 ? MathFloor(sl / m_cfg.tick_size + 1e-9) : MathCeil(sl / m_cfg.tick_size - 1e-9)) * m_cfg.tick_size;
      sl = NormalizeDouble(sl, m_cfg.digits);
      m_tr[i].entry_msc = q.time_msc;
      m_tr[i].entry_bid = q.bid;
      m_tr[i].entry_ask = q.ask;
      m_tr[i].entry_price = entry;
      m_tr[i].last_msc = q.time_msc;
      m_tr[i].sl = sl;

      bool invalid = (dir > 0 ? !(sl < entry) : !(sl > entry));
      double pnlStop = 0.0, pp = 0.0;
      bool ok = !invalid && m_econ.ProfitPerLot((ENUM_LSR_DIRECTION)dir, entry, sl, pnlStop) &&
                m_econ.ProfitPerLot((ENUM_LSR_DIRECTION)dir, entry, entry + dir * 1.0, pp) && pnlStop < 0.0 && pp > 0.0;
      if(!ok)
        {
         m_tr[i].state = "NO_TRADE";
         m_tr[i].reason = ORB_DecisionName(ORB_NO_TRADE_INVALID_STOP);
         return false;
        }
      m_tr[i].commission = LSR_CommissionCurrency(m_costs, 1.0, m_cfg.contract_size, entry);
      m_tr[i].r_per_lot = -pnlStop + m_tr[i].commission;
      m_tr[i].profit_per_price = pp;
      m_tr[i].f2 = (spread <= ORB_F2_MAX_SPREAD_TO_STOP * MathAbs(entry - sl) + LSR_EPS);
      //--- net target (LSR 4.7): profit(entry -> TP) - known costs = TargetR x PlannedRisk1R
      double gross = ORB_ExitTargetR(m_tr[i].exitv) * m_tr[i].r_per_lot + m_tr[i].commission;
      double tp = entry + dir * gross / pp;
      tp = (dir > 0 ? MathCeil(tp / m_cfg.tick_size - 1e-9) : MathFloor(tp / m_cfg.tick_size + 1e-9)) * m_cfg.tick_size;
      m_tr[i].tp = NormalizeDouble(tp, m_cfg.digits);
      m_tr[i].state = "OPEN";
      //--- excursions are measured from the entry tick itself (LSR 0C.14)
      double fav0 = dir * ((dir > 0 ? q.bid : q.ask) - entry);
      m_tr[i].mfe = fav0;
      m_tr[i].mae = MathMax(0.0, -fav0);
      int k = ArraySize(m_open);
      ArrayResize(m_open, k + 1, 64);
      m_open[k] = i;
      return true;
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

   string            EodReason(const datetime day) const
     {
      if(m_sched != NULL && m_sched.IsInSession(day + ORB_EOD_SEC))
         return "TIME_EXIT_EARLY_CLOSE";
      return "TIME_EXIT";
     }

   void              UpdateOpen(const int i, const LSR_Quote &q)
     {
      int dir = m_tr[i].dir;
      double fav = dir * ((dir > 0 ? q.bid : q.ask) - m_tr[i].entry_price);
      if(fav > m_tr[i].mfe)
         m_tr[i].mfe = fav;
      if(-fav > m_tr[i].mae)
         m_tr[i].mae = -fav;
      bool stopHit = (dir > 0 ? q.bid <= m_tr[i].sl : q.ask >= m_tr[i].sl);
      bool tpHit = (dir > 0 ? q.bid >= m_tr[i].tp : q.ask <= m_tr[i].tp);
      bool timeHit = (q.time >= m_tr[i].day + ORB_EOD_SEC);
      bool gap = (q.time_msc - m_tr[i].last_msc) > (long)ORB_GAP_EXIT_SECONDS * 1000;
      m_tr[i].last_msc = q.time_msc;
      if(stopHit && tpHit)
         Close(i, q, gap ? "GAP_CROSSED_BOTH_BARRIERS" : "STOP_AMBIGUOUS_BOTH_BARRIERS", gap, true);
      else
         if(stopHit)
            Close(i, q, gap ? "GAP_STOP" : "STOP", gap, false);
         else
            if(tpHit)
               Close(i, q, gap ? "GAP_TP" : "TP", gap, false);
            else
               if(timeHit)
                  Close(i, q, gap ? "GAP_TIME_EXIT" : "TIME_EXIT", gap, false);
     }

   string            N(const bool ok, const double v, const int d) const { return ok ? DoubleToString(v, d) : "NA"; }

public:
                     CORB_ProxySim(void) { m_days = NULL; m_econ = NULL; m_sched = NULL; m_n = 0; m_haveLast = false; }

   void              Init(CORB_DayLedger *days, CLSR_SymbolEconomics *econ, CLSR_SessionSchedule *sched,
                          const ORB_ProxyConfig &cfg, const LSR_CostModel &costs)
     {
      m_days = days;
      m_econ = econ;
      m_sched = sched;
      m_cfg = cfg;
      m_costs = costs;
      m_n = 0;
      ArrayResize(m_tr, 0);
      ArrayResize(m_open, 0);
      for(int k = 0; k < ORB_ORLEN_COUNT; k++)
         m_attempt[k] = 0;
      m_haveLast = false;
     }

   //--- Call for every usable quote, after the day ledger has consumed any M1 bar
   //--- completed by this quote.
   void              OnQuote(const LSR_Quote &q)
     {
      datetime day = LSR_BrokerDayStart(q.time);
      //--- 1) a proxy whose broker day ended without a tick at/after 23:00 closes on that day's last tick
      if(m_haveLast)
         for(int k = ArraySize(m_open) - 1; k >= 0; k--)
           {
            int i = m_open[k];
            if(day > m_tr[i].day)
               Close(i, m_last, EodReason(m_tr[i].day), false, false);
           }
      //--- 2) stop / target / time on this tick
      for(int k = ArraySize(m_open) - 1; k >= 0; k--)
        {
         if(k >= ArraySize(m_open))
            continue;
         UpdateOpen(m_open[k], q);
        }
      //--- 3) one entry attempt per OR length and broker day (F7)
      long latency = (m_costs.latency_mode == LSR_LATENCY_FIXED_MS ? m_costs.fixed_execution_delay_ms : 0);
      for(int k = 0; k < ORB_ORLEN_COUNT; k++)
        {
         if(m_attempt[k] == day)
            continue;
         datetime orEnd = day + ORB_SESSION_START_SEC + ORB_OrLenMinutes(k) * 60;
         if(q.time_msc < (long)orEnd * 1000 + latency)
            continue;
         m_attempt[k] = day;
         if(q.time >= day + ORB_EOD_SEC)
            continue;                                       // NO_TRADE_NO_TICK
         double o = 0.0, h = 0.0, l = 0.0, c = 0.0;
         int dir = 0;
         if(!m_days.CompleteRange(day, k, o, h, l, c, dir) || dir == 0)
            continue;                                       // incomplete range or doji
         for(int e = 0; e < ORB_EXIT_COUNT; e++)
           {
            int i = AddTrade(day, k, e, dir);
            m_tr[i].or_open = o;
            m_tr[i].or_high = h;
            m_tr[i].or_low = l;
            m_tr[i].or_close = c;
            Enter(i, q);
           }
        }
      m_last = q;
      m_haveLast = true;
     }

   //--- End of run: a proxy whose broker day lies fully inside the declared range
   //--- gets the end-of-day rule; otherwise it is END_OF_DATA.
   void              Finish(void)
     {
      for(int k = ArraySize(m_open) - 1; k >= 0; k--)
        {
         int i = m_open[k];
         if(!m_haveLast)
            continue;
         if(m_tr[i].day + LSR_SECONDS_PER_DAY <= m_cfg.range_end_exclusive)
            Close(i, m_last, EodReason(m_tr[i].day), false, false);
         else
            Close(i, m_last, "END_OF_DATA", false, false);
        }
     }

   int               TradeCount(void) const { return m_n; }
   int               Find(const datetime day, const int k, const int e) const
     {
      for(int i = m_n - 1; i >= 0; i--)
        {
         if(m_tr[i].day < day)
            break;
         if(m_tr[i].day == day && m_tr[i].orlen == k && m_tr[i].exitv == e)
            return i;
        }
      return -1;
     }
   string            TradeState(const int i) const  { return m_tr[i].state; }
   string            TradeReason(const int i) const { return m_tr[i].reason; }
   int               TradeDir(const int i) const    { return m_tr[i].dir; }
   int               TradeExit(const int i) const   { return m_tr[i].exitv; }
   int               TradeOrLen(const int i) const  { return m_tr[i].orlen; }
   datetime          TradeDay(const int i) const    { return m_tr[i].day; }
   double            TradeEntry(const int i) const  { return m_tr[i].entry_price; }
   double            TradeSL(const int i) const     { return m_tr[i].sl; }
   double            TradeTP(const int i) const     { return m_tr[i].tp; }
   double            TradeR(const int i) const      { return m_tr[i].r_per_lot; }
   double            TradeCommission(const int i) const { return m_tr[i].commission; }
   bool              TradeF2(const int i) const     { return m_tr[i].f2; }
   double            TradeMfe(const int i) const    { return m_tr[i].mfe; }
   double            TradeMae(const int i) const    { return m_tr[i].mae; }
   long              TradeEntryMsc(const int i) const { return m_tr[i].entry_msc; }
   long              TradeExitMsc(const int i) const  { return m_tr[i].exit_msc; }
   double            TradeExitPrice(const int i) const { return m_tr[i].exit_price; }
   double            TradeNetPnl(const int i) const
     {
      double pnl = 0.0;
      m_econ.ProfitPerLot((ENUM_LSR_DIRECTION)m_tr[i].dir, m_tr[i].entry_price, m_tr[i].exit_price, pnl);
      return pnl - m_tr[i].commission;
     }
   double            TradeNetR(const int i) const { return m_tr[i].r_per_lot > 0.0 ? TradeNetPnl(i) / m_tr[i].r_per_lot : 0.0; }

   //+---------------------------------------------------------------+
   //| orb_trades_<ORLEN>.csv: one row per TRADE day of the built day |
   //| ledger and exit variant (roadmap 4 item 5).                    |
   //+---------------------------------------------------------------+
   static string     Header(void)
     {
      return "date,or_length,exit_variant,direction,state,reason,or_open,or_high,or_low,or_close,or_end_time,entry_time,"
             "signal_to_entry_ms,entry_bid,entry_ask,entry_price,entry_spread,stop_price,take_profit,target_r,stop_distance,"
             "spread_to_stop,f2,planned_risk_1r_per_lot,commission_per_lot,exit_time,exit_bid,exit_ask,exit_price,exit_reason,"
             "gap_exit,ambiguous_execution,holding_seconds,swap_nights,swap_per_lot,gross_pnl_per_lot,net_pnl_per_lot,gross_r,"
             "costs_r,entry_spread_r,net_r,mfe_price,mae_price,mfe_r,mae_r,weekday,rv,f1,nr7,f5,width_bucket,news_state,in_quarantine";
     }

   bool              WriteCsv(const string path, const int k, CORB_IntervalCheck &quar) const
     {
      int h = FileOpen(path, FILE_WRITE | FILE_BIN | FILE_COMMON);
      if(h == INVALID_HANDLE)
         return false;
      ORB_WriteLine(h, Header());
      int d = m_cfg.digits;
      int nRows = m_days.RowCount();
      for(int ri = 0; ri < nRows; ri++)
        {
         ORB_DayRow r;
         m_days.Row(ri, r);
         if(r.orlen != k || r.decision != ORB_TRADE)
            continue;
         datetime orStart = r.day + ORB_SESSION_START_SEC;
         datetime orEnd = orStart + ORB_OrLenMinutes(k) * 60;
         string dayTail = LSR_WeekdayName(LSR_DayOfWeek(r.day)) + "," + N(r.rv_ok, r.rv, 6) + "," +
                          (r.rv_ok ? (r.f1 ? "1" : "0") : "NA") + "," + (r.nr7_ok ? (r.nr7 ? "1" : "0") : "NA") + "," +
                          (r.f5_ok ? (r.f5 ? "1" : "0") : "NA") + "," + ORB_WidthBucket(r.width_ok, r.width_atr) + "," + ORB_NEWS_STATE;
         for(int e = 0; e < ORB_EXIT_COUNT; e++)
           {
            int i = Find(r.day, k, e);
            string head = LSR_IsoDate(r.day) + "," + ORB_OrLenName(k) + "," + ORB_ExitName(e) + "," + (r.dir > 0 ? "LONG" : "SHORT") + ",";
            string orCols = DoubleToString(r.or_open, d) + "," + DoubleToString(r.or_high, d) + "," + DoubleToString(r.or_low, d) + "," +
                            DoubleToString(r.or_close, d) + "," + LSR_IsoTime(orEnd);
            if(i < 0)
              {
               //--- only possible with a latency delay: bars show a tick after OR end, but none was executable
               string row = head + "NOT_ENTERED,NO_EXECUTABLE_TICK," + orCols;
               for(int c = 0; c < 34; c++)                   // entry_time .. mae_r; target_r stays known
                  row += (c == 8 ? "," + DoubleToString(ORB_ExitTargetR(e), 1) : ",NA");
               ORB_WriteLine(h, row + "," + dayTail + "," + (quar.Overlaps(orStart, orEnd) ? "1" : "0"));
               continue;
              }
            bool entered = (m_tr[i].state != "NO_TRADE");
            bool closed = (m_tr[i].state == "CLOSED");
            double R = m_tr[i].r_per_lot;
            double spread = m_tr[i].entry_ask - m_tr[i].entry_bid;
            double dist = MathAbs(m_tr[i].entry_price - m_tr[i].sl);
            double gross = 0.0;
            if(closed)
               m_econ.ProfitPerLot((ENUM_LSR_DIRECTION)m_tr[i].dir, m_tr[i].entry_price, m_tr[i].exit_price, gross);
            double net = gross - m_tr[i].commission;
            bool rOk = entered && R > 0.0;
            long quarEnd = closed ? m_tr[i].exit_msc / 1000 + 1 : (long)orEnd;
            string row = head + m_tr[i].state + "," + m_tr[i].reason + "," + orCols + "," + LSR_IsoTimeMsc(m_tr[i].entry_msc) + "," +
                         IntegerToString(m_tr[i].entry_msc - (long)orEnd * 1000) + "," +
                         DoubleToString(m_tr[i].entry_bid, d) + "," + DoubleToString(m_tr[i].entry_ask, d) + "," +
                         DoubleToString(m_tr[i].entry_price, d) + "," + DoubleToString(spread, d) + "," +
                         DoubleToString(m_tr[i].sl, d) + "," + N(entered, m_tr[i].tp, d) + "," + DoubleToString(ORB_ExitTargetR(e), 1) + "," +
                         DoubleToString(dist, d) + "," + N(dist > 0.0, dist > 0.0 ? spread / dist : 0.0, 6) + "," +
                         (entered ? (m_tr[i].f2 ? "1" : "0") : "NA") + "," + N(rOk, R, 4) + "," + N(entered, m_tr[i].commission, 4) + "," +
                         (closed ? LSR_IsoTimeMsc(m_tr[i].exit_msc) : "NA") + "," + N(closed, m_tr[i].exit_bid, d) + "," +
                         N(closed, m_tr[i].exit_ask, d) + "," + N(closed, m_tr[i].exit_price, d) + "," + (closed ? m_tr[i].reason : "NA") + "," +
                         (closed ? (m_tr[i].gap_exit ? "1" : "0") : "NA") + "," + (closed ? (m_tr[i].ambiguous ? "1" : "0") : "NA") + "," +
                         (closed ? IntegerToString((m_tr[i].exit_msc - m_tr[i].entry_msc) / 1000) : "NA") + "," +
                         (entered ? "0" : "NA") + "," + N(entered, 0.0, 4) + "," +
                         N(closed, gross, 4) + "," + N(closed, net, 4) + "," +
                         N(closed && rOk, rOk ? gross / R : 0.0, 6) + "," + N(closed && rOk, rOk ? m_tr[i].commission / R : 0.0, 6) + "," +
                         N(rOk, rOk ? spread * m_tr[i].profit_per_price / R : 0.0, 6) + "," + N(closed && rOk, rOk ? net / R : 0.0, 6) + "," +
                         N(entered, m_tr[i].mfe, d) + "," + N(entered, m_tr[i].mae, d) + "," +
                         N(rOk, rOk ? m_tr[i].mfe * m_tr[i].profit_per_price / R : 0.0, 6) + "," +
                         N(rOk, rOk ? m_tr[i].mae * m_tr[i].profit_per_price / R : 0.0, 6) + "," +
                         dayTail + "," + (quar.Overlaps(orStart, (datetime)quarEnd) ? "1" : "0");
            ORB_WriteLine(h, row);
           }
        }
      FileClose(h);
      return true;
     }

   //--- Counts over the TRADE days of the built ledger (for the summary).
   int               CountReason(const int k, const string reason) const
     {
      int c = 0;
      int nRows = m_days.RowCount();
      for(int ri = 0; ri < nRows; ri++)
        {
         ORB_DayRow r;
         m_days.Row(ri, r);
         if(r.orlen != k || r.decision != ORB_TRADE)
            continue;
         for(int e = 0; e < ORB_EXIT_COUNT; e++)
           {
            int i = Find(r.day, k, e);
            string rs = (i < 0 ? "NO_EXECUTABLE_TICK" : m_tr[i].reason);
            if(rs == reason)
               c++;
           }
        }
      return c;
     }
  };

#endif // ORB_PROXY_MQH
//+------------------------------------------------------------------+
