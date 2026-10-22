/// Startup key/address validation with actionable errors.
/// The raw viem `privateKeyToAccount` crash ("invalid private key, expected
/// hex...") cost a debug session on 2026-10-09 when an address was pasted
/// in place of a key. Every entrypoint must fail fast with the fix attached.
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";
import type { Address, Hex } from "viem";

/** Load a 32-byte EVM key from env: trims, demands 0x + 64 hex, derives. */
export function loadEvmKey(envName: string, purpose: string): { key: Hex; account: PrivateKeyAccount } {
  const raw = (process.env[envName] ?? "").trim();
  if (!raw) throw new Error(`Missing env: ${envName} (${purpose})`);
  const key = (raw.startsWith("0x") ? raw : `0x${raw}`) as Hex;
  if (!/^0x[0-9a-fA-F]{64}$/.test(key)) {
    const looksAddr = /^0x[0-9a-fA-F]{40}$/.test(key.trim());
    throw new Error(
      `Invalid ${envName}: expected 32-byte 0x private key (64 hex chars), got ${raw.length} chars` +
        (looksAddr ? " — that looks like an ADDRESS, not a private key" : "") +
        ` (${purpose})`,
    );
  }
  try {
    return { key, account: privateKeyToAccount(key) };
  } catch (e) {
    throw new Error(`Invalid ${envName}: viem rejected the key (${(e as Error).message.slice(0, 100)}) (${purpose})`);
  }
}

/** Load a 20-byte EVM contract address from env. */
export function loadEvmAddress(envName: string, purpose: string): Address {
  const raw = (process.env[envName] ?? "").trim();
  if (!raw) throw new Error(`Missing env: ${envName} (${purpose})`);
  if (!/^0x[0-9a-fA-F]{40}$/.test(raw)) {
    throw new Error(`Invalid ${envName}: expected 20-byte 0x address, got ${raw.length} chars (${purpose})`);
  }
  return raw as Address;
}

/** Optional EVM address (auction/attester): "" / unset / zero-ish = disabled. */
export function loadOptionalEvmAddress(envName: string): Address | null {
  const raw = (process.env[envName] ?? "").trim();
  if (!raw || /^0x0+$/.test(raw)) return null;
  if (!/^0x[0-9a-fA-F]{40}$/.test(raw)) {
    throw new Error(`Invalid ${envName}: expected 20-byte 0x address or empty, got ${raw.length} chars`);
  }
  return raw as Address;
}

/** Parse a positive-bigint request field with a field name in the error. */
export function parseAmountField(value: unknown, field: string): bigint {
  if (typeof value !== "string" || !/^\d+$/.test(value)) {
    throw new Error(`${field} must be a non-negative integer string`);
  }
  return BigInt(value);
}
