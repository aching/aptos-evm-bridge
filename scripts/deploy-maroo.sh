#!/usr/bin/env bash
# Deploy OkrwVault to Maroo testnet.
# Env: MAROO_RPC_URL, MAROO_USER_PRIVATE_KEY (deployer), MAROO_RELAYER_ADDRESS
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/.tools/foundry:$PATH"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
: "${MAROO_RPC_URL:?set MAROO_RPC_URL}"
: "${MAROO_USER_PRIVATE_KEY:?set MAROO_USER_PRIVATE_KEY (deployer)}"
: "${MAROO_RELAYER_ADDRESS:?set MAROO_RELAYER_ADDRESS}"

cd "$ROOT/contracts/maroo"
forge script script/DeployVault.s.sol \
  --rpc-url "$MAROO_RPC_URL" \
  --private-key "$MAROO_USER_PRIVATE_KEY" \
  --broadcast -vv
