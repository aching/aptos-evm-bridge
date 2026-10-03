import "dotenv/config";
import express from "express";
import path from "node:path";
import { fileURLToPath } from "node:url";
// Crash guard: a single failed RPC (e.g. Maroo eth_getLogs timeout
// surfacing through got/p-cancelable internals) must NEVER take down the
// server. Log it and keep serving — the next tick/retry recovers.
process.on("unhandledRejection", (reason) => {
  console.error(`[crash-guard] unhandled rejection (server stays up): ${String(reason).slice(0, 300)}`);
});
process.on("uncaughtException", (err) => {
  console.error(`[crash-guard] uncaught exception (server stays up): ${err.message.slice(0, 300)}`);
});
import { createMarooClient, getDeposits, type DepositEvent } from "./maroon.js";
import {
  createAptos,
  relayerAccount,
  mintAttested,
  burnWithdraw,
  okrwBalance,
} from "./aptos.js";
import { Store } from "./store.js";
import { checkHealth } from "./monitor.js";
import { maybeAlert } from "./alerts.js";
import { friendlyError } from "./errors.js";
import { createWalletClient, http, parseAbiItem, type Address, type Hash } from "viem";
import { privateKeyToAccount } from "viem/accounts";

// ------------------------------------------------------------------ config
// TESTNET DEMO ONLY. This server holds live private keys in relayer/.env and
// signs with them on request — convenient for a one-click demo, NEVER a
// pattern for mainnet or real value. See README § Trust model.
const MAROO_RPC = process.env.MAROO_RPC_URL ?? "https://rpc-testnet.maroo.io";
const MAROO_CHAIN_ID = Number(process.env.MAROO_CHAIN_ID ?? 450815);
const VAULT = process.env.MAROO_VAULT_ADDRESS as Address;
const MAROO_USER_PK = process.env.MAROO_USER_PRIVATE_KEY as Hash;
const MAROO_RELAYER_PK = process.env.MAROO_RELAYER_PRIVATE_KEY as Hash;
const APTOS_NODE = process.env.APTOS_NODE_URL ?? "https://fullnode.testnet.aptoslabs.com/v1";
const MODULE_ADDR = process.env.APTOS_MODULE_ADDRESS!;
const BRIDGE_ADDR = process.env.APTOS_BRIDGE_ADDRESS!;
const OKRW_METADATA = process.env.APTOS_OKRW_METADATA!;
const APTOS_RELAYER_PK = process.env.APTOS_RELAYER_PRIVATE_KEY!;
const APTOS_USER_PK = process.env.APTOS_USER_PRIVATE_KEY!;
const APTOS_USER_ADDR = process.env.APTOS_USER_ADDRESS!;
const APTOS_EXPLORER = "https://explorer.aptoslabs.com/txn";
const MAROO_EXPLORER = "https://explorer-testnet.maroo.io/tx";
const DATA_DIR = process.env.RELAYER_DATA_DIR ?? path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "data");

const RELEASE_ABI = [
  parseAbiItem("function release(address to, uint256 amount, uint64 nonce)"),
  parseAbiItem("function nextReleaseNonce() view returns (uint64)"),
  parseAbiItem("function nextDepositNonce() view returns (uint64)"),
] as const;

for (const [k, v] of Object.entries({ VAULT, MAROO_USER_PK, MAROO_RELAYER_PK, MODULE_ADDR, BRIDGE_ADDR, OKRW_METADATA, APTOS_RELAYER_PK, APTOS_USER_PK, APTOS_USER_ADDR })) {
  if (!v) { console.error(`Missing env: ${k}`); process.exit(1); }
}

// ------------------------------------------------------------------ clients
const maroo = createMarooClient(MAROO_RPC, MAROO_CHAIN_ID);
const aptos = createAptos(APTOS_NODE);
const aptosRelayer = relayerAccount(APTOS_RELAYER_PK);
const aptosUser = relayerAccount(APTOS_USER_PK);
const marooChain = {
  id: MAROO_CHAIN_ID, name: "maroo-testnet",
  nativeCurrency: { name: "tOKRW", symbol: "tOKRW", decimals: 18 },
  rpcUrls: { default: { http: [MAROO_RPC] } },
} as const;
const marooUserWallet = createWalletClient({
  account: privateKeyToAccount(MAROO_USER_PK), transport: http(MAROO_RPC), chain: marooChain,
});
const marooRelayerWallet = createWalletClient({
  account: privateKeyToAccount(MAROO_RELAYER_PK), transport: http(MAROO_RPC), chain: marooChain,
});

const store = new Store(DATA_DIR);

// ------------------------------------------------------------------ helpers
const toAptosRecipient = (addr: string) => (addr.startsWith("0x") ? addr : `0x${addr}`);

