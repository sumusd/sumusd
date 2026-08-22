// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {MedianOracleAdapter} from "../src/oracles/MedianOracleAdapter.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

contract MedianOracleAdapterTest is Test {
    MedianOracleAdapter internal median;
    MockOracle internal s0;
    MockOracle internal s1;
    MockOracle internal s2;
    address internal owner = makeAddr("owner");
    address internal token = makeAddr("token");

    function setUp() public {
        vm.prank(owner);
        median = new MedianOracleAdapter(owner);
        s0 = new MockOracle();
        s1 = new MockOracle();
        s2 = new MockOracle();
        s0.setPrice(token, 0.99e18);
        s1.setPrice(token, 1.0e18);
        s2.setPrice(token, 1.01e18);
    }

    function _config(uint32 minFresh, uint32 maxSpreadBps) internal {
        IPriceOracle[] memory oracles = new IPriceOracle[](3);
        oracles[0] = s0;
        oracles[1] = s1;
        oracles[2] = s2;
        vm.prank(owner);
        median.setSources(token, oracles, minFresh, maxSpreadBps);
    }

    // --- median -----------------------------------------------------------

    function test_MedianOfThree() public {
        _config(2, 0);
        assertEq(median.getPriceWad(token), 1.0e18, "median of {0.99, 1.00, 1.01} is 1.00");
    }

    function test_MedianOfEvenAveragesMiddle() public {
        IPriceOracle[] memory oracles = new IPriceOracle[](2);
        oracles[0] = s0; // 0.99
        oracles[1] = s2; // 1.01
        vm.prank(owner);
        median.setSources(token, oracles, 2, 0);
        assertEq(median.getPriceWad(token), 1.0e18, "even count averages the two middle values");
    }

    function test_SingleOutlierIsOutvoted() public {
        // A single wildly-wrong source cannot move the median.
        s2.setPrice(token, 100e18);
        _config(2, 0); // spread check disabled
        assertEq(median.getPriceWad(token), 1.0e18, "median ignores the outlier");
    }

    function test_DeadSourceSkippedWhenQuorumHolds() public {
        s2.setPrice(token, 0); // MockOracle reverts on 0 -> treated as not fresh
        _config(2, 0);
        // Two fresh sources {0.99, 1.00} -> even median 0.995.
        assertEq(median.getPriceWad(token), 0.995e18, "dead source skipped, median of the rest");
    }

    // --- fail-closed ------------------------------------------------------

    function test_Revert_QuorumNotMet() public {
        s1.setPrice(token, 0);
        s2.setPrice(token, 0); // only one fresh source left
        _config(2, 0);
        vm.expectPartialRevert(MedianOracleAdapter.InsufficientFreshSources.selector);
        median.getPriceWad(token);
    }

    function test_Revert_NoSourcesConfigured() public {
        vm.expectPartialRevert(MedianOracleAdapter.NoSources.selector);
        median.getPriceWad(makeAddr("unconfigured"));
    }

    function test_SpreadWithinBoundOk() public {
        _config(2, 300); // {0.99,1.00,1.01}: spread = 200 bps <= 300
        assertEq(median.getPriceWad(token), 1.0e18, "in-spread median accepted");
    }

    function test_Revert_SpreadTooWide() public {
        _config(2, 100); // spread 200 bps > 100 -> circuit breaker
        vm.expectPartialRevert(MedianOracleAdapter.SpreadTooWide.selector);
        median.getPriceWad(token);
    }

    // --- configuration ----------------------------------------------------

    function test_Revert_InvalidQuorum() public {
        IPriceOracle[] memory oracles = new IPriceOracle[](2);
        oracles[0] = s0;
        oracles[1] = s1;
        vm.startPrank(owner);
        vm.expectPartialRevert(MedianOracleAdapter.InvalidQuorum.selector);
        median.setSources(token, oracles, 0, 0); // quorum 0
        vm.expectPartialRevert(MedianOracleAdapter.InvalidQuorum.selector);
        median.setSources(token, oracles, 3, 0); // quorum > count
        vm.stopPrank();
    }

    function test_Revert_ZeroSource() public {
        IPriceOracle[] memory oracles = new IPriceOracle[](2);
        oracles[0] = s0;
        oracles[1] = IPriceOracle(address(0));
        vm.prank(owner);
        vm.expectRevert(MedianOracleAdapter.ZeroSource.selector);
        median.setSources(token, oracles, 1, 0);
    }

    function test_MaxSourcesAllowedAtRail() public {
        // Exactly MAX_SOURCES (5) is accepted.
        IPriceOracle[] memory five = new IPriceOracle[](5);
        for (uint256 i; i < 5; ++i) {
            MockOracle m = new MockOracle();
            m.setPrice(token, 1e18);
            five[i] = m;
        }
        vm.prank(owner);
        median.setSources(token, five, 3, 0);
        (IPriceOracle[] memory got, uint32 mf,) = median.sourcesOf(token);
        assertEq(got.length, 5, "5 sources configured");
        assertEq(mf, 3, "a 3-of-5 quorum still fits under the rail");
        assertEq(median.getPriceWad(token), 1e18, "median of 5 identical sources");
    }

    function test_Revert_TooManySources() public {
        // 6 sources exceeds the MAX_SOURCES (5) rail. The cap was lowered from 7 because every source
        // is re-read for every listed collateral on the engine's redemption path.
        IPriceOracle[] memory tooMany = new IPriceOracle[](6);
        for (uint256 i; i < 6; ++i) {
            tooMany[i] = new MockOracle();
        }
        vm.prank(owner);
        vm.expectPartialRevert(MedianOracleAdapter.TooManySources.selector);
        median.setSources(token, tooMany, 1, 0);
    }

    function test_Revert_SetSources_NotOwner() public {
        IPriceOracle[] memory oracles = new IPriceOracle[](1);
        oracles[0] = s0;
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        median.setSources(token, oracles, 1, 0);
    }

    function test_RemoveSources() public {
        _config(2, 0);
        vm.prank(owner);
        median.removeSources(token);
        vm.expectPartialRevert(MedianOracleAdapter.NoSources.selector);
        median.getPriceWad(token);
    }
}
