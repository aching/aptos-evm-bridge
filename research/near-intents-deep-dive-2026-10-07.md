# NEAR Intents — deep dive (companion to bridge-comparison-2026-10-07.md)

Date: 2026-10-07. All trailing figures verified by direct fetch of
`api.llama.fi`, `revenue.near.org`, and `explorer.near-intents.org` on Oct 7.
Windows are trailing-30d to ~Oct 6 unless noted. Marketing claims flagged.

## TL;DR

- **What:** outcome-based solver protocol, not message-passing. Users declare
  swaps; solvers compete; the `intents.near` Verifier settles atomically or
  refunds. 1Click API distributes; Omni/POA/HOT bridges settle withdrawals.
- **Scale:** 30d swap volume **$4.41b**, all-time ~$31–33b, ~35 chains.
- **Money:** 30d gross fees **$7.38m**, net revenue **$1.93m**, ARR
  **~$23.1m** — the highest monetization in our five-protocol set, 8×
  Stargate's. Since Feb 23, 2026, net revenue buys back $NEAR on the open
  market (hold, not burn — burn claim conflicts, see §5).
- **Mix:** top swaps are stables (USDC/USDT), BTC, wNEAR, ETH. SwapKit family
  drives ~18%+ of daily flow. Frontend fees are the largest net-revenue
  stream on the 30d view (15.5% capture); B2B 9.4%, quote-improvement 3.6%.
- **Risk:** Oct 1, 2026 **$3.8M BSC bridge-logic hack** — settlement layer,
  not intent layer. Aptos "fully supported." Maroo not in chain set.

## 1. What it is (architecture in five layers)

1. **NEAR L1 settlement.** One Rust/WASM contract, the Verifier
   (`intents.near`, formerly "Defuse", open-source `github.com/near/intents`)
   holds the internal asset ledger: deposits credited, solver fills updating
   balances, withdrawals exiting. Intents inherits NEAR consensus/finality.
2. **Chain Signatures (MPC).** NEAR validators threshold-sign for foreign
   chains (ECDSA for EVM/BTC-style, EdDSA for Solana/TON/Stellar-style), so a
   NEAR account controls addresses elsewhere. Outbound withdrawals depend on
   MPC liveness.
3. **Solver network (off-chain).** Market makers hear requests via the
   **Message Bus** (WebSocket quote relay) or by indexing NEAR RPC directly,
   compete on price/speed, fill from their own inventory, submit signed fills.
   Ordinary bot infra — pricing, inventory, indexers — not a chain.
4. **Settlement bridges.** The intent layer only swaps ledger balances;
   assets cross via Omni Bridge (Ethereum, Base, Arbitrum, BNB, Solana,
   Bitcoin), POA Bridge (widest set — incl. Aptos, Sui), or HOT Bridge (TON,
   Stellar, Scroll, Monad…). Omni's internals recurse into message-passing:
   NEAR light clients inbound for BTC/ETH, **Wormhole** for Solana/L2s, MPC
   outbound. Intents commoditizes its competitors' rails.
5. **Distribution + tracking (hosted).** 1Click API
   (`1click.chaindefuser.com`), affiliate frontends (SwapKit, Rango, LI.FI),
   `explorer.near-intents.org`, `revenue.near.org` — services, not protocol.

Trust = solver market (liveness/competition) + Verifier atomicity (filled or
refunded) + *whichever bridge your withdrawal uses* + MPC + NEAR L1.

## 2. Scale: volume and chains

| Window | Swap volume | Source |
|---|---|---|
| 24h | $117.2m (Llama) / ~$94m (explorer) | api.llama.fi, explorer |
| 7d | $680.5m (Llama) / $627.8m (explorer) | same |
| 30d | **$4.415b** (Llama) / $3.264b (explorer) | same |
| All-time | $32.345b (Llama) / $30.925b (explorer) / $33B+ claimed | same + intents.near.org |

The Llama/explorer gap (~35% on 30d) is methodology/window, not error — use
Llama for cross-protocol comparison, explorer for mix. ~35 chains per the
homepage; DeFiLlama tracks 26 with TVL. Chain TVL (custody footprint, the
only per-chain split published): NEAR $138.7M (62%), Ethereum $47.9M,
Bitcoin $7.1M, Tron $7.0M, BSC $5.7M, Arbitrum $5.3M, Base $2.8M, then
TON/Polygon/XRP/Doge tails. Solana only $83K, Aptos $52 — TVL ≠ flow; both
are supported for swaps despite near-zero parked TVL. TVL total $221.7M,
**+61.8% over 30d**.

## 3. Token mix: what actually moves

No published aggregate token-share table — exact percentages **not found**.
Best evidence is the explorer's 24h Top Swaps (Oct 7 snapshot):

- 931K USDC (~$932K), 435K USDC (~$435K), 415K USDT (~$416K) — stables ~$1.78M
- 11.05 BTC (~$926K), 5.16 BTC (~$433K), 5.027 BTC (~$421K), 5 BTC (~$417K)
  — BTC ~$2.2M across four prints
- 135K wNEAR (~$700K) ×2 — wNEAR ~$1.4M
- 164 ETH (~$428K)

Top-10 ≈ stables + BTC + wNEAR + ETH. Directional read: majors, stables,
BTC, and NEAR itself dominate; no long-tail visibility. Per-tx sizes from
the 24h referral cut: SwapKit ~$1,890 avg, Rango ~$1,890, LI.FI ~$1,350,
Zodl ~$8,630 (whale-skewed) — retail-to-mid-size flow, not whale wires.

## 4. Revenue deep-dive: where the money comes from

