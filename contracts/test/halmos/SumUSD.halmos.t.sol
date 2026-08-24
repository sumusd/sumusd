// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SumUSD} from "../../src/SumUSD.sol";

/// @notice Symbolic (halmos) properties of the {SumUSD} token: supply can only move through MINTER_ROLE.
contract SumUSDHalmos is Test {
    SumUSD internal sumUsd;
    address internal admin = address(0xAD);
    address internal minter = address(0x1111);
    address internal holder = address(0x2222);

    function setUp() public {
        sumUsd = new SumUSD(admin);
        bytes32 minterRole = sumUsd.MINTER_ROLE(); // read first: the view call would otherwise consume the prank
        vm.prank(admin);
        sumUsd.grantRole(minterRole, minter);
        vm.prank(minter);
        sumUsd.mint(holder, 1_000e18);
    }

    /// @dev Nobody but a minter can mint, to any recipient, for any amount.
    function check_mint_requiresMinterRole(address caller, address to, uint256 amount) public {
        vm.assume(caller != minter);
        vm.prank(caller);
        (bool ok,) = address(sumUsd).call(abi.encodeCall(sumUsd.mint, (to, amount)));
        assertFalse(ok);
        assertEq(sumUsd.totalSupply(), 1_000e18);
    }

    /// @dev Nobody but a minter can burn, from any account, for any amount (no allowance path exists).
    function check_burn_requiresMinterRole(address caller, address from, uint256 amount) public {
        vm.assume(caller != minter);
        vm.prank(caller);
        (bool ok,) = address(sumUsd).call(abi.encodeCall(sumUsd.burn, (from, amount)));
        assertFalse(ok);
        assertEq(sumUsd.balanceOf(holder), 1_000e18);
    }

    /// @dev Mint authority cannot be self-granted: nobody but the admin can hand out MINTER_ROLE, to
    ///      anyone — the escalation path from "any address" to "can mint" does not exist.
    function check_grantMinterRole_requiresAdmin(address caller, address to) public {
        vm.assume(caller != admin);
        bytes32 minterRole = sumUsd.MINTER_ROLE();
        vm.prank(caller);
        (bool ok,) = address(sumUsd).call(abi.encodeCall(sumUsd.grantRole, (minterRole, to)));
        assertFalse(ok);
        if (to != minter) assertFalse(sumUsd.hasRole(minterRole, to));
    }
}
