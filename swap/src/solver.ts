/// Solver daemon: watch SwapLocked -> price check -> fill APT on Aptos ->
/// submit claim() with proof -> settle after challenge window.
/// Idempotency via JSON store (swapId-keyed legs). Refunds are user-driven
/// (no keeper needed); the solver simply stops quoting expired swaps.
import "dotenv/config";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createEvmClient, getSwapLocks, waitFinal, readSwap, swapExists, ESCROW_WRITE_ABI, type EvmClient } from "./escrow.js";
import { AUCTION_ABI, getAuctionWins } from "./auction.js";
import { quoteAptOut, priceConfigFromEnv } from "./quote.js";
import { quoteEthOut, readReverseSwap, reverseSwapExists, reverseNextId, createReverseAptos } from "./reverse.js";
import { loadEvmKey, loadEvmAddress, loadOptionalEvmAddress } from "./config.js";
import { Aptos, AptosConfig, Network, Account, Ed25519PrivateKey, Hex } from "@aptos-labs/ts-sdk";
import { createWalletClient, http, keccak256, encodePacked, type Address, type Hex as ViemHex } from "viem";
import fs from "node:fs";

const EVM_RPC = process.env.ETH_RPC_URL ?? "http://127.0.0.1:8545";
const EVM_CHAIN_ID = Number(process.env.ETH_CHAIN_ID ?? 31337);
// Fail fast with actionable messages (see config.ts) instead of noble
// internals or `.length of undefined` crashes mid-run.
const ESCROW = loadEvmAddress("SWAP_ESCROW_ADDRESS", "deployed SwapEscrow");
const { key: SOLVER_PK, account: evmAccount } = loadEvmKey("SOLVER_EVM_PRIVATE_KEY", "solver EVM claim key");
const _APTOS_SOLVER_PK = (process.env.APTOS_SOLVER_PRIVATE_KEY ?? "").trim();
if (!_APTOS_SOLVER_PK) {
  console.error("Missing env: APTOS_SOLVER_PRIVATE_KEY (solver Aptos fill key)");
  process.exit(1);
}
const APTOS_SOLVER_PK = _APTOS_SOLVER_PK;
// (Aptos endpoints come from createReverseAptos, which reads APTOS_NODE_URL / APTOS_INDEXER_URL.)
const CONFIRMATIONS = BigInt(process.env.EVM_CONFIRMATIONS ?? 2);
const DATA_DIR = process.env.SOLVER_DATA_DIR ?? path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "data");
const AUCTION = loadOptionalEvmAddress("SWAP_AUCTION_ADDRESS"); // null = v1 direct-fill
const ATTESTER = loadOptionalEvmAddress("SWAP_ATTESTER_ADDRESS"); // null = solver-attested claim
// Reverse direction (APT -> ETH): Move escrow admin hosting swap_escrow.
// Unset = reverse loop disabled (forward-only daemon).
const R_ESCROW_ADMIN = ((process.env.SWAP_REVERSE_ESCROW_ADMIN ?? "").trim() || null) as Address | null;

// --- activity reports to the swap server UI (best-effort: never break a fill).
const REPORT_URL = (process.env.SWAP_API_URL ?? "http://127.0.0.1:3201") + "/api/swap/report";
const REPORT_TOKEN_OUT = process.env.SWAP_REPORT_TOKEN ?? "";
async function report(swapId: bigint | number | string | null, step: string, detail: string, tx?: string, txKind?: "evm" | "aptos") {
  try {
    await fetch(REPORT_URL, { method: "POST", headers: { "content-type": "application/json" },
      signal: AbortSignal.timeout(8000),
      body: JSON.stringify({ swapId: swapId === null ? null : String(swapId), step, detail, tx, txKind, token: REPORT_TOKEN_OUT || undefined }) });
  } catch { /* UI feed is observability, not consensus — swallow */ }
}

