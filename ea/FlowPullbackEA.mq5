//+------------------------------------------------------------------+
//|                                               FlowPullbackEA.mq5 |
//|                                                             Flow |
//+------------------------------------------------------------------+
//| Trend-pullback Expert Advisor for MetaTrader 5.                  |
//|                                                                  |
//| Idea: bank small profits often (partial close at TP1, stop to    |
//| breakeven) and let the rest run with an ATR trailing stop when   |
//| the trend is strong. Built for small (cent) accounts.            |
//|                                                                  |
//| Rules                                                            |
//|  Trend  (H1) : EMA50 > EMA200 -> buys only                       |
//|                EMA50 < EMA200 -> sells only                      |
//|  Entry (M15) : price touched EMA20 within the last N closed bars,|
//|                the last closed bar closed back beyond EMA20 in   |
//|                the trend direction (with-trend candle) and       |
//|                RSI14 > 50 for buys / < 50 for sells              |
//|  Stop loss   : 1.5 x ATR14, lot sized to risk X% of the balance; |
//|                if even the minimum lot risks more, skip the trade|
//|  TP1         : 1.0 x ATR -> close 50%, stop to entry + buffer    |
//|  Runner      : ATR trailing stop (1.5 x ATR). H1 ADX > 25 ->     |
//|                no fixed target, otherwise TP2 = 2.5 x ATR        |
//|  Safety      : spread / session / news / weekend filters,        |
//|                max trades per day, daily loss limit, equity      |
//|                drawdown kill switch.                             |
//|                NO martingale, NO grid, NO averaging down.        |
//+------------------------------------------------------------------+
#property copyright   "Flow"
#property version     "1.00"
#property description "Trend pullback EA: H1 EMA50/200 trend filter, M15 EMA20 pullback entry."
#property description "ATR stop, partial close at TP1 + breakeven, ATR trailing runner."
#property description "Fixed % risk, daily loss limit, drawdown kill switch. No martingale / grid."

#include <Trade\Trade.mqh>

#define EA_NAME          "FlowPullbackEA"
#define EA_VERSION       "1.00"
#define MAX_CHASE_ATR    0.5   // drop a signal if price already ran this many ATRs away
#define MAX_ENTRY_TRIES  3     // order attempts per signal

//--- inputs ----------------------------------------------------------
input group "=== Risk management ==="
input double InpRiskPercent        = 1.5;      // Risk per trade (% of balance, max 5)
input double InpMaxDailyLossPct    = 4.0;      // Daily loss limit (%) -> no new trades today
input double InpMaxDrawdownPct     = 20.0;     // Max drawdown from equity peak (%) -> EA halts
input int    InpMaxTradesPerDay    = 8;        // Max new trades per day
input int    InpMaxPositions       = 3;        // Max open positions (extra only if others are risk-free)
input double InpMaxLots            = 0.0;      // Hard cap on lot size (0 = no cap)
input bool   InpResetPeak          = false;    // Reset equity peak + halt flag on start

input group "=== Timeframes ==="
input ENUM_TIMEFRAMES InpTrendTF   = PERIOD_H1;   // Trend timeframe
input ENUM_TIMEFRAMES InpEntryTF   = PERIOD_M15;  // Entry timeframe

input group "=== Trend filter ==="
input int    InpTrendFastEMA       = 50;       // Trend fast EMA
input int    InpTrendSlowEMA       = 200;      // Trend slow EMA
input int    InpADXPeriod          = 14;       // ADX period (trend timeframe)
input double InpADXStrong          = 25.0;     // ADX above this = strong trend (runner has no TP2)

input group "=== Entry (pullback) ==="
input int    InpEntryEMA           = 20;       // Pullback EMA (entry timeframe)
input int    InpTouchLookback      = 3;        // Closed bars to look back for the EMA touch
input int    InpRSIPeriod          = 14;       // RSI period
input double InpRSILevel           = 50.0;     // Buy: RSI > level, Sell: RSI < 100 - level
input bool   InpRequireCandleDir   = true;     // Signal candle must close in the trade direction
input int    InpSignalValidMin     = 5;        // Minutes after bar open a signal stays valid

input group "=== Exits (multiples of ATR) ==="
input int    InpATRPeriod          = 14;       // ATR period (entry timeframe)
input double InpSLATR              = 1.5;      // Stop loss distance
input double InpTP1ATR             = 1.0;      // TP1 distance (bank profit + breakeven)
input double InpTP1ClosePct        = 50.0;     // % of the position closed at TP1
input double InpBEBufferATR        = 0.1;      // Breakeven stop = entry +/- this
input double InpTP2ATR             = 2.5;      // TP2 for the runner when the trend is NOT strong
input double InpTrailATR           = 1.5;      // Trailing stop distance for the runner
input double InpTrailStepATR       = 0.1;      // Minimum stop improvement per modification

input group "=== Filters ==="
input double InpMaxSpreadPctATR    = 15.0;     // Max spread as % of ATR (0 = off)
input int    InpMaxSpreadPoints    = 0;        // Max spread in points (0 = off)
input int    InpThaiOffsetHours    = 5;        // Thai time = server time + this many hours
input int    InpSessionStartTH     = 14;       // Session start hour (Thai time)
input int    InpSessionEndTH       = 23;       // Session end hour (Thai time)
input bool   InpUseNewsFilter      = true;     // Skip entries near high-impact news (live only)
input string InpNewsCurrencies     = "USD";    // News currencies, comma separated (e.g. USD,EUR)
input int    InpNewsBeforeMin      = 30;       // No new trades this many minutes before news
input int    InpNewsAfterMin       = 30;       // No new trades this many minutes after news
input bool   InpCloseBeforeWeekend = true;     // Close all trades before the weekend
input int    InpWeekendCloseHourTH = 2;        // Saturday hour (Thai time) to close everything

