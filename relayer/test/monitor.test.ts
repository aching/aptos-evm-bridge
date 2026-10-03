import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { checkHealth } from "../src/monitor.js";

// Stub clients: scripted read sequences so we can simulate torn reads
// (parallel-fetch race) vs persistent gaps.
function stubMaroo(escrowReads: bigint[]) {
  let i = 0;
  return {
    readContract: async () => {
      const v = escrowReads[Math.min(i, escrowReads.length - 1)];
      i += 1;
      return v;
    },
    getBalance: async () => 0n,
  } as never;
}

function stubAptos(opts: { supplyReads?: bigint[]; noSupplyView?: boolean; cap?: bigint; used?: bigint; paused?: boolean; userBal?: bigint; relayerBal?: bigint }) {
  let i = 0;
  const supplies = opts.supplyReads ?? [0n];
  return {
    getAccountCoinAmount: async (args: { accountAddress: string }) =>
      args.accountAddress === ADDRS.aptosUser ? (opts.userBal ?? 0n) : (opts.relayerBal ?? 0n),
    view: async (args: { payload: { function: string } }) => {
      if (args.payload.function.endsWith("::okrw::supply")) {
        if (opts.noSupplyView) throw new Error("view not found");
        const v = supplies[Math.min(i, supplies.length - 1)];
        i += 1;
        return [{ vec: [v.toString()] }];
      }
      if (args.payload.function.endsWith("::okrw::is_paused")) return [false];
      throw new Error("unexpected view");
    },
    getAccountResource: async () => ({
      daily_mint_cap: (opts.cap ?? 10n ** 19n).toString(),
      minted_today: (opts.used ?? 0n).toString(),
      paused: opts.paused ?? false,
    }),
  } as never;
}

const ADDRS = {
  vault: "0x1" as `0x${string}`,
  metadata: "0x2",
  aptosUser: "0x3",
  aptosRelayer: "0x4",
  bridgeAddr: "0x5",
  moduleAddr: "0x6",
};

describe("checkHealth conservation", () => {
  it("is ok when escrow equals supply", async () => {
    const r = await checkHealth({
      maroo: stubMaroo([100n]), aptos: stubAptos({ supplyReads: [100n] }), ...ADDRS,
    });
    assert.equal(r.ok, true);
    assert.equal(r.vaultEscrow, "100");
    assert.equal(r.aptosSupply, "100");
  });

  it("does NOT flag a torn parallel read that agrees on re-read", async () => {
    // First escrow read races ahead of supply (100 vs 90), re-read agrees (100, 100).
    const r = await checkHealth({
      maroo: stubMaroo([100n, 100n]), aptos: stubAptos({ supplyReads: [90n, 100n] }), ...ADDRS,
    });
    assert.equal(r.ok, true);
    assert.ok(!r.issues.some((i) => i.check === "conservation"));
  });

  it("flags a persistent gap confirmed on re-read, with exact figures", async () => {
    const r = await checkHealth({
      maroo: stubMaroo([100n, 100n]), aptos: stubAptos({ supplyReads: [90n, 90n] }), ...ADDRS,
    });
    assert.equal(r.ok, false);
    const c = r.issues.find((i) => i.check === "conservation");
    assert.ok(c);
    assert.equal(c.level, "error");
    assert.match(c.detail, /confirmed on re-read/);
    assert.equal(r.vaultEscrow, "100");
    assert.equal(r.aptosSupply, "90");
  });

  it("falls back to the balance proxy with a warn when the supply view is missing", async () => {
    const r = await checkHealth({
      maroo: stubMaroo([50n]), aptos: stubAptos({ noSupplyView: true }), ...ADDRS,
    });
    assert.ok(r.issues.some((i) => i.check === "supply-view-unavailable" && i.level === "warn"));
  });

  it("flags cap exhaustion at 90%+ usage", async () => {
    const r = await checkHealth({
      maroo: stubMaroo([0n]), aptos: stubAptos({ supplyReads: [0n], cap: 100n, used: 95n }), ...ADDRS,
    });
    const cap = r.issues.find((i) => i.check === "mint-cap");
    assert.ok(cap);
    assert.equal(cap.level, "warn");
  });

  it("distinguishes wei-exact balances (no float rounding in the supply path)", async () => {
    // Regression: getAccountCoinAmount float-rounded ...016 to ...000.
    // The monitor must use the exact view path — a 16-wei gap is a real
    // (if tiny) gap, not noise. Balances differing only by rounding must
    // still compare exactly.
    const odd = 1010000000000000016n;
    const r = await checkHealth({
      maroo: stubMaroo([odd, odd]), aptos: stubAptos({ supplyReads: [odd, odd] }), ...ADDRS,
    });
    assert.equal(r.ok, true);
    assert.equal(r.vaultEscrow, odd.toString());
    assert.equal(r.aptosSupply, odd.toString());
  });
});