/** Retry fn with exponential backoff (max ~30s total). Retries network/RPC
 *  hiccups but NOT on-chain rejections (those throw AbortError-ish messages
 *  containing "abort" or "revert" — fail fast, they're deterministic). */
async function withRetry<T>(label: string, fn: () => Promise<T>, tries = 4): Promise<T> {
  let last: unknown;
  for (let i = 0; i < tries; i++) {
    try {
      return await fn();
    } catch (e) {
      last = e;
      const msg = (e as Error).message;
      if (/abort|revert|denied|insufficient/i.test(msg)) throw e; // deterministic — don't retry
      const wait = 1000 * 2 ** i;
      console.log(`[retry] ${label} attempt ${i + 1} failed (${msg.slice(0, 120)}), waiting ${wait}ms`);
      await new Promise((r) => setTimeout(r, wait));
    }
  }
  throw last;
}

/** Wait for a Maroo tx receipt and assert success (status === "success").
 *  Never return early on submit-hash alone — the UI polls on this. */
async function waitMarooSuccess(hash: `0x${string}`) {
  const receipt = await maroo.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`Maroo tx ${hash} reverted`);
  return receipt;
}

// ------------------------------------------------------------------ app
const app = express();
app.use(express.json());
app.use(express.static(path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "public")));

app.get("/api/config", (_req, res) => {
  res.json({
    vault: VAULT,
    moduleAddr: MODULE_ADDR,
    bridgeAddr: BRIDGE_ADDR,
    okrwMetadata: OKRW_METADATA,
    aptosUser: APTOS_USER_ADDR,
    marooUser: marooUserWallet.account.address,
    marooRelayer: marooRelayerWallet.account.address,
    aptosRelayer: aptosRelayer.accountAddress.toString(),
  });
});

app.get("/api/balances", async (req, res) => {
  try {
    // Optional ?aptosUser= override: lets the UI track a custom recipient's
    // OKRW balance (wallet mode) instead of the demo user's.
    const watchUser = typeof req.query.aptosUser === "string" &&
      /^0x[0-9a-fA-F]{64}$/.test(req.query.aptosUser)
      ? req.query.aptosUser
      : APTOS_USER_ADDR;
    const [userTokrw, vaultEscrow, userOkrw, relayerOkrw, depositNonce] = await Promise.all([
      withRetry("maroo.getBalance(user)", () => maroo.getBalance({ address: marooUserWallet.account.address })),
      withRetry("maroo.getBalance(vault)", () => maroo.getBalance({ address: VAULT })),
      withRetry("okrwBalance(user)", () => okrwBalance(aptos, watchUser, OKRW_METADATA)),
      withRetry("okrwBalance(relayer)", () => okrwBalance(aptos, aptosRelayer.accountAddress.toString(), OKRW_METADATA)),
      withRetry("nextDepositNonce", () => maroo.readContract({ address: VAULT, abi: RELEASE_ABI, functionName: "nextDepositNonce" })),
    ]);
    res.json({
      marooUser: userTokrw.toString(),
      vaultEscrow: vaultEscrow.toString(),
      aptosUser: userOkrw.toString(),
      aptosUserWatched: watchUser,
      aptosRelayer: relayerOkrw.toString(),
      nextDepositNonce: depositNonce.toString(),
    });
  } catch (e) {
    res.status(500).json({ error: friendlyError(e, "balances") });
  }
});

app.get("/api/history", (_req, res) => res.json(store.history));

app.get("/api/health", async (_req, res) => {
  try {
    const report = await checkHealth({
      maroo, aptos, vault: VAULT, metadata: OKRW_METADATA,
      aptosUser: APTOS_USER_ADDR,
      aptosRelayer: aptosRelayer.accountAddress.toString(),
      bridgeAddr: BRIDGE_ADDR, moduleAddr: MODULE_ADDR,
    });
    res.status(report.ok ? 200 : 503).json(report);
  } catch (e) {
    res.status(500).json({ error: friendlyError(e, "health") });
  }
});

