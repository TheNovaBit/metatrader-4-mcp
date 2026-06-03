# Bridge Order-Firewall Hardening — Design Spec

**Date:** 2026-06-03
**Repo:** `metatrader-4-mcp` (bridge/EA repo — separate from the agent repo `Claude---MT4`)
**Branch:** `order-firewall-hardening` (off `master` @ `96822ba`)
**Status:** Design approved; DEPLOY-GATED (EA recompile on EC2 required before the firewall is live; no EC2/master change without explicit user approval).

---

## 1. Motivation

An external quant review of the live trading stack (verified line-by-line against the code, 2026-06-03) found the most dangerous live-money weakness in the bridge:

- **B2 (naked-order chain) — CRITICAL.** `MCP_Ultimate.mq4` parses an order command and calls `OrderSend(... stopLoss, takeProfit ...)` (MCP_Ultimate.mq4:959) with **no validation** that those are non-zero. A missing/zero `stop_loss`/`take_profit` becomes `0.0` (via `StringToDouble("")`) and MT4 accepts it — an **unprotected order with no stop**. Separately, missing `lots` → `0` is silently normalized **up** to broker `minLot` (MCP_Ultimate.mq4:923). The realistic trigger is a torn read of a half-written command file (the agent itself always sends valid values).
- **B2-server.** Node writes command JSON directly to the final filename (`writeMT4File`, server.js:101-105) — non-atomic, so the EA can read a partial file mid-write.
- **B1 (concurrent clobber).** All commands of a type share one fixed filename (`order_commands.txt` etc.); two concurrent same-type writes overwrite each other (no queue/mutex).
- **B3-at-the-EA.** The TypeScript MCP `place_order` path defaults `price`/`stop_loss`/`take_profit` to `0`. Making the EA the validation boundary neutralizes that path regardless of how the command arrives.
- **B7 (timer gate).** `OnTimer` throttles command processing on `TimeCurrent()` (MCP_Ultimate.mq4:154), which stalls when no quotes arrive — emergency `CLOSE`/`MODIFY` can be blocked.

The quant's central prescription: **make the EA the hard risk boundary, not just an executor; make the transport deliver intact, complete, one-at-a-time commands.** This spec implements exactly that.

---

## 2. Scope & non-goals

**In scope (this spec):**
- EA order-validation firewall (tier-1 required protection + tier-2 side/stop-level) before `OrderSend`.
- EA `OnTimer` throttle fix (B7).
- Node: atomic command writes (tmp + rename), per-command-file serialization (mutex), and tightening `/api/order` to reject `≤0`.
- Node unit tests (`node --test`, no new dependencies).

**Out of scope (deferred, tracked elsewhere):**
- **B5** (export `MagicNumber` in `positions.txt`) and **B6-EA** (atomic status-file writes) → belong with the agent-side gap-#2 position-reconciliation work.
- **B4** (mandatory `BRIDGE_API_KEY`; `src/index.ts` missing `x-api-key`) and **B8/B9** (ZMQ magic/port mismatch + `tcp://*` bind) → separate hardening passes.
- **No change to the agent repo (`Claude---MT4`).** The agent already sends valid orders (`mt4_client.py:199-224` always sends `BUY_LIMIT`/`SELL_LIMIT` with `lots>0, price>0, sl>0, tp>0`) and already routes a `success:false` result through its existing order-failure/retry path — a firewall reject is simply a cleaner failure it already handles.

---

## 3. Architecture

Two layers, defense in depth, entirely within `metatrader-4-mcp`:

```
agent / Telegram / MCP
        │  POST /api/order
        ▼
windows-server/server.js
   ├── tightened validation  (reject ≤0 at the door — B1/B3 defense-in-depth)
   ├── per-file mutex         (serialize full send+wait — closes B1 clobber)
   └── writeMT4FileAtomic     (tmp + rename — closes B2-server torn read)
        │  complete, one-at-a-time command file
        ▼
mcp/MCP_Ultimate.mq4
   ├── ValidateOrderCommand   (tier-1 + tier-2 — closes B2-EA / B3-at-EA)  ← the hard boundary
   └── OnTimer GetTickCount   (B7 — emergency commands process when quotes stall)
        │
        ▼
     OrderSend  (only reached by a fully-protected, correctly-sided order)
```

---

## 4. EA firewall — `ValidateOrderCommand()`

New function called inside `ExecuteOrderCommand` (MCP_Ultimate.mq4:865) **after** the existing AutoTrading (line 884) and invalid-operation (line 907) checks, and **before** lot-normalization (line 923) and `OrderSend` (line 959). On any failure it writes a reject result and returns without sending.

The order-direction is derived from `operation`:
- **Long:** `BUY`, `BUY_LIMIT`, `BUY_STOP`
- **Short:** `SELL`, `SELL_LIMIT`, `SELL_STOP`
- **Pending:** `*_LIMIT`, `*_STOP`. **Market:** `BUY`, `SELL`.
- **entry** = `price` for pendings; `MarketInfo(symbol, MODE_ASK)` (long) / `MODE_BID` (short) for market orders.

### 4.1 Override
If the command contains `allow_unprotected:true` (string match via `ExtractJsonValue`), **all of tier-1 and tier-2 are bypassed**. The agent never sets this field; it exists only for rare manual/diagnostic use.

### 4.2 Tier 1 — required protection (checked on the raw parsed values, before lot-normalization)
Reject if **any** of:
- `lots <= 0` — checked **before** the `MathMax(minLot, …)` bump, so a missing/0 lots is a hard reject, never silently sized to `minLot`.
- `stop_loss <= 0`
- `take_profit <= 0`
- `price <= 0` **and** operation is a pending type (`*_LIMIT`/`*_STOP`). (Market orders are exempt — the EA fills `price` from `MarketInfo`.)

### 4.3 Tier 2 — side & distance correctness (call `RefreshRates()` first)
Let `point = MarketInfo(symbol, MODE_POINT)`, `stopLevel = MarketInfo(symbol, MODE_STOPLEVEL) * point`, `Ask = MarketInfo(symbol, MODE_ASK)`, `Bid = MarketInfo(symbol, MODE_BID)`.

**SL/TP side relative to entry:**
- Long: require `stop_loss < entry < take_profit`.
- Short: require `take_profit < entry < stop_loss`.

**SL/TP distance from entry:**
- Long: `(entry - stop_loss) >= stopLevel` AND `(take_profit - entry) >= stopLevel`.
- Short: `(stop_loss - entry) >= stopLevel` AND `(entry - take_profit) >= stopLevel`.

**Pending entry side vs market (pendings only):**
- `BUY_LIMIT`: `entry < Ask` AND `(Ask - entry) >= stopLevel`
- `SELL_LIMIT`: `entry > Bid` AND `(entry - Bid) >= stopLevel`
- `BUY_STOP`: `entry > Ask` AND `(entry - Ask) >= stopLevel`
- `SELL_STOP`: `entry < Bid` AND `(Bid - entry) >= stopLevel`

If `stopLevel == 0` (broker reports no minimum), the distance checks are satisfied trivially; the side checks still apply.

### 4.4 Reject contract
On any tier-1/tier-2 failure, write to `order_result.txt` (via the new `WriteOrderResult` helper) and return **without** calling `OrderSend`:

```json
{"success":false,"error":9001,"description":"FIREWALL_REJECTED: <reason>","symbol":"<sym>","operation":"<op>","request_id":"<id>"}
```

