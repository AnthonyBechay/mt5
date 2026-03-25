//+------------------------------------------------------------------+
//|                                          FTMO_Guardian v2.0.mq5  |
//|                              Anthony's FTMO Challenge Guardian    |
//|                                                                   |
//|  Strategy: Asian Range Breakout — H4 Trend-Filtered              |
//|  Pair:     XAUUSD (Gold) — optimized for high-ATR instruments    |
//|  Style:    Relaxed semi-swing — 2-4 trades/week, A+ setups only  |
//|  Edge:     Trend alignment + session volatility + risk mgmt      |
//+------------------------------------------------------------------+
#property copyright "Anthony — FTMO Challenge"
#property link      "https://github.com/AnthonyBechay/mt5"
#property version   "2.00"
#property strict
#property description "Professional FTMO Guardian with H4 trend filter, "
#property description "ATR volatility gate, news filter, spread filter, "
#property description "partial TP, session exit, and manual trade blocker."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

//--- Account & Risk
input group "══════ RISK MANAGEMENT ══════"
input double   InpRiskPercent        = 0.5;     // Risk % per trade (0.5 = $500 on 100k)
input double   InpDailyLossCapPct    = 4.0;     // Daily loss cap % (FTMO=5%, buffer=4%)
input double   InpMaxDrawdownPct     = 9.0;     // Max drawdown % (FTMO=10%, buffer=9%)
input int      InpMaxTradesPerDay    = 2;       // Max trades per day
input int      InpMaxOpenPositions   = 1;       // Max simultaneous positions

//--- Strategy: Asian Range Breakout
input group "══════ ASIAN RANGE BREAKOUT ══════"
input int      InpAsianStartHour     = 0;       // Asian range start (server hour)
input int      InpAsianEndHour       = 7;       // Asian range end (server hour)
input double   InpMinRangePoints     = 300;     // Min Asian range (points)
input double   InpMaxRangePoints     = 2500;    // Max Asian range (points)
input double   InpBreakoutBuffer     = 50;      // Breakout buffer (points)
input double   InpMinRR              = 3.0;     // Minimum reward:risk ratio

//--- H4 Trend Filter
input group "══════ TREND FILTER (H4) ══════"
input bool     InpUseTrendFilter     = true;    // Enable H4 trend filter
input int      InpTrendEMA_Period    = 50;      // H4 EMA period for trend
input int      InpTrendEMA_Buffer    = 0;       // Min distance from EMA (points, 0=disabled)

//--- ATR Volatility Gate
input group "══════ VOLATILITY FILTER ══════"
input bool     InpUseATRFilter       = true;    // Enable ATR volatility gate
input int      InpATR_Period         = 14;      // ATR period (H1)
input double   InpATR_MinMultiplier  = 0.5;     // Min ATR vs 20-day avg (skip if too quiet)
input double   InpATR_MaxMultiplier  = 2.5;     // Max ATR vs 20-day avg (skip if overextended)

//--- Spread Filter
input group "══════ SPREAD FILTER ══════"
input bool     InpUseSpreadFilter    = true;    // Enable spread filter
input int      InpMaxSpreadPoints    = 40;      // Max spread allowed (points)

//--- News Filter
input group "══════ NEWS FILTER ══════"
input bool     InpUseNewsFilter      = true;    // Enable news filter (MT5 calendar)
input int      InpNewsMinutesBefore  = 30;      // Minutes before news to stop entries
input int      InpNewsMinutesAfter   = 15;      // Minutes after news to resume

//--- Session Windows
input group "══════ SESSION FILTERS ══════"
input int      InpLondonStartHour    = 8;       // London session start (server hour)
input int      InpLondonEndHour      = 11;      // London entry window end
input int      InpNYStartHour        = 13;      // NY overlap start (server hour)
input int      InpNYEndHour          = 16;      // NY session end — all trades closed
input bool     InpTradeLondon        = true;    // Trade London session
input bool     InpTradeNY            = true;    // Trade NY session
input bool     InpCloseEndOfNY       = true;    // Close open trades at NY end (no overnight)

//--- Stop Loss & Take Profit Management
input group "══════ SL/TP MANAGEMENT ══════"
input double   InpBE_TriggerRR       = 1.5;    // Move SL to BE at this R:R
input double   InpBE_PlusPips        = 2.0;    // BE + this many pips lock-in
input bool     InpUsePartialTP       = true;    // Enable partial take-profit
input double   InpPartialTP_RR       = 2.0;    // Close partial at this R:R
input double   InpPartialTP_Pct      = 50.0;   // % of position to close at partial TP
input double   InpFinalTP_RR         = 4.0;    // Final TP target R:R (remainder)
input bool     InpTrailAfterPartial  = true;   // Trail stop after partial TP
input double   InpTrailStepRR        = 0.5;    // Trail step size in R multiples