// --- tiny JSON store (swapId legs + consecutive-failure counts) --
interface Leg { status: "seen" | "filled" | "claimed" | "settled" | "skipped"; aptosTx?: string; detail: string }
const storeFile = path.join(DATA_DIR, "solver-state.json");
function loadStore(): { lastBlock: string | null; legs: Record<string, Leg>; failures: Record<string, number>; lastSwapId?: string } {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  try { return { lastBlock: null, legs: {}, failures: {}, ...JSON.parse(fs.readFileSync(storeFile, "utf8")) }; }
  catch { return { lastBlock: null, legs: {}, failures: {} }; }
}
function saveStore(s: { lastBlock: string | null; legs: Record<string, Leg>; failures?: Record<string, number>; lastSwapId?: string }) {
  fs.writeFileSync(storeFile + ".tmp", JSON.stringify(s, null, 1));
  fs.renameSync(storeFile + ".tmp", storeFile);
}
const store = loadStore();

function aptosAccount(pk: string): Account {
  const hex = pk.startsWith("0x") ? pk.slice(2) : pk;
  const clean = hex.startsWith("ed25519-private:0x") ? hex.slice("ed25519-private:0x".length) : hex;
  if (!/^[0-9a-fA-F]{64}$/.test(clean)) {
    throw new Error(`Invalid APTOS_SOLVER_PRIVATE_KEY: expected 32-byte ed25519 key (64 hex chars), got ${pk.length} chars`);
  }
  return Account.fromPrivateKey({ privateKey: new Ed25519PrivateKey(`0x${clean}`) });
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
  // CRASH-SAFE RESUME: a previous run may have filled on Aptos but died
  // before claiming (or claimed but died before persisting). The on-chain
  // claim state is authoritative — re-check it first and NEVER re-fill a
  // swap that already has a fill recorded; go straight to claim.
  // Read on-chain swap state (canonical).
  const s = await readSwap(client, ESCROW, swapId);
  if (!swapExists(s)) {
    store.legs[key] = { status: "skipped", detail: "swap does not exist on-chain" };
    saveStore(store);
    return;
  }
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
  await report(swapId, "picked-up", `${s.amount} wei -> ${quoted} octas to ${s.aptosRecipient.slice(0, 10)}…`);
  await waitFinal(client, blockNumber, CONFIRMATIONS);
  // Auction mode: notify + quote, then fill only if we won exclusivity.
  // v1 direct mode (no AUCTION): fill immediately (single solver).
  const AUCTION_ON = AUCTION !== null;
  let wonAlready = false; // finalized auction we won: skip notify/quote, fill now
  if (AUCTION_ON) {
    // Winner fast-path: a finalized auction we won goes STRAIGHT to fill.
    // (The window has elapsed by definition at finalize time, so the
    // stale-guard below would otherwise skip our own win — observed 2026-10-09.)
    const fin = await client.readContract({
      address: AUCTION!, abi: AUCTION_ABI, functionName: "finalized", args: [swapId],
    }) as boolean;
    if (fin) {
      const win = await client.readContract({
        address: AUCTION!, abi: AUCTION_ABI, functionName: "winner", args: [swapId],
      }) as Address;
      if (win.toLowerCase() !== evmAccount.address.toLowerCase()) {
        console.log(`skip swap ${key}: auction finalized, won by ${win}`);
        store.legs[key] = { status: "skipped", detail: `auction won by ${win}` };
        saveStore(store);
        await report(swapId, "lost", `auction won by ${win.slice(0, 10)}…`);
        return;
      }
      console.log(`swap ${key}: auction won by us, proceeding to fill`);
      wonAlready = true;
    } else {
    // Stale-swap guard: quoting after the window closed always reverts, so
    // skip once with a clear reason instead of erroring every poll tick.
    // (lockTime/window are TIMESTAMP seconds — compare against the head
    // block's timestamp, not its number.)
    const lockT = await client.readContract({
      address: AUCTION!, abi: AUCTION_ABI, functionName: "lockTime", args: [swapId],
    }) as bigint;
    if (lockT !== 0n) {
      const win = await client.readContract({
        address: AUCTION!, abi: AUCTION_ABI, functionName: "auctionWindow",
      }) as bigint;
      const headBlock = await client.getBlock();
      if (headBlock.timestamp > lockT + win) {
        console.log(`skip swap ${key}: auction window closed (lock ${lockT} + window ${win} < now ${headBlock.timestamp})`);
        store.legs[key] = { status: "skipped", detail: "auction window closed before quote" };
        saveStore(store);
        await report(swapId, "skipped", "auction window closed before quote");
        return;
      }
    }
    }
    if (!wonAlready) {
    const w = wallet as unknown as { writeContract: (a: any) => Promise<`0x${string}`> };
    // Notify-then-quote ordering: writeContract returns on BROADCAST, not on
    // mining. On instant chains (Anvil) the notify is mined before the quote
    // simulates; on real chains (Maroo) the quote's preflight simulates
    // against pre-notify state (lockTime 0 -> AuctionClosed). Await the
    // notify receipt first — observed live on Maroo 2026-10-29.
    try {
      const notifyHash = await w.writeContract({ address: AUCTION, abi: AUCTION_ABI, functionName: "notifyLock", args: [swapId], account: (wallet as any).account, chain: undefined });
      await client.waitForTransactionReceipt({ hash: notifyHash });
    } catch { /* already notified */ }
    await w.writeContract({
      address: AUCTION, abi: AUCTION_ABI, functionName: "submitQuote",
      args: [swapId, quoted, BigInt(Math.floor(Date.now() / 1000)) + 86400n, s.minOut],
      account: (wallet as any).account, chain: undefined,
    });
    console.log(`quoted ${quoted} on auction for swap ${key} (fill after finalize if won)`);
    store.legs[key] = { status: "filled", detail: `quoted ${quoted}, awaiting auction finalize` };
    saveStore(store);
    await report(swapId, "quoted", `${quoted} octas (fill after finalize if won)`);
    return; // fill happens in auctionSweep after we win
    }
  }
  // Fill on Aptos from solver inventory (pay quoted).
  // DOUBLE-FILL GUARD: if a previous run filled but died before claiming,
  // the store holds the Aptos tx — reuse it, never pay twice. (On-chain
  // claimSolver is checked above, so a claimed swap never reaches here.)
  let aptosTx: string;
  const priorFill = store.legs[key]?.status === "filled" ? store.legs[key].aptosTx : undefined;
  if (priorFill) {
    console.log(`resuming swap ${key}: reusing prior Aptos fill ${priorFill}, skipping transfer`);
    aptosTx = priorFill;
  } else {
    // Inventory pre-check: fail with a clear message instead of a raw
    // transfer abort after gas is spent.
    const inv = await aptos.getAccountAPTAmount({ accountAddress: solverAcct.accountAddress });
    if (BigInt(inv) < quoted) {
      console.log(`skip swap ${key}: solver APT inventory ${inv} < quoted ${quoted} (fill more / lower prices)`);
      store.legs[key] = { status: "skipped", detail: `insufficient APT inventory ${inv} < ${quoted}` };
      saveStore(store);
      await report(swapId, "skipped", `insufficient APT inventory ${inv} < ${quoted} — fund solver`);
      return;
    }
    aptosTx = await fillApt(aptos, solverAcct, s.aptosRecipient, quoted);
    console.log(`filled on Aptos: ${aptosTx}`);
    store.legs[key] = { status: "filled", aptosTx, detail: `paid ${quoted} octas` };
    saveStore(store);
    await report(swapId, "filled", `paid ${quoted} octas to ${s.aptosRecipient.slice(0, 10)}…`, aptosTx, "aptos");
  }
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
  await report(swapId, "claimed", `escrow claim maturing (challenge window)`, hash, "evm");
  // Note: settle() after challenge window — left to a keeper loop or manual;
  // anyone may call it. Here we log the maturation time and move on.
}

