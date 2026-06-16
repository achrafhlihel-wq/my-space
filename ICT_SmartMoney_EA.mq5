//+------------------------------------------------------------------+
//|                                          ICT_SmartMoney_EA.mq5   |
//|                        ICT Smart Money Concepts Expert Advisor    |
//|                    v3.0 - Fixed Entry/SL Ratio Problem            |
//+------------------------------------------------------------------+
#property copyright "ICT SMC Bot"
#property link      ""
#property version   "3.00"
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

// === Stop Loss ===
input int      InpSL_MarginEU    = 3;              // SL margin EURUSD (pips)
input int      InpSL_MarginGold  = 30;             // SL margin XAUUSD (points)
input int      InpMaxSL_EU       = 25;             // Max SL EURUSD (pips) - REJECTS if bigger
input int      InpMaxSL_Gold     = 400;            // Max SL XAUUSD (points)

// === Take Profit ===
input double   InpRR_Ratio       = 3.0;            // Risk:Reward ratio
input double   InpMinRR_Ratio    = 1.5;            // Min R:R to accept trade
input bool     InpUsePartialClose = true;          // Use partial close at 2:1
input double   InpPartialPercent = 50.0;           // Partial close %

// === Entry Mode ===
input bool     InpUseLimitOrders = true;           // Use Limit Orders (better entry)
input int      InpLimitExpiry    = 3;              // Limit order expiry (bars)

// === Time Filter (Server Time) ===
input int      InpLondonStart    = 7;              // London session start hour
input int      InpLondonEnd      = 12;             // London session end hour
input int      InpNYStart        = 12;             // NY session start hour
input int      InpNYEnd          = 16;             // NY session end hour


// === News Filter ===
input int      InpNewsMinutes    = 30;             // Minutes before/after news

// === Quality Filters ===
input double   InpMaxSpread      = 40.0;           // Max spread (points)
input int      InpATR_Period     = 14;             // ATR period
input double   InpMinATR_Multi   = 0.3;            // Min ATR multiplier

// === Scoring System ===
input int      InpMinScore       = 65;             // Minimum score to trade

// === Structure Detection ===
input int      InpSwingLookback  = 3;              // Swing point lookback bars
input double   InpEqualLevel_Pips = 5.0;           // Equal highs/lows tolerance (pips)
input int      InpLiquidityBars  = 80;             // Bars to look for liquidity levels
input int      InpFVG_MinSize    = 3;              // Min FVG size (points)
input int      InpSweepWindow    = 5;              // Bars window for sweep detection
input int      InpMSS_Window     = 10;             // Bars window for MSS after sweep

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

enum ENUM_TREND { TREND_BULLISH, TREND_BEARISH, TREND_RANGING };

struct MarketStructureShift {
   bool detected;
   bool isBullish;
   double breakLevel;
   datetime time;
   int barIndex;
};

// Daily tracking
int            g_todayTrades = 0;
double         g_todayPnL = 0.0;
datetime       g_lastTradeDay = 0;
bool           g_dailyLimitHit = false;

// State tracking per symbol (multi-bar setup)
bool           g_sweepDetected[];
double         g_sweepLevel[];
datetime       g_sweepTime[];
bool           g_mssDetected[];
datetime       g_mssTime[];
ENUM_TREND     g_lastTrend[];

// Entry zone storage
double         g_entryZoneTop[];
double         g_entryZoneBottom[];

