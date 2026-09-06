//+------------------------------------------------------------------+
//| ZeroMQ_Bridge.mq4                                                |
//| Unified ZeroMQ bridge — replaces ClaudeDataExport + MCP_Ultimate|
//|                                                                   |
//| INSTALLATION (one-time manual steps):                            |
//|   1. Download mql-zmq: https://github.com/dingmaotu/mql-zmq      |
//|   2. Copy libzmq.dll → <MT4_DATA>\MQL4\Libraries\libzmq.dll      |
//|   3. Copy Zmq\ folder → <MT4_DATA>\MQL4\Include\Zmq\            |
//|   4. MT4 → Tools → Options → Expert Advisors → Allow DLL imports |
//|   5. Compile this EA in MetaEditor (F7)                          |
//|   6. Attach to any chart (it runs for all configured symbols)    |
//|                                                                   |
//| Socket topology (MT4 binds, Python connects):                    |
//|   PUSH tcp://*:5556  → Python PULL  (indicator data, ~1s push)  |
//|   REP  tcp://*:5555  ← Python REQ   (orders / close / modify)   |
//|                                                                   |
//| JSON values are strings to match existing file-format parsing.   |
//| Keys are identical to claude_data_SYMBOL.txt / positions.txt so  |
//| agent.py requires zero changes.                                   |
//+------------------------------------------------------------------+
#property copyright "Claude Trading Agent"
#property version   "1.00"
#property strict

#include <Zmq/Zmq.mqh>

// ---------------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------------
extern int    UpdateIntervalSec = 3;          // Data push interval (seconds)
extern int    DataPushPort      = 5558;       // PUSH port (data → Python) — scalper
extern int    OrderRepPort      = 5557;       // REP port  (orders ← Python) — scalper
// SymbolList is loaded from MQL4\Files\symbols.txt at OnInit if the file is
// present (deploy_ea.bat copies it from D:\Claude - MT4 - Scalper\symbols.txt).
// This default is the fallback used when symbols.txt is missing — keep it in
// sync with the scalper repo's symbols.txt so a manual reattach still works.
extern string SymbolList        = "EURUSD.r,GBPUSD.r,USDJPY.r,NZDUSD.r,CADJPY.r,AUDUSD.r,USDCHF.r,GBPAUD.r,GBPJPY.r,XAUUSD.r";
extern int    MagicNumber       = 20260200;   // scalper magic (swing uses 20260101)
extern string SymbolListFile    = "symbols.txt";   // file under MQL4\Files\ — blank to disable runtime load
// EnablePush=false makes this a REP-only bridge (history/orders), skipping all
// PUSH sends. A ZMQ PUSH socket with no connected consumer BLOCKS on send (mute
// state), which hangs OnTimer before the REP drain and kills REP. The file-based
// swing agent never consumes the PUSH stream, so it runs this bridge with
// EnablePush=false (history side-channel only). Leave true for the scalper and
// for a future direct-ZMQ agent that PULLs the data stream.
extern bool   EnablePush        = true;       // false = REP-only (no data PUSH)

// ---------------------------------------------------------------------------
// DEAD-MAN HEARTBEAT (2026-09-06)
// ---------------------------------------------------------------------------
// THE GAP IT CLOSES. Python cannot flatten over a failed bridge, so every
// agent-side protection -- the time exit, the 16:30 flatten, the profit lock --
// is unavailable exactly when the CHANNEL is the thing that broke. Only a
// broker-side contract can act then. Server-side SL/TP still bound the loss,
// which is why this was filed as a gap and not an emergency.
//
// WHAT IT DOES, and it is deliberately the NARROW half: on expiry the bridge
// REFUSES NEW ORDERS. It does not flatten. Flattening on a heartbeat expiry
// would close live positions on a transient socket hiccup, turning a
// communications fault into a realised loss -- worse than the disease. Refusing
// an entry is fail-safe: the cost is a skipped trade.
//
// THE REAL SCENARIO IT GUARDS. ZMQ REQ/REP queues. An order computed on a quote
// from minutes ago can sit in a socket buffer and be delivered late, after a
// reconnect -- and the agent's own staleness and drift aborts all run BEFORE the
// send, so they cannot see it. A stale heartbeat is the only evidence available
// on this side that the message crossing the wire is older than it looks.
//
// SELF-ARMING, which is what makes it safe to ship enabled. g_hbArmed starts
// false and is set by the FIRST ping. A consumer that never pings is never armed
// and is never refused, so the file-based swing bridge (magic 20260101,
// EnablePush=false, no pings) is untouched BY CONSTRUCTION rather than by a
// setting someone has to remember on every reattach. HeartbeatTimeoutSec=0
// disables it outright.
//
// CLOSE and MODIFY are NEVER gated -- reducing or protecting an existing
// position must work even when the channel is suspect. Only NEW exposure is
// refused.
extern int    HeartbeatTimeoutSec = 90;       // 0 = off; refuse NEW orders after this many seconds with no ping

datetime g_lastHeartbeat = 0;                 // when the last ping arrived
bool     g_hbArmed       = false;             // set by the first ping; never cleared
bool     g_hbRefusing    = false;             // latch so an episode logs once, not per order

// ---------------------------------------------------------------------------
// ZMQ context and sockets (module-level; created once)
// ---------------------------------------------------------------------------
Context g_ctx("ZeroMQ_Bridge");
Socket  g_push(g_ctx, ZMQ_PUSH);
Socket  g_rep(g_ctx, ZMQ_REP);

datetime g_lastPush = 0;

// ---------------------------------------------------------------------------
// Per-ticket excursion tracking (2026-09-02)
//
// The Python agent's mfe_r/mae_r are a 5s poll of its ZMQ quote cache, so they
// are a FLOOR on the true excursion, not a measurement (bar-extreme adjudication
// put the understatement at median +0.048R, p90 +0.392R, max +1.854R). OnTimer
// already fires at 100ms while PushAllData() is gated to UpdateIntervalSec (3s),
// so the EA can carry high-water marks at 50x the Python sample rate and emit
// them on the EXISTING positions payload — no new message type, no extra traffic.
//
// The EA stays dumb: it emits RAW closing prices and does no R arithmetic. The
// agent maps Max/Min to favourable/adverse by direction, where the entry, the
// entry stop and the tested _price_dist_to_gbp conversion already live.
//
// Parallel arrays keyed by ticket; g_trkCount is the live length and ArraySize()
// is the capacity, which is never shrunk (a closed ticket frees its slot for the
// next one instead of reallocating). Position counts here are single digits, so
// the linear TrackFind() is cheaper than any index at 10 Hz.
// ---------------------------------------------------------------------------
int      g_trkTicket[];    // ticket id
double   g_trkMax[];       // highest CLOSING price seen since tracking began
double   g_trkMin[];       // lowest  CLOSING price seen since tracking began
datetime g_trkSince[];     // when tracking began for this ticket
int      g_trkSeen[];      // scratch, one pass only (0/1 — MQL4 bool[] has no
                           // precedent in this file and F7 is a manual step) — evicts tickets that closed
