//+------------------------------------------------------------------+
//| LSR_Liquidity.mqh                                                |
//| Phase 2 — liquidity model, pools, touches and exact sweep events |
//| (roadmap 2.1–2.10A, 0B.1–0B.6, 0B.15, 0B.21, 0C.2–0C.6, 0C.19,   |
//| and the binding Phase 2 closures in 2.12).                       |
//|                                                                  |
//| One engine instance per SignalTimeframe (isolated state). Input  |
//| is the single-pass stream of completed M1 bars; everything is    |
//| deterministic and side-effect free until the ledgers are written.|
//+------------------------------------------------------------------+
#ifndef LSR_LIQUIDITY_MQH
#define LSR_LIQUIDITY_MQH

#include "LSR_Types.mqh"
#include "LSR_Json.mqh"
#include "LSR_Bars.mqh"
#include "LSR_Timeframes.mqh"
#include "LSR_BrokerTime.mqh"
#include "LSR_Sessions.mqh"

#define LSR_ATR_PERIOD        14
#define LSR_ID_HEX_CHARS      16
#define LSR_PHASE2_CONTRACT_ID "LSR-PHASE2-EVENTS-2026-09-29"

//--- Level kinds: even = high side (buy-side liquidity), odd = low side.
enum ENUM_LSR_LEVEL_KIND
  {
   LSR_LV_PDH         = 0,
   LSR_LV_PDL         = 1,
   LSR_LV_PSH         = 2,
   LSR_LV_PSL         = 3,
   LSR_LV_SWING_HIGH  = 4,
   LSR_LV_SWING_LOW   = 5,
   LSR_LV_EQUAL_HIGHS = 6,
   LSR_LV_EQUAL_LOWS  = 7
  };

enum ENUM_LSR_MULTI_POOL_POLICY
  {
   LSR_MULTIPOOL_FIRST_CROSSED_LEVEL       = 0, // FIRST_CROSSED_LEVEL (baseline)
   LSR_MULTIPOOL_DEEPEST_PENETRATION_LEVEL = 1  // DEEPEST_PENETRATION_LEVEL (research)
  };

enum ENUM_LSR_EQUAL_TOL_MODE
  {
   LSR_EQTOL_FIXED_PIPS     = 0, // FIXED_PIPS (baseline)
   LSR_EQTOL_ATR_NORMALIZED = 1  // ATR_NORMALIZED (not yet specified)
  };

enum ENUM_LSR_ENTRY_MODE
  {
   LSR_ENTRY_RECLAIM_CLOSE            = 0, // RECLAIM_CLOSE (baseline)
   LSR_ENTRY_NEXT_BAR_EXTREME_CONFIRM = 1  // NEXT_BAR_EXTREME_CONFIRM
  };

string LSR_LevelKindName(const int k)
  {
   switch(k)
     {
      case LSR_LV_PDH:         return "PDH";
      case LSR_LV_PDL:         return "PDL";
      case LSR_LV_PSH:         return "PSH";
      case LSR_LV_PSL:         return "PSL";
      case LSR_LV_SWING_HIGH:  return "SWING_HIGH";
      case LSR_LV_SWING_LOW:   return "SWING_LOW";
      case LSR_LV_EQUAL_HIGHS: return "EQUAL_HIGHS";
      case LSR_LV_EQUAL_LOWS:  return "EQUAL_LOWS";
     }
   return "UNKNOWN";
  }

int LSR_LevelKindSide(const int k)        { return (k % 2 == 0) ? 1 : -1; }
string LSR_SideName(const int side)       { return side > 0 ? "HIGH" : "LOW"; }
string LSR_MultiPoolPolicyName(const ENUM_LSR_MULTI_POOL_POLICY p)
  { return p == LSR_MULTIPOOL_FIRST_CROSSED_LEVEL ? "FIRST_CROSSED_LEVEL" : "DEEPEST_PENETRATION_LEVEL"; }
string LSR_EqualTolModeName(const ENUM_LSR_EQUAL_TOL_MODE m)
  { return m == LSR_EQTOL_FIXED_PIPS ? "FIXED_PIPS" : "ATR_NORMALIZED"; }
string LSR_EntryModeName(const ENUM_LSR_ENTRY_MODE m)
  { return m == LSR_ENTRY_RECLAIM_CLOSE ? "RECLAIM_CLOSE" : "NEXT_BAR_EXTREME_CONFIRM"; }

//--- Stable identifiers: first 16 hex chars of SHA-256 of a canonical string.
string LSR_StableId(const string canonical)
  {
   return StringSubstr(LSR_Sha256Hex(canonical), 0, LSR_ID_HEX_CHARS);
  }

string LSR_TouchBucket(const int n)
  {
   if(n >= 3)
      return "3+";
   return IntegerToString(n);
  }

//+------------------------------------------------------------------+
struct LSR_EventConfig
  {
   bool                       use_previous_day;
   bool                       use_previous_session;
   bool                       use_swings;
   bool                       use_equal;
   int                        session_start_sec;
   int                        session_end_sec;
   int                        swing_left;
   int                        swing_right;
   double                     equal_tol_pips;
   ENUM_LSR_EQUAL_TOL_MODE    equal_tol_mode;
   double                     cluster_tol_pips;
   ENUM_LSR_MULTI_POOL_POLICY multi_pool_policy;
   ENUM_LSR_ENTRY_MODE        entry_mode;
   double                     pip_size;
   double                     point;
   int                        digits;
  };

void LSR_EventConfigDefaults(LSR_EventConfig &c)
  {
   c.use_previous_day     = true;
   c.use_previous_session = true;
   c.use_swings           = true;
   c.use_equal            = true;
   c.session_start_sec    = 16 * 3600 + 30 * 60;
   c.session_end_sec      = 21 * 3600 + 30 * 60;
   c.swing_left           = 2;
   c.swing_right          = 2;
   c.equal_tol_pips       = 3.0;
   c.equal_tol_mode       = LSR_EQTOL_FIXED_PIPS;
   c.cluster_tol_pips     = 3.0;
   c.multi_pool_policy    = LSR_MULTIPOOL_FIRST_CROSSED_LEVEL;
   c.entry_mode           = LSR_ENTRY_RECLAIM_CLOSE;
   c.pip_size             = 0.10;
   c.point                = 0.01;
   c.digits               = 2;
  }

bool LSR_ValidateEventConfig(const LSR_EventConfig &c, string &error)
  {
   error = "";
   if(!c.use_previous_day && !c.use_previous_session && !c.use_swings && !c.use_equal)
     { error = "at least one liquidity source must be enabled"; return false; }
   if(c.session_start_sec < 0 || c.session_end_sec > LSR_SECONDS_PER_DAY || c.session_start_sec >= c.session_end_sec)
     { error = "LiquiditySessionStart must be before LiquiditySessionEnd on the same broker day"; return false; }
   if(c.swing_left < 1 || c.swing_right < 1 || c.swing_left > 50 || c.swing_right > 50)
     { error = "SwingLeftBars/SwingRightBars must be in 1..50"; return false; }
   if(!(c.equal_tol_pips >= 0.0) || !(c.cluster_tol_pips >= 0.0))
     { error = "tolerances must be non-negative"; return false; }
   if(c.equal_tol_mode == LSR_EQTOL_ATR_NORMALIZED)
     { error = "EqualLevelToleranceMode ATR_NORMALIZED: multiplier not specified (SPEC-INCOMPLETE, roadmap 2.6B/0B.13); keep FIXED_PIPS"; return false; }
   if(!(c.pip_size > 0.0) || !(c.point > 0.0) || c.digits < 0)
     { error = "invalid price units"; return false; }
   return true;
  }

//+------------------------------------------------------------------+
struct LSR_LevelRec
  {
   string            id;
   int               kind;
   double            lo;
   double            hi;
   int               px_start;
   int               px_count;
   string            instance;
   datetime          avail;
   datetime          arm;
   long              arm_index;
   datetime          end_time;
   string            end_reason;
   datetime          swing_time;
   double            prominence;
   bool              has_prominence;
   string            members;
   bool              active;
   int               pool;
  };