input group "=== Misc ==="
input ulong  InpMagic              = 20261103; // Magic number
input string InpTradeComment       = "FlowEA"; // Order comment
input int    InpSlippagePoints     = 50;       // Max slippage (points)
input bool   InpShowPanel          = true;     // Show the status panel on the chart

//--- globals ---------------------------------------------------------
CTrade   g_trade;

int      g_hTrendFast     = INVALID_HANDLE;
int      g_hTrendSlow     = INVALID_HANDLE;
int      g_hADX           = INVALID_HANDLE;
int      g_hEntryEMA      = INVALID_HANDLE;
int      g_hRSI           = INVALID_HANDLE;
int      g_hATR           = INVALID_HANDLE;

bool     g_isTester       = false;
bool     g_hedging        = true;
string   g_gvPrefix       = "";

datetime g_lastBarTime    = 0;
int      g_pendingSignal  = 0;      // +1 buy, -1 sell, 0 none
datetime g_signalBarTime  = 0;
double   g_signalATR      = 0.0;
double   g_signalClose    = 0.0;
int      g_entryTries     = 0;
string   g_waitReason     = "";

bool     g_halted         = false;
double   g_equityPeak     = 0.0;
bool     g_peakDirty      = false;
datetime g_lastForcedClose = 0;

bool     g_statsDirty     = true;
datetime g_statsDayStart  = 0;
int      g_todayEntries   = 0;
double   g_todayRealized  = 0.0;

bool     g_previewDone    = false;
string   g_status         = "Starting";
datetime g_lastPanel      = 0;

