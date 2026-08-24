// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SumUSD} from "../../src/SumUSD.sol";
import {SumUSDEngine} from "../../src/SumUSDEngine.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

/// @notice Exposes the engine's internal pure deposit peg-band guard so its band math can be proven
///         directly, without the basket-valuation division chains of the full deposit path.
contract EngineGuardHarness is SumUSDEngine {
    constructor(address admin, SumUSD _sumUsd) SumUSDEngine(admin, _sumUsd) {}

    function requirePeggedForDeposit(address collateral, uint256 priceWad) external pure {
        _requirePeggedForDeposit(collateral, priceWad);
    }
}

/// @notice Shared concrete world for the {SumUSDEngine} symbolic suites: the pool is seeded as in SetupLocal
///         (A $800 / B $400 / C $200, tilt 500, margin 2/1) so every basket loop unrolls over exactly three
///         flavors and the only symbolic inputs are the caller's.
abstract contract SumUSDEngineHalmosBase is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    // Mirrors the engine's immutable rails; a drift here fails the property, which is the point.
    uint256 internal constant MAX_TILT_SLOPE_BPS = 5000;
    uint256 internal constant MAX_REDEEM_MARGIN_BPS = 5;
    uint256 internal constant MIN_REDEEM_RATE_BPS = 9500;
    uint256 internal constant MAX_STALE_PRICE_GRACE = 1 days;
    uint256 internal constant MAX_DEPOSIT_PRICE_DEVIATION_BPS = 50;
    uint256 internal constant DISTRESS_RECOVERY_DELAY = 6 hours;

    SumUSD internal sumUsd;
    SumUSDEngine internal engine;
    MockOracle internal oracle;
    MockERC20 internal flavorA; // 6 decimals, overweight
    MockERC20 internal flavorB; // 6 decimals
    MockERC20 internal flavorC; // 18 decimals, underweight

    address internal owner = address(0x0111);
    address internal alice = address(0xA11CE);

    function setUp() public virtual {
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

        engine.setCollateral(address(flavorA), true, uint16(BPS), oracle);
        engine.setCollateral(address(flavorB), true, uint16(BPS), oracle);
        engine.setCollateral(address(flavorC), true, 9700, oracle);
        engine.setTiltSlopeBps(500);
        engine.setRedeemMargin(2, 1);
        vm.stopPrank();

        _deposit(flavorA, 800e6);
        _deposit(flavorB, 400e6);
        _deposit(flavorC, 200e18);
    }

    function _deposit(MockERC20 token, uint256 amount) internal {
        token.mint(alice, amount);
        vm.startPrank(alice);
        token.approve(address(engine), amount);
        engine.deposit(address(token), amount, 0);
        vm.stopPrank();
    }
}

