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
  parseAbiItem("function swaps(uint64) view returns (address user, bytes aptosRecipient, uint256 amount, uint256 minOut, uint64 deadline, bool claimed, bool refunded, bytes32 fillHash, uint64 claimableAt, address claimSolver)"),
] as const;

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
  return createPublicClient({ transport: http(rpcUrl), chain: {
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
  const logs = await client.getContractEvents({
    address: escrow,
    abi: ESCROW_ABI,
    eventName: "SwapLocked",
    fromBlock,
    toBlock,
  });
  return logs.map((l) => ({
    swapId: l.args.swapId as bigint,
    user: l.args.user as Address,
    aptosRecipient: l.args.aptosRecipient as string,
    amount: l.args.amount as bigint,
    minOut: l.args.minOut as bigint,
    deadline: l.args.deadline as bigint,
    txHash: l.transactionHash as Hash,
    blockNumber: l.blockNumber,
  }));
}

export async function waitFinal(client: EvmClient, blockNumber: bigint, confirmations: bigint): Promise<void> {
  for (;;) {
    const head = await client.getBlockNumber();
    if (head >= blockNumber + confirmations) return;
    await new Promise((r) => setTimeout(r, 2000));
  }
}
