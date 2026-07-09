// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mintable ERC-20 that blocks transfers to one configurable address, simulating a fee
///         recipient (treasury) an issuer has blacklisted. Used to prove the redemption fee routing is
///         best-effort: a recipient that can't receive is skipped, never blocking the redemption.
contract RecipientBlockMockERC20 is ERC20 {
    uint8 private immutable _decimals;
    address public blockedTo;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlockedTo(address a) external {
        blockedTo = a;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(to != blockedTo, "RecipientBlockMockERC20: recipient blocked");
        super._update(from, to, value);
    }
}
