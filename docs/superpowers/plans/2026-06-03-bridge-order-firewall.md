# Bridge Order-Firewall Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the MT4 EA the hard risk boundary (reject naked/wrong-sided orders before `OrderSend`) and make the Node bridge deliver complete, one-at-a-time command files.

**Architecture:** Two defense-in-depth layers in the `metatrader-4-mcp` repo. Node (`server.js`) validates and atomically + serially writes command files via a new testable `bridge-core.js` module. The EA (`MCP_Ultimate.mq4`) validates every order command (required protection + side/stop-level) and writes a `FIREWALL_REJECTED` result instead of placing a naked order; its `OnTimer` throttle moves off broker time so emergency commands process when quotes stall.

**Tech Stack:** Node.js ESM (`node --test`, no new deps), MQL4.

**Repo / branch:** `metatrader-4-mcp`, branch `order-firewall-hardening` (off `master` @ `96822ba`). Spec: `docs/superpowers/specs/2026-06-03-bridge-order-firewall-design.md`.

**DEPLOY-GATED:** After all tasks + final review, STOP. No merge to `master`, no push, no EC2 `git pull`/restart/EA-recompile without explicit user approval. The EA firewall is not live until `MCP_Ultimate.mq4` is recompiled on EC2 (MetaEditor F7).

**Conventions:** Commit messages use conventional-commit prefixes, no attribution footer. Run all `git` against the bridge repo with `git -C "C:/Users/mahip/metatrader-4-mcp" …`. Node ≥18 (uses `node:test`).

---

## File Structure

| File | Responsibility | Status |
|---|---|---|
| `windows-server/bridge-core.js` | Pure, testable bridge helpers: `validateOrderRequest`, `writeFileAtomic`, `createKeyedMutex`. No express, no server start. | **Create** |
| `windows-server/bridge-core.test.js` | `node:test` unit tests for the three helpers. | **Create** |
| `windows-server/server.js` | Wire in the helpers: validate `/api/order` via `validateOrderRequest`; serialize + atomically write commands in `sendMT4Command`. | Modify |
| `windows-server/package.json` | Add `"test": "node --test"` script. | Modify |
| `mcp/MCP_Ultimate.mq4` | `WriteOrderResult()` helper; `ValidateOrderCommand()` firewall + call site; B7 `OnTimer` `GetTickCount()` fix. | Modify |

> **Note on naming:** the spec §8 named the Node test file `server.test.js`. The plan places the tested logic in `bridge-core.js` (so it imports without starting the express server, which `server.js` does at top level), and names the test `bridge-core.test.js` accordingly. `node --test` discovers any `*.test.js`.

---

## Task 1: Node — `validateOrderRequest` (TDD)

Pure request-body validator for `/api/order`. Tightens the existing inline checks (server.js:289-309) to also reject non-positive `lots`/`stop_loss`/`take_profit`, and requires `price>0` only for pending operations.

**Files:**
- Create: `windows-server/bridge-core.js`
- Create (test): `windows-server/bridge-core.test.js`

- [ ] **Step 1: Write the failing test**

Create `windows-server/bridge-core.test.js`:

```js
import { test } from "node:test";
import assert from "node:assert/strict";
import { validateOrderRequest } from "./bridge-core.js";

const validPending = {
  symbol: "EURUSD.r", operation: "BUY_LIMIT", lots: 0.1,
  price: 1.1000, stop_loss: 1.0950, take_profit: 1.1100,
};

test("validateOrderRequest accepts a fully-valid pending order", () => {
  assert.deepEqual(validateOrderRequest(validPending), { ok: true });
});

test("validateOrderRequest rejects stop_loss <= 0", () => {
  const r = validateOrderRequest({ ...validPending, stop_loss: 0 });
  assert.equal(r.ok, false);
  assert.match(r.error, /stop_loss/);
});

test("validateOrderRequest rejects take_profit <= 0", () => {
  const r = validateOrderRequest({ ...validPending, take_profit: 0 });
  assert.equal(r.ok, false);
  assert.match(r.error, /take_profit/);
});

test("validateOrderRequest rejects lots <= 0", () => {
  const r = validateOrderRequest({ ...validPending, lots: 0 });
  assert.equal(r.ok, false);
  assert.match(r.error, /lots/);
});

test("validateOrderRequest rejects price <= 0 for a pending order", () => {
  const r = validateOrderRequest({ ...validPending, price: 0 });
  assert.equal(r.ok, false);
  assert.match(r.error, /price/);
});

test("validateOrderRequest allows omitted price for a market order", () => {
  const r = validateOrderRequest({
    symbol: "EURUSD.r", operation: "BUY", lots: 0.1,
    stop_loss: 1.0950, take_profit: 1.1100,
  });
  assert.deepEqual(r, { ok: true });
});

test("validateOrderRequest rejects an unknown operation", () => {
  const r = validateOrderRequest({ ...validPending, operation: "FOO" });
  assert.equal(r.ok, false);
  assert.match(r.error, /operation/);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node --test "C:/Users/mahip/metatrader-4-mcp/windows-server/bridge-core.test.js"`
