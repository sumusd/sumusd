# SumUSD: An Aggregated, Over-Collateralized USD Stablecoin

**Version 1.1 — July 2026**

---

## Abstract

SumUSD is an ERC-20 stablecoin that aggregates a governance-whitelisted basket of credible,
major USD stablecoins — prioritizing GENIUS Act–compliant, U.S. Treasury-backed issuers — into
a single, fungible unit of dollar value. Users deposit any whitelisted collateral and receive SumUSD at a raw 1:1 unit rate;
they burn SumUSD to redeem any flavor the protocol holds. The protocol becomes and stays over-collateralized
through a *redemption haircut* rather than a deposit-side collateral requirement, and it keeps its
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
| Redemption margin (2 bps, capped) | 1 bp extra backing + 1 bp to a governance-set recipient | Redeem |
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
    bool         enabled;         // deposits allowed (redemption is never gated)
    uint8        decimals;        // cached on listing
    uint16       redeemRateBps;   // base redemption rate (sanity-railed to 95-100%)
    IPriceOracle oracle;          // USD price feed (18-decimal WAD)
    bool         backingExcluded; // "siloed": contributes 0 to backing and drops out of the tilt (S9)
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
returns 0, the call is not bricked. So a single broken feed cannot halt the basket-wide loops
(backing ratio, weight tilt, `poolNeeds`), and `redeem` of the affected flavor falls back to its
flat base rate at par so holders can still exit. The on-chain quotes (`currentRedeemRateBps`,
`previewRedeem`) report that same base-rate fallback, so a quote never diverges from the actual
payout. (A deposit of a flavor whose feed is down still reverts — it can't be peg-checked.)

**Stale-price fallback (anti-distress-on-outage).** Valuing an unpriceable flavor at 0 is fully
conservative, but it means a *transient* feed outage on a large flavor can crater the backing ratio
and trip the whole system into distress (§5.4) even though nothing is actually insolvent. To bound
that, the engine can value a flavor whose live feed has failed at its **last-good price minus a
haircut**, for a governance-set grace window (`stalePriceGraceSeconds`, railed to
`MAX_STALE_PRICE_GRACE`); past the window it reverts to 0. The last-good price is only ever a value
the trusted oracle actually reported — warmed on every deposit/redeem of that flavor and by a
permissionless `refreshPrices()` keeper hook — so the fallback can never invent a price, only hold a
recent real one a little longer. It applies **only to the backing/tilt valuation**, never to the
deposit peg guard (still live-only, fail-closed) or the redemption payout (still par). It is
disabled by default (`stalePriceGraceSeconds = 0`, the fully-conservative behavior) and opt-in via
governance. Crucially, it only engages when there is *no* live price at all; a live feed reporting a
genuinely low price (a real de-peg) is used as-is, so distress still triggers correctly on actual
insolvency. `livePriceWad` / `valuationPriceWad` / `lastGoodPriceAt` surface feed health for a UI.

**A revert is not a neutral outcome, so adapters must not reject LOW prices.** Because the engine may
bridge an oracle revert with the (higher) last-good price, any adapter rule that turns a *low live
answer* into a revert converts a real crash into an apparent outage: the flavor would hold its pre-crash
value for the whole grace window, backing would read healthy, and the pick-your-flavor `redeem` would stay
open for exactly the first-redeemer run the distress gate exists to stop. The production
`ChainlinkOracleAdapter` therefore carries an absolute sane **ceiling** only (an implausibly high answer,
the direction that would inflate backing, is rejected); a fresh positive answer that is merely low is
passed through and valued as-is. An earlier version had a symmetric sane floor; it was removed once the
stale-price fallback made the masking path reachable. The same reasoning applies to any custom
`IPriceOracle`: fail closed on *unavailable* (stale, incomplete, sequencer down), never on *low*.
(The `MedianOracleAdapter`'s disagreement breaker still reverts on a wide spread; that condition is
transient during a crash, since deviation-triggered feeds re-converge within minutes, and is bounded by
the same grace window.)

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

**Eligibility requirements and the listing probe.** Because the engine accounts for collateral by
its on-chain `balanceOf` and treats one unit as exactly one dollar, a listed token must be
technically well-behaved: a conforming ERC-20 with standard fixed decimals (≤ 18), non-rebasing (a
balance changes only on transfer), no transfer hooks or callbacks, freely transferable with no
material fee-on-transfer, and honest, immutable metadata. Rebasing, fee-on-transfer, and hook-bearing
tokens are excluded, since any would silently break the unit accounting. `setCollateral` enforces the
mechanically-checkable part of this at listing time — a *sanity probe* that rejects a non-contract,
an unresponsive `decimals()`/`balanceOf()`, or decimals above the immutable cap, so a malformed token
fails at governance time rather than on first deposit. The behavioral properties (no rebase, no margin,
no hooks) cannot be detected on-chain at a single point in time and remain a governance whitelist
policy, backed by the timelock delay that gives holders a window to react to any listing.

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
that would immediately socialize an existing shortfall. Independently of the ratio, a deposit also
reverts (`MintDisabledInDistress`) for as long as the distress latch is set (§5.4), including the
recovery window in which backing may already read above par: the latched regime is exit-only, its exit
is the haircut-free pro-rata `redeemMix`, and a par-minted deposit taken straight back out through it
would be the peg-band arbitrage of §4.1 with nothing left to bound it. Recapitalization during distress
is `donate` (§5.4), not minting. The threshold sits at 99% rather than
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
share    = (collateralValueUsd(X) - out) / (totalCollateralValueUsd - out)   (POST-redemption)
out      = the redemption's face value (the maximum USD that can leave)
target   = 1 / N                                    (N = funded collaterals holding >= $1)
band     = [ target/2 , 2·target ]                  (parity band)

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

**Integrated (post-redemption) pricing.** The share is measured on the basket as it will stand *after*
the redemption settles, using the redemption's face value as the amount leaving (the maximum possible,
since the effective rate is ≤ 100%, so the adjustment is conservative in both directions). Two things
follow. First, a large redemption of a scarce flavor prices strictly worse than the marginal quote —
the anti-drain behaviour this design always intended, rather than one spot rate applied to the whole
size. Second, and more importantly, **a self-created imbalance cannot be cashed out**: flash-depositing
a flavor to push it past the upper edge used to clamp its rate to 100%, letting an attacker redeem the
flash mint *and* their pre-existing balance with no haircut at all, from a perfectly balanced pool, for
the cost of gas. Priced post-redemption, unwinding the deposit unwinds the share that justified the
bonus, so the round trip evaluates at the base rate and the attack is strictly loss-making.

