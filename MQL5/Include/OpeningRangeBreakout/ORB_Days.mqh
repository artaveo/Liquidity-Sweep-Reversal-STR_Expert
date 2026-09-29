//+------------------------------------------------------------------+
//| ORB_Days.mqh                                                     |
//| Day layer (roadmap Section 3): daily bars from M1, the opening   |
//| range per OR length, relative tick volume, NR7, SMA50, daily     |
//| ATR14, day decision codes and filter flags.                      |
//|                                                                  |
//| During the tick pass only raw per-day aggregates are stored      |
//| (OnM1). The ledger is built once at the end (Build), because the |
//| data quarantine and the detected closures are only known after   |
//| the raw audit is finalized. Every feature of day d uses only     |
//| broker days before d, so the end-of-run build has no look-ahead. |
//| The Python reference python/orb_reference/days.py rebuilds the   |
//| same rows byte for byte from bars_M1_BID.csv.                    |
//+------------------------------------------------------------------+
#ifndef ORB_DAYS_MQH
#define ORB_DAYS_MQH

#include "ORB_Types.mqh"
#include "../LiquiditySweepReversal/LSR_Json.mqh"
#include "../LiquiditySweepReversal/LSR_BrokerTime.mqh"
#include "../LiquiditySweepReversal/LSR_Sessions.mqh"
#include "../LiquiditySweepReversal/LSR_Bars.mqh"

//--- One CSV line as UTF-8 bytes + "\n" (same bytes as the LSR ledgers).
void ORB_WriteLine(const int h, const string line)
  {
   uchar b[];
   int n = LSR_Utf8Bytes(line + "\n", b);
   if(n > 0)
      FileWriteArray(h, b, 0, n);
  }

//--- ISO (2026-01-02T00:00:00) or MT5 (2026.01.02 00:00:00) broker time.
datetime ORB_ParseTime(const string s)
  {
   string t = s;
   StringTrimLeft(t);
   StringTrimRight(t);
   StringReplace(t, "-", ".");
   StringReplace(t, "T", " ");
   return StringToTime(t);
  }

struct ORB_LongList
  {
   long              v[];
  };

//+------------------------------------------------------------------+
//| Quarantine / closure lookup used by the day and trade ledgers.   |
//+------------------------------------------------------------------+
class CORB_IntervalCheck
  {
public:
   virtual bool      Overlaps(const datetime from, const datetime toExclusive) { return false; }
  };

//--- A plain list of [from, to) intervals (quarantine or closures).
class CORB_IntervalList : public CORB_IntervalCheck
  {
private:
   datetime          m_from[];
   datetime          m_to[];
public:
   void              Clear(void) { ArrayResize(m_from, 0); ArrayResize(m_to, 0); }
   int               Count(void) const { return ArraySize(m_from); }
   void              Add(const datetime a, const datetime b)
     {
      int n = ArraySize(m_from);
      ArrayResize(m_from, n + 1);
      ArrayResize(m_to, n + 1);
      m_from[n] = a;
      m_to[n] = b;
     }
   virtual bool      Overlaps(const datetime from, const datetime toExclusive)
     {
      int n = ArraySize(m_from);
      for(int i = 0; i < n; i++)
         if(m_from[i] < toExclusive && from < m_to[i])
            return true;
      return false;
     }
   //--- Parses "from,to[,...]" lines. Times are ISO (2026-01-02T00:00:00) or
   //--- MT5 (2026.01.02 00:00:00). Lines that do not start with a digit are skipped
   //--- (headers, comments), so both data_quarantine_windows.csv and
   //--- detected_market_closures.csv can be read.
   void              AddCsvText(const string text)
     {
      string lines[];
      int n = StringSplit(text, '\n', lines);
      for(int i = 0; i < n; i++)
        {
         string line = lines[i];
         StringTrimLeft(line);
         StringTrimRight(line);
         if(line == "")
            continue;
         ushort c0 = StringGetCharacter(line, 0);
         if(c0 < '0' || c0 > '9')
            continue;
         string f[];
         if(StringSplit(line, ',', f) < 2)
            continue;
         datetime a = ORB_ParseTime(f[0]);
         datetime b = ORB_ParseTime(f[1]);
         if(a > 0 && b > a)
            Add(a, b);
        }
     }
   bool              LoadCsv(const string fileName)
     {
      int h = FileOpen(fileName, FILE_READ | FILE_BIN | FILE_COMMON);
      if(h == INVALID_HANDLE)
         return false;
      uchar data[];
      ulong size = FileSize(h);
      if(size > 0)
         FileReadArray(h, data, 0, (int)size);
      FileClose(h);
      AddCsvText(CharArrayToString(data, 0, WHOLE_ARRAY, CP_UTF8));
      return true;
     }
  };