Expected: FAIL — `Cannot find module './bridge-core.js'` (or `validateOrderRequest is not a function`).

- [ ] **Step 3: Write the minimal implementation**

Create `windows-server/bridge-core.js`:

```js
// Pure, testable helpers for the MT4 HTTP bridge.
// No express, no server start — safe to import from tests.

export const VALID_OPS = ["BUY", "SELL", "BUY_LIMIT", "SELL_LIMIT", "BUY_STOP", "SELL_STOP"];
export const PENDING_OPS = ["BUY_LIMIT", "SELL_LIMIT", "BUY_STOP", "SELL_STOP"];

/**
 * Validate an /api/order request body.
 * Returns { ok: true } or { ok: false, error: "<message>" }.
 * Rejects non-positive lots/stop_loss/take_profit; requires price>0 for pending ops.
 */
export function validateOrderRequest(body) {
  const { symbol, operation, lots, price, stop_loss, take_profit } = body || {};

  if (!symbol || typeof symbol !== "string") {
    return { ok: false, error: "Missing or invalid field: symbol" };
  }
  if (!operation || !VALID_OPS.includes(operation)) {
    return { ok: false, error: `Missing or invalid field: operation (must be one of ${VALID_OPS.join(", ")})` };
  }
  if (typeof lots !== "number" || lots <= 0) {
    return { ok: false, error: "Missing or invalid field: lots (must be a positive number)" };
  }
  if (typeof stop_loss !== "number" || stop_loss <= 0) {
    return { ok: false, error: "Missing or invalid field: stop_loss (must be a positive number)" };
  }
  if (typeof take_profit !== "number" || take_profit <= 0) {
    return { ok: false, error: "Missing or invalid field: take_profit (must be a positive number)" };
  }
  if (PENDING_OPS.includes(operation)) {
    if (typeof price !== "number" || price <= 0) {
      return { ok: false, error: "Missing or invalid field: price (must be > 0 for pending orders)" };
    }
  } else if (price != null && typeof price !== "number") {
    return { ok: false, error: "Invalid field: price" };
  }
  return { ok: true };
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `node --test "C:/Users/mahip/metatrader-4-mcp/windows-server/bridge-core.test.js"`
Expected: PASS — 7 tests passing.

- [ ] **Step 5: Commit**

```bash
git -C "C:/Users/mahip/metatrader-4-mcp" add windows-server/bridge-core.js windows-server/bridge-core.test.js
git -C "C:/Users/mahip/metatrader-4-mcp" commit -m "feat(bridge): validateOrderRequest — reject non-positive lots/SL/TP/price"
```

---

## Task 2: Node — `writeFileAtomic` (TDD)

Atomic file write (tmp + rename) so the EA never reads a half-written command file.

**Files:**
- Modify: `windows-server/bridge-core.js`
- Modify (test): `windows-server/bridge-core.test.js`

- [ ] **Step 1: Write the failing test**

Add to the import block at the top of `windows-server/bridge-core.test.js`:

```js
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { writeFileAtomic } from "./bridge-core.js";
```

Append these tests:

```js
test("writeFileAtomic writes the complete content", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "bridge-atomic-"));
  const fp = path.join(dir, "order_commands.txt");
  const payload = JSON.stringify({ action: "PLACE_ORDER", lots: 0.1 });
  await writeFileAtomic(fp, payload);
  assert.equal(await fs.readFile(fp, "utf-8"), payload);
});