long     g_volIds[];                // cache: position identifier -> initial volume
double   g_volValues[];

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_isTester = (MQLInfoInteger(MQL_TESTER) != 0);
   if(!ValidateInputs())
      return(INIT_PARAMETERS_INCORRECT);

   g_hedging = ((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)
                == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   g_hTrendFast = iMA(_Symbol, InpTrendTF, InpTrendFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hTrendSlow = iMA(_Symbol, InpTrendTF, InpTrendSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hADX       = iADX(_Symbol, InpTrendTF, InpADXPeriod);
   g_hEntryEMA  = iMA(_Symbol, InpEntryTF, InpEntryEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hRSI       = iRSI(_Symbol, InpEntryTF, InpRSIPeriod, PRICE_CLOSE);
   g_hATR       = iATR(_Symbol, InpEntryTF, InpATRPeriod);
   if(g_hTrendFast == INVALID_HANDLE || g_hTrendSlow == INVALID_HANDLE || g_hADX == INVALID_HANDLE ||
      g_hEntryEMA == INVALID_HANDLE || g_hRSI == INVALID_HANDLE || g_hATR == INVALID_HANDLE)
     {
      Print(EA_NAME, ": failed to create indicators, error ", GetLastError());
      return(INIT_FAILED);
     }

   g_gvPrefix = "FlowEA_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" +
                IntegerToString((long)InpMagic) + "_";
   if(InpResetPeak)
     {
      DeleteGV("peak");
      DeleteGV("halt");
     }
   g_equityPeak = MathMax(AccountInfoDouble(ACCOUNT_EQUITY), LoadGV("peak", 0.0));
   g_halted     = (LoadGV("halt", 0.0) > 0.5);
   g_peakDirty  = true;

//--- do not trade a bar that was already running when the EA was attached
   g_lastBarTime = iTime(_Symbol, InpEntryTF, 0);

   PrintFormat("%s %s on %s | account currency %s | balance %.2f | lot min %.2f step %.2f max %.2f | stops level %d pts | %s account",
               EA_NAME, EA_VERSION, _Symbol, AccountInfoString(ACCOUNT_CURRENCY),
               AccountInfoDouble(ACCOUNT_BALANCE),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
               g_hedging ? "hedging" : "NETTING (one position at a time, hedging is recommended)");

   if(g_halted)
     {
      g_status = "HALTED (drawdown limit was hit earlier)";
      Print(EA_NAME, ": EA is HALTED because the drawdown limit was hit. Set InpResetPeak=true once to resume.");
     }
   else
      g_status = "Waiting for a signal";
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   SaveGV("peak", g_equityPeak);
   ReleaseHandle(g_hTrendFast);
   ReleaseHandle(g_hTrendSlow);
   ReleaseHandle(g_hADX);
   ReleaseHandle(g_hEntryEMA);
   ReleaseHandle(g_hRSI);
   ReleaseHandle(g_hATR);
   Comment("");
  }

//+------------------------------------------------------------------+
//| Any trade event: refresh today's statistics on next use          |
//+------------------------------------------------------------------+
void OnTrade()
  {
   g_statsDirty = true;
  }

//+------------------------------------------------------------------+
//| Expert tick                                                      |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!g_previewDone)
      LogSizingPreview();

   UpdateDrawdown();
   if(g_halted)
     {
      ForceCloseAll("drawdown halt");
      ShowPanel();
      return;
     }

   if(InpCloseBeforeWeekend && IsWeekendCloseTime())
      ForceCloseAll("weekend close");

   ManagePositions();

   datetime barTime = iTime(_Symbol, InpEntryTF, 0);
   if(barTime > 0 && barTime != g_lastBarTime)
     {
      g_lastBarTime = barTime;
      OnNewBar(barTime);
     }

   if(g_pendingSignal != 0)
      TryEnter();

   ShowPanel();
  }

//+------------------------------------------------------------------+
//| New entry-timeframe bar: look for a signal on the closed bar     |
//+------------------------------------------------------------------+
void OnNewBar(datetime barTime)
  {
   g_pendingSignal = 0;
   g_entryTries    = 0;
   g_waitReason    = "";
   if(g_peakDirty)
     {
      SaveGV("peak", g_equityPeak);
      g_peakDirty = false;
     }

   double atr = 0.0, close1 = 0.0;
   int sig = ComputeSignal(atr, close1);
   if(sig == 0)
      return;

   string side = (sig > 0) ? "BUY" : "SELL";
   string why  = "";
   if(!EntryConditionsOK(why))
     {
      g_status = side + " signal skipped: " + why;
      Print(EA_NAME, ": ", g_status);
      return;
     }
   g_pendingSignal = sig;
   g_signalBarTime = barTime;
   g_signalATR     = atr;
   g_signalClose   = close1;
   g_status        = side + " signal - entering";
  }

//+------------------------------------------------------------------+
//| Signal on the last closed bar: +1 buy, -1 sell, 0 none           |
//+------------------------------------------------------------------+
int ComputeSignal(double &atrOut, double &closeOut)
  {
   atrOut   = 0.0;
   closeOut = 0.0;

//--- 1) trend filter on the trend timeframe (closed bar)
   double fast = 0.0, slow = 0.0;
   if(!BufferValue(g_hTrendFast, 0, 1, fast) || !BufferValue(g_hTrendSlow, 0, 1, slow))
      return(0);
   int trend = 0;
   if(fast > slow)
      trend = 1;
   else
      if(fast < slow)
         trend = -1;
   if(trend == 0)
      return(0);

//--- 2) pullback on the entry timeframe
   double rsi = 0.0, atr = 0.0;
   if(!BufferValue(g_hRSI, 0, 1, rsi) || !BufferValue(g_hATR, 0, 1, atr) || atr <= 0.0)
      return(0);

   int n = InpTouchLookback;
   double ema[], low[], high[];
   ArraySetAsSeries(ema, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(high, true);
   if(CopyBuffer(g_hEntryEMA, 0, 1, n, ema) != n)
      return(0);
   if(CopyLow(_Symbol, InpEntryTF, 1, n, low) != n)
      return(0);
   if(CopyHigh(_Symbol, InpEntryTF, 1, n, high) != n)
      return(0);

   double open1  = iOpen(_Symbol, InpEntryTF, 1);
   double close1 = iClose(_Symbol, InpEntryTF, 1);
   if(open1 <= 0.0 || close1 <= 0.0)
      return(0);

   bool touched = false;
   for(int i = 0; i < n; i++)
     {
      if(trend > 0 && low[i] <= ema[i])
         touched = true;
      if(trend < 0 && high[i] >= ema[i])
         touched = true;
     }
   if(!touched)
      return(0);

   atrOut   = atr;
   closeOut = close1;
   if(trend > 0)
     {
      if(close1 <= ema[0])
         return(0);
      if(InpRequireCandleDir && close1 <= open1)
         return(0);
      if(rsi <= InpRSILevel)
         return(0);
      return(1);
     }
   if(close1 >= ema[0])
      return(0);
   if(InpRequireCandleDir && close1 >= open1)
      return(0);
   if(rsi >= 100.0 - InpRSILevel)
      return(0);
   return(-1);
  }

//+------------------------------------------------------------------+
//| Checks done once per signal (cheap ones are repeated per tick)   |
//+------------------------------------------------------------------+
bool EntryConditionsOK(string &why)
  {
   if(!TradingPermitted(why))
      return(false);
   if(!InSession())
     {
      why = "outside the trading session";
      return(false);
     }
   if(InpCloseBeforeWeekend && IsWeekendCloseTime())
     {
      why = "weekend";
      return(false);
     }
   RefreshStats();
   if(g_todayEntries >= InpMaxTradesPerDay)
     {
      why = StringFormat("max trades per day reached (%d)", g_todayEntries);
      return(false);
     }
   double dayPct = DailyPnLPct();
   if(InpMaxDailyLossPct > 0.0 && -dayPct >= InpMaxDailyLossPct)
     {
      why = StringFormat("daily loss limit reached (%.2f%%)", dayPct);
      return(false);
     }
   if(!PositionSlotFree(why))
      return(false);
   if(NewsBlocked(why))
      return(false);
   return(true);
  }

//+------------------------------------------------------------------+
//| Try to open the pending signal (runs on every tick of the window)|
//+------------------------------------------------------------------+
void TryEnter()
  {
   string side = (g_pendingSignal > 0) ? "BUY" : "SELL";

   if((long)TimeCurrent() - (long)g_signalBarTime > (long)InpSignalValidMin * 60)
     {
      g_status = side + " signal expired" + (g_waitReason != "" ? ": " + g_waitReason : "");
      Print(EA_NAME, ": ", g_status);
      g_pendingSignal = 0;
      return;
     }

   string why = "";
   if(!InSession() || !TradingPermitted(why) || !PositionSlotFree(why))
     {
      if(why == "")
         why = "outside the trading session";
      g_status = side + " signal cancelled: " + why;
      g_pendingSignal = 0;
      return;
     }

   double price = (g_pendingSignal > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(MathAbs(price - g_signalClose) > MAX_CHASE_ATR * g_signalATR)
     {
      g_status = side + " signal cancelled: price already moved too far";
      g_pendingSignal = 0;
      return;
     }

   if(!SpreadOK(g_signalATR, why))
     {
      g_waitReason = why;
      g_status = side + " signal waiting: " + why;
      return;
     }

   int result = OpenTrade(g_pendingSignal, g_signalATR, why);
   if(result > 0)
     {
      g_pendingSignal = 0;
      g_waitReason    = "";
      return;
     }
   g_entryTries++;
   if(result < 0 || g_entryTries >= MAX_ENTRY_TRIES)
     {
      g_status = side + " signal dropped: " + why;
      Print(EA_NAME, ": ", g_status);
      g_pendingSignal = 0;
     }
  }

//+------------------------------------------------------------------+
//| Open a trade. 1 = opened, 0 = retry later, -1 = give up          |
//+------------------------------------------------------------------+
int OpenTrade(int dir, double atr, string &why)
  {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0 || atr <= 0.0)
     {
      why = "no price data";
      return(0);
     }

   bool            isBuy = (dir > 0);
   ENUM_ORDER_TYPE type  = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double price   = isBuy ? ask : bid;
   double minDist = (ask - bid) + (double)(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 1) * _Point;
   double slDist  = MathMax(InpSLATR * atr, minDist);
   double sl      = NormPrice(isBuy ? price - slDist : price + slDist);

   double lots = CalcLots(type, price, sl, why);
   if(lots <= 0.0)
      return(-1);

//--- a trade that cannot be split (e.g. a single minimum lot) simply targets TP1
   bool   fullAtTP1 = (PartialVolume(lots) >= lots - VolumeStep() * 0.5);
   double tpDist    = MathMax((fullAtTP1 ? InpTP1ATR : InpTP2ATR) * atr, minDist);
   double tp        = NormPrice(isBuy ? price + tpDist : price - tpDist);

   bool sent = isBuy ? g_trade.Buy(lots, _Symbol, price, sl, tp, InpTradeComment)
                     : g_trade.Sell(lots, _Symbol, price, sl, tp, InpTradeComment);
   if(!sent || !TradeOK())
     {
      why = StringFormat("order failed: %u %s", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      Print(EA_NAME, ": ", why);
      return(0);
     }

   g_statsDirty = true;
   g_status = StringFormat("Opened %s %.2f lots @ %s  SL %s  TP %s%s",
                           isBuy ? "BUY" : "SELL", lots,
                           DoubleToString(price, _Digits), DoubleToString(sl, _Digits),
                           DoubleToString(tp, _Digits), fullAtTP1 ? " (whole trade at TP1)" : "");
   Print(EA_NAME, ": ", g_status);
   return(1);
  }

//+------------------------------------------------------------------+
//| Lot size that risks InpRiskPercent between price and sl          |
//+------------------------------------------------------------------+
double CalcLots(ENUM_ORDER_TYPE type, double price, double sl, string &why)
  {
   double minVol     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double base       = RiskBase();
   double riskMoney  = base * InpRiskPercent / 100.0;
   double lossPerLot = LossPerLot(type, price, sl);
   if(base <= 0.0 || lossPerLot <= 0.0)
     {
      why = "cannot calculate the risk per lot";
      return(0.0);
     }

   double lots = FloorToStep(riskMoney / lossPerLot);
   if(InpMaxLots > 0.0)
      lots = MathMin(lots, FloorToStep(InpMaxLots));
   if(maxVol > 0.0)
      lots = MathMin(lots, maxVol);
   if(lots < minVol - 1e-9)
     {
      why = StringFormat("minimum lot %.2f would risk %.2f%% (limit %.2f%%) - balance too small or stop too wide",
                         minVol, lossPerLot * minVol / base * 100.0, InpRiskPercent);
      return(0.0);
     }

//--- keep a margin reserve
   double margin     = 0.0;
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(OrderCalcMargin(type, _Symbol, lots, price, margin) && margin > 0.0 && margin > freeMargin * 0.8)
     {
      lots = FloorToStep(lots * freeMargin * 0.8 / margin);
      if(lots < minVol - 1e-9)
        {
         why = "not enough free margin";
         return(0.0);
        }
     }
   return(lots);
  }

//+------------------------------------------------------------------+
//| Loss in account currency for 1.0 lot from price to sl            |
//+------------------------------------------------------------------+
double LossPerLot(ENUM_ORDER_TYPE type, double price, double sl)
  {
   double profit = 0.0;
   if(OrderCalcProfit(type, _Symbol, 1.0, price, sl, profit) && profit < 0.0)
      return(-profit);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return(0.0);
   return(MathAbs(price - sl) / tickSize * tickValue);
  }

//+------------------------------------------------------------------+
//| Manage every open position of this EA                            |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   int total = PositionsTotal();
   if(total == 0)
      return;
   double atrNow = CurrentATR();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurSelectedPosition())
         continue;
      ManagePosition(ticket, atrNow);
     }
  }

//+------------------------------------------------------------------+
//| Stage 1: wait for TP1, bank part, lock breakeven                 |
//| Stage 2: trail the risk-free runner                              |
//+------------------------------------------------------------------+
void ManagePosition(ulong ticket, double atrNow)
  {
   if(!PositionSelectByTicket(ticket))
      return;
   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   bool   isBuy = (ptype == POSITION_TYPE_BUY);
   double open  = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl    = PositionGetDouble(POSITION_SL);
   double tp    = PositionGetDouble(POSITION_TP);
   double vol   = PositionGetDouble(POSITION_VOLUME);
   long   posId = PositionGetInteger(POSITION_IDENTIFIER);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;

//--- safety net: every position must have a stop loss
   if(sl <= 0.0)
     {
      if(atrNow <= 0.0)
         return;
      double fixSL = NormPrice(isBuy ? open - InpSLATR * atrNow : open + InpSLATR * atrNow);
      if(StopIsValid(isBuy, fixSL))
         ModifyPosition(ticket, fixSL, tp, "restore missing stop loss");
      else
         ClosePosition(ticket, "no stop loss and price is already beyond it");
      return;
     }

   if(!IsRiskFree(isBuy, open, sl))
     {
      //--- stage 1. The original stop is still in place, so it tells us the entry ATR.
      double atrEntry    = MathAbs(open - sl) / InpSLATR;
      double initVol     = InitialVolume(posId, vol);
      bool   partialDone = (vol < initVol - VolumeStep() * 0.5);

      if(!partialDone)
        {
         double tp1 = isBuy ? open + InpTP1ATR * atrEntry : open - InpTP1ATR * atrEntry;
         bool   hit = isBuy ? (bid >= tp1) : (ask <= tp1);
         if(!hit)
            return;

         double closeVol = PartialVolume(vol);
         if(closeVol >= vol - VolumeStep() * 0.5)
           {
            ClosePosition(ticket, "TP1 (whole position)");
            return;
           }
         if(closeVol > 0.0)
           {
            if(!ClosePartial(ticket, isBuy, closeVol))
               return;                       // try again on the next tick
            PrintFormat("%s: TP1 hit on %s - banked %.2f of %.2f lots", EA_NAME, TicketStr(ticket), closeVol, vol);
           }
         if(!PositionSelectByTicket(ticket))
            return;
         tp = PositionGetDouble(POSITION_TP);
        }

      //--- lock breakeven and pick the runner target
      double adx    = 0.0;
      bool   strong = BufferValue(g_hADX, 0, 1, adx) && adx > InpADXStrong;
      double tp2    = NormPrice(isBuy ? open + InpTP2ATR * atrEntry : open - InpTP2ATR * atrEntry);
      double newTP  = strong ? 0.0 : (tp > 0.0 ? tp : tp2);
      double beSL   = NormPrice(isBuy ? open + InpBEBufferATR * atrEntry : open - InpBEBufferATR * atrEntry);

      if(StopIsValid(isBuy, beSL))
        {
         if(ModifyPosition(ticket, beSL, newTP, "breakeven"))
           {
            g_status = StringFormat("%s TP1 done, stop at breakeven, runner %s", TicketStr(ticket),
                                    strong ? StringFormat("trails freely (ADX %.1f)", adx) : "trails to TP2");
            Print(EA_NAME, ": ", g_status);
           }
        }
      else
         ClosePosition(ticket, "price fell back before breakeven could be set");
      return;
     }

//--- stage 2: risk-free runner with an ATR trailing stop
   if(atrNow <= 0.0)
      return;
   double trail = InpTrailATR * atrNow;
   double step  = InpTrailStepATR * atrNow;
   if(isBuy)
     {
      double newSL = NormPrice(bid - trail);
      if(newSL > sl + step && StopIsValid(true, newSL))
         ModifyPosition(ticket, newSL, tp, "trailing stop");
     }
   else
     {
      double newSL = NormPrice(ask + trail);
      if(newSL < sl - step && StopIsValid(false, newSL))
         ModifyPosition(ticket, newSL, tp, "trailing stop");
     }
  }

//+------------------------------------------------------------------+
//| Volume to close at TP1 (returns vol when it cannot be split)     |
//+------------------------------------------------------------------+
double PartialVolume(double vol)
  {
   if(InpTP1ClosePct <= 0.0)
      return(0.0);
   if(InpTP1ClosePct >= 100.0)
      return(vol);
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double part   = FloorToStep(vol * InpTP1ClosePct / 100.0);
   if(part < minVol)
      part = minVol;
   if(vol - part < minVol - 1e-9)
      return(vol);                            // remainder would be below the minimum lot
   return(part);
  }

//+------------------------------------------------------------------+
//| Initial volume of a position (from its opening deals), cached    |
//+------------------------------------------------------------------+
double InitialVolume(long posId, double fallback)
  {
   int n = ArraySize(g_volIds);
   for(int i = 0; i < n; i++)
      if(g_volIds[i] == posId)
         return(g_volValues[i]);

   double vol = 0.0;
   if(HistorySelectByPosition(posId))
     {
      int deals = HistoryDealsTotal();
      for(int i = 0; i < deals; i++)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0)
            continue;
         if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
            vol += HistoryDealGetDouble(deal, DEAL_VOLUME);
        }
     }
   if(vol <= 0.0)
      return(fallback);                       // history not loaded yet: do not cache
   if(n >= 64)
     {
      ArrayFree(g_volIds);
      ArrayFree(g_volValues);
      n = 0;
     }
   ArrayResize(g_volIds, n + 1);
   ArrayResize(g_volValues, n + 1);
   g_volIds[n]    = posId;
   g_volValues[n] = vol;
   return(vol);
  }

