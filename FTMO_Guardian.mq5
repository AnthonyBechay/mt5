//+------------------------------------------------------------------+
//|                                          FTMO_Guardian v3.0.mq5  |
//|                              Anthony's FTMO Challenge Guardian    |
//|                                                                   |
//|  Mode:    Semi-Discretionary Trade Management Tool                |
//|  YOU decide when to trade. The EA handles risk perfectly.         |
//|                                                                   |
//|  Shift+B  = BUY  (auto lot size, auto SL from ATR)              |
//|  Shift+S  = SELL (auto lot size, auto SL from ATR)              |
//|  Shift+X  = CLOSE all positions                                  |
//|  Shift+E  = Move all to breakeven NOW                            |
//|                                                                   |
//|  The EA:                                                          |
//|   - Calculates position size from your risk %                    |
//|   - Sets SL using ATR (adapts to current volatility)             |
//|   - Sets TP at your chosen R:R ratio                             |
//|   - Moves to breakeven automatically at target R:R               |
//|   - Trails stop in R-multiple steps                              |
//|   - Blocks trades outside your session hours                     |
//|   - Enforces daily loss cap and max drawdown                     |
//|   - Shows everything on the dashboard so you stay informed       |
//|                                                                   |
//|  You:                                                             |
//|   - Read the H4 trend (shown on dashboard)                       |
//|   - Watch for price to reach your level                          |
//|   - Press Shift+B or Shift+S when the setup looks right          |
//|   - Walk away. The EA manages the rest.                          |
//+------------------------------------------------------------------+
#property copyright "Anthony — FTMO Challenge"
#property link      "https://github.com/AnthonyBechay/mt5"
#property version   "3.00"
#property strict
#property description "Semi-discretionary FTMO trade tool."
#property description "Shift+B = Buy, Shift+S = Sell, Shift+X = Close All"
#property description "Auto lot sizing, ATR-based SL, full FTMO protection."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| INPUTS                                                            |
//+------------------------------------------------------------------+

input group "══════ FTMO CHALLENGE ══════"
input double   InpChallengeBalance   = 100000;  // Challenge starting balance
input double   InpTargetPct          = 10.0;    // Profit target % (FTMO = 10%)
input double   InpFTMO_DailyLossPct = 5.0;     // FTMO daily loss limit %
input double   InpFTMO_MaxLossPct   = 10.0;    // FTMO max loss limit %

input group "══════ RISK MANAGEMENT ══════"
input double   InpRiskPercent        = 0.5;     // Risk % per trade
input double   InpDailyLossCapPct    = 3.0;     // Our daily stop % (inside FTMO 5%)
input double   InpMaxDrawdownPct     = 8.0;     // Our max DD stop % (inside FTMO 10%)
input int      InpMaxTradesPerDay    = 3;       // Max trades per day
input int      InpMaxOpenPositions   = 2;       // Max simultaneous positions

input group "══════ SL / TP (ATR-Based) ══════"
input double   InpSL_ATR_Multiplier  = 1.5;    // SL = X times ATR(14) on H1
input double   InpTargetRR           = 3.0;     // TP = SL distance x this R:R
input int      InpATR_Period         = 14;      // ATR period for SL calculation
input ENUM_TIMEFRAMES InpATR_TF      = PERIOD_H1; // ATR timeframe

input group "══════ TRADE MANAGEMENT ══════"
input double   InpBE_TriggerRR       = 1.5;    // Move to BE at this R:R
input double   InpBE_PlusPips        = 2.0;    // Lock BE + X pips
input bool     InpTrailAfterBE       = true;    // Trail stop after BE
input double   InpTrailStepRR        = 0.5;    // Trail step in R multiples

input group "══════ SESSION HOURS ══════"
input int      InpLondonStartHour    = 8;       // London entry window start
input int      InpLondonEndHour      = 11;      // London entry window end
input int      InpNYStartHour        = 13;      // NY entry window start
input int      InpNYEndHour          = 16;      // NY session end
input bool     InpTradeLondon        = true;    // Allow London entries
input bool     InpTradeNY            = true;    // Allow NY entries
input bool     InpCloseEndOfNY       = true;    // Close all at NY end

input group "══════ ASIAN RANGE (Visual Only) ══════"
input bool     InpDrawAsianRange     = true;    // Draw Asian range on chart
input int      InpAsianStartHour     = 0;       // Asian range start
input int      InpAsianEndHour       = 7;       // Asian range end
input color    InpAsianBoxColor      = C'25,35,45';

