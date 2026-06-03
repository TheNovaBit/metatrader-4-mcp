// Pure, testable helpers for the MT4 HTTP bridge.
// No express, no server start — safe to import from tests.

import fs from "node:fs/promises";
import { randomUUID } from "node:crypto";

export const VALID_OPS = ["BUY", "SELL", "BUY_LIMIT", "SELL_LIMIT", "BUY_STOP", "SELL_STOP"];
export const PENDING_OPS = ["BUY_LIMIT", "SELL_LIMIT", "BUY_STOP", "SELL_STOP"];

function isPositiveFinite(v) {
  return typeof v === "number" && Number.isFinite(v) && v > 0;
}

/**
 * Validate an /api/order request body.
 * Returns { ok: true } or { ok: false, error: "<message>" }.
 * Rejects non-positive lots/stop_loss/take_profit; requires price>0 for pending ops.
 */
export function validateOrderRequest(body) {
  const { symbol, operation, lots, price, stop_loss, take_profit } = body || {};

  if (!symbol || typeof symbol !== "string" || symbol.trim() === "") {
    return { ok: false, error: "Missing or invalid field: symbol" };
  }
  if (!operation || !VALID_OPS.includes(operation)) {
    return { ok: false, error: `Missing or invalid field: operation (must be one of ${VALID_OPS.join(", ")})` };
  }
  if (!isPositiveFinite(lots)) {
    return { ok: false, error: "Missing or invalid field: lots (must be a positive number)" };
  }
  if (!isPositiveFinite(stop_loss)) {
    return { ok: false, error: "Missing or invalid field: stop_loss (must be a positive number)" };
  }
  if (!isPositiveFinite(take_profit)) {
    return { ok: false, error: "Missing or invalid field: take_profit (must be a positive number)" };
  }
  if (PENDING_OPS.includes(operation)) {
    if (!isPositiveFinite(price)) {
      return { ok: false, error: "Missing or invalid field: price (must be > 0 for pending orders)" };
    }
  } else if (price != null && typeof price !== "number") {
    return { ok: false, error: "Invalid field: price" };
  }
  return { ok: true };
}

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