// News filter
datetime       g_newsTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(20);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   // Initialize arrays for 2 symbols
   int n = 2;
   ArrayResize(g_sweepDetected, n);
   ArrayResize(g_sweepLevel, n);
   ArrayResize(g_sweepTime, n);
   ArrayResize(g_mssDetected, n);
   ArrayResize(g_mssTime, n);
   ArrayResize(g_lastTrend, n);
   ArrayResize(g_entryZoneTop, n);
   ArrayResize(g_entryZoneBottom, n);
   
   for(int i = 0; i < n; i++)
   {
      g_sweepDetected[i] = false;
      g_sweepLevel[i] = 0;
      g_sweepTime[i] = 0;
      g_mssDetected[i] = false;
      g_mssTime[i] = 0;
      g_lastTrend[i] = TREND_RANGING;
      g_entryZoneTop[i] = 0;
      g_entryZoneBottom[i] = 0;
   }
   
   Print("=== ICT Smart Money EA v3.0 ===");
   Print("KEY FIX: Tight SL on OB/FVG zone, Limit orders, R:R validation");
   Print("Entry TF: ", EnumToString(InpEntryTF));
   Print("Min R:R: ", InpMinRR_Ratio);
   Print("Use Limits: ", InpUseLimitOrders);
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   // Clean pending orders
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         trade.OrderDelete(ticket);
   }
   Comment("");
   Print("ICT Smart Money EA v3.0 removed.");
}


//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   if(StringLen(InpSymbol1) > 0) ProcessSymbol(InpSymbol1, 0);
   if(StringLen(InpSymbol2) > 0) ProcessSymbol(InpSymbol2, 1);
   ManageOpenPositions();
   CleanExpiredOrders();
   DisplayStatus(Symbol());
}

