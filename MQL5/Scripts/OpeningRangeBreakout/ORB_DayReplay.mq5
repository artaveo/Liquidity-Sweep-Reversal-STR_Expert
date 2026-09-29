//+------------------------------------------------------------------+
//| ORB_DayReplay.mq5                                                |
//| Rebuilds orb_days_<ORLEN>.csv from an exported M1 bar file       |
//| (Common\Files\<Folder>\bars_M1_BID.csv), like LSR_EventReplay.   |
//| The weekly session schedule is read from the chart symbol; the   |
//| quarantine windows and detected closures come from the package.  |
//| No market access, no trading.                                    |
//+------------------------------------------------------------------+
#property copyright   "Opening Range Breakout"
#property version     "1.00"
#property description "ORB day-ledger replay from exported M1 bars (no trading)"
#property script_show_inputs

#include "../../Include/OpeningRangeBreakout/ORB_Phase1.mqh"

input string InpFolder                = "ORB\\ORB-1-SMOKE";            // Package folder under Common\Files
input string InpBarsFile              = "bars_M1_BID.csv";             // M1 bar file inside the folder
input string InpQuarantineFile        = "data_quarantine_windows.csv"; // Quarantine windows inside the folder ("" = none)
input string InpClosuresFile          = "detected_market_closures.csv"; // Detected closures inside the folder ("" = none)
input string InpOutputSubfolder       = "replay";                      // Ledger output subfolder
input int    InpDigits                = 2;                             // Symbol digits
input double InpPoint                 = 0.01;                          // SYMBOL_POINT
input bool   InpCloseTerminalWhenDone = false;                         // Close terminal after the run (CI use)

CORB_DayLedger    g_days;
CORB_IntervalList g_quar;

void OnStart(void)
  {
   string err;
   CLSR_SessionSchedule sched;
   if(!sched.LoadFromSymbol(_Symbol, err))
     {
      Print("ORB replay: ", err);
      return;
     }
   string dir = InpFolder + "\\";
   g_quar.Clear();
   if(InpQuarantineFile != "" && !g_quar.LoadCsv(dir + InpQuarantineFile))
      PrintFormat("ORB replay: warning, cannot read %s%s", dir, InpQuarantineFile);
   if(InpClosuresFile != "" && !g_quar.LoadCsv(dir + InpClosuresFile))
      PrintFormat("ORB replay: warning, cannot read %s%s", dir, InpClosuresFile);

   int h = FileOpen(dir + InpBarsFile, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("ORB replay: cannot open %s%s (error %d)", dir, InpBarsFile, GetLastError());
      return;
     }
   string header = FileReadString(h);
   if(header != "time,open,high,low,close,ticks")
     {
      Print("ORB replay: unexpected header ", header);
      FileClose(h);
      return;
     }
   g_days.Init(InpDigits, InpPoint);
   long n = 0;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      if(line == "")
         continue;
      string f[];
      if(StringSplit(line, ',', f) != 6)
        {
         PrintFormat("ORB replay: bad line %I64d: %s", n + 2, line);
         FileClose(h);
         return;
        }
      LSR_Bar b;
      b.time = ORB_ParseTime(f[0]);
      b.period = 60;
      b.open = StringToDouble(f[1]);
      b.high = StringToDouble(f[2]);
      b.low = StringToDouble(f[3]);
      b.close = StringToDouble(f[4]);
      b.ticks = StringToInteger(f[5]);
      g_days.OnM1(b);
      n++;
     }
   FileClose(h);
   g_days.Build(sched, g_quar);

   string out = dir + InpOutputSubfolder + "\\";
   string summary = "";
   for(int k = 0; k < ORB_ORLEN_COUNT; k++)
     {
      if(!g_days.WriteCsv(out + "orb_days_" + ORB_OrLenName(k) + ".csv", k))
         PrintFormat("ORB replay: cannot write orb_days_%s.csv", ORB_OrLenName(k));
      summary += StringFormat(" %s: rows=%d trade=%d", ORB_OrLenName(k), g_days.CountRows(k), g_days.CountDecision(k, ORB_TRADE));
     }
   LSR_WriteUtf8File(out + "replay_done.txt", StringFormat("m1_bars=%I64d quarantine_or_closure_windows=%d%s\n", n, g_quar.Count(), summary), true);
   PrintFormat("ORB replay done: m1_bars=%I64d%s -> Common\\Files\\%s", n, summary, out);
   if(InpCloseTerminalWhenDone)
      TerminalClose(0);
  }
//+------------------------------------------------------------------+
