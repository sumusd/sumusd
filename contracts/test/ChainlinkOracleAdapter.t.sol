// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {ChainlinkOracleAdapter} from "../src/oracles/ChainlinkOracleAdapter.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

contract ChainlinkOracleAdapterTest is Test {
    uint256 internal constant WAD = 1e18;

    ChainlinkOracleAdapter internal adapter;
    MockAggregatorV3 internal feed;
    address internal owner = makeAddr("owner");
    address internal token = makeAddr("token");

    uint32 internal constant STALENESS = 1 hours;
    uint128 internal constant MAX_WAD = 1.1e18;

    function setUp() public {
        vm.warp(1_700_000_000); // realistic timestamp so staleness math is meaningful
        vm.prank(owner);
        adapter = new ChainlinkOracleAdapter(owner);
        // 8-decimal feed reading $1.00, fresh as of now.
        feed = new MockAggregatorV3(8, 1e8, block.timestamp);
        vm.prank(owner);
        adapter.setFeed(token, address(feed), STALENESS, MAX_WAD);
    }

    // --- happy path & scaling -------------------------------------------

    function test_ReturnsScaledWad_8Decimals() public view {
        assertEq(adapter.getPriceWad(token), WAD, "$1.00 at 8 decimals -> 1e18 WAD");
    }

    function test_ReturnsScaledWad_18Decimals() public {
        MockAggregatorV3 f18 = new MockAggregatorV3(18, 1.0005e18, block.timestamp);
        address t2 = makeAddr("t2");
        vm.prank(owner);
        adapter.setFeed(t2, address(f18), STALENESS, MAX_WAD);
        assertEq(adapter.getPriceWad(t2), 1.0005e18, "18-decimal feed passes through");
    }

    function test_ReturnsScaledWad_MoreThan18Decimals() public {
        MockAggregatorV3 f20 = new MockAggregatorV3(20, 1e20, block.timestamp);
        address t3 = makeAddr("t3");
        vm.prank(owner);
        adapter.setFeed(t3, address(f20), STALENESS, MAX_WAD);
        assertEq(adapter.getPriceWad(t3), WAD, "20-decimal feed scales down to WAD");
    }

    function test_RealDepegIsReturned() public {
        // A genuine depeg to $0.95 is inside the sane band, so the adapter returns it (the engine's
        // own 0.5% deposit peg band is what gates deposits — the oracle only reports).
        feed.setAnswer(0.95e8, block.timestamp);
        assertEq(adapter.getPriceWad(token), 0.95e18, "in-band depeg reported, not rejected");
    }

    // --- fail-closed validation -----------------------------------------

    function test_Revert_Unconfigured() public {
        vm.expectPartialRevert(ChainlinkOracleAdapter.FeedNotConfigured.selector);
        adapter.getPriceWad(makeAddr("unknown"));
    }

    function test_Revert_NonPositiveAnswer() public {
        feed.setAnswer(0, block.timestamp);
        vm.expectPartialRevert(ChainlinkOracleAdapter.InvalidAnswer.selector);
        adapter.getPriceWad(token);

        feed.setAnswer(-1, block.timestamp);
        vm.expectPartialRevert(ChainlinkOracleAdapter.InvalidAnswer.selector);
        adapter.getPriceWad(token);
    }

    function test_Revert_RoundNotComplete() public {
        feed.setAnswer(1e8, 0); // updatedAt == 0
        vm.expectPartialRevert(ChainlinkOracleAdapter.RoundNotComplete.selector);
        adapter.getPriceWad(token);
    }

    function test_Revert_StaleRound() public {
        feed.setRounds(5, 4); // answeredInRound < roundId
        vm.expectPartialRevert(ChainlinkOracleAdapter.StaleRound.selector);
        adapter.getPriceWad(token);
    }

    function test_Revert_StalePrice() public {
        // Age the answer just past the staleness bound.
        feed.setUpdatedAt(block.timestamp - STALENESS - 1);
        vm.expectPartialRevert(ChainlinkOracleAdapter.StalePrice.selector);
        adapter.getPriceWad(token);
    }

    function test_FreshAtExactBoundary() public {
        feed.setUpdatedAt(block.timestamp - STALENESS); // exactly at the bound is still fresh
        assertEq(adapter.getPriceWad(token), WAD, "answer exactly at staleness bound is accepted");
    }

    function test_LowAnswerPassesThrough() public {
        // A fresh, positive answer that is merely LOW is a depeg signal, not a malfunction: it must be
        // reported as-is so the engine values the flavor DOWN. Rejecting it would let the engine's stale
        // fallback bridge a real crash with the (higher) last-good price.
        feed.setAnswer(0.5e8, block.timestamp); // $0.50
        assertEq(adapter.getPriceWad(token), 0.5e18, "low price is passed through, never masked");
        feed.setAnswer(1, block.timestamp); // 1e-8 dollars: still a valid (catastrophic) reading
        assertEq(adapter.getPriceWad(token), 1e10, "even a near-zero answer is reported, not rejected");
    }

    function test_Revert_AboveSaneCeiling() public {
        feed.setAnswer(5e8, block.timestamp); // $5.00 -> above the 1.1 sane ceiling (would inflate backing)
        vm.expectPartialRevert(ChainlinkOracleAdapter.PriceAboveSaneCeiling.selector);
        adapter.getPriceWad(token);
    }

    function test_Revert_AggregatorReverts() public {
        feed.setReverts(true);
        vm.expectRevert(); // bubbles up; the engine's _tryPriceWad turns this into a 0 valuation
        adapter.getPriceWad(token);
    }

    // --- configuration validation & access ------------------------------

    function test_Revert_SetFeed_ZeroAggregator() public {
        vm.prank(owner);
        vm.expectRevert(ChainlinkOracleAdapter.ZeroAggregator.selector);
        adapter.setFeed(token, address(0), STALENESS, MAX_WAD);
    }

    function test_Revert_SetFeed_ZeroStaleness() public {
        vm.prank(owner);
        vm.expectRevert(ChainlinkOracleAdapter.InvalidStaleness.selector);
        adapter.setFeed(token, address(feed), 0, MAX_WAD);
    }

    function test_Revert_SetFeed_ZeroCeiling() public {
        vm.prank(owner);
        vm.expectRevert(ChainlinkOracleAdapter.InvalidSaneCeiling.selector);
        adapter.setFeed(token, address(feed), STALENESS, 0);
    }

    function test_Revert_SetFeed_NotOwner() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        adapter.setFeed(token, address(feed), STALENESS, MAX_WAD);
    }

    function test_RemoveFeed() public {
        vm.prank(owner);
        adapter.removeFeed(token);
        vm.expectPartialRevert(ChainlinkOracleAdapter.FeedNotConfigured.selector);
        adapter.getPriceWad(token);
    }
}
