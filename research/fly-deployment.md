# Fly.io deployment (live since 2026-10-01). Testnet demo only.

## App
- Name: `aptos-evm-bridge` → https://aptos-evm-bridge.fly.dev/
- Region: `nrt` (Tokyo — Fly picked capacity over the `icn` in the original fly.toml)
- Image: `registry.fly.io/aptos-evm-bridge:deployment-01M3V7K1SNFFHM9M4N2WTVRSS5` (85 MB)
- Machines: 2× shared-cpu-1x (HA pair created by default), IDs:
  - `6835757c1e07e8`
  - `80e99e9b0ed1e8`
- IPs: dedicated IPv6 `2a09:8280:1::1a2:9a4d:0`, shared IPv4 `66.241.125.119`

## Live fly.toml vs repo
`fly launch` rewrote parts of the checked-in `fly.toml`:
- `internal_port` 8080 → **3013** (matches server default; `PORT` env not set)
- `min_machines_running` 1 → **0** (both machines stop when idle; cold start ~2s on wake)
- **No `[[mounts]]`** — the `bridge_data` volume was never attached. Relayer
  state (`relayer-state.json`: forward cursor, idempotency ledger, history)
  currently lives on the ephemeral rootfs: a machine restart/redeploy wipes
  it. On-chain replay guards (Seen table, nonces) still prevent double-mint,
  but history and the idempotency ledger reset. Attach a volume before any
  real demo traffic (see below).
- `primary_region = nrt` (not `icn`).

## Secrets (set via `fly secrets set`, NEVER in repo)
14 keys from `relayer/.env`: MAROO_RPC_URL, MAROO_CHAIN_ID,
MAROO_VAULT_ADDRESS, MAROO_RELAYER_PRIVATE_KEY, MAROO_CONFIRMATIONS,
APTOS_NODE_URL, APTOS_BRIDGE_ADDRESS, APTOS_OKRW_METADATA,
APTOS_RELAYER_PRIVATE_KEY, APTOS_USER_ADDRESS, APTOS_MODULE_ADDRESS,
MAROO_USER_ADDRESS, MAROO_USER_PRIVATE_KEY, APTOS_USER_PRIVATE_KEY.
⚠️ Initial deploy failed boot (`Missing env: VAULT`) because the first
secrets command wrongly used `--env` flags (`fly secrets set` takes bare
`KEY=value`). Correct form:
`fly secrets set $(grep -v '^#' relayer/.env | grep -v '^$' | tr '\n' ' ')`
+ `fly deploy` (secrets apply on next release).

## Known gaps before demo traffic
1. **No volume attached** — add: `fly volumes create bridge_data --size 1 --region nrt`
   + restore the `[[mounts]]` + `RELAYER_DATA_DIR=/data` in fly.toml.
2. **Scale to 1 machine** (`fly scale count 1`) unless HA is wanted (2× cost).
3. **Monitor loop off** — `MONITOR_ENABLED`/`ALERT_WEBHOOK_URL` not set in
   secrets; `/api/health` works on demand, no background paging.
4. Shell history on the deploy machine contains the four private keys in
   plaintext (from the secrets commands). Testnet-only; rotate if reused.
