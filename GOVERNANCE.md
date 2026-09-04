# SumUSD Governance Runbook

Operational guide for the signers who administer a deployed SumUSD instance. It covers the exact
transactions to build for every privileged action, and end-to-end checklists for the common jobs.

Read [WHITEPAPER.md](./WHITEPAPER.md) §9 for the design rationale; this document is the how-to.

> **Tooling.** [`governance/`](./governance) scripts every step below through the Safe{Core} SDK and the
> Safe Transaction Service **API** — deploy the Safes, and propose / confirm / execute each operation
> from the command line, no web UI. It encodes the exact calldata this document specifies. The manual
> `cast` + Safe-app flow here remains valid as a fallback and as the reference for what the tool builds.
> Example: `npm run gov -- queue set-tilt 500 --salt set-tilt-500` (see `governance/README.md`).

---

## 1. Topology: who owns what

```
Governance Safe (M-of-N)  ──queue/execute──▶  ImmutableTimelock (96h delay)  ──owns──▶  SumUSDEngine
                                                                              ──owns──▶  SumUSD token (DEFAULT_ADMIN_ROLE)
                                                                              ──owns──▶  MedianOracleAdapter
                                                                              ──owns──▶  ChainlinkOracleAdapter x2 (providers)

Guardian Safe (M-of-N)    ──────direct, instant──────▶  SumUSDEngine.freezeCollateral   (the one fast lever)
                          ──────direct, instant──────▶  ImmutableTimelock.cancel        (the veto)
```

- **Every** privileged change to the engine, token, or oracle adapters goes through the timelock:
  **queue it, wait the immutable delay (96h by default), then execute it.** There is no bypass.
- The **guardian** is the only fast path. It can call `freezeCollateral(token)` directly (no delay), and
  it is also the timelock's immutable **`CANCELLER`**: it can veto any queued operation, but can never
  queue or execute one. That is the lever a compromised governance Safe cannot strip — the delay alone
  gives holders notice, the veto gives defenders a response.
- **Queued operations expire.** A matured op is executable only within `[eta, eta + GRACE_PERIOD]`
  (14 days by default), then must be re-queued. Check `gov status <op> --salt <label>`.
- `renounceExecutor()` on the timelock is terminal. It is two-step: `initiateRenounce()`, wait the full
  delay (abortable with `abortRenounce()`), then `renounceExecutor()`.

There is intentionally **no global pause**: deposits and redemptions can never be halted wholesale, so
holders can always exit.

---

## 2. Prerequisites

