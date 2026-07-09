// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SumUSD} from "../src/SumUSD.sol";
import {SumUSDEngine} from "../src/SumUSDEngine.sol";
import {ImmutableTimelock} from "../src/ImmutableTimelock.sol";

/// @notice Regression cover for the "un-timelocked god-mode mint key" finding. This mirrors the exact
///         role wiring in `Deploy.s.sol` (grant token admin to the timelock, then renounce the
///         deployer's copy) and asserts the security-critical end state: after deploy, mint authority
///         lives only behind the timelock and no EOA can grant itself MINTER_ROLE.
///
/// @dev We replicate the wiring rather than invoking `Deploy.run()` directly because that script
///      reads `msg.sender` after `vm.startBroadcast()`; under `forge test` the broadcast sender and
///      the direct `msg.sender` read diverge and pranking conflicts with broadcasting, so a direct
///      invocation cannot reproduce the production sender. The steps below are byte-for-byte the same
///      role operations the script performs; if the script's wiring regresses, this test still pins
///      the invariant it must satisfy.
contract DeployTest is Test {
    SumUSD internal sumUsd;
    SumUSDEngine internal engine;
    ImmutableTimelock internal timelock;

    address internal deployer = makeAddr("deployer");
    address internal governance = makeAddr("governance");
    address internal guardian = makeAddr("guardian");

    bytes32 internal adminRole;
    bytes32 internal minterRole;

    function setUp() public {
        vm.startPrank(deployer);
        // --- mirrors Deploy.s.sol -----------------------------------------------------------------
        timelock = new ImmutableTimelock(96 hours, governance);
        sumUsd = new SumUSD(deployer);
        engine = new SumUSDEngine(deployer, sumUsd);
        sumUsd.grantRole(sumUsd.MINTER_ROLE(), address(engine));

        adminRole = sumUsd.DEFAULT_ADMIN_ROLE();
        sumUsd.grantRole(adminRole, address(timelock));
        sumUsd.renounceRole(adminRole, deployer);

        engine.setGuardian(guardian);
        engine.transferOwnership(address(timelock));
        // ------------------------------------------------------------------------------------------
        vm.stopPrank();

        minterRole = sumUsd.MINTER_ROLE();
    }

    function test_Deploy_TimelockIsTokenAdmin() public view {
        assertTrue(sumUsd.hasRole(adminRole, address(timelock)), "timelock not token admin");
    }

    function test_Deploy_DeployerRenouncedTokenAdmin() public view {
        assertFalse(sumUsd.hasRole(adminRole, deployer), "deployer retained token admin");
    }

    function test_Deploy_EngineIsMinter() public view {
        assertTrue(sumUsd.hasRole(minterRole, address(engine)), "engine is not a minter");
    }

    function test_Deploy_EngineOwnershipOfferedToTimelock() public view {
        // Two-step transfer: the deployer is still owner until the timelock accepts, but the pending
        // owner must be the timelock so governance can complete the hand-off.
        assertEq(engine.pendingOwner(), address(timelock), "timelock not pending owner");
    }

    /// @dev The core property: no EOA can grant itself MINTER_ROLE post-deploy, so no hot key can mint
    ///      unbacked SumUSD. Only the timelock (which holds DEFAULT_ADMIN_ROLE) can, and only through
    ///      its delayed queue/execute path.
    function test_Deploy_NoEoaCanGrantMinter() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        sumUsd.grantRole(minterRole, attacker);

        // The former deployer is equally powerless now.
        vm.prank(deployer);
        vm.expectRevert();
        sumUsd.grantRole(minterRole, deployer);
    }

    /// @dev The timelock CAN still manage minters, but only as its executor via queue -> wait -> execute.
    function test_Deploy_TimelockCanGrantMinterOnlyAfterDelay() public {
        address newMinter = makeAddr("newMinter");
        bytes memory data = abi.encodeCall(sumUsd.grantRole, (minterRole, newMinter));
        bytes32 salt = bytes32(0);

        vm.startPrank(governance);
        timelock.queue(address(sumUsd), data, salt);
        // Cannot execute before the delay elapses.
        vm.expectRevert(ImmutableTimelock.NotReady.selector);
        timelock.execute(address(sumUsd), data, salt);

        vm.warp(block.timestamp + 96 hours);
        timelock.execute(address(sumUsd), data, salt);
        vm.stopPrank();

        assertTrue(sumUsd.hasRole(minterRole, newMinter), "timelock could not grant minter after delay");
    }
}