struct LSR_PoolRec
  {
   string            id;
   int               side;
   double            lower;
   double            upper;
   double            anchor;
   int               mem_start;
   int               mem_count;
   string            member_ids;
   string            tags;
   datetime          arm;
   long              arm_index;
   datetime          level_arm;
   long              level_arm_index;
   datetime          end_time;
   string            end_reason;
   string            predecessor;
   int               inherited;
   int               touches;
   bool              active;
  };

struct LSR_TouchRec
  {
   int               pool;
   datetime          bar_time;
   int               number;
  };

struct LSR_EventRec
  {
   string            id;
   int               pool;
   string            status;
   long              bar_index;
   datetime          bar_time;
   double            open;
   double            high;
   double            low;
   double            close;
   bool              have_prev;
   double            prev_close;
   bool              atr_ready;
   double            atr;
   int               touches;
  };

struct LSR_SwingRec
  {
   int               side;
   double            price;
   datetime          bar_time;
   datetime          conf_time;
   bool              live;
  };

struct LSR_PendingLevel
  {
   int               kind;
   double            lo;
   double            hi;
   int               px_start;
   int               px_count;
   string            instance;
   datetime          avail;
   datetime          swing_time;
   double            prominence;
   bool              has_prominence;
   string            members;
  };

//+------------------------------------------------------------------+
//| Quarantine overlap callback used only when writing ledgers.      |
//+------------------------------------------------------------------+
class CLSR_QuarantineCheck
  {
public:
   virtual bool      Overlaps(const datetime from, const datetime toExclusive) { return false; }
  };

