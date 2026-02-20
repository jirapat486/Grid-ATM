//+------------------------------------------------------------------+
//|                                                          new.mq5 |
//|                                       Copyright 2026, JirapatFff |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, JirapatFff"
#property link      "https://www.mql5.com"
#property version   "1.36"

#include <Trade/Trade.mqh>

input group "Grid Buy Only"
input double InpLotSize          = 0.01;
input double InpMaxTradePrice    = 70.0;
input double InpMinTradePrice    = 60.0;
input int    InpGridStepPoints   = 1000;
input int    InpMaxBuyOrders     = 300;
input int    InpTakeProfitPoints = 1000;
input ulong  InpMagicNumber      = 20260201;
input int    InpSlippagePoints   = 20;
input int    InpDuplicateTolerancePoints = 10;

CTrade trade;
datetime g_nextRun = 0;

int CountEA_Positions();
int CountEA_Pendings();
int CountEA_TotalActive();
void UpdateStatusComment();
int CalculateBundledOrderCount(const double askPrice);
bool PlaceBundledStartOrder();

//+------------------------------------------------------------------+
//| Convert duplicate tolerance points to price distance             |
//+------------------------------------------------------------------+
double GetDuplicateTolerancePrice()
  {
   const double tolerance = InpDuplicateTolerancePoints * _Point;
   return MathMax(tolerance, _Point);
  }

//+------------------------------------------------------------------+
//| Normalize lot by symbol settings                                 |
//+------------------------------------------------------------------+
double NormalizeLot(const double lot)
  {
   const double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(stepLot <= 0.0)
      return MathMax(minLot, MathMin(lot, maxLot));

   const double fixedLot = MathFloor(lot / stepLot) * stepLot;
   return MathMax(minLot, MathMin(fixedLot, maxLot));
  }

//+------------------------------------------------------------------+
//| Check duplicated level from current buy positions                |
//+------------------------------------------------------------------+
bool HasBuyPositionAtLevel(const double levelPrice)
  {
   const double target = NormalizeDouble(levelPrice, _Digits);
   const double tolerance = GetDuplicateTolerancePrice();

   const int positionsTotal = PositionsTotal();
   for(int i = 0; i < positionsTotal; i++)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
         continue;

      const double openPrice = NormalizeDouble(PositionGetDouble(POSITION_PRICE_OPEN), _Digits);
      if(MathAbs(openPrice - target) <= tolerance)
         return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Check duplicated level from current pending buy orders           |
//+------------------------------------------------------------------+
bool HasPendingBuyOrderAtLevel(const double levelPrice)
  {
   const double target = NormalizeDouble(levelPrice, _Digits);
   const double tolerance = GetDuplicateTolerancePrice();

   const int ordersTotal = OrdersTotal();
   for(int i = 0; i < ordersTotal; i++)
     {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;

      const ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_STOP)
         continue;

      const double orderPrice = NormalizeDouble(OrderGetDouble(ORDER_PRICE_OPEN), _Digits);
      if(MathAbs(orderPrice - target) <= tolerance)
         return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Check duplicated level from current positions or pending orders  |
//+------------------------------------------------------------------+
bool HasOrderOrPositionAtLevel(const double levelPrice)
  {
   if(HasPendingBuyOrderAtLevel(levelPrice))
      return true;

   return HasBuyPositionAtLevel(levelPrice);
  }

//+------------------------------------------------------------------+
//| Count EA-owned buy positions + buy pending orders                |
//+------------------------------------------------------------------+
int CountActiveBuyExposure()
  {
   return CountEA_TotalActive();
  }


//+------------------------------------------------------------------+
//| Count EA-owned buy positions only                                |
//+------------------------------------------------------------------+
int CountEA_Positions()
  {
   int count = 0;
   const int positionsTotal = PositionsTotal();

   for(int i = 0; i < positionsTotal; i++)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         count++;
     }

   return count;
  }

//+------------------------------------------------------------------+
//| Count EA-owned buy stop pending orders only                      |
//+------------------------------------------------------------------+
int CountEA_Pendings()
  {
   int count = 0;
   const int ordersTotal = OrdersTotal();

   for(int i = 0; i < ordersTotal; i++)
     {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket))
         continue;

      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;

      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
         continue;

      const ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP)
         count++;
     }

   return count;
  }

//+------------------------------------------------------------------+
//| Count EA total active trades (positions + pending orders)        |
//+------------------------------------------------------------------+
int CountEA_TotalActive()
  {
   return CountEA_Positions() + CountEA_Pendings();
  }

//+------------------------------------------------------------------+
//| Lightweight status display on chart                              |
//+------------------------------------------------------------------+
void UpdateStatusComment()
  {
   const double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   const double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   const double profit  = AccountInfoDouble(ACCOUNT_PROFIT);

   const int eaPositions = CountEA_Positions();
   const int eaPendings  = CountEA_Pendings();
   const int eaTotal     = eaPositions + eaPendings;

   Comment(
      "Symbol: ", _Symbol, "\n",
      "Balance: ", DoubleToString(balance, 2),
      "  Equity: ", DoubleToString(equity, 2),
      "  Profit: ", DoubleToString(profit, 2), "\n",
      "EA Positions: ", eaPositions,
      "  EA Pendings: ", eaPendings,
      "  EA Total: ", eaTotal, " / ", InpMaxBuyOrders, "\n",
      "Duplicate tolerance: ", InpDuplicateTolerancePoints, " points\n",
      "Next run (server): ", TimeToString(g_nextRun, TIME_DATE|TIME_MINUTES|TIME_SECONDS)
   );
  }