Set these once for the `cast` snippets below (fill in your deployment's addresses):

```bash
export RPC=https://...                     # an archive/full node for the target chain
export TIMELOCK=0x...                      # ImmutableTimelock
export ENGINE=0x...                        # SumUSDEngine
export TOKEN=0x...                         # SumUSD
export MEDIAN=0x...                        # MedianOracleAdapter (the engine's oracle for each flavor)
export PROVIDER1=0x...                     # ChainlinkOracleAdapter (provider 1)
export PROVIDER2=0x...                     # ChainlinkOracleAdapter (provider 2)
export GOV_SAFE=0x...                      # governance Safe (the timelock executor)
export GUARDIAN_SAFE=0x...                 # guardian Safe
```

`cast` is from [Foundry](https://book.getfoundry.sh/). With the [`governance/`](./governance) toolkit you
do **not** need it for normal operation — the tool builds the calldata, proposes to the Safe Transaction
Service, and executes. Use `cast` (and the Safe app at `app.safe.global`) to independently verify what
the tool built, or as a fallback if the Transaction Service is unavailable.

---

## 3. The core pattern: queue → wait → execute

Every timelocked action is **two Safe transactions** against the `TIMELOCK`, separated by the delay.
Both carry the same three arguments: `target` (the contract being changed), `data` (the ABI-encoded
call to run on it), and `salt` (a unique `bytes32` tag).

### Step A — build the inner call (`data`)

The `data` is the call you ultimately want to run, e.g. `engine.setTiltSlopeBps(500)`:

```bash
DATA=$(cast calldata "setTiltSlopeBps(uint16)" 500)
```

### Step B — choose a salt

The salt makes each queued operation unique. **Use a fresh, descriptive salt per action, and reuse the
exact same salt for that action's `execute`.** A readable convention:

```bash
SALT=$(cast keccak "set-tilt-500-2026-07-20")
```

Two operations with identical `(target, data)` but different salts are distinct; queuing the same
`(target, data, salt)` twice while pending reverts `AlreadyQueued`.

### Step C — the two Safe transactions

Build the calldata for each; each is a Safe tx to `TIMELOCK` with `value = 0`:

```bash
# Transaction 1 (now): queue
cast calldata "queue(address,bytes,bytes32)"   $ENGINE $DATA $SALT

# Transaction 2 (after >= 96h): execute
cast calldata "execute(address,bytes,bytes32)" $ENGINE $DATA $SALT
```

In the Safe app, use **Transaction Builder** (or "New transaction → Contract interaction"): set the
`To` field to `$TIMELOCK`, pick `queue`/`execute`, and enter `$ENGINE`, the `data` hex, and the salt.
Collect the M signatures and execute. Then wait the delay and repeat for `execute`.

### Verify / cancel

```bash
# operation id, then its ready-at timestamp (0 = not queued)
ID=$(cast call $TIMELOCK "operationId(address,bytes,bytes32)(bytes32)" $ENGINE $DATA $SALT --rpc-url $RPC)
cast call $TIMELOCK "eta(bytes32)(uint256)" $ID --rpc-url $RPC     # execute allowed once block.timestamp >= this
cast call $TIMELOCK "GRACE_PERIOD()(uint256)" --rpc-url $RPC       # ...and only until eta + this

# to abort a queued op before it executes (Safe tx to TIMELOCK).
# Sendable from the governance Safe OR from the CANCELLER (the guardian Safe):
cast calldata "cancel(address,bytes,bytes32)" $ENGINE $DATA $SALT
```

With the toolkit: `npm run gov -- cancel <op> [args] --salt <label>` proposes from the governance Safe;
add `--safe $GUARDIAN_SAFE` to veto from the canceller instead.

---

## 4. Operation reference

Each entry gives the **target** and the **inner call** to put in `data` (Step A). Wrap it in
queue/execute per §3 unless marked otherwise.

### Post-deploy handoff (do this first)

| Action | Target | Inner call |
|---|---|---|
| Accept engine ownership | `$ENGINE` | `acceptOwnership()` |

`Deploy.s.sol` already grants the token admin to the timelock, renounces the deployer's, sets the
guardian, and deploys the oracle adapters owned by the timelock. It reads `GOVERNANCE`, `GUARDIAN`,
`DELAY` (default 96h), `GRACE` (default 14 days), and `CANCELLER` (defaults to `GUARDIAN`) from the
environment, and asserts the canceller landed. The **one** remaining step is accepting the two-step
engine ownership. Build `DATA=$(cast calldata "acceptOwnership()")` and run the
queue/execute cycle with `target = $ENGINE`.

### Collateral management (target `$ENGINE`)

| Action | Inner call |
|---|---|
| List / reconfigure a flavor | `setCollateral(address,bool,uint16,address)` — `(token, enabled, redeemRateBps, oracle)` |
| Enable / disable (incl. un-freeze) | `setCollateralEnabled(address,bool)` — `(token, enabled)` |
| Remove a retired flavor (disabled + zero balance) | `removeCollateral(address)` — `(token)` |
| Silo / un-silo a stuck flavor (backing exclusion) | `setCollateralBackingExcluded(address,bool)` — `(token, excluded)` |

`redeemRateBps` must be in `[9500, 10000]`; `oracle` is normally `$MEDIAN`. Example listing:

```bash
DATA=$(cast calldata "setCollateral(address,bool,uint16,address)" $TOKEN true 9900 $MEDIAN)
```

### Oracle configuration

Provider feeds (target `$PROVIDER1` / `$PROVIDER2`):

| Action | Inner call |
|---|---|
| Point a provider at a Chainlink feed | `setFeed(address,address,uint32,uint128)` — `(token, aggregator, maxStaleness, maxPriceWad)`. Ceiling only: a low answer is a depeg and is passed through, never rejected |
| Remove a provider feed | `removeFeed(address)` — `(token)` |
| Set the L2 sequencer uptime gate | `setSequencerFeed(address,uint32)` — `(uptimeFeed, gracePeriod)` |

Median sources (target `$MEDIAN`):

| Action | Inner call |
|---|---|
| Set the sources for a flavor | `setSources(address,address[],uint32,uint32)` — `(token, [provider1,provider2], minFresh, maxSpreadBps)` |
| Remove a flavor's sources | `removeSources(address)` — `(token)` |

At most **5** sources per flavor (`MAX_SOURCES`, lowered from 7): every source is a feed read multiplied
by every listed collateral on the engine's redemption path, so the cap is a direct multiplier on redeem
gas. A 3-of-5 quorum still fits. Two further points are policy, not code:

- **Sources must be genuinely independent.** Nothing on-chain stops `setSources` from pointing several
  providers at the *same* aggregator, which produces a median with a real quorum of one and would fail
  silently. Verify the resolved aggregators differ (`cast call $PROVIDERn "feeds(address)" $TOKEN`)
  before queueing, and monitor it after.
- **On any L2, set the sequencer gate.** After a sequencer outage the first blocks back replay a burst
  of feed updates carrying *fresh* timestamps, so `maxStaleness` alone accepts prices that reflect a
  market which moved without them. Reference: the network's canonical uptime feed, 1h grace. Leave it
  unset (`address(0)`) on mainnet.

```bash
# provider 1 -> Chainlink feed for TOKEN: 1h staleness, sane ceiling $1.10 (no floor: low = depeg, valued as-is)
DATA=$(cast calldata "setFeed(address,address,uint32,uint128)" \
  $TOKEN $AGGREGATOR 3600 1100000000000000000)

# median over both providers: quorum 1, 1% disagreement breaker
DATA=$(cast calldata "setSources(address,address[],uint32,uint32)" \
  $TOKEN "[$PROVIDER1,$PROVIDER2]" 1 100)
```

### Risk parameters (target `$ENGINE`)

| Action | Inner call | Rail |
|---|---|---|
| Set the tilt slope | `setTiltSlopeBps(uint16)` — `(slope)` | `<= 5000` |
| Set the redemption margin + split | `setRedeemMargin(uint16,uint16)` — `(totalBps, toRecipientBps)` | total `<= 5`, routed `<= total` |
| Set the margin recipient | `setMarginRecipient(address)` — `(recipient)` | `address(0)` = keep the routed part pooled |
| Set the stale-price fallback | `setStalePriceParams(uint32,uint16)` — `(graceSeconds, haircutBps)` | grace `<= 1 day`, haircut `<= 10000`; grace `0` disables |

The distress thresholds (`DISTRESS_ENTER_RATIO_BPS` 99%, `DISTRESS_EXIT_RATIO_BPS` 100.25%,
`DISTRESS_RECOVERY_DELAY` 6h) are **constants, not parameters** — governance cannot move the anti-run
gate in either direction. Read the live state with `distressed()`, `recoveryStartedAt()`,
`distressClearsAt()`, and `distressParams()`.

### Guardian & token roles (target `$ENGINE` / `$TOKEN`)

| Action | Target | Inner call |
|---|---|---|
| Change the guardian address | `$ENGINE` | `setGuardian(address)` — `(newGuardian)` |
| Grant `MINTER_ROLE` (e.g. a replacement engine) | `$TOKEN` | `grantRole(bytes32,address)` — `(keccak256("MINTER_ROLE"), account)` |
| Revoke a minter | `$TOKEN` | `revokeRole(bytes32,address)` |

`MINTER_ROLE = 0x9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4ceeef8d981c8956a6`.

### Guardian action — instant, NOT timelocked (target `$ENGINE`, from `$GUARDIAN_SAFE`)

| Action | Inner call |
|---|---|
| Freeze one collateral immediately | `freezeCollateral(address)` — `(token)` |

This is a single Safe tx from the **guardian** Safe (target `$ENGINE`, data = the `freezeCollateral`
call). No timelock, no queue/execute. Un-freezing is `setCollateralEnabled(token, true)` and takes the
slow timelocked path above.

### Keeper action — permissionless (anyone)

`refreshPrices()` / `refreshPrice(address)` on `$ENGINE` warm the stale-price cache.
`pokeDistress()` on `$ENGINE` syncs the distress latch: it is what starts and advances the recovery
countdown when the system is otherwise idle, so run it on a schedule while backing is anywhere near the
99% line. Run all of these from any address (a keeper bot), no Safe or timelock needed.

### Terminal — freeze governance forever (target `$TIMELOCK`)

Renouncing the executor makes all further changes impossible, **including re-pointing a deprecated
price feed** — which is the part of the system most likely to need maintenance. There is no undo. It is
deliberately two-step:

1. `initiateRenounce()` from the gov Safe (`gov direct initiate-renounce`) starts a publicly-visible
   countdown of one full `DELAY`.
2. `abortRenounce()` cancels it at any point during that window.
3. `renounceExecutor()` after the countdown completes it.

Only do this deliberately, against a verified-good configuration, and only if you accept that the oracle
layer can never be reconfigured again.

---

## 5. Checklists

### List a new collateral flavor (end to end)

1. Deploy/confirm the token's Chainlink aggregators exist on-chain.
2. Queue `PROVIDER1.setFeed(token, agg1, staleness, maxWad)` and `PROVIDER2.setFeed(token, agg2, ...)`.
3. Queue `MEDIAN.setSources(token, [PROVIDER1, PROVIDER2], minFresh, maxSpreadBps)`.
4. Queue `ENGINE.setCollateral(token, true, redeemRateBps, MEDIAN)`.
5. Wait 96h; execute all four, **within the 14-day grace window** (they can share the wait — queue them
   together, execute together). Past `eta + GRACE_PERIOD` they expire and must be re-queued.
6. Verify: `cast call $MEDIAN "getPriceWad(address)(uint256)" $token` returns ~`1e18`, and
   `cast call $ENGINE "collateralValueUsd(address)(uint256)" $token` reads sanely (0 until deposits).

### Retire a collateral flavor

1. Ensure it is enabled and let holders redeem it toward zero balance.
2. Queue + execute `ENGINE.setCollateralEnabled(token, false)`.
3. Once `balanceOf(engine)` is 0, queue + execute `ENGINE.removeCollateral(token)` to free the slot.

### Emergency: a collateral is misbehaving

- **Immediate:** guardian Safe sends `ENGINE.freezeCollateral(token)` (instant). Deposits of it stop; it
  drops from the tilt; it stays redeemable.
- **Follow-up (timelocked):** decide whether to un-freeze (`setCollateralEnabled(token, true)`), or, for
  a permanent problem, proceed to the de-back checklist.

### Permanent blacklist: silo a stuck flavor (backlog #7)

If an issuer permanently blacklists the engine so a flavor's balance is stuck:

1. (Optional, immediate) guardian Safe freezes it to stop new exposure.
2. Queue + execute `ENGINE.setCollateralBackingExcluded(token, true)`. This drops its value from
   backing and the tilt, so the ratio reflects only redeemable value, and it also makes the flavor
   **undepositable** (minting 1:1 against zero backing would dilute every holder). If that pushes
   backing below 99%, distress engages and holders exit fairly via `redeemMix` (the stuck slice stays
   pooled, shared equally). `rawCollateralValueUsd(token)` still shows the stranded value.
   Note that clearing distress afterwards needs a real recapitalization: backing must hold at/above
   100.25% for 6h (`donate` is the tool), and `pokeDistress()` advances the countdown.
3. If the blacklist ever lifts: queue + execute `setCollateralBackingExcluded(token, false)` to
   re-include it.

### Recover from distress

1. Confirm the latch: `cast call $ENGINE "distressed()(bool)"`. While set, single-flavor `redeem` and
   `redeemBatch` revert `UseRedeemMix`; holders exit pro-rata via `redeemMix`, which stays open
   throughout and needs no oracle.
2. Fix the cause: oracle recovery, or `donate(collateral, amount)` from anyone (permissionless, mints no
   SumUSD, purely additive to backing).
3. Backing must reach **100.25%**, not just 99%. The gap is deliberate: a par redemption at a rate equal
   to the current ratio is ratio-neutral, so re-crossing a bare 99% line once would unlock an unlimited
   cherry-picking drain that never re-trips the gate.
4. Call `pokeDistress()` (anyone) to start the countdown, then again after 6h to clear the latch. Any
   reading below 100.25% in between restarts the clock. `distressClearsAt()` publishes the target time.

### Rotate governance signers

Signer changes happen **inside the Safe**, not on the timelock (both the executor and the canceller
addresses are immutable).
From the governance Safe: `addOwnerWithThreshold(newOwner, newThreshold)`, `removeOwner(...)`, or
`changeThreshold(...)`. This is how a 1-of-1 launch Safe becomes, say, 3-of-5 without any protocol
migration.

---

## 6. Good practice

- **Dry-run on a testnet or Base first:** create the Safes, deploy pointing at them, and push one full
  `queue → wait → execute` cycle before touching mainnet.
- **Announce queued operations.** The 96h delay exists to give holders an exit window; make queued
  changes publicly visible (the timelock emits `Queued(id, target, data, eta)`).
- **Batch the wait.** Independent changes can be queued together and executed together after one delay.
- **Double-check `data` and `salt`** before executing: recompute the `operationId` and confirm its `eta`
  matches what you queued.
- **Keep the guardian Safe responsive** (smaller threshold), since its only value is speed.