//+------------------------------------------------------------------+
//| Equity drawdown kill switch                                      |
//+------------------------------------------------------------------+
void UpdateDrawdown()
  {
   if(g_halted)
      return;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_equityPeak)
     {
      g_equityPeak = equity;
      g_peakDirty  = true;
     }
   if(InpMaxDrawdownPct <= 0.0 || g_equityPeak <= 0.0)
      return;
   double dd = (g_equityPeak - equity) / g_equityPeak * 100.0;
   if(dd < InpMaxDrawdownPct)
      return;

   g_halted        = true;
   g_pendingSignal = 0;
   SaveGV("halt", 1.0);
   SaveGV("peak", g_equityPeak);
   g_status = StringFormat("HALTED: drawdown %.1f%% from peak %.2f", dd, g_equityPeak);
   string msg = StringFormat("%s on %s HALTED: equity %.2f is %.1f%% below its peak %.2f. All trades closed, no new trades. Set InpResetPeak=true once to resume.",
                             EA_NAME, _Symbol, equity, dd, g_equityPeak);
   Print(msg);
   if(!g_isTester)
      Alert(msg);
   g_lastForcedClose = 0;
   ForceCloseAll("drawdown halt");
  }

//+------------------------------------------------------------------+
//| Close all of this EA's positions (at most every 30 seconds)      |
//+------------------------------------------------------------------+
void ForceCloseAll(string reason)
  {
   if(CountOurPositions() == 0)
      return;
   if(g_lastForcedClose > 0 && (long)TimeCurrent() - (long)g_lastForcedClose < 30)
      return;
   g_lastForcedClose = TimeCurrent();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurSelectedPosition())
         continue;
      ClosePosition(ticket, reason);
     }
  }

