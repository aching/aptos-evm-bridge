# Maroo OKRW ↔ Aptos Bridge (demo)

Lock/mint + trusted-relayer demo bridge for the Won stablecoin between
**Maroo testnet** (native tOKRW, chain ID 450815) and **Aptos testnet**.
Token is **OKRW on both chains, 18 decimals, 1:1**.

- Maroo: `OkrwVault` locks native tOKRW (`deposit`), relayer-gated `release`.
- Aptos: `okrw` managed FA (mint/burn/pause/denylist) + `bridge` attestation.
- Relayer (TS): Maroo `DepositLocked` → Aptos `mint_attested`; manual
  `back.ts` for Aptos burn → Maroo `release`.

## Prereqs

Toolchains are vendored in `.tools/` (forge 1.6.0, aptos 9.6.0, solc 0.8.28).
Node 18+ required for the relayer.

```bash
export PATH="$PWD/.tools/foundry:$PWD/.tools/aptos:$PATH"
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
```

## 1. Keys

```bash
./scripts/keygen.sh   # fresh testnet-only keys (Maroo + Aptos)
```

Fund the Maroo user at https://faucet.maroo.io and both Aptos addresses
via the Aptos testnet faucet (`aptos account fund-with-faucet ...` in
`deploy-aptos.sh` does this automatically).

## 2. Deploy Maroo vault

```bash
export MAROO_RPC_URL=https://rpc-testnet.maroo.io
export MAROO_USER_PRIVATE_KEY=0x...       # deployer
export MAROO_RELAYER_ADDRESS=0x...        # from keygen
./scripts/deploy-maroo.sh
# -> note the deployed vault address as MAROO_VAULT_ADDRESS
```

## 3. Deploy Aptos package

```bash
export APTOS_USER_ADDRESS=0x... APTOS_USER_PRIVATE_KEY=...
export APTOS_RELAYER_ADDRESS=0x... APTOS_RELAYER_PRIVATE_KEY=...
./scripts/deploy-aptos.sh
# -> note APTOS_OKRW_METADATA; APTOS_BRIDGE_ADDRESS == APTOS_RELAYER_ADDRESS
```

## 4. Configure relayer

```bash
cp relayer/.env.example relayer/.env   # fill in all values
```

## 4b. Web demo (one-click UI)

```bash
cd relayer && cp .env.example .env   # fill in all values (incl. user keys)
WEB_PORT=3013 ./node_modules/.bin/tsx src/server.ts
# -> http://localhost:3013
```

Deposits relay **automatically**: a background loop attests each Maroo
deposit oldest-first (every `RELAY_POLL_S`, default 15s), exactly once —
deposit 0.5 then 1.0 and both arrive in nonce order with no clicks. The
"Relay now" button is the manual expedite for the same path (shares the
idempotency ledger, never double-mints). `AUTORELAY_ENABLED=0` restores
manual-only step-by-step narration. The relay queue panel shows every
recent deposit with its attested/pending status.

The page shows live balances (Maroo user / vault escrow / Aptos user+relayer),
three step buttons (Deposit → Relay → Bridge back), and an activity table with
explorer links. Each step runs live on testnets using the server-held demo keys.
`npm run web` does the same on the default port.

Modes: **One-click** (default, server demo keys) or **My wallet** (you sign the
Maroo deposit and Aptos transfer with your own keys; the server still relays,
burns, and releases). The recipient field lets minted OKRW go to any Aptos
address, and the balances panel can watch it. Each step shows live
submitted → confirmed states with elapsed time, plus a health pill
(escrow-vs-supply conservation, caps, pause state).

## 4c. Deploy the website (Fly.io)

The app is containerized (`Dockerfile`) and verified working in Docker.
`fly.toml` targets Fly.io (Seoul region, 1GB persistent volume for relayer
state, `/api/healthz` checks, 1 warm machine so the demo never cold-starts).

```bash
brew install flyctl && fly auth login
fly launch --no-deploy          # creates the app (keep region consistent!)
fly volumes create bridge_data --size 1
# Secrets = your relayer/.env (NEVER commit it; testnet keys only):
fly secrets set $(grep -v '^#' relayer/.env | grep -v '^$' | sed 's/^/--env /' | tr '\n' ' ')
fly deploy                      # -> https://okrw-bridge-demo.fly.dev
```

Notes:
- The Docker image was smoke-tested locally (balances, relay, `/api/health`
  conservation monitor all green in-container).
- First visit: check the health pill. If it ever flags a conservation gap,
  that means escrow ≠ supply — see `research/audit-2026-09-30.md` residual
  risk #6 (operator release path) for the recovery procedure.
- Costs: ~$2/mo (shared-cpu-1x + 1GB volume); `fly scale count 0` when idle.

## 5. Forward demo (Maroo → Aptos)

```bash
./scripts/balances.sh
./scripts/deposit-maroo.sh 1.5 <APTOS_USER_ADDRESS_0x...>
cd relayer && npm run forward   # watches vault, mints on Aptos
./scripts/balances.sh           # user OKRW > 0 on Aptos
```

## 6. Back demo (Aptos → Maroo)

```bash
./scripts/withdraw-aptos.sh <amount_base_units> <MAROO_USER_ADDRESS>
# step 1 prints the user transfer command; step 2 burns + releases.
./scripts/balances.sh
```

## Tests

```bash
cd contracts/maroo && forge test                      # 24 tests (incl. invariant fuzz)
cd contracts/aptos && aptos move test --dev --skip-fetch-latest-git-deps  # 17 tests
cd relayer && ./node_modules/.bin/tsc --noEmit
./scripts/e2e-regression.sh 0.2   # live testnet round-trip + conservation + idempotency
```

## Trust model & limits (demo only)

- Single trusted relayer holds Aptos MintRef + Maroo release key.
- Daily caps on both sides (`dailyReleaseCap`, `daily_mint_cap`).
- No light-client verification. Do not use on mainnet.

## Operability

- **Health**: `GET /api/health` runs the deep check (vault escrow vs real
  on-chain `okrw::supply`, cap exhaustion, pause state). The UI health pill
  polls it. `/api/healthz` is the chain-free liveness probe for hosting.
- **Paging**: set `MONITOR_ENABLED=1`, `MONITOR_INTERVAL_S`, and
  `ALERT_WEBHOOK_URL` (Slack-compatible) in `relayer/.env` — error-level
  issues page once per check per `ALERT_COOLDOWN_S`, with an all-clear on
  recovery. Empty webhook = errors log to stderr only.
- **CI** (`.github/workflows/ci.yml`): pin-guard (framework rev + vendored
  solc) → `forge test` → `aptos move compile` + `move test` → `npm ci` +
  `tsc --noEmit`. E2E regression stays out of CI (needs funded testnet keys);
  run `./scripts/e2e-regression.sh` manually after contract changes.

## Security controls (Aptos side, via UI)

The Security card exposes the coin's USDC-grade rails, signed server-side
with the demo role keys (relayer = minter/pauser/bridge-owner, user =
denylister): pause/unpause coin, pause/unpause bridge, one-tx emergency
pause, denylist/undenylist with live state check, daily mint-cap setter.
Role *rotation* (propose/accept admin, set minter/pauser/denylister,
propose/claim relayer) is admin/publisher-key gated and stays CLI-only —
the server deliberately does not hold those keys. All actions land in the
Activity history with tx links; failures render as structured errors
(title + what-to-do + safe-to-retry flag) instead of raw abort text.
