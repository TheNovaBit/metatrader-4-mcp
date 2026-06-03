import { test, mock } from "node:test";
import assert from "node:assert/strict";
import { validateOrderRequest } from "./bridge-core.js";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { writeFileAtomic } from "./bridge-core.js";
import { createKeyedMutex } from "./bridge-core.js";

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
