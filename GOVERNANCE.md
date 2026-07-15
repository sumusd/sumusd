# SumUSD Governance Runbook

Operational guide for the signers who administer a deployed SumUSD instance. It covers the exact
transactions to build for every privileged action, and end-to-end checklists for the common jobs.

Read [WHITEPAPER.md](./WHITEPAPER.md) §9 for the design rationale; this document is the how-to.

---

## 1. Topology: who owns what

```
Governance Safe (M-of-N)  ──queue/execute──▶  ImmutableTimelock (96h delay)  ──owns──▶  SumUSDEngine
                                                                              ──owns──▶  SumUSD token (DEFAULT_ADMIN_ROLE)
                                                                              ──owns──▶  MedianOracleAdapter
                                                                              ──owns──▶  ChainlinkOracleAdapter x2 (providers)

Guardian Safe (M-of-N)    ──────direct, instant──────▶  SumUSDEngine.freezeCollateral   (the one fast lever)
```

- **Every** privileged change to the engine, token, or oracle adapters goes through the timelock:
  **queue it, wait the immutable delay (96h by default), then execute it.** There is no bypass.
- The **guardian** is the only fast path. It can call `freezeCollateral(token)` directly (no delay), and
  nothing else.
- `renounceExecutor()` on the timelock is terminal: it freezes every parameter forever.

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

`cast` is from [Foundry](https://book.getfoundry.sh/). You only need it to *build calldata* and *read
state*; the transactions themselves are proposed, signed, and executed from the Safe app
(`app.safe.global`).

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

# to abort a queued op before it executes (Safe tx to TIMELOCK):
cast calldata "cancel(address,bytes,bytes32)" $ENGINE $DATA $SALT
```

---

## 4. Operation reference

Each entry gives the **target** and the **inner call** to put in `data` (Step A). Wrap it in
queue/execute per §3 unless marked otherwise.

### Post-deploy handoff (do this first)

| Action | Target | Inner call |
|---|---|---|
| Accept engine ownership | `$ENGINE` | `acceptOwnership()` |

`Deploy.s.sol` already grants the token admin to the timelock, renounces the deployer's, sets the
guardian, and deploys the oracle adapters owned by the timelock. The **one** remaining step is
accepting the two-step engine ownership. Build `DATA=$(cast calldata "acceptOwnership()")` and run the
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
| Point a provider at a Chainlink feed | `setFeed(address,address,uint32,uint128,uint128)` — `(token, aggregator, maxStaleness, minPriceWad, maxPriceWad)` |
| Remove a provider feed | `removeFeed(address)` — `(token)` |

Median sources (target `$MEDIAN`):

| Action | Inner call |
|---|---|
| Set the sources for a flavor | `setSources(address,address[],uint32,uint32)` — `(token, [provider1,provider2], minFresh, maxSpreadBps)` |
| Remove a flavor's sources | `removeSources(address)` — `(token)` |

```bash
# provider 1 -> Chainlink feed for TOKEN: 1h staleness, sane band [$0.90, $1.10]
DATA=$(cast calldata "setFeed(address,address,uint32,uint128,uint128)" \
  $TOKEN $AGGREGATOR 3600 900000000000000000 1100000000000000000)

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

`refreshPrices()` / `refreshPrice(address)` on `$ENGINE` warm the stale-price cache. Run these from any
address (a keeper bot), no Safe or timelock needed.

### Terminal — freeze governance forever (target `$TIMELOCK`)

`renounceExecutor()` on the timelock, once executed, makes all further changes impossible. There is no
undo. Only do this deliberately, against a verified-good configuration.

---

## 5. Checklists

### List a new collateral flavor (end to end)

1. Deploy/confirm the token's Chainlink aggregators exist on-chain.
2. Queue `PROVIDER1.setFeed(token, agg1, staleness, min, max)` and `PROVIDER2.setFeed(token, agg2, ...)`.
3. Queue `MEDIAN.setSources(token, [PROVIDER1, PROVIDER2], minFresh, maxSpreadBps)`.
4. Queue `ENGINE.setCollateral(token, true, redeemRateBps, MEDIAN)`.
5. Wait 96h; execute all four. (They can share the wait — queue them together, execute together.)
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
   backing and the tilt, so the ratio reflects only redeemable value. If that pushes backing below 99%,
   distress engages and holders exit fairly via `redeemMix` (the stuck slice stays pooled, shared
   equally). `rawCollateralValueUsd(token)` still shows the stranded value.
3. If the blacklist ever lifts: queue + execute `setCollateralBackingExcluded(token, false)` to
   re-include it.

### Rotate governance signers

Signer changes happen **inside the Safe**, not on the timelock (the executor address is immutable).
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
