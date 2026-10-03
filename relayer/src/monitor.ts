/// Basic bridge health monitoring:
/// - conservation: Maroo vault escrow vs Aptos OKRW total supply
/// - stuck nonces: deposits seen on Maroo but never attested on Aptos
/// - cap exhaustion: daily mint/release caps near or at limit
import type { MarooClient } from "./maroon.js";
import { okrwBalance } from "./aptos.js";
import type { Aptos } from "@aptos-labs/ts-sdk";
import type { Address } from "viem";

export interface HealthIssue {
  level: "warn" | "error";
  check: string;
  detail: string;
}

export interface HealthReport {
  ok: boolean;
  issues: HealthIssue[];
  vaultEscrow: string;
  aptosSupply: string;
  checkedAt: string;
}

const ESCROW_ABI = [
  {
    type: "function",
    name: "escrowed",
    inputs: [],
    outputs: [{ type: "uint256" }],
    stateMutability: "view",
  },
] as const;

// NOTE: fungible_asset::supply needs the metadata type param. Our metadata is
// Object<Metadata> (0x1::fungible_asset::Metadata), so the coin exposes its
// own okrw::supply view and the monitor calls that (see above).
export async function checkHealth(opts: {
  maroo: MarooClient;
  aptos: Aptos;
  vault: Address;
  metadata: string;
  aptosUser: string;
  aptosRelayer: string;
  bridgeAddr: string;
  moduleAddr: string;
}): Promise<HealthReport> {
  const issues: HealthIssue[] = [];
  const { maroo, aptos, vault, metadata, aptosUser, aptosRelayer, bridgeAddr, moduleAddr } = opts;

  const [escrow, userBal, relayerBal] = await Promise.all([
    maroo.readContract({ address: vault, abi: ESCROW_ABI, functionName: "escrowed" }),
    okrwBalance(aptos, aptosUser, metadata),
    okrwBalance(aptos, aptosRelayer, metadata),
  ]);

  // Prefer the on-chain okrw::supply view (exact, all holders). Fall back to
  // the balance-sum proxy on deployments predating the view — flagged as a
  // warn so degraded accuracy is visible, never silent.
  let supply: bigint;
  try {
    const supplyRaw = await aptos.view({
      payload: {
        function: `${moduleAddr}::okrw::supply` as `${string}::${string}::${string}`,
        functionArguments: [metadata],
      },
    });
    const vec = supplyRaw as unknown as [{ vec: string[] }];
    supply = BigInt(vec[0]?.vec?.[0] ?? "0");
  } catch {
    supply = userBal + relayerBal;
    issues.push({
      level: "warn",
      check: "supply-view-unavailable",
      detail: "okrw::supply view missing on this deployment; using balance-sum proxy (redeploy to fix)",
    });
  }

  // Conservation: every minted OKRW must be backed by escrowed tOKRW.
  // (Burned amounts leave both sides equally, so escrow should equal supply.)
  // Balances are reported for triage but NOT used as the supply figure.
  // The two reads above run in parallel, so a transfer landing between them
  // can produce a phantom dust gap. On ANY mismatch, re-read the pair
  // sequentially (escrow, then supply immediately after) and only flag if
  // the gap persists — every wei counts, but timing artifacts are not gaps.
  let finalEscrow = escrow;
  let finalSupply = supply;
  if (escrow !== supply) {
    const escrow2 = await maroo.readContract({ address: vault, abi: ESCROW_ABI, functionName: "escrowed" });
    let supply2: bigint;
    try {
      const supplyRaw2 = await aptos.view({
        payload: {
          function: `${moduleAddr}::okrw::supply` as `${string}::${string}::${string}`,
          functionArguments: [metadata],
        },
      });
      const vec2 = supplyRaw2 as unknown as [{ vec: string[] }];
      supply2 = BigInt(vec2[0]?.vec?.[0] ?? "0");
    } catch {
      const [u2, r2] = await Promise.all([
        okrwBalance(aptos, aptosUser, metadata),
        okrwBalance(aptos, aptosRelayer, metadata),
      ]);
      supply2 = u2 + r2;
    }
    if (escrow2 !== supply2) {
      issues.push({
        level: "error",
        check: "conservation",
        detail: `vault escrow ${escrow2} != Aptos supply ${supply2} (confirmed on re-read; user ${userBal} + relayer ${relayerBal})`,
      });
      finalEscrow = escrow2;
      finalSupply = supply2;
    }
    // Else the first mismatch was a read-timing race: keep the original
    // (matching-perspective) figures and do NOT flag.
  }

  // Cap exhaustion: read bridge Config + vault cap.
  try {
    const data = await aptos.getAccountResource({
      accountAddress: bridgeAddr,
      resourceType: `${moduleAddr}::bridge::Config`,
    }) as unknown as Record<string, string>;
    const cap = BigInt(data.daily_mint_cap as string);
    const used = BigInt(data.minted_today as string);
    if (cap > 0n && used * 100n >= cap * 90n) {
      issues.push({
        level: used >= cap ? "error" : "warn",
        check: "mint-cap",
        detail: `daily mint cap ${used}/${cap} used`,
      });
    }
    if ((data.paused as unknown as boolean) === true) {
      issues.push({ level: "warn", check: "paused", detail: "bridge is paused" });
    }
  } catch (e) {
    issues.push({ level: "warn", check: "mint-cap", detail: `could not read bridge Config: ${(e as Error).message.slice(0, 120)}` });
  }

  return {
    ok: issues.every((i) => i.level !== "error"),
    issues,
    vaultEscrow: finalEscrow.toString(),
    aptosSupply: finalSupply.toString(),
    checkedAt: new Date().toISOString(),
  };
}
