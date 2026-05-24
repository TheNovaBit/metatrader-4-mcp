import express from "express";
import cors from "cors";
import fs from "fs/promises";
import path from "path";
import { fileURLToPath } from "url";
import { spawn } from "child_process";
import { randomUUID } from "crypto";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const app = express();
const PORT = process.env.PORT || 8080;

// MT4 data directory - used only when MT4_FILES_PATH is not set.
// Derived from APPDATA so the same binary works on any Windows user account
// (local dev: mahip, EC2: Administrator) without machine-specific edits.
const MT4_DATA_PATH =
  process.env.MT4_DATA_PATH ||
  path.join(process.env.APPDATA || "", "MetaQuotes", "Terminal");

// Pin to a specific MQL4/Files directory (recommended — mirrors mt4_client.py MT4_FILES_PATH).
// Set this env var to the exact path, e.g.:
//   C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\7D024799C00A011848A10ECEDFE5CBC2\MQL4\Files
const MT4_FILES_PATH_OVERRIDE = process.env.MT4_FILES_PATH || null;

// MT4 installation path for MetaEditor
const MT4_INSTALL_PATH =
  process.env.MT4_INSTALL_PATH ||
  "C:\\Program Files (x86)\\Pepperstone UK MetaTrader 4\\metaeditor.exe";

const METAEDITOR_PATHS = [MT4_INSTALL_PATH];  // must be an array — findMetaEditor() iterates it

// Shared secret for API key authentication.
// Set BRIDGE_API_KEY in the EC2 environment (and in start_trader.bat).
// If unset the middleware is bypassed — useful during local dev, but MUST be set in production.
const API_KEY = process.env.BRIDGE_API_KEY || "";

// How long (ms) to poll for a MT4 result file before timing out
const MT4_RESULT_TIMEOUT_MS = 5000;
const MT4_RESULT_POLL_MS    = 200;

// Magic number stamped on every order placed through the bridge.
// Allows the EA to distinguish bridge orders from manually placed ones.
// Must match MagicNumber input in MCP_Ultimate.mq4.
const BRIDGE_MAGIC_NUMBER = 20260101;

// ── Middleware ────────────────────────────────────────────────────────────────

// Restrict CORS to same-origin (the bridge is a localhost API, not a public service)
app.use(cors({ origin: false }));
app.use(express.json());

// API key authentication — all routes require X-Api-Key header when key is configured
app.use((req, res, next) => {
  if (API_KEY && req.headers["x-api-key"] !== API_KEY) {
    return res.status(401).json({ error: "Unauthorized" });
  }
  next();
});

// ── MT4 file helpers ──────────────────────────────────────────────────────────

// Resolve the MT4 MQL4/Files directory once and cache it.
let _mt4FilesDirCache = null;

async function getMT4FilesDir() {
  if (_mt4FilesDirCache) return _mt4FilesDirCache;

  if (MT4_FILES_PATH_OVERRIDE) {
    _mt4FilesDirCache = MT4_FILES_PATH_OVERRIDE;
    return _mt4FilesDirCache;
  }

  // Auto-discover: pick the first 32-char hash folder that has a MQL4/Files subdir
  const terminalFolders = await fs.readdir(MT4_DATA_PATH);
  for (const folder of terminalFolders) {
    if (folder.length === 32) {
      const filesDir = path.join(MT4_DATA_PATH, folder, "MQL4", "Files");
      try {
        await fs.access(filesDir);
        _mt4FilesDirCache = filesDir;
        return _mt4FilesDirCache;
      } catch {
        continue;
      }
    }
  }
  throw new Error(
    "No MT4 MQL4/Files directory found. Set MT4_FILES_PATH environment variable."
  );
}

async function readMT4File(filename) {
  const dir      = await getMT4FilesDir();
  const filePath = path.join(dir, filename);
  const content  = await fs.readFile(filePath, "utf-8");
  return content.trim();
}

async function writeMT4File(filename, content) {
  const dir      = await getMT4FilesDir();
  const filePath = path.join(dir, filename);
  await fs.mkdir(dir, { recursive: true });
  await fs.writeFile(filePath, content, "utf-8");
}

