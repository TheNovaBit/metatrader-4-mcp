//+------------------------------------------------------------------+
//| ZeroMQ_Bridge.mq5                                                |
//| MT5 equity agent bridge — PUSH data stream + REP command socket. |
//| Port of ZeroMQ_Bridge.mq4 to MQL5 (handles/CopyBuffer, CTrade,   |
//| PositionsTotal model). Adds `discover` and `history` commands.   |
//|                                                                   |
//| INSTALL: copy libzmq.dll -> MQL5\Libraries\, Zmq\ -> MQL5\Include\|
//|   Tools>Options>Expert Advisors> allow DLL imports. Compile (F7). |
//|   Attach to ONE chart; it serves every symbol in symbols.txt.    |
//|                                                                   |
//| Sockets (MT5 binds, Python connects):                            |
//|   PUSH tcp://*:5560 -> Python PULL  (data, every UpdateIntervalSec)|
//|   REP  tcp://*:5559 <- Python REQ   (commands)                   |
//+------------------------------------------------------------------+
#property copyright "Claude Equity Agent"
#property version   "1.00"

#include <Zmq/Zmq.mqh>
#include <Trade/Trade.mqh>

input int    UpdateIntervalSec = 3;       // data push interval (s)
input int    DataPushPort      = 5560;    // PUSH (data -> Python)
input int    OrderRepPort      = 5559;    // REP  (orders <- Python)
input int    MagicNumber       = 20260300;// equity magic (swing 20260101 / scalper 20260200)
input string SymbolList        = "EURUSD,XAUUSD"; // fallback if symbols.txt missing
input string SymbolListFile    = "symbols.txt";   // under MQL5\Files\ ; "" disables
input bool   EnablePush        = true;    // false = REP-only (consumer-less PUSH blocks!)
input int    HistoryMaxBars    = 5000;    // cap for `history` CopyRates
input int    DiscoverChunkSize = 40;      // symbols per discover response chunk

Context g_ctx("ZeroMQ_Bridge_MT5");
Socket  g_push(g_ctx, ZMQ_PUSH);
Socket  g_rep(g_ctx, ZMQ_REP);
CTrade  g_trade;

datetime g_lastPush = 0;
string   g_symbols[];     // parsed symbol list

// discover paging cache — built on chunk 0, served across chunk requests
string   g_discoverRows[];
int      g_discoverCount = 0;

// Indicator handle cache (lazily filled per symbol) ---------------------------
struct SymHandles
{
   string sym;
   int    ema8_h1, ema21_h1, ema50_h1;
   int    ema8_m15, ema21_m15, ema50_m15;
   int    rsi_h1, atr_h1, atr_m15, atr_d1, adx_h1;
   bool   ready;
};
SymHandles g_h[];

// Find or create the handle bundle for sym. Returns index into g_h.
int GetHandles(string sym)
{
   for (int i = 0; i < ArraySize(g_h); i++)
      if (g_h[i].sym == sym) return i;

   int n = ArraySize(g_h);
   ArrayResize(g_h, n + 1);
   g_h[n].sym       = sym;
   g_h[n].ema8_h1   = iMA(sym, PERIOD_H1,  8, 0, MODE_EMA, PRICE_CLOSE);
   g_h[n].ema21_h1  = iMA(sym, PERIOD_H1, 21, 0, MODE_EMA, PRICE_CLOSE);
   g_h[n].ema50_h1  = iMA(sym, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE);
   g_h[n].ema8_m15  = iMA(sym, PERIOD_M15, 8, 0, MODE_EMA, PRICE_CLOSE);
   g_h[n].ema21_m15 = iMA(sym, PERIOD_M15,21, 0, MODE_EMA, PRICE_CLOSE);
   g_h[n].ema50_m15 = iMA(sym, PERIOD_M15,50, 0, MODE_EMA, PRICE_CLOSE);
   g_h[n].rsi_h1    = iRSI(sym, PERIOD_H1, 14, PRICE_CLOSE);
   g_h[n].atr_h1    = iATR(sym, PERIOD_H1, 14);
   g_h[n].atr_m15   = iATR(sym, PERIOD_M15,14);
   g_h[n].atr_d1    = iATR(sym, PERIOD_D1, 14);
   g_h[n].adx_h1    = iADX(sym, PERIOD_H1, 14);
   g_h[n].ready     = true;
   return n;
}

