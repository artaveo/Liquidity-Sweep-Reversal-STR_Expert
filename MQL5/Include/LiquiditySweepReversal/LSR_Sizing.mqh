//+------------------------------------------------------------------+
//| LSR_Sizing.mqh                                                   |
//| Stress-aware position sizing and symbol constraints              |
//| (roadmap 1.8, 0C.9, 0C.10, 4.5).                                 |
//|                                                                  |
//| WorstCaseLossPerLot =                                            |
//|   loss(ExecEntry → SL ∓ DeclaredRiskExecutionBufferPoints)       |
//|   + opening commission per lot                                   |
//| ExecEntry = admission quote with configured adverse entry        |
//| slippage (Ask+E long / Bid−E short); the buffer covers the       |
//| stop-exit leg. Volume is rounded DOWN to the legal step.         |
//+------------------------------------------------------------------+
#ifndef LSR_SIZING_MQH
#define LSR_SIZING_MQH

#include "LSR_Types.mqh"
#include "LSR_Quote.mqh"
#include "LSR_SymbolSpec.mqh"
#include "LSR_Costs.mqh"

//+------------------------------------------------------------------+
//| Symbol economics: account-currency P/L and margin per 1.0 lot.   |
//+------------------------------------------------------------------+
class CLSR_SymbolEconomics
  {
public:
   virtual          ~CLSR_SymbolEconomics(void) {}
   virtual bool      ProfitPerLot(const ENUM_LSR_DIRECTION dir, const double openPrice,
                                  const double closePrice, double &profit) = 0;
   virtual bool      MarginPerLot(const ENUM_LSR_DIRECTION dir, const double price, double &margin) = 0;
  };