//+------------------------------------------------------------------+
//| MAIN LOGIC PER SYMBOL                                            |
//+------------------------------------------------------------------+
void ProcessSymbol(string symbol, int symIdx)
{
   // Only process on new bar
   static datetime lastBar[];
   static bool barInit = false;
   if(!barInit) { ArrayResize(lastBar, 2); lastBar[0] = 0; lastBar[1] = 0; barInit = true; }
   
   datetime currentBar = iTime(symbol, InpEntryTF, 0);
   if(currentBar == lastBar[symIdx]) return;
   lastBar[symIdx] = currentBar;
   
   // Daily limits
   ResetDailyCounters();
   if(g_dailyLimitHit) return;
   if(g_todayTrades >= InpMaxTradesDay) return;
   if(CountPositions(symbol) >= InpMaxTradesPerPair) return;
   if(CountPendingOrders(symbol) > 0) return; // Already have pending order
   
   // Time & Quality
   if(!IsWithinTradingSession()) return;
   if(!PassQualityFilters(symbol)) return;
   
   // === PHASE 1: H1 Trend ===
   ENUM_TREND trend = DetectTrend(symbol);
   if(trend == TREND_RANGING) return;
   
   // Reset if trend flipped
   if(trend != g_lastTrend[symIdx])
   {
      g_sweepDetected[symIdx] = false;
      g_mssDetected[symIdx] = false;
      g_lastTrend[symIdx] = trend;
   }
   
   // === PHASE 2: Liquidity Sweep ===
   if(!g_sweepDetected[symIdx])
   {
      double sweepLevel = 0;
      if(DetectLiquiditySweep(symbol, trend, sweepLevel))
      {
         g_sweepDetected[symIdx] = true;
         g_sweepLevel[symIdx] = sweepLevel;
         g_sweepTime[symIdx] = TimeCurrent();
         Print("[", symbol, "] SWEEP at ", DoubleToString(sweepLevel, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)));
      }
      else return;
   }
   
   // Expire sweep if too old
   int barsSinceSweep = iBarShift(symbol, InpEntryTF, g_sweepTime[symIdx]);
   if(barsSinceSweep > 30) { g_sweepDetected[symIdx] = false; g_mssDetected[symIdx] = false; return; }
   
   // === PHASE 3: MSS ===
   if(!g_mssDetected[symIdx])
   {
      MarketStructureShift mss = DetectMSS(symbol, trend);
      if(mss.detected)
      {
         g_mssDetected[symIdx] = true;
         g_mssTime[symIdx] = TimeCurrent();
         Print("[", symbol, "] MSS at ", DoubleToString(mss.breakLevel, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)));
      }
      else return;
   }
   
   // Expire MSS
   int barsSinceMSS = iBarShift(symbol, InpEntryTF, g_mssTime[symIdx]);
   if(barsSinceMSS > InpMSS_Window) { g_mssDetected[symIdx] = false; return; }
   
   // === PHASE 4: Find TIGHT Entry Zone (FVG/OB) ===
   double zoneTop = 0, zoneBottom = 0;
   bool hasFVG = FindFVG(symbol, trend, zoneTop, zoneBottom);
   bool hasOB = FindOrderBlock(symbol, trend, zoneTop, zoneBottom);
   
   if(!hasFVG && !hasOB) return;
   
   // === PHASE 5: Validate R:R BEFORE entry ===
   double sl, entry, tp, risk, reward;
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double slMargin = GetSLMargin(symbol);
   
   if(trend == TREND_BULLISH)
   {
      // ENTRY at zone top (or middle for limit)
      entry = InpUseLimitOrders ? (zoneTop + zoneBottom) / 2.0 : SymbolInfoDouble(symbol, SYMBOL_ASK);
      // SL TIGHT: just below the zone (not at sweep level!)
      sl = zoneBottom - slMargin;
      risk = entry - sl;
      tp = entry + (risk * InpRR_Ratio);
   }
   else
   {
      entry = InpUseLimitOrders ? (zoneTop + zoneBottom) / 2.0 : SymbolInfoDouble(symbol, SYMBOL_BID);
      sl = zoneTop + slMargin;
      risk = sl - entry;
      tp = entry - (risk * InpRR_Ratio);
   }
   
   // === VALIDATE: Reject if SL too big ===
   double slPips = risk / point;
   double maxSL = IsGold(symbol) ? InpMaxSL_Gold : InpMaxSL_EU * 10; // Convert pips to points for EU
   if(slPips > maxSL || slPips < 5)
   {
      Print("[", symbol, "] REJECTED: SL too big/small: ", slPips, " pts (max: ", maxSL, ")");
      return;
   }
   
   // === VALIDATE: Check actual R:R ===
   double currentPrice = (trend == TREND_BULLISH) ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);
   double actualRisk = MathAbs(currentPrice - sl);
   double potentialReward = MathAbs(tp - currentPrice);
   double actualRR = (actualRisk > 0) ? potentialReward / actualRisk : 0;
   
   if(actualRR < InpMinRR_Ratio)
   {
      Print("[", symbol, "] REJECTED: R:R too low: ", DoubleToString(actualRR, 2), " (min: ", InpMinRR_Ratio, ")");
      return;
   }
   
   // === SCORING ===
   int score = CalculateScore(trend, true, true, hasFVG, hasOB);
   if(score < InpMinScore) return;
   
   // === EXECUTE ===
   double lotSize = CalculateLotSize(symbol, actualRisk);
   if(lotSize <= 0) return;
   
   // Normalize prices
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);
   entry = NormalizeDouble(entry, digits);
   
   bool success = false;
   string comment = StringFormat("ICT %s|S:%d|RR:%.1f", (trend==TREND_BULLISH)?"Buy":"Sell", score, actualRR);
   
   if(InpUseLimitOrders)
   {
      // Place LIMIT order at zone middle for better entry
      datetime expiry = TimeCurrent() + PeriodSeconds(InpEntryTF) * InpLimitExpiry;
      
      if(trend == TREND_BULLISH)
      {
         // Buy Limit below current price
         if(entry < currentPrice)
            success = trade.BuyLimit(lotSize, entry, symbol, sl, tp, ORDER_TIME_SPECIFIED, expiry, comment);
         else
            success = trade.Buy(lotSize, symbol, 0, sl, tp, comment);
      }
      else
      {
         // Sell Limit above current price  
         if(entry > currentPrice)
            success = trade.SellLimit(lotSize, entry, symbol, sl, tp, ORDER_TIME_SPECIFIED, expiry, comment);
         else
            success = trade.Sell(lotSize, symbol, 0, sl, tp, comment);
      }
   }
   else
   {
      if(trend == TREND_BULLISH)
         success = trade.Buy(lotSize, symbol, 0, sl, tp, comment);
      else
         success = trade.Sell(lotSize, symbol, 0, sl, tp, comment);
   }
   
   if(trade.ResultRetcode() == TRADE_RETCODE_DONE || trade.ResultRetcode() == TRADE_RETCODE_PLACED)
   {
      g_todayTrades++;
      g_sweepDetected[symIdx] = false;
      g_mssDetected[symIdx] = false;
      Print(StringFormat(">>> TRADE: %s %s | Score:%d | RR:%.1f | Entry:%.5f | SL:%.5f | TP:%.5f | Lots:%.2f",
            (trend==TREND_BULLISH)?"BUY":"SELL", symbol, score, actualRR, entry, sl, tp, lotSize));
   }
   else
   {
      Print("FAILED: ", trade.ResultRetcode(), " - ", trade.ResultRetcodeDescription());
   }
}