//+------------------------------------------------------------------+
//| Place buy stop pending order only                                 |
//+------------------------------------------------------------------+
bool PlaceBuyPendingAtLevel(const double levelPrice)
  {
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(levelPrice <= 0.0 || ask <= 0.0)
      return false;

   const double price = NormalizeDouble(levelPrice, _Digits);
   if(HasOrderOrPositionAtLevel(price))
      return false;

   double tp = 0.0;
   if(InpTakeProfitPoints > 0)
      tp = NormalizeDouble(price + InpTakeProfitPoints * _Point, _Digits);

   const double lot = NormalizeLot(InpLotSize);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   bool sent = false;
   if(price > ask)
      sent = trade.BuyStop(lot, price, _Symbol, 0.0, tp, ORDER_TIME_GTC, 0, "USOIL Grid BuyStop");
   else
      return false;

   if(!sent)
     {
      PrintFormat("Pending order failed. level=%.2f retcode=%d (%s)",
                  price,
                  trade.ResultRetcode(),
                  trade.ResultRetcodeDescription());
      return false;
     }

   return true;
  }


//+------------------------------------------------------------------+
//| Calculate bundled count from max price to current ask            |
//+------------------------------------------------------------------+
int CalculateBundledOrderCount(const double askPrice)
  {
   if(askPrice <= 0.0)
      return 0;

   if(askPrice >= InpMaxTradePrice)
      return 0;

   const double distance = InpMaxTradePrice - askPrice;
   const int bundledCount = (int)MathCeil(distance);
   return MathMax(0, MathMin(bundledCount, InpMaxBuyOrders));
  }

//+------------------------------------------------------------------+
//| Open bundled startup pending order when no active order exists   |
//+------------------------------------------------------------------+
bool PlaceBundledStartOrder()
  {
   if(CountEA_TotalActive() > 0)
      return false;

   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(ask <= 0.0)
      return false;

   const int bundledCount = CalculateBundledOrderCount(ask);
   if(bundledCount <= 0)
      return false;

   const double levelPrice = NormalizeDouble(MathCeil(ask), _Digits);
   if(levelPrice > InpMaxTradePrice)
      return false;

   if(HasOrderOrPositionAtLevel(levelPrice))
      return false;

   const double bundledLot = NormalizeLot(InpLotSize * bundledCount);
   double tp = 0.0;
   if(InpTakeProfitPoints > 0)
      tp = NormalizeDouble(levelPrice + InpTakeProfitPoints * _Point, _Digits);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   const bool sent = trade.BuyStop(bundledLot,
                                   levelPrice,
                                   _Symbol,
                                   0.0,
                                   tp,
                                   ORDER_TIME_GTC,
                                   0,
                                   "USOIL Grid BundledStart");
   if(!sent)
     {
      PrintFormat("Bundled start order failed. level=%.2f count=%d lot=%.2f retcode=%d (%s)",
                  levelPrice,
                  bundledCount,
                  bundledLot,
                  trade.ResultRetcode(),
                  trade.ResultRetcodeDescription());
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Build pending grid from min to max trade price                   |
//+------------------------------------------------------------------+
void RefillPendingGrid()
  {
   const double stepPrice = InpGridStepPoints * _Point;
   if(stepPrice <= 0.0)
      return;

   int activeExposure = CountActiveBuyExposure();
   if(activeExposure >= InpMaxBuyOrders)
      return;

   const int steps = (int)MathFloor(((InpMaxTradePrice - InpMinTradePrice) / stepPrice) + 0.0000001);
   for(int idx = 0; idx <= steps; idx++)
     {
      if(activeExposure >= InpMaxBuyOrders)
         break;

      const double level = InpMinTradePrice + (idx * stepPrice);
      const double gridLevel = NormalizeDouble(level, _Digits);
      if(HasOrderOrPositionAtLevel(gridLevel))
         continue;

      if(PlaceBuyPendingAtLevel(gridLevel))
         activeExposure++;
     }
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpGridStepPoints <= 0)
      return INIT_PARAMETERS_INCORRECT;

   if(InpMaxBuyOrders <= 0)
      return INIT_PARAMETERS_INCORRECT;

   if(InpMinTradePrice >= InpMaxTradePrice)
      return INIT_PARAMETERS_INCORRECT;

   if(InpDuplicateTolerancePoints < 0)
      return INIT_PARAMETERS_INCORRECT;

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   g_nextRun = TimeCurrent();

   if(PlaceBundledStartOrder())
     {
      UpdateStatusComment();
      return;
     }

   RefillPendingGrid();
   UpdateStatusComment();
  }
//+------------------------------------------------------------------+
