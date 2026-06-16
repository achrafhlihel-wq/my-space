//+------------------------------------------------------------------+
//|                                          ICT_SmartMoney_EA.mq5   |
//|                        ICT Smart Money Concepts Expert Advisor    |
//|                              For MetaTrader 5 - Backtesting Ready |
//+------------------------------------------------------------------+
#property copyright "ICT SMC Bot"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+
// === General Settings ===
input string   InpSymbol1        = "EURUSD";        // Symbol 1
input string   InpSymbol2        = "XAUUSD";        // Symbol 2
input ENUM_TIMEFRAMES InpEntryTF = PERIOD_M15;      // Entry Timeframe
input ENUM_TIMEFRAMES InpTrendTF = PERIOD_H1;       // Trend Timeframe
input int      InpMagicNumber    = 123456;          // Magic Number

// === Risk Management ===
input double   InpRiskPercent    = 1.0;             // Risk % per trade
input int      InpMaxTradesDay   = 3;              // Max trades per day
input double   InpMaxDailyLoss   = 3.0;            // Max daily loss %
input int      InpMaxTradesPerPair = 1;            // Max trades per pair

// === Stop Loss Safety Margin ===
input int      InpSL_MarginEU    = 5;              // SL margin EURUSD (points)
input int      InpSL_MarginGold  = 50;             // SL margin XAUUSD (points)

// === Take Profit ===
input double   InpRR_Ratio       = 3.0;            // Risk:Reward ratio
input bool     InpUsePartialClose = true;          // Use partial close at 2:1
input double   InpPartialPercent = 50.0;           // Partial close %

// === Time Filter (Server Time) ===
input int      InpLondonStart    = 8;              // London session start hour
input int      InpLondonEnd      = 12;             // London session end hour
input int      InpNYStart        = 13;             // NY session start hour
input int      InpNYEnd          = 15;             // NY first 2 hours end

// === News Filter ===
input int      InpNewsMinutes    = 30;             // Minutes before/after news

// === Quality Filters ===
input double   InpMaxSpread      = 30.0;           // Max spread (points)
input int      InpATR_Period     = 14;             // ATR period
input double   InpMinATR_Multi   = 0.5;            // Min ATR multiplier
input double   InpMaxWickRatio   = 0.7;            // Max wick ratio filter

// === Scoring System ===
input int      InpMinScore       = 80;             // Minimum score to trade


// === Structure Detection ===
input int      InpSwingLookback  = 5;              // Swing point lookback bars
input double   InpEqualLevel_Pips = 3.0;           // Equal highs/lows tolerance (pips)
input int      InpLiquidityBars  = 50;             // Bars to look for liquidity levels
input int      InpFVG_MinSize    = 5;              // Min FVG size (points)

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

// Trend state
enum ENUM_TREND { TREND_BULLISH, TREND_BEARISH, TREND_RANGING };

// Structure for swing points
struct SwingPoint {
   double price;
   datetime time;
   int barIndex;
   bool isHigh;  // true = high, false = low
};

// Structure for liquidity levels
struct LiquidityLevel {
   double price;
   datetime time;
   bool isHigh;       // true = resistance, false = support
   bool isSwept;      // has been swept
   datetime sweepTime;
};

// Structure for FVG
struct FairValueGap {
   double top;
   double bottom;
   datetime time;
   bool isBullish;    // true = bullish FVG (gap up), false = bearish FVG
   bool isFilled;
};

// Structure for Order Block
struct OrderBlock {
   double top;
   double bottom;
   datetime time;
   bool isBullish;    // true = bullish OB (last bearish before move up)
   bool isUsed;
};


// Structure for MSS
struct MarketStructureShift {
   bool detected;
   bool isBullish;
   double breakLevel;
   datetime time;
   int barIndex;
};

// Structure for trade signal
struct TradeSignal {
   bool valid;
   bool isBuy;
   double entryPrice;
   double stopLoss;
   double takeProfit;
   int score;
   string reason;
};

// Global state arrays
SwingPoint     g_swingPoints[];
LiquidityLevel g_liquidityLevels[];
FairValueGap   g_fvgZones[];
OrderBlock     g_orderBlocks[];

// Daily tracking
int            g_todayTrades = 0;
double         g_todayPnL = 0.0;
datetime       g_lastTradeDay = 0;
bool           g_dailyLimitHit = false;

// News filter (manual times - can be enhanced with calendar)
datetime       g_newsTime = 0;
bool           g_newsActive = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(10);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   Print("ICT Smart Money EA initialized");
   Print("Entry TF: ", EnumToString(InpEntryTF));
   Print("Trend TF: ", EnumToString(InpTrendTF));
   Print("Min Score: ", InpMinScore);
   
   return(INIT_SUCCEEDED);
}


