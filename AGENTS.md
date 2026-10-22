# AGENTS.md — Maroo OKRW ↔ Aptos Bridge + ETH→APT Swap RFQ

## Overview
Two independent demos share this repo. Separate chains, contracts, servers,
ports, and keys — **nothing is shared at runtime**.

**Demo A — OKRW bridge** (original brief): Won stablecoin between **Maroo**
and **Aptos testnet**. V1: **lock/mint + trusted relayer**. OKRW locked in a
vault on Maroo, OKRW minted on Aptos; burn on Aptos unlocks on Maroo. Token is
called **OKRW on both chains**. UI + API on **:3024**.

**Demo B — Swap RFQ, both directions** (added 2026-10-07–09, reversed 2026-10-11):
- Forward (live on Anvil + Aptos testnet): users lock ETH in `SwapEscrow`;
  solvers compete in `SwapAuction`; the winner fills APT from its own
  inventory and claims the escrow. One-way (refund if unfilled), 24h challenge
  window, expiry-aware finalize. Proven live e2e (swap 4: lock → quote →
  finalize → win → Aptos fill `0x59222478…` 5,970,000 octas → claim
  `0x57390530…` → settle + payout).
- Reverse (live on Anvil + **local** Aptos testnet, needs testnet APT to
  promote): users lock APT in `swap_escrow::SwapLocked` on Aptos; the same
  solver daemon fills ETH on Anvil from inventory, claims the locked APT, and
  settles after the window. Single-solver direct fill (no Aptos auction in
  v1); counter-based lock discovery (`next_swap_id` polling — the served
  indexer has no `events` table). Proven live e2e on localnet (r1: lock →
  pick-up → EVM fill 663,333,333,332 wei → claim → settle, full `r-` activity
  trail). Challenge window 120s on the local deployment (24h on testnet).
UI + API on **:3201** (direction toggle ETH→APT / APT→ETH), solver daemon
alongside.
> Status: both demos live and tested end-to-end (2026-10-11). Original design
> locked (see Locked decisions); swap decisions in
> `research/swap-plan-2026-10-07.md`.

## Goals (in order)
1. **Correctness first** — no loss, double-mint, or unauthorized mint. Demo on Maroo testnet + Aptos testnet.
2. **USDC-grade controls on Aptos** — standard regulated-FA pattern: managed fungible asset with distinct mint/burn, pause, denylist/freeze roles.
3. **Simple demo UX** — CLI/scripts: faucet on Maroo → bridge → balance on Aptos → bridge back.

Non-goals (v1): mainnet, decentralised attester set, light-client verification, UI.

## Maroo facts (from https://docs.maroo.io, verified 2026-09-30)
- Token is **OKRW/tOKRW**: KRW-pegged 1:1 AND native gas token. 18 decimals (`okrw` display, `aokrw` base). Testnet symbol tOKRW.
- Testnet: chain ID **450815** (mainnet 815), RPC `https://rpc-testnet.maroo.io`, WS `wss://ws-testnet.maroo.io`, explorer `https://explorer-testnet.maroo.io`, faucet `https://faucet.maroo.io`, indexer `/blockscout/api/v2`.
- Contracts (same testnet + mainnet): `IOkrw` precompile `0x1000000000000000000000000000000000000001` (`mint` + `getParams` only); ERC20 mirror `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`; **no burn in docs**.
- Mint rights: single consortium/gov `minter_address` — faucet funds the demo, we cannot mint.
- EVM-equivalent: Cosmos SDK + EVM hybrid (CometBFT, EIP-1559). Solidity `0.8.28`, Hardhat/Foundry/ethers/viem unpatched.
- Finality: CometBFT "instant, fork-free" (2/3+ votes). No numeric bridge-confirmation guidance — demo uses receipt + 1–2 blocks.
- No official bridge/messaging docs.

## Locked decisions
- Maroo stack: EVM-compatible (https://docs.maroo.io/en/guides/integration).
- Bridge model: **lock/mint**.
- Trust: **trusted relayer** (single off-chain watcher attests).
- Naming: **OKRW both chains**, **18 decimals both** (1:1, no conversion).
- Vault deposits: **native payable only** (no ERC20-mirror path in v1).
- Aptos mint authority: **relayer signer key holds MintRef directly** (simplest demo).
- Aptos controls: **standard regulated-FA pattern** (mint/burn/pause/denylist roles).
- Toolchain: **Foundry + TypeScript relayer + Aptos CLI**. **Fresh testnet-only keys** (to be generated).
- Demo scope: **full round-trip (lock→mint→burn→unlock) with small daily cap**.

## Architecture (v1)
- **Maroo `OkrwVault.sol`**: `deposit(bytes aptosRecipient)` payable, locks native OKRW; `release(to, amount, nonce)` only-relayer; events `DepositLocked(marooSender, aptosRecipient, amount, nonce)` / `Released(to, amount, nonce)`. Nonce + replay protection, daily cap.
- **Aptos `okrw` FA + `bridge`**: `MintRef`/`BurnRef`/`TransferRef` with separate admin/minter/pauser/blocklister; `bridge::mint(recipient, amount, nonce)` only-relayer-signer; `bridge::burn_withdraw(amount, marooRecipient)` burns + emits event for return path.
- **Relayer (TS)**: Maroo logs → wait receipt + 1–2 blocks → submit Aptos mint; Aptos burn events → submit Maroo release. Nonce tracking both sides.

## Repo layout (to scaffold)
- `contracts/maroo/` — Foundry: `OkrwVault.sol` + swap contracts (`SwapEscrow.sol`, `SwapAuction.sol`, `AptosLightClient.sol`), tests
- `contracts/aptos/` — Move: `okrw`, `bridge`, `aptos move test`
- `relayer/` — TS watcher + submitter, testnet config (Demo A, :3024)
- `swap/` — TS swap server (:3201) + solver daemon + quote/prover/audit libs (Demo B)
- `scripts/` — faucet, bridge-to-aptos, bridge-back, balances
- `research/` — Maroo digest, USDC reference notes, swap plan + deep-dives
- `AGENTS.md`, `README.md` (demo runbooks once working)

## Conventions
- Correctness over gas/UX. Smallest change that achieves the goal.
- `forge test` + `aptos move test` pass before any demo claim.
- Never commit secrets/keys. `.env` + testnet-only faucet accounts.
- Cite reference functions when choosing pause/denylist semantics.

## Aptos USDC parity checklist
- [ ] FA with `MintRef` / `BurnRef` / `TransferRef`
- [ ] Pauser halts transfers + bridge mint
- [ ] Denylist / freeze per-address
- [ ] Separate admin / minter / pauser / blocklister (multisig-friendly)
- [ ] Events for mint/burn/pause/block

## Demo definition of done
Demo A: Faucet tOKRW → lock on Maroo → OKRW on Aptos → burn → unlock on Maroo, with nonce/replay checks, pause + denylist unit-tested, runbook in README.
Demo B: quote → lock ETH → solver auction → finalize → win → Aptos fill → claim → settle, with idempotency, inventory guard, refund path, expiry-aware finalize unit-tested, runbook in README §7.

## Scaffold next (when approved)
1. `forge init contracts/maroo` + `OkrwVault.sol` + tests ✅ done
2. `aptos move init` + `okrw`/`bridge` modules + tests ✅ done
3. TS relayer skeleton + testnet config (fresh keys, `.env` gitignored) ✅ done
4. `scripts/` demo + `README.md` runbook ✅ done
5. Web demo: `relayer/src/server.ts` + `relayer/public/index.html` ✅ done (live, tested end-to-end 2026-09-30)
