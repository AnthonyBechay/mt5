//+------------------------------------------------------------------+
//|                                          FTMO_Guardian v2.1.mq5  |
//|                              Anthony's FTMO Challenge Guardian    |
//|                                                                   |
//|  Strategy: Asian Range Breakout — H4 Trend-Filtered              |
//|  Pair:     XAUUSD (Gold) recommended                             |
//|  Style:    Relaxed semi-swing — 2-4 trades/week, A+ setups only  |
//|  Edge:     Trend alignment + session volatility + setup scoring   |
//+------------------------------------------------------------------+
#property copyright "Anthony — FTMO Challenge"
#property link      "https://github.com/AnthonyBechay/mt5"
#property version   "2.10"
#property strict
#property description "FTMO Guardian v2.1 — Professional challenge EA."
#property description "H4 trend filter, ATR gate, news/spread filter,"
#property description "setup quality scoring, manual trade blocker."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                  |
//+------------------------------------------------------------------+

//--- FTMO Challenge Config
input group "══════ FTMO CHALLENGE ══════"
input double   InpChallengeBalance   = 100000;  // Challenge starting balance (FTMO account size)
input double   InpTargetPct          = 10.0;    // Profit target % (FTMO = 10%)
input double   InpFTMO_DailyLossPct = 5.0;     // FTMO daily loss rule % (5%)
input double   InpFTMO_MaxLossPct   = 10.0;    // FTMO max loss rule % (10%)

//--- Risk Management (our buffers inside FTMO rules)
input group "══════ RISK MANAGEMENT ══════"
input double   InpRiskPercent        = 0.5;     // Risk % per trade
input double   InpDailyLossCapPct    = 3.0;     // Our daily stop % (buffer inside FTMO 5%)
input double   InpMaxDrawdownPct     = 8.0;     // Our max DD stop % (buffer inside FTMO 10%)
input int      InpMaxTradesPerDay    = 2;       // Max trades per day
input int      InpMaxOpenPositions   = 1;       // Max simultaneous positions

//--- Strategy: Asian Range Breakout
input group "══════ ASIAN RANGE BREAKOUT ══════"
input int      InpAsianStartHour     = 0;       // Asian range start (server hour)
input int      InpAsianEndHour       = 7;       // Asian range end (server hour)
input double   InpMinRangePoints     = 300;     // Min Asian range (points)
input double   InpMaxRangePoints     = 2500;    // Max Asian range (points)
input double   InpBreakoutBuffer     = 50;      // Breakout buffer (points)
input double   InpTargetRR           = 3.0;     // Target reward:risk ratio

//--- H4 Trend Filter
input group "══════ TREND FILTER (H4) ══════"
input bool     InpUseTrendFilter     = true;    // Enable H4 trend filter
input int      InpTrendEMA_Period    = 50;      // H4 EMA period
input int      InpTrendEMA_Buffer    = 0;       // Min distance from EMA (points, 0=any)

//--- ATR Volatility Gate
input group "══════ VOLATILITY FILTER ══════"
input bool     InpUseATRFilter       = true;    // Enable ATR volatility gate
input int      InpATR_Period         = 14;      // ATR period (H1)
input double   InpATR_MinMultiplier  = 0.5;     // Min ATR vs 20-day avg
input double   InpATR_MaxMultiplier  = 2.5;     // Max ATR vs 20-day avg

//--- Spread Filter
input group "══════ SPREAD FILTER ══════"
input bool     InpUseSpreadFilter    = true;    // Enable spread filter
input int      InpMaxSpreadPoints    = 40;      // Max spread (points)

//--- News Filter
input group "══════ NEWS FILTER ══════"
input bool     InpUseNewsFilter      = true;    // Enable news filter
input int      InpNewsMinutesBefore  = 30;      // Pause entries X min before news
input int      InpNewsMinutesAfter   = 15;      // Resume X min after news

//--- Session Windows
input group "══════ SESSION FILTERS ══════"
input int      InpLondonStartHour    = 8;       // London entry window start
input int      InpLondonEndHour      = 11;      // London entry window end
input int      InpNYStartHour        = 13;      // NY entry window start
input int      InpNYEndHour          = 16;      // NY session end — close trades
input bool     InpTradeLondon        = true;    // Trade London session
input bool     InpTradeNY            = true;    // Trade NY session
input bool     InpCloseEndOfNY       = true;    // Close at NY end (no overnight)

//--- SL Management
input group "══════ STOP LOSS MANAGEMENT ══════"
input double   InpBE_TriggerRR       = 1.5;    // Move SL to BE at this R:R
input double   InpBE_PlusPips        = 2.0;    // Lock in BE + X pips
input bool     InpUsePartialTP       = false;   // Enable partial TP (off = simpler, higher EV)
input double   InpPartialTP_RR       = 2.0;    // Close partial at this R:R
input double   InpPartialTP_Pct      = 30.0;   // % of position to close (30% conservative)
input bool     InpTrailAfterBE       = true;    // Trail stop after BE
input double   InpTrailStepRR        = 0.5;    // Trail step in R multiples

