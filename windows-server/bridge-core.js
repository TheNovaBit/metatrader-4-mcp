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
  // price is required (>0) only for pending orders. Market BUY/SELL legitimately
  // omit it — the EA fills the live bid/ask — so price is optional there (this is
  // a deliberate, stricter-where-it-matters asymmetry; the agent always sends a
  // pending order with price>0 anyway).
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
 * retry once after a short delay, then surface the error. The temp file is
 * always cleaned up if it is never renamed into place.
 *
 * @param {string} filePath  Absolute path of the target file.
 * @param {string} content   File contents (must be a string).
 */
export async function writeFileAtomic(filePath, content, { retries = 1, retryDelayMs = 50 } = {}) {
  if (typeof content !== "string") {
    throw new TypeError("writeFileAtomic: content must be a string");
  }
  const tmpPath = `${filePath}.${randomUUID()}.tmp`;
  let renamed = false;
  try {
    await fs.writeFile(tmpPath, content, "utf-8");
    for (let attempt = 0; ; attempt++) {
      try {
        // On Windows, libuv calls MoveFileExW with MOVEFILE_REPLACE_EXISTING,
        // so this atomically replaces any existing target on the same volume.
        await fs.rename(tmpPath, filePath);
        renamed = true;
        return;
      } catch (err) {
        // retryDelayMs (50) ~ a brief window for the EA to release a held file handle.
        if (attempt >= retries) throw err;
        await new Promise((r) => setTimeout(r, retryDelayMs));
      }
    }
  } finally {
    if (!renamed) {
      try { await fs.unlink(tmpPath); } catch { /* best-effort cleanup */ }
    }
  }
}

/**
 * Create a keyed async mutex. `run(key, fn)` runs `fn` only after every prior
 * task with the same key has settled, and resolves/rejects with fn's outcome.
 * Different keys never block each other. A rejecting task does not poison the
 * chain (the stored tail swallows errors).
 */
export function createKeyedMutex() {
  // Keys are expected to be a small, long-lived set (the bridge uses 3 fixed
  // command-file paths). Do NOT key by per-request IDs — `tails` never prunes.
  const tails = new Map();
  return function run(key, fn) {
    const prev = tails.get(key) || Promise.resolve();
    const result = prev.then(() => fn(), () => fn());
    // store a non-rejecting tail so the chain survives a failed task
    tails.set(key, result.then(() => {}, () => {}));
    return result;
  };
}

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
