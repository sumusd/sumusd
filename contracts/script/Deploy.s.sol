// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {SumUSD} from "../src/SumUSD.sol";
import {SumUSDEngine} from "../src/SumUSDEngine.sol";
import {ImmutableTimelock} from "../src/ImmutableTimelock.sol";
import {ChainlinkOracleAdapter} from "../src/oracles/ChainlinkOracleAdapter.sol";
import {MedianOracleAdapter} from "../src/oracles/MedianOracleAdapter.sol";

/// @notice Deploys the SumUSD token, engine, an {ImmutableTimelock} (96h immutable delay), and the
///         oracle stack (a {MedianOracleAdapter} over two {ChainlinkOracleAdapter} providers), wires
///         the engine as the sole minter, and hands engine + oracle ownership to the timelock so that
///         all future parameter changes must clear the delay.
///
/// @dev Collateral listing (`setCollateral`) and oracle feed/source configuration are intentionally
///      follow-up governance actions so production token/feed addresses are not hardcoded here.
///      Engine ownership transfer is two-step (`Ownable2Step`): this script *offers* ownership to the
///      timelock; the GOVERNANCE multisig must then complete it by queuing `acceptOwnership()` on the
///      engine through the timelock and executing it after the delay. After that the deployer EOA has
///      no power over the engine.
///
///      Oracle ownership: the oracle adapters are deployed OWNED BY THE TIMELOCK FROM CONSTRUCTION
///      (their `Ownable` initial owner is the timelock), so the deployer EOA never controls them. An
///      un-timelocked oracle owner could reprice collateral or swap feeds instantly — as dangerous as
///      an un-timelocked mint key — so, like the token admin, feed/source config is timelocked from
///      block one. Governance configures `setFeed`/`setSources` and lists collateral through the
///      timelock afterward. (Asserted below.)
///
///      Token admin (mint authority): `SumUSD.DEFAULT_ADMIN_ROLE` controls who holds `MINTER_ROLE`,
///      i.e. who can mint SumUSD out of thin air. Leaving it on the deployer EOA would be an
///      un-timelocked god-mode mint key that bypasses every engine safety rail, so this script hands
///      that role to the timelock and renounces the deployer's copy IN THE SAME BROADCAST. After
///      this, changing the minter set is possible only through the timelock (queued + delayed, giving
///      holders an exit window) and never via a hot EOA. The transfer is atomic here (single-key
///      broadcast); a multisig-controlled deploy should verify the same end state (asserted below).
///
/// Usage:
///   forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
///
/// Env:
///   GOVERNANCE — the timelock executor (a multisig). Defaults to the broadcaster (dev only).
///   GUARDIAN   — fast brake that can freeze a single collateral. Defaults to the broadcaster.
///   DELAY      — timelock delay in seconds (default 345600 = 96h).
///   GRACE      — how long a matured timelock operation stays executable, in seconds (default 14 days).
///   CANCELLER  — cancel-only veto on queued timelock operations. Defaults to GUARDIAN, so the fast
///                multisig can veto a compromised executor's proposal inside the delay window.
contract Deploy is Script {
    function run()
        external
        returns (
            SumUSD sumUsd,
            SumUSDEngine engine,
            ImmutableTimelock timelock,
            MedianOracleAdapter oracle,
            ChainlinkOracleAdapter provider1,
            ChainlinkOracleAdapter provider2
        )
    {
        address governance = vm.envOr("GOVERNANCE", msg.sender);
        address guardian = vm.envOr("GUARDIAN", msg.sender);
        uint256 delay = vm.envOr("DELAY", uint256(96 hours));
        uint256 grace = vm.envOr("GRACE", uint256(14 days));
        address canceller = vm.envOr("CANCELLER", guardian);

        vm.startBroadcast();
        address deployer = msg.sender;

        timelock = new ImmutableTimelock(delay, grace, governance, canceller);
        sumUsd = new SumUSD(deployer); // deployer is temporary token admin; handed to the timelock below
        engine = new SumUSDEngine(deployer, sumUsd);
        sumUsd.grantRole(sumUsd.MINTER_ROLE(), address(engine));

        // Move mint authority behind the timelock: grant token admin to the timelock, then renounce
        // the deployer's copy so no hot EOA can ever grant itself MINTER_ROLE and mint unbacked SumUSD.
        bytes32 adminRole = sumUsd.DEFAULT_ADMIN_ROLE();
        sumUsd.grantRole(adminRole, address(timelock));
        sumUsd.renounceRole(adminRole, deployer);

        // Set the guardian while the deployer is still owner, then offer ownership to the timelock;
        // governance completes the hand-off via acceptOwnership() after the delay.
        engine.setGuardian(guardian);
        engine.transferOwnership(address(timelock));

        // Oracle stack, owned by the timelock from construction (the deployer never controls it), so
        // feed/source configuration is timelocked from block one. Two Chainlink providers under a
        // median; governance wires setFeed/setSources and lists collateral afterward via the timelock.
        provider1 = new ChainlinkOracleAdapter(address(timelock));
        provider2 = new ChainlinkOracleAdapter(address(timelock));
        oracle = new MedianOracleAdapter(address(timelock));
        vm.stopBroadcast();

        // Fail the deploy loudly if the mint authority or the oracle owners did not end up behind the
        // timelock.
        require(!sumUsd.hasRole(adminRole, deployer), "Deploy: deployer still token admin");
        require(timelock.CANCELLER() == canceller, "Deploy: timelock canceller not set");
        require(sumUsd.hasRole(adminRole, address(timelock)), "Deploy: timelock not token admin");
        require(sumUsd.hasRole(sumUsd.MINTER_ROLE(), address(engine)), "Deploy: engine not minter");
        require(oracle.owner() == address(timelock), "Deploy: median oracle not timelock-owned");
        require(provider1.owner() == address(timelock), "Deploy: provider1 not timelock-owned");
        require(provider2.owner() == address(timelock), "Deploy: provider2 not timelock-owned");

        console2.log("SumUSD:           ", address(sumUsd));
        console2.log("SumUSDEngine:     ", address(engine));
        console2.log("ImmutableTimelock:", address(timelock));
        console2.log("MedianOracle:     ", address(oracle));
        console2.log("Provider1 (CL):   ", address(provider1));
        console2.log("Provider2 (CL):   ", address(provider2));
        console2.log("Timelock executor:", governance);
        console2.log("Guardian:         ", guardian);
        console2.log("Timelock delay(s):", delay);
        console2.log("");
        console2.log("Token admin + all oracle adapters: now the timelock; deployer renounced.");
        console2.log("Next (all via the timelock): engine.acceptOwnership(); provider setFeed(s);");
        console2.log("median setSources; then engine.setCollateral per flavor.");
    }
}
