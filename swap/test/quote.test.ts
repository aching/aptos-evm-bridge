import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { quoteAptOut, checkMinOut, type PriceConfig } from "../src/quote.js";

const CFG: PriceConfig = { ethUsd: 3000, aptUsd: 5, spreadBps: 50 };

describe("quoteAptOut", () => {
  it("1 ETH @ $3000/$5, 50bps spread = 597,000 APT octas x correct math", () => {
    // 1e18 wei * (3000/5) * 1e-10 = 6e10 octas gross; *0.995 = 5.97e10.
    assert.equal(quoteAptOut(10n ** 18n, CFG), 59_700_000_000n);
  });

  it("zero spread pays gross", () => {
    assert.equal(quoteAptOut(10n ** 18n, { ...CFG, spreadBps: 0 }), 60_000_000_000n);
  });

  it("reverts on zero amount and bad prices", () => {
    assert.throws(() => quoteAptOut(0n, CFG));
    assert.throws(() => quoteAptOut(10n ** 18n, { ...CFG, aptUsd: 0 }));
  });

  it("checkMinOut accepts at-or-below quote, rejects above", () => {
    const q = quoteAptOut(10n ** 18n, CFG);
    assert.equal(checkMinOut(10n ** 18n, q, CFG).ok, true);
    assert.equal(checkMinOut(10n ** 18n, q + 1n, CFG).ok, false);
  });
});
