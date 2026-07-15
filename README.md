# SumUSD

**An over-collateralized, aggregated USD stablecoin.**

SumUSD is a pooled peg-stability module over a governance-curated basket of credible,
GENIUS-Act-compliant USD stablecoins ("flavors"). Deposit any whitelisted flavor and mint a single
fungible dollar token, **SumUSD**, at a raw 1:1 unit rate; burn SumUSD to redeem any flavor the pool
currently holds. The protocol becomes and stays over-collateralized through a redemption haircut
rather than a deposit-side collateral requirement.

This repository holds the protocol — the Solidity contracts and the specification. The mint/redeem
web app lives in a separate repo: **[sumusd/website](https://github.com/sumusd/website)**.

## How it works (in brief)

- **Mint is a raw 1:1 unit swap.** One unit of any accepted flavor mints exactly one SumUSD,
  independent of the oracle price, so all flavors are forced to be fungible $1 units. A ±0.5% deposit
  peg band rejects materially off-peg collateral.
- **Redemption carries the risk pricing.** Burning SumUSD returns a chosen flavor at par minus a
  **convex weight-tilted haircut**: redeeming an over-represented flavor is cheaper, and draining a
  scarce one gets steeply more expensive (self-defeating, but never blocked). The haircut stays in
  the pool, so mark-to-market backing trends above 100% over time — the source of
  over-collateralization.
- **Anti-run distress mode.** Below 99% backing, single-flavor redemption is disabled in favor of
  `redeemMix`, a pro-rata claim on the whole basket that shares any shortfall equally across holders.
- **Minimal, slow governance.** There is no global pause. Parameters are owned by an
  `ImmutableTimelock` (96h delay), leaving holders a guaranteed exit window; the one fast lever is a
  `guardian` that can freeze a single misbehaving collateral. The core safety rails (peg band, mint
  floor, redeem-rate / tilt / margin caps) are immutable with no setter.
- **Small redemption margin.** 2 bps on single-flavor redemption (immutably capped, timelock-set): 1 bp
  is retained as backing and 1 bp is routed to a governance-set recipient. The distress exit is exempt.

See **[WHITEPAPER.md](./WHITEPAPER.md)** for the full design and rationale, and **[CLAUDE.md](./CLAUDE.md)**
for a contributor-oriented map of the code and conventions.

## Layout

```
contracts/        Foundry project — the protocol
  src/            SumUSD.sol, SumUSDEngine.sol, ImmutableTimelock.sol, oracles/, interfaces/
  script/         Deploy + testnet/local bring-up scripts
  test/           Foundry test suite
WHITEPAPER.md     Protocol specification
GOVERNANCE.md     Signer runbook (timelock queue/execute, per-op calldata, checklists)
CLAUDE.md         Codebase guide / conventions
```

## Contracts

Requires [Foundry](https://book.getfoundry.sh/). `solc` is pinned to **0.8.34**; dependencies are
vendored under `contracts/lib/` (plain files, not submodules).

```bash
cd contracts
forge build         # compile
forge test          # run the test suite
forge fmt           # format
```

Deploy the core (token + engine + timelock, wired and ownership handed to the timelock):

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```

Collateral listing, oracle wiring, and the tilt/margin parameters are deliberate follow-up governance
actions (not hardcoded in the core deploy). `script/SetupSepolia.s.sol` and `script/SetupLocal.s.sol`
bring up the full stack against a testnet or a local `anvil` for development.

## Status

Unaudited. Do not use in production without an independent security review. The collateral tokens
and price feeds used in the setup scripts are mocks, for testnets only.

## License

Business Source License 1.1 (BUSL-1.1) — see [LICENSE](./LICENSE). Non-commercial use is permitted;
commercial use requires a separate license from the Licensor. The license converts to **MIT** on the
Change Date (2032-07-04). Third-party code under `contracts/lib/`
(OpenZeppelin, forge-std) remains under its own MIT license.
