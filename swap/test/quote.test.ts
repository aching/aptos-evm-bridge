import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { quoteAptOut, checkMinOut, priceConfigFromEnv, type PriceConfig } from "../src/quote.js";
import { quoteEthOut } from "../src/reverse.js";

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

  it("large amounts are wei-exact (float path drifted above 2^53 wei)", () => {
    // 1234.567890123456789 ETH: gross = amount * 600 / 1e10, net * 0.995.
    // Hand-computed in integers: no float involved anywhere.
    const amt = 1_234_567_890_123_456_789n * 1000n;
    const gross = (amt * 600n) / 10_000_000_000n;
    const want = (gross * 9950n) / 10_000n;
    assert.equal(quoteAptOut(amt, CFG), want);
    // The old float formula gave a different (off-by-dust) answer here.
    assert.notEqual(quoteAptOut(amt, CFG), BigInt(Math.floor(Number(amt) * 600 * 1e-10 * 0.995)));
  });

  it("fractional USD prices stay exact", () => {
    const cfg = { ethUsd: 3000.5, aptUsd: 5.25, spreadBps: 0 };
    // gross = 1e18 * 3000500000 * 1e8 / (5250000 * 1e18).
    const want = (10n ** 18n * 3_000_500_000n * 100_000_000n) / (5_250_000n * 10n ** 18n);
    assert.equal(quoteAptOut(10n ** 18n, cfg), want);
  });

  it("100% spread pays zero; over-100% and fractional spreads throw", () => {
    assert.equal(quoteAptOut(10n ** 18n, { ...CFG, spreadBps: 10_000 }), 0n);
    assert.throws(() => quoteAptOut(10n ** 18n, { ...CFG, spreadBps: 10_001 }), /spreadBps/);
    assert.throws(() => quoteAptOut(10n ** 18n, { ...CFG, spreadBps: -1 }), /spreadBps/);
    assert.throws(() => quoteAptOut(10n ** 18n, { ...CFG, spreadBps: 2.5 }), /spreadBps/);
  });

  it("NaN prices throw bad-prices, not silent zero", () => {
    assert.throws(() => quoteAptOut(10n ** 18n, { ...CFG, ethUsd: NaN }), /bad prices/);
    assert.throws(() => quoteAptOut(10n ** 18n, { ...CFG, aptUsd: NaN }), /bad prices/);
  });
});

describe("quoteEthOut (reverse)", () => {
  // 6,000,000 octas @ $5 = $3.00 -> 0.001 ETH gross @ $3000, minus 0.5%.
  it("round-trips the forward quote (minus both spreads)", () => {
    const fwd = quoteAptOut(10n ** 18n, CFG); // 1 ETH -> octas
    const back = quoteEthOut(fwd, CFG);
    // Two 50bps spreads: back ≈ 1e18 * 0.995^2.
    const want = (10n ** 18n * 9950n * 9950n) / (10_000n * 10_000n);
    assert.ok(back <= 10n ** 18n && back >= want - 2n && back <= want + 2n);
  });

  it("hand-computed integer value, no float drift", () => {
    // 6e6 octas * 5.25e6 * 1e18 / (3000.5e6 * 1e8), spread 0.
    const cfg = { ethUsd: 3000.5, aptUsd: 5.25, spreadBps: 0 };
    const want = (6_000_000n * 5_250_000n * 10n ** 18n) / (3_000_500_000n * 100_000_000n);
    assert.equal(quoteEthOut(6_000_000n, cfg), want);
  });

  it("rejects non-positive, bad spread, and u64-overflow amounts", () => {
    assert.throws(() => quoteEthOut(0n, CFG), /positive/);
    assert.throws(() => quoteEthOut(6_000_000n, { ...CFG, spreadBps: 10_001 }), /spreadBps/);
    // ~11.1M APT @ $5 = $55M -> ~18,500 ETH > u64 wei.
    assert.throws(() => quoteEthOut(1_111_000_000_000_000n, CFG), /u64/);
  });
});