//+------------------------------------------------------------------+
//| Raw aggregates of one broker day (only days that have M1 bars).  |
//+------------------------------------------------------------------+
struct ORB_DayRec
  {
   datetime          day;
   bool              first;                    // contains the first processed bar (incomplete)
   double            open, high, low, close;
   int               or_bars[ORB_ORLEN_COUNT];
   double            or_open[ORB_ORLEN_COUNT];
   double            or_high[ORB_ORLEN_COUNT];
   double            or_low[ORB_ORLEN_COUNT];
   double            or_close[ORB_ORLEN_COUNT];
   long              or_ticks[ORB_ORLEN_COUNT];
   bool              has_after[ORB_ORLEN_COUNT]; // an M1 bar in [OR end, 23:00)
  };

//+------------------------------------------------------------------+
//| One ledger row (one OR length, one broker day).                  |
//+------------------------------------------------------------------+
struct ORB_DayRow
  {
   datetime          day;
   int               orlen;
   int               or_bars;
   double            or_open, or_high, or_low, or_close;
   long              or_ticks;
   bool              complete;      // every M1 bar of the window exists
   int               dir;           // +1, -1, 0 (doji); valid only when complete
   int               decision;
   bool              in_quarantine;
   int               prior_valid;
   bool              rv_ok;
   double            rv;
   bool              f1;
   bool              prev_ok;
   datetime          prev_day;
   double            prev_range;
   double            prev_close;
   bool              nr7_ok;
   bool              nr7;
   bool              sma_ok;
   double            sma50;
   bool              f5_ok;
   bool              f5;
   bool              atr_ok;
   double            atr;
   bool              width_ok;
   double            width_atr;
  };

