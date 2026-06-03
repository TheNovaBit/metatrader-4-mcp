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