//+------------------------------------------------------------------+
//| A new trade is allowed only if every open trade is risk-free     |
//+------------------------------------------------------------------+
bool PositionSlotFree(string &why)
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurSelectedPosition())
         continue;
      count++;
      bool isBuy = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      if(!IsRiskFree(isBuy, PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_SL)))
        {
         why = "an open trade is still at risk";
         return(false);
        }
     }
   int maxPos = g_hedging ? InpMaxPositions : 1;
   if(count >= maxPos)
     {
      why = StringFormat("max open positions reached (%d)", maxPos);
      return(false);
     }
   return(true);
  }

bool IsRiskFree(bool isBuy, double open, double sl)
  {
   if(sl <= 0.0)
      return(false);
   double tol = _Point * 0.5;
   return(isBuy ? (sl >= open - tol) : (sl <= open + tol));
  }

bool IsOurSelectedPosition()
  {
   return(PositionGetString(POSITION_SYMBOL) == _Symbol &&
          (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic);
  }

int CountOurPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket != 0 && IsOurSelectedPosition())
         count++;
     }
   return(count);
  }

//+------------------------------------------------------------------+
//| Today's entries and realized P/L (day = Thai calendar day)       |
//+------------------------------------------------------------------+
datetime ServerDayStart()
  {
   long thai         = (long)ThaiNow();
   long thaiMidnight = thai - (thai % 86400);
   return((datetime)(thaiMidnight - (long)InpThaiOffsetHours * 3600));
  }