/// Register with the auction if not already (paying requiredBond). Idempotent:
/// skips when already registered; throws loudly when underfunded.
async function ensureRegistered(client: EvmClient, wallet: ReturnType<typeof createWalletClient>) {
  const registered = await client.readContract({
    address: AUCTION!, abi: AUCTION_ABI, functionName: "isSolver", args: [evmAccount.address],
  }) as boolean;
  if (registered) {
    console.log(`already registered with auction ${AUCTION}`);
    return;
  }
  const bond = await client.readContract({
    address: AUCTION!, abi: [...AUCTION_ABI, { name: "requiredBond", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] } as const],
    functionName: "requiredBond",
  }) as bigint;
  const bal = await client.getBalance({ address: evmAccount.address });
  if (bal < bond) {
    throw new Error(`solver ${evmAccount.address} holds ${bal} wei, needs ${bond} wei bond to register — fund it first`);
  }
  const hash = await (wallet as unknown as { writeContract: (a: any) => Promise<`0x${string}`> }).writeContract({
    address: AUCTION!, abi: AUCTION_ABI, functionName: "register", value: bond,
    account: (wallet as any).account, chain: undefined,
  });
  console.log(`registered with auction ${AUCTION} (bond ${bond} wei): ${hash}`);
}

async function main() {
  const client = createEvmClient(EVM_RPC, EVM_CHAIN_ID);
  const aptos = createReverseAptos(); // indexer-enabled (reverse event polling needs it)
  const solverAcct = aptosAccount(APTOS_SOLVER_PK);
  const wallet = createWalletClient({ account: evmAccount, transport: http(EVM_RPC, { timeout: 30_000 }) });
  console.log(`solver evm=${evmAccount.address} aptos=${solverAcct.accountAddress.toString()} escrow=${ESCROW} auction=${AUCTION ?? "v1-direct"}`);
  // Auction mode: self-register (with bond) at startup. Without this every
  // submitQuote reverts NotRegistered — the daemon spun forever on 2026-10-09.
  if (AUCTION !== null) await ensureRegistered(client, wallet);
  // Escrow solver role: claim() is onlySolver. Without this the daemon pays
  // for Aptos fills it can never claim — fail fast instead (2026-10-09).
  const escrowSolver = await client.readContract({
    address: ESCROW, abi: ESCROW_WRITE_ABI, functionName: "solver",
  }) as Address;
  if (escrowSolver.toLowerCase() !== evmAccount.address.toLowerCase()) {
    throw new Error(`escrow solver is ${escrowSolver}, we are ${evmAccount.address} — ask the escrow admin to call setSolver (fills would be unclaimable)`);
  }
  console.log(`escrow solver role confirmed: ${evmAccount.address}`);

  // Forward cursor = last handled swap id (persisted). Fresh store starts at
  // -1n = "everything since genesis" — the counter covers it in 50-id pages,
  // so redeploys never strand in-flight swaps (no block-based backfill needed).
  let lastSwapId: bigint;
  if (process.env.SWAP_START_ID) lastSwapId = BigInt(process.env.SWAP_START_ID) - 1n;
  else if ((store as Record<string, unknown>).lastSwapId != null) {
    lastSwapId = BigInt((store as Record<string, unknown>).lastSwapId as string);
  } else lastSwapId = -1n;

  for (;;) {
    try {
      // Lock discovery is COUNTER-BASED (nextSwapId range poll), not
      // event-based: Maroo's public RPC serves eth_getLogs unreliably
      // across its load-balanced backends ("invalid block range params" /
      // "tx not found" on arbitrary windows, observed live from Fly
      // 2026-10-29), while eth_call views are rock-solid. nextSwapId is
      // monotonic, so ranging (cursor, head] misses nothing.
      const headId = await client.readContract({
        address: ESCROW, abi: ESCROW_WRITE_ABI, functionName: "nextSwapId",
      }) as bigint;
      const from = lastSwapId + 1n;
      const to = headId;
      if (to > from + 50n) {
        console.log(`[forward] ${(to - from).toString()} unprocessed swap(s) — catching up 50/tick`);
      }
      const end = to - from > 50n ? from + 50n : to;
      // Per-swap isolation + poison-swap guard: one swap's failure must
      // never wedge the cursor. Failures are counted; after 3 consecutive
      // failures the swap is skipped with the error recorded. The cursor
      // ALWAYS advances past handled ids.
      for (let swapId = from; swapId < end; swapId++) {
        const k = `${swapId}`;
        if (store.legs[k]?.status === "claimed" || store.legs[k]?.status === "settled" ||
            store.legs[k]?.status === "filled" || store.legs[k]?.status === "skipped") continue;
        try {
          await handleSwap(client, aptos, solverAcct, wallet, swapId, 0n);
          delete store.failures?.[k];
        } catch (e) {
          const n = ((store.failures?.[k] ?? 0) + 1);
          store.failures = { ...store.failures, [k]: n };
          console.error(`swap ${k} failed (attempt ${n}/3): ${(e as Error).message.slice(0, 150)}`);
          await report(swapId, "failed", `attempt ${n}/3: ${(e as Error).message.slice(0, 120)}`);
          if (n >= 3) {
            store.legs[k] = { status: "skipped", detail: `failed ${n}x: ${(e as Error).message.slice(0, 120)}` };
            delete store.failures[k];
          }
          saveStore(store);
        }
      }
      // Auction mode: finalize matured auctions we quoted, fill the ones
      // we won. NOTE: no event backfill — the sweep covers every leg this
      // run quoted (eth_getLogs is unreliable on Maroo; see above). A
      // wipe-restart may miss older wins; they remain claimable manually.
      if (AUCTION !== null) await auctionSweep(client, aptos, solverAcct, wallet);
      lastSwapId = end;
      store.lastSwapId = end.toString();
      saveStore(store as Parameters<typeof saveStore>[0] & Record<string, unknown>);
      // ---------------- reverse direction (APT -> ETH) ----------------
      // Same daemon, second loop: poll Aptos SwapLocked events, fill ETH on
      // the EVM chain, claim the locked APT, settle after the window.
      // Single-solver direct-fill (no Aptos auction contract in v1).
      if (R_ESCROW_ADMIN !== null) {
        await reverseTick(client, aptos, solverAcct, wallet);
      }
    } catch (e) {
      console.error("poll error:", (e as Error).message);
    }
    await new Promise((r) => setTimeout(r, 5000));
  }
}

