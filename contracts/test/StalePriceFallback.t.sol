// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SumUSD} from "../src/SumUSD.sol";
import {SumUSDEngine} from "../src/SumUSDEngine.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

/// @notice The stale-price fallback: when a collateral's live feed fails, it is valued for BACKING/tilt
///         at its last-good price minus a haircut for a grace window, so a transient outage does not
///         trip the whole system into distress. Disabled by default (grace 0 = today's behavior).
contract StalePriceFallbackTest is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint32 internal constant GRACE = 6 hours;
    uint16 internal constant HAIRCUT = 100; // 1%

    SumUSD internal sumUsd;
    SumUSDEngine internal engine;
    MockOracle internal oracle;
    MockERC20 internal a; // 6 decimals
    MockERC20 internal b; // 6 decimals

    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.warp(1_700_000_000);
        sumUsd = new SumUSD(address(this));
        engine = new SumUSDEngine(address(this), sumUsd); // this contract is owner
        sumUsd.grantRole(sumUsd.MINTER_ROLE(), address(engine));
        oracle = new MockOracle();
        a = new MockERC20("Flavor A", "FLAV-A", 6);
        b = new MockERC20("Flavor B", "FLAV-B", 6);
        oracle.setPrice(address(a), WAD);
        oracle.setPrice(address(b), WAD);
        engine.setCollateral(address(a), true, 9900, oracle);
        engine.setCollateral(address(b), true, 9900, oracle);
    }

    function _deposit(address user, MockERC20 t, uint256 amount) internal returns (uint256) {
        t.mint(user, amount);
        vm.startPrank(user);
        t.approve(address(engine), amount);
        uint256 minted = engine.deposit(address(t), amount, 0);
        vm.stopPrank();
        return minted;
    }

    function _kill(MockERC20 t) internal {
        oracle.setPrice(address(t), 0); // MockOracle reverts on 0 -> feed "down"
    }

    // --- disabled by default ---------------------------------------------

    function test_DisabledByDefault_DeadFeedValuesZero() public {
        _deposit(alice, a, 1_000e6); // caches a@$1
        _kill(a);
        // No grace configured (default 0) -> unpriceable flavor values at 0, exactly as before.
        assertEq(engine.collateralValueUsd(address(a)), 0, "no fallback when disabled");
        assertEq(engine.valuationPriceWad(address(a)), 0, "valuation price 0 when disabled");
    }

    // --- enabled: last-good with haircut ---------------------------------

    function test_Enabled_DeadFeedUsesHaircutLastGood() public {
        engine.setStalePriceParams(GRACE, HAIRCUT);
        _deposit(alice, a, 1_000e6); // caches a@$1 now
        _kill(a);

        // Valued at last-good ($1) minus the 1% haircut = $0.99.
        assertEq(engine.valuationPriceWad(address(a)), 0.99e18, "haircut last-good price");
        assertEq(engine.collateralValueUsd(address(a)), 990e18, "1000 units * $0.99");
        // Feed-health views for the UI.
        (uint256 live, bool ok) = engine.livePriceWad(address(a));
        assertEq(live, 0);
        assertFalse(ok, "live feed reports down");
        assertEq(engine.lastGoodPriceWad(address(a)), WAD, "last-good recorded at $1");
    }

    // --- THE FIX: a transient outage does not trip systemic distress -----

    function test_Fix_TransientOutageDoesNotTripDistress() public {
        engine.setStalePriceParams(GRACE, HAIRCUT);
        _deposit(alice, a, 1_000e6);
        _deposit(alice, b, 1_000e6); // supply 2000, backing $2000, 100%

        _kill(b); // B's feed goes down transiently

        // Without the fallback B would drop to 0 -> ratio 50% -> distress. With it, B holds at $0.99.
        assertEq(engine.systemCollateralizationRatioBps(), 9950, "backing 1990/2000 = 99.5%, above floor");

        // So single-flavor redeem of the HEALTHY flavor A stays enabled...
        vm.prank(alice);
        assertGt(engine.redeem(address(a), 100e18, 0), 0, "healthy-flavor redeem not blocked by B's outage");
        // ...and the pro-rata distress exit stays dormant.
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        vm.expectPartialRevert(SumUSDEngine.NotDistressed.selector);
        engine.redeemMix(100e18, none);
    }

    function test_WithoutFallback_SameOutageTripsDistress() public {
        // Same scenario, fallback left disabled: the outage DOES trip distress (the pre-fix behavior).
        _deposit(alice, a, 1_000e6);
        _deposit(alice, b, 1_000e6);
        _kill(b);
        assertEq(engine.systemCollateralizationRatioBps(), 5000, "B at 0 -> 50%");
        vm.prank(alice);
        vm.expectPartialRevert(SumUSDEngine.UseRedeemMix.selector);
        engine.redeem(address(a), 100e18, 0);
    }

    // --- grace window bounds the staleness -------------------------------

    function test_GraceExpiry_ValuesZeroAfterWindow() public {
        engine.setStalePriceParams(GRACE, HAIRCUT);
        _deposit(alice, a, 1_000e6); // cached at t0
        _kill(a);

        vm.warp(block.timestamp + GRACE); // exactly at the edge -> still covered
        assertEq(engine.collateralValueUsd(address(a)), 990e18, "covered at the grace edge");

        vm.warp(block.timestamp + 1); // one second past -> falls to 0 (fully conservative)
        assertEq(engine.collateralValueUsd(address(a)), 0, "beyond grace -> 0");
    }

    function test_RefreshPrices_ExtendsCoverage() public {
        engine.setStalePriceParams(GRACE, HAIRCUT);
        _deposit(alice, a, 1_000e6); // cached at t0

        vm.warp(block.timestamp + 5 hours);
        engine.refreshPrices(); // feed still live -> re-warms lastGoodPriceAt to t0+5h
        assertEq(engine.lastGoodPriceAt(address(a)), block.timestamp, "cache re-warmed");

        _kill(a);
        vm.warp(block.timestamp + 5 hours); // 10h since deposit, but only 5h since refresh
        assertEq(engine.collateralValueUsd(address(a)), 990e18, "still covered thanks to refresh");
    }

    // --- fallback never covers the deposit peg guard ---------------------

    function test_PegGuardStillFailsClosed_DeadFeedDepositReverts() public {
        engine.setStalePriceParams(GRACE, HAIRCUT);
        _deposit(alice, a, 100e6); // cache a
        _deposit(alice, b, 10_000e6); // healthy flavor keeps the mint guard well above 99%
        _kill(a);

        // Even though A is now VALUED via the fallback, a DEPOSIT of A still reverts: the peg guard
        // reads the live oracle directly and is never covered by the fallback.
        a.mint(alice, 100e6);
        vm.startPrank(alice);
        a.approve(address(engine), 100e6);
        vm.expectRevert(); // MockOracle reverts "no price"
        engine.deposit(address(a), 100e6, 0);
        vm.stopPrank();
    }

    // --- recovery uses live again ----------------------------------------

    function test_Recovery_UsesLivePriceAgain() public {
        engine.setStalePriceParams(GRACE, HAIRCUT);
        _deposit(alice, a, 1_000e6);
        _kill(a);
        assertEq(engine.valuationPriceWad(address(a)), 0.99e18, "on fallback");
        oracle.setPrice(address(a), WAD); // feed recovers
        assertEq(engine.valuationPriceWad(address(a)), WAD, "back to live price (no haircut)");
        assertEq(engine.collateralValueUsd(address(a)), 1_000e18, "full value again");
    }

    // --- rails & access --------------------------------------------------

    function test_Rails_And_OnlyOwner() public {
        vm.expectPartialRevert(SumUSDEngine.InvalidStalePriceParams.selector);
        engine.setStalePriceParams(uint32(2 days + 1), HAIRCUT); // grace over the rail
        vm.expectPartialRevert(SumUSDEngine.InvalidStalePriceParams.selector);
        engine.setStalePriceParams(GRACE, uint16(BPS + 1)); // haircut over 100%
        engine.setStalePriceParams(uint32(2 days), uint16(BPS)); // ok at the rails

        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        engine.setStalePriceParams(GRACE, HAIRCUT);
    }
}
