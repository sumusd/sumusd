// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Mintable ERC-20 that can be switched, AFTER listing, into a hostile token: `transfer` and/or
///         `balanceOf` either burn every unit of gas forwarded to them (gas bomb) or return megabytes of
///         data (return-data bomb). Models a whitelisted collateral whose proxy is taken over. Used to prove
///         the engine's non-reverting helpers bound what one hostile flavor can cost the rest of the basket.
contract BombMockERC20 is ERC20 {
    uint8 private immutable _decimals;
    bool public gasBombTransfer;
    bool public gasBombBalance;
    bool public dataBombTransfer;
    bool public dataBombBalance;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(bool gasT, bool gasB, bool dataT, bool dataB) external {
        gasBombTransfer = gasT;
        gasBombBalance = gasB;
        dataBombTransfer = dataT;
        dataBombBalance = dataB;
    }

    function _burnAllGas() internal pure {
        uint256 x;
        while (true) {
            x = uint256(keccak256(abi.encode(x)));
        }
    }

    /// @dev Return ~1 MB of data. The caller pays quadratic memory expansion if it copies it all.
    function _dataBomb() internal pure {
        assembly {
            return(0, 0x100000)
        }
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (gasBombTransfer) _burnAllGas();
        if (dataBombTransfer) _dataBomb();
        return super.transfer(to, amount);
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (gasBombBalance) _burnAllGas();
        if (dataBombBalance) _dataBomb();
        return super.balanceOf(account);
    }
}
