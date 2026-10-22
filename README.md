# Move Bridge — Maroo OKRW ↔ Aptos (demo)

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

## 6b. Proven-fill demo (trustless settlement, no challenge wait)

```bash
# 1. Anchor the Aptos validator set (admin; from the stake resource):
#    lc.anchor(epoch, pubkeys[48B compressed G1…], powers[…])
# 2. Solver fills on Aptos, then anyone submits the QC + inclusion proof:
#    lc.submitQC(bcs129, bitmask, aggSig96)          # verifies aggregate BLS, records latestRoot
#    escrow.claimProven(id, leafHash, leafIndex, siblings, winner)  # verifies inclusion, binds auction winner
#    escrow.settle(id)                               # immediate — no challenge window
# 3. Build args off-chain:
cd swap && node src/lc-oracle.mjs                    # regen QC vectors -> /tmp/lc-vec.json
npx tsx --test test/prover.test.ts                   # 5 prover tests (leaf/fold/BCS pinned to forge vectors)
```

See `research/swap-plan-2026-10-07.md` §9 for the cryptography (POP-DST BLS,
NIST SHA3 accumulator, BCS layout), the oracle regen commands, and the
via_ir codegen rules. Forge suite: `contracts/maroo` 116 tests
(`AptosLightClient` 25, `SwapProvenE2E` 5, auction 14, committee 11, BLS 8).

## 7. Swap RFQ demo (ETH → APT solver auction, try it out)

A second, independent stack: users lock ETH in `SwapEscrow` on an EVM chain,
solvers compete in `SwapAuction`, the winner fills APT on Aptos testnet and
claims the escrow. Separate servers, ports, and state from the OKRW bridge
above — nothing is shared.

**What's running right now** (local Anvil + Aptos testnet):

| Piece | Where |
|---|---|
| Anvil (EVM chain, escrow + auction deployed) | `http://127.0.0.1:18888`, chain ID 31337 |
| Swap API + UI | `http://127.0.0.1:3201/swap.html` (`swap/src/server.ts`) |
| Solver daemon (auction mode, funded) | polling Anvil → filling on Aptos testnet |

Contracts (Anvil): escrow `0x5FbDB2315678afecb367f032d93F642f64180aa3`,
auction `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512`.

**Click-through** (fastest path — the stack is already live):

1. Open `http://127.0.0.1:3201/swap.html`.
2. Request a quote for e.g. `0.0001` ETH → note the APT octas quote.
3. Lock: ETH goes into escrow, you get a `swapId`.
4. The solver picks it up within ~10s (notify + quote on the auction).
5. Auction window is 600s — on Anvil, fast-forward instead of waiting
   (see commands below), then the solver finalizes, wins, fills APT on
   testnet, and claims. Check the swap status endpoint for
   `claimed: true`, and the recipient's APT balance on testnet.
6. After the 24h challenge window (fast-forward again), anyone calls
   `settle` and the solver is paid out in ETH.

**Restart it yourself:**

```bash
# terminal 1: swap server (quote/lock/status/refund API + UI)
cd swap && SWAP_PORT=3201 ETH_RPC_URL=http://127.0.0.1:18888 ETH_CHAIN_ID=31337 \
  SWAP_ESCROW_ADDRESS=0x5FbDB2315678afecb367f032d93F642f64180aa3 \
  SWAP_DEMO_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  node ./node_modules/.bin/tsx src/server.ts
# -> http://127.0.0.1:3201/swap.html

# terminal 2: solver daemon (auction mode)
cd swap && ETH_RPC_URL=http://127.0.0.1:18888 ETH_CHAIN_ID=31337 \
  SWAP_ESCROW_ADDRESS=0x5FbDB2315678afecb367f032d93F642f64180aa3 \
  SOLVER_EVM_PRIVATE_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d \
  SWAP_AUCTION_ADDRESS=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 \
  APTOS_SOLVER_PRIVATE_KEY=0x... \   # your funded Aptos testnet key (see below)
  APTOS_NODE_URL=https://fullnode.testnet.aptoslabs.com/v1 \
  EVM_CONFIRMATIONS=1 node ./node_modules/.bin/tsx src/solver.ts
```

(Anvil #0/#1 keys above are public test keys with no value — safe to paste.
Never reuse them anywhere real.)

**Anvil time-travel** (auction window 600s, challenge window 24h):

