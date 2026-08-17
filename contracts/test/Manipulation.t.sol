// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SumUSD} from "../src/SumUSD.sol";
import {SumUSDEngine} from "../src/SumUSDEngine.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

/// @notice Regressions for the state-manipulation findings. Each test is the proof-of-concept that
///         DEMONSTRATED the exploit before the fix, re-pointed to assert the exploit no longer works.
///         Run: forge test --match-contract ManipulationTest -vv
contract ManipulationTest is Test {
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

    // =====================================================================
    // The tilt is priced on the POST-redemption basket, so a self-created
    // imbalance cannot be cashed out. Previously: flash-deposit a flavor to
    // push it past the upper band edge, its rate clamped to 100%, and the
    // attacker redeemed the flash mint PLUS their pre-existing balance with
    // no haircut at all. The round trip cost only gas and was repeatable
    // every block from a perfectly balanced pool.
    // =====================================================================
    function test_FlashImbalanceCannotBypassTheHaircut() public {
        _deposit(makeAddr("lp1"), a, 1_000e6);
        _deposit(makeAddr("lp2"), b, 1_000e6);
        _deposit(makeAddr("lp3"), c, 1_000e18);

        address atk = makeAddr("atk");
        _deposit(atk, a, 100e6);
        uint256 held = sumUsd.balanceOf(atk);
        uint256 honest = engine.previewRedeem(address(a), held);
        assertLt(honest, 100e6, "an honest exit pays the base haircut");

        vm.roll(block.number + 1); // the attack lands in a later block than the pool it targets

        uint256 flash = 100_000e6;
        a.mint(atk, flash);
        vm.startPrank(atk);
        a.approve(address(engine), flash);
        uint256 mintedFlash = engine.deposit(address(a), flash, 0);
        uint256 got = engine.redeem(address(a), mintedFlash + held, 0);
        vm.stopPrank();

        // Unwinding the deposit unwinds the share that justified the bonus, so the whole round trip
        // prices at the base rate: the attacker cannot even repay the loan, let alone skip the haircut.
        assertLt(got, flash, "the flash loan cannot be repaid out of the proceeds");
        emit log_named_decimal_uint("shortfall vs the loan (units A)", flash - got, 6);
        assertLt(got, flash + honest, "strictly worse than simply exiting honestly");
    }

    /// @dev The marginal quote still shows the bonus (the basket really is lopsided at that instant);
    ///      what changed is that a redemption large enough to unwind it prices on where the basket LANDS.
    function test_SizeIsPricedIn_BonusShrinksWithSize() public {
        _deposit(makeAddr("lp1"), a, 800e6);
        _deposit(makeAddr("lp2"), b, 100e6);
        _deposit(makeAddr("lp3"), c, 100e18);

        uint256 marginal = engine.marginalRedeemRateBps(address(a));
        assertGt(marginal, 9900, "A is overweight, so the marginal rate carries a bonus");

        uint256 small = engine.redeemRateBpsFor(address(a), 1e18);
        uint256 large = engine.redeemRateBpsFor(address(a), 400e18);
        assertLe(small, marginal, "a small trade prices at about the marginal rate");
        assertLt(large, small, "a large trade prices strictly worse: integrated, not spot");
    }

    // =====================================================================
    // The block-start basket reference stops an intra-block inflation from
    // crushing a third party's share below the convex knee. Previously the
    // victim's rate went to 0: with slippage protection they were denied
    // service, without it they burned SumUSD for nothing.
    // =====================================================================
    function test_FlashImbalanceCannotGriefOtherRedeemers() public {
        _deposit(makeAddr("lp1"), a, 1_000e6);
        _deposit(makeAddr("lp2"), b, 1_000e6);
        address victim = makeAddr("victim");
        _deposit(victim, c, 1_000e18);

        vm.roll(block.number + 1); // the attack lands in a later block than the pool it targets

        uint256 fairQuote = engine.previewRedeem(address(c), 100e18);
        assertEq(engine.marginalRedeemRateBps(address(c)), 9700, "C is at its base rate pre-attack");

        address atk = makeAddr("atk");
        a.mint(atk, 1_000_000e6);
        vm.startPrank(atk);
        a.approve(address(engine), 1_000_000e6);
        engine.deposit(address(a), 1_000_000e6, 0);
        vm.stopPrank();

        assertEq(engine.marginalRedeemRateBps(address(c)), 9700, "C's rate is unmoved by the inflation");

        // The victim's original quote still fills, in the same block, at the same price.
        vm.prank(victim);
        uint256 out = engine.redeem(address(c), 100e18, fairQuote);
        assertEq(out, fairQuote, "victim is neither denied service nor paid zero");
    }

    /// @dev The protection is one-sided on purpose: it caps how far an inflation can DEEPEN a penalty,
    ///      and never lets a deposit manufacture a bonus.
    function test_BlockRefDoesNotLetADepositManufactureABonus() public {
        _deposit(makeAddr("lp1"), a, 1_000e6);
        _deposit(makeAddr("lp2"), b, 1_000e6);
        _deposit(makeAddr("lp3"), c, 1_000e18);

        address atk = makeAddr("atk");
        a.mint(atk, 500_000e6);
        vm.startPrank(atk);
        a.approve(address(engine), 500_000e6);
        uint256 minted = engine.deposit(address(a), 500_000e6, 0);
        uint256 rate = engine.redeemRateBpsFor(address(a), minted);
        vm.stopPrank();
        assertLe(rate, 9900, "no bonus is created by the depositor's own deposit");
    }

    // =====================================================================
    // A de-backed ("siloed") flavor contributes 0 to backing, so minting
    // against it 1:1 diluted every holder on the spot. Deposits now reject
    // it outright rather than relying on governance to also freeze it.
    // =====================================================================
    function test_BackingExcludedFlavorIsNotMintable() public {
        _deposit(makeAddr("lp1"), a, 1_000e6);
        _deposit(makeAddr("lp2"), b, 1_000e6);
        assertEq(engine.systemCollateralizationRatioBps(), BPS);

        engine.setCollateralBackingExcluded(address(c), true);

        address atk = makeAddr("atk");
        c.mint(atk, 20e18);
        vm.startPrank(atk);
        c.approve(address(engine), 20e18);
        vm.expectPartialRevert(SumUSDEngine.CollateralBackingExcluded.selector);
        engine.deposit(address(c), 20e18, 0);
        vm.stopPrank();

        assertEq(engine.systemCollateralizationRatioBps(), BPS, "backing cannot be diluted this way");
    }

    function test_BackingExcludedFlavorStaysRedeemable() public {
        _deposit(makeAddr("lp1"), a, 1_000e6);
        _deposit(makeAddr("lp2"), b, 1_000e6);
        address u = makeAddr("u");
        _deposit(u, c, 20e18); // small enough that siloing it does not honestly trip distress
        engine.setCollateralBackingExcluded(address(c), true);
        assertFalse(engine.distressed(), "the honest ratio still clears the distress line");

        // Siloing blocks new exposure; it must never trap the holders already in. A de-backed flavor is
        // by construction scarce relative to the basket (one big enough to matter would honestly trip
        // distress), so it carries the convex penalty and exits in pieces rather than all at once.
        vm.prank(u);
        uint256 out = engine.redeem(address(c), 1e18, 0);
        assertGt(out, 0, "a de-backed flavor stays redeemable");
        assertLt(out, 1e18, "at a penalized rate");
        assertLe(engine.marginalRedeemRateBps(address(c)), 9700, "and never above base: penalty-direction only");
    }

    // =====================================================================
    // A flavor trading above $1 used to be drained at par, extracting more
    // than $1 of mark-to-market value per SumUSD burned and LOWERING the
    // backing ratio. The payout is now clamped at $1 of value.
    // =====================================================================
    function test_AbovePegFlavorCannotBeDrainedAbovePar() public {
        _deposit(makeAddr("lp1"), a, 1_000e6);
        _deposit(makeAddr("lp2"), b, 1_000e6);
        _deposit(makeAddr("lp3"), c, 1_000e18);

        oracle.setPrice(address(a), 1.05e18); // flight to quality

        uint256 ratioBefore = engine.systemCollateralizationRatioBps();
        address u = makeAddr("u");
        _deposit(u, b, 500e6);
        uint256 held = sumUsd.balanceOf(u);
        vm.prank(u);
        uint256 gotA = engine.redeem(address(a), held, 0);

        uint256 valueOut = (gotA * 1.05e18) / 1e6;
        assertLe(valueOut, held, "never more than $1 of value per SumUSD burned");
        assertGe(engine.systemCollateralizationRatioBps(), ratioBefore, "redemption no longer lowers backing");
    }

    function test_BelowPegPayoutIsUnchangedAtPar() public {
        _deposit(makeAddr("lp1"), a, 1_000e6);
        _deposit(makeAddr("lp2"), b, 1_000e6);
        address u = makeAddr("u");
        _deposit(u, c, 1_000e18);

        uint256 parQuote = engine.previewRedeem(address(a), 10e18);
        oracle.setPrice(address(a), 0.97e18); // sub-$1: the clamp must NOT engage
        assertEq(engine.previewRedeem(address(a), 10e18), parQuote, "low prices still pay par units");
    }

    // =====================================================================
    // The distress gate is latched with hysteresis. Previously a dust
    // `donate` re-crossed a bare threshold, and because a par redemption at
    // rate == ratio is ratio-NEUTRAL, that one crossing unlocked an
    // unlimited cherry-picking drain that never re-tripped the gate.
    // =====================================================================
    function test_DistressGateCannotBeFlippedByDust() public {
        address whale = makeAddr("whale");
        _deposit(whale, a, 500_000e6);
        _deposit(makeAddr("lp"), b, 500_000e6);

        oracle.setPrice(address(b), 0.96e18); // half the basket impairs -> ~98% backing
        engine.pokeDistress();
        assertTrue(engine.distressed(), "system latches into distress");

        vm.prank(whale);
        vm.expectPartialRevert(SumUSDEngine.UseRedeemMix.selector);
        engine.redeem(address(a), 1_000e18, 0);

        // The old escape: donate just enough to clear the ENTRY line.
        uint256 need;
        {
            uint256 target = (sumUsd.totalSupply() * 9900) / BPS;
            need = ((target - engine.totalCollateralValueUsd()) / 1e12) + 1;
        }
        a.mint(whale, need);
        vm.startPrank(whale);
        a.approve(address(engine), need);
        engine.donate(address(a), need);
        vm.stopPrank();

        assertGe(engine.systemCollateralizationRatioBps(), 9900, "back over the old threshold...");
        assertTrue(engine.distressed(), "...but the latch does not clear at the entry line");
        vm.prank(whale);
        vm.expectPartialRevert(SumUSDEngine.UseRedeemMix.selector);
        engine.redeem(address(a), 400_000e18, 0);
    }

    function test_DistressClearsOnlyAfterRealRecoveryHeldForTheDelay() public {
        address u = makeAddr("u");
        _deposit(u, a, 500_000e6);
        _deposit(makeAddr("lp"), b, 500_000e6);
        oracle.setPrice(address(b), 0.96e18);
        engine.pokeDistress();
        assertTrue(engine.distressed());

        // A genuine recapitalization above the EXIT line starts the countdown but does not clear it.
        uint256 need;
        {
            uint256 target = (sumUsd.totalSupply() * 10_100) / BPS;
            need = ((target - engine.totalCollateralValueUsd()) / 1e12) + 1;
        }
        a.mint(address(this), need);
        a.approve(address(engine), need);
        engine.donate(address(a), need);
        assertTrue(engine.distressed(), "countdown started, latch still set");
        assertGt(engine.distressClearsAt(), block.timestamp, "a clearing time is published");

        // A dip back below the exit line restarts the clock.
        vm.warp(block.timestamp + 3 hours);
        oracle.setPrice(address(b), 0.9e18);
        engine.pokeDistress();
        assertEq(engine.recoveryStartedAt(), 0, "clock reset by the dip");

        oracle.setPrice(address(b), 1e18);
        engine.pokeDistress();
        vm.warp(block.timestamp + 6 hours);
        engine.pokeDistress();
        assertFalse(engine.distressed(), "clears once the recovery has held for the full delay");

        vm.prank(u);
        engine.redeem(address(a), 1_000e18, 0); // single-flavor redemption is available again
    }

    function test_DistressEntryIsInstant() public {
        _deposit(makeAddr("u"), a, 1_000e6);
        _deposit(makeAddr("lp"), b, 1_000e6);
        assertFalse(engine.distressed());
        oracle.setPrice(address(b), 0.5e18);
        engine.pokeDistress();
        assertTrue(engine.distressed(), "a safety action never waits");
    }

    // =====================================================================
    // `funded` sets both parity band edges, so dust in an empty listed
    // flavor used to re-price the whole basket for free.
    // =====================================================================
    function test_DustCannotShiftTheBandEdges() public {
        // funded == 2 -> upper band edge is 100%, so A at 90% carries no bonus.
        _deposit(makeAddr("lp1"), a, 900e6);
        _deposit(makeAddr("lp2"), b, 100e6);
        uint256 rateA0 = engine.marginalRedeemRateBps(address(a));
        assertEq(rateA0, 9900, "A sits at its base rate with two funded flavors");

        // 1 wei of C values above zero (1e12 WAD) but below the funded floor, so it must not count.
        _deposit(makeAddr("dust"), c, 1);
        assertEq(engine.marginalRedeemRateBps(address(a)), rateA0, "dust does not move any rate");

        // A real position does count: funded becomes 3, the upper edge drops to 66.7%, and A at ~82%
        // is now genuinely overweight.
        _deposit(makeAddr("lp3"), c, 100e18);
        assertGt(engine.marginalRedeemRateBps(address(a)), rateA0, "a funded flavor does count");
    }

    // =====================================================================
    // redeemMix had no dust guard: a small pro-rata exit burned SumUSD and
    // returned zero of everything.
    // =====================================================================
    function test_RedeemMixRevertsRatherThanBurningForNothing() public {
        address u = makeAddr("u");
        _deposit(u, a, 1_000_000e6);
        _deposit(makeAddr("lp"), b, 1_000_000e6);
        oracle.setPrice(address(b), 0.9e18);
        engine.pokeDistress();
        assertTrue(engine.distressed());

        uint256[] memory none = new uint256[](0);
        vm.prank(u);
        vm.expectPartialRevert(SumUSDEngine.ZeroCollateralOut.selector);
        engine.redeemMix(1e6, none);

        // A real exit still works and still skips nothing it can pay.
        vm.prank(u);
        uint256[] memory out = engine.redeemMix(1_000e18, none);
        assertGt(out[0], 0);
        assertGt(out[1], 0);
    }

    // =====================================================================
    // Views must never revert on an unlisted collateral: a keeper batching
    // refreshes over a stale address list would otherwise revert outright.
    // =====================================================================
    function test_ViewsOnUnlistedTokenDoNotRevert() public {
        MockERC20 z = new MockERC20("Z", "Z", 6);
        _deposit(makeAddr("lp1"), a, 1_000e6);

        assertEq(engine.marginalRedeemRateBps(address(z)), 0);
        assertEq(engine.currentRedeemRateBps(address(z)), 0);
        assertEq(engine.previewRedeem(address(z), 1e18), 0);
        assertEq(engine.redeemRateBpsFor(address(z), 1e18), 0);
        assertEq(engine.valuationPriceWad(address(z)), 0);
        (uint256 p, bool ok) = engine.livePriceWad(address(z));
        assertEq(p, 0);
        assertFalse(ok);
        engine.refreshPrice(address(z)); // no-op, not a revert
    }
}
