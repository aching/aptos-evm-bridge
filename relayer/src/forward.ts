import "dotenv/config";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createMarooClient, getDeposits, waitFinal, type DepositEvent } from "./maroon.js";
import { createAptos, relayerAccount, mintAttested } from "./aptos.js";
import { Store } from "./store.js";
import type { Address } from "viem";

const MAROO_RPC = process.env.MAROO_RPC_URL ?? "https://rpc-testnet.maroo.io";
const MAROO_CHAIN_ID = Number(process.env.MAROO_CHAIN_ID ?? 450815);
const VAULT = process.env.MAROO_VAULT_ADDRESS as Address;
const APTOS_NODE = process.env.APTOS_NODE_URL ?? "https://fullnode.testnet.aptoslabs.com/v1";
const MODULE_ADDR = process.env.APTOS_MODULE_ADDRESS!; // publisher: where modules live
const BRIDGE_ADDR = process.env.APTOS_BRIDGE_ADDRESS!; // relayer: holds Config/Seen
const OKRW_METADATA = process.env.APTOS_OKRW_METADATA!;
const RELAYER_PK = process.env.APTOS_RELAYER_PRIVATE_KEY!;
const CONFIRMATIONS = BigInt(process.env.MAROO_CONFIRMATIONS ?? 2);
const DATA_DIR = process.env.RELAYER_DATA_DIR ?? path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "data");

if (!VAULT || !MODULE_ADDR || !BRIDGE_ADDR || !OKRW_METADATA || !RELAYER_PK) {
  console.error("Missing env: MAROO_VAULT_ADDRESS, APTOS_MODULE_ADDRESS, APTOS_BRIDGE_ADDRESS, APTOS_OKRW_METADATA, APTOS_RELAYER_PRIVATE_KEY");
  process.exit(1);
}

const store = new Store(DATA_DIR);

async function handleDeposit(client: ReturnType<typeof createMarooClient>, aptos: ReturnType<typeof createAptos>, relayer: ReturnType<typeof relayerAccount>, d: DepositEvent) {
  const key = `${d.nonce}`;
  if (store.hasForward(key)) { console.log(`skip nonce ${key} (already processed)`); return; }
  console.log(`deposit nonce=${d.nonce} amount=${d.amount} -> ${d.aptosRecipient} (tx ${d.txHash})`);
  await waitFinal(client, d.blockNumber, CONFIRMATIONS);
  // 18-dec OKRW on Maroo == 18-dec OKRW on Aptos, but Aptos u64 caps at ~1.8e19.
  if (d.amount > BigInt("18446744073709551615")) throw new Error(`amount ${d.amount} exceeds u64`);
  const aptosRecipient = d.aptosRecipient.startsWith("0x") ? d.aptosRecipient : `0x${d.aptosRecipient}`;
  try {
    const res = await mintAttested(aptos, relayer, MODULE_ADDR, OKRW_METADATA, aptosRecipient, d.amount, d.nonce);
    console.log(`minted on Aptos: ${res.hash} (maroo nonce ${key})`);
    store.addForward(key); // persisted — restart-safe, no replay
  } catch (e) {
    // Do NOT mark seen: retry next poll. Back off to avoid spamming a
    // persistently-failing attestation (e.g. cap exceeded).
    console.error(`mint failed for nonce ${key}: ${(e as Error).message.slice(0, 200)} — will retry`);
    await new Promise((r) => setTimeout(r, 30000));
    throw e;
  }
}

async function main() {
  const client = createMarooClient(MAROO_RPC, MAROO_CHAIN_ID);
  const aptos = createAptos(APTOS_NODE);
  const relayer = relayerAccount(RELAYER_PK);
  console.log(`relayer aptos=${relayer.accountAddress.toString()} vault=${VAULT} (data: ${DATA_DIR})`);

  // Resume from persisted cursor; MAROO_START_BLOCK overrides (catch-up).
  let lastBlock: bigint;
  if (process.env.MAROO_START_BLOCK) {
    lastBlock = BigInt(process.env.MAROO_START_BLOCK);
    console.log(`catch-up from Maroo block ${lastBlock} (MAROO_START_BLOCK)`);
  } else if (store.lastBlock !== null) {
    lastBlock = store.lastBlock;
    console.log(`resuming from persisted Maroo block ${lastBlock}`);
  } else {
    lastBlock = await client.getBlockNumber();
    console.log(`starting from Maroo head ${lastBlock} (set MAROO_START_BLOCK to catch up)`);
  }
  for (;;) {
    try {
      const head = await client.getBlockNumber();
      if (head > lastBlock) {
        const deposits = await getDeposits(client, VAULT, lastBlock + 1n, head);
        for (const d of deposits) await handleDeposit(client, aptos, relayer, d);
        lastBlock = head;
        store.lastBlock = head; // persist cursor every poll
      }
    } catch (e) {
      console.error("poll error:", (e as Error).message);
    }
    await new Promise((r) => setTimeout(r, 5000));
  }
}

main();
