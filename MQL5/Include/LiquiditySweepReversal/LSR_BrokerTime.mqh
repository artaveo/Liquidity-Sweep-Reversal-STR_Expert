//+------------------------------------------------------------------+
//| LSR_BrokerTime.mqh                                               |
//| Broker Server Time helpers (roadmap 1.2). No UTC offset and no   |
//| DST table: every timestamp is the broker server's own datetime.  |
//+------------------------------------------------------------------+
#ifndef LSR_BROKERTIME_MQH
#define LSR_BROKERTIME_MQH

#include "LSR_Types.mqh"

#define LSR_SERVER_TIME_BASIS "BROKER_SERVER_TIME"

datetime LSR_BrokerDayStart(const datetime t)
  {
   long v = (long)t;
   return (datetime)(v - (v % LSR_SECONDS_PER_DAY));
  }

int LSR_SecondsOfDay(const datetime t)
  {
   return (int)((long)t % LSR_SECONDS_PER_DAY);
  }

// 0 = Sunday … 6 = Saturday (same as ENUM_DAY_OF_WEEK)
int LSR_DayOfWeek(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return s.day_of_week;
  }

int LSR_BrokerMonthKey(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return s.year * 100 + s.mon;
  }

int LSR_BrokerYear(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return s.year;
  }

//+------------------------------------------------------------------+
//| Broker-day clock. The reset timestamp is the first observed      |
//| broker-server timestamp at or after 00:00:00 of the new day      |
//| (roadmap 0B.10).                                                 |
//+------------------------------------------------------------------+
class CLSR_BrokerDayClock
  {
private:
   datetime          m_day;
   datetime          m_resetTimestamp;
   int               m_resets;

public:
                     CLSR_BrokerDayClock(void) { Reset(); }
   void              Reset(void)
     {
      m_day = 0;
      m_resetTimestamp = 0;
      m_resets = 0;
     }

   // Returns true when t opens a new broker day (including the very first observation).
   bool              Observe(const datetime t)
     {
      datetime d = LSR_BrokerDayStart(t);
      if(m_resets > 0 && d <= m_day)
         return false;
      m_day = d;
      m_resetTimestamp = t;
      m_resets++;
      return true;
     }

   datetime          Day(void) const            { return m_day; }
   datetime          ResetTimestamp(void) const { return m_resetTimestamp; }
   int               ResetCount(void) const     { return m_resets; }
  };

#endif // LSR_BROKERTIME_MQH
//+------------------------------------------------------------------+
