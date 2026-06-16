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

ulong    g_lastPushMs = 0;   // wall-clock (GetTickCount64) — NOT server time, which freezes when the market is closed
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
            if (StringGetCharacter(line, 0) == '#') continue;
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

// Classify asset class from broker path (mirrors mt5_client_zmq.derive_asset_class).
// Pepperstone paths: Retail\Forwards\Bonds\EUBund-F, Retail\Stocks\UK\AAL.GB, etc.
// Forward CFDs (-F) live under \Forwards\ but have expiration_time=0, so path wins.
// Order: Forwards before Commodities (energy forwards contain both); metals before
// commodities (silver/gold sit under \Commodities\).
string ClassifyAsset(string sym)
{
   string lp = SymbolInfoString(sym, SYMBOL_PATH); StringToLower(lp);
   if (StringFind(lp, "\\forwards\\") >= 0
       || (datetime)SymbolInfoInteger(sym, SYMBOL_EXPIRATION_TIME) > 0)  return "forward";
   if (StringFind(lp, "\\stocks\\") >= 0 || StringFind(lp, "\\shares\\") >= 0) return "stock";
   if (StringFind(lp, "\\etfs\\") >= 0)                                  return "etf";
   if (StringFind(lp, "\\forex\\") >= 0 || StringFind(lp, "\\fx\\") >= 0) return "fx";
   if (StringFind(lp, "\\silver\\") >= 0 || StringFind(lp, "\\gold\\") >= 0
       || StringFind(lp, "\\metals\\") >= 0
       || StringFind(lp, "xau") >= 0 || StringFind(lp, "xag") >= 0)      return "metal";
   if (StringFind(lp, "\\commodit") >= 0 || StringFind(lp, "\\energ") >= 0
       || StringFind(lp, "\\softs\\") >= 0)                             return "commodity";
   if (StringFind(lp, "\\indices\\") >= 0 || StringFind(lp, "\\index\\") >= 0
       || StringFind(lp, "\\cash") >= 0)                               return "index";
   return "unknown";
}

string JsonEscape(string s)
{
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\n", "\\n");
   StringReplace(s, "\r", "\\r");
   StringReplace(s, "\t", "\\t");
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
   if (EnablePush && GetTickCount64() - g_lastPushMs >= (ulong)UpdateIntervalSec * 1000)
   {
      PushAllData();
      g_lastPushMs = GetTickCount64();
   }
   while (ProcessREPOnce()) {}
}