//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("ICT Smart Money EA removed. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Process each symbol
   string symbols[];
   int symCount = 0;
   
   if(StringLen(InpSymbol1) > 0) { ArrayResize(symbols, symCount+1); symbols[symCount] = InpSymbol1; symCount++; }
   if(StringLen(InpSymbol2) > 0) { ArrayResize(symbols, symCount+1); symbols[symCount] = InpSymbol2; symCount++; }
   
   for(int s = 0; s < symCount; s++)
   {
      ProcessSymbol(symbols[s]);
   }
   
   // Manage open positions (BE, partial close)
   ManageOpenPositions();
}

//+------------------------------------------------------------------+
//| MAIN PROCESSING FUNCTION PER SYMBOL                              |
//+------------------------------------------------------------------+
void ProcessSymbol(string symbol)
{
   // Check if new bar on entry timeframe
   static datetime lastBar[];
   static bool initialized = false;
   if(!initialized) { ArrayResize(lastBar, 2); lastBar[0] = 0; lastBar[1] = 0; initialized = true; }
   
   int idx = (symbol == InpSymbol1) ? 0 : 1;
   datetime currentBar = iTime(symbol, InpEntryTF, 0);
   if(currentBar == lastBar[idx]) return;
   lastBar[idx] = currentBar;
   
   // Reset daily counters
   ResetDailyCounters();
   
   // Check daily limits
   if(g_dailyLimitHit) return;
   if(g_todayTrades >= InpMaxTradesDay) return;
   
   // Check if position already exists for this pair
   if(CountPositions(symbol) >= InpMaxTradesPerPair) return;
   
   // Time filter
   if(!IsWithinTradingSession()) return;
   
   // Quality filters
   if(!PassQualityFilters(symbol)) return;
   
   // === PHASE 1: Determine H1 Trend ===
   ENUM_TREND trend = DetectTrend(symbol);
   if(trend == TREND_RANGING) return;
   
   // === PHASE 2: Detect Liquidity Levels & Sweep ===
   bool liquiditySwept = false;
   double sweepLevel = 0;
   liquiditySwept = DetectLiquiditySweep(symbol, trend, sweepLevel);
   if(!liquiditySwept) return;


   // === PHASE 3: Detect MSS ===
   MarketStructureShift mss;
   mss = DetectMSS(symbol, trend);
   if(!mss.detected) return;
   
   // === PHASE 4: Find Entry Zone (FVG / Order Block) ===
   double entryZoneTop = 0, entryZoneBottom = 0;
   bool hasFVG = false, hasOB = false;
   hasFVG = FindFVG(symbol, trend, entryZoneTop, entryZoneBottom);
   hasOB = FindOrderBlock(symbol, trend, entryZoneTop, entryZoneBottom);
   
   if(!hasFVG && !hasOB) return;
   
   // === PHASE 5: Entry Confirmation ===
   bool confirmed = CheckEntryConfirmation(symbol, trend);
   if(!confirmed) return;
   
   // === SCORING SYSTEM ===
   int score = CalculateScore(trend, liquiditySwept, mss.detected, hasFVG, hasOB);
   if(score < InpMinScore) return;
   
   // === EXECUTE TRADE ===
   TradeSignal signal;
   signal.valid = true;
   signal.isBuy = (trend == TREND_BULLISH);
   signal.score = score;
   
   // Calculate SL and TP
   double slMargin = GetSLMargin(symbol);
   if(signal.isBuy)
   {
      signal.stopLoss = sweepLevel - slMargin;
      signal.entryPrice = SymbolInfoDouble(symbol, SYMBOL_ASK);
      double risk = signal.entryPrice - signal.stopLoss;
      signal.takeProfit = signal.entryPrice + (risk * InpRR_Ratio);
   }
   else
   {
      signal.stopLoss = sweepLevel + slMargin;
      signal.entryPrice = SymbolInfoDouble(symbol, SYMBOL_BID);
      double risk = signal.stopLoss - signal.entryPrice;
      signal.takeProfit = signal.entryPrice - (risk * InpRR_Ratio);
   }
   
   // Calculate lot size
   double lotSize = CalculateLotSize(symbol, MathAbs(signal.entryPrice - signal.stopLoss));
   if(lotSize <= 0) return;
   
   // Execute
   if(signal.isBuy)
      trade.Buy(lotSize, symbol, signal.entryPrice, signal.stopLoss, signal.takeProfit, 
                StringFormat("ICT Buy | Score:%d", score));
   else
      trade.Sell(lotSize, symbol, signal.entryPrice, signal.stopLoss, signal.takeProfit,
                 StringFormat("ICT Sell | Score:%d", score));
   
   if(trade.ResultRetcode() == TRADE_RETCODE_DONE)
   {
      g_todayTrades++;
      Print(StringFormat("Trade opened: %s %s | Score: %d | SL: %.5f | TP: %.5f",
            signal.isBuy ? "BUY" : "SELL", symbol, score, signal.stopLoss, signal.takeProfit));
   }
}


