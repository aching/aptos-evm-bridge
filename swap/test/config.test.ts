/// Startup validation: keys, addresses, amount fields fail fast with fixes.
import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import { loadEvmKey, loadEvmAddress, loadOptionalEvmAddress, parseAmountField } from "../src/config.js";

const GOOD_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const GOOD_ADDR = "0x5fbdb2315678afecb367f032d93f642f64180aa3";

let saved: Record<string, string | undefined> = {};
beforeEach(() => { saved = { ...process.env }; });
afterEach(() => {
  for (const k of ["T_K", "T_A"]) delete process.env[k];
  Object.assign(process.env, saved);
});

describe("loadEvmKey", () => {
  it("accepts 0x and bare keys, derives the Anvil deployer address", () => {
    process.env.T_K = GOOD_KEY;
    assert.equal(loadEvmKey("T_K", "t").account.address.toLowerCase(), "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266");
    process.env.T_K = GOOD_KEY.slice(2);
    assert.equal(loadEvmKey("T_K", "t").account.address.toLowerCase(), "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266");
  });

  it("missing env names the variable and purpose", () => {
    assert.throws(() => loadEvmKey("T_K", "demo locker"), /Missing env: T_K.*demo locker/);
  });

  it("an address pasted as a key says ADDRESS, not a noble crash", () => {
    process.env.T_K = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
    assert.throws(() => loadEvmKey("T_K", "t"), /looks like an ADDRESS/);
  });

  it("truncated key reports the length", () => {
    process.env.T_K = "0x1234";
    assert.throws(() => loadEvmKey("T_K", "t"), /64 hex chars.*got 6 chars/);
  });
});

describe("loadEvmAddress", () => {
  it("accepts a 20-byte address, rejects keys and garbage", () => {
    process.env.T_A = GOOD_ADDR;
    assert.equal(loadEvmAddress("T_A", "t"), GOOD_ADDR);
    process.env.T_A = GOOD_KEY;
    assert.throws(() => loadEvmAddress("T_A", "t"), /20-byte 0x address/);
    process.env.T_A = "not-an-address";
    assert.throws(() => loadEvmAddress("T_A", "t"), /20-byte 0x address/);
  });
});

describe("loadOptionalEvmAddress", () => {
  it("empty/unset/zero = null; valid = address; malformed throws", () => {
    assert.equal(loadOptionalEvmAddress("T_A"), null);
    process.env.T_A = "";
    assert.equal(loadOptionalEvmAddress("T_A"), null);
    process.env.T_A = "0x0000000000000000000000000000000000000000";
    assert.equal(loadOptionalEvmAddress("T_A"), null);
    process.env.T_A = GOOD_ADDR;
    assert.equal(loadOptionalEvmAddress("T_A"), GOOD_ADDR);
    process.env.T_A = "0x1234";
    assert.throws(() => loadOptionalEvmAddress("T_A"), /20-byte/);
  });
});

describe("parseAmountField", () => {
  it("digits pass; floats, negatives, empties, non-strings throw", () => {
    assert.equal(parseAmountField("5970000000", "minOut"), 5970000000n);
    for (const bad of ["5.97", "-1", "", "abc", undefined, 42, null]) {
      assert.throws(() => parseAmountField(bad, "minOut"), /non-negative integer string/);
    }
  });
});
