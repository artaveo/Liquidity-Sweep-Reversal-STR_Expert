//+------------------------------------------------------------------+
//| LSR_Timeframes.mqh                                               |
//| TimeframeSet parsing/canonicalisation and LiveTimeframe rule     |
//| (roadmap 1.1, architecture rules 2, 11, 12).                     |
//+------------------------------------------------------------------+
#ifndef LSR_TIMEFRAMES_MQH
#define LSR_TIMEFRAMES_MQH

#include "LSR_Types.mqh"

#define LSR_DEFAULT_TIMEFRAME_SET "M5,M15,H1"

string LSR_TimeframeName(const ENUM_LSR_TIMEFRAME tf)
  {
   switch(tf)
     {
      case LSR_TF_M1:  return "M1";
      case LSR_TF_M5:  return "M5";
      case LSR_TF_M15: return "M15";
      case LSR_TF_M30: return "M30";
      case LSR_TF_H1:  return "H1";
     }
   return "UNKNOWN";
  }

ENUM_TIMEFRAMES LSR_ToMqlTimeframe(const ENUM_LSR_TIMEFRAME tf)
  {
   switch(tf)
     {
      case LSR_TF_M1:  return PERIOD_M1;
      case LSR_TF_M5:  return PERIOD_M5;
      case LSR_TF_M15: return PERIOD_M15;
      case LSR_TF_M30: return PERIOD_M30;
      case LSR_TF_H1:  return PERIOD_H1;
     }
   return PERIOD_CURRENT;
  }

int LSR_TimeframeSeconds(const ENUM_LSR_TIMEFRAME tf)
  {
   switch(tf)
     {
      case LSR_TF_M1:  return 60;
      case LSR_TF_M5:  return 300;
      case LSR_TF_M15: return 900;
      case LSR_TF_M30: return 1800;
      case LSR_TF_H1:  return 3600;
     }
   return 0;
  }

//+------------------------------------------------------------------+
//| Token must already be trimmed and upper-cased.                   |
//+------------------------------------------------------------------+
bool LSR_TryParseTimeframeToken(const string token, ENUM_LSR_TIMEFRAME &tf)
  {
   if(token == "M1")  { tf = LSR_TF_M1;  return true; }
   if(token == "M5")  { tf = LSR_TF_M5;  return true; }
   if(token == "M15") { tf = LSR_TF_M15; return true; }
   if(token == "M30") { tf = LSR_TF_M30; return true; }
   if(token == "H1")  { tf = LSR_TF_H1;  return true; }
   return false;
  }

//+------------------------------------------------------------------+
//| A parsed TimeframeSet, always stored in canonical enum order.    |
//+------------------------------------------------------------------+
struct LSR_TimeframeSet
  {
   int                count;
   ENUM_LSR_TIMEFRAME items[LSR_TF_COUNT];
  };

void LSR_TimeframeSetClear(LSR_TimeframeSet &set)
  {
   set.count = 0;
   for(int i = 0; i < LSR_TF_COUNT; i++)
      set.items[i] = LSR_TF_M1;
  }

bool LSR_TimeframeSetContains(const LSR_TimeframeSet &set, const ENUM_LSR_TIMEFRAME tf)
  {
   for(int i = 0; i < set.count; i++)
      if(set.items[i] == tf)
         return true;
   return false;
  }

string LSR_TimeframeSetToString(const LSR_TimeframeSet &set)
  {
   string s = "";
   for(int i = 0; i < set.count; i++)
     {
      if(i > 0)
         s += ",";
      s += LSR_TimeframeName(set.items[i]);
     }
   return s;
  }

//+------------------------------------------------------------------+
//| Comma-separated, case-insensitive, whitespace-tolerant.          |
//| Empty entries, unsupported values and duplicates fail; duplicates|
//| are never silently removed. Output is canonical M1,M5,M15,M30,H1.|
//+------------------------------------------------------------------+
bool LSR_ParseTimeframeSet(const string text, LSR_TimeframeSet &set, string &error)
  {
   LSR_TimeframeSetClear(set);
   error = "";

   string whole = text;
   StringTrimLeft(whole);
   StringTrimRight(whole);
   if(whole == "")
     {
      error = "TimeframeSet is empty";
      return false;
     }

   string parts[];
   int n = StringSplit(text, ',', parts);
   if(n <= 0)
     {
      error = "TimeframeSet is empty";
      return false;
     }

   bool seen[LSR_TF_COUNT];
   ArrayInitialize(seen, false);

   for(int i = 0; i < n; i++)
     {
      string tok = parts[i];
      StringTrimLeft(tok);
      StringTrimRight(tok);
      StringToUpper(tok);
      if(tok == "")
        {
         error = StringFormat("TimeframeSet entry %d is empty", i + 1);
         return false;
        }
      ENUM_LSR_TIMEFRAME tf = LSR_TF_M1;
      if(!LSR_TryParseTimeframeToken(tok, tf))
        {
         error = StringFormat("TimeframeSet entry %d '%s' is not one of M1/M5/M15/M30/H1", i + 1, tok);
         return false;
        }
      if(seen[(int)tf])
        {
         error = StringFormat("TimeframeSet entry %d '%s' is a duplicate", i + 1, tok);
         return false;
        }
      seen[(int)tf] = true;
     }

   for(int k = 0; k < LSR_TF_COUNT; k++)
      if(seen[k])
        {
         set.items[set.count] = (ENUM_LSR_TIMEFRAME)k;
         set.count++;
        }
   return true;
  }

//+------------------------------------------------------------------+
//| LiveTimeframe must be exactly one member of TimeframeSet.        |
//+------------------------------------------------------------------+
bool LSR_ValidateLiveTimeframe(const LSR_TimeframeSet &set, const ENUM_LSR_TIMEFRAME live, string &error)
  {
   error = "";
   if(!LSR_TimeframeSetContains(set, live))
     {
      error = StringFormat("LiveTimeframe %s is not a member of TimeframeSet %s",
                           LSR_TimeframeName(live), LSR_TimeframeSetToString(set));
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Research (tester) runs every TimeframeSet member; live runs only |
//| the one fixed LiveTimeframe.                                     |
//+------------------------------------------------------------------+
void LSR_ResolveActiveTimeframes(const LSR_TimeframeSet &set,
                                 const ENUM_LSR_TIMEFRAME live,
                                 const ENUM_LSR_RUN_CONTEXT ctx,
                                 LSR_TimeframeSet &active)
  {
   if(ctx == LSR_CONTEXT_RESEARCH)
     {
      active = set;
      return;
     }
   LSR_TimeframeSetClear(active);
   active.items[0] = live;
   active.count = 1;
  }

#endif // LSR_TIMEFRAMES_MQH
//+------------------------------------------------------------------+