**Block-start reference.** The tilt's denominator additionally passes through a reference recorded by
the first state-changing call of each block, taking whichever of (spot, block-start) is less favorable
to the redeemer: the penalty side is capped at the block-start total so an intra-block inflation cannot
*deepen* a third party's penalty, and the bonus side takes the larger total so it cannot *manufacture*
one. Without this, a single large deposit collapsed every other flavor's measured share below the convex
knee and drove their rates to zero for the rest of the block — denying service to anyone redeeming with
slippage protection, and paying zero to anyone without it. Residual, by design: an attacker who holds
the inflated position *across* a block boundary does move the reference, but at that point the imbalance
is real, persistent, and carries capital risk, which is precisely the state the tilt exists to price.

The rate is **clamped to [0, 100%]**. The upper clamp is a hard safety property: a redemption can never
return more than the burned face value, so the tilt can never erode over-collateralization. For the discount side
to reward over-represented redemptions in practice, base `redeemRateBps` must sit below 100% to
leave headroom; the reference deployment uses 99% for the most liquid flavors, a steeper 97% for
one rated more conservatively, and `tiltSlopeBps = 500`. Setting `tiltSlopeBps = 0` disables the
tilt entirely (flat per-collateral haircut).

The **marginal** rate for any flavor (the curve's value at zero size) is readable on-chain via
`currentRedeemRateBps(token)` / `marginalRedeemRateBps(token)`; the rate a given size actually pays via
`redeemRateBpsFor(token, amount)`; and `previewRedeem` returns a full quote including the margin. Both views are computed by
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

When `systemCollateralizationRatioBps()` falls below `DISTRESS_ENTER_RATIO_BPS` (99%, the same line at
which minting is already frozen), the system **latches** into distress: single-flavor `redeem` is
disabled (`UseRedeemMix`) and holders exit via **`redeemMix(sumUsdAmount, minOut[])`**, a pro-rata claim
on the *whole* basket:

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
  backing ratio stays flat as holders exit (and rises, once the par cap binds above 100%) — versus
  an uncapped single-flavor par redemption, which *lowers* the ratio for everyone remaining (the
  mechanism that drives the run).

The payout is ownership math — **no haircut, no tilt** — with a single, one-sided use of the oracle:
**a slice is capped at par.** While backing is *above* 100% (the recovery window after a recap), every
slice is scaled by `totalSupply / backingUsd`, so a SumUSD never exits with more than $1.00 of backing.
The cap only ever shrinks a payout, and only when the pool holds *more* than the claim; below par the
slices are the raw pro-rata share, and a dead feed (which can only *lower* the measured backing) can
never shrink one. So the exit stays oracle-independent exactly where that matters — sharing a shortfall
— and remains correct even if some price feeds are dead. Without the cap the surplus above par was fully
extractable during every recovery window: deposit, then `redeemMix`, in one transaction, took
`ratio − 1` per unit, lowered the ratio by exactly that, and once it slipped under the exit line the
recovery clock reset — a loop that both skimmed the buffer and kept the system latched. With the cap the
excess stays pooled, so every pro-rata exit *raises* backing and shortens recovery (and minting is closed
while latched, §4.3, which removes the loop's other half). Frozen collaterals are included (their value
is distributed too). And
a flavor whose transfer *fails* — for instance a custodial issuer that has blacklisted the engine
address — is **skipped rather than reverted**, so a single non-transferable collateral cannot block
the whole pro-rata exit; its slice simply stays pooled. The skip is bounded, not just non-reverting:
the token's `transfer` receives a fixed gas stipend and only one word of its return data is ever read,
so a listed token that turns hostile (a captured proxy that burns all the gas it is given, or returns
megabytes) costs the redeemer its own leg and nothing more. The same bound applies to every basket-wide
`balanceOf` read, which otherwise could tax every call in the system. Above 99% backing, `redeemMix` reverts
(`NotDistressed`) and normal pick-your-flavor redemption with the tilt applies; `previewRedeemMix`
and `listedCollaterals` support the UI.

**Hysteresis (why the gate latches).** Entry is instant and unconditional; *exit* requires backing to
hold at or above a strictly higher `DISTRESS_EXIT_RATIO_BPS` (**100.25%**) continuously for
`DISTRESS_RECOVERY_DELAY` (**6 hours**), with any reading below the exit line restarting the clock. This
is load-bearing rather than cosmetic. A par redemption that removes value at an effective rate equal to
the current backing ratio is **ratio-neutral** — it changes nothing. So with a bare threshold, a holder
sitting just below the line could `donate` a trivial amount to re-cross 99% and then cherry-pick-drain
the healthy collateral without limit, because each redemption left the ratio exactly where it was and
never re-tripped the gate. Measured on the reference parameters, a $10,000 donation unlocked a $396,000
drain at par while backing read a flat 99% throughout, leaving the remaining holders in a basket that
went from half impaired to 81% impaired. Requiring a genuine recapitalization *above* 100%, sustained,
closes it.

The latch is observation-driven: every state-changing entry point syncs it from the live ratio, and the
permissionless **`pokeDistress()`** keeper hook starts or advances the countdown when the system is
otherwise idle. A price move alone does not update the flag, but the gate re-syncs before it gates, so
it cannot be stepped around by simply not poking it. `distressed`, `recoveryStartedAt`,
`distressClearsAt()`, and `distressParams()` expose the state to UIs and monitors.

A ratio gate structurally cannot see *composition* — a pool can go from evenly split to entirely
impaired at a constant ratio — so a per-epoch, per-flavor drain limit remains the natural next control
(§11).

### 5.5 Redemption margin

On top of the weight-tilt haircut, single-flavor redemption carries a small **protocol margin**,
`redeemMarginBps` (bps of the gross payout), split into a portion routed to a governance-set
`marginRecipient` (`marginToRecipientBps`) and a remainder retained in the pool as extra backing. The
reference configuration is **2 bps total, split 1 bp / 1 bp**: 1 bp is paid to the recipient and 1 bp
joins the over-collateralization buffer. The margin is immutably capped at `MAX_REDEEM_MARGIN_BPS` (5 bps),
so governance can tune or disable it but never set a punitive exit margin. Both `redeemMarginBps`/
`marginToRecipientBps` and the recipient address are set only by the owner, i.e. behind the 96h timelock.

Three properties keep it safe:

- **Distress-exempt.** The margin applies only to normal single-flavor `redeem`. `redeemMix` — the
  pro-rata distress exit — is never charged, preserving its run-proof, oracle-free fairness (§5.4).
- **Never blocks a redemption.** The routed portion is transferred to the recipient *best-effort*: if
  the recipient cannot receive the token (e.g. a blacklisted treasury), that slice is skipped and
  stays pooled rather than reverting the redemption. Redemptions are never gated by the margin.
- **Quoted exactly.** `previewRedeem` returns the net-of-margin payout and `previewRedeemMargin` breaks a
  redemption into redeemer / recipient / retained, so quotes never diverge from what `redeem` pays.
  (`currentRedeemRateBps` still reports the tilt rate only — the margin is a separate flat bps.)

### 5.6 Batch redemption (`redeemBatch`)

A holder can redeem several flavors in one transaction with
`redeemBatch(collaterals[], sumUsdAmounts[], minOuts[])`, which returns the collateral received per
leg. This is a convenience over calling `redeem` N times — most useful for spreading a large exit
across flavors rather than concentrating it on one and paying its convex scarcity premium (§5.2), and
for cutting N approvals/transactions to one. It changes no economics:

- **Snapshot pricing.** Every leg is priced on a *single* pre-batch basket snapshot (the tilt weights
  are read once, before any leg settles), so the ordering of the legs never changes a rate and the
  quote `previewRedeemBatch` matches the payout leg-for-leg — the same preview-equals-payout guarantee
  as single `redeem` (§5.5). `redeem` and `redeemBatch` share the same internal per-leg routine, so a
  leg pays exactly what the equivalent single `redeem` would at that snapshot.
- **Solvency-equivalent.** Each leg independently clamps its rate to ≤ 100% and retains the haircut, so
  a batch can never return more than face and never lowers backing — it is equivalent to a run of
  single redemptions for solvency purposes.
- **Distress gate, once.** The distress check (§5.4) runs once, up front: while distressed the whole
  batch reverts `UseRedeemMix` and the holder exits via `redeemMix`. A batch that begins in normal mode
  stays in it, because a redemption can never lower the backing ratio: the above-par clamp (§5.7) bounds
  the value removed at $1.00 per SumUSD burned, and the backing-ratio cap (§5.8) bounds it at the pool's
  current backing per SumUSD whenever that is below par. (Each of those was added after a case where
  "redemptions only raise backing" turned out to be false: a flavor trading above $1 drained at par, and
  a 100%-rate redemption from a pool backed at 99.5%.)
- **Atomic.** Any leg that would revert on its own — unlisted collateral, dust, per-leg slippage
  (`minOuts[i]`), insufficient pool, or a length mismatch across the three arrays — reverts the entire
  call, so a batch either settles completely or not at all.

The margin (§5.5) applies per leg exactly as in single `redeem`. `redeemBatch` must be a native engine
function rather than an external router, because `SumUSD` burns are `MINTER_ROLE`-gated and burn the
caller with no allowance path — no third-party contract can batch redemptions on a holder's behalf.

---

### 5.7 The above-par clamp

The payout is deliberately **price-blind below $1.00**: a holder redeeming a sub-par flavor receives par
units minus the haircut, not extra units. That asymmetry is what keeps the round-trip arbitrage closed
(§10), and valuing a low price *up* toward $1 would mask insolvency, so it is never done.

Above $1.00 the same blindness runs the wrong way. A flavor trading at $1.05 still paid one unit per
SumUSD, so every burn extracted $1.05 of mark-to-market value. During a flight to quality — one flavor
impaired, another bid above par — redeemers rationally strip the pool of its **best** asset and leave the
impaired one behind, and each such redemption *lowers* the backing ratio. The weight tilt does not resist
this; if anything a richer flavor has a larger USD share and sits closer to the overweight discount.

So the rate carries a one-sided clamp: when a flavor's **live** price exceeds $1.00, the effective rate is
scaled by `1/price`, capping the payout at $1.00 of value per SumUSD burned. Three properties keep it
safe:

- **Conservative direction only.** It can never *increase* a payout, so it cannot re-open any arbitrage.
  It is the mirror image of the rejected "clamp a low price up to $1", not a relaxation of it.
- **Bounded by the sane band.** A compromised-high feed can only shrink a payout as far as the oracle
  adapter's configured upper bound allows (§3.3), and holders can still exit via any other flavor.
- **Clamped against the price backing is counted at, so a feed outage cannot reopen the drain.** With a
  live feed the clamp uses the live price. On a dead feed it uses the stale-price fallback (§3.3), the same
  number the backing ratio values the flavor at, and 0 (no clamp, par) once that cache expires. An earlier
  version clamped on the live price only and accepted "a flavor which spikes above $1.00 and then loses
  its feed pays par units" as a residual; once the stale fallback shipped that residual became a leak the
  invariant suite caught: the flavor was *valued* at its cached ~$1.18 but *paid* at par, so every
  redemption of it lowered backing for the whole grace window. The exit is still oracle-independent in
  the sense that matters: no feed state can block it, only trim it, and after the grace window it is
  exactly the flat base rate at par.

### 5.8 The backing-ratio cap

Outside distress, backing can legitimately sit **between the 99% floor and par**: worst-case in-band
deposits settle it toward 99.5% (§4.3), and a mild depeg of one flavor can hold it anywhere in that band
without ever crossing the distress line. In that state a single-flavor redemption paid at an effective
rate *above* the ratio (a flavor with a 100% base rate, or one earning the overweight bonus) hands the
redeemer more per SumUSD than the pool holds per SumUSD. Every such exit pushes the remaining holders'
backing *down* — the first-redeemer dynamic one step at a time — and one large enough redemption could
walk a 99.5%-backed pool straight through the 99% line without ever being gated, because the distress
check is a pre-check.

So the effective rate is additionally **capped at the backing ratio** (`_capAtBacking`): a redemption
from a pool backed at 99.5¢ per SumUSD pays at most 99.5¢ per SumUSD. Properties:

- **Conservative direction only.** It never raises a payout. It is the below-par mirror of the above-par
  clamp, and is applied *before* it, so an above-$1 flavor's value per SumUSD is bounded by the ratio too.
- **Never binds where it could hurt liveness.** The ratio can only cap when it is under 100%, and it is
  never below 99% while single-flavor redemption is open (below that the latch has already routed holders
  to `redeemMix`), so the cap costs a redeemer at most one percentage point and never approaches zero.
- **Makes every redemption ratio-non-decreasing.** With the cap, the value leaving per SumUSD burned never
  exceeds the value held per SumUSD, so `systemCollateralizationRatioBps()` cannot fall on a redemption in
  any regime — the invariant `redeemBatch`'s single distress check relies on (§5.6), and one that also
  closes the par-mint arbitrage's payoff whenever backing is below par (deposit at $0.995, redeem at the
  ratio, not at $1). The dead-feed base-rate exit is capped the same way; it stays oracle-independent in
  units and can only be trimmed, never blocked.