//--- Kill Switch
input group "══════ KILL SWITCH ══════"
input int      InpMaxConsecLosses    = 3;       // Consecutive losses → stop for the day
input bool     InpFridayFilter       = true;    // No new trades Friday afternoon
input int      InpFridayCutoffHour   = 12;      // Friday cutoff (server hour)

//--- Manual Trade Blocker
input group "══════ MANUAL TRADE BLOCKER ══════"
input bool     InpBlockManualTrades  = true;    // Auto-close manual trades outside hours
input bool     InpBlockManualAlways  = false;   // Block ALL manual trades (full guardian mode)

//--- Display
input group "══════ DISPLAY ══════"
input bool     InpShowDashboard      = true;    // Show on-chart dashboard
input color    InpDashBgColor        = clrBlack;
input color    InpDashTextColor      = clrWhite;
input color    InpDashWarnColor      = clrOrangeRed;
input color    InpDashGoodColor      = clrLime;
input color    InpAsianBoxColor      = C'30,40,50';

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  posInfo;
CAccountInfo   accInfo;
CSymbolInfo    symInfo;

//--- State
double   g_startingBalance;
double   g_challengeStartBalance;
double   g_asianHigh;
double   g_asianLow;
bool     g_asianRangeSet;
bool     g_tradedLongToday;
bool     g_tradedShortToday;
int      g_tradesToday;
int      g_consecLosses;
bool     g_killSwitchActive;
string   g_killReason;
datetime g_lastBarTime;
int      g_currentDay;

//--- Indicator handles
int      g_hEMA_H4;
int      g_hATR_H1;

//--- Partial TP tracking (by ticket)
#define  MAX_TRACKED_TICKETS 20
ulong    g_partialDone_Tickets[MAX_TRACKED_TICKETS];
bool     g_partialDone_Flags[MAX_TRACKED_TICKETS];
int      g_partialCount;

//--- Dashboard
string   g_dashPrefix = "FGv2_";

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Validate inputs
   if(InpRiskPercent <= 0 || InpRiskPercent > 2.0)
   {
      Alert("Risk must be 0.01–2.0%. You set: ", InpRiskPercent);
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpMinRR < 1.5)
   {
      Alert("Minimum R:R should be >= 1.5 for FTMO. You set: ", InpMinRR);
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Initialize symbol
   symInfo.Name(_Symbol);
   trade.SetExpertMagicNumber(240325);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   //--- Create indicator handles
   g_hEMA_H4 = iMA(_Symbol, PERIOD_H4, InpTrendEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_hATR_H1 = iATR(_Symbol, PERIOD_H1, InpATR_Period);

   if(g_hEMA_H4 == INVALID_HANDLE || g_hATR_H1 == INVALID_HANDLE)
   {
      Alert("Failed to create indicator handles.");
      return INIT_FAILED;
   }

   //--- Balances
   g_startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(!GlobalVariableCheck("FTMO_ChallengeStart_v2"))
   {
      GlobalVariableSet("FTMO_ChallengeStart_v2", g_startingBalance);
      g_challengeStartBalance = g_startingBalance;
   }
   else
      g_challengeStartBalance = GlobalVariableGet("FTMO_ChallengeStart_v2");

   //--- Reset state
   ResetDailyState();
   g_partialCount = 0;
   ArrayInitialize(g_partialDone_Flags, false);

   Print("═══════════════════════════════════════");
   Print("  FTMO GUARDIAN v2.0 — INITIALIZED");
   Print("  Account: $", g_startingBalance);
   Print("  Challenge Start: $", g_challengeStartBalance);
   Print("  Risk/trade: ", InpRiskPercent, "% ($", NormalizeDouble(g_startingBalance * InpRiskPercent / 100, 2), ")");
   Print("  Symbol: ", _Symbol);
   Print("  Trend filter: ", InpUseTrendFilter ? "ON (H4 EMA " + IntegerToString(InpTrendEMA_Period) + ")" : "OFF");
   Print("  ATR filter: ", InpUseATRFilter ? "ON" : "OFF");
   Print("  News filter: ", InpUseNewsFilter ? "ON" : "OFF");
   Print("  Spread filter: ", InpUseSpreadFilter ? "ON (max " + IntegerToString(InpMaxSpreadPoints) + " pts)" : "OFF");
   Print("  Partial TP: ", InpUsePartialTP ? "ON (50% at 2R)" : "OFF");
   Print("  Manual blocker: ", InpBlockManualTrades ? "ON" : "OFF");
   Print("═══════════════════════════════════════");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_hEMA_H4 != INVALID_HANDLE) IndicatorRelease(g_hEMA_H4);
   if(g_hATR_H1 != INVALID_HANDLE) IndicatorRelease(g_hATR_H1);
   ObjectsDeleteAll(0, g_dashPrefix);
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   symInfo.RefreshRates();

   //--- Day change detection
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.day != g_currentDay)
   {
      ResetDailyState();
      g_currentDay = dt.day;
      g_startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      Print("─── New day. Balance: $", g_startingBalance, " ───");
   }

   //--- ALWAYS: manage open positions (BE, partials, trailing)
   ManageOpenPositions();

   //--- ALWAYS: check manual trade blocker
   if(InpBlockManualTrades || InpBlockManualAlways)
      CheckManualTrades();

   //--- ALWAYS: session exit check
   if(InpCloseEndOfNY)
      CheckSessionExit();

   //--- Strategy on new H1 bar only
   datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
   if(currentBarTime == g_lastBarTime)
   {
      if(InpShowDashboard) UpdateDashboard();
      return;
   }
   g_lastBarTime = currentBarTime;

   //--- Build Asian range
   if(!g_asianRangeSet)
      CalculateAsianRange();

   //--- Check all gates
   if(!PassesSafetyChecks())
   {
      if(InpShowDashboard) UpdateDashboard();
      return;
   }

   //--- Look for entry
   CheckBreakoutEntry();

   if(InpShowDashboard) UpdateDashboard();
}