//--- MT5 implementation: OrderCalcProfit / OrderCalcMargin.
class CLSR_MT5Economics : public CLSR_SymbolEconomics
  {
private:
   string            m_symbol;
public:
                     CLSR_MT5Economics(const string symbol) { m_symbol = symbol; }
   virtual bool      ProfitPerLot(const ENUM_LSR_DIRECTION dir, const double openPrice,
                                  const double closePrice, double &profit)
     {
      ENUM_ORDER_TYPE t = (dir == LSR_DIR_LONG ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      return OrderCalcProfit(t, m_symbol, 1.0, openPrice, closePrice, profit);
     }
   virtual bool      MarginPerLot(const ENUM_LSR_DIRECTION dir, const double price, double &margin)
     {
      ENUM_ORDER_TYPE t = (dir == LSR_DIR_LONG ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      return OrderCalcMargin(t, m_symbol, 1.0, price, margin);
     }
  };

//--- Linear CFD economics (profit currency = account currency). Used by tests.
class CLSR_LinearEconomics : public CLSR_SymbolEconomics
  {
private:
   double            m_contractSize;
   double            m_leverage;
public:
                     CLSR_LinearEconomics(const double contractSize, const double leverage)
     {
      m_contractSize = contractSize;
      m_leverage = leverage;
     }
   virtual bool      ProfitPerLot(const ENUM_LSR_DIRECTION dir, const double openPrice,
                                  const double closePrice, double &profit)
     {
      profit = (dir == LSR_DIR_LONG ? closePrice - openPrice : openPrice - closePrice) * m_contractSize;
      return true;
     }
   virtual bool      MarginPerLot(const ENUM_LSR_DIRECTION dir, const double price, double &margin)
     {
      if(m_leverage <= 0.0)
         return false;
      margin = price * m_contractSize / m_leverage;
      return true;
     }
  };

//+------------------------------------------------------------------+
//| Volume helpers                                                   |
//+------------------------------------------------------------------+
int LSR_StepDigits(const double step)
  {
   int d = 0;
   double v = step;
   while(d < 8 && MathAbs(v - MathRound(v)) > 1e-9)
     {
      v *= 10.0;
      d++;
     }
   return d;
  }

//--- Rounds DOWN to the legal volume step (never up).
double LSR_FloorToVolumeStep(const double volume, const double step)
  {
   if(step <= 0.0 || volume <= 0.0)
      return 0.0;
   double steps = MathFloor(volume / step + 1e-9);
   return NormalizeDouble(steps * step, LSR_StepDigits(step));
  }

//+------------------------------------------------------------------+
struct LSR_SizingRequest
  {
   ENUM_LSR_DIRECTION dir;
   double             entry_quote;          // admission-time executable quote: Ask (long) / Bid (short)
   double             stop_price;           // valid broker-native stop
   double             risk_budget_currency; // DayRiskUnitCurrency (1R)
   double             free_margin;          // margin available to this context
  };

struct LSR_SizingResult
  {
   bool                   ok;
   ENUM_LSR_SIZING_REASON reason;
   double                 volume;
   double                 exec_entry_price;
   double                 worst_exit_price;
   int                    buffer_points;
   double                 path_loss_per_lot;
   double                 commission_per_lot;
   double                 worst_loss_per_lot;
   double                 worst_loss_currency;   // NewTradeWorstCaseLoss at the final volume
   double                 raw_volume;
   double                 margin_per_lot;
   double                 margin_required;
  };

void LSR_SizingResultReset(LSR_SizingResult &r)
  {
   r.ok = false;
   r.reason = LSR_SIZING_INVALID_INPUT;
   r.volume = 0.0;
   r.exec_entry_price = 0.0;
   r.worst_exit_price = 0.0;
   r.buffer_points = 0;
   r.path_loss_per_lot = 0.0;
   r.commission_per_lot = 0.0;
   r.worst_loss_per_lot = 0.0;
   r.worst_loss_currency = 0.0;
   r.raw_volume = 0.0;
   r.margin_per_lot = 0.0;
   r.margin_required = 0.0;
  }

//+------------------------------------------------------------------+
//| Solves volume so NewTradeWorstCaseLoss <= risk budget.           |
//+------------------------------------------------------------------+
bool LSR_SizePosition(const LSR_SizingRequest &req, const LSR_SymbolSpec &spec, const LSR_CostModel &costs,
                      const ENUM_LSR_STOP_PROFILE stopProfile, CLSR_SymbolEconomics &econ, LSR_SizingResult &r)
  {
   LSR_SizingResultReset(r);

   if(stopProfile == LSR_STOP_RESEARCH_MID)
     {
      // 4.5 requires a declared stop-execution spread buffer for MID sizing;
      // its value is not yet specified, so this is SPEC-INCOMPLETE (0B.13).
      r.reason = LSR_SIZING_SPEC_INCOMPLETE_MID_STOP;
      return false;
     }
   if(!(req.entry_quote > 0.0) || !(req.stop_price > 0.0) || !(req.risk_budget_currency > 0.0) || req.free_margin < 0.0)
     {
      r.reason = LSR_SIZING_INVALID_INPUT;
      return false;
     }

   double point = spec.point;
   double entrySlip = (costs.slippage_mode == LSR_SLIPPAGE_FIXED_ADVERSE_POINTS ? costs.entry_slippage_points * point : 0.0);
   r.buffer_points = LSR_DeclaredRiskExecutionBufferPoints(costs);
   double buffer = r.buffer_points * point;

   if(req.dir == LSR_DIR_LONG)
     {
      r.exec_entry_price = req.entry_quote + entrySlip;
      r.worst_exit_price = req.stop_price - buffer;
      if(!(req.stop_price < r.exec_entry_price))
        {
         r.reason = LSR_SIZING_INVALID_STOP_SIDE;
         return false;
        }
     }
   else
     {
      r.exec_entry_price = req.entry_quote - entrySlip;
      r.worst_exit_price = req.stop_price + buffer;
      if(!(req.stop_price > r.exec_entry_price))
        {
         r.reason = LSR_SIZING_INVALID_STOP_SIDE;
         return false;
        }
     }

   double pnl = 0.0;
   if(!econ.ProfitPerLot(req.dir, r.exec_entry_price, r.worst_exit_price, pnl) || !(pnl < 0.0))
     {
      r.reason = LSR_SIZING_ECONOMICS_UNAVAILABLE;
      return false;
     }
   r.path_loss_per_lot = -pnl;
   r.commission_per_lot = LSR_CommissionCurrency(costs, 1.0, LSR_CommissionContractSize(costs, spec), r.exec_entry_price);
   r.worst_loss_per_lot = r.path_loss_per_lot + r.commission_per_lot;

   r.raw_volume = req.risk_budget_currency / r.worst_loss_per_lot;
   double vol = LSR_FloorToVolumeStep(MathMin(r.raw_volume, spec.volume_max), spec.volume_step);
   if(vol + LSR_EPS < spec.volume_min)
     {
      r.reason = LSR_SIZING_VOLUME_BELOW_MIN;
      return false;
     }

   if(!econ.MarginPerLot(req.dir, r.exec_entry_price, r.margin_per_lot) || r.margin_per_lot < 0.0)
     {
      r.reason = LSR_SIZING_ECONOMICS_UNAVAILABLE;
      return false;
     }
   if(r.margin_per_lot > 0.0 && vol * r.margin_per_lot > req.free_margin + LSR_MONEY_EPS)
     {
      vol = LSR_FloorToVolumeStep(req.free_margin / r.margin_per_lot, spec.volume_step);
      if(vol + LSR_EPS < spec.volume_min)
        {
         r.reason = LSR_SIZING_INSUFFICIENT_MARGIN;
         return false;
        }
     }

   r.volume = vol;
   r.margin_required = vol * r.margin_per_lot;
   r.worst_loss_currency = vol * r.worst_loss_per_lot;
   r.ok = true;
   r.reason = LSR_SIZING_OK;
   return true;
  }

//+------------------------------------------------------------------+
//| Live execution-validity pre-check (OrderCheck).                  |
//+------------------------------------------------------------------+
bool LSR_OrderCheckMarket(const string symbol, const ENUM_LSR_DIRECTION dir, const double volume,
                          const double price, const double sl, const double tp, MqlTradeCheckResult &check)
  {
   MqlTradeRequest req;
   ZeroMemory(req);
   ZeroMemory(check);
   req.action = TRADE_ACTION_DEAL;
   req.symbol = symbol;
   req.volume = volume;
   req.type = (dir == LSR_DIR_LONG ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   req.price = price;
   req.sl = sl;
   req.tp = tp;
   return OrderCheck(req, check);
  }

#endif // LSR_SIZING_MQH
//+------------------------------------------------------------------+