- `<reason>` is a short human string naming the failed check (e.g. `"stop_loss<=0"`, `"BUY_LIMIT entry>=Ask"`, `"SL within stopLevel"`).
- Error code **`9001`** is deliberately outside MT4's real retcode space **and** outside the agent's transient-retry set `{128,135,136,137,138,146}`. The agent's `_classify_order_outcome` therefore classifies it `REJECT_PERMANENT` → **no retry** (correct: a malformed command will not fix itself on retry). With the atomic-write fix in place, a malformed command means the caller genuinely sent bad data, so permanent rejection is the right behavior.
- Shape mirrors the existing `OrderSend`-failed JSON (MCP_Ultimate.mq4:971) so the agent's result parser already handles it with no change.

### 4.5 `WriteOrderResult(string json)` helper (DRY)
Extract the repeated `FileOpen("order_result.txt", FILE_WRITE|FILE_TXT|FILE_ANSI)` / `FileWrite` / `FileClose` blocks (currently duplicated at MCP_Ultimate.mq4:888, 912, 942, 976) into one helper. All order-result writes (success, broker-fail, duplicate, and the new firewall rejects) go through it.

---

## 5. EA — B7 timer-gate fix

In `OnTimer` (MCP_Ultimate.mq4:152-183), replace the `TimeCurrent()`-based throttle with `GetTickCount()` (wall-clock milliseconds, always advances regardless of quote flow):

- Track `lastUpdate` as a `uint` tick count (`GetTickCount()`), not a `datetime`.
- Gate: `if (GetTickCount() - lastUpdateTicks >= (uint)UpdateInterval)` (UpdateInterval is already in ms).
- Update `lastUpdateTicks = GetTickCount()` at the end of the processed block.

`GetTickCount()` wraps roughly every ~49.7 days; the unsigned subtraction handles wrap correctly, so no special-casing is needed for an always-on EA. This ensures `ProcessCloseCommands()` / `ProcessModifyCommands()` keep firing when a symbol goes quiet (weekend/illiquid), so emergency exits are not blocked on broker time advancing.

---

## 6. Node — atomic write + mutex + tighter validation (`server.js`)

### 6.1 `writeMT4FileAtomic(filename, content)`
New helper. Writes to `<dir>/<filename>.<randomUUID()>.tmp`, then `fs.rename` onto the final `<dir>/<filename>`. On a rare `EPERM`/`EEXIST` (EA holds the file open at that instant), retry once after a short delay; if still failing, surface the error to the caller. Command-file writes in `sendMT4Command` (server.js:143) switch to this helper; the EA therefore only ever observes a complete file (closes B2-server). `writeMT4File` may remain for non-command writes (e.g. backtest), or be replaced — implementation detail for the plan.

### 6.2 Per-command-file mutex
A minimal promise-chain keyed by the command filename serializes the **entire** `sendMT4Command` (write **and** result-poll), not just the write. Because the round-trip already waits for the EA to echo the `request_id` and then deletes the result file before returning, serializing it guarantees a 2nd same-type request is not written until the 1st command has been fully consumed — so it cannot clobber an unconsumed command (closes B1). Distinct command types (`order_`/`close_`/`modify_`) keep independent chains and so still run concurrently with respect to each other.

### 6.3 Tighten `/api/order` validation
Change the `lots`/`price`/`stop_loss`/`take_profit` checks (server.js:298-309) from "present & numeric" to also reject non-positive values:
- `lots`: must be `> 0` (already enforced).
- `stop_loss`: must be `> 0` (currently `0` passes — tighten).
- `take_profit`: must be `> 0` (currently `0` passes — tighten).
- `price`: must be `> 0` for pending operations (`*_LIMIT`/`*_STOP`); for market `BUY`/`SELL`, `price` may be `0`/omitted.

This is defense-in-depth: bad commands die at the door before reaching the EA. The EA firewall remains the authoritative boundary (it also covers the TS-MCP and any direct-file-write paths).

---

## 7. Error handling & data flow

