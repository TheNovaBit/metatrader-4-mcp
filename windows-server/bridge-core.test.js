import { test, mock } from "node:test";
import assert from "node:assert/strict";
import { validateOrderRequest } from "./bridge-core.js";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { writeFileAtomic } from "./bridge-core.js";
import { createKeyedMutex } from "./bridge-core.js";
import { resolveAuthConfig, isAuthorized } from "./bridge-core.js";

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

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

test("validateOrderRequest rejects NaN lots", () => {
  const r = validateOrderRequest({ ...validPending, lots: NaN });
  assert.equal(r.ok, false);
  assert.match(r.error, /lots/);
});

test("validateOrderRequest rejects Infinity lots", () => {
  const r = validateOrderRequest({ ...validPending, lots: Infinity });
  assert.equal(r.ok, false);
  assert.match(r.error, /lots/);
});

test("validateOrderRequest rejects NaN stop_loss", () => {
  const r = validateOrderRequest({ ...validPending, stop_loss: NaN });
  assert.equal(r.ok, false);
  assert.match(r.error, /stop_loss/);
});

test("validateOrderRequest rejects NaN price on a pending order", () => {
  const r = validateOrderRequest({ ...validPending, price: NaN });
  assert.equal(r.ok, false);
  assert.match(r.error, /price/);
});

test("validateOrderRequest rejects a whitespace-only symbol", () => {
  const r = validateOrderRequest({ ...validPending, symbol: "   " });
  assert.equal(r.ok, false);
  assert.match(r.error, /symbol/);
});

test("validateOrderRequest rejects a null body", () => {
  const r = validateOrderRequest(null);
  assert.equal(r.ok, false);
});

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

test("writeFileAtomic retries once on a transient rename failure then succeeds", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "bridge-atomic-"));
  const fp = path.join(dir, "order_commands.txt");
  const realRename = fs.rename.bind(fs);
  let calls = 0;
  mock.method(fs, "rename", async (...args) => {
    calls++;
    if (calls === 1) { const e = new Error("EPERM"); e.code = "EPERM"; throw e; }
    return realRename(...args);
  });
  try {
    await writeFileAtomic(fp, "retry-ok");
    assert.equal(await fs.readFile(fp, "utf-8"), "retry-ok");
    assert.equal(calls, 2);
    const leftover = (await fs.readdir(dir)).filter((f) => f.endsWith(".tmp"));
    assert.equal(leftover.length, 0);
  } finally {
    mock.restoreAll();
  }
});

test("writeFileAtomic rethrows and cleans up tmp when all rename attempts fail", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "bridge-atomic-"));
  const fp = path.join(dir, "order_commands.txt");
  mock.method(fs, "rename", async () => { const e = new Error("EPERM"); e.code = "EPERM"; throw e; });
  try {
    await assert.rejects(() => writeFileAtomic(fp, "nope"), /EPERM/);
    const leftover = (await fs.readdir(dir)).filter((f) => f.endsWith(".tmp"));
    assert.equal(leftover.length, 0);
  } finally {
    mock.restoreAll();
  }
});

test("writeFileAtomic rejects a non-string content", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "bridge-atomic-"));
  const fp = path.join(dir, "order_commands.txt");
  await assert.rejects(() => writeFileAtomic(fp, { not: "a string" }), TypeError);
});

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
  let releaseA;
  const aGate = new Promise((r) => { releaseA = r; });
  // A (key "order") is gated open; B (key "close") must start AND finish while A
  // is still running — proving different keys do not block each other.
  const a = mutex("order", async () => { events.push("A-start"); await aGate; events.push("A-end"); });
  const b = mutex("close", async () => { events.push("B-start"); events.push("B-end"); });
  await b;
  assert.deepEqual(events, ["A-start", "B-start", "B-end"]);
  releaseA();
  await a;
  assert.deepEqual(events, ["A-start", "B-start", "B-end", "A-end"]);
});

test("createKeyedMutex returns the task value and isolates rejection", async () => {
  const mutex = createKeyedMutex();
  await assert.rejects(() => mutex("k", async () => { throw new Error("boom"); }), /boom/);
  // a rejecting task must not poison the chain — the next task still runs
  const v = await mutex("k", async () => 42);
  assert.equal(v, 42);
});

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

test("resolveAuthConfig treats a null env as fatal (fail closed, no throw)", () => {
  assert.deepEqual(resolveAuthConfig(null), { mode: "fatal", apiKey: "" });
});

test("resolveAuthConfig treats an undefined env as fatal (fail closed, no throw)", () => {
  assert.deepEqual(resolveAuthConfig(undefined), { mode: "fatal", apiKey: "" });
});

test("isAuthorized is false when the provided header is null", () => {
  assert.equal(isAuthorized("secret123", null), false);
});
