/// Human-readable bridge errors. Every known on-chain failure (both Move
/// modules, the Maroo vault, common framework aborts) maps to a structured
/// { code, title, hint, retryable } so the UI never shows a raw abort offset
/// or undecodable selector. Unknown errors pass through with a generic code.

export interface FriendlyError {
  code: string; // stable machine-readable code, e.g. "MINT_CAP_EXCEEDED"
  title: string; // one-line human summary
  hint: string; // what to do about it
  retryable: boolean; // safe for the operator to retry as-is
}

interface Spec {
  title: string;
  hint: string;
  retryable: boolean;
}

// Move abort codes, keyed "module::CODE".
const MOVE_ERRORS: Record<string, Spec> = {
  "bridge::1": { title: "Wrong relayer key", hint: "The signer is not the registered bridge relayer. Check APTOS_RELAYER_PRIVATE_KEY.", retryable: false },
  "bridge::2": { title: "Deposit already relayed", hint: "This Maroo nonce was already attested — no double-mint. Safe to ignore.", retryable: false },
  "bridge::3": { title: "Amount must be greater than zero", hint: "Enter an amount above 0.", retryable: false },
  "bridge::4": { title: "Daily mint cap reached", hint: "Today's Aptos mint allowance is used up. Retry after the UTC-day window rolls, or raise it via bridge::set_daily_mint_cap.", retryable: true },
  "bridge::5": { title: "Bridge is paused", hint: "Minting/burning is frozen by emergency pause. Unpause bridge + coin to resume.", retryable: false },
  "bridge::6": { title: "Bad Maroo recipient", hint: "The Maroo address must be 20 bytes (0x + 40 hex chars).", retryable: false },
  "bridge::7": { title: "Wrong coin metadata", hint: "The bridge only mints the pinned OKRW coin. Check APTOS_OKRW_METADATA.", retryable: false },
  "bridge::8": { title: "Not the pending relayer", hint: "Only the proposed address can claim a relayer rotation.", retryable: false },
  "okrw::1": { title: "Coin is paused", hint: "Transfers, mint and burn are frozen. Unpause via okrw::unpause.", retryable: false },
  "okrw::2": { title: "Address is denylisted", hint: "This address is frozen by the denylister. Undenylist to resume.", retryable: false },
  "okrw::3": { title: "Not the coin admin", hint: "Caller lacks the admin role.", retryable: false },
  "okrw::4": { title: "Not the minter", hint: "Only the minter role (relayer) can mint. Check APTOS_RELAYER_PRIVATE_KEY.", retryable: false },
  "okrw::5": { title: "Not the pauser", hint: "Caller lacks the pauser role.", retryable: false },
  "okrw::6": { title: "Not the denylister", hint: "Caller lacks the denylister role.", retryable: false },
  "okrw::7": { title: "Amount must be greater than zero", hint: "Enter an amount above 0.", retryable: false },
};

// Maroo vault custom errors, keyed by 4-byte selector.
const VAULT_ERRORS: Record<string, Spec> = {
  "0x1f2a2005": { title: "Amount must be greater than zero", hint: "Enter an amount above 0.", retryable: false },
  "0xd92e233d": { title: "Zero address not allowed", hint: "Recipient address is missing.", retryable: false },
  "0x6dafeb71": { title: "Bad Aptos recipient", hint: "Recipient must be a 32-byte Aptos address.", retryable: false },
  "0x366b2e5a": { title: "Not the relayer", hint: "Only the vault relayer key can release. Check MAROO_RELAYER_PRIVATE_KEY.", retryable: false },
  "0x17a84242": { title: "Not the vault admin", hint: "Caller lacks the admin role.", retryable: false },
  "0x1309a563": { title: "Vault is paused", hint: "Deposits and releases are frozen. Unpause to resume.", retryable: false },
  "0x1a20d3e6": { title: "Release already processed", hint: "This (to, amount, nonce) was already released — no double-spend. Safe to ignore.", retryable: false },
  "0xdb9d0c46": { title: "Release nonce out of order", hint: "Releases must execute in strict nonce sequence. Retry the expected nonce first.", retryable: true },
  "0x3e814127": { title: "Daily release cap reached", hint: "Today's Maroo release allowance is used up. Retry after the UTC-day window rolls, or raise it via setDailyReleaseCap.", retryable: true },
  "0xb6b8cf18": { title: "Release transfer failed", hint: "The tOKRW transfer to the recipient reverted (e.g. recipient is a contract that rejects funds).", retryable: false },
  "0xed3ba6a6": { title: "Reentrant call blocked", hint: "Internal guard tripped — report this, it should not happen in normal use.", retryable: false },
  "0x1d0022d1": { title: "Not the pending admin", hint: "Only the proposed address can accept the admin transfer.", retryable: false },
};

// Aptos framework aborts we surface with context (substrings of SDK text).
const FRAMEWORK_HINTS: { match: RegExp; spec: Spec }[] = [
  { match: /INSUFFICIENT_BALANCE|insufficient.*balance/i, spec: { title: "Insufficient balance", hint: "The signing account lacks funds (gas on Aptos, tOKRW on Maroo). Top up and retry.", retryable: true } },
  { match: /SEQUENCE_NUMBER_TOO_OLD|sequence number/i, spec: { title: "Stale transaction sequence", hint: "A conflicting transaction landed first. Retry — the relayer rebuilds the transaction.", retryable: true } },
  { match: /gas/i, spec: { title: "Gas error", hint: "Transaction ran out of gas or gas price moved. Retry; if it persists, top up the signer.", retryable: true } },
];