//--- Setup Quality
input group "══════ SETUP QUALITY ══════"
input int      InpMinSetupScore      = 3;       // Minimum score to take trade (1-5)

//--- Kill Switch
input group "══════ KILL SWITCH ══════"
input int      InpMaxConsecLosses    = 3;       // Consecutive losses → stop today
input bool     InpFridayFilter       = true;    // No trades Friday afternoon
input int      InpFridayCutoffHour   = 12;      // Friday cutoff (server hour)

//--- Manual Trade Blocker
input group "══════ MANUAL TRADE BLOCKER ══════"
input bool     InpBlockManualTrades  = true;    // Block manual trades outside hours
input bool     InpBlockManualAlways  = false;   // Block ALL manual trades

//--- Display
input group "══════ DISPLAY ══════"
input bool     InpShowDashboard      = true;    // Show on-chart dashboard
input color    InpAsianBoxColor      = C'30,40,50';

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  posInfo;
CAccountInfo   accInfo;
CSymbolInfo    symInfo;

double   g_startingBalance;       // Balance at start of today
double   g_challengeStartBalance; // FTMO challenge size (input, not detected)
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
string   g_lastSetupReason;       // Why the last trade was taken / rejected
int      g_lastSetupScore;        // Last calculated setup score

//--- Indicator handles
int      g_hEMA_H4;
int      g_hATR_H1;

//--- Partial TP tracking
#define  MAX_TRACKED_TICKETS 20
ulong    g_partialDone_Tickets[MAX_TRACKED_TICKETS];
bool     g_partialDone_Flags[MAX_TRACKED_TICKETS];
int      g_partialCount;

string   g_dashPrefix = "FGv2_";

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpRiskPercent <= 0 || InpRiskPercent > 2.0)
   {
      Alert("Risk must be 0.01-2.0%. Set: ", InpRiskPercent);
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpTargetRR < 1.5)
   {
      Alert("R:R should be >= 1.5. Set: ", InpTargetRR);
      return INIT_PARAMETERS_INCORRECT;
   }

   symInfo.Name(_Symbol);
   trade.SetExpertMagicNumber(240325);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_hEMA_H4 = iMA(_Symbol, PERIOD_H4, InpTrendEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_hATR_H1 = iATR(_Symbol, PERIOD_H1, InpATR_Period);

   if(g_hEMA_H4 == INVALID_HANDLE || g_hATR_H1 == INVALID_HANDLE)
   {
      Alert("Failed to create indicator handles.");
      return INIT_FAILED;
   }

   //--- Challenge balance is the INPUT value, not detected balance
   //--- This ensures FTMO rules are always calculated from the real starting point
   g_challengeStartBalance = InpChallengeBalance;
   g_startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   ResetDailyState();
   g_partialCount = 0;
   g_lastSetupReason = "Waiting for first session...";
   g_lastSetupScore = 0;
   ArrayInitialize(g_partialDone_Flags, false);

   Print("===============================================");
   Print("  FTMO GUARDIAN v2.1");
   Print("  Challenge: $", InpChallengeBalance, " → target $", InpChallengeBalance * (1 + InpTargetPct / 100));
   Print("  Current balance: $", g_startingBalance);
   Print("  Risk/trade: ", InpRiskPercent, "% ($", NormalizeDouble(g_startingBalance * InpRiskPercent / 100, 2), ")");
   Print("  Daily stop: ", InpDailyLossCapPct, "% (FTMO limit: ", InpFTMO_DailyLossPct, "%)");
   Print("  Max DD stop: ", InpMaxDrawdownPct, "% (FTMO limit: ", InpFTMO_MaxLossPct, "%)");
   Print("  Min setup score: ", InpMinSetupScore, "/5");
   Print("  Symbol: ", _Symbol);
   Print("  Partial TP: ", InpUsePartialTP ? "ON" : "OFF (full 3R target)");
   Print("===============================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_hEMA_H4 != INVALID_HANDLE) IndicatorRelease(g_hEMA_H4);
   if(g_hATR_H1 != INVALID_HANDLE) IndicatorRelease(g_hATR_H1);
   ObjectsDeleteAll(0, g_dashPrefix);
   Comment("");
}

//+------------------------------------------------------------------+
//| OnTick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   symInfo.RefreshRates();

   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.day != g_currentDay)
   {
      ResetDailyState();
      g_currentDay = dt.day;
      g_startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      Print("--- New day. Balance: $", g_startingBalance, " ---");
   }

   ManageOpenPositions();

   if(InpBlockManualTrades || InpBlockManualAlways)
      CheckManualTrades();

   if(InpCloseEndOfNY)
      CheckSessionExit();

   // Strategy logic on new H1 bar
   datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
   if(currentBarTime == g_lastBarTime)
   {
      if(InpShowDashboard) UpdateDashboard();
      return;
   }
   g_lastBarTime = currentBarTime;

   if(!g_asianRangeSet)
      CalculateAsianRange();

   if(!PassesSafetyChecks())
   {
      if(InpShowDashboard) UpdateDashboard();
      return;
   }

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
   g_lastSetupReason  = "New day — building Asian range...";
   g_lastSetupScore   = 0;
}

