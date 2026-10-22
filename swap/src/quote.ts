/// Quoting: ETH (wei) -> APT (octas). No oracle trust: the quote IS the
/// price; the user's minOut is the slippage guard enforced on-chain by claim().
/// Prices come from env (testnet demo) — mainnet would use signed feeds.
import "dotenv/config";

/// Config: ETH_USD, APT_USD (floats), SPREAD_BPS (solver spread, default 50).
export interface PriceConfig {
  ethUsd: number;
  aptUsd: number;
  spreadBps: number; // e.g. 50 = 0.5%
}

export function priceConfigFromEnv(): PriceConfig {
  return {
    ethUsd: Number(process.env.ETH_USD ?? 3000),
    aptUsd: Number(process.env.APT_USD ?? 5),
    spreadBps: Number(process.env.SOLVER_SPREAD_BPS ?? 50),
  };
}

/// Quote APT octas for `ethWei`. Formula: eth * ethUsd / aptUsd, minus spread.
/// ALL integer math: the old `Number(ethWei) * ratio * 1e-10` float path lost
/// wei precision above 2^53 wei (~0.009 ETH) — every real quote drifted.
/// Prices carry at most 6 decimals exactly (1e6 scale); spread is integer bps.
export function quoteAptOut(ethWei: bigint, cfg: PriceConfig): bigint {
  if (ethWei <= 0n) throw new Error("amount must be positive");
  if (!(cfg.ethUsd > 0) || !(cfg.aptUsd > 0)) throw new Error("bad prices");
  if (!Number.isInteger(cfg.spreadBps) || cfg.spreadBps < 0 || cfg.spreadBps > 10_000) {
    throw new Error(`spreadBps must be an integer 0..10000, got ${cfg.spreadBps}`);
  }
  // gross_octas = ethWei * ethUsd * 1e8 / (aptUsd * 1e18), scaled by 1e6/1e6.
  const ethUsdM = BigInt(Math.round(cfg.ethUsd * 1e6));
  const aptUsdM = BigInt(Math.round(cfg.aptUsd * 1e6));
  if (ethUsdM <= 0n || aptUsdM <= 0n) throw new Error("bad prices");
  const gross = (ethWei * ethUsdM * 100_000_000n) / (aptUsdM * 1_000_000_000_000_000_000n);
  return (gross * BigInt(10_000 - cfg.spreadBps)) / 10_000n;
}

/// Validate a user-supplied minOut against the current quote (quote CLI).
export function checkMinOut(ethWei: bigint, minOut: bigint, cfg: PriceConfig): { ok: boolean; quoted: bigint } {
  const quoted = quoteAptOut(ethWei, cfg);
  return { ok: minOut <= quoted, quoted };
}
