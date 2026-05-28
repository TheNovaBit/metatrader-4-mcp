//+------------------------------------------------------------------+
//| BacktestExportM1.mq4                                             |
//| Exports M1 OHLC + minimal indicators to CSV for the Volman       |
//| EUR/USD scalping module (volman_eurusd.py).                      |
//|                                                                   |
//| USAGE:                                                            |
//|   1. In MT4 → Tools → History Center, ensure ample M1 EUR/USD    |
//|      history is loaded (Tools → Options → Charts → "Max bars in  |
//|      history" = 999999999, then F2 → EURUSD → 1 Minute →         |
//|      Download).                                                   |
//|   2. Compile this script in MetaEditor (F7).                     |
//|   3. In MT4: open an EURUSD chart, drag this script onto it.     |
//|   4. Output written to:                                          |
//|      ...Terminal\847DD919767F27CB10D9143EE38EC5D9\MQL4\Files\    |
//|      File name: volman_bt_<SYMBOL>.csv                            |
//|                                                                   |
//| CSV columns:                                                      |
//|   time, open, high, low, close, ema20_m1, atr14_m1                |
//|                                                                   |
//| Volman's method only uses a 20EMA. ATR is included for risk       |
//| sizing context (lots calculation Python-side) but is NOT used in  |
//| his entry or exit logic. No 1H context — Volman trades the chart  |
//| in front of him only.                                             |
//|                                                                   |
//| Bar indexing: rows written oldest-first so the backtest replays   |
//| forward chronologically.                                          |
//+------------------------------------------------------------------+
#property script_show_inputs
#property strict

extern string  Symbol_   = "EURUSD.r";    // Symbol to export
extern int     BarsBack  = 100000;         // Number of M1 bars (~70 trading days)

int OnStart()
{
   string sym    = Symbol_;
   int    digits = (int)MarketInfo(sym, MODE_DIGITS);

   string fname = "volman_bt_" + sym + ".csv";
   int fh = FileOpen(fname, FILE_WRITE | FILE_CSV | FILE_ANSI, ",");
   if (fh < 0) {
      Print("BacktestExportM1: cannot open file ", fname, " error=", GetLastError());
      return -1;
   }

   FileWrite(fh, "time,open,high,low,close,ema20_m1,atr14_m1");

   int total = MathMin(BarsBack, iBars(sym, PERIOD_M1) - 1);
   Print("BacktestExportM1: exporting ", total, " M1 bars for ", sym, " ...");

   for (int i = total; i >= 1; i--)
   {
      datetime t  = iTime( sym, PERIOD_M1, i);
      double   op = iOpen( sym, PERIOD_M1, i);
      double   hi = iHigh( sym, PERIOD_M1, i);
      double   lo = iLow(  sym, PERIOD_M1, i);
      double   cl = iClose(sym, PERIOD_M1, i);

      double ema20 = iMA( sym, PERIOD_M1, 20, 0, MODE_EMA, PRICE_CLOSE, i);
      double atr14 = iATR(sym, PERIOD_M1, 14, i);

      FileWrite(fh,
         TimeToString(t, TIME_DATE|TIME_MINUTES),
         DoubleToString(op,    digits),
         DoubleToString(hi,    digits),
         DoubleToString(lo,    digits),
         DoubleToString(cl,    digits),
         DoubleToString(ema20, digits),
         DoubleToString(atr14, digits)
      );
   }

   FileClose(fh);
   string msg = "BacktestExportM1 complete\n"
                "Symbol : " + sym + "\n"
                "Bars   : " + IntegerToString(total) + "\n"
                "File   : " + fname;
   Print(msg);
   Alert(msg);
   return 0;
}