//+------------------------------------------------------------------+
//| CALCULATE Asian range                                             |
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
      return;

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
      g_lastSetupReason = StringFormat("Asian range set: %.2f-%.2f (%.0f pts). Waiting for session...",
                           low, high, rangePoints);
      Print("Asian Range: ", g_lastSetupReason);
   }
   else
   {
      g_lastSetupReason = StringFormat("Asian range rejected: %.0f pts (need %d-%d). No trades today.",
                           rangePoints, (int)InpMinRangePoints, (int)InpMaxRangePoints);
      Print(g_lastSetupReason);
   }
}

//+------------------------------------------------------------------+
//| SETUP QUALITY SCORE — rates the current opportunity 1-5           |
//|                                                                   |
//| This is what tells you WHY a trade is taken:                      |
//|  +1  H4 trend aligned with breakout direction                    |
//|  +1  ATR in healthy range (not too quiet, not overextended)      |
//|  +1  Asian range is clean (not too wide, not too narrow)         |
//|  +1  London/NY session overlap (highest liquidity)               |
//|  +1  No high-impact news nearby                                  |
//+------------------------------------------------------------------+
int CalculateSetupScore(bool isLong, string &reasoning)
{
   int score = 0;
   reasoning = "";

   //--- 1. TREND ALIGNMENT
   int trend = GetTrendDirection();
   if((isLong && trend > 0) || (!isLong && trend < 0))
   {
      score++;
      reasoning += "+Trend ";
   }
   else if(trend == 0)
   {
      // Neutral trend — not a plus, but not disqualifying either
      reasoning += "~Trend ";
   }
   else
   {
      reasoning += "-Trend ";
   }

   //--- 2. ATR HEALTH
   double atrRatio = GetATRRatio();
   if(atrRatio >= InpATR_MinMultiplier && atrRatio <= InpATR_MaxMultiplier)
   {
      score++;
      reasoning += "+ATR ";
   }
   else
   {
      reasoning += "-ATR ";
   }

   //--- 3. RANGE QUALITY (middle 60% of allowed range = best)
   double rangePoints = (g_asianHigh - g_asianLow) / _Point;
   double rangeCenter = (InpMinRangePoints + InpMaxRangePoints) / 2.0;
   double rangeSpan   = InpMaxRangePoints - InpMinRangePoints;
   if(MathAbs(rangePoints - rangeCenter) < rangeSpan * 0.3)
   {
      score++;
      reasoning += "+Range ";
   }
   else
   {
      reasoning += "~Range ";
   }

   //--- 4. SESSION TIMING (overlap hours are best)
   MqlDateTime dt;
   TimeCurrent(dt);
   int hour = dt.hour;
   // London-NY overlap (typically server hours 13-15) is prime time
   if(hour >= InpNYStartHour && hour < InpNYStartHour + 2 && InpTradeNY)
   {
      score++;
      reasoning += "+Overlap ";
   }
   else if(hour >= InpLondonStartHour && hour < InpLondonStartHour + 2 && InpTradeLondon)
   {
      score++;
      reasoning += "+LdnOpen ";
   }
   else
   {
      reasoning += "~Session ";
   }

   //--- 5. NEWS CLEAR
   if(!IsNearHighImpactNews())
   {
      score++;
      reasoning += "+NoNews";
   }
   else
   {
      reasoning += "-NEWS";
   }

   return score;
}

