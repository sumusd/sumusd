# SumUSD: An Aggregated, Over-Collateralized USD Stablecoin

**Version 1.1 — July 2026**

---

## Abstract

SumUSD is an ERC-20 stablecoin that aggregates a governance-whitelisted basket of credible,
major USD stablecoins — prioritizing GENIUS Act–compliant, U.S. Treasury-backed issuers — into
a single, fungible unit of dollar value. Users deposit any whitelisted collateral and receive SumUSD at a raw 1:1 unit rate;
they burn SumUSD to redeem any flavor the protocol holds. The protocol becomes and stays over-collateralized
through a *redemption haircut* rather than a deposit-side margin requirement, and it keeps its
collateral basket diversified through a single, continuous price signal: a **convex
weight-tilted haircut** (inspired by surge/congestion pricing) that prices redemptions of an
over-represented flavor cheaply and makes draining a scarce flavor progressively — and steeply —
more expensive, so depletion is self-defeating yet never blocked. A read-only `poolNeeds()`
signal lets the interface steer fresh deposits toward the gaps. Minting is automatically paused
whenever mark-to-market backing falls below a safety threshold, so new holders can never buy
into an under-backed pool.

The canonical specification of SumUSD is its source code (`contracts/src/`). This document
describes the design and the reasoning behind it; where a number appears here it is stated as
either a hard-coded protocol **constant** or a governance-set **parameter**, and the reference
deployment values are listed in the appendix.

---

## 1. Motivation

The dollar-stablecoin market is fragmented across many issuers with distinct risk profiles.
Even within the regulated, fully-reserved *payment stablecoin* category — credible, major,
fiat-backed dollar units — liquidity, accounting, and integrations are split across many
near-identical tokens that all trade at or just below $1.00, and a holder of any one bears that
single issuer's idiosyncratic risk. (A wider universe of dollar designs — yield-bearing
delta-neutral "synthetic dollars," algorithmic, and crypto-collateralized — exists alongside
them; SumUSD's basket prioritizes the regulated, Treasury-backed set but does not categorically
exclude others — see §3.4.)

SumUSD addresses three friction points:

1. **Fragmentation.** Liquidity, accounting, and integrations are split across many
   near-identical units. A single aggregated unit is simpler to hold, quote, and integrate.
2. **Concentrated issuer risk.** A holder of a single flavor bears 100% of that issuer's tail
   risk. A diversified basket spreads it.
3. **Fungibility.** Downstream applications want *one* dollar token, not a matrix of them, and
   want deposits and redemptions to behave predictably regardless of which flavor moves.

SumUSD is deliberately *not* a yield product, an algorithmic stablecoin, or a
crypto-over-collateralized CDP system. It is a **pooled peg-stability module (PSM)** over a
curated basket of stablecoins, with risk controls tuned to the empirical behavior of those
assets.

---

## 2. Design Overview

SumUSD is built around a single core invariant and a small number of mechanisms that enforce
it.

**Core invariant.** Every SumUSD in circulation should be redeemable for real dollar value
from the basket, and the basket should hold *at least* as much marked-to-market value as the
SumUSD supply, trending above it over time.

**Mechanisms.**

| Mechanism | Purpose | Where it acts |
|---|---|---|
| Raw 1:1 unit mint | Force fungibility across flavors | Deposit |
| Peg-band guard | Reject deposits of off-peg collateral | Deposit |
| Under-collateralization mint guard | Pause issuance into an under-backed pool | Deposit |
| Base redemption haircut | Create the over-collateralization buffer | Redeem |
| Convex weight-tilted haircut | Incentivize rebalancing; make depleting a scarce flavor self-defeating | Redeem |
| Redemption fee (2 bps, capped) | 1 bp extra backing + 1 bp to a governance-set recipient | Redeem |
| `poolNeeds()` deposit nudge | Steer fresh deposits toward under-represented flavors | Deposit (UI) |
| `donate()` recapitalization | Add backing with no mint; lift the ratio back above the floor | Anyone |
| Guardian collateral freeze | Instantly quarantine one misbehaving collateral (no value control) | Admin (guardian) |

The asymmetry is intentional: **deposits are simple and frictionless; redemptions carry all
the risk pricing.** This keeps the user-facing "mint a dollar" experience trivial while
ensuring the protocol only ever gives back value on terms that preserve solvency and
diversification.

---

## 3. System Architecture

SumUSD is three contracts plus a price-oracle interface.

### 3.1 `SumUSD` (the token)

