// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SumUSD} from "../src/SumUSD.sol";
import {SumUSDEngine} from "../src/SumUSDEngine.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {BlacklistMockERC20} from "./mocks/BlacklistMockERC20.sol";
import {RevertingBalanceMock} from "./mocks/RevertingBalanceMock.sol";
import {ToggleBalanceMockERC20} from "./mocks/ToggleBalanceMockERC20.sol";

contract SumUSDEngineTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    SumUSD internal sumUsd;
    SumUSDEngine internal engine;
    MockOracle internal oracle;

    MockERC20 internal flavorA; // 6 decimals
    MockERC20 internal flavorB; // 6 decimals
    MockERC20 internal flavorC; // 18 decimals (rated more conservatively)

    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.startPrank(owner);
        sumUsd = new SumUSD(owner);
        engine = new SumUSDEngine(owner, sumUsd);
        sumUsd.grantRole(sumUsd.MINTER_ROLE(), address(engine));

        oracle = new MockOracle();
        flavorA = new MockERC20("Flavor A", "FLAV-A", 6);
        flavorB = new MockERC20("Flavor B", "FLAV-B", 6);
        flavorC = new MockERC20("Flavor C", "FLAV-C", 18);

        oracle.setPrice(address(flavorA), WAD);
        oracle.setPrice(address(flavorB), WAD);
        oracle.setPrice(address(flavorC), WAD);

        // Tilt defaults to 0 (flat) here so most unit tests stay isolated; the tilt tests set it.
        engine.setCollateral(address(flavorA), true, uint16(BPS), oracle);
        engine.setCollateral(address(flavorB), true, uint16(BPS), oracle);
        engine.setCollateral(address(flavorC), true, 9700, oracle);
        vm.stopPrank();
    }

    // --- helpers ---------------------------------------------------------

    function _deposit(address user, MockERC20 token, uint256 amount) internal returns (uint256 minted) {
        token.mint(user, amount);
        vm.startPrank(user);
        token.approve(address(engine), amount);
        minted = engine.deposit(address(token), amount, 0);
        vm.stopPrank();
    }

    // --- cold start / bootstrap ------------------------------------------
    // setUp lists collateral but makes no deposits, so every test begins from a cold pool (supply 0).

    function test_Bootstrap_EmptyPoolReadsInfiniteBacking() public view {
        // With zero supply the backing ratio is defined as "infinitely backed", which is what lets the
        // first-ever deposit clear the mint guard (no chicken-and-egg).
        assertEq(sumUsd.totalSupply(), 0, "pool starts cold");
        assertEq(engine.systemCollateralizationRatioBps(), type(uint256).max, "empty pool is infinitely backed");
    }

    function test_Bootstrap_FirstDepositAlwaysAllowedAndMints1to1() public {
        // First deposit at supply 0 passes the mint guard on the infinite pre-deposit ratio, and mints
        // at par. An at-$1 flavor lands the pool at exactly 100%.
        uint256 minted = _deposit(alice, flavorA, 1_000e6);
        assertEq(minted, 1_000e18, "bootstrap deposit mints 1:1 (par)");
        assertEq(sumUsd.totalSupply(), 1_000e18, "supply seeded by the first deposit");
        assertEq(engine.systemCollateralizationRatioBps(), BPS, "at-$1 bootstrap = exactly 100%");
    }

    function test_Bootstrap_RedemptionFloorNotEngagedAtColdStart() public {
        _deposit(alice, flavorA, 1_000e6); // seed at 100%

        // Above the 99% distress line: single-flavor redeem is the live path right after bootstrap...
        vm.prank(alice);
        assertGt(engine.redeem(address(flavorA), 100e18, 0), 0, "single-flavor redeem works post-bootstrap");

        // ...and the pro-rata distress exit is dormant (reverts NotDistressed).
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        vm.expectPartialRevert(SumUSDEngine.NotDistressed.selector);
        engine.redeemMix(100e18, none);
    }

    function test_Bootstrap_WorstInBandDepositStaysAboveFloor() public {
        // The 0.5% deposit peg band caps how sub-par a bootstrap flavor can be, so a cold pool can never
        // start in distress: the worst allowed price ($0.995) lands at 99.5%, still above the 99% floor.
        vm.prank(owner);
        oracle.setPrice(address(flavorA), 0.995e18);
        uint256 minted = _deposit(alice, flavorA, 1_000e6);
        assertEq(minted, 1_000e18, "still mints 1:1 at par");
        assertEq(engine.systemCollateralizationRatioBps(), 9950, "worst in-band bootstrap = 99.5%");
        assertGe(engine.systemCollateralizationRatioBps(), 9900, "never cold-starts below the floor");

        vm.prank(alice);
        assertGt(engine.redeem(address(flavorA), 10e18, 0), 0, "redeem available, not distressed");
    }

    function test_Bootstrap_CannotSeedBelowPegBand() public {
        // A flavor priced outside the band can't be deposited at all, so it can never drag a cold pool
        // under 99% via minting.
        vm.prank(owner);
        oracle.setPrice(address(flavorA), 0.98e18); // 2% below $1, outside the 0.5% band
        flavorA.mint(alice, 1_000e6);
        vm.startPrank(alice);
        flavorA.approve(address(engine), 1_000e6);
        vm.expectPartialRevert(SumUSDEngine.PriceOutOfBand.selector);
        engine.deposit(address(flavorA), 1_000e6, 0);
        vm.stopPrank();
    }

    function test_Bootstrap_MultiFlavorSequenceStaysHealthy() public {
        // Seed several flavors in sequence (the "some flavor(s) deposits" bootstrap): the first clears on
        // infinite backing, each later one on a >= 99% pre-snapshot, and the basket lands at 100%.
        _deposit(alice, flavorA, 500e6); // first: supply 0 -> allowed
        _deposit(bob, flavorB, 300e6); // pre-ratio 100% -> allowed
        _deposit(alice, flavorC, 200e18); // pre-ratio 100% -> allowed
        assertEq(sumUsd.totalSupply(), 1_000e18, "supply is the sum of the par deposits");
        assertEq(engine.systemCollateralizationRatioBps(), BPS, "all-at-$1 basket bootstraps to 100%");
    }

    // --- deposit ---------------------------------------------------------

    function test_Deposit_Mints1To1_SixDecimals() public {
        uint256 minted = _deposit(alice, flavorA, 1_000e6);
        assertEq(minted, 1_000e18, "1000 flavor A should mint 1000 SumUSD");
        assertEq(sumUsd.balanceOf(alice), 1_000e18);
        assertEq(engine.systemCollateralizationRatioBps(), BPS, "fresh deposit is exactly 100%");
    }

    function test_Deposit_Mints1To1_EighteenDecimals() public {
        uint256 minted = _deposit(alice, flavorC, 500e18);
        assertEq(minted, 500e18, "flavor C redemption haircut must not apply on deposit");
    }

    function test_Deposit_RawUnitSwapIgnoresOraclePrice() public {
        // Deposit is a raw 1:1 unit swap: the in-band price does NOT change the minted amount.
        vm.prank(owner);
        oracle.setPrice(address(flavorA), 0.998e18); // within the 0.2% band, but off $1
        uint256 minted = _deposit(alice, flavorA, 100e6);
        assertEq(minted, 100e18, "100 flavor A mints 100 SumUSD regardless of the $0.998 price");
    }

    function test_Deposit_ForcesFungibilityAcrossDecimals() public {
        // Same unit count of a 6-decimal and an 18-decimal flavor mint the same SumUSD, even at
        // slightly different (in-band) prices -> all flavors are fungible $1 units.
        // Prices kept >= $1 so the second deposit isn't blocked by the under-collateralization guard.
        vm.startPrank(owner);
        oracle.setPrice(address(flavorA), 1.002e18);
        oracle.setPrice(address(flavorC), 1.001e18);
        vm.stopPrank();
        assertEq(_deposit(alice, flavorA, 100e6), 100e18, "flavor A (6 dec)");
        assertEq(_deposit(bob, flavorC, 100e18), 100e18, "flavor C (18 dec)");
    }

    function test_Deposit_RevertsWhenUnderCollateralized() public {
        _deposit(alice, flavorC, 1_000e18); // ratio 100%
        vm.prank(owner);
        oracle.setPrice(address(flavorC), 0.95e18); // backing $950 vs 1,000 supply -> 95%
        assertLt(engine.systemCollateralizationRatioBps(), BPS);

        // A fresh, on-peg deposit is blocked: no new SumUSD into an underwater pool.
        flavorA.mint(bob, 100e6);
        vm.startPrank(bob);
        flavorA.approve(address(engine), 100e6);
        vm.expectPartialRevert(SumUSDEngine.UnderCollateralized.selector);
        engine.deposit(address(flavorA), 100e6, 0);
        vm.stopPrank();
    }

    function test_Deposit_AllowedWithinMintRatioTolerance() public {
        _deposit(alice, flavorC, 1_000e18); // ratio 100%
        vm.prank(owner);
        oracle.setPrice(address(flavorC), 0.993e18); // backing $993 -> 99.3%, within the 99% floor
        assertLt(engine.systemCollateralizationRatioBps(), BPS);

        // 99.3% >= 99% floor -> a fresh on-peg deposit is allowed (a hard 100% guard would block it).
        flavorA.mint(bob, 100e6);
        vm.startPrank(bob);
        flavorA.approve(address(engine), 100e6);
        uint256 minted = engine.deposit(address(flavorA), 100e6, 0);
        vm.stopPrank();
        assertEq(minted, 100e18, "deposit allowed at 99.3% backing (slack below par)");
    }

    function test_Deposit_MintReenabledWhenBackingRecovers() public {
        _deposit(alice, flavorC, 1_000e18);
        vm.prank(owner);
        oracle.setPrice(address(flavorC), 0.95e18); // 95% -> minting paused

        flavorA.mint(bob, 100e6);
        vm.startPrank(bob);
        flavorA.approve(address(engine), 100e6);
        vm.expectPartialRevert(SumUSDEngine.UnderCollateralized.selector);
        engine.deposit(address(flavorA), 100e6, 0);
        vm.stopPrank();

        // Backing recovers to >= 100% -> minting resumes.
        vm.prank(owner);
        oracle.setPrice(address(flavorC), 1e18);
        assertEq(engine.systemCollateralizationRatioBps(), BPS);
        assertEq(_deposit(bob, flavorA, 100e6), 100e18, "minting resumes once fully backed again");
    }

    function test_Deposit_RevertsWhenPriceBelowBand() public {
        vm.prank(owner);
        oracle.setPrice(address(flavorA), 0.98e18); // 2% below peg, beyond the 1% band
        flavorA.mint(alice, 100e6);
        vm.startPrank(alice);
        flavorA.approve(address(engine), 100e6);
        vm.expectPartialRevert(SumUSDEngine.PriceOutOfBand.selector);
        engine.deposit(address(flavorA), 100e6, 0);
        vm.stopPrank();
    }

    function test_Deposit_RevertsWhenPriceAboveBand() public {
        vm.prank(owner);
        oracle.setPrice(address(flavorA), 1.02e18); // 2% above peg
        flavorA.mint(alice, 100e6);
        vm.startPrank(alice);
        flavorA.approve(address(engine), 100e6);
        vm.expectPartialRevert(SumUSDEngine.PriceOutOfBand.selector);
        engine.deposit(address(flavorA), 100e6, 0);
        vm.stopPrank();
    }

    function test_Deposit_AllowedAtBandEdge() public {
        vm.prank(owner);
        oracle.setPrice(address(flavorA), 0.995e18); // exactly 0.5% below peg — inclusive, still allowed
        uint256 minted = _deposit(alice, flavorA, 100e6);
        assertEq(minted, 100e18, "deposit allowed at the band edge; raw 1:1 mint ignores the $0.995 price");
    }

    function test_Deposit_RevertsWhenDisabled() public {
        vm.prank(owner);
        engine.setCollateralEnabled(address(flavorA), false);
        flavorA.mint(alice, 1e6);
        vm.startPrank(alice);
        flavorA.approve(address(engine), 1e6);
        vm.expectPartialRevert(SumUSDEngine.CollateralNotEnabled.selector);
        engine.deposit(address(flavorA), 1e6, 0);
        vm.stopPrank();
    }

    function test_Deposit_RevertsOnZero() public {
        vm.prank(alice);
        vm.expectRevert(SumUSDEngine.ZeroAmount.selector);
        engine.deposit(address(flavorA), 0, 0);
    }

    function test_Deposit_RevertsOnSlippage() public {
        flavorA.mint(alice, 100e6);
        vm.startPrank(alice);
        flavorA.approve(address(engine), 100e6);
        vm.expectPartialRevert(SumUSDEngine.SlippageExceeded.selector);
        engine.deposit(address(flavorA), 100e6, 101e18); // expects more than 1:1
        vm.stopPrank();
    }

    // --- redeem ----------------------------------------------------------

    function test_Redeem_NoHaircutAtFullRate() public {
        _deposit(alice, flavorA, 1_000e6);
        vm.prank(alice);
        uint256 out = engine.redeem(address(flavorA), 1_000e18, 0);
        assertEq(out, 1_000e6, "flavor A at 100% rate redeems 1:1");
        assertEq(sumUsd.balanceOf(alice), 0);
    }

    function test_Redeem_AppliesHaircut() public {
        _deposit(alice, flavorC, 1_000e18);
        vm.prank(alice);
        uint256 out = engine.redeem(address(flavorC), 100e18, 0);
        assertEq(out, 97e18, "redeeming 100 SumUSD for flavor C (97% rate) returns 97 flavor C");
    }

    function test_Redeem_GrowsCollateralization() public {
        _deposit(alice, flavorC, 1_000e18);
        assertEq(engine.systemCollateralizationRatioBps(), BPS, "starts at 100%");

        vm.prank(alice);
        engine.redeem(address(flavorC), 500e18, 0); // burns 500, returns 485 flavor C

        // pool: 515 flavor C backing 500 SumUSD => 103%
        assertEq(engine.systemCollateralizationRatioBps(), 10_300, "haircut pushes backing above 100%");
    }

    function test_Redeem_RevertsInsufficientPool() public {
        // Alice mints from flavor A, then tries to redeem the flavor B flavor, which the pool doesn't hold.
        _deposit(alice, flavorA, 100e6);
        vm.prank(alice);
        vm.expectPartialRevert(SumUSDEngine.InsufficientPool.selector);
        engine.redeem(address(flavorB), 100e18, 0);
    }

    function test_Redeem_CrossCollateral() public {
        // Pool holds both flavor A and flavor C; a holder can redeem either flavor.
        _deposit(alice, flavorA, 1_000e6);
        _deposit(bob, flavorC, 1_000e18);

        vm.prank(alice);
        uint256 out = engine.redeem(address(flavorC), 100e18, 0);
        assertEq(out, 97e18, "alice redeems flavor C flavor though she deposited flavor A");
    }

    function test_Redeem_DepegBelowDistressForcesMix() public {
        // A hard depeg drops backing below the distress line (99%): single-flavor redeem is gated,
        // and holders exit pro-rata via redeemMix instead.
        _deposit(alice, flavorC, 1_000e18); // only C funded; supply 1000
        vm.prank(owner);
        oracle.setPrice(address(flavorC), 0.9e18); // backing 900/1000 = 90% < 99% -> distressed

        vm.prank(alice);
        vm.expectPartialRevert(SumUSDEngine.UseRedeemMix.selector);
        engine.redeem(address(flavorC), 90e18, 0);

        // Pro-rata exit: 90/1000 of the pool. Pool is only C (index 2), 1000e18 -> 90e18 C.
        uint256[] memory minOut = new uint256[](0);
        vm.prank(alice);
        uint256[] memory amounts = engine.redeemMix(90e18, minOut);
        assertEq(amounts[2], 90e18, "pro-rata slice of C");
    }

    // --- convex tilt: scarce-flavor protection (steep premium near depletion, never blocked) ---

    function test_Tilt_ScarceFlavorStillRedeemable() public {
        // A heavily under-represented flavor gets a steep convex haircut but is NEVER blocked
        // (a heavily under-represented flavor is steeply penalized but stays redeemable).
        _deposit(alice, flavorA, 1_000e6); // $1,000
        _deposit(bob, flavorC, 100e18); // $100 -> ~9% of basket (target 50%)
        vm.prank(owner);
        engine.setTiltSlopeBps(500);

        uint256 eff = engine.currentRedeemRateBps(address(flavorC));
        assertLt(eff, 9700, "scarce flavor is penalized below its base rate");
        assertGt(eff, 0, "but still redeemable, not floored to a revert");

        // A PARTIAL exit still succeeds, penalized. (The tilt is priced on the post-redemption basket,
        // so the rate a given size pays is strictly worse than the marginal quote above.)
        vm.prank(bob);
        uint256 out = engine.redeem(address(flavorC), 25e18, 0);
        assertGt(out, 0, "redemption of a scarce flavor succeeds (penalized, never blocked)");
        assertLt(out, (25e18 * eff) / BPS, "and pays less than the marginal quote: size is priced in");

        // Draining the WHOLE remaining position in one shot would price to zero, so it reverts rather
        // than burning for nothing. The holder exits in pieces, or via another flavor.
        vm.prank(bob);
        vm.expectPartialRevert(SumUSDEngine.ZeroCollateralOut.selector);
        engine.redeem(address(flavorC), 75e18, 0);
    }

    function test_Tilt_PenaltyGrowsAsFlavorDepletes() public {
        // Convexity: the haircut accelerates as a flavor's share shrinks.
        _deposit(alice, flavorA, 1_000e6);
        vm.prank(owner);
        engine.setTiltSlopeBps(500);

        _deposit(bob, flavorC, 300e18); // ~23% share
        uint256 effMild = engine.currentRedeemRateBps(address(flavorC));
        // Drain C so its share collapses, then re-quote: rate must be strictly lower (steeper).
        vm.prank(bob);
        engine.redeem(address(flavorC), 250e18, 0);
        uint256 effSteep = engine.currentRedeemRateBps(address(flavorC));
        assertLt(effSteep, effMild, "haircut steepens as the flavor depletes");
    }

    function test_Tilt_NearDepletionApproachesZeroNotRevert() public {
        // Dust-scarce flavor: rate clamps toward 0, redemption returns ~0 but does not revert.
        _deposit(alice, flavorA, 1_000_000e6);
        _deposit(bob, flavorC, 1e18); // ~0.0001% of basket
        vm.prank(owner);
        engine.setTiltSlopeBps(500);

        assertEq(engine.currentRedeemRateBps(address(flavorC)), 0, "dust-scarce flavor clamps to 0%");
        vm.prank(bob);
        uint256 out = engine.redeem(address(flavorC), 1e18, 0); // does not revert
        assertEq(out, 0);
    }

    // --- weight-tilted haircut ------------------------------------------

    function test_Tilt_DefaultIsFlatHaircut() public {
        // tiltSlopeBps defaults to 0 => currentRedeemRateBps == base rate regardless of weights.
        _deposit(alice, flavorA, 900e6);
        _deposit(bob, flavorC, 100e18);
        assertEq(engine.currentRedeemRateBps(address(flavorA)), BPS, "flat base for flavor A");
        assertEq(engine.currentRedeemRateBps(address(flavorC)), 9700, "flat base for flavor C");
    }

    function test_Tilt_WithinParityBand() public {
        // A 50/30/20 split is well inside the [1/2x, 2x] target band, so even a steep slope
        // leaves every flavor at its base rate — small imbalances are tolerated, not priced.
        vm.prank(owner);
        engine.setTiltSlopeBps(2000);
        _deposit(alice, flavorA, 500e6); // 50% (target 33.3%, band 16.66%..66.66%)
        _deposit(bob, flavorB, 300e6); // 30%
        _deposit(bob, flavorC, 200e18); // 20%
        assertEq(engine.currentRedeemRateBps(address(flavorA)), BPS, "A within band -> base");
        assertEq(engine.currentRedeemRateBps(address(flavorB)), BPS, "B within band -> base");
        assertEq(engine.currentRedeemRateBps(address(flavorC)), 9700, "C within band -> base");
    }

    function test_Tilt_RewardsOverweightPenalizesUnderweight() public {
        // Base 95% for all three, slope 0.1x. Pool flavor A $750 / flavor B $200 / flavor C $50
        // (total $1,000, target 3333 bps, parity band [1666, 6666] = 1/2x..2x target).
        vm.startPrank(owner);
        engine.setCollateral(address(flavorA), true, 9500, oracle);
        engine.setCollateral(address(flavorB), true, 9500, oracle);
        engine.setCollateral(address(flavorC), true, 9500, oracle);
        engine.setTiltSlopeBps(1000);
        vm.stopPrank();

        _deposit(alice, flavorA, 750e6); // share 7500 > 6666: discount 1000*(7500-6666)/10000=83 -> 9583
        _deposit(bob, flavorB, 200e6); // share 2000 in band -> parity 9500
        _deposit(bob, flavorC, 50e18); // share 500 < 1666: convex 1000*(1666-500)/500=2332 -> 7168

        assertEq(engine.currentRedeemRateBps(address(flavorA)), 9583, "overweight beyond 2x => discount");
        assertEq(engine.currentRedeemRateBps(address(flavorB)), 9500, "within parity band => base rate");
        assertEq(engine.currentRedeemRateBps(address(flavorC)), 7168, "below 1/2x => steep convex premium");
    }

    function test_Tilt_NeverExceedsOneHundredPct() public {
        // A heavily over-represented flavor with a steep slope must clamp the discount at 100%,
        // so a redemption can never return more than face value (over-collateralization preserved).
        vm.startPrank(owner);
        engine.setCollateral(address(flavorA), true, 9500, oracle); // base 95% leaves room to clamp
        engine.setTiltSlopeBps(5000);
        vm.stopPrank();
        _deposit(alice, flavorA, 900e6); // share 9000 >> 2x target: 9500 + big discount -> clamps
        _deposit(bob, flavorB, 50e6);
        _deposit(bob, flavorC, 50e18);
        assertEq(engine.currentRedeemRateBps(address(flavorA)), BPS, "clamped at 100%");
    }

    function test_Tilt_AppliedOnRedeemAndPreview() public {
        vm.startPrank(owner);
        engine.setCollateral(address(flavorA), true, 9500, oracle);
        engine.setCollateral(address(flavorC), true, 9500, oracle);
        engine.setTiltSlopeBps(1000);
        vm.stopPrank();

        // 3 funded, target 3333, band [1666, 6666]. A at 80% is beyond 2x target -> discount.
        _deposit(alice, flavorA, 800e6);
        _deposit(bob, flavorB, 100e6);
        _deposit(bob, flavorC, 100e18); // A share 8000 > 6666: 1000*(8000-6666)/10000=133 -> eff 9633

        // 9633 is the MARGINAL rate (share 8000, tilt 1000*(8000-6666)/10000 = 133 over the 9500 base).
        assertEq(engine.currentRedeemRateBps(address(flavorA)), 9633);

        // The rate an actual 100 SumUSD redemption pays is lower, because the tilt is priced on the
        // POST-redemption basket: A ends at 700/900 = 7777 bps, so the bonus is 1000*(7777-6666)/10000
        // = 111 over the 9500 base = 9611. Size is priced in rather than the whole trade clearing at the
        // marginal rate.
        assertEq(engine.redeemRateBpsFor(address(flavorA), 100e18), 9611, "size-aware rate is below marginal");

        uint256 quoted = engine.previewRedeem(address(flavorA), 100e18);
        vm.prank(alice);
        uint256 out = engine.redeem(address(flavorA), 100e18, 0);
        // netUsd = 100 * 0.9611 = $96.11 -> 96.11 flavor A (6 decimals).
        assertEq(out, 96_110000, "overweight redemption pays the tilt-improved rate");
        assertEq(quoted, out, "preview matches the actual tilted payout");
    }

    // --- views -----------------------------------------------------------

    function test_TotalCollateralValueAggregates() public {
        _deposit(alice, flavorA, 1_000e6);
        _deposit(bob, flavorC, 250e18);
        assertEq(engine.totalCollateralValueUsd(), 1_250e18, "basket value sums across flavors");
    }

    function test_PreviewMatchesActual() public {
        uint256 previewMint = engine.previewDeposit(address(flavorC), 400e18);
        uint256 minted = _deposit(alice, flavorC, 400e18);
        assertEq(previewMint, minted);

        uint256 previewOut = engine.previewRedeem(address(flavorC), 200e18);
        vm.prank(alice);
        uint256 out = engine.redeem(address(flavorC), 200e18, 0);
        assertEq(previewOut, out);
    }

    // --- admin / access control -----------------------------------------

    function test_SetCollateral_RevertsRedeemRateAbove100() public {
        vm.prank(owner);
        vm.expectPartialRevert(SumUSDEngine.InvalidRedeemRate.selector);
        engine.setCollateral(address(flavorA), true, uint16(BPS + 1), oracle);
    }

    function test_SetCollateral_RevertsRedeemRateBelowFloor() public {
        vm.prank(owner);
        vm.expectPartialRevert(SumUSDEngine.InvalidRedeemRate.selector);
        engine.setCollateral(address(flavorA), true, 9499, oracle); // just under the 95% floor
    }

    function test_SetCollateral_AllowedAtRails() public {
        vm.startPrank(owner);
        engine.setCollateral(address(flavorA), true, 9500, oracle); // exactly 95% floor
        engine.setCollateral(address(flavorB), true, uint16(BPS), oracle); // exactly 100% ceiling
        vm.stopPrank();
        (,, uint16 rA,,) = engine.configs(address(flavorA));
        (,, uint16 rB,,) = engine.configs(address(flavorB));
        assertEq(rA, 9500);
        assertEq(rB, uint16(BPS));
    }

    function test_SetCollateral_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        engine.setCollateral(address(flavorA), true, uint16(BPS), oracle);
    }

    function test_OnlyEngineCanMint() public {
        vm.prank(alice);
        vm.expectRevert();
        sumUsd.mint(alice, 1e18);
    }

    // --- guardian freeze -------------------------------------------------

    function test_Guardian_FreezeKeepsPenaltyDirectionButStillRedeemable() public {
        address guardian = makeAddr("guardian");
        vm.startPrank(owner);
        engine.setGuardian(guardian);
        // Sub-100% bases + a steep slope so the tilt (and its dependence on weights) is observable.
        engine.setCollateral(address(flavorA), true, 9500, oracle);
        engine.setCollateral(address(flavorB), true, 9500, oracle);
        engine.setCollateral(address(flavorC), true, 9500, oracle);
        engine.setTiltSlopeBps(1000);
        vm.stopPrank();
        _deposit(alice, flavorA, 700e6); // overweight (70%)
        _deposit(bob, flavorB, 200e6);
        _deposit(bob, flavorC, 100e18);

        uint256 rateBeforeA = engine.currentRedeemRateBps(address(flavorA)); // 9533 (slight discount)

        // Guardian freezes C instantly.
        vm.prank(guardian);
        engine.freezeCollateral(address(flavorC));
        (bool enabledC,,,,) = engine.configs(address(flavorC));
        assertFalse(enabledC, "C frozen");

        // Frozen C can no longer be DEPOSITED...
        flavorC.mint(alice, 1e18);
        vm.startPrank(alice);
        flavorC.approve(address(engine), 1e18);
        vm.expectPartialRevert(SumUSDEngine.CollateralNotEnabled.selector);
        engine.deposit(address(flavorC), 1e18, 0);
        vm.stopPrank();

        // ...but it stays REDEEMABLE, and because C is UNDER-represented (10% vs a 33% target) its
        // convex anti-drain penalty is KEPT even while frozen — it redeems below its 95% base, not at
        // base. (Penalty-direction-only: a freeze can discount a scarce flavor but never raise it.)
        uint256 frozenRateC = engine.currentRedeemRateBps(address(flavorC));
        assertEq(frozenRateC, 8834, "frozen underweight C keeps its convex penalty (below base)");
        // Redeem a PORTION: the whole position at once would price to zero on the post-redemption basket
        // (integrated pricing), which reverts rather than paying nothing.
        vm.prank(bob);
        uint256 outC = engine.redeem(address(flavorC), 25e18, 0);
        assertGt(outC, 0, "frozen C stays redeemable");
        assertLt(outC, (25e18 * frozenRateC) / BPS, "at the penalized rate (par), with size priced in");

        // A's weight/rate is recomputed over enabled flavors only (C dropped), so A's rate changes.
        assertTrue(engine.currentRedeemRateBps(address(flavorA)) != rateBeforeA, "weight excludes frozen C");
    }

    function test_Guardian_FreezeAllStillAllowsRedemption() public {
        address guardian = makeAddr("guardian");
        vm.prank(owner);
        engine.setGuardian(guardian);
        _deposit(alice, flavorA, 100e6); // alice holds 100e18 SumUSD; pool holds 100e6 A

        vm.startPrank(guardian); // freeze every flavor
        engine.freezeCollateral(address(flavorA));
        engine.freezeCollateral(address(flavorB));
        engine.freezeCollateral(address(flavorC));
        vm.stopPrank();

        // Deposits are blocked everywhere...
        flavorA.mint(alice, 1e6);
        vm.startPrank(alice);
        flavorA.approve(address(engine), 1e6);
        vm.expectPartialRevert(SumUSDEngine.CollateralNotEnabled.selector);
        engine.deposit(address(flavorA), 1e6, 0);
        // ...but holders can still exit at base par despite a total freeze (not trapped).
        uint256 out = engine.redeem(address(flavorA), 100e18, 0);
        vm.stopPrank();
        assertEq(out, 100e6, "freeze-all: redemption still works at base par");
    }

    function test_Guardian_OnlyGuardianCanFreeze() public {
        vm.prank(owner);
        engine.setGuardian(makeAddr("guardian"));
        vm.prank(alice); // not the guardian
        vm.expectRevert(SumUSDEngine.NotGuardian.selector);
        engine.freezeCollateral(address(flavorA));
    }

    function test_Guardian_CannotReEnable_OwnerCan() public {
        address guardian = makeAddr("guardian");
        vm.prank(owner);
        engine.setGuardian(guardian);
        vm.prank(guardian);
        engine.freezeCollateral(address(flavorA));

        // Guardian has no enable power; only the owner (timelock) can re-enable.
        vm.prank(guardian);
        vm.expectRevert(); // freezeCollateral only ever disables; there is no guardian enable path
        engine.setCollateralEnabled(address(flavorA), true); // onlyOwner -> reverts for guardian

        vm.prank(owner);
        engine.setCollateralEnabled(address(flavorA), true);
        (bool enabledA,,,,) = engine.configs(address(flavorA));
        assertTrue(enabledA, "owner re-enabled");
    }

    function test_Guardian_SetGuardianOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        engine.setGuardian(alice);
    }

    // --- oracle resilience (fix #1) -------------------------------------

    function test_Oracle_DeadFeedIsResilient() public {
        _deposit(alice, flavorA, 1_000e6); // $1,000
        address ch = makeAddr("ch");
        _deposit(ch, flavorC, 5e18); // $5 (small)

        vm.prank(owner);
        oracle.setPrice(address(flavorC), 0); // MockOracle now reverts for C ("no price")

        // A dead feed contributes 0, not a revert, to basket-wide loops.
        assertEq(engine.collateralValueUsd(address(flavorC)), 0, "dead feed -> 0 value, no revert");
        // Backing ~ 1000/1005 = 99.5% >= 99%, so other deposits keep working.
        assertEq(_deposit(alice, flavorA, 100e6), 100e18, "other deposits unaffected by a dead feed");
        // Healthy flavor still redeemable.
        vm.prank(alice);
        assertGt(engine.redeem(address(flavorA), 100e18, 0), 0);
        // The dead-oracle flavor falls back to its flat base rate (97%) at par — holders still exit.
        vm.prank(ch);
        assertEq(engine.redeem(address(flavorC), 5e18, 0), 4_850000000000000000, "base-rate par fallback");
    }

    function test_Oracle_DeadFeedHaltsMintRedeemViaMix() public {
        _deposit(alice, flavorA, 1_000e6);
        _deposit(bob, flavorB, 1_000e6); // supply 2000
        vm.prank(owner);
        oracle.setPrice(address(flavorA), 0); // kill a large feed -> backing = B only (50%) -> distressed

        // Minting halts (conservative).
        flavorB.mint(alice, 100e6);
        vm.startPrank(alice);
        flavorB.approve(address(engine), 100e6);
        vm.expectPartialRevert(SumUSDEngine.UnderCollateralized.selector);
        engine.deposit(address(flavorB), 100e6, 0);
        vm.stopPrank();

        // Single-flavor redeem is gated (distressed)...
        vm.prank(bob);
        vm.expectPartialRevert(SumUSDEngine.UseRedeemMix.selector);
        engine.redeem(address(flavorB), 100e18, 0);

        // ...but pro-rata exit works even with a dead feed (payout is balance-based, no oracle):
        // bob burns 100/2000 of supply -> 100/2000 of the pool (A 1000e6, B 1000e6).
        uint256[] memory minOut = new uint256[](0);
        vm.prank(bob);
        uint256[] memory amounts = engine.redeemMix(100e18, minOut);
        assertEq(amounts[0], 50e6, "slice of A (dead feed, still distributed)");
        assertEq(amounts[1], 50e6, "slice of B");
    }

    // --- tilt slope rail (fix #3) ---------------------------------------

    function test_SetTiltSlope_RevertsAboveRail() public {
        vm.prank(owner);
        vm.expectPartialRevert(SumUSDEngine.InvalidTiltSlope.selector);
        engine.setTiltSlopeBps(5001); // above MAX_TILT_SLOPE_BPS
    }

    function test_SetTiltSlope_AllowedAtRail() public {
        vm.prank(owner);
        engine.setTiltSlopeBps(5000); // exactly the rail
        assertEq(engine.tiltSlopeBps(), 5000);
    }

    // --- setCollateral listing sanity probe (#8) ------------------------

    function test_SetCollateral_RevertsDecimalsTooHigh() public {
        MockERC20 big = new MockERC20("Big", "BIG", 24); // > MAX_COLLATERAL_DECIMALS (18)
        vm.prank(owner);
        vm.expectPartialRevert(SumUSDEngine.InvalidCollateralDecimals.selector);
        engine.setCollateral(address(big), true, 9900, oracle);
    }

    function test_SetCollateral_AllowsDecimalsAtRail() public {
        MockERC20 t18 = new MockERC20("Eighteen", "T18", 18); // exactly at the rail
        vm.prank(owner);
        engine.setCollateral(address(t18), true, 9900, oracle);
        (, uint8 dec,,,) = engine.configs(address(t18));
        assertEq(dec, 18, "18-decimal token listed and cached");
    }

    function test_SetCollateral_RevertsOnNonConformingToken() public {
        // Implements decimals() but reverts on balanceOf -> fails the conformance probe.
        RevertingBalanceMock bad = new RevertingBalanceMock();
        vm.prank(owner);
        vm.expectPartialRevert(SumUSDEngine.CollateralProbeFailed.selector);
        engine.setCollateral(address(bad), true, 9900, oracle);
    }

    function test_SetCollateral_RevertsOnNonToken() public {
        // A plain address with no code can't answer decimals()/balanceOf() -> probe fails.
        vm.prank(owner);
        vm.expectPartialRevert(SumUSDEngine.CollateralProbeFailed.selector);
        engine.setCollateral(makeAddr("notAToken"), true, 9900, oracle);
    }

    // --- collateral list cap & removal (fix #4) -------------------------

    function _listFreshFlavor() internal returns (MockERC20 t) {
        t = new MockERC20("X", "X", 6);
        oracle.setPrice(address(t), WAD);
        vm.prank(owner);
        engine.setCollateral(address(t), true, 9900, oracle);
    }

    function test_Collateral_CapEnforced() public {
        // setUp lists 3; fill to the cap (MAX_COLLATERALS = 24), then the next NEW listing reverts.
        while (engine.collateralCount() < 24) {
            _listFreshFlavor();
        }
        assertEq(engine.collateralCount(), 24);
        MockERC20 over = new MockERC20("Y", "Y", 6);
        vm.prank(owner);
        vm.expectPartialRevert(SumUSDEngine.CollateralCapReached.selector);
        engine.setCollateral(address(over), true, 9900, oracle);
    }

    function test_RemoveCollateral_FreesSlot() public {
        MockERC20 d = _listFreshFlavor(); // 4th, enabled, empty
        uint256 n = engine.collateralCount();
        vm.startPrank(owner);
        engine.setCollateralEnabled(address(d), false); // must be disabled first
        engine.removeCollateral(address(d));
        vm.stopPrank();
        assertEq(engine.collateralCount(), n - 1, "slot freed");
        // Config cleared, so it can be listed fresh again.
        vm.prank(owner);
        engine.setCollateral(address(d), true, 9900, oracle);
        assertEq(engine.collateralCount(), n);
    }

    function test_RemoveCollateral_RevertsIfEnabled() public {
        MockERC20 d = _listFreshFlavor();
        vm.prank(owner);
        vm.expectPartialRevert(SumUSDEngine.CollateralStillEnabled.selector);
        engine.removeCollateral(address(d));
    }

    function test_RemoveCollateral_RevertsIfNotEmpty() public {
        MockERC20 d = _listFreshFlavor();
        _deposit(alice, d, 10e6); // d now holds a balance
        vm.startPrank(owner);
        engine.setCollateralEnabled(address(d), false);
        vm.expectPartialRevert(SumUSDEngine.CollateralNotEmpty.selector);
        engine.removeCollateral(address(d));
        vm.stopPrank();
    }

    function test_RemoveCollateral_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        engine.removeCollateral(address(flavorA));
    }

    // --- distress-mode 99% trigger --------------------------------------
    // Distress is a pure function of the backing ratio vs DISTRESS_RATIO_BPS (99%). A single 18-decimal
    // flavor gives exact control: backing = 1000 * price, supply = 1000, so ratioBps = price * 10000.

    function test_Distress_NotTriggeredAtExactly99Pct() public {
        _deposit(alice, flavorC, 1_000e18); // 100%
        vm.prank(owner);
        oracle.setPrice(address(flavorC), 0.99e18); // backing 990/1000 -> exactly 99%
        assertEq(engine.systemCollateralizationRatioBps(), 9900, "sits exactly on the distress line");

        // The boundary is exclusive: at exactly 99% the system is NOT distressed. redeemMix is blocked...
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        vm.expectPartialRevert(SumUSDEngine.NotDistressed.selector);
        engine.redeemMix(10e18, none);

        // ...and single-flavor redeem is still the live path.
        vm.prank(alice);
        assertGt(engine.redeem(address(flavorC), 10e18, 0), 0, "single-flavor redeem works at exactly 99%");
    }

    function test_Distress_TriggeredJustBelow99Pct() public {
        _deposit(alice, flavorC, 1_000e18);
        vm.prank(owner);
        oracle.setPrice(address(flavorC), 0.9899e18); // backing 989.9/1000 -> 98.99%, one bp under the floor
        assertEq(engine.systemCollateralizationRatioBps(), 9899, "just below the distress line");

        // Single-flavor (cherry-pick) redeem is disabled...
        vm.prank(alice);
        vm.expectPartialRevert(SumUSDEngine.UseRedeemMix.selector);
        engine.redeem(address(flavorC), 10e18, 0);

        // ...minting is halted at the same 99% line...
        flavorA.mint(bob, 100e6);
        vm.startPrank(bob);
        flavorA.approve(address(engine), 100e6);
        vm.expectPartialRevert(SumUSDEngine.UnderCollateralized.selector);
        engine.deposit(address(flavorA), 100e6, 0);
        vm.stopPrank();

        // ...and holders exit pro-rata via redeemMix (10% of the pool for a 100/1000 burn).
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        uint256[] memory amounts = engine.redeemMix(100e18, none);
        assertEq(amounts[2], 100e18, "pro-rata slice of flavor C (index 2 in the collateral list)");
    }

    function test_Distress_SelfHealsWhenBackingRecovers() public {
        _deposit(alice, flavorC, 1_000e18);
        vm.prank(owner);
        oracle.setPrice(address(flavorC), 0.95e18); // 95% -> distressed
        vm.prank(alice);
        vm.expectPartialRevert(SumUSDEngine.UseRedeemMix.selector);
        engine.redeem(address(flavorC), 10e18, 0);

        // Distress is a condition, not a latch: when the feed recovers, the ratio climbs back over 99%
        // and normal operation resumes automatically, no admin action.
        vm.prank(owner);
        oracle.setPrice(address(flavorC), 1e18);
        assertEq(engine.systemCollateralizationRatioBps(), BPS, "recovered to 100%");

        vm.prank(alice);
        assertGt(engine.redeem(address(flavorC), 10e18, 0), 0, "single-flavor redeem restored");
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        vm.expectPartialRevert(SumUSDEngine.NotDistressed.selector);
        engine.redeemMix(10e18, none); // redeemMix dormant again
    }

    // --- pro-rata redeemMix (option b) ----------------------------------

    function test_RedeemMix_FairAndOrderIndependent() public {
        address carol = makeAddr("carol");
        _deposit(alice, flavorA, 600e6); // 600 SumUSD
        _deposit(bob, flavorB, 300e6); // 300
        _deposit(carol, flavorC, 100e18); // 100; supply 1000
        vm.prank(owner);
        oracle.setPrice(address(flavorC), 0.5e18); // backing 950/1000 = 95% -> distressed

        uint256[] memory none = new uint256[](0);
        // Alice (600/1000) exits first.
        vm.prank(alice);
        uint256[] memory aOut = engine.redeemMix(600e18, none);
        assertEq(aOut[0], 360e6, "A slice");
        assertEq(aOut[1], 180e6, "B slice");
        assertEq(aOut[2], 60e18, "C slice");
        // Bob (300/1000) exits AFTER alice but still gets 30% of the ORIGINAL pool — order-independent.
        vm.prank(bob);
        uint256[] memory bOut = engine.redeemMix(300e18, none);
        assertEq(bOut[0], 180e6);
        assertEq(bOut[1], 90e6);
        assertEq(bOut[2], 30e18);
    }

    function test_RedeemMix_RevertsWhenHealthy() public {
        _deposit(alice, flavorA, 100e6);
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        vm.expectPartialRevert(SumUSDEngine.NotDistressed.selector);
        engine.redeemMix(50e18, none);
    }

    function test_RedeemMix_MinOutLengthMismatch() public {
        _deposit(alice, flavorC, 1_000e18);
        vm.prank(owner);
        oracle.setPrice(address(flavorC), 0.9e18); // distressed
        uint256[] memory bad = new uint256[](2); // collateralList length is 3
        vm.prank(alice);
        vm.expectPartialRevert(SumUSDEngine.MinOutLengthMismatch.selector);
        engine.redeemMix(10e18, bad);
    }

    function test_RedeemMix_SkipsBlacklistedTransfer() public {
        BlacklistMockERC20 bad = new BlacklistMockERC20("Bad", "BAD", 6); // 4th collateral (index 3)
        oracle.setPrice(address(bad), WAD);
        vm.prank(owner);
        engine.setCollateral(address(bad), true, 9900, oracle);

        _deposit(alice, flavorA, 600e6); // 600 SumUSD
        bad.mint(bob, 400e6);
        vm.startPrank(bob);
        bad.approve(address(engine), 400e6);
        engine.deposit(address(bad), 400e6, 0); // 400 SumUSD; supply 1000
        vm.stopPrank();

        // Depeg BAD -> distressed; then its issuer blacklists the engine (transfers revert).
        vm.prank(owner);
        oracle.setPrice(address(bad), 0.5e18); // backing 800/1000 = 80%
        bad.setBlocked(true);

        // The pro-rata exit still succeeds: alice gets her A slice; the un-transferable BAD slice is
        // skipped (reported 0, stays pooled) instead of bricking the whole redemption.
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        uint256[] memory amounts = engine.redeemMix(600e18, none);

        assertEq(amounts[0], 360e6, "A delivered (600/1000 of 600e6)");
        assertEq(amounts[3], 0, "BAD slice skipped (transfer blocked)");
        assertEq(flavorA.balanceOf(alice), 360e6, "alice received A");
        assertEq(bad.balanceOf(alice), 0, "alice received no BAD");
        assertEq(bad.balanceOf(address(engine)), 400e6, "skipped BAD slice stays pooled");
        assertEq(sumUsd.balanceOf(alice), 0, "alice's SumUSD burned in full");
    }

    function test_RedeemMix_PreviewMatches() public {
        _deposit(alice, flavorA, 500e6);
        _deposit(bob, flavorC, 500e18);
        vm.prank(owner);
        oracle.setPrice(address(flavorC), 0.8e18); // backing 900/1000 = 90% -> distressed

        (, uint256[] memory preview) = engine.previewRedeemMix(200e18);
        uint256[] memory none = new uint256[](0);
        vm.prank(alice);
        uint256[] memory actual = engine.redeemMix(200e18, none);
        assertEq(preview[0], actual[0]);
        assertEq(preview[1], actual[1]);
        assertEq(preview[2], actual[2]);
    }

    // --- fuzz ------------------------------------------------------------

    function testFuzz_DepositRedeemRoundTrip_FullRate(uint256 amount) public {
        amount = bound(amount, 1e6, 10_000_000e6);
        uint256 minted = _deposit(alice, flavorA, amount);
        vm.prank(alice);
        uint256 out = engine.redeem(address(flavorA), minted, 0);
        // Full-rate, $1 price: round trip returns the original collateral (modulo wei rounding).
        assertApproxEqAbs(out, amount, 1, "full-rate round trip is ~lossless");
    }

    function testFuzz_BackingNeverBelowSupply(uint256 a, uint256 b) public {
        a = bound(a, 1e6, 1_000_000e6);
        b = bound(b, 1e18, 1_000_000e18);
        _deposit(alice, flavorA, a);
        _deposit(bob, flavorC, b);
        // Redeem a chunk of the haircut flavor.
        vm.prank(bob);
        engine.redeem(address(flavorC), b / 2, 0);
        assertGe(engine.systemCollateralizationRatioBps(), BPS, "system stays >= 100% collateralized");
    }

    // --- poolNeeds skips unpriceable flavors (tier 2) -------------------

    function test_PoolNeeds_ReturnsSmallestPriceable() public {
        _deposit(alice, flavorA, 300e6); // $300
        _deposit(bob, flavorB, 200e6); // $200
        // flavorC left empty ($0) but priceable -> it is the most under-represented.
        assertEq(engine.poolNeeds(), address(flavorC), "empty-but-priceable flavor is surfaced");
    }

    function test_PoolNeeds_SkipsUnpriceableFlavor() public {
        _deposit(alice, flavorA, 300e6); // $300
        _deposit(bob, flavorB, 200e6); // $200
        _deposit(bob, flavorC, 100e18); // $100 (smallest priceable)

        vm.prank(owner);
        oracle.setPrice(address(flavorB), 0); // B feed dead -> B reads 0 value, but is undepositable

        // Without the skip, B (value 0) would be chosen; with it, the smallest PRICEABLE flavor wins.
        assertEq(engine.poolNeeds(), address(flavorC), "dead-feed flavor skipped, smallest priceable chosen");
    }

    // --- donate: first-class recapitalization (tier 2) ------------------

    function _donate(address from, MockERC20 t, uint256 amount) internal returns (uint256) {
        t.mint(from, amount);
        vm.startPrank(from);
        t.approve(address(engine), amount);
        uint256 received = engine.donate(address(t), amount);
        vm.stopPrank();
        return received;
    }

    function test_Donate_RaisesBackingWithoutMinting() public {
        _deposit(alice, flavorA, 100e6); // supply 100e18, backing $100
        uint256 supplyBefore = sumUsd.totalSupply();

        uint256 received = _donate(bob, flavorA, 50e6);

        assertEq(received, 50e6, "received the donated amount");
        assertEq(sumUsd.totalSupply(), supplyBefore, "no SumUSD minted by a donation");
        assertEq(engine.totalCollateralValueUsd(), 150e18, "backing rose by the donation");
        assertEq(engine.systemCollateralizationRatioBps(), 15_000, "ratio now 150%");
    }

    function test_Donate_RecapitalizesToReenableMinting() public {
        _deposit(alice, flavorA, 100e6);
        _deposit(bob, flavorB, 100e6); // supply 200e18
        vm.prank(owner);
        oracle.setPrice(address(flavorB), 0.9e18); // backing 190/200 = 95% -> minting frozen

        // A fresh mint is blocked below the 99% floor.
        flavorA.mint(alice, 1e6);
        vm.startPrank(alice);
        flavorA.approve(address(engine), 1e6);
        vm.expectPartialRevert(SumUSDEngine.UnderCollateralized.selector);
        engine.deposit(address(flavorA), 1e6, 0);
        vm.stopPrank();

        // Anyone donates to lift backing back to >= 99% (110 + 90 = 200 vs 200 supply -> 100%).
        _donate(makeAddr("whitehat"), flavorA, 10e6);
        assertGe(engine.systemCollateralizationRatioBps(), 9900, "backing recapitalized above the floor");

        // Minting self-heals -> the same deposit now succeeds.
        assertEq(_deposit(alice, flavorA, 1e6), 1e18, "minting re-enabled after recap");
    }

    function test_Donate_WorksForFrozenCollateral() public {
        address guardian = makeAddr("guardian");
        vm.prank(owner);
        engine.setGuardian(guardian);
        _deposit(alice, flavorA, 100e6);
        vm.prank(guardian);
        engine.freezeCollateral(address(flavorA)); // frozen but still listed + backing

        uint256 received = _donate(bob, flavorA, 25e6);
        assertEq(received, 25e6, "a frozen-but-listed collateral can still be donated");
        assertEq(engine.totalCollateralValueUsd(), 125e18, "frozen donation still counts toward backing");
    }

    function test_Donate_RevertsUnlisted() public {
        MockERC20 stray = new MockERC20("Z", "Z", 6);
        stray.mint(bob, 10e6);
        vm.startPrank(bob);
        stray.approve(address(engine), 10e6);
        vm.expectPartialRevert(SumUSDEngine.CollateralNotEnabled.selector);
        engine.donate(address(stray), 10e6);
        vm.stopPrank();
    }

    function test_Donate_RevertsZeroAmount() public {
        vm.prank(bob);
        vm.expectRevert(SumUSDEngine.ZeroAmount.selector);
        engine.donate(address(flavorA), 0);
    }

    // --- a listed flavor whose balanceOf starts reverting -----------------------------------------------
    // The listing probe checks balanceOf once; an upgradeable token can break AFTER listing. That must not
    // brick the basket-wide loops (every deposit/redeem/view) or the pro-rata distress exit: the broken
    // flavor values at 0 (conservative), distress triggers honestly, and redeemMix skips its slice.

    function test_BrickedBalanceOf_NeverBricksBasketOrDistressExit() public {
        ToggleBalanceMockERC20 bad = new ToggleBalanceMockERC20("Bad", "BAD", 6);
        oracle.setPrice(address(bad), WAD);
        vm.prank(owner);
        engine.setCollateral(address(bad), true, uint16(BPS), oracle);
        _deposit(alice, flavorA, 1_000e6);
        bad.mint(alice, 1_000e6);
        vm.startPrank(alice);
        bad.approve(address(engine), 1_000e6);
        engine.deposit(address(bad), 1_000e6, 0);
        vm.stopPrank();
        assertEq(engine.systemCollateralizationRatioBps(), BPS);

        bad.setBalanceReverts(true);

        // Basket loops keep working; the broken flavor counts 0 so the ratio is honest and distress latches.
        assertEq(engine.collateralValueUsd(address(bad)), 0, "unreadable balance values at 0");
        assertEq(engine.systemCollateralizationRatioBps(), 5000, "ratio reflects the unreachable half");
        assertTrue(engine.poolNeeds() != address(bad), "poolNeeds never steers deposits into the unreadable flavor");
        engine.pokeDistress();
        assertTrue(engine.distressed());

        // The pro-rata exit still pays every readable flavor and reports 0 for the broken one.
        (, uint256[] memory quoted) = engine.previewRedeemMix(1_000e18);
        vm.prank(alice);
        uint256[] memory paid = engine.redeemMix(1_000e18, new uint256[](0));
        assertEq(paid.length, 4);
        assertEq(paid[0], 500e6, "A slice paid");
        assertEq(paid[3], 0, "broken flavor skipped, not reverted");
        assertEq(quoted[0], paid[0]);
        assertEq(quoted[3], 0);
        assertEq(flavorA.balanceOf(alice), 500e6);
        assertEq(sumUsd.balanceOf(alice), 1_000e18);
    }

    // --- redeemMix par cap ------------------------------------------------------------------------------

    function test_RedeemMix_BelowParPaysFullSliceAboveParPaysDollar() public {
        _deposit(alice, flavorA, 1_000e6);
        _deposit(alice, flavorB, 1_000e6);
        oracle.setPrice(address(flavorB), 0.9e18); // 95% backed: latched, slices are NOT scaled (ratio < 100%)
        engine.pokeDistress();
        assertTrue(engine.distressed());
        vm.prank(alice);
        uint256[] memory outs = engine.redeemMix(200e18, new uint256[](0));
        assertEq(outs[0], 100e6, "under par: full pro-rata slice of A");
        assertEq(outs[1], 100e6, "under par: full pro-rata slice of B");

        // A recap above par: slices scale by 1/ratio, minOut is checked against the SCALED amount.
        flavorA.mint(bob, 300e6);
        vm.startPrank(bob);
        flavorA.approve(address(engine), 300e6);
        engine.donate(address(flavorA), 300e6);
        vm.stopPrank();
        oracle.setPrice(address(flavorB), WAD);
        // pool: 1,200 A + 900 B = $2,100 against 1,800 supply -> 116.66%
        assertEq(engine.systemCollateralizationRatioBps(), 11_666);
        uint256 backing = engine.totalCollateralValueUsd(); // 2,100e18
        uint256[] memory minOut = new uint256[](3);
        minOut[0] = (1_200e6 * 180e18 / 1_800e18) * 1_800e18 / backing; // exactly the capped slice
        vm.prank(alice);
        outs = engine.redeemMix(180e18, minOut);
        assertEq(outs[0], minOut[0], "A slice scaled by supply/backing");
        assertEq(outs[1], (900e6 * 180e18 / 1_800e18) * 1_800e18 / backing, "B slice scaled by supply/backing");
        assertLe((outs[0] + outs[1]) * 1e12, 180e18, "<= $1 per SumUSD");
        assertGe((outs[0] + outs[1]) * 1e12, 180e18 - 1e13, "and within rounding of $1");
        minOut[0] += 1;
        vm.prank(alice);
        vm.expectPartialRevert(SumUSDEngine.SlippageExceeded.selector);
        engine.redeemMix(180e18, minOut);
    }

    function test_Deposit_BlockedWhileLatchedEvenAboveMintFloor() public {
        _deposit(alice, flavorA, 1_000e6);
        oracle.setPrice(address(flavorA), 0.98e18); // 98%: latched
        engine.pokeDistress();
        assertTrue(engine.distressed());
        oracle.setPrice(address(flavorA), WAD); // back to 100%: still latched (needs 100.25% held 6h)
        flavorA.mint(bob, 10e6);
        vm.startPrank(bob);
        flavorA.approve(address(engine), 10e6);
        vm.expectPartialRevert(SumUSDEngine.MintDisabledInDistress.selector);
        engine.deposit(address(flavorA), 10e6, 0);
        vm.stopPrank();
        // Once the latch clears, minting resumes with no admin action.
        flavorA.mint(bob, 3e6);
        vm.startPrank(bob);
        flavorA.approve(address(engine), 3e6);
        engine.donate(address(flavorA), 3e6); // 100.3%
        vm.stopPrank();
        vm.warp(block.timestamp + 6 hours);
        engine.pokeDistress();
        assertFalse(engine.distressed());
        assertEq(_deposit(bob, flavorA, 10e6), 10e18, "minting resumes after recovery");
    }
}