/// @notice Symbolic (halmos) properties of {SumUSDEngine} that CI proves on every push. Every `check_*`
///         function is proven for ALL values of its arguments, not sampled. `forge test` ignores these
///         (no `test` prefix); run them with `halmos` from `contracts/` (config in halmos.toml).
contract SumUSDEngineHalmos is SumUSDEngineHalmosBase {
    // --- immutable rails on the owner setters ----------------------------------------------------

    /// @dev setTiltSlopeBps accepts exactly the values inside the MAX_TILT_SLOPE_BPS rail.
    function check_setTiltSlopeBps_rail(uint16 slope) public {
        vm.prank(owner);
        (bool ok,) = address(engine).call(abi.encodeCall(engine.setTiltSlopeBps, (slope)));
        assertEq(ok, slope <= MAX_TILT_SLOPE_BPS);
        if (ok) assertEq(engine.tiltSlopeBps(), slope);
    }

    /// @dev setRedeemMargin accepts exactly margin <= 5 bps with the routed part <= the margin.
    function check_setRedeemMargin_rail(uint16 marginBps, uint16 toRecipientBps) public {
        vm.prank(owner);
        (bool ok,) = address(engine).call(abi.encodeCall(engine.setRedeemMargin, (marginBps, toRecipientBps)));
        assertEq(ok, marginBps <= MAX_REDEEM_MARGIN_BPS && toRecipientBps <= marginBps);
    }

    /// @dev A listed flavor's base rate can only ever be set inside [95%, 100%].
    function check_setCollateral_rateRail(uint16 rateBps) public {
        vm.prank(owner);
        (bool ok,) =
            address(engine).call(abi.encodeCall(engine.setCollateral, (address(flavorA), true, rateBps, oracle)));
        assertEq(ok, rateBps >= MIN_REDEEM_RATE_BPS && rateBps <= BPS);
    }

    /// @dev setStalePriceParams accepts exactly grace <= MAX_STALE_PRICE_GRACE with haircut <= 100%.
    function check_setStalePriceParams_rail(uint32 graceSeconds, uint16 haircutBps) public {
        vm.prank(owner);
        (bool ok,) = address(engine).call(abi.encodeCall(engine.setStalePriceParams, (graceSeconds, haircutBps)));
        assertEq(ok, graceSeconds <= MAX_STALE_PRICE_GRACE && haircutBps <= BPS);
        if (ok) {
            assertEq(engine.stalePriceGraceSeconds(), graceSeconds);
            assertEq(engine.stalePriceHaircutBps(), haircutBps);
        }
    }

    /// @dev Exactly the guardian can freeze; a freeze only ever disables (never re-enables), and the
    ///      guardian holds no other lever (re-enabling is owner-only even for the guardian).
    function check_freezeCollateral_onlyGuardian(address caller) public {
        address g = address(0x6A4D);
        vm.prank(owner);
        engine.setGuardian(g);

        vm.prank(caller);
        (bool ok,) = address(engine).call(abi.encodeCall(engine.freezeCollateral, (address(flavorA))));
        assertEq(ok, caller == g);
        (bool enabled,,,,) = engine.configs(address(flavorA));
        assertEq(enabled, caller != g);

        vm.prank(g);
        (bool reEnabled,) = address(engine).call(abi.encodeCall(engine.setCollateralEnabled, (address(flavorA), true)));
        assertFalse(reEnabled); // the guardian's power is freeze-only
    }

    /// @dev No address other than the owner can move a governed parameter.
    function check_setters_onlyOwner(address caller) public {
        vm.assume(caller != owner);
        vm.startPrank(caller);
        (bool ok1,) = address(engine).call(abi.encodeCall(engine.setTiltSlopeBps, (100)));
        (bool ok2,) = address(engine).call(abi.encodeCall(engine.setRedeemMargin, (1, 0)));
        (bool ok3,) =
            address(engine).call(abi.encodeCall(engine.setCollateralBackingExcluded, (address(flavorA), true)));
        vm.stopPrank();
        assertFalse(ok1);
        assertFalse(ok2);
        assertFalse(ok3);
    }

    // --- pricing -------------------------------------------------------------------------------

    /// @dev The effective redemption rate never exceeds 100% for ANY size, on an overweight flavor (the
    ///      bonus side of the tilt, where a clamp bug would show) and an underweight one.
    function check_redeemRate_neverAboveBps(uint256 sumUsdAmount) public view {
        assertLe(engine.redeemRateBpsFor(address(flavorA), sumUsdAmount), BPS);
        assertLe(engine.redeemRateBpsFor(address(flavorC), sumUsdAmount), BPS);
    }

    /// @dev The mint quote is oracle-independent (par minting): repricing the flavor anywhere inside or
    ///      outside the peg band leaves the quote untouched, for any amount.
    function check_previewDeposit_ignoresPrice(uint256 amount, uint256 priceWad) public {
        vm.assume(priceWad != 0);
        uint256 before = engine.previewDeposit(address(flavorA), amount);
        oracle.setPrice(address(flavorA), priceWad);
        assertEq(engine.previewDeposit(address(flavorA), amount), before);
    }

    // --- deposit ---------------------------------------------------------------------------------

    /// @dev The peg-band guard's math is exact, proven on the pure guard via {EngineGuardHarness} in two
    ///      halves (the single-iff form drags the solver through the compiler's mul-overflow division and
    ///      times out; the end-to-end deposit version lives in the Deep suite for the same reason).
    ///      Half 1: every price within MAX_DEPOSIT_PRICE_DEVIATION_BPS of $1.00 is accepted.
    function check_pegBandGuard_acceptsInBand(uint256 priceWad) public {
        uint256 band = (WAD * MAX_DEPOSIT_PRICE_DEVIATION_BPS) / BPS;
        vm.assume(priceWad >= WAD - band && priceWad <= WAD + band);
        EngineGuardHarness harness = new EngineGuardHarness(owner, sumUsd);
        harness.requirePeggedForDeposit(address(flavorA), priceWad); // must not revert anywhere in the band
    }

    /// @dev Half 2: every price outside the band — all the way to the type's extremes — is rejected.
    function check_pegBandGuard_rejectsOutOfBand(uint256 priceWad) public {
        uint256 band = (WAD * MAX_DEPOSIT_PRICE_DEVIATION_BPS) / BPS;
        vm.assume(priceWad < WAD - band || priceWad > WAD + band);
        EngineGuardHarness harness = new EngineGuardHarness(owner, sumUsd);
        (bool ok,) =
            address(harness).call(abi.encodeCall(harness.requirePeggedForDeposit, (address(flavorA), priceWad)));
        assertFalse(ok);
    }

    /// @dev Mint conservation: a deposit mints EXACTLY the decimal-normalized amount (never more, never
    ///      less), and the pool receives exactly the deposited units — for any size.
    function check_deposit_mintsExactUnits(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 1e30);
        flavorB.mint(alice, amount);
        vm.prank(alice);
        flavorB.approve(address(engine), amount);

        uint256 supplyBefore = sumUsd.totalSupply();
        uint256 poolBefore = flavorB.balanceOf(address(engine));
        vm.prank(alice);
        uint256 minted = engine.deposit(address(flavorB), amount, 0);

        assertEq(minted, (amount * WAD) / 1e6); // 6-decimal flavor: 1 unit mints exactly 1 SumUSD
        assertEq(sumUsd.totalSupply(), supplyBefore + minted);
        assertEq(flavorB.balanceOf(address(engine)), poolBefore + amount);
    }

    // --- recapitalization / regime ---------------------------------------------------------------

    /// @dev donate is purely additive: for any size it mints nothing, credits the pool in full, and can
    ///      never push a healthy system into distress.
    function check_donate_neverMintsNeverDistresses(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 1e30);
        flavorA.mint(alice, amount);
        vm.prank(alice);
        flavorA.approve(address(engine), amount);

        uint256 supplyBefore = sumUsd.totalSupply();
        uint256 poolBefore = flavorA.balanceOf(address(engine));
        vm.prank(alice);
        uint256 received = engine.donate(address(flavorA), amount);

        assertEq(received, amount);
        assertEq(sumUsd.totalSupply(), supplyBefore); // no SumUSD minted for a donation
        assertEq(flavorA.balanceOf(address(engine)), poolBefore + amount);
        assertFalse(engine.distressed());
    }

    /// @dev The distress exit is sealed while healthy: redeemMix reverts for EVERY amount, so nobody can
    ///      take the haircut-free pro-rata path outside distress mode.
    function check_redeemMix_revertsWhenHealthy(uint256 amount) public {
        vm.prank(alice);
        (bool ok,) = address(engine).call(abi.encodeCall(engine.redeemMix, (amount, new uint256[](0))));
        assertFalse(ok);
        assertEq(sumUsd.totalSupply(), 1_400e18);
    }

    /// @dev Only a LISTED collateral is redeemable: for any unlisted token address and any size, redeem
    ///      reverts and burns nothing.
    function check_redeem_unlistedReverts(address token, uint256 amount) public {
        vm.assume(token != address(flavorA) && token != address(flavorB) && token != address(flavorC));
        vm.prank(alice);
        (bool ok,) = address(engine).call(abi.encodeCall(engine.redeem, (token, amount, 0)));
        assertFalse(ok);
        assertEq(sumUsd.totalSupply(), 1_400e18);
    }
}