// Read one buffer value at shift; returns 0.0 on failure.
double Buf(int handle, int shift)
{
   double tmp[];
   if (handle == INVALID_HANDLE) return 0.0;
   if (CopyBuffer(handle, 0, shift, 1, tmp) <= 0) return 0.0;
   return tmp[0];
}

// Parse SymbolList (or symbols.txt) into g_symbols[] and select each in Market Watch.
void LoadSymbols()
{
   string src = SymbolList;
   if (StringLen(SymbolListFile) > 0)
   {
      int fh = FileOpen(SymbolListFile, FILE_READ | FILE_TXT | FILE_ANSI);
      if (fh != INVALID_HANDLE)
      {
         string acc = "";
         int cnt = 0;
         while (!FileIsEnding(fh))
         {
            string line = FileReadString(fh);
            StringTrimLeft(line); StringTrimRight(line);
            if (StringLen(line) == 0) continue;
            if (StringGetChar(line, 0) == '#') continue;
            if (cnt > 0) acc += ",";
            acc += line; cnt++;
         }
         FileClose(fh);
         if (cnt > 0) { src = acc; Print("ZMQ5: loaded ", cnt, " symbols from ", SymbolListFile); }
      }
   }
   StringSplit(src, ',', g_symbols);
   for (int i = 0; i < ArraySize(g_symbols); i++)
   {
      StringTrimLeft(g_symbols[i]); StringTrimRight(g_symbols[i]);
      if (StringLen(g_symbols[i]) > 0) SymbolSelect(g_symbols[i], true);
   }
}

// Classify asset class from path + expiration (mirrors spec §6 rule).
string ClassifyAsset(string sym)
{
   if ((datetime)SymbolInfoInteger(sym, SYMBOL_EXPIRATION_TIME) > 0) return "forward";
   string p = SymbolInfoString(sym, SYMBOL_PATH);
   string lp = p; StringToLower(lp);
   if (StringFind(lp, "stock") >= 0 || StringFind(lp, "share") >= 0) return "stock";
   if (StringFind(lp, "etf")   >= 0)                                 return "etf";
   if (StringFind(lp, "forex") >= 0 || StringFind(lp, "\\fx") >= 0)  return "fx";
   if (StringFind(lp, "metal") >= 0 || StringFind(lp, "xau") >= 0
       || StringFind(lp, "xag") >= 0)                                return "metal";
   if (StringFind(lp, "ind")   >= 0 || StringFind(lp, "cash") >= 0)  return "index";
   return "unknown";
}

string JsonEscape(string s)
{
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   return s;
}
string JStr(string key, string val) { return "\"" + key + "\":\"" + JsonEscape(val) + "\""; }

int OnInit()
{
   string pushAddr = "tcp://*:" + IntegerToString(DataPushPort);
   string repAddr  = "tcp://*:" + IntegerToString(OrderRepPort);
   if (!g_push.bind(pushAddr)) { Print("ZMQ5: PUSH bind failed ", pushAddr); return INIT_FAILED; }
   if (!g_rep.bind(repAddr))   { Print("ZMQ5: REP bind failed ",  repAddr);  return INIT_FAILED; }
   g_push.setLinger(0);
   g_rep.setLinger(0);

   g_trade.SetExpertMagicNumber(MagicNumber);
   g_trade.SetDeviationInPoints(10);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   LoadSymbols();
   Print("ZMQ5 Bridge v1.0 — PUSH=", pushAddr, " REP=", repAddr,
         " symbols=", ArraySize(g_symbols));
   EventSetMillisecondTimer(100);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   g_push.unbind("tcp://*:" + IntegerToString(DataPushPort));
   g_rep.unbind("tcp://*:" + IntegerToString(OrderRepPort));
   for (int i = 0; i < ArraySize(g_h); i++)
   {
      IndicatorRelease(g_h[i].ema8_h1);  IndicatorRelease(g_h[i].ema21_h1); IndicatorRelease(g_h[i].ema50_h1);
      IndicatorRelease(g_h[i].ema8_m15); IndicatorRelease(g_h[i].ema21_m15);IndicatorRelease(g_h[i].ema50_m15);
      IndicatorRelease(g_h[i].rsi_h1);   IndicatorRelease(g_h[i].atr_h1);
      IndicatorRelease(g_h[i].atr_m15);  IndicatorRelease(g_h[i].atr_d1);   IndicatorRelease(g_h[i].adx_h1);
   }
   Print("ZMQ5: shutdown reason=", reason);
}