// Step 1: user locks tOKRW on Maroo. Idempotency key = client-supplied or
// derived; replays return the recorded result instead of re-submitting.
app.post("/api/deposit", async (req, res) => {
  try {
    const amount = BigInt(req.body.amount as string); // base units (aokrw)
    if (amount <= 0n) throw new Error("amount must be > 0");
    const recipient = typeof req.body.recipient === "string" && req.body.recipient.length > 0
      ? req.body.recipient as string
      : APTOS_USER_ADDR;
    if (!/^0x[0-9a-fA-F]{64}$/.test(toAptosRecipient(recipient))) {
      throw new Error("recipient must be a 32-byte 0x Aptos address");
    }
    const key = `deposit:${req.body.idempotencyKey as string ?? `${amount}:${recipient}:${Date.now()}`}`;
    const prior = store.getLeg(key);
    if (prior && prior.status === "confirmed") {
      return res.json({ hash: prior.marooTx, nonce: prior.detail, blockNumber: "", replayed: true });
    }
    store.putLeg({ key, status: "submitted", detail: "deposit submitted" });
    const hash = await withRetry("deposit submit", () => marooUserWallet.writeContract({
      address: VAULT,
      abi: [parseAbiItem("function deposit(bytes aptosRecipient) returns (uint64)")],
      functionName: "deposit",
      args: [toAptosRecipient(recipient) as unknown as `0x${string}`],
      value: amount,
    } as never));
    const receipt = await waitMarooSuccess(hash); // confirmed, not just submitted
    const nonce = (await withRetry("nextDepositNonce", () => maroo.readContract({
      address: VAULT, abi: RELEASE_ABI, functionName: "nextDepositNonce",
    }))) - 1n;
    store.putLeg({ key, status: "confirmed", marooTx: hash, detail: nonce.toString() });
    store.log("deposit", `Locked ${(Number(amount) / 1e18).toFixed(4)} tOKRW (deposit nonce ${nonce}) -> ${shortAddr(recipient)}`, { marooTx: hash });
    // Wake the auto-relay loop for this deposit's block (deposit-triggered,
    // not blind polling). No-op if autorelay is disabled.
    ((globalThis as Record<string, unknown>).__relayWake as ((b: bigint) => void) | undefined)?.(receipt.blockNumber);
    res.json({ hash, nonce: nonce.toString(), blockNumber: receipt.blockNumber.toString() });
  } catch (e) {
    res.status(500).json({ error: friendlyError(e, "deposit") });
  }
});

// ------------------------------------------------------------------ attest
// Shared attestation path: idempotency check -> finality wait -> u64 check
// -> mintAttested -> persist + log. Used by BOTH the manual /api/relay
// endpoint and the background auto-relay loop, so the two can never diverge.
// In-memory inFlight set guards against concurrent attest of the same nonce
// (loop tick racing a manual click); on-chain EALREADY_ATTESTED is the final
// backstop.
const inFlight = new Set<string>();
const CONFIRMATIONS = BigInt(process.env.MAROO_CONFIRMATIONS ?? 2);

// Live relay progress per nonce for the UI stepper: stage + timestamp.
// attestDeposit updates it; /api/relay-status reads it. Entries are trimmed
// when the attestation completes (finally block) — the queue panel remains
// the durable record.
export type RelayStage = "finality" | "submitting" | "confirming";
const relayProgress = new Map<string, { stage: RelayStage; since: number }>();

async function attestDeposit(d: DepositEvent): Promise<{ hash: string; nonce: string }> {
  const nonceStr = d.nonce.toString();
  const key = `relay:${nonceStr}`;
  const prior = store.getLeg(key);
  if (prior && prior.status === "confirmed") {
    return { hash: prior.aptosTx as string, nonce: nonceStr };
  }
  if (inFlight.has(nonceStr)) throw new Error(`nonce ${nonceStr} attestation already in flight`);
  inFlight.add(nonceStr);
  relayProgress.set(nonceStr, { stage: "finality", since: Date.now() });
  try {
    // Precise finality wait: poll head until the deposit has CONFIRMATIONS
    // on top (or time out) instead of a flat sleep. Fresh deposits wait
    // exactly as long as needed; already-final ones proceed immediately.
    const deadline = Date.now() + 60000;
    for (;;) {
      const cur = await maroo.getBlockNumber();
      if (cur >= d.blockNumber + CONFIRMATIONS) break;
      if (Date.now() > deadline) throw new Error(`finality timeout for nonce ${nonceStr}`);
      await new Promise((r) => setTimeout(r, 1500));
    }
    if (d.amount > 18446744073709551615n) throw new Error("amount exceeds u64");
    store.putLeg({ key, status: "submitted", detail: `relay nonce ${nonceStr}` });
    const tx = await withRetry("mintAttested", () => mintAttested(
      aptos, aptosRelayer, MODULE_ADDR, OKRW_METADATA,
      toAptosRecipient(d.aptosRecipient), d.amount, d.nonce,
      (s) => relayProgress.set(nonceStr, { stage: s, since: Date.now() }),
    )).catch((e: unknown) => {
      // Reconcile: the on-chain Seen table is authoritative. If the nonce
      // was already attested (e.g. by the standalone forward.ts watcher or
      // before a store wipe), adopt that fact locally instead of retrying
      // forever. mintAttested waits for the tx, so any other abort means it
      // did NOT land -> rethrow.
      if (/EALREADY_ATTESTED/.test((e as Error).message)) {
        console.log(`[autorelay] nonce ${nonceStr} already attested on-chain; reconciling local store`);
        store.putLeg({ key, status: "confirmed", detail: nonceStr });
        store.addForward(nonceStr);
        store.log("relay-reconciled", `Maroo nonce ${nonceStr} was already minted on Aptos; adopted into local ledger (no new mint)`);
        return null;
      }
      throw e;
    });
    if (tx === null) return { hash: "(already attested on-chain)", nonce: nonceStr };
    // mintAttested waits for the Aptos tx; a throw means it did NOT land.
    store.putLeg({ key, status: "confirmed", aptosTx: tx.hash, detail: nonceStr });
    store.addForward(nonceStr);
    store.log("relay", `Minted ${(Number(d.amount) / 1e18).toFixed(4)} OKRW on Aptos (maroo nonce ${nonceStr})`, { aptosTx: tx.hash });
    return { hash: tx.hash, nonce: nonceStr };
  } finally {
    inFlight.delete(nonceStr);
    relayProgress.delete(nonceStr);
  }
}

