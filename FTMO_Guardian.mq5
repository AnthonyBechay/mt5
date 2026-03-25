//+------------------------------------------------------------------+
//|                                               FTMO_Guardian.mq5  |
//|                                    Anthony's FTMO Challenge EA   |
//|                                                                  |
//|  Strategy: Asian Range Breakout during London/NY sessions        |
//|  Style:    Relaxed swing/day-swing — few trades per week         |
//|  Rules:    Full FTMO risk management enforcement                 |
//+------------------------------------------------------------------+
#property copyright "Anthony — FTMO Challenge"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| INPUT PARAMETERS — Tweak these, don't touch the logic            |
//+------------------------------------------------------------------+

//--- Account & Risk Management
input group "=== RISK MANAGEMENT ==="
input double   InpRiskPercent        = 0.5;     // Risk % per trade
input double   InpDailyLossCapPct    = 2.0;     // Daily loss cap %
input double   InpMaxDrawdownPct     = 9.0;     // Max drawdown % (FTMO=10, buffer=9)
input int      InpMaxTradesPerDay    = 2;        // Max trades per day
input int      InpMaxOpenPositions   = 1;        // Max simultaneous positions

//--- Strategy: Asian Range Breakout
input group "=== STRATEGY ==="
input int      InpAsianStartHour     = 0;       // Asian range start (server hour)
input int      InpAsianEndHour       = 7;       // Asian range end (server hour)
input double   InpMinRangePoints     = 300;     // Min Asian range size (points)
input double   InpMaxRangePoints     = 2000;    // Max Asian range size (points)
input double   InpBreakoutBuffer     = 50;      // Breakout buffer above/below range (points)
input double   InpMinRR              = 3.0;     // Minimum reward:risk ratio
input bool     InpRequireRetest      = false;   // Require price retest of range edge

//--- Session Filters
input group "=== SESSION FILTERS ==="
input int      InpLondonStartHour    = 8;       // London session start (server hour)
input int      InpLondonEndHour      = 11;      // London session end (server hour)
input int      InpNYStartHour        = 13;      // NY overlap start (server hour)
input int      InpNYEndHour          = 15;      // NY overlap end (server hour)
input bool     InpTradeLondon        = true;    // Trade London session
input bool     InpTradeNY            = true;    // Trade NY session

//--- Stop Loss Management
input group "=== SL MANAGEMENT ==="
input double   InpBE_TriggerRR       = 1.0;    // Move SL to BE at this R:R
input double   InpBE_PlusPips        = 2.0;    // BE + this many pips
input bool     InpTrailAfterBE       = false;  // Trail stop after BE (keep false for hands-off)

//--- Kill Switch
input group "=== KILL SWITCH ==="
input int      InpMaxConsecLosses    = 3;       // Consecutive losses → stop trading today
input bool     InpFridayFilter       = true;    // No new trades on Friday afternoon
input int      InpFridayCutoffHour   = 12;      // Friday cutoff hour (server time)

//--- Display
input group "=== DISPLAY ==="
input bool     InpShowDashboard      = true;    // Show on-chart dashboard
input color    InpDashColor          = clrWhite;
input color    InpAsianBoxColor      = clrDarkSlateGray;

//+------------------------------------------------------------------+
//| GLOBAL VARIABLES                                                  |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  posInfo;
CAccountInfo   accInfo;
CSymbolInfo    symInfo;

//--- State tracking
double   g_startingBalance;        // Balance at start of day
double   g_challengeStartBalance;  // Balance at start of challenge (set once)
double   g_asianHigh;              // Today's Asian session high
double   g_asianLow;               // Today's Asian session low
bool     g_asianRangeSet;          // Asian range calculated for today
bool     g_tradedLongToday;        // Already took a long breakout today
bool     g_tradedShortToday;       // Already took a short breakout today
int      g_tradesToday;            // Trade count today
int      g_consecLosses;           // Consecutive losses
bool     g_killSwitchActive;       // Kill switch engaged
datetime g_lastBarTime;            // For new bar detection
int      g_currentDay;             // Track day changes
bool     g_beMovedForTicket[];     // Track BE moves per position