//+------------------------------------------------------------------+
class CORB_DayLedger
  {
private:
   int               m_digits;
   double            m_point;
   ORB_DayRec        m_days[];
   int               m_n;
   ORB_DayRow        m_rows[];
   int               m_nRows;

   long              Pts(const double price) const { return (long)MathRound(price / m_point); }

   int               NewDay(const datetime day)
     {
      if(m_n >= ArraySize(m_days))
         ArrayResize(m_days, m_n + 1, 256);
      int i = m_n++;
      m_days[i].day = day;
      m_days[i].first = (i == 0);
      m_days[i].open = 0.0;
      m_days[i].high = 0.0;
      m_days[i].low = 0.0;
      m_days[i].close = 0.0;
      for(int k = 0; k < ORB_ORLEN_COUNT; k++)
        {
         m_days[i].or_bars[k] = 0;
         m_days[i].or_open[k] = 0.0;
         m_days[i].or_high[k] = 0.0;
         m_days[i].or_low[k] = 0.0;
         m_days[i].or_close[k] = 0.0;
         m_days[i].or_ticks[k] = 0;
         m_days[i].has_after[k] = false;
        }
      return i;
     }

   void              AddRow(const ORB_DayRow &r)
     {
      if(m_nRows >= ArraySize(m_rows))
         ArrayResize(m_rows, m_nRows + 1, 512);
      m_rows[m_nRows++] = r;
     }

   string            P(const double v) const { return DoubleToString(v, m_digits); }
   string            N(const bool ok, const double v, const int d) const { return ok ? DoubleToString(v, d) : "NA"; }
   static string     F(const bool ok, const bool v) { return ok ? (v ? "1" : "0") : "NA"; }

public:
                     CORB_DayLedger(void) { m_n = 0; m_nRows = 0; m_digits = 2; m_point = 0.01; }

   void              Init(const int digits, const double point)
     {
      m_digits = digits;
      m_point = point;
      m_n = 0;
      m_nRows = 0;
      ArrayResize(m_days, 0);
      ArrayResize(m_rows, 0);
     }

   //--- Completed M1 bars arrive in time order (CLSR_M1Builder).
   void              OnM1(const LSR_Bar &b)
     {
      datetime day = LSR_BrokerDayStart(b.time);
      int i = m_n - 1;
      if(m_n == 0 || day > m_days[i].day)
        {
         i = NewDay(day);
         m_days[i].open = b.open;
         m_days[i].high = b.high;
         m_days[i].low = b.low;
        }
      if(b.high > m_days[i].high)
         m_days[i].high = b.high;
      if(b.low < m_days[i].low)
         m_days[i].low = b.low;
      m_days[i].close = b.close;
      int sod = LSR_SecondsOfDay(b.time);
      for(int k = 0; k < ORB_ORLEN_COUNT; k++)
        {
         int orEnd = ORB_SESSION_START_SEC + ORB_OrLenMinutes(k) * 60;
         if(sod >= ORB_SESSION_START_SEC && sod < orEnd)
           {
            if(m_days[i].or_bars[k] == 0)
              {
               m_days[i].or_open[k] = b.open;
               m_days[i].or_high[k] = b.high;
               m_days[i].or_low[k] = b.low;
              }
            if(b.high > m_days[i].or_high[k])
               m_days[i].or_high[k] = b.high;
            if(b.low < m_days[i].or_low[k])
               m_days[i].or_low[k] = b.low;
            m_days[i].or_close[k] = b.close;
            m_days[i].or_ticks[k] += b.ticks;
            m_days[i].or_bars[k]++;
           }
         else
            if(sod >= orEnd && sod < ORB_EOD_SEC)
               m_days[i].has_after[k] = true;
        }
     }

   //--- Live query for the proxy simulator: the opening range of `day` when all of
   //--- its M1 bars exist. dir = sign(close - open) in integer points.
   bool              CompleteRange(const datetime day, const int k, double &o, double &h, double &l, double &c, int &dir) const
     {
      if(m_n == 0 || m_days[m_n - 1].day != day || m_days[m_n - 1].or_bars[k] != ORB_OrLenMinutes(k))
         return false;
      int i = m_n - 1;
      o = m_days[i].or_open[k];
      h = m_days[i].or_high[k];
      l = m_days[i].or_low[k];
      c = m_days[i].or_close[k];
      long d = Pts(c) - Pts(o);
      dir = (d > 0 ? 1 : d < 0 ? -1 : 0);
      return true;
     }

   int               DayCount(void) const { return m_n; }

   //+---------------------------------------------------------------+
   //| Builds every ledger row. `sched` decides which days get rows  |
   //| (16:30 inside a scheduled session); `quar` holds quarantine    |
   //| windows and detected/declared closures (roadmap 3 item 2).     |
   //+---------------------------------------------------------------+
   void              Build(const CLSR_SessionSchedule &sched, CORB_IntervalCheck &quar)
     {
      m_nRows = 0;
      ArrayResize(m_rows, 0);
      if(m_n == 0)
         return;
      //--- prior complete days (index into m_days), prior valid-session ticks per OR length
      int prior[];
      int nValid[ORB_ORLEN_COUNT];
      ArrayResize(prior, 0, 512);
      ArrayInitialize(nValid, 0);
      ORB_LongList tickHist[ORB_ORLEN_COUNT];
      CLSR_WilderAtr atr;
      atr.Init(ORB_ATR_D_PERIOD);

      int rec = 0;
      datetime lastDay = m_days[m_n - 1].day;
      for(datetime d = m_days[0].day; d <= lastDay; d += LSR_SECONDS_PER_DAY)
        {
         bool haveRec = (rec < m_n && m_days[rec].day == d);
         if(sched.IsInSession(d + ORB_SESSION_START_SEC))
           {
            int np = ArraySize(prior);
            for(int k = 0; k < ORB_ORLEN_COUNT; k++)
              {
               ORB_DayRow r;
               int len = ORB_OrLenMinutes(k);
               datetime orStart = d + ORB_SESSION_START_SEC;
               datetime orEnd = orStart + len * 60;
               r.day = d;
               r.orlen = k;
               r.or_bars = haveRec ? m_days[rec].or_bars[k] : 0;
               r.or_open = haveRec ? m_days[rec].or_open[k] : 0.0;
               r.or_high = haveRec ? m_days[rec].or_high[k] : 0.0;
               r.or_low = haveRec ? m_days[rec].or_low[k] : 0.0;
               r.or_close = haveRec ? m_days[rec].or_close[k] : 0.0;
               r.or_ticks = haveRec ? m_days[rec].or_ticks[k] : 0;
               r.complete = (r.or_bars == len);
               long dPts = Pts(r.or_close) - Pts(r.or_open);
               r.dir = (!r.complete ? 0 : dPts > 0 ? 1 : dPts < 0 ? -1 : 0);
               r.in_quarantine = quar.Overlaps(orStart, orEnd);
               bool valid = r.complete && !r.in_quarantine;
               //--- F1 relative tick volume over the previous 14 valid sessions
               r.prior_valid = nValid[k];
               long sum = 0;
               if(nValid[k] >= ORB_RV_LOOKBACK)
                  for(int j = nValid[k] - ORB_RV_LOOKBACK; j < nValid[k]; j++)
                     sum += tickHist[k].v[j];
               r.rv_ok = valid && nValid[k] >= ORB_RV_LOOKBACK && sum > 0;
               r.rv = r.rv_ok ? (double)r.or_ticks / ((double)sum / (double)ORB_RV_LOOKBACK) : 0.0;
               r.f1 = r.rv_ok && r.or_ticks * ORB_RV_LOOKBACK >= sum;
               //--- previous complete day, NR7, SMA50, ATR14_D
               r.prev_ok = (np >= 1);
               r.prev_day = r.prev_ok ? m_days[prior[np - 1]].day : (datetime)0;
               r.prev_range = r.prev_ok ? m_days[prior[np - 1]].high - m_days[prior[np - 1]].low : 0.0;
               r.prev_close = r.prev_ok ? m_days[prior[np - 1]].close : 0.0;
               r.nr7_ok = (np >= ORB_NR_LOOKBACK);
               r.nr7 = false;
               if(r.nr7_ok)
                 {
                  long pr = Pts(m_days[prior[np - 1]].high) - Pts(m_days[prior[np - 1]].low);
                  r.nr7 = true;
                  for(int j = 2; j <= ORB_NR_LOOKBACK; j++)
                    {
                     int q = prior[np - j];
                     if(pr > Pts(m_days[q].high) - Pts(m_days[q].low))
                        r.nr7 = false;
                    }
                 }
               r.sma_ok = (np >= ORB_SMA_PERIOD);
               long closeSum = 0;
               if(r.sma_ok)
                  for(int j = np - ORB_SMA_PERIOD; j < np; j++)
                     closeSum += Pts(m_days[prior[j]].close);
               r.sma50 = r.sma_ok ? (double)closeSum / (double)ORB_SMA_PERIOD * m_point : 0.0;
               r.f5_ok = r.sma_ok && r.complete && r.dir != 0;
               long pc50 = r.prev_ok ? Pts(r.prev_close) * ORB_SMA_PERIOD : 0;
               r.f5 = r.f5_ok && (r.dir > 0 ? pc50 > closeSum : pc50 < closeSum);
               r.atr_ok = atr.Ready();
               r.atr = r.atr_ok ? atr.Value() : 0.0;
               r.width_ok = r.complete && r.atr_ok && r.atr > 0.0;
               r.width_atr = r.width_ok ? (r.or_high - r.or_low) / r.atr : 0.0;
               //--- decision (first blocking reason wins)
               bool hasAfter = haveRec && m_days[rec].has_after[k];
               if(!r.complete)
                  r.decision = ORB_NO_TRADE_INCOMPLETE_RANGE;
               else
                  if(r.in_quarantine)
                     r.decision = ORB_NO_TRADE_QUARANTINE;
                  else
                     if(nValid[k] < ORB_RV_LOOKBACK)
                        r.decision = ORB_NO_TRADE_WARMUP;
                     else
                        if(r.dir == 0)
                           r.decision = ORB_NO_TRADE_DOJI;
                        else
                           if(!hasAfter)
                              r.decision = ORB_NO_TRADE_NO_TICK;
                           else
                              r.decision = ORB_TRADE;
               AddRow(r);
               if(valid)
                 {
                  ArrayResize(tickHist[k].v, nValid[k] + 1, 512);
                  tickHist[k].v[nValid[k]] = r.or_ticks;
                  nValid[k]++;
                 }
              }
           }
         //--- day d becomes a "previous complete day" for later days
         if(haveRec)
           {
            if(!m_days[rec].first)
              {
               int np = ArraySize(prior);
               ArrayResize(prior, np + 1, 512);
               prior[np] = rec;
               LSR_Bar db;
               db.time = d;
               db.period = LSR_SECONDS_PER_DAY;
               db.open = m_days[rec].open;
               db.high = m_days[rec].high;
               db.low = m_days[rec].low;
               db.close = m_days[rec].close;
               db.ticks = 0;
               atr.Update(db);
              }
            rec++;
           }
        }
     }

   int               RowCount(void) const { return m_nRows; }
   bool              Row(const int i, ORB_DayRow &r) const
     {
      if(i < 0 || i >= m_nRows)
         return false;
      r = m_rows[i];
      return true;
     }
   //--- Row index of (day, OR length), or -1.
   int               FindRow(const datetime day, const int k) const
     {
      for(int i = m_nRows - 1; i >= 0; i--)
        {
         if(m_rows[i].day < day)
            break;
         if(m_rows[i].day == day && m_rows[i].orlen == k)
            return i;
        }
      return -1;
     }
   int               CountDecision(const int k, const int decision) const
     {
      int c = 0;
      for(int i = 0; i < m_nRows; i++)
         if(m_rows[i].orlen == k && m_rows[i].decision == decision)
            c++;
      return c;
     }
   int               CountRows(const int k) const
     {
      int c = 0;
      for(int i = 0; i < m_nRows; i++)
         if(m_rows[i].orlen == k)
            c++;
      return c;
     }

   static string     Header(void)
     {
      return "date,or_length,weekday,or_start,or_end,or_bars,or_open,or_high,or_low,or_close,or_ticks,or_width,direction,"
             "decision,in_quarantine,prior_valid_sessions,rv,f1,prev_date,prev_range,nr7,prev_close,sma50,f5,atr14_d,"
             "width_atr,width_bucket,news_state";
     }

   string            RowText(const ORB_DayRow &r) const
     {
      datetime orStart = r.day + ORB_SESSION_START_SEC;
      bool any = (r.or_bars > 0);
      string dir = !r.complete ? "NA" : r.dir > 0 ? "LONG" : r.dir < 0 ? "SHORT" : "NONE";
      return LSR_IsoDate(r.day) + "," + ORB_OrLenName(r.orlen) + "," + LSR_WeekdayName(LSR_DayOfWeek(r.day)) + "," +
             LSR_IsoTime(orStart) + "," + LSR_IsoTime(orStart + ORB_OrLenMinutes(r.orlen) * 60) + "," +
             IntegerToString(r.or_bars) + "," + N(any, r.or_open, m_digits) + "," + N(any, r.or_high, m_digits) + "," +
             N(any, r.or_low, m_digits) + "," + N(any, r.or_close, m_digits) + "," + IntegerToString(r.or_ticks) + "," +
             N(r.complete, r.or_high - r.or_low, m_digits) + "," + dir + "," + ORB_DecisionName(r.decision) + "," +
             (r.in_quarantine ? "1" : "0") + "," + IntegerToString(r.prior_valid) + "," + N(r.rv_ok, r.rv, 6) + "," + F(r.rv_ok, r.f1) + "," +
             (r.prev_ok ? LSR_IsoDate(r.prev_day) : "NA") + "," + N(r.prev_ok, r.prev_range, m_digits) + "," + F(r.nr7_ok, r.nr7) + "," +
             N(r.prev_ok, r.prev_close, m_digits) + "," + N(r.sma_ok, r.sma50, 6) + "," + F(r.f5_ok, r.f5) + "," +
             N(r.atr_ok, r.atr, 6) + "," + N(r.width_ok, r.width_atr, 6) + "," + ORB_WidthBucket(r.width_ok, r.width_atr) + "," +
             ORB_NEWS_STATE;
     }

   bool              WriteCsv(const string path, const int k) const
     {
      int h = FileOpen(path, FILE_WRITE | FILE_BIN | FILE_COMMON);
      if(h == INVALID_HANDLE)
         return false;
      ORB_WriteLine(h, Header());
      for(int i = 0; i < m_nRows; i++)
         if(m_rows[i].orlen == k)
            ORB_WriteLine(h, RowText(m_rows[i]));
      FileClose(h);
      return true;
     }
  };

#endif // ORB_DAYS_MQH
//+------------------------------------------------------------------+
