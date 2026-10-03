import { describe, it, before, after } from "node:test";
import assert from "node:assert/strict";
import http from "node:http";
import type { AddressInfo } from "node:net";
import { maybeAlert } from "../src/alerts.js";
import type { HealthReport } from "../src/monitor.js";

describe("maybeAlert", () => {
  const posts: string[] = [];
  let server: http.Server;
  let url = "";

  before(async () => {
    server = http.createServer((req, res) => {
      let b = "";
      req.on("data", (c) => (b += c));
      req.on("end", () => { posts.push(b); res.end("ok"); });
    });
    await new Promise<void>((r) => server.listen(0, r));
    url = `http://127.0.0.1:${(server.address() as AddressInfo).port}/hook`;
    process.env.ALERT_WEBHOOK_URL = url;
    process.env.ALERT_COOLDOWN_S = "1";
  });

  after(() => { server.close(); delete process.env.ALERT_WEBHOOK_URL; });

  const errReport = (detail = "break"): HealthReport => ({
    ok: false, vaultEscrow: "100", aptosSupply: "50",
    checkedAt: new Date().toISOString(),
    issues: [{ level: "error", check: "conservation", detail }],
  });
  const okReport = (): HealthReport => ({
    ok: true, vaultEscrow: "0", aptosSupply: "0",
    checkedAt: new Date().toISOString(), issues: [],
  });

  it("pages once per incident, suppresses within cooldown, re-pages after expiry, then all-clears", async () => {
    await maybeAlert(errReport()); // pages
    await maybeAlert(errReport()); // suppressed (cooldown)
    assert.equal(posts.length, 1);
    assert.match(posts[0], /conservation/);
    await new Promise((r) => setTimeout(r, 1200));
    await maybeAlert(errReport()); // pages again (cooldown expired)
    assert.equal(posts.length, 2);
    await maybeAlert(okReport()); // all-clear
    await new Promise((r) => setTimeout(r, 200));
    assert.equal(posts.length, 3);
    assert.match(posts[2], /all errors cleared/);
  });

  it("stays silent when healthy and sends no duplicate all-clear", async () => {
    const before = posts.length;
    await maybeAlert(okReport());
    await maybeAlert(okReport());
    assert.equal(posts.length, before);
  });
});
