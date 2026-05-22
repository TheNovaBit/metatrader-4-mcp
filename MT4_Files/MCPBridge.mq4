//+------------------------------------------------------------------+
//|                                                    MCPBridge.mq4 |
//|                        Copyright 2024, MCP MT4 Integration       |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MCP MT4 Integration"
#property link      ""
#property version   "1.01"
#property strict

//--- Input parameters
input int UpdateInterval = 1000; // Update interval in milliseconds

//--- Global variables
datetime lastUpdate = 0;
string filesPath = "";

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   filesPath = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL4\\Files\\";

   Print("MCP Bridge initialized. Files path: ", filesPath);

   // Create initial files
   WriteAccountInfo();
   WritePositionsInfo();
   WriteExpertsList();

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("MCP Bridge deinitialized");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if (TimeCurrent() - lastUpdate >= UpdateInterval / 1000)
   {
      // Update market data for major pairs
      WriteMarketData("EURUSD");
      WriteMarketData("GBPUSD");
      WriteMarketData("USDJPY");
      WriteMarketData("USDCHF");
      WriteMarketData("AUDUSD");
      WriteMarketData("USDCAD");

      // Update account and positions info
      WriteAccountInfo();
      WritePositionsInfo();

      // Process pending commands
      ProcessOrderCommands();
      ProcessCloseCommands();
      ProcessModifyCommands();
      ProcessBacktestCommands();

      lastUpdate = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Write account information to file                                |
//+------------------------------------------------------------------+
void WriteAccountInfo()
{
   int fileHandle = FileOpen("account_info.txt", FILE_WRITE | FILE_TXT);
   if (fileHandle != INVALID_HANDLE)
   {
      FileWrite(fileHandle, "AccountNumber=" + IntegerToString(AccountNumber()));
      FileWrite(fileHandle, "AccountName=" + AccountName());
      FileWrite(fileHandle, "AccountServer=" + AccountServer());
      FileWrite(fileHandle, "AccountCompany=" + AccountCompany());
      FileWrite(fileHandle, "Currency=" + AccountCurrency());
      FileWrite(fileHandle, "Balance=" + DoubleToString(AccountBalance(), 2));
      FileWrite(fileHandle, "Equity=" + DoubleToString(AccountEquity(), 2));
      FileWrite(fileHandle, "Margin=" + DoubleToString(AccountMargin(), 2));
      FileWrite(fileHandle, "FreeMargin=" + DoubleToString(AccountFreeMargin(), 2));
      double marginLevel = AccountEquity() > 0 && AccountMargin() > 0 ? AccountEquity() / AccountMargin() * 100 : 0;
      FileWrite(fileHandle, "MarginLevel=" + DoubleToString(marginLevel, 2));
      FileWrite(fileHandle, "Leverage=" + IntegerToString(AccountLeverage()));

      FileClose(fileHandle);
   }
}

//+------------------------------------------------------------------+
//| Write market data for a symbol to file                          |
//+------------------------------------------------------------------+
void WriteMarketData(string symbol)
{
   string filename = "market_data_" + symbol + ".txt";
   int fileHandle = FileOpen(filename, FILE_WRITE | FILE_TXT);

   if (fileHandle != INVALID_HANDLE)
   {
      double bid = MarketInfo(symbol, MODE_BID);
      double ask = MarketInfo(symbol, MODE_ASK);
      double spread = MarketInfo(symbol, MODE_SPREAD);
      double high = MarketInfo(symbol, MODE_HIGH);
      double low = MarketInfo(symbol, MODE_LOW);

      FileWrite(fileHandle, "Symbol=" + symbol);
      FileWrite(fileHandle, "Bid=" + DoubleToString(bid, 5));
      FileWrite(fileHandle, "Ask=" + DoubleToString(ask, 5));
      FileWrite(fileHandle, "Spread=" + DoubleToString(spread, 1));
      FileWrite(fileHandle, "High=" + DoubleToString(high, 5));
      FileWrite(fileHandle, "Low=" + DoubleToString(low, 5));
      FileWrite(fileHandle, "Time=" + TimeToString(TimeCurrent()));

      FileClose(fileHandle);
   }
}

//+------------------------------------------------------------------+
//| Write positions information to file                             |
//+------------------------------------------------------------------+
void WritePositionsInfo()
{
   int fileHandle = FileOpen("positions.txt", FILE_WRITE | FILE_TXT);
   if (fileHandle != INVALID_HANDLE)
   {
      FileWrite(fileHandle, "TotalPositions=" + IntegerToString(OrdersTotal()));
      FileWrite(fileHandle, "");

      for (int i = 0; i < OrdersTotal(); i++)
      {
         if (OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         {
            if (OrderType() <= 1) // Only market orders (BUY/SELL)
            {
               FileWrite(fileHandle, "Ticket=" + IntegerToString(OrderTicket()));
               FileWrite(fileHandle, "Symbol=" + OrderSymbol());
               FileWrite(fileHandle, "Type=" + (OrderType() == OP_BUY ? "BUY" : "SELL"));
               FileWrite(fileHandle, "Lots=" + DoubleToString(OrderLots(), 2));
               FileWrite(fileHandle, "OpenPrice=" + DoubleToString(OrderOpenPrice(), 5));
               FileWrite(fileHandle, "CurrentPrice=" + DoubleToString(OrderType() == OP_BUY ? MarketInfo(OrderSymbol(), MODE_BID) : MarketInfo(OrderSymbol(), MODE_ASK), 5));
               FileWrite(fileHandle, "StopLoss=" + DoubleToString(OrderStopLoss(), 5));
               FileWrite(fileHandle, "TakeProfit=" + DoubleToString(OrderTakeProfit(), 5));
               FileWrite(fileHandle, "Profit=" + DoubleToString(OrderProfit(), 2));
               FileWrite(fileHandle, "OpenTime=" + TimeToString(OrderOpenTime()));
               FileWrite(fileHandle, "Comment=" + OrderComment());
               FileWrite(fileHandle, "---");
            }
         }
      }

      FileClose(fileHandle);
   }
}

//+------------------------------------------------------------------+
//| Process order commands from bridge server                        |
//+------------------------------------------------------------------+
void ProcessOrderCommands()
{
   if (!FileIsExist("order_commands.txt")) return;

   int fh = FileOpen("order_commands.txt", FILE_READ | FILE_TXT | FILE_ANSI);
   if (fh == INVALID_HANDLE) return;

   string jsonCommand = "";
   while (!FileIsEnding(fh))
      jsonCommand += FileReadString(fh);
   FileClose(fh);
   FileDelete("order_commands.txt");

   ExecuteOrderCommand(jsonCommand);
}

//+------------------------------------------------------------------+
//| Process close commands from bridge server                        |
//+------------------------------------------------------------------+
void ProcessCloseCommands()
{
   if (!FileIsExist("close_commands.txt")) return;

   int fh = FileOpen("close_commands.txt", FILE_READ | FILE_TXT | FILE_ANSI);
   if (fh == INVALID_HANDLE) return;

   string jsonCommand = "";
   while (!FileIsEnding(fh))
      jsonCommand += FileReadString(fh);
   FileClose(fh);
   FileDelete("close_commands.txt");

   ExecuteCloseCommand(jsonCommand);
}

//+------------------------------------------------------------------+
//| Process modify commands from bridge server (trailing SL/TP)      |
//+------------------------------------------------------------------+
void ProcessModifyCommands()
{
   if (!FileIsExist("modify_commands.txt")) return;

   int fh = FileOpen("modify_commands.txt", FILE_READ | FILE_TXT | FILE_ANSI);
   if (fh == INVALID_HANDLE) return;

   string jsonCommand = "";
   while (!FileIsEnding(fh))
      jsonCommand += FileReadString(fh);
   FileClose(fh);
   FileDelete("modify_commands.txt");

   ExecuteModifyCommand(jsonCommand);
}

//+------------------------------------------------------------------+
//| Execute order command                                            |
//+------------------------------------------------------------------+
void ExecuteOrderCommand(string jsonCommand)
{
   string symbol     = ExtractJsonValue(jsonCommand, "symbol");
   string operation  = ExtractJsonValue(jsonCommand, "operation");
   double lots       = StringToDouble(ExtractJsonValue(jsonCommand, "lots"));
   double price      = StringToDouble(ExtractJsonValue(jsonCommand, "price"));
   double stopLoss   = StringToDouble(ExtractJsonValue(jsonCommand, "stop_loss"));
   double takeProfit = StringToDouble(ExtractJsonValue(jsonCommand, "take_profit"));
   string comment    = ExtractJsonValue(jsonCommand, "comment");
   string requestId  = ExtractJsonValue(jsonCommand, "request_id");

   int   orderType  = -1;
   color arrowColor = clrNONE;

   if (operation == "BUY")        { orderType = OP_BUY;       price = MarketInfo(symbol, MODE_ASK); arrowColor = clrBlue; }
   else if (operation == "SELL")  { orderType = OP_SELL;      price = MarketInfo(symbol, MODE_BID); arrowColor = clrRed;  }
   else if (operation == "BUY_LIMIT")  { orderType = OP_BUYLIMIT;  arrowColor = clrBlue; }
   else if (operation == "SELL_LIMIT") { orderType = OP_SELLLIMIT; arrowColor = clrRed;  }
   else if (operation == "BUY_STOP")   { orderType = OP_BUYSTOP;   arrowColor = clrBlue; }
   else if (operation == "SELL_STOP")  { orderType = OP_SELLSTOP;  arrowColor = clrRed;  }

   string json = "";

   if (orderType >= 0)
   {
      int ticket = OrderSend(symbol, orderType, lots, price, 3, stopLoss, takeProfit, comment, 0, 0, arrowColor);
      if (ticket > 0)
      {
         Print("Order placed successfully. Ticket: ", ticket);
         json = StringFormat("{\"success\":true,\"ticket\":%d,\"symbol\":\"%s\",\"operation\":\"%s\",\"request_id\":\"%s\"}",
                             ticket, symbol, operation, requestId);
      }
      else
      {
         int error = GetLastError();
         Print("Order failed. Error: ", error);
         json = StringFormat("{\"success\":false,\"error\":%d,\"description\":\"OrderSend failed\",\"request_id\":\"%s\"}",
                             error, requestId);
      }
   }
   else
   {
      json = StringFormat("{\"success\":false,\"error\":\"Invalid operation\",\"operation\":\"%s\",\"request_id\":\"%s\"}",
                          operation, requestId);
   }

   int fh = FileOpen("order_result.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (fh != INVALID_HANDLE) { FileWrite(fh, json); FileClose(fh); }
}

//+------------------------------------------------------------------+
//| Execute close command                                            |
//+------------------------------------------------------------------+
void ExecuteCloseCommand(string jsonCommand)
{
   int    ticket    = StringToInteger(ExtractJsonValue(jsonCommand, "ticket"));
   string requestId = ExtractJsonValue(jsonCommand, "request_id");
   string json      = "";

   if (OrderSelect(ticket, SELECT_BY_TICKET))
   {
      bool   result     = false;
      double closePrice = 0;

      if (OrderType() == OP_BUY)
      {
         closePrice = MarketInfo(OrderSymbol(), MODE_BID);
         result = OrderClose(ticket, OrderLots(), closePrice, 3, clrRed);
      }
      else if (OrderType() == OP_SELL)
      {
         closePrice = MarketInfo(OrderSymbol(), MODE_ASK);
         result = OrderClose(ticket, OrderLots(), closePrice, 3, clrBlue);
      }

      if (result)
      {
         Print("Position closed successfully. Ticket: ", ticket);
         json = StringFormat("{\"success\":true,\"ticket\":%d,\"close_price\":%.5f,\"request_id\":\"%s\"}",
                             ticket, closePrice, requestId);
      }
      else
      {
         int error = GetLastError();
         Print("Failed to close position. Error: ", error);
         json = StringFormat("{\"success\":false,\"ticket\":%d,\"error\":%d,\"description\":\"OrderClose failed\",\"request_id\":\"%s\"}",
                             ticket, error, requestId);
      }
   }
   else
   {
      json = StringFormat("{\"success\":false,\"ticket\":%d,\"error\":\"Order not found\",\"request_id\":\"%s\"}",
                          ticket, requestId);
   }

   int fh = FileOpen("close_result.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (fh != INVALID_HANDLE) { FileWrite(fh, json); FileClose(fh); }
}

//+------------------------------------------------------------------+
//| Execute modify command (trailing SL / breakeven SL)              |
//+------------------------------------------------------------------+
void ExecuteModifyCommand(string jsonCommand)
{
   int    ticket     = StringToInteger(ExtractJsonValue(jsonCommand, "ticket"));
   double stopLoss   = StringToDouble(ExtractJsonValue(jsonCommand, "stop_loss"));
   double takeProfit = StringToDouble(ExtractJsonValue(jsonCommand, "take_profit"));
   string requestId  = ExtractJsonValue(jsonCommand, "request_id");
   string json       = "";

   if (OrderSelect(ticket, SELECT_BY_TICKET))
   {
      bool ok = OrderModify(ticket, OrderOpenPrice(), stopLoss, takeProfit, 0, clrNONE);
      if (ok)
      {
         Print("Order modified. Ticket: ", ticket, " SL: ", stopLoss, " TP: ", takeProfit);
         json = StringFormat("{\"success\":true,\"ticket\":%d,\"sl\":%.5f,\"tp\":%.5f,\"request_id\":\"%s\"}",
                             ticket, stopLoss, takeProfit, requestId);
      }
      else
      {
         int error = GetLastError();
         Print("OrderModify failed. Ticket: ", ticket, " Error: ", error);
         json = StringFormat("{\"success\":false,\"ticket\":%d,\"error\":%d,\"description\":\"OrderModify failed\",\"request_id\":\"%s\"}",
                             ticket, error, requestId);
      }
   }
   else
   {
      json = StringFormat("{\"success\":false,\"ticket\":%d,\"error\":\"Order not found\",\"request_id\":\"%s\"}",
                          ticket, requestId);
   }

   int fh = FileOpen("modify_result.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (fh != INVALID_HANDLE) { FileWrite(fh, json); FileClose(fh); }
}

//+------------------------------------------------------------------+
//| Extract value from JSON string (simplified)                     |
//+------------------------------------------------------------------+
string ExtractJsonValue(string json, string key)
{
   string searchKey = "\"" + key + "\":";
   int startPos = StringFind(json, searchKey);
   if (startPos == -1) return "";

   startPos += StringLen(searchKey);

   // Skip whitespace and opening quote
   while (startPos < StringLen(json) && (StringGetChar(json, startPos) == ' ' || StringGetChar(json, startPos) == '"'))
      startPos++;

   int  endPos  = startPos;
   bool inQuotes = false;

   while (endPos < StringLen(json))
   {
      char c = StringGetChar(json, endPos);
      if (c == '"' && !inQuotes)       { inQuotes = true; }
      else if (c == '"' && inQuotes)   { break; }
      else if (!inQuotes && (c == ',' || c == '}')) { break; }
      endPos++;
   }

   return StringSubstr(json, startPos, endPos - startPos);
}

//+------------------------------------------------------------------+
//| Write list of available Expert Advisors                         |
//+------------------------------------------------------------------+
void WriteExpertsList()
{
   int fileHandle = FileOpen("experts_list.txt", FILE_WRITE | FILE_TXT);
   if (fileHandle != INVALID_HANDLE)
   {
      FileWrite(fileHandle, "MCPBridge|MCP Bridge Expert Advisor|Current");
      FileWrite(fileHandle, "MACD Sample|Sample MACD Expert Advisor|Built-in");
      FileWrite(fileHandle, "Moving Average|Sample Moving Average EA|Built-in");
      FileWrite(fileHandle, "RSI|Relative Strength Index EA|Built-in");
      FileClose(fileHandle);
   }
}

//+------------------------------------------------------------------+
//| Process backtest commands from bridge server                     |
//+------------------------------------------------------------------+
void ProcessBacktestCommands()
{
   if (!FileIsExist("backtest_commands.txt")) return;

   int fh = FileOpen("backtest_commands.txt", FILE_READ | FILE_TXT | FILE_ANSI);
   if (fh == INVALID_HANDLE) return;

   string jsonCommand = "";
   while (!FileIsEnding(fh))
      jsonCommand += FileReadString(fh);
   FileClose(fh);
   FileDelete("backtest_commands.txt");

   ExecuteBacktestCommand(jsonCommand);
}

//+------------------------------------------------------------------+
//| Execute backtest command                                         |
//+------------------------------------------------------------------+
void ExecuteBacktestCommand(string jsonCommand)
{
   string expert         = ExtractJsonValue(jsonCommand, "expert");
   string symbol         = ExtractJsonValue(jsonCommand, "symbol");
   string timeframe      = ExtractJsonValue(jsonCommand, "timeframe");
   string fromDate       = ExtractJsonValue(jsonCommand, "from_date");
   string toDate         = ExtractJsonValue(jsonCommand, "to_date");
   double initialDeposit = StringToDouble(ExtractJsonValue(jsonCommand, "initial_deposit"));
   string model          = ExtractJsonValue(jsonCommand, "model");

   int resultHandle = FileOpen("backtest_results.txt", FILE_WRITE | FILE_TXT);
   if (resultHandle != INVALID_HANDLE)
   {
      FileWrite(resultHandle, "{");
      FileWrite(resultHandle, "\"status\": \"simulated\",");
      FileWrite(resultHandle, "\"message\": \"Backtest simulation - MT4 requires manual backtesting\",");
      FileWrite(resultHandle, "\"expert\": \"" + expert + "\",");
      FileWrite(resultHandle, "\"symbol\": \"" + symbol + "\"");
      FileWrite(resultHandle, "}");
      FileClose(resultHandle);
   }

   Print("Backtest command processed for: ", expert, " on ", symbol);
}
