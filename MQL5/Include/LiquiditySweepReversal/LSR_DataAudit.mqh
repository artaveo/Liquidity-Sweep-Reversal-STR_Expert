//+------------------------------------------------------------------+
//| LSR_DataAudit.mqh                                                |
//| Tick/data-quality audit (roadmap 1.4).                           |
//|                                                                  |
//| AuditEligibleMinute    = broker-scheduled tradeable minute in the|
//|                          declared range (not in a declared       |
//|                          closed-market interval).                |
//| PotentialFallbackMinute = eligible minute with zero usable raw   |
//|                          tick records OR failed M1 reconciliation|
//| CriticalDataGap        = continuously tradeable interval between |
//|                          consecutive usable raw ticks longer than|
//|                          CriticalDataGapThresholdMinutes.        |
//| PotentialFallbackMinute is never labelled "generated ticks".     |
//+------------------------------------------------------------------+
#ifndef LSR_DATAAUDIT_MQH
#define LSR_DATAAUDIT_MQH

#include "LSR_Types.mqh"
#include "LSR_Json.mqh"
#include "LSR_Quote.mqh"
#include "LSR_Sessions.mqh"
#include "LSR_Timeframes.mqh"

#define LSR_AUDIT_MAX_LISTED_ROWS 20000

//+------------------------------------------------------------------+
//| Tick-record anomaly counters (shared by raw and stream audits).  |
//+------------------------------------------------------------------+
struct LSR_TickAnomalies
  {
   long              records;
   long              usable;
   long              non_monotonic;       // time_msc strictly earlier than the previous record
   long              duplicate_timestamp; // same time_msc as the previous record
   long              exact_duplicate;     // identical to the previous record in every field
   long              nonpositive_spread;  // ask <= bid with positive prices
   long              invalid_price;       // non-finite or non-positive bid/ask
   long              first_msc;
   long              last_msc;
   double            min_spread;
   double            max_spread;
  };

void LSR_TickAnomaliesReset(LSR_TickAnomalies &a)
  {
   a.records = 0;
   a.usable = 0;
   a.non_monotonic = 0;
   a.duplicate_timestamp = 0;
   a.exact_duplicate = 0;
   a.nonpositive_spread = 0;
   a.invalid_price = 0;
   a.first_msc = -1;
   a.last_msc = -1;
   a.min_spread = EMPTY_VALUE;
   a.max_spread = EMPTY_VALUE;
  }

bool LSR_TickIsUsable(const MqlTick &t)
  {
   if(!MathIsValidNumber(t.bid) || !MathIsValidNumber(t.ask))
      return false;
   return t.bid > 0.0 && t.ask > 0.0 && t.ask > t.bid;
  }

//--- Records one tick; returns true if usable.
bool LSR_TickAnomaliesObserve(LSR_TickAnomalies &a, const MqlTick &t, const bool havePrev, const MqlTick &prev)
  {
   a.records++;
   if(a.first_msc < 0)
      a.first_msc = t.time_msc;
   if(havePrev)
     {
      if(t.time_msc < prev.time_msc)
         a.non_monotonic++;
      else
         if(t.time_msc == prev.time_msc)
           {
            a.duplicate_timestamp++;
            if(t.bid == prev.bid && t.ask == prev.ask && t.last == prev.last &&
               t.volume == prev.volume && t.flags == prev.flags && t.volume_real == prev.volume_real)
               a.exact_duplicate++;
           }
     }
   if(t.time_msc > a.last_msc)
      a.last_msc = t.time_msc;

   if(!MathIsValidNumber(t.bid) || !MathIsValidNumber(t.ask) || t.bid <= 0.0 || t.ask <= 0.0)
     {
      a.invalid_price++;
      return false;
     }
   double spread = t.ask - t.bid;
   if(spread <= 0.0)
     {
      a.nonpositive_spread++;
      return false;
     }
   a.usable++;
   if(a.min_spread == EMPTY_VALUE || spread < a.min_spread)
      a.min_spread = spread;
   if(a.max_spread == EMPTY_VALUE || spread > a.max_spread)
      a.max_spread = spread;
   return true;
  }

