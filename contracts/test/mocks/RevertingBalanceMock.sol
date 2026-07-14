// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @notice A token that implements `decimals()` but reverts on `balanceOf` — a non-conforming ERC-20
///         used to exercise the {SumUSDEngine} listing conformance probe.
contract RevertingBalanceMock {
    function decimals() external pure returns (uint8) {
        return 6;
    }

    function balanceOf(address) external pure returns (uint256) {
        revert("balanceOf reverts");
    }
}
