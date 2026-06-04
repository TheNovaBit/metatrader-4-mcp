# B4 — Bridge API-Key Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the MT4 HTTP bridge fail closed when `BRIDGE_API_KEY` is missing (instead of silently running wide-open), and make every bridge consumer send the `x-api-key` header.

**Architecture:** Extract the auth *config resolution* and the auth *decision* into two pure, unit-tested functions in `windows-server/bridge-core.js` (matching the existing `validateOrderRequest`/`writeFileAtomic` precedent). `windows-server/server.js` calls them, exits on misconfiguration before binding the port, and gates the existing middleware on the resolved mode. The MCP client (`src/index.ts`) and the two dev diagnostic scripts send the header from `process.env.BRIDGE_API_KEY`.

**Tech Stack:** Node.js ESM, Express (bridge), TypeScript strict (MCP server), `node --test` (test harness). Repo: `metatrader-4-mcp`, branch `api-key-hardening` (off `master 4dfdd06`).

**Repo / process notes:**
- This is the **bridge repo** (`C:\Users\mahip\metatrader-4-mcp`), NOT the swing repo. There is **no** `tests.py` and **no** pre-push hook here — the test command is `npm test` (which runs `node --test`) from `windows-server/`.
- All commits are **local only** — DEPLOY-GATED. Do NOT push, merge, or deploy. Stop after the final task for explicit user approval.
- Line numbers below reflect the files as read on 2026-06-04; they drift as edits land. **Anchor every edit by the quoted content, not by line number.**
- Commits use conventional messages; global git config already disables co-author attribution.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `windows-server/bridge-core.js` | Pure, testable bridge helpers | **Add** `resolveAuthConfig(env)` + `isAuthorized(configuredKey, providedHeader)` |
| `windows-server/bridge-core.test.js` | `node --test` unit tests | **Add** ~11 cases for the two new helpers |
| `windows-server/server.js` | Express wiring / live bridge | **Modify** import line, replace `const API_KEY` block, middleware body, listen-warning |
| `src/index.ts` | MCP server (stdio) client | **Modify** add `apiKey` field + `x-api-key` header in `makeApiCall` |
| `test-connection.js` | Dev diagnostic script | **Modify** add `x-api-key` header to axios calls |
| `test-ea-sync.js` | Dev diagnostic script | **Modify** add `x-api-key` header to axios calls |

---

## Task 1: Pure auth helpers + unit tests

**Files:**
- Modify: `windows-server/bridge-core.js` (append two exports at end of file)
- Test: `windows-server/bridge-core.test.js` (add imports + append test cases)

- [ ] **Step 1: Write the failing tests**

In `windows-server/bridge-core.test.js`, add to the existing import block near the top (after the other `from "./bridge-core.js"` imports):

```js
import { resolveAuthConfig, isAuthorized } from "./bridge-core.js";
```

Then append these cases at the end of the file:

