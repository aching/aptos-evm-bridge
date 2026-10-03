import { createPublicClient, http, parseAbiItem, type Address, type Hash } from "viem";

export const VAULT_ABI = [
  parseAbiItem(
    "event DepositLocked(address indexed marooSender, bytes aptosRecipient, uint256 amount, uint64 nonce)"
  ),
  parseAbiItem("event Released(address indexed to, uint256 amount, uint64 nonce)"),
] as const;

export interface DepositEvent {
  marooSender: Address;
  aptosRecipient: string; // 0x-prefixed 32-byte hex (BCS Aptos address)
  amount: bigint;
  nonce: bigint;
  txHash: Hash;
  blockNumber: bigint;
}

export function createMarooClient(rpcUrl: string, chainId: number) {
  return createPublicClient({ transport: http(rpcUrl), chain: {
    id: chainId, name: "maroo-testnet", nativeCurrency: { name: "tOKRW", symbol: "tOKRW", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  }});
}

export type MarooClient = ReturnType<typeof createMarooClient>;

/// Fetch DepositLocked events from the vault in [fromBlock, toBlock].
export async function getDeposits(
  client: MarooClient,
  vault: Address,
  fromBlock: bigint,
  toBlock: bigint,
): Promise<DepositEvent[]> {
  const logs = await client.getContractEvents({
    address: vault,
    abi: VAULT_ABI,
    eventName: "DepositLocked",
    fromBlock,
    toBlock,
  });
  return logs.map((l) => ({
    marooSender: l.args.marooSender as Address,
    aptosRecipient: l.args.aptosRecipient as string,
    amount: l.args.amount as bigint,
    nonce: l.args.nonce as bigint,
    txHash: l.transactionHash as Hash,
    blockNumber: l.blockNumber,
  }));
}

/// Wait for `confirmations` blocks on top of the deposit's block (demo finality).
export async function waitFinal(
  client: MarooClient,
  blockNumber: bigint,
  confirmations: bigint,
): Promise<void> {
  for (;;) {
    const head = await client.getBlockNumber();
    if (head >= blockNumber + confirmations) return;
    await new Promise((r) => setTimeout(r, 2000));
  }
}