//+------------------------------------------------------------------+
//| TREND DETECTION (H1)                                             |
//+------------------------------------------------------------------+
ENUM_TREND DetectTrend(string symbol)
{
   double swHighs[];
   double swLows[];
   ArrayResize(swHighs, 0);
   ArrayResize(swLows, 0);
   
   for(int i = InpSwingLookback; i < 80; i++)
   {
      if(IsSwingHigh(symbol, InpTrendTF, i, InpSwingLookback))
      {
         int size = ArraySize(swHighs);
         ArrayResize(swHighs, size + 1);
         swHighs[size] = iHigh(symbol, InpTrendTF, i);
         if(ArraySize(swHighs) >= 3) break;
      }
   }
   for(int i = InpSwingLookback; i < 80; i++)
   {
      if(IsSwingLow(symbol, InpTrendTF, i, InpSwingLookback))
      {
         int size = ArraySize(swLows);
         ArrayResize(swLows, size + 1);
         swLows[size] = iLow(symbol, InpTrendTF, i);
         if(ArraySize(swLows) >= 3) break;
      }
   }
   
   if(ArraySize(swHighs) < 2 || ArraySize(swLows) < 2) return TREND_RANGING;
   
   bool HH = (swHighs[0] > swHighs[1]);
   bool HL = (swLows[0] > swLows[1]);
   bool LH = (swHighs[0] < swHighs[1]);
   bool LL = (swLows[0] < swLows[1]);
   
   if(HH && HL) return TREND_BULLISH;
   if(LH && LL) return TREND_BEARISH;
   if(HL && !LH) return TREND_BULLISH;
   if(LH && !HL) return TREND_BEARISH;
   
   return TREND_RANGING;
}

bool IsSwingHigh(string symbol, ENUM_TIMEFRAMES tf, int bar, int lookback)
{
   double high = iHigh(symbol, tf, bar);
   if(high == 0) return false;
   for(int i = 1; i <= lookback; i++)
   {
      if(iHigh(symbol, tf, bar-i) >= high) return false;
      if(iHigh(symbol, tf, bar+i) >= high) return false;
   }
   return true;
}

bool IsSwingLow(string symbol, ENUM_TIMEFRAMES tf, int bar, int lookback)
{
   double low = iLow(symbol, tf, bar);
   if(low == 0) return false;
   for(int i = 1; i <= lookback; i++)
   {
      if(iLow(symbol, tf, bar-i) <= low) return false;
      if(iLow(symbol, tf, bar+i) <= low) return false;
   }
   return true;
}


