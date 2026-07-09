// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title SumUSD
/// @notice The aggregated USD stablecoin. Supply is fully controlled by holders of
///         `MINTER_ROLE` — in production this is the {SumUSDEngine}, which only mints
///         against deposited collateral and only burns on redemption.
/// @dev 18-decimal ERC-20 with EIP-2612 permit. This contract deliberately holds no
///      collateral logic; backing and over-collateralization are enforced by the engine.
contract SumUSD is ERC20, ERC20Permit, AccessControl {
    /// @notice Role allowed to mint and burn SumUSD. Granted to the engine.
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @param admin Address that receives DEFAULT_ADMIN_ROLE (manages minters).
    constructor(address admin) ERC20("SumUSD", "sumUSD") ERC20Permit("SumUSD") {
        require(admin != address(0), "SumUSD: admin=0");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Mint `amount` SumUSD to `to`. Restricted to the engine.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /// @notice Burn `amount` SumUSD from `from`. Restricted to the engine.
    /// @dev The engine burns the redeemer's balance directly; no allowance is required
    ///      because the engine is a trusted, role-gated minter rather than a third party.
    function burn(address from, uint256 amount) external onlyRole(MINTER_ROLE) {
        _burn(from, amount);
    }
}
