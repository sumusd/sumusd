// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mintable ERC-20 whose `balanceOf` can be switched to revert AFTER listing — models a
///         collateral that passes the listing probe and later breaks (e.g. an upgradeable token whose
///         implementation is bricked). Used to prove no single listed flavor can brick the basket loops
///         or the pro-rata distress exit.
contract ToggleBalanceMockERC20 is ERC20 {
    uint8 private immutable _decimals;
    bool public balanceReverts;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBalanceReverts(bool v) external {
        balanceReverts = v;
    }

    function balanceOf(address account) public view override returns (uint256) {
        require(!balanceReverts, "balanceOf bricked");
        return super.balanceOf(account);
    }
}
