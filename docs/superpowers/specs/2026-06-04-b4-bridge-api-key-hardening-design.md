# B4 — Bridge API-Key Hardening — Design

**Date:** 2026-06-04
**Repo:** `metatrader-4-mcp` (branch `api-key-hardening`, off `master 4dfdd06`)
**Status:** Approved — proceeding to implementation plan.
**Deploy:** Restart the Node bridge. No EA recompile, no swing-agent change.

---

## Problem

The MT4 HTTP bridge (`windows-server/server.js`) authenticates requests with a
shared secret in the `X-Api-Key` header — but **only when `BRIDGE_API_KEY` is
non-empty**. The current middleware:

```js
const API_KEY = process.env.BRIDGE_API_KEY || "";
app.use((req, res, next) => {
  if (API_KEY && req.headers["x-api-key"] !== API_KEY) {
    return res.status(401).json({ error: "Unauthorized" });
  }
  next();
});
```

When `BRIDGE_API_KEY` is unset, `API_KEY === ""` is falsy, the guard
short-circuits, and **every request is accepted** — a live-money order bridge
running wide-open. Startup only emits a `console.warn`; the process still runs.

This is a **silent-bypass footgun**: a future environment change that clears the
variable would silently drop authentication with no hard failure.

Separately, the MCP server client (`src/index.ts`) and the two dev diagnostic
scripts (`test-connection.js`, `test-ea-sync.js`) send **no** `x-api-key`
header, so they would 401 against a key-enforcing bridge.

### Current EC2 state (confirmed)

`BRIDGE_API_KEY` is a **Windows system environment variable on EC2**, inherited
by both the Node bridge process and the Python trading agent. Therefore:

- The bridge **already enforces** auth today (`API_KEY` is non-empty).
- The live Python agent **already authenticates** — `mt4_client.py:17` sets
  `_BRIDGE_HEADERS = {"x-api-key": os.environ.get("BRIDGE_API_KEY", "")}` and
  sends it on every order/modify/close/health call.

So this change is a **pure safety-net**. On deploy the bridge behaves exactly as
it does now (`mode: "enforce"`); the value is closing the *future* footgun.

### Scope boundary

The bridge binds `127.0.0.1` only (`server.js` `app.listen(PORT, "127.0.0.1")`)
— this is **defense-in-depth on a loopback service, not a remote-exploit fix**.
An attacker who can reach loopback already has local code execution and could
read the env var directly; therefore a constant-time key comparison
(`crypto.timingSafeEqual`) adds no real protection here and is **out of scope**
(YAGNI).

---

## Goal

1. A missing/empty `BRIDGE_API_KEY` becomes a **hard startup failure** (fail
   closed) unless the operator explicitly opts out for local dev.
2. Every bridge consumer sends the `x-api-key` header.
3. The auth decision is **pure and unit-tested** (no behavioural regression on
   the live path).

---

## Architecture

Follow the established repo pattern: **pure, testable logic in `bridge-core.js`;
express wiring in `server.js`.** `server.js` is not import-safe (it binds a port
and will now `process.exit(1)` on misconfiguration), so its logic cannot be unit
tested directly. The auth *config resolution* and the auth *decision* are
therefore extracted into two pure functions in `bridge-core.js`, mirroring the
existing `validateOrderRequest` / `writeFileAtomic` / `createKeyedMutex`
precedent and tested via the existing `node --test` harness
(`bridge-core.test.js`).

---

## Components

### 1. `windows-server/bridge-core.js` — two new pure exports

```js
/**
 * Decide the bridge's startup auth posture from the environment.
 * Pure: no IO, no process.exit. server.js acts on the returned mode.
 *
 *   mode "enforce" — a key is configured; the auth middleware is active.
 *   mode "noauth"  — no key, but BRIDGE_ALLOW_NO_AUTH=1 explicitly opts out (local dev).
 *   mode "fatal"   — no key and no opt-out; server.js must refuse to start.
 *
 * A configured key always wins, even if BRIDGE_ALLOW_NO_AUTH is also set.
 * A whitespace-only key trims to "" and is treated as unset.
 */
export function resolveAuthConfig(env) {
  const apiKey      = String(env.BRIDGE_API_KEY ?? "").trim();
  const allowNoAuth = env.BRIDGE_ALLOW_NO_AUTH === "1";
  if (apiKey !== "") return { mode: "enforce", apiKey };
  if (allowNoAuth)   return { mode: "noauth",  apiKey: "" };
  return { mode: "fatal", apiKey: "" };
}

/**
 * Whether a request is authorized. Pure boolean.
 * False unless a non-empty key is configured AND the provided header matches.
 */
export function isAuthorized(configuredKey, providedHeader) {
  return typeof configuredKey === "string" && configuredKey.length > 0
      && providedHeader === configuredKey;
}
```

### 2. `windows-server/server.js` — wire the helpers

