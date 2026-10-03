#!/usr/bin/env bash
# Demo helpers: show balances on both chains.
# Env: MAROO_RPC_URL, MAROO_VAULT_ADDRESS, MAROO_USER_ADDRESS,
#      APTOS_NODE_URL, APTOS_OKRW_METADATA, APTOS_USER_ADDRESS
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/.tools/foundry:$ROOT/.tools/aptos:$PATH"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

echo "== Maroo =="
echo -n "user tOKRW:   "; cast balance "${MAROO_USER_ADDRESS:?}" --rpc-url "${MAROO_RPC_URL:?}" | cast --from-wei
echo -n "vault escrow: "; cast balance "${MAROO_VAULT_ADDRESS:?}" --rpc-url "$MAROO_RPC_URL" | cast --from-wei

echo "== Aptos =="
APTOS_NODE_URL="${APTOS_NODE_URL:-https://fullnode.testnet.aptoslabs.com/v1}"
echo -n "user OKRW:    "
aptos account balance --account "${APTOS_USER_ADDRESS:?}" --asset-type "${APTOS_OKRW_METADATA:?}" \
  --url "$APTOS_NODE_URL" 2>&1 | grep -oE '[0-9]+' | head -1 || echo 0