input group "══════ FILTERS ══════"
input bool     InpUseSpreadFilter    = true;    // Block entries on wide spread
input int      InpMaxSpreadPoints    = 40;      // Max spread (points)
input bool     InpUseNewsFilter      = true;    // Pause near high-impact news
input int      InpNewsMinutesBefore  = 30;      // Minutes before news
input int      InpNewsMinutesAfter   = 15;      // Minutes after news
input bool     InpFridayFilter       = true;    // No trades Friday afternoon
input int      InpFridayCutoffHour   = 12;      // Friday cutoff hour

input group "══════ KILL SWITCH ══════"
input int      InpMaxConsecLosses    = 3;       // Consec losses → stop today

input group "══════ MANUAL TRADE BLOCKER ══════"
input bool     InpBlockManualOutside = true;    // Block clicking Buy/Sell outside hours

input group "══════ TREND DISPLAY ══════"
input int      InpEMA_Period         = 50;      // H4 EMA period (display + guidance)
input bool     InpShowSLPreview      = true;    // Show SL/TP preview lines on chart

//+------------------------------------------------------------------+
//| GLOBALS                                                           |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  posInfo;
CAccountInfo   accInfo;
CSymbolInfo    symInfo;

double   g_startingBalance;
double   g_challengeStartBalance;
double   g_asianHigh, g_asianLow;
bool     g_asianRangeSet;
int      g_tradesToday;
int      g_consecLosses;
bool     g_killSwitchActive;
string   g_killReason;
int      g_currentDay;
string   g_lastAction;           // What the EA last did (shown on dashboard)
string   g_blockReason;          // Why a trade was blocked (if blocked)
datetime g_lastBarTime;

int      g_hEMA_H4;
int      g_hATR;

string   g_prefix = "FG3_";