```js
// ── resolveAuthConfig ──────────────────────────────────────────────────────────

test("resolveAuthConfig returns enforce when BRIDGE_API_KEY is set", () => {
  assert.deepEqual(
    resolveAuthConfig({ BRIDGE_API_KEY: "secret123" }),
    { mode: "enforce", apiKey: "secret123" }
  );
});

test("resolveAuthConfig returns noauth when key absent but BRIDGE_ALLOW_NO_AUTH=1", () => {
  assert.deepEqual(
    resolveAuthConfig({ BRIDGE_ALLOW_NO_AUTH: "1" }),
    { mode: "noauth", apiKey: "" }
  );
});

test("resolveAuthConfig returns fatal when key absent and no opt-out", () => {
  assert.deepEqual(resolveAuthConfig({}), { mode: "fatal", apiKey: "" });
});

test("resolveAuthConfig: a configured key wins even if BRIDGE_ALLOW_NO_AUTH=1", () => {
  assert.deepEqual(
    resolveAuthConfig({ BRIDGE_API_KEY: "secret123", BRIDGE_ALLOW_NO_AUTH: "1" }),
    { mode: "enforce", apiKey: "secret123" }
  );
});

test("resolveAuthConfig: a whitespace-only key is treated as unset (fatal)", () => {
  assert.deepEqual(
    resolveAuthConfig({ BRIDGE_API_KEY: "   " }),
    { mode: "fatal", apiKey: "" }
  );
});

test("resolveAuthConfig: BRIDGE_ALLOW_NO_AUTH other than '1' does not opt out (fatal)", () => {
  assert.deepEqual(
    resolveAuthConfig({ BRIDGE_ALLOW_NO_AUTH: "true" }),
    { mode: "fatal", apiKey: "" }
  );
});

test("resolveAuthConfig preserves the RAW key value (never trims a real key)", () => {
  // The Python agent reads BRIDGE_API_KEY verbatim, so the bridge must compare the
  // raw value — trimming a real key would cause an auth mismatch.
  assert.deepEqual(
    resolveAuthConfig({ BRIDGE_API_KEY: " spaced-key " }),
    { mode: "enforce", apiKey: " spaced-key " }
  );
});

// ── isAuthorized ───────────────────────────────────────────────────────────────

test("isAuthorized is true only when a non-empty key matches the header", () => {
  assert.equal(isAuthorized("secret123", "secret123"), true);
});

test("isAuthorized is false on a mismatched header", () => {
  assert.equal(isAuthorized("secret123", "wrong"), false);
});

test("isAuthorized is false when the configured key is empty", () => {
  assert.equal(isAuthorized("", ""), false);
});

test("isAuthorized is false when the provided header is undefined", () => {
  assert.equal(isAuthorized("secret123", undefined), false);
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd "C:/Users/mahip/metatrader-4-mcp/windows-server" && npm test`
Expected: the new tests FAIL — `resolveAuthConfig`/`isAuthorized` are `undefined` (not exported yet). Existing tests still pass.

- [ ] **Step 3: Implement the two exports**

Append to the **end** of `windows-server/bridge-core.js`:

```js
/**
 * Decide the bridge's startup auth posture from the environment.
 * Pure: no IO, no process.exit — server.js acts on the returned mode.
 *
 *   mode "enforce" — a key is configured; the auth middleware is active.
 *   mode "noauth"  — no key, but BRIDGE_ALLOW_NO_AUTH=1 explicitly opts out (local dev).
 *   mode "fatal"   — no key and no opt-out; server.js must refuse to start.
 *
 * A configured key always wins, even if BRIDGE_ALLOW_NO_AUTH is also set.
 * Emptiness is decided on a trimmed view (so a whitespace-only value counts as
 * unset), but the RAW value is stored and compared — the Python agent reads the
 * env var verbatim, so the bridge must not trim a real key or auth would mismatch.
 */
export function resolveAuthConfig(env) {
  const apiKey      = String(env.BRIDGE_API_KEY ?? "");
  const allowNoAuth = env.BRIDGE_ALLOW_NO_AUTH === "1";
  if (apiKey.trim() !== "") return { mode: "enforce", apiKey };
  if (allowNoAuth)          return { mode: "noauth", apiKey: "" };
  return { mode: "fatal", apiKey: "" };
}

/**
 * Whether a request is authorized. Pure boolean.
 * False unless a non-empty key is configured AND the provided header matches it exactly.
 */
export function isAuthorized(configuredKey, providedHeader) {
  return typeof configuredKey === "string" && configuredKey.length > 0
      && providedHeader === configuredKey;
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd "C:/Users/mahip/metatrader-4-mcp/windows-server" && npm test`
Expected: ALL tests pass (the existing `validateOrderRequest`/`writeFileAtomic`/`createKeyedMutex` cases plus the 11 new auth cases).

- [ ] **Step 5: Commit**

```bash
cd "C:/Users/mahip/metatrader-4-mcp"
git add windows-server/bridge-core.js windows-server/bridge-core.test.js
git commit -m "feat(bridge): pure resolveAuthConfig + isAuthorized auth helpers"
```

---

## Task 2: Wire server.js — fail-closed startup + mode-gated middleware

**Files:**
- Modify: `windows-server/server.js` (import line ~8; `const API_KEY` block ~35-38; middleware ~55-61; listen-warning ~545-547)