//+------------------------------------------------------------------+
//| SAFETY CHECKS                                                     |
//+------------------------------------------------------------------+
bool PassesSafetyChecks()
{
   if(g_killSwitchActive) return false;
   if(g_tradesToday >= InpMaxTradesPerDay)
   {
      g_lastSetupReason = "Max trades reached for today (" + IntegerToString(InpMaxTradesPerDay) + ")";
      return false;
   }
   if(CountOpenPositions() >= InpMaxOpenPositions) return false;

   //--- FTMO Daily loss (calculated from STARTING balance, per FTMO rules)
   double dailyPnL = GetDailyPnL();
   double ourDailyLimit = g_startingBalance * (InpDailyLossCapPct / 100.0);
   double ftmoDailyLimit = g_startingBalance * (InpFTMO_DailyLossPct / 100.0);

   if(dailyPnL <= -ourDailyLimit)
   {
      EngageKillSwitch(StringFormat("Daily loss cap: $%.0f (our limit: %.1f%%, FTMO limit: $%.0f)",
                        MathAbs(dailyPnL), InpDailyLossCapPct, ftmoDailyLimit));
      return false;
   }

   //--- FTMO Max drawdown (from challenge start balance, not today's balance)
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddFromStart = g_challengeStartBalance - equity;
   double ddPct = (ddFromStart / g_challengeStartBalance) * 100.0;
   double ourLimit = InpMaxDrawdownPct;
   double ftmoFloor = g_challengeStartBalance * (1 - InpFTMO_MaxLossPct / 100.0);

   if(ddPct >= ourLimit)
   {
      EngageKillSwitch(StringFormat("Drawdown %.1f%% (our limit: %.1f%%). FTMO floor: $%.0f, equity: $%.0f",
                        ddPct, ourLimit, ftmoFloor, equity));
      return false;
   }

   //--- Warn when close to FTMO floor
   if(equity - ftmoFloor < g_challengeStartBalance * 0.02)
   {
      g_lastSetupReason = StringFormat("WARNING: Only $%.0f above FTMO floor ($%.0f). Trading cautiously.",
                           equity - ftmoFloor, ftmoFloor);
   }

   //--- Consecutive losses
   if(g_consecLosses >= InpMaxConsecLosses)
   {
      EngageKillSwitch(IntegerToString(g_consecLosses) + " consecutive losses — cooling off");
      return false;
   }

   if(!IsInEntryWindow())
   {
      g_lastSetupReason = "Outside trading session. Waiting...";
      return false;
   }

   MqlDateTime dt;
   TimeCurrent(dt);
   if(InpFridayFilter && dt.day_of_week == 5 && dt.hour >= InpFridayCutoffHour)
   {
      g_lastSetupReason = "Friday afternoon — no new trades.";
      return false;
   }
   if(dt.day_of_week == 1 && dt.hour < 2)
   {
      g_lastSetupReason = "Monday early hours — skip gap risk.";
      return false;
   }

   if(!g_asianRangeSet)
   {
      g_lastSetupReason = "Asian range not valid today.";
      return false;
   }

   if(InpUseSpreadFilter)
   {
      int spread = (int)symInfo.Spread();
      if(spread > InpMaxSpreadPoints)
      {
         g_lastSetupReason = StringFormat("Spread too wide: %d pts (max %d)", spread, InpMaxSpreadPoints);
         return false;
      }
   }

   if(InpUseATRFilter && !PassesATRFilter())
      return false;

   return true;
}