int      g_trkCount = 0;   // live entries occupy [0 .. g_trkCount-1]

// ---------------------------------------------------------------------------
// Symbol list loader — reads MQL4\Files\<SymbolListFile> if present
//
// Format: one symbol per line. Blank lines and lines starting with '#' are
// ignored. Returns a comma-separated string usable by StringSplit, or ""
// when the file is missing/empty (caller falls back to the extern SymbolList).
//
// This keeps the EA in sync with the scalper repo's symbols.txt — add a
// symbol there, run deploy_ea.bat (which also copies symbols.txt), reattach
// the EA, done. No EA recompile needed for symbol-list changes.
// ---------------------------------------------------------------------------
string LoadSymbolListFromFile(string fname)
{
   if (StringLen(fname) == 0) return "";
   int fh = FileOpen(fname, FILE_READ | FILE_TXT | FILE_ANSI);
   if (fh == INVALID_HANDLE) return "";

   string out = "";
   int count = 0;
   while (!FileIsEnding(fh))
   {
      string line = FileReadString(fh);
      StringTrimLeft(line);
      StringTrimRight(line);
      if (StringLen(line) == 0) continue;
      if (StringGetChar(line, 0) == '#') continue;
      if (count > 0) out += ",";
      out += line;
      count++;
   }
   FileClose(fh);
   if (count == 0) return "";
   Print("ZMQ_Bridge: loaded ", count, " symbols from ", fname);
   return out;
}

// ---------------------------------------------------------------------------
// Init / Deinit
// ---------------------------------------------------------------------------

int OnInit()
{
   string pushAddr = "tcp://*:" + IntegerToString(DataPushPort);
   string repAddr  = "tcp://*:" + IntegerToString(OrderRepPort);

   if (!g_push.bind(pushAddr)) { Print("ZMQ_Bridge: PUSH bind failed on ", pushAddr); return INIT_FAILED; }
   if (!g_rep.bind(repAddr))   { Print("ZMQ_Bridge: REP bind failed on ",  repAddr);  return INIT_FAILED; }

   g_push.setLinger(0);
   g_rep.setLinger(0);

   // Override extern SymbolList with the file-based list if present
   string loaded = LoadSymbolListFromFile(SymbolListFile);
   if (StringLen(loaded) > 0)
   {
      SymbolList = loaded;
      Print("ZMQ_Bridge: SymbolList <- ", SymbolList, " (from ", SymbolListFile, ")");
   }
   else
   {
      Print("ZMQ_Bridge: SymbolList <- ", SymbolList, " (extern fallback; ", SymbolListFile, " not found)");
   }

   Print("ZMQ_Bridge v1.0 started — PUSH=", pushAddr, "  REP=", repAddr);
   // The dead-man contract starts DISARMED on every attach and is armed by the
   // first ping, so a reattach can never inherit a stale clock and refuse the
   // agent's first order.
   g_lastHeartbeat = 0;
   g_hbArmed       = false;
   g_hbRefusing    = false;
   if (HeartbeatTimeoutSec > 0)
      Print("ZMQ_Bridge: dead-man heartbeat ready — arms on the first ping, ",
            "timeout ", HeartbeatTimeoutSec, "s (new orders only; close/modify ",
            "are never gated)");
   else
      Print("ZMQ_Bridge: dead-man heartbeat DISABLED (HeartbeatTimeoutSec=0)");
   EventSetMillisecondTimer(100);   // 100ms timer keeps REP latency low

   // Do NOT call PushAllData() here. Calling it in OnInit blocks the MT4 main
   // thread while loading indicator history for every symbol in SymbolList
   // across M15/H1/H4 timeframes, causing the terminal to freeze until all
   // history is fetched from disk. The timer fires within 100ms anyway.
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   g_push.unbind("tcp://*:" + IntegerToString(DataPushPort));
   g_rep.unbind("tcp://*:" + IntegerToString(OrderRepPort));
   Print("ZMQ_Bridge: shutdown (reason=", reason, ")");
}

// ---------------------------------------------------------------------------
// Timer — rate-limited data push + non-blocking REP drain
// ---------------------------------------------------------------------------

void OnTimer()
{
   // PUSH is gated: a consumer-less PUSH send blocks (mute state) and would
   // stall this loop before the REP drain. EnablePush=false => pure REP bridge.
   if (EnablePush && TimeCurrent() - g_lastPush >= UpdateIntervalSec)
   {
      PushAllData();
      g_lastPush = TimeCurrent();
   }

   // Drain all pending REP requests without blocking
   while (ProcessREPOnce()) {}

   // Excursion tracking runs LAST, AFTER the REP drain — never before it.
   // MT4 is single-threaded and OnTimer already pushes data before draining the
   // order socket; anything inserted ahead of the drain lengthens the MONEY PATH
   // (order send->ack is 165ms median and this timer is the only thing servicing
   // REP). Placing it here makes that structural instead of a claim. DO NOT MOVE
   // THIS CALL UP — the harm would be silent, showing up only as slower fills.
   UpdateExcursionTracking();
}

bool ProcessREPOnce()
{
   ZmqMsg request;
   if (!g_rep.recv(request, true))   // true = NOBLOCK; returns false if no msg
      return false;

   string cmd      = request.getData();
   string response = ProcessCommand(cmd);
   g_rep.send(response);
   return true;
}

// ---------------------------------------------------------------------------
// Excursion tracking — high-water marks per open ticket, updated every OnTimer
// ---------------------------------------------------------------------------

// Slot index for a ticket, or -1 if it is not being tracked.
int TrackFind(int ticket)
{
   for (int i = 0; i < g_trkCount; i++)
      if (g_trkTicket[i] == ticket) return i;
   return -1;
}