void RefreshStats()
  {
   datetime dayStart = ServerDayStart();
   if(!g_statsDirty && dayStart == g_statsDayStart)
      return;
   g_statsDirty    = false;
   g_statsDayStart = dayStart;
   g_todayEntries  = 0;
   g_todayRealized = 0.0;
   if(!HistorySelect(dayStart, TimeCurrent() + 86400))
     {
      g_statsDirty = true;
      return;
     }
   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic)
         continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
         g_todayEntries++;
      g_todayRealized += HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP) +
                         HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_FEE);
     }
  }

//--- today's P/L (realized + floating) in % of the balance at the start of the day
double DailyPnLPct()
  {
   RefreshStats();
   double floating = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurSelectedPosition())
         continue;
      floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   double startBalance = AccountInfoDouble(ACCOUNT_BALANCE) - g_todayRealized;
   if(startBalance <= 0.0)
      return(0.0);
   return((g_todayRealized + floating) / startBalance * 100.0);
  }

//+------------------------------------------------------------------+
//| Filters                                                          |
//+------------------------------------------------------------------+
bool TradingPermitted(string &why)
  {
   if(!g_isTester)
     {
      if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == 0)
        {
         why = "Algo Trading button is OFF";
         return(false);
        }
      if(MQLInfoInteger(MQL_TRADE_ALLOWED) == 0)
        {
         why = "'Allow Algo Trading' is off in the EA settings";
         return(false);
        }
     }
   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY)
     {
      why = "symbol is not tradable now";
      return(false);
     }
   return(true);
  }

bool SpreadOK(double atr, string &why)
  {
   double spread = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(InpMaxSpreadPctATR > 0.0 && atr > 0.0)
     {
      double maxSpread = atr * InpMaxSpreadPctATR / 100.0;
      if(spread > maxSpread)
        {
         why = "spread " + DoubleToString(spread, _Digits) + " > max " + DoubleToString(maxSpread, _Digits);
         return(false);
        }
     }
   if(InpMaxSpreadPoints > 0 && spread > InpMaxSpreadPoints * _Point)
     {
      why = StringFormat("spread %d pts > max %d pts", (int)MathRound(spread / _Point), InpMaxSpreadPoints);
      return(false);
     }
   return(true);
  }

datetime ThaiNow()
  {
   return((datetime)((long)TimeCurrent() + (long)InpThaiOffsetHours * 3600));
  }

bool InSession()
  {
   MqlDateTime t;
   TimeToStruct(ThaiNow(), t);
   if(InpSessionStartTH == InpSessionEndTH)
      return(true);                                         // 24 hours
   if(InpSessionStartTH < InpSessionEndTH)
      return(t.hour >= InpSessionStartTH && t.hour < InpSessionEndTH);
   return(t.hour >= InpSessionStartTH || t.hour < InpSessionEndTH);   // wraps past midnight
  }

bool IsWeekendCloseTime()
  {
   MqlDateTime t;
   TimeToStruct(ThaiNow(), t);
   return(t.day_of_week == 6 && t.hour >= InpWeekendCloseHourTH);  // Saturday, Thai time
  }

//--- high-impact news from the MT5 economic calendar (not available in the tester)
bool NewsBlocked(string &why)
  {
   if(!InpUseNewsFilter || g_isTester)
      return(false);
   datetime now  = TimeTradeServer();
   datetime from = (datetime)((long)now - (long)InpNewsAfterMin * 60);
   datetime to   = (datetime)((long)now + (long)InpNewsBeforeMin * 60);

   string codes[];
   int count = StringSplit(InpNewsCurrencies, ',', codes);
   for(int c = 0; c < count; c++)
     {
      string code = codes[c];
      StringTrimLeft(code);
      StringTrimRight(code);
      StringToUpper(code);
      if(StringLen(code) == 0)
         continue;
      MqlCalendarValue values[];
      if(!CalendarValueHistory(values, from, to, NULL, code))
         continue;
      int n = ArraySize(values);
      for(int i = 0; i < n; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev))
            continue;
         if(ev.importance == CALENDAR_IMPORTANCE_HIGH)
           {
            why = "high-impact " + code + " news: " + ev.name + " at " + TimeToString(values[i].time, TIME_MINUTES);
            return(true);
           }
        }
     }
   return(false);
  }

//+------------------------------------------------------------------+
//| Trade wrappers (hedging and netting)                             |
//+------------------------------------------------------------------+
bool TradeOK()
  {
   uint rc = g_trade.ResultRetcode();
   return(rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL ||
          rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_NO_CHANGES);
  }