//+------------------------------------------------------------------+
//| PHASE 1: TREND DETECTION ON H1                                   |
//+------------------------------------------------------------------+
ENUM_TREND DetectTrend(string symbol)
{
   // Get H1 swing points
   double highs[], lows[];
   ArrayResize(highs, 4);
   ArrayResize(lows, 4);
   
   int count = 0;
   int lookback = InpSwingLookback;
   
   // Find last 4 swing highs and 4 swing lows on H1
   int swingHighs = 0, swingLows = 0;
   
   for(int i = lookback; i < 100 && (swingHighs < 4 || swingLows < 4); i++)
   {
      if(swingHighs < 4 && IsSwingHigh(symbol, InpTrendTF, i, lookback))
      {
         highs[swingHighs] = iHigh(symbol, InpTrendTF, i);
         swingHighs++;
      }
      if(swingLows < 4 && IsSwingLow(symbol, InpTrendTF, i, lookback))
      {
         lows[swingLows] = iLow(symbol, InpTrendTF, i);
         swingLows++;
      }
   }
   
   if(swingHighs < 2 || swingLows < 2) return TREND_RANGING;
   
   // Check for Higher Highs and Higher Lows (Bullish)
   // Note: index 0 = most recent swing
   bool higherHighs = (highs[0] > highs[1]);
   bool higherLows  = (lows[0] > lows[1]);
   
   // Check for Lower Highs and Lower Lows (Bearish)
   bool lowerHighs = (highs[0] < highs[1]);
   bool lowerLows  = (lows[0] < lows[1]);
   
   if(higherHighs && higherLows) return TREND_BULLISH;
   if(lowerHighs && lowerLows)   return TREND_BEARISH;
   
   return TREND_RANGING;
}