test("writeFileAtomic leaves no .tmp file behind", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "bridge-atomic-"));
  const fp = path.join(dir, "order_commands.txt");
  await writeFileAtomic(fp, "x");
  const leftover = (await fs.readdir(dir)).filter((f) => f.endsWith(".tmp"));
  assert.equal(leftover.length, 0);
});

test("writeFileAtomic overwrites an existing file", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "bridge-atomic-"));
  const fp = path.join(dir, "order_commands.txt");
  await writeFileAtomic(fp, "first");
  await writeFileAtomic(fp, "second");
  assert.equal(await fs.readFile(fp, "utf-8"), "second");
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node --test "C:/Users/mahip/metatrader-4-mcp/windows-server/bridge-core.test.js"`
Expected: FAIL — `writeFileAtomic is not a function`.

- [ ] **Step 3: Write the minimal implementation**

Add to the top of `windows-server/bridge-core.js`:

```js
import fs from "node:fs/promises";
import { randomUUID } from "node:crypto";
```

Add the function:

```js
/**
 * Write `content` to `filePath` atomically: write a unique temp file, then
 * rename it onto the target. The reader (the EA) therefore sees either the old
 * file or the complete new file — never a partial write.
 * On a transient rename failure (e.g. the EA holds the target open on Windows),
 * retry once after a short delay, then surface the error.
 */
