/// Swap API server: quote / lock / status / refund / health + static swap UI.
/// One-click demo: server holds a demo EVM key for lock() and the user-side
/// refund call. Solver daemon (solver.ts) fills independently.
import "dotenv/config";
import express from "express";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createEvmClient, readSwap, swapExists, ESCROW_WRITE_ABI } from "./escrow.js";
import { quoteAptOut, priceConfigFromEnv } from "./quote.js";
import { quoteEthOut, readReverseSwap, reverseSwapExists } from "./reverse.js";
import { loadEvmKey, loadEvmAddress, parseAmountField } from "./config.js";
import { createWalletClient, http, parseEther, formatEther, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { Aptos, AptosConfig, Network, Account, Ed25519PrivateKey } from "@aptos-labs/ts-sdk";

const PORT = Number(process.env.SWAP_PORT ?? 3201);
const HOST = process.env.SWAP_HOST ?? "127.0.0.1";
const EVM_RPC = process.env.ETH_RPC_URL ?? "http://127.0.0.1:8545";
const EVM_CHAIN_ID = Number(process.env.ETH_CHAIN_ID ?? 31337);
// Fail fast with actionable messages (see config.ts): an address pasted as a
// key, or a missing escrow, used to crash deep in noble internals.
const ESCROW = loadEvmAddress("SWAP_ESCROW_ADDRESS", "deployed SwapEscrow");
const { key: DEMO_KEY, account: demoAccount } = loadEvmKey("SWAP_DEMO_PRIVATE_KEY", "one-click demo locker");
const QUOTE_TTL_S = 300;
const DEADLINE_SECONDS = 86400; // 1 day refunds

// --- Reverse direction (APT -> ETH): same one-click model, Aptos side. ---
// R_ESCROW_ADMIN is the Move publisher account hosting swap_escrow::Config.
// R_USER_PK is the demo locker key (must hold testnet APT). Both optional:
// reverse endpoints return 501 until configured.
const R_ESCROW_ADMIN = (process.env.SWAP_REVERSE_ESCROW_ADMIN ?? "").trim() || null;
const _R_USER_PK = (process.env.SWAP_REVERSE_USER_PK ?? "").trim();
const RAPTOS_NODE = process.env.APTOS_NODE_URL ?? "https://fullnode.testnet.aptoslabs.com/v1";
// Gas budget for reverse txs. Default 100k (generous — localnet minimums
// reject tiny budgets); set APTOS_MAX_GAS=5000 when the demo wallet is
// nearly empty on testnet (deposit = maxGas * price must fit the balance).
const R_MAX_GAS = Number(process.env.APTOS_MAX_GAS ?? 100_000);
const raptos = new Aptos(new AptosConfig({ network: Network.CUSTOM, fullnode: RAPTOS_NODE }));
function rUserAccount(): Account {
  if (!_R_USER_PK) throw new Error("reverse demo locker not configured (set SWAP_REVERSE_USER_PK)");
  const hex = _R_USER_PK.startsWith("0x") ? _R_USER_PK.slice(2) : _R_USER_PK;
  if (!/^[0-9a-fA-F]{64}$/.test(hex)) throw new Error("SWAP_REVERSE_USER_PK must be a 32-byte ed25519 key");
  return Account.fromPrivateKey({ privateKey: new Ed25519PrivateKey(`0x${hex}`) });
}
function rEscrow(): string {
  if (!R_ESCROW_ADMIN || !/^0x[0-9a-fA-F]{64}$/.test(R_ESCROW_ADMIN)) {
    throw new Error("reverse escrow not configured (set SWAP_REVERSE_ESCROW_ADMIN to the Move publisher)");
  }
  return R_ESCROW_ADMIN;
}
// Reverse locks are idempotent per key, same as forward.
const rLockLedger = new Map<string, { txHash: string; swapId: number }>();

const app = express();
app.use(express.json());
app.use(express.static(path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "public")));

const client = createEvmClient(EVM_RPC, EVM_CHAIN_ID);
const wallet = createWalletClient({ account: demoAccount, transport: http(EVM_RPC, { timeout: 30_000 }) });

// Lock idempotency: UI double-clicks / retries with the same key return the
// recorded swap instead of locking twice. Entries are best-effort in-memory
// (a restart may re-lock — the chain remains the source of truth).
const lockLedger = new Map<string, { txHash: string; swapId: number }>();