//+------------------------------------------------------------------+
//| RESET daily state                                                 |
//+------------------------------------------------------------------+
void ResetDailyState()
{
   g_asianHigh        = 0;
   g_asianLow         = DBL_MAX;
   g_asianRangeSet    = false;
   g_tradedLongToday  = false;
   g_tradedShortToday = false;
   g_tradesToday      = 0;
   g_killSwitchActive = false;
   g_killReason       = "";
}

//+------------------------------------------------------------------+
//| CALCULATE Asian session high/low                                  |
//+------------------------------------------------------------------+
void CalculateAsianRange()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour < InpAsianEndHour) return;

   datetime asianStart = StringToTime(StringFormat("%d.%02d.%02d %02d:00",
                           dt.year, dt.mon, dt.day, InpAsianStartHour));
   datetime asianEnd   = StringToTime(StringFormat("%d.%02d.%02d %02d:00",
                           dt.year, dt.mon, dt.day, InpAsianEndHour));

   int startBar = iBarShift(_Symbol, PERIOD_M15, asianStart);
   int endBar   = iBarShift(_Symbol, PERIOD_M15, asianEnd);

   if(startBar < 0 || endBar < 0 || startBar <= endBar)
   {
      Print("Warning: Asian range bar shift failed. Start:", startBar, " End:", endBar);
      return;
   }

   double high = 0, low = DBL_MAX;
   for(int i = endBar; i <= startBar; i++)
   {
      double h = iHigh(_Symbol, PERIOD_M15, i);
      double l = iLow(_Symbol, PERIOD_M15, i);
      if(h > high) high = h;
      if(l < low)  low  = l;
   }

   g_asianHigh = high;
   g_asianLow  = low;

   double rangePoints = (high - low) / _Point;
   if(rangePoints >= InpMinRangePoints && rangePoints <= InpMaxRangePoints)
   {
      g_asianRangeSet = true;
      DrawAsianBox(asianStart, asianEnd, high, low);
      Print("✓ Asian Range: ", NormalizeDouble(low, (int)symInfo.Digits()),
            " — ", NormalizeDouble(high, (int)symInfo.Digits()),
            " (", NormalizeDouble(rangePoints, 0), " pts)");
   }
   else
   {
      Print("✗ Asian Range rejected: ", NormalizeDouble(rangePoints, 0),
            " pts (need ", InpMinRangePoints, "–", InpMaxRangePoints, ")");
   }
}