/// One reverse poll tick: discover new locks by counter, handle each with
/// per-swap isolation + 3-strike poison-skip (same pattern as forward),
/// then settle matured claims. Cursor always advances.
/// Counter-based discovery (NOT event polling): the api.testnet.aptoslabs.com
/// indexer serves no `events` table, so ts-sdk getEvents is unusable here.
/// next_swap_id is monotonic — ranging (cursor, head] misses nothing.
async function reverseTick(
  client: EvmClient,
  aptos: Aptos,
  solverAcct: Account,
  wallet: ReturnType<typeof createWalletClient>,
) {
  const admin = R_ESCROW_ADMIN!;
  let cursor: bigint;
  if (process.env.SWAP_REVERSE_START_ID) cursor = BigInt(process.env.SWAP_REVERSE_START_ID);
  else if ((store as Record<string, unknown>).rnextId != null) {
    cursor = BigInt((store as Record<string, unknown>).rnextId as string);
  } else cursor = await reverseNextId(aptos, admin);
  const head = await reverseNextId(aptos, admin);
  if (head <= cursor) return;
  // Bound a single tick's catch-up (a long-offline daemon pages 50/tick).
  const from = cursor;
  const to = head - from > 50n ? from + 50n : head;
  console.log(`[reverse] ${to - from} new lock(s): ids [${from}, ${to})`);
  for (let id = from; id < to; id++) {
    const k = `r${id}`;
    if (store.legs[k]?.status === "claimed" || store.legs[k]?.status === "settled" ||
        store.legs[k]?.status === "filled" || store.legs[k]?.status === "skipped") continue;
    try {
      await handleReverseSwap(client, aptos, solverAcct, wallet, id);
      delete store.failures?.[k];
    } catch (e) {
      const n = ((store.failures?.[k] ?? 0) + 1);
      store.failures = { ...store.failures, [k]: n };
      console.error(`[reverse] swap ${k} failed (attempt ${n}/3): ${(e as Error).message.slice(0, 150)}`);
      await report(k, "r-failed", `attempt ${n}/3: ${(e as Error).message.slice(0, 120)}`);
      if (n >= 3) {
        store.legs[k] = { status: "skipped", detail: `failed ${n}x: ${(e as Error).message.slice(0, 120)}` };
        delete store.failures[k];
      }
      saveStore(store);
    }
  }
  await reverseSettleSweep(aptos, solverAcct);
  (store as Record<string, unknown>).rnextId = to.toString();
  saveStore(store as Parameters<typeof saveStore>[0] & Record<string, unknown>);
}

