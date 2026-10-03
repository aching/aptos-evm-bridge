#!/usr/bin/env bash
# Demo step 1: lock native tOKRW in the Maroo vault for bridging to Aptos.
# Usage: deposit-maroo.sh <amount_okrw> <aptos_recipient_0x32bytes>
# Env: MAROO_RPC_URL, MAROO_USER_PRIVATE_KEY, MAROO_VAULT_ADDRESS
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/.tools/foundry:$PATH"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
: "${MAROO_RPC_URL:?}"; : "${MAROO_USER_PRIVATE_KEY:?}"; : "${MAROO_VAULT_ADDRESS:?}"
AMOUNT_OKRW="${1:?amount in OKRW (e.g. 1.5)}"
APTOS_RECIPIENT="${2:?0x-prefixed 32-byte Aptos address}"

AMOUNT_WEI=$(cast --to-wei "$AMOUNT_OKRW" ether)
echo "-> deposit $AMOUNT_OKRW tOKRW ($AMOUNT_WEI aokrw) for $APTOS_RECIPIENT"
cast send "$MAROO_VAULT_ADDRESS" "deposit(bytes)" "$APTOS_RECIPIENT" \
  --value "$AMOUNT_WEI" \
  --rpc-url "$MAROO_RPC_URL" --private-key "$MAROO_USER_PRIVATE_KEY"