// Sample every open market position at the price it would actually CLOSE at —
// bid for a BUY, ask for a SELL — and carry the running max/min. Called from
// OnTimer AFTER the REP drain (see the comment there); nothing in here touches
// the order path, sends on a socket, or modifies an order.
void UpdateExcursionTracking()
{
   // Mark every tracked ticket unseen. Anything still unseen after the scan has
   // closed and its slot is reclaimed below, so the arrays cannot grow forever.
   for (int i = 0; i < g_trkCount; i++)
      g_trkSeen[i] = 0;

   for (int p = 0; p < OrdersTotal(); p++)
   {
      if (!OrderSelect(p, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderType() > 1) continue;   // skip pending — matches BuildPositionsJson

      int tk  = OrderTicket();
      int idx = TrackFind(tk);

      // Mark seen BEFORE the quote check. The position is demonstrably still
      // open, so the slot must survive even if this pass cannot price it —
      // otherwise a single bad quote would evict the ticket and re-seed its
      // high-water marks from the current price, silently losing the excursion.
      if (idx >= 0) g_trkSeen[idx] = 1;

      string sym = OrderSymbol();
      double px  = (OrderType() == OP_BUY) ? MarketInfo(sym, MODE_BID)
                                           : MarketInfo(sym, MODE_ASK);
      // A symbol with no quote yet returns 0. Seeding a high-water mark from
      // zero would report a MinPrice of 0 forever, so hold what we have rather
      // than record it — absent is not a measurement.
      if (px <= 0) continue;

      if (idx < 0)
      {
         // New ticket. Grow only when capacity is actually short; a slot freed
         // by a closed ticket is reused as-is.
         idx = g_trkCount;
         g_trkCount++;
         if (ArraySize(g_trkTicket) < g_trkCount)
         {
            ArrayResize(g_trkTicket, g_trkCount);
            ArrayResize(g_trkMax,    g_trkCount);
            ArrayResize(g_trkMin,    g_trkCount);
            ArrayResize(g_trkSince,  g_trkCount);
            ArrayResize(g_trkSeen,   g_trkCount);
         }
         g_trkTicket[idx] = tk;
         g_trkMax[idx]    = px;
         g_trkMin[idx]    = px;
         g_trkSince[idx]  = TimeCurrent();
         g_trkSeen[idx]   = 1;      // explicit, so a reused slot is never stale
      }
      else
      {
         if (px > g_trkMax[idx]) g_trkMax[idx] = px;
         if (px < g_trkMin[idx]) g_trkMin[idx] = px;
      }
   }

   // Compact — keep the seen entries in order, drop the rest. g_trkCount falls;
   // the allocated capacity is deliberately left alone for reuse.
   int w = 0;
   for (int r = 0; r < g_trkCount; r++)
   {
      if (g_trkSeen[r] == 0) continue;
      if (w != r)
      {
         g_trkTicket[w] = g_trkTicket[r];
         g_trkMax[w]    = g_trkMax[r];
         g_trkMin[w]    = g_trkMin[r];
         g_trkSince[w]  = g_trkSince[r];
      }
      w++;
   }
   g_trkCount = w;
}

// ---------------------------------------------------------------------------
// Data push — one PUSH message per symbol, then account + positions
// ---------------------------------------------------------------------------

void PushAllData()
{
   string parts[];
   int n = StringSplit(SymbolList, ',', parts);
   for (int i = 0; i < n; i++)
   {
      string sym = parts[i];
      StringTrimLeft(sym);
      StringTrimRight(sym);
      if (StringLen(sym) == 0) continue;
      string json = BuildSymbolJson(sym);
      if (StringLen(json) > 2)
      {
         ZmqMsg msg(json);
         g_push.send(msg);
      }
   }

   string accountJson = BuildAccountJson();
   ZmqMsg accMsg(accountJson);
   g_push.send(accMsg);

   string posJson = BuildPositionsJson();
   ZmqMsg posMsg(posJson);
   g_push.send(posMsg);
}

// ---------------------------------------------------------------------------
// JSON helper — wrap one key/string-value pair: "key":"value"
// ---------------------------------------------------------------------------

string JStr(string key, string val)
{
   return "\"" + key + "\":\"" + val + "\"";
}

// ---------------------------------------------------------------------------
// Symbol data builder — all fields identical to ClaudeDataExport.mq4
// ---------------------------------------------------------------------------

string BuildSymbolJson(string sym)
{
   int    tf     = PERIOD_H1;
   int    digits = (int)MarketInfo(sym, MODE_DIGITS);
   double ask    = MarketInfo(sym, MODE_ASK);
   double bid    = MarketInfo(sym, MODE_BID);
   double point  = MarketInfo(sym, MODE_POINT);
   double spread = MarketInfo(sym, MODE_SPREAD) * point;

   // 1H EMAs
   double ema8_cur   = iMA(sym, tf,  8, 0, MODE_EMA, PRICE_CLOSE, 0);
   double ema8_prev  = iMA(sym, tf,  8, 0, MODE_EMA, PRICE_CLOSE, 1);
   double ema21_cur  = iMA(sym, tf, 21, 0, MODE_EMA, PRICE_CLOSE, 0);
   double ema21_prev = iMA(sym, tf, 21, 0, MODE_EMA, PRICE_CLOSE, 1);
   double ema50_cur  = iMA(sym, tf, 50, 0, MODE_EMA, PRICE_CLOSE, 0);

   // 15M EMAs
   double ema8_15m_cur   = iMA(sym, PERIOD_M15,  8, 0, MODE_EMA, PRICE_CLOSE, 0);
   double ema8_15m_prev  = iMA(sym, PERIOD_M15,  8, 0, MODE_EMA, PRICE_CLOSE, 1);
   double ema21_15m_cur  = iMA(sym, PERIOD_M15, 21, 0, MODE_EMA, PRICE_CLOSE, 0);
   double ema21_15m_prev = iMA(sym, PERIOD_M15, 21, 0, MODE_EMA, PRICE_CLOSE, 1);
   double ema50_15m      = iMA(sym, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE, 0);

   // 4H EMA50
   double ema50_4h = iMA(sym, PERIOD_H4, 50, 0, MODE_EMA, PRICE_CLOSE, 0);

   // Trend / cross strings
   string trend_1h  = (bid > ema50_cur) ? "BULLISH" : ((bid < ema50_cur) ? "BEARISH" : "NEUTRAL");
   string trend_4h  = (bid > ema50_4h)  ? "BULLISH" : ((bid < ema50_4h)  ? "BEARISH" : "NEUTRAL");
   string trend_15m = (bid > ema50_15m) ? "BULLISH" : ((bid < ema50_15m) ? "BEARISH" : "NEUTRAL");

   string cross_1h;
   if      (ema8_prev <= ema21_prev && ema8_cur > ema21_cur)  cross_1h = "BULLISH_CROSS";
   else if (ema8_prev >= ema21_prev && ema8_cur < ema21_cur)  cross_1h = "BEARISH_CROSS";
   else if (ema8_cur > ema21_cur)                              cross_1h = "ABOVE";
   else                                                         cross_1h = "BELOW";

   string cross_15m;
   if      (ema8_15m_prev <= ema21_15m_prev && ema8_15m_cur > ema21_15m_cur)  cross_15m = "BULLISH_CROSS";
   else if (ema8_15m_prev >= ema21_15m_prev && ema8_15m_cur < ema21_15m_cur)  cross_15m = "BEARISH_CROSS";
   else if (ema8_15m_cur > ema21_15m_cur)                                      cross_15m = "ABOVE";
   else                                                                          cross_15m = "BELOW";

   // Current and previous 1H bars
   datetime t0 = iTime(sym, tf, 0);
   double o0 = iOpen(sym, tf, 0), h0 = iHigh(sym, tf, 0);
   double l0 = iLow(sym,  tf, 0), c0 = iClose(sym, tf, 0);
   datetime t1 = iTime(sym, tf, 1);
   double o1 = iOpen(sym, tf, 1), h1 = iHigh(sym, tf, 1);
   double l1 = iLow(sym,  tf, 1), c1 = iClose(sym, tf, 1);

   // RSI(14) single value + 10-bar array
   double rsi14 = iRSI(sym, PERIOD_H1, 14, PRICE_CLOSE, 1);
   string rsiArr = "";
   for (int b = 1; b <= 10; b++)
   {
      if (b > 1) rsiArr += ",";
      rsiArr += DoubleToString(iRSI(sym, PERIOD_H1, 14, PRICE_CLOSE, b), 2);
   }

   // Volume array (20 bars)
   string volArr = "";
   for (int b = 1; b <= 20; b++)
   {
      if (b > 1) volArr += ",";
      volArr += IntegerToString((long)iVolume(sym, PERIOD_H1, b));
   }

   // ADX
   double adx14_1h = iADX(sym, PERIOD_H1, 14, PRICE_CLOSE, MODE_MAIN, 1);
   double adx14_4h = iADX(sym, PERIOD_H4, 14, PRICE_CLOSE, MODE_MAIN, 1);

   // 30-bar H/L/C arrays (bar 0 = forming, bar 1 = last closed)
   string highArr = "", lowArr = "", closeArr = "";
   for (int b = 0; b <= 29; b++)
   {
      if (b > 0) { highArr += ","; lowArr += ","; closeArr += ","; }
      highArr  += DoubleToString(iHigh( sym, tf, b), digits);
      lowArr   += DoubleToString(iLow(  sym, tf, b), digits);
      closeArr += DoubleToString(iClose(sym, tf, b), digits);
   }

   // ATR
   double atr14_1h = iATR(sym, PERIOD_H1, 14, 1);
   double atr14_4h = iATR(sym, PERIOD_H4, 14, 1);

   // Stochastic(14,3,3)
   double stoch_k = iStochastic(sym, PERIOD_H1, 14, 3, 3, MODE_SMA, 0, MODE_MAIN,   1);
   double stoch_d = iStochastic(sym, PERIOD_H1, 14, 3, 3, MODE_SMA, 0, MODE_SIGNAL, 1);

   // MACD(12,26,9) histogram — bar1 and bar2
   double macd_h1 = iMACD(sym, PERIOD_H1, 12, 26, 9, PRICE_CLOSE, MODE_MAIN,   1)
                  - iMACD(sym, PERIOD_H1, 12, 26, 9, PRICE_CLOSE, MODE_SIGNAL, 1);
   double macd_h2 = iMACD(sym, PERIOD_H1, 12, 26, 9, PRICE_CLOSE, MODE_MAIN,   2)
                  - iMACD(sym, PERIOD_H1, 12, 26, 9, PRICE_CLOSE, MODE_SIGNAL, 2);

   // Asian session range (broker 03:00-09:00 = UTC 00:00-06:00)
   double asian_high = 0, asian_low = DBL_MAX;
   int td = TimeDay(TimeCurrent()), tm = TimeMonth(TimeCurrent()), ty = TimeYear(TimeCurrent());
   for (int ab = 1; ab <= 30; ab++)
   {
      datetime abt = iTime(sym, PERIOD_H1, ab);
      int abh = TimeHour(abt);
      if (TimeDay(abt) == td && TimeMonth(abt) == tm && TimeYear(abt) == ty
          && abh >= 3 && abh <= 9)
      {
         asian_high = MathMax(asian_high, iHigh(sym, PERIOD_H1, ab));
         asian_low  = MathMin(asian_low,  iLow( sym, PERIOD_H1, ab));
      }
   }
   if (asian_high == 0 || asian_low == DBL_MAX) { asian_high = 0; asian_low = 0; }

   // M15 arrays — 30 closed bars. Bumped 8->30 on 2026-06-24 for the M15 gold cohort:
   // CONNORS_RSI2_M15 computes RSI(2) in Python from these bars, and >=16 closed bars
   // are needed to match the full-history backtest RSI (8 bars flips the oversold/
   // overbought decision ~1.4% of the time; 16+ is bit-identical). 30 gives margin and
   // headroom for any future Python-computed M15 indicator. HEIKIN_STREAK_M15 (n=5 HA)
   // and PULLBACK_M15 (6-bar lookback) are unaffected. Opens added 2026-05 for Heikin Ashi.
   string m15O = "", m15C = "", m15H = "", m15L = "", m15T = "";
   for (int b = 1; b <= 30; b++)
   {
      if (b > 1) { m15O += ","; m15C += ","; m15H += ","; m15L += ","; m15T += ","; }
      m15O += DoubleToString(iOpen( sym, PERIOD_M15, b), digits);
      m15C += DoubleToString(iClose(sym, PERIOD_M15, b), digits);
      m15H += DoubleToString(iHigh( sym, PERIOD_M15, b), digits);
      m15L += DoubleToString(iLow(  sym, PERIOD_M15, b), digits);
      m15T += TimeToString(iTime(sym, PERIOD_M15, b), TIME_DATE|TIME_MINUTES);
   }
   double atr14_m15 = iATR(sym, PERIOD_M15, 14, 1);

   // M5 arrays — 150 closed bars (bar 0 = forming, skipped; bars 1-150 published).
   // Bumped 40->150 on 2026-06-28 for TILSON_CROSS_M5: the agent computes a Tilson
   // T3(21) in Python from these closes, and T3 is a 6-cascade EMA that needs ~80
   // converged bars (40 is unconverged — sweep_tilson_window.py). 150 gives margin;
   // the detector caps at the most-recent 80. (Mirrors the M15 8->30 CONNORS bump.)
   // Still ample for EMA(21)/BB(20)/RSI(14). Opens added 2026-05 for M5 HA/candles.
   string m5O = "", m5C = "", m5H = "", m5L = "", m5T = "";
   for (int b5 = 1; b5 <= 150; b5++)
   {
      if (b5 > 1) { m5O += ","; m5C += ","; m5H += ","; m5L += ","; m5T += ","; }
      m5O += DoubleToString(iOpen( sym, PERIOD_M5, b5), digits);
      m5C += DoubleToString(iClose(sym, PERIOD_M5, b5), digits);
      m5H += DoubleToString(iHigh( sym, PERIOD_M5, b5), digits);
      m5L += DoubleToString(iLow(  sym, PERIOD_M5, b5), digits);
      m5T += TimeToString(iTime(sym, PERIOD_M5, b5), TIME_DATE|TIME_MINUTES);
   }
   double atr14_m5  = iATR(sym, PERIOD_M5, 14, 1);

   // M1 arrays — 300 closed bars for the SNIPER_M1 composer (Phase 3 SHADOW,
   // EURUSD only). Knob preset: pivot 25/25, sweep 30, MSS/FVG 100 — needs
   // ≥250 closed bars per push. UNTESTED at this scale: 300 × 4 OHLC × ~12
   // chars ≈ 14 KB per symbol per push; watch journal for truncation.
   string m1O = "", m1C = "", m1H = "", m1L = "", m1T = "";
   for (int b1 = 1; b1 <= 300; b1++)
   {
      if (b1 > 1) { m1O += ","; m1C += ","; m1H += ","; m1L += ","; m1T += ","; }
      m1O += DoubleToString(iOpen( sym, PERIOD_M1, b1), digits);
      m1C += DoubleToString(iClose(sym, PERIOD_M1, b1), digits);
      m1H += DoubleToString(iHigh( sym, PERIOD_M1, b1), digits);
      m1L += DoubleToString(iLow(  sym, PERIOD_M1, b1), digits);
      m1T += TimeToString(iTime(sym, PERIOD_M1, b1), TIME_DATE|TIME_MINUTES);
   }
   double atr14_m1  = iATR(sym, PERIOD_M1, 14, 1);
   double ema8_m5   = iMA(sym, PERIOD_M5,  8, 0, MODE_EMA, PRICE_CLOSE, 0);
   double ema8_m5p  = iMA(sym, PERIOD_M5,  8, 0, MODE_EMA, PRICE_CLOSE, 1);
   double ema21_m5  = iMA(sym, PERIOD_M5, 21, 0, MODE_EMA, PRICE_CLOSE, 0);
   double ema21_m5p = iMA(sym, PERIOD_M5, 21, 0, MODE_EMA, PRICE_CLOSE, 1);
   double ema50_m5  = iMA(sym, PERIOD_M5, 50, 0, MODE_EMA, PRICE_CLOSE, 0);
   string trend_m5  = (bid > ema50_m5) ? "BULLISH" : ((bid < ema50_m5) ? "BEARISH" : "NEUTRAL");
   string cross_m5;
   if      (ema8_m5p <= ema21_m5p && ema8_m5 > ema21_m5) cross_m5 = "BULLISH_CROSS";
   else if (ema8_m5p >= ema21_m5p && ema8_m5 < ema21_m5) cross_m5 = "BEARISH_CROSS";
   else if (ema8_m5 > ema21_m5)                           cross_m5 = "ABOVE";
   else                                                    cross_m5 = "BELOW";

   // Build JSON — all values as strings (matches existing file-format parsing in agent.py)
   string j = "{";
   j += JStr("type",              "symbol_data")                                   + ",";
   j += JStr("Symbol",            sym)                                              + ",";
   j += JStr("Ask",               DoubleToString(ask, digits))                     + ",";
   j += JStr("Bid",               DoubleToString(bid, digits))                     + ",";
   j += JStr("Spread",            DoubleToString(spread, digits))                  + ",";
   j += JStr("EMA8_1H",           DoubleToString(ema8_cur, digits))                + ",";
   j += JStr("EMA8_1H_Prev",      DoubleToString(ema8_prev, digits))               + ",";
   j += JStr("EMA21_1H",          DoubleToString(ema21_cur, digits))               + ",";
   j += JStr("EMA21_1H_Prev",     DoubleToString(ema21_prev, digits))              + ",";
   j += JStr("EMA50_1H",          DoubleToString(ema50_cur, digits))               + ",";
   j += JStr("EMA50_4H",          DoubleToString(ema50_4h, digits))                + ",";
   j += JStr("Trend_4H",          trend_4h)                                        + ",";
   j += JStr("EMA8_15M",          DoubleToString(ema8_15m_cur, digits))            + ",";
   j += JStr("EMA21_15M",         DoubleToString(ema21_15m_cur, digits))           + ",";
   j += JStr("EMA50_15M",         DoubleToString(ema50_15m, digits))               + ",";
   j += JStr("Trend_15M",         trend_15m)                                       + ",";
   j += JStr("Cross_15M",         cross_15m)                                       + ",";
   j += JStr("EMA_Cross",         cross_1h)                                        + ",";
   j += JStr("Trend_1H",          trend_1h)                                        + ",";
   j += JStr("Bar0_Time",         TimeToString(t0, TIME_DATE|TIME_MINUTES))        + ",";
   j += JStr("Bar0_Open",         DoubleToString(o0, digits))                      + ",";
   j += JStr("Bar0_High",         DoubleToString(h0, digits))                      + ",";
   j += JStr("Bar0_Low",          DoubleToString(l0, digits))                      + ",";
   j += JStr("Bar0_Close",        DoubleToString(c0, digits))                      + ",";
   j += JStr("Bar1_Time",         TimeToString(t1, TIME_DATE|TIME_MINUTES))        + ",";
   j += JStr("Bar1_Open",         DoubleToString(o1, digits))                      + ",";
   j += JStr("Bar1_High",         DoubleToString(h1, digits))                      + ",";
   j += JStr("Bar1_Low",          DoubleToString(l1, digits))                      + ",";
   j += JStr("Bar1_Close",        DoubleToString(c1, digits))                      + ",";
   j += JStr("RSI14_1H",          DoubleToString(rsi14, 2))                        + ",";
   j += JStr("RSI_1H",            rsiArr)                                          + ",";
   j += JStr("Volume_1H",         volArr)                                          + ",";
   j += JStr("ADX14_1H",          DoubleToString(adx14_1h, 2))                     + ",";
   j += JStr("ADX14_4H",          DoubleToString(adx14_4h, 2))                     + ",";
   j += JStr("BarHighs_1H",       highArr)                                         + ",";
   j += JStr("BarLows_1H",        lowArr)                                          + ",";
   j += JStr("BarCloses_1H",      closeArr)                                        + ",";
   j += JStr("ATR14_1H",          DoubleToString(atr14_1h, digits))                + ",";
   j += JStr("ATR14_4H",          DoubleToString(atr14_4h, digits))                + ",";
   j += JStr("Stoch_K_1H",        DoubleToString(stoch_k, 2))                      + ",";
   j += JStr("Stoch_D_1H",        DoubleToString(stoch_d, 2))                      + ",";
   j += JStr("MACD_Hist_1H",      DoubleToString(macd_h1, digits + 2))             + ",";
   j += JStr("MACD_Hist_1H_Prev", DoubleToString(macd_h2, digits + 2))             + ",";
   j += JStr("Asian_High",        DoubleToString(asian_high, digits))              + ",";
   j += JStr("Asian_Low",         DoubleToString(asian_low, digits))               + ",";
   j += JStr("BarOpens_M15",      m15O)                                            + ",";
   j += JStr("BarCloses_M15",     m15C)                                            + ",";
   j += JStr("BarHighs_M15",      m15H)                                            + ",";
   j += JStr("BarLows_M15",       m15L)                                            + ",";
   j += JStr("BarTimes_M15",      m15T)                                            + ",";
   j += JStr("ATR14_M15",         DoubleToString(atr14_m15, digits))               + ",";
   j += JStr("BarOpens_M5",      m5O)                                              + ",";
   j += JStr("BarCloses_M5",     m5C)                                              + ",";
   j += JStr("BarHighs_M5",      m5H)                                              + ",";
   j += JStr("BarLows_M5",       m5L)                                              + ",";
   j += JStr("BarTimes_M5",      m5T)                                              + ",";
   j += JStr("ATR14_M5",         DoubleToString(atr14_m5,  digits))               + ",";
   j += JStr("BarOpens_M1",      m1O)                                              + ",";
   j += JStr("BarCloses_M1",     m1C)                                              + ",";
   j += JStr("BarHighs_M1",      m1H)                                              + ",";
   j += JStr("BarLows_M1",       m1L)                                              + ",";
   j += JStr("BarTimes_M1",      m1T)                                              + ",";
   j += JStr("ATR14_M1",         DoubleToString(atr14_m1,  digits))               + ",";
   j += JStr("EMA8_M5",          DoubleToString(ema8_m5,   digits))               + ",";
   j += JStr("EMA21_M5",         DoubleToString(ema21_m5,  digits))               + ",";
   j += JStr("EMA50_M5",         DoubleToString(ema50_m5,  digits))               + ",";
   j += JStr("Trend_M5",         trend_m5)                                        + ",";
   j += JStr("Cross_M5",         cross_m5)                                        + ",";
   j += JStr("LastUpdate",        TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)) + ",";
   j += JStr("WriteComplete",     "1");
   j += "}";
   return j;
}