//+------------------------------------------------------------------+
//| TREND DIRECTION from H4 EMA                                      |
//+------------------------------------------------------------------+
int GetTrendDirection()
{
   if(!InpUseTrendFilter) return 0;

   double emaValue[];
   ArraySetAsSeries(emaValue, true);
   if(CopyBuffer(g_hEMA_H4, 0, 0, 2, emaValue) < 2) return 0;

   double currentPrice = symInfo.Bid();
   double ema = emaValue[0];
   double bufferDist = InpTrendEMA_Buffer * _Point;

   if(currentPrice > ema + bufferDist) return +1;
   if(currentPrice < ema - bufferDist) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| ATR RATIO — current vs 20-day average                             |
//+------------------------------------------------------------------+
double GetATRRatio()
{
   double atrCurrent[];
   ArraySetAsSeries(atrCurrent, true);
   if(CopyBuffer(g_hATR_H1, 0, 0, 1, atrCurrent) < 1) return 1.0;

   double atrHistory[];
   ArraySetAsSeries(atrHistory, true);
   int bars = 24 * 20;
   if(CopyBuffer(g_hATR_H1, 0, 0, bars, atrHistory) < bars) return 1.0;

   double avg = 0;
   for(int i = 0; i < bars; i++) avg += atrHistory[i];
   avg /= bars;

   return (avg > 0) ? atrCurrent[0] / avg : 1.0;
}

bool PassesATRFilter()
{
   double ratio = GetATRRatio();
   if(ratio < InpATR_MinMultiplier)
   {
      g_lastSetupReason = StringFormat("ATR too low (%.2fx avg). Market too quiet.", ratio);
      return false;
   }
   if(ratio > InpATR_MaxMultiplier)
   {
      g_lastSetupReason = StringFormat("ATR too high (%.2fx avg). Overextended.", ratio);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| NEWS FILTER                                                       |
//+------------------------------------------------------------------+
bool IsNearHighImpactNews()
{
   if(!InpUseNewsFilter) return false;

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
      if(event.importance != CALENDAR_IMPORTANCE_HIGH) continue;

      MqlCalendarCountry country;
      if(!CalendarCountryById(event.country_id, country)) continue;

      string curr = country.currency;
      if(StringFind(_Symbol, curr) < 0 && curr != "USD") continue;

      datetime eventTime = values[i].time;
      long secsBefore = (long)(eventTime - now);
      long secsAfter  = (long)(now - eventTime);

      if(secsBefore >= 0 && secsBefore <= InpNewsMinutesBefore * 60)
      {
         g_lastSetupReason = StringFormat("News in %d min: %s — standing aside.",
                              (int)(secsBefore / 60), event.name);
         return true;
      }
      if(secsAfter >= 0 && secsAfter <= InpNewsMinutesAfter * 60)
      {
         g_lastSetupReason = StringFormat("News %d min ago: %s — waiting for dust to settle.",
                              (int)(secsAfter / 60), event.name);
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| CHECK BREAKOUT ENTRY                                              |
//+------------------------------------------------------------------+
void CheckBreakoutEntry()
{
   double ask = symInfo.Ask();
   double bid = symInfo.Bid();
   double buffer = InpBreakoutBuffer * _Point;

   //--- LONG breakout
   if(!g_tradedLongToday && ask > (g_asianHigh + buffer))
   {
      // Score the setup BEFORE deciding
      string reasoning;
      int score = CalculateSetupScore(true, reasoning);
      g_lastSetupScore = score;

      int trend = GetTrendDirection();
      if(InpUseTrendFilter && trend < 0)
      {
         g_lastSetupReason = "LONG rejected: H4 trend bearish. " + reasoning;
         g_tradedLongToday = true;
         Print(g_lastSetupReason);
         return;
      }

      if(score < InpMinSetupScore)
      {
         g_lastSetupReason = StringFormat("LONG rejected: score %d/%d (need %d). %s",
                              score, 5, InpMinSetupScore, reasoning);
         g_tradedLongToday = true;
         Print(g_lastSetupReason);
         return;
      }

      double sl = g_asianLow - buffer;
      double riskDist = ask - sl;
      double tp = ask + (riskDist * InpTargetRR);

      g_lastSetupReason = StringFormat("LONG TAKEN: score %d/5 [%s] | Entry %.2f SL %.2f TP %.2f",
                           score, reasoning, ask, sl, tp);
      Print(g_lastSetupReason);

      ExecuteTrade(ORDER_TYPE_BUY, ask, sl, tp,
                   StringFormat("ARB-L s%d %s", score, reasoning));
   }

   //--- SHORT breakout
   if(!g_tradedShortToday && bid < (g_asianLow - buffer))
   {
      string reasoning;
      int score = CalculateSetupScore(false, reasoning);
      g_lastSetupScore = score;

      int trend = GetTrendDirection();
      if(InpUseTrendFilter && trend > 0)
      {
         g_lastSetupReason = "SHORT rejected: H4 trend bullish. " + reasoning;
         g_tradedShortToday = true;
         Print(g_lastSetupReason);
         return;
      }

      if(score < InpMinSetupScore)
      {
         g_lastSetupReason = StringFormat("SHORT rejected: score %d/%d (need %d). %s",
                              score, 5, InpMinSetupScore, reasoning);
         g_tradedShortToday = true;
         Print(g_lastSetupReason);
         return;
      }

      double sl = g_asianHigh + buffer;
      double riskDist = sl - bid;
      double tp = bid - (riskDist * InpTargetRR);

      g_lastSetupReason = StringFormat("SHORT TAKEN: score %d/5 [%s] | Entry %.2f SL %.2f TP %.2f",
                           score, reasoning, bid, sl, tp);
      Print(g_lastSetupReason);

      ExecuteTrade(ORDER_TYPE_SELL, bid, sl, tp,
                   StringFormat("ARB-S s%d %s", score, reasoning));
   }
}

//+------------------------------------------------------------------+
//| EXECUTE TRADE                                                     |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE orderType, double price, double sl, double tp, string comment)
{
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0);
   double slDistance = MathAbs(price - sl);
   if(slDistance <= 0) return;

   double tickSize  = symInfo.TickSize();
   double tickValue = symInfo.TickValue();
   if(tickSize == 0 || tickValue == 0) return;

   double lotSize = (riskAmount * tickSize) / (slDistance * tickValue);

   double minLot  = symInfo.LotsMin();
   double maxLot  = symInfo.LotsMax();
   double lotStep = symInfo.LotsStep();

   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));

   // Risk verification
   double actualRisk = (slDistance / tickSize) * tickValue * lotSize;
   if(actualRisk > riskAmount * 1.1)
   {
      Print("BLOCKED: risk $", NormalizeDouble(actualRisk, 2), " > limit $", NormalizeDouble(riskAmount * 1.1, 2));
      return;
   }

   int digits = (int)symInfo.Digits();
   price = NormalizeDouble(price, digits);
   sl    = NormalizeDouble(sl, digits);
   tp    = NormalizeDouble(tp, digits);

   bool result = (orderType == ORDER_TYPE_BUY) ?
      trade.Buy(lotSize, _Symbol, price, sl, tp, comment) :
      trade.Sell(lotSize, _Symbol, price, sl, tp, comment);

   if(result)
   {
      g_tradesToday++;
      if(orderType == ORDER_TYPE_BUY) g_tradedLongToday = true;
      else g_tradedShortToday = true;

      Print(">>> EXECUTED: ", comment, " | ", lotSize, " lots | Risk $",
            NormalizeDouble(actualRisk, 2), " | R:R 1:", InpTargetRR);
   }
   else
      Print("!!! FAILED: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| MANAGE OPEN POSITIONS — BE, partial, trail                        |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != 240325 || posInfo.Symbol() != _Symbol) continue;

      ulong  ticket    = posInfo.Ticket();
      double openPrice = posInfo.PriceOpen();
      double currentSL = posInfo.StopLoss();
      double currentTP = posInfo.TakeProfit();
      double volume    = posInfo.Volume();
      bool   isBuy     = (posInfo.PositionType() == POSITION_TYPE_BUY);
      double currentPrice = isBuy ? symInfo.Bid() : symInfo.Ask();

      double riskDist = MathAbs(openPrice - currentSL);
      if(riskDist <= 0) continue;

      double priceDist = isBuy ? (currentPrice - openPrice) : (openPrice - currentPrice);
      double currentRR = priceDist / riskDist;
      int digits = (int)symInfo.Digits();

      // Pip value for BE buffer
      double bePips = InpBE_PlusPips * _Point * 10;
      if(StringFind(_Symbol, "XAU") >= 0) bePips = InpBE_PlusPips * 0.1;

      //--- PARTIAL TP (only if enabled — off by default for higher EV)
      if(InpUsePartialTP && currentRR >= InpPartialTP_RR && !IsPartialDone(ticket))
      {
         double closeLots = NormalizeDouble(volume * (InpPartialTP_Pct / 100.0), 2);
         double lotStep = symInfo.LotsStep();
         closeLots = MathFloor(closeLots / lotStep) * lotStep;
         closeLots = MathMax(symInfo.LotsMin(), closeLots);

         if(closeLots < volume)
         {
            if(trade.PositionClosePartial(ticket, closeLots))
            {
               MarkPartialDone(ticket);
               Print(">>> PARTIAL: #", ticket, " closed ", closeLots,
                     " lots (", InpPartialTP_Pct, "%) at ", NormalizeDouble(InpPartialTP_RR, 1), "R");
            }
         }
      }

      //--- BREAKEVEN
      if(currentRR >= InpBE_TriggerRR)
      {
         double newSL = isBuy ? (openPrice + bePips) : (openPrice - bePips);
         bool alreadyAtBE = isBuy ? (currentSL >= openPrice) : (currentSL > 0 && currentSL <= openPrice);

         if(!alreadyAtBE)
         {
            newSL = NormalizeDouble(newSL, digits);
            if(trade.PositionModify(ticket, newSL, currentTP))
               Print(">>> BE: #", ticket, " SL moved to ", newSL, " (BE+", InpBE_PlusPips, "p)");
         }
      }

      //--- TRAILING (after BE is set)
      if(InpTrailAfterBE && currentRR >= InpBE_TriggerRR + InpTrailStepRR)
      {
         bool pastBE = isBuy ? (currentSL >= openPrice) : (currentSL > 0 && currentSL <= openPrice);
         if(pastBE)
         {
            double trailRR = MathFloor(currentRR / InpTrailStepRR) * InpTrailStepRR - InpTrailStepRR;
            double trailSL = isBuy ? (openPrice + riskDist * trailRR) : (openPrice - riskDist * trailRR);
            trailSL = NormalizeDouble(trailSL, digits);

            bool shouldMove = isBuy ? (trailSL > currentSL) : (trailSL < currentSL);
            if(shouldMove)
            {
               if(trade.PositionModify(ticket, trailSL, currentTP))
                  Print(">>> TRAIL: #", ticket, " SL → ", trailSL, " (", NormalizeDouble(trailRR, 1), "R locked)");
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| MANUAL TRADE BLOCKER                                              |
//+------------------------------------------------------------------+
void CheckManualTrades()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic() != 0) continue; // Manual trades have magic=0

      bool shouldBlock = false;
      string reason = "";

      if(InpBlockManualAlways)
      {
         shouldBlock = true;
         reason = "Guardian mode: manual trades blocked on " + _Symbol;
      }
      else if(!IsInEntryWindow())
      {
         shouldBlock = true;
         reason = "Manual trade outside session hours";
      }

      if(shouldBlock)
      {
         ulong ticket = posInfo.Ticket();
         if(trade.PositionClose(ticket))
         {
            Print("BLOCKED MANUAL: #", ticket, " — ", reason);
            Alert("FTMO Guardian: ", reason);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| SESSION EXIT                                                      |
//+------------------------------------------------------------------+
void CheckSessionExit()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.hour < InpNYEndHour) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != 240325 || posInfo.Symbol() != _Symbol) continue;

      double openPrice = posInfo.PriceOpen();
      double currentSL = posInfo.StopLoss();
      bool isBuy = (posInfo.PositionType() == POSITION_TYPE_BUY);

      // If trailing and SL is well past BE, let it ride with the trail
      bool wellPastBE = false;
      double riskDist = MathAbs(openPrice - currentSL);
      if(isBuy && currentSL > openPrice + riskDist * 0.5) wellPastBE = true;
      if(!isBuy && currentSL > 0 && currentSL < openPrice - riskDist * 0.5) wellPastBE = true;

      if(!wellPastBE)
      {
         ulong ticket = posInfo.Ticket();
         double profit = posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
         if(trade.PositionClose(ticket))
            Print(">>> SESSION EXIT: #", ticket, " P&L $", NormalizeDouble(profit, 2));
      }
      else
      {
         Print(">>> SESSION END: #", posInfo.Ticket(), " kept open — trailing well past BE");
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
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(trans.deal_type != DEAL_TYPE_BUY && trans.deal_type != DEAL_TYPE_SELL) return;

   if(!HistoryDealSelect(trans.deal)) return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT) return;

   long dealMagic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
   if(dealMagic != 240325) return;

   double dealProfit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);

   if(dealProfit >= 0)
   {
      g_consecLosses = 0;
      Print("WIN +$", NormalizeDouble(dealProfit, 2), " | Streak reset");
   }
   else
   {
      g_consecLosses++;
      Print("LOSS $", NormalizeDouble(dealProfit, 2), " | Streak: ", g_consecLosses, "/", InpMaxConsecLosses);

      if(g_consecLosses >= InpMaxConsecLosses)
         EngageKillSwitch(IntegerToString(g_consecLosses) + " consecutive losses");
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
   g_lastSetupReason = "KILL SWITCH: " + reason;
   Print("KILL SWITCH: ", reason);
   Alert("FTMO Guardian KILL SWITCH: ", reason);
}

//+------------------------------------------------------------------+
//| HELPERS                                                           |
//+------------------------------------------------------------------+

int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Magic() == 240325 && posInfo.Symbol() == _Symbol)
            count++;
   return count;
}

double GetDailyPnL()
{
   double pnl = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Magic() == 240325)
            pnl += posInfo.Profit() + posInfo.Swap() + posInfo.Commission();

   datetime todayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   HistorySelect(todayStart, TimeCurrent());

   for(int i = 0; i < HistoryDealsTotal(); i++)
   {
      ulong t = HistoryDealGetTicket(i);
      if(t > 0 && HistoryDealGetInteger(t, DEAL_MAGIC) == 240325)
      {
         ENUM_DEAL_ENTRY e = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(t, DEAL_ENTRY);
         if(e == DEAL_ENTRY_OUT || e == DEAL_ENTRY_INOUT)
            pnl += HistoryDealGetDouble(t, DEAL_PROFIT) +
                   HistoryDealGetDouble(t, DEAL_SWAP) +
                   HistoryDealGetDouble(t, DEAL_COMMISSION);
      }
   }
   return pnl;
}

bool IsInEntryWindow()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int hour = dt.hour;
   if(InpTradeLondon && hour >= InpLondonStartHour && hour < InpLondonEndHour) return true;
   if(InpTradeNY && hour >= InpNYStartHour && hour < InpNYEndHour) return true;
   return false;
}

bool IsPartialDone(ulong ticket)
{
   for(int i = 0; i < g_partialCount; i++)
      if(g_partialDone_Tickets[i] == ticket) return g_partialDone_Flags[i];
   return false;
}

void MarkPartialDone(ulong ticket)
{
   for(int i = 0; i < g_partialCount; i++)
      if(g_partialDone_Tickets[i] == ticket) { g_partialDone_Flags[i] = true; return; }
   if(g_partialCount < MAX_TRACKED_TICKETS)
   {
      g_partialDone_Tickets[g_partialCount] = ticket;
      g_partialDone_Flags[g_partialCount] = true;
      g_partialCount++;
   }
}

//+------------------------------------------------------------------+
//| DRAW Asian box                                                    |
//+------------------------------------------------------------------+
void DrawAsianBox(datetime startTime, datetime endTime, double high, double low)
{
   string name = g_dashPrefix + "ABox_" + TimeToString(startTime, TIME_DATE);
   datetime extendEnd = endTime + 14 * 3600;

   ObjectCreate(0, name, OBJ_RECTANGLE, 0, startTime, high, extendEnd, low);
   ObjectSetInteger(0, name, OBJPROP_COLOR, InpAsianBoxColor);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);

   string hName = g_dashPrefix + "AHi_" + TimeToString(startTime, TIME_DATE);
   ObjectCreate(0, hName, OBJ_HLINE, 0, 0, high);
   ObjectSetInteger(0, hName, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, hName, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, hName, OBJPROP_BACK, true);

   string lName = g_dashPrefix + "ALo_" + TimeToString(startTime, TIME_DATE);
   ObjectCreate(0, lName, OBJ_HLINE, 0, 0, low);
   ObjectSetInteger(0, lName, OBJPROP_COLOR, clrOrangeRed);
   ObjectSetInteger(0, lName, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, lName, OBJPROP_BACK, true);
}