//+------------------------------------------------------------------+
//| LIQUIDITY SWEEP DETECTION                                        |
//+------------------------------------------------------------------+
bool DetectLiquiditySweep(string symbol, ENUM_TREND trend, double &sweepLevel)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tolerance = InpEqualLevel_Pips * 10 * point;
   
   for(int checkBar = 1; checkBar <= InpSweepWindow; checkBar++)
   {
      double barLow = iLow(symbol, InpEntryTF, checkBar);
      double barHigh = iHigh(symbol, InpEntryTF, checkBar);
      double barClose = iClose(symbol, InpEntryTF, checkBar);
      
      for(int i = checkBar + InpSwingLookback + 1; i < InpLiquidityBars; i++)
      {
         if(trend == TREND_BULLISH)
         {
            if(IsSwingLow(symbol, InpEntryTF, i, InpSwingLookback))
            {
               double swLow = iLow(symbol, InpEntryTF, i);
               if(barLow < swLow - tolerance * 0.3 && barClose > swLow)
               {
                  sweepLevel = swLow;
                  return true;
               }
            }
         }
         else
         {
            if(IsSwingHigh(symbol, InpEntryTF, i, InpSwingLookback))
            {
               double swHigh = iHigh(symbol, InpEntryTF, i);
               if(barHigh > swHigh + tolerance * 0.3 && barClose < swHigh)
               {
                  sweepLevel = swHigh;
                  return true;
               }
            }
         }
      }
   }
   
   // Previous day H/L sweep
   double prevHigh = 0, prevLow = 99999;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   for(int i = 1; i < 300; i++)
   {
      datetime barTime = iTime(symbol, InpEntryTF, i);
      if(barTime == 0) break;
      MqlDateTime barDt;
      TimeToStruct(barTime, barDt);
      
      if(barDt.day != dt.day)
      {
         double h = iHigh(symbol, InpEntryTF, i);
         double l = iLow(symbol, InpEntryTF, i);
         if(h > prevHigh) prevHigh = h;
         if(l < prevLow) prevLow = l;
         
         if(i+1 < 300)
         {
            MqlDateTime nextDt;
            TimeToStruct(iTime(symbol, InpEntryTF, i+1), nextDt);
            if(nextDt.day != barDt.day && prevHigh > 0) break;
         }
      }
   }
   
   for(int checkBar = 1; checkBar <= InpSweepWindow; checkBar++)
   {
      double barLow = iLow(symbol, InpEntryTF, checkBar);
      double barHigh = iHigh(symbol, InpEntryTF, checkBar);
      double barClose = iClose(symbol, InpEntryTF, checkBar);
      
      if(trend == TREND_BULLISH && prevLow < 99999)
      {
         if(barLow < prevLow && barClose > prevLow) { sweepLevel = prevLow; return true; }
      }
      else if(trend == TREND_BEARISH && prevHigh > 0)
      {
         if(barHigh > prevHigh && barClose < prevHigh) { sweepLevel = prevHigh; return true; }
      }
   }
   
   return false;
}


