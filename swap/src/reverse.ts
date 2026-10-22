/// Reverse direction (APT -> ETH): quote + Aptos swap_escrow client.
/// Mirrors quote.ts / escrow.ts. All integer math; u64 range documented.
import { Aptos, AptosConfig, Network } from "@aptos-labs/ts-sdk";
import type { PriceConfig } from "./quote.js";

/// Shared Aptos client with indexer support (getEvents is an indexer
/// GraphQL query — Network.CUSTOM without an indexer URL throws
/// "Please provide a custom indexer url"). Default verified reachable
/// from this environment 2026-10-09 (the staging indexer host is not
/// DNS-resolvable here); override with APTOS_INDEXER_URL.
export function createReverseAptos(nodeUrl?: string, indexerUrl?: string): Aptos {
  return new Aptos(new AptosConfig({
    network: Network.CUSTOM,
    fullnode: nodeUrl ?? process.env.APTOS_NODE_URL ?? "https://fullnode.testnet.aptoslabs.com/v1",
    indexer: indexerUrl ?? process.env.APTOS_INDEXER_URL ?? "https://api.testnet.aptoslabs.com/v1/graphql",
  }));
}

/// Quote ETH wei for `aptOctas`. Formula: octas * aptUsd / ethUsd, minus spread.
/// gross_wei = octas * aptUsd * 1e18 / (ethUsd * 1e8), prices 1e6-scaled.
export function quoteEthOut(aptOctas: bigint, cfg: PriceConfig): bigint {
  if (aptOctas <= 0n) throw new Error("amount must be positive");
  if (!(cfg.ethUsd > 0) || !(cfg.aptUsd > 0)) throw new Error("bad prices");
  if (!Number.isInteger(cfg.spreadBps) || cfg.spreadBps < 0 || cfg.spreadBps > 10_000) {
    throw new Error(`spreadBps must be an integer 0..10000, got ${cfg.spreadBps}`);
  }
  const ethUsdM = BigInt(Math.round(cfg.ethUsd * 1e6));
  const aptUsdM = BigInt(Math.round(cfg.aptUsd * 1e6));
  if (ethUsdM <= 0n || aptUsdM <= 0n) throw new Error("bad prices");
  const gross = (aptOctas * aptUsdM * 1_000_000_000_000_000_000n) / (ethUsdM * 100_000_000n);
  // u64 cap: the Move escrow stores min_out/amount-adjacent values as u64.
  // Swaps quoting above ~18.4 ETH revert client-side with a clear message.
  const net = (gross * BigInt(10_000 - cfg.spreadBps)) / 10_000n;
  const U64MAX = (1n << 64n) - 1n;
  if (net > U64MAX) throw new Error(`quoted ${net} wei exceeds u64 range — split into smaller swaps (max ~18.4 ETH)`);
  return net;
}

export interface ReverseSwapState {
  user: string;
  evmRecipient: string; // 0x + 40 hex
  amount: bigint;       // octas locked
  minOut: bigint;       // min acceptable ETH wei
  deadline: bigint;
  claimed: boolean;
  refunded: boolean;
  fillHash: string;
  claimableAt: bigint;
  claimSolver: string;
}

const ZERO_ADDR = "0x0000000000000000000000000000000000000000000000000000000000000000";

export function reverseSwapExists(s: ReverseSwapState): boolean {
  return s.user !== ZERO_ADDR && s.amount > 0n;
}

/// Read a reverse swap via the get_swap view. Returns normalized object.
export async function readReverseSwap(aptos: Aptos, escrowAdmin: string, swapId: bigint): Promise<ReverseSwapState> {
  const r = await aptos.view({
    payload: {
      function: `${escrowAdmin}::swap_escrow::get_swap`,
      typeArguments: [],
      functionArguments: [escrowAdmin, swapId.toString()],
    },
  });
  const [user, evmRecipient, amount, minOut, deadline, claimed, refunded, fillHash, claimableAt, claimSolver] = r as [
    string, string, string, string, string, boolean, boolean, string, string, string
  ];
  return {
    user, evmRecipient,
    amount: BigInt(amount), minOut: BigInt(minOut), deadline: BigInt(deadline),
    claimed, refunded, fillHash,
    claimableAt: BigInt(claimableAt), claimSolver,
  };
}

/// Latest swap id counter (cursor head for lock discovery).
export async function reverseNextId(aptos: Aptos, escrowAdmin: string): Promise<bigint> {
  const r = await aptos.view({
    payload: {
      function: `${escrowAdmin}::swap_escrow::next_swap_id`,
      typeArguments: [],
      functionArguments: [escrowAdmin],
    },
  });
  return BigInt((r as string[])[0]);
}
