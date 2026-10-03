import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { friendlyError } from "../src/errors.js";

describe("friendlyError", () => {
  it("decodes the mint_attested offset-only failure to the function fallback", () => {
    const f = friendlyError(
      new Error("Transaction 0xd0f1 failed: Execution failed in 0xd926::bridge::mint_attested (on instruction Add) at code offset 65"),
      "relay",
    );
    assert.equal(f.code, "MOVE_RELAY");
    assert.match(f.title, /Mint attestation failed/);
    assert.equal(f.retryable, true);
  });

  it("decodes numeric bridge abort codes", () => {
    const f = friendlyError(new Error("Move abort in 0xd926::bridge::burn_withdraw: (code 5)"), "bridge-back");
    assert.match(f.title, /paused/i);
    assert.equal(f.retryable, false);
  });

  it("decodes the vault DailyCapExceeded selector", () => {
    const f = friendlyError(
      new Error('The contract function "release" reverted with the following signature: 0x3e814127'),
      "bridge-back",
    );
    assert.match(f.title, /Daily release cap/);
    assert.equal(f.retryable, true);
  });

  it("decodes the vault OutOfOrderNonce selector", () => {
    const f = friendlyError(
      new Error('The contract function "release" reverted with the following signature: 0xdb9d0c46'),
      "bridge-back",
    );
    assert.match(f.title, /out of order/i);
    assert.equal(f.retryable, true);
  });

  it("maps okrw denylist aborts", () => {
    const f = friendlyError(new Error("Move abort 2 in 0xabc::okrw::mint"), "relay");
    assert.match(f.title, /denylisted/);
  });

  it("maps insufficient balance as retryable", () => {
    const f = friendlyError(new Error("insufficient balance for gas"), "deposit");
    assert.equal(f.retryable, true);
  });

  it("maps RPC failures as retryable network errors", () => {
    const f = friendlyError(new Error("fetch failed"), "relay");
    assert.equal(f.code, "NET_RELAY");
    assert.equal(f.retryable, true);
  });

  it("maps empty relay ranges", () => {
    const f = friendlyError(new Error("no unattested deposit found in range"), "relay");
    assert.equal(f.code, "NOTFOUND_RELAY");
    assert.equal(f.retryable, false);
  });

  it("passes unknown errors through with raw text preserved", () => {
    const f = friendlyError(new Error("something totally new"), "relay");
    assert.equal(f.code, "UNKNOWN_RELAY");
    assert.match(f.raw, /something totally new/);
  });
});