// Live progress for one in-flight relay (UI stepper). 404 when idle/done.
app.get("/api/relay-status", (req, res) => {
  const p = relayProgress.get(String(req.query.nonce ?? ""));
  if (!p) return res.status(404).json({ error: "no relay in flight for this nonce" });
  res.json({ stage: p.stage, elapsedS: Math.round((Date.now() - p.since) / 1000) });
});

// Oldest unattested deposit in [fromBlock, head]. Attested = in the local
// store (fast path); the on-chain Seen table remains the authoritative guard
// if the store was ever wiped. Scans in CHUNK-sized ranges: a single 2000+
// block eth_getLogs times out against the Maroo RPC (and the timeout once
// crashed the server via got internals), so large ranges are fanned out.
const SCAN_CHUNK = BigInt(process.env.MAROO_SCAN_CHUNK ?? 250);
async function oldestPending(fromBlock: bigint): Promise<{ deposits: DepositEvent[]; target: DepositEvent | undefined }> {
  const head = await withRetry("getBlockNumber", () => maroo.getBlockNumber());
  if (head < fromBlock) return { deposits: [], target: undefined };
  const deposits: DepositEvent[] = [];
  for (let from = fromBlock; from <= head; from += SCAN_CHUNK) {
    const to = from + SCAN_CHUNK - 1n > head ? head : from + SCAN_CHUNK - 1n;
    deposits.push(...await withRetry("getDeposits", () => getDeposits(maroo, VAULT, from, to)));
  }
  deposits.sort((a, b) => (a.nonce < b.nonce ? -1 : a.nonce > b.nonce ? 1 : 0));
  return { deposits, target: deposits.find((d) => !store.hasForward(d.nonce.toString())) };
}

// Step 2 (manual): attest the OLDEST unattested deposit in range — the
// "relay now" fallback/expedite for the background loop. An explicit nonce
// overrides the ordering (catch-up / retry of one deposit).
app.post("/api/relay", async (req, res) => {
  try {
    const fromBlock = BigInt(req.body.fromBlock as string);
    const { deposits, target: oldest } = await oldestPending(fromBlock);
    const target = req.body.nonce !== undefined
      ? deposits.find((d) => d.nonce === BigInt(req.body.nonce as string))
      : oldest;
    if (!target) throw new Error("no unattested deposit found in range");
    const nonceStr = target.nonce.toString();
    const wasAlready = store.getLeg(`relay:${nonceStr}`)?.status === "confirmed";
    const { hash, nonce } = await attestDeposit(target);
    res.json({ hash, nonce, replayed: wasAlready || undefined });
  } catch (e) {
    res.status(500).json({ error: friendlyError(e, "relay") });
  }
});
// Pending queue for the UI: recent deposits with attested status.
app.get("/api/pending", async (req, res) => {
  try {
    const lookback = BigInt(req.query.lookback as string ?? "5000");
    const head = await withRetry("getBlockNumber", () => maroo.getBlockNumber());
    const from = head > lookback ? head - lookback : 0n;
    const deposits: DepositEvent[] = [];
    for (let f = from; f <= head; f += SCAN_CHUNK) {
      const t = f + SCAN_CHUNK - 1n > head ? head : f + SCAN_CHUNK - 1n;
      deposits.push(...await withRetry("getDeposits", () => getDeposits(maroo, VAULT, f, t)));
    }
    deposits.sort((a, b) => (a.nonce < b.nonce ? -1 : a.nonce > b.nonce ? 1 : 0));
    res.json(deposits.map((d) => ({
      nonce: d.nonce.toString(),
      amount: d.amount.toString(),
      recipient: toAptosRecipient(d.aptosRecipient),
      txHash: d.txHash,
      blockNumber: d.blockNumber.toString(),
      attested: store.hasForward(d.nonce.toString()),
      inFlight: inFlight.has(d.nonce.toString()),
    })));
  } catch (e) {
    res.status(500).json({ error: friendlyError(e, "relay") });
  }
});

