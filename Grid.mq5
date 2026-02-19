//+------------------------------------------------------------------+
//|                                                         Grid.mq5 |
//|                                       Copyright 2026, JirapatFff |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, JirapatFff"
#property link      "https://www.mql5.com"
#property version   "1.21"

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
//| Read current grid status for this EA                             |
//+------------------------------------------------------------------+
void GetGridStatus(int &buyCount, double &lowestBuyPrice)
  {
   buyCount = 0;
   lowestBuyPrice = 0.0;

   const int total = PositionsTotal();
   for(int i = 0; i < total; i++)
     {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
         continue;

      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
         continue;

      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      buyCount++;

      if(lowestBuyPrice == 0.0 || openPrice < lowestBuyPrice)
         lowestBuyPrice = openPrice;
     }
  }


//+------------------------------------------------------------------+
//| Check current price is in allowed trade zone                     |
//+------------------------------------------------------------------+
bool IsInTradeZone(const double price)
  {
   return (price >= InpMinTradePrice && price <= InpMaxTradePrice);
  }

//+------------------------------------------------------------------+
//| Open buy order                                                   |
//+------------------------------------------------------------------+
bool OpenBuyOrder()
  {
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double tp = 0.0;

   if(InpTakeProfitPoints > 0)
      tp = NormalizeDouble(ask + InpTakeProfitPoints * _Point, _Digits);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   const double lot = NormalizeLot(InpLotSize);
   if(!trade.Buy(lot, _Symbol, 0.0, 0.0, tp, "USOIL Grid Buy"))
     {
      PrintFormat("Buy failed. retcode=%d (%s)", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
     }

   PrintFormat("Buy opened. lot=%.2f price=%.2f", lot, ask);
   return true;
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
   int buyCount = 0;
   double lowestBuyPrice = 0.0;
   GetGridStatus(buyCount, lowestBuyPrice);

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(!IsInTradeZone(bid))
      return;

   // เปิดออเดอร์แรกถ้ายังไม่มีออเดอร์ Buy ของ EA นี้
   if(buyCount == 0)
     {
      OpenBuyOrder();
      return;
     }

   if(buyCount >= InpMaxBuyOrders)
      return;

   const double nextGridLevel = lowestBuyPrice - InpGridStepPoints * _Point;

   // Grid Buy only: ราคาไหลลงถึงระยะ grid ให้เปิด Buy เพิ่ม
   if(bid <= nextGridLevel)
      OpenBuyOrder();
  }
//+------------------------------------------------------------------+
