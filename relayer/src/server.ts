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
import { createWalletClient, http, parseAbiItem, getAddress, type Address, type Hash } from "viem";
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
  account: privateKeyToAccount(MAROO_USER_PK), transport: http(MAROO_RPC, { timeout: 30_000 }), chain: marooChain,
});
const marooRelayerWallet = createWalletClient({
  account: privateKeyToAccount(MAROO_RELAYER_PK), transport: http(MAROO_RPC, { timeout: 30_000 }), chain: marooChain,
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
      // Maroo RPC quirk: "Missing or invalid parameters" on eth_getLogs is a
      // deterministic RPC limitation (range too wide), NOT transient — the
      // 8-block fan-out in getDeposits handles legit ranges, so anything
      // reaching here will fail identically on retry. Fail fast.
      if (/Missing or invalid parameters/i.test(msg)) throw e;
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

// ------------------------------------------------------------------ swap
// Multi-solver auction + proven-fill (trustless) API. Swap contracts are
// optional: endpoints 404 with a clear error until SWAP_* env is set.
// The demo solver key doubles as the quote/fill account; the server wallet
// submits lock/notify/finalize/prove/claim/settle on request (demo only).
// viem validates EIP-55 checksums: normalize env addresses (often lowercase from forge output).
const normAddr = (a: string): Address => {
  try { return getAddress(a); } catch { return a as Address; }
};
const SWAP_ESCROW: Address | undefined = process.env.SWAP_ESCROW_ADDRESS ? normAddr(process.env.SWAP_ESCROW_ADDRESS) : undefined;
const SWAP_AUCTION: Address | undefined = process.env.SWAP_AUCTION_ADDRESS ? normAddr(process.env.SWAP_AUCTION_ADDRESS) : undefined;
const SWAP_LC: Address | undefined = process.env.SWAP_LC_ADDRESS ? normAddr(process.env.SWAP_LC_ADDRESS) : undefined;
const swapReady = () => SWAP_ESCROW && SWAP_AUCTION && SWAP_LC;
const needSwap = () => {
  if (!swapReady()) throw new Error("swap contracts not configured (set SWAP_ESCROW_ADDRESS, SWAP_AUCTION_ADDRESS, SWAP_LC_ADDRESS)");
};

const ESCROW_ABI = [
  parseAbiItem("function lock(bytes aptosRecipient, uint256 minOut, uint64 deadlineSeconds) returns (uint64)"),
  parseAbiItem("function claimProven(uint64 swapId, bytes32 leafHash, uint64 leafIndex, bytes32[] siblings, address payoutSolver)"),
  parseAbiItem("function settle(uint64 swapId)"),
  parseAbiItem("function nextSwapId() view returns (uint64)"),
] as const;
const AUCTION_ABI = [
  parseAbiItem("function notifyLock(uint64 swapId)"),
  parseAbiItem("function submitQuote(uint64 swapId, uint256 aptOut, uint64 expiry, uint256 minOut)"),
  parseAbiItem("function finalize(uint64 swapId) returns (address)"),
  parseAbiItem("function quotes(uint64 swapId, uint256 index) view returns (address solver, uint256 aptOut, uint64 expiry)"),
  parseAbiItem("function quoteCount(uint64 swapId) view returns (uint256)"),
  parseAbiItem("event QuoteSubmitted(uint64 indexed swapId, address indexed solver, uint256 aptOut)"),
  parseAbiItem("function winner(uint64) view returns (address)"),
  parseAbiItem("function finalized(uint64) view returns (bool)"),
  parseAbiItem("function lockTime(uint64) view returns (uint64)"),
  parseAbiItem("function auctionWindow() view returns (uint64)"),
  parseAbiItem("error AlreadyFinalized()"),
] as const;
const LC_ABI = [
  parseAbiItem("function submitQC(bytes bcs, bytes bitmask, bytes sig)"),
  parseAbiItem("function latestRoot() view returns (bytes32)"),
  parseAbiItem("function latestVersion() view returns (uint64)"),
] as const;

app.get("/api/swap/config", (_req, res) => {
  res.json({
    ready: swapReady() === undefined ? false : true,
    escrow: SWAP_ESCROW ?? null, auction: SWAP_AUCTION ?? null, lightClient: SWAP_LC ?? null,
    user: marooUserWallet.account.address,
  });
});

/** Swap status: lock + quotes + winner + light-client head + escrow claim state. */
app.get("/api/swap/status", async (req, res) => {
  try {
    needSwap();
    const swapId = BigInt(req.query.swapId as string);
    const [lockT, fin, win, winAt, root, ver] = await Promise.all([
      withRetry("lockTime", () => maroo.readContract({ address: SWAP_AUCTION!, abi: AUCTION_ABI, functionName: "lockTime", args: [swapId] })),
      withRetry("finalized", () => maroo.readContract({ address: SWAP_AUCTION!, abi: AUCTION_ABI, functionName: "finalized", args: [swapId] })),
      withRetry("winner", () => maroo.readContract({ address: SWAP_AUCTION!, abi: AUCTION_ABI, functionName: "winner", args: [swapId] })),
      withRetry("auctionWindow", () => maroo.readContract({ address: SWAP_AUCTION!, abi: AUCTION_ABI, functionName: "auctionWindow" })),
      withRetry("latestRoot", () => maroo.readContract({ address: SWAP_LC!, abi: LC_ABI, functionName: "latestRoot" })),
      withRetry("latestVersion", () => maroo.readContract({ address: SWAP_LC!, abi: LC_ABI, functionName: "latestVersion" })),
    ]);
    const quotes: Array<{ solver: string; aptOut: string; expiry: string }> = [];
    try {
      const nq = Number(await withRetry("quoteCount", () => maroo.readContract({
        address: SWAP_AUCTION!, abi: AUCTION_ABI, functionName: "quoteCount", args: [swapId],
      })) as bigint);
      for (let i = 0; i < Math.min(nq, 25); i++) {
        const q = await withRetry(`quotes[${i}]`, () => maroo.readContract({
          address: SWAP_AUCTION!, abi: AUCTION_ABI, functionName: "quotes", args: [swapId, BigInt(i)],
        })) as unknown as [string, bigint, bigint];
        quotes.push({ solver: q[0], aptOut: (q[1] as bigint).toString(), expiry: (q[2] as bigint).toString() });
      }
    } catch {
      // quoteCount may not exist on older deployments — fall back to recent
      // QuoteSubmitted events for this swap.
      try {
        // Maroo post-reset quirk: eth_getLogs rejects wide ranges, so scan
        // back in 8-block windows (same shape as getDeposits in maroon.ts).
        const quoteEv = AUCTION_ABI.find((a) => (a as { name?: string }).name === "QuoteSubmitted");
        const head = await withRetry("getBlockNumber", () => maroo.getBlockNumber());
        const all: Array<{ args: { swapId: bigint; solver: string; aptOut: bigint } }> = [];
        const QSTEP = 8n;
        for (let f = 0n; f <= head; f += QSTEP) {
          const t = f + QSTEP - 1n > head ? head : f + QSTEP - 1n;
          const chunk = await withRetry("quoteLogs", () => maroo.getLogs({
            address: SWAP_AUCTION!, event: quoteEv as never, fromBlock: f, toBlock: t,
          }));
          all.push(...(chunk as Array<{ args: { swapId: bigint; solver: string; aptOut: bigint } }>));
        }
        const logs = all;
        const best = new Map<string, { aptOut: bigint; expiry?: bigint }>();
        for (const l of logs as Array<{ args: { swapId: bigint; solver: string; aptOut: bigint } }>) {
          if (l.args.swapId !== swapId) continue;
          const prev = best.get(l.args.solver);
          if (!prev || l.args.aptOut > prev.aptOut) best.set(l.args.solver, { aptOut: l.args.aptOut });
        }
        for (const [solver, q] of best) quotes.push({ solver, aptOut: q.aptOut.toString(), expiry: "0" });
      } catch { /* quotes stay empty — non-fatal */ }
    }
    const swap = await withRetry("swaps", () => maroo.readContract({
      address: SWAP_ESCROW!,
      abi: [parseAbiItem("function swaps(uint64) view returns (address user, bytes aptosRecipient, uint256 amount, uint256 minOut, uint64 deadline, bool claimed, bool refunded, bytes32 fillHash, uint64 claimableAt, address claimSolver)")],
      functionName: "swaps", args: [swapId],
    })) as unknown as [string, string, bigint, bigint, bigint, boolean, boolean, string, bigint, string];
    res.json({
      swapId: swapId.toString(),
      lockTime: (lockT as bigint).toString(), finalized: fin as boolean, winner: win as string,
      auctionWindow: (winAt as bigint).toString(),
      quotes,
      latestRoot: root as string, latestVersion: (ver as bigint).toString(),
      escrow: {
        user: swap[0], amount: (swap[2] as bigint).toString(), minOut: (swap[3] as bigint).toString(),
        deadline: (swap[4] as bigint).toString(), claimed: swap[5], refunded: swap[6],
        fillHash: swap[7], claimableAt: (swap[8] as bigint).toString(), claimSolver: swap[9],
      },
    });
  } catch (e) {
    res.status(500).json({ error: friendlyError(e, "swap status") });
  }
});

/** Lock ETH for a swap. Returns swapId. */
app.post("/api/swap/lock", async (req, res) => {
  try {
    needSwap();
    const amount = BigInt(req.body.amount as string);
    if (amount <= 0n) throw new Error("amount must be > 0");
    const recipient = toAptosRecipient(req.body.recipient as string);
    if (!/^0x[0-9a-fA-F]{64}$/.test(recipient)) throw new Error("recipient must be a 32-byte 0x Aptos address");
    const minOut = BigInt(req.body.minOut as string ?? "1");
    const deadlineSeconds = BigInt(req.body.deadlineSeconds as string ?? "86400");
    const key = `swap-lock:${req.body.idempotencyKey as string ?? `${amount}:${recipient}:${Date.now()}`}`;
    const prior = store.getLeg(key);
    if (prior && prior.status === "confirmed") return res.json({ swapId: prior.detail, hash: prior.marooTx, replayed: true });
    store.putLeg({ key, status: "submitted", detail: "swap lock submitted" });
    const nextId = await withRetry("nextSwapId", () => maroo.readContract({ address: SWAP_ESCROW!, abi: ESCROW_ABI, functionName: "nextSwapId" })) as bigint;
    const hash = await withRetry("lock submit", () => marooUserWallet.writeContract({
      address: SWAP_ESCROW!, abi: ESCROW_ABI, functionName: "lock",
      args: [recipient as unknown as `0x${string}`, minOut, deadlineSeconds], value: amount,
    } as never));
    await waitMarooSuccess(hash);
    store.putLeg({ key, status: "confirmed", marooTx: hash, detail: nextId.toString() });
    store.log("swap-lock", `Swap ${nextId} locked ${(Number(amount) / 1e18).toFixed(4)} ETH -> ${shortAddr(recipient)}`, { marooTx: hash });
    res.json({ swapId: nextId.toString(), hash });
  } catch (e) {
    res.status(500).json({ error: friendlyError(e, "swap lock") });
  }
});

/** Notify the auction + submit a solver quote (demo solver key). */
app.post("/api/swap/quote", async (req, res) => {
  try {
    needSwap();
    const swapId = BigInt(req.body.swapId as string);
    const aptOut = BigInt(req.body.aptOut as string);
    const minOut = BigInt(req.body.minOut as string ?? "1");
    const expiry = BigInt(req.body.expiry as string ?? `${Math.floor(Date.now() / 1000) + 86400}`);
    const key = `swap-quote:${swapId}:${marooUserWallet.account.address}:${aptOut}`;
    const prior = store.getLeg(key);
    if (prior && prior.status === "confirmed") return res.json({ hash: prior.marooTx, replayed: true });
    store.putLeg({ key, status: "submitted", detail: "quote submitted" });
    // notifyLock's AlreadyFinalized (0x475a2535) means "already notified"
    // (lockTime set) — but viem wraps it in ContractFunctionExecutionError
    // whose message does NOT match /abort|revert/, so withRetry burns 4
    // attempts (~15s) before we check chain state. Pre-check instead.
    const alreadyNotified = await withRetry("lockTime", () => maroo.readContract({
      address: SWAP_AUCTION!, abi: AUCTION_ABI, functionName: "lockTime", args: [swapId],
    }) as Promise<bigint>);
    try {
      if (alreadyNotified === 0n) {
        const nHash = await withRetry("notifyLock", () => marooUserWallet.writeContract({
          address: SWAP_AUCTION!, abi: AUCTION_ABI, functionName: "notifyLock", args: [swapId],
        } as never));
        await waitMarooSuccess(nHash);
      }
    } catch (e) {
      // already notified (race) — continue to quote; anything else rethrows.
      const already = await withRetry("lockTime", () => maroo.readContract({
        address: SWAP_AUCTION!, abi: AUCTION_ABI, functionName: "lockTime", args: [swapId],
      }) as Promise<bigint>);
      if (already === 0n) throw e;
    }
    const hash = await withRetry("submitQuote", () => marooUserWallet.writeContract({
      address: SWAP_AUCTION!, abi: AUCTION_ABI, functionName: "submitQuote",
      args: [swapId, aptOut, expiry, minOut],
    } as never));
    await waitMarooSuccess(hash);
    store.putLeg({ key, status: "confirmed", marooTx: hash, detail: aptOut.toString() });
    store.log("swap-quote", `Quote ${aptOut} octas on swap ${swapId}`, { marooTx: hash });
    res.json({ hash });
  } catch (e) {
    res.status(500).json({ error: friendlyError(e, "swap quote") });
  }
});

/** Finalize the auction (anyone may call after the window). Returns winner. */
app.post("/api/swap/finalize", async (req, res) => {
  try {
    needSwap();
    const swapId = BigInt(req.body.swapId as string);
    const hash = await withRetry("finalize", () => marooUserWallet.writeContract({
      address: SWAP_AUCTION!, abi: AUCTION_ABI, functionName: "finalize", args: [swapId],
    } as never));
    const receipt = await waitMarooSuccess(hash);
    const winner = await withRetry("winner", () => maroo.readContract({ address: SWAP_AUCTION!, abi: AUCTION_ABI, functionName: "winner", args: [swapId] })) as string;
    store.log("swap-finalize", `Swap ${swapId} winner ${shortAddr(winner)}`, { marooTx: hash });
    res.json({ hash, winner, blockNumber: receipt.blockNumber.toString() });
  } catch (e) {
    res.status(500).json({ error: friendlyError(e, "swap finalize") });
  }
});

/** Submit a QC to the light client. Body: { bcs, bitmask, sig } as 0x hex. */
app.post("/api/swap/submit-qc", async (req, res) => {
  try {
    needSwap();
    const { bcs, bitmask, sig } = req.body as { bcs: string; bitmask: string; sig: string };
    if (!/^0x[0-9a-fA-F]+$/.test(bcs) || !/^0x[0-9a-fA-F]+$/.test(bitmask) || !/^0x[0-9a-fA-F]+$/.test(sig)) {
      throw new Error("bcs/bitmask/sig must be 0x hex");
    }
    const key = `swap-qc:${bcs.slice(0, 66)}`;
    const prior = store.getLeg(key);
    if (prior && prior.status === "confirmed") return res.json({ hash: prior.marooTx, replayed: true });
    store.putLeg({ key, status: "submitted", detail: "QC submitted" });
    // QC verification is pairing-heavy (~250M gas in tests): viem's
    // estimation under-quotes, so set an explicit generous limit.
    const hash = await withRetry("submitQC", () => marooUserWallet.writeContract({
      address: SWAP_LC!, abi: LC_ABI, functionName: "submitQC",
      args: [bcs as `0x${string}`, bitmask as `0x${string}`, sig as `0x${string}`],
      gas: 300_000_000n,
    } as never));
    await waitMarooSuccess(hash);
    const [root, ver] = await Promise.all([
      withRetry("latestRoot", () => maroo.readContract({ address: SWAP_LC!, abi: LC_ABI, functionName: "latestRoot" })),
      withRetry("latestVersion", () => maroo.readContract({ address: SWAP_LC!, abi: LC_ABI, functionName: "latestVersion" })),
    ]);
    store.putLeg({ key, status: "confirmed", marooTx: hash, detail: `v${ver}` });
    store.log("swap-qc", `QC confirmed — latestVersion ${ver}`, { marooTx: hash });
    res.json({ hash, latestRoot: root as string, latestVersion: (ver as bigint).toString() });
  } catch (e) {
    res.status(500).json({ error: friendlyError(e, "submit QC") });
  }
});

/** Proven claim + immediate settle. Body: { swapId, leafHash, leafIndex, siblings[], payoutSolver }. */
app.post("/api/swap/claim", async (req, res) => {
  try {
    needSwap();
    const swapId = BigInt(req.body.swapId as string);
    const leafHash = req.body.leafHash as string;
    const leafIndex = BigInt(req.body.leafIndex as string ?? "0");
    const siblings = req.body.siblings as string[];
    const payoutSolver = req.body.payoutSolver as string;
    if (!/^0x[0-9a-fA-F]{64}$/.test(leafHash)) throw new Error("leafHash must be 0x + 64 hex");
    if (!/^0x[0-9a-fA-F]{40}$/.test(payoutSolver)) throw new Error("payoutSolver must be an EVM address");
    const key = `swap-claim:${swapId}:${leafHash}`;
    const prior = store.getLeg(key);
    if (prior && prior.status === "confirmed") return res.json({ claimHash: prior.marooTx, settleHash: prior.detail, replayed: true });
    store.putLeg({ key, status: "submitted", detail: "claimProven submitted" });
    const claimHash = await withRetry("claimProven", () => marooUserWallet.writeContract({
      address: SWAP_ESCROW!, abi: ESCROW_ABI, functionName: "claimProven",
      args: [swapId, leafHash as `0x${string}`, leafIndex, siblings as `0x${string}`[], payoutSolver as `0x${string}`],
    } as never));
    await waitMarooSuccess(claimHash);
    const settleHash = await withRetry("settle", () => marooUserWallet.writeContract({
      address: SWAP_ESCROW!, abi: ESCROW_ABI, functionName: "settle", args: [swapId],
    } as never));
    await waitMarooSuccess(settleHash);
    store.putLeg({ key, status: "confirmed", marooTx: claimHash, detail: settleHash });
    store.log("swap-claim", `Swap ${swapId} proven-claimed -> ${shortAddr(payoutSolver)}`, { marooTx: claimHash });
    res.json({ claimHash, settleHash });
  } catch (e) {
    res.status(500).json({ error: friendlyError(e, "proven claim") });
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
    // Units: Maroo tOKRW is 18 decimals (wei); Aptos OKRW is u64 base units.
    // 1 tOKRW == 1 OKRW == 1e8 octas (Aptos 8-decimal FA convention for this
    // demo). Scale down by 1e10 on the way over; scale back up on the way back.
    // (Pre-reset this scaling lived in the Move code; post-reset redeploy
    // takes raw u64, so the relayer converts explicitly.)
    const OCTAS_PER_TOKRW = 100_000_000n;
    const WEI_PER_TOKRW = 1_000_000_000_000_000_000n;
    if (d.amount % (WEI_PER_TOKRW / OCTAS_PER_TOKRW) !== 0n) {
      throw new Error(`amount ${d.amount} wei is not a whole number of octas`);
    }
    const octas = (d.amount * OCTAS_PER_TOKRW) / WEI_PER_TOKRW;
    store.putLeg({ key, status: "submitted", detail: `relay nonce ${nonceStr}` });
    // Preflight: simulate first so Move aborts (cap, seen, metadata) surface
    // WITHOUT burning faucet gas on a tx that will abort. Simulation runs
    // OUTSIDE withRetry (fail fast); only the submit retries.
    {
      const simTxn = await aptos.transaction.build.simple({
        sender: aptosRelayer.accountAddress,
        data: {
          function: `${MODULE_ADDR}::bridge::mint_attested` as `${string}::${string}::${string}`,
          functionArguments: [OKRW_METADATA, toAptosRecipient(d.aptosRecipient), octas.toString(), d.nonce.toString()],
        },
      });
      const [sim] = await aptos.transaction.simulate.simple({
        signerPublicKey: aptosRelayer.publicKey as never,
        transaction: simTxn,
      });
      console.log(`[relay] preflight nonce ${nonceStr}: success=${sim.success} vm=${sim.vm_status}`);
      if (!sim.success) throw new Error(`preflight abort: ${sim.vm_status}`);
    }
    const tx = await withRetry("mintAttested", () => mintAttested(
      aptos, aptosRelayer, MODULE_ADDR, OKRW_METADATA,
      toAptosRecipient(d.aptosRecipient), octas, d.nonce,
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
// if the store was ever wiped. Range scans go through getDeposits, which fans
// out into RPC-safe 8-block windows client-side (Maroo post-reset quirk).
async function oldestPending(fromBlock: bigint): Promise<{ deposits: DepositEvent[]; target: DepositEvent | undefined }> {
  const head = await withRetry("getBlockNumber", () => maroo.getBlockNumber());
  if (head < fromBlock) return { deposits: [], target: undefined };
  // getDeposits already fans out into RPC-safe 8-block windows internally;
  // call it ONCE for the whole range (chunking here would just multiply the
  // same 8-block calls AND re-trigger the wide-range RPC rejection).
  const deposits = await withRetry("getDeposits", () => getDeposits(maroo, VAULT, fromBlock, head));
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
    // Default lookback is 500 blocks: the UI only shows the last 8 deposits,
    // and wider scans fan out into hundreds of 8-block Maroo RPC windows
    // (5000 hung the endpoint for 120s+ on 2026-10-09). Relay-by-range uses
    // explicit fromBlock and is unaffected.
    const lookback = BigInt(req.query.lookback as string ?? "500");
    const head = await withRetry("getBlockNumber", () => maroo.getBlockNumber());
    const from = head > lookback ? head - lookback : 0n;
    const deposits = await withRetry("getDeposits", () => getDeposits(maroo, VAULT, from, head));
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
    // Units: API takes wei (18-decimal tOKRW convention); Aptos legs use
    // octas (see attestDeposit for the forward direction).
    const amountWei = BigInt(req.body.amount as string);
    if (amountWei <= 0n) throw new Error("amount must be > 0");
    const OCTAS_PER_TOKRW = 100_000_000n;
    const WEI_PER_TOKRW = 1_000_000_000_000_000_000n;
    if (amountWei % (WEI_PER_TOKRW / OCTAS_PER_TOKRW) !== 0n) {
      throw new Error(`amount ${amountWei} wei is not a whole number of octas`);
    }
    const amount = (amountWei * OCTAS_PER_TOKRW) / WEI_PER_TOKRW;
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
    // (amount is octas = 8-decimal; the log line must scale by 1e8, not 1e18 —
    // the old /1e18 printed "Burned 0.0000" for every real burn.)
    const burnRes = await withRetry("burnWithdraw", () => burnWithdraw(
      aptos, aptosRelayer, MODULE_ADDR, OKRW_METADATA,
      APTOS_USER_ADDR, amount, marooRecipient,
    ));
    const nonce = await withRetry("nextReleaseNonce", () => maroo.readContract({ address: VAULT, abi: RELEASE_ABI, functionName: "nextReleaseNonce" }));
    const releaseHash = await withRetry("release submit", () => marooRelayerWallet.writeContract({
      address: VAULT, abi: RELEASE_ABI, functionName: "release",
      args: [marooRecipient, amountWei, nonce],
    }));
    await waitMarooSuccess(releaseHash); // confirmed release, not just submitted
    store.putLeg({ key, status: "confirmed", aptosTx: transferHash.startsWith("0x") ? transferHash : undefined, marooTx: releaseHash, detail: burnRes.hash });
    store.addBack(nonce.toString());
    store.log(
      "bridge-back",
      `Burned ${(Number(amount) / 1e8).toFixed(4)} OKRW, released on Maroo`,
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
    // UNITS: report.vaultEscrow is 18-decimal wei, aptosSupply is 8-decimal
    // octas. The releasable gap is (escrowWholeOctas − supply) octas,
    // converted BACK to wei for vault.release(). The pre-fix code passed
    // (escrowWei − supplyOctas) raw — a ~entire-vault over-release.
    const WEI_PER_OCTA = 10_000_000_000n;
    const gapOctas = BigInt(report.vaultEscrow) / WEI_PER_OCTA - BigInt(report.aptosSupply);
    if (gapOctas <= 0n) throw new Error("no stranded escrow: vault backing does not exceed Aptos supply");
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
    // Both gap and room are wei here (gap converted back from octas); the
    // vault accrues/withdraws wei, so the cap comparison stays in wei.
    const gapWei = gapOctas * WEI_PER_OCTA;
    const amount = gapWei < room ? gapWei : room;
    const to = marooUserWallet.account.address;
    store.putLeg({ key, status: "submitted", detail: `recover ${amount}` });
    const nonce = await withRetry("nextReleaseNonce", () => maroo.readContract({ address: VAULT, abi: RELEASE_ABI, functionName: "nextReleaseNonce" }));
    const releaseHash = await withRetry("release submit", () => marooRelayerWallet.writeContract({
      address: VAULT, abi: RELEASE_ABI, functionName: "release",
      args: [to, amount, nonce],
    }));
    await waitMarooSuccess(releaseHash);
    const remainder = gapWei - amount;
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
  const runAutoRelay = async (fromOverride?: bigint): Promise<boolean> => {
    // Dropped work must be LOUD: a silent return here hid a 171s+ stall on
    // 2026-10-09 (wake-up scheduled, then nothing). Returns false when
    // skipped-busy so the deposit wake-up can retry once.
    if (relayRunning) {
      console.log(`[autorelay] tick skipped (previous tick still running)${fromOverride !== undefined ? ` for block ${fromOverride}` : ""} — next tick covers it`);
      return false;
    }
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
        return true;
      }
      // Process ALL unattested deposits oldest-first within the tick, then
      // advance the cursor past the whole range. (Processing one per tick
      // and persisting head would strand everything in between.)
      // A scan failure must NOT advance the cursor past unscanned blocks:
      // oldestPending throws on RPC errors (fail-fast, no silent skip), so
      // the cursor only moves after a successful full-range scan below.
      const { deposits } = await oldestPending(from);
      const pending = deposits.filter((d) => !store.hasForward(d.nonce.toString()));
      for (const d of pending) {
        console.log(`[autorelay] attesting nonce ${d.nonce} (${(Number(d.amount) / 1e18).toFixed(4)} OKRW)`);
        // Wedge guard: bound each attestation so a hung RPC can never hold
        // relayRunning forever again. On timeout the tick fails loudly, the
        // flag clears in finally, and the next tick reconciles idempotently
        // (on-chain Seen table + EALREADY_ATTESTED adoption).
        let attestTimer: ReturnType<typeof setTimeout> | undefined;
        try {
          await Promise.race([
            attestDeposit(d),
            new Promise<never>((_, rej) => {
              attestTimer = setTimeout(() => rej(new Error(`attest timeout (180s) for nonce ${d.nonce}`)), 180_000);
            }),
          ]);
        } finally {
          clearTimeout(attestTimer);
        }
      }
      if (head > (store.lastBlock ?? -1n)) store.lastBlock = head;
      return true;
    } catch (e) {
      console.error(`[autorelay] tick failed (will retry): ${(e as Error).message.slice(0, 200)}`);
      return true; // ran (and failed loudly); the 60s safety net retries
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
    setTimeout(async () => {
      const ran = await runAutoRelay(depositBlock);
      // If a sweep tick was running, retry once after it likely finished —
      // keeps deposit→mint latency at seconds, not "next 60s tick".
      if (!ran) setTimeout(() => void runAutoRelay(depositBlock), 20_000);
    }, waitMs);
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
