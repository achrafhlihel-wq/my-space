//+------------------------------------------------------------------+
//|                                          ICT_SmartMoney_EA.mq5   |
//|                        ICT Smart Money Concepts Expert Advisor    |
//|                              For MetaTrader 5 - Backtesting Ready |
//+------------------------------------------------------------------+
#property copyright "ICT SMC Bot"
#property link      ""
#property version   "2.00"
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
input int      InpLondonStart    = 7;              // London session start hour
input int      InpLondonEnd      = 12;             // London session end hour
input int      InpNYStart        = 12;             // NY session start hour
input int      InpNYEnd          = 16;             // NY session end hour

// === News Filter ===
input int      InpNewsMinutes    = 30;             // Minutes before/after news

// === Quality Filters ===
input double   InpMaxSpread      = 50.0;           // Max spread (points)
input int      InpATR_Period     = 14;             // ATR period
input double   InpMinATR_Multi   = 0.3;            // Min ATR multiplier (relaxed)
input double   InpMaxWickRatio   = 0.8;            // Max wick ratio filter

// === Scoring System ===
input int      InpMinScore       = 65;             // Minimum score to trade (relaxed)

// === Structure Detection ===
input int      InpSwingLookback  = 3;              // Swing point lookback bars (relaxed)
input double   InpEqualLevel_Pips = 5.0;           // Equal highs/lows tolerance (pips)
input int      InpLiquidityBars  = 80;             // Bars to look for liquidity levels
input int      InpFVG_MinSize    = 3;              // Min FVG size (points)
input int      InpSweepWindow    = 5;              // Bars window for sweep detection
input int      InpMSS_Window     = 10;             // Bars window for MSS detection


//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

// Trend state
enum ENUM_TREND { TREND_BULLISH, TREND_BEARISH, TREND_RANGING };

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

// Daily tracking
int            g_todayTrades = 0;
double         g_todayPnL = 0.0;
datetime       g_lastTradeDay = 0;
bool           g_dailyLimitHit = false;

// State tracking - allow multi-bar setup detection
bool           g_sweepDetected[];       // per symbol
double         g_sweepLevel[];          // per symbol
datetime       g_sweepTime[];           // per symbol
bool           g_mssDetected[];         // per symbol  
datetime       g_mssTime[];             // per symbol
ENUM_TREND     g_lastTrend[];           // per symbol

// News filter
datetime       g_newsTime = 0;
bool           g_newsActive = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   // Initialize state arrays for 2 symbols
   ArrayResize(g_sweepDetected, 2);
   ArrayResize(g_sweepLevel, 2);
   ArrayResize(g_sweepTime, 2);
   ArrayResize(g_mssDetected, 2);
   ArrayResize(g_mssTime, 2);
   ArrayResize(g_lastTrend, 2);
   
   for(int i = 0; i < 2; i++)
   {
      g_sweepDetected[i] = false;
      g_sweepLevel[i] = 0;
      g_sweepTime[i] = 0;
      g_mssDetected[i] = false;
      g_mssTime[i] = 0;
      g_lastTrend[i] = TREND_RANGING;
   }
   
   Print("=== ICT Smart Money EA v2.0 ===");
   Print("Entry TF: ", EnumToString(InpEntryTF));
   Print("Trend TF: ", EnumToString(InpTrendTF));
   Print("Min Score: ", InpMinScore);
   Print("Swing Lookback: ", InpSwingLookback);
   Print("Sweep Window: ", InpSweepWindow, " bars");
   Print("MSS Window: ", InpMSS_Window, " bars");
   
   return(INIT_SUCCEEDED);
}


//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
   Print("ICT Smart Money EA removed. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   // Process each symbol
   if(StringLen(InpSymbol1) > 0) ProcessSymbol(InpSymbol1, 0);
   if(StringLen(InpSymbol2) > 0) ProcessSymbol(InpSymbol2, 1);
   
   // Manage open positions (BE, partial close)
   ManageOpenPositions();
   
   // Display status
   DisplayStatus(Symbol());
}