//+------------------------------------------------------------------+
//| Swing High Detection                                             |
//+------------------------------------------------------------------+
bool IsSwingHigh(string symbol, ENUM_TIMEFRAMES tf, int bar, int lookback)
{
   double high = iHigh(symbol, tf, bar);
   for(int i = 1; i <= lookback; i++)
   {
      if(iHigh(symbol, tf, bar - i) >= high) return false;
      if(iHigh(symbol, tf, bar + i) >= high) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Swing Low Detection                                              |
//+------------------------------------------------------------------+
bool IsSwingLow(string symbol, ENUM_TIMEFRAMES tf, int bar, int lookback)
{
   double low = iLow(symbol, tf, bar);
   for(int i = 1; i <= lookback; i++)
   {
      if(iLow(symbol, tf, bar - i) <= low) return false;
      if(iLow(symbol, tf, bar + i) <= low) return false;
   }
   return true;
}


//+------------------------------------------------------------------+
//| PHASE 2: LIQUIDITY DETECTION & SWEEP                             |
//+------------------------------------------------------------------+
bool DetectLiquiditySweep(string symbol, ENUM_TREND trend, double &sweepLevel)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tolerance = InpEqualLevel_Pips * 10 * point; // Convert pips to price
   
   // Find liquidity levels on entry timeframe
   // Look for: Equal Highs, Equal Lows, Previous session H/L
   
   // --- Equal Highs / Equal Lows ---
   for(int i = InpSwingLookback; i < InpLiquidityBars; i++)
   {
      if(trend == TREND_BULLISH)
      {
         // For buys, look for equal lows that got swept
         if(IsSwingLow(symbol, InpEntryTF, i, InpSwingLookback))
         {
            double swLow = iLow(symbol, InpEntryTF, i);
            
            // Check if there's another equal low nearby
            for(int j = i + 1; j < InpLiquidityBars; j++)
            {
               if(IsSwingLow(symbol, InpEntryTF, j, InpSwingLookback))
               {
                  double swLow2 = iLow(symbol, InpEntryTF, j);
                  if(MathAbs(swLow - swLow2) <= tolerance)
                  {
                     // Equal lows found - check for sweep
                     // Sweep = price went below then closed back above
                     double recentLow = iLow(symbol, InpEntryTF, 1);
                     double recentClose = iClose(symbol, InpEntryTF, 1);
                     
                     if(recentLow < swLow && recentClose > swLow)
                     {
                        sweepLevel = swLow;
                        return true;
                     }
                  }
               }
            }
            
            // Also check single swing low sweep
            double recentLow = iLow(symbol, InpEntryTF, 1);
            double recentClose = iClose(symbol, InpEntryTF, 1);
            if(recentLow < swLow - tolerance && recentClose > swLow)
            {
               sweepLevel = swLow;
               return true;
            }
         }
      }
      else if(trend == TREND_BEARISH)
      {
         // For sells, look for equal highs that got swept
         if(IsSwingHigh(symbol, InpEntryTF, i, InpSwingLookback))
         {
            double swHigh = iHigh(symbol, InpEntryTF, i);
            
            // Check for equal high
            for(int j = i + 1; j < InpLiquidityBars; j++)
            {
               if(IsSwingHigh(symbol, InpEntryTF, j, InpSwingLookback))
               {
                  double swHigh2 = iHigh(symbol, InpEntryTF, j);
                  if(MathAbs(swHigh - swHigh2) <= tolerance)
                  {
                     double recentHigh = iHigh(symbol, InpEntryTF, 1);
                     double recentClose = iClose(symbol, InpEntryTF, 1);
                     
                     if(recentHigh > swHigh && recentClose < swHigh)
                     {
                        sweepLevel = swHigh;
                        return true;
                     }
                  }
               }
            }
            
            // Single swing high sweep
            double recentHigh = iHigh(symbol, InpEntryTF, 1);
            double recentClose = iClose(symbol, InpEntryTF, 1);
            if(recentHigh > swHigh + tolerance && recentClose < swHigh)
            {
               sweepLevel = swHigh;
               return true;
            }
         }
      }
   }


   // --- Previous Session High/Low Sweep ---
   // Find previous day's high/low
   double prevDayHigh = 0, prevDayLow = 99999;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   for(int i = 1; i < 200; i++)
   {
      MqlDateTime barDt;
      TimeToStruct(iTime(symbol, InpEntryTF, i), barDt);
      
      // Previous day bars
      if(barDt.day != dt.day)
      {
         double h = iHigh(symbol, InpEntryTF, i);
         double l = iLow(symbol, InpEntryTF, i);
         if(h > prevDayHigh) prevDayHigh = h;
         if(l < prevDayLow)  prevDayLow = l;
         
         // Stop after we've gone back one full day
         MqlDateTime prevBarDt;
         if(i+1 < 200)
         {
            TimeToStruct(iTime(symbol, InpEntryTF, i+1), prevBarDt);
            if(prevBarDt.day != barDt.day && prevDayHigh > 0) break;
         }
      }
   }
   
   // Check sweep of previous session levels
   if(trend == TREND_BULLISH && prevDayLow < 99999)
   {
      double recentLow = iLow(symbol, InpEntryTF, 1);
      double recentClose = iClose(symbol, InpEntryTF, 1);
      if(recentLow < prevDayLow && recentClose > prevDayLow)
      {
         sweepLevel = prevDayLow;
         return true;
      }
   }
   else if(trend == TREND_BEARISH && prevDayHigh > 0)
   {
      double recentHigh = iHigh(symbol, InpEntryTF, 1);
      double recentClose = iClose(symbol, InpEntryTF, 1);
      if(recentHigh > prevDayHigh && recentClose < prevDayHigh)
      {
         sweepLevel = prevDayHigh;
         return true;
      }
   }
   
   return false;
}


//+------------------------------------------------------------------+
//| PHASE 3: MARKET STRUCTURE SHIFT (MSS) DETECTION                  |
//+------------------------------------------------------------------+
MarketStructureShift DetectMSS(string symbol, ENUM_TREND trend)
{
   MarketStructureShift mss;
   mss.detected = false;
   mss.isBullish = false;
   mss.breakLevel = 0;
   mss.time = 0;
   mss.barIndex = 0;
   
   // MSS = After liquidity sweep, price breaks internal structure
   // Bullish MSS: breaks above last internal swing high
   // Bearish MSS: breaks below last internal swing low
   
   // Find internal structure on entry TF (last 20 bars after sweep)
   if(trend == TREND_BULLISH)
   {
      // Find last internal swing high
      double lastSwingHigh = 0;
      int shBar = 0;
      
      for(int i = 2; i < 20; i++)
      {
         if(IsSwingHigh(symbol, InpEntryTF, i, 2))
         {
            lastSwingHigh = iHigh(symbol, InpEntryTF, i);
            shBar = i;
            break;
         }
      }
      
      if(lastSwingHigh == 0) return mss;
      
      // Check if current/last bar broke above this swing high
      double currentHigh = iHigh(symbol, InpEntryTF, 1);
      double currentClose = iClose(symbol, InpEntryTF, 1);
      
      if(currentClose > lastSwingHigh)
      {
         mss.detected = true;
         mss.isBullish = true;
         mss.breakLevel = lastSwingHigh;
         mss.time = iTime(symbol, InpEntryTF, 1);
         mss.barIndex = 1;
      }
   }
   else if(trend == TREND_BEARISH)
   {
      // Find last internal swing low
      double lastSwingLow = 0;
      int slBar = 0;
      
      for(int i = 2; i < 20; i++)
      {
         if(IsSwingLow(symbol, InpEntryTF, i, 2))
         {
            lastSwingLow = iLow(symbol, InpEntryTF, i);
            slBar = i;
            break;
         }
      }
      
      if(lastSwingLow == 0) return mss;
      
      // Check if current/last bar broke below this swing low
      double currentLow = iLow(symbol, InpEntryTF, 1);
      double currentClose = iClose(symbol, InpEntryTF, 1);
      
      if(currentClose < lastSwingLow)
      {
         mss.detected = true;
         mss.isBullish = false;
         mss.breakLevel = lastSwingLow;
         mss.time = iTime(symbol, InpEntryTF, 1);
         mss.barIndex = 1;
      }
   }
   
   return mss;
}


//+------------------------------------------------------------------+
//| PHASE 4A: FAIR VALUE GAP (FVG) DETECTION                         |
//+------------------------------------------------------------------+
bool FindFVG(string symbol, ENUM_TREND trend, double &zoneTop, double &zoneBottom)
{
   // FVG Definition:
   // Bullish FVG: Low of candle[i-1] > High of candle[i+1] (gap between)
   // Bearish FVG: High of candle[i-1] < Low of candle[i+1] (gap between)
   
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double minSize = InpFVG_MinSize * point;
   
   // Look for FVG in last 15 bars after MSS
   for(int i = 2; i < 15; i++)
   {
      double high1 = iHigh(symbol, InpEntryTF, i+1);  // Candle before
      double low1  = iLow(symbol, InpEntryTF, i+1);
      double high2 = iHigh(symbol, InpEntryTF, i);    // Middle candle
      double low2  = iLow(symbol, InpEntryTF, i);
      double high3 = iHigh(symbol, InpEntryTF, i-1);  // Candle after
      double low3  = iLow(symbol, InpEntryTF, i-1);
      
      if(trend == TREND_BULLISH)
      {
         // Bullish FVG: gap between candle before's high and candle after's low
         double gapBottom = high1;
         double gapTop = low3;
         
         if(gapTop > gapBottom && (gapTop - gapBottom) >= minSize)
         {
            // Check if price is currently at or approaching this FVG
            double currentPrice = SymbolInfoDouble(symbol, SYMBOL_ASK);
            if(currentPrice <= gapTop && currentPrice >= gapBottom)
            {
               zoneTop = gapTop;
               zoneBottom = gapBottom;
               return true;
            }
            // Price above FVG but hasn't filled it yet
            if(currentPrice > gapTop)
            {
               // FVG already passed
               continue;
            }
            // Price approaching FVG from above
            if(currentPrice >= gapBottom - (gapTop - gapBottom))
            {
               zoneTop = gapTop;
               zoneBottom = gapBottom;
               return true;
            }
         }
      }
      else if(trend == TREND_BEARISH)
      {
         // Bearish FVG: gap between candle before's low and candle after's high
         double gapTop = low1;
         double gapBottom = high3;
         
         if(gapTop > gapBottom && (gapTop - gapBottom) >= minSize)
         {
            double currentPrice = SymbolInfoDouble(symbol, SYMBOL_BID);
            if(currentPrice >= gapBottom && currentPrice <= gapTop)
            {
               zoneTop = gapTop;
               zoneBottom = gapBottom;
               return true;
            }
            if(currentPrice < gapBottom)
            {
               continue;
            }
            if(currentPrice <= gapTop + (gapTop - gapBottom))
            {
               zoneTop = gapTop;
               zoneBottom = gapBottom;
               return true;
            }
         }
      }
   }
   
   return false;
}


//+------------------------------------------------------------------+
//| PHASE 4B: ORDER BLOCK DETECTION                                  |
//+------------------------------------------------------------------+
bool FindOrderBlock(string symbol, ENUM_TREND trend, double &zoneTop, double &zoneBottom)
{
   // Order Block Definition:
   // Bullish OB: Last bearish candle before a strong bullish move
   // Bearish OB: Last bullish candle before a strong bearish move
   
   for(int i = 2; i < 20; i++)
   {
      double open_i  = iOpen(symbol, InpEntryTF, i);
      double close_i = iClose(symbol, InpEntryTF, i);
      double high_i  = iHigh(symbol, InpEntryTF, i);
      double low_i   = iLow(symbol, InpEntryTF, i);
      
      // Next candle (the one that made the move)
      double open_next  = iOpen(symbol, InpEntryTF, i-1);
      double close_next = iClose(symbol, InpEntryTF, i-1);
      double high_next  = iHigh(symbol, InpEntryTF, i-1);
      double low_next   = iLow(symbol, InpEntryTF, i-1);
      
      double bodySize_i = MathAbs(close_i - open_i);
      double bodySize_next = MathAbs(close_next - open_next);
      
      if(trend == TREND_BULLISH)
      {
         // Bullish OB: bearish candle followed by strong bullish candle
         bool isBearish = (close_i < open_i);
         bool isBullishNext = (close_next > open_next);
         bool isStrong = (bodySize_next > bodySize_i * 1.5);
         
         if(isBearish && isBullishNext && isStrong)
         {
            // OB zone is the body of the bearish candle
            double obTop = open_i;   // Open of bearish candle (higher)
            double obBottom = close_i; // Close of bearish candle (lower)
            
            // Check if price is in or near this zone
            double currentPrice = SymbolInfoDouble(symbol, SYMBOL_ASK);
            if(currentPrice >= obBottom && currentPrice <= obTop)
            {
               if(zoneTop == 0) { zoneTop = obTop; zoneBottom = obBottom; }
               else { // Overlap with FVG gives priority
                  if(obBottom <= zoneTop && obTop >= zoneBottom) {
                     zoneTop = MathMax(zoneTop, obTop);
                     zoneBottom = MathMin(zoneBottom, obBottom);
                  }
               }
               return true;
            }
         }
      }
      else if(trend == TREND_BEARISH)
      {
         // Bearish OB: bullish candle followed by strong bearish candle
         bool isBullish = (close_i > open_i);
         bool isBearishNext = (close_next < open_next);
         bool isStrong = (bodySize_next > bodySize_i * 1.5);
         
         if(isBullish && isBearishNext && isStrong)
         {
            double obTop = close_i;  // Close of bullish candle (higher)
            double obBottom = open_i; // Open of bullish candle (lower)
            
            double currentPrice = SymbolInfoDouble(symbol, SYMBOL_BID);
            if(currentPrice >= obBottom && currentPrice <= obTop)
            {
               if(zoneTop == 0) { zoneTop = obTop; zoneBottom = obBottom; }
               else {
                  if(obBottom <= zoneTop && obTop >= zoneBottom) {
                     zoneTop = MathMax(zoneTop, obTop);
                     zoneBottom = MathMin(zoneBottom, obBottom);
                  }
               }
               return true;
            }
         }
      }
   }
   
   return false;
}


//+------------------------------------------------------------------+
//| PHASE 5: ENTRY CONFIRMATION (Rejection / Engulfing)              |
//+------------------------------------------------------------------+
bool CheckEntryConfirmation(string symbol, ENUM_TREND trend)
{
   // Check last completed candle for confirmation pattern
   double open1  = iOpen(symbol, InpEntryTF, 1);
   double close1 = iClose(symbol, InpEntryTF, 1);
   double high1  = iHigh(symbol, InpEntryTF, 1);
   double low1   = iLow(symbol, InpEntryTF, 1);
   
   double open2  = iOpen(symbol, InpEntryTF, 2);
   double close2 = iClose(symbol, InpEntryTF, 2);
   double high2  = iHigh(symbol, InpEntryTF, 2);
   double low2   = iLow(symbol, InpEntryTF, 2);
   
   double body1 = MathAbs(close1 - open1);
   double range1 = high1 - low1;
   double body2 = MathAbs(close2 - open2);
   
   if(range1 == 0) return false;
   
   if(trend == TREND_BULLISH)
   {
      // Bullish rejection: long lower wick, small body at top
      double lowerWick = MathMin(open1, close1) - low1;
      bool rejection = (lowerWick / range1 > 0.6) && (close1 > open1);
      
      // Bullish engulfing: current bullish candle engulfs previous bearish
      bool engulfing = (close2 < open2) && (close1 > open1) && 
                       (body1 > body2) && (close1 > open2) && (open1 < close2);
      
      return (rejection || engulfing);
   }
   else if(trend == TREND_BEARISH)
   {
      // Bearish rejection: long upper wick, small body at bottom
      double upperWick = high1 - MathMax(open1, close1);
      bool rejection = (upperWick / range1 > 0.6) && (close1 < open1);
      
      // Bearish engulfing: current bearish candle engulfs previous bullish
      bool engulfing = (close2 > open2) && (close1 < open1) &&
                       (body1 > body2) && (close1 < open2) && (open1 > close2);
      
      return (rejection || engulfing);
   }
   
   return false;
}

//+------------------------------------------------------------------+
//| SCORING SYSTEM                                                    |
//+------------------------------------------------------------------+
int CalculateScore(ENUM_TREND trend, bool liquiditySwept, bool mssDetected, 
                   bool hasFVG, bool hasOB)
{
   int score = 0;
   
   // Clear trend: 20 points
   if(trend == TREND_BULLISH || trend == TREND_BEARISH)
      score += 20;
   
   // Liquidity Sweep: 20 points
   if(liquiditySwept)
      score += 20;
   
   // MSS: 25 points
   if(mssDetected)
      score += 25;
   
   // FVG: 15 points
   if(hasFVG)
      score += 15;
   
   // Order Block: 10 points
   if(hasOB)
      score += 10;
   
   // Session alignment: 10 points
   if(IsWithinTradingSession())
      score += 10;
   
   return score;
}


//+------------------------------------------------------------------+
//| TIME FILTER                                                       |
//+------------------------------------------------------------------+
bool IsWithinTradingSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int hour = dt.hour;
   
   // London session
   if(hour >= InpLondonStart && hour < InpLondonEnd)
      return true;
   
   // NY first 2 hours
   if(hour >= InpNYStart && hour < InpNYEnd)
      return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| NEWS FILTER (Basic Implementation)                                |
//+------------------------------------------------------------------+
bool IsNewsTime()
{
   // In backtesting, we can't access economic calendar reliably
   // This is a placeholder - in live trading, integrate with calendar
   // For now, use manual news time if set
   
   if(g_newsTime == 0) return false;
   
   datetime current = TimeCurrent();
   datetime newsStart = g_newsTime - InpNewsMinutes * 60;
   datetime newsEnd   = g_newsTime + InpNewsMinutes * 60;
   
   return (current >= newsStart && current <= newsEnd);
}

//+------------------------------------------------------------------+
//| QUALITY FILTERS                                                   |
//+------------------------------------------------------------------+
bool PassQualityFilters(string symbol)
{
   // === Spread Filter ===
   double spread = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpread) 
   {
      return false;
   }
   
   // === ATR Filter (volatility check) ===
   int atrHandle = iATR(symbol, InpEntryTF, InpATR_Period);
   if(atrHandle == INVALID_HANDLE) return true; // Skip if can't calculate
   
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(atrHandle, 0, 0, 2, atrBuffer) < 2) return true;
   
   // Get average ATR for comparison
   double atrValues[];
   ArraySetAsSeries(atrValues, true);
   CopyBuffer(atrHandle, 0, 0, 50, atrValues);
   
   double avgATR = 0;
   int count = ArraySize(atrValues);
   for(int i = 0; i < count; i++) avgATR += atrValues[i];
   if(count > 0) avgATR /= count;
   
   // If current ATR is too low compared to average
   if(atrBuffer[0] < avgATR * InpMinATR_Multi)
   {
      return false;
   }
   
   IndicatorRelease(atrHandle);


   // === Ranging Market Filter (narrow range) ===
   double highestHigh = 0, lowestLow = 99999;
   for(int i = 1; i <= 20; i++)
   {
      double h = iHigh(symbol, InpEntryTF, i);
      double l = iLow(symbol, InpEntryTF, i);
      if(h > highestHigh) highestHigh = h;
      if(l < lowestLow) lowestLow = l;
   }
   double range20 = highestHigh - lowestLow;
   
   // If 20-bar range is less than 1.5x ATR, market is too tight
   if(range20 < atrBuffer[0] * 1.5)
   {
      return false;
   }
   
   // === Long Wick Filter (confused market) ===
   double open1 = iOpen(symbol, InpEntryTF, 1);
   double close1 = iClose(symbol, InpEntryTF, 1);
   double high1 = iHigh(symbol, InpEntryTF, 1);
   double low1 = iLow(symbol, InpEntryTF, 1);
   
   double body = MathAbs(close1 - open1);
   double totalRange = high1 - low1;
   
   if(totalRange > 0)
   {
      double wickRatio = 1.0 - (body / totalRange);
      if(wickRatio > InpMaxWickRatio)
      {
         return false;
      }
   }
   
   // === News Filter ===
   if(IsNewsTime())
   {
      return false;
   }
   
   return true;
}