// ---------------------------------------------------------------------------
// Account info builder — keys match account_info.txt
// ---------------------------------------------------------------------------

string BuildAccountJson()
{
   double marginLevel = (AccountEquity() > 0 && AccountMargin() > 0)
                       ? AccountEquity() / AccountMargin() * 100.0 : 0.0;
   string j = "{";
   j += JStr("type",          "account")                                  + ",";
   j += JStr("AccountNumber", IntegerToString(AccountNumber()))           + ",";
   j += JStr("AccountName",   AccountName())                              + ",";
   j += JStr("AccountServer", AccountServer())                            + ",";
   j += JStr("AccountCompany",AccountCompany())                           + ",";
   j += JStr("Currency",      AccountCurrency())                          + ",";
   j += JStr("Balance",       DoubleToString(AccountBalance(), 2))        + ",";
   j += JStr("Equity",        DoubleToString(AccountEquity(), 2))         + ",";
   j += JStr("Margin",        DoubleToString(AccountMargin(), 2))         + ",";
   j += JStr("FreeMargin",    DoubleToString(AccountFreeMargin(), 2))     + ",";
   j += JStr("MarginLevel",   DoubleToString(marginLevel, 2))             + ",";
   j += JStr("Leverage",      IntegerToString(AccountLeverage()));
   j += "}";
   return j;
}