---

## 6. Over-Collateralization and Solvency

### 6.1 Where the buffer comes from

SumUSD does not require depositors to post excess margin. Instead, the buffer accrues on the
way *out*: every redemption returns less than the burned face value (the haircut), leaving
residual collateral in the pool. Over time this drives mark-to-market backing above 100%. The
**accumulated surplus is locked as permanent backing** — there is no path to sweep the buffer that
has already built up, so it only grows. The one value that *does* leave is a small, immutably-capped
per-redemption protocol margin (§5.5): of the 2 bps taken on each single-flavor redemption, 1 bp is
retained (adding to this same buffer) and 1 bp is routed to a governance-set recipient. The margin is
bounded to `MAX_REDEEM_MARGIN_BPS` (5 bps) and never touches the existing buffer.

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

- **No mint when undercollateralized** below 99%, and **no mint while the distress latch is set** at any
  ratio (§4.3).
- **No redemption returns more than face, in UNITS or in VALUE** — `effectiveRedeemRate ≤ 100%` by
  clamp (§5.2), and when a flavor's live price is above $1.00 the rate is additionally scaled by
  `1/price`, so a redemption never removes more than $1.00 of mark-to-market value per SumUSD burned
  (§5.7). The unit clamp alone was not enough: a flavor trading at $1.05 could be drained at par, which
  extracted more value than was burned and *lowered* the backing ratio.