/// @notice Symbolic properties of the DISTRESS regime (the F2 latch): the same pool, tipped below the
///         99% enter line by repricing the largest flavor to $0.90 and latched via {pokeDistress}.
contract SumUSDEngineDistressHalmos is SumUSDEngineHalmosBase {
    function setUp() public override {
        super.setUp();
        oracle.setPrice(address(flavorA), 0.9e18); // backing 1320/1400 = 94.28% < 99%
        engine.pokeDistress();
        assertTrue(engine.distressed());
    }

    /// @dev While latched, the cherry-picking paths are sealed for EVERY flavor and size: single-flavor
    ///      redeem and redeemBatch always revert (UseRedeemMix), and nothing is burned.
    function check_redeem_disabledInDistress(uint256 amount) public {
        vm.startPrank(alice);
        (bool ok1,) = address(engine).call(abi.encodeCall(engine.redeem, (address(flavorB), amount, 0)));
        address[] memory tokens = new address[](1);
        tokens[0] = address(flavorB);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        (bool ok2,) = address(engine).call(abi.encodeCall(engine.redeemBatch, (tokens, amounts, new uint256[](1))));
        vm.stopPrank();
        assertFalse(ok1);
        assertFalse(ok2);
        assertEq(sumUsd.totalSupply(), 1_400e18);
    }

    /// @dev No new SumUSD is ever minted into an under-backed pool: deposit reverts for every size.
    function check_deposit_disabledInDistress(uint256 amount) public {
        vm.prank(alice);
        (bool ok,) = address(engine).call(abi.encodeCall(engine.deposit, (address(flavorB), amount, 0)));
        assertFalse(ok);
        assertEq(sumUsd.totalSupply(), 1_400e18);
    }

    /// @dev redeemMix conservation: for any size, every leg pays EXACTLY the pro-rata slice
    ///      floor(balance * amount / supply) — no leg can ever exceed the redeemer's share — and the
    ///      burn is exact. (Order-independence follows: the slices are pure ownership math.)
    function check_redeemMix_paysExactProRata(uint256 amount) public {
        vm.assume(amount >= 1e12 && amount <= 1_400e18);
        uint256 supply = sumUsd.totalSupply();
        uint256 balA = flavorA.balanceOf(address(engine));
        uint256 balB = flavorB.balanceOf(address(engine));
        uint256 balC = flavorC.balanceOf(address(engine));

        vm.prank(alice);
        uint256[] memory amounts = engine.redeemMix(amount, new uint256[](0));

        assertEq(amounts[0], (balA * amount) / supply);
        assertEq(amounts[1], (balB * amount) / supply);
        assertEq(amounts[2], (balC * amount) / supply);
        assertEq(sumUsd.totalSupply(), supply - amount);
        assertEq(flavorA.balanceOf(alice), amounts[0]);
        assertEq(flavorB.balanceOf(alice), amounts[1]);
        assertEq(flavorC.balanceOf(alice), amounts[2]);
    }

    /// @dev The latch never clears on time alone: with backing still below the exit line, waiting ANY
    ///      amount of time and poking leaves the system distressed.
    function check_latch_timeAloneNeverClears(uint256 t) public {
        vm.assume(t >= block.timestamp && t < type(uint64).max);
        vm.warp(t);
        engine.pokeDistress();
        assertTrue(engine.distressed());
    }

    /// @dev Hysteresis is exact: once backing is recapitalized above the 100.25% exit line, the latch
    ///      clears at recoveryStartedAt + DISTRESS_RECOVERY_DELAY and not one second before.
    function check_latch_recoveryNeedsFullDelay(uint256 t) public {
        oracle.setPrice(address(flavorA), WAD);
        flavorB.mint(alice, 20e6);
        vm.startPrank(alice);
        flavorB.approve(address(engine), 20e6);
        engine.donate(address(flavorB), 20e6); // backing 1420/1400 = 101.42% >= exit; countdown starts
        vm.stopPrank();
        uint256 startedAt = engine.recoveryStartedAt();
        assertEq(startedAt, block.timestamp);

        vm.assume(t >= startedAt && t < type(uint64).max);
        vm.warp(t);
        engine.pokeDistress();
        assertEq(engine.distressed(), t < startedAt + DISTRESS_RECOVERY_DELAY);
    }
}