// ---------------------------------------------------------------------------
// Positions builder — arrays of positions + pending orders
// Keys match positions.txt / pending_orders.txt field names.
// ---------------------------------------------------------------------------

string BuildPositionsJson()
{
   // Market positions (OP_BUY / OP_SELL)
   string positions = "";
   bool first = true;
   for (int i = 0; i < OrdersTotal(); i++)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderType() > 1) continue;   // skip pending

      int digs = (int)MarketInfo(OrderSymbol(), MODE_DIGITS);
      string cur_price = DoubleToString(
         OrderType() == OP_BUY ? MarketInfo(OrderSymbol(), MODE_BID)
                               : MarketInfo(OrderSymbol(), MODE_ASK), digs);

      // Excursion high-water marks, accumulated at 100ms by UpdateExcursionTracking().
      // Empty strings when the ticket is not tracked (it opened after the last
      // timer pass) — the agent must read empty as UNKNOWN and fall back to its
      // own poll, never as zero.
      //
      // TrackedSince is the HONESTY field: an EA reattach or an MT4 restart
      // clears the arrays and tracking restarts from the CURRENT price, which
      // silently understates the excursion. Comparing it with OpenTime is how the
      // agent tells a measurement from a floor, so it is emitted at the SAME
      // MINUTE resolution as OpenTime (bare TimeToString) and `TrackedSince <=
      // OpenTime` is then a correct comparison needing NO tolerance.
      //
      // Second resolution was tried first and is WORSE, for a reason worth keeping:
      // it forces a +60s tolerance, and a tolerance errs toward FULL — an EA that
      // restarted 59s into a position would claim a measurement it does not have.
      // Truncating both to the minute errs the other way, toward EA_PARTIAL, on
      // roughly the 0.2% of trades whose first sample crosses a minute boundary.
      // A floor wrongly labelled a floor costs nothing; a floor wrongly labelled a
      // measurement corrupts every exit study that trusts it.
      int    trk       = TrackFind(OrderTicket());
      string max_price = (trk >= 0) ? DoubleToString(g_trkMax[trk], digs) : "";
      string min_price = (trk >= 0) ? DoubleToString(g_trkMin[trk], digs) : "";
      string trk_since = (trk >= 0) ? TimeToString(g_trkSince[trk]) : "";

      if (!first) positions += ",";
      first = false;
      positions += "{";
      positions += JStr("Ticket",       IntegerToString(OrderTicket()))          + ",";
      positions += JStr("Symbol",       OrderSymbol())                            + ",";
      positions += JStr("Type",         OrderType() == OP_BUY ? "BUY" : "SELL") + ",";
      positions += JStr("Lots",         DoubleToString(OrderLots(), 2))          + ",";
      positions += JStr("OpenPrice",    DoubleToString(OrderOpenPrice(), digs))  + ",";
      positions += JStr("CurrentPrice", cur_price)                               + ",";
      positions += JStr("StopLoss",     DoubleToString(OrderStopLoss(), digs))   + ",";
      positions += JStr("TakeProfit",   DoubleToString(OrderTakeProfit(), digs)) + ",";
      positions += JStr("Profit",       DoubleToString(OrderProfit(), 2))        + ",";
      positions += JStr("Commission",   DoubleToString(OrderCommission(), 2))    + ",";
      positions += JStr("Swap",         DoubleToString(OrderSwap(), 2))          + ",";
      positions += JStr("OpenTime",     TimeToString(OrderOpenTime()))           + ",";
      positions += JStr("MaxPrice",     max_price)                               + ",";
      positions += JStr("MinPrice",     min_price)                               + ",";
      positions += JStr("TrackedSince", trk_since)                               + ",";
      positions += JStr("Comment",      OrderComment());
      positions += "}";
   }

   // Pending orders
   string pendings = "";
   first = true;
   for (int i = 0; i < OrdersTotal(); i++)
   {
      if (!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      int otype = OrderType();
      if (otype != OP_BUYLIMIT  && otype != OP_SELLLIMIT &&
          otype != OP_BUYSTOP   && otype != OP_SELLSTOP)
         continue;

      string type_str;
      if      (otype == OP_BUYLIMIT)  type_str = "BUY_LIMIT";
      else if (otype == OP_SELLLIMIT) type_str = "SELL_LIMIT";
      else if (otype == OP_BUYSTOP)   type_str = "BUY_STOP";
      else                             type_str = "SELL_STOP";

      int digs = (int)MarketInfo(OrderSymbol(), MODE_DIGITS);

      if (!first) pendings += ",";
      first = false;
      pendings += "{";
      pendings += JStr("Ticket",     IntegerToString(OrderTicket()))              + ",";
      pendings += JStr("Symbol",     OrderSymbol())                               + ",";
      pendings += JStr("Type",       type_str)                                    + ",";
      pendings += JStr("OpenPrice",  DoubleToString(OrderOpenPrice(), digs))      + ",";
      pendings += JStr("Lots",       DoubleToString(OrderLots(), 2))              + ",";
      pendings += JStr("StopLoss",   DoubleToString(OrderStopLoss(), digs))       + ",";
      pendings += JStr("TakeProfit", DoubleToString(OrderTakeProfit(), digs))     + ",";
      pendings += JStr("Comment",    OrderComment());
      pendings += "}";
   }

   string j = "{";
   j += JStr("type", "positions") + ",";
   j += "\"positions\":[" + positions + "],";
   j += "\"pending_orders\":[" + pendings + "]";
   j += "}";
   return j;
}