void LSR_WriteTickAnomaliesJson(CLSR_Json &j, const LSR_TickAnomalies &a)
  {
   j.BeginObject();
   j.KInt("records", a.records);
   j.KInt("usable_records", a.usable);
   j.KStr("first_record_time", LSR_IsoTimeMsc(a.first_msc));
   j.KStr("last_record_time", LSR_IsoTimeMsc(a.last_msc));
   j.KInt("non_monotonic_timestamps", a.non_monotonic);
   j.KInt("duplicate_timestamps", a.duplicate_timestamp);
   j.KInt("exact_duplicate_records", a.exact_duplicate);
   j.KInt("nonpositive_spreads", a.nonpositive_spread);
   j.KInt("invalid_or_nonpositive_prices", a.invalid_price);
   if(a.min_spread == EMPTY_VALUE)
     {
      j.KNull("min_usable_spread");
      j.KNull("max_usable_spread");
     }
   else
     {
      j.KNum("min_usable_spread", a.min_spread, 8);
      j.KNum("max_usable_spread", a.max_spread, 8);
     }
   j.EndObject();
  }

//+------------------------------------------------------------------+
//| Raw real-tick record audit, processed in contiguous chunks.      |
//+------------------------------------------------------------------+
class CLSR_RawTickAudit
  {
private:
   CLSR_SessionSchedule *m_sched;
   CLSR_ClosureCalendar *m_cal;
   ENUM_LSR_PRICE_SOURCE m_src;
   double            m_tolerance;
   datetime          m_rangeStart;
   datetime          m_rangeEnd;       // exclusive
   datetime          m_auditedTo;      // exclusive end of processed chunks
   int               m_thresholdSec;
   string            m_sourceLabel;

   LSR_TickAnomalies m_anom;
   bool              m_havePrev;
   MqlTick           m_prev;
   bool              m_haveUsable;
   long              m_lastUsableMsc;

   long              m_eligible;
   long              m_ok;
   long              m_pfmNoTicksNoBar;
   long              m_pfmNoTicksWithBar;
   long              m_pfmRecon;
   long              m_closedByCalendar;
   long              m_ticksOutsideSchedule;
   long              m_chunkErrors;

   datetime          m_pfmTime[];
   int               m_pfmClass[];
   datetime          m_gapFrom[];
   datetime          m_gapTo[];
   long              m_gapCount;

   void              AddGap(const datetime a, const datetime b)
     {
      m_gapCount++;
      int n = ArraySize(m_gapFrom);
      if(n >= LSR_AUDIT_MAX_LISTED_ROWS)
         return;
      ArrayResize(m_gapFrom, n + 1);
      ArrayResize(m_gapTo, n + 1);
      m_gapFrom[n] = a;
      m_gapTo[n] = b;
     }

   //--- Critical segments strictly inside the tick-free interval (a, b).
   void              CheckGap(const datetime a, const datetime b)
     {
      if(b - a <= m_thresholdSec)
         return;
      datetime sf[], st[];
      int n = LSR_TradeableSegments(m_sched, m_cal, a, b, sf, st);
      for(int i = 0; i < n; i++)
         if(st[i] - sf[i] > m_thresholdSec)
            AddGap(sf[i], st[i]);
     }

   void              AddPfm(const datetime minute, const ENUM_LSR_MINUTE_CLASS c)
     {
      int n = ArraySize(m_pfmTime);
      if(n >= LSR_AUDIT_MAX_LISTED_ROWS)
         return;
      ArrayResize(m_pfmTime, n + 1);
      ArrayResize(m_pfmClass, n + 1);
      m_pfmTime[n] = minute;
      m_pfmClass[n] = (int)c;
     }

   bool              BarMatches(const MqlRates &bar, const double o, const double h, const double l, const double c) const
     {
      return MathAbs(bar.open - o) <= m_tolerance && MathAbs(bar.high - h) <= m_tolerance &&
             MathAbs(bar.low - l) <= m_tolerance && MathAbs(bar.close - c) <= m_tolerance;
     }

public:
                     CLSR_RawTickAudit(void) { m_sched = NULL; m_cal = NULL; }

   void              Init(CLSR_SessionSchedule *sched, CLSR_ClosureCalendar *cal, const ENUM_LSR_PRICE_SOURCE src,
                          const double point, const datetime rangeStart, const datetime rangeEndExclusive,
                          const string sourceLabel)
     {
      m_sched = sched;
      m_cal = cal;
      m_src = src;
      m_tolerance = 0.5 * point;
      m_rangeStart = rangeStart;
      m_rangeEnd = rangeEndExclusive;
      m_auditedTo = rangeStart;
      m_thresholdSec = LSR_CRITICAL_DATA_GAP_THRESHOLD_MIN * 60;
      m_sourceLabel = sourceLabel;
      LSR_TickAnomaliesReset(m_anom);
      m_havePrev = false;
      m_haveUsable = false;
      m_lastUsableMsc = 0;
      m_eligible = 0;
      m_ok = 0;
      m_pfmNoTicksNoBar = 0;
      m_pfmNoTicksWithBar = 0;
      m_pfmRecon = 0;
      m_closedByCalendar = 0;
      m_ticksOutsideSchedule = 0;
      m_chunkErrors = 0;
      m_gapCount = 0;
      ArrayResize(m_pfmTime, 0);
      ArrayResize(m_pfmClass, 0);
      ArrayResize(m_gapFrom, 0);
      ArrayResize(m_gapTo, 0);
     }

   datetime          AuditedTo(void) const  { return m_auditedTo; }
   datetime          RangeStart(void) const { return m_rangeStart; }
   datetime          RangeEnd(void) const   { return m_rangeEnd; }

   void              MarkChunkError(const datetime chunkEnd)
     {
      m_chunkErrors++;
      m_auditedTo = chunkEnd;
     }

   //+---------------------------------------------------------------+
   //| ticks: raw records with time in [chunkStart, chunkEnd), in     |
   //| source order. rates: M1 bars with time in [chunkStart,chunkEnd)|
   //| sorted ascending. Chunks must be contiguous and minute-aligned.|
   //+---------------------------------------------------------------+
   void              ProcessChunk(const MqlTick &ticks[], const int nTicks, const MqlRates &rates[], const int nRates,
                                  const datetime chunkStart, const datetime chunkEnd)
     {
      int minutes = (int)((chunkEnd - chunkStart) / 60);
      if(minutes <= 0)
         return;
      int cnt[];
      double o[], h[], l[], c[];
      ArrayResize(cnt, minutes);
      ArrayResize(o, minutes);
      ArrayResize(h, minutes);
      ArrayResize(l, minutes);
      ArrayResize(c, minutes);
      ArrayInitialize(cnt, 0);

      for(int i = 0; i < nTicks; i++)
        {
         bool usable = LSR_TickAnomaliesObserve(m_anom, ticks[i], m_havePrev, m_prev);
         m_prev = ticks[i];
         m_havePrev = true;
         if(!usable)
            continue;
         double px = (m_src == LSR_PRICE_BID ? ticks[i].bid : ticks[i].last);
         if(m_src == LSR_PRICE_LAST && !(px > 0.0))
            continue;

         datetime ts = (datetime)(ticks[i].time_msc / 1000);
         if(!m_sched.IsInSession(ts))
            m_ticksOutsideSchedule++;

         // gap bookkeeping on usable ticks only
         if(m_haveUsable)
            CheckGap((datetime)(m_lastUsableMsc / 1000), ts);
         else
            CheckGap(m_rangeStart, ts);
         if(!m_haveUsable || ticks[i].time_msc > m_lastUsableMsc)
            m_lastUsableMsc = ticks[i].time_msc;
         m_haveUsable = true;

         int m = (int)((ts - chunkStart) / 60);
         if(m < 0 || m >= minutes)
            continue;
         if(cnt[m] == 0)
           {
            o[m] = px;
            h[m] = px;
            l[m] = px;
           }
         else
           {
            if(px > h[m])
               h[m] = px;
            if(px < l[m])
               l[m] = px;
           }
         c[m] = px;
         cnt[m]++;
        }

      int ri = 0;
      for(int m = 0; m < minutes; m++)
        {
         datetime mt = chunkStart + m * 60;
         while(ri < nRates && rates[ri].time < mt)
            ri++;
         bool haveBar = (ri < nRates && rates[ri].time == mt);

         if(mt < m_rangeStart || mt >= m_rangeEnd || !m_sched.IsInSession(mt))
            continue;
         if(m_cal.Contains(mt))
           {
            m_closedByCalendar++;
            continue;
           }
         m_eligible++;
         ENUM_LSR_MINUTE_CLASS cls;
         if(cnt[m] == 0)
            cls = haveBar ? LSR_MINUTE_PFM_NO_TICKS_WITH_BAR : LSR_MINUTE_PFM_NO_TICKS_NO_BAR;
         else
            cls = (haveBar && BarMatches(rates[ri], o[m], h[m], l[m], c[m])) ? LSR_MINUTE_OK : LSR_MINUTE_PFM_RECONCILIATION_FAILED;

         switch(cls)
           {
            case LSR_MINUTE_OK:                        m_ok++; break;
            case LSR_MINUTE_PFM_NO_TICKS_NO_BAR:       m_pfmNoTicksNoBar++; AddPfm(mt, cls); break;
            case LSR_MINUTE_PFM_NO_TICKS_WITH_BAR:     m_pfmNoTicksWithBar++; AddPfm(mt, cls); break;
            case LSR_MINUTE_PFM_RECONCILIATION_FAILED: m_pfmRecon++; AddPfm(mt, cls); break;
           }
        }
      m_auditedTo = chunkEnd;
     }

   //--- Trailing gap from the last usable tick to the audited end.
   void              Finalize(void)
     {
      datetime end = (m_auditedTo < m_rangeEnd ? m_auditedTo : m_rangeEnd);
      if(m_haveUsable)
         CheckGap((datetime)(m_lastUsableMsc / 1000), end);
      else
         CheckGap(m_rangeStart, end);
     }

   long              EligibleMinutes(void) const  { return m_eligible; }
   long              FallbackMinutes(void) const  { return m_pfmNoTicksNoBar + m_pfmNoTicksWithBar + m_pfmRecon; }
   long              CriticalGapCount(void) const { return m_gapCount; }
   long              ChunkErrors(void) const      { return m_chunkErrors; }
   double            FallbackShare(void) const
     {
      return m_eligible > 0 ? (double)FallbackMinutes() / (double)m_eligible : EMPTY_VALUE;
     }
   bool              CoverageComplete(void) const { return m_auditedTo >= m_rangeEnd; }

   ENUM_LSR_DATA_GATE Gate(void) const
     {
      if(m_chunkErrors > 0 || m_eligible == 0)
         return LSR_DATA_AUDIT_INCOMPLETE;
      if(FallbackShare() > LSR_MAX_FALLBACK_MINUTE_SHARE || m_gapCount > LSR_MAX_CRITICAL_DATA_GAP_COUNT)
         return LSR_DATA_FAILED;
      return LSR_DATA_PASSED;
     }

   void              WriteJson(CLSR_Json &j) const
     {
      j.BeginObject();
      j.KStr("audit_source", m_sourceLabel);
      j.KTime("declared_range_start", m_rangeStart);
      j.KTime("declared_range_end_exclusive", m_rangeEnd);
      j.KTime("audited_to_exclusive", m_auditedTo);
      j.KBool("declared_range_fully_audited", CoverageComplete());
      j.KInt("chunk_copy_errors", m_chunkErrors);
      j.KStr("price_source", LSR_PriceSourceName(m_src));
      j.KNum("m1_reconciliation_tolerance_price", m_tolerance, 10);
      j.KObj("raw_tick_records");
      j.Key("anomalies");
      LSR_WriteTickAnomaliesJson(j, m_anom);
      j.KInt("usable_ticks_outside_broker_schedule", m_ticksOutsideSchedule);
      j.EndObject();
      j.KObj("minutes");
      j.KInt("audit_eligible_minutes", m_eligible);
      j.KInt("ok_minutes", m_ok);
      j.KInt("potential_fallback_minutes", FallbackMinutes());
      j.KInt("pfm_no_ticks_no_bar__no_tick_or_sparse_data", m_pfmNoTicksNoBar);
      j.KInt("pfm_no_ticks_with_bar__potential_tester_fallback", m_pfmNoTicksWithBar);
      j.KInt("pfm_reconciliation_failed", m_pfmRecon);
      j.KInt("excluded_declared_closed_market_minutes", m_closedByCalendar);
      j.KStr("excluded_session_break_rule", "minutes outside SymbolInfoSessionTrade schedule are not audit-eligible");
      if(m_eligible > 0)
         j.KNum("potential_fallback_minute_share", FallbackShare(), 8);
      else
         j.KNull("potential_fallback_minute_share");
      j.KStr("label_note", "PotentialFallbackMinute is not proof of generated ticks");
      j.EndObject();
      j.KObj("critical_data_gaps");
      j.KInt("threshold_minutes", LSR_CRITICAL_DATA_GAP_THRESHOLD_MIN);
      j.KInt("count", m_gapCount);
      j.KStr("exclusions", "scheduled session breaks, weekends, declared closed-market intervals");
      j.EndObject();
      j.KObj("gates");
      j.KNum("max_fallback_minute_share", LSR_MAX_FALLBACK_MINUTE_SHARE, 6);
      j.KInt("max_critical_data_gap_count", LSR_MAX_CRITICAL_DATA_GAP_COUNT);
      j.KStr("result", LSR_DataGateName(Gate()));
      j.EndObject();
      j.EndObject();
     }

   string            FallbackCsv(void) const
     {
      string s = "minute_broker_time,class\n";
      int n = ArraySize(m_pfmTime);
      for(int i = 0; i < n; i++)
         s += LSR_IsoTime(m_pfmTime[i]) + "," + LSR_MinuteClassName((ENUM_LSR_MINUTE_CLASS)m_pfmClass[i]) + "\n";
      return s;
     }

   string            GapsCsv(void) const
     {
      string s = "gap_from_broker_time,gap_to_broker_time_exclusive,tradeable_seconds\n";
      int n = ArraySize(m_gapFrom);
      for(int i = 0; i < n; i++)
         s += LSR_IsoTime(m_gapFrom[i]) + "," + LSR_IsoTime(m_gapTo[i]) + "," + IntegerToString((long)(m_gapTo[i] - m_gapFrom[i])) + "\n";
      return s;
     }
  };