/// Handle one reverse swap: price-check -> fill ETH -> claim APT.
async function handleReverseSwap(
  client: EvmClient,
  aptos: Aptos,
  solverAcct: Account,
  wallet: ReturnType<typeof createWalletClient>,
  swapId: bigint,
) {
  const admin = R_ESCROW_ADMIN!;
  const key = `r${swapId}`;
  if (store.legs[key]?.status === "settled" || store.legs[key]?.status === "claimed") {
    console.log(`[reverse] skip swap ${key} (already ${store.legs[key].status})`);
    return;
  }
  const s = await readReverseSwap(aptos, admin, swapId);
  if (!reverseSwapExists(s)) {
    store.legs[key] = { status: "skipped", detail: "swap does not exist on-chain" };
    saveStore(store);
    return;
  }
  if (s.claimed || s.refunded) {
    store.legs[key] = { status: "skipped", detail: s.claimed ? "already claimed" : "already refunded/settled" };
    saveStore(store);
    return;
  }
  const nowAptos = Math.floor(Date.now() / 1000);
  if (nowAptos >= Number(s.deadline)) {
    console.log(`[reverse] skip swap ${key}: past deadline (user-refundable)`);
    store.legs[key] = { status: "skipped", detail: "past deadline — user refund path" };
    saveStore(store);
    return;
  }
  // Price check: quoted ETH payout must cover the user's minOut.
  const cfg = priceConfigFromEnv();
  const quoted = quoteEthOut(s.amount, cfg);
  if (quoted < s.minOut) {
    console.log(`[reverse] skip swap ${key}: quoted ${quoted} wei < minOut ${s.minOut}`);
    store.legs[key] = { status: "skipped", detail: `quoted ${quoted} < minOut ${s.minOut}` };
    saveStore(store);
    return;
  }
  console.log(`[reverse] fill swap ${key}: ${s.amount} octas -> ${quoted} wei to ${s.evmRecipient.slice(0, 10)}…`);
  await report(key, "r-picked-up", `${s.amount} octas -> ${quoted} wei to ${s.evmRecipient.slice(0, 10)}…`);

  // DOUBLE-FILL GUARD: reuse a prior EVM fill if a previous run paid but
  // died before claiming.
  let evmTx: string;
  const priorFill = store.legs[key]?.status === "filled" ? store.legs[key].aptosTx : undefined;
  if (priorFill) {
    console.log(`[reverse] resuming swap ${key}: reusing prior EVM fill ${priorFill}, skipping transfer`);
    evmTx = priorFill;
  } else {
    // EVM inventory pre-check (leave a gas buffer).
    const bal = await client.getBalance({ address: evmAccount.address });
    if (bal < quoted + 10n ** 15n) {
      console.log(`[reverse] skip swap ${key}: solver EVM inventory ${bal} < quoted ${quoted} + gas`);
      store.legs[key] = { status: "skipped", detail: `insufficient EVM inventory ${bal} < ${quoted}` };
      saveStore(store);
      await report(key, "r-skipped", `insufficient EVM inventory ${bal} < ${quoted} — fund solver`);
      return;
    }
    const hash = await wallet.sendTransaction({
      to: s.evmRecipient as Address, value: quoted,
      account: (wallet as unknown as { account: Address }).account, chain: undefined,
    });
    const receipt = await client.waitForTransactionReceipt({ hash });
    if (receipt.status === "reverted") throw new Error(`EVM fill tx ${hash} reverted`);
    await waitFinal(client, receipt.blockNumber, CONFIRMATIONS);
    evmTx = hash;
    console.log(`[reverse] filled on EVM: ${evmTx}`);
    store.legs[key] = { status: "filled", aptosTx: evmTx, detail: `paid ${quoted} wei` };
    saveStore(store);
    await report(key, "r-filled", `paid ${quoted} wei to ${s.evmRecipient.slice(0, 10)}…`, evmTx, "evm");
  }

  // Claim the locked APT. fill_hash = keccak256(evmTxHash || recipient || amount).
  const fillHash = keccak256(encodePacked(["bytes32", "bytes", "uint256"],
    [evmTx as `0x${string}`, s.evmRecipient as `0x${string}`, quoted]));
  const fillHashBytes = Array.from(Buffer.from(fillHash.slice(2), "hex"));
  const claimTxn = await aptos.transaction.build.simple({
    sender: solverAcct.accountAddress,
    data: {
      function: `${admin}::swap_escrow::claim`,
      functionArguments: [admin, swapId.toString(), fillHashBytes, quoted.toString()],
    },
  });
  const claimRes = await aptos.signAndSubmitTransaction({ signer: solverAcct, transaction: claimTxn });
  await aptos.waitForTransaction({ transactionHash: claimRes.hash });
  console.log(`[reverse] claim submitted: ${claimRes.hash}`);
  store.legs[key] = { status: "claimed", aptosTx: evmTx, detail: `claim tx ${claimRes.hash}` };
  saveStore(store);
  await report(key, "r-claimed", `escrow claim maturing (challenge window)`, claimRes.hash, "aptos");
}