// ---------------------------------------------------------------------------
// REP command dispatcher
// ---------------------------------------------------------------------------

// Is the dead-man contract currently satisfied? See the HeartbeatTimeoutSec
// block above. False ONLY when the agent has proved it sends heartbeats and has
// then gone quiet for longer than the timeout -- so an un-armed consumer, or a
// timeout of 0, always reads fresh.
bool HeartbeatFresh()
{
   if (HeartbeatTimeoutSec <= 0) return true;   // disabled
   if (!g_hbArmed)               return true;   // this consumer never pings
   return (TimeCurrent() - g_lastHeartbeat) <= HeartbeatTimeoutSec;
}

string ProcessCommand(string cmd)
{
   string action = ExtractJsonValue(cmd, "cmd");

   if (action == "ping")
   {
      // The heartbeat renewal, and the ONLY thing that arms the contract. Other
      // commands deliberately do NOT renew it: an order is exactly the message
      // that may have been sitting in a socket buffer, so letting it renew the
      // clock it is about to be judged against would make the check circular.
      if (!g_hbArmed)
         Print("ZMQ_Bridge: dead-man heartbeat ARMED (timeout ",
               HeartbeatTimeoutSec, "s) — new orders will be refused after that ",
               "long without a ping");
      g_hbArmed       = true;
      g_lastHeartbeat = TimeCurrent();
      if (g_hbRefusing)
      {
         Print("ZMQ_Bridge: heartbeat restored — new orders accepted again");
         g_hbRefusing = false;
      }
      return "{\"success\":true,\"type\":\"pong\"}";
   }

   if (action == "place_order")
   {
      // NEW EXPOSURE ONLY. close/modify below are never gated: reducing or
      // protecting an existing position must work even when the channel is
      // suspect, and refusing those would be the one way this guard could cost
      // real money rather than a skipped trade.
      if (!HeartbeatFresh())
      {
         if (!g_hbRefusing)
         {
            Print("ZMQ_Bridge: DEAD-MAN TRIPPED — no heartbeat for ",
                  (int)(TimeCurrent() - g_lastHeartbeat), "s (limit ",
                  HeartbeatTimeoutSec, "s). Refusing new orders; close/modify ",
                  "still served.");
            g_hbRefusing = true;
         }
         return StringFormat(
            "{\"success\":false,\"error\":\"dead-man: no heartbeat for %ds (limit %ds)\"}",
            (int)(TimeCurrent() - g_lastHeartbeat), HeartbeatTimeoutSec);
      }
      return HandlePlaceOrder(cmd);
   }

   if (action == "close")
      return HandleClose(cmd);

   if (action == "modify")
      return HandleModify(cmd);

   if (action == "get_closed_trade")
      return HandleHistory(cmd);

   return StringFormat("{\"success\":false,\"error\":\"unknown cmd: %s\"}", action);
}