//+------------------------------------------------------------------+
//| MONEY MANAGEMENT                                                  |
//+------------------------------------------------------------------+
double CalculateLotSize(string symbol, double slDistance)
{
   if(slDistance <= 0) return 0;
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (InpRiskPercent / 100.0);
   
   // Get tick value
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   
   if(tickSize == 0 || tickValue == 0) return 0;
   
   // Calculate lots
   double slPoints = slDistance / point;
   double lotSize = riskAmount / (slPoints * tickValue / (tickSize / point));
   
   // Normalize
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(lotSize, minLot);
   lotSize = MathMin(lotSize, maxLot);
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| GET SL MARGIN BASED ON SYMBOL                                    |
//+------------------------------------------------------------------+
double GetSLMargin(string symbol)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   
   if(StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0)
      return InpSL_MarginGold * point;
   else
      return InpSL_MarginEU * point;
}

//+------------------------------------------------------------------+
//| COUNT OPEN POSITIONS FOR SYMBOL                                  |
//+------------------------------------------------------------------+
int CountPositions(string symbol)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Symbol() == symbol && posInfo.Magic() == InpMagicNumber)
            count++;
      }
   }
   return count;
}


//+------------------------------------------------------------------+
//| TRADE MANAGEMENT (BE + Partial Close)                            |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != InpMagicNumber) continue;
      
      string symbol = posInfo.Symbol();
      double openPrice = posInfo.PriceOpen();
      double sl = posInfo.StopLoss();
      double tp = posInfo.TakeProfit();
      double currentPrice;
      long posType = posInfo.PositionType();
      ulong ticket = posInfo.Ticket();
      
      double riskDistance = MathAbs(openPrice - sl);
      
      if(posType == POSITION_TYPE_BUY)
      {
         currentPrice = SymbolInfoDouble(symbol, SYMBOL_BID);
         double profit = currentPrice - openPrice;
         
         // Move to Break Even at 1:1
         if(profit >= riskDistance && sl < openPrice)
         {
            double newSL = openPrice + SymbolInfoDouble(symbol, SYMBOL_POINT);
            trade.PositionModify(ticket, newSL, tp);
            Print("Moved to BE: ", symbol, " ticket: ", ticket);
         }
         
         // Partial close at 2:1
         if(InpUsePartialClose && profit >= riskDistance * 2.0)
         {
            double volume = posInfo.Volume();
            double closeVolume = NormalizeVolume(symbol, volume * (InpPartialPercent / 100.0));
            
            if(closeVolume > 0 && volume > closeVolume)
            {
               trade.PositionClosePartial(ticket, closeVolume);
               Print("Partial close: ", symbol, " volume: ", closeVolume);
            }
         }
      }
      else if(posType == POSITION_TYPE_SELL)
      {
         currentPrice = SymbolInfoDouble(symbol, SYMBOL_ASK);
         double profit = openPrice - currentPrice;
         
         // Move to Break Even at 1:1
         if(profit >= riskDistance && sl > openPrice)
         {
            double newSL = openPrice - SymbolInfoDouble(symbol, SYMBOL_POINT);
            trade.PositionModify(ticket, newSL, tp);
            Print("Moved to BE: ", symbol, " ticket: ", ticket);
         }
         
         // Partial close at 2:1
         if(InpUsePartialClose && profit >= riskDistance * 2.0)
         {
            double volume = posInfo.Volume();
            double closeVolume = NormalizeVolume(symbol, volume * (InpPartialPercent / 100.0));
            
            if(closeVolume > 0 && volume > closeVolume)
            {
               trade.PositionClosePartial(ticket, closeVolume);
               Print("Partial close: ", symbol, " volume: ", closeVolume);
            }
         }
      }
   }
}


