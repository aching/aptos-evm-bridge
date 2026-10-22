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
  parseAbiItem("function auctionWindow() view returns (uint64)"),
  parseAbiItem("function lockTime(uint64) view returns (uint64)"),
  parseAbiItem("event AuctionFinalized(uint64 indexed swapId, address indexed winner, uint256 aptOut)"),
] as const;

export async function ensureNotified(
  wallet: { writeContract: (args: any) => Promise<`0x${string}`> },
  auction: Address,
  swapId: bigint,
): Promise<void> {
  await wallet.writeContract({ address: auction, abi: AUCTION_ABI, functionName: "notifyLock", args: [swapId] });
}

/// SwapIds finalized TO `winner` in [fromBlock, toBlock] (chunked like locks).
/// Lets a fresh solver (wiped store) discover its stranded wins instead of
/// leaving them unfilled forever.
export async function getAuctionWins(
  client: EvmClient,
  auction: Address,
  winner: Address,
  fromBlock: bigint,
  toBlock: bigint,
): Promise<bigint[]> {
  const STEP = 500n;
  const out: bigint[] = [];
  const want = winner.toLowerCase();
  for (let from = fromBlock; from <= toBlock; from += STEP) {
    const to = from + STEP - 1n > toBlock ? toBlock : from + STEP - 1n;
    const logs = await client.getContractEvents({
      address: auction,
      abi: AUCTION_ABI,
      eventName: "AuctionFinalized",
      fromBlock: from,
      toBlock: to,
    });
    for (const l of logs) {
      if ((l.args.winner as string).toLowerCase() === want) {
        out.push(l.args.swapId as bigint);
      }
    }
  }
  return out;
}
