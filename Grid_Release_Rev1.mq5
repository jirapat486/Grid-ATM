//+------------------------------------------------------------------+
//|                          Grid Release (Production).mq5            |
//|  USOILm Grid EA - BuyStop only, Range-based, EMA H1 filter,       |
//|  Refill every 5 minutes aligned (00/05/10...), anti-duplicate,    |
//|  optional "top-up at one price" mode, optional chart EMA colors.  |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>
#include <Trade/DealInfo.mqh>

CTrade    trade;
CDealInfo m_deal;

// ===== Symbol / Magic =====
input string InpSymbol              = "USOILm";   // Broker symbol (e.g., USOILm)
input long   InpMagic               = 26637;      // EA identification no
input double InpLot                 = 0.01;       // Fixed lot

// ===== Grid settings =====
input group  "=== Grid Settings ===";
input double PriceMin               = 60.0;       // Range low
input double PriceMax               = 70.0;       // Range high
input int    StepPoints             = 500;        // Grid step (points)

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
input bool   UseIntegerLevels       = true;      // Use integer price levels (e.g., 70,69,68...)
input int    LevelStep              = 1;         // Integer level step (price units)
input int    ProfitPoints           = 1000;       // TP distance (points)
input int    FirstOffsetPoints      = 50;         // BuyStop start above Ask (points)
input int    PriceTolerancePts      = 30;         // "same level" tolerance (points)

// ===== Risk / Limits =====
input group  "=== Limits ===";
input int    MaxTotalTrades         = 30;         // Max (positions + pending) for this EA/symbol         // Max (positions + pending) for this EA/symbol
input int    MaxPlacePerRun         = 10;         // Max new pendings per 5-minute run (throttle)
input int    SlippagePoints         = 150;        // Deviation (points)

// ===== Trend filter (EMA) =====
input group  "=== Trend Filter (H1 EMA) ===";
input ENUM_TIMEFRAMES InpEMATF      = PERIOD_H1;  // EMA timeframe
input bool   UseTrendFilter         = true;       // Enable EMA filter
input int    EmaLongPeriod          = 200;        // EMA200
input int    EmaFastPeriod          = 3;          // EMA3
input int    EmaSlowPeriod          = 10;         // EMA10
input bool   UseClosedBar           = true;       // Use shift=1 (closed bar) to avoid flicker

// ===== Refill schedule (aligned) =====
input group  "=== Refill Schedule ===";
input int    RefillEveryMinutes     = 5;          // 5 minutes, aligned to :00,:05,:10...

// ===== Mode =====
enum ENUM_FILL_MODE
  {
   FILL_REBUILD_LEVELS = 0,   // Fill missing levels inside range (classic)
   FILL_TOPUP_ONEPRICE = 1    // Count missing levels and place all at one BuyStop price (aggressive)
  };
input group "=== Fill Mode ===";
input ENUM_FILL_MODE FillMode       = FILL_REBUILD_LEVELS;
input int    TopUpEntryOffsetPts    = 50;         // For TOPUP mode: entry = Ask + offset (points)

// ===== Optional: show EMA on chart with colors =====
input group "=== Chart Display (Optional) ===";
input bool   ShowEmaOnChart         = false;      // Add EMA indicators to chart
// Colors: EMA200 red, EMA10 blue, EMA3 green

// ===== Globals =====
int g_maxTotalTradesEffective = 0;
datetime g_nextRun = 0;
int hEma200 = INVALID_HANDLE;
int hEma3   = INVALID_HANDLE;
int hEma10  = INVALID_HANDLE;