// --- Activity log: every lifecycle step, user-side and solver-side, in one
// reverse-chron feed for the UI. In-memory ring (demo): a restart clears it
// and logs a marker so the gap is visible, not silent.
interface ActivityEntry {
  // swapId: forward legs are numbers; reverse legs are namespaced "r<id>"
  // (a plain number would collide with forward ids in the filter).
  time: string; swapId: number | string | null; source: "user" | "solver" | "server";
  step: string; detail: string; tx?: string; txKind?: "evm" | "aptos";
}
const ACTIVITY_CAP = 500;
const activity: ActivityEntry[] = [
  { time: new Date().toISOString(), swapId: null, source: "server", step: "restart", detail: "server booted — events below start here" },
];
function logActivity(e: Omit<ActivityEntry, "time">) {
  activity.unshift({ ...e, time: new Date().toISOString() });
  if (activity.length > ACTIVITY_CAP) activity.length = ACTIVITY_CAP;
}
// Optional shared secret for solver reports (demo default: open on localhost).
const REPORT_TOKEN = process.env.SWAP_REPORT_TOKEN ?? "";

app.get("/api/swap/activity", (req, res) => {
  const limit = Math.min(Math.max(Number(req.query.limit ?? 50) || 50, 1), 200);
  // swapId filter: digits (forward) or r<digits> (reverse) or null (all).
  const rawId = typeof req.query.swapId === "string" && req.query.swapId !== "" ? req.query.swapId : null;
  if (rawId !== null && !/^(r?\d+)$/.test(rawId)) {
    return res.status(400).json({ error: `swapId must be digits or r<digits>, got ${rawId}` });
  }
  const idNum = rawId === null ? null : Number(rawId.replace(/^r/, ""));
  const isReverse = rawId !== null && rawId.startsWith("r");
  const key = (a: ActivityEntry) => typeof a.swapId === "string" ? a.swapId : `n${a.swapId}`;
  const want = isReverse ? rawId! : `n${idNum}`;
  const list = rawId === null ? activity : activity.filter((a) => key(a) === want);
  res.json(list.slice(0, limit));
});

// Solver lifecycle reports (picked-up/quoted/won/filled/claimed/skipped/failed).
app.post("/api/swap/report", (req, res) => {
  try {
    if (REPORT_TOKEN && req.body.token !== REPORT_TOKEN) {
      return res.status(403).json({ error: "bad report token" });
    }
    const { swapId, step, detail, tx, txKind } = req.body as {
      swapId?: unknown; step?: unknown; detail?: unknown; tx?: unknown; txKind?: unknown;
    };
    if (typeof step !== "string" || !/^[a-z0-9-]{1,40}$/.test(step)) throw new Error("step must be [a-z0-9-] ≤40 chars");
    if (typeof detail !== "string" || detail.length === 0 || detail.length > 300) throw new Error("detail must be 1..300 chars");
    let id: number | string | null = null;
    if (swapId !== undefined && swapId !== null) {
      if (!/^(r?\d+)$/.test(String(swapId))) throw new Error("swapId must be digits or r<digits>");
      id = String(swapId).startsWith("r") ? String(swapId) : Number(swapId);
    }
    let hash: string | undefined;
    let kind: "evm" | "aptos" | undefined;
    if (tx !== undefined) {
      if (typeof tx !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(tx)) throw new Error("tx must be 0x + 64 hex");
      hash = tx;
      kind = txKind === "aptos" ? "aptos" : "evm";
    }
    logActivity({ swapId: id, source: "solver", step, detail, tx: hash, txKind: kind });
    res.json({ ok: true });
  } catch (e) {
    res.status(400).json({ error: (e as Error).message });
  }
});

function octasToApt(octas: bigint): string {
  return (Number(octas) / 1e8).toFixed(8).replace(/\.?0+$/, "");
}

app.get("/api/swap/health", (_req, res) => {
  const cfg = priceConfigFromEnv();
  res.json({ solver: "online (daemon)", spreadBps: cfg.spreadBps, ethUsd: cfg.ethUsd, aptUsd: cfg.aptUsd, escrow: ESCROW });
});

