//+------------------------------------------------------------------+
//|                                                          new.mq5 |
//|                                       Copyright 2026, JirapatFff |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, JirapatFff"
#property link      "https://www.mql5.com"
#property version   "1.31"

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

CTrade trade;

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
//| Check duplicated level from current positions or pending orders  |
//+------------------------------------------------------------------+
bool HasOrderOrPositionAtLevel(const double levelPrice)
  {
   const double tolerance = _Point * 0.5;

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

      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(openPrice - levelPrice) <= tolerance)
         return true;
     }

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

      const double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      if(MathAbs(orderPrice - levelPrice) <= tolerance)
         return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Count EA-owned buy positions + buy pending orders                |
//+------------------------------------------------------------------+
int CountActiveBuyExposure()
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
//| Place buy stop pending order only                                 |
//+------------------------------------------------------------------+
bool PlaceBuyPendingAtLevel(const double levelPrice)
  {
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(levelPrice <= 0.0 || ask <= 0.0)
      return false;

   const double price = NormalizeDouble(levelPrice, _Digits);
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

   for(double level = InpMinTradePrice; level <= InpMaxTradePrice + (stepPrice * 0.1); level += stepPrice)
     {
      if(activeExposure >= InpMaxBuyOrders)
         break;

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
   RefillPendingGrid();
  }
//+------------------------------------------------------------------+
