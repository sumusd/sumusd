// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SumUSD} from "../src/SumUSD.sol";
import {SumUSDEngine} from "../src/SumUSDEngine.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {BlacklistMockERC20} from "./mocks/BlacklistMockERC20.sol";

/// @notice The de-back / "silo" lever: `setCollateralBackingExcluded` removes a permanently-inaccessible
///         flavor (e.g. one whose issuer has blacklisted the engine) from the backing + tilt math so the
///         collateralization ratio reflects only redeemable value, while the flavor stays listed and its
///         stuck slice is still shared pro-rata by `redeemMix`.
contract BackingExclusionTest is Test {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;

    SumUSD internal sumUsd;
    SumUSDEngine internal engine;
    MockOracle internal oracle;
    MockERC20 internal a; // 6 dec
    MockERC20 internal b; // 6 dec

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
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

    function test_Exclude_DropsFromBackingButRawStillShows() public {
        _deposit(alice, a, 1_000e6);
        _deposit(alice, b, 1_000e6); // supply 2000, backing $2000, 100%

        engine.setCollateralBackingExcluded(address(b), true);

        assertEq(engine.collateralValueUsd(address(b)), 0, "de-backed flavor counts 0 toward backing");
        assertEq(engine.rawCollateralValueUsd(address(b)), 1_000e18, "raw view still reports the stranded $1000");
        assertEq(engine.totalCollateralValueUsd(), 1_000e18, "backing now counts only flavor A");
        assertEq(engine.systemCollateralizationRatioBps(), 5000, "ratio drops to reflect redeemable value");
    }

    function test_Exclude_TripsDistressHonestly() public {
        _deposit(alice, a, 1_000e6);
        _deposit(alice, b, 1_000e6);
        assertEq(engine.systemCollateralizationRatioBps(), BPS, "healthy before exclusion");

        engine.setCollateralBackingExcluded(address(b), true); // ratio -> 50% -> distress

        // Single-flavor redeem is now gated; holders exit pro-rata.
        vm.prank(alice);
        vm.expectPartialRevert(SumUSDEngine.UseRedeemMix.selector);
        engine.redeem(address(a), 100e18, 0);

        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        engine.redeemMix(100e18, none); // works (distressed)
    }

    function test_Exclude_RemovedFromTilt() public {
        engine.setTiltSlopeBps(500);
        MockERC20 c = new MockERC20("Flavor C", "FLAV-C", 6);
        oracle.setPrice(address(c), WAD);
        engine.setCollateral(address(c), true, 9900, oracle);

        // A overweight, B/C underweight -> A gets an overweight discount (rate above base).
        _deposit(alice, a, 1_000e6);
        _deposit(alice, b, 200e6);
        _deposit(alice, c, 200e6);
        uint256 rateBefore = engine.currentRedeemRateBps(address(a));
        assertGt(rateBefore, 9900, "A overweight -> discount above base");

        engine.setCollateralBackingExcluded(address(c), true); // C leaves the tilt weight set

        uint256 rateAfter = engine.currentRedeemRateBps(address(a));
        assertTrue(rateAfter != rateBefore, "A's tilt recomputes without the de-backed flavor");
    }

    function test_Exclude_RedeemMixSharesLossOnStuckFlavor() public {
        // The real permanent-blacklist scenario: the issuer blacklists the engine, so transfers fail.
        BlacklistMockERC20 bl = new BlacklistMockERC20("Blk", "BLK", 6); // collateralList index 2
        oracle.setPrice(address(bl), WAD);
        engine.setCollateral(address(bl), true, 9900, oracle);

        _deposit(alice, a, 600e6); // 600 SumUSD
        bl.mint(bob, 400e6);
        vm.startPrank(bob);
        bl.approve(address(engine), 400e6);
        engine.deposit(address(bl), 400e6, 0); // 400 SumUSD; supply 1000
        vm.stopPrank();

        bl.setBlocked(true); // issuer blacklists the engine
        engine.setCollateralBackingExcluded(address(bl), true); // de-back the stuck flavor

        // Ratio now reflects only the redeemable flavor A (600/1000 = 60%) -> distressed.
        assertEq(engine.systemCollateralizationRatioBps(), 6000, "backing = redeemable A only");

        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        uint256[] memory amounts = engine.redeemMix(600e18, none);
        // Alice gets her pro-rata A; the stuck flavor's slice is skipped and stays pooled (shared loss).
        assertEq(amounts[0], 360e6, "A slice delivered (600/1000 of 600e6)");
        assertEq(amounts[2], 0, "stuck flavor slice skipped, not delivered");
        assertEq(bl.balanceOf(address(engine)), 400e6, "stuck value stays pooled, shared across holders");
    }

    function test_Reinclude_RestoresBacking() public {
        _deposit(alice, a, 1_000e6);
        _deposit(alice, b, 1_000e6);
        engine.setCollateralBackingExcluded(address(b), true);
        assertEq(engine.systemCollateralizationRatioBps(), 5000);

        engine.setCollateralBackingExcluded(address(b), false); // blacklist lifted -> re-include
        assertEq(engine.collateralValueUsd(address(b)), 1_000e18, "value counted again");
        assertEq(engine.systemCollateralizationRatioBps(), BPS, "backing fully restored");
    }

    function test_Exclude_OnlyOwner() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        engine.setCollateralBackingExcluded(address(a), true);
    }

    function test_Exclude_RevertsUnlisted() public {
        vm.expectPartialRevert(SumUSDEngine.CollateralNotEnabled.selector);
        engine.setCollateralBackingExcluded(makeAddr("unlisted"), true);
    }
}