//+------------------------------------------------------------------+
//| MAIN PROCESSING FUNCTION PER SYMBOL                              |
//+------------------------------------------------------------------+
void ProcessSymbol(string symbol, int symIdx)
{
   // Check if new bar on entry timeframe
   static datetime lastBar[];
   static bool barInit = false;
   if(!barInit) { ArrayResize(lastBar, 2); lastBar[0] = 0; lastBar[1] = 0; barInit = true; }
   
   datetime currentBar = iTime(symbol, InpEntryTF, 0);
   if(currentBar == lastBar[symIdx]) return;
   lastBar[symIdx] = currentBar;
   
   // Reset daily counters
   ResetDailyCounters();
   
   // Check daily limits
   if(g_dailyLimitHit) return;
   if(g_todayTrades >= InpMaxTradesDay) return;
   
   // Check if position already exists for this pair
   if(CountPositions(symbol) >= InpMaxTradesPerPair) return;
   
   // Time filter
   if(!IsWithinTradingSession()) return;
   
   // Quality filters (relaxed)
   if(!PassQualityFilters(symbol)) return;
   
   // === PHASE 1: Determine H1 Trend ===
   ENUM_TREND trend = DetectTrend(symbol);
   if(trend == TREND_RANGING) return;
   
   // Reset state if trend changed
   if(trend != g_lastTrend[symIdx])
   {
      g_sweepDetected[symIdx] = false;
      g_mssDetected[symIdx] = false;
      g_lastTrend[symIdx] = trend;
   }
   
   // === PHASE 2: Detect Liquidity Sweep (within window) ===
   double sweepLevel = 0;
   if(!g_sweepDetected[symIdx])
   {
      if(DetectLiquiditySweep(symbol, trend, sweepLevel))
      {
         g_sweepDetected[symIdx] = true;
         g_sweepLevel[symIdx] = sweepLevel;
         g_sweepTime[symIdx] = TimeCurrent();
         Print("[", symbol, "] Liquidity Sweep detected at: ", sweepLevel);
      }
      else return; // No sweep yet
   }
   
   // Check sweep validity (within window)
   int barsSinceSweep = iBarShift(symbol, InpEntryTF, g_sweepTime[symIdx]);
   if(barsSinceSweep > InpLiquidityBars)
   {
      g_sweepDetected[symIdx] = false;
      g_mssDetected[symIdx] = false;
      return;
   }
   
   // === PHASE 3: Detect MSS ===
   if(!g_mssDetected[symIdx])
   {
      MarketStructureShift mss = DetectMSS(symbol, trend);
      if(mss.detected)
      {
         g_mssDetected[symIdx] = true;
         g_mssTime[symIdx] = TimeCurrent();
         Print("[", symbol, "] MSS detected at: ", mss.breakLevel);
      }
      else return;
   }
   
   // Check MSS validity window
   int barsSinceMSS = iBarShift(symbol, InpEntryTF, g_mssTime[symIdx]);
   if(barsSinceMSS > InpMSS_Window)
   {
      g_mssDetected[symIdx] = false;
      return;
   }


   // === PHASE 4: Find Entry Zone (FVG / Order Block) ===
   double entryZoneTop = 0, entryZoneBottom = 0;
   bool hasFVG = FindFVG(symbol, trend, entryZoneTop, entryZoneBottom);
   bool hasOB = FindOrderBlock(symbol, trend, entryZoneTop, entryZoneBottom);
   
   if(!hasFVG && !hasOB) return;
   
   // === PHASE 5: Entry Confirmation (relaxed - strong candle OR pattern) ===
   bool confirmed = CheckEntryConfirmation(symbol, trend);
   if(!confirmed) return;
   
   // === SCORING SYSTEM ===
   int score = CalculateScore(trend, true, true, hasFVG, hasOB);
   
   Print("[", symbol, "] Signal Score: ", score, " (min: ", InpMinScore, ")");
   
   if(score < InpMinScore) return;
   
   // === EXECUTE TRADE ===
   double slMargin = GetSLMargin(symbol);
   double sl, entry, tp, risk;
   
   if(trend == TREND_BULLISH)
   {
      entry = SymbolInfoDouble(symbol, SYMBOL_ASK);
      sl = g_sweepLevel[symIdx] - slMargin;
      risk = entry - sl;
      if(risk <= 0) return;
      tp = entry + (risk * InpRR_Ratio);
   }
   else
   {
      entry = SymbolInfoDouble(symbol, SYMBOL_BID);
      sl = g_sweepLevel[symIdx] + slMargin;
      risk = sl - entry;
      if(risk <= 0) return;
      tp = entry - (risk * InpRR_Ratio);
   }
   
   // Validate SL distance (not too small, not too big)
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double slPips = risk / point;
   if(slPips < 10 || slPips > 1000) return;
   
   // Calculate lot size
   double lotSize = CalculateLotSize(symbol, risk);
   if(lotSize <= 0) return;
   
   // Execute
   bool result = false;
   if(trend == TREND_BULLISH)
      result = trade.Buy(lotSize, symbol, entry, sl, tp, 
                StringFormat("ICT Buy|Score:%d", score));
   else
      result = trade.Sell(lotSize, symbol, entry, sl, tp,
                StringFormat("ICT Sell|Score:%d", score));
   
   if(trade.ResultRetcode() == TRADE_RETCODE_DONE || 
      trade.ResultRetcode() == TRADE_RETCODE_PLACED)
   {
      g_todayTrades++;
      // Reset state for next setup
      g_sweepDetected[symIdx] = false;
      g_mssDetected[symIdx] = false;
      
      Print(StringFormat(">>> TRADE OPENED: %s %s | Score: %d | Entry: %.5f | SL: %.5f | TP: %.5f | Lots: %.2f",
            (trend == TREND_BULLISH) ? "BUY" : "SELL", symbol, score, entry, sl, tp, lotSize));
   }
   else
   {
      Print("Trade FAILED: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   }
}


//+------------------------------------------------------------------+
//| PHASE 1: TREND DETECTION ON H1                                   |
//+------------------------------------------------------------------+
ENUM_TREND DetectTrend(string symbol)
{
   // Find swing highs and lows on H1
   double swHighs[];
   double swLows[];
   ArrayResize(swHighs, 0);
   ArrayResize(swLows, 0);
   
   int lookback = InpSwingLookback;
   
   // Scan H1 bars for swings (need at least 2 of each)
   for(int i = lookback; i < 80; i++)
   {
      if(IsSwingHigh(symbol, InpTrendTF, i, lookback))
      {
         int size = ArraySize(swHighs);
         ArrayResize(swHighs, size + 1);
         swHighs[size] = iHigh(symbol, InpTrendTF, i);
         if(ArraySize(swHighs) >= 3) break;
      }
   }
   
   for(int i = lookback; i < 80; i++)
   {
      if(IsSwingLow(symbol, InpTrendTF, i, lookback))
      {
         int size = ArraySize(swLows);
         ArrayResize(swLows, size + 1);
         swLows[size] = iLow(symbol, InpTrendTF, i);
         if(ArraySize(swLows) >= 3) break;
      }
   }
   
   if(ArraySize(swHighs) < 2 || ArraySize(swLows) < 2) return TREND_RANGING;
   
   // Index 0 = most recent
   bool higherHighs = (swHighs[0] > swHighs[1]);
   bool higherLows  = (swLows[0] > swLows[1]);
   bool lowerHighs  = (swHighs[0] < swHighs[1]);
   bool lowerLows   = (swLows[0] < swLows[1]);
   
   // Relaxed: only need ONE condition for trend
   if(higherHighs && higherLows) return TREND_BULLISH;
   if(lowerHighs && lowerLows)   return TREND_BEARISH;
   
   // Partial trend detection (relaxed)
   if(higherLows && !lowerHighs) return TREND_BULLISH;
   if(lowerHighs && !higherLows) return TREND_BEARISH;
   
   return TREND_RANGING;
}

//+------------------------------------------------------------------+
//| Swing High Detection                                             |
//+------------------------------------------------------------------+
bool IsSwingHigh(string symbol, ENUM_TIMEFRAMES tf, int bar, int lookback)
{
   double high = iHigh(symbol, tf, bar);
   if(high == 0) return false;
   
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
   if(low == 0) return false;
   
   for(int i = 1; i <= lookback; i++)
   {
      if(iLow(symbol, tf, bar - i) <= low) return false;
      if(iLow(symbol, tf, bar + i) <= low) return false;
   }
   return true;
}


//+------------------------------------------------------------------+
//| PHASE 2: LIQUIDITY DETECTION & SWEEP                             |
//| KEY FIX: Check multiple recent bars, not just bar 1              |
//+------------------------------------------------------------------+
bool DetectLiquiditySweep(string symbol, ENUM_TREND trend, double &sweepLevel)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tolerance = InpEqualLevel_Pips * 10 * point;
   
   // Check RECENT bars (1 to InpSweepWindow) for sweep
   for(int checkBar = 1; checkBar <= InpSweepWindow; checkBar++)
   {
      double barLow = iLow(symbol, InpEntryTF, checkBar);
      double barHigh = iHigh(symbol, InpEntryTF, checkBar);
      double barClose = iClose(symbol, InpEntryTF, checkBar);
      
      // Look for liquidity levels to sweep
      for(int i = checkBar + InpSwingLookback; i < InpLiquidityBars; i++)
      {
         if(trend == TREND_BULLISH)
         {
            // Look for swing lows that got swept downward
            if(IsSwingLow(symbol, InpEntryTF, i, InpSwingLookback))
            {
               double swLow = iLow(symbol, InpEntryTF, i);
               
               // Sweep condition: bar went below swing low but closed above
               if(barLow < swLow - (tolerance * 0.5) && barClose > swLow)
               {
                  sweepLevel = swLow;
                  return true;
               }
            }
         }
         else if(trend == TREND_BEARISH)
         {
            // Look for swing highs that got swept upward
            if(IsSwingHigh(symbol, InpEntryTF, i, InpSwingLookback))
            {
               double swHigh = iHigh(symbol, InpEntryTF, i);
               
               // Sweep condition: bar went above swing high but closed below
               if(barHigh > swHigh + (tolerance * 0.5) && barClose < swHigh)
               {
                  sweepLevel = swHigh;
                  return true;
               }
            }
         }
      }
   }
   
   // --- Also check Previous Session High/Low Sweep ---
   double prevDayHigh = 0, prevDayLow = 99999;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int todayDOW = dt.day_of_week;
   
   for(int i = 1; i < 300; i++)
   {
      MqlDateTime barDt;
      datetime barTime = iTime(symbol, InpEntryTF, i);
      if(barTime == 0) break;
      TimeToStruct(barTime, barDt);
      
      if(barDt.day != dt.day)
      {
         double h = iHigh(symbol, InpEntryTF, i);
         double l = iLow(symbol, InpEntryTF, i);
         if(h > prevDayHigh) prevDayHigh = h;
         if(l < prevDayLow)  prevDayLow = l;
         
         // Check if we've gone past one full previous day
         if(i + 1 < 300)
         {
            MqlDateTime nextDt;
            TimeToStruct(iTime(symbol, InpEntryTF, i+1), nextDt);
            if(nextDt.day != barDt.day && prevDayHigh > 0) break;
         }
      }
   }
   
   // Check recent bars for session level sweep
   for(int checkBar = 1; checkBar <= InpSweepWindow; checkBar++)
   {
      double barLow = iLow(symbol, InpEntryTF, checkBar);
      double barHigh = iHigh(symbol, InpEntryTF, checkBar);
      double barClose = iClose(symbol, InpEntryTF, checkBar);
      
      if(trend == TREND_BULLISH && prevDayLow < 99999)
      {
         if(barLow < prevDayLow && barClose > prevDayLow)
         {
            sweepLevel = prevDayLow;
            return true;
         }
      }
      else if(trend == TREND_BEARISH && prevDayHigh > 0)
      {
         if(barHigh > prevDayHigh && barClose < prevDayHigh)
         {
            sweepLevel = prevDayHigh;
            return true;
         }
      }
   }
   
   return false;
}


//+------------------------------------------------------------------+
//| PHASE 3: MARKET STRUCTURE SHIFT (MSS) DETECTION                  |
//| KEY FIX: Look at wider window, not just bar 1                    |
//+------------------------------------------------------------------+
MarketStructureShift DetectMSS(string symbol, ENUM_TREND trend)
{
   MarketStructureShift mss;
   mss.detected = false;
   mss.isBullish = false;
   mss.breakLevel = 0;
   mss.time = 0;
   mss.barIndex = 0;
   
   if(trend == TREND_BULLISH)
   {
      // Find internal swing highs to break above
      for(int sh = 3; sh < 25; sh++)
      {
         if(IsSwingHigh(symbol, InpEntryTF, sh, 2))
         {
            double swingHigh = iHigh(symbol, InpEntryTF, sh);
            
            // Check if any recent bar (1 to MSS_Window) broke above
            for(int b = 1; b < MathMin(sh, InpMSS_Window); b++)
            {
               double closeB = iClose(symbol, InpEntryTF, b);
               if(closeB > swingHigh)
               {
                  mss.detected = true;
                  mss.isBullish = true;
                  mss.breakLevel = swingHigh;
                  mss.time = iTime(symbol, InpEntryTF, b);
                  mss.barIndex = b;
                  return mss;
               }
            }
            break; // Only check first swing high found
         }
      }
   }
   else if(trend == TREND_BEARISH)
   {
      // Find internal swing lows to break below
      for(int sl = 3; sl < 25; sl++)
      {
         if(IsSwingLow(symbol, InpEntryTF, sl, 2))
         {
            double swingLow = iLow(symbol, InpEntryTF, sl);
            
            // Check if any recent bar broke below
            for(int b = 1; b < MathMin(sl, InpMSS_Window); b++)
            {
               double closeB = iClose(symbol, InpEntryTF, b);
               if(closeB < swingLow)
               {
                  mss.detected = true;
                  mss.isBullish = false;
                  mss.breakLevel = swingLow;
                  mss.time = iTime(symbol, InpEntryTF, b);
                  mss.barIndex = b;
                  return mss;
               }
            }
            break;
         }
      }
   }
   
   return mss;
}


//+------------------------------------------------------------------+
//| PHASE 4A: FAIR VALUE GAP (FVG) DETECTION                         |
//+------------------------------------------------------------------+
bool FindFVG(string symbol, ENUM_TREND trend, double &zoneTop, double &zoneBottom)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double minSize = InpFVG_MinSize * point;
   
   // Look for FVG in last 20 bars
   for(int i = 2; i < 20; i++)
   {
      double high_prev = iHigh(symbol, InpEntryTF, i+1);  // Candle before (oldest)
      double low_prev  = iLow(symbol, InpEntryTF, i+1);
      double high_mid  = iHigh(symbol, InpEntryTF, i);    // Middle candle
      double low_mid   = iLow(symbol, InpEntryTF, i);
      double high_next = iHigh(symbol, InpEntryTF, i-1);  // Candle after (newest)
      double low_next  = iLow(symbol, InpEntryTF, i-1);
      
      if(trend == TREND_BULLISH)
      {
         // Bullish FVG: gap between prev candle high and next candle low
         if(low_next > high_prev + minSize)
         {
            double gapTop = low_next;
            double gapBottom = high_prev;
            
            double currentPrice = SymbolInfoDouble(symbol, SYMBOL_ASK);
            // Price is in or near the FVG zone
            double zoneRange = gapTop - gapBottom;
            if(currentPrice >= gapBottom - zoneRange && currentPrice <= gapTop + zoneRange)
            {
               zoneTop = gapTop;
               zoneBottom = gapBottom;
               return true;
            }
         }
      }
      else if(trend == TREND_BEARISH)
      {
         // Bearish FVG: gap between prev candle low and next candle high
         if(low_prev > high_next + minSize)
         {
            double gapTop = low_prev;
            double gapBottom = high_next;
            
            double currentPrice = SymbolInfoDouble(symbol, SYMBOL_BID);
            double zoneRange = gapTop - gapBottom;
            if(currentPrice >= gapBottom - zoneRange && currentPrice <= gapTop + zoneRange)
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
   for(int i = 2; i < 25; i++)
   {
      double open_i  = iOpen(symbol, InpEntryTF, i);
      double close_i = iClose(symbol, InpEntryTF, i);
      double high_i  = iHigh(symbol, InpEntryTF, i);
      double low_i   = iLow(symbol, InpEntryTF, i);
      
      double open_next  = iOpen(symbol, InpEntryTF, i-1);
      double close_next = iClose(symbol, InpEntryTF, i-1);
      
      double bodySize_i = MathAbs(close_i - open_i);
      double bodySize_next = MathAbs(close_next - open_next);
      
      if(bodySize_i == 0) continue;
      
      if(trend == TREND_BULLISH)
      {
         // Bullish OB: bearish candle followed by strong bullish
         bool isBearish = (close_i < open_i);
         bool isBullishNext = (close_next > open_next);
         bool isStrong = (bodySize_next > bodySize_i * 1.2); // Relaxed from 1.5
         
         if(isBearish && isBullishNext && isStrong)
         {
            double obTop = open_i;
            double obBottom = close_i;
            
            double currentPrice = SymbolInfoDouble(symbol, SYMBOL_ASK);
            double obRange = obTop - obBottom;
            
            // Price within or near OB (with margin)
            if(currentPrice >= obBottom - obRange * 0.5 && 
               currentPrice <= obTop + obRange * 0.5)
            {
               if(zoneTop == 0) { zoneTop = obTop; zoneBottom = obBottom; }
               return true;
            }
         }
      }
      else if(trend == TREND_BEARISH)
      {
         bool isBullish = (close_i > open_i);
         bool isBearishNext = (close_next < open_next);
         bool isStrong = (bodySize_next > bodySize_i * 1.2);
         
         if(isBullish && isBearishNext && isStrong)
         {
            double obTop = close_i;
            double obBottom = open_i;
            
            double currentPrice = SymbolInfoDouble(symbol, SYMBOL_BID);
            double obRange = obTop - obBottom;
            
            if(currentPrice >= obBottom - obRange * 0.5 && 
               currentPrice <= obTop + obRange * 0.5)
            {
               if(zoneTop == 0) { zoneTop = obTop; zoneBottom = obBottom; }
               return true;
            }
         }
      }
   }
   
   return false;
}


//+------------------------------------------------------------------+
//| PHASE 5: ENTRY CONFIRMATION                                      |
//| KEY FIX: More relaxed - accepts strong directional candle too    |
//+------------------------------------------------------------------+
bool CheckEntryConfirmation(string symbol, ENUM_TREND trend)
{
   // Check last 3 candles for any confirmation pattern
   for(int bar = 1; bar <= 3; bar++)
   {
      double open1  = iOpen(symbol, InpEntryTF, bar);
      double close1 = iClose(symbol, InpEntryTF, bar);
      double high1  = iHigh(symbol, InpEntryTF, bar);
      double low1   = iLow(symbol, InpEntryTF, bar);
      
      double open2  = iOpen(symbol, InpEntryTF, bar + 1);
      double close2 = iClose(symbol, InpEntryTF, bar + 1);
      
      double body1 = MathAbs(close1 - open1);
      double range1 = high1 - low1;
      double body2 = MathAbs(close2 - open2);
      
      if(range1 == 0) continue;
      
      if(trend == TREND_BULLISH)
      {
         // 1. Bullish rejection (long lower wick)
         double lowerWick = MathMin(open1, close1) - low1;
         bool rejection = (lowerWick / range1 > 0.5) && (close1 > open1);
         
         // 2. Bullish engulfing
         bool engulfing = (close2 < open2) && (close1 > open1) && 
                          (body1 > body2 * 0.8) && (close1 > open2);
         
         // 3. Strong bullish candle (body > 60% of range)
         bool strongBull = (close1 > open1) && (body1 / range1 > 0.6);
         
         if(rejection || engulfing || strongBull) return true;
      }
      else if(trend == TREND_BEARISH)
      {
         // 1. Bearish rejection (long upper wick)
         double upperWick = high1 - MathMax(open1, close1);
         bool rejection = (upperWick / range1 > 0.5) && (close1 < open1);
         
         // 2. Bearish engulfing
         bool engulfing = (close2 > open2) && (close1 < open1) &&
                          (body1 > body2 * 0.8) && (close1 < open2);
         
         // 3. Strong bearish candle
         bool strongBear = (close1 < open1) && (body1 / range1 > 0.6);
         
         if(rejection || engulfing || strongBear) return true;
      }
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
   
   if(hour >= InpLondonStart && hour < InpLondonEnd) return true;
   if(hour >= InpNYStart && hour < InpNYEnd) return true;
   
   return false;
}

//+------------------------------------------------------------------+
//| NEWS FILTER                                                       |
//+------------------------------------------------------------------+
bool IsNewsTime()
{
   if(g_newsTime == 0) return false;
   datetime current = TimeCurrent();
   datetime newsStart = g_newsTime - InpNewsMinutes * 60;
   datetime newsEnd   = g_newsTime + InpNewsMinutes * 60;
   return (current >= newsStart && current <= newsEnd);
}

//+------------------------------------------------------------------+
//| QUALITY FILTERS (RELAXED)                                        |
//+------------------------------------------------------------------+
bool PassQualityFilters(string symbol)
{
   // Spread Filter
   long spread = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   if(spread > (long)InpMaxSpread) return false;
   
   // ATR Filter
   int atrHandle = iATR(symbol, InpEntryTF, InpATR_Period);
   if(atrHandle == INVALID_HANDLE) return true;
   
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   if(CopyBuffer(atrHandle, 0, 0, 50, atrBuffer) < 50)
   {
      IndicatorRelease(atrHandle);
      return true; // Skip filter if not enough data
   }
   
   // Average ATR
   double avgATR = 0;
   for(int i = 0; i < 50; i++) avgATR += atrBuffer[i];
   avgATR /= 50.0;
   
   IndicatorRelease(atrHandle);
   
   // Current ATR too low = no trade
   if(avgATR > 0 && atrBuffer[0] < avgATR * InpMinATR_Multi)
      return false;
   
   // News filter
   if(IsNewsTime()) return false;
   
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
   
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   
   if(tickSize == 0 || tickValue == 0 || point == 0) return 0;
   
   double slTicks = slDistance / tickSize;
   double lotSize = riskAmount / (slTicks * tickValue);
   
   // Normalize
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   
   if(lotStep == 0) lotStep = 0.01;
   
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(lotSize, minLot);
   lotSize = MathMin(lotSize, maxLot);
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| GET SL MARGIN                                                    |
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
//| COUNT POSITIONS                                                  |
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
//| NORMALIZE VOLUME                                                  |
//+------------------------------------------------------------------+
double NormalizeVolume(string symbol, double volume)
{
   double minVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double stepVol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(stepVol == 0) stepVol = 0.01;
   
   volume = MathFloor(volume / stepVol) * stepVol;
   volume = MathMax(volume, minVol);
   volume = MathMin(volume, maxVol);
   return volume;
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
      if(riskDistance == 0) continue;
      
      if(posType == POSITION_TYPE_BUY)
      {
         currentPrice = SymbolInfoDouble(symbol, SYMBOL_BID);
         double profit = currentPrice - openPrice;
         
         // Move to Break Even at 1:1
         if(profit >= riskDistance && sl < openPrice)
         {
            double newSL = openPrice + SymbolInfoDouble(symbol, SYMBOL_POINT) * 2;
            trade.PositionModify(ticket, newSL, tp);
         }
         
         // Partial close at 2:1
         if(InpUsePartialClose && profit >= riskDistance * 2.0)
         {
            double volume = posInfo.Volume();
            double closeVolume = NormalizeVolume(symbol, volume * (InpPartialPercent / 100.0));
            if(closeVolume > 0 && volume > closeVolume)
            {
               trade.PositionClosePartial(ticket, closeVolume);
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
            double newSL = openPrice - SymbolInfoDouble(symbol, SYMBOL_POINT) * 2;
            trade.PositionModify(ticket, newSL, tp);
         }
         
         // Partial close at 2:1
         if(InpUsePartialClose && profit >= riskDistance * 2.0)
         {
            double volume = posInfo.Volume();
            double closeVolume = NormalizeVolume(symbol, volume * (InpPartialPercent / 100.0));
            if(closeVolume > 0 && volume > closeVolume)
            {
               trade.PositionClosePartial(ticket, closeVolume);
            }
         }
      }
   }
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
   
   if(balance > 0 && todayProfit < 0 && MathAbs(todayProfit) >= balance * (InpMaxDailyLoss / 100.0))
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
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime todayStart = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   
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
//| ON TRADE EVENT                                                   |
//+------------------------------------------------------------------+
void OnTrade()
{
   g_todayPnL = GetTodayProfit();
}

//+------------------------------------------------------------------+
//| DISPLAY STATUS ON CHART                                          |
//+------------------------------------------------------------------+
void DisplayStatus(string symbol)
{
   ENUM_TREND trend = DetectTrend(symbol);
   string trendStr = (trend == TREND_BULLISH) ? "BULLISH" :
                     (trend == TREND_BEARISH) ? "BEARISH" : "RANGING";
   
   int symIdx = (symbol == InpSymbol1) ? 0 : 1;
   
   string status = StringFormat(
      "=== ICT Smart Money EA v2.0 ===\n"
      "Symbol: %s | TF: %s\n"
      "H1 Trend: %s\n"
      "Sweep Detected: %s (Level: %.5f)\n"
      "MSS Detected: %s\n"
      "Today Trades: %d / %d\n"
      "Today P&L: %.2f\n"
      "Daily Limit: %s\n"
      "Session Active: %s\n"
      "Spread: %d pts\n",
      symbol, EnumToString(InpEntryTF),
      trendStr,
      g_sweepDetected[symIdx] ? "YES" : "NO", g_sweepLevel[symIdx],
      g_mssDetected[symIdx] ? "YES" : "NO",
      g_todayTrades, InpMaxTradesDay,
      g_todayPnL,
      g_dailyLimitHit ? "HIT - STOPPED" : "OK",
      IsWithinTradingSession() ? "YES" : "NO",
      (int)SymbolInfoInteger(symbol, SYMBOL_SPREAD)
   );
   
   Comment(status);
}

//+------------------------------------------------------------------+
//| TESTER EVENT                                                      |
//+------------------------------------------------------------------+
double OnTester()
{
   double profitFactor = TesterStatistics(STAT_PROFIT_FACTOR);
   double totalTrades = TesterStatistics(STAT_TRADES);
   double winRate = 0;
   
   if(totalTrades > 0)
   {
      double profitTrades = TesterStatistics(STAT_PROFIT_TRADES);
      winRate = profitTrades / totalTrades;
   }
   
   // Custom: PF * WinRate * sqrt(trades) - balanced metric
   return profitFactor * winRate * MathSqrt(totalTrades);
}
//+------------------------------------------------------------------+