//+------------------------------------------------------------------+
class CLSR_EventEngine
  {
private:
   LSR_EventConfig   m_cfg;
   ENUM_LSR_TIMEFRAME m_tf;
   string            m_tfName;
   int               m_period;
   long              m_eqTolPts;
   long              m_clusterTolPts;

   CLSR_TfAggregator m_agg;
   CLSR_WilderAtr    m_atr;
   LSR_Bar           m_bars[];
   int               m_nBars;

   bool              m_haveFirst;
   datetime          m_firstM1;
   bool              m_dayHave;
   datetime          m_day;
   double            m_dayHi;
   double            m_dayLo;
   bool              m_sesHave;
   datetime          m_sesDate;
   double            m_sesHi;
   double            m_sesLo;

   LSR_LevelRec      m_levels[];
   int               m_nLevels;
   double            m_px[];
   int               m_nPx;
   LSR_PoolRec       m_pools[];
   int               m_nPools;
   int               m_poolMem[];
   int               m_nPoolMem;
   LSR_TouchRec      m_touches[];
   int               m_nTouches;
   LSR_EventRec      m_events[];
   int               m_nEvents;
   LSR_SwingRec      m_swings[];
   int               m_nSwings;
   LSR_PendingLevel  m_pending[];

   int               m_activeHigh[];   // pool indices, lower asc
   int               m_activeLow[];    // pool indices, upper desc
   int               m_liveSwHigh[];   // swing indices, price asc
   int               m_liveSwLow[];    // swing indices, price desc
   int               m_activeByKind[4]; // PDH, PDL, PSH, PSL level index or -1

   //--- helpers --------------------------------------------------------
   long              Pts(const double p) const { return (long)MathRound(p / m_cfg.point); }
   string            P(const double p) const   { return DoubleToString(p, m_cfg.digits); }

   int               AddPx(const double p)
     {
      if(m_nPx >= ArraySize(m_px))
         ArrayResize(m_px, m_nPx + 1, 4096);
      m_px[m_nPx] = p;
      return m_nPx++;
     }

   //--- ordering keys for active lists
   bool              HighBefore(const int a, const int b) const
     {
      if(m_pools[a].lower != m_pools[b].lower)
         return m_pools[a].lower < m_pools[b].lower;
      if(m_pools[a].upper != m_pools[b].upper)
         return m_pools[a].upper < m_pools[b].upper;
      return StringCompare(m_pools[a].id, m_pools[b].id) < 0;
     }
   bool              LowBefore(const int a, const int b) const
     {
      if(m_pools[a].upper != m_pools[b].upper)
         return m_pools[a].upper > m_pools[b].upper;
      if(m_pools[a].lower != m_pools[b].lower)
         return m_pools[a].lower > m_pools[b].lower;
      return StringCompare(m_pools[a].id, m_pools[b].id) < 0;
     }

   void              InsertActive(const int pi)
     {
      if(m_pools[pi].side > 0)
        {
         int n = ArraySize(m_activeHigh);
         ArrayResize(m_activeHigh, n + 1, 256);
         int pos = n;
         while(pos > 0 && HighBefore(pi, m_activeHigh[pos - 1]))
           {
            m_activeHigh[pos] = m_activeHigh[pos - 1];
            pos--;
           }
         m_activeHigh[pos] = pi;
        }
      else
        {
         int n = ArraySize(m_activeLow);
         ArrayResize(m_activeLow, n + 1, 256);
         int pos = n;
         while(pos > 0 && LowBefore(pi, m_activeLow[pos - 1]))
           {
            m_activeLow[pos] = m_activeLow[pos - 1];
            pos--;
           }
         m_activeLow[pos] = pi;
        }
     }

   static void       RemoveValue(int &arr[], const int v)
     {
      int n = ArraySize(arr);
      for(int i = 0; i < n; i++)
         if(arr[i] == v)
           {
            for(int j = i; j < n - 1; j++)
               arr[j] = arr[j + 1];
            ArrayResize(arr, n - 1, 256);
            return;
           }
     }

   static void       SortStrings(string &a[])
     {
      int n = ArraySize(a);
      for(int i = 1; i < n; i++)
        {
         string k = a[i];
         int j = i - 1;
         while(j >= 0 && StringCompare(a[j], k) > 0)
           {
            a[j + 1] = a[j];
            j--;
           }
         a[j + 1] = k;
        }
     }

   //--- pools ----------------------------------------------------------
   int               CreatePool(const int &members[], const datetime armTime, const long armIndex,
                                const string predecessor, const int inherited)
     {
      int n = ArraySize(members);
      int side = LSR_LevelKindSide(m_levels[members[0]].kind);
      double prices[];
      string ids[];
      bool kindSeen[8];
      ArrayInitialize(kindSeen, false);
      ArrayResize(ids, n);
      datetime lvArm = 0;
      long lvArmIdx = 0;
      for(int i = 0; i < n; i++)
        {
         int li = members[i];
         ids[i] = m_levels[li].id;
         kindSeen[m_levels[li].kind] = true;
         for(int k = 0; k < m_levels[li].px_count; k++)
           {
            int np = ArraySize(prices);
            ArrayResize(prices, np + 1);
            prices[np] = m_px[m_levels[li].px_start + k];
           }
         if(i == 0 || m_levels[li].arm < lvArm)
           {
            lvArm = m_levels[li].arm;
            lvArmIdx = m_levels[li].arm_index;
           }
        }
      ArraySort(prices);
      SortStrings(ids);
      int np = ArraySize(prices);
      string idList = "";
      for(int i = 0; i < n; i++)
         idList += (i > 0 ? ";" : "") + ids[i];
      string tags = "";
      for(int k = 0; k < 8; k++)
         if(kindSeen[k])
            tags += (tags == "" ? "" : ";") + LSR_LevelKindName(k);

      if(m_nPools >= ArraySize(m_pools))
         ArrayResize(m_pools, m_nPools + 1, 1024);
      int pi = m_nPools++;
      m_pools[pi].side = side;
      m_pools[pi].lower = prices[0];
      m_pools[pi].upper = prices[np - 1];
      m_pools[pi].anchor = (np % 2 == 1) ? prices[np / 2] : (prices[np / 2 - 1] + prices[np / 2]) / 2.0;
      m_pools[pi].member_ids = idList;
      m_pools[pi].tags = tags;
      m_pools[pi].arm = armTime;
      m_pools[pi].arm_index = armIndex;
      m_pools[pi].level_arm = lvArm;
      m_pools[pi].level_arm_index = lvArmIdx;
      m_pools[pi].end_time = 0;
      m_pools[pi].end_reason = "";
      m_pools[pi].predecessor = predecessor;
      m_pools[pi].inherited = inherited;
      m_pools[pi].touches = inherited;
      m_pools[pi].active = true;
      m_pools[pi].id = LSR_StableId("P|" + m_tfName + "|" + LSR_SideName(side) + "|" + LSR_IsoTime(armTime) + "|" +
                                    StringReplaceAll(idList, ";", ","));
      m_pools[pi].mem_start = m_nPoolMem;
      m_pools[pi].mem_count = n;
      for(int i = 0; i < n; i++)
        {
         if(m_nPoolMem >= ArraySize(m_poolMem))
            ArrayResize(m_poolMem, m_nPoolMem + 1, 4096);
         m_poolMem[m_nPoolMem++] = members[i];
         m_levels[members[i]].pool = pi;
        }
      InsertActive(pi);
      return pi;
     }

   static string     StringReplaceAll(const string s, const string a, const string b)
     {
      string r = s;
      StringReplace(r, a, b);
      return r;
     }

   void              EndPool(const int pi, const datetime t, const string reason)
     {
      m_pools[pi].active = false;
      m_pools[pi].end_time = t;
      m_pools[pi].end_reason = reason;
      if(m_pools[pi].side > 0)
         RemoveValue(m_activeHigh, pi);
      else
         RemoveValue(m_activeLow, pi);
     }

   //--- band of a level in points
   void              LevelBandPts(const int li, long &lo, long &hi) const
     {
      lo = Pts(m_levels[li].lo);
      hi = Pts(m_levels[li].hi);
     }

   void              JoinPool(const int li, const datetime t, const long nextIndex)
     {
      int side = LSR_LevelKindSide(m_levels[li].kind);
      long llo, lhi;
      LevelBandPts(li, llo, lhi);
      double mid = (m_levels[li].lo + m_levels[li].hi) / 2.0;
      int best = -1;
      double bestDist = 0.0;
      int n = (side > 0 ? ArraySize(m_activeHigh) : ArraySize(m_activeLow));
      for(int i = 0; i < n; i++)
        {
         int pi = (side > 0 ? m_activeHigh[i] : m_activeLow[i]);
         long plo = Pts(m_pools[pi].lower), phi = Pts(m_pools[pi].upper);
         long width = MathMax(phi, lhi) - MathMin(plo, llo);
         if(width > m_clusterTolPts)
            continue;
         double d = MathAbs(m_pools[pi].anchor - mid);
         bool better = (best < 0) || (d < bestDist) ||
                       (d == bestDist && (m_pools[pi].arm > m_pools[best].arm ||
                                          (m_pools[pi].arm == m_pools[best].arm && StringCompare(m_pools[pi].id, m_pools[best].id) < 0)));
         if(better)
           {
            best = pi;
            bestDist = d;
           }
        }
      int members[];
      if(best < 0)
        {
         ArrayResize(members, 1);
         members[0] = li;
         CreatePool(members, t, nextIndex, "", 0);
         return;
        }
      int mc = m_pools[best].mem_count;
      ArrayResize(members, mc + 1);
      for(int i = 0; i < mc; i++)
         members[i] = m_poolMem[m_pools[best].mem_start + i];
      members[mc] = li;
      string pred = m_pools[best].id;
      int inh = m_pools[best].touches;
      EndPool(best, t, "SUPERSEDED");
      CreatePool(members, t, nextIndex, pred, inh);
     }

   void              ExpireLevel(const int li, const datetime t, const long nextIndex)
     {
      if(!m_levels[li].active)
         return;
      m_levels[li].active = false;
      m_levels[li].end_time = t;
      m_levels[li].end_reason = "EXPIRED";
      int pi = m_levels[li].pool;
      if(pi < 0 || !m_pools[pi].active)
         return;
      int rest[];
      for(int i = 0; i < m_pools[pi].mem_count; i++)
        {
         int m = m_poolMem[m_pools[pi].mem_start + i];
         if(m == li)
            continue;
         int k = ArraySize(rest);
         ArrayResize(rest, k + 1);
         rest[k] = m;
        }
      string pred = m_pools[pi].id;
      int inh = m_pools[pi].touches;
      EndPool(pi, t, ArraySize(rest) > 0 ? "MEMBER_EXPIRED" : "EXPIRED");
      if(ArraySize(rest) > 0)
         CreatePool(rest, t, nextIndex, pred, inh);
     }

   //--- pending levels -------------------------------------------------
   void              Queue(const int kind, const double lo, const double hi, const double &prices[],
                           const string instance, const datetime avail, const datetime swingTime,
                           const bool hasProm, const double prom, const string members)
     {
      int n = ArraySize(m_pending);
      ArrayResize(m_pending, n + 1, 64);
      m_pending[n].kind = kind;
      m_pending[n].lo = lo;
      m_pending[n].hi = hi;
      m_pending[n].px_start = m_nPx;
      m_pending[n].px_count = ArraySize(prices);
      for(int i = 0; i < ArraySize(prices); i++)
         AddPx(prices[i]);
      m_pending[n].instance = instance;
      m_pending[n].avail = avail;
      m_pending[n].swing_time = swingTime;
      m_pending[n].has_prominence = hasProm;
      m_pending[n].prominence = prom;
      m_pending[n].members = members;
     }

   bool              PendingBefore(const int a, const int b) const
     {
      int sa = m_pending[a].kind / 2, sb = m_pending[b].kind / 2;
      if(sa != sb)
         return sa < sb;
      int da = LSR_LevelKindSide(m_pending[a].kind), db = LSR_LevelKindSide(m_pending[b].kind);
      if(da != db)
         return da > db;
      if(m_pending[a].lo != m_pending[b].lo)
         return m_pending[a].lo < m_pending[b].lo;
      if(m_pending[a].hi != m_pending[b].hi)
         return m_pending[a].hi < m_pending[b].hi;
      return StringCompare(m_pending[a].instance, m_pending[b].instance) < 0;
     }

   void              ApplyPending(const datetime t, const long nextIndex)
     {
      int ready[];
      int keep[];
      for(int i = 0; i < ArraySize(m_pending); i++)
        {
         if(m_pending[i].avail <= t)
           {
            int n = ArraySize(ready);
            ArrayResize(ready, n + 1);
            int pos = n;
            while(pos > 0 && PendingBefore(i, ready[pos - 1]))
              {
               ready[pos] = ready[pos - 1];
               pos--;
              }
            ready[pos] = i;
           }
         else
           {
            int n = ArraySize(keep);
            ArrayResize(keep, n + 1);
            keep[n] = i;
           }
        }
      if(ArraySize(ready) == 0)
         return;

      //--- pass 1: previous-day / previous-session replacements expire first
      for(int r = 0; r < ArraySize(ready); r++)
        {
         int k = m_pending[ready[r]].kind;
         if(k <= LSR_LV_PSL && m_activeByKind[k] >= 0)
           {
            ExpireLevel(m_activeByKind[k], t, nextIndex);
            m_activeByKind[k] = -1;
           }
        }
      //--- pass 2: arm
      for(int r = 0; r < ArraySize(ready); r++)
        {
         int q = ready[r];
         if(m_nLevels >= ArraySize(m_levels))
            ArrayResize(m_levels, m_nLevels + 1, 1024);
         int li = m_nLevels++;
         string priceKey = (m_pending[q].lo == m_pending[q].hi) ? P(m_pending[q].lo) : P(m_pending[q].lo) + "-" + P(m_pending[q].hi);
         m_levels[li].kind = m_pending[q].kind;
         m_levels[li].lo = m_pending[q].lo;
         m_levels[li].hi = m_pending[q].hi;
         m_levels[li].px_start = m_pending[q].px_start;
         m_levels[li].px_count = m_pending[q].px_count;
         m_levels[li].instance = m_pending[q].instance;
         m_levels[li].avail = m_pending[q].avail;
         m_levels[li].arm = t;
         m_levels[li].arm_index = nextIndex;
         m_levels[li].end_time = 0;
         m_levels[li].end_reason = "";
         m_levels[li].swing_time = m_pending[q].swing_time;
         m_levels[li].has_prominence = m_pending[q].has_prominence;
         m_levels[li].prominence = m_pending[q].prominence;
         m_levels[li].members = m_pending[q].members;
         m_levels[li].active = true;
         m_levels[li].pool = -1;
         m_levels[li].id = LSR_StableId("L|" + m_tfName + "|" + LSR_LevelKindName(m_pending[q].kind) + "|" +
                                        m_pending[q].instance + "|" + priceKey);
         if(m_pending[q].kind <= LSR_LV_PSL)
            m_activeByKind[m_pending[q].kind] = li;
         JoinPool(li, t, nextIndex);
        }
      //--- keep the rest (original order)
      LSR_PendingLevel rest[];
      ArrayResize(rest, ArraySize(keep));
      for(int i = 0; i < ArraySize(keep); i++)
         rest[i] = m_pending[keep[i]];
      ArrayResize(m_pending, ArraySize(rest));
      for(int i = 0; i < ArraySize(rest); i++)
         m_pending[i] = rest[i];
     }

   //--- day / session trackers (M1 resolution) --------------------------
   void              TrackDay(const LSR_Bar &b)
     {
      datetime d = LSR_BrokerDayStart(b.time);
      FinalizeDayIfPast(b.time);
      if(!m_dayHave)
        {
         m_day = d;
         m_dayHi = b.high;
         m_dayLo = b.low;
         m_dayHave = true;
        }
      else
        {
         if(b.high > m_dayHi)
            m_dayHi = b.high;
         if(b.low < m_dayLo)
            m_dayLo = b.low;
        }
     }

   //--- A day is complete once any later timestamp belongs to a new broker day.
   void              FinalizeDayIfPast(const datetime t)
     {
      datetime d = LSR_BrokerDayStart(t);
      if(m_dayHave && d != m_day)
        {
         if(m_cfg.use_previous_day && m_day != LSR_BrokerDayStart(m_firstM1))
           {
            double one[1];
            one[0] = m_dayHi;
            Queue(LSR_LV_PDH, m_dayHi, m_dayHi, one, LSR_IsoDate(m_day), m_day + LSR_SECONDS_PER_DAY, 0, false, 0.0, "");
            one[0] = m_dayLo;
            Queue(LSR_LV_PDL, m_dayLo, m_dayLo, one, LSR_IsoDate(m_day), m_day + LSR_SECONDS_PER_DAY, 0, false, 0.0, "");
           }
         m_dayHave = false;
        }
     }

   void              TrackSession(const LSR_Bar &b)
     {
      datetime ds = LSR_BrokerDayStart(b.time);
      int sod = (int)(b.time - ds);
      FinalizeSessionIfPast(b.time);
      if(sod >= m_cfg.session_start_sec && sod < m_cfg.session_end_sec)
        {
         if(!m_sesHave)
           {
            m_sesDate = ds;
            m_sesHi = b.high;
            m_sesLo = b.low;
            m_sesHave = true;
           }
         else
           {
            if(b.high > m_sesHi)
               m_sesHi = b.high;
            if(b.low < m_sesLo)
               m_sesLo = b.low;
           }
        }
     }

   //--- A session is complete once any later timestamp is on a new day or past its end.
   void              FinalizeSessionIfPast(const datetime t)
     {
      datetime ds = LSR_BrokerDayStart(t);
      int sod = (int)(t - ds);
      if(m_sesHave && (ds != m_sesDate || sod >= m_cfg.session_end_sec))
        {
         if(m_cfg.use_previous_session && m_firstM1 <= m_sesDate + m_cfg.session_start_sec)
           {
            double one[1];
            string inst = LSR_IsoTime(m_sesDate + m_cfg.session_start_sec);
            datetime avail = m_sesDate + m_cfg.session_end_sec;
            one[0] = m_sesHi;
            Queue(LSR_LV_PSH, m_sesHi, m_sesHi, one, inst, avail, 0, false, 0.0, "");
            one[0] = m_sesLo;
            Queue(LSR_LV_PSL, m_sesLo, m_sesLo, one, inst, avail, 0, false, 0.0, "");
           }
         m_sesHave = false;
        }
     }

   //--- sweep classification (roadmap 0B.2, 0C.4, 0C.5; closures 2.12) ------
   string            ClassifyHigh(const LSR_PoolRec &p, const LSR_Bar &b, const bool havePrev, const double prevClose, bool &crossing) const
     {
      crossing = b.high > p.upper;
      if(!crossing)
        {
         if(b.open < p.lower && havePrev && prevClose < p.lower)
            return "PARTIAL_POOL_SWEEP";
         return "";
        }
      if(b.open > p.upper)
         return "OPENED_BEYOND_POOL";
      if(b.open == p.lower)
         return "OPEN_ON_LIQUIDITY";
      if(b.open > p.lower)
         return "OPEN_INSIDE_POOL";
      if(!havePrev)
         return "NO_PREVIOUS_BAR";
      if(prevClose >= p.lower)
         return "PREV_CLOSE_NOT_OUTSIDE";
      if(b.close >= p.lower)
         return "NO_RECLAIM";
      return "VALID";
     }

   string            ClassifyLow(const LSR_PoolRec &p, const LSR_Bar &b, const bool havePrev, const double prevClose, bool &crossing) const
     {
      crossing = b.low < p.lower;
      if(!crossing)
        {
         if(b.open > p.upper && havePrev && prevClose > p.upper)
            return "PARTIAL_POOL_SWEEP";
         return "";
        }
      if(b.open < p.lower)
         return "OPENED_BEYOND_POOL";
      if(b.open == p.upper)
         return "OPEN_ON_LIQUIDITY";
      if(b.open < p.upper)
         return "OPEN_INSIDE_POOL";
      if(!havePrev)
         return "NO_PREVIOUS_BAR";
      if(prevClose <= p.upper)
         return "PREV_CLOSE_NOT_OUTSIDE";
      if(b.close <= p.upper)
         return "NO_RECLAIM";
      return "VALID";
     }

   void              AddEvent(const int pi, const string status, const long k, const LSR_Bar &b,
                              const bool havePrev, const double prevClose, const bool atrReady, const double atr)
     {
      if(m_nEvents >= ArraySize(m_events))
         ArrayResize(m_events, m_nEvents + 1, 1024);
      int e = m_nEvents++;
      m_events[e].pool = pi;
      m_events[e].status = status;
      m_events[e].bar_index = k;
      m_events[e].bar_time = b.time;
      m_events[e].open = b.open;
      m_events[e].high = b.high;
      m_events[e].low = b.low;
      m_events[e].close = b.close;
      m_events[e].have_prev = havePrev;
      m_events[e].prev_close = prevClose;
      m_events[e].atr_ready = atrReady;
      m_events[e].atr = atr;
      m_events[e].touches = m_pools[pi].touches;
      m_events[e].id = LSR_StableId("E|" + m_tfName + "|" + m_pools[pi].id + "|" + LSR_IsoTime(b.time));
     }

   int               Select(const int &cand[], const int side) const
     {
      int best = -1;
      for(int i = 0; i < ArraySize(cand); i++)
        {
         int pi = cand[i];
         if(best < 0)
           {
            best = pi;
            continue;
           }
         bool better;
         bool first = (m_cfg.multi_pool_policy == LSR_MULTIPOOL_FIRST_CROSSED_LEVEL);
         if(side > 0)
           {
            if(first)
               better = m_pools[pi].lower < m_pools[best].lower ||
                        (m_pools[pi].lower == m_pools[best].lower && (m_pools[pi].upper < m_pools[best].upper ||
                              (m_pools[pi].upper == m_pools[best].upper && StringCompare(m_pools[pi].id, m_pools[best].id) < 0)));
            else
               better = m_pools[pi].upper > m_pools[best].upper ||
                        (m_pools[pi].upper == m_pools[best].upper && (m_pools[pi].lower > m_pools[best].lower ||
                              (m_pools[pi].lower == m_pools[best].lower && StringCompare(m_pools[pi].id, m_pools[best].id) < 0)));
           }
         else
           {
            if(first)
               better = m_pools[pi].upper > m_pools[best].upper ||
                        (m_pools[pi].upper == m_pools[best].upper && (m_pools[pi].lower > m_pools[best].lower ||
                              (m_pools[pi].lower == m_pools[best].lower && StringCompare(m_pools[pi].id, m_pools[best].id) < 0)));
            else
               better = m_pools[pi].lower < m_pools[best].lower ||
                        (m_pools[pi].lower == m_pools[best].lower && (m_pools[pi].upper < m_pools[best].upper ||
                              (m_pools[pi].upper == m_pools[best].upper && StringCompare(m_pools[pi].id, m_pools[best].id) < 0)));
           }
         if(better)
            best = pi;
        }
      return best;
     }

   void              EvaluateSweeps(const long k, const LSR_Bar &b, const bool havePrev, const double prevClose,
                                    const bool atrReady, const double atr)
     {
      int hp[], lp[];
      string hs[], ls[];
      bool hc[], lc[];
      //--- high side: pools sorted by lower asc; interaction needs high > lower
      for(int i = 0; i < ArraySize(m_activeHigh); i++)
        {
         int pi = m_activeHigh[i];
         if(!(b.high > m_pools[pi].lower))
            break;
         bool crossing;
         string st = ClassifyHigh(m_pools[pi], b, havePrev, prevClose, crossing);
         if(st == "" && !crossing)
            continue;
         int n = ArraySize(hp);
         ArrayResize(hp, n + 1);
         ArrayResize(hs, n + 1);
         ArrayResize(hc, n + 1);
         hp[n] = pi;
         hs[n] = st;
         hc[n] = crossing;
        }
      for(int i = 0; i < ArraySize(m_activeLow); i++)
        {
         int pi = m_activeLow[i];
         if(!(b.low < m_pools[pi].upper))
            break;
         bool crossing;
         string st = ClassifyLow(m_pools[pi], b, havePrev, prevClose, crossing);
         if(st == "" && !crossing)
            continue;
         int n = ArraySize(lp);
         ArrayResize(lp, n + 1);
         ArrayResize(ls, n + 1);
         ArrayResize(lc, n + 1);
         lp[n] = pi;
         ls[n] = st;
         lc[n] = crossing;
        }

      int hv[], lv[];
      for(int i = 0; i < ArraySize(hp); i++)
         if(hs[i] == "VALID")
           {
            int n = ArraySize(hv);
            ArrayResize(hv, n + 1);
            hv[n] = hp[i];
           }
      for(int i = 0; i < ArraySize(lp); i++)
         if(ls[i] == "VALID")
           {
            int n = ArraySize(lv);
            ArrayResize(lv, n + 1);
            lv[n] = lp[i];
           }
      int hsel = Select(hv, 1);
      int lsel = Select(lv, -1);
      bool conflict = (hsel >= 0 && lsel >= 0);

      for(int i = 0; i < ArraySize(hp); i++)
        {
         string st = hs[i];
         if(st == "VALID")
            st = (hp[i] != hsel) ? "MULTI_POOL_NOT_SELECTED" : (conflict ? "CONFLICTING_SWEEP_SAME_BAR" : "SETUP");
         AddEvent(hp[i], st, k, b, havePrev, prevClose, atrReady, atr);
         hs[i] = st;
        }
      for(int i = 0; i < ArraySize(lp); i++)
        {
         string st = ls[i];
         if(st == "VALID")
            st = (lp[i] != lsel) ? "MULTI_POOL_NOT_SELECTED" : (conflict ? "CONFLICTING_SWEEP_SAME_BAR" : "SETUP");
         AddEvent(lp[i], st, k, b, havePrev, prevClose, atrReady, atr);
         ls[i] = st;
        }
      //--- consumption: every crossed pool is consumed (0B.4 / 2.12)
      datetime closeT = LSR_BarCloseTime(b);
      for(int i = 0; i < ArraySize(hp); i++)
         if(hc[i])
            ConsumePool(hp[i], closeT, hs[i]);
      for(int i = 0; i < ArraySize(lp); i++)
         if(lc[i])
            ConsumePool(lp[i], closeT, ls[i]);
     }

   void              ConsumePool(const int pi, const datetime t, const string status)
     {
      string reason;
      if(status == "SETUP")
         reason = "SWEPT";
      else
         if(status == "MULTI_POOL_NOT_SELECTED" || status == "CONFLICTING_SWEEP_SAME_BAR")
            reason = "SWEPT_NOT_TRADED";
         else
            reason = "BREACHED_" + status;
      EndPool(pi, t, reason);
      for(int i = 0; i < m_pools[pi].mem_count; i++)
        {
         int li = m_poolMem[m_pools[pi].mem_start + i];
         if(!m_levels[li].active)
            continue;
         m_levels[li].active = false;
         m_levels[li].end_time = t;
         m_levels[li].end_reason = reason;
         if(m_levels[li].kind <= LSR_LV_PSL && m_activeByKind[m_levels[li].kind] == li)
            m_activeByKind[m_levels[li].kind] = -1;
        }
     }

   //--- touches (0B.5 as closed in 2.12) -------------------------------
   void              AddTouch(const int pi, const datetime t)
     {
      m_pools[pi].touches++;
      if(m_nTouches >= ArraySize(m_touches))
         ArrayResize(m_touches, m_nTouches + 1, 4096);
      m_touches[m_nTouches].pool = pi;
      m_touches[m_nTouches].bar_time = t;
      m_touches[m_nTouches].number = m_pools[pi].touches;
      m_nTouches++;
     }

   void              UpdateTouches(const LSR_Bar &b, const bool havePrev, const double prevClose)
     {
      for(int i = 0; i < ArraySize(m_activeHigh); i++)
        {
         int pi = m_activeHigh[i];
         if(m_pools[pi].lower > b.high)
            break;
         if(m_pools[pi].upper < b.low)
            continue;
         if(!havePrev || prevClose < m_pools[pi].lower || prevClose > m_pools[pi].upper)
            AddTouch(pi, b.time);
        }
      for(int i = 0; i < ArraySize(m_activeLow); i++)
        {
         int pi = m_activeLow[i];
         if(m_pools[pi].upper < b.low)
            break;
         if(m_pools[pi].lower > b.high)
            continue;
         if(!havePrev || prevClose < m_pools[pi].lower || prevClose > m_pools[pi].upper)
            AddTouch(pi, b.time);
        }
     }

   //--- swings ----------------------------------------------------------
   void              ViolateSwings(const LSR_Bar &b)
     {
      while(ArraySize(m_liveSwHigh) > 0 && m_swings[m_liveSwHigh[0]].price < b.high)
        {
         m_swings[m_liveSwHigh[0]].live = false;
         RemoveValue(m_liveSwHigh, m_liveSwHigh[0]);
        }
      while(ArraySize(m_liveSwLow) > 0 && m_swings[m_liveSwLow[0]].price > b.low)
        {
         m_swings[m_liveSwLow[0]].live = false;
         RemoveValue(m_liveSwLow, m_liveSwLow[0]);
        }
     }

   void              InsertLiveSwing(const int si)
     {
      if(m_swings[si].side > 0)
        {
         int n = ArraySize(m_liveSwHigh);
         ArrayResize(m_liveSwHigh, n + 1, 256);
         int pos = n;
         while(pos > 0 && m_swings[m_liveSwHigh[pos - 1]].price > m_swings[si].price)
           {
            m_liveSwHigh[pos] = m_liveSwHigh[pos - 1];
            pos--;
           }
         m_liveSwHigh[pos] = si;
        }
      else
        {
         int n = ArraySize(m_liveSwLow);
         ArrayResize(m_liveSwLow, n + 1, 256);
         int pos = n;
         while(pos > 0 && m_swings[m_liveSwLow[pos - 1]].price < m_swings[si].price)
           {
            m_liveSwLow[pos] = m_liveSwLow[pos - 1];
            pos--;
           }
         m_liveSwLow[pos] = si;
        }
     }

   void              RegisterSwing(const int side, const int c, const long k)
     {
      datetime confT = LSR_BarCloseTime(m_bars[(int)k]);
      double price = (side > 0 ? m_bars[c].high : m_bars[c].low);
      //--- prominence diagnostic (0C.19): nearest prior confirmed opposite swing
      bool hasProm = false;
      double prom = 0.0;
      for(int i = m_nSwings - 1; i >= 0; i--)
         if(m_swings[i].side == -side && m_swings[i].conf_time < confT)
           {
            if(m_atr.Ready() && m_atr.Value() > 0.0)
              {
               prom = MathAbs(price - m_swings[i].price) / m_atr.Value();
               hasProm = true;
              }
            break;
           }
      //--- equal-level candidates (before registering this swing)
      int cand[];
      if(m_cfg.use_equal)
        {
         long pts = Pts(price);
         int n = (side > 0 ? ArraySize(m_liveSwHigh) : ArraySize(m_liveSwLow));
         for(int i = 0; i < n; i++)
           {
            int si = (side > 0 ? m_liveSwHigh[i] : m_liveSwLow[i]);
            if(m_swings[si].conf_time >= confT)
               continue;
            if(MathAbs(Pts(m_swings[si].price) - pts) > m_eqTolPts)
               continue;
            int q = ArraySize(cand);
            ArrayResize(cand, q + 1);
            cand[q] = si;
           }
        }

      if(m_nSwings >= ArraySize(m_swings))
         ArrayResize(m_swings, m_nSwings + 1, 1024);
      int s = m_nSwings++;
      m_swings[s].side = side;
      m_swings[s].price = price;
      m_swings[s].bar_time = m_bars[c].time;
      m_swings[s].conf_time = confT;
      m_swings[s].live = true;
      InsertLiveSwing(s);

      double one[1];
      one[0] = price;
      if(m_cfg.use_swings)
         Queue(side > 0 ? LSR_LV_SWING_HIGH : LSR_LV_SWING_LOW, price, price, one, LSR_IsoTime(m_bars[c].time),
               confT, m_bars[c].time, hasProm, prom, "");

      if(m_cfg.use_equal && ArraySize(cand) > 0)
        {
         //--- greedy: nearest price first, then most recent confirmation, then latest bar
         int nc = ArraySize(cand);
         for(int i = 1; i < nc; i++)
           {
            int key = cand[i];
            int j = i - 1;
            while(j >= 0 && EqBefore(key, cand[j], price))
              {
               cand[j + 1] = cand[j];
               j--;
              }
            cand[j + 1] = key;
           }
         int mem[];
         ArrayResize(mem, 1);
         mem[0] = s;
         long mn = Pts(price), mx = Pts(price);
         for(int i = 0; i < nc; i++)
           {
            long p = Pts(m_swings[cand[i]].price);
            long nmn = MathMin(mn, p), nmx = MathMax(mx, p);
            if(nmx - nmn > m_eqTolPts)
               continue;
            mn = nmn;
            mx = nmx;
            int q = ArraySize(mem);
            ArrayResize(mem, q + 1);
            mem[q] = cand[i];
           }
         if(ArraySize(mem) >= 2)
           {
            double prices[];
            string times[];
            ArrayResize(prices, ArraySize(mem));
            ArrayResize(times, ArraySize(mem));
            for(int i = 0; i < ArraySize(mem); i++)
              {
               prices[i] = m_swings[mem[i]].price;
               times[i] = LSR_IsoTime(m_swings[mem[i]].bar_time);
              }
            ArraySort(prices);
            SortStrings(times);
            string members = "";
            for(int i = 0; i < ArraySize(times); i++)
               members += (i > 0 ? ";" : "") + times[i];
            Queue(side > 0 ? LSR_LV_EQUAL_HIGHS : LSR_LV_EQUAL_LOWS, prices[0], prices[ArraySize(prices) - 1], prices,
                  members, confT, m_bars[c].time, false, 0.0, members);
           }
        }
     }

   bool              EqBefore(const int a, const int b, const double ref) const
     {
      long da = MathAbs(Pts(m_swings[a].price) - Pts(ref));
      long db = MathAbs(Pts(m_swings[b].price) - Pts(ref));
      if(da != db)
         return da < db;
      if(m_swings[a].conf_time != m_swings[b].conf_time)
         return m_swings[a].conf_time > m_swings[b].conf_time;
      return m_swings[a].bar_time > m_swings[b].bar_time;
     }

   void              DetectSwings(const long k)
     {
      int c = (int)k - m_cfg.swing_right;
      if(c - m_cfg.swing_left < 0)
         return;
      bool isHigh = true, isLow = true;
      for(int j = c - m_cfg.swing_left; j <= c + m_cfg.swing_right; j++)
        {
         if(j == c)
            continue;
         if(!(m_bars[c].high > m_bars[j].high))
            isHigh = false;
         if(!(m_bars[c].low < m_bars[j].low))
            isLow = false;
        }
      if(isHigh)
         RegisterSwing(1, c, k);
      if(isLow)
         RegisterSwing(-1, c, k);
     }

   //--- one completed SignalTimeframe bar ------------------------------
   //--- applyTime: when queued levels become effective = open of the next
   //--- TF bar (first bar after a gap), or this bar's close at the final flush.
   void              ProcessBar(const LSR_Bar &b, const datetime applyTime)
     {
      long k = m_nBars;
      if(m_nBars >= ArraySize(m_bars))
         ArrayResize(m_bars, m_nBars + 1, 4096);
      m_bars[m_nBars++] = b;
      bool havePrev = (k > 0);
      double prevClose = havePrev ? m_bars[(int)k - 1].close : 0.0;
      bool atrReady = m_atr.Ready();
      double atr = m_atr.Value();

      EvaluateSweeps(k, b, havePrev, prevClose, atrReady, atr);
      UpdateTouches(b, havePrev, prevClose);
      ViolateSwings(b);
      m_atr.Update(b);
      DetectSwings(k);
      ApplyPending(applyTime, k + 1);
     }

   //--- formatting ------------------------------------------------------
   string            N(const bool ok, const double v, const int d) const { return ok ? DoubleToString(v, d) : "NA"; }
   string            T(const datetime t) const { return t > 0 ? LSR_IsoTime(t) : ""; }

public:
                     CLSR_EventEngine(void) { m_nBars = 0; }

   bool              Init(const ENUM_LSR_TIMEFRAME tf, const LSR_EventConfig &cfg, string &error)
     {
      if(!LSR_ValidateEventConfig(cfg, error))
         return false;
      m_cfg = cfg;
      m_tf = tf;
      m_tfName = LSR_TimeframeName(tf);
      m_period = LSR_TimeframeSeconds(tf);
      m_eqTolPts = (long)MathRound(cfg.equal_tol_pips * cfg.pip_size / cfg.point);
      m_clusterTolPts = (long)MathRound(cfg.cluster_tol_pips * cfg.pip_size / cfg.point);
      m_agg.Init(m_period);
      m_atr.Init(LSR_ATR_PERIOD);
      m_nBars = 0;
      m_haveFirst = false;
      m_dayHave = false;
      m_sesHave = false;
      m_nLevels = 0;
      m_nPx = 0;
      m_nPools = 0;
      m_nPoolMem = 0;
      m_nTouches = 0;
      m_nEvents = 0;
      m_nSwings = 0;
      ArrayResize(m_pending, 0);
      ArrayResize(m_activeHigh, 0);
      ArrayResize(m_activeLow, 0);
      ArrayResize(m_liveSwHigh, 0);
      ArrayResize(m_liveSwLow, 0);
      for(int i = 0; i < 4; i++)
         m_activeByKind[i] = -1;
      return true;
     }

   void              OnM1(const LSR_Bar &m1)
     {
      if(!m_haveFirst)
        {
         m_firstM1 = m1.time;
         m_haveFirst = true;
        }
      TrackDay(m1);
      TrackSession(m1);
      LSR_Bar done;
      if(m_agg.OnM1(m1, done))
         ProcessBar(done, m1.time - (m1.time % m_period));
     }

   //--- Time advance from the tick stream (call after the tick's completed M1, if any).
   //--- Completes the day/session and the SignalTimeframe bar on the first tick after
   //--- their end, so a sweep is known at the first executable tick after the close.
   //--- Produces exactly the same ledgers as the M1-only path (OnM1).
   void              OnTime(const datetime t)
     {
      if(!m_haveFirst)
         return;
      FinalizeDayIfPast(t);
      FinalizeSessionIfPast(t);
      LSR_Bar done;
      if(m_agg.CompleteIfPast(t, done))
         ProcessBar(done, t - (t % m_period));
     }

   void              Flush(void)
     {
      LSR_Bar done;
      if(m_agg.Flush(done))
         ProcessBar(done, LSR_BarCloseTime(done));
     }

   //--- Test hook: queue a level that becomes effective at the next bar boundary.
   void              InjectLevel(const int kind, const double lo, const double hi, const string instance)
     {
      double prices[];
      ArrayResize(prices, lo == hi ? 1 : 2);
      prices[0] = lo;
      if(lo != hi)
         prices[1] = hi;
      Queue(kind, lo, hi, prices, instance, 0, 0, false, 0.0, "");
     }

   //--- accessors used by tests and reports
   ENUM_LSR_TIMEFRAME Timeframe(void) const { return m_tf; }
   int               BarCount(void) const   { return m_nBars; }
   int               LevelCount(void) const { return m_nLevels; }
   int               PoolCount(void) const  { return m_nPools; }
   int               EventCount(void) const { return m_nEvents; }
   int               TouchCount(void) const { return m_nTouches; }
   int               SwingCount(void) const { return m_nSwings; }
   int               ActivePoolCount(void) const { return ArraySize(m_activeHigh) + ArraySize(m_activeLow); }

   int               CountStatus(const string status) const
     {
      int c = 0;
      for(int i = 0; i < m_nEvents; i++)
         if(m_events[i].status == status)
            c++;
      return c;
     }
   string            EventStatus(const int i) const   { return m_events[i].status; }
   string            EventId(const int i) const       { return m_events[i].id; }
   int               EventSide(const int i) const     { return m_pools[m_events[i].pool].side; }
   int               EventTouches(const int i) const  { return m_events[i].touches; }
   datetime          EventBarTime(const int i) const  { return m_events[i].bar_time; }
   string            EventTags(const int i) const     { return m_pools[m_events[i].pool].tags; }
   double            EventPoolLower(const int i) const { return m_pools[m_events[i].pool].lower; }
   double            EventPoolUpper(const int i) const { return m_pools[m_events[i].pool].upper; }
   double            EventPenetration(const int i) const
     {
      int pi = m_events[i].pool;
      return m_pools[pi].side > 0 ? m_events[i].high - m_pools[pi].upper : m_pools[pi].lower - m_events[i].low;
     }
   double            EventReclaim(const int i) const
     {
      int pi = m_events[i].pool;
      return m_pools[pi].side > 0 ? m_pools[pi].lower - m_events[i].close : m_events[i].close - m_pools[pi].upper;
     }
   string            LevelKind(const int i) const    { return LSR_LevelKindName(m_levels[i].kind); }
   double            LevelLo(const int i) const      { return m_levels[i].lo; }
   double            LevelHi(const int i) const      { return m_levels[i].hi; }
   datetime          LevelArm(const int i) const     { return m_levels[i].arm; }
   string            LevelEndReason(const int i) const { return m_levels[i].end_reason; }
   bool              LevelHasProminence(const int i) const { return m_levels[i].has_prominence; }
   string            PoolTags(const int i) const     { return m_pools[i].tags; }
   string            PoolEndReason(const int i) const { return m_pools[i].end_reason; }
   int               PoolTouches(const int i) const  { return m_pools[i].touches; }
   double            PoolAnchor(const int i) const   { return m_pools[i].anchor; }
   double            PoolLower(const int i) const    { return m_pools[i].lower; }
   double            PoolUpper(const int i) const    { return m_pools[i].upper; }
   int               PoolInherited(const int i) const { return m_pools[i].inherited; }
   bool              PoolActive(const int i) const   { return m_pools[i].active; }
   datetime          PoolArm(const int i) const      { return m_pools[i].arm; }
   int               EventPoolIndex(const int i) const { return m_events[i].pool; }
   string            LevelId(const int i) const      { return m_levels[i].id; }
   int               ActiveHighCount(void) const     { return ArraySize(m_activeHigh); }
   bool              GetBar(const int k, LSR_Bar &b) const
     {
      if(k < 0 || k >= m_nBars)
         return false;
      b = m_bars[k];
      return true;
     }
   long              EventBarIndex(const int i) const { return m_events[i].bar_index; }
   void              EventBar(const int i, LSR_Bar &b) const
     {
      b.time = m_events[i].bar_time;
      b.period = m_period;
      b.open = m_events[i].open;
      b.high = m_events[i].high;
      b.low = m_events[i].low;
      b.close = m_events[i].close;
      b.ticks = 0;
     }
   string            EventMemberIds(const int i) const { return m_pools[m_events[i].pool].member_ids; }
   //--- Swing prominence of the first pool member that carries one (0C.19 diagnostic).
   bool              EventSwingProminence(const int i, double &v) const
     {
      int pi = m_events[i].pool;
      for(int k = 0; k < m_pools[pi].mem_count; k++)
        {
         int li = m_poolMem[m_pools[pi].mem_start + k];
         if(m_levels[li].has_prominence)
           {
            v = m_levels[li].prominence;
            return true;
           }
        }
      return false;
     }
   int               Period(void) const { return m_period; }

   //+---------------------------------------------------------------+
   //| Ledgers (CSV, UTF-8). Returns false if a file cannot be opened.|
   //+---------------------------------------------------------------+
   bool              WriteLedgers(const string dir, CLSR_QuarantineCheck &q) const
     {
      string tf = m_tfName;
      int h = FileOpen(dir + "events_" + tf + ".csv", FILE_WRITE | FILE_BIN | FILE_COMMON);
      if(h == INVALID_HANDLE)
         return false;
      WriteLine(h, "tf,event_id,pool_id,side,direction,status,sweep_bar_time,sweep_close_time,open,high,low,close,prev_close,"
                "pool_lower,pool_upper,pool_anchor,sweep_extreme,penetration,reclaim,penetration_pips,reclaim_pips,atr,"
                "penetration_atr,reclaim_atr,touch_count,touch_bucket,source_tags,member_level_ids,level_age_sec,level_age_bars,"
                "pool_age_sec,pool_age_bars,confirmation_mode,multi_pool_policy,in_quarantine,decision_trace");
      for(int i = 0; i < m_nEvents; i++)
        {
         int pi = m_events[i].pool;
         int side = m_pools[pi].side;
         double pen = side > 0 ? m_events[i].high - m_pools[pi].upper : m_pools[pi].lower - m_events[i].low;
         double rec = side > 0 ? m_pools[pi].lower - m_events[i].close : m_events[i].close - m_pools[pi].upper;
         bool atrOk = m_events[i].atr_ready && m_events[i].atr > 0.0;
         datetime closeT = m_events[i].bar_time + m_period;
         bool quar = q.Overlaps(m_events[i].bar_time, closeT);
         string trace = "LEVEL_ELIGIBLE=PASS|POOL_MATCH=" + m_pools[pi].id + "|SWEEP_VALID=" + m_events[i].status +
                        "|TOUCH_COUNT=" + IntegerToString(m_events[i].touches) + "|ENTRY_MODE=" + LSR_EntryModeName(m_cfg.entry_mode) +
                        "|FILTER_A=NOT_EVALUATED|FILTER_B=NOT_EVALUATED|FILTER_C=NOT_EVALUATED|NEWS_STATE=OBSERVE_ONLY"
                        "|SPREAD_STATE=NOT_EVALUATED|RISK_STATE=NOT_EVALUATED|ACCOUNT_RULE_STATE=NOT_EVALUATED|FINAL_ADMISSION=NOT_EVALUATED";
         string row = tf + "," + m_events[i].id + "," + m_pools[pi].id + "," + LSR_SideName(side) + "," + (side > 0 ? "SHORT" : "LONG") + "," +
                      m_events[i].status + "," + T(m_events[i].bar_time) + "," + T(closeT) + "," +
                      P(m_events[i].open) + "," + P(m_events[i].high) + "," + P(m_events[i].low) + "," + P(m_events[i].close) + "," +
                      (m_events[i].have_prev ? P(m_events[i].prev_close) : "NA") + "," +
                      P(m_pools[pi].lower) + "," + P(m_pools[pi].upper) + "," + DoubleToString(m_pools[pi].anchor, m_cfg.digits + 1) + "," +
                      P(side > 0 ? m_events[i].high : m_events[i].low) + "," +
                      P(pen) + "," + P(rec) + "," + DoubleToString(pen / m_cfg.pip_size, 4) + "," + DoubleToString(rec / m_cfg.pip_size, 4) + "," +
                      N(atrOk, m_events[i].atr, 8) + "," + N(atrOk, atrOk ? pen / m_events[i].atr : 0.0, 6) + "," + N(atrOk, atrOk ? rec / m_events[i].atr : 0.0, 6) + "," +
                      IntegerToString(m_events[i].touches) + "," + LSR_TouchBucket(m_events[i].touches) + "," +
                      m_pools[pi].tags + "," + m_pools[pi].member_ids + "," +
                      IntegerToString((long)(m_events[i].bar_time - m_pools[pi].level_arm)) + "," + IntegerToString(m_events[i].bar_index - m_pools[pi].level_arm_index) + "," +
                      IntegerToString((long)(m_events[i].bar_time - m_pools[pi].arm)) + "," + IntegerToString(m_events[i].bar_index - m_pools[pi].arm_index) + "," +
                      LSR_EntryModeName(m_cfg.entry_mode) + "," + LSR_MultiPoolPolicyName(m_cfg.multi_pool_policy) + "," +
                      (quar ? "1" : "0") + "," + trace;
         WriteLine(h, row);
        }
      FileClose(h);

      h = FileOpen(dir + "levels_" + tf + ".csv", FILE_WRITE | FILE_BIN | FILE_COMMON);
      if(h == INVALID_HANDLE)
         return false;
      WriteLine(h, "tf,level_id,kind,side,price_low,price_high,source_instance,available_time,arm_time,end_time,end_reason,pool_id,prominence_atr,members");
      for(int i = 0; i < m_nLevels; i++)
        {
         string row = tf + "," + m_levels[i].id + "," + LSR_LevelKindName(m_levels[i].kind) + "," + LSR_SideName(LSR_LevelKindSide(m_levels[i].kind)) + "," +
                      P(m_levels[i].lo) + "," + P(m_levels[i].hi) + "," + m_levels[i].instance + "," + T(m_levels[i].avail) + "," + T(m_levels[i].arm) + "," +
                      T(m_levels[i].end_time) + "," + (m_levels[i].active ? "ACTIVE" : m_levels[i].end_reason) + "," +
                      (m_levels[i].pool >= 0 ? m_pools[m_levels[i].pool].id : "") + "," +
                      N(m_levels[i].has_prominence, m_levels[i].prominence, 6) + "," + m_levels[i].members;
         WriteLine(h, row);
        }
      FileClose(h);

      h = FileOpen(dir + "pools_" + tf + ".csv", FILE_WRITE | FILE_BIN | FILE_COMMON);
      if(h == INVALID_HANDLE)
         return false;
      WriteLine(h, "tf,pool_id,side,pool_lower,pool_upper,pool_anchor,source_tags,member_level_ids,arm_time,end_time,end_reason,final_state,predecessor_pool_id,inherited_touches,touches");
      for(int i = 0; i < m_nPools; i++)
        {
         string state;
         if(m_pools[i].active)
            state = m_pools[i].touches > 0 ? "TOUCHED" : "ARMED";
         else
            if(m_pools[i].end_reason == "SUPERSEDED")
               state = "SUPERSEDED";
            else
               if(m_pools[i].end_reason == "EXPIRED" || m_pools[i].end_reason == "MEMBER_EXPIRED")
                  state = "EXPIRED";
               else
                  state = "CONSUMED";
         string row = tf + "," + m_pools[i].id + "," + LSR_SideName(m_pools[i].side) + "," + P(m_pools[i].lower) + "," + P(m_pools[i].upper) + "," +
                      DoubleToString(m_pools[i].anchor, m_cfg.digits + 1) + "," + m_pools[i].tags + "," + m_pools[i].member_ids + "," +
                      T(m_pools[i].arm) + "," + T(m_pools[i].end_time) + "," + (m_pools[i].active ? "ACTIVE" : m_pools[i].end_reason) + "," + state + "," +
                      m_pools[i].predecessor + "," + IntegerToString(m_pools[i].inherited) + "," + IntegerToString(m_pools[i].touches);
         WriteLine(h, row);
        }
      FileClose(h);

      h = FileOpen(dir + "touches_" + tf + ".csv", FILE_WRITE | FILE_BIN | FILE_COMMON);
      if(h == INVALID_HANDLE)
         return false;
      WriteLine(h, "tf,pool_id,touch_bar_time,touch_number,band_lower,band_upper");
      for(int i = 0; i < m_nTouches; i++)
        {
         int pi = m_touches[i].pool;
         WriteLine(h, tf + "," + m_pools[pi].id + "," + T(m_touches[i].bar_time) + "," + IntegerToString(m_touches[i].number) + "," +
                   P(m_pools[pi].lower) + "," + P(m_pools[pi].upper));
        }
      FileClose(h);
      return true;
     }

   static void       WriteLine(const int h, const string line)
     {
      uchar bytes[];
      LSR_Utf8Bytes(line + "\n", bytes);
      FileWriteArray(h, bytes, 0, ArraySize(bytes));
     }

   void              WriteSummaryJson(CLSR_Json &j) const
     {
      j.BeginObject();
      j.KStr("timeframe", m_tfName);
      j.KInt("bars", m_nBars);
      j.KInt("swings", m_nSwings);
      j.KInt("levels", m_nLevels);
      j.KInt("pools", m_nPools);
      j.KInt("active_pools_at_end", ActivePoolCount());
      j.KInt("touches", m_nTouches);
      j.KInt("event_rows", m_nEvents);
      j.KObj("event_status_counts");
      string st[] = {"SETUP", "PARTIAL_POOL_SWEEP", "OPEN_ON_LIQUIDITY", "OPEN_INSIDE_POOL", "OPENED_BEYOND_POOL",
                     "PREV_CLOSE_NOT_OUTSIDE", "NO_RECLAIM", "NO_PREVIOUS_BAR", "MULTI_POOL_NOT_SELECTED", "CONFLICTING_SWEEP_SAME_BAR"};
      for(int i = 0; i < ArraySize(st); i++)
         j.KInt(st[i], CountStatus(st[i]));
      j.EndObject();
      int longs = 0, shorts = 0;
      for(int i = 0; i < m_nEvents; i++)
         if(m_events[i].status == "SETUP")
           {
            if(m_pools[m_events[i].pool].side > 0)
               shorts++;
            else
               longs++;
           }
      j.KInt("setups_long", longs);
      j.KInt("setups_short", shorts);
      j.EndObject();
     }
  };

#endif // LSR_LIQUIDITY_MQH
//+------------------------------------------------------------------+
