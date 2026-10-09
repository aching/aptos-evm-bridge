/// Solver daemon: watch SwapLocked -> price check -> fill APT on Aptos ->
/// submit claim() with proof -> settle after challenge window.
/// Idempotency via JSON store (swapId-keyed legs). Refunds are user-driven
/// (no keeper needed); the solver simply stops quoting expired swaps.
import "dotenv/config";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createEvmClient, getSwapLocks, waitFinal, ESCROW_WRITE_ABI, type EvmClient } from "./escrow.js";
import { AUCTION_ABI } from "./auction.js";
import { quoteAptOut, priceConfigFromEnv } from "./quote.js";
import { Aptos, AptosConfig, Network, Account, Ed25519PrivateKey, Hex } from "@aptos-labs/ts-sdk";
import { createWalletClient, http, type Address, type Hex as ViemHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import fs from "node:fs";

const EVM_RPC = process.env.ETH_RPC_URL ?? "http://127.0.0.1:8545";
const EVM_CHAIN_ID = Number(process.env.ETH_CHAIN_ID ?? 31337);
const ESCROW = process.env.SWAP_ESCROW_ADDRESS as Address;
const SOLVER_PK = (process.env.SOLVER_EVM_PRIVATE_KEY ?? "") as ViemHex;
const APTOS_NODE = process.env.APTOS_NODE_URL ?? "https://fullnode.testnet.aptoslabs.com/v1";
const APTOS_SOLVER_PK = process.env.APTOS_SOLVER_PRIVATE_KEY!;
const CONFIRMATIONS = BigInt(process.env.EVM_CONFIRMATIONS ?? 2);
const DATA_DIR = process.env.SOLVER_DATA_DIR ?? path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "data");
const AUCTION = (process.env.SWAP_AUCTION_ADDRESS ?? "") as Address; // unset = v1 direct-fill
const ATTESTER = (process.env.SWAP_ATTESTER_ADDRESS ?? "") as Address; // unset = solver-attested claim

if (!ESCROW || !SOLVER_PK || !APTOS_SOLVER_PK) {
  console.error("Missing env: SWAP_ESCROW_ADDRESS, SOLVER_EVM_PRIVATE_KEY, APTOS_SOLVER_PRIVATE_KEY");
  process.exit(1);
}

// --- tiny JSON store (swapId legs) ---
interface Leg { status: "seen" | "filled" | "claimed" | "settled" | "skipped"; aptosTx?: string; detail: string }
const storeFile = path.join(DATA_DIR, "solver-state.json");
function loadStore(): { lastBlock: string | null; legs: Record<string, Leg> } {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  try { return { lastBlock: null, legs: {}, ...JSON.parse(fs.readFileSync(storeFile, "utf8")) }; }
  catch { return { lastBlock: null, legs: {} }; }
}
function saveStore(s: { lastBlock: string | null; legs: Record<string, Leg> }) {
  fs.writeFileSync(storeFile + ".tmp", JSON.stringify(s, null, 1));
  fs.renameSync(storeFile + ".tmp", storeFile);
}
const store = loadStore();

function aptosAccount(pk: string): Account {
  let hex = pk.startsWith("0x") ? pk.slice(2) : pk;
  if (hex.startsWith("ed25519-private:0x")) hex = hex.slice("ed25519-private:0x".length);
  return Account.fromPrivateKey({ privateKey: new Ed25519PrivateKey(`0x${hex}`) });
}

/// Send APT (native, octas) from solver inventory to the user. Returns tx hash.
async function fillApt(aptos: Aptos, solver: Account, recipient: string, octas: bigint): Promise<string> {
  const to = recipient.startsWith("0x") ? recipient : `0x${recipient}`;
  const txn = await aptos.transaction.build.simple({
    sender: solver.accountAddress,
    data: {
      function: "0x1::aptos_account::transfer",
      functionArguments: [to, octas.toString()],
    },
  });
  const r = await aptos.signAndSubmitTransaction({ signer: solver, transaction: txn });
  const res = await aptos.waitForTransaction({ transactionHash: r.hash });
  return (res as { hash: string }).hash;
}