void OnTimer()
{
   if (EnablePush && TimeCurrent() - g_lastPush >= UpdateIntervalSec)
   {
      PushAllData();
      g_lastPush = TimeCurrent();
   }
   while (ProcessREPOnce()) {}
}

void PushAllData()
{
   for (int i = 0; i < ArraySize(g_symbols); i++)
   {
      string sym = g_symbols[i];
      if (StringLen(sym) == 0) continue;
      string js = BuildSymbolJson(sym);
      if (StringLen(js) > 2) { ZmqMsg m(js); g_push.send(m); }
   }
   ZmqMsg am(BuildAccountJson());   g_push.send(am);
   ZmqMsg pm(BuildPositionsJson()); g_push.send(pm);
}

string BuildSymbolJson(string sym)
{
   int    digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double ask    = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(sym, SYMBOL_BID);
   double point  = SymbolInfoDouble(sym, SYMBOL_POINT);
   double spread = (double)SymbolInfoInteger(sym, SYMBOL_SPREAD) * point;
   int    hi     = GetHandles(sym);

   double ema8   = Buf(g_h[hi].ema8_h1, 0),  ema8p  = Buf(g_h[hi].ema8_h1, 1);
   double ema21  = Buf(g_h[hi].ema21_h1, 0), ema21p = Buf(g_h[hi].ema21_h1, 1);
   double ema50  = Buf(g_h[hi].ema50_h1, 0);
   double e8m    = Buf(g_h[hi].ema8_m15, 0), e8mp  = Buf(g_h[hi].ema8_m15, 1);
   double e21m   = Buf(g_h[hi].ema21_m15,0), e21mp = Buf(g_h[hi].ema21_m15,1);
   double e50m   = Buf(g_h[hi].ema50_m15,0);

   string trend1h = bid > ema50 ? "BULLISH" : (bid < ema50 ? "BEARISH" : "NEUTRAL");
   string trend15 = bid > e50m  ? "BULLISH" : (bid < e50m  ? "BEARISH" : "NEUTRAL");
   string cross1h = (ema8p <= ema21p && ema8 > ema21) ? "BULLISH_CROSS" :
                    (ema8p >= ema21p && ema8 < ema21) ? "BEARISH_CROSS" :
                    (ema8 > ema21 ? "ABOVE" : "BELOW");
   string cross15 = (e8mp <= e21mp && e8m > e21m) ? "BULLISH_CROSS" :
                    (e8mp >= e21mp && e8m < e21m) ? "BEARISH_CROSS" :
                    (e8m > e21m ? "ABOVE" : "BELOW");

   double rsi14   = Buf(g_h[hi].rsi_h1, 1);
   double atr1h   = Buf(g_h[hi].atr_h1, 1);
   double atrm15  = Buf(g_h[hi].atr_m15,1);
   double atrd1   = Buf(g_h[hi].atr_d1, 1);
   double adx1h   = Buf(g_h[hi].adx_h1, 1);

   // 30-bar H/L/C (H1) and D1 OHLC arrays
   string h1H="", h1L="", h1C="";
   for (int b = 0; b <= 29; b++)
   {
      if (b > 0) { h1H+=","; h1L+=","; h1C+=","; }
      h1H += DoubleToString(iHigh(sym, PERIOD_H1, b), digits);
      h1L += DoubleToString(iLow (sym, PERIOD_H1, b), digits);
      h1C += DoubleToString(iClose(sym,PERIOD_H1, b), digits);
   }
   string d1O="", d1H="", d1L="", d1C="";
   for (int d = 0; d <= 29; d++)
   {
      if (d > 0) { d1O+=","; d1H+=","; d1L+=","; d1C+=","; }
      d1O += DoubleToString(iOpen (sym, PERIOD_D1, d), digits);
      d1H += DoubleToString(iHigh (sym, PERIOD_D1, d), digits);
      d1L += DoubleToString(iLow  (sym, PERIOD_D1, d), digits);
      d1C += DoubleToString(iClose(sym, PERIOD_D1, d), digits);
   }
   double prevClose = iClose(sym, PERIOD_D1, 1);

   // RVOL = today's D1 tick volume / 20-day average
   long volSum = 0; int vc = 0;
   for (int v = 1; v <= 20; v++) { volSum += iVolume(sym, PERIOD_D1, v); vc++; }
   double avgVol = vc > 0 ? (double)volSum / vc : 0.0;
   double rvol   = avgVol > 0 ? (double)iVolume(sym, PERIOD_D1, 0) / avgVol : 0.0;

   string assetClass   = ClassifyAsset(sym);
   long   expiration   = (long)SymbolInfoInteger(sym, SYMBOL_EXPIRATION_TIME);
   long   tradeMode    = SymbolInfoInteger(sym, SYMBOL_TRADE_MODE);
   double contractSize = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
   double tickValue    = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double marginInit   = SymbolInfoDouble(sym, SYMBOL_MARGIN_INITIAL);

   string j = "{";
   j += JStr("type","symbol_data") + ",";
   j += JStr("Symbol", sym) + ",";
   j += JStr("AssetClass", assetClass) + ",";
   j += JStr("Ask",  DoubleToString(ask, digits)) + ",";
   j += JStr("Bid",  DoubleToString(bid, digits)) + ",";
   j += JStr("Spread", DoubleToString(spread, digits)) + ",";
   j += JStr("Digits", IntegerToString(digits)) + ",";
   j += JStr("EMA8_1H", DoubleToString(ema8, digits)) + ",";
   j += JStr("EMA21_1H", DoubleToString(ema21, digits)) + ",";
   j += JStr("EMA50_1H", DoubleToString(ema50, digits)) + ",";
   j += JStr("Trend_1H", trend1h) + ",";
   j += JStr("EMA_Cross", cross1h) + ",";
   j += JStr("EMA8_15M", DoubleToString(e8m, digits)) + ",";
   j += JStr("EMA21_15M", DoubleToString(e21m, digits)) + ",";
   j += JStr("EMA50_15M", DoubleToString(e50m, digits)) + ",";
   j += JStr("Trend_15M", trend15) + ",";
   j += JStr("Cross_15M", cross15) + ",";
   j += JStr("RSI14_1H", DoubleToString(rsi14, 2)) + ",";
   j += JStr("ADX14_1H", DoubleToString(adx1h, 2)) + ",";
   j += JStr("ATR14_1H", DoubleToString(atr1h, digits)) + ",";
   j += JStr("ATR14_M15", DoubleToString(atrm15, digits)) + ",";
   j += JStr("ATR14_D1", DoubleToString(atrd1, digits)) + ",";
   j += JStr("BarHighs_1H", h1H) + ",";
   j += JStr("BarLows_1H", h1L) + ",";
   j += JStr("BarCloses_1H", h1C) + ",";
   j += JStr("D1_Opens", d1O) + ",";
   j += JStr("D1_Highs", d1H) + ",";
   j += JStr("D1_Lows", d1L) + ",";
   j += JStr("D1_Closes", d1C) + ",";
   j += JStr("PrevClose", DoubleToString(prevClose, digits)) + ",";
   j += JStr("RVOL", DoubleToString(rvol, 3)) + ",";
   j += JStr("ExpirationTime", IntegerToString(expiration)) + ",";
   j += JStr("TradeMode", IntegerToString(tradeMode)) + ",";
   j += JStr("ContractSize", DoubleToString(contractSize, 2)) + ",";
   j += JStr("TickValue", DoubleToString(tickValue, 5)) + ",";
   j += JStr("MarginRate", DoubleToString(marginInit, 2)) + ",";
   j += JStr("LastUpdate", TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)) + ",";
   j += JStr("WriteComplete", "1");
   j += "}";
   return j;
}

