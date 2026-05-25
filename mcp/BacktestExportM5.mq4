//+------------------------------------------------------------------+
//| BacktestExportM5.mq4                                             |
//| Exports M5 OHLC + indicator data to CSV for scalper backtesting. |
//|                                                                   |
//| USAGE:                                                            |
//|   1. Open MetaEditor, compile this file (F7)                     |
//|   2. In MT4: Tools → Scripts → BacktestExportM5                  |
//|      (attach to any chart — symbol is set via the Symbol input)   |
//|   3. Output written directly to terminal data folder:            |
//|      ...Terminal\847DD919767F27CB10D9143EE38EC5D9\MQL4\Files\    |
//|      backtest_scalper.py reads from there — no copy needed.      |
//|                                                                   |
//| CSV columns:                                                      |
//|   time, open, high, low, close,                                   |
//|   atr14_m5, ema8_m5, ema21_m5, ema50_m5,                        |
//|   atr14_1h, adx14_1h, trend_1h,                                  |
//|   asian_high, asian_low                                           |
//|                                                                   |
//| Bar indexing: most recent bar = row 0 (highest index in iXxx).   |
//| Rows are written oldest-first so the backtest can replay forward. |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

extern string  Symbol_      = "EURUSD.r";   // Symbol to export
extern int     BarsBack     = 5000;          // Number of M5 bars to export (~17 days)

int OnStart()
{
   string sym    = Symbol_;
   int    digits = (int)MarketInfo(sym, MODE_DIGITS);

   // File name mirrors what backtest_scalper.py expects
   string fname = "scalper_bt_" + sym + ".csv";
   int fh = FileOpen(fname, FILE_WRITE | FILE_CSV | FILE_ANSI, ",");
   if (fh < 0) {
      Print("BacktestExportM5: cannot open file ", fname, " error=", GetLastError());
      return -1;
   }

   // Header
   FileWrite(fh, "time,open,high,low,close,"
                 "atr14_m5,ema8_m5,ema21_m5,ema50_m5,"
                 "atr14_1h,adx14_1h,trend_1h,"
                 "asian_high,asian_low");

   int total = MathMin(BarsBack, iBars(sym, PERIOD_M5) - 1);
   Print("BacktestExportM5: exporting ", total, " M5 bars for ", sym, " ...");

   // Write oldest → newest so backtest replays forward chronologically
   for (int i = total; i >= 1; i--)
   {
      datetime t    = iTime( sym, PERIOD_M5, i);
      double   op   = iOpen( sym, PERIOD_M5, i);
      double   hi   = iHigh( sym, PERIOD_M5, i);
      double   lo   = iLow(  sym, PERIOD_M5, i);
      double   cl   = iClose(sym, PERIOD_M5, i);

      double atr_m5  = iATR(sym, PERIOD_M5, 14, i);
      double e8_m5   = iMA( sym, PERIOD_M5,  8, 0, MODE_EMA, PRICE_CLOSE, i);
      double e21_m5  = iMA( sym, PERIOD_M5, 21, 0, MODE_EMA, PRICE_CLOSE, i);
      double e50_m5  = iMA( sym, PERIOD_M5, 50, 0, MODE_EMA, PRICE_CLOSE, i);

      // Map M5 bar index to the H1 bar that contains it
      int h1_idx = iBarShift(sym, PERIOD_H1, t);
      double atr_1h  = iATR(sym, PERIOD_H1, 14, h1_idx);
      double adx_1h  = iADX(sym, PERIOD_H1, 14, PRICE_CLOSE, MODE_MAIN, h1_idx);
      double e50_1h  = iMA( sym, PERIOD_H1, 50, 0, MODE_EMA, PRICE_CLOSE, h1_idx);
      double bid_h1  = iClose(sym, PERIOD_H1, h1_idx);
      string trend_1h = (bid_h1 > e50_1h) ? "BULLISH" : ((bid_h1 < e50_1h) ? "BEARISH" : "NEUTRAL");

      // Asian range: H1 bars with hour 0-6 UTC on the same date as this M5 bar.
      // (Broker time may be UTC+2/UTC+3; adjust if needed by reading the offset.)
      double ah = 0, al = DBL_MAX;
      int td = TimeDay(t), tm_ = TimeMonth(t), ty = TimeYear(t);
      for (int ab = 1; ab <= 30; ab++)
      {
         datetime abt = iTime(sym, PERIOD_H1, h1_idx + ab);
         int      abh = TimeHour(abt);
         if (TimeDay(abt) == td && TimeMonth(abt) == tm_ && TimeYear(abt) == ty
             && abh >= 0 && abh <= 6)
         {
            ah = MathMax(ah, iHigh(sym, PERIOD_H1, h1_idx + ab));
            al = MathMin(al, iLow( sym, PERIOD_H1, h1_idx + ab));
         }
      }
      if (ah == 0 || al == DBL_MAX) { ah = 0; al = 0; }

      FileWrite(fh,
         TimeToString(t, TIME_DATE|TIME_MINUTES),
         DoubleToString(op,  digits),
         DoubleToString(hi,  digits),
         DoubleToString(lo,  digits),
         DoubleToString(cl,  digits),
         DoubleToString(atr_m5, digits),
         DoubleToString(e8_m5,  digits),
         DoubleToString(e21_m5, digits),
         DoubleToString(e50_m5, digits),
         DoubleToString(atr_1h, digits),
         DoubleToString(adx_1h, 2),
         trend_1h,
         DoubleToString(ah, digits),
         DoubleToString(al, digits)
      );
   }

   FileClose(fh);
   Print("BacktestExportM5: done. File: ", fname, "  Rows: ", total);
   return 0;
}