Depends on Task 1 (imports the new helpers).

- [ ] **Step 1: Extend the bridge-core import**

Find:
```js
import { validateOrderRequest, writeFileAtomic, createKeyedMutex } from "./bridge-core.js";
```
Replace with:
```js
import { validateOrderRequest, writeFileAtomic, createKeyedMutex, resolveAuthConfig, isAuthorized } from "./bridge-core.js";
```

- [ ] **Step 2: Replace the `const API_KEY` block with fail-closed resolution**

Find:
```js
// Shared secret for API key authentication.
// Set BRIDGE_API_KEY in the EC2 environment (and in start_trader.bat).
// If unset the middleware is bypassed — useful during local dev, but MUST be set in production.
const API_KEY = process.env.BRIDGE_API_KEY || "";
```
Replace with:
```js
// Shared secret for API key authentication.
// BRIDGE_API_KEY is a system env var on EC2 (inherited by both the bridge and the
// Python agent). The bridge FAILS CLOSED: if no key is configured it refuses to
// start — unless BRIDGE_ALLOW_NO_AUTH=1 is set, which opts out for local dev only.
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

- [ ] **Step 3: Replace the middleware body**

Find:
```js
// API key authentication — all routes require X-Api-Key header when key is configured
app.use((req, res, next) => {
  if (API_KEY && req.headers["x-api-key"] !== API_KEY) {
    return res.status(401).json({ error: "Unauthorized" });
  }
  next();
});
```
Replace with:
```js
// API key authentication — when enforcing, all routes require a matching X-Api-Key header.
app.use((req, res, next) => {
  if (AUTH.mode === "enforce" && !isAuthorized(AUTH.apiKey, req.headers["x-api-key"])) {
    return res.status(401).json({ error: "Unauthorized" });
  }
  next();
});
```

- [ ] **Step 4: Replace the listen-time warning**

Find:
```js
  if (!API_KEY) {
    console.warn("WARNING: BRIDGE_API_KEY is not set — running without authentication");
  }
```
Replace with:
```js
  if (AUTH.mode === "noauth") {
    console.warn("WARNING: running WITHOUT authentication (BRIDGE_ALLOW_NO_AUTH=1). Local dev only — never in production.");
  }
```

- [ ] **Step 5: Smoke-test the FATAL path (deterministic — it exits)**

> Inline `BRIDGE_API_KEY=""` overrides any inherited value for that one command, so this works even if the dev machine has the env var set. `PORT=18080` avoids clobbering any running bridge.

Run:
```bash
cd "C:/Users/mahip/metatrader-4-mcp/windows-server"
BRIDGE_API_KEY="" BRIDGE_ALLOW_NO_AUTH="" PORT=18080 node server.js; echo "exit=$?"
```
Expected output:
```
FATAL: BRIDGE_API_KEY is not set. Refusing to start without authentication.
Set BRIDGE_API_KEY in the environment, or set BRIDGE_ALLOW_NO_AUTH=1 to run without auth (local dev only).
exit=1
```

- [ ] **Step 6: Smoke-test the ENFORCE path (401 without key, 200 with key)**

Run:
```bash
cd "C:/Users/mahip/metatrader-4-mcp/windows-server"
PORT=18080 BRIDGE_API_KEY="smoketest" node server.js &
SRV=$!
sleep 1
echo -n "no key   -> "; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18080/api/health
echo -n "with key -> "; curl -s -o /dev/null -w "%{http_code}\n" -H "x-api-key: smoketest" http://127.0.0.1:18080/api/health
kill $SRV 2>/dev/null
```
Expected output:
```
no key   -> 401
with key -> 200
```
(`/api/health` returns its JSON without touching MT4 files, so 200 is clean.)

- [ ] **Step 7: Smoke-test the NOAUTH dev hatch (key absent + opt-out → open)**

Run:
```bash
cd "C:/Users/mahip/metatrader-4-mcp/windows-server"
PORT=18080 BRIDGE_API_KEY="" BRIDGE_ALLOW_NO_AUTH="1" node server.js &
SRV=$!
sleep 1
echo -n "noauth no key -> "; curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:18080/api/health
kill $SRV 2>/dev/null
```
Expected output:
```
noauth no key -> 200
```

- [ ] **Step 8: Confirm the unit suite is still green**

Run: `cd "C:/Users/mahip/metatrader-4-mcp/windows-server" && npm test`
Expected: all tests pass (server.js is not imported by the suite; this confirms no collateral breakage to `bridge-core.js`).

- [ ] **Step 9: Commit**

```bash
cd "C:/Users/mahip/metatrader-4-mcp"
git add windows-server/server.js
git commit -m "feat(bridge): fail closed at startup when BRIDGE_API_KEY is unset"
```

---

## Task 3: MCP client sends the x-api-key header (src/index.ts)

**Files:**
- Modify: `src/index.ts` (class fields ~14-18; constructor ~37-40; `makeApiCall` ~352-354)

- [ ] **Step 1: Add the `apiKey` field**

Find:
```ts
  private reportsPath: string;
