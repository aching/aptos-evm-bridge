import { describe, it, beforeEach, afterEach } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Store } from "../src/store.js";

describe("Store", () => {
  let dir: string;
  let store: Store;
  beforeEach(() => {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "okrw-store-test-"));
    store = new Store(dir);
  });
  afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

  it("starts empty with null cursor", () => {
    assert.equal(store.lastBlock, null);
    assert.equal(store.hasForward("0"), false);
    assert.deepEqual(store.history, []);
  });

  it("persists the block cursor across re-instantiation", () => {
    store.lastBlock = 12345n;
    const reopened = new Store(dir);
    assert.equal(reopened.lastBlock, 12345n);
  });

  it("tracks attested nonces without duplicates", () => {
    store.addForward("7");
    store.addForward("7");
    assert.equal(store.hasForward("7"), true);
    assert.equal(store.hasForward("8"), false);
    const reopened = new Store(dir);
    assert.equal(reopened.hasForward("7"), true);
  });

  it("round-trips idempotency legs", () => {
    assert.equal(store.getLeg("relay:7"), undefined);
    store.putLeg({ key: "relay:7", status: "submitted", detail: "x" });
    assert.equal(store.getLeg("relay:7")?.status, "submitted");
    store.putLeg({ key: "relay:7", status: "confirmed", aptosTx: "0xabc", detail: "7" });
    const leg = store.getLeg("relay:7");
    assert.equal(leg?.status, "confirmed");
    assert.equal(leg?.aptosTx, "0xabc");
    assert.ok(leg?.updatedAt);
  });

  it("caps history at 100 entries, newest first", () => {
    for (let i = 0; i < 105; i++) store.log("step", `detail ${i}`);
    assert.equal(store.history.length, 100);
    assert.match(store.history[0].detail, /detail 104/);
  });

  it("writes atomically (no partial file)", () => {
    store.lastBlock = 1n;
    const raw = fs.readFileSync(path.join(dir, "relayer-state.json"), "utf8");
    assert.doesNotThrow(() => JSON.parse(raw));
    assert.equal(fs.existsSync(path.join(dir, "relayer-state.json.tmp")), false);
  });
});
