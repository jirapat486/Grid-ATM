//+------------------------------------------------------------------+
//|                                                         Grid.mq5 |
//|                                       Copyright 2026, JirapatFff |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, JirapatFff"
#property link      "https://www.mql5.com"
#property version   "1.31"

#include <Trade/Trade.mqh>

input group "Signal setup"
input ENUM_TIMEFRAMES InpTimeframe       = PERIOD_H1;
input int             InpTrendEMAPeriod  = 200;
input int             InpFastEMAPeriod   = 3;
input int             InpSlowEMAPeriod   = 10;

input group "Order setup"
input double          InpBaseLot         = 0.01;
input int             InpGridStepPoints  = 300;
input bool            InpUseIntegerGrid  = true;
input double          InpIntegerGridStep = 1.0;
input int             InpTakeProfitPoints= 600;
input int             InpMaxMissedOrders = 6;
input ulong           InpMagicNumber     = 26012026;
input int             InpSlippagePoints  = 20;

input group "Trade zone (price filter)"
input double          InpMinTradePrice   = 60.0;
input double          InpMaxTradePrice   = 70.0;

CTrade trade;

int      trendHandle            = INVALID_HANDLE;
int      fastHandle             = INVALID_HANDLE;
int      slowHandle             = INVALID_HANDLE;
datetime lastProcessedBarTime   = 0;
double   accumulationAnchorPrice= 0.0;
int      missedOrderCount       = 0;

//+------------------------------------------------------------------+
//| Check price is within trade range                                |
//+------------------------------------------------------------------+
bool IsPriceInTradeRange(const double price)
  {
   if(InpMinTradePrice > 0.0 && price < InpMinTradePrice)
      return false;

   if(InpMaxTradePrice > 0.0 && price > InpMaxTradePrice)
      return false;

   return true;
  }

//+------------------------------------------------------------------+
//| Normalize lot to symbol constraints                              |
//+------------------------------------------------------------------+
double NormalizeLot(const double lot)
  {
   const double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0.0)
      return MathMax(minLot, MathMin(lot, maxLot));

   const double steppedLot = MathFloor(lot / lotStep) * lotStep;
   return MathMax(minLot, MathMin(steppedLot, maxLot));
  }

//+------------------------------------------------------------------+
//| Count missed orders while market is in pause/down mode           |
//+------------------------------------------------------------------+
void TrackMissedOrders(const double bidPrice)
  {
   if(accumulationAnchorPrice <= 0.0)
      return;

   if(missedOrderCount >= InpMaxMissedOrders)
      return;

   double stepInPrice = InpGridStepPoints * _Point;
   double anchorBase  = accumulationAnchorPrice;

   // โหมดกริดแบบเลขจำนวนเต็มราคา เช่น 70, 69, 68, ...
   if(InpUseIntegerGrid)
     {
      if(InpIntegerGridStep <= 0.0)
         return;

      stepInPrice = InpIntegerGridStep;
      anchorBase  = MathFloor(accumulationAnchorPrice);
     }

   if(stepInPrice <= 0.0)
      return;

   while(missedOrderCount < InpMaxMissedOrders)
     {
      const double nextLevel = anchorBase - stepInPrice * (missedOrderCount + 1);
      if(bidPrice <= nextLevel)
         missedOrderCount++;
      else
         break;
     }
  }

//+------------------------------------------------------------------+
//| Open one bundled order when signal appears                       |
//+------------------------------------------------------------------+
bool OpenBundledOrder(const int bundleSize)
  {
   if(bundleSize <= 0)
      return false;

   const double volume = NormalizeLot(InpBaseLot * bundleSize);
   const double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double tpPrice      = 0.0;

   if(InpTakeProfitPoints > 0)
      tpPrice = NormalizeDouble(ask + InpTakeProfitPoints * _Point, _Digits);

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippagePoints);

   if(!trade.Buy(volume, _Symbol, 0.0, 0.0, tpPrice, "Grid bundle entry"))
     {
      PrintFormat("Buy failed. retcode=%d, description=%s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
     }

   return true;
  }

