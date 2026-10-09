# Bridge comparison: LayerZero vs Wormhole vs Chainlink CCIP vs Circle CCTP v2 vs NEAR Intents (vs our demo bridge)

Date: 2026-10-07. Sources: web docs (URLs inline) + local checkouts
`~/github/wormhole` and `~/github/chainlink`, plus the LayerZero
[awesome-layerzero](https://github.com/LayerZero-Labs/awesome-layerzero) index.
Marketing numbers ($68B, $85B+) are vendor-claimed; treat as directional.
Detail below: §0 baseline · §1–5 protocols · §6 table · §7 trailing
activity · §8 comparison · §9 CCTP deep-dive · glossary · sources.

## TL;DR

- **LayerZero v2** — generic messaging + OFT token standard; the app picks
  its verifier set (DVNs). ~150 chains, mature Aptos OFT, ~$0.01–1/message.
  Best for omnichain tokens and shared liquidity (Stargate).
- **Wormhole** — messaging (VAAs) + NTT framework + solver-based Settlement;
  19-guardian 13-of-19 quorum. 45+ chains, Aptos core live. Best for
  multichain-native issuance with a speed layer.
- **Chainlink CCIP** — messaging + CCT tokens, compliance-first (ACE/CRE);
  the only explicit fee schedule (4-part, LINK or native). 77 networks,
  Aptos at v1.6 (newest, lags EVM). Best for banks and RWA.
- **Circle CCTP v2** — issuer burn-mint for USDC/EURC only, no messaging;
  Standard lane free + gas. Aptos domain 9 live. Best USDC rail — but it
  cannot serve Maroo/OKRW, so it is a reference model here, not an option.
- **NEAR Intents** — outcome-based solver auctions, not message-passing;
  any asset, BTC + 35 chains incl. Aptos ("fully supported"). 1 pip protocol
  fee + 1Click spread; the only one with real trailing revenue
  (~$23m ARR). Best for swaps; cannot custody a lock/mint pair like ours.
- **Ours** — single-pair lock/mint demo, one-key trust, gas-only cost. Same
  core pattern as OFT-Adapter / NTT hub-and-spoke / CCT lock-mint, minus
  quorum verification, messaging, and N-chain scale.
- **Verdict:** keep the demo. Graduation paths: OFT-adapter (closest
  structural match) · NTT (speed) · CCIP (regulated counterparty). §7 has
  the trailing-30d receipts (Intents ~$4.4b DEX vol + ~$23m ARR leads on
  monetization; LZ ~$11.5b bridge volume leads on flow; LZ/Wormhole take
  zero protocol revenue). Biggest
  upgrade under any path: replace the one-key relayer with a quorum the
  bridge itself verifies.

## 0. Baseline: our demo bridge ("Move Bridge")

`contracts/maroo/src/OkrwVault.sol` (227 lines, 24 forge tests): payable
`deposit(bytes aptosRecipient)` locks native OKRW, emits
`DepositLocked(marooSender, aptosRecipient, amount, nonce)` with a monotonic
deposit nonce; `release(to, amount, releaseNonce)` is `onlyRelayer`, enforces
in-order nonces, a `keccak(to,amount,nonce)` replay guard, a daily release cap,
pause, two-step admin rotation, and `receive()` rejects direct transfers.
`contracts/aptos/sources/bridge.move` (240 lines, 17 move tests): `init` pins
the one OKRW metadata object the bridge may mint; `mint_attested` is
relayer-only with a `Seen` nonce table + daily mint cap; `burn_withdraw` is a
two-step return rail (user FAs to the bridge account, relayer burns and emits
`WithdrawInitiated`); `emergency_pause` freezes bridge + coin in one tx;
relayer rotation is two-step and *moves* the `Seen` table so nonces survive.
`okrw.move` is a USDC-grade managed FA (separate mint/burn/pause/denylist).
`relayer/src/`: `forward.ts` (Maroo log → Aptos mint), `back.ts` (Aptos burn →
Maroo release), `server.ts` (web UI + autorelay loop + idempotency ledger),
`monitor.ts` (escrow-vs-supply conservation check + alerting).
**Trust model: one key.** The relayer holds the Aptos `MintRef` and the Maroo
release key; a daily cap bounds compromise blast radius. No light client, no
attester set, testnet-only by design.

## 1. LayerZero v2 — generic messaging + OFT

**What it is.** A permissionless generic-messaging protocol: the same
primitive carries arbitrary bytes and token moves (value transfer = messaging
+ burn/lock → mint/unlock invariants). Apps build on standards:
- `OApp` — generic send/receive (`_lzSend`/`_lzReceive`, peers, enforced options).
- `OFT` — omnichain fungible token (unified supply; BurnMint preferred,
  LockUnlock/OFT-Adapter for existing tokens; `sharedDecimals` default 6).
- `ONFT`, `lzRead` (pull queries), Composers (`lzCompose`), `OVault`
  (ERC-4626 hub-spoke), `lzAsset` (managed pre-native OFTs like USDG0/PYUSD0).
- **Stargate** — the liquidity/bridge hub on top (pools + Hydra mint/burn,
  Taxi composable vs Bus batched). Stargate *pool contracts* are EVM-only;
  non-EVM chains route as OFT peers via the frontend.
- Docs claim **150+ chains** (EVM + Aptos, Solana, Sui, Movement, Starknet,
  TON, Tron…); dev tracks for Solidity, Rust/Anchor, Aptos-Move, Sui.
- **Verification:** v1 = oracle + relayer; **v2 = DVNs verify, Executors
  deliver** (permissionless execution — anyone can deliver a verified
  message). Per-channel **security stack**: `UlnConfig` with X-of-Y-of-N DVN
  sets; production guidance is ≥2 diverse-operator DVNs, pinned both sides.
  One Executor per pathway (default: LZ Labs) — a liveness concentration.

**Cost.** Sender pays on source in **native gas or ZRO**. Four components:
source tx + DVN fees (scale with count/type) + Executor fee + destination gas
(quoting converts dst gas to source token). Docs FAQ: typical OFT
**~$0.01–$1 per pathway**. Stargate adds LP/pool/app fees on top. No fixed
protocol percentage published.

**Top use cases.** (1) **Stargate** — the canonical LZ bridge hub
(`stargate.finance`). (2) **Omnichain stablecoins** — USDT0, PYUSD0/USD G0/AUSD0
via lzAsset/Hydra. (3) **WBTC0** — BitGo's omnichain WBTC. (4) **RWA/yield** —
Ondo, Usual, Pendle, Ozean; WYST bulletin cites 145M messages / $60B via
PayPal/BitGo/Ethena/Ondo. (5) **Governance/enterprise** — Aragon gasless
omnichain voting, IntellectEU DvP.

**Future.** V2 expansion (more chains/VMs), `lzAsset` managed issuance,
OVault, lzRead; the site pivots toward **Console** (enterprise control plane),
**Zero** (heterogeneous chain), **ATLAS** (headless exchange); Wyoming's WYST
stablecoin OFT is the flagship state-level pilot (testnets 2025, target July
2025 launch per the state bulletin).

**Aptos.** Live and first-class for messaging/OFT: mainnet Endpoint listed,
Move modules (`endpoint_v2`, `uln_302`, `oft_fa` burn/mint +
`oft_adapter_fa` lock/unlock escrow on Fungible Assets, `fee_bps`,
blocklist, rate limits). Our `okrw` FA + `bridge` split maps almost 1:1 onto
the OFT-adapter pattern.

## 2. Wormhole — VAAs + NTT + Settlement

**What it is.** A connective layer ("move assets, data, apps as if one");
claims **$68B all-time volume, 45+ chains**. Product suite: Messaging (generic
VAA passing), **NTT** (native-token-transfer framework — `NttManager`
locks/burns ↔ mints/unlocks, hub-and-spoke *or* burn-and-mint modes,
rate limits, Global Accountant; framework, not a wrapped token), WTT/Token
Bridge (legacy wrapped), Connect widget, **Settlement** (intent-based,
solver auctions), Queries, MultiGov. **Trust: 19 guardians, 13-of-19 VAA
multisig** (direct or delegated observation); permissionless executors relay.

**Local repo evidence** (`~/github/wormhole` — the `wormhole` monorepo,
reference implementation): `node/` (guardian node; `docs/guardian.md`
confirms bespoke watchers for Sui/Aptos/Algorand/Near alongside EVM/Solana/
Cosmwasm/IBC), `ethereum/contracts/` (core + token/nft bridges),
`aptos/` (full Move suite: `wormhole/` core, `token_bridge/` —
`attest_token`, `transfer_tokens`, `complete_transfer[_with_payload]`,
`vaa`, `wrapped` — plus `coin/`, `nft_bridge/`, `deployer/`, `examples/`),
`sdk/js/src/` (incl. `aptos/`, `token_bridge/`, `vaa/`), `docs/operations.md`
(NTT + accountant ops). Note: this checkout has **no top-level NTT module** —
NTT lives in the separate `wormhole-foundation/example-native-token-transfers`
repo; don't go looking for it in the monorepo.

**Cost.** No CCIP-style protocol fee table: cost = source/destination gas +
off-chain delivery; Settlement solvers front capital and take a cut. (The
Circle-CCTP fallback leg is explicitly "typically more expensive.")

**Top use cases.** (1) **Portal** — the multichain transfer/swap app (WTT
reference). (2) **BlackRock BUIDL + Securitize** — BUIDL expanded to BNB chain
via Wormhole (Nov 2025). (3) **Monad** — MON multichain via NTT; Monad native
bridge powered by Wormhole (Nov 2025). (4) **Pyth** — the canonical oracle-on-
Wormhole-messaging case. (5) **RLUSD multichain via NTT** (June 2026).

**Future.** Institutional/RWA positioning ("financial infrastructure for the
modern economy"); Settlement as the intent-based speed layer (Mayan Swift
~12s solver auctions + Mayan MCTP wrapping CCTP); NTT deploy tracks for
EVM/SVM/Sui/Hyperliquid.

**Aptos.** Yes at the core layer — the contract-address reference lists Aptos
mainnet + testnet (`0x5bc114…e19625`), and the local `aptos/` Move suite is
mature. Caveat: the NTT *supported-networks* table we fetched lists EVM/SVM/
Sui chains without Aptos in view — verify NTT-on-Aptos status before assuming
it; core messaging + token bridge on Aptos is the safe claim.

## 3. Chainlink CCIP — compliance-first messaging + CCT

**What it is.** The institution-facing messaging + token/data transfer stack.
Claims **$85B+ cross-chain token value, 80+ networks**; the on-chain
[directory](https://docs.chain.link/ccip/directory) shows **77 mainnet
networks / 281 tokens** (e.g. Ethereum 76 lanes/210 tokens, Solana 28/51).
Features: Programmable Token Transfers, arbitrary messaging, configurable
settlement speed (full finality vs Faster-Than-Finality), additive CCV
verification, ACE compliance hooks. Key standard is **CCT**: any registered
ERC-20 with per-chain Token + Token Pool + Token Admin Registry; burn-mint,
lock-mint/burn-unlock, or lock-unlock; **issuer retains ownership** with
per-lane rate limits. Verification is the DON/OCR + Risk Management Network
stack (now "CCIP 2.0" with additive CCV).

**Local repo evidence** (`~/github/chainlink` — EVM-first, non-EVM expanding):
`ccip/config/evm/` (~90 chain TOMLs — the lane inventory), `deployment/
ccip/` (changesets/sequences for rollout), `core/capabilities/ccip/` with
per-VM plugins **`ccipaptos` / `ccipevm` / `ccipsolana` / `ccipsui` /
`ccipton`** (address/codec/msghasher/gas helpers per chain family), and
`integration-tests/smoke/ccip/ccip_aptos_*_test.go` — EVM↔Aptos messaging,
FA transfers, even *regulated* token transfer tests. Aptos arrived as
**CCIP v1.6.0 (initial Aptos release)**: Aptos↔EVM messaging, FA transfers,
native APT fees — vs EVM's v2.0 surface. Non-EVM is real but a version behind.

**Cost.** The only one of the four with an explicit fee schedule: **four
parts paid in LINK or native/wrapped fee token** — Executor (destination gas
+ optional flat) + CCV + Token Pool (flat USD or bps) + CCIP Network
(protocol). Example protocol slice: Eth→non-Eth/Solana $0.45 in LINK / $0.50
otherwise; non-Eth→Eth $1.35/$1.50. Unused gas is **not** refunded. This is
the premium-priced, compliance-grade option by construction.

**Top use cases.** (1) **Swift** (+ DTCC/Euroclear Sibos-2025 story) — bank-
rail trials. (2) **ANZ** (+ ADDX, SBI Digital Markets, Project Guardian) —
tokenized-asset settlement. (3) **Aave GHO** — multichain native stablecoin.
(4) **Lido wstETH Direct Staking** via Programmable Token Transfers. (5)
**J.P. Morgan Kinexys + Ondo** cross-chain DvP via the CRE layer.

**Future.** CCIP 2.0 (additive CCV, built-in compliance, configurable speeds),
CCT self-serve SDK/CLI + AdvancedPoolHooks/ACE policies, and above it the
**Chainlink Runtime Environment (CRE)** — orchestration across chains, APIs,
and payment rails (the Swift/Kinexys DvP story is a CRE story).

**Aptos.** Yes, newest of the three: v1.6.0 Aptos↔EVM messaging + FA
transfers, Move reference docs, native APT fees. Directionally full support;
maturity lags EVM.

## 4. Circle CCTP v2 — issuer burn-mint for USDC

**What it is.** The odd one out — and the most relevant to a stablecoin
bridge. CCTP is **not a generic bridge**: it is Circle's permissionless
onchain utility for moving *its own* USDC (plus EURC / third-party assets via
the CCTP-for-non-USDC extension) by **issuer burn-and-mint**: burn on source
(`TokenMessengerV2.depositForBurn`), Circle's offchain **Iris attestation
service** signs after finality, mint on destination
(`MessageTransmitterV2.receiveMessage`). No liquidity pools, no wrapped IOUs,
unified supply — trust is *Circle's attestation*, not a quorum you configure.
Two speeds: **Standard** (`minFinalityThreshold` 2000 — hard finality;
~15–19 min on ETH/L2s) vs **Fast** (1000 — soft finality, ~8–20 s, subject to
a global allowance). **Hooks** (`depositForBurnWithHook` /
`CrossChainTokenService`) execute a destination call atomically in the same
tx as the mint (revert = whole delivery reverts; self-relay only — Iris does
not relay). Optional **forwarding service** has Circle broadcast the
destination mint, and an **upfront-fee quote** lets the payer cover Fast/
forwarding fees in native gas or USDC on source so the recipient gets the
full amount. ~30 domains in the v2 table (Ethereum, Avalanche, OP, Arbitrum,
Solana, Base, Polygon, Unichain, Linea, Sonic, World, Monad, Sei, HyperEVM,
Plume, Starknet, Arc, Stellar, Injective, …); non-EVM beyond Solana includes
Aptos, Sui, Starknet, Stellar, Injective. **V1 phases out Oct 31–Dec 1,
2026** (breaking contract/ABI/API change).

**Cost.** Cheapest of the four for its lane: **Standard is 0 bps (free) +
gas only**; **Fast is 0–13 bps deducted at mint** (e.g. ETH 1.0, Solana 1.0,
Base 1.3, Linea 13, Starknet 12 bps; `maxFee` reverts if under-quoted —
query `GET /v2/burn/USDC/fees`, never hardcode). Forwarding = dynamic
destination-gas fee. No onchain fee for Standard/message/hooks/wrapping.

**Top use cases.** (1) **Hyperliquid HyperEVM/HyperCore** — official
CCTP-to-HyperCore path (`CoreDepositWallet` + `CctpForwarder` hooks,
Arbitrum-sponsored extension). (2) **Binance** — $100M investment + 5-yr
commercial pact (strategic; not a proven CCTP route). (3) **Eco on Gateway**
— adjacent unified-balance product, not CCTP proper. Notably: Wormhole's
Mayan MCTP fallback leg *is* CCTP under the hood (per Wormhole docs, "more
expensive due to protocol fees") — CCTP is infrastructure the others build
on, not just a competitor.

**Future.** 2026 releases: Aptos V2 Standard (Aug 2026), Plasma, **Arc
mainnet** (Circle's own L1 — USDC gas, sub-second finality, CCTP/Gateway/App
Kits as the bridge story), CCTP-for-non-USDC launch (EURC/cirBTC/WETH),
Sui V2. Direction: CCTP as the settlement rail for Circle's chain, not just
a bridging utility.

**Aptos.** Yes — **domain 9, live on V2 Standard** (Aug 2026): Move packages
`TokenMessengerMinterV2`/`MessageTransmitterV2` on mainnet + testnet,
~0.5 s / 1-conf Standard, Aptos↔Arc quickstart published. Caveats: Fast,
upfront-fee, and forwarding support are N/A on Aptos per the domains table.

**Structural contrast.** CCTP inverts the other three models (see §8 for the
full pros/cons): OFT/NTT/CCT are *frameworks* where the token developer deploys the standard and picks
the verification (DVNs / guardians / DONs); CCTP is *issuer-operated* —
Circle attests its own burn/mint and there is nothing to configure. That is
why it only moves Circle-family assets, and why it is simultaneously the
cheapest, the most centralized, and the only one with zero smart-contract
verification risk on the attestation path (the risk is Circle/Iris liveness
and correctness, not a quorum you misconfigure).

## 5. NEAR Intents — solver-filled outcomes, not messages

**What it is.** The fifth model — and the only one that isn't message-passing
*or* issuer burn-mint. The user declares a desired **outcome** ("1 ETH on
Ethereum → USDC on Arbitrum"); market makers/solvers compete on price/speed
and the best quote settles atomically on NEAR's **Verifier** contract
(`intents.near`, formerly "Defuse", open-source `github.com/near/intents`)
— or the user is refunded. Components: the **1Click Swap API** (REST layer:
solver quotes, execution, retries/refunds, non-custodial), an optional
**Message Bus** (WebSocket quote relay; solvers can also index NEAR
directly), and **settlement bridges** the withdrawal leg routes through —
Omni Bridge (Ethereum, Base, Arbitrum, BNB, Solana, Bitcoin), POA Bridge
(widest set), HOT Bridge (TON, Stellar, Scroll, Monad…). Chain coverage is
the widest here for *non-EVM*: EVM majors plus BTC and forks (Doge, Zcash,
BCH, Litecoin, Dash), Solana, TON, Stellar, Tron, Sui, XRP, Starknet, Cardano
— ~35 chains per the homepage's $33B+ all-time claim. Trust = solver market
+ Verifier atomicity + the settlement bridge of the withdrawal leg (Omni
itself uses NEAR light clients inbound, Wormhole for Solana/L2s, MPC
signatures outbound — i.e. the message-passing models *inside* the intent
model's settlement layer).

**Cost.** The only published two-sided schedule in the set: protocol fee
**0.0001% (1 pip)** per tx to `fee_collector`; `near-intents.org` frontend
+0.2%; 1Click API +25 bps keyless / 20 bps with key (1 bp for stable/same-
asset pairs), 50/50 app-fee splits, 500 bps cap; quote-improvement surplus
split 50/50. Plus gas + solver spread — the auction, not a quote table,
sets the price.

**Top use cases.** (1) **SwapKit** — dominant affiliate (9,049 tx / $17.16M
in one 24h window on the official explorer). (2) **Rango + LI.FI + THORSwap**
— the aggregator-of-aggregators distribution (1.2k/979/114 tx respectively
same window). (3) **Frax Finance + Bitte (AI execution) + Delta Trade** —
homepage ecosystem. (4) **Sailor Send** — BTC-collateral loans (the
Bitcoin-leg showcase). (5) **Confidential Intents B2B** (Jul 2026) — private
chain, shielded balances, allowlisted solvers.

**Future.** Changelog velocity is the highest in the set (Jun–Sep 2026):
Robinhood Chain support, **1Click Limit Orders**, verifiable quote
signatures, SHIELD incident API, Confidential Intents; Omni roadmap adds
cross-chain contract calls and new token standards. No Omni sunset found —
it sits alongside POA/HOT.

**Aptos.** Yes — **"fully supported"** on the 1Click chain-support page
(0x64-hex address format) and in the POA Bridge set; DeFiLlama corroborates
an Aptos chain entry. Sui likewise.

**Caveat (do not skip).** DeFiLlama logs **one hack: Oct 1, 2026, $3.8M, BSC
bridge-logic flaw**, classification "Bridge & Cross-Chain." The intent layer
settled correctly; the *settlement bridge* didn't — which is exactly the
residual-trust point above. Track remediation before citing Intents as the
safe option.

## 6. Head-to-head

| Dimension | LayerZero v2 | Wormhole | Chainlink CCIP | Circle CCTP v2 | NEAR Intents | Our demo bridge |
|---|---|---|---|---|---|---|
| Primitive | Generic messaging; tokens via OFT | Messaging (VAAs) + NTT framework + Settlement intents | Messaging + CCT tokens + CRE orchestration | Issuer burn-mint (USDC/EURC); Hooks, no messaging | Solver-filled outcome declarations; 1Click API | Lock/mint + burn/unlock, one pair |
| Trust model | App-chosen DVN set (X-of-Y-of-N); 1 executor/path | 19 guardians, 13-of-19 VAA quorum | DON/OCR + Risk Mgmt Network; CCV in 2.0 | Circle Iris attestation (issuer-operated) | Solver market + Verifier atomicity + settlement bridge | 1 trusted relayer key |
| Chains | ~150 claimed | 45+ claimed | 77 mainnet (directory) | ~30 domains | ~35 (EVM + BTC/forks + L1s) | 2 (Maroo ↔ Aptos) |
| Aptos status | Live OFT/Move, mature | Core + token bridge live; NTT TBD | v1.6.0, newest, lags EVM | Domain 9, V2 Standard live (Aug 2026) | Fully supported (1Click + POA) | Native (both endpoints) |
| Token standard | OFT (unified supply) / adapter | NTT (lock/burn ↔ mint/unlock) | CCT (issuer-owned pools) | Native USDC/EURC; CCTPx for 3P assets | Any asset solvers quote (incl. BTC) | Bespoke FA + vault |
| Fee model | Per-pathway quote (DVN+executor+gas), ~$0.01–1 | Gas + delivery; no protocol table | 4-part, LINK/native, published schedule | Standard free+gas; Fast 0–13 bps | 1 pip protocol + 1Click bps/auction spread | Gas only |
| Compliance rails | Per-app (`fee_bps`, blocklist) | Rate limits, accountant | First-class (ACE, CCT rate limits, regulated-token tests) | Circle-level (denylist, rate limits, CTS) | Confidential Intents (B2B); allowlisted solvers | Pause + denylist + caps |
| Typical latency | ~1–3 min EVM lanes (confirmations + DVN verifies + executor) | Minutes (source finality + 13-of-19 VAA + relay); Settlement ~12s solver-fronted | Full finality: source-bound (ETH ~12.8 min, L2s 17–20 min); FTF opt-in ~24s (ETH→ARB) | Standard 15–19 min; Fast ~8–20s | Tens of seconds–few min (deposit + auction + Verifier); allow up to 15 min | ~1–2 Maroo blocks + poll cadence (15s manual, 60s autorelay) + Aptos confirm |
| Maroo fit | Custom EVM endpoint + peer registration needed | Same (custom EVM endpoint) | Same (custom EVM endpoint) | Cannot serve Maroo (no Circle domain) | No Maroo route (not in chain set) | Native (built for it) |
| Best fit | Omnichain tokens, Stargate liquidity | Multichain-native assets, speed via Settlement | Institutional/RWA, bank rails | USDC movement, Circle ecosystem | Swaps incl. BTC, aggregator distribution | Demo / learning |

## 7. Trailing activity: volume, transactions, fees (30d to ~Oct 6, 2026)

Onchain-indexed trailing windows, fetched Oct 7, 2026. Primary source is
DeFiLlama (protocol pages + `api.llama.fi` fee API, figures verified by
direct fetch); its windows are 24h / 7d / 30d / 1y / cumulative — **no
trailing-90d is published**, and 90d quarters below are the closest proxy.
"Fees" = what users paid (mostly to operators); "revenue" = protocol take.
Transaction counts are the gap: neither LayerZeroScan (HTTP 429) nor
WormholeScan `/analytics` (403), CCIP Explorer, nor CCTPscan yielded an
aggregated 30d/90d tx count to an unauthenticated fetch. Dune / Token
Terminal / Artemis need login or API keys — the advised next step if tx
counts matter.

| Trailing-30d (to ~Oct 6) | LayerZero (V1+V2) | Wormhole (as "Portal") | Stargate (on LZ; memo) | CCIP | CCTP | NEAR Intents |
|---|---|---|---|---|---|---|
| Bridge volume | **$11.457b** | **$1.365b** | $992.06m | n/a (no bridge-volume row) | n/a (no DeFiLlama entry) | $4.415b DEX vol[^1] |
| Fees (users paid) | **$292,357** | **$17,924** | $244,302 | n/a | n/a | **$7.38m**[^2] |
| Protocol revenue | **$0** (0% take; fees → DVNs/executors) | **$0** ("makes no revenue") | $244,302 (= fees) | n/a | n/a (Standard free; Fast bps undisclosed) | **$1.93m** |
| ARR (30d rev × 12) | **$0** | **$0** | **~$2.93m** | n/a | n/a | **~$23.1m** |
| Transactions | n/a | n/a | 5,711 *24h only* | n/a | n/a | n/a (explorer has 24h referral mix, no 30d agg) |

ARR = trailing-30d *protocol revenue* annualized — i.e. what the protocol
itself (not its operators) keeps. LZ and Wormhole read $0 by design: ~100%
of messaging fees flow to DVNs/executors (LZ) and relayers/executors
(Wormhole). Monetization sits one level up — Stargate's ~$2.93m ARR is the
app-layer spread on top of LZ's $0-protocol-take transport. (Sanity check:
Portal's annualized fees ≈ $17,924 × 12 ≈ $215k matches DeFiLlama's own
~$214.6k figure; Stargate 1y revenue $1.24m trails its 30d pace, so treat
the $2.93m as a current-run-rate read, not a realized year.)

Context beyond 30d. **LayerZero:** 7d volume $5.572b / fees $64,783; 1y fees
$2.18m; cumulative volume $168.952b, cumulative fees $76.11m; Q3-2026 fees
$564.1K vs Q2 $538.31K (quarterly income table — the only ~90d proxy).
**Wormhole:** 7d volume $248.76m / fees $3,807; 1y fees $415,208; cumulative
volume $35.642b, cumulative fees $983,824; vendor claim $68B all-time volume
(wormhole.com — cumulative, not trailing). **CCIP:** no trailing volume/fees
retrieved (DeFiLlama fee pages 404; Token Terminal JS-gated); what exists is
TVL **$1.89b (+6.4% over 30d**, #8 bridge protocol, 77.9% Ethereum) and the
directory (77 networks / 281 tokens), plus the vendor $85B+ cumulative
cross-chain token value claim. **CCTP:** nothing trailing retrieved (no
DeFiLlama entry, CCTPscan JS-only, Circle transparency covers USDC-wide
mint/burn, Q2-2026 earnings PDFs JS-gated). Nearest proxy — **Circle
Gateway is a different product**, do not cite as CCTP: 30d volume $949.06m,
fees $47,250, TVL $80.6m. **NEAR Intents** (all verified by direct API
fetch): DEX volume 30d **$4.415b** (7d $680.5m, 24h $117.2m, cumulative
$32.345b)[^1]; fees 30d **$7.38m** (1y $50.8m, cumulative $52.73m)[^2]; revenue
30d **$1.93m** (1y $7.51m — revenue history starts Feb 2026, buyback to
holders since 2026-02-23); TVL $221.73M (+61.8% 30d); explorer claims
$33B+/all-time across 35 chains, 30d $3.26b. **Ours:** testnet demo — no
mainnet volume by design; the comparable "activity" metric is relayer
attestations in `relayer/data/`.

[^1]: DeFiLlama tracks Intents as a DEX (swap) protocol, not a bridge — its
"$4.415b volume" is solver-filled swap flow, not bridge escrow flow. Do not
compare naively with LZ/Wormhole *bridge* volume; compare fees/revenue.
[^2]: Intents "fees" = protocol pip + affiliate (frontend) fees summed across
integrators; "revenue" = NEAR/wNEAR swept to revenue wallets. Highest
monetization in the set *because* the auction + affiliate stack captures
spread the $0-take transports give away.

Reading it. (1) Volume concentrates ~8:1 in LayerZero's favor over Wormhole
on the 30d window — but LZ's figure bundles every OFT/Stargate-adjacent
message while Portal tracks the token bridge only, so treat as directional.
Intents' $4.4b is swap flow, not bridge flow (footnote [^1]) — its real story
is monetization, not throughput.
(2) Both message-passing protocols take **zero revenue** (ARR $0 both):
fees flow to DVNs/executors (LZ) and relayers/executors (Wormhole). The
only monetized rails in the set are the layers that capture spread:
Stargate's ~$2.93m ARR on LZ transport, and Intents' **~$23.1m ARR** —
8× Stargate's — from the pip + affiliate + auction-surplus stack. The
takeaway inverts the fee-model ranking in §1–5: the "cheapest" transports
(LZ/Wormhole $0-take) monetize nothing; the auction model monetizes most.
(3) CCIP/CCTP opacity cuts opposite ways: CCIP's value is locked TVL
($1.89b) more than flow, and Circle discloses nothing per-route — a
reminder that fee-schedule transparency (§3) is not usage transparency.
(4) Missing tx counts mean no per-tx fee math is possible from public
sources today; volume-per-dollar-of-fee is the usable efficiency ratio
(~$39k volume per $1 fee on LZ, ~$76k on Wormhole — i.e. both round to
"users pay gas plus dust").

## 8. How each compares to what we built

**Functionality.** Our `DepositLocked → mint_attested / burn → release` loop
is the same lock/mint core as OFT-Adapter (lock/unlock escrow), NTT
hub-and-spoke, and CCT lock-mint — generalized in §1–3 to N chains plus
arbitrary messaging, with configurability we lack (per-lane rate limits
beyond one daily cap, X-of-Y attestation, messaging payload beyond the
recipient). CCTP (§4) is the mirror image: *also* single-asset like us
(USDC, not any token), but with issuer burn-mint instead of our lock-mint,
and Circle's attestation instead of our one key. NEAR Intents (§5) is the
third pole: neither lock/mint nor burn/mint as the user experiences it —
the solver fills the outcome from inventory and the Verifier enforces
atomicity. Ours is a *custody* bridge (escrow on Maroo, mint on Aptos);
Intents is a *liquidity* protocol (no per-pair escrow, solvers hold the
inventory). Our two-step
`propose/claim` relayer rotation and `Seen`-table replay guard
are the demo analogues of their validator-set management and nonce tracking.

**Cost.** Ours is cheapest in absolute terms (two gas payments, no protocol
fee) because there is no verification network to pay. That comparison is
misleading: the fee in the quorum-based systems *is the decentralization* —
DVNs, guardians, DONs. Per-message, LayerZero (~$0.01–1) and Wormhole (gas +
delivery) undercut CCIP's scheduled fees; CCIP charges for compliance and
finality optionality. CCTP breaks the ranking: Standard is free + gas because
there is no quorum to pay — the issuer subsidizes attestation as USDC
infrastructure (full trade-off analysis in §9).

**Use cases.** Ours has exactly one: demo stablecoin round-trip. Their top
use cases cluster where a single-key bridge cannot go: shared-liquidity hubs
(Stargate, Portal), issuer-owned multichain tokens (USDT0, GHO, BUIDL),
bank/RWA settlement (Swift, ANZ, Kinexys/Ondo), oracle/data relay (Pyth) —
and CCTP's niche, canonical-USDC movement with no liquidity fragmentation
(Hyperliquid, Arc). Our pause/denylist/cap controls are the embryo of the
compliance story that is CCIP's whole pitch — and of Circle-level controls
(denylist, rate limits) that CCTP ships by default.

**What adopting one would mean for Maroo↔Aptos.** Maroo is EVM-equivalent
(chain ID 450815), so the three message-passing frameworks can speak to it
as a custom EVM endpoint — none lists Maroo out of the box, so each needs a
custom deployment + lane/peer registration. CCTP cannot serve Maroo at all
(Circle must add the domain; only Circle-family assets move). Intents can't
either (Maroo is not in its chain set — and even if listed, Intents fills
swaps from solver inventory; it cannot custody a dedicated lock/mint pair
with a pinned FA metadata object like ours). On the Aptos side all five
have Move support (LZ most mature, Wormhole core live, CCIP newest, CCTP V2
Standard live since Aug 2026, Intents "fully supported" via 1Click + POA).
Concretely: our `okrw` FA maps onto
an OFT-adapter / NTT manager / CCT pool with minimal logic change — the
`bridge.move` attestation logic is *exactly* the piece each protocol replaces
(DVN quorum / VAA quorum / DON commit). The vault's escrow accounting and the
conservation monitor stay either way.

**Recommendation (opinion).** Keep the demo as-is — replacing a 227-line
vault + 240-line bridge with a protocol integration teaches less and costs
more. If this ever graduates past demo: LayerZero's OFT-adapter is the
closest structural match to what we built (and its Aptos OFT modules mirror
our `okrw`/`bridge` split); Wormhole NTT if the priority is multichain-native
issuance with solver speed; CCIP if the counterparty is a bank or regulator;
CCTP if the asset were USDC instead of OKRW — it isn't, so CCTP is a
reference model (issuer burn-mint, free Standard lane) rather than an option.
The single biggest security upgrade under any option is the same: retire the
one-key relayer for a quorum the bridge itself verifies.

## 9. CCTP v2 pros and cons (detail)

CCTP is a different species — **issuer burn-mint for Circle assets**, not a
generic bridge framework — so the trade-offs below are structural, not just
matters of degree.

### CCTP v2 vs LayerZero / Wormhole / CCIP

**Pros.**

- **No fragmentation, no wrapped IOUs.** Burn on source → Iris attests →
  mint canonical USDC on dest; unified supply. No pool-depeg or `wrapped`
  asset risk (cf. Wormhole WTT legacy).
- **Cheapest lane.** Standard is 0 bps + gas; Fast is 0–13 bps. No
  DVN/guardian/DON quorum to pay, unlike the LZ per-pathway quote (~$0.01–1),
  Wormhole gas + delivery + solver cut, or CCIP's 4-part scheduled fee.
- **Nothing to misconfigure.** No DVN set, guardian set, or lane config —
  OFT/NTT/CCT security is only as good as your `UlnConfig` / transceiver
  thresholds / rate limits. CCTP has no knobs to get wrong.
- **Hooks.** `depositForBurnWithHook` gives atomic mint + execute on dest in
  one tx (the Hyperliquid HyperCore path).
- **Aptos live.** Domain 9 on V2 Standard with Move packages
  (`TokenMessengerMinterV2` / `MessageTransmitterV2`) on mainnet + testnet.

**Cons.**

- **One issuer's asset only.** USDC + EURC + authorized 3P via CCTPx. The
  other three move *any* token — and CCTP carries value + hook call only, no
  generic messaging (no OApp / VAA / CCIP-messaging equivalent for votes,
  oracle data, arbitrary payloads).
- **Centralized trust.** Iris attestation = Circle liveness + correctness +
  denylist. One operator vs 19 guardians (13-of-19), app-chosen DVN quorum,
  DON + Risk Network. If Iris halts, *all* routes halt — correlated failure.
- **Permissioned chains.** Circle must add the domain. The other three can
  onboard Maroo as a custom EVM endpoint; CCTP never can unless Circle ships
  it.
- **Rigid speed/cost trade-off.** Standard = hard finality but slow (ETH/L2s
  ~15–19 min, Linea 6–32 h, Starknet 2–4 h); Fast = ~8–20 s soft finality but
  bps fee + global allowance caps. No executor market (LZ) or solver auction
  (Wormhole Settlement) to tune it.
- **Aptos gaps.** Per the domains table, Fast / upfront-fee / forwarding are
  N/A on Aptos; Hooks require self-relay (Iris does not relay).
- **CCTPx is EVM-only** (Solana explicitly unsupported); V1→V2 migration is a
  breaking change on a deadline (phase-out Oct 31–Dec 1, 2026).

### CCTP v2 vs our Maroo↔Aptos demo bridge

**Where CCTP wins.**

- **No escrow to drain.** Our biggest risk is vault escrow ≠ supply (the
  reason `monitor.ts` exists). Burn-mint has no escrow and no conservation
  invariant to watch.
- **No one-key catastrophe.** Our relayer compromise = arbitrary mint +
  unlock up to the daily cap. CCTP's compromise surface is Circle/Iris, not
  a testnet key in `.env`.
- **Free Standard lane** vs our gas-only — same cost class, but with real
  attestation instead of self-attestation.

**Where ours wins (for this project).**

- **Works on Maroo.** CCTP can't — Maroo isn't a Circle domain and OKRW
  isn't a Circle asset. Ours was built for exactly this pair.
- **Sovereign.** We own admin/relayer rotation, pause, denylist, caps. CCTP
  cedes all of that to Circle.
- **Generalizable pattern.** Our lock/mint core maps 1:1 onto OFT-Adapter /
  NTT hub-and-spoke / CCT lock-mint. CCTP teaches nothing transferable to
  non-USDC bridging.

**Bottom line.** CCTP is the best *USDC rail* and infrastructure the others
reuse (Wormhole Mayan MCTP wraps it) — not a competitor to our bridge but
the reference model for issuer burn-mint when you *are* the issuer. If OKRW
were USDC, you'd delete our vault and use CCTP. Since it isn't, keep the
demo; if it graduates, steal CCTP's insight (burn-mint > lock-mint when you
control issuance) via LZ OFT burn-mint or Wormhole NTT burn-mint mode.

## Glossary (alphabet soup, defined once)

- **ACE** — Advanced Compliance Engine: Chainlink's policy layer for CCT
  (jurisdiction / KYC / limit hooks).
- **CCIP / CCT** — Chainlink's messaging protocol / its Cross-Chain Token
  standard (issuer-owned pools). Not to be confused with:
- **CCTP / CCTPx** — Circle's issuer burn-mint for USDC/EURC (no messaging)
  / its extension to third-party (non-Circle) assets.
- **CCV** — Cross-Chain Verification: CCIP 2.0's additive verification layer.
- **CRE** — Chainlink Runtime Environment: orchestration across chains, APIs,
  payment rails (the Swift/Kinexys DvP story).
- **DON / OCR** — Decentralized Oracle Network / Off-Chain Reporting: the
  Chainlink node quorum + aggregation protocol behind CCIP commits.
- **DVN** — Decentralized Verifier Network: a LayerZero v2 attester the app
  picks per channel (X-of-Y-of-N sets).
- **Hooks** — CCTP feature: a destination call executed atomically with the
  mint (`depositForBurnWithHook`).
- **Iris** — Circle's offchain attestation service that signs CCTP
  burn events after finality.
- **Intents (NEAR)** — outcome declarations filled by competing solvers off
  chain, settled atomically on the `intents.near` Verifier; 1Click is the
  REST distribution layer, the Message Bus the quote relay.
- **NTT** — Native Token Transfers: Wormhole's lock/burn ↔ mint/unlock
  framework (hub-and-spoke *or* burn-and-mint modes).
- **OApp / OFT / ONFT** — LayerZero app standards: generic messaging /
  omnichain fungible token / omnichain NFT.
- **VAA** — Verifiable Action Approval: a guardian-quorum-signed Wormhole
  message payload.
- **WTT** — Wrapped Token Transfer: Wormhole's legacy lock + wrapped-IOU
  bridge (superseded by NTT for new deployments).

## Sources

- LayerZero: `docs.layerzero.network/v2` (protocol architecture, OApp/OFT/
  pricing/DVN config), `layerzero.network` + blog, `stargate.finance`,
  Wyoming WYST bulletin (`content.govdelivery.com/accounts/WYGOV/bulletins/
  3d8d97a`), `github.com/LayerZero-Labs/awesome-layerzero` + `LayerZero-v2`
  (`packages/layerzero-v2/aptos/contracts`).
- Wormhole: `wormhole.com` + `/blog` + `/case-studies`, docs (`/products/
  messaging`, `/products/token-transfers/*`, `/products/settlement`,
  `/protocol/infrastructure/guardians`, `/reference/contract-addresses`),
  local `~/github/wormhole` (`node/`, `ethereum/contracts/`, `aptos/`,
  `sdk/js/src/`, `docs/`).
- Chainlink: `chain.link/cross-chain`, `chain.link/chainlink-runtime-
  environment`, `docs.chain.link/ccip` (concepts, fees-and-billing, CCT
  overview, directory, Aptos v1.6.0 reference), local `~/github/chainlink`
  (`ccip/config/evm/`, `deployment/ccip/`, `core/capabilities/ccip/`,
  `integration-tests/smoke/ccip/ccip_aptos_*`).
- Circle CCTP v2: `developers.circle.com/cctp*` (overview, technical guide,
  finality, fees, supported-chains-and-domains, forwarding, upfront-fees,
  Hooks, expanded-assets, HyperCore, Aptos packages, 2026 release notes,
  V1→V2 migration), `circle.com/cross-chain-transfer-protocol` + pressroom,
  `docs.arc.io/llms.txt`.
- NEAR Intents: `docs.near-intents.org` (what-are-intents, verifier,
  market-makers, 1Click API, fee-config, chain-support, bridging,
  changelog), `docs.near.org/chain-abstraction` (intents overview,
  omnibridge), `intents.near.org` + `explorer.near-intents.org`,
  `defillama.com/protocol/near-intents` + `api.llama.fi/summary/fees/ +
  dexs/near-intents` (figures verified by direct fetch).
- Trailing activity (§6, fetched Oct 7, 2026): `defillama.com/protocol/
  layerzero`, `/protocol/portal` (Wormhole redirect), `/protocol/ccip`,
  `api.llama.fi/summary/fees/{layerzero,portal}`, `api.wormholescan.io/api/
  v1/operations` (liveness only), `wormhole.com`, `chain.link/cross-chain`.
  DeFiLlama publishes 24h/7d/30d/1y/cumulative only — no trailing-90d;
  LayerZeroScan (429), WormholeScan `/analytics` (403), Dune / Token
  Terminal / Artemis (login-walled) yielded no tx counts.