app.post("/api/swap/quote", (req, res) => {
  try {
    const ethAmount = String(req.body.ethAmount ?? "");
    const ethWei = parseEther(ethAmount);
    if (ethWei <= 0n) throw new Error("amount must be positive");
    const cfg = priceConfigFromEnv();
    const out = quoteAptOut(ethWei, cfg);
    logActivity({ swapId: null, source: "user", step: "quoted",
      detail: `${ethAmount} ETH -> ${octasToApt(out)} APT (${out} octas, ${cfg.spreadBps}bps spread)` });
    res.json({
      ethAmount, ethWei: ethWei.toString(),
      aptOut: octasToApt(out), minOutOctas: out.toString(),
      quoteTtlS: QUOTE_TTL_S, deadlineDays: DEADLINE_SECONDS / 86400,
      ethUsd: cfg.ethUsd, aptUsd: cfg.aptUsd, spreadBps: cfg.spreadBps,
      escrow: ESCROW,
    });
  } catch (e) {
    res.status(400).json({ error: (e as Error).message });
  }
});

const LOCK_ABI = [
  { name: "lock", type: "function", stateMutability: "payable",
    inputs: [{ type: "bytes" }, { type: "uint256" }, { type: "uint64" }],
    outputs: [{ type: "uint64" }] },
] as const;

app.post("/api/swap/lock", async (req, res) => {
  try {
    const { ethAmount, aptosRecipient, minOutOctas } = req.body as {
      ethAmount: string; aptosRecipient: string; minOutOctas: string;
    };
    if (!aptosRecipient || !/^0x[0-9a-fA-F]{64}$/.test(aptosRecipient)) {
      throw new Error("aptosRecipient must be 0x + 64 hex chars (32-byte BCS address)");
    }
    const minOut = parseAmountField(minOutOctas, "minOutOctas");
    if (minOut <= 0n) throw new Error("minOutOctas must be > 0");
    // Idempotent retry: same key returns the first lock, never a second one.
    const idemKey = typeof req.body.idempotencyKey === "string" && req.body.idempotencyKey
      ? req.body.idempotencyKey : null;
    if (idemKey && lockLedger.has(idemKey)) {
      return res.json({ ...lockLedger.get(idemKey), replayed: true });
    }
    const value = parseEther(String(ethAmount));
    // Re-quote server-side so minOut can't be spoofed above market.
    const cfg = priceConfigFromEnv();
    const fresh = quoteAptOut(value, cfg);
    if (minOut > fresh) throw new Error(`minOut ${minOut} above fresh quote ${fresh}`);
    // Pre-check the demo balance so users get "insufficient funds", not a
    // raw revert after signing.
    const bal = await client.getBalance({ address: demoAccount.address });
    if (bal < value) {
      throw new Error(`demo account ${demoAccount.address} holds ${formatEther(bal)} ETH, need ${ethAmount}`);
    }
    const hash = await wallet.writeContract({
      address: ESCROW, abi: LOCK_ABI, functionName: "lock",
      args: [aptosRecipient as Hex, minOut, BigInt(DEADLINE_SECONDS)],
      value, account: demoAccount, chain: undefined,
    });
    // swapId: look up the SwapLocked event in the lock tx receipt.
    const receipt = await client.waitForTransactionReceipt({ hash });
    const { decodeEventLog } = await import("viem");
    const { ESCROW_ABI } = await import("./escrow.js");
    let swapId = -1;
    for (const log of receipt.logs) {
      try {
        const dec = decodeEventLog({ abi: ESCROW_ABI, ...log });
        if (dec.eventName === "SwapLocked") { swapId = Number((dec.args as { swapId: bigint }).swapId); break; }
      } catch { /* not our event */ }
    }
    if (swapId < 0) throw new Error(`lock tx ${hash} confirmed but no SwapLocked event found — check escrow ${ESCROW}`);
    const out = { txHash: hash, swapId };
    if (idemKey) lockLedger.set(idemKey, out);
    logActivity({ swapId, source: "user", step: "locked",
      detail: `${ethAmount} ETH locked, minOut ${minOut} octas -> ${(aptosRecipient as string).slice(0, 10)}…`, tx: hash, txKind: "evm" });
    res.json(out);
  } catch (e) {
    res.status(400).json({ error: (e as Error).message.slice(0, 300) });
  }
});