// Step 3: user sends OKRW back to relayer (transfer), relayer burns + releases.
// Wallet mode: pass { skipTransfer: true } when the user already transferred
// with their own wallet — the server only burns + releases.
app.post("/api/bridge-back", async (req, res) => {
  try {
    const amount = BigInt(req.body.amount as string);
    if (amount <= 0n) throw new Error("amount must be > 0");
    const marooRecipient = marooUserWallet.account.address;
    const skipTransfer = req.body.skipTransfer === true;
    const key = `back:${req.body.idempotencyKey as string ?? `${amount}:${Date.now()}`}`;
    const prior = store.getLeg(key);
    if (prior && prior.status === "confirmed") {
      return res.json({ transferHash: prior.aptosTx, burnHash: prior.detail, releaseHash: prior.marooTx, replayed: true });
    }
    store.putLeg({ key, status: "submitted", detail: "bridge-back submitted" });

    // 3a. user transfers OKRW to relayer on Aptos (dispatch hooks enforced).
    // Skipped in wallet mode — the user transferred with their own key.
    let transferHash = "(sent by user wallet)";
    if (!skipTransfer) {
      const transferTxn = await aptos.transaction.build.simple({
        sender: aptosUser.accountAddress,
        data: {
          function: "0x1::primary_fungible_store::transfer",
          typeArguments: ["0x1::fungible_asset::Metadata"],
          functionArguments: [OKRW_METADATA, BRIDGE_ADDR, amount.toString()],
        },
      });
      const t = await withRetry("user transfer submit", () =>
        aptos.signAndSubmitTransaction({ signer: aptosUser, transaction: transferTxn }));
      await aptos.waitForTransaction({ transactionHash: t.hash }); // throws on abort
      transferHash = t.hash;
    }

    // 3b. relayer burns + releases on Maroo.
    const burnRes = await withRetry("burnWithdraw", () => burnWithdraw(
      aptos, aptosRelayer, MODULE_ADDR, OKRW_METADATA,
      APTOS_USER_ADDR, amount, marooRecipient,
    ));
    const nonce = await withRetry("nextReleaseNonce", () => maroo.readContract({ address: VAULT, abi: RELEASE_ABI, functionName: "nextReleaseNonce" }));
    const releaseHash = await withRetry("release submit", () => marooRelayerWallet.writeContract({
      address: VAULT, abi: RELEASE_ABI, functionName: "release",
      args: [marooRecipient, amount, nonce],
    }));
    await waitMarooSuccess(releaseHash); // confirmed release, not just submitted
    store.putLeg({ key, status: "confirmed", aptosTx: transferHash.startsWith("0x") ? transferHash : undefined, marooTx: releaseHash, detail: burnRes.hash });
    store.addBack(nonce.toString());
    store.log(
      "bridge-back",
      `Burned ${(Number(amount) / 1e18).toFixed(4)} OKRW, released on Maroo`,
      { aptosTx: burnRes.hash, marooTx: releaseHash },
    );
    res.json({ transferHash, burnHash: burnRes.hash, releaseHash });
  } catch (e) {
    res.status(500).json({ error: friendlyError(e, "bridge-back") });
  }
});

// Live security state for the panel: coin/bridge pause flags, caps + usage,
// and whether a given address is denylisted.
app.get("/api/security-status", async (req, res) => {
  try {
    const account = typeof req.query.account === "string" ? req.query.account : null;
    const [coinPaused, bridgeCfg, denylisted] = await Promise.all([
      aptos.view({ payload: {
        function: `${MODULE_ADDR}::okrw::is_paused` as `${string}::${string}::${string}`,
        functionArguments: [OKRW_METADATA],
      } }),
      aptos.getAccountResource({
        accountAddress: BRIDGE_ADDR,
        resourceType: `${MODULE_ADDR}::bridge::Config`,
      }) as unknown as Promise<Record<string, string>>,
      account && /^0x[0-9a-fA-F]{64}$/.test(account)
        ? aptos.view({ payload: {
            function: `${MODULE_ADDR}::okrw::is_denylisted` as `${string}::${string}::${string}`,
            functionArguments: [OKRW_METADATA, account],
          } })
        : Promise.resolve([false]),
    ]);
    res.json({
      coinPaused: (coinPaused as boolean[])[0] === true,
      bridgePaused: (bridgeCfg as unknown as Record<string, unknown>).paused === true,
      dailyMintCap: String((bridgeCfg as unknown as Record<string, string>).daily_mint_cap ?? "0"),
      mintedToday: String((bridgeCfg as unknown as Record<string, string>).minted_today ?? "0"),
      denylisted: Array.isArray(denylisted) ? denylisted[0] === true : false,
    });
  } catch (e) {
    res.status(500).json({ error: friendlyError(e, "health") });
  }
});