//+------------------------------------------------------------------+
//| Read indicator values safely                                     |
//+------------------------------------------------------------------+
bool ReadEMAValues(double &trendNow, double &fastPrev, double &fastNow, double &slowPrev, double &slowNow)
  {
   double trendBuff[1];
   double fastBuff[2];
   double slowBuff[2];

   if(CopyBuffer(trendHandle, 0, 0, 1, trendBuff) != 1)
      return false;

   if(CopyBuffer(fastHandle, 0, 0, 2, fastBuff) != 2)
      return false;

   if(CopyBuffer(slowHandle, 0, 0, 2, slowBuff) != 2)
      return false;

   trendNow = trendBuff[0];
   fastNow  = fastBuff[0];
   fastPrev = fastBuff[1];
   slowNow  = slowBuff[0];
   slowPrev = slowBuff[1];
   return true;
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpMinTradePrice > 0.0 && InpMaxTradePrice > 0.0 && InpMinTradePrice >= InpMaxTradePrice)
     {
      Print("Invalid trade zone: MinTradePrice must be less than MaxTradePrice");
      return INIT_PARAMETERS_INCORRECT;
     }

   if(InpUseIntegerGrid && InpIntegerGridStep <= 0.0)
     {
      Print("Invalid grid setup: InpIntegerGridStep must be greater than 0");
      return INIT_PARAMETERS_INCORRECT;
     }

   trendHandle = iMA(_Symbol, InpTimeframe, InpTrendEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   fastHandle  = iMA(_Symbol, InpTimeframe, InpFastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   slowHandle  = iMA(_Symbol, InpTimeframe, InpSlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(trendHandle == INVALID_HANDLE || fastHandle == INVALID_HANDLE || slowHandle == INVALID_HANDLE)
     {
      Print("Unable to create EMA handles");
      return INIT_FAILED;
     }

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(trendHandle != INVALID_HANDLE)
      IndicatorRelease(trendHandle);

   if(fastHandle != INVALID_HANDLE)
      IndicatorRelease(fastHandle);

   if(slowHandle != INVALID_HANDLE)
      IndicatorRelease(slowHandle);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime barTime = iTime(_Symbol, InpTimeframe, 0);
   if(barTime == 0 || barTime == lastProcessedBarTime)
      return;

   lastProcessedBarTime = barTime;

   double trendNow = 0.0, fastPrev = 0.0, fastNow = 0.0, slowPrev = 0.0, slowNow = 0.0;
   if(!ReadEMAValues(trendNow, fastPrev, fastNow, slowPrev, slowNow))
      return;

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(!IsPriceInTradeRange(bid))
      return;

   const bool trendReady = (bid > trendNow);
   const bool bullishCross = (fastPrev <= slowPrev && fastNow > slowNow);

   // เก็บจำนวนออเดอร์ที่ไม่ได้เปิดไว้ระหว่างตลาดพักตัว/ขาลง
   if(!trendReady || fastNow <= slowNow)
      TrackMissedOrders(bid);

   // เมื่อกลับมามีแนวโน้มขึ้นและเกิดสัญญาณตัดขึ้น ให้รวบเป็นออเดอร์เดียว
   if(trendReady && bullishCross)
     {
      if(accumulationAnchorPrice <= 0.0)
         accumulationAnchorPrice = ask;

      const int bundleSize = 1 + missedOrderCount;
      if(OpenBundledOrder(bundleSize))
        {
         PrintFormat("Bundled BUY opened. bundle_size=%d, missed=%d, price=%.2f", bundleSize, missedOrderCount, ask);
         missedOrderCount = 0;
         accumulationAnchorPrice = ask;
        }
     }
  }
//+------------------------------------------------------------------+