- **No redemption lowers the backing ratio** — the effective rate is also capped at the current backing
  ratio (§5.8), so the value leaving per SumUSD burned never exceeds the value held per SumUSD, in any
  regime. Checked by a stateful invariant across price moves, dead feeds and the stale fallback.
- **No exit pays more than $1.00 of backing per SumUSD, in either regime** — single-flavor via the
  above-par clamp (§5.7), pro-rata via the `redeemMix` par cap (§5.4). The accumulated surplus is not
  extractable through the distress exit.
- **No single collateral can brick, or tax, the basket or the distress exit** — a listed token whose
  `balanceOf` starts reverting after listing (e.g. a bricked upgradeable proxy) is read defensively wherever
  the engine walks the whole basket: it values at 0 (so distress triggers honestly), `poolNeeds` never steers
  deposits into it, and `redeemMix` skips its slice exactly as it skips a failing transfer. Both defensive
  calls are gas-capped and read at most one word of return data, so a hostile token cannot burn the
  caller's gas budget (63/64 of it, under EIP-150) or charge it for copying a huge return payload (§5.4).
- **The convex tilt never gates a flavor** — it prices the extremes continuously (the rate
  approaches 0), rather than reverting (§5.2). A holder is never trapped: SumUSD is a fungible claim,
  so a positive-output flavor is always redeemable, and `redeemMix` covers distress.