// ===== Helpers =====
double Point_()  { return SymbolInfoDouble(InpSymbol, SYMBOL_POINT); }
//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int    Digits_() { return (int)SymbolInfoInteger(InpSymbol, SYMBOL_DIGITS); }
double N(double p) { return NormalizeDouble(p, Digits_()); }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsTradeAllowedNow()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int StopsLevelPoints()
  {
   int sl = (int)SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(sl < 0)
      sl = 0;
   return sl;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int FreezeLevelPoints()
  {
   int fl = (int)SymbolInfoInteger(InpSymbol, SYMBOL_TRADE_FREEZE_LEVEL);
   if(fl < 0)
      fl = 0;
   return fl;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool IsTooCloseToMarket(double entryPrice, ENUM_ORDER_TYPE orderType)
  {
   double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   int minPts = MathMax(StopsLevelPoints(), FreezeLevelPoints());
   double minDist = minPts * Point_();

   if(orderType == ORDER_TYPE_BUY_STOP)
      return (entryPrice <= ask + minDist);

// (BuyLimit is not used in this EA; kept for completeness)
   if(orderType == ORDER_TYPE_BUY_LIMIT)
      return (entryPrice >= ask - minDist);

   return true;
  }

// ---- Counting / duplicate checks (EA + symbol scoped) ----
int CountEA_Positions()
  {
   int total = 0;
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong t = PositionGetTicket(i);
      if(t==0)
         continue;
      if(!PositionSelectByTicket(t))
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol)
         continue;

      total++;
     }
   return total;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int CountEA_Pendings()
  {
   int total = 0;
   for(int i=0;i<OrdersTotal();i++)
     {
      ulong t = OrderGetTicket(i);
      if(t==0)
         continue;
      if(!OrderSelect(t))
         continue;

      if(OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != InpSymbol)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP)
         total++;
     }
   return total;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int CountEA_TotalActive()
  {
   return CountEA_Positions() + CountEA_Pendings();
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool PendingExistsNearPrice(double price)
  {
   double tol = PriceTolerancePts * Point_();
   for(int i=0;i<OrdersTotal();i++)
     {
      ulong t = OrderGetTicket(i);
      if(t==0)
         continue;
      if(!OrderSelect(t))
         continue;

      if(OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != InpSymbol)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_STOP)
         continue;

      double op = OrderGetDouble(ORDER_PRICE_OPEN);
      if(MathAbs(op - price) <= tol)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool PositionExistsNearPrice(double price)
  {
   double tol = PriceTolerancePts * Point_();
   for(int i=0;i<PositionsTotal();i++)
     {
      ulong t = PositionGetTicket(i);
      if(t==0)
         continue;
      if(!PositionSelectByTicket(t))
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol)
         continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(ptype != POSITION_TYPE_BUY)
         continue;

      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      if(MathAbs(op - price) <= tol)
         return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool ExistsOrderOrPositionAtPrice(double price)
  {
   price = N(price);
   if(PendingExistsNearPrice(price))
      return true;
   if(PositionExistsNearPrice(price))
      return true;
   return false;
  }


// ===== Integer Level Helpers =====
double SnapIntPrice(double price)
  {
// Round to nearest integer price, then normalize to symbol digits
   return N((double)MathRound(price));
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int TotalLevelsInteger()
  {
   int minL = (int)MathRound(PriceMin);
   int maxL = (int)MathRound(PriceMax);
   if(maxL < minL)
      return 0;
   return (maxL - minL) / MathMax(1, LevelStep) + 1; // inclusive
  }

// TopUp entry as integer price strictly ABOVE current Ask (BuyStop requirement)
double CalcTopUpEntry_Integer()
  {
   double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   int entryL = (int)MathCeil(ask);
   if((double)entryL <= ask)
      entryL++;
   return N((double)entryL);
  }

// Missing levels considered "active" from floor(Ask) up to PriceMax (inclusive), integer steps.
// This matches the user's expectation: at Ask~63, active levels are 63..70, not the whole 60..70.
int CalculateMissingActiveLevels_Integer()
  {
   int minL = (int)MathRound(PriceMin);
   int maxL = (int)MathRound(PriceMax);
   if(maxL < minL)
      return 0;

   double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);

   if(ask > (double)maxL)
      return 0; // market above range -> nothing to place in range

   int startL = (int)MathFloor(ask);
   if(startL < minL)
      startL = minL;

   int step = MathMax(1, LevelStep);

   int missing = 0;
   for(int lvl = startL; lvl <= maxL; lvl += step)
     {
      double p = N((double)lvl);
      if(!ExistsOrderOrPositionAtPrice(p))
         missing++;
     }
   return missing;
  }

// For TOPUP mode: allow multiple orders at same price; count how many already exist there.
int CountBuyStopsAtPrice(double price)
  {
   price = N(price);
   double tol = PriceTolerancePts * Point_();
   int count = 0;

   for(int i=0;i<OrdersTotal();i++)
     {
      ulong t = OrderGetTicket(i);
      if(t==0)
         continue;
      if(!OrderSelect(t))
         continue;

      if(OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != InpSymbol)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_STOP)
         continue;

      double op = OrderGetDouble(ORDER_PRICE_OPEN);
      if(MathAbs(op - price) <= tol)
         count++;
     }
   return count;
  }

// ===== EMA filter =====
bool InitEmaHandles()
  {
   hEma200 = iMA(InpSymbol, InpEMATF, EmaLongPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hEma3   = iMA(InpSymbol, InpEMATF, EmaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   hEma10  = iMA(InpSymbol, InpEMATF, EmaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);

   if(hEma200 == INVALID_HANDLE || hEma3 == INVALID_HANDLE || hEma10 == INVALID_HANDLE)
     {
      Print("ERROR: EMA handle init failed");
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool TrendFilterPass()
  {
   if(!UseTrendFilter)
      return true;
   if(hEma200 == INVALID_HANDLE || hEma3 == INVALID_HANDLE || hEma10 == INVALID_HANDLE)
      return false;

   double ema200[], ema3[], ema10[];
   int shift = UseClosedBar ? 1 : 0;

   if(CopyBuffer(hEma200, 0, shift, 1, ema200) <= 0)
      return false;
   if(CopyBuffer(hEma3,   0, shift, 1, ema3)   <= 0)
      return false;
   if(CopyBuffer(hEma10,  0, shift, 1, ema10)  <= 0)
      return false;

   double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);

   return (ask > ema200[0] && ema3[0] > ema10[0]);
  }

// ===== Timer alignment =====
datetime CalcNextAlignedRun(int everyMinutes)
  {
   datetime now = TimeCurrent();
   int interval = everyMinutes * 60;
   datetime next = ((now / interval) + 1) * interval;
   return next;
  }

// ===== Optional chart display =====
void AddEmaToChartIfEnabled()
  {
   if(!ShowEmaOnChart)
      return;

// Add to current chart main window
   long chart_id = ChartID();

// EMA200 red
   PlotIndexSetInteger(hEma200, 0, PLOT_LINE_COLOR, clrRed);
   ChartIndicatorAdd(chart_id, 0, hEma200);

// EMA10 blue
   PlotIndexSetInteger(hEma10, 0, PLOT_LINE_COLOR, clrBlue);
   ChartIndicatorAdd(chart_id, 0, hEma10);

// EMA3 green
   PlotIndexSetInteger(hEma3, 0, PLOT_LINE_COLOR, clrLime);
   ChartIndicatorAdd(chart_id, 0, hEma3);
  }

// ===== Core grid logic =====
int ExpectedLevelsInRange()
  {
   double stepPrice = StepPoints * Point_();
   if(stepPrice <= 0)
      return 0;

// inclusive-like count of discrete levels starting at PriceMin+step up to PriceMax
// (mirrors your original loop that starts from a computed start)
   int n = (int)MathFloor((PriceMax - PriceMin) / stepPrice);
   if(n < 0)
      n = 0;
   return n;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
bool PlaceBuyStop(double entry)
  {
   if(!IsTradeAllowedNow())
      return false;

   double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   if(entry <= ask)
      return false;

   if(IsTooCloseToMarket(entry, ORDER_TYPE_BUY_STOP))
      return false;

   double tp = N(entry + (ProfitPoints * Point_()));

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(SlippagePoints);

   bool ok = trade.BuyStop(InpLot, entry, InpSymbol, 0.0, tp, ORDER_TIME_GTC, 0, "GridBuyStop");
   if(!ok)
     {
      Print("BuyStop failed ret=", trade.ResultRetcode(),
            " desc=", trade.ResultRetcodeDescription(),
            " entry=", DoubleToString(entry, Digits_()));
     }
   return ok;
  }

// Mode A: Rebuild missing levels within range (BuyStop only)
void EnsureBuyStopGridInRange_Rebuild()
  {
   if(!TrendFilterPass())
      return;
   if(PriceMin <= 0 || PriceMax <= 0 || PriceMax <= PriceMin)
      return;
   if(ProfitPoints <= 0)
      return;

   int placed = 0;
   double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);

   if(UseIntegerLevels)
     {
      int minL = (int)MathRound(PriceMin);
      int maxL = (int)MathRound(PriceMax);
      int step = MathMax(1, LevelStep);

      // First level must be strictly above Ask for BuyStop. Start from ceil(ask)+offset (in integer levels).
      int startL = (int)MathCeil(ask);
      if((double)startL <= ask)
         startL++;
      // Also respect FirstOffsetPoints by converting it to price offset in points then snapping upward to int.
      double minStart = ask + (FirstOffsetPoints * Point_());
      if((double)startL < minStart)
         startL = (int)MathCeil(minStart);

      if(startL > maxL)
         return;

      for(int lvl = startL; lvl <= maxL; lvl += step)
        {
         if(CountEA_TotalActive() >= g_maxTotalTradesEffective)
            break;
         if(placed >= MaxPlacePerRun)
            break;

         double entry = N((double)lvl);

         if(ExistsOrderOrPositionAtPrice(entry))
            continue;

         if(PlaceBuyStop(entry))
            placed++;
        }
      return;
     }

// ---- points-based fallback (original) ----
   if(StepPoints <= 0)
      return;

   double point = Point_();
   int digits   = Digits_();
   double stepPrice = StepPoints * point;

// first entry must be above ask
   double start = PriceMin;
   double minStart = ask + (FirstOffsetPoints * point);
   if(start < minStart)
      start = minStart;
   if(start > PriceMax)
      return;

// align to grid based on PriceMin
   double k = MathCeil((start - PriceMin) / stepPrice);
   start = PriceMin + (k * stepPrice);
   start = NormalizeDouble(start, digits);

   for(double entry = start; entry <= PriceMax + (0.5 * stepPrice); entry += stepPrice)
     {
      if(CountEA_TotalActive() >= g_maxTotalTradesEffective)
         break;
      if(placed >= MaxPlacePerRun)
         break;

      entry = NormalizeDouble(entry, digits);
      if(entry <= ask)
         continue;

      if(ExistsOrderOrPositionAtPrice(entry))
         continue;

      if(PlaceBuyStop(entry))
         placed++;
     }
  }


// ===== Dynamic missing calculation (active levels from current price up to PriceMax) =====
// We count grid levels that are considered "active" given the current market price.
// Active range starts from the nearest grid level at-or-below current Ask, then goes up to PriceMax.
// Missing levels = levels in active range that do NOT have either (position or pending) at that level.
int CalculateMissingActiveLevels()
  {
   double stepPrice = StepPoints * Point_();
   if(stepPrice <= 0)
      return 0;

   double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);

// If market is above the max range, there are no active levels in the range.
   if(ask > PriceMax)
      return 0;

// Find nearest grid level at-or-below Ask, aligned to PriceMin
   double start = PriceMin;
   if(ask > PriceMin)
     {
      double k = MathFloor((ask - PriceMin) / stepPrice);
      start = PriceMin + (k * stepPrice);
     }
   start = N(start);

   int missing = 0;

   for(double lvl = start; lvl <= PriceMax + (0.5 * stepPrice); lvl += stepPrice)
     {
      lvl = N(lvl);

      if(lvl < PriceMin - (0.5 * stepPrice) || lvl > PriceMax + (0.5 * stepPrice))
         continue;

      if(!ExistsOrderOrPositionAtPrice(lvl))
         missing++;
     }

   return missing;
  }

// Mode B: Count missing and place all missing at ONE BuyStop price (Ask + offset)
void EnsureBuyStopGrid_TopUpOnePrice()
  {
   if(!TrendFilterPass())
      return;
   if(PriceMin <= 0 || PriceMax <= 0 || PriceMax <= PriceMin)
      return;
   if(ProfitPoints <= 0)
      return;

   int missing = 0;
   if(UseIntegerLevels)
      missing = CalculateMissingActiveLevels_Integer();
   else
      missing = CalculateMissingActiveLevels();

   if(missing <= 0)
      return;

   int current  = CountEA_TotalActive();
   int room = g_maxTotalTradesEffective - current;
   if(room <= 0)
      return;

   int toPlace = missing;
   toPlace = MathMin(toPlace, room);
   toPlace = MathMin(toPlace, MaxPlacePerRun);
   if(toPlace <= 0)
      return;

   double entry = 0.0;
   if(UseIntegerLevels)
      entry = CalcTopUpEntry_Integer();
   else
      entry = N(SymbolInfoDouble(InpSymbol, SYMBOL_ASK) + (TopUpEntryOffsetPts * Point_()));

// For this mode, we ALLOW multiple orders at same entry.
   for(int i=0;i<toPlace;i++)
     {
      if(CountEA_TotalActive() >= g_maxTotalTradesEffective)
         break;
      PlaceBuyStop(entry);
     }
  }


// ===== Exact TOPUP (integer levels based on existing highest) =====
double GetUpperBound_FromExistingOrMax()
  {
   double upper = PriceMax;

// positions
   for(int i=0; i<PositionsTotal(); i++)
     {
      ulong t = PositionGetTicket(i);
      if(t==0)
         continue;
      if(!PositionSelectByTicket(t))
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol)
         continue;

      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      if(op > upper)
         upper = op;
     }

// pendings (BuyStop)
   for(int i=0; i<OrdersTotal(); i++)
     {
      ulong t = OrderGetTicket(i);
      if(t==0)
         continue;
      if(!OrderSelect(t))
         continue;

      if(OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != InpSymbol)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_STOP)
         continue;

      double op = OrderGetDouble(ORDER_PRICE_OPEN);
      if(op > upper)
         upper = op;
     }

   if(upper > PriceMax)
      upper = PriceMax;
   return upper;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int CalcEntryLevel_Integer()
  {
   double ask = SymbolInfoDouble(InpSymbol, SYMBOL_ASK);
   int entryL = (int)MathCeil(ask);
   if((double)entryL <= ask)
      entryL++;
   return entryL;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int CountExistingInRange_IntLevels(int entryL, int upperL)
  {
   int count = 0;

// positions
   for(int i=0; i<PositionsTotal(); i++)
     {
      ulong t = PositionGetTicket(i);
      if(t==0)
         continue;
      if(!PositionSelectByTicket(t))
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != InpSymbol)
         continue;

      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      int lvl = (int)MathRound(op);

      if(lvl >= entryL && lvl <= upperL)
         count++;
     }

// pendings
   for(int i=0; i<OrdersTotal(); i++)
     {
      ulong t = OrderGetTicket(i);
      if(t==0)
         continue;
      if(!OrderSelect(t))
         continue;

      if(OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != InpSymbol)
         continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_STOP)
         continue;

      double op = OrderGetDouble(ORDER_PRICE_OPEN);
      int lvl = (int)MathRound(op);

      if(lvl >= entryL && lvl <= upperL)
         count++;
     }

   return count;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
int CalcMissingToTopUp_IntLevels()
  {
   int minL = (int)MathRound(PriceMin);
   int maxL = (int)MathRound(PriceMax);

   int entryL = CalcEntryLevel_Integer();
   if(entryL < minL)
      entryL = minL;
   if(entryL > maxL)
      return 0;

   double upper = GetUpperBound_FromExistingOrMax();
   int upperL = (int)MathRound(upper);
   if(upperL < entryL)
      return 0;

   int totalLevels = (upperL - entryL + 1);
   int existing = CountExistingInRange_IntLevels(entryL, upperL);

   int missing = totalLevels - existing;
   if(missing < 0)
      missing = 0;

   return missing;
  }

//+------------------------------------------------------------------+
//|     test                                                             |
//+------------------------------------------------------------------+
void EnsureBuyStopGrid_TopUpOnePrice_IntegerLogic()
  {
   if(!TrendFilterPass())
      return;

   int missing = CalcMissingToTopUp_IntLevels();
   if(missing <= 0)
      return;

   int toPlace = MathMin(missing, MaxPlacePerRun);
   if(toPlace <= 0)
      return;

   int entryL = CalcEntryLevel_Integer();
   double entry = N((double)entryL);

   if(IsTooCloseToMarket(entry, ORDER_TYPE_BUY_STOP))
      return;

   for(int i=0; i<toPlace; i++)
      PlaceBuyStop(entry);
  }
// ===== MT5 Events =====
int OnInit()
  {
   if(!SymbolSelect(InpSymbol, true))
     {
      Print("ERROR: SymbolSelect failed for ", InpSymbol);
      return INIT_FAILED;
     }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(SlippagePoints);

   if(!InitEmaHandles())
      return INIT_FAILED;

   AddEmaToChartIfEnabled();

// Set effective max trades: cap by total integer levels if enabled
   g_maxTotalTradesEffective = MaxTotalTrades;
   if(UseIntegerLevels)
     {
      int totalLevels = TotalLevelsInteger();
      if(totalLevels > 0)
         g_maxTotalTradesEffective = MathMin(g_maxTotalTradesEffective, totalLevels);
     }

   g_nextRun = CalcNextAlignedRun(RefillEveryMinutes);

// timer every second to hit aligned minutes exactly
   EventSetTimer(1);

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();

// Do NOT delete pending orders (per your requirement)

   if(hEma200 != INVALID_HANDLE)
      IndicatorRelease(hEma200);
   if(hEma3   != INVALID_HANDLE)
      IndicatorRelease(hEma3);
   if(hEma10  != INVALID_HANDLE)
      IndicatorRelease(hEma10);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnTimer()
  {
   datetime now = TimeCurrent();
   if(now < g_nextRun)
      return;

// Run once per aligned interval
   if(FillMode == FILL_REBUILD_LEVELS)
      EnsureBuyStopGridInRange_Rebuild();
   else
      EnsureBuyStopGrid_TopUpOnePrice_IntegerLogic();

   g_nextRun = CalcNextAlignedRun(RefillEveryMinutes);
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnTick()
  {
// Lightweight status display
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double profit  = AccountInfoDouble(ACCOUNT_PROFIT);

   Comment(
      "Symbol: ", InpSymbol, "\n",
      "Balance: ", DoubleToString(balance, 2), "  Equity: ", DoubleToString(equity, 2), "  Profit: ", DoubleToString(profit, 2), "\n",
      "EA Positions: ", CountEA_Positions(), "  EA Pendings: ", CountEA_Pendings(), "  EA Total: ", CountEA_TotalActive(), " / ", g_maxTotalTradesEffective, "\n",
      "FillMode: ", (FillMode==FILL_REBUILD_LEVELS ? "REBUILD_LEVELS" : "TOPUP_ONEPRICE"), "\n",
      "Next run (server): ", TimeToString(g_nextRun, TIME_DATE|TIME_MINUTES|TIME_SECONDS)
   );
  }

//+------------------------------------------------------------------+
//|                                                                  |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
  {
// Not used in this version (you can add TP-refill logic here if needed),
// because we refill on aligned timer every 5 minutes.
  }
//+------------------------------------------------------------------+