bool ModifyPosition(ulong ticket, double sl, double tp, string reason)
  {
   bool sent = g_hedging ? g_trade.PositionModify(ticket, sl, tp)
                         : g_trade.PositionModify(_Symbol, sl, tp);
   if(sent && TradeOK())
      return(true);
   PrintFormat("%s: modify %s (%s) failed: %u %s", EA_NAME, TicketStr(ticket), reason,
               g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   return(false);
  }

bool ClosePosition(ulong ticket, string reason)
  {
   bool sent = g_hedging ? g_trade.PositionClose(ticket) : g_trade.PositionClose(_Symbol);
   if(sent && TradeOK())
     {
      PrintFormat("%s: closed %s (%s)", EA_NAME, TicketStr(ticket), reason);
      g_statsDirty = true;
      return(true);
     }
   PrintFormat("%s: close %s (%s) failed: %u %s", EA_NAME, TicketStr(ticket), reason,
               g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   return(false);
  }

bool ClosePartial(ulong ticket, bool isBuy, double vol)
  {
   bool sent;
   if(g_hedging)
      sent = g_trade.PositionClosePartial(ticket, vol);
   else                                     // netting: an opposite deal reduces the position
      sent = isBuy ? g_trade.Sell(vol, _Symbol, 0.0, 0.0, 0.0, InpTradeComment)
                   : g_trade.Buy(vol, _Symbol, 0.0, 0.0, 0.0, InpTradeComment);
   if(sent && TradeOK())
     {
      g_statsDirty = true;
      return(true);
     }
   PrintFormat("%s: partial close %s failed: %u %s", EA_NAME, TicketStr(ticket),
               g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   return(false);
  }

bool StopIsValid(bool isBuy, double slPrice)
  {
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   return(isBuy ? (slPrice < bid - minDist) : (slPrice > ask + minDist));
  }

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool BufferValue(int handle, int buffer, int shift, double &value)
  {
   double tmp[];
   if(CopyBuffer(handle, buffer, shift, 1, tmp) != 1)
      return(false);
   value = tmp[0];
   return(value != EMPTY_VALUE);
  }

double CurrentATR()
  {
   double atr = 0.0;
   if(!BufferValue(g_hATR, 0, 1, atr))
      return(0.0);
   return(atr);
  }

double RiskBase()
  {
   return(MathMin(AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY)));
  }

double NormPrice(double price)
  {
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize > 0.0)
      price = MathRound(price / tickSize) * tickSize;
   return(NormalizeDouble(price, _Digits));
  }

double VolumeStep()
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   return(step > 0.0 ? step : 0.01);
  }

int VolumeDigits()
  {
   double step   = VolumeStep();
   int    digits = 0;
   while(step < 1.0 - 1e-9 && digits < 8)
     {
      step *= 10.0;
      digits++;
     }
   return(digits);
  }

double FloorToStep(double vol)
  {
   double step = VolumeStep();
   return(NormalizeDouble(MathFloor(vol / step + 1e-7) * step, VolumeDigits()));
  }

string TicketStr(ulong ticket)
  {
   return("#" + IntegerToString((long)ticket));
  }

string TfName(ENUM_TIMEFRAMES tf)
  {
   return(StringSubstr(EnumToString(tf), 7));   // "PERIOD_M15" -> "M15"
  }

void ReleaseHandle(int &handle)
  {
   if(handle != INVALID_HANDLE)
     {
      IndicatorRelease(handle);
      handle = INVALID_HANDLE;
     }
  }

//--- persistent values (terminal global variables), skipped in the tester
void SaveGV(string name, double value)
  {
   if(g_isTester || g_gvPrefix == "")
      return;
   GlobalVariableSet(g_gvPrefix + name, value);
  }

double LoadGV(string name, double def)
  {
   if(g_isTester || g_gvPrefix == "")
      return(def);
   string full = g_gvPrefix + name;
   return(GlobalVariableCheck(full) ? GlobalVariableGet(full) : def);
  }

void DeleteGV(string name)
  {
   if(g_isTester || g_gvPrefix == "")
      return;
   GlobalVariableDel(g_gvPrefix + name);
  }

//+------------------------------------------------------------------+
//| One-time log: what a typical trade would risk on this account    |
//+------------------------------------------------------------------+
void LogSizingPreview()
  {
   double atr = CurrentATR();
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(atr <= 0.0 || ask <= 0.0)
      return;
   g_previewDone = true;

   double sl      = NormPrice(ask - InpSLATR * atr);
   double perLot  = LossPerLot(ORDER_TYPE_BUY, ask, sl);
   double minVol  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double base    = RiskBase();
   string why     = "";
   double lots    = CalcLots(ORDER_TYPE_BUY, ask, sl, why);
   double minPct  = (base > 0.0) ? perLot * minVol / base * 100.0 : 0.0;
   PrintFormat("%s sizing check: ATR %s, stop distance %s | minimum lot %.2f would lose %.2f %s (%.2f%% of %.2f) | lot for %.2f%% risk = %.2f%s",
               EA_NAME, DoubleToString(atr, _Digits), DoubleToString(ask - sl, _Digits),
               minVol, perLot * minVol, AccountInfoString(ACCOUNT_CURRENCY), minPct, base,
               InpRiskPercent, lots, lots > 0.0 ? "" : " -> TRADES WILL BE SKIPPED: " + why);
  }

