#!/usr/bin/env bash
# Generate fresh testnet-only keys for the demo.
# Prints: Maroo relayer/user addresses + private keys, Aptos relayer/user addresses + keys.
# SAFE: testnet only. Keys print to stdout — copy into relayer/.env, never commit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/.tools/foundry:$ROOT/.tools/aptos:$PATH"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1

echo "=== Maroo (EVM) keys via cast ==="
MAROO_RELAYER_PK=$(cast wallet new 2>/dev/null | grep -i "private key" | awk '{print $NF}')
MAROO_USER_PK=$(cast wallet new 2>/dev/null | grep -i "private key" | awk '{print $NF}')
MAROO_RELAYER_ADDR=$(cast wallet address "$MAROO_RELAYER_PK" 2>/dev/null)
MAROO_USER_ADDR=$(cast wallet address "$MAROO_USER_PK" 2>/dev/null)
echo "MAROO_RELAYER_ADDRESS=$MAROO_RELAYER_ADDR"
echo "MAROO_RELAYER_PRIVATE_KEY=$MAROO_RELAYER_PK"
echo "MAROO_USER_ADDRESS=$MAROO_USER_ADDR"
echo "MAROO_USER_PRIVATE_KEY=$MAROO_USER_PK"

echo ""
echo "=== Aptos keys ==="
gen_aptos() {
  local f
  f=$(mktemp)
  aptos key generate --output-file "$f" --assume-yes >/dev/null 2>&1
  local pub_hex
  pub_hex=$(cat "${f}.pub")
  # authKey = sha3_256(pubkey_bytes || 0x00)
  local addr
  addr=$(python3 -c "
import hashlib
pub = bytes.fromhex('$pub_hex')
h = hashlib.sha3_256(pub + b'\x00').hexdigest()
print('0x' + h)")
  # CLI key file is raw BCS hex; TS SDK accepts ed25519-private: prefix or raw hex
  local priv_hex
  priv_hex=$(cat "$f")
  rm -f "$f" "${f}.pub"
  echo "$addr $priv_hex"
}
read -r APTOS_RELAYER_ADDR APTOS_RELAYER_RAW <<< "$(gen_aptos)"
read -r APTOS_USER_ADDR APTOS_USER_RAW <<< "$(gen_aptos)"
echo "APTOS_RELAYER_ADDRESS=$APTOS_RELAYER_ADDR"
echo "APTOS_RELAYER_PRIVATE_KEY=$APTOS_RELAYER_RAW"
echo "APTOS_USER_ADDRESS=$APTOS_USER_ADDR"
echo "APTOS_USER_PRIVATE_KEY=$APTOS_USER_RAW"

echo ""
echo "Next: fund MAROO_USER_ADDRESS at https://faucet.maroo.io and both Aptos addresses at the Aptos testnet faucet."
