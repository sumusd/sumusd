// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Test} from "forge-std/Test.sol";
import {SumUSD} from "../../src/SumUSD.sol";
import {SumUSDEngine} from "../../src/SumUSDEngine.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

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

    SumUSD internal sumUsd;
    SumUSDEngine internal engine;
    MockOracle internal oracle;
    MockERC20 internal flavorA; // 6 decimals, overweight
    MockERC20 internal flavorB; // 6 decimals
    MockERC20 internal flavorC; // 18 decimals, underweight

    address internal owner = address(0x0111);
    address internal alice = address(0xA11CE);

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
}
