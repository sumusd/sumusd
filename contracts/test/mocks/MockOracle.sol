// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";

/// @notice Settable in-memory price oracle for tests. Prices are 18-decimal WADs.
contract MockOracle is IPriceOracle {
    mapping(address token => uint256 priceWad) public prices;

    function setPrice(address token, uint256 priceWad) external {
        prices[token] = priceWad;
    }

    function getPriceWad(address token) external view returns (uint256) {
        uint256 p = prices[token];
        require(p != 0, "MockOracle: no price");
        return p;
    }
}