//+------------------------------------------------------------------+
//| SAFETY CHECKS — all gates must pass                               |
//+------------------------------------------------------------------+
bool PassesSafetyChecks()
{
   if(g_killSwitchActive) return false;
   if(g_tradesToday >= InpMaxTradesPerDay) return false;
   if(CountOpenPositions() >= InpMaxOpenPositions) return false;

   //--- Daily loss cap
   double dailyPnL = GetDailyPnL();
   double dailyLimit = g_startingBalance * (InpDailyLossCapPct / 100.0);
   if(dailyPnL <= -dailyLimit)
   {
      EngageKillSwitch("Daily loss cap hit: $" + DoubleToString(dailyPnL, 2));
      return false;
   }

   //--- Max drawdown
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct = ((g_challengeStartBalance - equity) / g_challengeStartBalance) * 100.0;
   if(ddPct >= InpMaxDrawdownPct)
   {
      EngageKillSwitch("Max drawdown: " + DoubleToString(ddPct, 2) + "%");
      return false;
   }

   //--- Consecutive losses
   if(g_consecLosses >= InpMaxConsecLosses)
   {
      EngageKillSwitch(IntegerToString(g_consecLosses) + " consecutive losses");
      return false;
   }

   //--- Session check
   if(!IsInEntryWindow()) return false;

   //--- Friday filter
   MqlDateTime dt;
   TimeCurrent(dt);
   if(InpFridayFilter && dt.day_of_week == 5 && dt.hour >= InpFridayCutoffHour)
      return false;

   //--- Monday gap filter
   if(dt.day_of_week == 1 && dt.hour < 2)
      return false;

   //--- Asian range must exist
   if(!g_asianRangeSet) return false;

   //--- Spread filter
   if(InpUseSpreadFilter)
   {
      int spread = (int)symInfo.Spread();
      if(spread > InpMaxSpreadPoints)
      {
         Print("Spread too wide: ", spread, " pts (max: ", InpMaxSpreadPoints, ")");
         return false;
      }
   }

   //--- ATR volatility gate
   if(InpUseATRFilter && !PassesATRFilter())
      return false;

   //--- News filter
   if(InpUseNewsFilter && IsNearHighImpactNews())
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| H4 TREND FILTER — EMA direction check                            |
//+------------------------------------------------------------------+
int GetTrendDirection()
{
   // Returns: +1 = bullish, -1 = bearish, 0 = neutral/no filter
   if(!InpUseTrendFilter) return 0;

   double emaValue[];
   ArraySetAsSeries(emaValue, true);
   if(CopyBuffer(g_hEMA_H4, 0, 0, 2, emaValue) < 2) return 0;

   double currentPrice = symInfo.Bid();
   double ema = emaValue[0];
   double bufferDist = InpTrendEMA_Buffer * _Point;

   if(currentPrice > ema + bufferDist)  return +1;  // Bullish
   if(currentPrice < ema - bufferDist)  return -1;  // Bearish

   return 0; // Too close to EMA — no clear bias
}

//+------------------------------------------------------------------+
//| ATR VOLATILITY GATE                                               |
//+------------------------------------------------------------------+
bool PassesATRFilter()
{
   double atrCurrent[];
   ArraySetAsSeries(atrCurrent, true);
   if(CopyBuffer(g_hATR_H1, 0, 0, 1, atrCurrent) < 1) return true;

   // Get 20-day average ATR for comparison
   double atrHistory[];
   ArraySetAsSeries(atrHistory, true);
   int barsNeeded = 24 * 20; // ~20 days of H1 bars
   if(CopyBuffer(g_hATR_H1, 0, 0, barsNeeded, atrHistory) < barsNeeded) return true;

   double avgATR = 0;
   for(int i = 0; i < barsNeeded; i++)
      avgATR += atrHistory[i];
   avgATR /= barsNeeded;

   if(avgATR <= 0) return true;

   double ratio = atrCurrent[0] / avgATR;

   if(ratio < InpATR_MinMultiplier)
   {
      Print("ATR too low: ratio ", NormalizeDouble(ratio, 2), " (need >", InpATR_MinMultiplier, ")");
      return false;
   }
   if(ratio > InpATR_MaxMultiplier)
   {
      Print("ATR too high: ratio ", NormalizeDouble(ratio, 2), " (max ", InpATR_MaxMultiplier, ")");
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| NEWS FILTER — MT5 Economic Calendar                               |
//+------------------------------------------------------------------+
bool IsNearHighImpactNews()
{
   datetime now = TimeCurrent();
   datetime from = now - InpNewsMinutesBefore * 60;
   datetime to   = now + InpNewsMinutesBefore * 60;

   MqlCalendarValue values[];
   int count = CalendarValueHistory(values, from, to);

   if(count <= 0) return false;

   for(int i = 0; i < count; i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event)) continue;

      // Only care about high-impact events
      if(event.importance != CALENDAR_IMPORTANCE_HIGH) continue;

      // Check if event affects our currency
      MqlCalendarCountry country;
      if(!CalendarCountryById(event.country_id, country)) continue;

      string curr = country.currency;
      // For XAUUSD, we care about USD events
      if(StringFind(_Symbol, curr) < 0 && curr != "USD") continue;

      // We're near a high-impact event
      datetime eventTime = values[i].time;
      long secsBefore = (long)(eventTime - now);
      long secsAfter  = (long)(now - eventTime);

      if(secsBefore >= 0 && secsBefore <= InpNewsMinutesBefore * 60)
      {
         Print("⚠ News filter: ", event.name, " in ", secsBefore / 60, " minutes");
         return true;
      }
      if(secsAfter >= 0 && secsAfter <= InpNewsMinutesAfter * 60)
      {
         Print("⚠ News filter: ", event.name, " was ", secsAfter / 60, " min ago");
         return true;
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| CHECK for breakout entries                                        |
//+------------------------------------------------------------------+
void CheckBreakoutEntry()
{
   double ask = symInfo.Ask();
   double bid = symInfo.Bid();
   double buffer = InpBreakoutBuffer * _Point;
   int trendDir = GetTrendDirection();

   //--- LONG: price above Asian high + buffer
   if(!g_tradedLongToday && ask > (g_asianHigh + buffer))
   {
      // Trend filter: skip longs in bearish trend
      if(trendDir < 0)
      {
         Print("Long signal rejected — H4 trend is bearish");
         g_tradedLongToday = true; // Don't keep checking
         return;
      }

      double sl = g_asianLow - buffer;
      double riskDist = ask - sl;

      // Partial TP system: set initial TP at final target
      double tp = ask + (riskDist * InpFinalTP_RR);
      if(!InpUsePartialTP)
         tp = ask + (riskDist * InpMinRR);

      ExecuteTrade(ORDER_TYPE_BUY, ask, sl, tp, "ARB Long v2");
   }

   //--- SHORT: price below Asian low - buffer
   if(!g_tradedShortToday && bid < (g_asianLow - buffer))
   {
      if(trendDir > 0)
      {
         Print("Short signal rejected — H4 trend is bullish");
         g_tradedShortToday = true;
         return;
      }

      double sl = g_asianHigh + buffer;
      double riskDist = sl - bid;

      double tp = bid - (riskDist * InpFinalTP_RR);
      if(!InpUsePartialTP)
         tp = bid - (riskDist * InpMinRR);

      ExecuteTrade(ORDER_TYPE_SELL, bid, sl, tp, "ARB Short v2");
   }
}

//+------------------------------------------------------------------+
//| EXECUTE trade with position sizing                                |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE orderType, double price, double sl, double tp, string comment)
{
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0);
   double slDistance = MathAbs(price - sl);

   if(slDistance <= 0)
   {
      Print("Error: SL distance zero.");
      return;
   }

   double tickSize  = symInfo.TickSize();
   double tickValue = symInfo.TickValue();
   if(tickSize == 0 || tickValue == 0)
   {
      Print("Error: tick size/value unavailable.");
      return;
   }

   double lotSize = (riskAmount * tickSize) / (slDistance * tickValue);

   double minLot  = symInfo.LotsMin();
   double maxLot  = symInfo.LotsMax();
   double lotStep = symInfo.LotsStep();

   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));

   // Final risk verification
   double actualRisk = (slDistance / tickSize) * tickValue * lotSize;
   double maxAllowed = riskAmount * 1.1;
   if(actualRisk > maxAllowed)
   {
      Print("BLOCKED: risk $", NormalizeDouble(actualRisk, 2), " > max $", NormalizeDouble(maxAllowed, 2));
      return;
   }

   int digits = (int)symInfo.Digits();
   price = NormalizeDouble(price, digits);
   sl    = NormalizeDouble(sl, digits);
   tp    = NormalizeDouble(tp, digits);

   bool result = false;
   if(orderType == ORDER_TYPE_BUY)
      result = trade.Buy(lotSize, _Symbol, price, sl, tp, comment);
   else
      result = trade.Sell(lotSize, _Symbol, price, sl, tp, comment);

   if(result)
   {
      g_tradesToday++;
      if(orderType == ORDER_TYPE_BUY)
         g_tradedLongToday = true;
      else
         g_tradedShortToday = true;

      Print(">>> TRADE: ", comment,
            " | Lots: ", lotSize,
            " | Risk: $", NormalizeDouble(actualRisk, 2),
            " | SL: ", sl, " | TP: ", tp,
            " | Trend: ", GetTrendDirection() > 0 ? "BULL" : GetTrendDirection() < 0 ? "BEAR" : "NEUTRAL");
   }
   else
      Print("!!! TRADE FAILED: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| MANAGE open positions — BE, partial TP, trailing                  |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != 240325) continue;
      if(posInfo.Symbol() != _Symbol) continue;

      ulong  ticket    = posInfo.Ticket();
      double openPrice = posInfo.PriceOpen();
      double currentSL = posInfo.StopLoss();
      double currentTP = posInfo.TakeProfit();
      double volume    = posInfo.Volume();
      bool   isBuy     = (posInfo.PositionType() == POSITION_TYPE_BUY);
      double currentPrice = isBuy ? symInfo.Bid() : symInfo.Ask();

      double riskDist  = MathAbs(openPrice - currentSL);
      if(riskDist <= 0) continue;

      double priceDist = isBuy ? (currentPrice - openPrice) : (openPrice - currentPrice);
      double currentRR = priceDist / riskDist;

      int digits = (int)symInfo.Digits();

      //--- Calculate pip value for this symbol
      double bePips = InpBE_PlusPips * _Point * 10;
      if(StringFind(_Symbol, "XAU") >= 0)
         bePips = InpBE_PlusPips * 0.1;

      //--- 1. PARTIAL TP: Close 50% at target R:R
      if(InpUsePartialTP && currentRR >= InpPartialTP_RR)
      {
         if(!IsPartialDone(ticket))
         {
            double closeLots = NormalizeDouble(volume * (InpPartialTP_Pct / 100.0), 2);
            double lotStep = symInfo.LotsStep();
            closeLots = MathFloor(closeLots / lotStep) * lotStep;
            closeLots = MathMax(symInfo.LotsMin(), closeLots);

            if(closeLots < volume) // Don't close entire position
            {
               if(trade.PositionClosePartial(ticket, closeLots))
               {
                  MarkPartialDone(ticket);
                  Print(">>> PARTIAL TP: Ticket #", ticket,
                        " closed ", closeLots, " lots at ",
                        NormalizeDouble(InpPartialTP_RR, 1), "R");
               }
            }
         }
      }

      //--- 2. BREAKEVEN: Move SL to entry + buffer
      if(currentRR >= InpBE_TriggerRR)
      {
         double newSL = isBuy ? (openPrice + bePips) : (openPrice - bePips);
         bool alreadyAtBE = isBuy ? (currentSL >= openPrice) : (currentSL <= openPrice && currentSL > 0);

         if(!alreadyAtBE)
         {
            newSL = NormalizeDouble(newSL, digits);
            if(trade.PositionModify(ticket, newSL, currentTP))
               Print(">>> BE MOVED: #", ticket, " SL → ", newSL);
         }
      }

      //--- 3. TRAILING STOP: After partial TP taken, trail in R steps
      if(InpTrailAfterPartial && IsPartialDone(ticket) && currentRR >= InpPartialTP_RR + InpTrailStepRR)
      {
         double trailRR = MathFloor(currentRR / InpTrailStepRR) * InpTrailStepRR - InpTrailStepRR;
         double trailSL = 0;

         if(isBuy)
            trailSL = openPrice + (riskDist * trailRR);
         else
            trailSL = openPrice - (riskDist * trailRR);

         trailSL = NormalizeDouble(trailSL, digits);

         bool shouldUpdate = isBuy ? (trailSL > currentSL) : (trailSL < currentSL);
         if(shouldUpdate)
         {
            if(trade.PositionModify(ticket, trailSL, currentTP))
               Print(">>> TRAIL: #", ticket, " SL → ", trailSL, " (", NormalizeDouble(trailRR, 1), "R locked)");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| MANUAL TRADE BLOCKER                                              |
//+------------------------------------------------------------------+
void CheckManualTrades()
{
   int total = PositionsTotal();

   for(int i = total - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;

      // Manual trades have magic number 0
      if(posInfo.Magic() != 0) continue;

      bool shouldBlock = false;
      string reason = "";

      if(InpBlockManualAlways)
      {
         shouldBlock = true;
         reason = "Guardian mode: all manual trades blocked";
      }
      else if(!IsInEntryWindow())
      {
         shouldBlock = true;
         reason = "Manual trade outside allowed session hours";
      }

      if(shouldBlock)
      {
         ulong ticket = posInfo.Ticket();
         if(trade.PositionClose(ticket))
         {
            Print("⛔ BLOCKED MANUAL TRADE: Ticket #", ticket, " — ", reason);
            Alert("FTMO Guardian blocked a manual trade: ", reason);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| SESSION EXIT — Close trades at end of NY                          |
//+------------------------------------------------------------------+
void CheckSessionExit()
{
   MqlDateTime dt;
   TimeCurrent(dt);

   if(dt.hour < InpNYEndHour) return;

   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != 240325) continue;
      if(posInfo.Symbol() != _Symbol) continue;

      // Check if SL is already at or past breakeven
      double openPrice = posInfo.PriceOpen();
      double currentSL = posInfo.StopLoss();
      bool isBuy = (posInfo.PositionType() == POSITION_TYPE_BUY);
      bool atBE = isBuy ? (currentSL >= openPrice) : (currentSL > 0 && currentSL <= openPrice);

      // If already at BE+ with partial taken, let it ride until hard TP
      // Otherwise close to avoid overnight risk
      if(!atBE || !IsPartialDone(posInfo.Ticket()))
      {
         ulong ticket = posInfo.Ticket();
         double profit = posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
         if(trade.PositionClose(ticket))
         {
            Print(">>> SESSION EXIT: #", ticket, " closed at NY end. P&L: $",
                  NormalizeDouble(profit, 2));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| TRADE RESULT TRACKING                                             |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                         const MqlTradeRequest& request,
                         const MqlTradeResult& result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(trans.deal_type == DEAL_TYPE_BUY || trans.deal_type == DEAL_TYPE_SELL)
      {
         if(HistoryDealSelect(trans.deal))
         {
            ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
            if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
            {
               double dealProfit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
               long   dealMagic  = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);

               if(dealMagic == 240325)
               {
                  if(dealProfit >= 0)
                  {
                     g_consecLosses = 0;
                     Print("✓ WIN: +$", NormalizeDouble(dealProfit, 2),
                           " | Streak reset");
                  }
                  else
                  {
                     g_consecLosses++;
                     Print("✗ LOSS: $", NormalizeDouble(dealProfit, 2),
                           " | Streak: ", g_consecLosses, "/", InpMaxConsecLosses);

                     if(g_consecLosses >= InpMaxConsecLosses)
                        EngageKillSwitch(IntegerToString(g_consecLosses) + " consecutive losses");
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| KILL SWITCH                                                       |
//+------------------------------------------------------------------+
void EngageKillSwitch(string reason)
{
   if(g_killSwitchActive) return;
   g_killSwitchActive = true;
   g_killReason = reason;
   Print("⛔ KILL SWITCH ENGAGED: ", reason);
   Alert("FTMO Guardian: KILL SWITCH — ", reason);
}

//+------------------------------------------------------------------+
//| HELPERS                                                           |
//+------------------------------------------------------------------+

int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Magic() == 240325 && posInfo.Symbol() == _Symbol)
            count++;
   }
   return count;
}

double GetDailyPnL()
{
   double pnl = 0;

   // Unrealized
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
         if(posInfo.Magic() == 240325)
            pnl += posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
   }

   // Realized today
   datetime todayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   HistorySelect(todayStart, TimeCurrent());

   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket > 0 && HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == 240325)
      {
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
         {
            pnl += HistoryDealGetDouble(dealTicket, DEAL_PROFIT) +
                   HistoryDealGetDouble(dealTicket, DEAL_SWAP) +
                   HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         }
      }
   }

   return pnl;
}

bool IsInEntryWindow()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int hour = dt.hour;

   if(InpTradeLondon && hour >= InpLondonStartHour && hour < InpLondonEndHour)
      return true;
   if(InpTradeNY && hour >= InpNYStartHour && hour < InpNYEndHour)
      return true;

   return false;
}

//--- Partial TP tracking
bool IsPartialDone(ulong ticket)
{
   for(int i = 0; i < g_partialCount; i++)
      if(g_partialDone_Tickets[i] == ticket)
         return g_partialDone_Flags[i];
   return false;
}

void MarkPartialDone(ulong ticket)
{
   // Check if already tracked
   for(int i = 0; i < g_partialCount; i++)
   {
      if(g_partialDone_Tickets[i] == ticket)
      {
         g_partialDone_Flags[i] = true;
         return;
      }
   }
   // Add new entry
   if(g_partialCount < MAX_TRACKED_TICKETS)
   {
      g_partialDone_Tickets[g_partialCount] = ticket;
      g_partialDone_Flags[g_partialCount] = true;
      g_partialCount++;
   }
}

//+------------------------------------------------------------------+
//| DRAW Asian range box                                              |
//+------------------------------------------------------------------+
void DrawAsianBox(datetime startTime, datetime endTime, double high, double low)
{
   string name = g_dashPrefix + "ABox_" + TimeToString(startTime, TIME_DATE);
   datetime extendEnd = endTime + 14 * 3600;

   ObjectCreate(0, name, OBJ_RECTANGLE, 0, startTime, high, extendEnd, low);
   ObjectSetInteger(0, name, OBJPROP_COLOR, InpAsianBoxColor);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);

   // High level
   string hName = g_dashPrefix + "AHi_" + TimeToString(startTime, TIME_DATE);
   ObjectCreate(0, hName, OBJ_HLINE, 0, 0, high);
   ObjectSetInteger(0, hName, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, hName, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, hName, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, hName, OBJPROP_BACK, true);

   // Low level
   string lName = g_dashPrefix + "ALo_" + TimeToString(startTime, TIME_DATE);
   ObjectCreate(0, lName, OBJ_HLINE, 0, 0, low);
   ObjectSetInteger(0, lName, OBJPROP_COLOR, clrOrangeRed);
   ObjectSetInteger(0, lName, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, lName, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, lName, OBJPROP_BACK, true);
}

//+------------------------------------------------------------------+
//| DASHBOARD — on-chart display with server time                     |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyPnL = GetDailyPnL();
   double dailyPct = (g_startingBalance > 0) ? (dailyPnL / g_startingBalance) * 100.0 : 0;
   double totalDD  = (g_challengeStartBalance > 0) ?
                     ((g_challengeStartBalance - equity) / g_challengeStartBalance) * 100.0 : 0;
   int    openPos  = CountOpenPositions();

   //--- Server time
   MqlDateTime dt;
   TimeCurrent(dt);
   string serverTime = StringFormat("%04d-%02d-%02d  %02d:%02d:%02d",
                        dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec);
   string dayNames[] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
   string dayName = dayNames[dt.day_of_week];

   //--- Status strings
   string sessionStr = IsInEntryWindow() ? "● ACTIVE" : "○ CLOSED";
   string killStr    = g_killSwitchActive ? ">>> " + g_killReason + " <<<" : "OFF";
   string trendStr   = "—";
   int td = GetTrendDirection();
   if(td > 0)       trendStr = "▲ BULLISH";
   else if(td < 0)  trendStr = "▼ BEARISH";
   else              trendStr = "◆ NEUTRAL";

   string rangeStr = g_asianRangeSet ?
      StringFormat("%.2f — %.2f (%.0f pts)", g_asianLow, g_asianHigh,
                    (g_asianHigh - g_asianLow) / _Point) :
      "Not set";

   //--- Spread
   int spread = (int)symInfo.Spread();
   string spreadStr = IntegerToString(spread) + " pts";
   if(InpUseSpreadFilter)
      spreadStr += (spread <= InpMaxSpreadPoints) ? " ✓" : " ✗";

   //--- Progress toward target
   double profitFromStart = equity - g_challengeStartBalance;
   double targetAmount = g_challengeStartBalance * 0.10; // 10% target
   double progressPct = (targetAmount > 0) ? (profitFromStart / targetAmount) * 100.0 : 0;

   string dashText = StringFormat(
      "═══════════════════════════════════════════\n"
      "       FTMO GUARDIAN v2.0 — %s\n"
      "       Server: %s  %s\n"
      "═══════════════════════════════════════════\n"
      " Balance:       $%s\n"
      " Equity:        $%s\n"
      " Daily P&&L:     $%s  (%s%%)\n"
      " Drawdown:      %s%%  /  %.1f%% max\n"
      "───────────────────────────────────────────\n"
      " Challenge:     $%s  →  target $%s\n"
      " Progress:      %s%%\n"
      "───────────────────────────────────────────\n"
      " H4 Trend:      %s\n"
      " Session:       %s\n"
      " Asian Range:   %s\n"
      " Spread:        %s\n"
      "───────────────────────────────────────────\n"
      " Trades Today:  %d / %d\n"
      " Open:          %d / %d\n"
      " Consec Losses: %d / %d\n"
      " Kill Switch:   %s\n"
      " Risk/Trade:    %.1f%%  ($%.0f)\n"
      "═══════════════════════════════════════════",
      _Symbol,
      serverTime, dayName,
      FormatMoney(balance), FormatMoney(equity),
      FormatMoney(dailyPnL), DoubleToString(dailyPct, 2),
      DoubleToString(totalDD, 2), InpMaxDrawdownPct,
      FormatMoney(g_challengeStartBalance), FormatMoney(g_challengeStartBalance * 1.10),
      DoubleToString(progressPct, 1),
      trendStr,
      sessionStr,
      rangeStr,
      spreadStr,
      g_tradesToday, InpMaxTradesPerDay,
      openPos, InpMaxOpenPositions,
      g_consecLosses, InpMaxConsecLosses,
      killStr,
      InpRiskPercent, balance * (InpRiskPercent / 100.0)
   );

   Comment(dashText);
}

//--- Format number with commas
string FormatMoney(double value)
{
   string str = DoubleToString(MathAbs(value), 2);
   string sign = (value < 0) ? "-" : "";

   // Insert commas
   int dotPos = StringFind(str, ".");
   string intPart = StringSubstr(str, 0, dotPos);
   string decPart = StringSubstr(str, dotPos);

   string result = "";
   int len = StringLen(intPart);
   for(int i = 0; i < len; i++)
   {
      if(i > 0 && (len - i) % 3 == 0) result += ",";
      result += StringSubstr(intPart, i, 1);
   }

   return sign + result + decPart;
}

//+------------------------------------------------------------------+