async function handleSwap(client: EvmClient, aptos: Aptos, solverAcct: Account, wallet: ReturnType<typeof createWalletClient>, swapId: bigint, blockNumber: bigint) {
  const key = `${swapId}`;
  if (store.legs[key]?.status === "settled" || store.legs[key]?.status === "claimed") {
    console.log(`skip swap ${key} (already ${store.legs[key].status})`);
    return;
  }
  // Read on-chain swap state (canonical).
  const s = await client.readContract({
    address: ESCROW, abi: ESCROW_WRITE_ABI, functionName: "swaps", args: [swapId],
  }) as unknown as { user: Address; aptosRecipient: string; amount: bigint; minOut: bigint; deadline: bigint; claimed: boolean; refunded: boolean; claimSolver: Address };
  if (s.claimed || s.refunded || s.claimSolver !== "0x0000000000000000000000000000000000000000") {
    store.legs[key] = { status: "skipped", detail: "already claimed/refunded on-chain" };
    saveStore(store);
    return;
  }
  const now = BigInt(Math.floor(Date.now() / 1000));
  if (now > s.deadline) {
    store.legs[key] = { status: "skipped", detail: "expired before fill; user may refund" };
    saveStore(store);
    return;
  }
  // Price check: quote must cover minOut or skip (no fill at a loss).
  const cfg = priceConfigFromEnv();
  const quoted = quoteAptOut(s.amount, cfg);
  if (quoted < s.minOut) {
    store.legs[key] = { status: "skipped", detail: `quote ${quoted} < minOut ${s.minOut}` };
    saveStore(store);
    return;
  }
  console.log(`fill swap ${key}: ${s.amount} wei -> ${quoted} octas to ${s.aptosRecipient}`);
  await waitFinal(client, blockNumber, CONFIRMATIONS);
  // Auction mode: notify + quote, then fill only if we won exclusivity.
  // v1 direct mode (no AUCTION): fill immediately (single solver).
  const AUCTION_ON = AUCTION.length === 42 && !/^0x0+$/.test(AUCTION);
  if (AUCTION_ON) {
    const w = wallet as unknown as { writeContract: (a: any) => Promise<`0x${string}`> };
    try {
      await w.writeContract({ address: AUCTION, abi: AUCTION_ABI, functionName: "notifyLock", args: [swapId], account: (wallet as any).account, chain: undefined });
    } catch { /* already notified */ }
    await w.writeContract({
      address: AUCTION, abi: AUCTION_ABI, functionName: "submitQuote",
      args: [swapId, quoted, BigInt(Math.floor(Date.now() / 1000)) + 86400n, s.minOut],
      account: (wallet as any).account, chain: undefined,
    });
    console.log(`quoted ${quoted} on auction for swap ${key} (fill after finalize if won)`);
    store.legs[key] = { status: "filled", detail: `quoted ${quoted}, awaiting auction finalize` };
    saveStore(store);
    return; // fill happens in runAuctionSweep after we win
  }
  // Fill on Aptos from solver inventory (pay exactly minOut or quoted? pay quoted).
  const aptosTx = await fillApt(aptos, solverAcct, s.aptosRecipient, quoted);
  console.log(`filled on Aptos: ${aptosTx}`);
  store.legs[key] = { status: "filled", aptosTx, detail: `paid ${quoted} octas` };
  saveStore(store);
  // Claim on Ethereum with proof.
  const recipientBytes = Hex.fromHexString(s.aptosRecipient).toString() as `0x${string}`;
  const hash = await wallet.writeContract({
    address: ESCROW, abi: ESCROW_WRITE_ABI, functionName: "claim",
    args: [swapId, aptosTx as `0x${string}`, recipientBytes, quoted],
    account: wallet.account!, chain: undefined,
  });
  console.log(`claim submitted: ${hash}`);
  store.legs[key] = { status: "claimed", aptosTx, detail: `claim tx ${hash}` };
  saveStore(store);
  // Note: settle() after challenge window — left to a keeper loop or manual;
  // anyone may call it. Here we log the maturation time and move on.
}

async function main() {
  const client = createEvmClient(EVM_RPC, EVM_CHAIN_ID);
  const aptos = new Aptos(new AptosConfig({ network: Network.CUSTOM, fullnode: APTOS_NODE }));
  const solverAcct = aptosAccount(APTOS_SOLVER_PK);
  const evmAccount = privateKeyToAccount(SOLVER_PK);
  const wallet = createWalletClient({ account: evmAccount, transport: http(EVM_RPC) });
  console.log(`solver evm=${evmAccount.address} aptos=${solverAcct.accountAddress.toString()} escrow=${ESCROW}`);

  let lastBlock: bigint;
  if (process.env.SWAP_START_BLOCK) lastBlock = BigInt(process.env.SWAP_START_BLOCK);
  else if (store.lastBlock !== null) lastBlock = BigInt(store.lastBlock);
  else lastBlock = await client.getBlockNumber();
  console.log(`watching from block ${lastBlock}`);

  for (;;) {
    try {
      const head = await client.getBlockNumber();
      if (head > lastBlock) {
        const locks = await getSwapLocks(client, ESCROW, lastBlock + 1n, head);
        for (const l of locks) await handleSwap(client, aptos, solverAcct, wallet, l.swapId, l.blockNumber);
        lastBlock = head;
        store.lastBlock = head.toString();
        saveStore(store);
      }
    } catch (e) {
      console.error("poll error:", (e as Error).message);
    }
    await new Promise((r) => setTimeout(r, 5000));
  }
}

main();
