// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title IPriceOracle
/// @notice Minimal USD price feed used by the SumUSD engine to value collateral.
/// @dev Prices are quoted in USD and scaled to 18 decimals (a WAD): `1e18` means $1.00.
///      Implementations should wrap a production feed (e.g. Chainlink) and normalise
///      its answer to 18 decimals, reverting on stale or invalid rounds.
interface IPriceOracle {
    /// @notice Returns the USD price of `token`, scaled to 18 decimals.
    /// @param token The collateral token being priced.
    /// @return priceWad The price where `1e18` == $1.00.
    function getPriceWad(address token) external view returns (uint256 priceWad);
}