async function deleteMT4File(filename) {
  try {
    const dir = await getMT4FilesDir();
    await fs.unlink(path.join(dir, filename));
  } catch {
    // ignore — file may have already been deleted by MT4 EA
  }
}

// Find the MT4 Experts directory (reuses the same hash folder as getMT4FilesDir)
async function findMT4ExpertsDirectory() {
  const filesDir  = await getMT4FilesDir();
  // filesDir is …/MQL4/Files — Experts is a sibling of Files
  const expertsDir = path.join(filesDir, "..", "Experts");
  try {
    await fs.access(expertsDir);
    return path.resolve(expertsDir);
  } catch {
    throw new Error(`MT4 Experts directory not found at: ${expertsDir}`);
  }
}

// ── MT4 command helper ────────────────────────────────────────────────────────

/**
 * Write a command file to MT4, then poll the result file until the EA echoes
 * back the same request_id (or the timeout expires).
 *
 * Returns the parsed result object.
 * Throws if MT4 does not respond within MT4_RESULT_TIMEOUT_MS ms.
 */
async function sendMT4Command(commandFile, resultFile, command) {
  const id = randomUUID();
  command.request_id = id;

  await writeMT4File(commandFile, JSON.stringify(command));

  const deadline = Date.now() + MT4_RESULT_TIMEOUT_MS;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, MT4_RESULT_POLL_MS));
    try {
      const raw    = await readMT4File(resultFile);
      const result = JSON.parse(raw);
      if (result.request_id === id) {
        // Consume the result file so stale data cannot be re-read
        await deleteMT4File(resultFile);
        return result;
      }
    } catch {
      // File not yet written or not yet updated — keep polling
    }
  }

  // ── Timeout cleanup (prevents stale-command execution) ───────────────────────
  // Attempt to delete the command file so that, if MT4 hasn't read it yet,
  // the order is cleanly cancelled.  If delete fails the file is already gone
  // (EA consumed it but hasn't written the result yet — see one-last-check below).
  await deleteMT4File(commandFile);

  // One last result check: EA may have processed the command in the instant
  // between our final poll and the timeout throw.  If so, return the result
  // rather than falsely reporting failure (which would cause the caller to retry
  // and potentially place a duplicate order).
  try {
    const raw    = await readMT4File(resultFile);
    const result = JSON.parse(raw);
    if (result.request_id === id) {
      await deleteMT4File(resultFile);
      return result;
    }
  } catch {
    // Result not present — command was not processed in time
  }

  throw new Error(`MT4 did not respond within ${MT4_RESULT_TIMEOUT_MS / 1000}s`);
}

// ── MetaEditor helper ─────────────────────────────────────────────────────────

async function findMetaEditor() {
  for (const editorPath of METAEDITOR_PATHS) {
    try {
      await fs.access(editorPath);
      return editorPath;
    } catch {
      continue;
    }
  }
  throw new Error(
    "MetaEditor not found. Please set MT4_INSTALL_PATH environment variable."
  );
}