// Manual recovery: release escrowed tOKRW stranded by burns whose Maroo
// release never landed (escrow > supply). Computes the gap, releases up to
// the remaining daily cap window, and reports any remainder for the next
// window. Same nonce-ordered, idempotent release path as bridge-back.
app.post("/api/recover", async (req, res) => {
  try {
    const key = `recover:${req.body.idempotencyKey as string ?? Date.now()}`;
    const prior = store.getLeg(key);
    if (prior && prior.status === "confirmed") {
      return res.json({ releaseHash: prior.marooTx, released: prior.detail, replayed: true });
    }
    const report = await checkHealth({
      maroo, aptos, vault: VAULT, metadata: OKRW_METADATA,
      aptosUser: APTOS_USER_ADDR,
      aptosRelayer: aptosRelayer.accountAddress.toString(),
      bridgeAddr: BRIDGE_ADDR, moduleAddr: MODULE_ADDR,
    });
    const gap = BigInt(report.vaultEscrow) - BigInt(report.aptosSupply);
    if (gap <= 0n) throw new Error("no stranded escrow: vault balance does not exceed Aptos supply");
    const CAP_ABI = [
      parseAbiItem("function dailyReleaseCap() view returns (uint256)"),
      parseAbiItem("function releasedToday() view returns (uint256)"),
    ] as const;
    const [cap, used] = await Promise.all([
      withRetry("dailyReleaseCap", () => maroo.readContract({ address: VAULT, abi: CAP_ABI, functionName: "dailyReleaseCap" })),
      withRetry("releasedToday", () => maroo.readContract({ address: VAULT, abi: CAP_ABI, functionName: "releasedToday" })),
    ]);
    const room = (cap as bigint) - (used as bigint);
    if (room <= 0n) throw new Error("daily release window exhausted — retry after UTC midnight rollover");
    const amount = gap < room ? gap : room;
    const to = marooUserWallet.account.address;
    store.putLeg({ key, status: "submitted", detail: `recover ${amount}` });
    const nonce = await withRetry("nextReleaseNonce", () => maroo.readContract({ address: VAULT, abi: RELEASE_ABI, functionName: "nextReleaseNonce" }));
    const releaseHash = await withRetry("release submit", () => marooRelayerWallet.writeContract({
      address: VAULT, abi: RELEASE_ABI, functionName: "release",
      args: [to, amount, nonce],
    }));
    await waitMarooSuccess(releaseHash);
    const remainder = gap - amount;
    store.putLeg({ key, status: "confirmed", marooTx: releaseHash, detail: amount.toString() });
    store.addBack(nonce.toString());
    store.log("recover", `Released ${(Number(amount) / 1e18).toFixed(4)} stranded tOKRW to ${shortAddr(to)}${remainder > 0n ? ` — ${(Number(remainder) / 1e18).toFixed(4)} remains for next window` : " — books balanced"}`, { marooTx: releaseHash });
    res.json({ releaseHash, released: amount.toString(), remainder: remainder.toString() });
  } catch (e) {
    res.status(500).json({ error: friendlyError(e, "bridge-back") });
  }
});

app.get("/api/links", (_req, res) => res.json({ aptos: APTOS_EXPLORER, maroo: MAROO_EXPLORER }));

// Security controls: exposes the coin + bridge safety rails (pause, denylist,
// caps, emergency pause) through the UI, signed server-side with the role
// keys the server holds (relayer = minter/pauser/bridge-owner, user =
// denylister). Role *rotation* (admin-only) stays CLI-only — the server does
// not hold the publisher key. Every action is idempotent-safe and logged.
const APTOS_TX = (fn: string, signer: { accountAddress: unknown }, args: unknown[]) => ({
  fn, signer, args,
});

async function submitAptosEntry(
  fn: `${string}::${string}::${string}`,
  signer: ReturnType<typeof relayerAccount>,
  functionArguments: unknown[],
  typeArguments: string[] = [],
): Promise<string> {
  const txn = await aptos.transaction.build.simple({
    sender: signer.accountAddress,
    data: { function: fn, functionArguments: functionArguments as never[], ...(typeArguments.length ? { typeArguments } : {}) },
  });
  const r = await withRetry(fn, () =>
    aptos.signAndSubmitTransaction({ signer, transaction: txn }));
  await aptos.waitForTransaction({ transactionHash: r.hash }); // throws on abort
  return r.hash;
}