The fee stack (from docs): **1 pip (0.0001%)** protocol fee to
`fee_collector` + **0.2%** `near-intents.org` frontend fee + **1Click**
(+25 bps keyless / 20 bps keyed / 1 bp stable-or-same-asset pairs, 50/50
app splits, 500 bps cap) + **quote-improvement surplus split 50/50** + gas +
solver spread (the auction sets the price).

What the numbers say (all verified Oct 7):

- **Gross → net:** 30d gross $7.384M − net $1.927M ⇒ ~74% goes to
  solvers/distribution, **~26% captured**. Implied gross rate ~16.7 bp,
  net ~4.4 bp. Q3-2026 income statement: gross $14.43M, cost to solvers
  $11.37M (78.8%), profit $3.07M — accelerating (Q2 profit $1.5M, Q1 $760K).
- **Capture by mechanism** (revenue.near.org, 30d): front-end fees **15.5%**,
  B2B partners **9.4%**, quote improvement **3.6%** (~28.5% total — matches
  the ~26% Llama capture within methodology noise). Frontend is the largest
  net stream on the 30d view, though Llama's quarterly split shows "Other"
  (B2B/1Click/quote-improvement) ahead in Q3 — dominant line is
  period-dependent.
- **Affiliate concentration** (explorer 24h): SwapKit referral $17.17M /
  9,066 tx (**~18% of daily vol**); SwapKit-family affiliates
  (ledgerswapkit $6.93M + swapkit.near $6.24M) dominate the affiliate table
  alongside buybacks.* ($9.3M), Zodl ($2.87M), Rango ($2.22M), LI.FI
  ($1.33M), THORSwap ($2.7M). No 30d affiliate shares published.
- **Wallet trace** (all-time, revenue.near.org): `fefundsadmin` 1.851M NEAR
  (48.7%, frontend fund) → `buybacks.multisignature.near` 1.392M NEAR
  (36.6%, buyback wallet) → `1csfundsadmin` 555K NEAR (14.6%, 1Click fund).
  Llama adapter: frontend = fe-wallet sweeps; Other = 1cs + buybacks.
- **Efficiency ratios** (dashboard's own framing): gross fee rate (bps of
  volume), net revenue (bps), capture-rate trend — explicitly "tracking
  NEAR's path to deflation."

Why it monetizes most: the pip + affiliate + auction-surplus stack captures
spread at the order-flow layer, while LZ/Wormhole give transport away at $0
protocol take. The 74–79% paid out is the cost of solver competition — the
26% kept is the most valuable slice in the bridge set.

## 5. Buyback promise (status: live, with one conflict)

- Since **2026-02-23**, captured Intents revenue buys back **$NEAR on the
  open market**, executed via `buybacks.multisignature.near`. Cumulative
  holders-revenue $5.74M (DeFiLlama); 30d $1.93M; Q3 $3.07M.
- **Burn conflict — do not cite either way without resolving:**
  revenue.near.org tagline says buybacks "permanently remove NEAR from
  circulation"; DeFiLlama methodology says explicitly **"(not burned)"**.
  Treat burn as **not verified**.
- Cadence not verified. No separate INTENTS-token accrual verified —
  DeFiLlama lists symbol NEAR, parent near-protocol; docs show no
  tokenomics/INTENTS page. The buyback asset is $NEAR itself.
- Verdict: **live-and-accruing, buyback (not verified burn).**

## 6. Use cases, future, Aptos, risks

- **Use cases:** SwapKit (dominant), Rango/LI.FI/THORSwap (aggregator
  distribution), Frax/Bitte/Delta Trade (ecosystem), Sailor Send
  (BTC-collateral loans — the Bitcoin-leg showcase), Confidential Intents B2B
  (Jul 2026: private chain, shielded balances, allowlisted solvers).
- **Future:** highest changelog velocity in the set (Jun–Sep 2026):
  Robinhood Chain support, 1Click Limit Orders, verifiable quote signatures,
  SHIELD incident API, Confidential Intents; Confidential TVL $144M
  (+335% over 90d). No Omni sunset found.
- **Aptos:** "fully supported" (1Click chain-support page, POA Bridge set).
- **Risks:** (1) Oct 1, 2026 **$3.8M BSC bridge-logic flaw** (DeFiLlama:
  "Bridge & Cross-Chain," bridgeHack: true) — settlement, not intent layer;
  track remediation. (2) Solver dependence: huge size / illiquid tokens /
  volatile markets get bad quotes or no fill. (3) No canonical issuance —
  can't mint native assets, pass votes, relay oracle data, or enforce issuer
  compliance. (4) Maroo not in chain set; and Intents fills swaps from
  inventory — it cannot custody a dedicated lock/mint pair.

## Sources

- Trailing figures (verified by direct fetch Oct 7, 2026):
  `api.llama.fi/summary/fees/near-intents` (dailyFees/Revenue/HoldersRevenue),
  `api.llama.fi/summary/dexs/near-intents`, `api.llama.fi/protocol/near-intents`
  (chain TVL, hack entry), `revenue.near.org` (capture rates, wallets),
  `explorer.near-intents.org` (top swaps, referrals, affiliates).
- Architecture/docs: `docs.near-intents.org` (what-are-intents, verifier,
  market-makers, 1Click API, fee-config, chain-support, bridging, changelog),
  `docs.near.org/chain-abstraction` (intents overview, omnibridge),
  `intents.near.org`, `github.com/near/intents`.
- Fee methodology: DeFiLlama near-intents page + `dimension-adapters/.../
  fees/near-intents/index.ts` (frontend vs Other split).