function moveAbort(msg: string): Spec | null {
  // SDK shapes: "Move abort in 0xADDR::bridge::mint_attested ... (code 4)"
  // or "... Execution failed in 0x..::bridge::mint_attested ... at code offset N".
  // NOTE: "code offset" is a bytecode offset, NOT the abort code — when only
  // an offset is present we cannot identify the exact abort, so fall through
  // to the per-function fallback below.
  const m = msg.match(/([a-z_]+)::(\w+)[\s\S]{0,200}?\(?(?:code|error)\s+(\d+)\)?/i)
    ?? msg.match(/::(bridge|okrw)::\w+[\s\S]{0,200}?\b([1-8])\b/);
  if (m) {
    const mod = m[1] === "bridge" || m[1] === "okrw" ? m[1] : null;
    const code = m[3] ?? m[2];
    if (mod && MOVE_ERRORS[`${mod}::${code}`]) return MOVE_ERRORS[`${mod}::${code}`];
  }
  // Fallback: bare "(abort code N)" with module name nearby.
  const mod2 = /::(bridge|okrw)::/.exec(msg)?.[1];
  const code2 = /abort[^\d]*(\d+)/i.exec(msg)?.[1];
  if (mod2 && code2 && MOVE_ERRORS[`${mod2}::${code2}`]) return MOVE_ERRORS[`${mod2}::${code2}`];
  // Last resort: known function failed without a decodable code. Name the
  // function and list the likely causes instead of showing raw output.
  const fn = /::(bridge|okrw)::(\w+)/.exec(msg);
  if (fn) {
    const fns: Record<string, Spec> = {
      "bridge::mint_attested": { title: "Mint attestation failed", hint: "The bridge refused to mint. Most likely: daily mint cap reached (check the health pill), bridge paused, or this deposit was already relayed. Retry is safe — attestation is idempotent.", retryable: true },
      "bridge::burn_withdraw": { title: "Burn/withdraw failed", hint: "The bridge refused to burn. Most likely: bridge paused, or relayer OKRW balance is lower than the amount. Check balances and pause state.", retryable: true },
      "okrw::pause": { title: "Pause failed", hint: "Caller lacks the pauser role, or the coin is already paused.", retryable: false },
      "okrw::unpause": { title: "Unpause failed", hint: "Caller lacks the pauser role, or the coin is not paused.", retryable: false },
      "okrw::denylist": { title: "Denylist failed", hint: "Caller lacks the denylister role.", retryable: false },
      "okrw::undenylist": { title: "Undenylist failed", hint: "Caller lacks the denylister role.", retryable: false },
    };
    if (fns[`${fn[1]}::${fn[2]}`]) return fns[`${fn[1]}::${fn[2]}`];
  }
  return null;
}

function vaultRevert(msg: string): Spec | null {
  const m = /0x[0-9a-fA-F]{8}/.exec(msg);
  if (m && VAULT_ERRORS[m[0].toLowerCase()]) return VAULT_ERRORS[m[0].toLowerCase()];
  if (/revert|reverted/i.test(msg)) {
    return { title: "Maroo transaction reverted", hint: "The vault rejected the call. Check the transaction on the Maroo explorer for the revert reason.", retryable: false };
  }
  return null;
}

/** Convert any thrown error into a user-facing FriendlyError + short code. */
export function friendlyError(e: unknown, context: "deposit" | "relay" | "bridge-back" | "balances" | "health"): FriendlyError & { raw: string } {
  const msg = (e as Error)?.message ?? String(e);
  const raw = msg.slice(0, 300);

  const mv = moveAbort(msg);
  if (mv) return { code: `MOVE_${context.toUpperCase()}`, ...mv, raw };
  const vv = vaultRevert(msg);
  if (vv) return { code: `VAULT_${context.toUpperCase()}`, ...vv, raw };
  for (const { match, spec } of FRAMEWORK_HINTS) {
    if (match.test(msg)) return { code: `TX_${context.toUpperCase()}`, ...spec, raw };
  }
  if (/timeout|timed out|ECONNRESET|fetch failed|network/i.test(msg)) {
    return { code: `NET_${context.toUpperCase()}`, title: "Network/RPC timeout", hint: "A chain RPC didn't respond. Safe to retry — nothing was submitted twice (idempotency keys + on-chain guards).", retryable: true, raw };
  }
  if (/no .* found in range|no blocks in range/i.test(msg)) {
    return { code: `NOTFOUND_${context.toUpperCase()}`, title: "Nothing to relay in range", hint: "No unattested deposit in the scanned blocks. Deposit first, or widen the scan range.", retryable: false, raw };
  }
  return { code: `UNKNOWN_${context.toUpperCase()}`, title: "Unexpected error", hint: "See server logs and the raw detail below. Report with the raw text.", retryable: false, raw };
}