An 18-decimal ERC-20 with EIP-2612 permit. Its total supply is controlled exclusively by
holders of `MINTER_ROLE`; in production that role is held only by the engine. The role that
*manages* minters (the token's `DEFAULT_ADMIN_ROLE`) is held by the same immutable timelock that
owns the engine — **not** by a hot deployer key — so mint authority itself can only ever change on
the timelock's public delay (§9). The deploy script grants that admin role to the timelock and
renounces the deployer's copy in the same transaction, so at no point after deployment can a single
EOA grant itself minting rights. The token itself contains **no collateral logic** — it is a pure
unit of account whose issuance and destruction are delegated to the engine.

### 3.2 `SumUSDEngine` (the vault)

The engine custodies the entire collateral basket and is the sole minter/burner of SumUSD. It
holds, per collateral, a configuration record:

```
struct CollateralConfig {
    bool        enabled;              // deposits/redemptions allowed
    uint8       decimals;             // cached on listing
    uint16      redeemRateBps;              // base redemption rate (sanity-railed to 95-100%)
    IPriceOracle oracle;             // USD price feed (18-decimal WAD)
}
```

Collateral is **pooled, not tracked per depositor.** SumUSD is therefore a fungible claim on
the whole basket, not a receipt for a specific deposit — a user who deposited one flavor may
redeem another, subject to availability.

The engine uses OpenZeppelin `Ownable2Step` (two-step ownership transfer), `ReentrancyGuard` (on
`deposit`/`redeem`), and `SafeERC20`. It reads the *actually received* balance on deposit, so
fee-on-transfer tokens can never cause over-minting. There is deliberately **no global pause** —
deposits and redemptions can never be halted wholesale by an admin; the only fast lever is a
guardian that can freeze a single collateral (see §9).

### 3.3 Price oracle (`IPriceOracle`)

```
function getPriceWad(address token) external view returns (uint256 priceWad);
```

Prices are quoted in USD and scaled to 18 decimals — a "WAD" — where `1e18 == $1.00`.
Production implementations are expected to wrap a robust feed (e.g. Chainlink) and revert on
stale or invalid rounds. All engine valuation math normalizes through this WAD.

The engine reads the oracle **defensively** (`_tryPriceWad`, a `try/catch`): if a feed reverts or
returns 0, that collateral is valued at **0** rather than reverting the call. So a single broken
feed cannot brick the basket-wide loops (backing ratio, weight tilt, `poolNeeds`); it just drops
that collateral to zero backing/weight (conservative — may halt minting if it is a large share),
while `redeem` of the affected flavor falls back to its flat base rate at par so holders can still
exit. The on-chain quotes (`currentRedeemRateBps`, `previewRedeem`) report that same base-rate
fallback, so a quote never diverges from the actual payout. (A deposit of a flavor whose feed is
down still reverts — it can't be peg-checked.)

It is important to understand *where the oracle is and is not used*:

- It **does not** price minting *or* redemption — both are fungible 1:1 unit swaps (§4, §5).
- It **gates** deposits via the peg band (§4.2).
- It **values** the basket for the collateralization ratio (§6) and weighs each flavor's share
  for the redemption tilt (§5.2).

### 3.4 Eligible collateral

Acceptable collateral is a governance-curated **whitelist** — it is never open or
permissionless. The whitelist **prioritizes GENIUS Act–compliant payment stablecoins backed by
U.S. Treasuries**: fully reserved, regulated, fiat- and Treasury-backed U.S. dollar stablecoins
from permitted payment stablecoin issuers form the core of the basket. Other credible, major
dollar designs — including yield-bearing, delta-neutral "synthetic dollars" — are **not
categorically excluded**; where governance whitelists them, they are admitted under more
conservative risk parameters (a steeper base haircut) commensurate with their risk profile.

Anchoring the basket on regulated, Treasury-backed issuers is what keeps the protocol's
simplifying assumptions safe: those instruments are designed to be fully redeemable at par by a
regulated issuer, which is why SumUSD can mint against the basket at a flat 1:1 rate (§4) and
treat whitelisted flavors as fungible dollars. Risk varies across the set — issuer
concentration, reserve composition, secondary-market liquidity, and the nature of the backing —
so each whitelisted flavor carries its own per-collateral risk parameters (§5, §8). Adding or
removing a flavor is a governance action.

---

## 4. Minting

### 4.1 Raw 1:1 unit swap

A deposit of `amount` units of an accepted collateral mints SumUSD equal to that amount,
normalized only for decimals:

```
minted = amount × 10^18 / 10^(collateral decimals)
```

One unit of *any* accepted collateral mints exactly one SumUSD. The oracle price does **not**
enter this calculation. This is a deliberate choice to **force fungibility**: within the
protocol, every accepted flavor is treated as exactly one dollar, so one unit of any whitelisted
flavor mints 1 SumUSD even when their market prices differ by a few basis points. The result
is a clean, predictable unit and a single internal notion of "a dollar."

The trade-off is that, because the basket is *valued* at oracle prices but *minted* at par, a
deposit made while a flavor trades slightly below $1 mints marginally more SumUSD than the USD
value deposited. Two guards bound and contain this.

### 4.2 Peg-band guard

A deposit reverts (`PriceOutOfBand`) if the collateral's oracle price deviates from $1.00 by
more than `MAX_DEPOSIT_PRICE_DEVIATION_BPS` (a constant, **0.5%**):

```
|priceWad − 1e18| × 10_000  >  1e18 × MAX_DEPOSIT_PRICE_DEVIATION_BPS   ⇒ revert
```

This is a circuit breaker, not a pricing input. Because the major stablecoins normally trade
within a few basis points of par and only rarely above it, a 0.5% band comfortably admits
normal deposits while rejecting collateral that has genuinely de-pegged. The band is what
bounds the par-vs-market mint drift from §4.1 to ≤ 0.5% per deposit. Redemptions are
deliberately **not** gated by this band, so holders can always exit during a de-peg.

### 4.3 Under-collateralization mint guard

A deposit reverts (`UnderCollateralized`) when the system's mark-to-market backing, measured
*before* the deposit, is below `MIN_MINT_RATIO_BPS` (a constant, **99%**):

```
if systemCollateralizationRatioBps() < MIN_MINT_RATIO_BPS  ⇒ revert
```

This prevents new issuance into an under-backed pool — a fresh depositor cannot mint SumUSD
that would immediately socialize an existing shortfall. The threshold sits at 99% rather than
100% precisely because the basket structurally trades a hair under par: a hard 100% guard,
combined with raw 1:1 minting, would pause issuance during entirely normal market conditions.
The 1% of slack absorbs ordinary sub-par trading while still halting issuance during a real
de-peg.

The guard is:

- **Bootstrap-safe** — at zero supply the ratio is defined as "infinitely backed," so the
  first deposit is always allowed.
- **Self-healing** — it is a condition, not a latch. Minting resumes automatically once backing
  recovers to ≥ 99% (via redemptions or oracle recovery), with no administrative action.
- **One-sided** — it never blocks redemptions.

---

## 5. Redemption

Redemption is where SumUSD prices risk. Burning `sumUsdAmount` returns a chosen collateral as a
**fungible 1:1 unit swap** ($1 = 1 unit, decimal-normalized) minus a convex weight-tilted
haircut — the oracle does **not** price the payout (it only sets the haircut's tilt via basket
weights). Mint and redeem are therefore symmetric unit swaps. No redemption is ever gated or
blocked — every flavor is always redeemable; balance is maintained by the haircut alone.

### 5.1 The base haircut (`redeemRateBps`)

Each collateral has a base redemption rate `redeemRateBps`, bounded by immutable sanity rails to
**[95%, 100%]** — governance can tune it but never outside that tight band (≤100% preserves
over-collateralization; ≥95% caps the base haircut at 5%). Burning 1 SumUSD returns at most
`redeemRateBps` worth of collateral; the remainder stays in the pool. Because the redeemer leaves
value behind on every exit, **the redemption haircut is the source of the protocol's
over-collateralization** — backing trends above 100% as redemptions occur. Riskier flavors
carry a steeper base haircut (a lower `redeemRateBps`).

### 5.2 The convex weight-tilted haircut (with a parity band)

The effective redemption rate is the base `redeemRateBps` adjusted by how the redeemed flavor
sits relative to an equal-weight target — but only *after* a wide **parity band**. A flavor
redeems at exactly its base rate while its weight stays between **half** and **twice** its target;
the tilt engages only outside that band, and is measured from the band edge so the rate is
continuous at the knee. The shape is deliberately **asymmetric**: a gentle linear *discount* for
over-represented flavors, and a **convex** *premium* for under-represented ones that stays mild
just past the band but grows steeply as a flavor nears depletion. Inspiration is surge/congestion
pricing — cost rises with scarcity, and the rise accelerates — rather than any AMM invariant.

```
share    = collateralValueUsd(X) / totalCollateralValueUsd          (pre-redemption)
target   = 1 / N                                                     (N = funded collaterals)
band     = [ target/2 , 2·target ]                                   (parity band)

within band            :  effectiveRedeemRate = redeemRateBps                                   (no tilt)
above 2·target         :  effectiveRedeemRate = redeemRateBps + slope · (share − 2·target)      (linear discount)
below target/2         :  effectiveRedeemRate = redeemRateBps − slope · (target/2 − share)/share (convex premium)

effectiveRedeemRate is clamped to [0, 100%]
```

In basis-point integer form, exactly as implemented (`slope = tiltSlopeBps`):

```
shareBps  = collateralUsd × 10_000 / totalUsd
targetBps = 10_000 / funded
upper = 2 × targetBps ;  lower = targetBps / 2
share in [lower, upper]:  effectiveRedeemRateBps = redeemRateBps
share > upper          :  bonus   = slope × (shareBps − upper) / 10_000 ;  eff = min(redeemRateBps + bonus, 10_000)
share < lower          :  penalty = slope × (lower − shareBps) / shareBps;  eff = redeemRateBps − penalty (floored at 0)
```

- **Inside the band** → base rate. Ordinary, moderate imbalances (anywhere from half to double a
  flavor's target weight) are tolerated at parity, so the protocol does not over-react to noise.
- **Above 2× target** → higher rate → smaller haircut → more value back. This pulls the abundant
  flavor out and rebalances the basket.
- **Below ½× target** → convex premium → larger haircut. Because the penalty divides by `share`,
  it is small just past the band but blows up as `share → 0`: the last units of a scarce flavor
  return almost nothing. Draining a flavor to zero is therefore economically self-defeating —
  **without ever reverting**. Pricing, not a gate, protects the extremes, so a scarce flavor is
  never made un-redeemable and no large deposit can freeze redemptions.

The rate is priced on the **pre-redemption** basket (a marginal quote) and **clamped to
[0, 100%]**. The upper clamp is a hard safety property: a redemption can never return more than
the burned face value, so the tilt can never erode over-collateralization. For the discount side
to reward over-represented redemptions in practice, base `redeemRateBps` must sit below 100% to
leave headroom; the reference deployment uses 99% for the most liquid flavors, a steeper 97% for
one rated more conservatively, and `tiltSlopeBps = 500`. Setting `tiltSlopeBps = 0` disables the
tilt entirely (flat per-collateral haircut).

The effective rate for any flavor at the current moment is readable on-chain via
`currentRedeemRateBps(token)`, and `previewRedeem` returns a full quote. Both views are computed by
the same internal function that `redeem` applies, so a quote can never diverge from the actual
payout — including the flat-base fallback for an unpriceable feed (§3.3) and the penalty-direction
tilt for a frozen flavor (§9).

### 5.3 Deposit nudge (`poolNeeds`)

Redemption pricing pulls the basket toward balance from one side; a lightweight deposit-side
nudge pushes from the other, with no economics or solvency impact. The view `poolNeeds()` returns
the enabled flavor with the smallest USD balance — the one the basket most needs — while skipping any
flavor whose feed is currently unpriceable (it can't be deposited anyway, so steering deposits there
would be a dead end). The interface defaults the deposit selector to it and labels "the pool needs
**X**," steering fresh deposits into the gaps. It is purely a default / signal (inspired by
choice-architecture nudges); deposits remain a raw 1:1 unit swap regardless of which flavor a user
ultimately picks.

### 5.4 Distress mode: pro-rata redemption (`redeemMix`)

Pick-your-flavor redemption is correct while the basket is fully backed, but under a genuine
shortfall it becomes a **race**: par, first-come redemption lets early redeemers drain the healthy
collateral at ~$1 while late holders are left with the impaired remainder. To eliminate that
first-redeemer advantage, the system has a distress mode.

When `systemCollateralizationRatioBps()` falls below `DISTRESS_RATIO_BPS` (99%, the same line at
which minting is already frozen), single-flavor `redeem` is disabled (`UseRedeemMix`) and holders
exit via **`redeemMix(sumUsdAmount, minOut[])`**, a pro-rata claim on the *whole* basket:

```
out_i = balance_i · sumUsdAmount / totalSupply      for every listed collateral i
```

Each redeemer receives the same proportional slice of every flavor — including the impaired one —
so the shortfall is shared equally and the outcome is independent of *when* you redeem. Two
properties make it run-proof:

- **Order-independence.** Redeeming `S` from `(balance_i, T)` yields `balance_i·S/T`, leaving the
  pool at the same ratios; a later redeemer gets exactly the same slice of the original basket they
  would have gotten first. There is no advantage to redeeming earlier.
- **Ratio-invariance.** Pro-rata removes value and burns supply in the same proportion, so the
  backing ratio stays flat as holders exit — versus single-flavor par redemption, which *lowers*
  the ratio for everyone remaining (the mechanism that drives the run).

The payout is pure ownership math — **no oracle, no haircut, no tilt** — so it remains correct even
if some price feeds are dead. Frozen collaterals are included (their value is distributed too). And
a flavor whose transfer *fails* — for instance a custodial issuer that has blacklisted the engine
address — is **skipped rather than reverted**, so a single non-transferable collateral cannot block
the whole pro-rata exit; its slice simply stays pooled. Above 99% backing, `redeemMix` reverts
(`NotDistressed`) and normal pick-your-flavor redemption with the tilt applies; `previewRedeemMix`
and `listedCollaterals` support the UI.

### 5.5 Redemption fee

On top of the weight-tilt haircut, single-flavor redemption carries a small **protocol fee**,
`redeemFeeBps` (bps of the gross payout), split into a portion routed to a governance-set
`feeRecipient` (`feeToRecipientBps`) and a remainder retained in the pool as extra backing. The
reference configuration is **2 bps total, split 1 bp / 1 bp**: 1 bp is paid to the recipient and 1 bp
joins the over-collateralization buffer. The fee is immutably capped at `MAX_REDEEM_FEE_BPS` (2 bps),
so governance can tune or disable it but never set a punitive exit fee. Both `redeemFeeBps`/
`feeToRecipientBps` and the recipient address are set only by the owner, i.e. behind the 96h timelock.

Three properties keep it safe:

- **Distress-exempt.** The fee applies only to normal single-flavor `redeem`. `redeemMix` — the
  pro-rata distress exit — is never charged, preserving its run-proof, oracle-free fairness (§5.4).
- **Never blocks a redemption.** The routed portion is transferred to the recipient *best-effort*: if
  the recipient cannot receive the token (e.g. a blacklisted treasury), that slice is skipped and
  stays pooled rather than reverting the redemption. Redemptions are never gated by the fee.
- **Quoted exactly.** `previewRedeem` returns the net-of-fee payout and `previewRedeemFee` breaks a
  redemption into redeemer / recipient / retained, so quotes never diverge from what `redeem` pays.
  (`currentRedeemRateBps` still reports the tilt rate only — the fee is a separate flat bps.)

---

## 6. Over-Collateralization and Solvency

### 6.1 Where the buffer comes from

SumUSD does not require depositors to post excess margin. Instead, the buffer accrues on the
way *out*: every redemption returns less than the burned face value (the haircut), leaving
residual collateral in the pool. Over time this drives mark-to-market backing above 100%. The
**accumulated surplus is locked as permanent backing** — there is no path to sweep the buffer that
has already built up, so it only grows. The one value that *does* leave is a small, immutably-capped
per-redemption protocol fee (§5.5): of the 2 bps taken on each single-flavor redemption, 1 bp is
retained (adding to this same buffer) and 1 bp is routed to a governance-set recipient. The fee is
bounded to `MAX_REDEEM_FEE_BPS` (2 bps) and never touches the existing buffer.

The buffer can also be topped up directly. Anyone may call **`donate(collateral, amount)`** to add a
listed collateral to the pool as permanent backing, minting **no** SumUSD in return — it raises
`totalCollateralValueUsd()` (and the backing ratio) without increasing supply. This is the intended
recapitalization path: because the distress-mode `redeemMix` exit is ratio-flat (§5.4), redemptions
do not heal the ratio while distressed, so recovery back above the mint floor / distress line comes
from oracle recovery or a donation here. It reads the actually-received balance (fee-on-transfer
safe) and works even for a frozen-but-listed collateral. Being permissionless and mint-free, it can
only ever *raise* backing — never dilute it.

### 6.2 What the buffer buys

The redemption haircut turns a small, spread-out cost on the way out into a permanent, self-funding
solvency cushion — no depositor posts excess margin, and no backstop or equity token is required. That
cushion does several things specific to this design:

- **It pays for the fungibility guarantee.** Minting forces every flavor to a $1 unit at par,
  independent of the oracle (§4.1). Because the accepted flavors trade at or just under $1, a par mint
  of a sub-$1 flavor issues marginally more SumUSD than the dollar value deposited, nudging backing
  below 100% on the mint side (bounded by the ±0.5% peg band). The haircut is the counterweight that
  recovers this slack on redemption, so forced fungibility is *funded* rather than free.
- **It absorbs single-issuer impairment.** The reason to hold a basket rather than one flavor is
  diversification; over-collateralization is what keeps that diversification solvent. If one flavor
  de-pegs, total basket value falls, but a ratio above 100% means the impairment consumes the buffer
  before it touches holders' backing.
- **It is capital-efficient and self-capitalizing.** Unlike CDP designs that lock 150%+ collateral and
  lean on an equity token to cover shortfalls, SumUSD mints 1:1 and lets the margin accrue from
  redeemers each paying a small haircut. The safety pool builds itself out of ordinary throughput, and
  because the accumulated buffer is locked (§6.1) it is a one-way ratchet: the system trends *safer*
  the more it is used, and the cushion scales with redemption volume. The same headroom also delays
  and softens the distress regime (§5.4), so transient wobbles are absorbed before the floor is hit.

The cost is borne by redeemers, who receive slightly less than face — deliberately. This discourages
round-trip churn and effectively rewards holding (a passive holder's claim is over-backed and growing),
while the marginal cost falls on those exiting. In peg-stability-module terms the haircut is a
redemption spread, except it is retained to capitalize the protocol rather than paid out.

### 6.3 The solvency gauge

The protocol's health metric is:

```
systemCollateralizationRatioBps() = totalCollateralValueUsd() × 10_000 / SumUSD.totalSupply()
```

(`type(uint256).max` when supply is zero). `10_000` is exactly 100%; above is
over-collateralized. Numerator and denominator are deliberately on different bases — collateral
at **oracle mark-to-market value**, SumUSD at **face** — which is what makes the gauge
meaningful. It rises as the redemption haircut deposits residual value, and it can dip slightly
below 100% if collateral entered just under par (bounded by the peg band). This single number
is load-bearing: it gates minting (§4.3) and is surfaced to users and monitors.

### 6.4 Enforced invariants

- **No mint when undercollateralized** below 99% (§4.3).
- **No redemption returns more than face** — `effectiveRedeemRate ≤ 100%` by clamp (§5.2).
- **The convex tilt never gates a flavor** — it prices the extremes continuously (the rate
  approaches 0), rather than reverting (§5.2). A holder is never trapped: SumUSD is a fungible claim,
  so a positive-output flavor is always redeemable, and `redeemMix` covers distress.
- **A redemption never burns SumUSD for zero collateral** — if a positive-rate redemption would
  round to zero units (dust input too small for the token's decimals) it reverts (`ZeroCollateralOut`)
  instead of destroying the burn for nothing. (The one intentional zero-return case — a flavor the
  tilt has priced to a rate of exactly 0 — still returns 0 without reverting, preserving the
  never-gates property above.)
- **No deposit of materially off-peg collateral** — ±0.5% band (§4.2).
- **No over-mint on fee-on-transfer tokens** — mint is on the received balance.
- **No reentrancy** on `deposit`/`redeem`.

---

## 7. Incentive Design and Equilibrium Dynamics

### 7.1 Intuition: over/under-weight = cheap/expensive to remove

Read the redeem rate as the protocol expressing a *preference about its own composition*, but
only once a flavor drifts well off target. There is a wide **parity band** — from half to
twice a flavor's target weight — where nothing is priced and every flavor redeems at its base
rate. Moderate imbalance is simply tolerated. Beyond the band:

- A flavor **above 2× its target** is one the pool has too much of, so it is made **cheaper to
  redeem** (rate toward 100%, smaller haircut) — a carrot to take it away.
- A flavor **below ½× its target** is scarce, so it is made **more expensive to redeem** (lower
  rate, larger haircut). The premium is **convex**: gentle just past the band, but it ramps up
  sharply as the flavor approaches empty, so the last units return almost nothing — yet it never
  *blocks* a redemption (pricing, not a gate).

A redeemer is rational and takes whichever flavor returns the most, i.e. the most
over-represented one — and in doing so removes exactly the flavor the pool had too much of,
pulling its weight back toward target. The redeemer's self-interest *is* the rebalancing; no
keeper, gauge, or incentive token is required.

### 7.2 Worked example

Basket = flavor A \$2,100 / B \$750 / C \$150 (total \$3,000), target weight 33.3% (parity band
16.7%–66.7%), slope 500, base rates 99% / 99% / 97%:

| Flavor | Weight | vs. band | Effective redeem rate | Haircut |
|--------|--------|----------|-----------------------|---------|
| **A** | 70% | above 2× target | 99.16% | 0.84% |
| **B** | 25% | inside band | 99.00% | 1.00% |
| **C** | 5% | below ½× target | 85.34% | 14.66% |

B sits in the parity band and redeems at its base rate. A is over-represented and slightly cheaper;
C is badly under-represented and steeply dearer. The same SumUSD returns ≈99.2¢ as A but only
≈85.3¢ as C, so redeemers take A; A's weight falls back toward the band, and the basket converges
to balance.

### 7.3 The three forces

Equilibrium emerges from three mechanisms, each with a distinct role:

1. **1:1 mint — a neutral inflow valve.** Minting issues one SumUSD per unit regardless of
   flavor (the fungibility guarantee), so it applies *no* weight preference on the way in and can
   even push a flavor over-weight. The only entry-side steering is the soft `poolNeeds()` nudge
   that points fresh deposits at the most under-represented flavor.
2. **Base haircut — the spring tension.** Every redemption returns slightly less than face,
   leaving residual value behind. This is the always-present cost of exit that makes the system
   over-collateralized over time, independent of balance.
3. **Convex tilt — the restoring force.** It varies that haircut by weight: smaller on the
   over-represented flavor, convexly larger on the under-represented one. This is the directional
   pressure that channels redemptions toward the abundant flavor.

Together, **redemptions behave like a thermostat.** Knock the basket out of balance and a rate
gap opens (the abundant flavor becomes the cheap exit); redeemers close it. Drain a flavor too
far and its convex haircut spikes, so redeemers avoid it and deposits are nudged in, and it
refills.

### 7.4 Where it settles

The stable state is not a single point but the whole **parity band**: as long as every
flavor sits between half and twice its target, the tilt is zero and all flavors redeem at their
base rates — no flavor is cheaper than another, so no rebalancing pressure exists. Equilibrium is
therefore a comfortable *region*, not a knife-edge: only a flavor that drifts outside the band
opens a rate differential, which the next redeemer arbitrages away, pushing it back into the band.

The asymmetry is deliberate: the **mint side is neutral and symmetric** (1:1, fungible), while
the **redeem side carries all the steering** (base haircut for solvency, convex tilt for
balance). Minting a dollar stays trivial and predictable; the protocol does its risk-pricing and
rebalancing only on the way out, where it can afford to.

SumUSD deliberately keeps this to an on-chain, redemption-only price signal — there is no
StableSwap-style invariant, amplification coefficient, utilization curve, or liquidity-mining
token — because those add surface area without serving the core goal of a diversified, solvent
dollar.

---

## 8. Risk Parameters

### 8.1 Protocol constants (hard-coded, not governable)

| Constant | Value | Meaning |
|---|---|---|
| `WAD` | `1e18` | Fixed-point scale; `1e18` = $1.00 / 1.0 |
| `BPS` | `10_000` | Basis-point scale; `10_000` = 100% |
| `MAX_DEPOSIT_PRICE_DEVIATION_BPS` | `50` (0.5%) | Peg band for accepting deposits |
| `MIN_MINT_RATIO_BPS` | `9_900` (99%) | Minimum backing required to mint |
| `MIN_REDEEM_RATE_BPS` / `MAX_REDEEM_RATE_BPS` | `9_500` / `10_000` (95% / 100%) | Sanity rails on a collateral's base redeem rate — governance can only set it inside this band |
| `MAX_TILT_SLOPE_BPS` | `5_000` | Sanity rail on `tiltSlopeBps` — caps how steep the tilt can be set |
| `MAX_COLLATERALS` | `24` | Cap on listed collaterals — bounds the gas of all basket-wide loops |
| `MAX_REDEEM_FEE_BPS` | `2` (0.02%) | Sanity rail on the redemption fee — caps the total exit fee governance can impose |
| `DISTRESS_RATIO_BPS` | `9_900` (99%) | Below this, single-flavor redeem is disabled in favor of pro-rata `redeemMix` |

### 8.2 Governance parameters (set via the engine's owner)

| Parameter | Scope | Reference value | Meaning |
|---|---|---|---|
| `redeemRateBps` | per collateral | 99% (most flavors), 97% (conservatively rated) | Base redemption rate. Immutably bounded to **[95%, 100%]** (`MIN_/MAX_REDEEM_RATE_BPS`) |
| `tiltSlopeBps` | global | 500 | Sensitivity of the convex haircut to imbalance (0 = flat). Railed to ≤ `MAX_TILT_SLOPE_BPS` (5000) |
| `redeemFeeBps` | global | 2 | Total redemption fee (bps of gross payout), on top of the tilt haircut. Railed to ≤ `MAX_REDEEM_FEE_BPS` (2) |
| `feeToRecipientBps` | global | 1 | Portion of `redeemFeeBps` routed to `feeRecipient`; rest retained as backing. Must be ≤ `redeemFeeBps` |
| `feeRecipient` | global | deployment-specific | Recipient of the routed fee. `address(0)` ⇒ the routed portion stays pooled |
| `enabled` | per collateral | true | Accept deposits/redemptions |
| `oracle` | per collateral | deployment-specific | USD price feed |

The base redeem rates are set below 100% so the weight tilt has headroom to reward over-represented
redemptions, and the 99% mint guard is consistent with that — the protocol is designed to
operate comfortably in the 99–101% band that real stablecoin baskets occupy.

---

## 9. Governance and Administration

The engine's owner can:

- list or reconfigure a collateral (`setCollateral`): set its base redeem rate, oracle, and
  enabled status (the base redeem rate is bounded to the immutable [95%, 100%] rails). Listings follow the §3.4
  priority — favoring GENIUS Act–compliant, Treasury-backed stablecoins, with riskier designs
  admitted only under more conservative parameters;
- enable/disable a listed collateral (`setCollateralEnabled`);
- remove a retired collateral (`removeCollateral`) — only if it is disabled and holds a zero
  balance, so removal can never strand funds or change backing; this frees a slot against the
  `MAX_COLLATERALS` cap;
- tune the imbalance sensitivity (`setTiltSlopeBps`);
- set the redemption fee and its split (`setRedeemFee`, railed to `MAX_REDEEM_FEE_BPS`) and the fee
  recipient (`setFeeRecipient`);
- set the guardian (`setGuardian`).

That is the entire privileged surface. Notably, **there is no global pause** — no admin can halt
deposits or redemptions wholesale; holders can always exit.

**Guardian (the one fast lever).** A separate `guardian` address (a fast multisig, set by the
owner) can call `freezeCollateral(token)` to instantly disable a *single* collateral. This is the
narrow safety brake the design allows: a frozen collateral can no longer be **deposited** and is
**dropped from the active weight set** — so it never skews the redemption rates of the *other*
flavors — yet it **remains redeemable** and still counts toward backing. Its own redemption keeps
the convex tilt in the **penalty direction only**: a frozen flavor that is scarce still redeems at
its steep convex haircut (measured on the basket augmented with itself), so a freeze can never make
draining it *cheaper*; but the over-weight discount is dropped and the effective rate is capped at
its base, so a freeze can never *raise* a flavor's payout either. Keeping a frozen flavor redeemable
is deliberate — it means even freezing *every* flavor cannot trap holders; they can always exit (at
the base rate, or the scarcity-penalized rate, but never above base). The guardian's power is
strictly limited: it can only *stop new exposure* to an asset and quarantine it from influencing the
other flavors' rates; it cannot move value, cannot re-enable a collateral (un-freezing is
owner/timelock-only, i.e. slow), and cannot halt redemptions. This gives a real-time response to a
single misbehaving or compromised collateral without any wholesale kill-switch and without ever
locking holders out.

**The owner is an immutable timelock.** In production the owner is an `ImmutableTimelock` whose
delay is set once at construction and can never be shortened or removed (there is no `setDelay`),
and the deployer EOA is renounced — both the engine's ownership and the token's minter-admin role
(§3.1) rest with the timelock, not a hot key. Every change above must therefore be queued on-chain
and wait the full delay (reference: **96 hours**) before it can execute — a publicly-visible
announcement that gives holders a guaranteed window to redeem before any change lands. Even a compromised
timelock executor cannot act faster than the delay; calling `renounceExecutor()` freezes the
engine's parameters permanently. (OpenZeppelin's `TimelockController` is a battle-tested
alternative, but its delay is itself adjustable after a delay; the custom contract is used where a
strictly-immutable delay is required.)

The peg band and the 99% mint guard are **constants**, not governance levers — they are core
safety properties rather than tunable policy. Governance cannot mint SumUSD directly, cannot
return more than face value on redemption, and cannot sweep the accumulated over-collateralization
buffer. The one value it can route out is the per-redemption fee, and only within the immutable
`MAX_REDEEM_FEE_BPS` (2 bps) cap — the accumulated buffer itself stays untouchable.

The trade-off of having no pause is that there is no circuit breaker to halt an in-progress
exploit; the design leans instead on a minimal, immutable surface (constants for the rails,
timelocked-only parameter changes, redemptions always open) so that the attack surface an admin
could even reach is small and slow.

---

## 10. Security Considerations

- **Oracle dependence.** Valuation, the peg band, and the mint guard all rely on the oracle.
  A compromised or *stale-but-non-reverting* feed is the primary systemic risk (it would mis-value
  backing). Production deployments must use a robust feed that reverts on staleness, and may layer
  per-collateral redundancy. Note that a *reverting* feed is handled gracefully — `_tryPriceWad`
  values that collateral at 0 so one dead feed cannot brick the protocol (§3.3); the residual risk
  is a feed that returns a confidently-wrong price.
- **Fungibility trade-off.** Both mint and redeem are 1:1 unit swaps, so the protocol assumes par
  on both sides; the oracle only measures (backing ratio, tilt weights) and gates deposits (peg
  band). A holder of a flavor that has drifted below $1 is not compensated with extra units on
  redemption — they receive par units minus the haircut. The 0.5% peg band and the 99% mint guard
  bound the drift on the way in, and the redemption haircut offsets it over time. Because redeem is
  now par (not oracle-priced), a round-trip can no longer extract extra units of a sub-par
  collateral; the residual cross-flavor arbitrage that remains is inherent to par minting (a
  sub-par flavor is accepted at $1), bounded by the peg band.
- **Depeg behavior.** During a de-peg, deposits of the affected flavor are blocked (peg band)
  and minting may auto-halt system-wide (the mint guard, not an admin pause), but redemptions stay
  open so holders can exit. The weight tilt makes the depegged (now over-represented, as others are redeemed)
  flavor cheaper to take, accelerating its rotation out of the basket.
- **Run resistance (distress mode).** A par, first-come redemption is run-prone once backing falls
  below 100%: early redeemers could drain the healthy collateral while late holders are left with
  the impaired remainder. Below `DISTRESS_RATIO_BPS` (99%) the protocol switches to pro-rata
  `redeemMix` (§5.4), which gives every holder the same proportional slice of the whole basket — the
  shortfall is shared equally, redemption order stops mattering, and the backing ratio holds flat as
  holders exit. The normal 99–100% band keeps single-flavor redemption (the shortfall there is ≤1%
  and typically transient).
- **Reentrancy / token quirks.** `deposit` and `redeem` are guarded; transfers use `SafeERC20`;
  minting is computed on the received balance to neutralize fee-on-transfer tokens.
- **Pricing at the margin.** The weight tilt quotes on pre-redemption weights, so a single very
  large redemption is priced at one rate rather than integrated along the convex curve — a
  simplicity choice. The convex penalty still rises sharply with scarcity, so a large redemption
  of a thin flavor is heavily penalized even at the marginal rate.
- **Two-step ownership + immutable timelock.** Ownership transfer uses `Ownable2Step` (no
  hand-off to an unrecoverable address), and the production owner is an `ImmutableTimelock`: every
  parameter change waits a fixed, non-shortenable delay, so a key compromise cannot change the
  protocol faster than holders can exit (§9).
- **No global pause; only a per-collateral guardian freeze.** There is no system-wide kill-switch.
  The single fast response is the guardian's `freezeCollateral`, which can quarantine *one*
  misbehaving collateral in real time (no delay) — stopping new exposure to it and removing it from
  the active weight set (so it can't skew the other flavors' rates), while it (and every other
  flavor) **stays redeemable**. A frozen flavor keeps its convex penalty when scarce but its rate is
  capped at base (§9), so a freeze can never raise a payout; because it remains redeemable, even a
  rogue guardian freezing *all* flavors cannot trap holders — it can only stop deposits, never exits.
  The guardian cannot move value or re-enable; un-freezing is timelocked. The residual risk is that a
  basket-wide exploit (e.g. a broken shared oracle) still has no instant blanket stop.

---

## 11. Limitations and Future Work

- **Marginal vs. integrated tilt pricing.** A future version could price large redemptions
  progressively along the imbalance curve rather than at a single spot rate.
- **Rate-limited drain.** The convex tilt makes depleting a scarce flavor economically
  self-defeating but does not *forbid* it; if a hard guarantee on minimum diversity is ever
  required, a per-epoch redemption rate limit could be layered on without the liveness problems a
  hard gate would introduce.
- **Surplus utilization.** The over-collateralization buffer is currently locked permanently.
  A future, carefully-bounded mechanism could route a portion of realized surplus to a
  protocol reserve or to holders without weakening solvency.
- **Oracle robustness.** Multi-oracle medianization and explicit staleness/deviation circuit
  breakers are deployment-level hardening that a production launch should include.

---

## 12. Conclusion

SumUSD packages a diversified basket of dollar stablecoins into a single fungible unit with a
small, legible set of mechanisms. Minting is a frictionless 1:1 unit swap, gated only by safety
guards. Redemption carries all the risk pricing: a base haircut that builds an
over-collateralization buffer, and a convex weight tilt that continuously rebalances the basket
and makes depleting any flavor self-defeating without ever blocking a redemption. A self-healing
mint guard keeps new issuance
honest about the system's real, marked-to-market backing. The result is a dollar token that is
simple to hold and use, transparent in its solvency, and structurally biased toward staying
over-collateralized and diversified.

---

## Appendix A: Glossary

- **WAD** — a fixed-point number scaled by `10^18`; `1e18` represents `$1.00` (or the scalar
  `1.0`). Used for USD values and oracle prices.
- **bps (basis points)** — hundredths of a percent; `10_000 bps = 100%`. Used for rates,
  ratios, and risk parameters.
- **Flavor** — an individual whitelisted collateral stablecoin (a credible, major dollar
  stablecoin, with the basket prioritizing GENIUS Act–compliant, Treasury-backed issuers).
- **Funded collateral** — a listed collateral that currently holds a non-zero pool balance.
- **Haircut** — the portion of face value *not* returned on redemption (`100% − effectiveRedeemRate`); the
  source of the over-collateralization buffer.

## Appendix B: Canonical reference

This document describes the protocol; the authoritative specification is the source code:

- `contracts/src/SumUSD.sol` — the token.
- `contracts/src/SumUSDEngine.sol` — the vault, all mechanisms and guards.
- `contracts/src/interfaces/IPriceOracle.sol` — the price-feed interface.
- `contracts/test/SumUSDEngine.t.sol` — executable specification of the behaviors above.
