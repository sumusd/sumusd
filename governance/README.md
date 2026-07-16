# SumUSD governance — Safe multisig tooling (API-driven)

Scripts that drive SumUSD governance entirely through the **Safe{Core} SDK** and the **Safe Transaction
Service API** — no web UI. They deploy the Safes, and propose / confirm / execute every privileged
operation (all of which flow through the `ImmutableTimelock`, except the guardian freeze and the terminal
`renounceExecutor`).

This is the executable companion to [`../GOVERNANCE.md`](../GOVERNANCE.md), which explains the topology
and the meaning of each operation. Read that first.

```
Governance Safe (M-of-N) ──queue/execute──▶ ImmutableTimelock (96h) ──owns──▶ Engine / Token / Oracles
Guardian Safe (M-of-N)   ──────direct──────▶ Engine.freezeCollateral   (the one fast lever)
```

## Setup

```bash
cd governance
npm ci
cp .env.example .env      # fill in RPC_URL, CHAIN_ID, SIGNER_KEY, SAFE_API_KEY, the Safes, and addresses
```

- `SIGNER_KEY` is the owner running the command; it must be one of the Safe's owners.
- `SAFE_API_KEY` is a Safe Transaction Service key ([developer.safe.global](https://developer.safe.global)).
  For a self-hosted service, set `SAFE_TX_SERVICE_URL` instead.

All commands are `npm run gov -- <command> …`. Run `npm run gov -- help` for the full command +
operation catalogue.

## The lifecycle of one change

A timelocked change is: **queue → (owners confirm) → execute the queue tx → wait ≥ 96h → execute →
(owners confirm) → execute the execute tx.** Each timelock step is itself an M-of-N Safe transaction.

```bash
# 1. An owner proposes the QUEUE (wrapped as gov Safe -> timelock.queue(engine, setTiltSlopeBps(500), salt))
npm run gov -- queue set-tilt 500 --salt set-tilt-500-2026-07-20
#   -> prints a safeTxHash

# 2. The other owners add their confirmations
npm run gov -- confirm <safeTxHash>

# 3. Any owner executes the (now fully-signed) Safe tx on-chain
npm run gov -- exec <safeTxHash>

# 4. Watch the timelock until the delay elapses
npm run gov -- status set-tilt 500 --salt set-tilt-500-2026-07-20

# 5. After >= 96h, repeat the propose/confirm/exec cycle for EXECUTE (reuse the exact same salt)
npm run gov -- execute set-tilt 500 --salt set-tilt-500-2026-07-20
npm run gov -- confirm <safeTxHash>
npm run gov -- exec <safeTxHash>
```

`--salt` is a unique, human-readable label (hashed to `bytes32`, matching `cast keccak "<label>"`); a raw
`0x…` 32-byte value is also accepted. **Reuse the same salt for a given action's `queue`, `execute`, and
`cancel`.** Independent changes can be queued together and executed together after one wait.

## Deploying the Safes

```bash
# Governance Safe (start 1-of-1 for launch, then rotate owners inside the Safe later)
npm run gov -- deploy-safe --owners 0xAlice --threshold 1
# Guardian Safe (keep the threshold low for speed)
npm run gov -- deploy-safe --owners 0xAlice,0xBob --threshold 1
```

Deploy the protocol (`Deploy.s.sol`) pointing the timelock's executor at the governance Safe and the
engine guardian at the guardian Safe. The first governance action is `accept-ownership` (the two-step
engine handover).

## Direct (non-timelocked) operations

```bash
# Guardian instant freeze (from the guardian Safe)
npm run gov -- direct freeze <token>            # --safe defaults to the guardian Safe

# Terminal: renounce the executor (from the gov Safe) — freezes all parameters forever
npm run gov -- direct renounce-executor
```

## Other commands

```bash
npm run gov -- cancel set-tilt 500 --salt <label>   # abort a queued op before it executes
npm run gov -- list                                 # pending Safe txs + confirmation progress
npm run gov -- encode set-collateral <token> true 9900   # print target + calldata (no proposal)
```

Rotating signers is done **inside the Safe** (the timelock executor is immutable): propose a direct Safe
tx calling `addOwnerWithThreshold` / `removeOwner` / `changeThreshold` on the Safe itself. (Encode that
calldata with `cast` and use `direct` with an explicit `--to`/raw path, or the Safe SDK owner-management
helpers.)

## Verify calldata before signing

Every command prints the human-readable operation and, for `encode`/`status`, the exact target + data.
Cross-check against `cast`:

```bash
cast calldata "setTiltSlopeBps(uint16)" 500      # compare to `gov encode set-tilt 500`
```

## Notes / safety

- **Dry-run on a testnet or Base first** — deploy the Safes, wire a deployment to them, and push one full
  `queue → wait → execute` cycle before mainnet.
- The 96h delay is the holder exit window; **announce queued operations** (the timelock emits
  `Queued(id, target, data, eta)`).
- The Transaction Service is off-chain coordination only; the on-chain authority is the Safe + timelock.
  If the service is unavailable you can still execute via the Safe SDK / the Safe app as a fallback.
- Keep `.env` (and any key) out of version control; it is gitignored.