app.post("/api/security", async (req, res) => {
  try {
    const action = req.body.action as string;
    const aptosUserSigner = relayerAccount(APTOS_USER_PK); // denylister role
    let hash = "";
    let detail = "";
    switch (action) {
      case "pause-coin": {
        hash = await submitAptosEntry(`${MODULE_ADDR}::okrw::pause`, aptosRelayer, [OKRW_METADATA]);
        detail = "Coin paused (transfers, mint, burn frozen)";
        break;
      }
      case "unpause-coin": {
        hash = await submitAptosEntry(`${MODULE_ADDR}::okrw::unpause`, aptosRelayer, [OKRW_METADATA]);
        detail = "Coin unpaused";
        break;
      }
      case "pause-bridge": {
        hash = await submitAptosEntry(`${MODULE_ADDR}::bridge::pause`, aptosRelayer, []);
        detail = "Bridge paused (mint attestation + burns frozen)";
        break;
      }
      case "unpause-bridge": {
        hash = await submitAptosEntry(`${MODULE_ADDR}::bridge::unpause`, aptosRelayer, []);
        detail = "Bridge unpaused";
        break;
      }
      case "emergency-pause": {
        hash = await submitAptosEntry(`${MODULE_ADDR}::bridge::emergency_pause`, aptosRelayer, [OKRW_METADATA]);
        detail = "EMERGENCY: coin + bridge paused in one tx";
        break;
      }
      case "denylist": {
        const account = req.body.account as string;
        if (!/^0x[0-9a-fA-F]{64}$/.test(account)) throw new Error("account must be a 32-byte 0x Aptos address");
        hash = await submitAptosEntry(`${MODULE_ADDR}::okrw::denylist`, aptosUserSigner, [OKRW_METADATA, account]);
        detail = `Denylisted ${shortAddr(account)} (frozen: no transfers/mint/burn)`;
        break;
      }
      case "undenylist": {
        const account = req.body.account as string;
        if (!/^0x[0-9a-fA-F]{64}$/.test(account)) throw new Error("account must be a 32-byte 0x Aptos address");
        hash = await submitAptosEntry(`${MODULE_ADDR}::okrw::undenylist`, aptosUserSigner, [OKRW_METADATA, account]);
        detail = `Removed ${shortAddr(account)} from denylist`;
        break;
      }
      case "set-mint-cap": {
        const cap = BigInt(req.body.cap as string);
        if (cap <= 0n) throw new Error("cap must be > 0");
        if (cap > 18446744073709551615n) throw new Error("cap exceeds u64 (max ~18.45 OKRW at 18 decimals)");
        hash = await submitAptosEntry(`${MODULE_ADDR}::bridge::set_daily_mint_cap`, aptosRelayer, [cap.toString()]);
        detail = `Daily mint cap set to ${(Number(cap) / 1e18).toFixed(2)} OKRW`;
        break;
      }
      default:
        throw new Error(`unknown security action: ${action}`);
    }
    store.log("security", `${detail} (tx ${shortAddr(hash)})`, { aptosTx: hash });
    res.json({ hash, detail });
  } catch (e) {
    res.status(500).json({ error: friendlyError(e, "health") });
  }
});

// Liveness probe for hosting platforms (Fly, Render...). Local-only, never
// touches a chain — keep /api/health (deep check) out of the check path.
app.get("/api/healthz", (_req, res) => res.json({ ok: true }));

function shortAddr(a: string) {
  return a.length > 16 ? `${a.slice(0, 10)}…${a.slice(-6)}` : a;
}

const PORT = Number(process.env.PORT ?? process.env.WEB_PORT ?? 3013);
const HOST = process.env.HOST ?? "0.0.0.0";
app.listen(PORT, HOST, () => console.log(`bridge demo UI: http://${HOST}:${PORT} (data: ${DATA_DIR})`));