```
Replace with:
```ts
  private reportsPath: string;
  private apiKey: string;
```

- [ ] **Step 2: Assign it in the constructor**

Find:
```ts
    // Path for EA reports and status files (configurable via environment)
    this.reportsPath = process.env.MT4_REPORTS_PATH || "/tmp/mt4_reports";
```
Replace with:
```ts
    // Path for EA reports and status files (configurable via environment)
    this.reportsPath = process.env.MT4_REPORTS_PATH || "/tmp/mt4_reports";

    // Shared secret matching the bridge's BRIDGE_API_KEY (sent as the x-api-key header).
    this.apiKey = process.env.BRIDGE_API_KEY || "";
```

- [ ] **Step 3: Send the header on both axios calls in `makeApiCall`**

Find (note: the original `const response = data` line has a trailing space — match the file exactly):
```ts
      const response = data 
        ? await axios.post(url, data, { timeout: 30000 })
        : await axios.get(url, { timeout: 30000 });
```
Replace with:
```ts
      const headers = this.apiKey ? { "x-api-key": this.apiKey } : {};
      const response = data
        ? await axios.post(url, data, { timeout: 30000, headers })
        : await axios.get(url, { timeout: 30000, headers });
```

- [ ] **Step 4: Verify the TypeScript build is clean (strict mode)**

Run:
```bash
cd "C:/Users/mahip/metatrader-4-mcp"
npm run build
echo "build exit=$?"
```
Expected: `tsc` completes with no errors, `build exit=0`, and `dist/index.js` is regenerated. (If `tsc` is missing, run `npm install` first.)

- [ ] **Step 5: Commit**

```bash
cd "C:/Users/mahip/metatrader-4-mcp"
git add src/index.ts
git commit -m "feat(mcp): send x-api-key header on all bridge calls"
```

> Note: `dist/` is build output. Only commit it if it is already tracked in the repo; otherwise leave it untracked (check `git status` — do not add `dist/` if it is gitignored).

---

## Task 4: Dev diagnostic scripts send the header

**Files:**
- Modify: `test-connection.js` (consts ~3-4; two `axios.get` calls)
- Modify: `test-ea-sync.js` (consts ~12-13; four axios calls)

- [ ] **Step 1: Add the header consts to `test-connection.js`**

Find:
```js
const MT4_HOST = process.env.MT4_HOST || '192.168.50.161';
const MT4_PORT = process.env.MT4_PORT || '8080';
```
Replace with:
```js
const MT4_HOST = process.env.MT4_HOST || '192.168.50.161';
const MT4_PORT = process.env.MT4_PORT || '8080';
const API_KEY = process.env.BRIDGE_API_KEY || '';
const authHeaders = API_KEY ? { 'x-api-key': API_KEY } : {};
```

- [ ] **Step 2: Attach the header to both axios calls in `test-connection.js`**

Use a replace-all on the axios options (both occurrences are `timeout: 5000`):

Find (replace all occurrences): `timeout: 5000`
Replace with: `timeout: 5000, headers: authHeaders`

This updates both the `/api/health` and `/api/account` GET calls.

- [ ] **Step 3: Syntax-check `test-connection.js`**

Run: `cd "C:/Users/mahip/metatrader-4-mcp" && node --check test-connection.js && echo "OK"`
Expected: `OK` (no syntax errors).

- [ ] **Step 4: Add the header consts to `test-ea-sync.js`**

Find:
```js
const MT4_HOST = process.env.MT4_HOST || '192.168.50.161';
const MT4_PORT = process.env.MT4_PORT || '8080';
```
Replace with:
```js
const MT4_HOST = process.env.MT4_HOST || '192.168.50.161';
const MT4_PORT = process.env.MT4_PORT || '8080';
const API_KEY = process.env.BRIDGE_API_KEY || '';
const authHeaders = API_KEY ? { 'x-api-key': API_KEY } : {};
```

- [ ] **Step 5: Attach the header to all four axios calls in `test-ea-sync.js`**

Each axios options object uses a distinct timeout value, so make four single edits:

| Find | Replace |
|---|---|
| `timeout: 5000` | `timeout: 5000, headers: authHeaders` |
| `timeout: 30000` | `timeout: 30000, headers: authHeaders` |
| `timeout: 45000` | `timeout: 45000, headers: authHeaders` |
| `timeout: 10000` | `timeout: 10000, headers: authHeaders` |

(These cover the health GET, the `/api/ea/upload` POST, the `/api/ea/compile` POST, and the `/api/ea/list` GET respectively.)

- [ ] **Step 6: Syntax-check `test-ea-sync.js`**

Run: `cd "C:/Users/mahip/metatrader-4-mcp" && node --check test-ea-sync.js && echo "OK"`
Expected: `OK` (no syntax errors).

- [ ] **Step 7: Commit**

```bash
cd "C:/Users/mahip/metatrader-4-mcp"
git add test-connection.js test-ea-sync.js
git commit -m "feat(bridge): dev diagnostic scripts send x-api-key header"
```

---

## After all tasks

1. **Final holistic review** (subagent-driven-development final step): dispatch an `ecc:typescript-reviewer` (covers the JS bridge + TS client) over the whole branch diff. Verify: the fatal exit cannot be reached in the EC2 system-env-set state; the middleware never enforces in `noauth`/`fatal` modes; the raw key is compared (not trimmed); no consumer left without the header; no live-path regression.
2. **STOP at the deploy gate.** Do NOT push/merge/deploy. Present the branch summary and wait for explicit user approval.
3. **On approval (deploy runbook):**
   - `git push -u origin api-key-hardening` (or merge to `master` per the user's choice) — bridge repo only.
   - **Live bridge:** on EC2, in `metatrader-4-mcp`, `git pull` (or fetch+checkout) → restart the Node bridge. Because `BRIDGE_API_KEY` is a system env var, the bridge resolves `mode: "enforce"` and boots normally. Verify: startup banner shows **no** warning; `curl http://127.0.0.1:8080/api/health` with no key → 401, with the configured key → 200.
   - **MCP server (only if used):** `npm run build` + reconnect in the MCP client. Non-live, separate from the bridge restart.
   - No swing-agent restart, no EA recompile.

---

## Self-Review (completed by plan author)

**Spec coverage:** Goal #1 (fail-closed startup) → Task 2 Steps 2/5/7. Goal #2 (all consumers send header) → Task 2 (server accepts), Task 3 (MCP client), Task 4 (dev scripts), plus the agent already sends it (no task needed). Goal #3 (pure, unit-tested decision) → Task 1. Scope-boundary "no timing-safe compare" → honoured (plain `===`). "No express integration test / no new dep" → honoured (smoke tests are manual shell commands, not committed tests). All spec sections covered.

**Placeholder scan:** No TBD/TODO/vague steps; every code step shows the exact find/replace block and every command shows expected output.

**Type/name consistency:** `resolveAuthConfig` returns `{ mode, apiKey }` everywhere; `AUTH.mode`/`AUTH.apiKey` used consistently in server.js; `isAuthorized(configuredKey, providedHeader)` signature matches its call site `isAuthorized(AUTH.apiKey, req.headers["x-api-key"])`; `this.apiKey` field name matches its use in `makeApiCall`. Consistent.
