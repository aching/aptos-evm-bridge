import "dotenv/config";
import { createWalletClient, http, parseAbiItem, type Address, type Hash } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { createAptos, relayerAccount, burnWithdraw } from "./aptos.js";

const MAROO_RPC = process.env.MAROO_RPC_URL ?? "https://rpc-testnet.maroo.io";
const MAROO_CHAIN_ID = Number(process.env.MAROO_CHAIN_ID ?? 450815);
const VAULT = process.env.MAROO_VAULT_ADDRESS as Address;
const MAROO_RELAYER_PK = process.env.MAROO_RELAYER_PRIVATE_KEY as Hash;
const APTOS_NODE = process.env.APTOS_NODE_URL ?? "https://fullnode.testnet.aptoslabs.com/v1";
const MODULE_ADDR = process.env.APTOS_MODULE_ADDRESS!;
const BRIDGE_ADDR = process.env.APTOS_BRIDGE_ADDRESS!;
const OKRW_METADATA = process.env.APTOS_OKRW_METADATA!;
const APTOS_RELAYER_PK = process.env.APTOS_RELAYER_PRIVATE_KEY!;

const RELEASE_ABI = [
  parseAbiItem("function release(address to, uint256 amount, uint64 nonce)"),
  parseAbiItem("function nextReleaseNonce() view returns (uint64)"),
] as const;

if (!VAULT || !MAROO_RELAYER_PK || !MODULE_ADDR || !BRIDGE_ADDR || !OKRW_METADATA || !APTOS_RELAYER_PK) {
  console.error("Missing env: MAROO_VAULT_ADDRESS, MAROO_RELAYER_PRIVATE_KEY, APTOS_MODULE_ADDRESS, APTOS_BRIDGE_ADDRESS, APTOS_OKRW_METADATA, APTOS_RELAYER_PRIVATE_KEY");
  process.exit(1);
}

/// Withdraw flow (Aptos -> Maroo), driven manually for the demo:
///   1. user transfers OKRW to the relayer's Aptos account (normal FA transfer)
///   2. this script burns from the relayer account (burn_withdraw) and then
///      calls vault.release on Maroo.
/// Usage: tsx src/back.ts <userAptosAddr> <amount> <marooRecipient0x>
async function main() {
  const [userAptos, amountStr, marooRecipient] = process.argv.slice(2);
  if (!userAptos || !amountStr || !marooRecipient) {
    console.error("usage: tsx src/back.ts <userAptosAddr> <amount> <marooRecipient0x>");
    process.exit(1);
  }
  const amount = BigInt(amountStr);

  const aptos = createAptos(APTOS_NODE);
  const relayer = relayerAccount(APTOS_RELAYER_PK);

  console.log(`step 1: burn ${amount} on Aptos from relayer (user funds pre-sent)`);
  const burnRes = await burnWithdraw(aptos, relayer, MODULE_ADDR, OKRW_METADATA, userAptos, amount, marooRecipient);
  console.log(`burned: ${burnRes.hash}`);

  const marooAccount = privateKeyToAccount(MAROO_RELAYER_PK);
  const wallet = createWalletClient({
    account: marooAccount,
    transport: http(MAROO_RPC),
    chain: {
      id: MAROO_CHAIN_ID, name: "maroo-testnet",
      nativeCurrency: { name: "tOKRW", symbol: "tOKRW", decimals: 18 },
      rpcUrls: { default: { http: [MAROO_RPC] } },
    },
  });
  // Read next release nonce via public client.
  const { createMarooClient } = await import("./maroon.js");
  const pub = createMarooClient(MAROO_RPC, MAROO_CHAIN_ID);
  const nonce = await pub.readContract({ address: VAULT, abi: RELEASE_ABI, functionName: "nextReleaseNonce" });
  console.log(`step 2: release ${amount} to ${marooRecipient} (release nonce ${nonce})`);
  const hash = await wallet.writeContract({
    address: VAULT, abi: RELEASE_ABI, functionName: "release",
    args: [marooRecipient as Address, amount, nonce],
  });
  console.log(`released on Maroo: ${hash}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