- **A redemption never burns SumUSD for zero collateral** — if the payout would be zero while the
  flavor's *marginal* rate is still positive, it reverts (`ZeroCollateralOut`) instead of destroying the
  burn for nothing. That covers both dust input and a request larger than the convex curve will serve
  under post-redemption pricing. (The one intentional zero-return case — a flavor the tilt has priced to
  a rate of exactly 0 *at the margin* — still returns 0 without reverting, preserving the never-gates
  property above.) `redeemMix` carries the same guard: it reverts if every leg would be zero, while
  still allowing partial zeros so an empty or non-transferable flavor stays skippable.
- **No deposit of materially off-peg collateral** — ±0.5% band (§4.2).
- **No deposit can grief the system into distress** — the mint floor sits at or below
  `100% − (peg band)`, i.e. `MIN_MINT_RATIO_BPS ≤ BPS − MAX_DEPOSIT_PRICE_DEVIATION_BPS` (9900 ≤ 9950),
  asserted in the engine's constructor. Worst-case in-band deposits drive backing asymptotically toward
  99.50% and no further, so no deposit sequence can cross the 99% line. The 50 bps of slack *is* the
  margin: widening the peg band to 100 bps would silently delete it.
- **A de-backed flavor is never mintable** — `deposit` rejects `backingExcluded` collateral outright, so
  siloing a stuck flavor can never become a permissionless dilution path (§9).