string BuildAccountJson()
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double mg = AccountInfoDouble(ACCOUNT_MARGIN);
   double ml = (eq > 0 && mg > 0) ? eq / mg * 100.0 : 0.0;
   string j = "{";
   j += JStr("type","account") + ",";
   j += JStr("AccountNumber", IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))) + ",";
   j += JStr("AccountName",   AccountInfoString(ACCOUNT_NAME)) + ",";
   j += JStr("AccountServer", AccountInfoString(ACCOUNT_SERVER)) + ",";
   j += JStr("AccountCompany",AccountInfoString(ACCOUNT_COMPANY)) + ",";
   j += JStr("Currency",      AccountInfoString(ACCOUNT_CURRENCY)) + ",";
   j += JStr("Balance",   DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2)) + ",";
   j += JStr("Equity",    DoubleToString(eq, 2)) + ",";
   j += JStr("Margin",    DoubleToString(mg, 2)) + ",";
   j += JStr("FreeMargin",DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2)) + ",";
   j += JStr("MarginLevel",DoubleToString(ml, 2)) + ",";
   j += JStr("Leverage",  IntegerToString(AccountInfoInteger(ACCOUNT_LEVERAGE)));
   j += "}";
   return j;
}

string BuildPositionsJson()
{
   string positions = ""; bool first = true;
   for (int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if (ticket == 0) continue;
      if (!PositionSelectByTicket(ticket)) continue;
      string sym = PositionGetString(POSITION_SYMBOL);
      int digs = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      string typ = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "BUY" : "SELL";
      if (!first) positions += ","; first = false;
      positions += "{";
      positions += JStr("Ticket", IntegerToString((long)ticket)) + ",";
      positions += JStr("Symbol", sym) + ",";
      positions += JStr("Type", typ) + ",";
      positions += JStr("Lots", DoubleToString(PositionGetDouble(POSITION_VOLUME), 2)) + ",";
      positions += JStr("OpenPrice", DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN), digs)) + ",";
      positions += JStr("CurrentPrice", DoubleToString(PositionGetDouble(POSITION_PRICE_CURRENT), digs)) + ",";
      positions += JStr("StopLoss", DoubleToString(PositionGetDouble(POSITION_SL), digs)) + ",";
      positions += JStr("TakeProfit", DoubleToString(PositionGetDouble(POSITION_TP), digs)) + ",";
      positions += JStr("Profit", DoubleToString(PositionGetDouble(POSITION_PROFIT), 2)) + ",";
      positions += JStr("Swap", DoubleToString(PositionGetDouble(POSITION_SWAP), 2)) + ",";
      positions += JStr("OpenTime", TimeToString((datetime)PositionGetInteger(POSITION_TIME))) + ",";
      positions += JStr("Comment", PositionGetString(POSITION_COMMENT));
      positions += "}";
   }

   string pendings = ""; first = true;
   for (int i = 0; i < OrdersTotal(); i++)
   {
      ulong ticket = OrderGetTicket(i);
      if (ticket == 0) continue;
      if (!OrderSelect(ticket)) continue;
      long ot = OrderGetInteger(ORDER_TYPE);
      string tstr;
      if      (ot == ORDER_TYPE_BUY_LIMIT)  tstr = "BUY_LIMIT";
      else if (ot == ORDER_TYPE_SELL_LIMIT) tstr = "SELL_LIMIT";
      else if (ot == ORDER_TYPE_BUY_STOP)   tstr = "BUY_STOP";
      else if (ot == ORDER_TYPE_SELL_STOP)  tstr = "SELL_STOP";
      else continue;
      string sym = OrderGetString(ORDER_SYMBOL);
      int digs = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
      if (!first) pendings += ","; first = false;
      pendings += "{";
      pendings += JStr("Ticket", IntegerToString((long)ticket)) + ",";
      pendings += JStr("Symbol", sym) + ",";
      pendings += JStr("Type", tstr) + ",";
      pendings += JStr("OpenPrice", DoubleToString(OrderGetDouble(ORDER_PRICE_OPEN), digs)) + ",";
      pendings += JStr("Lots", DoubleToString(OrderGetDouble(ORDER_VOLUME_INITIAL), 2)) + ",";
      pendings += JStr("StopLoss", DoubleToString(OrderGetDouble(ORDER_SL), digs)) + ",";
      pendings += JStr("TakeProfit", DoubleToString(OrderGetDouble(ORDER_TP), digs)) + ",";
      pendings += JStr("Comment", OrderGetString(ORDER_COMMENT));
      pendings += "}";
   }

   string j = "{";
   j += JStr("type","positions") + ",";
   j += "\"positions\":[" + positions + "],";
   j += "\"pending_orders\":[" + pendings + "]";
   j += "}";
   return j;
}
