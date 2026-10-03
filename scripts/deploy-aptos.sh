#!/usr/bin/env bash
# Deploy okrw_bridge Move package to Aptos testnet, then init coin + bridge.
#
# Env (export before running):
#   APTOS_USER_ADDRESS / APTOS_USER_PRIVATE_KEY       (publisher + coin admin)
#   APTOS_RELAYER_ADDRESS / APTOS_RELAYER_PRIVATE_KEY (minter + bridge owner)
#   APTOS_NODE_URL (default: testnet fullnode)
#
# Prints the two addresses needed for relayer/.env.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/.tools/aptos:$PATH"
: "${APTOS_USER_ADDRESS:?export APTOS_USER_ADDRESS (see scripts/keygen.sh)}"
: "${APTOS_USER_PRIVATE_KEY:?export APTOS_USER_PRIVATE_KEY}"
: "${APTOS_RELAYER_ADDRESS:?export APTOS_RELAYER_ADDRESS}"
: "${APTOS_RELAYER_PRIVATE_KEY:?export APTOS_RELAYER_PRIVATE_KEY}"
APTOS_NODE_URL="${APTOS_NODE_URL:-https://fullnode.testnet.aptoslabs.com/v1}"
FAUCET_URL="https://faucet.testnet.aptoslabs.com"

echo "-> Funding publisher + relayer from testnet faucet..."
aptos account fund-with-faucet --account "$APTOS_USER_ADDRESS" --amount 100_000_000 \
  --faucet-url "$FAUCET_URL" --assume-yes 2>&1 | tail -1 || true
aptos account fund-with-faucet --account "$APTOS_RELAYER_ADDRESS" --amount 100_000_000 \
  --faucet-url "$FAUCET_URL" --assume-yes 2>&1 | tail -1 || true

cd "$ROOT/contracts/aptos"
echo "-> Publishing okrw_bridge (publisher $APTOS_USER_ADDRESS)..."
aptos move publish \
  --named-addresses "okrw_bridge=$APTOS_USER_ADDRESS" \
  --private-key "$APTOS_USER_PRIVATE_KEY" \
  --url "$APTOS_NODE_URL" --assume-yes --skip-fetch-latest-git-deps 2>&1 | tail -3

echo "-> okrw::init (minter/pauser/denylister: relayer/relayer/user)..."
# NOTE: pauser=relayer (not split) so bridge::emergency_pause can freeze the
# coin + bridge in one tx. Rotate apart later with okrw::set_pauser if needed.
aptos move run --function-id "${APTOS_USER_ADDRESS}::okrw::init" \
  --args "address:$APTOS_RELAYER_ADDRESS" "address:$APTOS_RELAYER_ADDRESS" "address:$APTOS_USER_ADDRESS" \
  --private-key "$APTOS_USER_PRIVATE_KEY" --url "$APTOS_NODE_URL" --assume-yes 2>&1 | tail -2

echo "-> bridge::init (owner: relayer, pinned metadata)..."
META_EARLY=$(aptos move view --function-id "${APTOS_USER_ADDRESS}::okrw::metadata_address" \
  --args "address:$APTOS_USER_ADDRESS" --url "$APTOS_NODE_URL" 2>/dev/null | python3 -c "import json,sys; print(json.load(sys.stdin)['Result'][0])" 2>/dev/null || true)
aptos move run --function-id "${APTOS_USER_ADDRESS}::bridge::init" \
  --args "address:$META_EARLY" "u64:10000000000000000" \
  --private-key "$APTOS_RELAYER_PRIVATE_KEY" --url "$APTOS_NODE_URL" --assume-yes 2>&1 | tail -2

echo "-> OKRW metadata address:"
aptos move view --function-id "${APTOS_USER_ADDRESS}::okrw::metadata_address" \
  --args "address:$APTOS_USER_ADDRESS" --url "$APTOS_NODE_URL" 2>&1 | tail -3

echo ""
echo "APTOS_BRIDGE_ADDRESS=$APTOS_RELAYER_ADDRESS"
echo "(copy APTOS_OKRW_METADATA from the view output above)"