//+------------------------------------------------------------------+
//| Tester-side driver: audits completed hours of the declared range |
//| with CopyTicksRange/CopyRates while the run progresses.          |
//+------------------------------------------------------------------+
class CLSR_RawAuditDriver
  {
private:
   string            m_symbol;
   CLSR_RawTickAudit *m_audit;

public:
                     CLSR_RawAuditDriver(void) { m_audit = NULL; }
   void              Init(const string symbol, CLSR_RawTickAudit *audit) { m_symbol = symbol; m_audit = audit; }

   bool              AuditChunk(const datetime from, const datetime to)
     {
      MqlTick ticks[];
      MqlRates rates[];
      int nt = CopyTicksRange(m_symbol, ticks, COPY_TICKS_ALL, (ulong)from * 1000, (ulong)to * 1000 - 1);
      if(nt < 0)
        {
         m_audit.MarkChunkError(to);
         return false;
        }
      int nr = CopyRates(m_symbol, PERIOD_M1, from, to - 1, rates);
      if(nr < 0)
        {
         // No bars in range is reported as -1 by some builds; treat as zero bars only when no ticks exist.
         if(nt > 0)
           {
            m_audit.MarkChunkError(to);
            return false;
           }
         nr = 0;
         ArrayResize(rates, 0);
        }
      m_audit.ProcessChunk(ticks, nt, rates, nr, from, to);
      return true;
     }

   //--- Audits every completed hour strictly before `now`.
   void              Advance(const datetime now)
     {
      datetime limit = now - (now % 3600);
      if(limit > m_audit.RangeEnd())
         limit = m_audit.RangeEnd();
      while(m_audit.AuditedTo() + 3600 <= limit)
        {
         datetime from = m_audit.AuditedTo();
         AuditChunk(from, from + 3600);
        }
     }

   //--- Audits the remaining complete minutes up to `lastTick`.
   void              Flush(const datetime lastTick)
     {
      datetime limit = lastTick - (lastTick % 60);
      if(limit > m_audit.RangeEnd())
         limit = m_audit.RangeEnd();
      Advance(lastTick);
      datetime from = m_audit.AuditedTo();
      if(limit > from)
         AuditChunk(from, limit);
      m_audit.Finalize();
     }
  };