app.get("/api/swap/status/:id", async (req, res) => {
  try {
    if (!/^\d+$/.test(req.params.id)) throw new Error(`swap id must be a non-negative integer, got ${req.params.id}`);
    const s = await readSwap(client, ESCROW, BigInt(req.params.id));
    if (!swapExists(s)) {
      return res.status(404).json({ error: `swap ${req.params.id} does not exist` });
    }
    const now = BigInt(Math.floor(Date.now() / 1000));
    res.json({
      user: s.user, amountEth: formatEther(s.amount), minOutOctas: s.minOut.toString(),
      deadline: new Date(Number(s.deadline) * 1000).toISOString(),
      claimed: s.claimSolver !== "0x0000000000000000000000000000000000000000",
      settled: s.claimed, refunded: s.refunded,
      refundable: now > s.deadline && !s.claimed && !s.refunded,
    });
  } catch (e) {
    res.status(400).json({ error: (e as Error).message.slice(0, 200) });
  }
});

const REFUND_ABI = [{ name: "refund", type: "function", inputs: [{ type: "uint64" }], outputs: [] }] as const;

app.post("/api/swap/refund", async (req, res) => {
  try {
    if (req.body.swapId === undefined || !/^\d+$/.test(String(req.body.swapId))) {
      throw new Error("swapId must be a non-negative integer");
    }
    // Friendly pre-checks so users get "too early" / "already settled",
    // not a raw contract revert.
    const s = await readSwap(client, ESCROW, BigInt(req.body.swapId));
    if (!swapExists(s)) {
      throw new Error(`swap ${req.body.swapId} does not exist`);
    }
    if (s.refunded) throw new Error(`swap ${req.body.swapId} already refunded`);
    if (s.claimSolver !== "0x0000000000000000000000000000000000000000") {
      throw new Error(`swap ${req.body.swapId} was claimed by a solver — no refund`);
    }
    const now = BigInt(Math.floor(Date.now() / 1000));
    if (now <= s.deadline) {
      throw new Error(`swap ${req.body.swapId} not yet refundable — deadline ${new Date(Number(s.deadline) * 1000).toISOString()}`);
    }
    // Demo: server key must BE the depositor (one-click locks from demo key).
    const hash = await wallet.writeContract({
      address: ESCROW, abi: REFUND_ABI, functionName: "refund",
      args: [BigInt(req.body.swapId)], account: demoAccount, chain: undefined,
    });
    logActivity({ swapId: Number(req.body.swapId), source: "user", step: "refunded",
      detail: `${formatEther(s.amount)} ETH returned to depositor`, tx: hash, txKind: "evm" });
    res.json({ txHash: hash });
  } catch (e) {
    res.status(400).json({ error: (e as Error).message.slice(0, 300) });
  }
});

app.get("/api/healthz", (_req, res) => res.json({ ok: true }));

// ------------------------- reverse direction (APT -> ETH) -----------------
app.post("/api/swap/rquote", (req, res) => {
  try {
    const octas = parseAmountField(String(req.body.aptOctas ?? ""), "aptOctas");
    if (octas <= 0n) throw new Error("aptOctas must be > 0");
    const cfg = priceConfigFromEnv();
    const out = quoteEthOut(octas, cfg);
    logActivity({ swapId: null, source: "user", step: "r-quoted",
      detail: `${octas} octas -> ${formatEther(out)} ETH (${out} wei, ${cfg.spreadBps}bps spread)` });
    res.json({
      aptOctas: octas.toString(), ethOut: formatEther(out), minOutWei: out.toString(),
      quoteTtlS: QUOTE_TTL_S, deadlineDays: DEADLINE_SECONDS / 86400,
      ethUsd: cfg.ethUsd, aptUsd: cfg.aptUsd, spreadBps: cfg.spreadBps,
      escrowAdmin: R_ESCROW_ADMIN,
    });
  } catch (e) {
    res.status(400).json({ error: (e as Error).message.slice(0, 300) });
  }
});

