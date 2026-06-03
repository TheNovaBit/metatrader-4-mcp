//+------------------------------------------------------------------+
//|                                                    MCP_Ultimate.mq4 |
//|                    Ultimate MCP Bridge for MT4 Integration          |
//|                   All-in-One Solution for Claude Code MCP           |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MCP MT4 Integration"
#property link      "https://github.com/anthropics/claude-code"
#property version   "3.00"
#property strict
#property description "Ultimate MCP Bridge: Complete MT4 integration for Claude Code"
#property description "Features: Trading, Reporting, Backtesting, File I/O, Visual Indicators"

//--- Input parameters - Main Configuration
input group "=== MCP BRIDGE SETTINGS ==="
input int UpdateInterval = 1000;           // Update interval in milliseconds
input bool EnableFileReporting = true;     // Enable enhanced file-based reporting
input bool EnableBacktestTracking = true;  // Enable backtest status tracking
input bool EnableVisualMode = true;        // Show MCP status on chart
input bool EnableDebugMode = false;        // Enable debug logging

input group "=== REPORTING CONFIGURATION ==="
input string ReportsFolder = "mt4_reports"; // Reports folder name
input bool SaveDetailedLogs = true;         // Save detailed operation logs
input bool EnableJSONFormat = true;         // Use JSON format for reports
input int MaxLogFiles = 10;                 // Maximum log files to keep

input group "=== MARKET DATA SETTINGS ==="
input bool TrackMajorPairs = true;          // Track major currency pairs
input bool TrackMinorPairs = false;         // Track minor currency pairs
input bool TrackExoticPairs = false;        // Track exotic currency pairs
input bool TrackCommodities = false;        // Track commodities (XAUUSD, XAGUSD, WTIUSD)

input group "=== ORDER SETTINGS ==="
input int MagicNumber = 20260101;           // Magic number stamped on every bridge order (must match BRIDGE_MAGIC_NUMBER in server.js)

//--- Global variables
datetime lastUpdate = 0;
string filesPath = "";
string mcpVersion = "3.00";

// File-based reporting variables
string StatusFilePath;
string ResultsFilePath;
string LogFilePath;
datetime BacktestStartTime;
datetime SessionStartTime;
int TotalTrades = 0;
double InitialBalance = 0;
double MaxDrawdown = 0;
double CurrentDrawdown = 0;
double MaxEquity = 0;
bool IsBacktesting = false;
int OperationCounter = 0;

// Symbol lists for market data
string MajorPairs[] = {"EURUSD", "GBPUSD", "USDJPY", "USDCHF", "AUDUSD", "USDCAD", "NZDUSD"};
string MinorPairs[] = {"EURJPY", "GBPJPY", "EURGBP", "EURAUD", "EURCHF", "EURAUD", "AUDCAD"};
string ExoticPairs[] = {"USDZAR", "USDTRY", "USDHKD", "USDSGD", "USDMXN", "USDSEK", "USDNOK"};
string Commodities[] = {"XAUUSD", "XAGUSD", "WTIUSD", "BRENTUSD"};

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize paths
   filesPath = TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL4\\Files\\";
   StatusFilePath = ReportsFolder + "\\mcp_status.json";
   ResultsFilePath = ReportsFolder + "\\mcp_results.json";
   LogFilePath = ReportsFolder + "\\mcp_operations.log";
   
   SessionStartTime = TimeCurrent();
   
   Print("========================================");
   Print("MCP Ultimate Bridge v", mcpVersion, " Starting");
   Print("========================================");
   Print("Files path: ", filesPath);
   Print("File Reporting: ", (EnableFileReporting ? "Enabled" : "Disabled"));
   Print("Backtest Tracking: ", (EnableBacktestTracking ? "Enabled" : "Disabled"));
   Print("Visual Mode: ", (EnableVisualMode ? "Enabled" : "Disabled"));
   Print("Debug Mode: ", (EnableDebugMode ? "Enabled" : "Disabled"));
   
   // Initialize MCP Bridge functionality
   WriteAccountInfo();
   WritePositionsInfo();
   WriteExpertsList();
   CleanupOldLogFiles();
   
   // Initialize file-based reporting if enabled
   if(EnableFileReporting)
   {
      BacktestStartTime = TimeCurrent();
      InitialBalance = AccountBalance();
      MaxEquity = AccountEquity();
      IsBacktesting = IsTesting();
      
      // Create reports directory
      CreateDirectory(ReportsFolder);
      
      // Write initial status
      if(EnableBacktestTracking)
      {
         WriteMCPStatus("starting", 0, "MCP Ultimate Bridge initialized successfully");
      }
      
      LogOperation("INIT", "MCP Ultimate Bridge started", "");
   }
   
   // Setup visual indicators
   if(EnableVisualMode)
   {
      SetupVisualIndicators();
   }
   
   // Use a timer instead of OnTick so commands are processed even on low-tick symbols
   // or during quiet periods where no price changes arrive.
   EventSetMillisecondTimer(500);

   Print("MCP Ultimate Bridge initialization completed successfully");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   string reasonText = GetUninitReasonText(reason);
   Print("MCP Ultimate Bridge shutting down. Reason: ", reasonText);
   
   // Write final status and results if file reporting is enabled
   if(EnableFileReporting && EnableBacktestTracking)
   {
      WriteMCPStatus("completed", 100, "MCP Bridge session completed - " + reasonText);
      WriteMCPResults();
      LogOperation("DEINIT", "MCP Ultimate Bridge stopped", reasonText);
   }
   
   // Cleanup visual objects
   if(EnableVisualMode)
   {
      CleanupVisualIndicators();
   }
   
   Print("MCP Ultimate Bridge shutdown completed");
}