void PushAllData()
{
   // Non-blocking sends (nowait=true): if no Python PULL consumer is connected,
   // PUSH would otherwise BLOCK in mute state and starve the REP/order drain in
   // OnTimer (a live order command could hang). Dropping a data tick is safe —
   // the client keeps a latest-value cache — but order responsiveness is not.
   for (int i = 0; i < ArraySize(g_symbols); i++)
   {
      string sym = g_symbols[i];
      if (StringLen(sym) == 0) continue;
      string js = BuildSymbolJson(sym);
      if (StringLen(js) > 2) { ZmqMsg m(js); g_push.send(m, true); }
   }
   ZmqMsg am(BuildAccountJson());   g_push.send(am, true);
   ZmqMsg pm(BuildPositionsJson()); g_push.send(pm, true);
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
   j += JStr("Leverage",  IntegerToString(AccountInfoInteger(ACCOUNT_LEVERAGE))) + ",";
   long marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   string marginModeStr = (marginMode == ACCOUNT_MARGIN_MODE_RETAIL_NETTING) ? "netting"
                        : (marginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING) ? "hedging" : "exchange";
   j += JStr("MarginMode", marginModeStr);
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

string ExtractJsonValue(string json, string key)
{
   string sk = "\"" + key + "\":";
   int sp = StringFind(json, sk);
   if (sp < 0) return "";
   sp += StringLen(sk);
   while (sp < StringLen(json) && StringGetCharacter(json, sp) == ' ') sp++;
   int ep = sp;
   if (sp < StringLen(json) && StringGetCharacter(json, sp) == '"')
   {
      sp++; ep = sp;
      while (ep < StringLen(json) && StringGetCharacter(json, ep) != '"') ep++;
   }
   else
   {
      while (ep < StringLen(json))
      {
         ushort c = StringGetCharacter(json, ep);
         if (c == ',' || c == '}') break;
         ep++;
      }
   }
   return StringSubstr(json, sp, ep - sp);
}

bool ProcessREPOnce()
{
   ZmqMsg request;
   if (!g_rep.recv(request, true)) return false;   // NOBLOCK
   string cmd = request.getData();
   string resp = ProcessCommand(cmd);
   g_rep.send(resp);
   return true;
}

string ProcessCommand(string cmd)
{
   string a = ExtractJsonValue(cmd, "cmd");
   if (a == "ping")             return "{\"success\":true,\"type\":\"pong\"}";
   if (a == "place_order")      return HandlePlaceOrder(cmd);
   if (a == "close")            return HandleClose(cmd);
   if (a == "modify")           return HandleModify(cmd);
   if (a == "history")          return HandleHistory(cmd);
   if (a == "deals")            return HandleDeals(cmd);
   if (a == "discover")         return HandleDiscover(cmd);
   return StringFormat("{\"success\":false,\"error\":\"unknown cmd: %s\"}", a);
}

string HandlePlaceOrder(string cmd)
{
   string symbol = ExtractJsonValue(cmd, "symbol");
   string op     = ExtractJsonValue(cmd, "operation");
   double lots   = StringToDouble(ExtractJsonValue(cmd, "lots"));
   double price  = StringToDouble(ExtractJsonValue(cmd, "price"));
   double sl     = StringToDouble(ExtractJsonValue(cmd, "stop_loss"));
   double tp     = StringToDouble(ExtractJsonValue(cmd, "take_profit"));
   string comment= ExtractJsonValue(cmd, "comment");

   if (!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return "{\"success\":false,\"error\":\"AutoTrading disabled\"}";

   // Normalise lots to broker constraints
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double mn   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double mx   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   if (step > 0) lots = MathFloor(lots / step) * step;
   lots = MathMax(mn, MathMin(mx, lots));

   // Idempotency — suppress duplicate by matching comment+magic on open positions
   for (int i = 0; i < PositionsTotal(); i++)
   {
      ulong t = PositionGetTicket(i);
      if (t == 0 || !PositionSelectByTicket(t)) continue;
      if (PositionGetString(POSITION_SYMBOL) == symbol &&
          PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
          StringLen(comment) > 0 &&
          StringFind(PositionGetString(POSITION_COMMENT), comment) >= 0)
         return StringFormat("{\"success\":true,\"ticket\":%s,\"duplicate\":true,\"symbol\":\"%s\"}", IntegerToString((long)t), symbol);
   }

   g_trade.SetTypeFillingBySymbol(symbol);
   bool ok = false;
   if      (op == "BUY")        ok = g_trade.Buy (lots, symbol, 0.0, sl, tp, comment);
   else if (op == "SELL")       ok = g_trade.Sell(lots, symbol, 0.0, sl, tp, comment);
   else if (op == "BUY_LIMIT")  ok = g_trade.BuyLimit (lots, price, symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
   else if (op == "SELL_LIMIT") ok = g_trade.SellLimit(lots, price, symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
   else if (op == "BUY_STOP")   ok = g_trade.BuyStop  (lots, price, symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
   else if (op == "SELL_STOP")  ok = g_trade.SellStop (lots, price, symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
   else return StringFormat("{\"success\":false,\"error\":\"invalid operation: %s\"}", op);

   if (ok && (g_trade.ResultRetcode() == TRADE_RETCODE_DONE ||
              g_trade.ResultRetcode() == TRADE_RETCODE_PLACED))
   {
      return StringFormat(
         "{\"success\":true,\"ticket\":%s,\"symbol\":\"%s\",\"operation\":\"%s\","
         "\"lots\":%s,\"open_price\":%s}",
         IntegerToString((long)g_trade.ResultOrder()), symbol, op,
         DoubleToString(lots, 2), DoubleToString(g_trade.ResultPrice(), 5));
   }
   return StringFormat(
      "{\"success\":false,\"error\":%s,\"description\":\"%s\",\"symbol\":\"%s\"}",
      IntegerToString((int)g_trade.ResultRetcode()),
      JsonEscape(g_trade.ResultRetcodeDescription()), symbol);
}

string HandleClose(string cmd)
{
   ulong  ticket  = (ulong)StringToInteger(ExtractJsonValue(cmd, "ticket"));
   double reqLots = StringToDouble(ExtractJsonValue(cmd, "lots"));   // 0 = full

   // Pending order? delete it.
   if (OrderSelect(ticket))
   {
      if (g_trade.OrderDelete(ticket))
         return StringFormat("{\"success\":true,\"ticket\":%s,\"deleted\":true}", IntegerToString((long)ticket));
      return StringFormat("{\"success\":false,\"ticket\":%s,\"error\":%s}", IntegerToString((long)ticket), IntegerToString((int)g_trade.ResultRetcode()));
   }

   if (!PositionSelectByTicket(ticket))
      return StringFormat("{\"success\":false,\"ticket\":%s,\"error\":\"not found\"}", IntegerToString((long)ticket));

   double full = PositionGetDouble(POSITION_VOLUME);
   bool ok;
   if (reqLots > 0 && reqLots < full)
   {
      string sym = PositionGetString(POSITION_SYMBOL);
      double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
      double mn   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
      double cl   = MathMax(mn, MathFloor(reqLots / step) * step);
      ok = g_trade.PositionClosePartial(ticket, cl);
   }
   else ok = g_trade.PositionClose(ticket);

   if (ok && (g_trade.ResultRetcode() == TRADE_RETCODE_DONE ||
              g_trade.ResultRetcode() == TRADE_RETCODE_PLACED))
      return StringFormat("{\"success\":true,\"ticket\":%s,\"close_price\":%s}", IntegerToString((long)ticket), DoubleToString(g_trade.ResultPrice(), 5));
   return StringFormat("{\"success\":false,\"ticket\":%s,\"error\":%s}", IntegerToString((long)ticket), IntegerToString((int)g_trade.ResultRetcode()));
}

string HandleModify(string cmd)
{
   ulong  ticket = (ulong)StringToInteger(ExtractJsonValue(cmd, "ticket"));
   double sl     = StringToDouble(ExtractJsonValue(cmd, "stop_loss"));
   double tp     = StringToDouble(ExtractJsonValue(cmd, "take_profit"));
   if (!PositionSelectByTicket(ticket))
      return StringFormat("{\"success\":false,\"ticket\":%s,\"error\":\"not found\"}", IntegerToString((long)ticket));
   if (g_trade.PositionModify(ticket, sl, tp))
      return StringFormat("{\"success\":true,\"ticket\":%s,\"sl\":%s,\"tp\":%s}", IntegerToString((long)ticket), DoubleToString(sl, 5), DoubleToString(tp, 5));
   return StringFormat("{\"success\":false,\"ticket\":%s,\"error\":%s}", IntegerToString((long)ticket), IntegerToString((int)g_trade.ResultRetcode()));
}

ENUM_TIMEFRAMES TfFromStr(string tf)
{
   if (tf == "M5")  return PERIOD_M5;
   if (tf == "M15") return PERIOD_M15;
   if (tf == "H1")  return PERIOD_H1;
   if (tf == "H4")  return PERIOD_H4;
   return PERIOD_D1;
}

string HandleHistory(string cmd)
{
   string sym = ExtractJsonValue(cmd, "symbol");
   ENUM_TIMEFRAMES tf = TfFromStr(ExtractJsonValue(cmd, "timeframe"));
   int count = (int)StringToInteger(ExtractJsonValue(cmd, "count"));
   if (count <= 0 || count > HistoryMaxBars) count = HistoryMaxBars;

   MqlRates r[];
   ArraySetAsSeries(r, false);
   int got = CopyRates(sym, tf, 0, count, r);
   if (got <= 0)
      return StringFormat("{\"type\":\"history\",\"success\":false,\"symbol\":\"%s\",\"error\":\"no bars\"}", sym);

   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   string bars = "";
   for (int i = 0; i < got; i++)
   {
      if (i > 0) bars += ",";
      bars += StringFormat("{\"t\":%s,\"o\":%s,\"h\":%s,\"l\":%s,\"c\":%s,\"v\":%s}",
              IntegerToString((long)r[i].time),
              DoubleToString(r[i].open,  digits),
              DoubleToString(r[i].high,  digits),
              DoubleToString(r[i].low,   digits),
              DoubleToString(r[i].close, digits),
              IntegerToString((long)r[i].tick_volume));
   }
   return StringFormat("{\"type\":\"history\",\"success\":true,\"symbol\":\"%s\",\"count\":%d,\"bars\":[%s]}",
                       sym, got, bars);
}

string HandleDeals(string cmd)
{
   long from = StringToInteger(ExtractJsonValue(cmd, "from"));
   long to   = StringToInteger(ExtractJsonValue(cmd, "to"));
   if (to <= 0) to = (long)TimeCurrent();

   if (!HistorySelect((datetime)from, (datetime)to))
      return "{\"type\":\"deals\",\"success\":false,\"error\":\"history_select_failed\"}";

   int total = HistoryDealsTotal();
   string deals = "";
   int n = 0;
   for (int i = 0; i < total; i++)
   {
      ulong t = HistoryDealGetTicket(i);
      if (t == 0) continue;
      string sym = HistoryDealGetString(t, DEAL_SYMBOL);
      int digits = (sym != "") ? (int)SymbolInfoInteger(sym, SYMBOL_DIGITS) : 2;
      string row = "{";
      row += JStr("deal_id",     IntegerToString((long)t)) + ",";
      row += JStr("order",       IntegerToString((long)HistoryDealGetInteger(t, DEAL_ORDER))) + ",";
      row += JStr("position_id", IntegerToString((long)HistoryDealGetInteger(t, DEAL_POSITION_ID))) + ",";
      row += JStr("magic",       IntegerToString((long)HistoryDealGetInteger(t, DEAL_MAGIC))) + ",";
      row += JStr("type",        IntegerToString((long)HistoryDealGetInteger(t, DEAL_TYPE))) + ",";
      row += JStr("entry",       IntegerToString((long)HistoryDealGetInteger(t, DEAL_ENTRY))) + ",";
      row += JStr("symbol",      sym) + ",";
      row += JStr("volume",      DoubleToString(HistoryDealGetDouble(t, DEAL_VOLUME), 2)) + ",";
      row += JStr("price",       DoubleToString(HistoryDealGetDouble(t, DEAL_PRICE), digits)) + ",";
      row += JStr("commission",  DoubleToString(HistoryDealGetDouble(t, DEAL_COMMISSION), 2)) + ",";
      row += JStr("swap",        DoubleToString(HistoryDealGetDouble(t, DEAL_SWAP), 2)) + ",";
      row += JStr("profit",      DoubleToString(HistoryDealGetDouble(t, DEAL_PROFIT), 2)) + ",";
      row += JStr("time",        IntegerToString((long)HistoryDealGetInteger(t, DEAL_TIME))) + ",";
      row += JStr("comment",     HistoryDealGetString(t, DEAL_COMMENT));
      row += "}";
      if (n > 0) deals += ",";
      deals += row;
      n++;
   }
   return StringFormat("{\"type\":\"deals\",\"success\":true,\"count\":%d,\"deals\":[%s]}", n, deals);
}

// Build one discover row (a JSON object string) for symbol sym.
string DiscoverRow(string sym)
{
   string r = "{";
   r += JStr("symbol", sym) + ",";
   r += JStr("path", SymbolInfoString(sym, SYMBOL_PATH)) + ",";
   r += JStr("asset_class", ClassifyAsset(sym)) + ",";
   r += JStr("description", SymbolInfoString(sym, SYMBOL_DESCRIPTION)) + ",";
   r += JStr("trade_mode", IntegerToString(SymbolInfoInteger(sym, SYMBOL_TRADE_MODE))) + ",";
   r += JStr("digits", IntegerToString(SymbolInfoInteger(sym, SYMBOL_DIGITS))) + ",";
   r += JStr("point", DoubleToString(SymbolInfoDouble(sym, SYMBOL_POINT), 8)) + ",";
   r += JStr("contract_size", DoubleToString(SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE), 2)) + ",";
   r += JStr("min_lot", DoubleToString(SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN), 2)) + ",";
   r += JStr("max_lot", DoubleToString(SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX), 2)) + ",";
   r += JStr("lot_step", DoubleToString(SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP), 2)) + ",";
   r += JStr("tick_value", DoubleToString(SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE), 5)) + ",";
   r += JStr("tick_size", DoubleToString(SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE), 8)) + ",";
   r += JStr("margin_initial", DoubleToString(SymbolInfoDouble(sym, SYMBOL_MARGIN_INITIAL), 2)) + ",";
   r += JStr("swap_long", DoubleToString(SymbolInfoDouble(sym, SYMBOL_SWAP_LONG), 4)) + ",";
   r += JStr("swap_short", DoubleToString(SymbolInfoDouble(sym, SYMBOL_SWAP_SHORT), 4)) + ",";
   r += JStr("swap_mode", IntegerToString(SymbolInfoInteger(sym, SYMBOL_SWAP_MODE))) + ",";
   r += JStr("currency_base", SymbolInfoString(sym, SYMBOL_CURRENCY_BASE)) + ",";
   r += JStr("currency_profit", SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT)) + ",";
   r += JStr("currency_margin", SymbolInfoString(sym, SYMBOL_CURRENCY_MARGIN)) + ",";
   r += JStr("sector", IntegerToString(SymbolInfoInteger(sym, SYMBOL_SECTOR))) + ",";
   r += JStr("industry", IntegerToString(SymbolInfoInteger(sym, SYMBOL_INDUSTRY))) + ",";
   // SYMBOL_MARGIN_INITIAL is 0 on Pepperstone; the real leverage comes from the margin RATE.
   double mrInit = 0.0, mrMaint = 0.0;
   SymbolInfoMarginRate(sym, ORDER_TYPE_BUY, mrInit, mrMaint);
   r += JStr("margin_rate", DoubleToString(mrInit, 6)) + ",";
   r += JStr("expiration_time", IntegerToString(SymbolInfoInteger(sym, SYMBOL_EXPIRATION_TIME)));
   r += "}";
   return r;
}