//+------------------------------------------------------------------+
//| DASHBOARD                                                         |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyPnL = GetDailyPnL();
   double dailyPct = (g_startingBalance > 0) ? (dailyPnL / g_startingBalance) * 100.0 : 0;

   // Drawdown from challenge start (FTMO rule)
   double ddFromStart = g_challengeStartBalance - equity;
   double ddPct = (g_challengeStartBalance > 0) ? (ddFromStart / g_challengeStartBalance) * 100.0 : 0;
   double ftmoFloor = g_challengeStartBalance * (1 - InpFTMO_MaxLossPct / 100.0);
   double roomToFloor = equity - ftmoFloor;

   // Progress
   double target = g_challengeStartBalance * (1 + InpTargetPct / 100.0);
   double profitNeeded = target - equity;
   double progressPct = ((equity - g_challengeStartBalance) / (target - g_challengeStartBalance)) * 100.0;
   if(progressPct < 0) progressPct = 0;

   // Server time
   MqlDateTime dt;
   TimeCurrent(dt);
   string dayNames[] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};

   // Trend
   int td = GetTrendDirection();
   string trendStr = (td > 0) ? "BULLISH" : (td < 0) ? "BEARISH" : "NEUTRAL";

   // Spread
   int spread = (int)symInfo.Spread();

   // Setup score display
   string scoreBar = "";
   for(int i = 0; i < 5; i++)
      scoreBar += (i < g_lastSetupScore) ? "||" : "--";

   string dash = StringFormat(
      "==============================================\n"
      "  FTMO GUARDIAN v2.1 — %s\n"
      "  %s %04d-%02d-%02d  %02d:%02d:%02d\n"
      "==============================================\n"
      "\n"
      "  Balance:     $%s\n"
      "  Equity:      $%s\n"
      "  Daily P&&L:   $%s  (%s%%)\n"
      "\n"
      "  --- FTMO RULES ---\n"
      "  Drawdown:    %s%%  (our limit %s%%, FTMO %s%%)\n"
      "  Floor:       $%s  (room: $%s)\n"
      "  Daily cap:   %s%%  (FTMO: %s%%)\n"
      "  Target:      $%s  (need $%s more)\n"
      "  Progress:    %s%%\n"
      "\n"
      "  --- STRATEGY ---\n"
      "  H4 Trend:    %s\n"
      "  Session:     %s\n"
      "  Asian Range: %s\n"
      "  Spread:      %d pts %s\n"
      "  Setup Score: [%s] %d/5  (min: %d)\n"
      "\n"
      "  --- STATUS ---\n"
      "  Trades:      %d / %d\n"
      "  Open:        %d / %d\n"
      "  Losses:      %d / %d\n"
      "  Kill Switch: %s\n"
      "  Risk:        %s%%  ($%s)\n"
      "\n"
      "  --- LAST SIGNAL ---\n"
      "  %s\n"
      "==============================================",
      _Symbol,
      dayNames[dt.day_of_week], dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec,
      FmtMoney(balance), FmtMoney(equity),
      FmtMoney(dailyPnL), DoubleToString(dailyPct, 2),
      //--- FTMO rules
      DoubleToString(ddPct, 2), DoubleToString(InpMaxDrawdownPct, 1), DoubleToString(InpFTMO_MaxLossPct, 1),
      FmtMoney(ftmoFloor), FmtMoney(roomToFloor),
      DoubleToString(InpDailyLossCapPct, 1), DoubleToString(InpFTMO_DailyLossPct, 1),
      FmtMoney(target), FmtMoney(profitNeeded),
      DoubleToString(progressPct, 1),
      //--- Strategy
      trendStr,
      IsInEntryWindow() ? "ACTIVE" : "CLOSED",
      g_asianRangeSet ? StringFormat("%.2f - %.2f (%.0f pts)", g_asianLow, g_asianHigh, (g_asianHigh - g_asianLow) / _Point) : "Not set",
      spread, (InpUseSpreadFilter && spread > InpMaxSpreadPoints) ? "HIGH" : "OK",
      scoreBar, g_lastSetupScore, InpMinSetupScore,
      //--- Status
      g_tradesToday, InpMaxTradesPerDay,
      CountOpenPositions(), InpMaxOpenPositions,
      g_consecLosses, InpMaxConsecLosses,
      g_killSwitchActive ? g_killReason : "OFF",
      DoubleToString(InpRiskPercent, 1), FmtMoney(balance * InpRiskPercent / 100),
      //--- Last signal
      g_lastSetupReason
   );

   Comment(dash);
}

string FmtMoney(double value)
{
   string str = DoubleToString(MathAbs(value), 2);
   string sign = (value < 0) ? "-" : "";
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