//+------------------------------------------------------------------+
//| Timer function — fires every 500 ms regardless of tick activity |
//+------------------------------------------------------------------+
void OnTimer()
{
   if (TimeCurrent() - lastUpdate >= UpdateInterval / 1000)
   {
      OperationCounter++;
      
      // MCP Bridge core functionality
      UpdateMarketData();
      WriteAccountInfo();
      WritePositionsInfo();
      
      // Process MCP commands
      ProcessOrderCommands();
      ProcessCloseCommands();
      ProcessModifyCommands();
      ProcessBacktestCommands();
      
      // File-based reporting updates
      if(EnableFileReporting)
      {
         UpdateMCPTracking();
      }
      
      // Update visual indicators
      if(EnableVisualMode)
      {
         UpdateVisualIndicators();
      }
      
      lastUpdate = TimeCurrent();
   }
}

//+------------------------------------------------------------------+
//| Update MCP tracking information                                 |
//+------------------------------------------------------------------+
void UpdateMCPTracking()
{
   if(!EnableBacktestTracking) return;
   
   // Update status periodically (every 10 updates for performance)
   static int updateCount = 0;
   updateCount++;
   
   if(updateCount % 10 == 0)
   {
      double progress = CalculateSessionProgress();
      string status = IsBacktesting ? "backtesting" : "live_trading";
      WriteMCPStatus(status, progress, "Processing market data - " + IntegerToString(OperationCounter) + " operations");
   }
   
   // Track drawdown and equity
   double currentBalance = AccountBalance();
   double currentEquity = AccountEquity();
   
   CurrentDrawdown = InitialBalance - currentBalance;
   if(CurrentDrawdown > MaxDrawdown)
      MaxDrawdown = CurrentDrawdown;
      
   if(currentEquity > MaxEquity)
      MaxEquity = currentEquity;
}

//+------------------------------------------------------------------+
//| Calculate session progress percentage                           |
//+------------------------------------------------------------------+
double CalculateSessionProgress()
{
   if(!IsTesting()) 
   {
      // For live trading, calculate session progress
      datetime currentTime = TimeCurrent();
      datetime sessionStart = SessionStartTime;
      datetime sessionEnd = sessionStart + 86400; // 24 hours
      
      double sessionDuration = sessionEnd - sessionStart;
      double elapsed = currentTime - sessionStart;
      
      if(sessionDuration <= 0) return 0.0;
      
      double progress = (elapsed / sessionDuration) * 100.0;
      return MathMin(progress, 100.0);
   }
   else
   {
      // For backtesting, estimate based on tick count
      return MathMin((OperationCounter / 1000.0) * 100.0, 100.0);
   }
}

//+------------------------------------------------------------------+
//| Enhanced market data update for multiple symbol types          |
//+------------------------------------------------------------------+
void UpdateMarketData()
{
   // Update major pairs if enabled
   if(TrackMajorPairs)
   {
      for(int i = 0; i < ArraySize(MajorPairs); i++)
      {
         WriteMarketData(MajorPairs[i]);
      }
   }
   
   // Update minor pairs if enabled
   if(TrackMinorPairs)
   {
      for(int i = 0; i < ArraySize(MinorPairs); i++)
      {
         WriteMarketData(MinorPairs[i]);
      }
   }
   
   // Update exotic pairs if enabled
   if(TrackExoticPairs)
   {
      for(int i = 0; i < ArraySize(ExoticPairs); i++)
      {
         WriteMarketData(ExoticPairs[i]);
      }
   }
   
   // Update commodities if enabled
   if(TrackCommodities)
   {
      for(int i = 0; i < ArraySize(Commodities); i++)
      {
         WriteMarketData(Commodities[i]);
      }
   }
}

