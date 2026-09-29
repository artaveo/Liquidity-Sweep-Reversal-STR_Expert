//+------------------------------------------------------------------+
//| LSR_EventReplay.mq5                                              |
//| Deterministic replay of the Phase 2 event layer from an exported |
//| M1 bar file (Common\Files\<Folder>\bars_M1_BID.csv). Writes the  |
//| same events/levels/pools/touches ledgers as LSR_Expert, so a run |
//| package or a synthetic fixture can be re-derived and reconciled  |
//| with the Python reference. No market access, no trading.         |
//+------------------------------------------------------------------+
#property copyright   "Liquidity Sweep Reversal"
#property version     "1.00"
#property description "Phase 2 event replay from exported M1 bars (no trading)"
#property script_show_inputs

#include "../../Include/LiquiditySweepReversal/LSR_Phase2.mqh"

input string                     InpFolder                  = "LSR\\LSR-P2-SMOKE"; // Package folder under Common\Files
input string                     InpBarsFile                = "bars_M1_BID.csv";    // M1 bar file inside the folder
input string                     InpOutputSubfolder         = "replay";             // Ledger output subfolder
input string                     InpTimeframes              = "M5,M15,H1";          // TimeframeSet
input int                        InpDigits                  = 2;                    // Symbol digits
input double                     InpPoint                   = 0.01;                 // SYMBOL_POINT
input double                     InpStrategyPipSize         = 0.10;                 // StrategyPipSize
input bool                       InpUsePreviousDayHighLow   = true;                 // PreviousDayHighLow
input bool                       InpUsePreviousSessionHighLow = true;               // PreviousSessionHighLow
input bool                       InpUseConfirmedSwingHighLow = true;                // ConfirmedSwingHighLow
input bool                       InpUseEqualHighsLows       = true;                 // EqualHighsLows
input string                     InpLiquiditySessionStart   = "16:30";              // LiquiditySessionStart
input string                     InpLiquiditySessionEnd     = "21:30";              // LiquiditySessionEnd
input int                        InpSwingLeftBars           = 2;                    // SwingLeftBars
input int                        InpSwingRightBars          = 2;                    // SwingRightBars
input double                     InpEqualLevelTolerancePips = 3.0;                  // EqualLevelTolerancePips
input double                     InpLiquidityClusteringTolerancePips = 3.0;         // LiquidityClusteringTolerancePips
input ENUM_LSR_MULTI_POOL_POLICY InpMultiPoolSweepPolicy    = LSR_MULTIPOOL_FIRST_CROSSED_LEVEL; // MultiPoolSweepPolicy
input ENUM_LSR_ENTRY_MODE        InpEntryMode               = LSR_ENTRY_RECLAIM_CLOSE; // EntryMode
input bool                       InpCloseTerminalWhenDone   = false;                // Close terminal after the run (CI use)

CLSR_EventEngine g_engines[LSR_TF_COUNT];

datetime ParseIso(const string s)
  {
   string t = s;
   StringReplace(t, "-", ".");
   StringReplace(t, "T", " ");
   return StringToTime(t);
  }

void OnStart(void)
  {
   string err;
   LSR_TimeframeSet set;
   if(!LSR_ParseTimeframeSet(InpTimeframes, set, err))
     {
      Print("LSR replay: ", err);
      return;
     }
   LSR_EventConfig cfg;
   LSR_EventConfigDefaults(cfg);
   cfg.use_previous_day = InpUsePreviousDayHighLow;
   cfg.use_previous_session = InpUsePreviousSessionHighLow;
   cfg.use_swings = InpUseConfirmedSwingHighLow;
   cfg.use_equal = InpUseEqualHighsLows;
   if(!LSR_ParseHHMM(InpLiquiditySessionStart, false, cfg.session_start_sec, err) ||
      !LSR_ParseHHMM(InpLiquiditySessionEnd, true, cfg.session_end_sec, err))
     {
      Print("LSR replay: ", err);
      return;
     }
   cfg.swing_left = InpSwingLeftBars;
   cfg.swing_right = InpSwingRightBars;
   cfg.equal_tol_pips = InpEqualLevelTolerancePips;
   cfg.cluster_tol_pips = InpLiquidityClusteringTolerancePips;
   cfg.multi_pool_policy = InpMultiPoolSweepPolicy;
   cfg.entry_mode = InpEntryMode;
   cfg.pip_size = InpStrategyPipSize;
   cfg.point = InpPoint;
   cfg.digits = InpDigits;
   for(int i = 0; i < set.count; i++)
      if(!g_engines[i].Init(set.items[i], cfg, err))
        {
         Print("LSR replay: ", err);
         return;
        }

   string dir = InpFolder + "\\";
   int h = FileOpen(dir + InpBarsFile, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("LSR replay: cannot open %s%s (error %d)", dir, InpBarsFile, GetLastError());
      return;
     }
   string header = FileReadString(h);
   if(header != "time,open,high,low,close,ticks")
     {
      Print("LSR replay: unexpected header ", header);
      FileClose(h);
      return;
     }
   long n = 0;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      if(line == "")
         continue;
      string f[];
      if(StringSplit(line, ',', f) != 6)
        {
         PrintFormat("LSR replay: bad line %I64d: %s", n + 2, line);
         FileClose(h);
         return;
        }
      LSR_Bar b;
      b.time = ParseIso(f[0]);
      b.period = 60;
      b.open = StringToDouble(f[1]);
      b.high = StringToDouble(f[2]);
      b.low = StringToDouble(f[3]);
      b.close = StringToDouble(f[4]);
      b.ticks = StringToInteger(f[5]);
      for(int i = 0; i < set.count; i++)
         g_engines[i].OnM1(b);
      n++;
     }
   FileClose(h);
   for(int i = 0; i < set.count; i++)
      g_engines[i].Flush();

   string out = dir + InpOutputSubfolder + "\\";
   CLSR_QuarantineCheck none;
   string summary = "";
   for(int i = 0; i < set.count; i++)
     {
      if(!g_engines[i].WriteLedgers(out, none))
         PrintFormat("LSR replay: cannot write ledgers for %s", LSR_TimeframeName(set.items[i]));
      summary += StringFormat(" %s: bars=%d events=%d setups=%d", LSR_TimeframeName(set.items[i]), g_engines[i].BarCount(),
                              g_engines[i].EventCount(), g_engines[i].CountStatus("SETUP"));
     }
   LSR_WriteUtf8File(out + "replay_done.txt", StringFormat("m1_bars=%I64d%s\n", n, summary), true);
   PrintFormat("LSR replay done: m1_bars=%I64d%s -> Common\\Files\\%s", n, summary, out);
   if(InpCloseTerminalWhenDone)
      TerminalClose(0);
  }
//+------------------------------------------------------------------+