//+------------------------------------------------------------------+
//| Selected SignalTimeframe OHLC construction/reconciliation:       |
//| bars built from processed ticks vs the platform's bars.          |
//+------------------------------------------------------------------+
class CLSR_BarReconciler
  {
private:
   string            m_symbol;
   ENUM_LSR_TIMEFRAME m_tf;
   ENUM_LSR_PRICE_SOURCE m_src;
   double            m_tolerance;
   int               m_secs;
   datetime          m_barTime;
   bool              m_haveBar;
   bool              m_firstBar;
   double            m_o, m_h, m_l, m_c;
   long              m_compared, m_matched, m_mismatched, m_missing, m_skipped;
   string            m_rows;
   int               m_rowCount;

   void              CloseBar(void)
     {
      if(m_firstBar)
        {
         m_skipped++;   // first bar after init may be partial — cannot be verified
         m_firstBar = false;
         return;
        }
      MqlRates r[];
      int n = CopyRates(m_symbol, LSR_ToMqlTimeframe(m_tf), m_barTime, m_barTime, r);
      if(n != 1 || r[0].time != m_barTime)
        {
         m_missing++;
         AddRow("MISSING_PLATFORM_BAR", 0, 0, 0, 0);
         return;
        }
      m_compared++;
      if(MathAbs(r[0].open - m_o) <= m_tolerance && MathAbs(r[0].high - m_h) <= m_tolerance &&
         MathAbs(r[0].low - m_l) <= m_tolerance && MathAbs(r[0].close - m_c) <= m_tolerance)
         m_matched++;
      else
        {
         m_mismatched++;
         AddRow("OHLC_MISMATCH", r[0].open, r[0].high, r[0].low, r[0].close);
        }
     }

   void              AddRow(const string kind, const double po, const double ph, const double pl, const double pc)
     {
      if(m_rowCount >= LSR_AUDIT_MAX_LISTED_ROWS)
         return;
      m_rowCount++;
      m_rows += LSR_TimeframeName(m_tf) + "," + LSR_IsoTime(m_barTime) + "," + kind + "," +
                LSR_NumStr(m_o) + "," + LSR_NumStr(m_h) + "," + LSR_NumStr(m_l) + "," + LSR_NumStr(m_c) + "," +
                LSR_NumStr(po) + "," + LSR_NumStr(ph) + "," + LSR_NumStr(pl) + "," + LSR_NumStr(pc) + "\n";
     }

public:
   void              Init(const string symbol, const ENUM_LSR_TIMEFRAME tf, const ENUM_LSR_PRICE_SOURCE src, const double point)
     {
      m_symbol = symbol;
      m_tf = tf;
      m_src = src;
      m_tolerance = 0.5 * point;
      m_secs = LSR_TimeframeSeconds(tf);
      m_haveBar = false;
      m_firstBar = true;
      m_compared = 0;
      m_matched = 0;
      m_mismatched = 0;
      m_missing = 0;
      m_skipped = 0;
      m_rows = "";
      m_rowCount = 0;
     }

   void              OnQuote(const LSR_Quote &q)
     {
      double px = LSR_SignalBarPrice(q, m_src);
      if(!(px > 0.0))
         return;
      datetime bt = q.time - (q.time % m_secs);
      if(m_haveBar && bt != m_barTime)
        {
         CloseBar();
         m_haveBar = false;
        }
      if(!m_haveBar)
        {
         m_barTime = bt;
         m_o = px;
         m_h = px;
         m_l = px;
         m_haveBar = true;
        }
      else
        {
         if(px > m_h)
            m_h = px;
         if(px < m_l)
            m_l = px;
        }
      m_c = px;
     }

   //--- The final bar is left open (it may be incomplete) and is not compared.
   ENUM_LSR_TIMEFRAME Timeframe(void) const { return m_tf; }
   long              Mismatched(void) const { return m_mismatched; }
   long              Missing(void) const    { return m_missing; }

   void              WriteJson(CLSR_Json &j) const
     {
      j.BeginObject();
      j.KStr("timeframe", LSR_TimeframeName(m_tf));
      j.KStr("price_source", LSR_PriceSourceName(m_src));
      j.KInt("bars_compared", m_compared);
      j.KInt("bars_matched", m_matched);
      j.KInt("bars_mismatched", m_mismatched);
      j.KInt("platform_bars_missing", m_missing);
      j.KInt("bars_skipped_partial_first", m_skipped);
      j.KNum("tolerance_price", m_tolerance, 10);
      j.EndObject();
     }

   string            CsvRows(void) const { return m_rows; }
  };

#endif // LSR_DATAAUDIT_MQH
//+------------------------------------------------------------------+
