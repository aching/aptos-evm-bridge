#!/usr/bin/env bash
# Demo step 3 (return path): user sends OKRW to relayer, relayer burns + releases.
# Usage: withdraw-aptos.sh <amount_base_units> <maroo_recipient_0x>
# Env: relayer/.env values (APTOS_*, MAROO_*, APTOS_USER_ADDRESS)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/.tools/aptos:$PATH"
: "${APTOS_USER_ADDRESS:?}"; : "${APTOS_OKRW_METADATA:?}"
: "${APTOS_BRIDGE_ADDRESS:?}"; : "${APTOS_USER_PRIVATE_KEY:?}"
APTOS_NODE_URL="${APTOS_NODE_URL:-https://fullnode.testnet.aptoslabs.com/v1}"

AMOUNT="${1:?amount in base units (aokrw)}"
MAROO_RECIPIENT="${2:?0x maroo recipient}"

echo "-> step 1: user transfers $AMOUNT OKRW to relayer:"
aptos move run --function-id 0x1::primary_fungible_store::transfer \
  --type-args 0x1::fungible_asset::Metadata \
  --args "address:$APTOS_OKRW_METADATA" "address:$APTOS_BRIDGE_ADDRESS" "u64:$AMOUNT" \
  --private-key "$APTOS_USER_PRIVATE_KEY" --url "$APTOS_NODE_URL" --assume-yes 2>&1 | tail -2
echo ""
echo "-> step 2: relayer burns + releases on Maroo:"
cd "$ROOT/relayer" && ./node_modules/.bin/tsx src/back.ts "$APTOS_USER_ADDRESS" "$AMOUNT" "$MAROO_RECIPIENT"