/// @notice Size-dependent pricing properties. TRUE but currently beyond the solvers (yices and bitwuzla both
///         time out on the 256-bit division chains in the tilt math), so they are NOT part of the CI gate
///         (halmos.toml matches `Halmos$`). Run by hand when the solver stack improves:
///         `halmos --contract SumUSDEngineHalmosDeep --solver-timeout-assertion 0`
contract SumUSDEngineHalmosDeep is SumUSDEngineHalmosBase {
    /// @dev Burning `x` SumUSD never pays out more than `x` of face value (at $1, 6-dec units == x / 1e12),
    ///      margin included, for any size the pool can actually serve.
    function check_previewRedeem_neverExceedsFace(uint256 sumUsdAmount) public view {
        vm.assume(sumUsdAmount <= 800e18);
        uint256 outUnits = engine.previewRedeem(address(flavorA), sumUsdAmount);
        assertLe(outUnits * 1e12, sumUsdAmount);
    }

    /// @dev Size monotonicity (the F1 fix): a larger redemption of the same flavor never prices at a
    ///      BETTER rate than a smaller one, so splitting a redemption can't beat a single one.
    function check_redeemRate_monotoneInSize(uint256 small, uint256 large) public view {
        vm.assume(small < large);
        vm.assume(large <= 1_400e18);
        assertGe(engine.redeemRateBpsFor(address(flavorC), small), engine.redeemRateBpsFor(address(flavorC), large));
    }

    /// @dev The above-par clamp (the F4 fix): for ANY live price at or above $1, redeeming never returns
    ///      more than $1 of mark-to-market value per SumUSD burned (outUnits * price <= face), so a
    ///      flight-to-quality flavor cannot be drained for more value than the supply retired.
    function check_redeemPayout_valueNeverExceedsFace(uint256 priceWad) public {
        vm.assume(priceWad >= WAD && priceWad <= 100 * WAD);
        oracle.setPrice(address(flavorA), priceWad);
        uint256 outUnits = engine.previewRedeem(address(flavorA), 100e18);
        // 6-decimal units valued at priceWad: value(WAD) = outUnits * priceWad / 1e6 <= 100e18.
        assertLe(outUnits * priceWad, 100e18 * 1e6);
    }

    /// @dev End-to-end peg-band exactness: a deposit succeeds iff the flavor's live price is in the band,
    ///      for every price in [0, $2]. (At this pool's weights every in-band price also passes the mint
    ///      guard, so the band is the whole gate. The CI suite proves the guard's band math on the pure
    ///      function instead — this full-path version hits the basket-ratio division chains and times out.)
    function check_deposit_pegBandExact(uint256 priceWad) public {
        vm.assume(priceWad <= 2 * WAD);
        uint256 amount = 100e6;
        flavorB.mint(alice, amount);
        vm.prank(alice);
        flavorB.approve(address(engine), amount);
        oracle.setPrice(address(flavorB), priceWad);

        vm.prank(alice);
        (bool ok,) = address(engine).call(abi.encodeCall(engine.deposit, (address(flavorB), amount, 0)));
        uint256 band = (WAD * MAX_DEPOSIT_PRICE_DEVIATION_BPS) / BPS;
        assertEq(ok, priceWad >= WAD - band && priceWad <= WAD + band);
    }

    /// @dev Redemption conservation: a successful redeem burns EXACTLY the requested SumUSD and sends
    ///      exactly the returned units, which never exceed face value.
    function check_redeem_burnsExact(uint256 amount) public {
        vm.assume(amount >= 1e12 && amount <= 100e18);
        uint256 supplyBefore = sumUsd.totalSupply();
        vm.prank(alice);
        uint256 out = engine.redeem(address(flavorA), amount, 0);
        assertEq(sumUsd.totalSupply(), supplyBefore - amount);
        assertEq(flavorA.balanceOf(alice), out);
        assertLe(out * 1e12, amount);
    }
}
