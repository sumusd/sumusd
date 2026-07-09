// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console2} from "forge-std/Script.sol";
import {SumUSD} from "../src/SumUSD.sol";
import {SumUSDEngine} from "../src/SumUSDEngine.sol";
import {ImmutableTimelock} from "../src/ImmutableTimelock.sol";

/// @notice Deploys the SumUSD token, engine, and an {ImmutableTimelock} (96h immutable delay), wires
///         the engine as the sole minter, and hands engine ownership to the timelock so that all
///         future parameter changes must clear the delay.
///
/// @dev Collateral listing (`setCollateral`) is intentionally a follow-up governance action so
///      production token/oracle addresses are not hardcoded here. Ownership transfer is two-step
///      (`Ownable2Step`): this script *offers* ownership to the timelock; the GOVERNANCE multisig
///      must then complete it by queuing `acceptOwnership()` on the engine through the timelock and
///      executing it after the delay. After that the deployer EOA has no power over the engine.
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
contract Deploy is Script {
    function run() external returns (SumUSD sumUsd, SumUSDEngine engine, ImmutableTimelock timelock) {
        address governance = vm.envOr("GOVERNANCE", msg.sender);
        address guardian = vm.envOr("GUARDIAN", msg.sender);
        uint256 delay = vm.envOr("DELAY", uint256(96 hours));

        vm.startBroadcast();
        address deployer = msg.sender;

        timelock = new ImmutableTimelock(delay, governance);
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
        vm.stopBroadcast();

        // Fail the deploy loudly if the mint authority did not end up fully behind the timelock.
        require(!sumUsd.hasRole(adminRole, deployer), "Deploy: deployer still token admin");
        require(sumUsd.hasRole(adminRole, address(timelock)), "Deploy: timelock not token admin");
        require(sumUsd.hasRole(sumUsd.MINTER_ROLE(), address(engine)), "Deploy: engine not minter");

        console2.log("SumUSD:           ", address(sumUsd));
        console2.log("SumUSDEngine:     ", address(engine));
        console2.log("ImmutableTimelock:", address(timelock));
        console2.log("Timelock executor:", governance);
        console2.log("Guardian:         ", guardian);
        console2.log("Timelock delay(s):", delay);
        console2.log("");
        console2.log("Token admin (mint authority): now the timelock; deployer renounced.");
        console2.log("Next: governance queues+executes engine.acceptOwnership() via the timelock");
        console2.log("to complete the ownership hand-off.");
    }
}