//+------------------------------------------------------------------+
//| OnInit                                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpRiskPercent <= 0 || InpRiskPercent > 2.0)
   {
      Alert("Risk must be 0.01-2.0%");
      return INIT_PARAMETERS_INCORRECT;
   }

   symInfo.Name(_Symbol);
   trade.SetExpertMagicNumber(240325);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);

   g_hEMA_H4 = iMA(_Symbol, PERIOD_H4, InpEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   g_hATR    = iATR(_Symbol, InpATR_TF, InpATR_Period);

   if(g_hEMA_H4 == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
   {
      Alert("Indicator handles failed.");
      return INIT_FAILED;
   }

   g_challengeStartBalance = InpChallengeBalance;
   g_startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_lastAction = "Ready. Shift+B = Buy, Shift+S = Sell";
   g_blockReason = "";

   ResetDailyState();

   //--- Enable chart events for keyboard
   ChartSetInteger(0, CHART_EVENT_OBJECT_CREATE, true);
   ChartSetInteger(0, CHART_EVENT_OBJECT_DELETE, true);

   Print("================================================");
   Print("  FTMO GUARDIAN v3.0 — SEMI-DISCRETIONARY MODE");
   Print("  Shift+B = BUY    Shift+S = SELL");
   Print("  Shift+X = CLOSE  Shift+E = BREAKEVEN");
   Print("  Challenge: $", InpChallengeBalance);
   Print("  Balance: $", g_startingBalance);
   Print("  Risk: ", InpRiskPercent, "% | SL: ", InpSL_ATR_Multiplier, "x ATR | TP: ", InpTargetRR, "R");
   Print("================================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_hEMA_H4 != INVALID_HANDLE) IndicatorRelease(g_hEMA_H4);
   if(g_hATR != INVALID_HANDLE) IndicatorRelease(g_hATR);
   ObjectsDeleteAll(0, g_prefix);
   Comment("");
}

//+------------------------------------------------------------------+
//| OnTick — trade management only, NO auto-entries                   |
//+------------------------------------------------------------------+
void OnTick()
{
   symInfo.RefreshRates();

   //--- Day change
   MqlDateTime dt;
   TimeCurrent(dt);
   if(dt.day != g_currentDay)
   {
      ResetDailyState();
      g_currentDay = dt.day;
      g_startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   }

   //--- Always manage open positions
   ManageOpenPositions();

   //--- Always check kill conditions (close if needed)
   CheckKillConditions();

   //--- Block manual trades outside hours (from MT5 buttons)
   if(InpBlockManualOutside)
      CheckManualTrades();

   //--- Session exit
   if(InpCloseEndOfNY)
      CheckSessionExit();

   //--- New H1 bar: update Asian range
   datetime barTime = iTime(_Symbol, PERIOD_H1, 0);
   if(barTime != g_lastBarTime)
   {
      g_lastBarTime = barTime;
      if(InpDrawAsianRange && !g_asianRangeSet)
         CalculateAsianRange();
   }

   //--- Update SL/TP preview lines
   if(InpShowSLPreview)
      DrawSLTPPreview();

   //--- Dashboard
   UpdateDashboard();
}

//+------------------------------------------------------------------+
//| OnChartEvent — KEYBOARD SHORTCUTS                                 |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
{
   if(id != CHARTEVENT_KEYDOWN) return;

   //--- Check for Shift modifier
   bool shiftPressed = (TerminalInfoInteger(TERMINAL_KEYSTATE_SHIFT) < 0);
   if(!shiftPressed) return;

   int key = (int)lparam;

   //--- Shift + B = BUY
   if(key == 'B')
   {
      ExecuteManualEntry(ORDER_TYPE_BUY);
      return;
   }

   //--- Shift + S = SELL
   if(key == 'S')
   {
      ExecuteManualEntry(ORDER_TYPE_SELL);
      return;
   }

   //--- Shift + X = CLOSE ALL
   if(key == 'X')
   {
      CloseAllPositions();
      return;
   }

   //--- Shift + E = MOVE ALL TO BREAKEVEN
   if(key == 'E')
   {
      ForceBreakevenAll();
      return;
   }
}

//+------------------------------------------------------------------+
//| EXECUTE MANUAL ENTRY — the core function                          |
//|                                                                   |
//| When you press Shift+B or Shift+S:                               |
//|  1. Checks all safety gates                                      |
//|  2. Gets ATR to calculate SL distance                            |
//|  3. Calculates lot size from risk % and SL distance              |
//|  4. Sets TP at your R:R ratio                                    |
//|  5. Places the trade                                             |
//|  6. You walk away. EA manages BE + trail.                        |
//+------------------------------------------------------------------+
void ExecuteManualEntry(ENUM_ORDER_TYPE orderType)
{
   string dir = (orderType == ORDER_TYPE_BUY) ? "BUY" : "SELL";

   //--- Gate 1: Kill switch
   if(g_killSwitchActive)
   {
      g_lastAction = dir + " BLOCKED: Kill switch active — " + g_killReason;
      Alert(g_lastAction);
      return;
   }

   //--- Gate 2: Max trades
   if(g_tradesToday >= InpMaxTradesPerDay)
   {
      g_lastAction = dir + " BLOCKED: Max trades today (" + IntegerToString(InpMaxTradesPerDay) + ")";
      Alert(g_lastAction);
      return;
   }

   //--- Gate 3: Max positions
   if(CountOpenPositions() >= InpMaxOpenPositions)
   {
      g_lastAction = dir + " BLOCKED: Max positions open (" + IntegerToString(InpMaxOpenPositions) + ")";
      Alert(g_lastAction);
      return;
   }

   //--- Gate 4: Session hours
   if(!IsInEntryWindow())
   {
      g_lastAction = dir + " BLOCKED: Outside trading session";
      Alert(g_lastAction);
      return;
   }

   //--- Gate 5: Friday filter
   MqlDateTime dt;
   TimeCurrent(dt);
   if(InpFridayFilter && dt.day_of_week == 5 && dt.hour >= InpFridayCutoffHour)
   {
      g_lastAction = dir + " BLOCKED: Friday afternoon";
      Alert(g_lastAction);
      return;
   }

   //--- Gate 6: Daily loss cap
   double dailyPnL = GetDailyPnL();
   double dailyLimit = g_startingBalance * (InpDailyLossCapPct / 100.0);
   if(dailyPnL <= -dailyLimit)
   {
      g_lastAction = dir + " BLOCKED: Daily loss cap reached";
      Alert(g_lastAction);
      return;
   }

   //--- Gate 7: Max drawdown
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct = ((g_challengeStartBalance - equity) / g_challengeStartBalance) * 100.0;
   if(ddPct >= InpMaxDrawdownPct)
   {
      g_lastAction = dir + " BLOCKED: Max drawdown limit";
      Alert(g_lastAction);
      return;
   }

   //--- Gate 8: Consecutive losses
   if(g_consecLosses >= InpMaxConsecLosses)
   {
      g_lastAction = dir + " BLOCKED: " + IntegerToString(g_consecLosses) + " consecutive losses";
      Alert(g_lastAction);
      return;
   }

   //--- Gate 9: Spread
   if(InpUseSpreadFilter)
   {
      int spread = (int)symInfo.Spread();
      if(spread > InpMaxSpreadPoints)
      {
         g_lastAction = StringFormat("%s BLOCKED: Spread %d pts (max %d)", dir, spread, InpMaxSpreadPoints);
         Alert(g_lastAction);
         return;
      }
   }

   //--- Gate 10: News
   if(InpUseNewsFilter && IsNearHighImpactNews())
   {
      // g_lastAction already set by news function
      Alert(g_lastAction);
      return;
   }

   //--- ALL GATES PASSED — Calculate and execute

   //--- Get ATR for SL distance
   double atrValue = GetCurrentATR();
   if(atrValue <= 0)
   {
      g_lastAction = dir + " FAILED: Could not read ATR";
      Alert(g_lastAction);
      return;
   }

   double slDistance = atrValue * InpSL_ATR_Multiplier;
   double price = (orderType == ORDER_TYPE_BUY) ? symInfo.Ask() : symInfo.Bid();

   //--- Calculate SL and TP
   double sl, tp;
   if(orderType == ORDER_TYPE_BUY)
   {
      sl = price - slDistance;
      tp = price + (slDistance * InpTargetRR);
   }
   else
   {
      sl = price + slDistance;
      tp = price - (slDistance * InpTargetRR);
   }

   //--- Position sizing from risk
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0);
   double tickSize  = symInfo.TickSize();
   double tickValue = symInfo.TickValue();

   if(tickSize <= 0 || tickValue <= 0)
   {
      g_lastAction = dir + " FAILED: Tick data unavailable";
      return;
   }

   double lotSize = (riskAmount * tickSize) / (slDistance * tickValue);

   double minLot  = symInfo.LotsMin();
   double maxLot  = symInfo.LotsMax();
   double lotStep = symInfo.LotsStep();

   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));

   // Verify actual risk
   double actualRisk = (slDistance / tickSize) * tickValue * lotSize;
   if(actualRisk > riskAmount * 1.15)
   {
      g_lastAction = StringFormat("%s BLOCKED: Risk $%.0f exceeds limit $%.0f", dir, actualRisk, riskAmount);
      return;
   }

   //--- Normalize
   int digits = (int)symInfo.Digits();
   price = NormalizeDouble(price, digits);
   sl    = NormalizeDouble(sl, digits);
   tp    = NormalizeDouble(tp, digits);

   //--- Execute
   string comment = StringFormat("FG3 %s ATR%.1f", dir, InpSL_ATR_Multiplier);
   bool result = (orderType == ORDER_TYPE_BUY) ?
      trade.Buy(lotSize, _Symbol, price, sl, tp, comment) :
      trade.Sell(lotSize, _Symbol, price, sl, tp, comment);

   if(result)
   {
      g_tradesToday++;
      g_lastAction = StringFormat("%s EXECUTED: %.2f lots | Risk $%.0f (%.1f%%) | SL %.2f (%.0f pts) | TP %.2f (1:%.1f)",
                      dir, lotSize, actualRisk, InpRiskPercent,
                      sl, slDistance / _Point, tp, InpTargetRR);
      Print(">>> ", g_lastAction);
   }
   else
   {
      g_lastAction = dir + " FAILED: " + trade.ResultRetcodeDescription();
      Print("!!! ", g_lastAction);
   }
}