```bash
curl -X POST http://127.0.0.1:18888 -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"anvil_increaseTime","params":["700"]}'
curl -X POST http://127.0.0.1:18888 -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"anvil_mine","params":["3"]}'
```

**Solver funding:** each fill pays real testnet APT from the solver key, so
it must hold enough APT to cover the quotes it wins (a 0.0001 ETH swap fills
~6M octas ≈ 0.06 APT). Fund via the
[Aptos testnet faucet](https://aptos.dev/network/faucet) (note: the
`faucet-e2` host requires JWT auth and will not mint anonymously).
The live solver key `0x99301c6613fb523f3997250e8abae33bbb7c8d26b294f6223de8d46f017fc28b`
currently holds ~79M octas — enough for a few more tiny swaps.

**API cheat sheet** (`http://127.0.0.1:3201`):

```bash
curl -X POST /api/swap/quote -d '{"ethAmount":"0.0001"}'
curl -X POST /api/swap/lock  -d '{"ethAmount":"0.0001","aptosRecipient":"0x<64 hex>","minOutOctas":"<int>","idempotencyKey":"my-1"}'
curl /api/swap/status/4
curl -X POST /api/swap/refund -d '{"swapId":4}'   # after deadline, unclaimed only
```

**Edge cases already handled** (all proven live 2026-10-09): lock
idempotency keys (double-click safe), server-side minOut re-quote, exact
integer quote math (no float drift), solver self-registration + escrow-role
check at startup, crash-safe resume (never double-fills), poison-swap cursor
guard, stale-window skip, winner fast-path to fill, APT inventory pre-check,
expired quotes can't win auctions. Full list + war stories in `swap/` source
comments. Proven live e2e (swap 4): lock → quote → finalize → win →
on-chain Aptos fill `0x59222478…` (5,970,000 octas) → claim `0x57390530…` →
settle with payout.

### Reverse direction: APT → ETH (same page, direction toggle)

The swap page has an **APT → ETH** toggle: quote in octas, lock APT into
`swap_escrow` on Aptos, and the same solver daemon fills ETH on Anvil from
its inventory, claims the APT, and settles after the window. Single-solver
direct fill (no auction on this side in v1); activity shows the full `r-`
trail (`r-locked → r-picked-up → r-filled → r-claimed → r-settled`); track
with `r<id>` (e.g. `r1`).

```bash
curl -X POST /api/swap/rquote -d '{"aptOctas":"50000"}'
curl -X POST /api/swap/rlock  -d '{"aptOctas":"50000","evmRecipient":"0x<40 hex>","minOutWei":"<int>","idempotencyKey":"r-my-1"}'
curl /api/swap/rstatus/0
curl -X POST /api/swap/rrefund -d '{"swapId":0}'   # after deadline, unclaimed only
curl -X POST /api/swap/rsettle -d '{"swapId":0}'   # after challenge window matures
```

**Where it runs today:** the reverse escrow is deployed on **both** Aptos
testnet (module `0x1729…0983fd`, 24h window) and a **local testnet**
(`aptos node run-localnet`, REST `:8080`, faucet `:8081`, 120s demo window).
The live demo stack currently points at the localnet because the sandbox
cannot reach the public faucet to fund the reverse locker/solver keys —
promoting to testnet is a config change, not a code change: restart the
server + solver with the testnet `APTOS_NODE_URL`,
`SWAP_REVERSE_ESCROW_ADMIN=0x1729…0983fd`, and funded
`SWAP_REVERSE_USER_PK` / `APTOS_SOLVER_PRIVATE_KEY` (the escrow solver role
is currently the demo user key — rotate with `swap_escrow::set_solver`).
Proven live e2e on localnet (r1): lock 40k octas → pick-up → EVM fill
663,333,333,332 wei → claim → settle, all in the activity feed.

**Reverse gotchas baked in:** `vector<u8>` args must be byte arrays (a
`0x…` string encodes as ASCII and trips `EBAD_RECIPIENT`); fullnode URLs
need the `/v1` suffix in ts-sdk CUSTOM configs; explicit `maxGasAmount`
(`APTOS_MAX_GAS`, default 100k) so small demo wallets pass the fee-deposit
check; lock discovery polls `next_swap_id` (counter-based — the served
indexer exposes no `events` table, so `getEvents` is unusable there; the
bridge's burn-event path has the same latent dependency).

## Tests

```bash
cd contracts/maroo && forge test                      # 116 tests (light client + proven e2e incl.)
cd swap && npm test                                    # 20 tests (quote/prover/config)
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