//+------------------------------------------------------------------+
//| Status panel                                                     |
//+------------------------------------------------------------------+
void ShowPanel()
  {
   if(!InpShowPanel)
      return;
   if(g_isTester && MQLInfoInteger(MQL_VISUAL_MODE) == 0)
      return;
   datetime now = TimeCurrent();
   if(now == g_lastPanel)
      return;
   g_lastPanel = now;

   string why   = "";
   string state = g_halted ? "HALTED (max drawdown)" : "ACTIVE";
   if(!g_halted && !TradingPermitted(why))
      state = "PAUSED - " + why;

   double fast = 0.0, slow = 0.0, adx = 0.0;
   double atr  = CurrentATR();
   string trend = "n/a";
   if(BufferValue(g_hTrendFast, 0, 1, fast) && BufferValue(g_hTrendSlow, 0, 1, slow))
      trend = (fast > slow) ? "UP (buys only)" : ((fast < slow) ? "DOWN (sells only)" : "FLAT");
   string adxText = "n/a";
   if(BufferValue(g_hADX, 0, 1, adx))
      adxText = StringFormat("%.1f%s", adx, adx > InpADXStrong ? " (strong)" : "");

   double spread    = SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double maxSpread = atr * InpMaxSpreadPctATR / 100.0;
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct     = (g_equityPeak > 0.0) ? (g_equityPeak - equity) / g_equityPeak * 100.0 : 0.0;
   double dayPct    = DailyPnLPct();

   string offsetNote = "";
   if(!g_isTester)
     {
      int detected = (int)MathRound(((double)((long)TimeGMT() - (long)TimeTradeServer()) + 7.0 * 3600.0) / 3600.0);
      if(detected != InpThaiOffsetHours)
         offsetNote = StringFormat("  <- check: this PC suggests %+d", detected);
     }

   string text = StringFormat("%s %s  |  %s  entry %s / trend %s\n", EA_NAME, EA_VERSION, _Symbol,
                              TfName(InpEntryTF), TfName(InpTrendTF));
   text += StringFormat("Thai time %s (server %+dh)%s\n",
                        TimeToString(ThaiNow(), TIME_DATE | TIME_MINUTES), InpThaiOffsetHours, offsetNote);
   text += StringFormat("State: %s  |  session %02d:00-%02d:00 %s\n", state,
                        InpSessionStartTH, InpSessionEndTH, InSession() ? "OPEN" : "closed");
   text += StringFormat("Trend: %s  |  ADX %s\n", trend, adxText);
   text += "Spread " + DoubleToString(spread, _Digits) + " / max " + DoubleToString(maxSpread, _Digits) +
           "  (ATR " + DoubleToString(atr, _Digits) + ")\n";
   text += StringFormat("Today: %d/%d trades  |  P/L %+.2f%% (limit -%.2f%%)\n",
                        g_todayEntries, InpMaxTradesPerDay, dayPct, InpMaxDailyLossPct);
   text += StringFormat("Drawdown from peak %.2f%% (limit %.2f%%)  |  risk %.2f%%/trade  |  open %d\n",
                        ddPct, InpMaxDrawdownPct, InpRiskPercent, CountOurPositions());
   text += "Last: " + g_status;
   Comment(text);
  }

//+------------------------------------------------------------------+
//| Input validation                                                 |
//+------------------------------------------------------------------+
bool ValidateInputs()
  {
   string err = "";
   if(InpRiskPercent <= 0.0 || InpRiskPercent > 5.0)
      err = "InpRiskPercent must be > 0 and <= 5";
   else if(InpMaxDailyLossPct < 0.0)
      err = "InpMaxDailyLossPct must be >= 0";
   else if(InpMaxDrawdownPct < 0.0 || InpMaxDrawdownPct >= 100.0)
      err = "InpMaxDrawdownPct must be between 0 and 100";
   else if(InpMaxTradesPerDay < 1 || InpMaxPositions < 1)
      err = "InpMaxTradesPerDay and InpMaxPositions must be >= 1";
   else if(InpTrendFastEMA < 1 || InpTrendFastEMA >= InpTrendSlowEMA)
      err = "trend EMAs: fast must be >= 1 and smaller than slow";
   else if(InpEntryEMA < 1 || InpRSIPeriod < 2 || InpATRPeriod < 1 || InpADXPeriod < 2)
      err = "indicator periods are too small";
   else if(InpTouchLookback < 1 || InpTouchLookback > 20)
      err = "InpTouchLookback must be 1..20";
   else if(InpRSILevel < 0.0 || InpRSILevel > 100.0)
      err = "InpRSILevel must be 0..100";
   else if(InpSignalValidMin < 1)
      err = "InpSignalValidMin must be >= 1";
   else if(InpSLATR <= 0.0 || InpTP1ATR <= 0.0 || InpTP2ATR <= 0.0 || InpTrailATR <= 0.0 || InpTrailStepATR < 0.0)
      err = "ATR multipliers must be > 0";
   else if(InpTP2ATR <= InpTP1ATR)
      err = "InpTP2ATR must be greater than InpTP1ATR";
   else if(InpBEBufferATR < 0.0 || InpBEBufferATR >= InpTP1ATR)
      err = "InpBEBufferATR must be >= 0 and smaller than InpTP1ATR";
   else if(InpTP1ClosePct < 0.0 || InpTP1ClosePct > 100.0)
      err = "InpTP1ClosePct must be 0..100";
   else if(InpMaxSpreadPctATR < 0.0 || InpMaxSpreadPoints < 0)
      err = "spread limits must be >= 0";
   else if(InpThaiOffsetHours < -12 || InpThaiOffsetHours > 24)
      err = "InpThaiOffsetHours must be -12..24";
   else if(InpSessionStartTH < 0 || InpSessionStartTH > 23 || InpSessionEndTH < 0 || InpSessionEndTH > 23)
      err = "session hours must be 0..23";
   else if(InpWeekendCloseHourTH < 0 || InpWeekendCloseHourTH > 23)
      err = "InpWeekendCloseHourTH must be 0..23";
   else if(InpNewsBeforeMin < 0 || InpNewsAfterMin < 0)
      err = "news minutes must be >= 0";
   else if(InpMaxLots < 0.0 || InpSlippagePoints < 0)
      err = "InpMaxLots and InpSlippagePoints must be >= 0";

   if(err != "")
     {
      Print(EA_NAME, " input error: ", err);
      if(!g_isTester)
         Alert(EA_NAME, " input error: ", err);
      return(false);
     }
   if(PeriodSeconds(InpTrendTF) < PeriodSeconds(InpEntryTF))
      Print(EA_NAME, " warning: the trend timeframe is lower than the entry timeframe");
   return(true);
  }
//+------------------------------------------------------------------+