//+------------------------------------------------------------------+
//| CLOSE ALL positions                                               |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != 240325 || posInfo.Symbol() != _Symbol) continue;
      if(trade.PositionClose(posInfo.Ticket()))
         closed++;
   }
   g_lastAction = StringFormat("CLOSE ALL: %d position(s) closed", closed);
   Print(g_lastAction);
}

//+------------------------------------------------------------------+
//| FORCE BREAKEVEN on all positions                                  |
//+------------------------------------------------------------------+
void ForceBreakevenAll()
{
   int moved = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != 240325 || posInfo.Symbol() != _Symbol) continue;

      double openPrice = posInfo.PriceOpen();
      double currentSL = posInfo.StopLoss();
      bool isBuy = (posInfo.PositionType() == POSITION_TYPE_BUY);

      // Only move if in profit
      double currentPrice = isBuy ? symInfo.Bid() : symInfo.Ask();
      bool inProfit = isBuy ? (currentPrice > openPrice) : (currentPrice < openPrice);
      if(!inProfit) continue;

      bool alreadyAtBE = isBuy ? (currentSL >= openPrice) : (currentSL > 0 && currentSL <= openPrice);
      if(alreadyAtBE) continue;

      double bePips = InpBE_PlusPips * _Point * 10;
      if(StringFind(_Symbol, "XAU") >= 0) bePips = InpBE_PlusPips * 0.1;

      double newSL = isBuy ? (openPrice + bePips) : (openPrice - bePips);
      newSL = NormalizeDouble(newSL, (int)symInfo.Digits());

      if(trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit()))
         moved++;
   }
   g_lastAction = StringFormat("BREAKEVEN: %d position(s) moved to BE", moved);
   Print(g_lastAction);
}

