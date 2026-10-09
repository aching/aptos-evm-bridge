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
/// Uses integer math on the ETH side, float only for the USD ratio (demo).
export function quoteAptOut(ethWei: bigint, cfg: PriceConfig): bigint {
  if (ethWei <= 0n) throw new Error("amount must be positive");
  if (cfg.ethUsd <= 0 || cfg.aptUsd <= 0) throw new Error("bad prices");
  // octas per wei = (ethUsd / aptUsd) * (1e8 / 1e18) = ratio * 1e-10.
  const ratio = cfg.ethUsd / cfg.aptUsd;
  const gross = Number(ethWei) * ratio * 1e-10;
  const net = Math.floor(gross * (1 - cfg.spreadBps / 10_000));
  return BigInt(net);
}

/// Validate a user-supplied minOut against the current quote (quote CLI).
export function checkMinOut(ethWei: bigint, minOut: bigint, cfg: PriceConfig): { ok: boolean; quoted: bigint } {
  const quoted = quoteAptOut(ethWei, cfg);
  return { ok: minOut <= quoted, quoted };
}
