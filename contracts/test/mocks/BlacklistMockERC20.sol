// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mintable ERC-20 whose transfers can be toggled to revert, to simulate an issuer that has
///         blacklisted the holder (e.g. a custodial stablecoin freezing the engine address).
contract BlacklistMockERC20 is ERC20 {
    uint8 private immutable _decimals;
    bool public blocked;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(bool b) external {
        blocked = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked, "BlacklistMockERC20: blocked");
        super._update(from, to, value);
    }
}