// Background auto-relay loop: the real-bridge behavior. Polls Maroo for new
// deposits and attests each one oldest-first, exactly once (store ledger +
// on-chain Seen table). This is what makes deposit 0.5 then 1.0 Just Work:
// nonce N is attested before N+1 with no clicks. Manual /api/relay remains
// as the "relay now" expedite (shares attestDeposit + inFlight guard, so the
// two can never double-mint).
// ON by default; set AUTORELAY_ENABLED=0 to run manual-only (step-by-step
// narration). Cadence via RELAY_POLL_S (default 15). Cursor shared with the
// standalone forward.ts watcher through the persisted store.
// Cold start (no cursor): scans back AUTORELAY_LOOKBACK blocks (default
// 2000) so deposits that landed while the server was down/fresh are still
// picked up; already-attested nonces are skipped idempotently.
if (process.env.AUTORELAY_ENABLED !== "0") {
  const RELAY_POLL_MS = Number(process.env.RELAY_POLL_S ?? 60) * 1000;
  const LOOKBACK = BigInt(process.env.AUTORELAY_LOOKBACK ?? 2000);
  const SWEEP_EVERY = 10; // every Nth tick, re-scan the lookback window (self-healing)
  let relayRunning = false; // no overlapping ticks
  let tickCount = 0;
  const runAutoRelay = async (fromOverride?: bigint) => {
    if (relayRunning) return;
    relayRunning = true;
    try {
      tickCount += 1;
      const head = await maroo.getBlockNumber();
      // Normal ticks scan only new blocks; every SWEEP_EVERY-th tick
      // re-scans the lookback window so nothing behind the cursor is ever
      // stranded (e.g. after downtime, cursor jumps, or RPC gaps).
      // A fromOverride (deposit-triggered wake-up) scans just that range.
      let from: bigint;
      if (fromOverride !== undefined) {
        from = fromOverride;
      } else if (tickCount % SWEEP_EVERY === 0) {
        from = head > LOOKBACK ? head - LOOKBACK : 0n;
        console.log(`[autorelay] sweep tick: re-scanning ${LOOKBACK} blocks from ${from}`);
      } else if (store.lastBlock !== null) {
        from = store.lastBlock + 1n;
      } else if (process.env.MAROO_START_BLOCK) {
        from = BigInt(process.env.MAROO_START_BLOCK) + 1n;
        console.log(`[autorelay] one-time catch-up from Maroo block ${from - 1n} (MAROO_START_BLOCK)`);
      } else {
        from = head > LOOKBACK ? head - LOOKBACK : 0n;
        console.log(`[autorelay] cold start: scanning back ${LOOKBACK} blocks from ${head}`);
      }
      if (head < from) {
        if (head > (store.lastBlock ?? -1n)) store.lastBlock = head;
        return;
      }
      // Process ALL unattested deposits oldest-first within the tick, then
      // advance the cursor past the whole range. (Processing one per tick
      // and persisting head would strand everything in between.)
      const { deposits } = await oldestPending(from);
      const pending = deposits.filter((d) => !store.hasForward(d.nonce.toString()));
      for (const d of pending) {
        console.log(`[autorelay] attesting nonce ${d.nonce} (${(Number(d.amount) / 1e18).toFixed(4)} OKRW)`);
        await attestDeposit(d);
      }
      if (head > (store.lastBlock ?? -1n)) store.lastBlock = head;
    } catch (e) {
      console.error(`[autorelay] tick failed (will retry): ${(e as Error).message.slice(0, 200)}`);
    } finally {
      relayRunning = false;
    }
  };
  console.log(`[autorelay] enabled, safety-net every ${RELAY_POLL_MS / 1000}s (AUTORELAY_ENABLED=0 to disable)`);
  setInterval(() => void runAutoRelay(), RELAY_POLL_MS);
  // Deposit-triggered wake-up: the deposit endpoint schedules a targeted
  // sweep at this deposit's block once finality is plausible, instead of
  // waiting for the next blind tick. attestDeposit itself still enforces the
  // confirmation wait, so this is purely a latency optimization.
  (globalThis as Record<string, unknown>).__relayWake = (depositBlock: bigint) => {
    const waitMs = 1000; // attestDeposit enforces finality precisely; this just yields to block propagation
    console.log(`[autorelay] wake-up scheduled for block ${depositBlock} in ${waitMs}ms`);
    setTimeout(() => void runAutoRelay(depositBlock), waitMs);
  };
}

// Background monitor loop: deep health check on an interval, paging error-
// level issues (conservation break, cap exhaustion) to ALERT_WEBHOOK_URL.
// Opt-in via MONITOR_ENABLED=1 so local dev servers don't page anyone.
// Interval via MONITOR_INTERVAL_S (default 300). Failures of the check itself
// are logged, never crash the server.
if (process.env.MONITOR_ENABLED === "1") {
  const INTERVAL_MS = Number(process.env.MONITOR_INTERVAL_S ?? 300) * 1000;
  const runMonitor = async () => {
    try {
      const report = await checkHealth({
        maroo, aptos, vault: VAULT, metadata: OKRW_METADATA,
        aptosUser: APTOS_USER_ADDR,
        aptosRelayer: aptosRelayer.accountAddress.toString(),
        bridgeAddr: BRIDGE_ADDR, moduleAddr: MODULE_ADDR,
      });
      if (!report.ok) {
        store.log("monitor", `health: ${report.issues.map((i) => `[${i.level}] ${i.check}: ${i.detail}`).join(" | ")}`);
      }
      await maybeAlert(report);
    } catch (e) {
      console.error(`[monitor] check failed: ${(e as Error).message.slice(0, 200)}`);
    }
  };
  console.log(`[monitor] enabled, every ${INTERVAL_MS / 1000}s (webhook ${process.env.ALERT_WEBHOOK_URL ? "set" : "NOT SET — errors log only"})`);
  void runMonitor();
  setInterval(() => void runMonitor(), INTERVAL_MS);
}