//+------------------------------------------------------------------+
//| MSS DETECTION                                                     |
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
      for(int sh = 3; sh < 25; sh++)
      {
         if(IsSwingHigh(symbol, InpEntryTF, sh, 2))
         {
            double swHigh = iHigh(symbol, InpEntryTF, sh);
            for(int b = 1; b < MathMin(sh, InpMSS_Window); b++)
            {
               if(iClose(symbol, InpEntryTF, b) > swHigh)
               {
                  mss.detected = true;
                  mss.isBullish = true;
                  mss.breakLevel = swHigh;
                  mss.time = iTime(symbol, InpEntryTF, b);
                  mss.barIndex = b;
                  return mss;
               }
            }
            break;
         }
      }
   }
   else if(trend == TREND_BEARISH)
   {
      for(int sl = 3; sl < 25; sl++)
      {
         if(IsSwingLow(symbol, InpEntryTF, sl, 2))
         {
            double swLow = iLow(symbol, InpEntryTF, sl);
            for(int b = 1; b < MathMin(sl, InpMSS_Window); b++)
            {
               if(iClose(symbol, InpEntryTF, b) < swLow)
               {
                  mss.detected = true;
                  mss.isBullish = false;
                  mss.breakLevel = swLow;
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
//| FVG DETECTION - Returns TIGHT zone for SL placement              |
//+------------------------------------------------------------------+
bool FindFVG(string symbol, ENUM_TREND trend, double &zoneTop, double &zoneBottom)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double minSize = InpFVG_MinSize * point;
   double currentPrice = (trend == TREND_BULLISH) ? 
                         SymbolInfoDouble(symbol, SYMBOL_ASK) : 
                         SymbolInfoDouble(symbol, SYMBOL_BID);
   
   for(int i = 2; i < 20; i++)
   {
      double high_prev = iHigh(symbol, InpEntryTF, i+1);
      double low_prev  = iLow(symbol, InpEntryTF, i+1);
      double high_next = iHigh(symbol, InpEntryTF, i-1);
      double low_next  = iLow(symbol, InpEntryTF, i-1);
      
      if(trend == TREND_BULLISH)
      {
         // Bullish FVG: gap up
         if(low_next > high_prev + minSize)
         {
            double gapTop = low_next;
            double gapBottom = high_prev;
            
            // Price must be AT or APPROACHING the zone (not far past it)
            if(currentPrice <= gapTop * 1.001 && currentPrice >= gapBottom * 0.999)
            {
               zoneTop = gapTop;
               zoneBottom = gapBottom;
               return true;
            }
            // Price slightly above zone (just entered)
            if(currentPrice > gapTop && currentPrice < gapTop + (gapTop - gapBottom) * 2)
            {
               zoneTop = gapTop;
               zoneBottom = gapBottom;
               return true;
            }
         }
      }
      else
      {
         // Bearish FVG: gap down
         if(low_prev > high_next + minSize)
         {
            double gapTop = low_prev;
            double gapBottom = high_next;
            
            if(currentPrice >= gapBottom * 0.999 && currentPrice <= gapTop * 1.001)
            {
               zoneTop = gapTop;
               zoneBottom = gapBottom;
               return true;
            }
            if(currentPrice < gapBottom && currentPrice > gapBottom - (gapTop - gapBottom) * 2)
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
//| ORDER BLOCK DETECTION                                            |
//+------------------------------------------------------------------+
bool FindOrderBlock(string symbol, ENUM_TREND trend, double &zoneTop, double &zoneBottom)
{
   double currentPrice = (trend == TREND_BULLISH) ? 
                         SymbolInfoDouble(symbol, SYMBOL_ASK) : 
                         SymbolInfoDouble(symbol, SYMBOL_BID);
   
   for(int i = 2; i < 25; i++)
   {
      double open_i  = iOpen(symbol, InpEntryTF, i);
      double close_i = iClose(symbol, InpEntryTF, i);
      double high_i  = iHigh(symbol, InpEntryTF, i);
      double low_i   = iLow(symbol, InpEntryTF, i);
      
      double open_n  = iOpen(symbol, InpEntryTF, i-1);
      double close_n = iClose(symbol, InpEntryTF, i-1);
      
      double body_i = MathAbs(close_i - open_i);
      double body_n = MathAbs(close_n - open_n);
      
      if(body_i == 0) continue;
      
      if(trend == TREND_BULLISH)
      {
         // Bullish OB: bearish candle → strong bullish
         if(close_i < open_i && close_n > open_n && body_n > body_i * 1.2)
         {
            double obTop = open_i;    // Body top of bearish candle
            double obBottom = close_i; // Body bottom
            double obRange = obTop - obBottom;
            
            // Price at/near OB
            if(currentPrice >= obBottom - obRange * 0.3 && 
               currentPrice <= obTop + obRange * 0.5)
            {
               // Use OB as zone if better (tighter) than existing
               if(zoneTop == 0 || obRange < (zoneTop - zoneBottom))
               {
                  zoneTop = obTop;
                  zoneBottom = obBottom;
               }
               return true;
            }
         }
      }
      else
      {
         // Bearish OB: bullish candle → strong bearish
         if(close_i > open_i && close_n < open_n && body_n > body_i * 1.2)
         {
            double obTop = close_i;
            double obBottom = open_i;
            double obRange = obTop - obBottom;
            
            if(currentPrice >= obBottom - obRange * 0.5 && 
               currentPrice <= obTop + obRange * 0.3)
            {
               if(zoneTop == 0 || obRange < (zoneTop - zoneBottom))
               {
                  zoneTop = obTop;
                  zoneBottom = obBottom;
               }
               return true;
            }
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| SCORING                                                          |
//+------------------------------------------------------------------+
int CalculateScore(ENUM_TREND trend, bool sweep, bool mss, bool fvg, bool ob)
{
   int score = 0;
   if(trend != TREND_RANGING) score += 20;
   if(sweep) score += 20;
   if(mss)   score += 25;
   if(fvg)   score += 15;
   if(ob)    score += 10;
   if(IsWithinTradingSession()) score += 10;
   return score;
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
      ulong ticket = posInfo.Ticket();
      long posType = posInfo.PositionType();
      
      double riskDist = MathAbs(openPrice - sl);
      if(riskDist == 0) continue;
      
      double currentPrice, profit;
      
      if(posType == POSITION_TYPE_BUY)
      {
         currentPrice = SymbolInfoDouble(symbol, SYMBOL_BID);
         profit = currentPrice - openPrice;
         
         // BE at 1:1
         if(profit >= riskDist && sl < openPrice)
         {
            double newSL = openPrice + SymbolInfoDouble(symbol, SYMBOL_POINT) * 3;
            trade.PositionModify(ticket, NormalizeDouble(newSL, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)), tp);
         }
         
         // Partial at 2:1
         if(InpUsePartialClose && profit >= riskDist * 2.0 && sl >= openPrice)
         {
            double vol = posInfo.Volume();
            double closeVol = NormalizeVolume(symbol, vol * (InpPartialPercent / 100.0));
            if(closeVol > 0 && vol > closeVol)
               trade.PositionClosePartial(ticket, closeVol);
         }
      }
      else
      {
         currentPrice = SymbolInfoDouble(symbol, SYMBOL_ASK);
         profit = openPrice - currentPrice;
         
         if(profit >= riskDist && sl > openPrice)
         {
            double newSL = openPrice - SymbolInfoDouble(symbol, SYMBOL_POINT) * 3;
            trade.PositionModify(ticket, NormalizeDouble(newSL, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)), tp);
         }
         
         if(InpUsePartialClose && profit >= riskDist * 2.0 && sl <= openPrice)
         {
            double vol = posInfo.Volume();
            double closeVol = NormalizeVolume(symbol, vol * (InpPartialPercent / 100.0));
            if(closeVol > 0 && vol > closeVol)
               trade.PositionClosePartial(ticket, closeVol);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CLEAN EXPIRED PENDING ORDERS                                     |
//+------------------------------------------------------------------+
void CleanExpiredOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      
      datetime expiry = (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION);
      if(expiry > 0 && TimeCurrent() > expiry)
         trade.OrderDelete(ticket);
   }
}

//+------------------------------------------------------------------+
//| COUNT PENDING ORDERS                                             |
//+------------------------------------------------------------------+
int CountPendingOrders(string symbol)
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetInteger(ORDER_MAGIC) == InpMagicNumber && OrderGetString(ORDER_SYMBOL) == symbol)
         count++;
   }
   return count;
}


//+------------------------------------------------------------------+
//| UTILITY FUNCTIONS                                                 |
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

bool IsNewsTime()
{
   if(g_newsTime == 0) return false;
   datetime current = TimeCurrent();
   return (current >= g_newsTime - InpNewsMinutes*60 && current <= g_newsTime + InpNewsMinutes*60);
}

bool IsGold(string symbol)
{
   return (StringFind(symbol, "XAU") >= 0 || StringFind(symbol, "GOLD") >= 0);
}

double GetSLMargin(string symbol)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(IsGold(symbol))
      return InpSL_MarginGold * point;
   else
      return InpSL_MarginEU * 10 * point; // pips to points
}

bool PassQualityFilters(string symbol)
{
   long spread = SymbolInfoInteger(symbol, SYMBOL_SPREAD);
   if(spread > (long)InpMaxSpread) return false;
   
   int atrHandle = iATR(symbol, InpEntryTF, InpATR_Period);
   if(atrHandle == INVALID_HANDLE) return true;
   
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(atrHandle, 0, 0, 50, atrBuf) < 50) { IndicatorRelease(atrHandle); return true; }
   
   double avgATR = 0;
   for(int i = 0; i < 50; i++) avgATR += atrBuf[i];
   avgATR /= 50.0;
   
   IndicatorRelease(atrHandle);
   
   if(avgATR > 0 && atrBuf[0] < avgATR * InpMinATR_Multi) return false;
   if(IsNewsTime()) return false;
   
   return true;
}

double CalculateLotSize(string symbol, double slDist)
{
   if(slDist <= 0) return 0;
   
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt = balance * (InpRiskPercent / 100.0);
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   
   if(tickSize == 0 || tickValue == 0) return 0;
   
   double slTicks = slDist / tickSize;
   double lots = riskAmt / (slTicks * tickValue);
   
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(lotStep == 0) lotStep = 0.01;
   
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   return lots;
}

double NormalizeVolume(string symbol, double volume)
{
   double minV = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(step == 0) step = 0.01;
   volume = MathFloor(volume / step) * step;
   return MathMax(MathMin(volume, maxV), minV);
}

int CountPositions(string symbol)
{
   int count = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == symbol && posInfo.Magic() == InpMagicNumber)
            count++;
   }
   return count;
}


//+------------------------------------------------------------------+
//| DAILY MANAGEMENT                                                 |
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
   
   double todayProfit = GetTodayProfit();
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance > 0 && todayProfit < 0 && MathAbs(todayProfit) >= balance * (InpMaxDailyLoss / 100.0))
      g_dailyLimitHit = true;
}

double GetTodayProfit()
{
   double profit = 0;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime todayStart = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   
   HistorySelect(todayStart, TimeCurrent());
   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == InpMagicNumber)
      {
         profit += HistoryDealGetDouble(ticket, DEAL_PROFIT);
         profit += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         profit += HistoryDealGetDouble(ticket, DEAL_SWAP);
      }
   }
   
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Magic() == InpMagicNumber)
            profit += posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
   }
   return profit;
}

