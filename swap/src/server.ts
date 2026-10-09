/// Swap API server: quote / lock / status / refund / health + static swap UI.
/// One-click demo: server holds a demo EVM key for lock() and the user-side
/// refund call. Solver daemon (solver.ts) fills independently.
import "dotenv/config";
import express from "express";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createEvmClient, ESCROW_WRITE_ABI } from "./escrow.js";
import { quoteAptOut, priceConfigFromEnv } from "./quote.js";
import { createWalletClient, http, parseEther, formatEther, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const PORT = Number(process.env.SWAP_PORT ?? 3201);
const HOST = process.env.SWAP_HOST ?? "127.0.0.1";
const EVM_RPC = process.env.ETH_RPC_URL ?? "http://127.0.0.1:8545";
const EVM_CHAIN_ID = Number(process.env.ETH_CHAIN_ID ?? 31337);
const ESCROW = process.env.SWAP_ESCROW_ADDRESS as Address;
const DEMO_PK = (process.env.SWAP_DEMO_PRIVATE_KEY ?? "") as Hex;
const QUOTE_TTL_S = 300;
const DEADLINE_SECONDS = 86400; // 1 day refunds

if (!ESCROW || !DEMO_PK) {
  console.error("Missing env: SWAP_ESCROW_ADDRESS, SWAP_DEMO_PRIVATE_KEY");
  process.exit(1);
}

const app = express();
app.use(express.json());
app.use(express.static(path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "public")));

const client = createEvmClient(EVM_RPC, EVM_CHAIN_ID);
const demoAccount = privateKeyToAccount(DEMO_PK);
const wallet = createWalletClient({ account: demoAccount, transport: http(EVM_RPC) });

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
    const value = parseEther(String(ethAmount));
    // Re-quote server-side so minOut can't be spoofed above market.
    const cfg = priceConfigFromEnv();
    const fresh = quoteAptOut(value, cfg);
    if (BigInt(minOutOctas) > fresh) throw new Error(`minOut ${minOutOctas} above fresh quote ${fresh}`);
    const hash = await wallet.writeContract({
      address: ESCROW, abi: LOCK_ABI, functionName: "lock",
      args: [aptosRecipient as Hex, BigInt(minOutOctas), BigInt(DEADLINE_SECONDS)],
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
    res.json({ txHash: hash, swapId });
  } catch (e) {
    res.status(400).json({ error: (e as Error).message.slice(0, 300) });
  }
});

app.get("/api/swap/status/:id", async (req, res) => {
  try {
    const s = await client.readContract({
      address: ESCROW, abi: ESCROW_WRITE_ABI, functionName: "swaps", args: [BigInt(req.params.id)],
    }) as unknown as { user: Address; aptosRecipient: string; amount: bigint; minOut: bigint; deadline: bigint; claimed: boolean; refunded: boolean; claimSolver: Address };
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
    // Demo: server key must BE the depositor (one-click locks from demo key).
    const hash = await wallet.writeContract({
      address: ESCROW, abi: REFUND_ABI, functionName: "refund",
      args: [BigInt(req.body.swapId)], account: demoAccount, chain: undefined,
    });
    res.json({ txHash: hash });
  } catch (e) {
    res.status(400).json({ error: (e as Error).message.slice(0, 300) });
  }
});

app.get("/api/healthz", (_req, res) => res.json({ ok: true }));

app.listen(PORT, HOST, () => console.log(`swap UI: http://${HOST}:${PORT}/swap.html`));