// Rebuild the discover cache from the FULL broker symbol tree (selected=false).
void BuildDiscoverCache()
{
   int total = SymbolsTotal(false);
   ArrayResize(g_discoverRows, total);
   for (int i = 0; i < total; i++)
      g_discoverRows[i] = DiscoverRow(SymbolName(i, false));
   g_discoverCount = total;
}

string HandleDiscover(string cmd)
{
   string chunkStr = ExtractJsonValue(cmd, "chunk");
   int chunk = StringLen(chunkStr) > 0 ? (int)StringToInteger(chunkStr) : 0;
   if (chunk == 0) BuildDiscoverCache();   // (re)build on first chunk

   int chunks = (g_discoverCount + DiscoverChunkSize - 1) / DiscoverChunkSize;
   if (chunks == 0) chunks = 1;
   int start = chunk * DiscoverChunkSize;
   int end   = MathMin(start + DiscoverChunkSize, g_discoverCount);

   string arr = "";
   for (int i = start; i < end; i++)
   {
      if (i > start) arr += ",";
      arr += g_discoverRows[i];
   }
   return StringFormat(
      "{\"type\":\"discover\",\"success\":true,\"count\":%d,\"chunk\":%d,\"chunks\":%d,\"symbols\":[%s]}",
      g_discoverCount, chunk, chunks, arr);
}