// ---------------------------------------------------------------------------
// Order placement — mirrors MCP_Ultimate.mq4's ExecuteOrderCommand()
// ---------------------------------------------------------------------------

string HandlePlaceOrder(string cmd)
{
   string symbol    = ExtractJsonValue(cmd, "symbol");
   string operation = ExtractJsonValue(cmd, "operation");
   double lots      = StringToDouble(ExtractJsonValue(cmd, "lots"));
   double price     = StringToDouble(ExtractJsonValue(cmd, "price"));
   double sl        = StringToDouble(ExtractJsonValue(cmd, "stop_loss"));
   double tp        = StringToDouble(ExtractJsonValue(cmd, "take_profit"));
   string comment   = ExtractJsonValue(cmd, "comment");
   int    expMins   = (int)StringToInteger(ExtractJsonValue(cmd, "expiry_minutes"));
   string slipStr   = ExtractJsonValue(cmd, "slippage");
   int    slippage  = StringLen(slipStr) > 0 ? (int)StringToInteger(slipStr) : 10;
   string magicStr  = ExtractJsonValue(cmd, "magic_number");
   int    magic     = StringLen(magicStr) > 0 ? (int)StringToInteger(magicStr) : MagicNumber;

   if (!IsTradeAllowed())
      return "{\"success\":false,\"error\":\"AutoTrading disabled\"}";

   RefreshRates();

   int   orderType  = -1;
   color arrowColor = clrNONE;
   if      (operation == "BUY")        { orderType = OP_BUY;       price = MarketInfo(symbol, MODE_ASK); arrowColor = clrBlue; }
   else if (operation == "SELL")       { orderType = OP_SELL;      price = MarketInfo(symbol, MODE_BID); arrowColor = clrRed;  }
   else if (operation == "BUY_LIMIT")  { orderType = OP_BUYLIMIT;  arrowColor = clrBlue; }
   else if (operation == "SELL_LIMIT") { orderType = OP_SELLLIMIT; arrowColor = clrRed;  }
   else if (operation == "BUY_STOP")   { orderType = OP_BUYSTOP;   arrowColor = clrBlue; }
   else if (operation == "SELL_STOP")  { orderType = OP_SELLSTOP;  arrowColor = clrRed;  }
   else return StringFormat("{\"success\":false,\"error\":\"invalid operation: %s\"}", operation);

   // Normalise lot size to broker constraints
   double lotStep = MarketInfo(symbol, MODE_LOTSTEP);
   double minLot  = MarketInfo(symbol, MODE_MINLOT);
   double maxLot  = MarketInfo(symbol, MODE_MAXLOT);
   if (lotStep > 0) lots = MathFloor(lots / lotStep) * lotStep;
   lots = NormalizeDouble(MathMax(minLot, MathMin(maxLot, lots)), 2);

   // Idempotency — suppress duplicate if comment+magic matches an existing order
   for (int k = 0; k < OrdersTotal(); k++)
   {
      if (!OrderSelect(k, SELECT_BY_POS, MODE_TRADES)) continue;
      if (OrderSymbol() == symbol &&
          OrderMagicNumber() == magic &&
          StringLen(comment) > 0 &&
          StringFind(OrderComment(), comment) >= 0)
         return StringFormat(
            "{\"success\":true,\"ticket\":%d,\"duplicate\":true,\"symbol\":\"%s\"}",
            OrderTicket(), symbol);
   }

   datetime expiry = (expMins > 0) ? TimeCurrent() + expMins * 60 : 0;
   int ticket = OrderSend(symbol, orderType, lots, price, slippage, sl, tp,
                          comment, magic, expiry, arrowColor);
   if (ticket > 0)
   {
      // Return the ACTUAL fill (OrderOpenPrice) as open_price so the agent can
      // measure true slippage vs the requested price (Fix F). Falls back to the
      // requested price if the ticket can't be selected.
      double fillPrice = price;
      if (OrderSelect(ticket, SELECT_BY_TICKET))
         fillPrice = OrderOpenPrice();
      Print("ZMQ_Bridge: order placed ticket=", ticket, " ", operation, " ", symbol);
      return StringFormat(
         "{\"success\":true,\"ticket\":%d,\"symbol\":\"%s\",\"operation\":\"%s\","
         "\"lots\":%.2f,\"price\":%.5f,\"open_price\":%.5f}",
         ticket, symbol, operation, lots, price, fillPrice);
   }

   int err = GetLastError();
   Print("ZMQ_Bridge: OrderSend failed error=", err, " ", operation, " ", symbol);
   return StringFormat(
      "{\"success\":false,\"error\":%d,\"description\":\"OrderSend failed\","
      "\"symbol\":\"%s\",\"operation\":\"%s\"}",
      err, symbol, operation);
}

