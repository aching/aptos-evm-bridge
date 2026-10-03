/// Paging for bridge incidents: POSTs error-level health issues to a webhook
/// (Slack-compatible) with per-check cooldown so each incident pages once,
/// plus an all-clear when errors resolve. Warn-level issues are logged only.
/// Env (ALERT_WEBHOOK_URL, ALERT_COOLDOWN_S) is read lazily on each call so
/// tests and late-bound config work.
import type { HealthReport } from "./monitor.js";

// check name -> timestamp of last alert sent
const lastAlerted = new Map<string, number>();
let allClearSent = true;

function shouldFire(check: string, now: number, cooldownMs: number): boolean {
  const last = lastAlerted.get(check) ?? 0;
  if (now - last < cooldownMs) return false;
  lastAlerted.set(check, now);
  return true;
}

export async function maybeAlert(report: HealthReport): Promise<void> {
  const webhook = process.env.ALERT_WEBHOOK_URL ?? "";
  const cooldownMs = Number(process.env.ALERT_COOLDOWN_S ?? 3600) * 1000;
  const errors = report.issues.filter((i) => i.level === "error");
  if (!webhook) {
    if (errors.length > 0) {
      console.error(`[alert] (no webhook configured) ${errors.map((e) => `${e.check}: ${e.detail}`).join(" | ")}`);
    }
    return;
  }
  const now = Date.now();
  const fresh = errors.filter((e) => shouldFire(e.check, now, cooldownMs));
  try {
    if (fresh.length > 0) {
      allClearSent = false;
      await fetch(webhook, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          text: `🚨 OKRW bridge: ${fresh.map((e) => `*${e.check}* ${e.detail}`).join("\n")}\nescrow=${report.vaultEscrow} supply=${report.aptosSupply} at ${report.checkedAt}`,
        }),
      });
      console.error(`[alert] paged ${fresh.length} issue(s): ${fresh.map((e) => e.check).join(", ")}`);
    } else if (errors.length === 0 && !allClearSent) {
      allClearSent = true;
      await fetch(webhook, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ text: `✅ OKRW bridge: all errors cleared at ${report.checkedAt}` }),
      });
      console.log("[alert] all-clear sent");
    }
  } catch (e) {
    console.error(`[alert] webhook POST failed: ${(e as Error).message.slice(0, 150)}`);
  }
}
