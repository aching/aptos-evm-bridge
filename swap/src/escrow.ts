/// SwapEscrow ABIs + event fetching/parsing (viem). Mirrors relayer/src/maroon.ts.
import { createPublicClient, http, parseAbiItem, type Address, type Hash } from "viem";

export const ESCROW_ABI = [
  parseAbiItem(
    "event SwapLocked(uint64 indexed swapId, address indexed user, bytes aptosRecipient, uint256 amount, uint256 minOut, uint64 deadline)"
  ),
  parseAbiItem("event SwapClaimed(uint64 indexed swapId, address indexed solver, bytes32 fillHash, uint64 claimableAt)"),
  parseAbiItem("event SwapSettled(uint64 indexed swapId, address indexed solver, uint256 amount)"),
  parseAbiItem("event SwapRefunded(uint64 indexed swapId, address indexed user, uint256 amount)"),
  parseAbiItem("event ClaimChallenged(uint64 indexed swapId, address indexed challenger)"),
] as const;

export const ESCROW_WRITE_ABI = [
  parseAbiItem("function claim(uint64 swapId, bytes32 aptosTxHash, bytes fillRecipient, uint256 fillAmount)"),
  parseAbiItem("function settle(uint64 swapId)"),
  parseAbiItem("function solver() view returns (address)"),
  parseAbiItem("function swaps(uint64) view returns (address user, bytes aptosRecipient, uint256 amount, uint256 minOut, uint64 deadline, bool claimed, bool refunded, bytes32 fillHash, uint64 claimableAt, address claimSolver)"),
] as const;

export interface SwapState {
  user: Address;
  aptosRecipient: string;
  amount: bigint;
  minOut: bigint;
  deadline: bigint;
  claimed: boolean;
  refunded: boolean;
  fillHash: string;
  claimableAt: bigint;
  claimSolver: Address;
}

const ZERO_ADDR = "0x0000000000000000000000000000000000000000" as Address;

/// Read a swap, normalizing viem's tuple-array return into a named object.
/// (viem returns positional arrays here — direct `.user` access yields
/// undefined, which broke status/refund/solver checks on 2026-10-09.)
export async function readSwap(client: EvmClient, escrow: Address, swapId: bigint): Promise<SwapState> {
  const s = await client.readContract({
    address: escrow, abi: ESCROW_WRITE_ABI, functionName: "swaps", args: [swapId],
  }) as unknown as [Address, string, bigint, bigint, bigint, boolean, boolean, string, bigint, Address];
  return {
    user: s[0], aptosRecipient: s[1], amount: s[2], minOut: s[3], deadline: s[4],
    claimed: s[5], refunded: s[6], fillHash: s[7], claimableAt: s[8], claimSolver: s[9],
  };
}

/** A swap exists iff it has a user and a nonzero amount. */
export function swapExists(s: SwapState): boolean {
  return s.user !== ZERO_ADDR && s.amount > 0n;
}

export interface SwapEvent {
  swapId: bigint;
  user: Address;
  aptosRecipient: string; // 0x-prefixed 32-byte hex
  amount: bigint; // wei
  minOut: bigint; // octas
  deadline: bigint;
  txHash: Hash;
  blockNumber: bigint;
}

export function createEvmClient(rpcUrl: string, chainId: number) {
  // 15s transport timeout: viem http() defaults to NO timeout, and one hung
  // RPC wedged the bridge auto-relay for 171s on 2026-10-09. Same fix here.
  return createPublicClient({ transport: http(rpcUrl, { timeout: 15_000 }), chain: {
    id: chainId, name: "eth-testnet", nativeCurrency: { name: "ETH", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
  }});
}

export type EvmClient = ReturnType<typeof createEvmClient>;

export async function getSwapLocks(
  client: EvmClient,
  escrow: Address,
  fromBlock: bigint,
  toBlock: bigint,
): Promise<SwapEvent[]> {
  // Chunk into 8-block windows: Maroo testnet rejects wider eth_getLogs
  // ranges ("invalid block range params") — observed live 2026-10-29 from
  // Fly (the bridge relayer learned this 2026-10-09). Anvil tolerates
  // anything, so one small window size serves both chains.
  const STEP = 8n;
  const out: SwapEvent[] = [];
  for (let from = fromBlock; from <= toBlock; from += STEP) {
    const to = from + STEP - 1n > toBlock ? toBlock : from + STEP - 1n;
    const logs = await client.getContractEvents({
      address: escrow,
      abi: ESCROW_ABI,
      eventName: "SwapLocked",
      fromBlock: from,
      toBlock: to,
    });
    for (const l of logs) {
      out.push({
        swapId: l.args.swapId as bigint,
        user: l.args.user as Address,
        aptosRecipient: l.args.aptosRecipient as string,
        amount: l.args.amount as bigint,
        minOut: l.args.minOut as bigint,
        deadline: l.args.deadline as bigint,
        txHash: l.transactionHash as Hash,
        blockNumber: l.blockNumber,
      });
    }
  }
  return out;
}

export async function waitFinal(
  client: EvmClient,
  blockNumber: bigint,
  confirmations: bigint,
  timeoutMs = 120_000,
): Promise<void> {
  // Bounded: the old infinite loop hung the solver forever on a stalled
  // chain. Callers treat timeout as a retryable poll-tick failure.
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const head = await client.getBlockNumber();
    if (head >= blockNumber + confirmations) return;
    if (Date.now() > deadline) {
      throw new Error(`finality timeout: block ${blockNumber} + ${confirmations} confirmations not reached in ${timeoutMs / 1000}s`);
    }
    await new Promise((r) => setTimeout(r, 2000));
  }
}