- **Manipulating the basket never pays** — the tilt is priced on the post-redemption basket and against a
  block-start basket reference, so no sequence of deposits inside one transaction or one block can raise
  a flavor's effective rate above its base rate, or push another flavor's below it (§5.2).
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

| Flavor | Weight | vs. band | Marginal redeem rate | Haircut |
|--------|--------|----------|----------------------|---------|
| **A** | 70% | above 2× target | 99.16% | 0.84% |
| **B** | 25% | inside band | 99.00% | 1.00% |
| **C** | 5% | below ½× target | 85.34% | 14.66% |

B sits in the parity band and redeems at its base rate. A is over-represented and slightly cheaper;
C is badly under-represented and steeply dearer. The same SumUSD returns ≈99.2¢ as A but only
≈85.3¢ as C, so redeemers take A; A's weight falls back toward the band, and the basket converges
to balance.

These are **marginal** rates (§5.2). A redemption of meaningful size is priced on the basket it leaves
behind, so it pays strictly less than the column above: taking \$300 of A moves A's weight to ≈66.7% and
its rate back to ≈99.00%, and the gap that motivated the trade closes as the trade fills. That is the
mechanism working as intended — the rate gap is an incentive to rebalance, not a fixed discount to be
taken in unlimited size.

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
| `MAX_REDEEM_MARGIN_BPS` | `5` (0.05%) | Sanity rail on the redemption margin — caps the total exit margin governance can impose |
| `DISTRESS_ENTER_RATIO_BPS` | `9_900` (99%) | Below this, the system latches into distress: single-flavor redeem is disabled in favor of pro-rata `redeemMix` |
| `DISTRESS_EXIT_RATIO_BPS` | `10_025` (100.25%) | Distress clears only at or above this, strictly higher than entry (§5.4 hysteresis) |
| `DISTRESS_RECOVERY_DELAY` | `6 hours` | How long backing must hold at/above the exit line before distress clears |
| `MIN_FUNDED_VALUE_WAD` | `1e18` ($1.00) | Minimum value for a flavor to count toward `funded` — stops dust from shifting both parity band edges |
| `MAX_SOURCES` (oracle) | `5` | Cap on median sources per token — a direct multiplier on redemption gas, lowered from 7 |

The mint floor and the peg band are **coupled**: `MIN_MINT_RATIO_BPS ≤ BPS −
MAX_DEPOSIT_PRICE_DEVIATION_BPS` (9900 ≤ 9950) is asserted in the engine's constructor, and it is what
makes deposit-driven dilution unable to reach the distress line (§6.4).

### 8.2 Governance parameters (set via the engine's owner)

| Parameter | Scope | Reference value | Meaning |
|---|---|---|---|
| `redeemRateBps` | per collateral | 99% (most flavors), 97% (conservatively rated) | Base redemption rate. Immutably bounded to **[95%, 100%]** (`MIN_/MAX_REDEEM_RATE_BPS`) |
| `tiltSlopeBps` | global | 500 | Sensitivity of the convex haircut to imbalance (0 = flat). Railed to ≤ `MAX_TILT_SLOPE_BPS` (5000) |
| `redeemMarginBps` | global | 2 | Total redemption margin (bps of gross payout), on top of the tilt haircut. Railed to ≤ `MAX_REDEEM_MARGIN_BPS` (5) |
| `marginToRecipientBps` | global | 1 | Portion of `redeemMarginBps` routed to `marginRecipient`; rest retained as backing. Must be ≤ `redeemMarginBps` |
| `marginRecipient` | global | deployment-specific | Recipient of the routed margin. `address(0)` ⇒ the routed portion stays pooled |
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
- remove a retired collateral (`removeCollateral(token, maxResidualUnits)`) — only if it is
  disabled and holds no more than the dust governance names in the queued call, so removal strands at
  most what governance has explicitly accepted; this frees a slot against the `MAX_COLLATERALS` cap.
  (An exact-zero requirement was free to grief: one wei transferred to the engine before the timelocked
  execute reverted it, every round. Exceeding a declared tolerance costs the griefer that much, paid to
  holders, per round.)