async function compileEA(eaPath) {
  return new Promise(async (resolve, reject) => {
    try {
      const metaEditorPath = await findMetaEditor();
      const logFile = path.join(
        path.dirname(eaPath),
        `${path.basename(eaPath, ".mq4")}_compile.log`
      );

      const compiler = spawn(metaEditorPath, [
        `/compile:${eaPath}`,
        `/log:${logFile}`,
        `/inc:${path.dirname(eaPath)}\\..\\Include`,
      ]);

      let stdout = "";
      let stderr = "";

      compiler.stdout?.on("data", (data) => { stdout += data.toString(); });
      compiler.stderr?.on("data", (data) => { stderr += data.toString(); });

      compiler.on("close", async (code) => {
        try {
          let logContent = "";
          try { logContent = await fs.readFile(logFile, "utf-8"); }
          catch { logContent = "Compilation log not available"; }

          const ex4Path  = eaPath.replace(".mq4", ".ex4");
          let compiled   = false;
          try { await fs.access(ex4Path); compiled = true; } catch {}

          const errors      = (logContent.match(/\d+ error\(s\)/gi) || ["0 error(s)"])[0];
          const warnings    = (logContent.match(/\d+ warning\(s\)/gi) || ["0 warning(s)"])[0];
          const errorCount  = parseInt(errors.match(/\d+/)[0]) || 0;
          const warnCount   = parseInt(warnings.match(/\d+/)[0]) || 0;

          resolve({
            success: errorCount === 0, compiled, exit_code: code,
            errors: errorCount, warnings: warnCount,
            log: logContent, stdout, stderr,
            ex4_path: compiled ? ex4Path : null, log_file: logFile,
          });
        } catch (e) {
          reject(new Error(`Failed to parse compilation results: ${e.message}`));
        }
      });

      compiler.on("error", (e) => reject(new Error(`Failed to start MetaEditor: ${e.message}`)));
      setTimeout(() => { compiler.kill(); reject(new Error("Compilation timeout after 30s")); }, 30000);
    } catch (e) {
      reject(e);
    }
  });
}

// ── API Routes ────────────────────────────────────────────────────────────────

