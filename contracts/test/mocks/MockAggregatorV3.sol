// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// @notice Settable Chainlink AggregatorV3 mock for tests. Lets a test drive every field the
///         {ChainlinkOracleAdapter} validates (answer, updatedAt, roundId vs answeredInRound), and
///         can be made to revert to exercise the try/catch paths.
contract MockAggregatorV3 is AggregatorV3Interface {
    uint8 public decimals;

    uint80 internal _roundId;
    int256 internal _answer;
    uint256 internal _startedAt;
    uint256 internal _updatedAt;
    uint80 internal _answeredInRound;
    bool internal _reverts;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        decimals = decimals_;
        _answer = answer_;
        _updatedAt = updatedAt_;
        _startedAt = updatedAt_;
        _roundId = 1;
        _answeredInRound = 1;
    }

    function setAnswer(int256 answer_, uint256 updatedAt_) external {
        _answer = answer_;
        _updatedAt = updatedAt_;
        _startedAt = updatedAt_;
    }

    function setRounds(uint80 roundId_, uint80 answeredInRound_) external {
        _roundId = roundId_;
        _answeredInRound = answeredInRound_;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    function setReverts(bool reverts_) external {
        _reverts = reverts_;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        require(!_reverts, "MockAggregatorV3: reverting");
        return (_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
    }
}