app.post("/api/swap/rlock", async (req, res) => {
  try {
    const admin = rEscrow();
    const { aptOctas, evmRecipient, minOutWei } = req.body as {
      aptOctas: string; evmRecipient: string; minOutWei: string;
    };
    if (!evmRecipient || !/^0x[0-9a-fA-F]{40}$/.test(evmRecipient)) {
      throw new Error("evmRecipient must be 0x + 40 hex chars (20-byte EVM address)");
    }
    const amount = parseAmountField(String(aptOctas ?? ""), "aptOctas");
    if (amount <= 0n) throw new Error("aptOctas must be > 0");
    const minOut = parseAmountField(String(minOutWei ?? ""), "minOutWei");
    if (minOut <= 0n) throw new Error("minOutWei must be > 0");
    const idemKey = typeof req.body.idempotencyKey === "string" && req.body.idempotencyKey
      ? `r:${req.body.idempotencyKey}` : null;
    if (idemKey && rLockLedger.has(idemKey)) {
      return res.json({ ...rLockLedger.get(idemKey), replayed: true });
    }
    // Re-quote server-side so minOut can't be spoofed above market.
    const cfg = priceConfigFromEnv();
    const fresh = quoteEthOut(amount, cfg);
    if (minOut > fresh) throw new Error(`minOut ${minOut} above fresh quote ${fresh}`);
    const locker = rUserAccount();
    // Pre-check APT balance for a friendly error instead of a raw abort.
    const bal = await raptos.getAccountAPTAmount({ accountAddress: locker.accountAddress });
    if (BigInt(bal) < amount) {
      throw new Error(`demo locker ${locker.accountAddress} holds ${bal} octas, need ${amount}`);
    }
    const deadline = BigInt(Math.floor(Date.now() / 1000) + DEADLINE_SECONDS);
    // vector<u8> args must be byte arrays — a "0x..." string would be
    // encoded as ASCII, tripping EBAD_RECIPIENT on-chain (observed live).
    const recipientBytes = Array.from(Buffer.from(evmRecipient.slice(2), "hex"));
    const txn = await raptos.transaction.build.simple({
      sender: locker.accountAddress,
      data: {
        function: `${admin}::swap_escrow::lock`,
        functionArguments: [admin, recipientBytes, amount.toString(), minOut.toString(), deadline.toString()],
      },
      // A simple lock costs ~3-5k units; small demo wallets can't cover a big
      // deposit, so keep the budget tight (deposit = maxGas * price).
      options: { maxGasAmount: R_MAX_GAS },
    });
    const submitted = await raptos.signAndSubmitTransaction({ signer: locker, transaction: txn });
    await raptos.waitForTransaction({ transactionHash: submitted.hash });
    // swapId: next_swap_id - 1 (our lock just incremented it).
    const nextId = await raptos.view({
      payload: { function: `${admin}::swap_escrow::next_swap_id`, typeArguments: [], functionArguments: [admin] },
    });
    const swapId = Number((nextId as string[])[0]) - 1;
    if (swapId < 0) throw new Error(`rlock tx ${submitted.hash} confirmed but next_swap_id unreadable — check escrow ${admin}`);
    const out = { txHash: submitted.hash, swapId };
    if (idemKey) rLockLedger.set(idemKey, out);
    logActivity({ swapId: `r${swapId}`, source: "user", step: "r-locked",
      detail: `${amount} octas locked, minOut ${minOut} wei -> ${evmRecipient.slice(0, 10)}…`, tx: submitted.hash, txKind: "aptos" });
    res.json(out);
  } catch (e) {
    res.status(400).json({ error: (e as Error).message.slice(0, 300) });
  }
});

app.get("/api/swap/rstatus/:id", async (req, res) => {
  try {
    const admin = rEscrow();
    if (!/^\d+$/.test(req.params.id)) throw new Error(`swap id must be a non-negative integer, got ${req.params.id}`);
    const s = await readReverseSwap(raptos, admin, BigInt(req.params.id));
    if (!reverseSwapExists(s)) {
      return res.status(404).json({ error: `reverse swap ${req.params.id} does not exist` });
    }
    const now = BigInt(Math.floor(Date.now() / 1000));
    res.json({
      user: s.user, evmRecipient: s.evmRecipient, amountOctas: s.amount.toString(), minOutWei: s.minOut.toString(),
      deadline: new Date(Number(s.deadline) * 1000).toISOString(),
      claimed: s.claimed, settled: s.claimed && s.refunded, refunded: s.refunded && !s.claimed,
      claimableAt: s.claimableAt > 0n ? new Date(Number(s.claimableAt) * 1000).toISOString() : null,
      refundable: now >= s.deadline && !s.claimed && !s.refunded,
    });
  } catch (e) {
    res.status(400).json({ error: (e as Error).message.slice(0, 300) });
  }
});