//--- Dashboard object names
string   g_dashPrefix = "FG_";

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Validate inputs
   if(InpRiskPercent <= 0 || InpRiskPercent > 2.0)
   {
      Alert("Risk percent must be between 0.01 and 2.0. You set: ", InpRiskPercent);
      return INIT_PARAMETERS_INCORRECT;
   }
   
   if(InpMinRR < 1.0)
   {
      Alert("Minimum R:R must be >= 1.0. You set: ", InpMinRR);
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- Initialize
   symInfo.Name(_Symbol);
   trade.SetExpertMagicNumber(240325);  // Unique magic number
   trade.SetDeviationInPoints(30);      // Slippage tolerance
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   
   //--- Set starting balances
   g_startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   
   //--- Load challenge start balance from global variable (persists across restarts)
   if(!GlobalVariableCheck("FTMO_ChallengeStart"))
   {
      GlobalVariableSet("FTMO_ChallengeStart", g_startingBalance);
      g_challengeStartBalance = g_startingBalance;
   }
   else
   {
      g_challengeStartBalance = GlobalVariableGet("FTMO_ChallengeStart");
   }
   
   //--- Reset daily state
   ResetDailyState();
   
   Print("=== FTMO Guardian EA Initialized ===");
   Print("Account Balance: ", g_startingBalance);
   Print("Challenge Start: ", g_challengeStartBalance);
   Print("Risk per trade: ", InpRiskPercent, "%");
   Print("Daily loss cap: ", InpDailyLossCapPct, "%");
   Print("Symbol: ", _Symbol);
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Clean up dashboard objects
   ObjectsDeleteAll(0, g_dashPrefix);
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Refresh symbol info
   symInfo.RefreshRates();
   
   //--- Check for new day
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.day != g_currentDay)
   {
      ResetDailyState();
      g_currentDay = dt.day;
      g_startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      Print("--- New trading day. Starting balance: ", g_startingBalance, " ---");
   }
   
   //--- ALWAYS run position management (BE moves, etc.) every tick
   ManageOpenPositions();
   
   //--- Run strategy logic only on new H1 bar (performance + no overtrading)
   datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
   if(currentBarTime == g_lastBarTime) 
   {
      if(InpShowDashboard) UpdateDashboard();
      return;
   }
   g_lastBarTime = currentBarTime;
   
   //--- Build Asian range if not set
   if(!g_asianRangeSet)
      CalculateAsianRange();
   
   //--- Check all safety gates before looking for entries
   if(!PassesSafetyChecks())
   {
      if(InpShowDashboard) UpdateDashboard();
      return;
   }
   
   //--- Look for breakout entry
   CheckBreakoutEntry();
   
   //--- Update display
   if(InpShowDashboard) UpdateDashboard();
}

//+------------------------------------------------------------------+
//| RESET daily tracking state                                        |
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
   // Don't reset g_consecLosses — carries across days until a win
}

//+------------------------------------------------------------------+
//| CALCULATE Asian session range                                     |
//+------------------------------------------------------------------+
void CalculateAsianRange()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   
   //--- Only calculate after Asian session ends
   if(dt.hour < InpAsianEndHour) return;
   
   //--- Get today's date at Asian start
   datetime asianStart = StringToTime(IntegerToString(dt.year) + "." + 
                          IntegerToString(dt.mon) + "." + 
                          IntegerToString(dt.day) + " " + 
                          IntegerToString(InpAsianStartHour) + ":00");
   datetime asianEnd   = StringToTime(IntegerToString(dt.year) + "." + 
                          IntegerToString(dt.mon) + "." + 
                          IntegerToString(dt.day) + " " + 
                          IntegerToString(InpAsianEndHour) + ":00");
   
   //--- Find high and low of Asian session using M15 bars
   int startBar = iBarShift(_Symbol, PERIOD_M15, asianStart);
   int endBar   = iBarShift(_Symbol, PERIOD_M15, asianEnd);
   
   if(startBar < 0 || endBar < 0 || startBar <= endBar)
   {
      Print("Warning: Could not calculate Asian range bars. Start:", startBar, " End:", endBar);
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
   
   //--- Validate range size
   double rangePoints = (high - low) / _Point;
   if(rangePoints >= InpMinRangePoints && rangePoints <= InpMaxRangePoints)
   {
      g_asianRangeSet = true;
      DrawAsianBox(asianStart, asianEnd, high, low);
      Print("Asian Range SET — High: ", high, " Low: ", low, " Range: ", rangePoints, " pts");
   }
   else
   {
      Print("Asian Range REJECTED — Size: ", rangePoints, " pts (min:", InpMinRangePoints, " max:", InpMaxRangePoints, ")");
      g_asianRangeSet = false;
   }
}