// ---------------------------------------------------------------------------
// Closed-trade history lookup — realised P&L (price + commission + swap) by
// ticket. Lets the Python agent record broker truth instead of last floating
// P&L. Returns success:false if the ticket is not in this terminal's history.
// ---------------------------------------------------------------------------

string HandleHistory(string cmd)
{
   int ticket = (int)StringToInteger(ExtractJsonValue(cmd, "ticket"));
   if (!OrderSelect(ticket, SELECT_BY_TICKET, MODE_HISTORY))
      return StringFormat(
         "{\"success\":false,\"error\":\"ticket %d not in history\"}", ticket);

   return StringFormat(
      "{\"success\":true,\"ticket\":%d,\"profit\":%.2f,\"commission\":%.2f,"
      "\"swap\":%.2f,\"open_price\":%.5f,\"close_price\":%.5f,\"lots\":%.2f,"
      "\"comment\":\"%s\",\"close_time\":\"%s\"}",
      OrderTicket(), OrderProfit(), OrderCommission(), OrderSwap(),
      OrderOpenPrice(), OrderClosePrice(), OrderLots(),
      OrderComment(), TimeToString(OrderCloseTime(), TIME_DATE | TIME_SECONDS));
}

// ---------------------------------------------------------------------------
// Position close / pending delete — mirrors ExecuteCloseCommand()
// ---------------------------------------------------------------------------

string HandleClose(string cmd)
{
   int    ticket   = (int)StringToInteger(ExtractJsonValue(cmd, "ticket"));
   double reqLots  = StringToDouble(ExtractJsonValue(cmd, "lots"));   // 0 = full close

   if (!OrderSelect(ticket, SELECT_BY_TICKET))
      return StringFormat("{\"success\":false,\"ticket\":%d,\"error\":\"not found\"}", ticket);

   double closePrice = 0;
   double closeLots  = OrderLots();

   // Partial close: honour requested lot size if < full position
   if (reqLots > 0 && reqLots < OrderLots())
   {
      double lotStep = MarketInfo(OrderSymbol(), MODE_LOTSTEP);
      double minLot  = MarketInfo(OrderSymbol(), MODE_MINLOT);
      closeLots = NormalizeDouble(
         MathMax(minLot, MathFloor(reqLots / lotStep) * lotStep), 2);
   }

   bool result = false;
   if (OrderType() == OP_BUY)
   {
      closePrice = MarketInfo(OrderSymbol(), MODE_BID);
      result = OrderClose(ticket, closeLots, closePrice, 3, clrRed);
   }
   else if (OrderType() == OP_SELL)
   {
      closePrice = MarketInfo(OrderSymbol(), MODE_ASK);
      result = OrderClose(ticket, closeLots, closePrice, 3, clrBlue);
   }
   else
      result = OrderDelete(ticket, clrNONE);   // pending order

   if (result)
      return StringFormat("{\"success\":true,\"ticket\":%d,\"close_price\":%.5f}",
                          ticket, closePrice);

   return StringFormat("{\"success\":false,\"ticket\":%d,\"error\":%d}",
                       ticket, GetLastError());
}

// ---------------------------------------------------------------------------
// Position modify (trailing SL / TP) — mirrors ExecuteModifyCommand()
// ---------------------------------------------------------------------------

string HandleModify(string cmd)
{
   int    ticket = (int)StringToInteger(ExtractJsonValue(cmd, "ticket"));
   double sl     = StringToDouble(ExtractJsonValue(cmd, "stop_loss"));
   double tp     = StringToDouble(ExtractJsonValue(cmd, "take_profit"));

   if (!OrderSelect(ticket, SELECT_BY_TICKET))
      return StringFormat("{\"success\":false,\"ticket\":%d,\"error\":\"not found\"}", ticket);

   bool ok = OrderModify(ticket, OrderOpenPrice(), sl, tp, 0, clrNONE);
   if (ok)
      return StringFormat("{\"success\":true,\"ticket\":%d,\"sl\":%.5f,\"tp\":%.5f}",
                          ticket, sl, tp);

   return StringFormat("{\"success\":false,\"ticket\":%d,\"error\":%d}",
                       ticket, GetLastError());
}

// ---------------------------------------------------------------------------
// JSON value extractor — handles quoted strings and bare numbers/booleans
// ---------------------------------------------------------------------------

string ExtractJsonValue(string json, string key)
{
   string searchKey = "\"" + key + "\":";
   int startPos = StringFind(json, searchKey);
   if (startPos < 0) return "";

   startPos += StringLen(searchKey);

   // Skip optional whitespace
   while (startPos < StringLen(json) && StringGetChar(json, startPos) == ' ')
      startPos++;

   int endPos = startPos;

   if (startPos < StringLen(json) && StringGetChar(json, startPos) == '"')
   {
      // Quoted string value
      startPos++;
      endPos = startPos;
      while (endPos < StringLen(json) && StringGetChar(json, endPos) != '"')
         endPos++;
   }
   else
   {
      // Bare value (number / boolean) — stop at comma or closing brace
      while (endPos < StringLen(json))
      {
         ushort c = StringGetChar(json, endPos);
         if (c == ',' || c == '}') break;
         endPos++;
      }
   }

   return StringSubstr(json, startPos, endPos - startPos);
}