- tune the imbalance sensitivity (`setTiltSlopeBps`);
- set the redemption margin and its split (`setRedeemMargin`, railed to `MAX_REDEEM_MARGIN_BPS`) and the margin
  recipient (`setMarginRecipient`);
- "silo" a permanently-inaccessible flavor (`setCollateralBackingExcluded`, below);
- configure the stale-price fallback (`setStalePriceParams`, §3.3);
- set the guardian (`setGuardian`).

Two things are permissionless rather than privileged: `donate` (recapitalization, §6) and
`pokeDistress` / `refreshPrices` (keeper hooks that advance the distress countdown and warm the
last-good price cache; neither can move value or change a parameter).

That is the entire privileged surface. Notably, **there is no global pause** — no admin can halt
deposits or redemptions wholesale; holders can always exit.

**De-backing a stuck flavor.** A custodial stablecoin issuer can blacklist the engine, permanently
freezing that flavor's balance in the pool: it can no longer be transferred out, yet its `balanceOf`
and oracle price still read normally, so it keeps counting toward backing and the collateralization
ratio silently overstates what is actually redeemable. Left unaddressed, that lets early redeemers
exit through the healthy flavors at par while the last holders are stranded with the inaccessible
remainder — the very first-redeemer advantage distress mode exists to prevent, except distress never
triggers because the ratio still looks healthy. `setCollateralBackingExcluded(token, true)` fixes
this by *siloing* the flavor: its value contributes 0 to `totalCollateralValueUsd` and it drops out
of the weight tilt, so the ratio reflects only redeemable value and distress engages honestly if the
loss warrants it. The flavor stays listed and its balance stays pooled, so `redeemMix` still offers
its (skipped) slice and shares the shortfall pro-rata across all holders; `rawCollateralValueUsd`
still surfaces the stranded value for transparency. It is owner-only (so it waits the timelock, since
it can trip distress and holders deserve the exit window) and reversible if the blacklist ever lifts.
It is the honest-accounting counterpart to the guardian's `freezeCollateral` (which stops new
exposure instantly); a permanent blacklist warrants both.

A siloed flavor is **not depositable** — `deposit` rejects it outright, rather than relying on
governance to also freeze it. Since it contributes 0 to backing, minting against it 1:1 would dilute
every holder immediately, and the two levers sit on different timelocks and different signers, which is
exactly the condition under which one gets forgotten. Its redemption also takes the
penalty-direction-only tilt path (the same as a frozen flavor), because it is excluded from the basket
statistics and must not be measured against a basket it is not part of.

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
announcement that gives holders a guaranteed window to redeem before any change lands. (OpenZeppelin's
`TimelockController` is a battle-tested alternative, but its delay is itself adjustable after a delay;
the custom contract is used where a strictly-immutable delay is required.)

Three rails surround the delay:

- **A cancel-only canceller.** `CANCELLER` (immutable, pointed at the guardian multisig) can `cancel`
  any queued operation but can never queue or execute one. This matters because the delay alone gives
  holders *notice* but gives defenders *nothing*: if the executor multisig were compromised, the only
  account able to veto its malicious proposal would be the compromised one. Granting a cancel-only veto
  costs no additional authority, and it is immutable for the same reason the executor is — an executor
  able to strip the canceller instantly would defeat the point. Signer rotation happens inside the
  multisig.
- **An expiry.** A matured operation is executable only within `[eta, eta + GRACE_PERIOD]` (reference:
  **14 days**), then reverts and must be re-queued. Without it a queued proposal stayed live forever, so
  one drafted against long-stale assumptions could be fired years later.
- **A two-step renounce.** Renouncing the executor is permanent and freezes every parameter — including
  the ability to re-point a deprecated price feed, which is the part of the system that most needs to
  stay maintainable. So `initiateRenounce()` starts a publicly-visible countdown of one full `DELAY`,
  abortable via `abortRenounce()`, before `renounceExecutor()` will complete it.