export async function writeFileAtomic(filePath, content, { retries = 1, retryDelayMs = 50 } = {}) {
  const tmpPath = `${filePath}.${randomUUID()}.tmp`;
  await fs.writeFile(tmpPath, content, "utf-8");
  for (let attempt = 0; ; attempt++) {
    try {
      await fs.rename(tmpPath, filePath);
      return;
    } catch (err) {
      if (attempt >= retries) {
        try { await fs.unlink(tmpPath); } catch { /* best-effort cleanup */ }
        throw err;
      }
      await new Promise((r) => setTimeout(r, retryDelayMs));
    }
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `node --test "C:/Users/mahip/metatrader-4-mcp/windows-server/bridge-core.test.js"`
Expected: PASS — 10 tests passing.

- [ ] **Step 5: Commit**

```bash
git -C "C:/Users/mahip/metatrader-4-mcp" add windows-server/bridge-core.js windows-server/bridge-core.test.js
git -C "C:/Users/mahip/metatrader-4-mcp" commit -m "feat(bridge): writeFileAtomic — tmp+rename so EA never reads a torn command file"
```

---

## Task 3: Node — `createKeyedMutex` (TDD)

Per-key promise chain that serializes async tasks sharing a key, while allowing different keys to run concurrently. Used to serialize the full write+poll round-trip per command file.

**Files:**
- Modify: `windows-server/bridge-core.js`
- Modify (test): `windows-server/bridge-core.test.js`

- [ ] **Step 1: Write the failing test**

Add to the import block at the top of `windows-server/bridge-core.test.js`:

```js
import { createKeyedMutex } from "./bridge-core.js";
```

Add a helper near the top (after imports) and the tests:

```js
const delay = (ms) => new Promise((r) => setTimeout(r, ms));

test("createKeyedMutex serializes tasks sharing a key", async () => {
  const mutex = createKeyedMutex();
  const events = [];
  const a = mutex("order", async () => { events.push("A-start"); await delay(25); events.push("A-end"); });
  const b = mutex("order", async () => { events.push("B-start"); await delay(5); events.push("B-end"); });
  await Promise.all([a, b]);
  assert.deepEqual(events, ["A-start", "A-end", "B-start", "B-end"]);
});

test("createKeyedMutex runs different keys concurrently", async () => {
  const mutex = createKeyedMutex();
  const events = [];
  const a = mutex("order", async () => { events.push("A-start"); await delay(25); events.push("A-end"); });
  const b = mutex("close", async () => { events.push("B-start"); await delay(5); events.push("B-end"); });
  await Promise.all([a, b]);
  // close (key B) finishes before order (key A) because they do not block each other
  assert.deepEqual(events, ["A-start", "B-start", "B-end", "A-end"]);
});

test("createKeyedMutex returns the task value and isolates rejection", async () => {
  const mutex = createKeyedMutex();
  await assert.rejects(() => mutex("k", async () => { throw new Error("boom"); }), /boom/);
  // a rejecting task must not poison the chain — the next task still runs
  const v = await mutex("k", async () => 42);
  assert.equal(v, 42);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `node --test "C:/Users/mahip/metatrader-4-mcp/windows-server/bridge-core.test.js"`
Expected: FAIL — `createKeyedMutex is not a function`.

- [ ] **Step 3: Write the minimal implementation**

Add to `windows-server/bridge-core.js`:

```js
/**
 * Create a keyed async mutex. `run(key, fn)` runs `fn` only after every prior
 * task with the same key has settled, and resolves/rejects with fn's outcome.
 * Different keys never block each other. A rejecting task does not poison the
 * chain (the stored tail swallows errors).
 */
export function createKeyedMutex() {
  const tails = new Map();
  return function run(key, fn) {
    const prev = tails.get(key) || Promise.resolve();
    const result = prev.then(() => fn(), () => fn());
    // store a non-rejecting tail so the chain survives a failed task
    tails.set(key, result.then(() => {}, () => {}));
    return result;
  };
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `node --test "C:/Users/mahip/metatrader-4-mcp/windows-server/bridge-core.test.js"`
Expected: PASS — 13 tests passing.

- [ ] **Step 5: Commit**

```bash
git -C "C:/Users/mahip/metatrader-4-mcp" add windows-server/bridge-core.js windows-server/bridge-core.test.js
git -C "C:/Users/mahip/metatrader-4-mcp" commit -m "feat(bridge): createKeyedMutex — serialize per-command-file send/poll"
```

---

## Task 4: Node — wire `bridge-core` into `server.js`

Replace the inline `/api/order` validation with `validateOrderRequest`; route command writes through `writeFileAtomic` and the keyed mutex inside `sendMT4Command`; add the `test` npm script.

**Files:**
- Modify: `windows-server/server.js` (imports near top; `sendMT4Command` ~139-183; `/api/order` validation ~288-309)
- Modify: `windows-server/package.json:7-9`

- [ ] **Step 1: Add the import and a module-level mutex**

In `windows-server/server.js`, add after the existing `import { randomUUID } from "crypto";` (line 7):

```js
import { validateOrderRequest, writeFileAtomic, createKeyedMutex } from "./bridge-core.js";
```

After the helpers block (immediately after `writeMT4File`, which ends at line 106), add:

```js
// Serializes the full send+poll round-trip per command file so two concurrent
// same-type requests can't clobber an unconsumed command (the round-trip already
// waits for the EA to consume the command before returning).
const commandMutex = createKeyedMutex();

// Atomic command write — EA never observes a partial command file.
async function writeMT4FileAtomic(filename, content) {
  const dir = await getMT4FilesDir();
  await fs.mkdir(dir, { recursive: true });
  await writeFileAtomic(path.join(dir, filename), content);
}
```

- [ ] **Step 2: Serialize + atomically write inside `sendMT4Command`**

Replace the body of `sendMT4Command` (server.js:139-183). Wrap the existing logic in `commandMutex(commandFile, …)` and switch the command write to `writeMT4FileAtomic`. The poll/timeout/cleanup logic is unchanged — only the wrapper and the write call change:

```js
async function sendMT4Command(commandFile, resultFile, command) {
  return commandMutex(commandFile, async () => {
    const id = randomUUID();
    command.request_id = id;

    await writeMT4FileAtomic(commandFile, JSON.stringify(command));

    const deadline = Date.now() + MT4_RESULT_TIMEOUT_MS;
    while (Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, MT4_RESULT_POLL_MS));
      try {
        const raw    = await readMT4File(resultFile);
        const result = JSON.parse(raw);
        if (result.request_id === id) {
          await deleteMT4File(resultFile);
          return result;
        }
      } catch {
        // File not yet written or not yet updated — keep polling
      }
    }

    // Timeout cleanup — delete the command file so an unread command is cancelled.
    await deleteMT4File(commandFile);

    // One last result check (EA may have processed it in the final instant).
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
  });
}
```

- [ ] **Step 3: Replace the inline `/api/order` validation**

In the `app.post("/api/order", …)` handler, replace the block from the `const VALID_OPS = …` line through the final `take_profit` check (server.js:289-309) with:

```js
  const v = validateOrderRequest(req.body);
  if (!v.ok) {
    return res.status(400).json({ error: v.error });
  }
  const { symbol, operation, lots, price, stop_loss, take_profit } = req.body;
```

(The downstream `sendMT4Command(...)` call that builds the command object stays exactly as-is, server.js:311-324.)

- [ ] **Step 4: Add the npm test script**

In `windows-server/package.json`, change the `scripts` block (lines 7-9) to:

```json
  "scripts": {
    "start": "node server.js",
    "test": "node --test"
  },
```

- [ ] **Step 5: Run the full Node test suite**

Run: `node --test "C:/Users/mahip/metatrader-4-mcp/windows-server/bridge-core.test.js"`
Expected: PASS — all 13 tests still pass (the helpers are unchanged; this confirms the import path and that nothing broke).

- [ ] **Step 6: Sanity-check that `server.js` parses**

Run: `node --check "C:/Users/mahip/metatrader-4-mcp/windows-server/server.js"`
Expected: no output, exit 0 (syntax OK). *(Do not run `node server.js` — it would try to bind the port / locate MT4.)*

- [ ] **Step 7: Commit**

```bash
git -C "C:/Users/mahip/metatrader-4-mcp" add windows-server/server.js windows-server/package.json
git -C "C:/Users/mahip/metatrader-4-mcp" commit -m "feat(bridge): atomic+serialized command writes, validateOrderRequest in /api/order"
```

---

## Task 5: EA — extract `WriteOrderResult()` helper (refactor, behavior-preserving)

DRY the four duplicated `order_result.txt` write blocks into one helper, so the firewall (Task 6) reuses it.

> **No automated test:** MQL4 cannot be unit-tested without an MT4 terminal. Verification = careful review (this task is behavior-preserving — identical bytes written) + the deploy-time manual test in the spec runbook §10. Do NOT attempt to compile locally.

**Files:**
- Modify: `mcp/MCP_Ultimate.mq4`

- [ ] **Step 1: Add the helper**

Add this function immediately above `void ExecuteOrderCommand(string jsonCommand)` (currently MCP_Ultimate.mq4:865):

```cpp
//+------------------------------------------------------------------+
//| Write an order-result JSON to order_result.txt                  |
//+------------------------------------------------------------------+
void WriteOrderResult(string json)
{
   int fh = FileOpen("order_result.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (fh != INVALID_HANDLE) { FileWrite(fh, json); FileClose(fh); }
}
```

- [ ] **Step 2: Replace the four duplicated write blocks**

In `ExecuteOrderCommand`, replace each of these blocks with a single `WriteOrderResult(...)` call (preserving the variable written):

1. AutoTrading-disabled block (MCP_Ultimate.mq4:888-889):
   ```cpp
   int fh0 = FileOpen("order_result.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (fh0 != INVALID_HANDLE) { FileWrite(fh0, json); FileClose(fh0); }
   ```
   →
   ```cpp
   WriteOrderResult(json);
   ```

2. Invalid-operation block (MCP_Ultimate.mq4:912-913):
   ```cpp
   int fh1 = FileOpen("order_result.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (fh1 != INVALID_HANDLE) { FileWrite(fh1, json); FileClose(fh1); }
   ```
   →
   ```cpp
   WriteOrderResult(json);
   ```

3. Duplicate-suppression block (MCP_Ultimate.mq4:942-943):
   ```cpp
   int fhd = FileOpen("order_result.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (fhd != INVALID_HANDLE) { FileWrite(fhd, dupJson); FileClose(fhd); }
   ```
   →
   ```cpp
   WriteOrderResult(dupJson);
   ```

4. Final success/fail block (MCP_Ultimate.mq4:976-977):
   ```cpp
   int fh = FileOpen("order_result.txt", FILE_WRITE | FILE_TXT | FILE_ANSI);
   if (fh != INVALID_HANDLE) { FileWrite(fh, json); FileClose(fh); }
   ```
   →
   ```cpp
   WriteOrderResult(json);
   ```

- [ ] **Step 3: Review checklist (no compile)**

Confirm: helper added once; all four call sites replaced; the variable name passed matches what each block wrote (`json`, `json`, `dupJson`, `json`); no other `FileOpen("order_result.txt"…)` remains in `ExecuteOrderCommand` (grep `order_result.txt` — only the helper should open it for writing).

- [ ] **Step 4: Commit**

```bash
git -C "C:/Users/mahip/metatrader-4-mcp" add mcp/MCP_Ultimate.mq4
git -C "C:/Users/mahip/metatrader-4-mcp" commit -m "refactor(ea): extract WriteOrderResult() — DRY the order_result writes"
```

---

## Task 6: EA — `ValidateOrderCommand()` firewall + call site (B2 / B3-at-EA)

The hard risk boundary: reject naked / wrong-sided / wrong-distance orders before `OrderSend`.

> **No automated test** (MQL4). Verification = review checklist below + deploy-time manual reject-test (spec §10). Do NOT compile locally.

**Files:**
- Modify: `mcp/MCP_Ultimate.mq4`

- [ ] **Step 1: Add the validator function**

Add immediately above `void ExecuteOrderCommand(string jsonCommand)` (next to `WriteOrderResult`):

```cpp
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
   if (allowUnprotected) return "";

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
```

- [ ] **Step 2: Insert the call site**

In `ExecuteOrderCommand`, immediately **after** the invalid-operation guard (the block that ends at MCP_Ultimate.mq4:915, i.e. right before the `// 4. Normalise lot size` comment at line 917), insert:

```cpp
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
```

- [ ] **Step 3: Review checklist (no compile)**

- The call site is **after** `orderType` is assigned (lines 900-905) and after `RefreshRates()` (line 894), and **before** lot normalization (line 917) — so `lots` is the raw parsed value and `price` is the live bid/ask for market orders.
- `error` code is `9001` (outside MT4 retcodes and outside the agent transient set `{128,135,136,137,138,146}`).
- The reject JSON shape mirrors the existing OrderSend-failed JSON (line 971): `success/error/description/symbol/operation/request_id`.
- `allow_unprotected` parsed via `ExtractJsonValue(...) == "true"`.
- Mentally trace: a `stop_loss:0` BUY_LIMIT → tier-1 returns `"stop_loss<=0"` → `WriteOrderResult` → `return` (no `OrderSend`). A valid order → `vErr == ""` → falls through to lot-normalization and `OrderSend` unchanged.

- [ ] **Step 4: Commit**

```bash
git -C "C:/Users/mahip/metatrader-4-mcp" add mcp/MCP_Ultimate.mq4
git -C "C:/Users/mahip/metatrader-4-mcp" commit -m "feat(ea): ValidateOrderCommand risk firewall — reject naked/wrong-sided orders"
```

---

## Task 7: EA — B7 `OnTimer` `GetTickCount()` fix

Move command-processing throttle off broker time so emergency CLOSE/MODIFY still process when quotes stall.

> **No automated test** (MQL4). Verification = review + deploy-time quiet-symbol check (spec §10). Do NOT compile locally.

**Files:**
- Modify: `mcp/MCP_Ultimate.mq4:37` (global), `:154` and `:181` (OnTimer)

- [ ] **Step 1: Retype the throttle global**

Change MCP_Ultimate.mq4:37 from:

```cpp
datetime lastUpdate = 0;
```
to:
```cpp
uint lastUpdateTicks = 0;   // GetTickCount() ms — wall-clock throttle (not broker time)
```

- [ ] **Step 2: Update the OnTimer gate**

Change MCP_Ultimate.mq4:154 from:

```cpp
   if (TimeCurrent() - lastUpdate >= UpdateInterval / 1000)
```
to:
```cpp
   if (GetTickCount() - lastUpdateTicks >= (uint)UpdateInterval)
```

- [ ] **Step 3: Update the OnTimer bookkeeping**

Change MCP_Ultimate.mq4:181 from:

```cpp
      lastUpdate = TimeCurrent();
```
to:
```cpp
      lastUpdateTicks = GetTickCount();
```

- [ ] **Step 4: Review checklist (no compile)**

- Grep `lastUpdate` in `mcp/MCP_Ultimate.mq4`: only the renamed `lastUpdateTicks` should remain (3 sites: decl line 37, gate, bookkeeping). Confirm no other reference to the old `lastUpdate` exists.
- `UpdateInterval` is in ms (declared `input int UpdateInterval = 1000;` at line 15); the new comparison uses it directly (no `/1000`).
- Unsigned subtraction `GetTickCount() - lastUpdateTicks` correctly handles the ~49.7-day wrap; no special-casing needed.

- [ ] **Step 5: Commit**

```bash
git -C "C:/Users/mahip/metatrader-4-mcp" add mcp/MCP_Ultimate.mq4
git -C "C:/Users/mahip/metatrader-4-mcp" commit -m "fix(ea): OnTimer throttle uses GetTickCount() so emergency commands process when quotes stall"
```

---

## Task 8: Final verification + DEPLOY GATE

**Files:** none (verification only).

- [ ] **Step 1: Full Node test suite green**

Run: `node --test "C:/Users/mahip/metatrader-4-mcp/windows-server/bridge-core.test.js"`
Expected: PASS — 13 tests, 0 failures.

- [ ] **Step 2: `server.js` syntax check**

Run: `node --check "C:/Users/mahip/metatrader-4-mcp/windows-server/server.js"`
Expected: exit 0.

- [ ] **Step 3: Branch-diff sanity**

Run: `git -C "C:/Users/mahip/metatrader-4-mcp" diff --stat master...HEAD`
Expected: only these files changed — `docs/superpowers/specs/2026-06-03-bridge-order-firewall-design.md`, `docs/superpowers/plans/2026-06-03-bridge-order-firewall.md`, `windows-server/bridge-core.js`, `windows-server/bridge-core.test.js`, `windows-server/server.js`, `windows-server/package.json`, `mcp/MCP_Ultimate.mq4`. No agent-repo files (this is a different repo), no `src/index.ts`, no ZMQ files, no `start_*.bat`.

- [ ] **Step 4: STOP — present for deploy approval**

Do NOT merge to `master`, push, or touch EC2. Present the branch + diff summary + the spec §10 runbook (restart Node, **recompile `MCP_Ultimate.mq4` in MetaEditor F7**, run the manual reject-test) and wait for explicit user approval.

---

## Self-Review

**1. Spec coverage:**
- §4 EA firewall (tier-1 + tier-2 + override + reject contract `9001`) → Task 6. ✓
- §4.5 `WriteOrderResult` DRY helper → Task 5. ✓
- §5 B7 `GetTickCount` fix → Task 7. ✓
- §6.1 `writeMT4FileAtomic` → Task 2 (`writeFileAtomic`) + Task 4 (wrapper). ✓
- §6.2 per-file mutex → Task 3 + Task 4. ✓
- §6.3 tighten `/api/order` (reject ≤0; price>0 for pendings only) → Task 1 + Task 4. ✓
- §9 testing (validation rejects/accepts, atomic completeness, mutex serialization) → Tasks 1-3 tests. ✓
- §10 deploy gate → Task 8. ✓
- Out-of-scope (B5/B6-EA/B4/B8/B9, agent repo) → not touched; Task 8 branch-diff enforces. ✓

**2. Placeholder scan:** No TBD/TODO; every code step has complete code; EA "no automated test" steps give concrete review checklists rather than vague instructions. ✓

**3. Type consistency:** `validateOrderRequest` returns `{ok}`/`{ok,error}` used identically in Task 4. `writeFileAtomic(filePath, content, opts)` (Task 2) wrapped by `writeMT4FileAtomic(filename, content)` (Task 4). `createKeyedMutex()` → `run(key, fn)` used as `commandMutex(commandFile, fn)` (Task 4). EA `ValidateOrderCommand(symbol, orderType, lots, entry, stopLoss, takeProfit, allowUnprotected)` signature matches its call site (Task 6) — note `price` is passed as the `entry` argument. `WriteOrderResult(json)` defined Task 5, used Tasks 5 & 6. Consistent. ✓