void OnTrade() { g_todayPnL = GetTodayProfit(); }

//+------------------------------------------------------------------+
//| DISPLAY                                                          |
//+------------------------------------------------------------------+
void DisplayStatus(string symbol)
{
   ENUM_TREND trend = DetectTrend(symbol);
   int symIdx = (symbol == InpSymbol1) ? 0 : 1;
   
   string trendStr = (trend == TREND_BULLISH) ? "BULLISH" :
                     (trend == TREND_BEARISH) ? "BEARISH" : "RANGING";
   
   Comment(StringFormat(
      "=== ICT Smart Money EA v3.0 ===\n"
      "Symbol: %s | TF: %s\n"
      "H1 Trend: %s\n"
      "Sweep: %s (%.5f)\n"
      "MSS: %s\n"
      "Trades: %d/%d | P&L: %.2f\n"
      "Session: %s | Spread: %d\n"
      "R:R Min: %.1f | SL Mode: TIGHT (Zone-based)\n",
      symbol, EnumToString(InpEntryTF), trendStr,
      g_sweepDetected[symIdx] ? "YES" : "NO", g_sweepLevel[symIdx],
      g_mssDetected[symIdx] ? "YES" : "NO",
      g_todayTrades, InpMaxTradesDay, g_todayPnL,
      IsWithinTradingSession() ? "YES" : "NO",
      (int)SymbolInfoInteger(symbol, SYMBOL_SPREAD),
      InpMinRR_Ratio
   ));
}

//+------------------------------------------------------------------+
//| TESTER                                                           |
//+------------------------------------------------------------------+
double OnTester()
{
   double pf = TesterStatistics(STAT_PROFIT_FACTOR);
   double trades = TesterStatistics(STAT_TRADES);
   double winTrades = TesterStatistics(STAT_PROFIT_TRADES);
   double wr = (trades > 0) ? winTrades / trades : 0;
   return pf * wr * MathSqrt(trades);
}
//+------------------------------------------------------------------+
