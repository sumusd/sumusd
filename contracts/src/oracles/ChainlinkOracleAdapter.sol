// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";

/// @title ChainlinkOracleAdapter
/// @notice Production {IPriceOracle} that wraps a Chainlink AggregatorV3 feed per collateral and
///         normalizes its answer to an 18-decimal WAD (`1e18 == $1.00`). It is deliberately
///         **fail-closed**: `getPriceWad` REVERTS on any feed that is stale, incomplete, non-positive,
///         or outside a configured sane band. The {SumUSDEngine} reads collateral prices through a
///         try/catch (`_tryPriceWad`), so a revert here is treated as "unpriceable" and that collateral
///         is valued at **0** (conservative) rather than at a stale or garbage price — never up. This
///         closes the "stale-but-returning feed" gap: a frozen feed that keeps returning $1.00 for a
///         depegged asset is rejected once it passes the staleness bound, instead of silently keeping
///         the asset valued at par.
///
/// @dev The engine calls this directly on the deposit peg-band guard (so a stale feed blocks deposits
///      of that flavor) and via try/catch everywhere else (so a stale feed just drops the flavor to 0
///      backing/weight and lets it redeem at its flat base rate). This contract holds no funds and has
///      no power over the engine; it is pure read-only pricing with owner-gated configuration.
contract ChainlinkOracleAdapter is IPriceOracle, Ownable2Step {
    /// @notice Per-collateral feed configuration.
    struct FeedConfig {
        address aggregator; // Chainlink AggregatorV3 feed for token/USD
        uint8 feedDecimals; // cached aggregator.decimals()
        uint32 maxStaleness; // seconds; reject an answer older than this (feed heartbeat + buffer)
        uint128 minPriceWad; // absolute sane lower bound (WAD); reject a price below it
        uint128 maxPriceWad; // absolute sane upper bound (WAD); reject a price above it
    }

    /// @notice Feed configuration per collateral token.
    mapping(address token => FeedConfig config) public feeds;

    event FeedConfigured(
        address indexed token,
        address indexed aggregator,
        uint8 feedDecimals,
        uint32 maxStaleness,
        uint128 minPriceWad,
        uint128 maxPriceWad
    );
    event FeedRemoved(address indexed token);

    error FeedNotConfigured(address token);
    error ZeroAggregator();
    error InvalidStaleness();
    error InvalidSaneBand(uint128 minPriceWad, uint128 maxPriceWad);
    error InvalidAnswer(address token, int256 answer);
    error RoundNotComplete(address token);
    error StaleRound(address token, uint80 roundId, uint80 answeredInRound);
    error StalePrice(address token, uint256 updatedAt, uint256 nowTs);
    error PriceOutOfSaneBand(address token, uint256 priceWad);

    constructor(address admin) Ownable(admin) {}

    // ---------------------------------------------------------------------
    // Configuration (owner / timelock)
    // ---------------------------------------------------------------------

    /// @notice Configure (or reconfigure) the Chainlink feed for `token`.
    /// @param token        Collateral token to price.
    /// @param aggregator   Chainlink AggregatorV3 feed (token/USD). Its decimals are read and cached.
    /// @param maxStaleness Max age (seconds) of a round before it is rejected. Set to the feed's
    ///                     heartbeat plus a safety buffer. Must be > 0.
    /// @param minPriceWad  Absolute lower sane bound (WAD). A price below it is rejected as a feed
    ///                     malfunction. Must be > 0 and <= `maxPriceWad`.
    /// @param maxPriceWad  Absolute upper sane bound (WAD). A price above it is rejected.
    function setFeed(address token, address aggregator, uint32 maxStaleness, uint128 minPriceWad, uint128 maxPriceWad)
        external
        onlyOwner
    {
        if (aggregator == address(0)) revert ZeroAggregator();
        if (maxStaleness == 0) revert InvalidStaleness();
        if (minPriceWad == 0 || minPriceWad > maxPriceWad) revert InvalidSaneBand(minPriceWad, maxPriceWad);

        uint8 feedDecimals = AggregatorV3Interface(aggregator).decimals();
        feeds[token] = FeedConfig({
            aggregator: aggregator,
            feedDecimals: feedDecimals,
            maxStaleness: maxStaleness,
            minPriceWad: minPriceWad,
            maxPriceWad: maxPriceWad
        });
        emit FeedConfigured(token, aggregator, feedDecimals, maxStaleness, minPriceWad, maxPriceWad);
    }

    /// @notice Remove the feed for `token`. Subsequent {getPriceWad} calls revert `FeedNotConfigured`,
    ///         so the engine values the collateral at 0 (conservative) until a feed is set again.
    function removeFeed(address token) external onlyOwner {
        if (feeds[token].aggregator == address(0)) revert FeedNotConfigured(token);
        delete feeds[token];
        emit FeedRemoved(token);
    }

    // ---------------------------------------------------------------------
    // IPriceOracle
    // ---------------------------------------------------------------------

    /// @inheritdoc IPriceOracle
    /// @dev Reverts (fail-closed) unless the latest round is positive, complete, fresh within
    ///      `maxStaleness`, not a carried-over stale answer, and within the configured sane band.
    function getPriceWad(address token) external view returns (uint256 priceWad) {
        FeedConfig memory f = feeds[token];
        if (f.aggregator == address(0)) revert FeedNotConfigured(token);

        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            AggregatorV3Interface(f.aggregator).latestRoundData();

        if (answer <= 0) revert InvalidAnswer(token, answer);
        if (updatedAt == 0) revert RoundNotComplete(token);
        if (answeredInRound < roundId) revert StaleRound(token, roundId, answeredInRound);
        // updatedAt <= block.timestamp for any real feed; if the feed reports the future, the
        // subtraction underflow-reverts, which is itself a fail-closed outcome.
        if (block.timestamp - updatedAt > f.maxStaleness) revert StalePrice(token, updatedAt, block.timestamp);

        priceWad = _scaleToWad(uint256(answer), f.feedDecimals);
        if (priceWad < f.minPriceWad || priceWad > f.maxPriceWad) revert PriceOutOfSaneBand(token, priceWad);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Scale a feed answer from `feedDecimals` to an 18-decimal WAD.
    function _scaleToWad(uint256 answer, uint8 feedDecimals) internal pure returns (uint256) {
        if (feedDecimals == 18) return answer;
        if (feedDecimals < 18) return answer * (10 ** (18 - feedDecimals));
        return answer / (10 ** (feedDecimals - 18));
    }
}