//+------------------------------------------------------------------+
//| SAFETY CHECKS — All must pass before any entry                    |
//+------------------------------------------------------------------+
bool PassesSafetyChecks()
{
   //--- Kill switch
   if(g_killSwitchActive)
      return false;
   
   //--- Max trades per day
   if(g_tradesToday >= InpMaxTradesPerDay)
      return false;
   
   //--- Max open positions
   int openPos = CountOpenPositions();
   if(openPos >= InpMaxOpenPositions)
      return false;
   
   //--- Daily loss cap
   double dailyPnL = GetDailyPnL();
   double dailyLossLimit = g_startingBalance * (InpDailyLossCapPct / 100.0);
   if(dailyPnL <= -dailyLossLimit)
   {
      if(!g_killSwitchActive)
      {
         g_killSwitchActive = true;
         Print("!!! KILL SWITCH: Daily loss cap hit. PnL: ", dailyPnL, " Limit: -", dailyLossLimit);
         Alert("FTMO Guardian: Daily loss cap reached! Trading stopped for today.");
      }
      return false;
   }
   
   //--- Max drawdown from challenge start
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double drawdownPct = ((g_challengeStartBalance - currentEquity) / g_challengeStartBalance) * 100.0;
   if(drawdownPct >= InpMaxDrawdownPct)
   {
      g_killSwitchActive = true;
      Print("!!! KILL SWITCH: Max drawdown approaching. DD: ", drawdownPct, "%");
      Alert("FTMO Guardian: Approaching max drawdown! Trading stopped.");
      return false;
   }
   
   //--- Consecutive losses kill switch
   if(g_consecLosses >= InpMaxConsecLosses)
   {
      g_killSwitchActive = true;
      Print("!!! KILL SWITCH: ", g_consecLosses, " consecutive losses.");
      return false;
   }
   
   //--- Session filter
   if(!IsInTradingSession())
      return false;
   
   //--- Friday filter
   MqlDateTime dt;
   TimeCurrent(dt);
   if(InpFridayFilter && dt.day_of_week == 5 && dt.hour >= InpFridayCutoffHour)
      return false;
   
   //--- Monday filter — skip first 2 hours (gaps)
   if(dt.day_of_week == 1 && dt.hour < 2)
      return false;
   
   //--- Asian range must be set
   if(!g_asianRangeSet)
      return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| CHECK for breakout entry signals                                  |
//+------------------------------------------------------------------+
void CheckBreakoutEntry()
{
   double ask = symInfo.Ask();
   double bid = symInfo.Bid();
   double buffer = InpBreakoutBuffer * _Point;
   
   //--- LONG: Price breaks above Asian high + buffer
   if(!g_tradedLongToday && ask > (g_asianHigh + buffer))
   {
      double sl = g_asianLow - buffer;  // SL below Asian low
      double riskDist = ask - sl;
      double tp = ask + (riskDist * InpMinRR);  // TP at minimum R:R
      
      //--- Optional: Require retest (price pulled back to range edge on prior bar)
      if(InpRequireRetest)
      {
         double prevLow = iLow(_Symbol, PERIOD_H1, 1);
         if(prevLow > g_asianHigh + buffer) // Never came back to retest
            return;
      }
      
      ExecuteTrade(ORDER_TYPE_BUY, ask, sl, tp, "Asian Breakout LONG");
   }
   
   //--- SHORT: Price breaks below Asian low - buffer
   if(!g_tradedShortToday && bid < (g_asianLow - buffer))
   {
      double sl = g_asianHigh + buffer;  // SL above Asian high
      double riskDist = sl - bid;
      double tp = bid - (riskDist * InpMinRR);  // TP at minimum R:R
      
      if(InpRequireRetest)
      {
         double prevHigh = iHigh(_Symbol, PERIOD_H1, 1);
         if(prevHigh < g_asianLow - buffer)
            return;
      }
      
      ExecuteTrade(ORDER_TYPE_SELL, bid, sl, tp, "Asian Breakout SHORT");
   }
}

//+------------------------------------------------------------------+
//| EXECUTE a trade with proper position sizing                       |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE orderType, double price, double sl, double tp, string comment)
{
   //--- Calculate position size based on risk
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0);
   double slDistance = MathAbs(price - sl);
   
   if(slDistance <= 0)
   {
      Print("Error: SL distance is zero or negative.");
      return;
   }
   
   //--- Get tick value for proper lot calculation
   double tickSize  = symInfo.TickSize();
   double tickValue = symInfo.TickValue();
   
   if(tickSize == 0 || tickValue == 0)
   {
      Print("Error: Could not get tick size/value.");
      return;
   }
   
   double lotSize = (riskAmount * tickSize) / (slDistance * tickValue);
   
   //--- Normalize lot size to broker requirements
   double minLot  = symInfo.LotsMin();
   double maxLot  = symInfo.LotsMax();
   double lotStep = symInfo.LotsStep();
   
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   
   //--- Final safety: Check if this trade's risk exceeds our limit
   double actualRisk = (slDistance / tickSize) * tickValue * lotSize;
   double maxRiskAllowed = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0) * 1.1; // 10% tolerance
   
   if(actualRisk > maxRiskAllowed)
   {
      Print("BLOCKED: Calculated risk $", actualRisk, " exceeds max $", maxRiskAllowed);
      return;
   }
   
   //--- Normalize prices
   int digits = (int)symInfo.Digits();
   price = NormalizeDouble(price, digits);
   sl    = NormalizeDouble(sl, digits);
   tp    = NormalizeDouble(tp, digits);
   
   //--- Send order
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
      
      Print(">>> TRADE OPENED: ", comment, 
            " | Lots: ", lotSize, 
            " | Risk: $", NormalizeDouble(actualRisk, 2),
            " | SL: ", sl, 
            " | TP: ", tp,
            " | R:R 1:", InpMinRR);
   }
   else
   {
      Print("!!! TRADE FAILED: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| MANAGE open positions — BE moves, trailing                        |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   int total = PositionsTotal();
   
   for(int i = total - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != 240325) continue;  // Only our trades
      if(posInfo.Symbol() != _Symbol) continue;
      
      ulong ticket = posInfo.Ticket();
      double openPrice = posInfo.PriceOpen();
      double currentSL = posInfo.StopLoss();
      double currentTP = posInfo.TakeProfit();
      double profit    = posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
      
      //--- Calculate initial risk distance from open to SL
      double riskDist = MathAbs(openPrice - currentSL);
      if(riskDist <= 0) continue;
      
      //--- Current price distance from entry
      double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? symInfo.Bid() : symInfo.Ask();
      double priceDist = 0;
      
      if(posInfo.PositionType() == POSITION_TYPE_BUY)
         priceDist = currentPrice - openPrice;
      else
         priceDist = openPrice - currentPrice;
      
      //--- Move to Breakeven + buffer at 1:1
      double bePips = InpBE_PlusPips * _Point * 10; // Convert pips to price distance
      
      // For XAUUSD, 1 pip = 0.1, so adjust
      if(StringFind(_Symbol, "XAU") >= 0)
         bePips = InpBE_PlusPips * 0.1;
      
      if(priceDist >= riskDist * InpBE_TriggerRR)
      {
         double newSL = 0;
         bool alreadyAtBE = false;
         
         if(posInfo.PositionType() == POSITION_TYPE_BUY)
         {
            newSL = openPrice + bePips;
            if(currentSL >= openPrice) alreadyAtBE = true; // Already at or past BE
         }
         else
         {
            newSL = openPrice - bePips;
            if(currentSL <= openPrice && currentSL > 0) alreadyAtBE = true;
         }
         
         if(!alreadyAtBE)
         {
            newSL = NormalizeDouble(newSL, (int)symInfo.Digits());
            if(trade.PositionModify(ticket, newSL, currentTP))
            {
               Print(">>> BE MOVED: Ticket #", ticket, " SL → ", newSL, " (BE+", InpBE_PlusPips, " pips)");
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| TRADE RESULT TRACKING — called on trade close                     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans, 
                         const MqlTradeRequest& request, 
                         const MqlTradeResult& result)
{
   //--- Track wins/losses for kill switch
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      //--- Check if it's a close deal (entry=out)
      if(trans.deal_type == DEAL_TYPE_BUY || trans.deal_type == DEAL_TYPE_SELL)
      {
         //--- Get deal info
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
                     Print("--- Trade closed: WIN $", dealProfit, " | Consecutive losses reset.");
                  }
                  else
                  {
                     g_consecLosses++;
                     Print("--- Trade closed: LOSS $", dealProfit, " | Consecutive losses: ", g_consecLosses);
                     
                     if(g_consecLosses >= InpMaxConsecLosses)
                     {
                        g_killSwitchActive = true;
                        Alert("FTMO Guardian: ", g_consecLosses, " consecutive losses. Kill switch engaged.");
                     }
                  }
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| HELPER: Count open positions with our magic number                |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Magic() == 240325 && posInfo.Symbol() == _Symbol)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| HELPER: Get today's realized + unrealized PnL                     |
//+------------------------------------------------------------------+
double GetDailyPnL()
{
   double pnl = 0;
   
   //--- Unrealized PnL from open positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i))
      {
         if(posInfo.Magic() == 240325)
            pnl += posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
      }
   }
   
   //--- Realized PnL from today's closed trades
   datetime todayStart = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   HistorySelect(todayStart, TimeCurrent());
   
   int totalDeals = HistoryDealsTotal();
   for(int i = 0; i < totalDeals; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket > 0)
      {
         if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == 240325)
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
   }
   
   return pnl;
}

//+------------------------------------------------------------------+
//| HELPER: Check if current time is in a trading session             |
//+------------------------------------------------------------------+
bool IsInTradingSession()
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

//+------------------------------------------------------------------+
//| DRAW Asian session box on chart                                   |
//+------------------------------------------------------------------+
void DrawAsianBox(datetime startTime, datetime endTime, double high, double low)
{
   string name = g_dashPrefix + "AsianBox_" + TimeToString(startTime, TIME_DATE);
   
   //--- Extend box to end of day for visibility
   datetime extendEnd = endTime + 12 * 3600;
   
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, startTime, high, extendEnd, low);
   ObjectSetInteger(0, name, OBJPROP_COLOR, InpAsianBoxColor);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   
   //--- High line
   string highName = g_dashPrefix + "AsianHigh_" + TimeToString(startTime, TIME_DATE);
   ObjectCreate(0, highName, OBJ_HLINE, 0, 0, high);
   ObjectSetInteger(0, highName, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, highName, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, highName, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, highName, OBJPROP_BACK, true);
   
   //--- Low line  
   string lowName = g_dashPrefix + "AsianLow_" + TimeToString(startTime, TIME_DATE);
   ObjectCreate(0, lowName, OBJ_HLINE, 0, 0, low);
   ObjectSetInteger(0, lowName, OBJPROP_COLOR, clrOrangeRed);
   ObjectSetInteger(0, lowName, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, lowName, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, lowName, OBJPROP_BACK, true);
}

//+------------------------------------------------------------------+
//| UPDATE on-chart dashboard                                         |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyPnL = GetDailyPnL();
   double dailyPct = (dailyPnL / g_startingBalance) * 100.0;
   double totalDD  = ((g_challengeStartBalance - equity) / g_challengeStartBalance) * 100.0;
   int    openPos  = CountOpenPositions();
   
   string sessionStr = IsInTradingSession() ? "ACTIVE" : "CLOSED";
   string killStr    = g_killSwitchActive ? ">>> ENGAGED <<<" : "OFF";
   string rangeStr   = g_asianRangeSet ? 
                        StringFormat("%.2f — %.2f", g_asianLow, g_asianHigh) : 
                        "Not set";
   
   string dashText = StringFormat(
      "═══════════════════════════════════\n"
      "       FTMO GUARDIAN v1.0\n"
      "═══════════════════════════════════\n"
      "Balance:        $%.2f\n"
      "Equity:         $%.2f\n"
      "Daily P&L:      $%.2f  (%.2f%%)\n"
      "Total DD:       %.2f%%  / %.1f%% max\n"
      "═══════════════════════════════════\n"
      "Session:        %s\n"
      "Asian Range:    %s\n"
      "Trades Today:   %d / %d\n"
      "Open Positions: %d / %d\n"
      "Consec Losses:  %d / %d\n"
      "Kill Switch:    %s\n"
      "Risk/Trade:     %.1f%% ($%.0f)\n"
      "═══════════════════════════════════",
      balance, equity,
      dailyPnL, dailyPct,
      totalDD, InpMaxDrawdownPct,
      sessionStr,
      rangeStr,
      g_tradesToday, InpMaxTradesPerDay,
      openPos, InpMaxOpenPositions,
      g_consecLosses, InpMaxConsecLosses,
      killStr,
      InpRiskPercent, balance * (InpRiskPercent / 100.0)
   );
   
   Comment(dashText);
}

//+------------------------------------------------------------------+