The peg band and the 99% mint guard are **constants**, not governance levers — they are core
safety properties rather than tunable policy. Governance cannot mint SumUSD directly, cannot
return more than face value on redemption, and cannot sweep the accumulated over-collateralization
buffer. The one value it can route out is the per-redemption margin, and only within the immutable
`MAX_REDEEM_MARGIN_BPS` (5 bps) cap — the accumulated buffer itself stays untouchable.

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
  is a feed that returns a confidently-wrong price. With the stale-price fallback enabled, a revert is
  bridged by the last-good price for the grace window, which is why adapters must never turn a low live
  answer into a revert (§3.3): "unavailable" may be bridged, "low" must be believed.
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
  open so holders can exit. Note the tilt's direction here, which is easy to get backwards: a de-peg
  *lowers* the affected flavor's USD value and therefore its measured share, which moves it toward the
  convex **penalty** side, not the discount side. It only becomes cheap to take once other flavors have
  actually been redeemed away and its share has risen past the upper band edge — a second-order effect,
  not an immediate one. In the meantime the wide parity band usually absorbs the move entirely.
- **Run resistance (distress mode).** A par, first-come redemption is run-prone once backing falls
  below 100%: early redeemers could drain the healthy collateral while late holders are left with
  the impaired remainder. Below `DISTRESS_ENTER_RATIO_BPS` (99%) the protocol **latches** into pro-rata
  `redeemMix` (§5.4), which gives every holder the same proportional slice of the whole basket — the
  shortfall is shared equally, redemption order stops mattering, and the backing ratio holds flat as
  holders exit. The normal 99–100% band keeps single-flavor redemption (the shortfall there is ≤1%
  and typically transient). The latch is essential: because a par redemption at a rate equal to the
  current ratio is ratio-neutral, a bare threshold could be re-crossed once with a dust donation and
  then drained indefinitely without ever re-tripping it. Exit requires a sustained recovery above
  100.25%. The remaining exposure is *composition* rather than level — a ratio gate cannot see that the
  basket is rotating into its worst asset at a constant ratio — which is what the per-epoch drain limit
  in §11 addresses.
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

- **Rate-limited drain.** The convex tilt makes depleting a scarce flavor economically self-defeating
  but does not *forbid* it, and a backing-ratio gate structurally cannot see *composition* — a pool can
  go from evenly split to entirely impaired while the ratio never moves (§5.4). A per-epoch, per-flavor
  redemption rate limit, active inside the recovering band, is the natural next control; it can be
  layered on without the liveness problems a hard gate would introduce. This is the most significant
  remaining item.
- **Cross-block basket manipulation.** The tilt is protected against intra-block manipulation by
  post-redemption pricing and a block-start reference (§5.2). An attacker willing to hold an inflated
  position across a block boundary still moves the reference; a multi-block EMA of basket weights would
  close that too, at the cost of more state and more surface area. The current stopping point is
  deliberate: it removes the free, atomic, flash-loanable version and leaves only the one that carries
  real capital risk.
- **Above-par payouts on a dead feed.** The above-par clamp (§5.7) is live-only, so a flavor that spikes
  above $1.00 and then loses its feed still pays par units. Extending the clamp to the stale-price
  fallback would close it but would make the dead-feed exit oracle-dependent, which the design
  deliberately avoids.
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
- **Funded collateral** — an *enabled* listed collateral holding at least `MIN_FUNDED_VALUE_WAD` ($1.00)
  of pool value. The count of these sets the equal-weight target and therefore both parity band edges.
- **Haircut** — the portion of face value *not* returned on redemption (`100% − effectiveRedeemRate`); the
  source of the over-collateralization buffer.

## Appendix B: Canonical reference

This document describes the protocol; the authoritative specification is the source code:

- `contracts/src/SumUSD.sol` — the token.
- `contracts/src/SumUSDEngine.sol` — the vault, all mechanisms and guards.
- `contracts/src/ImmutableTimelock.sol` — the governance timelock (delay, canceller, grace, renounce).
- `contracts/src/oracles/` — the production price stack (`ChainlinkOracleAdapter`, `MedianOracleAdapter`).
- `contracts/src/interfaces/IPriceOracle.sol` — the price-feed interface.
- `contracts/test/SumUSDEngine.t.sol` — executable specification of the behaviors above.
- `contracts/test/Adversarial.t.sol` — attack attempts and the defenses that hold.
- `contracts/test/Manipulation.t.sol` — regressions for the basket-state and distress-gate exploits.
- `contracts/test/invariant/` — the stateful invariant suite (healthy and distressed regimes).