//+------------------------------------------------------------------+
//| MANAGE positions — auto BE + trail                                |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != 240325 || posInfo.Symbol() != _Symbol) continue;

      double openPrice = posInfo.PriceOpen();
      double currentSL = posInfo.StopLoss();
      double currentTP = posInfo.TakeProfit();
      bool   isBuy     = (posInfo.PositionType() == POSITION_TYPE_BUY);
      double currentPrice = isBuy ? symInfo.Bid() : symInfo.Ask();

      double riskDist = MathAbs(openPrice - currentSL);
      if(riskDist <= 0) continue;

      double priceDist = isBuy ? (currentPrice - openPrice) : (openPrice - currentPrice);
      double currentRR = priceDist / riskDist;
      int digits = (int)symInfo.Digits();

      double bePips = InpBE_PlusPips * _Point * 10;
      if(StringFind(_Symbol, "XAU") >= 0) bePips = InpBE_PlusPips * 0.1;

      //--- AUTO BREAKEVEN at target R:R
      if(currentRR >= InpBE_TriggerRR)
      {
         double newSL = isBuy ? (openPrice + bePips) : (openPrice - bePips);
         bool alreadyBE = isBuy ? (currentSL >= openPrice) : (currentSL > 0 && currentSL <= openPrice);

         if(!alreadyBE)
         {
            newSL = NormalizeDouble(newSL, digits);
            if(trade.PositionModify(posInfo.Ticket(), newSL, currentTP))
            {
               g_lastAction = StringFormat("AUTO BE: #%d SL → %.2f at %.1fR", posInfo.Ticket(), newSL, currentRR);
               Print(">>> ", g_lastAction);
            }
         }
      }

      //--- TRAILING after BE
      if(InpTrailAfterBE && currentRR >= InpBE_TriggerRR + InpTrailStepRR)
      {
         bool pastBE = isBuy ? (currentSL >= openPrice) : (currentSL > 0 && currentSL <= openPrice);
         if(pastBE)
         {
            double trailRR = MathFloor(currentRR / InpTrailStepRR) * InpTrailStepRR - InpTrailStepRR;
            double trailSL = isBuy ? (openPrice + riskDist * trailRR) : (openPrice - riskDist * trailRR);
            trailSL = NormalizeDouble(trailSL, digits);

            bool better = isBuy ? (trailSL > currentSL) : (trailSL < currentSL);
            if(better && trade.PositionModify(posInfo.Ticket(), trailSL, currentTP))
            {
               g_lastAction = StringFormat("TRAIL: #%d SL → %.2f (%.1fR locked)", posInfo.Ticket(), trailSL, trailRR);
               Print(">>> ", g_lastAction);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CHECK KILL CONDITIONS (runs every tick)                           |
//+------------------------------------------------------------------+
void CheckKillConditions()
{
   if(g_killSwitchActive) return;

   double dailyPnL = GetDailyPnL();
   double dailyLimit = g_startingBalance * (InpDailyLossCapPct / 100.0);
   if(dailyPnL <= -dailyLimit)
   {
      EngageKillSwitch(StringFormat("Daily loss $%.0f hit %.1f%% cap", MathAbs(dailyPnL), InpDailyLossCapPct));
      return;
   }

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct = ((g_challengeStartBalance - equity) / g_challengeStartBalance) * 100.0;
   if(ddPct >= InpMaxDrawdownPct)
   {
      EngageKillSwitch(StringFormat("Drawdown %.1f%% hit %.1f%% limit", ddPct, InpMaxDrawdownPct));
      return;
   }
}

//+------------------------------------------------------------------+
//| BLOCK manual trades (from MT5 buttons) outside hours              |
//+------------------------------------------------------------------+
void CheckManualTrades()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != 0) continue;

      if(!IsInEntryWindow())
      {
         ulong ticket = posInfo.Ticket();
         if(trade.PositionClose(ticket))
         {
            g_lastAction = StringFormat("BLOCKED MANUAL #%d — outside session hours. Use Shift+B/S during sessions.", ticket);
            Alert("Guardian: ", g_lastAction);
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
      double riskDist = MathAbs(openPrice - currentSL);

      // Keep if trailing well past BE (SL locked at 1R+ profit)
      bool keepOpen = false;
      if(isBuy && currentSL > openPrice + riskDist * 0.5) keepOpen = true;
      if(!isBuy && currentSL > 0 && currentSL < openPrice - riskDist * 0.5) keepOpen = true;

      if(!keepOpen)
      {
         double profit = posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
         if(trade.PositionClose(posInfo.Ticket()))
         {
            g_lastAction = StringFormat("SESSION EXIT: #%d closed at NY end. P&L $%.0f", posInfo.Ticket(), profit);
            Print(g_lastAction);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| DRAW SL/TP preview lines (where SL and TP would be right now)    |
//+------------------------------------------------------------------+
void DrawSLTPPreview()
{
   double atr = GetCurrentATR();
   if(atr <= 0) return;

   double slDist = atr * InpSL_ATR_Multiplier;
   double bid = symInfo.Bid();
   double ask = symInfo.Ask();

   // Buy preview: SL below, TP above
   double buySL = ask - slDist;
   double buyTP = ask + slDist * InpTargetRR;

   // Sell preview: SL above, TP below
   double sellSL = bid + slDist;
   double sellTP = bid - slDist * InpTargetRR;

   int digits = (int)symInfo.Digits();

   //--- Buy SL preview
   string bslName = g_prefix + "PreviewBuySL";
   if(ObjectFind(0, bslName) < 0)
      ObjectCreate(0, bslName, OBJ_HLINE, 0, 0, NormalizeDouble(buySL, digits));
   else
      ObjectSetDouble(0, bslName, OBJPROP_PRICE, NormalizeDouble(buySL, digits));
   ObjectSetInteger(0, bslName, OBJPROP_COLOR, C'80,30,30');
   ObjectSetInteger(0, bslName, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, bslName, OBJPROP_BACK, true);
   ObjectSetString(0, bslName, OBJPROP_TEXT, StringFormat("Buy SL (%.0f pts)", slDist / _Point));

   //--- Buy TP preview
   string btpName = g_prefix + "PreviewBuyTP";
   if(ObjectFind(0, btpName) < 0)
      ObjectCreate(0, btpName, OBJ_HLINE, 0, 0, NormalizeDouble(buyTP, digits));
   else
      ObjectSetDouble(0, btpName, OBJPROP_PRICE, NormalizeDouble(buyTP, digits));
   ObjectSetInteger(0, btpName, OBJPROP_COLOR, C'30,80,30');
   ObjectSetInteger(0, btpName, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, btpName, OBJPROP_BACK, true);
   ObjectSetString(0, btpName, OBJPROP_TEXT, StringFormat("Buy TP 1:%.1f", InpTargetRR));

   //--- Sell SL preview
   string sslName = g_prefix + "PreviewSellSL";
   if(ObjectFind(0, sslName) < 0)
      ObjectCreate(0, sslName, OBJ_HLINE, 0, 0, NormalizeDouble(sellSL, digits));
   else
      ObjectSetDouble(0, sslName, OBJPROP_PRICE, NormalizeDouble(sellSL, digits));
   ObjectSetInteger(0, sslName, OBJPROP_COLOR, C'80,30,30');
   ObjectSetInteger(0, sslName, OBJPROP_STYLE, STYLE_DASHDOT);
   ObjectSetInteger(0, sslName, OBJPROP_BACK, true);
   ObjectSetString(0, sslName, OBJPROP_TEXT, StringFormat("Sell SL (%.0f pts)", slDist / _Point));

   //--- Sell TP preview
   string stpName = g_prefix + "PreviewSellTP";
   if(ObjectFind(0, stpName) < 0)
      ObjectCreate(0, stpName, OBJ_HLINE, 0, 0, NormalizeDouble(sellTP, digits));
   else
      ObjectSetDouble(0, stpName, OBJPROP_PRICE, NormalizeDouble(sellTP, digits));
   ObjectSetInteger(0, stpName, OBJPROP_COLOR, C'30,80,30');
   ObjectSetInteger(0, stpName, OBJPROP_STYLE, STYLE_DASHDOT);
   ObjectSetInteger(0, stpName, OBJPROP_BACK, true);
   ObjectSetString(0, stpName, OBJPROP_TEXT, StringFormat("Sell TP 1:%.1f", InpTargetRR));
}

//+------------------------------------------------------------------+
//| ASIAN RANGE — visual reference only                               |
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
   if(startBar < 0 || endBar < 0 || startBar <= endBar) return;

   double high = 0, low = DBL_MAX;
   for(int i = endBar; i <= startBar; i++)
   {
      double h = iHigh(_Symbol, PERIOD_M15, i);
      double l = iLow(_Symbol, PERIOD_M15, i);
      if(h > high) high = h;
      if(l < low)  low  = l;
   }

   g_asianHigh = high;
   g_asianLow = low;
   g_asianRangeSet = true;

   // Draw box
   string name = g_prefix + "ABox_" + TimeToString(asianStart, TIME_DATE);
   datetime extendEnd = asianEnd + 14 * 3600;
   ObjectCreate(0, name, OBJ_RECTANGLE, 0, asianStart, high, extendEnd, low);
   ObjectSetInteger(0, name, OBJPROP_COLOR, InpAsianBoxColor);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);

   // High/low lines
   string hName = g_prefix + "AHi";
   if(ObjectFind(0, hName) < 0) ObjectCreate(0, hName, OBJ_HLINE, 0, 0, high);
   else ObjectSetDouble(0, hName, OBJPROP_PRICE, high);
   ObjectSetInteger(0, hName, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, hName, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, hName, OBJPROP_BACK, true);
   ObjectSetString(0, hName, OBJPROP_TEXT, "Asian High");

   string lName = g_prefix + "ALo";
   if(ObjectFind(0, lName) < 0) ObjectCreate(0, lName, OBJ_HLINE, 0, 0, low);
   else ObjectSetDouble(0, lName, OBJPROP_PRICE, low);
   ObjectSetInteger(0, lName, OBJPROP_COLOR, clrOrangeRed);
   ObjectSetInteger(0, lName, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, lName, OBJPROP_BACK, true);
   ObjectSetString(0, lName, OBJPROP_TEXT, "Asian Low");
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
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != 240325) return;

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
   if(profit >= 0)
   {
      g_consecLosses = 0;
      g_lastAction = StringFormat("WIN +$%.0f — streak reset", profit);
   }
   else
   {
      g_consecLosses++;
      g_lastAction = StringFormat("LOSS $%.0f — streak %d/%d", profit, g_consecLosses, InpMaxConsecLosses);
      if(g_consecLosses >= InpMaxConsecLosses)
         EngageKillSwitch(IntegerToString(g_consecLosses) + " consecutive losses");
   }
   Print(g_lastAction);
}

//+------------------------------------------------------------------+
//| HELPERS                                                           |
//+------------------------------------------------------------------+

void ResetDailyState()
{
   g_asianHigh = 0; g_asianLow = DBL_MAX;
   g_asianRangeSet = false;
   g_tradesToday = 0;
   g_killSwitchActive = false;
   g_killReason = "";
}

void EngageKillSwitch(string reason)
{
   if(g_killSwitchActive) return;
   g_killSwitchActive = true;
   g_killReason = reason;
   g_lastAction = "KILL SWITCH: " + reason;
   Print(g_lastAction);
   Alert("FTMO Guardian: ", g_lastAction);
}

double GetCurrentATR()
{
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_hATR, 0, 0, 1, buf) < 1) return 0;
   return buf[0];
}

int GetTrendDirection()
{
   double ema[];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(g_hEMA_H4, 0, 0, 1, ema) < 1) return 0;
   double price = symInfo.Bid();
   if(price > ema[0]) return +1;
   if(price < ema[0]) return -1;
   return 0;
}

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
   int h = dt.hour;
   if(InpTradeLondon && h >= InpLondonStartHour && h < InpLondonEndHour) return true;
   if(InpTradeNY && h >= InpNYStartHour && h < InpNYEndHour) return true;
   return false;
}

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
      if(event.importance != CALENDAR_IMPORTANCE_HIGH) continue;

      MqlCalendarCountry country;
      if(!CalendarCountryById(event.country_id, country)) continue;
      if(StringFind(_Symbol, country.currency) < 0 && country.currency != "USD") continue;

      datetime eventTime = values[i].time;
      long diff = (long)MathAbs((double)(eventTime - now));
      if(diff <= InpNewsMinutesBefore * 60)
      {
         g_lastAction = StringFormat("NEWS BLOCK: %s in %d min", event.name, (int)(diff / 60));
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| DASHBOARD                                                         |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double dailyPnL = GetDailyPnL();
   double dailyPct = (g_startingBalance > 0) ? (dailyPnL / g_startingBalance) * 100.0 : 0;

   double ddFromStart = g_challengeStartBalance - equity;
   double ddPct = (g_challengeStartBalance > 0) ? (ddFromStart / g_challengeStartBalance) * 100.0 : 0;
   double ftmoFloor = g_challengeStartBalance * (1 - InpFTMO_MaxLossPct / 100.0);
   double roomToFloor = equity - ftmoFloor;

   double target = g_challengeStartBalance * (1 + InpTargetPct / 100.0);
   double needed = target - equity;
   double progressPct = ((equity - g_challengeStartBalance) / (target - g_challengeStartBalance)) * 100.0;
   if(progressPct < -100) progressPct = -100;

   MqlDateTime dt;
   TimeCurrent(dt);
   string days[] = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"};

   int trend = GetTrendDirection();
   string trendStr = (trend > 0) ? "BULLISH (above EMA50)" :
                     (trend < 0) ? "BEARISH (below EMA50)" : "NEUTRAL (at EMA50)";

   double atr = GetCurrentATR();
   double slDist = atr * InpSL_ATR_Multiplier;
   double riskAmt = balance * (InpRiskPercent / 100.0);
   int spread = (int)symInfo.Spread();

   string sessionStr = IsInEntryWindow() ? ">> OPEN — You can trade <<" : "Closed — Shift+B/S blocked";

   // Open position info
   string posStr = "None";
   double openPnL = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != 240325 || posInfo.Symbol() != _Symbol) continue;
      openPnL = posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
      double openRiskDist = MathAbs(posInfo.PriceOpen() - posInfo.StopLoss());
      double openPriceDist = (posInfo.PositionType() == POSITION_TYPE_BUY) ?
         (symInfo.Bid() - posInfo.PriceOpen()) : (posInfo.PriceOpen() - symInfo.Ask());
      double openRR = (openRiskDist > 0) ? openPriceDist / openRiskDist : 0;
      posStr = StringFormat("%s %.2f lots | P&L $%.0f | %.1fR",
                (posInfo.PositionType() == POSITION_TYPE_BUY) ? "LONG" : "SHORT",
                posInfo.Volume(), openPnL, openRR);
   }

   string dash = StringFormat(
      "=====================================================\n"
      "  FTMO GUARDIAN v3.0 — %s\n"
      "  %s %04d-%02d-%02d  %02d:%02d:%02d  (server time)\n"
      "=====================================================\n"
      "\n"
      "  SHORTCUTS:\n"
      "  Shift+B = BUY    Shift+S = SELL\n"
      "  Shift+X = CLOSE  Shift+E = BREAKEVEN\n"
      "\n"
      "  ── ACCOUNT ──\n"
      "  Balance:     $%s\n"
      "  Equity:      $%s\n"
      "  Daily P&&L:   $%s  (%s%%)\n"
      "\n"
      "  ── FTMO RULES ──\n"
      "  Drawdown:    %s%%  (stop at %s%%, FTMO limit %s%%)\n"
      "  DD Floor:    $%s  (room: $%s)\n"
      "  Daily cap:   %s%%  (FTMO: %s%%)\n"
      "  Target:      $%s  (need: $%s)\n"
      "  Progress:    %s%%\n"
      "\n"
      "  ── NEXT TRADE ──\n"
      "  H4 Trend:    %s\n"
      "  Session:     %s\n"
      "  SL distance: %.0f pts (%.1f x ATR)\n"
      "  TP distance: %.0f pts (1:%.1f)\n"
      "  Risk:        $%.0f (%.1f%%)\n"
      "  Spread:      %d pts %s\n"
      "  Trades left: %d / %d\n"
      "  Consec loss: %d / %d\n"
      "\n"
      "  ── OPEN POSITION ──\n"
      "  %s\n"
      "\n"
      "  ── KILL SWITCH ──\n"
      "  %s\n"
      "\n"
      "  ── LAST ACTION ──\n"
      "  %s\n"
      "=====================================================",
      _Symbol,
      days[dt.day_of_week], dt.year, dt.mon, dt.day, dt.hour, dt.min, dt.sec,
      Fmt(balance), Fmt(equity),
      Fmt(dailyPnL), DoubleToString(dailyPct, 2),
      DoubleToString(ddPct, 2), DoubleToString(InpMaxDrawdownPct, 1), DoubleToString(InpFTMO_MaxLossPct, 1),
      Fmt(ftmoFloor), Fmt(roomToFloor),
      DoubleToString(InpDailyLossCapPct, 1), DoubleToString(InpFTMO_DailyLossPct, 1),
      Fmt(target), Fmt(needed),
      DoubleToString(progressPct, 1),
      trendStr,
      sessionStr,
      slDist / _Point, InpSL_ATR_Multiplier,
      slDist * InpTargetRR / _Point, InpTargetRR,
      riskAmt, InpRiskPercent,
      spread, (spread > InpMaxSpreadPoints) ? "!! HIGH" : "OK",
      InpMaxTradesPerDay - g_tradesToday, InpMaxTradesPerDay,
      g_consecLosses, InpMaxConsecLosses,
      posStr,
      g_killSwitchActive ? g_killReason : "OFF",
      g_lastAction
   );

   Comment(dash);
}

string Fmt(double v)
{
   string s = DoubleToString(MathAbs(v), 2);
   string sign = (v < 0) ? "-" : "";
   int dot = StringFind(s, ".");
   string ip = StringSubstr(s, 0, dot);
   string dp = StringSubstr(s, dot);
   string r = "";
   int len = StringLen(ip);
   for(int i = 0; i < len; i++)
   {
      if(i > 0 && (len - i) % 3 == 0) r += ",";
      r += StringSubstr(ip, i, 1);
   }
   return sign + r + dp;
}
//+------------------------------------------------------------------+