- Extend the existing line-8 import:
  `import { validateOrderRequest, writeFileAtomic, createKeyedMutex, resolveAuthConfig, isAuthorized } from "./bridge-core.js";`
- Replace the `const API_KEY = process.env.BRIDGE_API_KEY || "";` line with:

  ```js
  const AUTH = resolveAuthConfig(process.env);
  if (AUTH.mode === "fatal") {
    console.error(
      "FATAL: BRIDGE_API_KEY is not set. Refusing to start without authentication.\n" +
      "Set BRIDGE_API_KEY in the environment, or set BRIDGE_ALLOW_NO_AUTH=1 to run " +
      "without auth (local dev only)."
    );
    process.exit(1);
  }
  ```

  This runs **before** the port binds — a misconfigured bridge never serves a
  single request.
- Replace the auth middleware body:

  ```js
  app.use((req, res, next) => {
    if (AUTH.mode === "enforce" && !isAuthorized(AUTH.apiKey, req.headers["x-api-key"])) {
      return res.status(401).json({ error: "Unauthorized" });
    }
    next();
  });
  ```
- Replace the `app.listen` startup warning (the `if (!API_KEY) console.warn(...)`
  block) with one that fires only in `noauth` mode:

  ```js
  if (AUTH.mode === "noauth") {
    console.warn("WARNING: running WITHOUT authentication (BRIDGE_ALLOW_NO_AUTH=1). Local dev only — never in production.");
  }
  ```

### 3. `src/index.ts` (MCP server client) — send the header

- In the constructor: `this.apiKey = process.env.BRIDGE_API_KEY || "";`
  (new `private apiKey: string;` field).
- In `makeApiCall`, build a headers object and pass it on both axios calls:

  ```ts
  const headers = this.apiKey ? { "x-api-key": this.apiKey } : {};
  const response = data
    ? await axios.post(url, data, { timeout: 30000, headers })
    : await axios.get(url, { timeout: 30000, headers });
  ```
- Must compile clean under `tsconfig.json` `strict: true`.

### 4. `test-connection.js` + `test-ea-sync.js` — send the header

In each, after the host/port consts:

```js
const API_KEY = process.env.BRIDGE_API_KEY || '';
const authHeaders = API_KEY ? { 'x-api-key': API_KEY } : {};
```

Merge `headers: authHeaders` into each axios options object (which already
carries `timeout`), e.g. `{ timeout: 5000, headers: authHeaders }`.

### 5. `windows-server/bridge-core.test.js` — unit tests (node --test)

Add cases:

- `resolveAuthConfig`:
  - key set → `{ mode: "enforce", apiKey: <key> }`
  - no key + `BRIDGE_ALLOW_NO_AUTH=1` → `{ mode: "noauth", apiKey: "" }`
  - no key + no opt-out → `{ mode: "fatal", apiKey: "" }`
  - key set + `BRIDGE_ALLOW_NO_AUTH=1` → `enforce` (key wins)
  - whitespace-only key → `fatal` (treated as unset)
- `isAuthorized`:
  - matching key → true
  - mismatched key → false
  - empty configured key → false
  - `undefined` provided header → false

No express-level integration test and no new dependency — consistent with the
repo's existing pure-helper test convention (`server.js` is not import-safe).

---

## Error handling & live-safety

- **Misconfiguration** (`mode: "fatal"`) → fail fast, never bind the port. The
  swing agent's existing `BRIDGE_DOWN` watchdog (3 consecutive missed cycles,
  `agent.py:1146`) Telegram-alerts that the bridge is unreachable — the footgun
  becomes loud instead of silent.
- **401 path** unchanged (still a JSON `{ error: "Unauthorized" }`).
- **EC2 deploy**: `BRIDGE_API_KEY` is set as a system env var → `mode: "enforce"`
  → the bridge boots exactly as it does today. **Zero live-path behaviour
  change.**

---

## Testing & deploy

- **Test:** `cd windows-server && npm test` (`node --test`) — green, including the
  new auth cases.
- **Deploy (live bridge):** in `metatrader-4-mcp` on EC2 → `git pull` → restart
  the Node bridge. Verify: startup log shows the normal banner with **no**
  warning; `curl http://127.0.0.1:8080/api/health` with no key → 401, with the
  configured key → 200.
- **MCP server (non-live, only if used):** `npm run build` (tsc) + reconnect in
  the MCP client. Separate from the live bridge restart.
- **Dev scripts:** no deploy; they simply keep working against a keyed bridge.
- **DEPLOY-GATED:** stop for explicit user approval after the final holistic
  review; nothing merged/pushed/deployed before that.

---

## Out of scope (explicit)

- `crypto.timingSafeEqual` constant-time comparison (no real benefit on a
  loopback-bound service; see Scope boundary).
- Any change to the swing repo (`Claude---MT4`), the EA, or the Python agent —
  the agent already authenticates correctly.
- Rotating the existing `BRIDGE_API_KEY` value (operational, not a code change).