```
agent → POST /api/order
  → Node: reject ≤0 (400) ──────────────► agent failure path (existing)
  → Node: mutex → writeMT4FileAtomic
  → EA: reads complete file
       → ValidateOrderCommand fails → FIREWALL_REJECTED result ─► agent REJECT_PERMANENT (no retry, logged)
       → passes → OrderSend → success/broker-fail result ───────► agent existing handling
```

Every path writes a `request_id`-stamped result the agent already knows how to consume. No naked order can be placed through any path once the EA is recompiled. **No agent code change.**

---

## 8. Files touched

| File | Change |
|---|---|
| `mcp/MCP_Ultimate.mq4` | Add `ValidateOrderCommand()` (tier-1+2) called in `ExecuteOrderCommand`; add `WriteOrderResult()` helper; B7 `OnTimer` `GetTickCount()` fix. |
| `windows-server/server.js` | Add `writeMT4FileAtomic()`; per-file mutex around `sendMT4Command`; tighten `/api/order` (reject ≤0); extract pure `validateOrderRequest(body)`. |
| `windows-server/server.test.js` | **New.** `node --test`: validation rejects/accepts, atomic write completeness, mutex serialization. |
| `windows-server/package.json` | Add `"test": "node --test"` script. |

---

## 9. Testing

**Node (`node --test`, built-in, no new deps):**
- `validateOrderRequest(body)` (extracted pure function): rejects `stop_loss=0`, `take_profit=0`, `lots=0`, `price=0` for a pending op; accepts a fully-valid pending order; accepts `price=0` for a market op.
- `writeMT4FileAtomic`: after the call the target file contains the exact content and no `.tmp` file remains in the directory.
- Mutex: two concurrent `sendMT4Command` calls on the same command file do not interleave (the 2nd write begins only after the 1st resolves) — verified with a stubbed file layer / fake timers.

**EA (`MCP_Ultimate.mq4` — not locally unit-testable; MQL4 needs an MT4 terminal):**
- The diff gets human code review.
- Deploy-time manual reject-test (documented in §10): with the EA recompiled on EC2, push a `stop_loss:0` order via the bridge → confirm `order_result.txt` = `FIREWALL_REJECTED` and **no** ticket opens; then push a valid order → confirm it fills normally; then (quiet-symbol check) confirm a `CLOSE` command processes when the symbol has no recent ticks.

---

## 10. Deploy runbook (gated — requires explicit user approval)

1. On branch `order-firewall-hardening`: commit Node + EA + tests; run `node --test` green; push.
2. **STOP — present for user approval.** No EC2/master action until approved.
3. On approval: merge to `master`, push.
4. EC2 (`C:\Users\Administrator\metatrader-4-mcp`): `git pull`.
5. Restart the Node bridge (`server.js`).
6. **Recompile `MCP_Ultimate.mq4` in MetaEditor (F7)** and confirm the EA reloaded on its chart. *Until recompiled, the firewall is not live.*
7. Run the manual reject-test (§9). Confirm valid orders still fill.

---

## 11. Risks & mitigations

- **False reject of a legitimate order (tier-2 too strict).** Mitigated: the agent's ATR-based SL/TP distances are normally well beyond `stopLevel`; a reject yields a clear `FIREWALL_REJECTED: <reason>` (logged) rather than a silent broker error 130. If a real symbol's `stopLevel` proves tight, the reason string makes it diagnosable.
- **`fs.rename` EPERM on Windows when the EA holds the file open.** Mitigated by the mutex (we only write when the prior command is consumed, so the target is normally absent) plus a single short retry.
- **EA not recompiled after deploy.** The firewall lives in `.ex4`; the runbook makes recompile an explicit, called-out step, and the manual reject-test verifies it before trusting it.
- **`GetTickCount()` wrap (~49.7 days).** Unsigned subtraction handles wrap; no special-casing needed.
- **Agent classifying `9001` unexpectedly.** Mitigated: `9001` is outside the transient set and the agent's unknown→PERMANENT fail-safe; the result shape matches the existing `OrderSend`-failed JSON the agent already parses.