//+------------------------------------------------------------------+
//| NORMALIZE VOLUME                                                  |
//+------------------------------------------------------------------+
double NormalizeVolume(string symbol, double volume)
{
   double minVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double stepVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   
   volume = MathFloor(volume / stepVol) * stepVol;
   volume = MathMax(volume, minVol);
   volume = MathMin(volume, maxVol);
   
   return volume;
}

//+------------------------------------------------------------------+
//| RESET DAILY COUNTERS                                              |
//+------------------------------------------------------------------+
void ResetDailyCounters()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   
   if(today != g_lastTradeDay)
   {
      g_lastTradeDay = today;
      g_todayTrades = 0;
      g_todayPnL = 0.0;
      g_dailyLimitHit = false;
   }
   
   // Check daily P&L
   double todayProfit = GetTodayProfit();
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   if(todayProfit < 0 && MathAbs(todayProfit) >= balance * (InpMaxDailyLoss / 100.0))
   {
      g_dailyLimitHit = true;
   }
}

//+------------------------------------------------------------------+
//| GET TODAY'S PROFIT                                                |
//+------------------------------------------------------------------+
double GetTodayProfit()
{
   double profit = 0;
   
   // Check closed trades today
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime todayStart = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   
   // Select history for today
   HistorySelect(todayStart, TimeCurrent());
   
   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      
      if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == InpMagicNumber)
      {
         profit += HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
         profit += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         profit += HistoryDealGetDouble(dealTicket, DEAL_SWAP);
      }
   }
   
   // Add floating P&L
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Magic() == InpMagicNumber)
            profit += posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
      }
   }
   
   return profit;
}


