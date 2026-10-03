#!/usr/bin/env bash
# End-to-end regression test against LIVE testnets via the web server API.
# Asserts conservation at every leg: deposit raises escrow 1:1, relay mints
# 1:1, bridge-back burns + releases 1:1, and /api/health stays OK.
#
# Usage: WEB_PORT=3013 ./scripts/e2e-regression.sh [amount_tokrw]
# Requires: server running (npm run web), funded demo accounts.
set -euo pipefail
BASE="${BASE_URL:-http://localhost:${WEB_PORT:-3013}}"
AMOUNT="${1:-0.2}"

fail() { echo "E2E FAIL: $*" >&2; exit 1; }
pass() { echo "E2E ok: $*"; }

to_base() { python3 -c "print(int($1 * 10**18))"; }

api() { curl -s -m 120 -X POST "$BASE$1" -H 'Content-Type: application/json' -d "$2"; }
get() { curl -s -m 30 "$BASE$1"; }
num() { python3 -c "import json,sys; print(json.load(sys.stdin)[\"$1\"])"; }

echo "== E2E regression: $AMOUNT tOKRW round-trip via $BASE =="
AMOUNT_BASE=$(to_base "$AMOUNT")

B0=$(get /api/balances)
E0=$(echo "$B0" | num vaultEscrow); U0=$(echo "$B0" | num aptosUser)
H0=$(get /api/health | num ok || true)

# --- leg 1: deposit
echo "-- leg 1: deposit"
DKEY="e2e-$(date +%s)"
D=$(api /api/deposit "{\"amount\":\"$AMOUNT_BASE\",\"idempotencyKey\":\"$DKEY\"}")
DHASH=$(echo "$D" | num hash); NONCE=$(echo "$D" | num nonce); BLK=$(echo "$D" | num blockNumber)
[ -n "$DHASH" ] || fail "no deposit hash: $D"
B1=$(get /api/balances)
E1=$(echo "$B1" | num vaultEscrow)
[ "$E1" -eq "$((E0 + AMOUNT_BASE))" ] || fail "escrow $E0 -> $E1, expected +$AMOUNT_BASE"
pass "deposit $DHASH (nonce $NONCE): escrow +$AMOUNT"

# --- leg 2: relay
echo "-- leg 2: relay"
FROM=$((BLK - 5))
R=$(api /api/relay "{\"fromBlock\":\"$FROM\",\"nonce\":\"$NONCE\"}")
RHASH=$(echo "$R" | num hash)
[ -n "$RHASH" ] || fail "no relay hash: $R"
B2=$(get /api/balances)
U2=$(echo "$B2" | num aptosUser)
[ "$U2" -eq "$((U0 + AMOUNT_BASE))" ] || fail "aptos user $U0 -> $U2, expected +$AMOUNT_BASE"
pass "relay $RHASH: minted +$AMOUNT"

# --- health mid-trip (conservation must hold)
H=$(get /api/health)
echo "$H" | python3 -c "import json,sys; h=json.load(sys.stdin); assert h['ok'], h['issues']" \
  || fail "health check failed mid-trip: $H"
pass "health ok (escrow == supply)"

# --- leg 3: bridge back
echo "-- leg 3: bridge-back"
BB=$(api /api/bridge-back "{\"amount\":\"$AMOUNT_BASE\",\"idempotencyKey\":\"e2e-back-$(date +%s)\"}")
BHASH=$(echo "$BB" | num burnHash); RELH=$(echo "$BB" | num releaseHash)
[ -n "$BHASH" ] && [ -n "$RELH" ] || fail "missing burn/release hash: $BB"
sleep 5 # Maroo receipt already waited server-side; indexer lag only
B3=$(get /api/balances)
E3=$(echo "$B3" | num vaultEscrow); U3=$(echo "$B3" | num aptosUser)
[ "$E3" -eq "$E0" ] || fail "escrow $E3 != start $E0"
[ "$U3" -eq "$U0" ] || fail "aptos user $U3 != start $U0"
pass "bridge-back burn $BHASH release $RELH: balances back to start"

# --- leg 4: idempotency replay: same keys must return recorded results, no new txs.
echo "-- leg 4: idempotency replay"
N_BEFORE=$(get /api/balances | num nextDepositNonce)
# Re-post leg-1's EXACT deposit key: must replay, not re-deposit.
DRE=$(api /api/deposit "{\"amount\":\"$AMOUNT_BASE\",\"idempotencyKey\":\"$DKEY\"}")
echo "$DRE" | python3 -c "import json,sys; assert json.load(sys.stdin).get('replayed') is True" \
  || fail "deposit replay did not return recorded result: $DRE"
R2=$(api /api/relay "{\"fromBlock\":\"$FROM\",\"nonce\":\"$NONCE\"}")
echo "$R2" | python3 -c "import json,sys; assert json.load(sys.stdin).get('replayed') is True" \
  || fail "relay replay did not return recorded result: $R2"
N_AFTER=$(get /api/balances | num nextDepositNonce)
[ "$N_AFTER" -eq "$N_BEFORE" ] || fail "deposit nonce advanced on replay ($N_BEFORE -> $N_AFTER)"
pass "deposit+relay replays return recorded results, no double-mint, nonce counter unchanged"

echo "== E2E PASS: full round-trip + conservation + idempotency =="