/// Settle matured reverse claims (permissionless; solver collects its APT).
async function reverseSettleSweep(aptos: Aptos, solverAcct: Account) {
  const admin = R_ESCROW_ADMIN!;
  for (const [key, leg] of Object.entries(store.legs)) {
    if (!key.startsWith("r") || leg.status !== "claimed") continue;
    const swapId = BigInt(key.slice(1));
    try {
      const s = await readReverseSwap(aptos, admin, swapId);
      if (s.refunded) {
        // Settled (refunded flag doubles as terminal marker) or challenged.
        console.log(`[reverse] swap ${key} terminal on-chain, marking settled`);
        store.legs[key] = { status: "settled", detail: leg.detail };
        saveStore(store);
        continue;
      }
      const now = BigInt(Math.floor(Date.now() / 1000));
      if (now < s.claimableAt) continue; // not mature yet
      const txn = await aptos.transaction.build.simple({
        sender: solverAcct.accountAddress,
        data: { function: `${admin}::swap_escrow::settle`, functionArguments: [admin, swapId.toString()] },
      });
      const res = await aptos.signAndSubmitTransaction({ signer: solverAcct, transaction: txn });
      await aptos.waitForTransaction({ transactionHash: res.hash });
      console.log(`[reverse] settled swap ${key}: ${res.hash}`);
      store.legs[key] = { status: "settled", detail: `settle tx ${res.hash}` };
      saveStore(store);
      await report(key, "r-settled", `collected ${s.amount} octas`, res.hash, "aptos");
    } catch (e) {
      console.error(`[reverse] settle sweep ${key} failed (will retry):`, (e as Error).message.slice(0, 150));
    }
  }
}

