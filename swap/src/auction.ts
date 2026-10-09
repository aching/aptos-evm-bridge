/// Auction participation: register, submit quotes, check winner.
/// Complements escrow.ts (locks) — the solver's bidding leg.
import { parseAbiItem, type Address } from "viem";
import type { EvmClient } from "./escrow.js";

export const AUCTION_ABI = [
  parseAbiItem("function register() payable"),
  parseAbiItem("function notifyLock(uint64 swapId)"),
  parseAbiItem("function submitQuote(uint64 swapId, uint256 aptOut, uint64 expiry, uint256 minOut)"),
  parseAbiItem("function finalize(uint64 swapId) returns (address)"),
  parseAbiItem("function winner(uint64 swapId) view returns (address)"),
  parseAbiItem("function finalized(uint64 swapId) view returns (bool)"),
  parseAbiItem("function isSolver(address) view returns (bool)"),
  parseAbiItem("function quoteCount(uint64) view returns (uint256)"),
] as const;

export async function ensureNotified(
  wallet: { writeContract: (args: any) => Promise<`0x${string}`> },
  auction: Address,
  swapId: bigint,
): Promise<void> {
  await wallet.writeContract({ address: auction, abi: AUCTION_ABI, functionName: "notifyLock", args: [swapId] });
}