app.get("/api/account", async (req, res) => {
  try {
    const accountData = await readMT4File("account_info.txt");
    const info = {};
    for (const line of accountData.split("\n")) {
      const [key, value] = line.split("=");
      if (key && value) info[key.trim()] = value.trim();
    }
    res.json(info);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.get("/api/market/:symbol", async (req, res) => {
  try {
    const marketData = await readMT4File(`market_data_${req.params.symbol}.txt`);
    const data = {};
    for (const line of marketData.split("\n")) {
      const [key, value] = line.split("=");
      if (key && value) data[key.trim()] = value.trim();
    }
    res.json(data);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Place an order
app.post("/api/order", async (req, res) => {
  // Field validation — prevent empty/garbage from reaching MT4
  const VALID_OPS = ["BUY", "SELL", "BUY_LIMIT", "SELL_LIMIT", "BUY_STOP", "SELL_STOP"];
  const { symbol, operation, lots, price, stop_loss, take_profit } = req.body;

  if (!symbol || typeof symbol !== "string") {
    return res.status(400).json({ error: "Missing or invalid field: symbol" });
  }
  if (!operation || !VALID_OPS.includes(operation)) {
    return res.status(400).json({ error: `Missing or invalid field: operation (must be one of ${VALID_OPS.join(", ")})` });
  }
  if (typeof lots !== "number" || lots <= 0) {
    return res.status(400).json({ error: "Missing or invalid field: lots (must be a positive number)" });
  }
  if (price == null || typeof price !== "number") {
    return res.status(400).json({ error: "Missing or invalid field: price" });
  }
  if (stop_loss == null || typeof stop_loss !== "number") {
    return res.status(400).json({ error: "Missing or invalid field: stop_loss" });
  }
  if (take_profit == null || typeof take_profit !== "number") {
    return res.status(400).json({ error: "Missing or invalid field: take_profit" });
  }

  try {
    const result = await sendMT4Command(
      "order_commands.txt",
      "order_result.txt",
      { action: "PLACE_ORDER", symbol, operation, lots, price, stop_loss, take_profit,
        comment: req.body.comment || "Opened by Claude",
        magic_number: BRIDGE_MAGIC_NUMBER,
        expiry_minutes: req.body.expiry_minutes || 0,
        slippage: req.body.slippage || 3,
        timestamp: Date.now() }
    );
    // Mirror MT4's own success flag in the outer envelope so callers don't
    // need to unwrap a nested object to detect broker-side failures.
    res.json({ success: result.success === true, result });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.get("/api/positions", async (req, res) => {
  try {
    const positionsData = await readMT4File("positions.txt");
    const positions = [];
    let currentPosition = {};
    for (const line of positionsData.split("\n")) {
      if (line === "---") {
        if (Object.keys(currentPosition).length > 0) {
          positions.push(currentPosition);
          currentPosition = {};
        }
      } else if (line.includes("=")) {
        const [key, value] = line.split("=");
        if (key && value) currentPosition[key.trim()] = value.trim();
      }
    }
    if (Object.keys(currentPosition).length > 0) positions.push(currentPosition);
    res.json({ positions });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Close a position
app.post("/api/close", async (req, res) => {
  if (!req.body.ticket) {
    return res.status(400).json({ error: "Missing required field: ticket" });
  }
  try {
    const result = await sendMT4Command(
      "close_commands.txt",
      "close_result.txt",
      { action: "CLOSE_POSITION", ticket: req.body.ticket,
        lots: req.body.lots,   // optional — for partial close
        timestamp: Date.now() }
    );
    res.json({ success: result.success === true, result });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Modify an order's SL/TP (trailing stop / breakeven)
app.post("/api/modify", async (req, res) => {
  const { ticket, stop_loss, take_profit } = req.body;
  if (!ticket) {
    return res.status(400).json({ error: "Missing required field: ticket" });
  }
  if (stop_loss == null || typeof stop_loss !== "number") {
    return res.status(400).json({ error: "Missing or invalid field: stop_loss" });
  }
  if (take_profit == null || typeof take_profit !== "number") {
    return res.status(400).json({ error: "Missing or invalid field: take_profit" });
  }
  try {
    const result = await sendMT4Command(
      "modify_commands.txt",
      "modify_result.txt",
      { action: "MODIFY_ORDER", ticket, stop_loss, take_profit, timestamp: Date.now() }
    );
    res.json({ success: result.success === true, result });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.get("/api/history", async (req, res) => {
  try {
    const days        = req.query.days || 7;
    const historyData = await readMT4File(`history_${days}d.txt`);
    const history     = [];
    let currentTrade  = {};
    for (const line of historyData.split("\n")) {
      if (line === "---") {
        if (Object.keys(currentTrade).length > 0) { history.push(currentTrade); currentTrade = {}; }
      } else if (line.includes("=")) {
        const [key, value] = line.split("=");
        if (key && value) currentTrade[key.trim()] = value.trim();
      }
    }
    if (Object.keys(currentTrade).length > 0) history.push(currentTrade);
    res.json({ history });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.post("/api/backtest", async (req, res) => {
  try {
    const backtestCommand = { action: "RUN_BACKTEST", ...req.body, timestamp: Date.now() };
    await writeMT4File("backtest_commands.txt", JSON.stringify(backtestCommand));
    res.json({ success: true, message: "Backtest command sent to MT4",
               expert: req.body.expert, symbol: req.body.symbol, timeframe: req.body.timeframe });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.get("/api/backtest/results", async (req, res) => {
  try {
    const filename    = req.query.detailed === "true" ? "backtest_results_detailed.txt" : "backtest_results.txt";
    const resultsData = await readMT4File(filename);
    try { res.json(JSON.parse(resultsData)); }
    catch { res.json({ report: resultsData }); }
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

app.get("/api/experts", async (req, res) => {
  try {
    const expertsData = await readMT4File("experts_list.txt");
    const experts     = expertsData.split("\n").filter((l) => l.trim()).map((line) => {
      const parts = line.split("|");
      return { name: parts[0]?.trim(), description: parts[1]?.trim() || "", modified: parts[2]?.trim() || "" };
    });
    res.json({ experts });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// EA Upload — path traversal protection
app.post("/api/ea/upload", async (req, res) => {
  try {
    const { ea_content } = req.body;
    const rawName = String(req.body.ea_name || "").replace(/[^a-zA-Z0-9_-]/g, "");

    if (!rawName) {
      return res.status(400).json({ success: false, error: "Invalid ea_name: must contain only letters, digits, underscores, or hyphens" });
    }
    if (!ea_content) {
      return res.status(400).json({ success: false, error: "Missing ea_content" });
    }

    const expertsDir = await findMT4ExpertsDirectory();
    const eaFilePath = path.resolve(path.join(expertsDir, `${rawName}.mq4`));

    // Verify the resolved path is still inside expertsDir (defense-in-depth)
    if (!eaFilePath.startsWith(path.resolve(expertsDir))) {
      return res.status(400).json({ success: false, error: "Path traversal rejected" });
    }

    await fs.writeFile(eaFilePath, ea_content, "utf-8");
    const stats = await fs.stat(eaFilePath);

    res.json({ success: true, message: "EA uploaded successfully",
               ea_name: rawName, file_path: eaFilePath,
               file_size: stats.size, experts_directory: expertsDir,
               timestamp: new Date().toISOString() });
  } catch (error) {
    console.error("EA Upload Error:", error);
    res.status(500).json({ success: false, error: error.message });
  }
});

app.post("/api/ea/compile", async (req, res) => {
  try {
    const { ea_name } = req.body;
    if (!ea_name) return res.status(400).json({ success: false, error: "Missing ea_name" });

    const expertsDir = await findMT4ExpertsDirectory();
    const eaFilePath = path.join(expertsDir, `${ea_name}.mq4`);

    try { await fs.access(eaFilePath); }
    catch { return res.status(404).json({ success: false, error: `EA file not found: ${ea_name}.mq4`, expected_path: eaFilePath }); }

    console.log(`Starting compilation of ${ea_name}...`);
    const r = await compileEA(eaFilePath);
    res.json({ success: r.success, compiled: r.compiled, ea_name, source_file: eaFilePath,
               ex4_file: r.ex4_path, errors: r.errors, warnings: r.warnings,
               exit_code: r.exit_code, log: r.log, log_file: r.log_file,
               timestamp: new Date().toISOString(),
               message: r.success ? "EA compiled successfully" : `Compilation failed with ${r.errors} error(s)` });
  } catch (error) {
    console.error("EA Compilation Error:", error);
    res.status(500).json({ success: false, error: error.message, ea_name: req.body.ea_name });
  }
});

app.get("/api/ea/list", async (req, res) => {
  try {
    const expertsDir = await findMT4ExpertsDirectory();
    const files      = await fs.readdir(expertsDir);
    const eaFiles    = [];
    for (const file of files) {
      if (file.endsWith(".mq4") || file.endsWith(".ex4")) {
        const stats = await fs.stat(path.join(expertsDir, file));
        eaFiles.push({ name: file, path: path.join(expertsDir, file),
                       size: stats.size, modified: stats.mtime.toISOString(),
                       type: file.endsWith(".mq4") ? "source" : "compiled" });
      }
    }
    res.json({ success: true, experts_directory: expertsDir, files: eaFiles, count: eaFiles.length });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message });
  }
});

app.get("/api/ea/metaeditor", async (req, res) => {
  try {
    const metaEditorPath = await findMetaEditor();
    const expertsDir     = await findMT4ExpertsDirectory();
    res.json({ success: true, metaeditor_path: metaEditorPath,
               experts_directory: expertsDir, mt4_data_path: MT4_DATA_PATH });
  } catch (error) {
    res.status(500).json({ success: false, error: error.message, mt4_data_path: MT4_DATA_PATH });
  }
});

app.get("/api/health", (req, res) => {
  res.json({ status: "ok", timestamp: new Date().toISOString(),
             mt4_path: MT4_FILES_PATH_OVERRIDE || MT4_DATA_PATH,
             features: ["account_info", "market_data", "orders", "positions",
                        "history", "backtesting", "ea_upload", "ea_compilation"] });
});

// ── Start ─────────────────────────────────────────────────────────────────────

app.listen(PORT, "127.0.0.1", () => {
  console.log(`MT4 HTTP Bridge running on http://127.0.0.1:${PORT}`);
  console.log(`MT4 Files path: ${MT4_FILES_PATH_OVERRIDE || MT4_DATA_PATH}`);
  if (!API_KEY) {
    console.warn("WARNING: BRIDGE_API_KEY is not set — running without authentication");
  }
  console.log("Make sure MT4 is running with the MCPBridge Expert Advisor attached to a chart");
});
