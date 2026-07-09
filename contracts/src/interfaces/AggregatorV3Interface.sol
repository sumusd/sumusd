// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/// @title AggregatorV3Interface
/// @notice Minimal subset of the Chainlink AggregatorV3 feed interface consumed by
///         {ChainlinkOracleAdapter}. Vendored locally (as a plain interface) to avoid taking a
///         dependency on the full Chainlink contracts package.
interface AggregatorV3Interface {
    /// @notice Number of decimals in the feed's `answer`.
    function decimals() external view returns (uint8);

    /// @notice The latest round's data.
    /// @return roundId         The round in which `answer` was computed.
    /// @return answer          The price answer, scaled to {decimals}.
    /// @return startedAt       Timestamp the round started.
    /// @return updatedAt       Timestamp the round was last updated (0 until the round is complete).
    /// @return answeredInRound The round in which the answer was actually computed (can lag `roundId`
    ///                         if a feed carries a stale answer forward).
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
