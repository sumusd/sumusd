// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SumUSD} from "../src/SumUSD.sol";
import {SumUSDEngine} from "../src/SumUSDEngine.sol";
import {ChainlinkOracleAdapter} from "../src/oracles/ChainlinkOracleAdapter.sol";
import {MedianOracleAdapter} from "../src/oracles/MedianOracleAdapter.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAggregatorV3} from "./mocks/MockAggregatorV3.sol";

/// @notice End-to-end wiring of the {SumUSDEngine} to a {MedianOracleAdapter} over TWO independent
///         {ChainlinkOracleAdapter} providers, matching the SetupSepolia config (MIN_FRESH = 1,
///         MAX_SPREAD_BPS = 100). Proves the median's distinctive behaviors through the engine:
///         - both providers fresh -> prices normally;
///         - one provider down -> the survivor still prices (outage tolerance);
///         - providers disagree beyond the breaker -> fails closed -> engine values the flavor at 0,
///           blocking its deposit but keeping it redeemable at base par (holders never trapped);
///         - both providers down -> quorum unmet -> same conservative failure mode.
contract MedianIntegrationTest is Test {
    uint256 internal constant WAD = 1e18;
    uint32 internal constant STALENESS = 1 hours;
    uint32 internal constant MIN_FRESH = 1;
    uint32 internal constant MAX_SPREAD_BPS = 100; // 1%

    SumUSD internal sumUsd;
    SumUSDEngine internal engine;
    ChainlinkOracleAdapter internal o1;
    ChainlinkOracleAdapter internal o2;
    MedianOracleAdapter internal median;

    MockERC20 internal a; // 6 decimals, median-priced
    MockERC20 internal b; // 6 decimals, median-priced (kept healthy to hold backing up)
    MockAggregatorV3 internal aggA1; // flavor A, provider 1
    MockAggregatorV3 internal aggA2; // flavor A, provider 2
    MockAggregatorV3 internal aggB1;
    MockAggregatorV3 internal aggB2;

    address internal owner = makeAddr("owner");

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.startPrank(owner);
        sumUsd = new SumUSD(owner);
        engine = new SumUSDEngine(owner, sumUsd);
        sumUsd.grantRole(sumUsd.MINTER_ROLE(), address(engine));

        o1 = new ChainlinkOracleAdapter(owner);
        o2 = new ChainlinkOracleAdapter(owner);
        median = new MedianOracleAdapter(owner);

        a = new MockERC20("Flavor A", "FLAV-A", 6);
        b = new MockERC20("Flavor B", "FLAV-B", 6);
        aggA1 = new MockAggregatorV3(8, 1e8, block.timestamp);
        aggA2 = new MockAggregatorV3(8, 1e8, block.timestamp);
        aggB1 = new MockAggregatorV3(8, 1e8, block.timestamp);
        aggB2 = new MockAggregatorV3(8, 1e8, block.timestamp);

        // Each provider wraps its own aggregator per flavor.
        o1.setFeed(address(a), address(aggA1), STALENESS, 0.9e18, 1.1e18);
        o2.setFeed(address(a), address(aggA2), STALENESS, 0.9e18, 1.1e18);
        o1.setFeed(address(b), address(aggB1), STALENESS, 0.9e18, 1.1e18);
        o2.setFeed(address(b), address(aggB2), STALENESS, 0.9e18, 1.1e18);

        // Median over both providers, per flavor.
        IPriceOracle[] memory srcs = new IPriceOracle[](2);
        srcs[0] = o1;
        srcs[1] = o2;
        median.setSources(address(a), srcs, MIN_FRESH, MAX_SPREAD_BPS);
        median.setSources(address(b), srcs, MIN_FRESH, MAX_SPREAD_BPS);

        // The engine reads the median.
        engine.setCollateral(address(a), true, 9900, median);
        engine.setCollateral(address(b), true, 9900, median);
        vm.stopPrank();
    }

    function _deposit(address user, MockERC20 t, uint256 amount) internal returns (uint256) {
        t.mint(user, amount);
        vm.startPrank(user);
        t.approve(address(engine), amount);
        uint256 minted = engine.deposit(address(t), amount, 0);
        vm.stopPrank();
        return minted;
    }

    function _stale(MockAggregatorV3 agg) internal {
        agg.setUpdatedAt(block.timestamp - STALENESS - 1);
    }

    function test_HealthyMedian_PricesAndMints() public {
        assertEq(median.getPriceWad(address(a)), WAD, "median of two $1 feeds is $1");
        assertEq(_deposit(makeAddr("u"), a, 100e6), 100e18, "1:1 mint through the median");
        assertEq(engine.collateralValueUsd(address(a)), 100e18, "priced at $1");
        assertEq(engine.systemCollateralizationRatioBps(), 10_000, "100% backed");
    }

    function test_OneProviderDown_MedianStillPricesViaSurvivor() public {
        _deposit(makeAddr("u"), a, 100e6);

        _stale(aggA1); // provider 1's feed for A goes stale -> its adapter fails closed

        // MIN_FRESH = 1, so the surviving provider still prices A at $1.
        assertEq(median.getPriceWad(address(a)), WAD, "survivor still prices");
        assertEq(engine.collateralValueUsd(address(a)), 100e18, "A still valued at $1");
        // And a fresh deposit of A still works (the peg guard reads the median, which returns $1).
        assertEq(_deposit(makeAddr("u2"), a, 50e6), 50e18, "deposit works with one provider down");
    }

    function test_ProvidersDisagree_FailsClosedButStillRedeemable() public {
        _deposit(makeAddr("lp"), b, 100_000e6); // healthy flavor holds backing above the distress line
        address u = makeAddr("u");
        _deposit(u, a, 100e6);

        // Provider 2's A feed drifts to $1.02: the two providers now disagree by ~2% (> 1% breaker).
        vm.prank(owner);
        aggA2.setAnswer(1.02e8, block.timestamp);
        vm.expectPartialRevert(MedianOracleAdapter.SpreadTooWide.selector);
        median.getPriceWad(address(a));

        // The engine treats A as unpriceable -> 0 backing (conservative, not a mid-disagreement value).
        assertEq(engine.collateralValueUsd(address(a)), 0, "disagreement -> unpriceable -> 0");

        // A deposit of A reverts (the peg guard reads the median directly)...
        a.mint(makeAddr("u2"), 100e6);
        vm.startPrank(makeAddr("u2"));
        a.approve(address(engine), 100e6);
        vm.expectPartialRevert(MedianOracleAdapter.SpreadTooWide.selector);
        engine.deposit(address(a), 100e6, 0);
        vm.stopPrank();

        // ...but the holder still exits A at its flat base rate at par (never trapped by a bad feed).
        vm.prank(u);
        assertEq(engine.redeem(address(a), 100e18, 0), 99e6, "redeem falls back to base par");
    }

    function test_BothProvidersDown_QuorumUnmetButStillRedeemable() public {
        _deposit(makeAddr("lp"), b, 100_000e6);
        address u = makeAddr("u");
        _deposit(u, a, 100e6);

        _stale(aggA1);
        _stale(aggA2); // 0 fresh providers for A < MIN_FRESH (1)

        vm.expectPartialRevert(MedianOracleAdapter.InsufficientFreshSources.selector);
        median.getPriceWad(address(a));
        assertEq(engine.collateralValueUsd(address(a)), 0, "no fresh sources -> 0");

        a.mint(makeAddr("u2"), 100e6);
        vm.startPrank(makeAddr("u2"));
        a.approve(address(engine), 100e6);
        vm.expectPartialRevert(MedianOracleAdapter.InsufficientFreshSources.selector);
        engine.deposit(address(a), 100e6, 0);
        vm.stopPrank();

        vm.prank(u);
        assertEq(engine.redeem(address(a), 100e18, 0), 99e6, "redeem at base par despite both feeds down");
    }
}