/// Finalize auctions for swaps we quoted, and fill the ones we won.
/// Runs each poll tick in auction mode; every step is idempotent.
async function auctionSweep(client: EvmClient, aptos: Aptos, solverAcct: Account, wallet: ReturnType<typeof createWalletClient>) {
  for (const [key, leg] of Object.entries(store.legs)) {
    if (!leg.detail.startsWith("quoted ")) continue; // only our quoted swaps
    const swapId = BigInt(key);
    try {
      const finalized = await client.readContract({
        address: AUCTION!, abi: AUCTION_ABI, functionName: "finalized", args: [swapId],
      }) as boolean;
      if (!finalized) {
        // Attempt finalize; reverts if the auction window is still open or
        // someone else already finalized — both are fine, next tick retries.
        try {
          await (wallet as unknown as { writeContract: (a: any) => Promise<`0x${string}`> }).writeContract({
            address: AUCTION!, abi: AUCTION_ABI, functionName: "finalize", args: [swapId],
            account: (wallet as any).account, chain: undefined,
          });
        } catch (e) {
          console.log(`auction ${key}: finalize not ready (${(e as Error).message.slice(0, 80)})`);
          continue;
        }
      }
      const winner = await client.readContract({
        address: AUCTION!, abi: AUCTION_ABI, functionName: "winner", args: [swapId],
      }) as Address;
      if (winner.toLowerCase() !== evmAccount.address.toLowerCase()) {
        console.log(`auction ${key}: won by ${winner}, skipping fill`);
        store.legs[key] = { status: "skipped", detail: `auction won by ${winner}` };
        saveStore(store);
        continue;
      }
      // We won: fall through to the normal fill+claim path by resetting the
      // leg to unseen — handleSwap re-reads on-chain state (still unclaimed)
      // and fills exactly once. blockNumber 0n skips the finality wait: the
      // lock predates the (already-finalized) auction, so it is final.
      console.log(`auction ${key}: we won, filling`);
      delete store.legs[key];
      saveStore(store);
      await report(swapId, "won", `auction finalized, we won exclusivity`);
      await handleSwap(client, aptos, solverAcct, wallet, swapId, 0n);
    } catch (e) {
      console.error(`auction sweep ${key} failed (will retry):`, (e as Error).message.slice(0, 150));
    }
  }
}

main();
