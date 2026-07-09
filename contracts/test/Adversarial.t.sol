// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SumUSD} from "../src/SumUSD.sol";
import {SumUSDEngine} from "../src/SumUSDEngine.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

/// @notice Adversarial / exploit attempts against the engine. Each test either DEMONSTRATES a
///         value leak / liveness issue (named test_Attack_*) or CONFIRMS a defense holds
///         (test_Defense_*). Run: forge test --match-contract AdversarialTest -vv
contract AdversarialTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;

    SumUSD internal sumUsd;
    SumUSDEngine internal engine;
    MockOracle internal oracle;
    MockERC20 internal a; // 6 dec
    MockERC20 internal b; // 6 dec
    MockERC20 internal c; // 18 dec

    function setUp() public {
        sumUsd = new SumUSD(address(this));
        engine = new SumUSDEngine(address(this), sumUsd);
        sumUsd.grantRole(sumUsd.MINTER_ROLE(), address(engine));

        oracle = new MockOracle();
        a = new MockERC20("Flavor A", "FLAV-A", 6);
        b = new MockERC20("Flavor B", "FLAV-B", 6);
        c = new MockERC20("Flavor C", "FLAV-C", 18);
        oracle.setPrice(address(a), WAD);
        oracle.setPrice(address(b), WAD);
        oracle.setPrice(address(c), WAD);

        // Reference parameters.
        engine.setCollateral(address(a), true, 9900, oracle);
        engine.setCollateral(address(b), true, 9900, oracle);
        engine.setCollateral(address(c), true, 9700, oracle);
        engine.setTiltSlopeBps(500);
    }

    function _deposit(address user, MockERC20 t, uint256 amount) internal returns (uint256) {
        t.mint(user, amount);
        vm.startPrank(user);
        t.approve(address(engine), amount);
        uint256 minted = engine.deposit(address(t), amount, 0);
        vm.stopPrank();
        return minted;
    }

    // -----------------------------------------------------------------
    // ATTACK 1 — round-trip arbitrage: mint a sub-par (but in-band) flavor
    // at par, redeem an over-represented flavor whose tilted rate clamps to
    // 100%. The peg-band gap is extracted from the pool on every cycle.
    // -----------------------------------------------------------------
    function test_Attack_RoundTripArbExtractsValue() public {
        address lp = makeAddr("lp");
        _deposit(lp, b, 900e6); // B heavily over-represented (90%, well beyond 2x target)
        _deposit(lp, a, 50e6);
        _deposit(lp, c, 50e18);
        assertEq(engine.currentRedeemRateBps(address(b)), BPS, "B redeems at 100% (discount clamps)");

        // Flavor A trades 0.5% below peg — inside the 0.5% deposit band.
        oracle.setPrice(address(a), 0.995e18);

        address attacker = makeAddr("attacker");
        a.mint(attacker, 100e6); // acquired at market: 100 A == $99.5
        uint256 startValueWad = (100e6 * 0.995e18) / 1e6; // 99.5e18

        vm.startPrank(attacker);
        a.approve(address(engine), 100e6);
        uint256 minted = engine.deposit(address(a), 100e6, 0); // mints 100 SumUSD at par
        uint256 gotB = engine.redeem(address(b), minted, 0); // redeem B at 100%
        vm.stopPrank();

        uint256 endValueWad = (gotB * 1e18) / 1e6; // B at $1
        emit log_named_decimal_uint("attacker start USD", startValueWad, 18);
        emit log_named_decimal_uint("attacker end USD  ", endValueWad, 18);
        assertGt(endValueWad, startValueWad, "ATTACK SUCCEEDS: attacker extracted pool value");
    }

    // -----------------------------------------------------------------
    // PROPERTY — a heavily under-represented flavor stays redeemable (steeply penalized but never
    // blocked), and a whale inflating the basket cannot freeze redemptions: the convex tilt only
    // prices, it never gates.
    // -----------------------------------------------------------------
    function test_Fix_ScarceFlavorPenalizedButRedeemable() public {
        _deposit(makeAddr("lp1"), a, 1_000e6);
        _deposit(makeAddr("lp2"), b, 1_000e6);
        address cHolder = makeAddr("cHolder");
        _deposit(cHolder, c, 50e18); // a tiny, heavily under-represented flavor

        assertLt(engine.currentRedeemRateBps(address(c)), 9700, "scarce flavor is convex-penalized");
        vm.prank(cHolder);
        uint256 out = engine.redeem(address(c), 10e18, 0);
        assertGt(out, 0, "but it is redeemable (penalized, not floored to a revert)");
    }

    function test_Fix_WhaleCannotFreezeRedemptions() public {
        _deposit(makeAddr("lp"), a, 100e6);
        _deposit(makeAddr("lp2"), b, 100e6);
        address cHolder = makeAddr("cHolder");
        _deposit(cHolder, c, 100e18);
        _deposit(makeAddr("whale"), a, 10_000e6); // a whale inflates the basket

        // No longer reverts — the convex tilt just prices C; the call completes.
        vm.prank(cHolder);
        engine.redeem(address(c), 1e18, 0);
    }

    // -----------------------------------------------------------------
    // DEFENSE — the 0.5% peg band + 99% mint floor leave a margin, so even an
    // unbounded sub-par (in-band) deposit cannot drive backing below 99% and
    // DoS minting for everyone.
    // -----------------------------------------------------------------
    function test_Defense_MintGuardMarginHoldsForInBandDeposits() public {
        _deposit(makeAddr("lp"), a, 1_000e6); // ratio 100%
        oracle.setPrice(address(b), 0.995e18); // worst in-band sub-par
        _deposit(makeAddr("atk"), b, 1_000_000e6); // huge sub-par deposit

        uint256 ratio = engine.systemCollateralizationRatioBps();
        emit log_named_uint("resulting ratio bps", ratio);
        assertGe(ratio, 9900, "in-band deposits cannot push backing below the 99% mint floor");
    }

    // -----------------------------------------------------------------
    // DEFENSE — privileged functions are owner/role gated.
    // -----------------------------------------------------------------
    function test_Defense_AccessControl() public {
        address rando = makeAddr("rando");
        vm.startPrank(rando);
        vm.expectRevert();
        engine.setCollateral(address(a), true, 9900, oracle);
        vm.expectRevert();
        engine.setTiltSlopeBps(5000);
        vm.expectRevert();
        sumUsd.mint(rando, 1e18); // only MINTER_ROLE (the engine)
        vm.expectRevert();
        sumUsd.burn(rando, 0);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // DEFENSE — no ERC4626-style first-depositor/donation inflation: minting
    // is unit-based, so a direct token donation can't distort the mint rate
    // for the next depositor.
    // -----------------------------------------------------------------
    function test_Defense_DonationDoesNotDistortMintRate() public {
        a.mint(address(engine), 500e6); // donate collateral, no SumUSD minted
        uint256 minted = _deposit(makeAddr("u"), a, 100e6);
        assertEq(minted, 100e18, "mint stays 1:1; donations can't dilute new minters");
    }

    // -----------------------------------------------------------------
    // PROPERTY — a dust redemption (positive rate, but input too small to yield any collateral) now
    // REVERTS instead of burning SumUSD for nothing. The user keeps their balance; the foot-gun is
    // closed. (A rate-0 depleted flavor is a separate case — see the near-depletion test.)
    // -----------------------------------------------------------------
    function test_DustRedeemRevertsNotBurns() public {
        _deposit(makeAddr("lp"), a, 1_000e6);
        address u = makeAddr("u");
        _deposit(u, a, 1e6); // u holds 1e18 SumUSD; A is the only funded flavor (tilt disabled, rate 100%)

        uint256 supplyBefore = sumUsd.totalSupply();
        vm.prank(u);
        vm.expectPartialRevert(SumUSDEngine.ZeroCollateralOut.selector);
        engine.redeem(address(a), 100, 0); // 100 wei SumUSD -> rounds to 0 collateral -> revert
        assertEq(sumUsd.totalSupply(), supplyBefore, "no SumUSD burned; the holder keeps their balance");
    }

    // -----------------------------------------------------------------
    // PROPERTY — freezing keeps the tilt in the PENALTY direction only. A heavily UNDER-represented
    // flavor carrying a steep convex penalty KEEPS that penalty once frozen (it is not snapped back
    // up to base), so freezing a scarce flavor can never make it cheaper to drain. The frozen
    // flavor's share is measured on the basket augmented with itself, so the penalty is unchanged
    // by the freeze; the views and the actual redeem agree.
    // -----------------------------------------------------------------
    function test_Freeze_KeepsConvexUnderweightPenalty() public {
        engine.setGuardian(address(this));
        _deposit(makeAddr("lp"), a, 1_000e6); // A dominates the basket
        address u = makeAddr("u");
        _deposit(u, b, 20e6); // B heavily under-represented -> convex penalty engaged

        uint256 tiltedRate = engine.currentRedeemRateBps(address(b));
        assertLt(tiltedRate, 9900, "while enabled, the scarce flavor is convex-penalized below base");

        engine.freezeCollateral(address(b));

        uint256 frozenRate = engine.currentRedeemRateBps(address(b));
        assertEq(frozenRate, tiltedRate, "freeze PRESERVES the convex penalty (penalty-direction tilt kept)");
        assertLt(frozenRate, 9900, "a frozen scarce flavor is NOT raised to base rate");

        // Still fully redeemable at the penalized rate, and the preview matches the actual payout.
        uint256 quoted = engine.previewRedeem(address(b), 1e18);
        vm.prank(u);
        uint256 out = engine.redeem(address(b), 1e18, 0);
        assertGt(out, 0, "frozen scarce flavor stays redeemable");
        assertEq(out, quoted, "preview matches the frozen-flavor payout (views == redeem)");
    }

    // -----------------------------------------------------------------
    // PROPERTY — the other half of penalty-direction-only: an OVER-represented flavor loses its
    // overweight bonus when frozen (capped at base), so a freeze never raises a flavor's rate.
    // -----------------------------------------------------------------
    function test_Freeze_DropsOverweightBonus() public {
        engine.setGuardian(address(this));
        _deposit(makeAddr("lp"), a, 900e6); // A over-represented -> bonus (rate clamps up toward 100%)
        _deposit(makeAddr("lp2"), b, 50e6);
        _deposit(makeAddr("lp3"), c, 50e18);

        uint256 enabledRate = engine.currentRedeemRateBps(address(a));
        assertGt(enabledRate, 9900, "while enabled, overweight A gets a bonus above its 99% base");

        engine.freezeCollateral(address(a));

        uint256 frozenRate = engine.currentRedeemRateBps(address(a));
        assertEq(frozenRate, 9900, "frozen overweight A is capped at base (bonus dropped)");
        assertLt(frozenRate, enabledRate, "freeze removed the overweight bonus");
    }

    // -----------------------------------------------------------------
    // PROPERTY — on a dead feed the redeem VIEWS mirror the actual payout. `redeem` falls back to the
    // flat base rate at par (oracle-independent), and previewRedeem / currentRedeemRateBps now report
    // exactly that instead of quoting a spurious 0 (which would make an integrator treat the position
    // as worthless or block a redemption that would in fact succeed).
    // -----------------------------------------------------------------
    function test_DeadFeed_ViewsMatchRedeemPayout() public {
        // Keep >=2 OTHER funded flavors (A, C) so the tilt WOULD be live in the views if B were priced.
        _deposit(makeAddr("lp1"), a, 10_000e6);
        _deposit(makeAddr("lp2"), c, 10_000e18);
        address u = makeAddr("u");
        _deposit(u, b, 100e6); // small: killing its feed keeps backing above the distress line

        oracle.setPrice(address(b), 0); // B feed goes dead (MockOracle reverts on 0)

        uint256 quotedRate = engine.currentRedeemRateBps(address(b));
        uint256 quoted = engine.previewRedeem(address(b), 100e18);
        assertEq(quotedRate, 9900, "dead-feed flavor quotes its flat base rate, not 0");
        assertEq(quoted, 99e6, "preview quotes the base-rate payout at par");

        vm.prank(u);
        uint256 actual = engine.redeem(address(b), 100e18, 0);
        assertEq(actual, quoted, "redeem pays exactly what the view quoted");
        assertEq(actual, 99e6, "dead-feed redeem = base 99% at par");
    }
}
