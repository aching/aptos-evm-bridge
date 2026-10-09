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
  // 15s transport timeout: viem http() defaults to NO timeout, and one hung
  // Maroo RPC promise wedged the whole auto-relay (relayRunning stuck true,
  // wake-ups silently dropped) for 171s+ on 2026-10-09. Timeouts turn stalls
  // into rejections -> withRetry retries -> ticks fail loudly and recover.
  return createPublicClient({ transport: http(rpcUrl, { timeout: 15_000 }), chain: {
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
  // Maroo RPC quirk (post-reset, 2026-10-09): eth_getLogs rejects ranges
  // wider than ~10 blocks ("invalid block range params"). Fan out into
  // 8-block windows client-side; a single 250-block getContractEvents would
  // always fail and stall the relay loop.
  // Windows run CONCURRENTLY (cap 10 in flight): 625 sequential RPCs hung
  // /api/pending for 120s+ (2026-10-09) — concurrency brings it to ~10s.
  const STEP = 8n;
  const CONCURRENCY = 10;
  const windows: Array<[bigint, bigint]> = [];
  for (let from = fromBlock; from <= toBlock; from += STEP) {
    const to = from + STEP - 1n > toBlock ? toBlock : from + STEP - 1n;
    windows.push([from, to]);
  }
  const out: DepositEvent[] = [];
  for (let i = 0; i < windows.length; i += CONCURRENCY) {
    const batch = windows.slice(i, i + CONCURRENCY);
    const results = await Promise.all(batch.map(async ([from, to]) => {
      const logs = await client.getContractEvents({
        address: vault,
        abi: VAULT_ABI,
        eventName: "DepositLocked",
        fromBlock: from,
        toBlock: to,
      });
      return logs.map((l) => ({
        marooSender: l.args.marooSender as Address,
        aptosRecipient: l.args.aptosRecipient as string,
        amount: l.args.amount as bigint,
        nonce: l.args.nonce as bigint,
        txHash: l.transactionHash as Hash,
        blockNumber: l.blockNumber,
      }));
    }));
    for (const r of results) out.push(...r);
  }
  return out;
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