//+------------------------------------------------------------------+
//| ON TRADE EVENT - Track daily trades                              |
//+------------------------------------------------------------------+
void OnTrade()
{
   // Update daily P&L tracking
   g_todayPnL = GetTodayProfit();
}

//+------------------------------------------------------------------+
//| CHART COMMENT - Display EA Status                                |
//+------------------------------------------------------------------+
void DisplayStatus(string symbol)
{
   ENUM_TREND trend = DetectTrend(symbol);
   string trendStr = (trend == TREND_BULLISH) ? "BULLISH" :
                     (trend == TREND_BEARISH) ? "BEARISH" : "RANGING";
   
   string status = StringFormat(
      "=== ICT Smart Money EA ===\n"
      "Symbol: %s\n"
      "H1 Trend: %s\n"
      "Today Trades: %d / %d\n"
      "Today P&L: %.2f\n"
      "Daily Limit: %s\n"
      "Session Active: %s\n"
      "Spread: %.1f\n",
      symbol, trendStr,
      g_todayTrades, InpMaxTradesDay,
      g_todayPnL,
      g_dailyLimitHit ? "HIT" : "OK",
      IsWithinTradingSession() ? "YES" : "NO",
      (double)SymbolInfoInteger(symbol, SYMBOL_SPREAD)
   );
   
   Comment(status);
}

//+------------------------------------------------------------------+
//| TESTER EVENT - For backtesting statistics                        |
//+------------------------------------------------------------------+
double OnTester()
{
   // Return custom optimization criterion
   // Profit Factor * Win Rate gives balanced metric
   double profitFactor = TesterStatistics(STAT_PROFIT_FACTOR);
   double winRate = 0;
   double totalTrades = TesterStatistics(STAT_TRADES);
   
   if(totalTrades > 0)
   {
      double profitTrades = TesterStatistics(STAT_PROFIT_TRADES);
      winRate = profitTrades / totalTrades;
   }
   
   // Custom criterion: PF * WinRate * sqrt(trades)
   // Penalizes low trade count, rewards consistency
   double criterion = profitFactor * winRate * MathSqrt(totalTrades);
   
   return criterion;
}
//+------------------------------------------------------------------+