//+------------------------------------------------------------------+
//| Setup visual indicators on chart                               |
//+------------------------------------------------------------------+
void SetupVisualIndicators()
{
   // Create MCP status panel
   if(ObjectFind("MCP_Status_Panel") < 0)
   {
      ObjectCreate("MCP_Status_Panel", OBJ_LABEL, 0, 0, 0);
      ObjectSet("MCP_Status_Panel", OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSet("MCP_Status_Panel", OBJPROP_XDISTANCE, 10);
      ObjectSet("MCP_Status_Panel", OBJPROP_YDISTANCE, 20);
      ObjectSetText("MCP_Status_Panel", "MCP Ultimate v" + mcpVersion + " - Initializing...", 9, "Arial Bold", clrLime);
   }
   
   // Create operation counter
   if(ObjectFind("MCP_Operations") < 0)
   {
      ObjectCreate("MCP_Operations", OBJ_LABEL, 0, 0, 0);
      ObjectSet("MCP_Operations", OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSet("MCP_Operations", OBJPROP_XDISTANCE, 10);
      ObjectSet("MCP_Operations", OBJPROP_YDISTANCE, 40);
      ObjectSetText("MCP_Operations", "Operations: 0", 8, "Arial", clrWhite);
   }
   
   // Create session info
   if(ObjectFind("MCP_Session") < 0)
   {
      ObjectCreate("MCP_Session", OBJ_LABEL, 0, 0, 0);
      ObjectSet("MCP_Session", OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSet("MCP_Session", OBJPROP_XDISTANCE, 10);
      ObjectSet("MCP_Session", OBJPROP_YDISTANCE, 60);
      ObjectSetText("MCP_Session", "Session: " + TimeToString(SessionStartTime, TIME_DATE|TIME_MINUTES), 8, "Arial", clrYellow);
   }
}

//+------------------------------------------------------------------+
//| Update visual indicators with current status                   |
//+------------------------------------------------------------------+
void UpdateVisualIndicators()
{
   // Update status panel
   string statusText = "MCP Ultimate v" + mcpVersion + " - " + (IsBacktesting ? "BACKTEST" : "LIVE");
   color statusColor = IsBacktesting ? clrOrange : clrLime;
   ObjectSetText("MCP_Status_Panel", statusText, 9, "Arial Bold", statusColor);
   
   // Update operations counter
   ObjectSetText("MCP_Operations", "Operations: " + IntegerToString(OperationCounter), 8, "Arial", clrWhite);
   
   // Update session info with current equity
   string sessionInfo = "Equity: $" + DoubleToString(AccountEquity(), 2);
   if(MaxDrawdown > 0)
      sessionInfo += " | DD: $" + DoubleToString(MaxDrawdown, 2);
   ObjectSetText("MCP_Session", sessionInfo, 8, "Arial", clrYellow);
}

//+------------------------------------------------------------------+
//| Cleanup visual indicators                                       |
//+------------------------------------------------------------------+
void CleanupVisualIndicators()
{
   ObjectDelete("MCP_Status_Panel");
   ObjectDelete("MCP_Operations");
   ObjectDelete("MCP_Session");
}

//+------------------------------------------------------------------+
//| Enhanced logging system with rotation                          |
//+------------------------------------------------------------------+
void LogOperation(string operation, string description, string details)
{
   if(!SaveDetailedLogs) return;
   
   int fileHandle = FileOpen(LogFilePath, FILE_WRITE|FILE_READ|FILE_TXT);
   
   if(fileHandle != INVALID_HANDLE)
   {
      // Move to end of file
      FileSeek(fileHandle, 0, SEEK_END);
      
      string logEntry = StringFormat("%s | %s | %s | %s | %s\n",
         TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
         operation,
         description,
         details,
         "Op#" + IntegerToString(OperationCounter)
      );
      
      FileWriteString(fileHandle, logEntry);
      FileClose(fileHandle);
   }
}

//+------------------------------------------------------------------+
//| Cleanup old log files to prevent disk space issues            |
//+------------------------------------------------------------------+
void CleanupOldLogFiles()
{
   // This is a placeholder - MT4 doesn't have direct file enumeration
   // In practice, you would manually clean old files or use external tools
   if(EnableDebugMode)
      Print("Log cleanup: Limited to ", MaxLogFiles, " files (manual cleanup recommended)");
}

//+------------------------------------------------------------------+
//| Get human-readable uninit reason                                |
//+------------------------------------------------------------------+
string GetUninitReasonText(int reason)
{
   switch(reason)
   {
      case REASON_PROGRAM:     return "EA stopped by user";
      case REASON_REMOVE:      return "EA removed from chart";
      case REASON_RECOMPILE:   return "EA recompiled";
      case REASON_CHARTCHANGE: return "Chart symbol/period changed";
      case REASON_CHARTCLOSE:  return "Chart closed";
      case REASON_PARAMETERS:  return "Input parameters changed";
      case REASON_ACCOUNT:     return "Account changed";
      default:                 return "Unknown reason (" + IntegerToString(reason) + ")";
   }
}

//+------------------------------------------------------------------+
//| Write enhanced MCP status to JSON file                         |
//+------------------------------------------------------------------+
void WriteMCPStatus(string status, double progress, string message)
{
   if(!EnableFileReporting) return;
   
   int fileHandle = FileOpen(StatusFilePath, FILE_WRITE|FILE_TXT);
   
   if(fileHandle != INVALID_HANDLE)
   {
      // Count current trades
      int openTrades = 0;
      for(int i = 0; i < OrdersTotal(); i++)
      {
         if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         {
            if(OrderType() <= 1) openTrades++; // Only market orders
         }
      }
      
      string jsonStatus;
      if(EnableJSONFormat)
      {
         jsonStatus = StringFormat(
            "{\n"
            "  \"mcp_version\": \"%s\",\n"
            "  \"status\": \"%s\",\n"
            "  \"expert\": \"%s\",\n"
            "  \"symbol\": \"%s\",\n"
            "  \"timeframe\": \"%s\",\n"
            "  \"progress\": %.2f,\n"
            "  \"session_start\": \"%s\",\n"
            "  \"current_time\": \"%s\",\n"
            "  \"operations_count\": %d,\n"
            "  \"trades_executed\": %d,\n"
            "  \"open_trades\": %d,\n"
            "  \"current_balance\": %.2f,\n"
            "  \"current_equity\": %.2f,\n"
            "  \"max_equity\": %.2f,\n"
            "  \"current_drawdown\": %.2f,\n"
            "  \"max_drawdown\": %.2f,\n"
            "  \"is_testing\": %s,\n"
            "  \"market_tracking\": {\n"
            "    \"major_pairs\": %s,\n"
            "    \"minor_pairs\": %s,\n"
            "    \"exotic_pairs\": %s,\n"
            "    \"commodities\": %s\n"
            "  },\n"
            "  \"features\": {\n"
            "    \"file_reporting\": %s,\n"
            "    \"backtest_tracking\": %s,\n"
            "    \"visual_mode\": %s,\n"
            "    \"debug_mode\": %s,\n"
            "    \"detailed_logs\": %s\n"
            "  },\n"
            "  \"message\": \"%s\"\n"
            "}",
            mcpVersion,
            status,
            WindowExpertName(),
            Symbol(),
            PeriodToString(Period()),
            progress,
            TimeToString(SessionStartTime, TIME_DATE|TIME_SECONDS),
            TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
            OperationCounter,
            OrdersHistoryTotal(),
            openTrades,
            AccountBalance(),
            AccountEquity(),
            MaxEquity,
            CurrentDrawdown,
            MaxDrawdown,
            (IsTesting() ? "true" : "false"),
            (TrackMajorPairs ? "true" : "false"),
            (TrackMinorPairs ? "true" : "false"),
            (TrackExoticPairs ? "true" : "false"),
            (TrackCommodities ? "true" : "false"),
            (EnableFileReporting ? "true" : "false"),
            (EnableBacktestTracking ? "true" : "false"),
            (EnableVisualMode ? "true" : "false"),
            (EnableDebugMode ? "true" : "false"),
            (SaveDetailedLogs ? "true" : "false"),
            message
         );
      }
      else
      {
         // Simple text format
         jsonStatus = StringFormat(
            "MCP_Version=%s\n"
            "Status=%s\n"
            "Expert=%s\n"
            "Symbol=%s\n"
            "Progress=%.2f\n"
            "Operations=%d\n"
            "Balance=%.2f\n"
            "Equity=%.2f\n"
            "Message=%s\n",
            mcpVersion, status, WindowExpertName(), Symbol(), 
            progress, OperationCounter, AccountBalance(), AccountEquity(), message
         );
      }
      
      FileWrite(fileHandle, jsonStatus);
      FileClose(fileHandle);
      
      if(EnableDebugMode)
         Print("MCP Status updated: ", status, " (", DoubleToString(progress, 1), "%) - ", message);
   }
}

//+------------------------------------------------------------------+
//| Write comprehensive MCP results to JSON file                   |
//+------------------------------------------------------------------+
void WriteMCPResults()
{
   if(!EnableFileReporting) return;
   
   int fileHandle = FileOpen(ResultsFilePath, FILE_WRITE|FILE_TXT);
   
   if(fileHandle != INVALID_HANDLE)
   {
      // Calculate comprehensive statistics
      double totalProfit = AccountProfit();
      int totalTrades = OrdersHistoryTotal();
      int profitTrades = 0;
      int lossTrades = 0;
      double largestProfit = 0;
      double largestLoss = 0;
      double grossProfit = 0;
      double grossLoss = 0;
      
      // Analyze historical orders
      for(int i = 0; i < totalTrades; i++)
      {
         if(OrderSelect(i, SELECT_BY_POS, MODE_HISTORY))
         {
            double orderProfit = OrderProfit() + OrderSwap() + OrderCommission();
            if(orderProfit > 0)
            {
               profitTrades++;
               grossProfit += orderProfit;
               if(orderProfit > largestProfit) largestProfit = orderProfit;
            }
            else if(orderProfit < 0)
            {
               lossTrades++;
               grossLoss += MathAbs(orderProfit);
               if(orderProfit < largestLoss) largestLoss = orderProfit;
            }
         }
      }
      
      double winRate = totalTrades > 0 ? (profitTrades * 100.0 / totalTrades) : 0;
      double profitFactor = grossLoss > 0 ? grossProfit / grossLoss : 0;
      double expectedPayoff = totalTrades > 0 ? totalProfit / totalTrades : 0;
      datetime sessionDuration = TimeCurrent() - SessionStartTime;
      
      string jsonResults;
      if(EnableJSONFormat)
      {
         jsonResults = StringFormat(
            "{\n"
            "  \"mcp_ultimate_results\": {\n"
            "    \"version\": \"%s\",\n"
            "    \"expert\": \"%s\",\n"
            "    \"symbol\": \"%s\",\n"
            "    \"timeframe\": \"%s\",\n"
            "    \"session_period\": \"%s to %s\",\n"
            "    \"session_duration_hours\": %.2f,\n"
            "    \"total_operations\": %d,\n"
            "    \"initial_balance\": %.2f,\n"
            "    \"final_balance\": %.2f,\n"
            "    \"final_equity\": %.2f,\n"
            "    \"max_equity\": %.2f,\n"
            "    \"total_net_profit\": %.2f,\n"
            "    \"gross_profit\": %.2f,\n"
            "    \"gross_loss\": %.2f,\n"
            "    \"profit_factor\": %.2f,\n"
            "    \"expected_payoff\": %.2f,\n"
            "    \"absolute_drawdown\": %.2f,\n"
            "    \"maximal_drawdown\": %.2f,\n"
            "    \"total_trades\": %d,\n"
            "    \"profit_trades\": %d,\n"
            "    \"loss_trades\": %d,\n"
            "    \"largest_profit_trade\": %.2f,\n"
            "    \"largest_loss_trade\": %.2f,\n"
            "    \"win_rate_percentage\": %.2f,\n"
            "    \"session_type\": \"%s\"\n"
            "  },\n"
            "  \"market_tracking_summary\": {\n"
            "    \"major_pairs_tracked\": %d,\n"
            "    \"minor_pairs_tracked\": %d,\n"
            "    \"exotic_pairs_tracked\": %d,\n"
            "    \"commodities_tracked\": %d\n"
            "  },\n"
            "  \"account_details\": {\n"
            "    \"leverage\": %d,\n"
            "    \"currency\": \"%s\",\n"
            "    \"server\": \"%s\",\n"
            "    \"company\": \"%s\"\n"
            "  },\n"
            "  \"completion_info\": {\n"
            "    \"status\": \"completed\",\n"
            "    \"completion_time\": \"%s\",\n"
            "    \"is_backtest\": %s,\n"
            "    \"reports_folder\": \"%s\"\n"
            "  }\n"
            "}",
            mcpVersion,
            WindowExpertName(),
            Symbol(),
            PeriodToString(Period()),
            TimeToString(SessionStartTime, TIME_DATE),
            TimeToString(TimeCurrent(), TIME_DATE),
            sessionDuration / 3600.0,
            OperationCounter,
            InitialBalance,
            AccountBalance(),
            AccountEquity(),
            MaxEquity,
            totalProfit,
            grossProfit,
            grossLoss,
            profitFactor,
            expectedPayoff,
            CurrentDrawdown,
            MaxDrawdown,
            totalTrades,
            profitTrades,
            lossTrades,
            largestProfit,
            largestLoss,
            winRate,
            (IsBacktesting ? "backtest" : "live_trading"),
            (TrackMajorPairs ? ArraySize(MajorPairs) : 0),
            (TrackMinorPairs ? ArraySize(MinorPairs) : 0),
            (TrackExoticPairs ? ArraySize(ExoticPairs) : 0),
            (TrackCommodities ? ArraySize(Commodities) : 0),
            AccountLeverage(),
            AccountCurrency(),
            AccountServer(),
            AccountCompany(),
            TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
            (IsTesting() ? "true" : "false"),
            ReportsFolder
         );
      }
      else
      {
         // Simple text format
         jsonResults = StringFormat(
            "MCP_Ultimate_Results\n"
            "Version=%s\n"
            "Expert=%s\n"
            "Symbol=%s\n"
            "Operations=%d\n"
            "FinalBalance=%.2f\n"
            "TotalProfit=%.2f\n"
            "WinRate=%.2f\n"
            "CompletionTime=%s\n",
            mcpVersion, WindowExpertName(), Symbol(), OperationCounter,
            AccountBalance(), totalProfit, winRate,
            TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS)
         );
      }
      
      FileWrite(fileHandle, jsonResults);
      FileClose(fileHandle);
      
      if(EnableDebugMode)
         Print("MCP Results written: ", totalTrades, " trades, ", DoubleToString(totalProfit, 2), " profit");
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
      // Count only market orders (BUY/SELL) so TotalPositions matches the
      // list entries below.  OrdersTotal() includes pending orders which are
      // written separately — mixing the two caused an off-by-N inconsistency.
      int marketCount = 0;
      for (int c = 0; c < OrdersTotal(); c++)
         if (OrderSelect(c, SELECT_BY_POS, MODE_TRADES) && OrderType() <= 1)
            marketCount++;

      FileWrite(fileHandle, "TotalPositions=" + IntegerToString(marketCount));
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
//| Process order commands from MCP server                          |
//+------------------------------------------------------------------+
void ProcessOrderCommands()
{
   if (FileIsExist("order_commands.txt"))
   {
      int fileHandle = FileOpen("order_commands.txt", FILE_READ | FILE_TXT);
      if (fileHandle != INVALID_HANDLE)
      {
         string jsonCommand = "";
         while (!FileIsEnding(fileHandle))
         {
            jsonCommand += FileReadString(fileHandle);
         }
         FileClose(fileHandle);
         
         // Delete the command file after reading
         FileDelete("order_commands.txt");
         
         // Parse and execute the order command
         ExecuteOrderCommand(jsonCommand);
         LogOperation("ORDER", "Order command processed", jsonCommand);
      }
   }
}

//+------------------------------------------------------------------+
//| Process close commands from MCP server                          |
//+------------------------------------------------------------------+
void ProcessCloseCommands()
{
   if (FileIsExist("close_commands.txt"))
   {
      int fileHandle = FileOpen("close_commands.txt", FILE_READ | FILE_TXT);
      if (fileHandle != INVALID_HANDLE)
      {
         string jsonCommand = "";
         while (!FileIsEnding(fileHandle))
         {
            jsonCommand += FileReadString(fileHandle);
         }
         FileClose(fileHandle);
         
         // Delete the command file after reading
         FileDelete("close_commands.txt");
         
         // Parse and execute the close command
         ExecuteCloseCommand(jsonCommand);
         LogOperation("CLOSE", "Close command processed", jsonCommand);
      }
   }
}

//+------------------------------------------------------------------+
//| Process backtest commands from MCP server                       |
//+------------------------------------------------------------------+
void ProcessBacktestCommands()
{
   if (FileIsExist("backtest_commands.txt"))
   {
      int fileHandle = FileOpen("backtest_commands.txt", FILE_READ | FILE_TXT);
      if (fileHandle != INVALID_HANDLE)
      {
         string jsonCommand = "";
         while (!FileIsEnding(fileHandle))
         {
            jsonCommand += FileReadString(fileHandle);
         }
         FileClose(fileHandle);
         
         // Delete the command file after reading
         FileDelete("backtest_commands.txt");
         
         // Execute the backtest command
         ExecuteBacktestCommand(jsonCommand);
         LogOperation("BACKTEST", "Backtest command processed", jsonCommand);
      }
   }
}

//+------------------------------------------------------------------+
//| Write an order-result JSON to order_result.txt                  |
//+------------------------------------------------------------------+
void WriteOrderResult(string json)
{
   int fh = FileOpen("order_result.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (fh != INVALID_HANDLE) { FileWrite(fh, json); FileClose(fh); }
}

//+------------------------------------------------------------------+
//| Order risk firewall. Returns "" if the order is safe to send,   |
//| otherwise a short reason string. `entry` is the parsed `price`  |
//| (for market orders the caller has already set price = live      |
//| MarketInfo bid/ask).                                            |
//+------------------------------------------------------------------+
string ValidateOrderCommand(string symbol, int orderType, double lots,
                            double entry, double stopLoss, double takeProfit,
                            bool allowUnprotected)
{
   if (allowUnprotected)
   {
      LogOperation("ORDER_FIREWALL_BYPASS", "allow_unprotected active — firewall checks skipped", symbol);
      return "";
   }

   bool isLong    = (orderType == OP_BUY || orderType == OP_BUYLIMIT || orderType == OP_BUYSTOP);
   bool isPending = (orderType == OP_BUYLIMIT || orderType == OP_SELLLIMIT ||
                     orderType == OP_BUYSTOP  || orderType == OP_SELLSTOP);

   // ── Tier 1: required protection (raw values, before lot normalisation) ──
   if (lots <= 0)                  return "lots<=0";
   if (stopLoss <= 0)              return "stop_loss<=0";
   if (takeProfit <= 0)            return "take_profit<=0";
   if (isPending && entry <= 0)    return "price<=0";

   // ── Tier 2: side & distance correctness ──
   double point     = MarketInfo(symbol, MODE_POINT);
   double stopLevel = MarketInfo(symbol, MODE_STOPLEVEL) * point;
   double ask       = MarketInfo(symbol, MODE_ASK);
   double bid       = MarketInfo(symbol, MODE_BID);

   // NOTE: many ECN/STP accounts (incl. Pepperstone UK) report MODE_STOPLEVEL == 0,
   // which makes the distance checks below inert (any positive distance passes).
   // The SL/TP SIDE checks (SL<entry<TP long, inverse short) and the pending
   // entry-vs-market side checks are the primary protection and ALWAYS apply.

   if (isLong)
   {
      if (!(stopLoss < entry))            return "SL not below entry (long)";
      if (!(takeProfit > entry))          return "TP not above entry (long)";
      if ((entry - stopLoss)   < stopLevel) return "SL within stopLevel";
      if ((takeProfit - entry) < stopLevel) return "TP within stopLevel";
   }
   else
   {
      if (!(stopLoss > entry))            return "SL not above entry (short)";
      if (!(takeProfit < entry))          return "TP not below entry (short)";
      if ((stopLoss - entry)   < stopLevel) return "SL within stopLevel";
      if ((entry - takeProfit) < stopLevel) return "TP within stopLevel";
   }

   // Pending entry side vs market
   if (orderType == OP_BUYLIMIT)
   {
      if (!(entry < ask))            return "BUY_LIMIT entry>=Ask";
      if ((ask - entry) < stopLevel) return "BUY_LIMIT within stopLevel";
   }
   else if (orderType == OP_SELLLIMIT)
   {
      if (!(entry > bid))            return "SELL_LIMIT entry<=Bid";
      if ((entry - bid) < stopLevel) return "SELL_LIMIT within stopLevel";
   }
   else if (orderType == OP_BUYSTOP)
   {
      if (!(entry > ask))            return "BUY_STOP entry<=Ask";
      if ((entry - ask) < stopLevel) return "BUY_STOP within stopLevel";
   }
   else if (orderType == OP_SELLSTOP)
   {
      if (!(entry < bid))            return "SELL_STOP entry>=Bid";
      if ((bid - entry) < stopLevel) return "SELL_STOP within stopLevel";
   }

   return "";
}

//+------------------------------------------------------------------+
//| Execute order command (simplified JSON parsing)                 |
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
   // Magic number from command (falls back to EA input if absent)
   string magicStr   = ExtractJsonValue(jsonCommand, "magic_number");
   int    magic      = StringLen(magicStr) > 0 ? (int)StringToInteger(magicStr) : MagicNumber;

   string json = "";

   // ── Pre-flight checks ────────────────────────────────────────────────────────

   // 1. AutoTrading must be enabled
   if (!IsTradeAllowed())
   {
      json = StringFormat("{\"success\":false,\"error\":4109,\"description\":\"AutoTrading is disabled\",\"request_id\":\"%s\"}", requestId);
      LogOperation("ORDER_BLOCKED", "AutoTrading disabled", operation + " " + symbol);
      WriteOrderResult(json);
      return;
   }

   // 2. Refresh quotes so MarketInfo() values are current
   RefreshRates();

   // 3. Determine order type and live price for market orders
   int   orderType  = -1;
   color arrowColor = clrNONE;

   if      (operation == "BUY")        { orderType = OP_BUY;       price = MarketInfo(symbol, MODE_ASK); arrowColor = clrBlue; }
   else if (operation == "SELL")       { orderType = OP_SELL;      price = MarketInfo(symbol, MODE_BID); arrowColor = clrRed;  }
   else if (operation == "BUY_LIMIT")  { orderType = OP_BUYLIMIT;  arrowColor = clrBlue; }
   else if (operation == "SELL_LIMIT") { orderType = OP_SELLLIMIT; arrowColor = clrRed;  }
   else if (operation == "BUY_STOP")   { orderType = OP_BUYSTOP;   arrowColor = clrBlue; }
   else if (operation == "SELL_STOP")  { orderType = OP_SELLSTOP;  arrowColor = clrRed;  }

   if (orderType < 0)
   {
      json = StringFormat("{\"success\":false,\"error\":\"Invalid operation\",\"operation\":\"%s\",\"request_id\":\"%s\"}",
                          operation, requestId);
      LogOperation("ORDER_INVALID", "Invalid operation type", operation);
      WriteOrderResult(json);
      return;
   }

   // 3b. Risk firewall — reject naked / wrong-sided orders before sizing & send.
   //     `price` here is already the live bid/ask for market orders (set above)
   //     and the requested entry for pending orders.
   bool allowUnprotected = (ExtractJsonValue(jsonCommand, "allow_unprotected") == "true");
   string vErr = ValidateOrderCommand(symbol, orderType, lots, price, stopLoss, takeProfit, allowUnprotected);
   if (vErr != "")
   {
      json = StringFormat(
         "{\"success\":false,\"error\":9001,\"description\":\"FIREWALL_REJECTED: %s\",\"symbol\":\"%s\",\"operation\":\"%s\",\"request_id\":\"%s\"}",
         vErr, symbol, operation, requestId);
      LogOperation("ORDER_FIREWALL", "Firewall rejected: " + vErr, operation + " " + symbol);
      WriteOrderResult(json);
      return;
   }

   // 4. Normalise lot size to broker step/min/max
   double lotStep = MarketInfo(symbol, MODE_LOTSTEP);
   double minLot  = MarketInfo(symbol, MODE_MINLOT);
   double maxLot  = MarketInfo(symbol, MODE_MAXLOT);
   if (lotStep > 0)
      lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   lots = NormalizeDouble(lots, 2);

   // 5. Idempotency — suppress duplicate if an open/pending order already has this comment+magic
   for (int k = 0; k < OrdersTotal(); k++)
   {
      if (OrderSelect(k, SELECT_BY_POS, MODE_TRADES))
      {
         if (OrderSymbol() == symbol &&
             OrderMagicNumber() == magic &&
             StringLen(comment) > 0 &&
             StringFind(OrderComment(), comment) >= 0)
         {
            string dupJson = StringFormat(
               "{\"success\":true,\"ticket\":%d,\"symbol\":\"%s\",\"operation\":\"%s\","
               "\"lots\":%.2f,\"price\":%.5f,\"request_id\":\"%s\",\"duplicate\":true}",
               OrderTicket(), symbol, operation, OrderLots(), OrderOpenPrice(), requestId);
            LogOperation("ORDER_DUPLICATE", "Duplicate suppressed — returning existing ticket",
                         "Ticket: " + IntegerToString(OrderTicket()) + " Comment: " + comment);
            WriteOrderResult(dupJson);
            return;
         }
      }
   }

   // ── Place order ─────────────────────────────────────────────────────────────

   // Broker-side expiry for pending orders (0 = never expires)
   int      expiryMins = (int)StringToInteger(ExtractJsonValue(jsonCommand, "expiry_minutes"));
   datetime expiry     = (expiryMins > 0) ? TimeCurrent() + expiryMins * 60 : 0;

   // Asset-class slippage (default 3 if not provided)
   string slippageStr = ExtractJsonValue(jsonCommand, "slippage");
   int    slippage    = StringLen(slippageStr) > 0 ? (int)StringToInteger(slippageStr) : 3;

   int ticket = OrderSend(symbol, orderType, lots, price, slippage, stopLoss, takeProfit, comment, magic, expiry, arrowColor);
   if (ticket > 0)
   {
      Print("Order placed successfully. Ticket: ", ticket, " Magic: ", magic);
      json = StringFormat("{\"success\":true,\"ticket\":%d,\"symbol\":\"%s\",\"operation\":\"%s\",\"lots\":%.2f,\"price\":%.5f,\"request_id\":\"%s\"}",
                          ticket, symbol, operation, lots, price, requestId);
      LogOperation("ORDER_SUCCESS", "Order placed: " + operation + " " + symbol, "Ticket: " + IntegerToString(ticket));
   }
   else
   {
      int error = GetLastError();
      Print("Order failed. Error: ", error, " Op: ", operation, " Symbol: ", symbol);
      json = StringFormat("{\"success\":false,\"error\":%d,\"description\":\"OrderSend failed\",\"symbol\":\"%s\",\"operation\":\"%s\",\"request_id\":\"%s\"}",
                          error, symbol, operation, requestId);
      LogOperation("ORDER_FAILED", "Order failed: " + operation + " " + symbol, "Error: " + IntegerToString(error));
   }

   WriteOrderResult(json);
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

      // Determine close size — honour partial close request if lots > 0 and < full position
      double requestedLots = StringToDouble(ExtractJsonValue(jsonCommand, "lots"));
      double closeLots     = OrderLots();
      if (requestedLots > 0 && requestedLots < OrderLots())
      {
         double lotStep = MarketInfo(OrderSymbol(), MODE_LOTSTEP);
         double minLot  = MarketInfo(OrderSymbol(), MODE_MINLOT);
         closeLots = requestedLots;
         if (lotStep > 0) closeLots = MathFloor(closeLots / lotStep) * lotStep;
         closeLots = MathMax(minLot, closeLots);
         closeLots = NormalizeDouble(closeLots, 2);
      }

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
      {
         // Pending order (BUY_LIMIT, SELL_LIMIT, BUY_STOP, SELL_STOP) — use OrderDelete()
         // OrderClose() is only valid for filled market orders; it silently does nothing
         // (returns false, GetLastError() == 0) on pending orders.
         result = OrderDelete(ticket, clrNONE);
      }

      if (result)
      {
         Print("Position closed/deleted successfully. Ticket: ", ticket);
         json = StringFormat("{\"success\":true,\"ticket\":%d,\"close_price\":%.5f,\"request_id\":\"%s\"}",
                             ticket, closePrice, requestId);
         LogOperation("CLOSE_SUCCESS", "Position closed", "Ticket: " + IntegerToString(ticket));
      }
      else
      {
         int error = GetLastError();
         Print("Failed to close/delete order. Error: ", error);
         json = StringFormat("{\"success\":false,\"ticket\":%d,\"error\":%d,\"description\":\"OrderClose failed\",\"request_id\":\"%s\"}",
                             ticket, error, requestId);
         LogOperation("CLOSE_FAILED", "Failed to close position", "Ticket: " + IntegerToString(ticket) + ", Error: " + IntegerToString(error));
      }
   }
   else
   {
      json = StringFormat("{\"success\":false,\"ticket\":%d,\"error\":\"Order not found\",\"request_id\":\"%s\"}",
                          ticket, requestId);
      LogOperation("CLOSE_NOT_FOUND", "Order not found for close", "Ticket: " + IntegerToString(ticket));
   }

   int fh = FileOpen("close_result.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (fh != INVALID_HANDLE) { FileWrite(fh, json); FileClose(fh); }
}

//+------------------------------------------------------------------+
//| Process modify commands (trailing SL / breakeven SL)            |
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
   LogOperation("MODIFY", "Modify command processed", jsonCommand);
}

//+------------------------------------------------------------------+
//| Execute modify command (trailing SL / breakeven SL)             |
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
         LogOperation("MODIFY_SUCCESS", "Order modified", "Ticket: " + IntegerToString(ticket));
      }
      else
      {
         int error = GetLastError();
         Print("OrderModify failed. Ticket: ", ticket, " Error: ", error);
         json = StringFormat("{\"success\":false,\"ticket\":%d,\"error\":%d,\"description\":\"OrderModify failed\",\"request_id\":\"%s\"}",
                             ticket, error, requestId);
         LogOperation("MODIFY_FAILED", "OrderModify failed", "Ticket: " + IntegerToString(ticket) + ", Error: " + IntegerToString(error));
      }
   }
   else
   {
      json = StringFormat("{\"success\":false,\"ticket\":%d,\"error\":\"Order not found\",\"request_id\":\"%s\"}",
                          ticket, requestId);
      LogOperation("MODIFY_NOT_FOUND", "Order not found for modify", "Ticket: " + IntegerToString(ticket));
   }

   int fh = FileOpen("modify_result.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (fh != INVALID_HANDLE) { FileWrite(fh, json); FileClose(fh); }
}

//+------------------------------------------------------------------+
//| Execute backtest command                                         |
//+------------------------------------------------------------------+
void ExecuteBacktestCommand(string jsonCommand)
{
   // Extract backtest parameters
   string expert = ExtractJsonValue(jsonCommand, "expert");
   string symbol = ExtractJsonValue(jsonCommand, "symbol");
   string timeframe = ExtractJsonValue(jsonCommand, "timeframe");
   string fromDate = ExtractJsonValue(jsonCommand, "from_date");
   string toDate = ExtractJsonValue(jsonCommand, "to_date");
   double initialDeposit = StringToDouble(ExtractJsonValue(jsonCommand, "initial_deposit"));
   string model = ExtractJsonValue(jsonCommand, "model");
   bool optimization = ExtractJsonValue(jsonCommand, "optimization") == "true";
   
   // Write backtest results file
   int resultHandle = FileOpen("backtest_results.txt", FILE_WRITE | FILE_TXT);
   
   if (resultHandle != INVALID_HANDLE)
   {
      // Note: MT4 doesn't have direct API for programmatic backtesting
      // This is a simulation of what the results would look like
      
      FileWrite(resultHandle, "{");
      FileWrite(resultHandle, "\"status\": \"acknowledged\",");
      FileWrite(resultHandle, "\"message\": \"Backtest command received - Use Strategy Tester or enable file reporting\",");
      FileWrite(resultHandle, "\"expert\": \"" + expert + "\",");
      FileWrite(resultHandle, "\"symbol\": \"" + symbol + "\",");
      FileWrite(resultHandle, "\"timeframe\": \"" + timeframe + "\",");
      FileWrite(resultHandle, "\"period\": \"" + fromDate + " to " + toDate + "\",");
      FileWrite(resultHandle, "\"initial_deposit\": " + DoubleToString(initialDeposit, 2) + ",");
      FileWrite(resultHandle, "\"model\": \"" + model + "\",");
      FileWrite(resultHandle, "\"file_reporting\": " + (EnableFileReporting ? "\"enabled\"" : "\"disabled\"") + ",");
      FileWrite(resultHandle, "\"instructions\": [");
      FileWrite(resultHandle, "\"1. Open MT4 Strategy Tester (Ctrl+R)\",");
      FileWrite(resultHandle, "\"2. Select Expert: " + expert + "\",");
      FileWrite(resultHandle, "\"3. Select Symbol: " + symbol + "\",");
      FileWrite(resultHandle, "\"4. Set Timeframe: " + timeframe + "\",");
      FileWrite(resultHandle, "\"5. Set Period: " + fromDate + " - " + toDate + "\",");
      FileWrite(resultHandle, "\"6. Set Initial Deposit: " + DoubleToString(initialDeposit, 2) + "\",");
      FileWrite(resultHandle, "\"7. Select Model: " + model + "\",");
      FileWrite(resultHandle, "\"8. Enable 'File Reporting' and 'Backtest Tracking' in EA inputs\",");
      FileWrite(resultHandle, "\"9. Click Start to run backtest with enhanced reporting\"");
      FileWrite(resultHandle, "]");
      FileWrite(resultHandle, "}");
      
      FileClose(resultHandle);
   }
   
   Print("Backtest command processed for: ", expert, " on ", symbol);
   
   // If file reporting is enabled and we're in testing mode, update status
   if(EnableFileReporting && EnableBacktestTracking)
   {
      WriteMCPStatus("backtest_requested", 0, "Backtest command received from MCP");
   }
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

   // Skip whitespace only
   while (startPos < StringLen(json) && StringGetChar(json, startPos) == ' ')
      startPos++;

   int endPos = startPos;

   // Quoted string value
   if (startPos < StringLen(json) && StringGetChar(json, startPos) == '"')
   {
      startPos++;  // skip opening quote
      endPos = startPos;
      while (endPos < StringLen(json) && StringGetChar(json, endPos) != '"')
         endPos++;
   }
   else
   {
      // Numeric or boolean — read until comma or closing brace
      while (endPos < StringLen(json))
      {
         char c = StringGetChar(json, endPos);
         if (c == ',' || c == '}')
            break;
         endPos++;
      }
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
      // Add MCP Ultimate and other Expert Advisors
      FileWrite(fileHandle, "MCP_Ultimate|Ultimate MCP Bridge with All Features|Current");
      FileWrite(fileHandle, "MCPBridge_Unified|Unified MCP Bridge with Reporting|Legacy");
      FileWrite(fileHandle, "EA_FileReporting_Template|File Reporting Template|Template");
      FileWrite(fileHandle, "MACD Sample|Sample MACD Expert Advisor|Built-in");
      FileWrite(fileHandle, "Moving Average|Sample Moving Average EA|Built-in");
      FileWrite(fileHandle, "RSI|Relative Strength Index EA|Built-in");
      
      // Note: In a real implementation, this would scan the Experts folder
      // For now, users need to manually add their EAs to this list
      
      FileClose(fileHandle);
   }
}

//+------------------------------------------------------------------+
//| Convert period to string                                         |
//+------------------------------------------------------------------+
string PeriodToString(int period)
{
   switch(period)
   {
      case PERIOD_M1:  return "M1";
      case PERIOD_M5:  return "M5";
      case PERIOD_M15: return "M15";
      case PERIOD_M30: return "M30";
      case PERIOD_H1:  return "H1";
      case PERIOD_H4:  return "H4";
      case PERIOD_D1:  return "D1";
      case PERIOD_W1:  return "W1";
      case PERIOD_MN1: return "MN1";
      default:         return "UNKNOWN";
   }
}

//+------------------------------------------------------------------+
//| Create directory if it doesn't exist                            |
//+------------------------------------------------------------------+
void CreateDirectory(string path)
{
   // Note: MT4 automatically creates directories when writing files
   // This is a placeholder for directory creation logic
   if(EnableDebugMode)
      Print("Creating directory: ", path);
}