app.post("/api/swap/rrefund", async (req, res) => {
  try {
    const admin = rEscrow();
    if (req.body.swapId === undefined || !/^\d+$/.test(String(req.body.swapId))) {
      throw new Error("swapId must be a non-negative integer");
    }
    const s = await readReverseSwap(raptos, admin, BigInt(req.body.swapId));
    if (!reverseSwapExists(s)) throw new Error(`reverse swap ${req.body.swapId} does not exist`);
    if (s.refunded) throw new Error(`reverse swap ${req.body.swapId} already settled/refunded`);
    if (s.claimed) throw new Error(`reverse swap ${req.body.swapId} was claimed by a solver — no refund`);
    const now = BigInt(Math.floor(Date.now() / 1000));
    if (now < s.deadline) {
      throw new Error(`reverse swap ${req.body.swapId} not yet refundable — deadline ${new Date(Number(s.deadline) * 1000).toISOString()}`);
    }
    // Demo: server key must BE the depositor (one-click locks from demo key).
    const locker = rUserAccount();
    const txn = await raptos.transaction.build.simple({
      sender: locker.accountAddress,
      data: { function: `${admin}::swap_escrow::refund`, functionArguments: [admin, String(req.body.swapId)] },
      options: { maxGasAmount: R_MAX_GAS },
    });
    const submitted = await raptos.signAndSubmitTransaction({ signer: locker, transaction: txn });
    await raptos.waitForTransaction({ transactionHash: submitted.hash });
    logActivity({ swapId: `r${req.body.swapId}`, source: "user", step: "r-refunded",
      detail: `${s.amount} octas returned to depositor`, tx: submitted.hash, txKind: "aptos" });
    res.json({ txHash: submitted.hash });
  } catch (e) {
    res.status(400).json({ error: (e as Error).message.slice(0, 300) });
  }
});

// Settle a matured reverse claim (anyone may call; solver convenience).
app.post("/api/swap/rsettle", async (req, res) => {
  try {
    const admin = rEscrow();
    if (req.body.swapId === undefined || !/^\d+$/.test(String(req.body.swapId))) {
      throw new Error("swapId must be a non-negative integer");
    }
    const s = await readReverseSwap(raptos, admin, BigInt(req.body.swapId));
    if (!reverseSwapExists(s)) throw new Error(`reverse swap ${req.body.swapId} does not exist`);
    if (!s.claimed) throw new Error(`reverse swap ${req.body.swapId} has no pending claim`);
    if (s.refunded) throw new Error(`reverse swap ${req.body.swapId} already settled`);
    const now = BigInt(Math.floor(Date.now() / 1000));
    if (now < s.claimableAt) {
      throw new Error(`reverse swap ${req.body.swapId} not yet settleable — matures ${new Date(Number(s.claimableAt) * 1000).toISOString()}`);
    }
    const caller = rUserAccount();
    const txn = await raptos.transaction.build.simple({
      sender: caller.accountAddress,
      data: { function: `${admin}::swap_escrow::settle`, functionArguments: [admin, String(req.body.swapId)] },
      options: { maxGasAmount: R_MAX_GAS },
    });
    const submitted = await raptos.signAndSubmitTransaction({ signer: caller, transaction: txn });
    await raptos.waitForTransaction({ transactionHash: submitted.hash });
    logActivity({ swapId: `r${req.body.swapId}`, source: "user", step: "r-settled",
      detail: `${s.amount} octas released to solver ${s.claimSolver.slice(0, 10)}…`, tx: submitted.hash, txKind: "aptos" });
    res.json({ txHash: submitted.hash });
  } catch (e) {
    res.status(400).json({ error: (e as Error).message.slice(0, 300) });
  }
});

app.listen(PORT, HOST, async () => {
  console.log(`swap UI: http://${HOST}:${PORT}/swap.html`);
  // Fail LOUD at boot if the escrow address has no code (wrong address or
  // chain): otherwise every lock fails later with a confusing estimate-gas
  // error instead of one clear line here.
  try {
    const code = await client.getCode({ address: ESCROW });
    if (!code || code === "0x") {
      console.error(`FATAL: no contract code at SWAP_ESCROW_ADDRESS=${ESCROW} on chain ${EVM_CHAIN_ID} — fix the address`);
      process.exit(1);
    }
  } catch (e) {
    console.error(`FATAL: cannot reach EVM RPC ${EVM_RPC}: ${(e as Error).message.slice(0, 150)}`);
    process.exit(1);
  }
});
